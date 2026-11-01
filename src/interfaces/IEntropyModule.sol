// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { PackageItem } from "./types/PackageTypes.sol";

/// @title IEntropyModule
/// @notice The optional VRF module for seeded 1/1s, revealed before any sale starts (ADR 0001
///         section 9).
/// @dev Entropy is never in Core's mint path. Seeds are drawn once per content hash (one seed per
///      work, whatever package lists it) and requested before any token exists. 6529 Stream's
///      `mint` requires `isDeliveredContent(item.contentHash)` for a VRF item (one storage word)
///      and `IWorkRecords.openRecord` stores `seedOfContent(item.contentHash)`, so nothing ever
///      sits in sale custody waiting for randomness. The item-keyed reads (`isDelivered`,
///      `seedOf`) go through the link `requestSeed` records; the renderer reads `seedOf` before a
///      record opens. The VRF fulfillment stores the seed here, with no callback into
///      any token or adapter. Anyone may request, for an item of an approved package that is not
///      yet consumed and whose seed policy is VRF (checked against the package registry), which
///      keeps the subscription safe from spam. An item whose content already has a delivered or
///      pending draw only joins it. While no seed is fixed, anyone may add another request once
///      `retryDelay()` (at least 3 days) has passed since the last one. The first delivery wins:
///      any outstanding request from the coordinator that issued it may deliver until the
///      content's seed is fixed, and later deliveries are no-ops. Seeds are permanent.
interface IEntropyModule is IERC165 {
    /// @notice The item was linked to its content's draw; it reads that draw's seed.
    /// @param itemHash The linked item's hash (`WorksHashing.itemHash`).
    /// @param contentHash The item's content hash, which keys the draw.
    event SeedLinked(bytes32 indexed itemHash, bytes32 indexed contentHash);
    /// @notice A seed was requested for the item's content.
    /// @param itemHash The hash of the item whose call made the request.
    /// @param requestId The coordinator's ID for the request.
    event SeedRequested(bytes32 indexed itemHash, uint256 requestId);
    /// @notice The content's seed was delivered.
    /// @param contentHash The content whose seed is now fixed.
    /// @param requestId The request whose delivery fixed it.
    /// @param seed The seed: the delivered random word, unchanged.
    event SeedDelivered(bytes32 indexed contentHash, uint256 requestId, bytes32 seed);
    /// @notice The VRF coordinator changed; `codeHash` is the pinned code hash of `next`.
    /// @param previous The coordinator before the change (zero at deployment).
    /// @param next The coordinator after the change.
    /// @param codeHash The code hash `next` must keep at every later use.
    event CoordinatorSet(address previous, address next, bytes32 codeHash);

    /// @notice The item is not in an approved package, is already consumed, has no content hash,
    ///         or is not VRF.
    error NotRequestable(bytes32 itemHash);
    /// @notice The seed was already delivered.
    error SeedAlreadyDelivered(bytes32 itemHash);
    /// @notice A request is outstanding and may be repeated only from `retryAt`.
    error RequestPending(bytes32 itemHash, uint64 retryAt);
    /// @notice No seed has been delivered yet.
    error SeedNotDelivered(bytes32 itemHash);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();
    /// @notice A request parameter is zero or outside its bounds (the callback gas limit's
    ///         ceiling is enforced by `BoundedParameter`).
    error InvalidConfig();
    /// @notice `retryDelay` is outside the module's bounds (3 to 30 days for the VRF module).
    error InvalidRetryDelay(uint64 retryDelay);
    /// @notice The VRF callback was called by `have`, not by the coordinator `want`.
    error OnlyCoordinatorCanFulfill(address have, address want);
    /// @notice The request ID was never issued by the current coordinator.
    error UnknownRequest(uint256 requestId);
    /// @notice The coordinator returned a zero or already used request ID.
    error InvalidRequestId(uint256 requestId);
    /// @notice The coordinator delivered other than exactly one random word.
    error InvalidRandomWords(uint256 requestId);

    /// @notice Links an approved, unconsumed VRF item to its content's draw and requests that
    ///         draw's seed, or adds another request once `retryDelay()` has passed with no seed
    ///         fixed. Returns zero when the item only joined a delivered or pending draw. A
    ///         linked item called again once `retryDelay()` has passed with no seed fixed makes
    ///         a new request for the content. Permissionless.
    /// @param item The package item; the module computes its hash itself.
    /// @param packageRoot An approved package root that lists the item.
    /// @param proof The Merkle proof of the item's leaf (`WorksHashing.leaf(itemHash)`) under
    ///        `packageRoot`.
    /// @return requestId The coordinator's ID for the new request, or zero when the item only
    ///        joined its content's draw.
    function requestSeed(PackageItem calldata item, bytes32 packageRoot, bytes32[] calldata proof)
        external
        returns (uint256 requestId);
    /// @notice Whether the seed of the item's content was delivered (false for an item never
    ///         linked by `requestSeed`).
    /// @param itemHash The item's hash (`WorksHashing.itemHash`).
    /// @return True once the seed is delivered.
    function isDelivered(bytes32 itemHash) external view returns (bool);
    /// @notice Whether the seed of `contentHash` was delivered: one storage word, read by 6529
    ///         Stream's `mint` for a VRF item (a seed belongs to its content, whichever package
    ///         lists it, and a content hash is consumed by one item only).
    /// @param contentHash The content hash.
    /// @return True once the content's seed is delivered.
    function isDeliveredContent(bytes32 contentHash) external view returns (bool);
    /// @notice The delivered seed of `contentHash`, which `IWorkRecords.openRecord` stores; reverts
    ///         with `SeedNotDelivered(contentHash)` before delivery.
    /// @param contentHash The content hash.
    /// @return The seed.
    function seedOfContent(bytes32 contentHash) external view returns (bytes32);
    /// @notice The delivered seed of the item's content. Reverts with `SeedNotDelivered`.
    /// @param itemHash The item's hash (`WorksHashing.itemHash`).
    /// @return The seed: the delivered random word, unchanged.
    function seedOf(bytes32 itemHash) external view returns (bytes32);
    /// @notice The latest request for the item's content: its ID (zero once the seed is
    ///         delivered) and when it was made.
    /// @param itemHash The item's hash (`WorksHashing.itemHash`).
    /// @return requestId The latest request's ID; zero once the seed is delivered, and for an
    ///        item never linked.
    /// @return requestedAt When the latest request was made, in seconds since the epoch (kept
    ///        after delivery); zero for an item never linked.
    function requestOf(bytes32 itemHash)
        external
        view
        returns (uint256 requestId, uint64 requestedAt);
    /// @notice Seconds after the latest request before another may be added (at least 3 days).
    /// @return The delay in seconds.
    function retryDelay() external view returns (uint64);
    /// @notice The VRF coordinator.
    /// @return The coordinator's address, the only account that may deliver seeds.
    function coordinator() external view returns (address);
    /// @notice Sets the VRF coordinator (Chainlink migrations): code hash `nextCodeHash`, not an
    ///         EIP-7702 delegated account. SUCCESSOR_SETTER role (30-day class), compare-and-set.
    /// @param expected The current coordinator; any other value reverts with
    ///        `ExpectedValueMismatch`.
    /// @param next The new coordinator, which must differ from the current one.
    /// @param nextCodeHash The reviewed code hash `next` must have now and at every later use.
    function setCoordinator(address expected, address next, bytes32 nextCodeHash) external;
}
