// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IClaimRouter
/// @notice Stateless batch claims across split wallets (ADR 0001 section 7, "optional batch
///         claims"). Each item calls `ISplitWallet.release`, which pays only the payee's own payout
///         address, so the router can never redirect funds and never holds any.
interface IClaimRouter {
    /// @notice One release: payee `payee` of `wallet`, in `asset`.
    struct Claim {
        address wallet;
        address asset;
        uint256 payee;
    }

    /// @notice In continue mode, item `index` failed. `size` is the size of the data the wallet
    ///         returned, and `reason` is at most its first 256 bytes, or a router error.
    event ClaimFailed(
        address indexed wallet,
        address indexed asset,
        uint256 indexed payee,
        uint256 index,
        uint256 size,
        bytes reason
    );

    /// @notice The batch has `count` claims, more than {MAX_CLAIMS}.
    error TooManyClaims(uint256 count);
    /// @notice In continue mode, item `index` would get only `available` gas, less than
    ///         {MIN_ITEM_GAS}; the whole batch reverts so gas estimation raises the limit.
    error ClaimInsufficientGas(uint256 index, uint256 available);
    /// @notice In atomic mode, item `index` failed and the whole batch reverted.
    error ClaimCallFailed(uint256 index, address wallet, uint256 size, bytes reason);
    /// @notice The claim target has no code.
    error ClaimTargetHasNoCode(address wallet);
    /// @notice The wallet succeeded but returned `size` bytes instead of one word.
    error InvalidClaimReturnData(uint256 size);

    /// @notice The most claims one batch may carry, so a batch fits the EIP-7825 per-transaction
    ///         gas cap of 16,777,216.
    function MAX_CLAIMS() external view returns (uint256);

    /// @notice In continue mode, the least gas each item must be offered.
    function MIN_ITEM_GAS() external view returns (uint256);

    /// @notice Releases every claim in order. In atomic mode any failure reverts the batch; in
    ///         continue mode a failed item emits {ClaimFailed}, releases 0 and the batch goes on.
    /// @return amounts The amount each item released.
    function claim(Claim[] calldata claims, bool continueOnFailure)
        external
        returns (uint256[] memory amounts);
}
