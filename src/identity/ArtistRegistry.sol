// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRegistry, IConsolidationSource } from "../interfaces/IArtistRegistry.sol";
import { IArtistRoleResolver } from "../interfaces/IArtistRoleResolver.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { IStream } from "../interfaces/IStream.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "../interfaces/types/IdentityTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";

/// @title ArtistRegistry
/// @notice The slim artist registry: artist IDs, authority, payout and profile, with recovery
///         through 6529 consolidation (ADR 0001 section 11, including "Hardening"). Split wallets
///         resolve artist-resolved payees through {payoutAddress} (the economics lane's
///         `IArtistPayoutResolver`), and the statement log asks {isArtist}.
/// @dev Every identity change is staged, waits and can be stopped:
///      - STANDARD changes are signed by the authority or an established consolidated wallet over
///        an EIP-712 `IdentityChange` (artist ID, next identity with its profile ID and profile
///        document hash, nonce, deadline); a new authority countersigns the same digest. They wait
///        {CHANGE_DELAY}; the previous authority, any wallet captured at staging, or the guardian
///        ({vetoChange}) can stop them.
///      - Overrides (CONTESTED, ESTATE, LOST_KEY) are governed, carry an evidence hash as public
///        notice and wait {OVERRIDE_DELAY}; ESTATE and LOST_KEY need {DORMANCY} without signed
///        activity. An override that changes the authority carries the new authority's EIP-712
///        `OverrideAcceptance` (single-use, with a deadline, and free of the artist nonce so a held
///        key cannot void it). Only captured wallets (never the previous authority) or the
///        guardian stop overrides. An override replaces a pending STANDARD change, so a key holder
///        cannot block one by keeping a change staged.
///      Cancellers are the established consolidated wallets captured at staging, so revoking a
///      consolidation later does not strip them. Signed payloads are replay-protected by a
///      per-artist nonce (never signature bytes) that every staging consumes, so the chain of
///      changes is linear; {revokeNonce} burns the current nonce to retract an unused signature.
///      The guardian can only veto: no guardian path writes an identity.
///
///      Callers. The package registry, the Stream contract and the v1.1 federation registry are
///      one-shot bindings, set once at wiring and never changed. Only the bound package registry
///      may {register}, and it may {heartbeat} for the artist (it does so only for first-time
///      acceptances); everything else is the artist's keys, governance or anyone.
///
///      Identifiers. An account's artist ID is `artistIdOf(account)` when non-zero, and otherwise
///      `uint256(uint160(account))`, the ID its first registration would create. The profile ID
///      and profile document hash are the artist's unverified claims; the registry stores and
///      binds them into signatures but does not check them against 6529 profiles.
contract ArtistRegistry is IArtistRegistry, AccessManaged, EIP712 {
    /// @notice The EIP-712 type of a signed STANDARD change.
    bytes32 public constant IDENTITY_CHANGE_TYPEHASH = keccak256(
        "IdentityChange(uint256 artistId,address authority,address payout,bytes32 profileId,"
        "bytes32 profileDocHash,uint256 nonce,uint64 deadline)"
    );
    /// @notice The EIP-712 type a new authority signs to accept an override.
    bytes32 public constant OVERRIDE_ACCEPTANCE_TYPEHASH = keccak256(
        "OverrideAcceptance(uint256 artistId,uint8 kind,address authority,address payout,"
        "bytes32 profileId,bytes32 profileDocHash,bytes32 evidenceHash,uint64 deadline)"
    );
    /// @notice The wait before a STANDARD change can execute.
    uint64 public constant CHANGE_DELAY = 7 days;
    /// @notice The public notice before an override can execute.
    uint64 public constant OVERRIDE_DELAY = 180 days;
    /// @notice The time without signed activity before an ESTATE or LOST_KEY override.
    uint64 public constant DORMANCY = 365 days;
    /// @notice ERC-165 ID of the economics lane's `IArtistPayoutResolver` (`payoutAddress`).
    bytes4 public constant PAYOUT_RESOLVER_INTERFACE_ID =
        bytes4(keccak256("payoutAddress(uint256)"));

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
    uint256 public override artistCount;
    /// @inheritdoc IArtistRegistry
    IConsolidationSource public override consolidationSource;
    /// @notice The bound package registry: the only {register} caller. Zero until bound.
    address public packageRegistry;
    /// @notice The bound 6529 Stream contract whose works {isArtist} resolves. Zero until bound.
    address public stream;
    /// @notice The bound v1.1 federation registry, the only writer of federated listings.
    address public federationRegistry;

    /// @notice The artist's current nonce was burned, retracting unused signed payloads.
    event NonceRevoked(uint256 indexed artistId, uint256 nonce);
    /// @notice A one-shot caller binding was set (`name` is "PACKAGE_REGISTRY", "STREAM" or
    ///         "FEDERATION_REGISTRY"); it never changes again.
    event Bound(bytes32 indexed name, address target);
    /// @notice The federation registry listed a federated contract of an artist.
    event FederatedContractListed(uint256 indexed artistId, address indexed token);

    /// @notice A consolidation source has no code, is an EIP-7702 delegated account, does not
    ///         support ERC-165 for `IConsolidationSource`, or returned more than
    ///         `Limits.MAX_CANCELLERS` wallets.
    error InvalidSource(address source);
    /// @notice The binding is already set.
    error AlreadyBound(bytes32 name);
    /// @notice A binding target has no code, is an EIP-7702 delegated account, or lacks the
    ///         expected ERC-165 interface.
    error InvalidBinding(address target);
    /// @notice The caller is not the bound contract for this call.
    error UnboundCaller(address caller);

    /// @param initialAuthority The AccessManager.
    /// @param source The consolidation source (the v1 `ConsolidationAdapter`).
    constructor(address initialAuthority, IConsolidationSource source)
        AccessManaged(initialAuthority)
        EIP712("6529 Works Artist Registry", "1")
    {
        _checkSource(source);
        consolidationSource = source;
        emit ConsolidationSourceSet(address(0), address(source));
    }

    // ----- identity lifecycle -----

    /// @inheritdoc IArtistRegistry
    /// @dev Only the bound package registry. Registration counts as signed activity.
    function register(address account, bytes32 profileId, bytes32 profileDocHash)
        external
        returns (uint256 artistId)
    {
        if (msg.sender != packageRegistry) revert UnboundCaller(msg.sender);
        if (account == address(0)) revert InvalidIdentity();
        if (artistIdOf[account] != 0) revert AccountTaken(account);
        artistId = uint256(uint160(account));
        ArtistIdentity memory identity = ArtistIdentity(account, account, profileId, profileDocHash);
        _artists[artistId] = Artist(identity, uint64(block.timestamp), 0);
        artistIdOf[account] = artistId;
        ++artistCount;
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
    /// @dev For overrides that keep the authority (for example an estate's payout). One that
    ///      changes the authority needs the six-argument form with the new authority's acceptance
    ///      and reverts here with `InvalidSignature`.
    function stageOverride(
        uint256 artistId,
        ChangeKind kind,
        ArtistIdentity calldata next,
        bytes32 evidenceHash
    ) external restricted {
        Artist storage a = _checkOverride(artistId, kind, next, evidenceHash);
        if (next.authority != a.identity.authority) revert InvalidSignature();
        _stageOverride(artistId, a, kind, next, evidenceHash);
    }

    /// @notice Stages an override, with `authorityAcceptance` from a new authority over
    ///         {overrideDigest} (two-sided). PARAMETER_SETTER role. Reverts with
    ///         `InvalidIdentity` for a non-override kind or a zero `evidenceHash`, `NotDormant` for
    ///         an ESTATE or LOST_KEY override within {DORMANCY} of signed activity, and
    ///         `InvalidSignature` for an expired, used or invalid acceptance. Replaces (vetoes) a
    ///         pending STANDARD change.
    function stageOverride(
        uint256 artistId,
        ChangeKind kind,
        ArtistIdentity calldata next,
        bytes32 evidenceHash,
        uint64 deadline,
        bytes calldata authorityAcceptance
    ) external restricted {
        Artist storage a = _checkOverride(artistId, kind, next, evidenceHash);
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
        _stageOverride(artistId, a, kind, next, evidenceHash);
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
        if (msg.sender != packageRegistry) _requireSigner(artistId, a, msg.sender);
        _recordActivity(artistId, a);
    }

    /// @notice Burns the artist's current nonce, so every unused payload signed for it is void
    ///         (preventive revocation). Callable by the authority or an established consolidated
    ///         wallet; records activity.
    function revokeNonce(uint256 artistId) external {
        Artist storage a = _artist(artistId);
        _requireSigner(artistId, a, msg.sender);
        emit NonceRevoked(artistId, a.nonce++);
        _recordActivity(artistId, a);
    }

    // ----- governed wiring (compare-and-set) -----

    /// @inheritdoc IArtistRegistry
    function setConsolidationSource(IConsolidationSource expected, IConsolidationSource next)
        external
        restricted
    {
        if (address(expected) != address(consolidationSource)) revert ExpectedValueMismatch();
        _checkSource(next);
        consolidationSource = next;
        emit ConsolidationSourceSet(address(expected), address(next));
    }

    /// @notice Binds the package registry, once (genesis wiring). It must support ERC-165 for
    ///         `IPackageRegistry`.
    function bindPackageRegistry(address target) external restricted {
        _checkBinding(target, type(IPackageRegistry).interfaceId);
        packageRegistry = _bind("PACKAGE_REGISTRY", packageRegistry, target);
    }

    /// @notice Binds the 6529 Stream contract, once (genesis wiring). It must support ERC-165 for
    ///         ERC-721.
    function bindStream(address target) external restricted {
        _checkBinding(target, type(IERC721).interfaceId);
        stream = _bind("STREAM", stream, target);
    }

    /// @notice Binds the v1.1 federation registry, once.
    function bindFederationRegistry(address target) external restricted {
        _checkBinding(target, bytes4(0));
        federationRegistry = _bind("FEDERATION_REGISTRY", federationRegistry, target);
    }

    /// @notice Lists a federated contract under an artist, for cross-world discovery (ADR 0001
    ///         section 16). Callable only by the federation registry (v1.1 placeholder).
    function listFederatedContract(uint256 artistId, address token) external {
        if (msg.sender != federationRegistry) revert UnboundCaller(msg.sender);
        _artist(artistId);
        _federated[artistId].push(token);
        emit FederatedContractListed(artistId, token);
    }

    // ----- reads -----

    /// @inheritdoc IArtistRoleResolver
    /// @dev Resolves a 6529 Stream work, or a 6529 Editions edition through its master, to the
    ///      lead artist's current authority. Any other subject, including `token == address(0)`,
    ///      is unknown and returns false.
    function isArtist(address token, uint256 id, address account) external view returns (bool) {
        address s = stream;
        if (s == address(0) || token == address(0) || account == address(0)) return false;
        if (token != s) {
            if (token != IStream(s).editions()) return false;
            try IEditions(token).masterOf(id) returns (
                address master, uint256 workId, bytes32 contentId
            ) {
                // A well-formed answer names this Stream and the master's content.
                if (master != s || contentId == bytes32(0)) return false;
                id = workId;
            } catch {
                return false;
            }
        }
        try IStream(s).work(id) returns (IStream.WorkInfo memory info) {
            return _artists[info.artistId].identity.authority == account;
        } catch {
            return false;
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IArtistRoleResolver).interfaceId
            || interfaceId == type(IArtistRegistry).interfaceId
            || interfaceId == PAYOUT_RESOLVER_INTERFACE_ID;
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
    function payoutAddress(uint256 artistId) external view returns (address) {
        return _artists[artistId].identity.payout;
    }

    /// @inheritdoc IArtistRegistry
    function pendingChange(uint256 artistId) external view returns (PendingChange memory) {
        return _pending[artistId];
    }

    /// @inheritdoc IArtistRegistry
    function changeNonce(uint256 artistId) external view returns (uint256) {
        return _artists[artistId].nonce;
    }

    /// @notice An artist's federated contracts, in listing order.
    function federatedContracts(uint256 artistId) external view returns (address[] memory) {
        return _federated[artistId];
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
                    OVERRIDE_ACCEPTANCE_TYPEHASH,
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

    /// @notice The EIP-712 digest a STANDARD change (and a new authority's acceptance) signs.
    function changeDigest(
        uint256 artistId,
        ArtistIdentity calldata next,
        uint256 nonce,
        uint64 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    IDENTITY_CHANGE_TYPEHASH,
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

    /// @dev Validates an override before any acceptance is checked or consumed.
    function _checkOverride(
        uint256 artistId,
        ChangeKind kind,
        ArtistIdentity calldata next,
        bytes32 evidenceHash
    ) private view returns (Artist storage a) {
        a = _artist(artistId);
        if (kind < ChangeKind.CONTESTED || evidenceHash == bytes32(0)) {
            revert InvalidIdentity();
        }
        _checkNext(artistId, next);
        // Dormancy is a wall-clock bound by design; validator drift is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (kind != ChangeKind.CONTESTED && block.timestamp < a.lastActivity + DORMANCY) {
            revert NotDormant(artistId, a.lastActivity);
        }
    }

    /// @dev Replaces a pending STANDARD change (a veto) and stages the override.
    function _stageOverride(
        uint256 artistId,
        Artist storage a,
        ChangeKind kind,
        ArtistIdentity calldata next,
        bytes32 evidenceHash
    ) private {
        ChangeKind pending = _pending[artistId].kind;
        if (pending > ChangeKind.STANDARD) revert ChangePending(artistId);
        if (pending != ChangeKind.NONE) _clear(artistId, true);
        _stage(artistId, a, kind, next, evidenceHash, OVERRIDE_DELAY);
    }

    function _checkNext(uint256 artistId, ArtistIdentity memory next) private view {
        if (next.authority == address(0) || next.payout == address(0)) revert InvalidIdentity();
        uint256 holder = artistIdOf[next.authority];
        if (holder != 0 && holder != artistId) revert AccountTaken(next.authority);
    }

    function _checkSource(IConsolidationSource source) private view {
        address target = address(source);
        if (
            target.code.length == 0 || DelegatedEOA.isDelegated(target)
                || !ERC165Checker.supportsInterface(target, type(IConsolidationSource).interfaceId)
        ) revert InvalidSource(target);
    }

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
