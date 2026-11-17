// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice An artist account's recorded fields (ADR 0001 section 11 "Registry").
/// @dev `root` is the wallet the account's 6529 consolidation is read from; every wallet
///      consolidated with it acts for the account with the same rights. `payout` receives the
///      account's artist-resolved split payments and is never zero. `profileId` is the 6529
///      profile ID and `profileDocHash` the hash of the profile document.
struct ArtistIdentity {
    address root;
    address payout;
    bytes32 profileId;
    bytes32 profileDocHash;
}

/// @notice What kind of identity change is pending.
/// @dev NONE: nothing pending. OWN: the account's own change, signed by any of its wallets,
///      executable after 2 days. REPLACEMENT: the network replaces the root, executable after
///      14 days' notice; a contested one runs only if the network upholds it within 90 days.
enum ChangeKind {
    NONE,
    OWN,
    REPLACEMENT
}

/// @notice A staged identity change.
/// @dev `executableAt` is when it may execute. `contestedAt` is when a wallet of the account
///      contested a REPLACEMENT (zero otherwise), and `priorOutcome` the account's latest
///      DISPUTE_OUTCOME entry at that moment, so only a vote recorded after the contest can
///      resolve it. `evidenceHash` is zero for an OWN change.
struct PendingChange {
    ChangeKind kind;
    uint48 executableAt;
    uint48 contestedAt;
    ArtistIdentity next;
    bytes32 evidenceHash;
    bytes32 priorOutcome;
}
