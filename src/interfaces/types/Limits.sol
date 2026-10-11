// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Limits
/// @notice Bounds on every user-supplied array or blob the interfaces accept. Each bound keeps
///         the worst-case transaction well inside the EIP-7825 (Fusaka) cap of 16,777,216 gas
///         per transaction, and keeps loops over user data bounded (ADR 0001 engineering rules).
/// @dev Constants only; nothing here is linked bytecode. Content-store bounds (`CHUNK_SIZE`,
///      `MAX_CHUNKS`) are defined by `IContentStore`, and the split-wallet payee bound by the
///      economics lane. Worst cases, at 22,100 gas per new storage
///      word and about 200 gas per SSTORE2 byte:
///      - `consume`: one consent read and one identity read per party, and one check per payee
///        (at most one payee per party), under 0.5M gas at 16;
///      - `setWorkRecord`: a full 24,575-byte record stored as one SSTORE2 chunk costs about
///        5M gas, plus one content-store read per media file; storing the same record word by
///        word in contract storage would exceed the cap, so implementations must not;
///      - captured cancellers, sale phases and locators: under 1M gas each at these bounds,
///        and `preferredLocator` scans at most 16 locators inside `tokenURI`'s 8M budget.
library Limits {
    /// @notice Parties (artists and collaborators) per package item.
    uint256 internal constant MAX_PARTIES = 16;
    /// @notice Credited artist names per work record.
    uint256 internal constant MAX_ARTISTS = 16;
    /// @notice Attributes per work record.
    uint256 internal constant MAX_ATTRIBUTES = 64;
    /// @notice Media files per work record.
    uint256 internal constant MAX_MEDIA_FILES = 32;
    /// @notice Dependencies per work record.
    uint256 internal constant MAX_DEPENDENCIES = 16;
    /// @notice Bytes of `abi.encode(work)`: one SSTORE2 chunk.
    uint256 internal constant MAX_WORK_RECORD_BYTES = 24_575;
    /// @notice Locators per file of a work.
    uint256 internal constant MAX_LOCATORS_PER_FILE = 16;
    /// @notice Bytes per locator URI (the statement log uses the same bound).
    uint256 internal constant MAX_URI_BYTES = 2_048;
    /// @notice Phases per fixed-price sale.
    uint256 internal constant MAX_PHASES = 16;
    /// @notice Consolidated wallets captured as cancellers of one identity change.
    uint256 internal constant MAX_CANCELLERS = 16;
}
