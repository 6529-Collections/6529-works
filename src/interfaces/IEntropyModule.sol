// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { PackageItem } from "./types/PackageTypes.sol";

/// @title IEntropyModule
/// @notice The optional VRF module for seeded 1/1s, revealed before any sale starts (ADR 0001
///         section 9).
/// @dev Entropy is never in Core's mint path. Seeds are drawn once per content hash (one seed per
///      work, whatever package lists it) and requested before any token exists. Reads are keyed
///      by item hash, through the link `requestSeed` records: the auction's start (through 6529
///      Stream's `mint`) requires `isDelivered(itemHash)` for a VRF item, and
///      `IWorkRecords.seedOf` reads `seedOf(itemHash)`, so nothing ever sits in sale custody
///      waiting for randomness. The VRF fulfillment stores the seed here, with no callback into
///      any token or adapter. Anyone may request, for an item of an approved package that is not
///      yet consumed and whose seed policy is VRF (checked against the package registry), which
///      keeps the subscription safe from spam. An item whose content already has a delivered or
///      pending draw only joins it. While no seed is fixed, anyone may add another request once
///      `retryDelay()` (at least 3 days) has passed since the last one. The first delivery wins:
///      any outstanding request from the coordinator that issued it may deliver until the
///      content's seed is fixed, and later deliveries are no-ops. Seeds are permanent.
interface IEntropyModule is IERC165 {
    /// @notice The item was linked to its content's draw; it reads that draw's seed.
    event SeedLinked(bytes32 indexed itemHash, bytes32 indexed contentHash);
    /// @notice A seed was requested for the item's content.
    event SeedRequested(bytes32 indexed itemHash, uint256 requestId);
    /// @notice The content's seed was delivered.
    event SeedDelivered(bytes32 indexed contentHash, uint256 requestId, bytes32 seed);
    /// @notice The VRF coordinator changed; `codeHash` is the pinned code hash of `next`.
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

    /// @notice Links an approved, unconsumed VRF item to its content's draw and requests that
    ///         draw's seed, or adds another request once `retryDelay()` has passed with no seed
    ///         fixed. Returns zero when the item only joined a delivered or pending draw.
    ///         Permissionless.
    function requestSeed(PackageItem calldata item, bytes32 packageRoot, bytes32[] calldata proof)
        external
        returns (uint256 requestId);
    /// @notice Whether the seed of the item's content was delivered (false for an item never
    ///         linked by `requestSeed`).
    function isDelivered(bytes32 itemHash) external view returns (bool);
    /// @notice The delivered seed of the item's content. Reverts with `SeedNotDelivered`.
    function seedOf(bytes32 itemHash) external view returns (bytes32);
    /// @notice The latest request for the item's content: its ID (zero once the seed is
    ///         delivered) and when it was made.
    function requestOf(bytes32 itemHash)
        external
        view
        returns (uint256 requestId, uint64 requestedAt);
    /// @notice Seconds after the latest request before another may be added (at least 3 days).
    function retryDelay() external view returns (uint64);
    /// @notice The VRF coordinator.
    function coordinator() external view returns (address);
    /// @notice Sets the VRF coordinator (Chainlink migrations): code hash `nextCodeHash`, not an
    ///         EIP-7702 delegated account. SUCCESSOR_SETTER role (30-day class), compare-and-set.
    function setCoordinator(address expected, address next, bytes32 nextCodeHash) external;
}
