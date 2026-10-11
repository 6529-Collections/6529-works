// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { IArtistPayoutResolver } from "./interfaces/IArtistPayoutResolver.sol";
import { ISplitFactory } from "./interfaces/ISplitFactory.sol";
import { ISplitWallet } from "./interfaces/ISplitWallet.sol";
import { SplitWallet } from "./SplitWallet.sol";
import { Splits } from "./Splits.sol";

/// @title SplitFactory
/// @notice Deploys immutable split wallets (ADR 0001 section 7). The CREATE2 init code carries the
///         resolver and the canonical payee list as constructor arguments, so the address commits to
///         the whole configuration: no initializer, nothing to front-run, and funds sent to the
///         address before deployment are split once the wallet exists.
/// @dev Permissionless and unowned. Code at a predicted address can only be a wallet this factory
///      deployed with exactly those arguments, because only this factory can CREATE2 there.
contract SplitFactory is ISplitFactory {
    /// @inheritdoc ISplitFactory
    IArtistPayoutResolver public immutable resolver;

    /// @inheritdoc ISplitFactory
    mapping(address wallet => bool) public isWallet;

    /// @param resolver_ The artist payout resolver (the artist registry); it must have code.
    constructor(IArtistPayoutResolver resolver_) {
        if (address(resolver_).code.length == 0) revert InvalidResolver(address(resolver_));
        resolver = resolver_;
    }

    /// @inheritdoc ISplitFactory
    function createWallet(ISplitWallet.Payee[] calldata payees) external returns (address wallet) {
        wallet = walletFor(payees);
        if (wallet.code.length != 0) return wallet;
        new SplitWallet{ salt: bytes32(0) }(resolver, payees);
        isWallet[wallet] = true;
        emit WalletCreated(wallet, keccak256(abi.encode(payees)), payees);
    }

    /// @inheritdoc ISplitFactory
    function walletFor(ISplitWallet.Payee[] calldata payees) public view returns (address) {
        Splits.validate(payees);
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(SplitWallet).creationCode, abi.encode(resolver, payees))
        );
        return Create2.computeAddress(bytes32(0), initCodeHash);
    }
}
