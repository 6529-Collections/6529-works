// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice What a package item mints on 6529 Stream (ADR 0001 sections 3 and 6).
/// @dev ORIGINAL is a 1/1. EDITION_MASTER is a 1/1 that also anchors exactly one 6529 Editions
///      edition, created from the same item after the master is minted.
enum ItemKind {
    ORIGINAL,
    EDITION_MASTER
}

/// @notice How a listed party is credited (ADR 0001 section 3).
/// @dev ARTIST parties are credited authors; COLLABORATOR parties share the artist portion
///      without authorship. The first party of every item is the lead ARTIST, whose current
///      authority signs "move to Stream", edits the work record and finalizes.
enum PartyRole {
    ARTIST,
    COLLABORATOR
}

/// @notice Where a seeded work's seed comes from (ADR 0001 section 9).
/// @dev NONE: unseeded, `seed` is zero. ARTIST: `seed` is chosen by the artist and committed in
///      the package. VRF: `seed` is zero in the package; the optional entropy module delivers it
///      before bidding opens.
enum SeedPolicy {
    NONE,
    ARTIST,
    VRF
}

/// @notice Whether an edition has a fixed size or sells for an open window (ADR 0001 section 6).
/// @dev FIXED: at most `size` copies, no time limit. OPEN: any number of copies (or at most
///      `size` when it is nonzero) during `window` seconds from the first mint.
enum EditionFormat {
    FIXED,
    OPEN
}

/// @notice A party named by a package item: who is credited and paid, and how much.
/// @dev `account` is the address that signs the package root (ADR 0001 section 3 "every listed
///      party signs"). It maps to an artist ID in the artist registry, created on first
///      acceptance, so later payouts follow that identity through recovery. `share` is the
///      party's part of the artist portion, out of `SHARE_DENOMINATOR` (100,000); an item's
///      shares are each nonzero and sum to exactly 100,000.
struct Party {
    address account;
    uint32 share;
    PartyRole role;
}

/// @notice A work's license (ADR 0001 section 8, owner direction 11 October 2026).
/// @dev `spdxId` is an SPDX identifier or `LicenseRef-` expression, for example `CC0-1.0`.
///      `textFileId` is the `IContentStore` file ID of the full license text, so the text is
///      permanent and its hash is part of the work. Editions carry their master's license.
struct License {
    string spdxId;
    bytes32 textFileId;
}

/// @notice How a work is first sold: a sale kind, its parameters and the currency
///         (ADR 0001 section 5 "Sale extensibility").
/// @dev `saleKind` is a `SaleKind` label; only an adapter reporting the same kind may sell the
///      work, and 6529 Stream accepts only `SaleKind.ENGLISH_AUCTION`. `currency` is
///      `CURRENCY_ETH` (`address(0)`), an allowlisted ERC-20, or `CURRENCY_DEFAULT` for the
///      product's default currency at the time the sale starts. `params` is the ABI encoding the
///      kind defines; the English auction takes none (its terms are governed), so it must be
///      empty.
struct SaleTerms {
    bytes32 saleKind;
    address currency;
    bytes params;
}

/// @notice The edition an EDITION_MASTER item anchors (ADR 0001 section 6).
/// @dev `price` is the unit price for FIXED_PRICE sales and the starting price for DUTCH
///      sales. `saleKind` is `SaleKind.FIXED_PRICE` or `SaleKind.DUTCH`; `params` is that kind's
///      encoding (empty for fixed price, `abi.encode(DutchParams)` for Dutch). For an ORIGINAL
///      item every field is zero or empty.
struct EditionTerms {
    EditionFormat format;
    uint64 size;
    uint64 window;
    uint256 price;
    address currency;
    bytes32 saleKind;
    bytes params;
}

/// @notice One item of an approved package: everything voters approve and every party signs.
/// @dev Hashed as `WorksHashing.itemHash`, and the package root is a Merkle root over
///      `WorksHashing.leaf(itemHash)` (see `WorksHashing` for the exact convention).
///      `contentId` is the `IContentStore` file ID of the primary media, which must be
///      registered in the content store before the sale starts. The item's content hash (the
///      ADR's uniqueness key) is the SHA-256 of the decoded primary media that the store declares
///      for it, `IContentStore.fileInfo(contentId).sha256Hash`: it does not depend on MIME type or
///      encoding, so the same media re-encoded is still the same content. 6529 Stream and
///      6529 Editions each reject a content hash already used in that product.
///      `metadataHash` is `WorksHashing.workRecordHash` of the approved work record. `split`
///      must equal `WorksHashing.partySplitId(parties)`, the split wallet that receives the
///      artist portion. `parties` holds 1 to `Limits.MAX_PARTIES` entries. `seed` is nonzero
///      only under `SeedPolicy.ARTIST`.
struct PackageItem {
    ItemKind kind;
    uint256 collectionId;
    bytes32 contentId;
    bytes32 metadataHash;
    Party[] parties;
    bytes32 split;
    License license;
    SeedPolicy seedPolicy;
    bytes32 seed;
    SaleTerms sale;
    EditionTerms edition;
}

/// @notice The lead artist's revocable "move to Stream" authorization (ADR 0001 section 3).
/// @dev An EIP-712 signature by the lead artist's current authority over
///      `MoveToStream(bytes32 packageRoot,bytes32 itemHash,uint256 nonce,uint64 deadline)` in
///      the package registry's domain. The nonce is single-use per artist ID and can be revoked
///      before use.
struct MoveAuthorization {
    uint256 nonce;
    uint64 deadline;
    bytes signature;
}

/// @notice A party's acceptance of a package root (ADR 0001 sections 3 and 11).
/// @dev An EIP-712 signature over `PackageAcceptance(bytes32 packageRoot,address account,
///      bytes32 profileId,bytes32 profileDocHash,uint64 deadline)` in the package registry's
///      domain, by `account` when it has no artist ID yet (the acceptance then creates one), or
///      by the current authority of `account`'s artist ID. The profile fields must match the
///      artist record when one exists.
struct PartyAcceptance {
    address account;
    bytes32 profileId;
    bytes32 profileDocHash;
    uint64 deadline;
}

/// @notice The `data` a sale adapter passes to `IStream.mint` to start a curated work.
/// @dev The adapter treats it as opaque bytes: `abi.encode(StreamMintRequest)`.
struct StreamMintRequest {
    bytes32 packageRoot;
    PackageItem item;
    bytes32[] proof;
    MoveAuthorization move;
}
