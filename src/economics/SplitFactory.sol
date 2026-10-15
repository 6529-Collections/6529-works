// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { IArtistPayoutResolver } from "./interfaces/IArtistPayoutResolver.sol";
import { IReleaseVerifier } from "./interfaces/IReleaseVerifier.sol";
import { ISplitFactory } from "./interfaces/ISplitFactory.sol";
import { ISplitWallet } from "./interfaces/ISplitWallet.sol";
import { SplitWallet } from "./SplitWallet.sol";
import { Splits } from "./Splits.sol";

/// @title SplitFactory
/// @notice Deploys immutable split wallets (ADR 0001 section 7). Every wallet has the same CREATE2
///         init code (`walletInitCodeHash`); the CREATE2 salt is
///         `keccak256(abi.encode(keccak256(abi.encode(payees)), salt))`, and the factory fixes the
///         resolver and verifier. So the address commits to the whole configuration: no
///         initializer, nothing to front-run, and funds sent to the address before deployment are
///         split once the wallet exists.
/// @dev Permissionless and unowned. Code at a predicted address can only be a wallet this factory
///      deployed with exactly that payee list, because only this factory can CREATE2 there and it
///      derives the salt from the list it deploys. The wallet's constructor reads the list back
///      with {pendingPayees}, which the factory holds in transient storage during {createWallet}
///      only. A constant init code keeps prediction cheap: {walletFor} hashes a few words, not the
///      wallet's creation code, on every start and every `royaltyInfo`. The resolver and verifier
///      are pinned at installation (code present, not EIP-7702 delegated, code hash recorded) and
///      rechecked before every deployment (ADR 0001 section 13.6).
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
    bytes32 public immutable walletInitCodeHash;

    /// @inheritdoc ISplitFactory
    mapping(address wallet => bytes32) public configOf;

    /// @dev The transient slot holding the pending payee count; payee `i`'s `artistId` and its
    ///      packed `account | share << 160` follow at `+ 1 + 2i` and `+ 2 + 2i`.
    ///      `keccak256("6529works.SplitFactory.pendingPayees")`.
    bytes32 private constant _PENDING =
        0x602a15ccc3efeba81089c44d5e87274e38b694ed83abb516822d4adb6c4f57d5;

    /// @param resolver_ The artist payout resolver (the artist registry).
    /// @param verifier_ The singleton release verifier.
    constructor(IArtistPayoutResolver resolver_, IReleaseVerifier verifier_) {
        resolver = resolver_;
        resolverCodeHash = _pin(address(resolver_));
        verifier = verifier_;
        verifierCodeHash = _pin(address(verifier_));
        walletInitCodeHash = keccak256(type(SplitWallet).creationCode);
    }

    /// @inheritdoc ISplitFactory
    /// @dev The wallet constructor validates `payees`, so an invalid list reverts on deployment.
    function createWallet(ISplitWallet.Payee[] calldata payees, bytes32 salt)
        external
        returns (address wallet)
    {
        bytes32 configHash = keccak256(abi.encode(payees));
        bytes32 walletSalt = _walletSalt(configHash, salt);
        wallet = Create2.computeAddress(walletSalt, walletInitCodeHash);
        if (wallet.code.length != 0) return wallet;
        Dependency.checkUnchanged(address(resolver), resolverCodeHash);
        Dependency.checkUnchanged(address(verifier), verifierCodeHash);
        _setPending(payees);
        address deployed = address(new SplitWallet{ salt: walletSalt }());
        if (deployed != wallet) revert WalletAddressMismatch(wallet, deployed);
        assembly ("memory-safe") {
            tstore(_PENDING, 0)
        }
        configOf[wallet] = configHash;
        emit WalletCreated(wallet, configHash, salt, payees);
    }

    /// @inheritdoc ISplitFactory
    function pendingPayees() external view returns (ISplitWallet.Payee[] memory payees) {
        uint256 count;
        assembly ("memory-safe") {
            count := tload(_PENDING)
        }
        payees = new ISplitWallet.Payee[](count);
        for (uint256 i; i < count; ++i) {
            uint256 artistId;
            uint256 packed;
            assembly ("memory-safe") {
                let slot := add(_PENDING, add(1, mul(2, i)))
                artistId := tload(slot)
                packed := tload(add(slot, 1))
            }
            // `_setPending` packed an address into the low 160 bits and a uint32 above them, so
            // both truncations recover exactly what it wrote.
            // forge-lint: disable-next-line(unsafe-typecast)
            address account = address(uint160(packed));
            // forge-lint: disable-next-line(unsafe-typecast)
            uint32 share = uint32(packed >> 160);
            payees[i] = ISplitWallet.Payee(artistId, account, share);
        }
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
        return Create2.computeAddress(
            _walletSalt(keccak256(abi.encode(payees)), salt), walletInitCodeHash
        );
    }

    /// @dev The CREATE2 salt: the payee configuration hash and the caller's salt.
    function _walletSalt(bytes32 configHash, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(configHash, salt));
    }

    /// @dev Holds `payees` in transient storage for the wallet's constructor ({pendingPayees}).
    function _setPending(ISplitWallet.Payee[] calldata payees) private {
        uint256 count = payees.length;
        assembly ("memory-safe") {
            tstore(_PENDING, count)
        }
        for (uint256 i; i < count; ++i) {
            ISplitWallet.Payee calldata p = payees[i];
            uint256 artistId = p.artistId;
            uint256 packed = uint256(uint160(p.account)) | (uint256(p.share) << 160);
            assembly ("memory-safe") {
                let slot := add(_PENDING, add(1, mul(2, i)))
                tstore(slot, artistId)
                tstore(add(slot, 1), packed)
            }
        }
    }

    function _pin(address dependency) private view returns (bytes32) {
        Dependency.check(dependency);
        return dependency.codehash;
    }
}
