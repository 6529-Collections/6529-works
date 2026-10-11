// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVRFCoordinatorV2Plus
/// @notice The one function of the Chainlink VRF v2.5 coordinator that the entropy module calls,
///         declared locally so the repository has no Chainlink dependency.
/// @dev The ABI is the `requestRandomWords` of Chainlink contracts v1.3.0
///      (`IVRFCoordinatorV2Plus` with `VRFV2PlusClient.RandomWordsRequest`). The coordinator
///      delivers the result by calling `rawFulfillRandomWords(uint256, uint256[])` on the
///      requester, the unchanged callback selector of every VRF generation.
interface IVRFCoordinatorV2Plus {
    /// @notice A randomness request.
    /// @param keyHash The gas lane: the oracle key to use.
    /// @param subId The funded subscription that pays (a uint256 in VRF v2.5).
    /// @param requestConfirmations Blocks to wait before the oracle answers.
    /// @param callbackGasLimit Gas forwarded to the requester's callback.
    /// @param numWords How many random words to deliver.
    /// @param extraArgs `abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")),
    ///        nativePayment)`: whether the subscription pays in native currency instead of LINK.
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    /// @notice Requests random words for the caller, which must be a consumer of `subId`.
    /// @param req The request.
    /// @return requestId The coordinator's ID for the request.
    function requestRandomWords(RandomWordsRequest calldata req)
        external
        returns (uint256 requestId);
}
