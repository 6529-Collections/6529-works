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
///
///      Gas convention: a source that was given too little gas by its caller must say so,
///      by running out of gas itself or by reverting with `BoundedCall.BoundedCallInsufficientGas`
///      or `BoundedCall.BoundedCallShortfall`. The artist registry rethrows those two errors on
///      every refresh, best-effort or not, so a submitter's gas limit can never turn a refresh
///      into a skip. Any other revert is the source failing, which a best-effort refresh skips.
///
///      Trust: the source decides which wallets gain standing (cancellers of later changes,
///      contestants of overrides) and which wallets may sign a STANDARD change for a dormant
///      artist. It decides nothing for a live artist: only the authority signs a live artist's
///      changes and heartbeats.
interface IConsolidationSource is IERC165 {
    /// @notice A read of the underlying data failed for a reason other than its end (out of
    ///         gas within its own stipend, a revert with data, or oversized return data). A
    ///         best-effort refresh of the artist registry skips on it; `refreshStanding` and a
    ///         consolidated wallet's signer check revert.
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
///      - STANDARD changes are signed by the authority and wait the change delay (7 days at
///        genesis); or, only for a dormant artist (no signed activity for the dormancy period),
///        by an established consolidated wallet, and then wait the override delay (180 days at
///        genesis) and record no activity. Either may be cancelled by the previous authority or
///        any consolidated wallet captured at staging, or vetoed by the guardian (which blocks
///        but never redirects). The consolidation source is replaceable, so it never decides
///        anything for a live artist;
///      - overrides (CONTESTED, ESTATE, LOST_KEY) are staged by a governed network action with
///        a public notice (180 days at genesis); ESTATE and LOST_KEY, and any override that moves
///        the payout but keeps the authority, need the dormancy period (a year at genesis)
///        without signed activity; only captured wallets (never the previous authority) may
///        cancel, and the guardian may veto.
///        A captured wallet's cancel during the notice does not kill an override: it becomes
///        contested and waits for a TDH vote, applied by the governed `resolveContested` citing
///        the vote's DISPUTE_OUTCOME statement (subject `(this registry, artistId)`), recorded
///        after the contest. Upholding executes it (not before its notice ends); voiding deletes
///        it; the guardian may still veto it; and a contest nobody resolves within
///        its locked contest timeout lapses (`expireContest`). Until then the payout stays frozen if the
///        override would move it: the artist's own captured wallet cannot end a rogue override
///        alone, only a veto, a governed void or the lapse can.
///      One change may be pending per artist. `executeChange` is permissionless once due.
///      The waits are governed timers (`setTimer`), each between a compiled floor (the genesis
///      value) and a compiled ceiling (`timerBounds`); a staged change locks its delay and its
///      contest timeout, so a later setting never traps or releases it.
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
///      Dormancy counts the artist's own activity only: registration (the first package
///      acceptance), a change the authority signed, the authority's heartbeat, a cancellation by
///      the old key or a captured wallet, a nonce revocation, and a change's execution. Governed
///      overrides, guardian vetoes and changes signed by a consolidated wallet never count.
///
///      `isArtist(token, id, account)` is true when `account` is the active authority
///      (`activeAuthorityOf`) of the lead artist of 6529 Stream work `id`, or of the master of
///      6529 Stream Editions edition `id`; it is false for the pre-mint subject
///      `(address(0), uint256(itemHash))`. It meets the resolver trust requirement for granting:
///      no governed action makes it true for a new account faster than the 30-day class
///      (changes take at least 7 days, overrides at least 180 days, and the consolidation source
///      swaps on the 30-day class). A staged override that would move the authority (48 hours) withholds the
///      answer until it ends, by the owner decision on IDENTITY-1; it never redirects it, and the
///      guardian's veto restores it. It also answers split wallets' payout question
///      (`IArtistPayoutResolver`). The package registry, 6529 Stream, the federation registry,
///      the split factory and the statement log are each bound once (`Bound`): never EIP-7702
///      delegated accounts, and ERC-165 checked except the split factory and the statement log,
///      which implement no ERC-165. The package registry and the federation registry are
///      replaceable afterwards (SUCCESSOR_SETTER, 30 days). Only the package registry may call
///      `register`, and only the federation registry `registerFederated` (which verifies the
///      account's own signature) and the federation directory writes.
///
///      Federation directory (ADR 0001 section 16). The registry is the permanent, logs-only
///      record of every federated contract: one entry per token (`federatedListing`), written by
///      the current federation registry (`listFederatedContract`, `setFederatedStatus`: ACTIVE
///      and DELISTED) except exit, which only the token itself writes (`recordFederationExit`:
///      LEFT, terminal). An entry's artist, code hash (computed here), form, partner and fee
///      terms are fixed when it is listed. Entries never name this registry, 6529 Stream, its
///      Editions, or a bound contract. No identity, payout, standing or change
///      reads a directory entry, so the federation registry has no authority over any artist,
///      work, token or fund: it can create identities only for accounts that signed for them,
///      and write directory entries about other contracts.
interface IArtistRegistry is IArtistRoleResolver, IArtistPayoutResolver {
    /// @notice A federated contract's directory status. LEFT is terminal.
    enum FederationStatus {
        NONE,
        ACTIVE,
        DELISTED,
        LEFT
    }

