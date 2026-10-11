// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEntropyModule
/// @notice The optional VRF module for seeded 1/1s revealed before bidding (ADR 0001 section 9).
/// @dev Entropy is never in Core's mint path. The auction's start calls `request` for a work whose
///      seed policy is VRF; the VRF fulfillment stores the seed here (no callback into the token
///      or the auction), and the auction's `activate` starts the clock once `isDelivered`.
///      Seeds are stored permanently and are the source `IStream.seedOf` reads for VRF works.
///      A request that has not been fulfilled after `retryDelay()` may be requested again. The
///      VRF coordinator and subscription are internal, governed configuration.
interface IEntropyModule {
    /// @notice A seed was requested for `(token, tokenId)`.
    event SeedRequested(address indexed token, uint256 indexed tokenId, uint256 requestId);
    /// @notice A seed was delivered.
    event SeedDelivered(
        address indexed token, uint256 indexed tokenId, uint256 requestId, bytes32 seed
    );

    /// @notice The token is not admitted, or the work's seed policy is not VRF.
    error NotVrfWork(address token, uint256 tokenId);
    /// @notice The seed was already delivered.
    error SeedAlreadyDelivered(address token, uint256 tokenId);
    /// @notice A request is outstanding and may be repeated only from `retryAt`.
    error RequestPending(address token, uint256 tokenId, uint64 retryAt);
    /// @notice No seed has been delivered yet.
    error SeedNotDelivered(address token, uint256 tokenId);

    /// @notice Requests the seed of a VRF work. Permissionless.
    function request(address token, uint256 tokenId) external returns (uint256 requestId);
    /// @notice Whether the seed was delivered.
    function isDelivered(address token, uint256 tokenId) external view returns (bool);
    /// @notice The delivered seed. Reverts with `SeedNotDelivered`.
    function seedOf(address token, uint256 tokenId) external view returns (bytes32);
    /// @notice The outstanding or last request: its ID and when it was made.
    function requestOf(address token, uint256 tokenId)
        external
        view
        returns (uint256 requestId, uint64 requestedAt);
    /// @notice Seconds after which an unfulfilled request may be repeated.
    function retryDelay() external view returns (uint64);
}
