// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Limits
/// @notice Bounds on every user-supplied array or blob the interfaces accept. Each bound keeps
///         the worst-case transaction well inside the EIP-7825 (Fusaka) cap of 16,777,216 gas
///         per transaction, and keeps loops over user data bounded (ADR 0001 engineering rules).
/// @dev Constants only; nothing here is linked bytecode. Content-store bounds (`CHUNK_SIZE`,
///      `MAX_CHUNKS`) are defined by `IContentStore`, and the split-wallet payee bound by the
///      economics lane. Worst cases, at 22,100 gas per new storage word:
///      - `consume`: one `acceptedAs` read per party and one check per payee (at most one payee
///        per party), with no registry calls, so at most 16 cold reads on the start path;
///      - `openRecord`: per media file, one content-store read and one stored file ID, under
///        1.5M gas at 32 (the descriptive record is a content-store file, so only its ID is
///        stored);
///      - captured cancellers, sale phases and locators: under 1M gas each at these bounds,
///        and `preferredLocator` scans at most 16 locators inside `tokenURI`'s 8M budget.
library Limits {
    /// @notice Parties (artists and collaborators) per package item, and so payees per item.
    uint256 internal constant MAX_PARTIES = 16;
    /// @notice Media files per work.
    uint256 internal constant MAX_MEDIA_FILES = 32;
    /// @notice Bytes of a license's SPDX identifier.
    uint256 internal constant MAX_LICENSE_ID_BYTES = 64;
    /// @notice Locators per file of a work.
    uint256 internal constant MAX_LOCATORS_PER_FILE = 16;
    /// @notice Bytes per locator URI (the statement log uses the same bound).
    uint256 internal constant MAX_URI_BYTES = 2_048;
    /// @notice Phases per fixed-price sale.
    uint256 internal constant MAX_PHASES = 16;
    /// @notice Consolidated wallets captured as cancellers of one identity change.
    uint256 internal constant MAX_CANCELLERS = 16;
    /// @notice Bytes of a descriptive record file (12 KiB, half of a content-store chunk, so one
    ///         chunk always holds it): the renderer's cost per byte of a record is bounded by it.
    uint256 internal constant MAX_RECORD_BYTES = 12_288;
    /// @notice Artists listed in a descriptive record.
    uint256 internal constant MAX_ARTISTS = 16;
    /// @notice Nodes in a Merkle proof (package items and allowlists): enough for 2^32 leaves.
    uint256 internal constant MAX_PROOF_DEPTH = 32;
}
