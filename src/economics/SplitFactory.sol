// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { IArtistPayoutResolver } from "./interfaces/IArtistPayoutResolver.sol";
import { IReleaseVerifier } from "./interfaces/IReleaseVerifier.sol";
import { ISplitFactory } from "./interfaces/ISplitFactory.sol";
import { ISplitWallet } from "./interfaces/ISplitWallet.sol";
import { SplitWallet } from "./SplitWallet.sol";
import { Splits } from "./Splits.sol";

/// @title SplitFactory
/// @notice Deploys immutable split wallets (ADR 0001 section 7). The CREATE2 init code carries the
///         resolver, the verifier and the canonical payee list as constructor arguments, so the
///         address commits to the whole configuration: no initializer, nothing to front-run, and
///         funds sent to the address before deployment are split once the wallet exists.
/// @dev Permissionless and unowned. Code at a predicted address can only be a wallet this factory
///      deployed with exactly those arguments, because only this factory can CREATE2 there. The
///      resolver and verifier are pinned at installation (code present, not EIP-7702 delegated,
///      code hash recorded) and rechecked before every deployment (ADR 0001 section 13.6).
contract SplitFactory is ISplitFactory {
    /// @inheritdoc ISplitFactory
    IArtistPayoutResolver public immutable resolver;
    /// @inheritdoc ISplitFactory
    bytes32 public immutable resolverCodeHash;
    /// @inheritdoc ISplitFactory
    IReleaseVerifier public immutable verifier;
    /// @inheritdoc ISplitFactory
    bytes32 public immutable verifierCodeHash;

    /// @inheritdoc ISplitFactory
    mapping(address wallet => bytes32) public configOf;

    /// @param resolver_ The artist payout resolver (the artist registry).
    /// @param verifier_ The singleton release verifier.
    constructor(IArtistPayoutResolver resolver_, IReleaseVerifier verifier_) {
        resolver = resolver_;
        resolverCodeHash = _pin(address(resolver_));
        verifier = verifier_;
        verifierCodeHash = _pin(address(verifier_));
    }

    /// @inheritdoc ISplitFactory
    /// @dev The wallet constructor validates `payees`, so an invalid list reverts on deployment.
    function createWallet(ISplitWallet.Payee[] calldata payees, bytes32 salt)
        external
        returns (address wallet)
    {
        wallet = _predict(payees, salt);
        if (wallet.code.length != 0) return wallet;
        if (address(resolver).codehash != resolverCodeHash) {
            revert DependencyCodeChanged(address(resolver));
        }
        if (address(verifier).codehash != verifierCodeHash) {
            revert DependencyCodeChanged(address(verifier));
        }
        new SplitWallet{ salt: salt }(resolver, verifier, payees);
        bytes32 configHash = keccak256(abi.encode(payees));
        configOf[wallet] = configHash;
        emit WalletCreated(wallet, configHash, salt, payees);
    }

    /// @inheritdoc ISplitFactory
    function isWallet(address wallet) external view returns (bool) {
        return configOf[wallet] != bytes32(0);
    }

    /// @inheritdoc ISplitFactory
    function walletFor(ISplitWallet.Payee[] calldata payees, bytes32 salt)
        external
        view
        returns (address)
    {
        Splits.validate(payees);
        return _predict(payees, salt);
    }

    function _predict(ISplitWallet.Payee[] calldata payees, bytes32 salt)
        private
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(SplitWallet).creationCode, abi.encode(resolver, verifier, payees))
        );
        return Create2.computeAddress(salt, initCodeHash);
    }

    function _pin(address dependency) private view returns (bytes32) {
        if (dependency.code.length == 0 || DelegatedEOA.isDelegated(dependency)) {
            revert InvalidDependency(dependency);
        }
        return dependency.codehash;
    }
}
