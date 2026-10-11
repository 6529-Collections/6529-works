// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { PackageItem } from "./types/PackageTypes.sol";

/// @title IEntropyModule
/// @notice The optional VRF module for seeded 1/1s, revealed before any sale starts (ADR 0001
///         section 9).
/// @dev Entropy is never in Core's mint path. Seeds are keyed by item hash and requested before
///      any token exists: the auction's start (through 6529 Stream's `mint`) requires
///      `isDelivered(itemHash)` for a VRF item, and `IStream.seedOf` reads `seedOf(itemHash)`, so
///      nothing ever sits in sale custody waiting for randomness. The VRF fulfillment stores the
///      seed here, with no callback into any token or adapter. Anyone may request, for an item
///      of an approved package that is not yet consumed and whose seed policy is VRF (checked
///      against the package registry), which keeps the subscription safe from spam; a request
///      still undelivered after `retryDelay()` may be repeated by anyone and supersedes the
///      previous one. Seeds are permanent.
interface IEntropyModule is IERC165 {
    /// @notice A seed was requested for the item.
    event SeedRequested(bytes32 indexed itemHash, uint256 requestId);
    /// @notice A seed was delivered.
    event SeedDelivered(bytes32 indexed itemHash, uint256 requestId, bytes32 seed);
    /// @notice The VRF coordinator changed.
    event CoordinatorSet(address previous, address next);

    /// @notice The item is not in an approved package, is already consumed, or is not VRF.
    error NotRequestable(bytes32 itemHash);
    /// @notice The seed was already delivered.
    error SeedAlreadyDelivered(bytes32 itemHash);
    /// @notice A request is outstanding and may be repeated only from `retryAt`.
    error RequestPending(bytes32 itemHash, uint64 retryAt);
    /// @notice No seed has been delivered yet.
    error SeedNotDelivered(bytes32 itemHash);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();

    /// @notice Requests the seed of an approved, unconsumed VRF item, or repeats a request still
    ///         undelivered after `retryDelay()`, superseding it. Permissionless.
    function requestSeed(PackageItem calldata item, bytes32 packageRoot, bytes32[] calldata proof)
        external
        returns (uint256 requestId);
    /// @notice Whether the item's seed was delivered.
    function isDelivered(bytes32 itemHash) external view returns (bool);
    /// @notice The delivered seed. Reverts with `SeedNotDelivered`.
    function seedOf(bytes32 itemHash) external view returns (bytes32);
    /// @notice The outstanding or last request: its ID and when it was made.
    function requestOf(bytes32 itemHash)
        external
        view
        returns (uint256 requestId, uint64 requestedAt);
    /// @notice Seconds after which an undelivered request may be repeated.
    function retryDelay() external view returns (uint64);
    /// @notice The VRF coordinator.
    function coordinator() external view returns (address);
    /// @notice Sets the VRF coordinator (Chainlink migrations). SUCCESSOR_SETTER role (30-day
    ///         class), compare-and-set.
    function setCoordinator(address expected, address next) external;
}
