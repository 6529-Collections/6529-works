// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistPayoutResolver } from "../economics/interfaces/IArtistPayoutResolver.sol";
import { IArtistRoleResolver } from "./IArtistRoleResolver.sol";
import { ArtistIdentity, ChangeKind, PendingChange, Standing } from "./types/IdentityTypes.sol";

/// @title IConsolidationSource
/// @notice Where the artist registry learns an account's established consolidated wallets
///         (ADR 0001 section 11 "Recovery uses 6529 consolidation").
/// @dev The v1 adapter reads the 6529 delegation contract
///      (`0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`, use case 999) and walks registration and
///      expiry dates directly: a wallet counts only if its consolidation with `account` is at
///      least 30 days old and not expired. Use case 997 (primary address) is never used as a
///      payout. A 6529-chain source replaces it through a 30-day governed swap. A source must
///      fail closed: when it cannot read its data, it reverts instead of answering "not
///      consolidated", which would strip recorded standing.
interface IConsolidationSource is IERC165 {
    /// @notice `account`'s established consolidated wallets, at most `Limits.MAX_CANCELLERS`.
    function establishedWallets(address account) external view returns (address[] memory);
    /// @notice Whether `wallet` is an established consolidated wallet of `account` now.
    function isEstablished(address account, address wallet) external view returns (bool);
    /// @notice `account`'s live two-way consolidations, established or still young, at most
    ///         `2 * Limits.MAX_CANCELLERS`, each with the time it becomes (or became) established.
    function consolidations(address account)
        external
        view
        returns (address[] memory wallets, uint64[] memory effectiveAt);
    /// @notice When `wallet`'s live consolidation with `account` becomes (or became)
    ///         established, or zero if they are not consolidated both ways.
    function effectiveAt(address account, address wallet) external view returns (uint64);
}

