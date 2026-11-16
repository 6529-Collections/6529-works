// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
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
import { Dependency } from "../libraries/Dependency.sol";
import { ProtocolContracts } from "../libraries/ProtocolContracts.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";

/// @title ArtistRegistry
/// @notice The slim artist registry: artist IDs, authority, payout and profile, with recovery
///         through 6529 consolidation (ADR 0001 section 11, including "Hardening"). Split wallets
///         resolve artist-resolved payees through {payoutAddress}, and the statement log asks
///         {isArtist}. Its address never changes: split wallets pin it, and the identity source
///         is swapped inside it ({setConsolidationSource}).
/// @dev Every identity change is staged, waits and can be stopped:
///      - STANDARD changes are signed as `Typehashes.IDENTITY_CHANGE` by the authority (they
///        wait the change delay) or, only for a dormant artist, by an established consolidated
///        wallet that was never this artist's authority (they wait the override delay and
///        record no activity): the consolidation source is replaceable, so it never decides
///        anything for a live artist. A new authority countersigns the same digest. The
///        previous authority, any wallet captured at staging, or the guardian ({vetoChange})
///        can stop them.
///      - Overrides (CONTESTED, ESTATE, LOST_KEY) are governed, carry an evidence hash as public
///        notice and wait the override delay; ESTATE and LOST_KEY, and any override that moves
///        the payout but keeps the authority, need the dormancy period without signed activity
///        (so a single governed role cannot freeze and redirect a live artist's payout without
///        also restraining the authority, in public). One that changes the authority carries the
///        new authority's
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
///      Timers. The waits are governed values ({setTimer}), each between a compiled floor (its
///      genesis value: the guarantee) and a compiled ceiling (lengthening is bounded too, because
///      a longer wait lengthens a payout freeze, a restraint or a stale wallet's standing). A
///      staged change locks the delay that set its `executableAt` and its contest timeout.
///
///      Standing: each artist keeps a sticky snapshot of at most `Limits.MAX_CANCELLERS`
///      consolidated wallets, refreshed on registration, staging, heartbeats, executions and by
///      anyone (`refreshStanding`; a keeper or the 6529.io UI calls it after consolidation
///      events). A refresh records every live two-way consolidation, a young one as pending
///      until its `effectiveAt` (registration plus 30 days). A recorded wallet that is no longer
///      consolidated (checked directly, not only against the bounded scan) is marked missing but
///      keeps standing; only a refresh at least the standing grace later removes it. A pending
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
///      source that fails is never read as "not consolidated": `refreshStanding` reverts, and
///      every other refresh (registration, staging, heartbeat, execution) is skipped with
///      {StandingRefreshSkipped}, so a dead, reverting or repriced source can block neither
///      recovery nor an artist's proof of activity. A gas shortfall reverts instead, whether
///      this registry observes it or the source reports it (`IConsolidationSource`).
///
///      Payout freeze. While a pending change would move the payout, {payoutAddress} returns
///      zero, so split wallets hold accrued balances until the outcome; the artist's own pulls
///      pause too. Payouts are validated at registration, staging and execution: never zero,
///      this registry, the bound package registry, Stream or its Editions, a split wallet of
///      the bound split factory, or a protocol contract that cannot pull (the revenue escrow,
///      the claim router, a sale adapter, a mint target, a registry or the work records,
///      recognised by ERC-165 through `ProtocolContracts`). A predicted, undeployed CREATE2
///      wallet is undetectable.
///
///      Restrained authority (owner decision on IDENTITY-1). While a pending, unlapsed override
///      would move the authority, {activeAuthorityOf} returns zero: nobody acts as the artist.
///      The consumers that treat the authority as the artist acting (sale `creator`, move and
///      acceptance signers, record amendments, ARTIST statements through {isArtist}) read it, so
///      the key being recovered from loses those powers and the reserved new key gains none
///      until the override executes. {authorityOf} keeps identifying the artist. A STANDARD
///      change or a payout-only override restrains nothing; identity calls ({heartbeat},
///      {revokeNonce}) are not creator powers and stay with the authority. The artist's
///      `restrained` flag, in the authority's own storage word, records whether the pending
///      change is an override that moves the authority: it is set at every staging and cleared
///      at every end of a change, so {activeAuthorityOf} reads the pending change (for a lapsed
///      contest) only while it is set.
///
///      Dormancy counts only acts of the artist's own authority: registration, a change the
///      authority signed, the authority's heartbeat, its cancel or contest, a nonce revocation,
///      and an execution that installs a new authority (its acceptance restarts the clock). A
///      wallet the consolidation source names never moves it: its stagings, cancels and contests
///      stop or propose changes but are no proof of life. Overrides, vetoes and executions that
///      keep the authority never move it either.
///
///      Federation directory (ADR 0001 section 16): one entry per federated token, written by the
///      current federation registry except LEFT, which only the token writes. Nothing that decides
///      an identity, a payout or standing reads it.
contract ArtistRegistry is IArtistRegistry, AccessManaged, EIP712 {
    // Floors and ceilings of the governed waits. Each floor is the genesis value and the
    // guarantee artists rely on (never shorter); each ceiling bounds lengthening, which would
    // otherwise let governance stretch a payout freeze, a restraint or a stale wallet's standing.
    // Packed 48 bits per {Timer}, in its order: CHANGE_DELAY 7 to 30 days, OVERRIDE_DELAY 180 to
    // 365 days, DORMANCY 365 to 1,825 days, CONTEST_TIMEOUT 365 to 730 days, STANDING_GRACE 30
    // to 90 days.
    uint256 private constant FLOORS = uint256(7 days) | (uint256(180 days) << 48)
        | (uint256(365 days) << 96) | (uint256(365 days) << 144) | (uint256(30 days) << 192);
    uint256 private constant CEILINGS = uint256(30 days) | (uint256(365 days) << 48)
        | (uint256(1825 days) << 96) | (uint256(730 days) << 144) | (uint256(90 days) << 192);
    /// @dev The floors' uphold window: the contest timeout exceeds the override delay by at least
    ///      this, so a contested override can always be upheld after its notice.
    uint256 private constant UPHOLD_WINDOW = 365 days - 180 days;

    /// @dev The account's consent to an identity created by the federation registry.
    bytes32 private constant ARTIST_REGISTRATION = keccak256(
        "ArtistRegistration(address account,bytes32 profileId,bytes32 profileDocHash,uint64 deadline)"
    );

    /// @dev The identity fields with `restrained` beside the authority, so the active authority
    ///      is one storage read: `restrained` is whether the pending change is an override that
    ///      moves the authority (`kind > STANDARD`, `next.authority != authority`), lapsed or not.
    struct Artist {
        address authority;
        bool restrained;
        address payout;
        bytes32 profileId;
        bytes32 profileDocHash;
        uint64 lastActivity;
        uint64 nonce;
    }

    mapping(uint256 artistId => Artist) private _artists;
    mapping(uint256 artistId => PendingChange) private _pending;
    mapping(uint256 artistId => Standing[]) private _standing;
    mapping(bytes32 digest => bool) private _acceptanceUsed;

    /// @dev A federation directory entry; artist IDs fit 160 bits. One slot.
    struct Listing {
        uint160 artistId;
        FederationStatus status;
    }

    mapping(address token => Listing) private _listings;
    /// @dev The governed waits, packed as {FLOORS} is.
    uint256 private _timerWord;

    /// @inheritdoc IArtistRegistry
    mapping(address account => uint256) public override artistIdOf;
    /// @inheritdoc IArtistRegistry
    mapping(address account => uint256) public override reservedFor;
    /// @inheritdoc IArtistRegistry
    IConsolidationSource public override consolidationSource;
    /// @inheritdoc IArtistRegistry
    bytes32 public override consolidationSourceCodeHash;
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
        consolidationSourceCodeHash = sourceCodeHash;
        emit ConsolidationSourceSet(address(0), address(source), sourceCodeHash);
        _timerWord = FLOORS;
        for (uint256 i; i <= uint256(Timer.STANDING_GRACE); ++i) {
            emit TimerSet(Timer(i), _field(FLOORS, i));
        }
    }

    // ----- wiring -----

    /// @inheritdoc IArtistRegistry
    function bindPackageRegistry(address target) external restricted {
        Dependency.check(target, type(IPackageRegistry).interfaceId);
        packageRegistry = _bind("PACKAGE_REGISTRY", packageRegistry, target);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev SUCCESSOR_SETTER role (the 30-day class): the same class as Stream's
    ///      `setDependency`, so both run in one governance batch. The install check is
    ///      `bindPackageRegistry`'s.
    function setPackageRegistry(address expected, address next) external restricted {
        if (expected != packageRegistry) revert ExpectedValueMismatch();
        Dependency.check(next, type(IPackageRegistry).interfaceId);
        packageRegistry = next;
        emit PackageRegistrySet(expected, next);
    }

    /// @inheritdoc IArtistRegistry
    function bindStream(address target) external restricted {
        Dependency.check(target, type(IStream).interfaceId);
        stream = _bind("STREAM", stream, target);
    }

    /// @inheritdoc IArtistRegistry
    function bindFederationRegistry(address target) external restricted {
        Dependency.check(target, type(IFederationRegistry).interfaceId);
        federationRegistry = _bind("FEDERATION_REGISTRY", federationRegistry, target);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev SUCCESSOR_SETTER role (the 30-day class). The install check is
    ///      `bindFederationRegistry`'s; a zero successor is refused, so the pointer never returns
    ///      to the unbound state.
    function setFederationRegistry(address expected, address next) external restricted {
        if (expected != federationRegistry) revert ExpectedValueMismatch();
        Dependency.check(next, type(IFederationRegistry).interfaceId);
        federationRegistry = next;
        emit FederationRegistrySet(expected, next);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev The factory does not implement ERC-165, so only code and no EIP-7702 are checked.
    function bindSplitFactory(address target) external restricted {
        Dependency.check(target);
        splitFactory = _bind("SPLIT_FACTORY", splitFactory, target);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev The statement log does not implement ERC-165: code, no EIP-7702, and its
    ///      `artistResolver()` naming this registry are checked instead. The read forwards all
    ///      gas (`BoundedCall.tryReadWordAll`): a shortfall reverts with `BoundedCallShortfall`,
    ///      any other failure or answer with `InvalidBinding`.
    function bindStatementLog(address target) external restricted {
        Dependency.check(target);
        (bool ok, bytes32 resolver) =
            BoundedCall.tryReadWordAll(target, abi.encodeWithSignature("artistResolver()"));
        if (!ok || resolver != bytes32(uint256(uint160(address(this))))) {
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
        consolidationSourceCodeHash = nextCodeHash;
        emit ConsolidationSourceSet(address(expected), address(next), nextCodeHash);
    }

    /// @inheritdoc IArtistRegistry
    function setTimer(Timer which, uint48 value) external restricted {
        uint256 shift = 48 * uint256(which);
        (uint48 floor, uint48 ceiling) = timerBounds(which);
        uint256 word =
            (_timerWord & ~(uint256(type(uint48).max) << shift)) | (uint256(value) << shift);
        if (
            value < floor || value > ceiling
                || _field(word, uint256(Timer.CONTEST_TIMEOUT))
                    < uint256(_field(word, uint256(Timer.OVERRIDE_DELAY))) + UPHOLD_WINDOW
        ) revert InvalidTimers();
        _timerWord = word;
        emit TimerSet(which, value);
    }

    // ----- identity lifecycle -----

    /// @inheritdoc IArtistRegistry
    function register(address account, bytes32 profileId, bytes32 profileDocHash)
        external
        returns (uint256)
    {
        if (msg.sender != packageRegistry) revert UnboundCaller(msg.sender);
        return _create(account, profileId, profileDocHash);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev The package registry verifies the account's own acceptance before it calls
    ///      `register`; the federation registry is not trusted to, so the signature is checked
    ///      here, in this registry's domain.
    function registerFederated(
        address account,
        bytes32 profileId,
        bytes32 profileDocHash,
        uint64 deadline,
        bytes calldata signature
    ) external returns (uint256) {
        if (msg.sender != federationRegistry) {
            revert UnboundCaller(msg.sender);
        }
        SignatureVerifier.checkDeadline(deadline);
        SignatureVerifier.check(
            account, registrationDigest(account, profileId, profileDocHash, deadline), signature
        );
        return _create(account, profileId, profileDocHash);
    }

    function _create(address account, bytes32 profileId, bytes32 profileDocHash)
        private
        returns (uint256 artistId)
    {
        if (account == address(0) || !_payoutAllowed(account)) revert InvalidIdentity();
        if (artistIdOf[account] != 0 || reservedFor[account] != 0) revert AccountTaken(account);
        artistId = uint256(uint160(account));
        ArtistIdentity memory identity = ArtistIdentity(account, account, profileId, profileDocHash);
        _artists[artistId] = Artist(
            account, false, account, profileId, profileDocHash, uint64(block.timestamp), 0
        );
        artistIdOf[account] = artistId;
        emit ArtistRegistered(artistId, identity);
        _refresh(artistId, account, true);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev Consumes the nonce. `authorityAcceptance` is ignored when the authority does not
    ///      change. Signed by the authority: records activity and waits the change delay. Signed
    ///      by a consolidated wallet (the replaceable consolidation source decides which): only
    ///      once the artist is dormant, checked before the source is read, so a live artist's
    ///      authority and payout never depend on the source; such a change records no activity
    ///      and waits the override delay, so a source has no faster path to a dormant artist
    ///      than a governed override, and the authority's own cancel stops it.
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
        bool byWallet = signer != a.authority;
        if (byWallet) {
            // A key the artist rotated away from signs nothing for it, even while it stays
            // consolidated with the new authority.
            if (artistIdOf[signer] == artistId) revert NotAuthorized(artistId, signer);
            _requireDormant(artistId, a);
            if (!_source().isEstablished(a.authority, signer)) {
                revert NotAuthorized(artistId, signer);
            }
        }
        _checkNext(artistId, next);
        bytes32 digest = changeDigest(artistId, next, a.nonce, deadline);
        SignatureVerifier.checkDeadline(deadline);
        SignatureVerifier.check(signer, digest, signature);
        if (next.authority != a.authority) {
            SignatureVerifier.check(next.authority, digest, authorityAcceptance);
        }
        if (!byWallet) _recordActivity(artistId, a);
        _stage(
            artistId,
            a,
            ChangeKind.STANDARD,
            next,
            bytes32(0),
            byWallet ? Timer.OVERRIDE_DELAY : Timer.CHANGE_DELAY
        );
    }

    /// @inheritdoc IArtistRegistry
    /// @dev Validates the kind, evidence, identity and dormancy first; the acceptance is checked
    ///      only when the authority changes. Replaces (vetoes) a pending STANDARD change. Dormancy
    ///      is required for ESTATE and LOST_KEY and for every override that moves the payout but
    ///      keeps the authority: such an override is never needed against a live artist (an
    ///      artist who holds the authority changes the payout itself; a thief who holds it must
    ///      lose it), and without the rule it would freeze a live artist's payout at once.
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
        bool payoutOnly = next.authority == a.authority && next.payout != a.payout;
        if (kind != ChangeKind.CONTESTED || payoutOnly) _requireDormant(artistId, a);
        if (next.authority != a.authority) {
            bytes32 digest = overrideDigest(artistId, kind, next, evidenceHash, deadline);
            if (_acceptanceUsed[digest]) revert AcceptanceUsed(digest);
            SignatureVerifier.checkDeadline(deadline);
            SignatureVerifier.check(next.authority, digest, authorityAcceptance);
            _acceptanceUsed[digest] = true;
            emit OverrideAcceptanceConsumed(artistId, digest);
        }
        ChangeKind pending = _pending[artistId].kind;
        if (pending > ChangeKind.STANDARD) revert ChangePending(artistId);
        if (pending != ChangeKind.NONE) _clear(artistId, msg.sender, true);
        _stage(artistId, a, kind, next, evidenceHash, Timer.OVERRIDE_DELAY);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev Records activity only when the caller is the artist's own key (the previous
    ///      authority): a captured wallet's cancel or contest stops the change but is no proof of
    ///      life, since the replaceable consolidation source decides which wallets are captured.
    ///      The no-op cancel of an already contested override records nothing. A contest
    ///      snapshots the artist's latest DISPUTE_OUTCOME, which can then not resolve it.
    function cancelChange(uint256 artistId) external {
        PendingChange storage p = _pendingOf(artistId);
        bool own = msg.sender == p.previousAuthority;
        bool allowed = p.kind == ChangeKind.STANDARD && own;
        address[] storage cancellers = p.cancellers;
        for (uint256 i; !allowed && i < cancellers.length; ++i) {
            allowed = cancellers[i] == msg.sender;
        }
        if (!allowed) revert NotAuthorized(artistId, msg.sender);
        if (p.contestedAt != 0) return;
        if (own) _recordActivity(artistId, _artists[artistId]);
        if (p.kind == ChangeKind.STANDARD) {
            _clear(artistId, msg.sender, false);
            return;
        }
        // Cancels happen during the notice; a late contest could front-run a due execution.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= p.executableAt) {
            revert ContestWindowClosed(artistId, p.executableAt);
        }
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
        if (!_lapsed(p)) revert ContestNotExpired(artistId, p.contestedAt + p.contestTimeout);
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
    ///      restarts the dormancy clock if the authority changed, and refreshes standing for the
    ///      (new) authority.
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
        ArtistIdentity memory previous = _identity(a);
        artistIdOf[next.authority] = artistId;
        // The change ends here, so the authority is no longer restrained.
        (a.authority, a.restrained, a.payout) = (next.authority, false, next.payout);
        (a.profileId, a.profileDocHash) = (next.profileId, next.profileDocHash);
        delete reservedFor[next.authority];
        delete _pending[artistId];
        // Only a new authority's acceptance is that authority's own act: an execution that keeps
        // the authority (a payout or profile change, whoever staged it) restarts no clock.
        if (next.authority != previous.authority) _recordActivity(artistId, a);
        emit ChangeExecuted(artistId, previous, next);
        _refresh(artistId, next.authority, true);
        return true;
    }

    /// @inheritdoc IArtistRegistry
    /// @dev The current authority only: a wallet named by a replaceable source could otherwise
    ///      keep any artist live and block dormancy-gated recovery. The refresh is best-effort:
    ///      a failing source must not keep a live artist from proving activity, or the artist
    ///      would become dormant and overridable.
    function heartbeat(uint256 artistId) external {
        Artist storage a = _artist(artistId);
        if (msg.sender != a.authority) revert NotAuthorized(artistId, msg.sender);
        _recordActivity(artistId, a);
        _refresh(artistId, a.authority, true);
    }

    /// @inheritdoc IArtistRegistry
    /// @dev The current authority only; records activity.
    function revokeNonce(uint256 artistId) external {
        Artist storage a = _artist(artistId);
        if (msg.sender != a.authority) revert NotAuthorized(artistId, msg.sender);
        emit NonceRevoked(artistId, a.nonce++);
        _recordActivity(artistId, a);
    }

    /// @inheritdoc IArtistRegistry
    function refreshStanding(uint256 artistId) external {
        _refresh(artistId, _artist(artistId).authority, false);
    }

    // ----- federation directory -----

    /// @inheritdoc IArtistRegistry
    /// @dev Writes only the token's own entry: nothing that decides an identity, a payout or
    ///      standing reads it. No list and no cap: each listing is its own slot, paid by its
    ///      registrant; enumeration is by events.
    function listFederatedContract(
        uint256 artistId,
        address token,
        uint8 form,
        address partner,
        uint32 feeShare,
        address feeRecipient
    ) external {
        if (msg.sender != federationRegistry) revert UnboundCaller(msg.sender);
        _artist(artistId);
        address s = stream;
        address e = IStream(s).editions();
        if (
            _listings[token].status != FederationStatus.NONE || !Dependency.isInstallable(token)
                || _canonical(token, s, e) || _canonical(partner, s, e)
                || _canonical(feeRecipient, s, e)
        ) revert FederatedContractRefused(token);
        // A registered artist's ID is the uint160 of its first authority.
        // forge-lint: disable-next-line(unsafe-typecast)
        _listings[token] = Listing(uint160(artistId), FederationStatus.ACTIVE);
        emit FederatedContractListed(
            artistId, token, token.codehash, form, partner, feeShare, feeRecipient
        );
    }

    /// @inheritdoc IArtistRegistry
    function setFederatedStatus(address token, FederationStatus status, bytes32 ref) external {
        if (msg.sender != federationRegistry) revert UnboundCaller(msg.sender);
        Listing storage l = _listings[token];
        FederationStatus current = l.status;
        if (
            current == FederationStatus.NONE || current == FederationStatus.LEFT
                || (status != FederationStatus.ACTIVE && status != FederationStatus.DELISTED)
        ) revert FederatedStatusRefused(token, current);
        l.status = status;
        emit FederatedContractStatus(token, l.artistId, status, ref);
    }

    /// @inheritdoc IArtistRegistry
    function recordFederationExit() external {
        Listing storage l = _listings[msg.sender];
        FederationStatus current = l.status;
        if (current == FederationStatus.NONE) revert FederatedStatusRefused(msg.sender, current);
        if (current == FederationStatus.LEFT) return;
        l.status = FederationStatus.LEFT;
        emit FederatedContractStatus(msg.sender, l.artistId, FederationStatus.LEFT, bytes32(0));
    }

    // ----- reads -----

    /// @inheritdoc IArtistRoleResolver
    /// @dev Resolves a 6529 Stream work (`IStream.artistOf`), or a 6529 Stream Editions edition
    ///      through its master, to the lead artist's active authority ({activeAuthorityOf}). Any
    ///      other subject returns false.
    function isArtist(address token, uint256 id, address account) external view returns (bool) {
        address s = stream;
        if (s == address(0) || token == address(0) || account == address(0)) return false;
        uint256 gasBefore = gasleft();
        if (token != s) {
            if (token != IStream(s).editions()) return false;
            try IEditions(token).masterOf(id) returns (
                address master, uint256 workId, bytes32 contentHash
            ) {
                // A well-formed answer names this Stream and the master's content.
                if (master != s || contentHash == bytes32(0)) return false;
                id = workId;
            } catch {
                _revertOnShortfall(token, gasBefore);
                return false;
            }
            gasBefore = gasleft();
        }
        try IStream(s).artistOf(id) returns (uint256 artistId) {
            return _active(artistId) == account;
        } catch {
            _revertOnShortfall(s, gasBefore);
            return false;
        }
    }

    /// @inheritdoc IArtistPayoutResolver
    /// @dev Zero for an unknown artist, and while a pending change would move the payout.
    function payoutAddress(uint256 artistId) external view returns (address) {
        address current = _artists[artistId].payout;
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
        return (_identity(a), a.lastActivity);
    }

    /// @inheritdoc IArtistRegistry
    function authorityOf(uint256 artistId) external view returns (address) {
        return _artist(artistId).authority;
    }

    /// @inheritdoc IArtistRegistry
    function activeAuthorityOf(uint256 artistId) external view returns (address) {
        _artist(artistId);
        return _active(artistId);
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
    function federatedListing(address token)
        external
        view
        returns (uint256 artistId, FederationStatus status)
    {
        Listing storage l = _listings[token];
        return (l.artistId, l.status);
    }

    /// @inheritdoc IArtistRegistry
    function timer(Timer which) public view returns (uint48) {
        return _field(_timerWord, uint256(which));
    }

    /// @inheritdoc IArtistRegistry
    function timerBounds(Timer which) public pure returns (uint48 floor, uint48 ceiling) {
        return (_field(FLOORS, uint256(which)), _field(CEILINGS, uint256(which)));
    }

    /// @dev The 48-bit field `index` of a packed timer word.
    function _field(uint256 word, uint256 index) private pure returns (uint48) {
        // The cast keeps exactly the field's 48 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(word >> (48 * index));
    }

    /// @notice The EIP-712 digest an account signs to consent to an identity created through
    ///         the federation registry (`registerFederated`).
    /// @param account The consenting account.
    /// @param profileId The claimed 6529 profile ID.
    /// @param profileDocHash The profile document hash.
    /// @param deadline The Unix time in seconds after which the signature is expired.
    /// @return The `ArtistRegistration` digest in this registry's EIP-712 domain.
    function registrationDigest(
        address account,
        bytes32 profileId,
        bytes32 profileDocHash,
        uint64 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(ARTIST_REGISTRATION, account, profileId, profileDocHash, deadline))
        );
    }

    /// @inheritdoc IArtistRegistry
    function standingOf(uint256 artistId) external view returns (Standing[] memory) {
        return _standing[artistId];
    }

    /// @notice The EIP-712 digest of a STANDARD change, which a new authority also signs.
    /// @param artistId The artist to change.
    /// @param next The identity after the change.
    /// @param nonce The artist's change nonce the signature binds (`changeNonce` when staged).
    /// @param deadline The Unix time in seconds after which the signatures are expired.
    /// @return The `Typehashes.IDENTITY_CHANGE` digest in this registry's EIP-712 domain.
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
    /// @param artistId The artist to override.
    /// @param kind The override kind: CONTESTED, ESTATE or LOST_KEY.
    /// @param next The identity after the override.
    /// @param evidenceHash The override's evidence hash.
    /// @param deadline The Unix time in seconds after which the acceptance is expired.
    /// @return The `Typehashes.OVERRIDE_ACCEPTANCE` digest in this registry's EIP-712 domain.
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
        if (a.authority == address(0)) revert UnknownArtist(artistId);
    }

    function _pendingOf(uint256 artistId) private view returns (PendingChange storage p) {
        p = _pending[artistId];
        if (p.kind == ChangeKind.NONE) revert NoPendingChange(artistId);
    }

    /// @dev Reverts with {NotDormant} unless the artist has had no signed activity for the
    ///      dormancy period.
    function _requireDormant(uint256 artistId, Artist storage a) private view {
        // Dormancy is a wall-clock bound; validator drift is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < uint256(a.lastActivity) + timer(Timer.DORMANCY)) {
            revert NotDormant(artistId, a.lastActivity);
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
    ///      consumer verifies against the active authority, which A never is again.
    function _taken(uint256 artistId, address account) private view returns (bool) {
        if (account == _artists[artistId].authority) return false;
        uint256 reserved = reservedFor[account];
        return artistIdOf[account] != 0 || (reserved != 0 && reserved != artistId);
    }

    /// @dev False for payouts that would strand or stall pull-only artist funds: none of these
    ///      can call `release`, and a release some other caller triggers for them pays them.
    function _payoutAllowed(address account) private view returns (bool) {
        address s = stream;
        address factory = splitFactory;
        return !(account == address(0) || account == address(this) || account == packageRegistry
                || (s != address(0) && (account == s || account == IStream(s).editions()))
                || (factory != address(0)
                    && (account == factory || ISplitFactory(factory).isWallet(account)))
                || ProtocolContracts.isProtocolContract(account));
    }

    /// @dev Whether `account` is a contract this registry knows as canonical or protocol: this
    ///      registry, 6529 Stream `s` and its Editions `e`, and every bound contract (the package
    ///      and federation registries, the split factory, the statement log and the consolidation
    ///      source). Zero is not.
    function _canonical(address account, address s, address e) private view returns (bool) {
        return account != address(0)
            && (account == address(this)
                || account == s
                || account == e
                || account == packageRegistry
                || account == federationRegistry
                || account == splitFactory
                || account == statementLog
                || account == address(consolidationSource));
    }

    /// @dev The consolidation source, its install-time code-hash pin re-checked at use (DEPS-6):
    ///      a source whose code no longer matches is never trusted. The established-wallet check
    ///      fails closed with `Dependency.DependencyCodeChanged`; for refreshes see {_refresh}.
    function _source() private view returns (IConsolidationSource source) {
        source = consolidationSource;
        Dependency.checkUnchanged(address(source), consolidationSourceCodeHash);
    }

    function _checkSource(IConsolidationSource source, bytes32 codeHash) private view {
        Dependency.checkPinned(address(source), type(IConsolidationSource).interfaceId, codeHash);
    }

    function _bind(bytes32 name, address current, address target) private returns (address) {
        if (current != address(0)) revert AlreadyBound(name);
        emit Bound(name, target);
        return target;
    }

    /// @dev Refreshes standing (best-effort), captures the snapshot's effective entries (missing
    ///      ones within their grace included; the refresh has removed the rest, unless it was
    ///      skipped, which removes nobody), consumes the nonce, locks the wait `delay` and the
    ///      contest timeout, and reserves a new authority until the change ends.
    function _stage(
        uint256 artistId,
        Artist storage a,
        ChangeKind kind,
        ArtistIdentity calldata next,
        bytes32 evidenceHash,
        Timer delay
    ) private {
        address current = a.authority;
        _refresh(artistId, current, true);
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
        p.contestTimeout = timer(Timer.CONTEST_TIMEOUT);
        p.next = next;
        p.previousAuthority = current;
        p.stagedAt = uint64(block.timestamp);
        p.executableAt = uint64(block.timestamp) + timer(delay);
        p.evidenceHash = evidenceHash;
        p.cancellers = cancellers;
        a.restrained = kind > ChangeKind.STANDARD && next.authority != current;
        if (next.authority != current) reservedFor[next.authority] = artistId;
        emit ChangeStaged(artistId, p);
    }

    /// @dev Updates recorded entries (a wallet absent from the bounded scan is checked directly
    ///      before it is marked missing), removes those missing for the standing grace and
    ///      pending ones found missing (they never had standing), then records new consolidations
    ///      in free slots, established before pending. Nothing is evicted. When `bestEffort`
    ///      (every refresh but `refreshStanding`), any source failure (a revert of any kind, or
    ///      an answer out of bounds) ends the refresh ({StandingRefreshSkipped}) instead of
    ///      reverting: what it already applied came from successful reads, and skipping the rest
    ///      removes nobody's standing. A source whose code no longer matches its pin (DEPS-6) is
    ///      treated the same way: a best-effort refresh skips without reading it, and
    ///      `refreshStanding` reverts with `Dependency.DependencyCodeChanged`. Reads forward all
    ///      gas, and a failure that leaves at most 1/8 of the gas held before it reverts with
    ///      `BoundedCallShortfall` (a gas shortfall is never read as a failing source).
    function _refresh(uint256 artistId, address authority, bool bestEffort) private {
        IConsolidationSource source = consolidationSource;
        if (address(source).codehash != consolidationSourceCodeHash) {
            if (!bestEffort) revert Dependency.DependencyCodeChanged(address(source));
            emit StandingRefreshSkipped(artistId);
            return;
        }
        uint256 gasBefore = gasleft();
        try source.consolidations(authority) returns (
            address[] memory live, uint64[] memory times
        ) {
            _update(artistId, source, authority, live, times, bestEffort);
        } catch (bytes memory reason) {
            _skipRefresh(artistId, reason, bestEffort, gasBefore);
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
            if (!bestEffort) revert InvalidSource(address(source));
            emit StandingRefreshSkipped(artistId);
            return;
        }
        Standing[] storage s = _standing[artistId];
        for (uint256 i = s.length; i > 0; --i) {
            Standing storage e = s[i - 1];
            address wallet = e.wallet;
            uint64 since = _effectiveIn(live, times, wallet);
            if (since == 0) {
                uint256 gasBefore = gasleft();
                try source.effectiveAt(authority, wallet) returns (uint64 at) {
                    since = at;
                } catch (bytes memory reason) {
                    return _skipRefresh(artistId, reason, bestEffort, gasBefore);
                }
            }
            if (since != 0) {
                // A pending entry follows its live clock, later as well as earlier (a revocation
                // and re-registration no refresh saw); an established one only moves earlier.
                // Every change, and a missing entry found again, is announced (logs-only rule).
                uint48 clock = e.effectiveAt;
                // forge-lint: disable-next-line(block-timestamp)
                if (since < clock || clock > block.timestamp) clock = _clamp48(since);
                if (clock != e.effectiveAt || e.missingSince != 0) {
                    (e.effectiveAt, e.missingSince) = (clock, 0);
                    emit StandingAdded(artistId, wallet, clock);
                }
                // forge-lint: disable-next-line(block-timestamp)
            } else if (e.missingSince == 0 && e.effectiveAt <= block.timestamp) {
                // forge-lint: disable-next-line(unsafe-typecast)
                e.missingSince = uint48(block.timestamp);
                emit StandingMissing(artistId, wallet);
                // A pending entry found missing never had standing: its consolidation ended
                // before its 30 days, so it goes at once (ADR 0001 section 11). Its missingSince is
                // zero, so the grace check below always holds for it. The grace is read only
                // here, so a refresh with nothing missing never loads the timers.
                // forge-lint: disable-next-line(block-timestamp)
            } else if (block.timestamp >= uint256(e.missingSince) + timer(Timer.STANDING_GRACE)) {
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
                uint48 since = _clamp48(times[i]);
                _standing[artistId].push(Standing(live[i], since, 0));
                emit StandingAdded(artistId, live[i], since);
            }
        }
    }

    /// @dev Ends a best-effort refresh on any source failure; rethrows every failure of a
    ///      refresh that must succeed. A gas shortfall reverts in both cases: one this call
    ///      observes (at most 1/8 of the gas left), and one the source reports, by the
    ///      `IConsolidationSource` convention, as `BoundedCallInsufficientGas` or
    ///      `BoundedCallShortfall` (a fixed-gas source refuses to start while gas is still left).
    function _skipRefresh(uint256 artistId, bytes memory reason, bool bestEffort, uint256 gasBefore)
        private
    {
        _revertOnShortfall(address(consolidationSource), gasBefore);
        // The first four bytes of the revert data: its error selector.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 selector = bytes4(reason);
        if (
            !bestEffort || selector == BoundedCall.BoundedCallInsufficientGas.selector
                || selector == BoundedCall.BoundedCallShortfall.selector
        ) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
        emit StandingRefreshSkipped(artistId);
    }

    /// @dev The shared gas rule (`BoundedCall`) for the registry's own try/catch reads, which
    ///      forward all gas: a failure that left at most 1/8 of the gas held before the call may
    ///      be the caller's gas supply, so it reverts and is never read as the callee's answer.
    function _revertOnShortfall(address target, uint256 gasBefore) private view {
        if (gasleft() <= gasBefore / BoundedCall.SHORTFALL_DIVISOR) {
            revert BoundedCall.BoundedCallShortfall(target);
        }
    }

    /// @dev A source-supplied time as stored: never truncated, at most the largest uint48 (a time
    ///      that far ahead stays pending for good).
    function _clamp48(uint64 time) private pure returns (uint48) {
        // The cast is reached only for times that fit 48 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return time > type(uint48).max ? type(uint48).max : uint48(time);
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

    /// @dev The authority, or zero while a pending, unlapsed override would move it (owner
    ///      decision on IDENTITY-1, 14 October 2026): nobody acts as the artist until it ends.
    ///      `restrained` stands for the pending change's kind and next authority, so the pending
    ///      change is read only while it is set.
    function _active(uint256 artistId) private view returns (address current) {
        Artist storage a = _artists[artistId];
        current = a.authority;
        if (a.restrained && !_lapsed(_pending[artistId])) current = address(0);
    }

    /// @dev Whether `p` is a contest nobody resolved within the contest timeout locked at its
    ///      staging.
    function _lapsed(PendingChange storage p) private view returns (bool) {
        uint64 contestedAt = p.contestedAt;
        // forge-lint: disable-next-line(block-timestamp)
        return contestedAt != 0 && block.timestamp >= uint256(contestedAt) + p.contestTimeout;
    }

    /// @dev Ends the pending change and its reservation. A change that keeps the authority
    ///      reserved nothing, and no other artist can reserve this artist's authority.
    function _clear(uint256 artistId, address by, bool vetoed) private {
        delete reservedFor[_pending[artistId].next.authority];
        delete _pending[artistId];
        _artists[artistId].restrained = false;
        emit ChangeCancelled(artistId, by, vetoed);
    }

    function _identity(Artist storage a) private view returns (ArtistIdentity memory) {
        return ArtistIdentity(a.authority, a.payout, a.profileId, a.profileDocHash);
    }

    function _recordActivity(uint256 artistId, Artist storage a) private {
        a.lastActivity = uint64(block.timestamp);
        emit ActivityRecorded(artistId, uint64(block.timestamp));
    }
}
