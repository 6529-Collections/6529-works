// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { Dependency } from "../libraries/Dependency.sol";
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
///      so a hostile token can only affect its own credits. The governed path, {recover}, moves a
///      split wallet's credit only to a replacement wallet with an identical payee configuration
///      (consent is trivially satisfied because the payees and shares are identical; ADR 0003),
///      the network's own credits (an account whose `authority()` is this escrow's, such as the
///      fee and museum vaults) wherever the network names (C19), and any other account's credit
///      only to the replacement that account named itself with {consentToRecovery}, each consent
///      covering one recovery. A credit nobody flushed for {UNCLAIMED_PERIOD} after it was last
///      added to moves to the network ({expire}, R12).
///      Funds force-sent or transferred here without a deposit are owed to nobody; only
///      {sweepExcess} moves them, and it can reach nothing beyond `balance - totalOwed` of the
///      asset it names. That bound is per token address: for a token with two addresses over one
///      balance, or one that rebases, see {IRevenueEscrow.sweepExcess}.
contract RevenueEscrow is IRevenueEscrow, AccessManaged, ReentrancyGuardTransient {
    /// @notice How long a credit stays its account's after it was last added to: 180 days. The
    ///         number is the guarantee (an unclaimed credit is its owner's for at least this
    ///         long), so it is compiled in and nothing changes it.
    uint256 public constant UNCLAIMED_PERIOD = 180 days;

    /// @inheritdoc IRevenueEscrow
    ISplitFactory public immutable factory;

    /// @inheritdoc IRevenueEscrow
    mapping(address wallet => mapping(address asset => uint256)) public owed;
    /// @inheritdoc IRevenueEscrow
    mapping(address asset => uint256) public totalOwed;
    /// @inheritdoc IRevenueEscrow
    mapping(address account => address replacement) public recoveryConsent;
    /// @inheritdoc IRevenueEscrow
    mapping(address wallet => mapping(address asset => uint48)) public creditedAt;

    /// @param authority The AccessManager governing {recover}.
    /// @param factory_ The split factory whose wallet configurations {recover} compares.
    constructor(address authority, ISplitFactory factory_) AccessManaged(authority) {
        Dependency.check(address(factory_));
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
        } else if (_isNetworks(wallet)) {
            // C19: the network moves its own credits without consent.
            if (replacement == address(0) || replacement == address(this) || replacement == wallet)
            {
                revert InvalidWallet(replacement);
            }
        } else {
            if (replacement == address(0) || recoveryConsent[wallet] != replacement) {
                revert RecoveryNotConsented(wallet, replacement);
            }
            // Single use: one consent covers one recovery of one asset.
            delete recoveryConsent[wallet];
        }
        uint256 amount = _take(wallet, asset);
        emit Recovered(wallet, replacement, asset, amount, _add(replacement, asset, amount));
    }

    /// @inheritdoc IRevenueEscrow
    function expire(address wallet, address asset) external nonReentrant returns (uint256 amount) {
        address network = factory.network();
        if (wallet == network) revert InvalidWallet(wallet);
        uint256 dueAt = uint256(creditedAt[wallet][asset]) + UNCLAIMED_PERIOD;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < dueAt) revert CreditNotExpired(wallet, asset, dueAt);
        amount = _take(wallet, asset);
        emit Expired(wallet, asset, network, amount, _add(network, asset, amount));
    }

    /// @inheritdoc IRevenueEscrow
    function sweepExcess(address asset, address recipient)
        external
        restricted
        nonReentrant
        returns (uint256 amount)
    {
        if (recipient == address(0) || recipient == address(this)) {
            revert InvalidWallet(recipient);
        }
        uint256 balance = asset == address(0)
            ? address(this).balance
            : TokenTransfer.balanceOf(asset, address(this));
        uint256 owedTotal = totalOwed[asset];
        if (balance <= owedTotal) revert NothingToSweep(asset);
        amount = balance - owedTotal;
        emit ExcessSwept(asset, recipient, amount);
        if (asset == address(0)) {
            if (!TokenTransfer.sendETH(recipient, amount, gasleft())) {
                revert ETHTransferFailed(recipient, amount);
            }
        } else {
            TokenTransfer.transferExactAllowingNoReturn(asset, recipient, amount);
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IRevenueEscrow).interfaceId
                || interfaceId == type(IERC165).interfaceId;
    }

    function _credit(address wallet, address asset, uint256 amount) private {
        totalOwed[asset] += amount;
        emit Credited(wallet, asset, msg.sender, amount, _add(wallet, asset, amount));
    }

    /// @dev Adds `amount` to `wallet`'s credit, restarts its clock and returns the new credit.
    function _add(address wallet, address asset, uint256 amount) private returns (uint256 balance) {
        balance = owed[wallet][asset] + amount;
        owed[wallet][asset] = balance;
        creditedAt[wallet][asset] = uint48(block.timestamp);
    }

    /// @dev Zeroes `wallet`'s credit in `asset` and returns it; reverts when there is none.
    function _take(address wallet, address asset) private returns (uint256 amount) {
        amount = owed[wallet][asset];
        if (amount == 0) revert NothingOwed(wallet, asset);
        owed[wallet][asset] = 0;
    }

    /// @dev Whether `account` is the network's own: a contract whose `authority()` is this
    ///      escrow's authority (the fee and museum vaults). The read forwards all gas; a
    ///      shortfall reverts (`BoundedCall`), and any other failure or answer is "no".
    function _isNetworks(address account) private view returns (bool) {
        (bool ok, bytes32 word) =
            BoundedCall.tryReadWordAll(account, abi.encodeCall(IAccessManaged.authority, ()));
        return ok && word == bytes32(uint256(uint160(authority())));
    }

    function _checkCredit(address wallet, uint256 amount) private view {
        if (wallet == address(0) || wallet == address(this)) revert InvalidWallet(wallet);
        if (amount == 0) revert ZeroAmount();
    }
}
