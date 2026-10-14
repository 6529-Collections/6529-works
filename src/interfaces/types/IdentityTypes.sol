// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice An artist identity's mutable state (ADR 0001 section 11 "Registry").
/// @dev `authority` signs for the artist and is never zero. `payout` receives the artist's
///      artist-resolved split payments and is never zero. `profileId` is the 6529 profile ID and
///      `profileDocHash` the hash of the profile document; every artist-signed identity payload
///      includes both.
struct ArtistIdentity {
    address authority;
    address payout;
    bytes32 profileId;
    bytes32 profileDocHash;
}

/// @notice What kind of identity change is pending (ADR 0001 section 11).
/// @dev NONE: nothing pending. STANDARD: staged by the authority or an established consolidated
///      wallet; executable after 7 days. CONTESTED, ESTATE and LOST_KEY are network overrides
///      with a 180-day public notice; ESTATE and LOST_KEY also need a year with no signed
///      activity.
enum ChangeKind {
    NONE,
    STANDARD,
    CONTESTED,
    ESTATE,
    LOST_KEY
}

/// @notice A wallet with recovery standing in an artist's sticky snapshot (ADR 0001 section 11
///         "Canceller set captured at staging").
/// @dev `effectiveAt` is when the wallet's consolidation became (or becomes) at least 30 days
///      old; before then the entry is pending and confers no standing. `missingSince` is when a
///      refresh first found the established wallet no longer consolidated, or zero. A missing
///      wallet keeps standing until a refresh at least `STANDING_GRACE` later removes it; a
///      pending entry found no longer consolidated is removed at once. One storage slot.
struct Standing {
    address wallet;
    uint48 effectiveAt;
    uint48 missingSince;
}

/// @notice A staged identity change.
/// @dev `cancellers` are the established consolidated wallets captured when the change was
///      staged (ADR 0001 section 11 "Canceller set captured at staging"); a later revocation of
///      a consolidation does not remove them; at most `Limits.MAX_CANCELLERS` are captured.
///      `previousAuthority` may cancel a STANDARD change but never an override. `evidenceHash`
///      is zero for STANDARD changes. An override a captured wallet cancelled during its notice
///      is contested: `contestedAt` records the first such cancel (zero otherwise), and
///      `priorOutcome` the artist's latest DISPUTE_OUTCOME entry at that moment, so only a vote
///      recorded after the contest can resolve it. `contestedAt` shares `executableAt`'s slot.
struct PendingChange {
    ChangeKind kind;
    ArtistIdentity next;
    address previousAuthority;
    uint64 stagedAt;
    uint64 executableAt;
    uint64 contestedAt;
    bytes32 priorOutcome;
    bytes32 evidenceHash;
    address[] cancellers;
}
