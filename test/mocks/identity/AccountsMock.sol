// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { IAccounts } from "src/interfaces/IAccounts.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";

/// @notice A settable `IAccounts` for tests of contracts that read accounts. Wallets, the freeze,
///         the delisting and the federated fee share are plain setters; `requireSigned` really
///         verifies the signature (ECDSA or ERC-1271) with the shared `SignatureVerifier`. An
///         account with no wallets set is its own single wallet, as for an unregistered account.
contract AccountsMock is IAccounts, EIP712 {
    /// @notice The EIP-712 type of a consent (`Typehashes.ACCOUNT_CONSENT`).
    bytes32 public constant CONSENT_TYPEHASH = Typehashes.ACCOUNT_CONSENT;

    /// @notice Whether the account wallet list was set: when false the account is its own wallet.
    mapping(uint256 accountId => bool) public registered;
    mapping(uint256 accountId => mapping(address wallet => bool)) private _wallets;
    mapping(uint256 accountId => uint48) private _frozenUntil;
    mapping(uint256 accountId => bool) private _delisted;
    mapping(address token => uint32) private _feeShare;

    /// @dev The artist registry's EIP-712 domain name and version (at this mock's address).
    constructor() EIP712(Typehashes.ARTIST_REGISTRY_NAME, Typehashes.DOMAIN_VERSION) { }

    /// @notice Sets whether `wallet` is a wallet of `accountId` (and marks the account registered).
    function setWallet(uint256 accountId, address wallet, bool isIt) external {
        registered[accountId] = true;
        _wallets[accountId][wallet] = isIt;
    }

    /// @notice Freezes `accountId` until `until` (zero unfreezes).
    function setFrozenUntil(uint256 accountId, uint48 until) external {
        _frozenUntil[accountId] = until;
    }

    /// @notice Freezes `accountId` with no end, or unfreezes it.
    function setFrozen(uint256 accountId, bool frozen) external {
        _frozenUntil[accountId] = frozen ? type(uint48).max : 0;
    }

    /// @notice Sets whether `accountId` is delisted from the federation.
    function setFederationDelisted(uint256 accountId, bool delisted) external {
        _delisted[accountId] = delisted;
    }

    /// @notice Sets the recorded federated fee share of `token`.
    function setFederatedFeeShare(address token, uint32 share) external {
        _feeShare[token] = share;
    }

    /// @inheritdoc IAccounts
    function isWallet(uint256 accountId, address wallet) public view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        if (_frozenUntil[accountId] > block.timestamp) return false;
        if (!registered[accountId]) {
            return wallet != address(0) && uint256(uint160(wallet)) == accountId;
        }
        return _wallets[accountId][wallet];
    }

    /// @inheritdoc IAccounts
    function requireSigned(uint256 accountId, bytes32 digest, bytes calldata proof)
        public
        view
        returns (address wallet)
    {
        wallet = _requireSigned(accountId, digest, proof);
    }

    /// @inheritdoc IAccounts
    function requireConsent(uint256 accountId, bytes32 what, bytes calldata proof)
        external
        view
        returns (address wallet)
    {
        wallet = _requireSigned(accountId, consentDigest(msg.sender, what), proof);
    }

    /// @inheritdoc IAccounts
    function consentDigest(address subject, bytes32 what) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(CONSENT_TYPEHASH, subject, what)));
    }

    /// @inheritdoc IAccounts
    function frozenUntil(uint256 accountId) external view returns (uint48) {
        return _frozenUntil[accountId];
    }

    /// @inheritdoc IAccounts
    function isFederationDelisted(uint256 accountId) external view returns (bool) {
        return _delisted[accountId];
    }

    /// @inheritdoc IAccounts
    function federatedFeeShare(address token) external view returns (uint32) {
        return _feeShare[token];
    }

    /// @dev The proof is `abi.encodePacked(wallet, signature)`: 20 address bytes, then the rest.
    function _requireSigned(uint256 accountId, bytes32 digest, bytes calldata proof)
        private
        view
        returns (address wallet)
    {
        if (proof.length < 20) revert SignatureVerifier.InvalidSignature(address(0));
        wallet = address(bytes20(proof[:20]));
        if (!isWallet(accountId, wallet)) revert SignatureVerifier.InvalidSignature(wallet);
        SignatureVerifier.check(wallet, digest, proof[20:]);
    }
}
