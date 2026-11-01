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
///      fail closed: when it cannot read its data, it reverts with {DelegationReadFailed}
///      instead of answering "not consolidated", which would strip recorded standing.
interface IConsolidationSource is IERC165 {
    /// @notice A read of the underlying data failed for a reason other than its end (out of
    ///         gas, a revert with data, or oversized return data). The artist registry skips a
    ///         registration's or an execution's standing refresh on it, and reverts elsewhere.
    error DelegationReadFailed(address delegation);

    /// @notice `account`'s established consolidated wallets, at most `Limits.MAX_CANCELLERS`.
    /// @param account The account whose consolidations are read (an artist's authority).
    /// @return The established wallets.
    function establishedWallets(address account) external view returns (address[] memory);
    /// @notice Whether `wallet` is an established consolidated wallet of `account` now.
    /// @param account The account whose consolidations are read (an artist's authority).
    /// @param wallet The wallet to check.
    /// @return True if the two are consolidated both ways and the consolidation is established.
    function isEstablished(address account, address wallet) external view returns (bool);
    /// @notice `account`'s live two-way consolidations, established or still young, at most
    ///         `2 * Limits.MAX_CANCELLERS`, each with the time it becomes (or became) established.
    /// @param account The account whose consolidations are read (an artist's authority).
    /// @return wallets The consolidated wallets.
    /// @return effectiveAt For each entry of `wallets`, the Unix time in seconds at which it
    ///        becomes (or became) established; the same length as `wallets`.
    function consolidations(address account)
        external
        view
        returns (address[] memory wallets, uint64[] memory effectiveAt);
    /// @notice When `wallet`'s live consolidation with `account` becomes (or became)
    ///         established, or zero if they are not consolidated both ways.
    /// @param account The account whose consolidations are read (an artist's authority).
    /// @param wallet The wallet to check.
    /// @return A Unix time in seconds, or zero.
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
///      only the active authority (`activeAuthorityOf`) can sign. An account the artist rotated
///      away from never becomes its authority again (A, then B, then A is refused with
///      `AccountTaken`), so the move, consent and acceptance signatures it left unused, which
///      every consumer checks against the active authority, never verify again. `profileId` is
///      the artist's unverified claim of a 6529 profile; the profile document hash is what the
///      artist signed.
///
///      Every change of authority, payout or profile is staged, waits, and can be cancelled. At
///      staging and again at execution, `next.authority` must be the current authority or an
///      account that has never been an authority, and not reserved by another artist's pending
///      change; a new authority must sign its acceptance (two-sided). Staging reserves a new
///      authority for the artist (`reservedFor`) until the change executes or ends, so neither
///      `register` (a package acceptance) nor another artist's change can take it meanwhile
///      (`AccountTaken`):
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
///      `isArtist(token, id, account)` is true when `account` is the active authority
///      (`activeAuthorityOf`) of the lead artist of 6529 Stream work `id`, or of the master of
///      6529 Stream Editions edition `id`; it is false for the pre-mint subject
///      `(address(0), uint256(itemHash))`. It meets the resolver trust requirement for granting:
///      no governed action makes it true for a new account faster than the 30-day class
///      (changes take 7 days, overrides 180 days, and the consolidation source swaps on the
///      30-day class). A staged override that would move the authority (48 hours) withholds the
///      answer until it ends, by the owner decision on IDENTITY-1; it never redirects it, and the
///      guardian's veto restores it. It also answers split wallets' payout question
///      (`IArtistPayoutResolver`). The package registry, 6529 Stream, the federation registry,
///      the split factory and the statement log are each bound once (`Bound`): never EIP-7702
///      delegated accounts, and ERC-165 checked except the split factory and the statement log,
///      which implement no ERC-165. Only the package registry may call `register`, and only the
///      federation registry `listFederatedContract`.
interface IArtistRegistry is IArtistRoleResolver, IArtistPayoutResolver {
    /// @notice An artist identity was created.
    /// @param artistId The new artist ID, `uint256(uint160(identity.authority))`.
    /// @param identity The new identity: the accepting account as authority and payout, with the
    ///        profile fields of its signed acceptance.
    event ArtistRegistered(uint256 indexed artistId, ArtistIdentity identity);
    /// @notice A change was staged.
    /// @param artistId The artist whose identity would change.
    /// @param change The pending change as stored, with its captured cancellers and its
    ///        `executableAt`.
    event ChangeStaged(uint256 indexed artistId, PendingChange change);
    /// @notice A pending change ended without taking effect: cancelled by the previous authority
    ///         or a captured wallet, vetoed by the guardian, replaced by an override, voided by a
    ///         vote, or cleared by the registry (a lapsed contest, or failed execution re-checks).
    /// @param artistId The artist whose pending change ended.
    /// @param by The canceller or the governed caller, or this registry when it cleared the
    ///        change itself.
    /// @param vetoed True for a guardian veto, a replacement by an override, or a voided contest;
    ///        false for a cancel or a clear by the registry.
    event ChangeCancelled(uint256 indexed artistId, address indexed by, bool vetoed);
    /// @notice A change took effect.
    /// @param artistId The artist whose identity changed.
    /// @param previous The identity before the change.
    /// @param next The identity after the change.
    event ChangeExecuted(uint256 indexed artistId, ArtistIdentity previous, ArtistIdentity next);
    /// @notice Signed activity was recorded for dormancy purposes.
    /// @param artistId The artist whose activity was recorded.
    /// @param timestamp The block timestamp now stored as the artist's last activity.
    event ActivityRecorded(uint256 indexed artistId, uint64 timestamp);
    /// @notice The consolidation source changed.
    /// @param previous The source before the change (zero at deployment).
    /// @param next The source after the change.
    event ConsolidationSourceSet(address previous, address next);
    /// @notice Governance replaced the package registry, the only `register` caller
    ///         (`setPackageRegistry`), with Stream's (owner decision 16).
    /// @param previous The package registry before.
    /// @param next The package registry after.
    event PackageRegistrySet(address previous, address next);
    /// @notice A contract was bound under `name` (PACKAGE_REGISTRY, STREAM, FEDERATION_REGISTRY,
    ///         SPLIT_FACTORY or STATEMENT_LOG), once.
    /// @param name The binding's name as a `bytes32` string.
    /// @param target The contract bound.
    event Bound(bytes32 indexed name, address target);
    /// @notice A captured wallet contested a pending override; it now waits for a vote.
    /// @param artistId The artist whose pending override is contested.
    /// @param by The captured wallet that contested it.
    event ChangeContested(uint256 indexed artistId, address indexed by);
    /// @notice Governance applied a vote on a contested override: upheld or voided. `executed`
    ///         is false for a void, and for an upheld change the execution re-checks cleared.
    /// @param artistId The artist whose contested override was resolved.
    /// @param upheld True if the vote upheld the override, false if it voided it.
    /// @param executed True if the upheld override took effect.
    /// @param outcomeRef The entry hash of the DISPUTE_OUTCOME statement recording the vote.
    event ContestResolved(uint256 indexed artistId, bool upheld, bool executed, bytes32 outcomeRef);
    /// @notice A contested override lapsed unresolved after `CONTEST_TIMEOUT`.
    /// @param artistId The artist whose contested override was deleted.
    event ContestExpired(uint256 indexed artistId);
    /// @notice The authority revoked its unused change nonce `nonce`.
    /// @param artistId The artist whose change nonce was burned.
    /// @param nonce The revoked nonce; `changeNonce` is now one higher.
    event NonceRevoked(uint256 indexed artistId, uint256 nonce);
    /// @notice A federated contract was listed under an artist (ADR 0001 section 16).
    /// @param artistId The artist the contract was listed under.
    /// @param token The federated token contract.
    event FederatedContractListed(uint256 indexed artistId, address indexed token);
    /// @notice A consolidated wallet was recorded (or found consolidated again); it has standing
    ///         from `effectiveAt`.
    /// @param artistId The artist whose standing snapshot changed.
    /// @param wallet The consolidated wallet.
    /// @param effectiveAt The Unix time in seconds from which the wallet has standing.
    event StandingAdded(uint256 indexed artistId, address indexed wallet, uint64 effectiveAt);
    /// @notice A wallet is no longer established; it keeps standing for `STANDING_GRACE`.
    /// @param artistId The artist whose standing snapshot changed.
    /// @param wallet The recorded wallet a refresh found no longer consolidated.
    event StandingMissing(uint256 indexed artistId, address indexed wallet);
    /// @notice A wallet left the standing snapshot: it was missing for its grace period, or it
    ///         was still pending (it never had standing) and is no longer consolidated.
    /// @param artistId The artist whose standing snapshot changed.
    /// @param wallet The wallet removed.
    event StandingRemoved(uint256 indexed artistId, address indexed wallet);
    /// @notice A registration's or an execution's standing refresh was skipped because the
    ///         consolidation source could not read (`IConsolidationSource.DelegationReadFailed`)
    ///         or no longer matches its pinned code hash.
    ///         Skipping removes nobody's standing; `refreshStanding` catches up later.
    /// @param artistId The artist whose standing was not refreshed.
    event StandingRefreshSkipped(uint256 indexed artistId);

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
    /// @notice An override acceptance with this digest was already consumed.
    error AcceptanceUsed(bytes32 digest);
    /// @notice `name` is already bound.
    error AlreadyBound(bytes32 name);
    /// @notice The statement log to bind does not name this registry as its `artistResolver()`.
    error InvalidBinding(address target);
    /// @notice The caller is not the bound contract for this function.
    error UnboundCaller(address caller);
    /// @notice The consolidation source answered with more than `2 * Limits.MAX_CANCELLERS`
    ///         consolidations, or with lists of different lengths.
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

