// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";
import { IReleaseVerifier } from "./interfaces/IReleaseVerifier.sol";

/// @title ReleaseVerifier
/// @notice The singleton verifier for signed split-wallet releases (ADR 0001 section 7). An
///         authorization binds the wallet, asset, payee, account, recipient, amount, nonce and
///         deadline; the EIP-712 domain binds the chain. Nonces are unordered, single use and
///         stored per account across all wallets, so one revocation covers every wallet. They
///         are kept in a bitmap, 256 to a storage word, as the statement log keeps its own: a
///         payee who signs nonces in order writes one new slot per 256 releases, not one each.
/// @dev Unowned and immutable; split wallets pin it at deployment. Signatures go through the
///      shared `SignatureVerifier` (low-s ECDSA, ERC-2098, EIP-7702 delegated accounts, gas-capped
///      ERC-1271), so smart accounts can sign. Replay protection is keyed on `(account, nonce)`,
///      never on signature bytes. The only external call is the ERC-1271 `staticcall`.
contract ReleaseVerifier is IReleaseVerifier, EIP712 {
    /// @notice The EIP-712 type hash of {IReleaseVerifier.Authorization}.
    bytes32 public constant RELEASE_TYPEHASH = keccak256(
        "ReleaseAuthorization(address wallet,address asset,uint256 payee,address account,address recipient,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    /// @dev Bit `nonce % 256` of word `nonce / 256` is set once `account` used `nonce`.
    mapping(address account => mapping(uint256 word => uint256 bits)) private _nonceBitmap;

    constructor() EIP712("6529 Works Release Verifier", "1") { }

    /// @inheritdoc IReleaseVerifier
    function consume(Authorization calldata authorization, bytes calldata signature) external {
        if (authorization.wallet != msg.sender) {
            revert WrongWallet(authorization.wallet, msg.sender);
        }
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

    /// @inheritdoc IReleaseVerifier
    function revokeNonce(uint256 nonce) external {
        _useNonce(msg.sender, nonce, true);
    }

    /// @inheritdoc IReleaseVerifier
    function nonceUsed(address account, uint256 nonce) external view returns (bool) {
        return _nonceBitmap[account][nonce >> 8] & _bit(nonce) != 0;
    }

    /// @inheritdoc IReleaseVerifier
    function releaseDigest(Authorization calldata authorization) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(RELEASE_TYPEHASH, authorization)));
    }

    /// @inheritdoc IReleaseVerifier
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _useNonce(address account, uint256 nonce, bool revoked) private {
        uint256 bit = _bit(nonce);
        uint256 bits = _nonceBitmap[account][nonce >> 8];
        if (bits & bit != 0) revert NonceAlreadyUsed(account, nonce);
        _nonceBitmap[account][nonce >> 8] = bits | bit;
        emit NonceUsed(account, nonce, revoked);
    }

    function _bit(uint256 nonce) private pure returns (uint256) {
        return uint256(1) << (nonce & 0xff);
    }
}