/// @title IArtistRegistry
/// @notice The slim artist registry: artist IDs, authority, payout and profile, with recovery
///         through 6529 consolidation (ADR 0001 section 11).
/// @dev Artist IDs: an account's ID is `artistIdOf(account)` when nonzero, otherwise
///      `uint256(uint160(account))`, the ID its first package acceptance creates. IDs are known
///      before any transaction, are the same on every chain, fit in 160 bits, and never change
///      when the authority does. Every account that has been an artist's authority maps to that
///      ID forever, so a package naming an old address still resolves to the identity, while
///      only the current authority can sign. `profileId` is the artist's unverified claim of a
///      6529 profile; the profile document hash is what the artist signed.
///
///      Every change of authority, payout or profile is staged, waits, and can be cancelled. At
///      staging and again at execution, `next.authority` must be unmapped or already mapped to
///      the same artist ID, and not reserved by another artist's pending change; a new authority
///      must sign its acceptance (two-sided). Staging reserves a new authority for the artist
///      (`reservedFor`) until the change executes or ends, so neither `register` (a package
///      acceptance) nor another artist's change can take it meanwhile (`AccountTaken`):
///      - STANDARD changes are staged by the authority or an established consolidated wallet,
///        wait 7 days, and may be cancelled by the previous authority or any consolidated wallet
///        captured at staging, or vetoed by the guardian (which blocks but never redirects);
///      - overrides (CONTESTED, ESTATE, LOST_KEY) are staged by a governed network action with
///        a 180-day public notice; ESTATE and LOST_KEY need a year without signed activity; only
///        captured wallets (never the previous authority) may cancel, and the guardian may veto.
///        A captured wallet's cancel during the notice does not kill an override: it becomes
///        contested and waits for a TDH vote, applied by the governed `resolveContested` citing
///        the vote's DISPUTE_OUTCOME statement (subject `(this registry, artistId)`), recorded
///        after the contest. Upholding executes it (not before its notice ends); voiding deletes
///        it; the guardian may still veto it; and a contest nobody resolves within
///        `CONTEST_TIMEOUT` lapses (`expireContest`). Until then the payout stays frozen if the
///        override would move it: the artist's own captured wallet cannot end a rogue override
///        alone, only a veto, a governed void or the lapse can.
///      One change may be pending per artist. `executeChange` is permissionless once due.
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
///      Dormancy counts the artist's own activity only: registration (the first package
///      acceptance), a staged change, a heartbeat, a cancellation by the old key or a captured
///      wallet, a nonce revocation, and a change's execution. Governed overrides and guardian
///      vetoes never count.
///
///      `isArtist(token, id, account)` is true when `account` is the current authority of the
///      lead artist of 6529 Stream work `id`, or of the master of 6529 Editions edition `id`; it
///      is false for the pre-mint subject `(address(0), uint256(itemHash))`. It
///      meets the resolver trust requirement: no governed action changes an answer faster than
///      the 30-day class (changes take 7 days, overrides 180 days, and the consolidation source
///      swaps on the 30-day class). It also answers the economics lane's payout question
///      (`IArtistPayoutResolver`). The package registry, 6529 Stream, the federation registry and
///      the split factory are each bound once (`Bound`; ERC-165 checked, not EIP-7702 delegated
///      accounts); only the package registry may call `register`, and only the federation
///      registry `listFederatedContract`.
interface IArtistRegistry is IArtistRoleResolver, IArtistPayoutResolver {
    /// @notice An artist identity was created.
    event ArtistRegistered(uint256 indexed artistId, ArtistIdentity identity);
    /// @notice A change was staged.
    event ChangeStaged(uint256 indexed artistId, PendingChange change);
    /// @notice A pending change was cancelled by `by` (a captured wallet or the previous
    ///         authority) or vetoed by the guardian (`vetoed`).
    event ChangeCancelled(uint256 indexed artistId, address indexed by, bool vetoed);
    /// @notice A change took effect.
    event ChangeExecuted(uint256 indexed artistId, ArtistIdentity previous, ArtistIdentity next);
    /// @notice Signed activity was recorded for dormancy purposes.
    event ActivityRecorded(uint256 indexed artistId, uint64 timestamp);
    /// @notice The consolidation source changed.
    event ConsolidationSourceSet(address previous, address next);
    /// @notice A contract was bound under `name` (PACKAGE_REGISTRY, STREAM, FEDERATION_REGISTRY,
    ///         SPLIT_FACTORY or STATEMENT_LOG), once.
    event Bound(bytes32 indexed name, address target);
    /// @notice A captured wallet contested a pending override; it now waits for a vote.
    event ChangeContested(uint256 indexed artistId, address indexed by);
    /// @notice Governance applied a vote on a contested override: upheld or voided. `executed`
    ///         is false for a void, and for an upheld change the execution re-checks cleared.
    event ContestResolved(uint256 indexed artistId, bool upheld, bool executed, bytes32 outcomeRef);
    /// @notice A contested override lapsed unresolved after `CONTEST_TIMEOUT`.
    event ContestExpired(uint256 indexed artistId);
    /// @notice The authority revoked its unused change nonce `nonce`.
    event NonceRevoked(uint256 indexed artistId, uint256 nonce);
    /// @notice A federated contract was listed under an artist (ADR 0001 section 16).
    event FederatedContractListed(uint256 indexed artistId, address indexed token);
    /// @notice A consolidated wallet was recorded (or found consolidated again); it has standing
    ///         from `effectiveAt`.
    event StandingAdded(uint256 indexed artistId, address indexed wallet, uint64 effectiveAt);
    /// @notice A wallet is no longer established; it keeps standing for `STANDING_GRACE`.
    event StandingMissing(uint256 indexed artistId, address indexed wallet);
    /// @notice A wallet lost recovery standing after its grace period.
    event StandingRemoved(uint256 indexed artistId, address indexed wallet);

