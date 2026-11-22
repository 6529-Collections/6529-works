// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { ReplayBase } from "./ReplayBase.sol";

/// @notice Log replay of the split ledger and the revenue escrow (ECO-10 to ECO-22, ECO-27,
///         ECO-28, ECO-40, ECO-44, ECO-45, INV-ECO-14): a history that emits every event of both
///         rebuilds, from their logs alone, every wallet configuration, released total, recorded
///         receipt, mark and nonce, and every credit, its clock, `totalOwed` and each recovery
///         consent.
contract LogReplayLedgerTest is ReplayBase {
    address internal alice;
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal payer = makeAddr("payer");
    address internal ledgerArtist;
    ISplitWallet.Payee[] internal pair;

    function setUp() public override {
        super.setUp();
        alice = _actor("alice");
        ledgerArtist = _actor("ledgerArtist");
        (address lo, address hi) = alice < bob ? (alice, bob) : (bob, alice);
        pair.push(ISplitWallet.Payee(0, lo, lo == alice ? 60_000 : 40_000));
        pair.push(ISplitWallet.Payee(0, hi, hi == alice ? 60_000 : 40_000));
    }

    function _idx(address account) internal view returns (uint256) {
        return pair[0].account == account ? 0 : 1;
    }

    function test_EveryLedgerEventReplaysToTheSameState() public {
        ledgerIdx.probe(alice);
        address w1 = splitFactory.createWallet(pair, 0);
        vm.deal(w1, 10 ether);
        splitFactory.release(pair, 0, address(0), _idx(alice));
        usd.mint(w1, 1000e18);
        vm.prank(bob);
        splitFactory.releaseTo(pair, 0, address(usd), _idx(bob), carol);
        _sync();

        // A signed release (ECO-20) and a revoked nonce in the same 256-bit word (ECO-21).
        IReleaseVerifier.Authorization memory a = IReleaseVerifier.Authorization(
            w1, address(usd), _idx(alice), alice, alice, 100e18, 7, block.timestamp + 1 days
        );
        splitFactory.releaseWithAuthorization(
            pair, 0, a, _sign(alice, splitFactory.releaseDigest(a))
        );
        vm.prank(alice);
        splitFactory.revokeNonce(8);
        _sync();

        // A royalty wallet naming the network fee vault: a payee's release also pays the vault
        // its due share, logged as a second `Released` (R11).
        ISplitWallet.Payee[] memory royalty =
            Splits.royaltyPayees(alice, splitFactory.network(), 10_000);
        address w2 = splitFactory.createWallet(royalty, 0);
        vm.deal(w2, 1 ether);
        splitFactory.release(royalty, 0, address(0), royalty[0].account == alice ? 0 : 1);
        _sync();

        // An artist-resolved payee releases to its payout address (ECO-16).
        _publish(_one(_work(ledgerArtist, collectionId)));
        ISplitWallet.Payee[] memory mixed = new ISplitWallet.Payee[](2);
        mixed[0] = ISplitWallet.Payee(0, bob, 50_000);
        mixed[1] = ISplitWallet.Payee(artists.artistIdOf(ledgerArtist), address(0), 50_000);
        address w3 = splitFactory.createWallet(mixed, keccak256("mixed"));
        vm.deal(w3, 2 ether);
        vm.prank(ledgerArtist);
        splitFactory.release(mixed, keccak256("mixed"), address(0), 1);
        _sync();

        // A share unclaimed for 180 days goes to the network: mark, then forfeit (R12, ECO-44).
        splitFactory.mark(pair, 0, address(0), _idx(bob));
        _sync();
        vm.warp(block.timestamp + 180 days);
        splitFactory.forfeit(pair, 0, address(0), _idx(bob));
        _sync();
        assertGt(splitFactory.released(w1, address(0), _idx(bob)), 0);
        assertGt(splitFactory.recordedObserved(w1, address(usd)), 0);
        assertGt(splitFactory.released(w3, address(0), 1), 0);
        _assertEveryEventReplayed("SplitLedger", ledgerIdx, _list("EIP712DomainChanged()"));
    }

    function test_EveryEscrowEventReplaysToTheSameState() public {
        address dave = makeAddr("dave");
        address eve = makeAddr("eve");
        escrowIdx.probe(alice);
        escrowIdx.probe(dave);
        escrowIdx.probe(eve);
        vm.deal(payer, 10 ether);
        vm.prank(payer);
        escrow.depositETH{ value: 1 ether }(alice);
        _sync();
        vm.warp(block.timestamp + 1 days);
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

        // An ordinary account's recovery uses up its consent (ECO-28).
        vm.prank(payer);
        escrow.depositETH{ value: 1 ether }(dave);
        vm.prank(dave);
        escrow.consentToRecovery(eve);
        _sync();
        _govern(hotAdmin, address(escrow), abi.encodeCall(escrow.recover, (dave, eve, address(0))));
        _sync();
        assertEq(escrow.recoveryConsent(dave), address(0));

        // A split wallet's credit moves to an equivalent wallet, no consent needed.
        address w1 = splitFactory.createWallet(pair, 0);
        address w1b = splitFactory.createWallet(pair, bytes32(uint256(1)));
        vm.prank(payer);
        escrow.depositETH{ value: 2 ether }(w1);
        _sync();
        _govern(hotAdmin, address(escrow), abi.encodeCall(escrow.recover, (w1, w1b, address(0))));
        _sync();

        // Credits whose window's last credit is 180 days old become the network fee vault's,
        // the rest stays (R12, ECO-45): one window of two credits, then a credit after it closed.
        vm.prank(payer);
        escrow.depositETH{ value: 0.25 ether }(carol);
        _sync();
        vm.warp(block.timestamp + 100 days);
        vm.prank(payer);
        escrow.depositETH{ value: 0.1 ether }(carol);
        _sync();
        vm.warp(block.timestamp + 90 days);
        vm.prank(payer);
        escrow.depositETH{ value: 0.05 ether }(carol);
        _sync();
        vm.warp(block.timestamp + 90 days);
        assertEq(escrow.expire(carol, address(0)), 0.35 ether);
        _sync();
        vm.warp(block.timestamp + 90 days);
        assertEq(escrow.expire(carol, address(0)), 0.05 ether);
        _sync();

        // Only what no credit is owed can be swept (ECO-40).
        vm.deal(address(escrow), address(escrow).balance + 1 ether);
        _govern(
            hotAdmin,
            address(escrow),
            abi.encodeCall(escrow.sweepExcess, (address(0), networkFeeSafe))
        );
        _sync();
        _assertEveryEventReplayed("RevenueEscrow", escrowIdx, new string[](0));
    }

    /// @dev Negative control: slot 2 holds `configOf`; a wallet configuration no
    ///      `WalletCreated` logged makes the comparison fail.
    function test_LedgerIndexerDetectsStateThatLogsDoNotExplain() public {
        address w1 = splitFactory.createWallet(pair, 0);
        _sync();
        vm.store(address(splitFactory), keccak256(abi.encode(w1, uint256(2))), keccak256("other"));
        vm.expectRevert();
        ledgerIdx.assertMatches();
    }

    /// @dev Negative control: slot 2 holds `totalOwed`; ETH's total moved with no log.
    function test_EscrowIndexerDetectsStateThatLogsDoNotExplain() public {
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        escrow.depositETH{ value: 1 ether }(alice);
        _sync();
        vm.store(
            address(escrow), keccak256(abi.encode(address(0), uint256(2))), bytes32(uint256(7))
        );
        vm.expectRevert();
        escrowIdx.assertMatches();
    }
}
