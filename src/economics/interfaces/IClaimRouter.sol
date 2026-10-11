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

    /// @notice In atomic mode, item `index` failed and the whole batch reverted.
    error ClaimCallFailed(uint256 index, address wallet, uint256 size, bytes reason);
    /// @notice The claim target has no code.
    error ClaimTargetHasNoCode(address wallet);
    /// @notice The wallet succeeded but returned `size` bytes instead of one word.
    error InvalidClaimReturnData(uint256 size);

    /// @notice Releases every claim in order. In atomic mode any failure reverts the batch; in
    ///         continue mode a failed item emits {ClaimFailed}, releases 0 and the batch goes on.
    /// @return amounts The amount each item released.
    function claim(Claim[] calldata claims, bool continueOnFailure)
        external
        returns (uint256[] memory amounts);
}
