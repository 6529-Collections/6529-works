// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "../../economics/interfaces/ISplitWallet.sol";

/// @notice What a package item mints on 6529 Stream (ADR 0001 sections 3 and 6).
/// @dev ORIGINAL is a 1/1. EDITION_MASTER is a 1/1 that also anchors exactly one 6529 Editions
///      edition, created from the same item once the master's sale has settled.
enum ItemKind {
    ORIGINAL,
    EDITION_MASTER
}

/// @notice How a listed party is credited (ADR 0001 section 3).
/// @dev ARTIST parties are credited authors; COLLABORATOR parties are credited contributors.
///      The first party of every item is the lead ARTIST, whose active authority signs "move to
///      Stream", edits the work record and finalizes.
enum PartyRole {
    ARTIST,
    COLLABORATOR
}

/// @notice Where a seeded work's seed comes from (ADR 0001 section 9).
/// @dev NONE: unseeded, `seed` is zero. ARTIST: `seed` is chosen by the artist and committed in
///      the package. VRF: `seed` is zero in the package; the entropy module delivers it, keyed by
///      the item hash, before the sale can start.
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

/// @notice A party named by a package item: someone credited, paid, or both.
/// @dev `account` signs the package root (ADR 0001 section 3 "every listed party signs"). Its
///      artist ID is `IArtistRegistry.artistIdOf(account)` if nonzero, otherwise
///      `uint256(uint160(account))` (the ID its first acceptance creates), so tools know every
///      artist ID before any transaction.
struct Party {
    address account;
    PartyRole role;
}

/// @notice A work's license (ADR 0001 section 8, owner direction 11 October 2026).
/// @dev `spdxId` is an SPDX identifier or `LicenseRef-` expression in its original case, for
///      display and URLs, from `[A-Za-z0-9.+-]` (at most `Limits.MAX_LICENSE_ID_BYTES`), for
///      example `CC0-1.0`; its canonical key is `WorksHashing.licenseKey(spdxId)`, keccak256 of
///      the ID lowercased, and a license
///      is identified by that key plus `textFileId`, the `IContentStore` file ID of the full
///      license text. CC0 irrevocability is checked on the key. Editions carry their master's
///      license.
struct License {
    string spdxId;
    bytes32 textFileId;
}

/// @notice How a work is first sold: a sale kind, its parameters and the currency
///         (ADR 0001 section 5 "Sale extensibility").
/// @dev `saleKind` is a `SaleKind` label; only an adapter reporting the same kind may sell the
///      work, and 6529 Stream accepts only `SaleKind.ENGLISH_AUCTION`. `currency` is
///      `CURRENCY_ETH` (`address(0)`), an allowlisted ERC-20, or `CURRENCY_DEFAULT` for the
///      product's default currency when the sale starts. `params` is the encoding the kind
///      defines; the English auction takes none, so it must be empty.
struct SaleTerms {
    bytes32 saleKind;
    address currency;
    bytes params;
}

/// @notice The edition an EDITION_MASTER item anchors (ADR 0001 section 6).
/// @dev `price` is the unit price for FIXED_PRICE sales and the starting price for DUTCH sales.
///      A non-zero `price` must name an explicit `currency`: `CURRENCY_DEFAULT` is allowed only
///      with a zero price, because a price is meaningless without its currency.
///      `saleKind` is `SaleKind.FIXED_PRICE` or `SaleKind.DUTCH`; `params` is that kind's
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
/// @dev Hashed as `WorksHashing.itemHash`; the package root is a Merkle root over
///      `WorksHashing.leaf(itemHash)`.
///      - `contentHash`: the decoded SHA-256 of the primary media, the per-product uniqueness key.
///      - `mediaHash`: `WorksHashing.mediaHash` of every media file (file IDs and decoded SHA-256,
///        primary first), so media is fixed by approval; the list's first entry carries
///        `contentHash`.
///      - `recordFileId`: the `IContentStore` file ID of the approved descriptive record (JSON);
///        the artist may point the work at a new record file until finalize.
///      - `parties`: 1 to `Limits.MAX_PARTIES` distinct accounts, lead ARTIST first.
///      - `payees`: the canonical payee list of the artist portion; every payee is a party, by
///        account (fixed) or by artist ID (artist-resolved), so nobody is paid without signing.
///        Payees never change after mint; only the royalty rate may, by agreement.
///      - `collectionId`: a 6529 Stream collection (chain-specific, below 2^32).
///      - `seed`: nonzero only under `SeedPolicy.ARTIST`.
struct PackageItem {
    ItemKind kind;
    uint256 collectionId;
    bytes32 contentHash;
    bytes32 mediaHash;
    bytes32 recordFileId;
    Party[] parties;
    ISplitWallet.Payee[] payees;
    License license;
    SeedPolicy seedPolicy;
    bytes32 seed;
    SaleTerms sale;
    EditionTerms edition;
}

/// @notice The lead artist's revocable "move to Stream" authorization (ADR 0001 section 3).
/// @dev An EIP-712 `Typehashes.MOVE_TO_STREAM` signature by the lead artist's active authority
///      in the package registry's domain. The nonce is single-use per artist ID and revocable;
///      the registry tracks nonces in a bitmap of 255 per word (word `nonce / 255`, bit
///      `nonce % 255`), so any `uint256` nonce works. An authority the artist rotated away from
///      never becomes its authority again, so its unused moves stay void; a new authority that is
///      an ERC-1271 or EIP-7702 wallet accepting the old key's signatures revives them (the
///      artist's own configuration).
struct MoveAuthorization {
    uint256 nonce;
    uint64 deadline;
    bytes signature;
}

/// @notice A party's acceptance of a package root (ADR 0001 sections 3 and 11).
/// @dev An EIP-712 `Typehashes.PACKAGE_ACCEPTANCE` signature in the package registry's domain,
///      by `account` when it has no artist ID yet (the acceptance then creates one), or by the
///      active authority of `account`'s artist ID. `profileId` is the artist's unverified claim
///      of a 6529 profile; it must match the record when one exists. A rotated-away authority's
///      unused acceptances stay void, unless a new authority that is an ERC-1271 or EIP-7702
///      wallet accepts the old key's signatures (the artist's own configuration).
struct PartyAcceptance {
    address account;
    bytes32 profileId;
    bytes32 profileDocHash;
    uint64 deadline;
}

/// @notice The `data` a sale adapter passes to `IStream.mint` to start a curated work: opaque to
///         the adapter, `abi.encode(StreamMintRequest)`.
struct StreamMintRequest {
    bytes32 packageRoot;
    PackageItem item;
    bytes32[] proof;
    MoveAuthorization move;
}
