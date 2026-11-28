// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitLedger } from "src/economics/interfaces/ISplitLedger.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { ReplayIndexer } from "./ReplayIndexer.sol";
import { CoreDirectoryIndexer } from "./StreamCoreIndexer.sol";

/// @notice Rebuilds the split ledger from its own logs (ECO-10 to ECO-22, ECO-44): every
///         wallet's configuration from `WalletCreated`, the released totals per payee and asset,
///         the recorded observed receipts of each ERC-20, the marks, and every spent or revoked
///         signed-release nonce.
/// @dev Money arriving in a wallet is not logged by the ledger (ECO-11), so `observed` and
///      `releasable`, which read the wallet's balance, are outside what the logs can rebuild and
///      are not compared; the docs say to read them from the views.
contract LedgerIndexer is ReplayIndexer {
    struct Mark {
        uint256 target;
        uint256 markedAt;
    }

    address[] internal _wallets;
    mapping(address wallet => bytes32) public configOf;
    mapping(address wallet => ISplitWallet.Payee[]) internal _payees;
    mapping(address wallet => bytes32) internal _salts;
    address[] internal _assets;
    mapping(address asset => bool) internal _knownAsset;
    mapping(address wallet => mapping(address asset => mapping(uint256 index => uint256))) internal
        _released;
    mapping(address wallet => mapping(address asset => uint256)) internal _totalReleased;
    mapping(address wallet => mapping(address asset => uint256)) internal _recordedObserved;
    mapping(address wallet => mapping(address asset => mapping(uint256 index => Mark))) internal
        _marks;
    address[] internal _nonceAccounts;
    uint256[] internal _nonces;
    mapping(address account => mapping(uint256 nonce => bool)) internal _used;
    /// @dev Accounts whose first `PROBED_NONCES` nonces are compared whether or not a log named
    ///      them, so a nonce spent with no `NonceUsed` is caught, not only a logged one.
    address[] internal _probes;
    uint256 private constant PROBED_NONCES = 32;

    constructor(address ledger_) ReplayIndexer(ledger_) {
        // ETH is compared for every wallet, so a release no log reports is caught.
        _asset(address(0));
    }

    /// @notice Also compare `account`'s first nonces, logged or not.
    function probe(address account) external {
        _probes.push(account);
    }

    function _apply(Vm.Log memory log) internal override {
        bytes32 sig = log.topics[0];
        if (sig == ISplitFactory.WalletCreated.selector) {
            address wallet = _addr(log.topics[1]);
            (bytes32 salt, ISplitWallet.Payee[] memory payees) =
                abi.decode(log.data, (bytes32, ISplitWallet.Payee[]));
            assertEq(keccak256(abi.encode(payees)), log.topics[2], "indexer: config hash");
            assertEq(_walletFor(target, payees, salt), wallet, "indexer: wallet address");
            _wallets.push(wallet);
            configOf[wallet] = log.topics[2];
            _salts[wallet] = salt;
            for (uint256 i; i < payees.length; ++i) {
                _payees[wallet].push(payees[i]);
            }
        } else if (sig == ISplitWallet.Released.selector) {
            address wallet = _addr(log.topics[1]);
            address asset = _addr(log.topics[2]);
            (uint256 payee,, uint256 amount, uint256 observed) =
                abi.decode(log.data, (uint256, address, uint256, uint256));
            require(configOf[wallet] != 0, "indexer: release from an unknown wallet");
            _asset(asset);
            _released[wallet][asset][payee] += amount;
            _totalReleased[wallet][asset] += amount;
            // The ledger records an ERC-20's observed receipts at each release (ECO-21 floor).
            if (asset != address(0)) _recordedObserved[wallet][asset] = observed;
        } else if (sig == ISplitLedger.Marked.selector) {
            (uint256 target_, uint256 markedAt) = abi.decode(log.data, (uint256, uint256));
            _asset(_addr(log.topics[2]));
            _marks[_addr(log.topics[1])][_addr(log.topics[2])][uint256(log.topics[3])] =
                Mark(target_, markedAt);
        } else if (sig == ISplitLedger.Forfeited.selector) {
            delete _marks[_addr(log.topics[1])][_addr(log.topics[2])][uint256(log.topics[3])];
        } else if (sig == IReleaseVerifier.NonceUsed.selector) {
            address account = _addr(log.topics[1]);
            uint256 nonce = uint256(log.topics[2]);
            assertFalse(_used[account][nonce], "indexer: nonce spent twice");
            _used[account][nonce] = true;
            _nonceAccounts.push(account);
            _nonces.push(nonce);
        } else {
            _unknown(sig);
        }
    }

    function _asset(address asset) private {
        if (_knownAsset[asset]) return;
        _knownAsset[asset] = true;
        _assets.push(asset);
    }

    function assertMatches() external view override {
        ISplitLedger l = ISplitLedger(target);
        for (uint256 w; w < _wallets.length; ++w) {
            address wallet = _wallets[w];
            assertEq(l.configOf(wallet), configOf[wallet], "configOf");
            assertTrue(l.isWallet(wallet), "isWallet");
            ISplitWallet.Payee[] memory payees = _payees[wallet];
            assertEq(l.walletFor(payees, _salts[wallet]), wallet, "walletFor");
            for (uint256 a; a < _assets.length; ++a) {
                address asset = _assets[a];
                assertEq(
                    l.totalReleased(wallet, asset), _totalReleased[wallet][asset], "totalReleased"
                );
                assertEq(
                    l.recordedObserved(wallet, asset),
                    _recordedObserved[wallet][asset],
                    "recordedObserved"
                );
                for (uint256 i; i < payees.length; ++i) {
                    assertEq(l.released(wallet, asset, i), _released[wallet][asset][i], "released");
                    (uint256 target_, uint256 markedAt) = l.markOf(wallet, asset, i);
                    assertEq(target_, _marks[wallet][asset][i].target, "markOf target");
                    assertEq(markedAt, _marks[wallet][asset][i].markedAt, "markOf markedAt");
                }
            }
        }
        for (uint256 i; i < _nonces.length; ++i) {
            assertTrue(l.nonceUsed(_nonceAccounts[i], _nonces[i]), "nonceUsed");
            // Nonces share 256-bit words: the neighbours the logs never spent stay unspent.
            uint256 next = _nonces[i] ^ 1;
            assertEq(
                l.nonceUsed(_nonceAccounts[i], next), _used[_nonceAccounts[i]][next], "nonceUsed"
            );
        }
        for (uint256 i; i < _probes.length; ++i) {
            for (uint256 n; n < PROBED_NONCES; ++n) {
                assertEq(l.nonceUsed(_probes[i], n), _used[_probes[i]][n], "nonceUsed (probed)");
            }
        }
    }
}

