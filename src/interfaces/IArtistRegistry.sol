// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IArtistRoleResolver } from "./IArtistRoleResolver.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "./types/IdentityTypes.sol";

/// @title IConsolidationSource
/// @notice Where the artist registry learns an account's established consolidated wallets
///         (ADR 0001 section 11 "Recovery uses 6529 consolidation").
/// @dev The v1 adapter reads the 6529 delegation contract
///      (`0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`, use case 999) and walks registration and
///      expiry dates directly: a wallet counts only if its consolidation with `account` is at
///      least 30 days old and not expired. Use case 997 (primary address) is never used as a
///      payout. A 6529-chain source replaces it through a 30-day governed swap.
interface IConsolidationSource {
    /// @notice `account`'s established consolidated wallets, at most an implementation bound.
    function establishedWallets(address account) external view returns (address[] memory);

    /// @notice Whether `wallet` is an established consolidated wallet of `account` now.
    function isEstablished(address account, address wallet) external view returns (bool);
}

/// @title IArtistRegistry
/// @notice The slim artist registry: artist IDs, authority, payout and profile, with recovery
///         through 6529 consolidation (ADR 0001 section 11).
/// @dev An identity is created from the artist's first package acceptance. Every account that
///      has been an artist's authority maps to that artist ID forever, so a package naming an
///      old address still resolves to the identity, while only the current authority can sign.
///      Every change of authority, payout or profile is staged, waits, and can be cancelled:
///      - STANDARD changes are staged by the authority or by an established consolidated wallet
///        (signed, with a deadline, and including the profile ID and document hash), wait
///        7 days, and may be cancelled by the previous authority, by any consolidated wallet
///        captured at staging, or vetoed by the guardian (which blocks but never redirects);
///      - overrides (CONTESTED, ESTATE, LOST_KEY) are staged by a governed network action with
///        a 180-day public notice; ESTATE and LOST_KEY need a year without signed activity from
///        the authority or its established consolidated wallets; only captured consolidated
///        wallets (never the previous authority) may cancel, and the guardian may veto.
///      One change may be pending per artist. `executeChange` is permissionless once due.
///      `isArtist(token, id, account)` (from `IArtistRoleResolver`) is true when `account` is
///      the current authority of the lead artist of 6529 Stream work `id`, or of the master of
///      6529 Editions edition `id`.
interface IArtistRegistry is IArtistRoleResolver {
    /// @notice An artist identity was created.
    event ArtistRegistered(uint64 indexed artistId, ArtistIdentity identity);
    /// @notice A change was staged.
    event ChangeStaged(uint64 indexed artistId, PendingChange change);
    /// @notice A pending change was cancelled by `by` (a captured wallet or the previous
    ///         authority) or vetoed by the guardian (`vetoed`).
    event ChangeCancelled(uint64 indexed artistId, address indexed by, bool vetoed);
    /// @notice A change took effect.
    event ChangeExecuted(uint64 indexed artistId, ArtistIdentity previous, ArtistIdentity next);
    /// @notice Signed activity was recorded for dormancy purposes.
    event ActivityRecorded(uint64 indexed artistId, uint64 timestamp);
    /// @notice The consolidation source changed.
    event ConsolidationSourceSet(address previous, address next);

    /// @notice No artist has this ID.
    error UnknownArtist(uint64 artistId);
    /// @notice The account already belongs to an artist identity.
    error AccountTaken(address account);
    /// @notice The caller or signer may not perform this action.
    error NotAuthorized(uint64 artistId, address account);
    /// @notice A change is already pending.
    error ChangePending(uint64 artistId);
    /// @notice No change is pending.
    error NoPendingChange(uint64 artistId);
    /// @notice The change is not executable before `executableAt`.
    error ChangeNotDue(uint64 artistId, uint64 executableAt);
    /// @notice The artist has signed activity within the last year.
    error NotDormant(uint64 artistId, uint64 lastActivity);
    /// @notice The next identity has a zero authority or payout, or an invalid override kind.
    error InvalidIdentity();
    /// @notice A signature is expired or does not verify.
    error InvalidSignature();
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();

    /// @notice Creates an identity for `authority` (payout defaults to `authority`). Restricted to
    ///         the package registry (SYSTEM role), which has verified the artist's signed
    ///         acceptance carrying the profile fields.
    function register(address authority, bytes32 profileId, bytes32 profileDocHash)
        external
        returns (uint64 artistId);

    /// @notice Stages a STANDARD change signed by `signer`: the current authority or an
    ///         established consolidated wallet of it. The EIP-712 payload is
    ///         `IdentityChange(uint64 artistId,address authority,address payout,bytes32 profileId,
    ///         bytes32 profileDocHash,uint256 nonce,uint64 deadline)`. When the authority changes,
    ///         `authorityAcceptance` is the new authority's signature over the same payload (the
    ///         two-sided change); otherwise it is empty. Captures the cancellers.
    function stageChange(
        uint64 artistId,
        ArtistIdentity calldata next,
        address signer,
        uint64 deadline,
        bytes calldata signature,
        bytes calldata authorityAcceptance
    ) external;

    /// @notice Stages a network override (CONTESTED, ESTATE or LOST_KEY) with a 180-day notice.
    ///         PARAMETER_SETTER role. `evidenceHash` commits to the public record.
    function stageOverride(
        uint64 artistId,
        ChangeKind kind,
        ArtistIdentity calldata next,
        bytes32 evidenceHash
    ) external;

    /// @notice Cancels the pending change. Callable by a captured consolidated wallet, or by the
    ///         previous authority for a STANDARD change.
    function cancelChange(uint64 artistId) external;

    /// @notice Vetoes the pending change. GUARDIAN role; it can block, never redirect.
    function vetoChange(uint64 artistId) external;

    /// @notice Applies a due change. Permissionless.
    function executeChange(uint64 artistId) external;

    /// @notice Records signed activity. Callable by the authority, an established consolidated
    ///         wallet, or a protocol contract (SYSTEM role) on the artist's behalf.
    function heartbeat(uint64 artistId) external;

    /// @notice Swaps the consolidation source. SUCCESSOR_SETTER role, compare-and-set.
    function setConsolidationSource(IConsolidationSource expected, IConsolidationSource next)
        external;

    /// @notice An artist's identity and last signed activity. Reverts with `UnknownArtist`.
    function artist(uint64 artistId)
        external
        view
        returns (ArtistIdentity memory identity, uint64 lastActivity);
    /// @notice The artist ID of an account that is or was an authority, or zero.
    function artistIdOf(address account) external view returns (uint64);
    /// @notice The current authority. Reverts with `UnknownArtist`.
    function authorityOf(uint64 artistId) external view returns (address);
    /// @notice The current payout address. Reverts with `UnknownArtist`.
    function payoutOf(uint64 artistId) external view returns (address);
    /// @notice The pending change (kind NONE if none).
    function pendingChange(uint64 artistId) external view returns (PendingChange memory);
    /// @notice The nonce the next signed change must carry.
    function changeNonce(uint64 artistId) external view returns (uint256);
    /// @notice The number of artist identities.
    function artistCount() external view returns (uint64);
    /// @notice The consolidation source.
    function consolidationSource() external view returns (IConsolidationSource);
}
