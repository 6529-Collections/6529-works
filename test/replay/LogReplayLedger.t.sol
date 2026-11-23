// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { MockERC20 } from "../mocks/economics/EconomicsMocks.sol";
import { ReplayBase } from "./ReplayBase.sol";
import { ReplayEvents } from "./ReplayEvents.sol";

/// @notice Log replay of the split ledger and the revenue escrow on the deployed stack, from
///         their deployment on: a history that emits every event of both rebuilds, from their
///         logs alone, every wallet configuration, released total, recorded receipt, mark and
///         nonce, and every credit with its window times, `totalOwed` and each recovery
///         consent. The escrow's windows age under the unclaimed period the Directory's own logs
///         set, including a change of that period in the middle of the history.
contract LogReplayLedgerTest is ReplayBase {
    address internal alice;
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal payer = makeAddr("payer");
    address internal ledgerArtist;
    MockERC20 internal usd;
    ISplitWallet.Payee[] internal pair;

    function setUp() public override {
        super.setUp();
        alice = _actor("alice");
        ledgerArtist = _actor("ledgerArtist");
        usd = new MockERC20("USD", "USD");
        (address lo, address hi) = alice < bob ? (alice, bob) : (bob, alice);
        pair.push(ISplitWallet.Payee(0, lo, lo == alice ? 60_000 : 40_000));
        pair.push(ISplitWallet.Payee(0, hi, hi == alice ? 60_000 : 40_000));
    }

    function _idx(address account) internal view returns (uint256) {
        return pair[0].account == account ? 0 : 1;
    }

    function test_SplitLedger_EveryEventReplaysToTheSameState() public {
        ledgerIdx.probe(alice);
        address w1 = ledger.createWallet(pair, 0);
        vm.deal(w1, 10 ether);
        ledger.release(pair, 0, address(0), _idx(alice));
        usd.mint(w1, 1000e18);
        vm.prank(bob);
        ledger.releaseTo(pair, 0, address(usd), _idx(bob), carol);
        _sync();

        // A signed release and a revoked nonce in the same 256-bit word.
        IReleaseVerifier.Authorization memory a = IReleaseVerifier.Authorization(
            w1, address(usd), _idx(alice), alice, alice, 100e18, 7, block.timestamp + 1 days
        );
        ledger.releaseWithAuthorization(pair, 0, a, _sign(alice, ledger.releaseDigest(a)));
        vm.prank(alice);
        ledger.revokeNonce(8);
        _sync();

        // A royalty wallet naming the network fee vault: a payee's release also pays the vault
        // its due share, logged as a second `Released`.
        ISplitWallet.Payee[] memory royalty = Splits.royaltyPayees(alice, ledger.network(), 10_000);
        address w2 = ledger.createWallet(royalty, 0);
        vm.deal(w2, 1 ether);
        ledger.release(royalty, 0, address(0), royalty[0].account == alice ? 0 : 1);
        _sync();

        // An artist-resolved payee releases to its payout address (the Directory).
        _publish(_one(_work(ledgerArtist, collectionId)));
        ISplitWallet.Payee[] memory mixed = new ISplitWallet.Payee[](2);
        mixed[0] = ISplitWallet.Payee(0, bob, 50_000);
        mixed[1] = ISplitWallet.Payee(uint256(uint160(ledgerArtist)), address(0), 50_000);
        address w3 = ledger.createWallet(mixed, keccak256("mixed"));
        vm.deal(w3, 2 ether);
        vm.prank(ledgerArtist);
        ledger.release(mixed, keccak256("mixed"), address(0), 1);
        _sync();

        // A share unclaimed for the Directory's period goes to the network: mark, then forfeit.
        ledger.mark(pair, 0, address(0), _idx(bob));
        _sync();
        skip(directory.unclaimedPeriod());
        ledger.forfeit(pair, 0, address(0), _idx(bob));
        _sync();
        assertGt(ledger.released(w1, address(0), _idx(bob)), 0);
        assertGt(ledger.recordedObserved(w1, address(usd)), 0);
        assertGt(ledger.released(w3, address(0), 1), 0);
        _assertEveryEventReplayed(
            "SplitLedger", ledgerIdx, ReplayEvents.splitLedger(), _list("EIP712DomainChanged()")
        );
    }

    function test_RevenueEscrow_EveryEventReplaysToTheSameState() public {
        address dave = makeAddr("dave");
        address eve = makeAddr("eve");
        escrowIdx.probe(alice);
        escrowIdx.probe(dave);
        escrowIdx.probe(eve);
        vm.deal(payer, 10 ether);
        vm.prank(payer);
        escrow.depositETH{ value: 1 ether }(alice);
        _sync();
        skip(1 days);
        vm.prank(payer);
        escrow.depositETH{ value: 0.5 ether }(alice); // joins the open window
        usd.mint(payer, 50e18);
        vm.startPrank(payer);
        usd.approve(address(escrow), 50e18);
        escrow.depositERC20(bob, address(usd), 50e18);
        vm.stopPrank();
        _sync();
        escrow.flush(alice, address(0));
        _sync();

        // An ordinary account's recovery uses up its consent.
        vm.prank(payer);
        escrow.depositETH{ value: 1 ether }(dave);
        vm.prank(dave);
        escrow.consentToRecovery(eve);
        _sync();
        _asNetwork(address(escrow), abi.encodeCall(escrow.recover, (dave, eve, address(0))));
        _sync();
        assertEq(escrow.recoveryConsent(dave), address(0));

        // A split wallet's credit moves to an equivalent wallet, no consent needed.
        address w1 = ledger.createWallet(pair, 0);
        address w1b = ledger.createWallet(pair, bytes32(uint256(1)));
        vm.prank(payer);
        escrow.depositETH{ value: 2 ether }(w1);
        _sync();
        _asNetwork(address(escrow), abi.encodeCall(escrow.recover, (w1, w1b, address(0))));
        _sync();

        // Credits whose window's last credit is one period old move to the network; the rest
        // stays: one window of two credits, then a credit after it closed.
        vm.prank(payer);
        escrow.depositETH{ value: 0.25 ether }(carol);
        _sync();
        skip(100 days);
        vm.prank(payer);
        escrow.depositETH{ value: 0.1 ether }(carol);
        _sync();
        skip(90 days);
        vm.prank(payer);
        escrow.depositETH{ value: 0.05 ether }(carol);
        _sync();
        skip(90 days);
        assertEq(escrow.expire(carol, address(0)), 0.35 ether);
        _sync();
        skip(90 days);
        assertEq(escrow.expire(carol, address(0)), 0.05 ether);
        _sync();

        // The network shortens the unclaimed period: later credits age under the new one, which
        // the indexer reads from the Directory's log, not from a contract.
        _asNetwork(address(directory), abi.encodeCall(directory.setUnclaimedPeriod, (30 days)));
        vm.prank(payer);
        escrow.depositETH{ value: 0.2 ether }(carol);
        _sync();
        skip(30 days);
        escrow.depositETH{ value: 0.01 ether }(carol); // opens a new window
        _sync();
        skip(29 days);
        assertEq(escrow.expire(carol, address(0)), 0.2 ether);
        _sync();

        // Only what no credit is owed can be swept.
        vm.deal(address(escrow), address(escrow).balance + 1 ether);
        _asNetwork(address(escrow), abi.encodeCall(escrow.sweepExcess, (address(0), feeSafe)));
        _sync();
        _assertEveryEventReplayed("RevenueEscrow", escrowIdx, ReplayEvents.revenueEscrow(), _none());
    }

    // ------------------------------------------------------------------ negative controls

    /// @dev Slot 2 holds `configOf`: a wallet configuration no `WalletCreated` logged.
    function test_SplitLedger_ReplayFailsOnStateNoLogExplains() public {
        address w1 = ledger.createWallet(pair, 0);
        _sync();
        vm.store(address(ledger), keccak256(abi.encode(w1, uint256(2))), keccak256("other"));
        vm.expectRevert();
        ledgerIdx.assertMatches();
    }

    /// @dev A release whose `Released` log is dropped: the rebuilt totals are stale.
    function test_SplitLedger_ReplayFailsOnADroppedLog() public {
        address w1 = ledger.createWallet(pair, 0);
        vm.deal(w1, 1 ether);
        _sync();
        ledger.release(pair, 0, address(0), _idx(alice));
        _apply(_dropOne(address(ledger), ISplitWallet.Released.selector));
        vm.expectRevert();
        ledgerIdx.assertMatches();
    }

    /// @dev Slot 2 holds `totalOwed`: ETH's total moved with no log.
    function test_RevenueEscrow_ReplayFailsOnStateNoLogExplains() public {
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        escrow.depositETH{ value: 1 ether }(alice);
        _sync();
        vm.store(
            address(escrow), keccak256(abi.encode(address(0), uint256(2))), bytes32(uint256(7))
        );
        vm.expectRevert(bytes("totalOwed: 7 != 1000000000000000000"));
        escrowIdx.assertMatches();
    }

    /// @dev A period change whose Directory log is dropped: the escrow indexer ages a credit
    ///      under the stale period and its expiry no longer matches.
    function test_RevenueEscrow_ReplayFailsOnADroppedDirectoryLog() public {
        _asNetwork(address(directory), abi.encodeCall(directory.setUnclaimedPeriod, (30 days)));
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        escrow.depositETH{ value: 1 ether }(carol);
        _apply(_dropOne(address(directory), keccak256("UnclaimedPeriodSet(uint48,uint48)")));
        skip(60 days);
        escrow.expire(carol, address(0));
        compareOnSync = false;
        vm.expectRevert(bytes("indexer: expired amount: 1000000000000000000 != 0"));
        this.syncExternally();
    }

    function syncExternally() external {
        _sync();
    }
}