/// @notice Rebuilds the revenue escrow from its own logs (ECO-27, ECO-28, ECO-40, ECO-45): every
///         credit per wallet and asset in its three parts and their window times (`credits`),
///         `totalOwed` per asset, every recovery consent and the AccessManager. The parts age by
///         the escrow's rule at each logged change, from the log's block time, under the
///         unclaimed period the `StreamDirectory6529`'s own logs set (`UnclaimedPeriodSet`, kept by
///         the Directory indexer, never read from a contract), so they match the stored record.
/// @dev A recovery consumes the consent of an ordinary account only; for a split wallet and for
///      the network's own credit it leaves the consent as it is. `Recovered` says which case
///      applied (`consentUsed`), so the indexer clears a consent exactly when the log says so.
contract EscrowIndexer is ReplayIndexer {
    CoreDirectoryIndexer public immutable directoryIndexer;
    address public authority;
    address[] internal _wallets;
    mapping(address wallet => bool) internal _knownWallet;
    address[] internal _assets;
    mapping(address asset => bool) internal _knownAsset;

    /// @dev A credit as the escrow stores it: aged, maturing, recent, maturingLastAt, openedAt,
    ///      lastAt.
    struct Credit {
        uint256 aged;
        uint256 maturing;
        uint256 recent;
        uint256 maturingLastAt;
        uint256 openedAt;
        uint256 lastAt;
    }

    mapping(address wallet => mapping(address asset => Credit)) internal _credits;
    mapping(address asset => uint256) internal _totalOwed;
    address[] internal _consenters;
    mapping(address account => address) internal _consent;

    constructor(address escrow_, CoreDirectoryIndexer directoryIndexer_) ReplayIndexer(escrow_) {
        directoryIndexer = directoryIndexer_;
    }

    /// @notice Also compare `account`'s ETH credit, clock and recovery consent, whether or not
    ///         a log named it, so a change with no log is caught, not only a logged one.
    function probe(address account) external {
        _track(bytes32(uint256(uint160(account))), bytes32(0));
        _consenters.push(account);
    }

    function _apply(Vm.Log memory log) internal override {
        bytes32 sig = log.topics[0];
        if (sig == IRevenueEscrow.Credited.selector) {
            (uint256 amount, uint256 owed) = abi.decode(log.data, (uint256, uint256));
            _totalOwed[_track(log.topics[1], log.topics[2])] += amount;
            _set(_addr(log.topics[1]), _addr(log.topics[2]), owed, amount);
        } else if (sig == IRevenueEscrow.Flushed.selector) {
            address asset = _track(log.topics[1], log.topics[2]);
            uint256 amount = abi.decode(log.data, (uint256));
            assertEq(amount, _owedOf(_addr(log.topics[1]), asset), "indexer: flushed amount");
            delete _credits[_addr(log.topics[1])][asset];
            _totalOwed[asset] -= amount;
        } else if (sig == IRevenueEscrow.Recovered.selector) {
            address wallet = _addr(log.topics[1]);
            address replacement = _addr(log.topics[2]);
            address asset = _track(log.topics[1], log.topics[3]);
            _track(log.topics[2], log.topics[3]);
            (uint256 amount, uint256 owed, bool consentUsed) =
                abi.decode(log.data, (uint256, uint256, bool));
            assertEq(amount, _owedOf(wallet, asset), "indexer: recovered amount");
            delete _credits[wallet][asset];
            _set(replacement, asset, owed, amount);
            if (consentUsed) delete _consent[wallet];
        } else if (sig == IRevenueEscrow.Expired.selector) {
            address asset = _track(log.topics[1], log.topics[2]);
            _track(log.topics[3], log.topics[2]);
            (uint256 amount, uint256 owed) = abi.decode(log.data, (uint256, uint256));
            // Only the aged part moves; the rest stays with the wallet.
            Credit memory c = _rolled(_credits[_addr(log.topics[1])][asset]);
            assertEq(amount, c.aged, "indexer: expired amount");
            c.aged = 0;
            _credits[_addr(log.topics[1])][asset] = c;
            _set(_addr(log.topics[3]), asset, owed, amount);
        } else if (sig == IRevenueEscrow.RecoveryConsentSet.selector) {
            address account = _addr(log.topics[1]);
            _consenters.push(account);
            _consent[account] = _addr(log.topics[2]);
        } else if (sig == IAccessManaged.AuthorityUpdated.selector) {
            authority = abi.decode(log.data, (address));
        } else if (sig != IRevenueEscrow.ExcessSwept.selector) {
            // A sweep moves only what no credit is owed (ECO-40): it changes no rebuilt value.
            _unknown(sig);
        }
    }

    /// @dev Adds a credit at this block: it joins the open window, or opens one when there is
    ///      none or it has closed (ECO-45).
    function _set(address wallet, address asset, uint256 owed, uint256 amount) private {
        Credit memory c = _rolled(_credits[wallet][asset]);
        if (c.recent == 0) c.openedAt = _now;
        c.recent += amount;
        c.lastAt = _now;
        _credits[wallet][asset] = c;
        assertEq(owed, c.aged + c.maturing + c.recent, "indexer: owed");
    }

    /// @dev The escrow's ageing rule, written from the spec, under the period the Directory's
    ///      logs set: a closed window's credits age one period after that window's last credit
    ///      (`maturingLastAt`); the open window closes one period after it opened, and its
    ///      credits join `maturing` under its own last credit.
    function _rolled(Credit memory c) private view returns (Credit memory) {
        uint256 period = directoryIndexer.unclaimedPeriod();
        if (c.maturing != 0 && _now >= c.maturingLastAt + period) {
            c.aged += c.maturing;
            c.maturing = 0;
        }
        if (c.recent != 0 && _now >= c.openedAt + period) {
            (c.maturing, c.recent, c.maturingLastAt) = (c.maturing + c.recent, 0, c.lastAt);
            if (_now >= c.maturingLastAt + period) {
                c.aged += c.maturing;
                c.maturing = 0;
            }
        }
        return c;
    }

    function _owedOf(address wallet, address asset) private view returns (uint256) {
        Credit storage c = _credits[wallet][asset];
        return c.aged + c.maturing + c.recent;
    }

    function _track(bytes32 walletTopic, bytes32 assetTopic) private returns (address asset) {
        address wallet = _addr(walletTopic);
        asset = _addr(assetTopic);
        if (!_knownWallet[wallet]) {
            _knownWallet[wallet] = true;
            _wallets.push(wallet);
        }
        if (!_knownAsset[asset]) {
            _knownAsset[asset] = true;
            _assets.push(asset);
        }
    }

    function assertMatches() external view override {
        IRevenueEscrow e = IRevenueEscrow(target);
        assertEq(IAccessManaged(target).authority(), authority, "authority");
        for (uint256 a; a < _assets.length; ++a) {
            address asset = _assets[a];
            assertEq(e.totalOwed(asset), _totalOwed[asset], "totalOwed");
            for (uint256 w; w < _wallets.length; ++w) {
                address wallet = _wallets[w];
                assertEq(e.owed(wallet, asset), _owedOf(wallet, asset), "owed");
                _assertCredit(e, wallet, asset);
            }
        }
        for (uint256 i; i < _consenters.length; ++i) {
            assertEq(e.recoveryConsent(_consenters[i]), _consent[_consenters[i]], "recoveryConsent");
        }
    }

    function _assertCredit(IRevenueEscrow e, address wallet, address asset) private view {
        Credit storage c = _credits[wallet][asset];
        (
            uint256 aged,
            uint256 maturing,
            uint256 recent,
            uint48 maturingLastAt,
            uint48 openedAt,
            uint48 lastAt
        ) = e.credits(wallet, asset);
        assertEq(aged, c.aged, "credits.aged");
        assertEq(maturing, c.maturing, "credits.maturing");
        assertEq(recent, c.recent, "credits.recent");
        assertEq(maturingLastAt, c.maturingLastAt, "credits.maturingLastAt");
        assertEq(openedAt, c.openedAt, "credits.openedAt");
        assertEq(lastAt, c.lastAt, "credits.lastAt");
    }
}