    /// @notice Binds the package registry (the only `register` caller), once, at genesis.
    ///         ADMIN role. A later replacement goes through `setPackageRegistry`.
    /// @param target The package registry: a contract supporting `IPackageRegistry` (ERC-165),
    ///        not an EIP-7702 delegated account.
    function bindPackageRegistry(address target) external;
    /// @notice Replaces the package registry, the only `register` caller, so that a successor
    ///         registry installed in 6529 Stream (`IStream.setDependency`, owner decision 16) can
    ///         register new artists. SUCCESSOR_SETTER role (the 30-day class), compare-and-set,
    ///         scheduled in the same batch as Stream's replacement. Existing artists are
    ///         unaffected.
    /// @param expected The current package registry (`ExpectedValueMismatch` otherwise).
    /// @param next The successor: a contract supporting `IPackageRegistry` (ERC-165), not an
    ///        EIP-7702 delegated account.
    function setPackageRegistry(address expected, address next) external;
    /// @notice Binds 6529 Stream, which `isArtist` reads (`IStream.artistOf`), once. ADMIN role.
    /// @param target 6529 Stream: a contract supporting `IStream` (ERC-165), not an EIP-7702
    ///        delegated account.
    function bindStream(address target) external;
    /// @notice Binds the v1.1 federation registry (the only `listFederatedContract` caller),
    ///         once. ADMIN role.
    /// @param target The federation registry: a contract supporting `IFederationRegistry`
    ///        (ERC-165), not an EIP-7702 delegated account.
    function bindFederationRegistry(address target) external;
    /// @notice Binds the economics split factory, once: code, not an EIP-7702 delegated account
    ///         (the factory implements no ERC-165). ADMIN role.
    /// @param target The split factory, whose wallets this registry refuses as payouts.
    function bindSplitFactory(address target) external;
    /// @notice Creates an identity for `authority` with ID `uint256(uint160(authority))` and
    ///         payout `authority`, and counts as its first activity. Bound package registry only,
    ///         after it verified the signed acceptance. Reverts with `AccountTaken` if mapped, or
    ///         reserved as a pending change's next authority. If the consolidation source cannot
    ///         read, it registers anyway and skips the standing refresh (`StandingRefreshSkipped`).
    /// @param authority The accepting account, which becomes the authority and the payout; it
    ///        must be a payout this registry allows (`InvalidIdentity` otherwise).
    /// @param profileId The artist's claimed 6529 profile ID, from the signed acceptance.
    /// @param profileDocHash The hash of the profile document, from the signed acceptance.
    /// @return artistId `uint256(uint160(authority))`.
    function register(address authority, bytes32 profileId, bytes32 profileDocHash)
        external
        returns (uint256 artistId);
    /// @notice Stages a STANDARD change signed by `signer` (the current authority or an
    ///         established consolidated wallet) as `Typehashes.IDENTITY_CHANGE`.
    ///         `authorityAcceptance` is the new authority's signature over the same payload when
    ///         the authority changes, empty otherwise. Captures the cancellers.
    /// @param artistId The artist to change.
    /// @param next The identity after the change: authority, payout and profile fields.
    /// @param signer The account that signed the change.
    /// @param deadline The Unix time in seconds after which the signatures are expired.
    /// @param signature `signer`'s EIP-712 signature of the change at the current `changeNonce`.
    /// @param authorityAcceptance `next.authority`'s signature of the same digest; ignored when
    ///        the authority does not change.
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
    /// @param artistId The artist to override.
    /// @param kind CONTESTED, ESTATE or LOST_KEY; ESTATE and LOST_KEY revert with `NotDormant`
    ///        unless the artist has had no signed activity for a year.
    /// @param next The identity after the override: authority, payout and profile fields.
    /// @param evidenceHash The nonzero hash of the override's public record.
    /// @param deadline The Unix time in seconds after which `authorityAcceptance` is expired;
    ///        unused when the authority does not change.
    /// @param authorityAcceptance `next.authority`'s acceptance signature; ignored when the
    ///        authority does not change.
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
    /// @param artistId The artist whose pending change is cancelled or contested.
    function cancelChange(uint256 artistId) external;
    /// @notice Applies a TDH vote on a contested override: upholding executes it (once its notice
    ///         has passed, with the execution re-checks), voiding deletes it. `outcomeRef` must
    ///         be `IStatementLog.latestDisputeOutcome(address(this), artistId)`, the PLATFORM
    ///         statement recording the vote, and differ from the outcome that was latest when the
    ///         contest began. SUCCESSOR_SETTER role (30 days). Schedule an uphold no earlier than
    ///         `executableAt` minus the 30-day delay: it reverts before `executableAt`, and the
    ///         AccessManager drops a matured operation after 7 days. A later DISPUTE_OUTCOME on
    ///         the same subject invalidates a scheduled resolution.
    /// @param artistId The artist whose contested override is resolved.
    /// @param uphold True to uphold (execute) the override, false to void (delete) it.
    /// @param outcomeRef The entry hash of the DISPUTE_OUTCOME statement recording the vote.
    function resolveContested(uint256 artistId, bool uphold, bytes32 outcomeRef) external;
    /// @notice Deletes a contested override that nobody resolved within `CONTEST_TIMEOUT` of
    ///         its contest. Permissionless; `payoutAddress` already ignores a lapsed contest.
    /// @param artistId The artist whose contested override lapsed.
    function expireContest(uint256 artistId) external;
    /// @notice Binds the statement log `resolveContested` reads, once; its artist resolver must
    ///         be this registry. ADMIN role.
    /// @param target The statement log: a contract, not an EIP-7702 delegated account, whose
    ///        `artistResolver()` returns this registry.
    function bindStatementLog(address target) external;
    /// @notice Vetoes the pending change. GUARDIAN role; it can block, never redirect.
    /// @param artistId The artist whose pending change is vetoed.
    function vetoChange(uint256 artistId) external;
    /// @notice Applies a due, uncontested change. Permissionless. If the next identity is no
    ///         longer valid (its payout is now rejected; its authority is reserved, so it cannot
    ///         be taken), the change is cleared with `ChangeCancelled(artistId, address(this),
    ///         false)` instead of reverting, so a stale change cannot keep the payout frozen. If
    ///         the consolidation source cannot read, the change applies and its standing refresh
    ///         is skipped (`StandingRefreshSkipped`).
    /// @param artistId The artist whose due change is applied.
    function executeChange(uint256 artistId) external;
    /// @notice Records signed activity. Callable by the authority or an established consolidated
    ///         wallet. Never on the auction-start path.
    /// @param artistId The artist whose activity is recorded; its standing is refreshed too.
    function heartbeat(uint256 artistId) external;
    /// @notice The authority burns its current change nonce, so a change it pre-signed can never
    ///         be staged (preventive revocation).
    /// @param artistId The artist whose change nonce is burned.
    function revokeNonce(uint256 artistId) external;
    /// @notice Lists `token` as one of the artist's federated contracts. Bound federation
    ///         registry only; reverts with `FederatedListFull` past the bound.
    /// @param artistId The registered artist to list the contract under.
    /// @param token The federated token contract.
    function listFederatedContract(uint256 artistId, address token) external;
    /// @notice Records the authority's live consolidations in the artist's standing snapshot
    ///         and ages out missing ones. Permissionless and not signed activity; a keeper or the
    ///         6529.io UI calls it after consolidation events.
    /// @param artistId The registered artist whose snapshot is refreshed.
    function refreshStanding(uint256 artistId) external;
    /// @notice Swaps the consolidation source: ERC-165 checked, code hash `nextCodeHash`, not an
    ///         EIP-7702 delegated account. SUCCESSOR_SETTER role, compare-and-set. The pinned
    ///         code hash (`consolidationSourceCodeHash`) is re-checked at every use.
    /// @param expected The source the proposer saw; a stale value reverts with
    ///        `ExpectedValueMismatch`.
    /// @param next The new consolidation source.
    /// @param nextCodeHash The reviewed code hash `next` must have.
    function setConsolidationSource(
        IConsolidationSource expected,
        IConsolidationSource next,
        bytes32 nextCodeHash
    ) external;

