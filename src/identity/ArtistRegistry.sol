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
import { IStatementLog } from "../interfaces/IStatementLog.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { IStream } from "../interfaces/IStream.sol";
import {
    ArtistIdentity,
    ChangeKind,
    PendingChange,
    Standing
} from "../interfaces/types/IdentityTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
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
///        `Typehashes.OVERRIDE_ACCEPTANCE`, nonce-free (so a held key cannot void it by burning
///        nonces) and consumed once by digest. The previous authority can never stop an
///        override; a captured wallet's cancel during the notice contests it (a TDH vote then
///        decides, through {resolveContested}), and the guardian may veto it. An override
///        replaces a pending STANDARD change, so a key holder cannot block one by keeping a
///        change staged.
///      Every staging consumes the per-artist nonce (replay protection never keys on signature
///      bytes); {revokeNonce} burns it to retract an unused signature. A staging that changes the
///      authority reserves the new one ({reservedFor}) until the change executes or ends, so a
///      package acceptance by the new key cannot register it as a separate artist and void the
///      change. A new authority must never have been an authority, so the artist never returns
///      to a key it rotated away from, and that key's unused signatures stay void. The guardian
///      can only veto: no guardian path writes an identity.
///
///      Standing: each artist keeps a sticky snapshot of at most `Limits.MAX_CANCELLERS`
///      consolidated wallets, refreshed on registration, staging, heartbeats, executions and by
///      anyone (`refreshStanding`; a keeper or the 6529.io UI calls it after consolidation
///      events). A refresh records every live two-way consolidation, a young one as pending
///      until its `effectiveAt` (registration plus 30 days). A recorded wallet that is no longer
///      consolidated (checked directly, not only against the bounded scan) is marked missing but
///      keeps standing; only a refresh at least `STANDING_GRACE` later removes it. A pending
///      entry found no longer consolidated is removed at once: a consolidation that ended before
///      its 30 days never gives standing (ADR 0001 section 11). When the
///      snapshot is full nothing is evicted early: established wallets take free slots before
///      pending ones, and slots free up only as missing entries age out. The cancellers
///      captured at staging are the snapshot's entries whose `effectiveAt` has passed, so a key
///      holder who revokes or reorders the artist's consolidations cannot strip their standing:
///      one refresh any time after consolidating suffices (a consolidation revoked before its 30
///      days never had standing to strip).
///      After a rotation the previous authority's wallets stay in the snapshot as missing for the
///      grace, so a full snapshot admits the new authority's wallets only as they age out. A
///      source that cannot read reverts, so every call that reads it fails closed instead of
///      marking recorded wallets missing.
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
    /// @notice The wait before a STANDARD change can execute.
    uint64 public constant CHANGE_DELAY = 7 days;
    /// @notice The public notice before an override can execute.
    uint64 public constant OVERRIDE_DELAY = 180 days;
    /// @notice The time without signed activity before an ESTATE or LOST_KEY override.
    uint64 public constant DORMANCY = 365 days;
    /// @inheritdoc IArtistRegistry
    uint64 public constant override STANDING_GRACE = 30 days;
    /// @inheritdoc IArtistRegistry
    uint64 public constant override CONTEST_TIMEOUT = 365 days;
    /// @notice The most federated contracts listed per artist.
    uint256 public constant MAX_FEDERATED = 64;
    /// @dev Gas forwarded to the statement log's `artistResolver()` when it is bound.
    uint256 private constant BIND_READ_GAS = 50_000;

    struct Artist {
        ArtistIdentity identity;
        uint64 lastActivity;
        uint64 nonce;
    }

    mapping(uint256 artistId => Artist) private _artists;
    mapping(uint256 artistId => PendingChange) private _pending;
    mapping(uint256 artistId => Standing[]) private _standing;
    mapping(uint256 artistId => address[]) private _federated;
    mapping(bytes32 digest => bool) private _acceptanceUsed;

    /// @inheritdoc IArtistRegistry
    mapping(address account => uint256) public override artistIdOf;
    /// @inheritdoc IArtistRegistry
    mapping(address account => uint256) public override reservedFor;
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
    /// @inheritdoc IArtistRegistry
    address public override statementLog;

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
    /// @dev The statement log does not implement ERC-165: code, no EIP-7702, and its
    ///      `artistResolver()` naming this registry are checked instead, with a bounded read.
    function bindStatementLog(address target) external restricted {
        _checkBinding(target, bytes4(0));
        (bool ok, bytes memory resolver) = BoundedCall.tryRead(
            target, abi.encodeWithSignature("artistResolver()"), BIND_READ_GAS, 32, 0
        );
        if (!ok || resolver.length != 32 || abi.decode(resolver, (address)) != address(this)) {
            revert InvalidBinding(target);
        }
        statementLog = _bind("STATEMENT_LOG", statementLog, target);
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
        if (artistIdOf[account] != 0 || reservedFor[account] != 0) revert AccountTaken(account);
        artistId = uint256(uint160(account));
        ArtistIdentity memory identity = ArtistIdentity(account, account, profileId, profileDocHash);
        _artists[artistId] = Artist(identity, uint64(block.timestamp), 0);
        artistIdOf[account] = artistId;
        emit ArtistRegistered(artistId, identity);
        _refresh(artistId, account, true);
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
            bytes32 digest = overrideDigest(artistId, kind, next, evidenceHash, deadline);
            // forge-lint: disable-next-line(block-timestamp)
            bool expired = block.timestamp > deadline;
            if (_acceptanceUsed[digest]) revert AcceptanceUsed(digest);
            if (expired || !SignatureVerifier.isValid(next.authority, digest, authorityAcceptance))
            {
                revert InvalidSignature();
            }
            _acceptanceUsed[digest] = true;
        }
        ChangeKind pending = _pending[artistId].kind;
        if (pending > ChangeKind.STANDARD) revert ChangePending(artistId);
        if (pending != ChangeKind.NONE) _clear(artistId, msg.sender, true);
        _stage(artistId, a, kind, next, evidenceHash, OVERRIDE_DELAY);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev Records activity (the caller is the artist's old key or a captured wallet), except
    ///      for the no-op cancel of an already contested override. A contest snapshots the
    ///      artist's latest DISPUTE_OUTCOME, which can then not resolve it.
    function cancelChange(uint256 artistId) external {
        PendingChange storage p = _pendingOf(artistId);
        bool allowed = p.kind == ChangeKind.STANDARD && msg.sender == p.previousAuthority;
        address[] storage cancellers = p.cancellers;
        for (uint256 i; !allowed && i < cancellers.length; ++i) {
            allowed = cancellers[i] == msg.sender;
        }
        if (!allowed) revert NotAuthorized(artistId, msg.sender);
        if (p.contestedAt != 0) return;
        if (p.kind == ChangeKind.STANDARD) {
            _recordActivity(artistId, _artists[artistId]);
            _clear(artistId, msg.sender, false);
            return;
        }
        // Cancels happen during the notice; a late contest could front-run a due execution.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= p.executableAt) {
            revert ContestWindowClosed(artistId, p.executableAt);
        }
        _recordActivity(artistId, _artists[artistId]);
        p.contestedAt = uint64(block.timestamp);
        p.priorOutcome = _latestOutcome(artistId);
        emit ChangeContested(artistId, msg.sender);
    }

    /// @inheritdoc IArtistRegistry
    function resolveContested(uint256 artistId, bool uphold, bytes32 outcomeRef)
        external
        restricted
    {
        PendingChange storage p = _pending[artistId];
        if (p.contestedAt == 0 || _lapsed(p)) revert NotContested(artistId);
        if (outcomeRef == bytes32(0) || outcomeRef != _latestOutcome(artistId)) {
            revert OutcomeNotRecorded(artistId, outcomeRef);
        }
        if (outcomeRef == p.priorOutcome) revert OutcomePredatesContest(artistId, outcomeRef);
        // forge-lint: disable-next-line(block-timestamp)
        if (uphold && block.timestamp < p.executableAt) {
            revert ChangeNotDue(artistId, p.executableAt);
        }
        bool executed = uphold && _apply(artistId, p);
        if (!uphold) _clear(artistId, msg.sender, true);
        emit ContestResolved(artistId, uphold, executed, outcomeRef);
    }

    /// @inheritdoc IArtistRegistry
    function expireContest(uint256 artistId) external {
        PendingChange storage p = _pending[artistId];
        if (p.contestedAt == 0) revert NotContested(artistId);
        if (!_lapsed(p)) revert ContestNotExpired(artistId, p.contestedAt + CONTEST_TIMEOUT);
        emit ContestExpired(artistId);
        _clear(artistId, address(this), false);
    }

    /// @inheritdoc IArtistRegistry
    function vetoChange(uint256 artistId) external restricted {
        _pendingOf(artistId);
        _clear(artistId, msg.sender, true);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev Re-checks the next identity; if it is no longer valid (its payout became a split
    ///      wallet), the change is cleared with `ChangeCancelled(artistId, address(this), false)`
    ///      instead of reverting, so a stale change cannot freeze the payout. The authority
    ///      re-check is defence in depth: the staging reserved the new authority
    ///      ({reservedFor}), so nothing can take it meanwhile. Otherwise it applies the change,
    ///      restarts the dormancy clock and refreshes standing for the new authority.
    function executeChange(uint256 artistId) external {
        PendingChange storage p = _pendingOf(artistId);
        if (p.contestedAt != 0) revert OverrideContested(artistId);
        // Deadlines and delays are wall-clock bounds; validator drift is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < p.executableAt) revert ChangeNotDue(artistId, p.executableAt);
        _apply(artistId, p);
    }

    /// @dev Applies `p` after the D18 and payout re-checks, or clears it if they fail; returns
    ///      whether it was applied.
    function _apply(uint256 artistId, PendingChange storage p) private returns (bool) {
        ArtistIdentity memory next = p.next;
        if (!_payoutAllowed(next.payout) || _taken(artistId, next.authority)) {
            _clear(artistId, address(this), false);
            return false;
        }
        Artist storage a = _artists[artistId];
        ArtistIdentity memory previous = a.identity;
        artistIdOf[next.authority] = artistId;
        a.identity = next;
        delete reservedFor[next.authority];
        delete _pending[artistId];
        _recordActivity(artistId, a);
        emit ChangeExecuted(artistId, previous, next);
        _refresh(artistId, next.authority, true);
        return true;
    }

    /// @inheritdoc IArtistRegistry
    function heartbeat(uint256 artistId) external {
        Artist storage a = _artist(artistId);
        _requireSigner(artistId, a, msg.sender);
        _recordActivity(artistId, a);
        _refresh(artistId, a.identity.authority, false);
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
    function refreshStanding(uint256 artistId) external {
        _refresh(artistId, _artist(artistId).identity.authority, false);
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
        bool moves = p.kind != ChangeKind.NONE && p.next.payout != current && !_lapsed(p);
        return moves ? address(0) : current;
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

    /// @inheritdoc IArtistRegistry
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

    function _checkNext(uint256 artistId, ArtistIdentity calldata next) private view {
        if (next.authority == address(0) || !_payoutAllowed(next.payout)) revert InvalidIdentity();
        if (_taken(artistId, next.authority)) revert AccountTaken(next.authority);
    }

    /// @dev Whether `account` may not become `artistId`'s authority: it is or was an authority
    ///      (of another artist, or a previous one of this artist), or another artist's pending
    ///      change reserves it. The current authority itself is never taken. Refusing a return to
    ///      a previous authority (A, then B, then A) keeps the signatures A left unused dead: every
    ///      consumer verifies against the current authority, which A never is again.
    function _taken(uint256 artistId, address account) private view returns (bool) {
        if (account == _artists[artistId].identity.authority) return false;
        uint256 reserved = reservedFor[account];
        return artistIdOf[account] != 0 || (reserved != 0 && reserved != artistId);
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

    /// @dev Refreshes standing, captures the snapshot's effective entries (missing ones within
    ///      their grace included; the refresh has removed the rest), consumes the nonce and
    ///      reserves a new authority until the change ends.
    function _stage(
        uint256 artistId,
        Artist storage a,
        ChangeKind kind,
        ArtistIdentity calldata next,
        bytes32 evidenceHash,
        uint64 delay
    ) private {
        address current = a.identity.authority;
        _refresh(artistId, current, false);
        Standing[] storage snapshot = _standing[artistId];
        address[] memory cancellers = new address[](snapshot.length);
        uint256 n;
        for (uint256 i; i < snapshot.length; ++i) {
            // forge-lint: disable-next-line(block-timestamp)
            if (snapshot[i].effectiveAt <= block.timestamp) cancellers[n++] = snapshot[i].wallet;
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
        if (next.authority != current) reservedFor[next.authority] = artistId;
        emit ChangeStaged(artistId, p);
    }

    /// @dev Updates recorded entries (a wallet absent from the bounded scan is checked directly
    ///      before it is marked missing), removes those missing for {STANDING_GRACE} and pending
    ///      ones found missing (they never had standing), then records new consolidations in free
    ///      slots, established before pending. Nothing is evicted. When `bestEffort` (registration
    ///      and execution), a source read failing with `DelegationReadFailed` ends the refresh
    ///      ({StandingRefreshSkipped}) instead of reverting: what it already applied came from
    ///      successful reads, and skipping the rest removes nobody's standing. Staging,
    ///      heartbeats and `refreshStanding` fail closed.
    function _refresh(uint256 artistId, address authority, bool bestEffort) private {
        IConsolidationSource source = consolidationSource;
        try source.consolidations(authority) returns (
            address[] memory live, uint64[] memory times
        ) {
            _update(artistId, source, authority, live, times, bestEffort);
        } catch (bytes memory reason) {
            _skipRefresh(artistId, reason, bestEffort);
        }
    }

    /// @dev {_refresh} after the scan: `live` and `times` are the authority's consolidations.
    function _update(
        uint256 artistId,
        IConsolidationSource source,
        address authority,
        address[] memory live,
        uint64[] memory times,
        bool bestEffort
    ) private {
        if (live.length > 2 * Limits.MAX_CANCELLERS || times.length != live.length) {
            revert InvalidSource(address(source));
        }
        Standing[] storage s = _standing[artistId];
        for (uint256 i = s.length; i > 0; --i) {
            Standing storage e = s[i - 1];
            address wallet = e.wallet;
            uint64 since = _effectiveIn(live, times, wallet);
            if (since == 0) {
                try source.effectiveAt(authority, wallet) returns (uint64 at) {
                    since = at;
                } catch (bytes memory reason) {
                    return _skipRefresh(artistId, reason, bestEffort);
                }
            }
            if (since != 0) {
                // A pending entry follows its live clock, later as well as earlier (a revocation
                // and re-registration no refresh saw); an established one only moves earlier.
                // forge-lint: disable-next-line(block-timestamp)
                if (since < e.effectiveAt || e.effectiveAt > block.timestamp) {
                    // forge-lint: disable-next-line(unsafe-typecast)
                    e.effectiveAt = uint48(since);
                }
                if (e.missingSince != 0) {
                    e.missingSince = 0;
                    emit StandingAdded(artistId, wallet, e.effectiveAt);
                }
                // forge-lint: disable-next-line(block-timestamp)
            } else if (e.missingSince == 0 && e.effectiveAt <= block.timestamp) {
                // forge-lint: disable-next-line(unsafe-typecast)
                e.missingSince = uint48(block.timestamp);
                emit StandingMissing(artistId, wallet);
                // A pending entry found missing never had standing: its consolidation ended
                // before its 30 days, so it goes at once (ADR 0001 section 11). Its missingSince is
                // zero, so the grace check below always holds for it.
                // forge-lint: disable-next-line(block-timestamp)
            } else if (block.timestamp >= uint256(e.missingSince) + STANDING_GRACE) {
                s[i - 1] = s[s.length - 1];
                s.pop();
                emit StandingRemoved(artistId, wallet);
            }
        }
        for (uint256 pass; pass < 2; ++pass) {
            for (uint256 i; i < live.length && s.length < Limits.MAX_CANCELLERS; ++i) {
                // Pass 0 records established wallets, pass 1 pending ones.
                // forge-lint: disable-next-line(block-timestamp)
                if ((times[i] <= block.timestamp) != (pass == 0) || _recorded(s, live[i])) {
                    continue;
                }
                // forge-lint: disable-next-line(unsafe-typecast)
                _standing[artistId].push(Standing(live[i], uint48(times[i]), 0));
                emit StandingAdded(artistId, live[i], times[i]);
            }
        }
    }

    /// @dev Ends a best-effort refresh on the source's `DelegationReadFailed`; rethrows any other
    ///      failure, and every failure of a refresh that must succeed.
    function _skipRefresh(uint256 artistId, bytes memory reason, bool bestEffort) private {
        if (
            !bestEffort || reason.length != 36
                // forge-lint: disable-next-line(unsafe-typecast)
                || bytes4(reason) != IConsolidationSource.DelegationReadFailed.selector
        ) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
        emit StandingRefreshSkipped(artistId);
    }

    function _effectiveIn(address[] memory list, uint64[] memory times, address wallet)
        private
        pure
        returns (uint64)
    {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == wallet) return times[i];
        }
        return 0;
    }

    function _recorded(Standing[] storage s, address wallet) private view returns (bool) {
        for (uint256 i; i < s.length; ++i) {
            if (s[i].wallet == wallet) return true;
        }
        return false;
    }

    /// @dev The artist's latest DISPUTE_OUTCOME entry in the bound statement log, or zero.
    function _latestOutcome(uint256 artistId) private view returns (bytes32) {
        address log = statementLog;
        if (log == address(0)) return bytes32(0);
        return IStatementLog(log).latestDisputeOutcome(address(this), artistId);
    }

    /// @dev Whether `p` is a contest nobody resolved within {CONTEST_TIMEOUT}.
    function _lapsed(PendingChange storage p) private view returns (bool) {
        uint64 contestedAt = p.contestedAt;
        // forge-lint: disable-next-line(block-timestamp)
        return contestedAt != 0 && block.timestamp >= uint256(contestedAt) + CONTEST_TIMEOUT;
    }

    /// @dev Ends the pending change and its reservation. A change that keeps the authority
    ///      reserved nothing, and no other artist can reserve this artist's authority.
    function _clear(uint256 artistId, address by, bool vetoed) private {
        delete reservedFor[_pending[artistId].next.authority];
        delete _pending[artistId];
        emit ChangeCancelled(artistId, by, vetoed);
    }

    function _recordActivity(uint256 artistId, Artist storage a) private {
        a.lastActivity = uint64(block.timestamp);
        emit ActivityRecorded(artistId, uint64(block.timestamp));
    }
}
