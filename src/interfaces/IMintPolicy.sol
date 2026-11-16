// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { PrimaryTerms } from "./types/SaleTypes.sol";

/// @title IMintPolicy
/// @notice The one replaceable contract that decides what 6529 Stream may mint: it interprets an
///         adapter's mint request (opaque to Stream), checks consent, the item rules, the
///         economics and the entropy, and answers with the record Stream stores. Stream calls it
///         once per mint and decides; the policy has no write access to Stream and no power over
///         any existing token.
/// @dev The v1 policy is the package registry (`IPackageRegistry`), on the call Stream already
///      made to consume an item, so a mint reaches no extra account. Stream checks its own
///      invariants on the answer (the adapter's sale kind, a nonzero lead artist and seller,
///      bounded economics, an existing collection, the kind and seed policy within their stored
///      width), interns the terms and mints into the adapter's custody. Governance replaces the
///      policy (`IStream.setDependency("PACKAGE_REGISTRY", ...)`, the 30-day class); a successor
///      must keep its predecessor's consumed items and content claims authoritative.
///
///      What the core enforces, and what it leaves to the policy: Stream holds content
///      uniqueness, keyed by the content hash (a content hash mints once; a released one only
///      for the artist the release named, and never by the item it tombstoned), not
///      item-identifier uniqueness. The tombstone is read only when released content is claimed
///      again, so a mint costs no extra storage read for it. A successor policy must therefore
///      answer only item hashes that commit to their content hash (as the genesis registry's
///      `WorksHashing.itemHash` does, the content hash being one of the item's fields): a policy
///      that did not could mint a tombstoned item hash again with other content, which the core
///      would accept (`StreamPolicySafety.t.sol`, `test_MP1_TheCoreHoldsContentNotItemIdentifiers`).
interface IMintPolicy is IERC165 {
    /// @notice What Stream tells the policy about a mint: the calling adapter and Stream's own
    ///         current dependencies, so the policy holds no copy of them.
    /// @param adapter The admitted sale adapter that called `IMintTarget.mint`.
    /// @param economics Stream's economics resolver.
    /// @param entropyModule Stream's current entropy module (zero if none): the module whose
    ///        delivery a seeded work's mint checks, which `IStream.entropyModuleOf` reports.
    /// @param splitFactory Stream's split factory, which derives every seller and royalty wallet.
    struct MintContext {
        address adapter;
        address economics;
        address entropyModule;
        address splitFactory;
    }

    /// @notice What the policy admits: the work's facts and the terms it locks.
    /// @param itemHash The hash of the consumed item (nonzero), committing to `contentHash` (the
    ///        policy's obligation; see the contract notes).
    /// @param artistId The lead artist's ID (nonzero, at most 160 bits).
    /// @param collectionId The collection the work joins.
    /// @param kind The item kind (0 ORIGINAL, 1 EDITION_MASTER; Stream stores up to 3).
    /// @param seedPolicy The seed policy (0 NONE, 1 ARTIST, 2 VRF; Stream stores up to 3).
    /// @param royaltyRate The initial royalty rate, out of 100,000.
    /// @param packageRoot The approved package root.
    /// @param contentHash The decoded SHA-256 of the primary media.
    /// @param mediaHash The commitment to the media list.
    /// @param recordFileId The approved descriptive record's file ID.
    /// @param saleKind The item's sale kind (the adapter's, as Stream checks).
    /// @param currency The sale currency as approved.
    /// @param seller The seller wallet (the artist portion's split wallet).
    /// @param feeRecipient The network fee recipient.
    /// @param feeShare The network fee share, out of 100,000.
    /// @param creator The lead artist's active authority, which signed the move.
    /// @param params The sale method's params as approved.
    /// @dev Flat, one word per field and `params` last, so Stream reads the answer in place.
    struct MintRecord {
        bytes32 itemHash;
        uint256 artistId;
        uint256 collectionId;
        uint8 kind;
        uint8 seedPolicy;
        uint32 royaltyRate;
        bytes32 packageRoot;
        bytes32 contentHash;
        bytes32 mediaHash;
        bytes32 recordFileId;
        bytes32 saleKind;
        address currency;
        address seller;
        address feeRecipient;
        uint32 feeShare;
        address creator;
        bytes params;
    }

    /// @notice The item names no sale kind.
    error InvalidItemSale();
    /// @notice The item names no parties, or (a preview) its lead party has no artist ID yet.
    error InvalidLeadArtist();
    /// @notice The item's seed does not fit its seed policy, or it is a VRF item and Stream has
    ///         no entropy module.
    error InvalidSeedPolicy();
    /// @notice The item's license ID does not follow the `SpdxId` rule.
    error InvalidLicenseId();
    /// @notice The economics resolver's terms cannot be locked.
    error InvalidWorkTerms();
    /// @notice The VRF seed of this item has not been delivered.
    error SeedNotDelivered(bytes32 itemHash);

    /// @notice Admits one mint: consumes the request's item (single use) and answers with the
    ///         record Stream stores. Bound Stream only.
    /// @param context The calling adapter and Stream's current dependencies.
    /// @param request The adapter's `data`, as it passed it to `IMintTarget.mint`.
    /// @return record The admitted work and its terms.
    function authorize(MintContext calldata context, bytes calldata request)
        external
        returns (MintRecord memory record);

    /// @notice The terms `authorize` would lock for `request`, unverified and consuming nothing
    ///         (`IMintTarget.primaryTerms` with `id` 0).
    /// @param context As for `authorize`.
    /// @param request As for `authorize`.
    /// @return terms The primary-sale terms, `creator` resolved now.
    function preview(MintContext calldata context, bytes calldata request)
        external
        view
        returns (PrimaryTerms memory terms);

    /// @notice The artist registry the policy resolves parties through; Stream refuses a policy
    ///         whose registry is not its own.
    /// @return The artist registry.
    function artistRegistry() external view returns (address);
}
