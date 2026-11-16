// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVRFV2PlusWrapper
/// @notice The two functions of the Chainlink VRF v2.5 wrapper (direct funding) that the entropy
///         module calls for a federated work's seed, declared locally so the repository has no
///         Chainlink dependency.
/// @dev The ABI is `VRFV2PlusWrapper` of Chainlink contracts v1.3.0. The requester pays the
///      wrapper's own quoted price, in native currency, with the request; no subscription is
///      used. The wrapper delivers the result by calling `rawFulfillRandomWords(uint256,
///      uint256[])` on the requester, the same callback selector as the coordinator's.
interface IVRFV2PlusWrapper {
    /// @notice The native price of a request at the current transaction's gas price.
    /// @param callbackGasLimit Gas forwarded to the requester's callback.
    /// @param numWords How many random words to deliver.
    /// @return The price in wei.
    function calculateRequestPriceNative(uint32 callbackGasLimit, uint32 numWords)
        external
        view
        returns (uint256);

    /// @notice Requests random words, paid in native currency with the call (at least the
    ///         quoted price; the wrapper keeps what is sent).
    /// @param callbackGasLimit Gas forwarded to the requester's callback.
    /// @param requestConfirmations Blocks to wait before the oracle answers.
    /// @param numWords How many random words to deliver.
    /// @param extraArgs `abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true)`.
    /// @return requestId The ID of the request.
    function requestRandomWordsInNative(
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        uint32 numWords,
        bytes calldata extraArgs
    ) external payable returns (uint256 requestId);
}
