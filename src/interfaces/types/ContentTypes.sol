// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice What a file does in a work (ADR 0001 section 8).
/// @dev PRIMARY is the artwork itself; every media list has exactly one, first. PREVIEW is a small
///      still image used where the primary media is too large or interactive to inline.
///      AUXILIARY files are everything else the work loads (scripts, textures, audio).
enum FileRole {
    PRIMARY,
    PREVIEW,
    AUXILIARY
}

/// @notice Where a copy of a file can be fetched (ADR 0001 section 8 "Preferred location").
/// @dev NONE is the unset value of a preference and never a registered locator. ONCHAIN is the
///      content store itself: it is implicit for every on-chain complete file and cannot be
///      registered by hand.
enum LocatorKind {
    NONE,
    ARWEAVE,
    IPFS,
    HTTPS,
    ONCHAIN
}

/// @notice One entry of a work's media list.
/// @dev `fileId` is an `IContentStore` file ID, which already binds the file's chunk hashes,
///      stored length, encoding, MIME type and the SHA-256 of the decoded file (the work's media
///      hash); this entry adds only what the file is for and the relative path other files of
///      the work use to load it (empty when nothing loads it by path).
struct ContentFile {
    bytes32 fileId;
    FileRole role;
    string path;
}

/// @notice A registered copy of a file: the locator kind and its URI.
/// @dev Arweave URIs are `ar://<txid>`, IPFS URIs are `ipfs://<CIDv1>` under the fixed CID
///      profile, HTTPS URIs are absolute `https://` URLs. Locators are append-only.
struct Locator {
    LocatorKind kind;
    string uri;
}

/// @notice One per-token trait.
struct Attribute {
    string traitType;
    string value;
}

/// @notice A dependency-registry entry a work loads, by its `IDependencyRegistry` labels.
struct DependencyRef {
    bytes32 name;
    bytes32 version;
}

/// @notice A work's descriptive record (ADR 0001 section 8 "Work record").
/// @dev Hashed as `WorksHashing.workRecordHash`; the package item commits that hash, and the
///      lead artist may replace the record until the work is finalized. `media[0]` is the
///      PRIMARY file and its `fileId` always equals the item's `contentId`. Each file's SHA-256,
///      size and MIME type come from the content store; each file's locators are kept per token
///      by 6529 Stream. Collection and artist traits are added by the renderer, not listed in
///      `attributes`. Limits keep every write within the EIP-7825 transaction gas cap:
///      at most `Limits.MAX_ARTISTS` artists, `Limits.MAX_ATTRIBUTES` attributes,
///      `Limits.MAX_MEDIA_FILES` files, `Limits.MAX_DEPENDENCIES` dependencies, and at most
///      `Limits.MAX_WORK_RECORD_BYTES` bytes of `abi.encode(work)`.
struct Work {
    string title;
    string description;
    string[] artists;
    uint16 year;
    string medium;
    string dimensions;
    Attribute[] attributes;
    ContentFile[] media;
    DependencyRef[] dependencies;
}