    /// @notice No artist has this ID.
    error UnknownArtist(uint256 artistId);
    /// @notice The account already belongs to another artist identity.
    error AccountTaken(address account);
    /// @notice The caller or signer may not perform this action.
    error NotAuthorized(uint256 artistId, address account);
    /// @notice A change is already pending.
    error ChangePending(uint256 artistId);
    /// @notice No change is pending.
    error NoPendingChange(uint256 artistId);
    /// @notice The change is not executable before `executableAt`.
    error ChangeNotDue(uint256 artistId, uint64 executableAt);
    /// @notice The artist has signed activity within the last year.
    error NotDormant(uint256 artistId, uint64 lastActivity);
    /// @notice The next identity has a zero authority or payout, or an override has an invalid
    ///         kind or a zero evidence hash.
    error InvalidIdentity();
    /// @notice A signature is expired or does not verify.
    error InvalidSignature();
    /// @notice An override acceptance with this digest was already consumed.
    error AcceptanceUsed(bytes32 digest);
    /// @notice `name` is already bound.
    error AlreadyBound(bytes32 name);
    /// @notice The binding target lacks code or the expected ERC-165 support, or is an EIP-7702
    ///         delegated account.
    error InvalidBinding(address target);
    /// @notice The caller is not the bound contract for this function.
    error UnboundCaller(address caller);
    /// @notice The consolidation source lacks ERC-165 support or the pinned code hash.
    error InvalidSource(address source);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();
    /// @notice The pending override is contested; only a vote, a veto or expiry ends it.
    error OverrideContested(uint256 artistId);
    /// @notice No live (unexpired) contested override is pending.
    error NotContested(uint256 artistId);
    /// @notice `outcomeRef` is not the latest DISPUTE_OUTCOME recorded for the artist.
    error OutcomeNotRecorded(uint256 artistId, bytes32 outcomeRef);
    /// @notice The contest does not lapse before `expiresAt`.
    error ContestNotExpired(uint256 artistId, uint64 expiresAt);
    /// @notice `outcomeRef` was already the latest DISPUTE_OUTCOME when the contest began, so it
    ///         is not a vote on this contest.
    error OutcomePredatesContest(uint256 artistId, bytes32 outcomeRef);
    /// @notice The override's notice ended at `executableAt`; it can no longer be contested.
    error ContestWindowClosed(uint256 artistId, uint64 executableAt);
    /// @notice The artist already lists the maximum number of federated contracts.
    error FederatedListFull(uint256 artistId);

    /// @notice Binds the package registry (the only `register` caller), once. ADMIN role.
    function bindPackageRegistry(address target) external;
    /// @notice Binds 6529 Stream, which `isArtist` reads (`IStream.artistOf`), once. ADMIN role.
    function bindStream(address target) external;
    /// @notice Binds the v1.1 federation registry (the only `listFederatedContract` caller),
    ///         once. ADMIN role.
    function bindFederationRegistry(address target) external;
    /// @notice Binds the economics split factory, once. ADMIN role.
    function bindSplitFactory(address target) external;
    /// @notice Creates an identity for `authority` with ID `uint256(uint160(authority))` and
    ///         payout `authority`, and counts as its first activity. Bound package registry only,
    ///         after it verified the signed acceptance. Reverts with `AccountTaken` if mapped, or
    ///         reserved as a pending change's next authority.
    function register(address authority, bytes32 profileId, bytes32 profileDocHash)
        external
        returns (uint256 artistId);
    /// @notice Stages a STANDARD change signed by `signer` (the current authority or an
    ///         established consolidated wallet) as `Typehashes.IDENTITY_CHANGE`.
    ///         `authorityAcceptance` is the new authority's signature over the same payload when
    ///         the authority changes, empty otherwise. Captures the cancellers.
    function stageChange(
        uint256 artistId,
        ArtistIdentity calldata next,
        address signer,
        uint64 deadline,
        bytes calldata signature,
        bytes calldata authorityAcceptance
    ) external;
    /// @notice Stages a network override (CONTESTED, ESTATE or LOST_KEY) with a 180-day notice.
    ///         PARAMETER_SETTER role. `evidenceHash` commits to the public record. When the
    ///         authority changes, `authorityAcceptance` is the new authority's
    ///         `Typehashes.OVERRIDE_ACCEPTANCE` signature with `deadline`; it binds no change
    ///         nonce and is consumed once by digest, so a replay reverts with `AcceptanceUsed`.
    function stageOverride(
        uint256 artistId,
        ChangeKind kind,
        ArtistIdentity calldata next,
        bytes32 evidenceHash,
        uint64 deadline,
        bytes calldata authorityAcceptance
    ) external;
    /// @notice Cancels a pending STANDARD change (a captured consolidated wallet or the previous
    ///         authority), or contests a pending override (a captured wallet, before its notice
    ///         ends; it then waits for a vote). A cancel of an already contested override does
    ///         nothing.
    function cancelChange(uint256 artistId) external;
    /// @notice Applies a TDH vote on a contested override: upholding executes it (once its notice
    ///         has passed, with the execution re-checks), voiding deletes it. `outcomeRef` must
    ///         be `IStatementLog.latestDisputeOutcome(address(this), artistId)`, the PLATFORM
    ///         statement recording the vote, and differ from the outcome that was latest when the
    ///         contest began. SUCCESSOR_SETTER role (30 days). Schedule an uphold no earlier than
    ///         `executableAt` minus the 30-day delay: it reverts before `executableAt`, and the
    ///         AccessManager drops a matured operation after 7 days. A later DISPUTE_OUTCOME on
    ///         the same subject invalidates a scheduled resolution.
    function resolveContested(uint256 artistId, bool uphold, bytes32 outcomeRef) external;
    /// @notice Deletes a contested override that nobody resolved within `CONTEST_TIMEOUT` of
    ///         its contest. Permissionless; `payoutAddress` already ignores a lapsed contest.
    function expireContest(uint256 artistId) external;
    /// @notice Binds the statement log `resolveContested` reads, once; its artist resolver must
    ///         be this registry. ADMIN role.
    function bindStatementLog(address target) external;
    /// @notice Vetoes the pending change. GUARDIAN role; it can block, never redirect.
    function vetoChange(uint256 artistId) external;
    /// @notice Applies a due, uncontested change. Permissionless. If the next identity is no
    ///         longer valid (its payout is now rejected; its authority is reserved, so it cannot
    ///         be taken), the change is cleared with `ChangeCancelled(artistId, address(this),
    ///         false)` instead of reverting, so a stale change cannot keep the payout frozen.
    function executeChange(uint256 artistId) external;
    /// @notice Records signed activity. Callable by the authority or an established consolidated
    ///         wallet. Never on the auction-start path.
    function heartbeat(uint256 artistId) external;
    /// @notice The authority burns its current change nonce, so a change it pre-signed can never
    ///         be staged (preventive revocation).
    function revokeNonce(uint256 artistId) external;
    /// @notice Lists `token` as one of the artist's federated contracts. Bound federation
    ///         registry only; reverts with `FederatedListFull` past the bound.
    function listFederatedContract(uint256 artistId, address token) external;
    /// @notice Records the authority's live consolidations in the artist's standing snapshot
    ///         and ages out missing ones. Permissionless and not signed activity; a keeper or the
    ///         6529.io UI calls it after consolidation events.
    function refreshStanding(uint256 artistId) external;
    /// @notice Swaps the consolidation source: ERC-165 checked, code hash `nextCodeHash`, not an
    ///         EIP-7702 delegated account. SUCCESSOR_SETTER role, compare-and-set.
    function setConsolidationSource(
        IConsolidationSource expected,
        IConsolidationSource next,
        bytes32 nextCodeHash
    ) external;

