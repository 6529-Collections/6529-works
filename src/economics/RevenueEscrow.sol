// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { IRevenueEscrow } from "./interfaces/IRevenueEscrow.sol";
import { ISplitFactory } from "./interfaces/ISplitFactory.sol";
import { TokenTransfer } from "./TokenTransfer.sol";

/// @title RevenueEscrow
/// @notice The escrow fallback for wallet payments (ADR 0001 sections 5 and 7). When a payer cannot
///         deliver to a wallet (for example a token blocks the wallet, as USDC can), it credits the
///         escrow instead, so the sale still settles. Anyone may flush a credit to the wallet it
///         was made for.
/// @dev Crediting and flushing are permissionless and never consult the asset allowlist: a credit
///      is backed by funds that arrived by exact balance delta, and credits are isolated per asset,
///      so a hostile token can only affect its own credits. The one governed path, {recover},
///      needs the consent ADR 0001 section 7 requires. A split wallet's credit moves only to a
///      replacement wallet with an identical payee configuration, where consent is trivially
///      satisfied because the payees and shares are identical (recorded in ADR 0003). Any other
///      account's credit, such as the network fee recipient's, moves only to the replacement that
///      account named itself with {consentToRecovery}, and each consent covers one recovery.
///      Funds force-sent or transferred here without a deposit are never owed to anyone and stay
///      put.
contract RevenueEscrow is IRevenueEscrow, AccessManaged, ReentrancyGuardTransient {
    /// @inheritdoc IRevenueEscrow
    ISplitFactory public immutable factory;

    /// @inheritdoc IRevenueEscrow
    mapping(address wallet => mapping(address asset => uint256)) public owed;
    /// @inheritdoc IRevenueEscrow
    mapping(address asset => uint256) public totalOwed;
    /// @inheritdoc IRevenueEscrow
    mapping(address account => address replacement) public recoveryConsent;

    /// @param authority The AccessManager governing {recover}.
    /// @param factory_ The split factory whose wallet configurations {recover} compares.
    constructor(address authority, ISplitFactory factory_) AccessManaged(authority) {
        if (address(factory_).code.length == 0 || DelegatedEOA.isDelegated(address(factory_))) {
            revert InvalidFactory(address(factory_));
        }
        factory = factory_;
    }

    /// @inheritdoc IRevenueEscrow
    function depositETH(address wallet) external payable nonReentrant {
        _checkCredit(wallet, msg.value);
        _credit(wallet, address(0), msg.value);
    }

    /// @inheritdoc IRevenueEscrow
    function depositERC20(address wallet, address asset, uint256 amount) external nonReentrant {
        if (asset == address(0)) revert InvalidAsset(asset);
        _checkCredit(wallet, amount);
        TokenTransfer.pullExact(asset, msg.sender, amount);
        _credit(wallet, asset, amount);
    }

    /// @inheritdoc IRevenueEscrow
    function flush(address wallet, address asset) external nonReentrant returns (uint256 amount) {
        amount = owed[wallet][asset];
        if (amount == 0) revert NothingOwed(wallet, asset);
        owed[wallet][asset] = 0;
        totalOwed[asset] -= amount;
        emit Flushed(wallet, asset, msg.sender, amount);
        if (asset == address(0)) {
            if (!TokenTransfer.sendETH(wallet, amount, gasleft())) {
                revert ETHTransferFailed(wallet, amount);
            }
        } else {
            TokenTransfer.transferExact(asset, wallet, amount);
        }
    }

    /// @inheritdoc IRevenueEscrow
    function consentToRecovery(address replacement) external {
        if (replacement == address(this) || replacement == msg.sender) {
            revert InvalidWallet(replacement);
        }
        recoveryConsent[msg.sender] = replacement;
        emit RecoveryConsentSet(msg.sender, replacement);
    }

    /// @inheritdoc IRevenueEscrow
    function recover(address wallet, address replacement, address asset)
        external
        restricted
        nonReentrant
    {
        bytes32 config = factory.configOf(wallet);
        if (config != bytes32(0)) {
            if (replacement == wallet || factory.configOf(replacement) != config) {
                revert NotEquivalentWallet(wallet, replacement);
            }
        } else {
            if (replacement == address(0) || recoveryConsent[wallet] != replacement) {
                revert RecoveryNotConsented(wallet, replacement);
            }
            // Single use: one consent covers one recovery of one asset.
            delete recoveryConsent[wallet];
        }
        uint256 amount = owed[wallet][asset];
        if (amount == 0) revert NothingOwed(wallet, asset);
        owed[wallet][asset] = 0;
        uint256 balance = owed[replacement][asset] + amount;
        owed[replacement][asset] = balance;
        emit Recovered(wallet, replacement, asset, amount, balance);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IRevenueEscrow).interfaceId
                || interfaceId == type(IERC165).interfaceId;
    }

    function _credit(address wallet, address asset, uint256 amount) private {
        uint256 balance = owed[wallet][asset] + amount;
        owed[wallet][asset] = balance;
        totalOwed[asset] += amount;
        emit Credited(wallet, asset, msg.sender, amount, balance);
    }

    function _checkCredit(address wallet, uint256 amount) private view {
        if (wallet == address(0) || wallet == address(this)) revert InvalidWallet(wallet);
        if (amount == 0) revert ZeroAmount();
    }
}
