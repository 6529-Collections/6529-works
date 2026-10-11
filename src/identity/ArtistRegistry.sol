// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistPayoutResolver } from "../economics/interfaces/IArtistPayoutResolver.sol";
import { ISplitFactory } from "../economics/interfaces/ISplitFactory.sol";
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
///        `Typehashes.OVERRIDE_ACCEPTANCE`, bound to the change nonce. Only captured wallets
///        (never the previous authority) or the guardian stop overrides. An override replaces a
///        pending STANDARD change, so a key holder cannot block one by keeping a change staged.
///      Every staging consumes the per-artist nonce (replay protection never keys on signature
///      bytes); {revokeNonce} burns it to retract an unused signature. The guardian can only
///      veto: no guardian path writes an identity.
///
///      Standing. Each artist has a sticky snapshot of up to `Limits.MAX_CANCELLERS` wallets with
///      recovery standing, refreshed on registration, staging, heartbeats, executions and by
///      anyone through {refreshStanding}. A refresh adds the authority's established wallets; a
///      wallet no longer established is marked missing but keeps standing, and is removed only
///      by a refresh at least {STANDING_GRACE} after it went missing, each step with an event.
///      The cancellers captured at staging are the snapshot's wallets with standing plus the
///      currently established ones. A thief who revokes the artist's consolidations therefore
///      cannot strip their standing before staging, and must wait out a public 30-day grace.
///
///      Payout freeze. While a pending change would move the payout, {payoutAddress} returns
///      zero, so split wallets hold accrued balances until the outcome; the artist's own pulls
///      pause too. Payouts are validated at registration, staging and execution: never zero,
///      this registry, the bound package registry, Stream or its Editions, or a split wallet of
///      the bound split factory (a predicted, undeployed CREATE2 wallet is undetectable).
///
///      Dormancy counts the artist's own activity: registration, a staged change, a heartbeat,
///      a cancel by the old key or a captured wallet, a nonce revocation, and an execution
///      (which restarts the clock for the identity it installs). Overrides and vetoes never do.
contract ArtistRegistry is IArtistRegistry, AccessManaged, EIP712 {
    /// @notice A wallet with recovery standing; `missingSince` is when a refresh first found it
    ///         no longer established, or zero.
    struct Standing {
        address wallet;
        uint64 missingSince;
    }

    /// @notice The wait before a STANDARD change can execute.
    uint64 public constant CHANGE_DELAY = 7 days;
    /// @notice The public notice before an override can execute.
    uint64 public constant OVERRIDE_DELAY = 180 days;
    /// @notice The time without signed activity before an ESTATE or LOST_KEY override.
    uint64 public constant DORMANCY = 365 days;
    /// @notice How long a missing wallet keeps standing.
    uint64 public constant STANDING_GRACE = 30 days;
    /// @notice The most federated contracts listed per artist.
    uint256 public constant MAX_FEDERATED = 64;

    struct Artist {
        ArtistIdentity identity;
        uint64 lastActivity;
        uint64 nonce;
    }

    mapping(uint256 artistId => Artist) private _artists;
    mapping(uint256 artistId => PendingChange) private _pending;
    mapping(uint256 artistId => Standing[]) private _standing;
    mapping(uint256 artistId => address[]) private _federated;

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
    /// @inheritdoc IArtistRegistry
    address public override splitFactory;

    /// @notice A wallet gained (or regained) recovery standing for an artist.
    event StandingAdded(uint256 indexed artistId, address indexed wallet);
    /// @notice A wallet is no longer established; it keeps standing for {STANDING_GRACE}.
    event StandingMissing(uint256 indexed artistId, address indexed wallet);
    /// @notice A wallet lost recovery standing after its grace period.
    event StandingRemoved(uint256 indexed artistId, address indexed wallet);

    /// @notice The artist already lists {MAX_FEDERATED} federated contracts.
    error FederatedListFull(uint256 artistId);

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
    function bindPackageRegistry(address target) external restricted {
        _checkBinding(target, type(IPackageRegistry).interfaceId);
        packageRegistry = _bind("PACKAGE_REGISTRY", packageRegistry, target);
    }

    /// @inheritdoc IArtistRegistry
    function bindStream(address target) external restricted {
        _checkBinding(target, type(IStream).interfaceId);
        stream = _bind("STREAM", stream, target);
    }

    /// @inheritdoc IArtistRegistry
    function bindFederationRegistry(address target) external restricted {
        _checkBinding(target, type(IFederationRegistry).interfaceId);
        federationRegistry = _bind("FEDERATION_REGISTRY", federationRegistry, target);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev The factory does not implement ERC-165, so only code and no EIP-7702 are checked.
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
        if (account == address(0) || !_payoutAllowed(account)) revert InvalidIdentity();
        if (artistIdOf[account] != 0) revert AccountTaken(account);
        artistId = uint256(uint160(account));
        ArtistIdentity memory identity = ArtistIdentity(account, account, profileId, profileDocHash);
        _artists[artistId] = Artist(identity, uint64(block.timestamp), 0);
        artistIdOf[account] = artistId;
        emit ArtistRegistered(artistId, identity);
        _refresh(artistId, account);
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
    /// @dev Validates the kind, evidence, identity and dormancy first; the acceptance is checked
    ///      only when the authority changes. Replaces (vetoes) a pending STANDARD change.
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
        // Dormancy and deadlines are wall-clock bounds; validator drift is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (kind != ChangeKind.CONTESTED && block.timestamp < a.lastActivity + DORMANCY) {
            revert NotDormant(artistId, a.lastActivity);
        }
        if (next.authority != a.identity.authority) {
            bytes32 digest = overrideDigest(artistId, kind, next, evidenceHash, a.nonce, deadline);
            // forge-lint: disable-next-line(block-timestamp)
            bool expired = block.timestamp > deadline;
            if (expired || !SignatureVerifier.isValid(next.authority, digest, authorityAcceptance))
            {
                revert InvalidSignature();
            }
        }
        ChangeKind pending = _pending[artistId].kind;
        if (pending > ChangeKind.STANDARD) revert ChangePending(artistId);
        if (pending != ChangeKind.NONE) _clear(artistId, msg.sender, true);
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
        _clear(artistId, msg.sender, false);
    }

    /// @inheritdoc IArtistRegistry
    function vetoChange(uint256 artistId) external restricted {
        _pendingOf(artistId);
        _clear(artistId, msg.sender, true);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev Re-checks the next identity; if it is no longer valid (its authority was taken or
    ///      its payout became a split wallet), the change is cleared with
    ///      `ChangeCancelled(artistId, address(this), false)` instead of reverting, so a stale
    ///      change cannot freeze the payout. Otherwise it applies the change, restarts the
    ///      dormancy clock and refreshes standing for the new authority.
    function executeChange(uint256 artistId) external {
        PendingChange storage p = _pendingOf(artistId);
        // Deadlines and delays are wall-clock bounds; validator drift is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < p.executableAt) revert ChangeNotDue(artistId, p.executableAt);
        ArtistIdentity memory next = p.next;
        if (!_payoutAllowed(next.payout) || _taken(artistId, next.authority)) {
            _clear(artistId, address(this), false);
            return;
        }
        Artist storage a = _artists[artistId];
        ArtistIdentity memory previous = a.identity;
        artistIdOf[next.authority] = artistId;
        a.identity = next;
        delete _pending[artistId];
        _recordActivity(artistId, a);
        emit ChangeExecuted(artistId, previous, next);
        _refresh(artistId, next.authority);
    }

    /// @inheritdoc IArtistRegistry
    function heartbeat(uint256 artistId) external {
        Artist storage a = _artist(artistId);
        _requireSigner(artistId, a, msg.sender);
        _recordActivity(artistId, a);
        _refresh(artistId, a.identity.authority);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev The current authority only; records activity.
    function revokeNonce(uint256 artistId) external {
        Artist storage a = _artist(artistId);
        if (msg.sender != a.identity.authority) revert NotAuthorized(artistId, msg.sender);
        emit NonceRevoked(artistId, a.nonce++);
        _recordActivity(artistId, a);
    }

    /// @notice Folds the authority's currently established wallets into the artist's standing
    ///         snapshot and ages out missing ones. Permissionless; not activity.
    function refreshStanding(uint256 artistId) external {
        _refresh(artistId, _artist(artistId).identity.authority);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev A v1.1 placeholder for cross-world discovery (ADR 0001 section 16); append-only and
    ///      bounded to {MAX_FEDERATED} entries.
    function listFederatedContract(uint256 artistId, address token) external {
        if (msg.sender != federationRegistry) revert UnboundCaller(msg.sender);
        _artist(artistId);
        if (_federated[artistId].length >= MAX_FEDERATED) revert FederatedListFull(artistId);
        _federated[artistId].push(token);
        emit FederatedContractListed(artistId, token);
    }

    // ----- reads -----

    /// @inheritdoc IArtistRoleResolver
    /// @dev Resolves a 6529 Stream work (`IStream.artistOf`), or a 6529 Editions edition through
    ///      its master, to the lead artist's current authority. Any other subject returns false.
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
    /// @dev Zero for an unknown artist, and while a pending change would move the payout.
    function payoutAddress(uint256 artistId) external view returns (address) {
        address current = _artists[artistId].identity.payout;
        PendingChange storage p = _pending[artistId];
        return (p.kind != ChangeKind.NONE && p.next.payout != current) ? address(0) : current;
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

    /// @notice The artist's standing snapshot, including missing wallets not yet removed.
    function standingOf(uint256 artistId) external view returns (Standing[] memory) {
        return _standing[artistId];
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
        uint256 nonce,
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

    function _checkNext(uint256 artistId, ArtistIdentity calldata next) private view {
        if (next.authority == address(0) || !_payoutAllowed(next.payout)) revert InvalidIdentity();
        if (_taken(artistId, next.authority)) revert AccountTaken(next.authority);
    }

    function _taken(uint256 artistId, address account) private view returns (bool) {
        uint256 holder = artistIdOf[account];
        return holder != 0 && holder != artistId;
    }

    /// @dev False for payouts that would strand or stall pull-only artist funds.
    function _payoutAllowed(address account) private view returns (bool) {
        address s = stream;
        address factory = splitFactory;
        return !(account == address(0) || account == address(this) || account == packageRegistry
                || (s != address(0) && (account == s || account == IStream(s).editions()))
                || (factory != address(0) && ISplitFactory(factory).isWallet(account)));
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

    /// @dev Refreshes standing, then captures the snapshot's wallets with standing plus the
    ///      currently established ones (snapshot first), and consumes the nonce.
    function _stage(
        uint256 artistId,
        Artist storage a,
        ChangeKind kind,
        ArtistIdentity calldata next,
        bytes32 evidenceHash,
        uint64 delay
    ) private {
        address current = a.identity.authority;
        address[] memory live = _refresh(artistId, current);
        Standing[] storage snapshot = _standing[artistId];
        address[] memory cancellers = new address[](Limits.MAX_CANCELLERS);
        uint256 n;
        for (uint256 i; i < snapshot.length && n < Limits.MAX_CANCELLERS; ++i) {
            uint64 missing = snapshot[i].missingSince;
            // forge-lint: disable-next-line(block-timestamp)
            if (missing == 0 || block.timestamp < missing + STANDING_GRACE) {
                cancellers[n++] = snapshot[i].wallet;
            }
        }
        for (uint256 i; i < live.length && n < Limits.MAX_CANCELLERS; ++i) {
            if (!_contains(cancellers, n, live[i])) cancellers[n++] = live[i];
        }
        assembly ("memory-safe") {
            mstore(cancellers, n)
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

    /// @dev Adds `authority`'s established wallets to the snapshot (while it has room), marks
    ///      absent ones missing, and removes those missing for {STANDING_GRACE}. Returns the
    ///      established wallets it read.
    function _refresh(uint256 artistId, address authority) private returns (address[] memory live) {
        live = consolidationSource.establishedWallets(authority);
        if (live.length > Limits.MAX_CANCELLERS) {
            revert InvalidSource(address(consolidationSource));
        }
        Standing[] storage s = _standing[artistId];
        for (uint256 i = s.length; i > 0; --i) {
            Standing storage e = s[i - 1];
            address wallet = e.wallet;
            if (_contains(live, live.length, wallet)) {
                if (e.missingSince != 0) {
                    e.missingSince = 0;
                    emit StandingAdded(artistId, wallet);
                }
            } else if (e.missingSince == 0) {
                e.missingSince = uint64(block.timestamp);
                emit StandingMissing(artistId, wallet);
                // forge-lint: disable-next-line(block-timestamp)
            } else if (block.timestamp >= e.missingSince + STANDING_GRACE) {
                s[i - 1] = s[s.length - 1];
                s.pop();
                emit StandingRemoved(artistId, wallet);
            }
        }
        for (uint256 i; i < live.length && s.length < Limits.MAX_CANCELLERS; ++i) {
            bool known = false;
            for (uint256 j; !known && j < s.length; ++j) {
                known = s[j].wallet == live[i];
            }
            if (!known) {
                _standing[artistId].push(Standing(live[i], 0));
                emit StandingAdded(artistId, live[i]);
            }
        }
    }

    function _contains(address[] memory list, uint256 length, address value)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < length; ++i) {
            if (list[i] == value) return true;
        }
        return false;
    }

    function _clear(uint256 artistId, address by, bool vetoed) private {
        delete _pending[artistId];
        emit ChangeCancelled(artistId, by, vetoed);
    }

    function _recordActivity(uint256 artistId, Artist storage a) private {
        a.lastActivity = uint64(block.timestamp);
        emit ActivityRecorded(artistId, uint64(block.timestamp));
    }
}
