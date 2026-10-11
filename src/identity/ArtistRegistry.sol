// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistPayoutResolver } from "../interfaces/IArtistPayoutResolver.sol";
import { IArtistRegistry, IConsolidationSource } from "../interfaces/IArtistRegistry.sol";
import { IArtistRoleResolver } from "../interfaces/IArtistRoleResolver.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IFederationRegistry } from "../interfaces/IFederationRegistry.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { IStream } from "../interfaces/IStream.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "../interfaces/types/IdentityTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";

/// @title ISplitWalletSource
/// @notice The one read the artist registry makes of the economics lane's split factory.
interface ISplitWalletSource {
    /// @notice Returns whether the factory deployed `wallet`.
    function isWallet(address wallet) external view returns (bool);
}

/// @title ArtistRegistry
/// @notice The slim artist registry: artist IDs, authority, payout and profile, with recovery
///         through 6529 consolidation (ADR 0001 section 11, including "Hardening"). Split wallets
///         resolve artist-resolved payees through {payoutAddress}, and the statement log asks
///         {isArtist}. Its address never changes: split wallets pin it, and the identity source
///         is swapped inside it ({setConsolidationSource}).
/// @dev Every identity change is staged, waits and can be stopped:
///      - STANDARD changes are signed by the authority or an established consolidated wallet as
///        `Typehashes.IDENTITY_CHANGE`; a new authority countersigns the same digest. They wait
///        {CHANGE_DELAY}; the previous authority, any wallet captured at staging, or the guardian
///        ({vetoChange}) can stop them.
///      - Overrides (CONTESTED, ESTATE, LOST_KEY) are governed, carry an evidence hash as public
///        notice and wait {OVERRIDE_DELAY}; ESTATE and LOST_KEY need {DORMANCY} without signed
///        activity. One that changes the authority carries the new authority's
///        `Typehashes.OVERRIDE_ACCEPTANCE`, single-use and free of the artist nonce so a held key
///        cannot void it. Only captured wallets (never the previous authority) or the guardian
///        stop overrides. An override replaces a pending STANDARD change, so a key holder cannot
///        block one by keeping a change staged.
///      Cancellers are the established consolidated wallets captured at staging, so revoking a
///      consolidation later does not strip them. STANDARD payloads are replay-protected by a
///      per-artist nonce (never signature bytes) that every staging consumes, so the chain of
///      changes is linear; {revokeNonce} burns the current nonce to retract an unused signature.
///      The guardian can only veto: no guardian path writes an identity.
///
///      Payout freeze. While an override, or a STANDARD change that moves the payout, is pending,
///      {payoutAddress} returns zero, so split wallets hold accrued balances until the outcome.
///      The trade-off: the artist's own withdrawals also pause for the window (7 days, or 180 for
///      an override), and a held key can re-freeze them by staging again after each cancel.
///
///      Payout validation. A payout (at registration, staging and again at execution) is never
///      zero, this registry, the bound package registry, Stream or its Editions, or a split wallet
///      the bound split factory deployed: artist payees are pull-only, so such a payout would
///      strand or stall funds. A split wallet's predicted CREATE2 address is undetectable before
///      deployment; the re-check at execution catches one deployed while the change waits.
///
///      Signed activity (for dormancy) is registration, a staged change, a heartbeat, a cancel by
///      the artist's keys or captured wallets, and a nonce revocation; executing a change also
///      restarts the clock for the identity it installs.
contract ArtistRegistry is IArtistRegistry, AccessManaged, EIP712 {
    /// @notice The wait before a STANDARD change can execute.
    uint64 public constant CHANGE_DELAY = 7 days;
    /// @notice The public notice before an override can execute.
    uint64 public constant OVERRIDE_DELAY = 180 days;
    /// @notice The time without signed activity before an ESTATE or LOST_KEY override.
    uint64 public constant DORMANCY = 365 days;

    struct Artist {
        ArtistIdentity identity;
        uint64 lastActivity;
        uint64 nonce;
    }

    mapping(uint256 artistId => Artist) private _artists;
    mapping(uint256 artistId => PendingChange) private _pending;
    mapping(uint256 artistId => address[]) private _federated;
    mapping(bytes32 digest => bool) private _acceptanceUsed;

    /// @inheritdoc IArtistRegistry
    mapping(address account => uint256) public override artistIdOf;
    /// @inheritdoc IArtistRegistry
    IConsolidationSource public override consolidationSource;
    /// @inheritdoc IArtistRegistry
    address public override packageRegistry;
    /// @inheritdoc IArtistRegistry
    address public override stream;
    /// @inheritdoc IArtistRegistry
    address public override federationRegistry;
    /// @notice The bound split factory, whose wallets are never accepted as a payout.
    address public splitFactory;

    /// @param initialAuthority The AccessManager.
    /// @param source The consolidation source (the v1 `ConsolidationAdapter`).
    /// @param sourceCodeHash The reviewed code hash of `source`.
    constructor(address initialAuthority, IConsolidationSource source, bytes32 sourceCodeHash)
        AccessManaged(initialAuthority)
        EIP712(Typehashes.ARTIST_REGISTRY_NAME, Typehashes.DOMAIN_VERSION)
    {
        _checkSource(source, sourceCodeHash);
        consolidationSource = source;
        emit ConsolidationSourceSet(address(0), address(source));
    }

    // ----- wiring -----

    /// @inheritdoc IArtistRegistry
    /// @dev Requires code, ERC-165 for `IPackageRegistry`, and no EIP-7702 delegation.
    function bindPackageRegistry(address target) external restricted {
        _checkBinding(target, type(IPackageRegistry).interfaceId);
        packageRegistry = _bind("PACKAGE_REGISTRY", packageRegistry, target);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev Requires code, ERC-165 for ERC-721, and no EIP-7702 delegation.
    function bindStream(address target) external restricted {
        _checkBinding(target, type(IERC721).interfaceId);
        stream = _bind("STREAM", stream, target);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev Requires code, ERC-165 for `IFederationRegistry`, and no EIP-7702 delegation.
    function bindFederationRegistry(address target) external restricted {
        _checkBinding(target, type(IFederationRegistry).interfaceId);
        federationRegistry = _bind("FEDERATION_REGISTRY", federationRegistry, target);
    }

    /// @notice Binds the economics split factory, once (genesis wiring). ADMIN role. Its
    ///         `isWallet` keeps split wallets out of payouts. Requires code and no EIP-7702
    ///         delegation (the factory does not implement ERC-165).
    function bindSplitFactory(address target) external restricted {
        _checkBinding(target, bytes4(0));
        splitFactory = _bind("SPLIT_FACTORY", splitFactory, target);
    }

    /// @inheritdoc IArtistRegistry
    function setConsolidationSource(
        IConsolidationSource expected,
        IConsolidationSource next,
        bytes32 nextCodeHash
    ) external restricted {
        if (address(expected) != address(consolidationSource)) {
            revert ExpectedValueMismatch();
        }
        _checkSource(next, nextCodeHash);
        consolidationSource = next;
        emit ConsolidationSourceSet(address(expected), address(next));
    }

    // ----- identity lifecycle -----

    /// @inheritdoc IArtistRegistry
    function register(address account, bytes32 profileId, bytes32 profileDocHash)
        external
        returns (uint256 artistId)
    {
        if (msg.sender != packageRegistry) revert UnboundCaller(msg.sender);
        if (account == address(0)) revert InvalidIdentity();
        if (artistIdOf[account] != 0) revert AccountTaken(account);
        _checkPayout(account);
        artistId = uint256(uint160(account));
        ArtistIdentity memory identity = ArtistIdentity(account, account, profileId, profileDocHash);
        _artists[artistId] = Artist(identity, uint64(block.timestamp), 0);
        artistIdOf[account] = artistId;
        emit ArtistRegistered(artistId, identity);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev Consumes the nonce and records activity. `authorityAcceptance` is ignored when the
    ///      authority does not change.
    function stageChange(
        uint256 artistId,
        ArtistIdentity calldata next,
        address signer,
        uint64 deadline,
        bytes calldata signature,
        bytes calldata authorityAcceptance
    ) external {
        Artist storage a = _artist(artistId);
        if (_pending[artistId].kind != ChangeKind.NONE) revert ChangePending(artistId);
        _requireSigner(artistId, a, signer);
        _checkNext(artistId, next);
        bytes32 digest = changeDigest(artistId, next, a.nonce, deadline);
        // Deadlines and delays are wall-clock bounds; validator drift is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline || !SignatureVerifier.isValid(signer, digest, signature)) {
            revert InvalidSignature();
        }
        if (
            next.authority != a.identity.authority
                && !SignatureVerifier.isValid(next.authority, digest, authorityAcceptance)
        ) revert InvalidSignature();
        _recordActivity(artistId, a);
        _stage(artistId, a, ChangeKind.STANDARD, next, bytes32(0), CHANGE_DELAY);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev Validates the kind, evidence, identity and dormancy before the acceptance, which is
    ///      checked (and consumed by digest) only when the authority changes. Replaces (vetoes) a
    ///      pending STANDARD change.
    function stageOverride(
        uint256 artistId,
        ChangeKind kind,
        ArtistIdentity calldata next,
        bytes32 evidenceHash,
        uint64 deadline,
        bytes calldata authorityAcceptance
    ) external restricted {
        Artist storage a = _artist(artistId);
        if (kind < ChangeKind.CONTESTED || evidenceHash == bytes32(0)) revert InvalidIdentity();
        _checkNext(artistId, next);
        // Dormancy is a wall-clock bound by design; validator drift is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (kind != ChangeKind.CONTESTED && block.timestamp < a.lastActivity + DORMANCY) {
            revert NotDormant(artistId, a.lastActivity);
        }
        if (next.authority != a.identity.authority) {
            bytes32 digest = overrideDigest(artistId, kind, next, evidenceHash, deadline);
            // A deadline is a wall-clock bound by design; validator drift is immaterial.
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp > deadline || _acceptanceUsed[digest]) revert InvalidSignature();
            if (!SignatureVerifier.isValid(next.authority, digest, authorityAcceptance)) {
                revert InvalidSignature();
            }
            _acceptanceUsed[digest] = true;
        }
        ChangeKind pending = _pending[artistId].kind;
        if (pending > ChangeKind.STANDARD) revert ChangePending(artistId);
        if (pending != ChangeKind.NONE) _clear(artistId, true);
        _stage(artistId, a, kind, next, evidenceHash, OVERRIDE_DELAY);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev Records activity: the canceller is the artist's old key or a captured wallet.
    function cancelChange(uint256 artistId) external {
        PendingChange storage p = _pendingOf(artistId);
        bool allowed = p.kind == ChangeKind.STANDARD && msg.sender == p.previousAuthority;
        address[] storage cancellers = p.cancellers;
        for (uint256 i; !allowed && i < cancellers.length; ++i) {
            allowed = cancellers[i] == msg.sender;
        }
        if (!allowed) revert NotAuthorized(artistId, msg.sender);
        _recordActivity(artistId, _artists[artistId]);
        _clear(artistId, false);
    }

    /// @inheritdoc IArtistRegistry
    function vetoChange(uint256 artistId) external restricted {
        _pendingOf(artistId);
        _clear(artistId, true);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev Re-checks that a new authority is still free, and restarts the dormancy clock.
    function executeChange(uint256 artistId) external {
        PendingChange storage p = _pendingOf(artistId);
        // Deadlines and delays are wall-clock bounds; validator drift is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < p.executableAt) revert ChangeNotDue(artistId, p.executableAt);
        Artist storage a = _artists[artistId];
        ArtistIdentity memory previous = a.identity;
        ArtistIdentity memory next = p.next;
        _checkNext(artistId, next);
        artistIdOf[next.authority] = artistId;
        a.identity = next;
        delete _pending[artistId];
        _recordActivity(artistId, a);
        emit ChangeExecuted(artistId, previous, next);
    }

    /// @inheritdoc IArtistRegistry
    function heartbeat(uint256 artistId) external {
        Artist storage a = _artist(artistId);
        _requireSigner(artistId, a, msg.sender);
        _recordActivity(artistId, a);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev The current authority only; records activity.
    function revokeNonce(uint256 artistId) external {
        Artist storage a = _artist(artistId);
        if (msg.sender != a.identity.authority) revert NotAuthorized(artistId, msg.sender);
        emit NonceRevoked(artistId, a.nonce++);
        _recordActivity(artistId, a);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev A v1.1 placeholder for cross-world discovery (ADR 0001 section 16); append-only.
    function listFederatedContract(uint256 artistId, address token) external {
        if (msg.sender != federationRegistry) revert UnboundCaller(msg.sender);
        _artist(artistId);
        _federated[artistId].push(token);
        emit FederatedContractListed(artistId, token);
    }

    // ----- reads -----

    /// @inheritdoc IArtistRoleResolver
    /// @dev Resolves a 6529 Stream work (`IStream.artistOf`), or a 6529 Editions edition through
    ///      its master, to the lead artist's current authority. Any other subject is unknown and
    ///      returns false, including pre-mint subjects `(address(0), itemHash)`: a v1 limitation.
    function isArtist(address token, uint256 id, address account) external view returns (bool) {
        address s = stream;
        if (s == address(0) || token == address(0) || account == address(0)) return false;
        if (token != s) {
            if (token != IStream(s).editions()) return false;
            try IEditions(token).masterOf(id) returns (
                address master, uint256 workId, bytes32 contentHash
            ) {
                // A well-formed answer names this Stream and the master's content.
                if (master != s || contentHash == bytes32(0)) return false;
                id = workId;
            } catch {
                return false;
            }
        }
        try IStream(s).artistOf(id) returns (uint256 artistId) {
            return _artists[artistId].identity.authority == account;
        } catch {
            return false;
        }
    }

    /// @inheritdoc IArtistPayoutResolver
    /// @dev Zero for an unknown artist, and while an override or a STANDARD change that moves the
    ///      payout is pending (see the payout freeze above).
    function payoutAddress(uint256 artistId) external view returns (address) {
        address current = _artists[artistId].identity.payout;
        PendingChange storage p = _pending[artistId];
        if (
            p.kind != ChangeKind.NONE && (p.kind != ChangeKind.STANDARD || p.next.payout != current)
        ) {
            return address(0);
        }
        return current;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IArtistRoleResolver).interfaceId
            || interfaceId == type(IArtistPayoutResolver).interfaceId
            || interfaceId == type(IArtistRegistry).interfaceId;
    }

    /// @inheritdoc IArtistRegistry
    function artist(uint256 artistId)
        external
        view
        returns (ArtistIdentity memory identity, uint64 lastActivity)
    {
        Artist storage a = _artist(artistId);
        return (a.identity, a.lastActivity);
    }

    /// @inheritdoc IArtistRegistry
    function authorityOf(uint256 artistId) external view returns (address) {
        return _artist(artistId).identity.authority;
    }

    /// @inheritdoc IArtistRegistry
    function pendingChange(uint256 artistId) external view returns (PendingChange memory) {
        return _pending[artistId];
    }

    /// @inheritdoc IArtistRegistry
    function changeNonce(uint256 artistId) external view returns (uint256) {
        return _artists[artistId].nonce;
    }

    /// @inheritdoc IArtistRegistry
    function federatedContracts(uint256 artistId) external view returns (address[] memory) {
        return _federated[artistId];
    }

    /// @notice The EIP-712 digest of a STANDARD change, which a new authority also signs.
    function changeDigest(
        uint256 artistId,
        ArtistIdentity calldata next,
        uint256 nonce,
        uint64 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    Typehashes.IDENTITY_CHANGE,
                    artistId,
                    next.authority,
                    next.payout,
                    next.profileId,
                    next.profileDocHash,
                    nonce,
                    deadline
                )
            )
        );
    }

    /// @notice The EIP-712 digest a new authority signs to accept an override.
    function overrideDigest(
        uint256 artistId,
        ChangeKind kind,
        ArtistIdentity calldata next,
        bytes32 evidenceHash,
        uint64 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    Typehashes.OVERRIDE_ACCEPTANCE,
                    artistId,
                    kind,
                    next.authority,
                    next.payout,
                    next.profileId,
                    next.profileDocHash,
                    evidenceHash,
                    deadline
                )
            )
        );
    }

    // ----- internals -----

    function _artist(uint256 artistId) private view returns (Artist storage a) {
        a = _artists[artistId];
        if (a.identity.authority == address(0)) revert UnknownArtist(artistId);
    }

    function _pendingOf(uint256 artistId) private view returns (PendingChange storage p) {
        p = _pending[artistId];
        if (p.kind == ChangeKind.NONE) revert NoPendingChange(artistId);
    }

    /// @dev `account` must be the authority or an established consolidated wallet of it.
    function _requireSigner(uint256 artistId, Artist storage a, address account) private view {
        address current = a.identity.authority;
        if (account != current && !consolidationSource.isEstablished(current, account)) {
            revert NotAuthorized(artistId, account);
        }
    }

    function _checkNext(uint256 artistId, ArtistIdentity memory next) private view {
        if (next.authority == address(0)) revert InvalidIdentity();
        _checkPayout(next.payout);
        uint256 holder = artistIdOf[next.authority];
        if (holder != 0 && holder != artistId) revert AccountTaken(next.authority);
    }

    /// @dev Rejects payouts that would strand or stall pull-only artist funds.
    function _checkPayout(address account) private view {
        address s = stream;
        address factory = splitFactory;
        if (
            account == address(0) || account == address(this) || account == packageRegistry
                || (s != address(0) && (account == s || account == IStream(s).editions()))
                || (factory != address(0) && ISplitWalletSource(factory).isWallet(account))
        ) revert InvalidIdentity();
    }

    function _checkSource(IConsolidationSource source, bytes32 codeHash) private view {
        address target = address(source);
        if (
            target.codehash != codeHash || DelegatedEOA.isDelegated(target)
                || !ERC165Checker.supportsInterface(target, type(IConsolidationSource).interfaceId)
        ) revert InvalidSource(target);
    }

    /// @dev `interfaceId` zero skips ERC-165 but still requires code.
    function _checkBinding(address target, bytes4 interfaceId) private view {
        if (
            target.code.length == 0 || DelegatedEOA.isDelegated(target)
                || (interfaceId != 0 && !ERC165Checker.supportsInterface(target, interfaceId))
        ) revert InvalidBinding(target);
    }

    function _bind(bytes32 name, address current, address target) private returns (address) {
        if (current != address(0)) revert AlreadyBound(name);
        emit Bound(name, target);
        return target;
    }

    /// @dev Consumes the nonce and captures the established wallets of the current authority.
    function _stage(
        uint256 artistId,
        Artist storage a,
        ChangeKind kind,
        ArtistIdentity calldata next,
        bytes32 evidenceHash,
        uint64 delay
    ) private {
        address current = a.identity.authority;
        address[] memory cancellers = consolidationSource.establishedWallets(current);
        if (cancellers.length > Limits.MAX_CANCELLERS) {
            revert InvalidSource(address(consolidationSource));
        }
        ++a.nonce;
        PendingChange storage p = _pending[artistId];
        p.kind = kind;
        p.next = next;
        p.previousAuthority = current;
        p.stagedAt = uint64(block.timestamp);
        p.executableAt = uint64(block.timestamp) + delay;
        p.evidenceHash = evidenceHash;
        p.cancellers = cancellers;
        emit ChangeStaged(artistId, p);
    }

    function _clear(uint256 artistId, bool vetoed) private {
        delete _pending[artistId];
        emit ChangeCancelled(artistId, msg.sender, vetoed);
    }

    function _recordActivity(uint256 artistId, Artist storage a) private {
        a.lastActivity = uint64(block.timestamp);
        emit ActivityRecorded(artistId, uint64(block.timestamp));
    }
}
