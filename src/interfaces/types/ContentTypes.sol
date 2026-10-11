// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice What a media file is in a work (ADR 0001 section 8).
/// @dev PRIMARY is the artwork itself: exactly one, first in the media list. PREVIEW is a small
///      still image used where the primary media is too large or interactive to inline.
///      AUXILIARY files are everything else the work loads (scripts, textures, audio).
enum FileRole {
    PRIMARY,
    PREVIEW,
    AUXILIARY
}

/// @notice Where a copy of a file can be fetched (ADR 0001 section 8 "Preferred location").
/// @dev NONE is the unset value of a preference and never a registered locator. ONCHAIN is the
///      content store itself: implicit for every on-chain complete file, never registered by
///      hand. There is no HTTPS kind: every locator is content-addressed.
enum LocatorKind {
    NONE,
    ARWEAVE,
    IPFS,
    ONCHAIN
}

/// @notice One media file of a work, fixed by approval (ADR 0001 sections 3 and 8).
/// @dev `fileId` is an `IContentStore` file ID; `sha256Hash` is the SHA-256 of the decoded file,
///      which the curation signer verifies against the decoded bytes before attesting. The
///      ordered list is committed by `PackageItem.mediaHash` and can never change.
struct MediaFile {
    bytes32 fileId;
    bytes32 sha256Hash;
    FileRole role;
}

/// @notice A registered copy of a file: `ar://<txid>` for ARWEAVE, `ipfs://<CIDv1>` under the fixed
///         CID profile for IPFS. Locators are append-only.
struct Locator {
    LocatorKind kind;
    string uri;
}