    /// @notice The governed waits, in seconds. Each lies between a compiled floor, its genesis
    ///         value (the guarantee: never shorter), and a compiled ceiling (`timerBounds`).
    ///         CHANGE_DELAY: before a STANDARD change executes (7 to 30 days). OVERRIDE_DELAY:
    ///         an override's public notice (180 to 365 days). DORMANCY: the silence an override
    ///         needs when it requires dormancy (365 to 1,825 days). CONTEST_TIMEOUT: before an
    ///         unresolved contest lapses (365 to 730 days, and at least OVERRIDE_DELAY plus 185
    ///         days). STANDING_GRACE: how long a missing wallet keeps standing (30 to 90 days).
    ///         A staged change locks its delay and contest timeout; DORMANCY is read when an
    ///         override is staged and STANDING_GRACE when a refresh ages out a missing wallet.
    enum Timer {
        CHANGE_DELAY,
        OVERRIDE_DELAY,
        DORMANCY,
        CONTEST_TIMEOUT,
        STANDING_GRACE
    }

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
    /// @param codeHash The reviewed code hash pinned for `next` (`consolidationSourceCodeHash`).
    event ConsolidationSourceSet(address previous, address next, bytes32 codeHash);
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
    /// @notice A federated contract was listed under an artist, ACTIVE (ADR 0001 section 16).
    ///         Its fields never change; `FederatedContractStatus` carries later statuses.
    /// @param artistId The artist the contract was listed under.
    /// @param token The federated token contract.
    /// @param codeHash `token`'s runtime code hash, read by this registry at listing.
    /// @param form The token's form as reported by the federation registry, recorded and not
    ///        interpreted here (0 for ERC-721, 1 for ERC-1155 under `IFederationRegistry.Form`).
    /// @param partner The other half of a linked pair, or zero.
    /// @param feeShare The network's share of primary sales and royalties, out of 100,000, as
    ///        locked in the token.
    /// @param feeRecipient The network fee recipient locked in the token.
    event FederatedContractListed(
        uint256 indexed artistId,
        address indexed token,
        bytes32 codeHash,
        uint8 form,
        address partner,
        uint32 feeShare,
        address feeRecipient
    );
    /// @notice A federated contract's status changed: ACTIVE or DELISTED by the federation
    ///         registry, or LEFT by the token itself.
    /// @param token The federated token contract.
    /// @param artistId The artist it is listed under.
    /// @param status The new status.
    /// @param ref The federation registry's reference for the decision (a vote), zero for LEFT.
    event FederatedContractStatus(
        address indexed token, uint256 indexed artistId, FederationStatus status, bytes32 ref
    );
    /// @notice Governance replaced the federation registry (`setFederationRegistry`).
    /// @param previous The federation registry before (zero if none was bound).
    /// @param next The federation registry after.
    event FederationRegistrySet(address previous, address next);
    /// @notice A governed wait was set: each at deployment (its floor), then by `setTimer`.
    /// @param timer The wait.
    /// @param value Its value in seconds, for changes staged and refreshes made from now on.
    event TimerSet(Timer indexed timer, uint48 value);
    /// @notice A consolidated wallet was recorded, found consolidated again, or its
    ///         `effectiveAt` changed (a pending entry following its live clock, an established
    ///         one moving earlier); it has standing from `effectiveAt`. The latest event for a
    ///         wallet gives its entry, until `StandingMissing` or `StandingRemoved`.
    /// @param artistId The artist whose standing snapshot changed.
    /// @param wallet The consolidated wallet.
    /// @param effectiveAt The Unix time in seconds from which the wallet has standing.
    event StandingAdded(uint256 indexed artistId, address indexed wallet, uint64 effectiveAt);
    /// @notice A wallet is no longer established; it keeps standing for the standing grace.
    /// @param artistId The artist whose standing snapshot changed.
    /// @param wallet The recorded wallet a refresh found no longer consolidated.
    event StandingMissing(uint256 indexed artistId, address indexed wallet);
    /// @notice A wallet left the standing snapshot: it was missing for its grace period, or it
    ///         was still pending (it never had standing) and is no longer consolidated.
    /// @param artistId The artist whose standing snapshot changed.
    /// @param wallet The wallet removed.
    event StandingRemoved(uint256 indexed artistId, address indexed wallet);
    /// @notice A best-effort standing refresh (every refresh except `refreshStanding`) was
    ///         skipped because the consolidation source failed (reverted, used up the gas it was
    ///         given, or answered out of bounds) or no longer matches its pinned code hash.
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
    /// @notice The artist has signed activity within the dormancy period.
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
    /// @notice The contract cannot be listed: it is already listed (in any status), has no
    ///         code or is an EIP-7702 delegated account, or it, its partner or its fee recipient
    ///         is this registry, 6529 Stream, its Editions, or a bound contract.
    error FederatedContractRefused(address token);
    /// @notice The status write is refused: the token is unlisted or LEFT, or the requested
    ///         status is not ACTIVE or DELISTED.
    error FederatedStatusRefused(address token, FederationStatus current);
    /// @notice A wait is outside its floor and ceiling, or the contest timeout would not exceed
    ///         the override delay by the floors' 185 days.
    error InvalidTimers();

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
    /// @notice Binds the federation registry (the only caller of `registerFederated` and of the
    ///         directory writes), once. ADMIN role. A later replacement goes through
    ///         `setFederationRegistry`.
    /// @param target The federation registry: a contract supporting `IFederationRegistry`
    ///        (ERC-165), not an EIP-7702 delegated account.
    function bindFederationRegistry(address target) external;
    /// @notice Replaces the federation registry. SUCCESSOR_SETTER role (the 30-day class),
    ///         compare-and-set. Existing directory entries and identities are unaffected.
    /// @param expected The current federation registry, zero if none (`ExpectedValueMismatch`
    ///        otherwise).
    /// @param next The successor: a contract supporting `IFederationRegistry` (ERC-165), not an
    ///        EIP-7702 delegated account.
    function setFederationRegistry(address expected, address next) external;
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
    /// @notice Creates an identity exactly as `register` does, for an uncurated (federated)
    ///         artist. Bound federation registry only. The account consents itself: this registry
    ///         verifies `signature` by `account` over `ArtistRegistration(account, profileId,
    ///         profileDocHash, deadline)` in its own EIP-712 domain (`registrationDigest`), so no
    ///         caller can create an identity for an account that did not sign for it. A signature
    ///         is usable once: the account is then taken.
    /// @param account The consenting account, which becomes the authority and the payout.
    /// @param profileId The artist's claimed 6529 profile ID, as signed.
    /// @param profileDocHash The hash of the profile document, as signed.
    /// @param deadline The Unix time in seconds after which the signature is expired.
    /// @param signature `account`'s signature (ECDSA, EIP-7702 or ERC-1271).
    /// @return artistId `uint256(uint160(account))`.
    function registerFederated(
        address account,
        bytes32 profileId,
        bytes32 profileDocHash,
        uint64 deadline,
        bytes calldata signature
    ) external returns (uint256 artistId);
    /// @notice Stages a STANDARD change signed by `signer` as `Typehashes.IDENTITY_CHANGE`.
    ///         `signer` is the current authority (the change records activity and waits the
    ///         change delay), or, only while the artist is dormant (`NotDormant` otherwise, checked
    ///         before the consolidation source is read), an established consolidated wallet that
    ///         was never an authority of this artist (the change records no activity and waits
    ///         the override delay; `NotAuthorized` if the source does not name it).
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
    /// @notice Stages a network override (CONTESTED, ESTATE or LOST_KEY) with the override
    ///         notice. PARAMETER_SETTER role. `evidenceHash` commits to the public record. An
    ///         override that moves the payout but keeps the authority needs the dormancy period
    ///         whatever its kind, so no override freezes a live artist's payout without also
    ///         moving (and restraining) the authority. When the
    ///         authority changes, `authorityAcceptance` is the new authority's
    ///         `Typehashes.OVERRIDE_ACCEPTANCE` signature with `deadline`; it binds no change
    ///         nonce and is consumed once by digest, so a replay reverts with `AcceptanceUsed`.
    /// @param artistId The artist to override.
    /// @param kind CONTESTED, ESTATE or LOST_KEY; ESTATE and LOST_KEY, and any kind that moves
    ///        the payout but keeps the authority, revert with `NotDormant` unless the artist has
    ///        had no signed activity for the dormancy period.
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
    /// @notice Deletes a contested override that nobody resolved within its locked contest
    ///         timeout of its contest. Permissionless; `payoutAddress` already ignores a lapsed contest.
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
    /// @notice Records signed activity. The current authority only (`NotAuthorized`). Never on
    ///         the auction-start path.
    /// @param artistId The artist whose activity is recorded; its standing is refreshed too.
    function heartbeat(uint256 artistId) external;
    /// @notice The authority burns its current change nonce, so a change it pre-signed can never
    ///         be staged (preventive revocation).
    /// @param artistId The artist whose change nonce is burned.
    function revokeNonce(uint256 artistId) external;
    /// @notice Lists `token` under the artist, ACTIVE, with fields fixed from now on. Bound
    ///         federation registry only. Refused (`FederatedContractRefused`) for a listed token,
    ///         a token without code or EIP-7702 delegated, and when the token, partner or fee
    ///         recipient is a contract this registry knows as canonical. The code hash is read
    ///         here, never taken from the caller.
    /// @param artistId The registered artist to list the contract under.
    /// @param token The federated token contract.
    /// @param form The token's form, recorded and not interpreted (see `FederatedContractListed`).
    /// @param partner The other half of a linked pair, or zero.
    /// @param feeShare The network's share, out of 100,000, as locked in the token.
    /// @param feeRecipient The network fee recipient locked in the token.
    function listFederatedContract(
        uint256 artistId,
        address token,
        uint8 form,
        address partner,
        uint32 feeShare,
        address feeRecipient
    ) external;
    /// @notice Sets a listed token's status to ACTIVE or DELISTED. Bound federation registry
    ///         only; never for an unlisted or LEFT token (`FederatedStatusRefused`).
    /// @param token The federated token contract.
    /// @param status ACTIVE or DELISTED.
    /// @param ref The federation registry's reference for the decision.
    function setFederatedStatus(address token, FederationStatus status, bytes32 ref) external;
    /// @notice Records that the calling token left the federation: its status becomes LEFT,
    ///         for good. Only the token itself can write it, so exit never depends on replaceable
    ///         code; a repeat does nothing, and an unlisted caller reverts.
    function recordFederationExit() external;
    /// @notice Sets one governed wait. SUCCESSOR_SETTER role (the 30-day class). It must lie
    ///         within `timerBounds`, and afterwards CONTEST_TIMEOUT must exceed OVERRIDE_DELAY by
    ///         at least 185 days (`InvalidTimers`; lengthen CONTEST_TIMEOUT before OVERRIDE_DELAY).
    ///         Pending changes keep the delay and contest timeout locked at their staging.
    /// @param timer The wait to set.
    /// @param value Its new value in seconds.
    function setTimer(Timer timer, uint48 value) external;
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
    ///         every use. On a mismatch, `refreshStanding` and a consolidated wallet's signer
    ///         check revert with `Dependency.DependencyCodeChanged`; every other refresh skips
    ///         (`StandingRefreshSkipped`), trusting nothing from the changed source.
    /// @return The pinned code hash.
    function consolidationSourceCodeHash() external view returns (bytes32);
    /// @notice A token's federation directory entry: its artist and status (NONE if never
    ///         listed). The fixed fields are in its `FederatedContractListed` event.
    /// @param token The token.
    /// @return artistId The artist it is listed under, or zero.
    /// @return status Its status.
    function federatedListing(address token)
        external
        view
        returns (uint256 artistId, FederationStatus status);
    /// @notice The package registry, the only `register` caller: bound at genesis, replaceable
    ///         by governance (`setPackageRegistry`).
    /// @return The package registry, or zero before it is bound.
    function packageRegistry() external view returns (address);
    /// @notice The bound 6529 Stream.
    /// @return The 6529 Stream contract, or zero before it is bound.
    function stream() external view returns (address);
    /// @notice The current federation registry, or zero before it is bound.
    /// @return The federation registry, or zero.
    function federationRegistry() external view returns (address);
    /// @notice The bound split factory.
    /// @return The split factory, or zero before it is bound.
    function splitFactory() external view returns (address);
    /// @notice The artist's standing snapshot, including missing wallets not yet removed.
    /// @param artistId The artist ID.
    /// @return The snapshot's entries, at most `Limits.MAX_CANCELLERS`, in no fixed order.
    function standingOf(uint256 artistId) external view returns (Standing[] memory);
    /// @notice A governed wait's current value.
    /// @param timer The wait.
    /// @return Its value in seconds.
    function timer(Timer timer) external view returns (uint48);
    /// @notice A wait's compiled floor (its genesis value) and ceiling.
    /// @param timer The wait.
    /// @return floor The shortest it can ever be, in seconds.
    /// @return ceiling The longest governance can make it, in seconds.
    function timerBounds(Timer timer) external pure returns (uint48 floor, uint48 ceiling);
    /// @notice The bound statement log, or zero before it is bound.
    /// @return The statement log, or zero.
    function statementLog() external view returns (address);
}
