// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC5267 } from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";
import { ISplitWallet } from "./interfaces/ISplitWallet.sol";

/// @title ReleaseAuthorization
/// @notice Signed releases for split wallets (ADR 0001 section 7, "signed release authorization").
///         An authorization binds the asset, payee, account, recipient, amount, nonce and deadline;
///         the EIP-712 domain binds the chain and the wallet. Nonces are unordered, stored per
///         account, and single use; an account can revoke an unused one.
/// @dev Signatures go through the shared `SignatureVerifier` (low-s ECDSA, ERC-2098, EIP-7702
///      delegated accounts, gas-capped ERC-1271). Replay protection is keyed on the nonce, never on
///      signature bytes.
abstract contract ReleaseAuthorization is ISplitWallet, IERC5267, ReentrancyGuardTransient {
    /// @notice The EIP-712 type hash of {ISplitWallet.Authorization}.
    bytes32 public constant RELEASE_TYPEHASH = keccak256(
        "ReleaseAuthorization(address asset,uint256 payee,address account,address recipient,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant _NAME_HASH = keccak256("6529 Works Split Wallet");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    /// @inheritdoc ISplitWallet
    mapping(address account => mapping(uint256 nonce => bool)) public nonceUsed;

    /// @inheritdoc ISplitWallet
    function revokeNonce(uint256 nonce) external nonReentrant {
        _useNonce(msg.sender, nonce, true);
    }

    /// @inheritdoc ISplitWallet
    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this))
        );
    }

    /// @inheritdoc ISplitWallet
    function releaseDigest(Authorization calldata authorization) public view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(
            domainSeparator(), keccak256(abi.encode(RELEASE_TYPEHASH, authorization))
        );
    }

    /// @inheritdoc IERC5267
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (
            hex"0f",
            "6529 Works Split Wallet",
            "1",
            block.chainid,
            address(this),
            bytes32(0),
            new uint256[](0)
        );
    }

    /// @dev Checks the deadline and the signature, then consumes the nonce. The caller checks that
    ///      `authorization.account` is the payee's current payout address.
    function _useAuthorization(Authorization calldata authorization, bytes calldata signature)
        internal
    {
        // Deadlines are coarse (minutes or more); validator timestamp drift is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > authorization.deadline) {
            revert AuthorizationExpired(authorization.deadline);
        }
        if (!SignatureVerifier.isValid(
                authorization.account, releaseDigest(authorization), signature
            )) {
            revert InvalidSignature(authorization.account);
        }
        _useNonce(authorization.account, authorization.nonce, false);
    }

    function _useNonce(address account, uint256 nonce, bool revoked) private {
        if (nonceUsed[account][nonce]) revert NonceAlreadyUsed(account, nonce);
        nonceUsed[account][nonce] = true;
        emit NonceUsed(account, nonce, revoked);
    }
}