    /// @notice An artist's identity and last signed activity. Reverts with `UnknownArtist`.
    function artist(uint256 artistId)
        external
        view
        returns (ArtistIdentity memory identity, uint64 lastActivity);
    /// @notice The artist ID of an account that is or was an authority, or zero.
    function artistIdOf(address account) external view returns (uint256);
    /// @notice The artist whose pending change would make `account` its new authority, or zero.
    ///         A reserved account cannot be registered or become another artist's authority.
    function reservedFor(address account) external view returns (uint256);
    /// @notice The current authority. Reverts with `UnknownArtist`.
    function authorityOf(uint256 artistId) external view returns (address);
    /// @notice The pending change (kind NONE if none).
    function pendingChange(uint256 artistId) external view returns (PendingChange memory);
    /// @notice The nonce the next signed change must carry.
    function changeNonce(uint256 artistId) external view returns (uint256);
    /// @notice The consolidation source.
    function consolidationSource() external view returns (IConsolidationSource);
    /// @notice An artist's listed federated contracts.
    function federatedContracts(uint256 artistId) external view returns (address[] memory);
    /// @notice The bound package registry.
    function packageRegistry() external view returns (address);
    /// @notice The bound 6529 Stream.
    function stream() external view returns (address);
    /// @notice The bound federation registry, or zero before v1.1.
    function federationRegistry() external view returns (address);
    /// @notice The bound split factory.
    function splitFactory() external view returns (address);
    /// @notice The artist's standing snapshot, including missing wallets not yet removed.
    function standingOf(uint256 artistId) external view returns (Standing[] memory);
    /// @notice How long a missing wallet keeps standing (30 days).
    function STANDING_GRACE() external view returns (uint64);
    /// @notice How long a contested override waits for a vote before it lapses (365 days).
    function CONTEST_TIMEOUT() external view returns (uint64);
    /// @notice The bound statement log, or zero before it is bound.
    function statementLog() external view returns (address);
}
