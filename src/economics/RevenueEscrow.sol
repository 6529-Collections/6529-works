// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IDirectory } from "../interfaces/core/IDirectory.sol";
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
///      fee and museum vaults) wherever the network names, and any other account's credit
///      only to the replacement that account named itself with {consentToRecovery}, each consent
///      covering one recovery.
///
///      Expiry (ECO-45). The wait is the unclaimed period, the network's setting
///      (`IDirectory.unclaimedPeriod`, 180 days at launch), read from the split factory's resolver
///      (the `Directory`) whenever the escrow ages a credit: at every deposit (the depositee's
///      credit), recovery (the replacement's credit), expiry (the expired account's credit, and
///      the fee vault's as it is credited), and in the view {expirableAt}. A flush takes the
///      whole credit and reads no period. If that read fails, the call reverts and the money
///      stays.
///      Every amount credited to an account stays that account's at least for the period in
///      force from the block it was credited in, and may move to the network ({expire}) less
///      than twice that after it. Credits are grouped in windows: a credit to an account and
///      asset with no open window opens one; the window takes every credit for one period, and
///      all of its credits may move once a period has passed since its last one. Guarantees,
///      whoever deposits and whenever (P is the period in force when the escrow looks):
///      - no amount can move sooner than P after it was credited;
///      - a credit made when an amount is already P old never joins that amount's window, so
///        nothing anyone does moves the time from which such an amount may expire;
///      - a credit into an open window (all of whose credits are younger than P) delays that
///        window's credits by at most the rest of the window, never past 2P from each.
///      The bound, exactly: a window takes credits for P from its first credit and is due P
///      after its last one, so its due time is at least P and less than 2P after its first
///      credit. Anyone may deposit into an open window, the account's payers and strangers
///      alike; such a deposit can move that window's due time later, never past that bound,
///      and never earlier. Money expires only after it has itself waited the period.
///      A change of the period applies to every amount not yet aged, including windows already
///      open or closed (their due time is computed from their last credit when the escrow
///      looks); an amount the escrow already aged under the period then in force stays aged.
///      Each of those writes stores what has aged by then, so whether a later change of the
///      period reaches an amount depends on the last write to that account and asset: an
///      amount that write found a period old stays aged (even if the period is raised after),
///      and an amount no write has aged yet takes the period in force when the escrow next
///      reads it. Anyone may cause such a write (a deposit to the account, or an expiry, which
///      pays only the network fee vault).
///      The amounts a window holds never change with the period: never money credited later.
///      A recovery counts as a new credit to its replacement. The network fee vault's credit
///      (`factory().network()`) never expires; any other account's, the museum vault's and other
///      network accounts' included, expires into the fee vault like anyone's. Storage: four
///      words per account and asset ({credits}); every change follows from
///      the logged deposits, flushes, recoveries and expiries and their block times.
///      Funds force-sent or transferred here without a deposit are owed to nobody; only
///      {sweepExcess} moves them, and it can reach nothing beyond `balance - totalOwed` of the
///      asset it names. That bound is per token address: for a token with two addresses over one
///      balance, or one that rebases, see {IRevenueEscrow.sweepExcess}.
contract RevenueEscrow is IRevenueEscrow, AccessManaged, ReentrancyGuardTransient {
    /// @dev An account's credit in one asset, in three parts that age oldest first. `aged` may
    ///      move to the network. `maturing` holds the credits of the last closed window and may
    ///      move one period after `maturingLastAt`, that window's last credit. `recent` holds the
    ///      open window's credits; the window opened at `openedAt`, closes one period later, and
    ///      last took a credit at `lastAt`. The stored parts are as of the last write; {_rolled}
    ///      ages them to any later time under the period in force.
    struct Credit {
        uint256 aged;
        uint256 maturing;
        uint256 recent;
        uint48 maturingLastAt;
        uint48 openedAt;
        uint48 lastAt;
    }

    /// @inheritdoc IRevenueEscrow
    ISplitFactory public immutable factory;

    /// @inheritdoc IRevenueEscrow
    mapping(address wallet => mapping(address asset => Credit)) public credits;
    /// @inheritdoc IRevenueEscrow
    mapping(address asset => uint256) public totalOwed;
    /// @inheritdoc IRevenueEscrow
    mapping(address account => address replacement) public recoveryConsent;

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
        amount = _take(wallet, asset);
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
        bool consentUsed;
        if (config != bytes32(0)) {
            if (replacement == wallet || factory.configOf(replacement) != config) {
                revert NotEquivalentWallet(wallet, replacement);
            }
        } else if (_isNetworks(wallet)) {
            // The network moves its own credits without consent.
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
            consentUsed = true;
        }
        uint256 amount = _take(wallet, asset);
        emit Recovered(
            wallet, replacement, asset, amount, _add(replacement, asset, amount), consentUsed
        );
    }

    /// @inheritdoc IRevenueEscrow
    function expire(address wallet, address asset) external nonReentrant returns (uint256 amount) {
        address network = factory.network();
        if (wallet == network) revert InvalidWallet(wallet);
        uint256 period = _period();
        Credit memory c = _rolled(wallet, asset, block.timestamp, period);
        amount = c.aged;
        if (amount == 0) {
            if (c.maturing == 0 && c.recent == 0) revert NothingOwed(wallet, asset);
            // `maturing` matures first: its window closed before the open one opened.
            revert CreditNotExpired(
                wallet, asset, (c.maturing != 0 ? c.maturingLastAt : c.lastAt) + period
            );
        }
        c.aged = 0;
        credits[wallet][asset] = c;
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

    /// @inheritdoc IRevenueEscrow
    function owed(address wallet, address asset) public view returns (uint256) {
        Credit storage c = credits[wallet][asset];
        return c.aged + c.maturing + c.recent;
    }

    /// @inheritdoc IRevenueEscrow
    function expirableAt(address wallet, address asset, uint256 time)
        external
        view
        returns (uint256)
    {
        if (wallet == factory.network()) return 0;
        // forge-lint: disable-next-line(block-timestamp)
        if (time < block.timestamp) time = block.timestamp;
        return _rolled(wallet, asset, time, _period()).aged;
    }

    /// @inheritdoc IRevenueEscrow
    function locked() external view returns (bool) {
        return _reentrancyGuardEntered();
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

    /// @dev Adds `amount` to `wallet`'s credit in `asset` as of this block and returns the whole
    ///      credit. The amount joins the open window, or opens one when there is none (none was
    ///      opened, or it has closed), so it never joins credits a period old.
    function _add(address wallet, address asset, uint256 amount) private returns (uint256 balance) {
        Credit memory c = _rolled(wallet, asset, block.timestamp, _period());
        // Safe: a block time fits 48 bits for millions of years.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 nowAt = uint48(block.timestamp);
        if (c.recent == 0) c.openedAt = nowAt;
        c.recent += amount;
        c.lastAt = nowAt;
        credits[wallet][asset] = c;
        balance = c.aged + c.maturing + c.recent;
    }

    /// @dev Zeroes `wallet`'s whole credit in `asset` and returns it; reverts when there is none.
    function _take(address wallet, address asset) private returns (uint256 amount) {
        amount = owed(wallet, asset);
        if (amount == 0) revert NothingOwed(wallet, asset);
        delete credits[wallet][asset];
    }

    /// @dev `wallet`'s credit in `asset` aged to `time`, which is no earlier than its last write,
    ///      under the unclaimed period `period`. A closed window's credits join `aged` one period
    ///      after its last credit (`maturingLastAt`). The open window closes one period after it
    ///      opened; its credits become `maturing`, due one period after its last credit, which
    ///      may already have passed. When the open window closes, `maturing` is always already
    ///      empty: it holds the window before, whose last credit came no later than the open
    ///      window opened (`maturingLastAt <= openedAt`, since a window opens only at a write
    ///      after the one before closed), and this one roll uses one period, so the first branch
    ///      aged it whenever the second applies. The addition therefore adds to zero; it is
    ///      written as an addition so no unit could ever be dropped.
    function _rolled(address wallet, address asset, uint256 time, uint256 period)
        private
        view
        returns (Credit memory c)
    {
        c = credits[wallet][asset];
        if (c.maturing != 0 && time >= c.maturingLastAt + period) {
            c.aged += c.maturing;
            c.maturing = 0;
        }
        if (c.recent != 0 && time >= c.openedAt + period) {
            c.maturing += c.recent;
            c.recent = 0;
            c.maturingLastAt = c.lastAt;
            if (time >= c.maturingLastAt + period) {
                c.aged += c.maturing;
                c.maturing = 0;
            }
        }
    }

    /// @dev The unclaimed period in force: a plain read of the split factory's resolver (the
    ///      `Directory`). If it fails, the calling deposit, recovery or expiry reverts.
    function _period() private view returns (uint256) {
        return IDirectory(address(factory.resolver())).unclaimedPeriod();
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
