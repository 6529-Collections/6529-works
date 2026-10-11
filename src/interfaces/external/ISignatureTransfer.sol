// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISignatureTransfer
/// @notice The one Permit2 entry point the shared sale adapters call: a signature transfer whose
///         witness binds the bid or purchase, so a relayer can submit a payer's signed payment
///         intent (ADR 0001 sections 5 and 6). Permit2 is Uniswap's canonical deployment,
///         `0x000000000022D473030F116dDEE9F6B43aC78BA3` on Ethereum and Sepolia.
/// @dev An exact subset of Permit2's `ISignatureTransfer`. Permit2 checks the deadline, the
///      requested amount against the permitted amount, the signature and its unordered nonce
///      bitmap, then pulls the tokens; the spender in the signed hash is the calling adapter.
interface ISignatureTransfer {
    /// @notice The token and the maximum amount the signer permits.
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    /// @notice The signed permit: permissions, an unordered nonce and a deadline.
    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice Where the tokens go and how many the spender takes (at most the permitted amount).
    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    /// @notice Transfers `transferDetails.requestedAmount` from `owner` under a signature over
    ///         the permit, the calling spender and `witness`, typed by `witnessTypeString`.
    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;
}