    /// @notice An artist's identity and last signed activity. Reverts with `UnknownArtist`.
    /// @param artistId The artist ID.
    /// @return identity The artist's current identity.
    /// @return lastActivity The Unix time in seconds of the artist's last signed activity.
    function artist(uint256 artistId)
        external
        view
        returns (ArtistIdentity memory identity, uint64 lastActivity);
    /// @notice The artist ID of an account that is or was an authority, or zero.
    /// @param account The account to look up.
    /// @return The artist ID, or zero.
    function artistIdOf(address account) external view returns (uint256);
    /// @notice The artist whose pending change would make `account` its new authority, or zero.
    ///         A reserved account cannot be registered or become another artist's authority.
    /// @param account The account to look up.
    /// @return The reserving artist's ID, or zero.
    function reservedFor(address account) external view returns (uint256);
    /// @notice The current authority, which identifies the artist. Reverts with `UnknownArtist`.
    /// @param artistId The artist ID.
    /// @return The current authority.
    function authorityOf(uint256 artistId) external view returns (address);
    /// @notice The authority that may act as the artist now: the current authority, or zero
    ///         while a pending override that would move the authority has not executed, been
    ///         vetoed or voided, or lapsed (owner decision on IDENTITY-1). Sale creator powers,
    ///         move and acceptance signatures, record amendments and ARTIST statements read it.
    ///         A STANDARD change or a payout-only override does not restrain. Reverts with
    ///         `UnknownArtist`.
    /// @param artistId The artist ID.
    /// @return The current authority, or zero while it is restrained.
    function activeAuthorityOf(uint256 artistId) external view returns (address);
    /// @notice The pending change (kind NONE if none).
    /// @param artistId The artist ID.
    /// @return The pending change; all zero or empty (kind NONE) when none is pending.
    function pendingChange(uint256 artistId) external view returns (PendingChange memory);
    /// @notice The nonce the next signed change must carry.
    /// @param artistId The artist ID.
    /// @return The nonce, starting at zero; every staging and every `revokeNonce` adds one.
    function changeNonce(uint256 artistId) external view returns (uint256);
    /// @notice The consolidation source.
    /// @return The source the registry reads consolidations from.
    function consolidationSource() external view returns (IConsolidationSource);
    /// @notice The code hash pinned when the consolidation source was installed, re-checked at
    ///         every use. On a mismatch, staging, heartbeats and `refreshStanding` revert with
    ///         `Dependency.DependencyCodeChanged`; registration and execution skip their standing
    ///         refresh (`StandingRefreshSkipped`), trusting nothing from the changed source.
    /// @return The pinned code hash.
    function consolidationSourceCodeHash() external view returns (bytes32);
    /// @notice An artist's listed federated contracts.
    /// @param artistId The artist ID.
    /// @return The listed contracts, in listing order.
    function federatedContracts(uint256 artistId) external view returns (address[] memory);
    /// @notice The package registry, the only `register` caller: bound at genesis, replaceable
    ///         by governance (`setPackageRegistry`).
    /// @return The package registry, or zero before it is bound.
    function packageRegistry() external view returns (address);
    /// @notice The bound 6529 Stream.
    /// @return The 6529 Stream contract, or zero before it is bound.
    function stream() external view returns (address);
    /// @notice The bound federation registry, or zero before v1.1.
    /// @return The federation registry, or zero.
    function federationRegistry() external view returns (address);
    /// @notice The bound split factory.
    /// @return The split factory, or zero before it is bound.
    function splitFactory() external view returns (address);
    /// @notice The artist's standing snapshot, including missing wallets not yet removed.
    /// @param artistId The artist ID.
    /// @return The snapshot's entries, at most `Limits.MAX_CANCELLERS`, in no fixed order.
    function standingOf(uint256 artistId) external view returns (Standing[] memory);
    /// @notice How long a missing wallet keeps standing (30 days).
    /// @return The grace period in seconds.
    function STANDING_GRACE() external view returns (uint64);
    /// @notice How long a contested override waits for a vote before it lapses (365 days).
    /// @return The timeout in seconds.
    function CONTEST_TIMEOUT() external view returns (uint64);
    /// @notice The bound statement log, or zero before it is bound.
    /// @return The statement log, or zero.
    function statementLog() external view returns (address);
}
