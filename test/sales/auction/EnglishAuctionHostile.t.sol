// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { console2 } from "forge-std/console2.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import {
    BlocklistToken,
    CallbackToken,
    FeeOnTransferToken,
    GasHungryToken,
    MockERC20,
    NoReturnToken,
    RebasingToken,
    ReturnsFalseToken
} from "../../mocks/economics/EconomicsMocks.sol";
import { GasBurnerToken, HostileActor } from "../../mocks/sales/AuctionMocks.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { AuctionBase } from "./AuctionBase.sol";

/// @dev Hostile bidders, winners, wallets and tokens. None of them can block a sale, take
///      another account's funds, or leave funds without an owner.
contract EnglishAuctionHostileTest is AuctionBase {
    bytes4 internal constant REENTRY =
        ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;

    function _actorBid(HostileActor actor, uint256 saleId, uint256 amount) internal {
        vm.deal(address(actor), amount);
        actor.execute(
            address(auction),
            amount,
            abi.encodeCall(auction.bid, (saleId, address(0), _direct(address(actor), amount)))
        );
    }

    function _startIn(address currency) internal returns (uint256) {
        stream.setTerms(_terms(currency));
        return auction.start(address(stream), "");
    }

    function _bidToken(MockERC20 token, uint256 saleId, address bidder, uint256 amount) internal {
        token.mint(bidder, amount);
        vm.startPrank(bidder);
        token.approve(address(auction), amount);
        auction.bid(saleId, address(0), _direct(bidder, amount));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------- ETH receivers

    function test_RevertingBidderCannotBlockOutbidding() public {
        HostileActor actor = new HostileActor();
        actor.configure(HostileActor.Behaviour.REVERT, HostileActor.Behaviour.ACCEPT);
        uint256 saleId = _start();
        _actorBid(actor, saleId, 1 ether);
        _bidEth(saleId, alice, 2 ether);
        assertEq(auction.claimable(address(actor), ETH), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.ClaimFailed.selector, address(actor)));
        actor.execute(address(auction), 0, abi.encodeCall(auction.claim, (ETH, address(actor))));
        actor.execute(address(auction), 0, abi.encodeCall(auction.claim, (ETH, carol)));
        assertEq(carol.balance, 1 ether);
    }

    function test_GasBurningWalletsAreEscrowed() public {
        HostileActor burner = new HostileActor();
        burner.configure(HostileActor.Behaviour.BURN_GAS, HostileActor.Behaviour.ACCEPT);
        PrimaryTerms memory t = _terms(ETH);
        t.seller = address(burner);
        t.feeRecipient = address(burner);
        stream.setTerms(t);
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _end(saleId);
        uint256 before = gasleft();
        auction.settle(saleId);
        assertLt(before - gasleft(), 2 * auction.PAYOUT_GAS() + 400_000, "bounded by the caps");
        assertEq(escrow.owed(address(burner), ETH), 1 ether);
        assertEq(stream.ownerOf(_tokenIdOf(saleId)), alice);
    }

    function test_ReentrantClaimerIsBlocked() public {
        HostileActor actor = new HostileActor();
        actor.configure(HostileActor.Behaviour.REENTER, HostileActor.Behaviour.ACCEPT);
        uint256 saleId = _start();
        _actorBid(actor, saleId, 1 ether);
        _bidEth(saleId, alice, 2 ether);
        _bidEth(saleId, bob, 3 ether);
        actor.setReentry(address(auction), abi.encodeCall(auction.claim, (ETH, address(actor))));
        actor.execute(address(auction), 0, abi.encodeCall(auction.claim, (ETH, address(actor))));
        assertTrue(actor.reentered());
        assertFalse(actor.reentryOk());
        assertEq(bytes4(actor.reentryResult()), REENTRY);
        assertEq(address(actor).balance, 1 ether, "paid once");
        assertEq(address(auction).balance, 5 ether);
    }

    function test_ReentrantWinnerCannotReenterSettlement() public {
        HostileActor winner = new HostileActor();
        winner.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.REENTER);
        uint256 saleId = _start();
        uint256 other = _start();
        _bidEth(other, alice, 1 ether);
        vm.deal(address(winner), 1 ether);
        winner.execute(
            address(auction),
            1 ether,
            abi.encodeCall(auction.bid, (saleId, address(0), _direct(address(winner), 1 ether)))
        );
        _end(other);
        winner.setReentry(address(auction), abi.encodeCall(auction.settle, (other)));
        auction.settle(saleId);
        assertTrue(winner.reentered());
        assertFalse(winner.reentryOk());
        assertEq(bytes4(winner.reentryResult()), REENTRY);
        assertEq(
            stream.ownerOf(_tokenIdOf(saleId)), address(winner), "delivered despite the attempt"
        );
        auction.settle(other);
        assertEq(stream.ownerOf(_tokenIdOf(other)), alice);
    }

    function test_ReentrantSellerWalletIsBlocked() public {
        HostileActor wallet = new HostileActor();
        wallet.configure(HostileActor.Behaviour.REENTER, HostileActor.Behaviour.ACCEPT);
        PrimaryTerms memory t = _terms(ETH);
        t.seller = address(wallet);
        stream.setTerms(t);
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _bidEth(saleId, bob, 2 ether);
        wallet.setReentry(address(auction), abi.encodeCall(auction.claim, (ETH, address(wallet))));
        _end(saleId);
        auction.settle(saleId);
        assertTrue(wallet.reentered());
        assertFalse(wallet.reentryOk());
        assertEq(address(wallet).balance, 1.5 ether);
        assertEq(auction.claimable(alice, ETH), 1 ether);
    }

    // ----------------------------------------------------------------------- hostile tokens

    function test_FeeOnTransferBidsFailClosed() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        allowlist.admitAsset(address(token), 0, 1);
        uint256 saleId = _startIn(address(token));
        token.mint(alice, 100);
        vm.startPrank(alice);
        token.approve(address(auction), 100);
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, address(token))
        );
        auction.bid(saleId, address(0), _direct(alice, 100));
        vm.stopPrank();
    }

    function test_RebasingBidsFailClosed() public {
        RebasingToken token = new RebasingToken();
        token.setIndex(3e18);
        allowlist.admitAsset(address(token), 0, 1);
        uint256 saleId = _startIn(address(token));
        token.mint(alice, 100);
        vm.startPrank(alice);
        token.approve(address(auction), 100);
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, address(token))
        );
        auction.bid(saleId, address(0), _direct(alice, 100));
        vm.stopPrank();
    }

    function test_NoReturnAndFalseReturningTokensFailClosed() public {
        NoReturnToken silent = new NoReturnToken();
        ReturnsFalseToken liar = new ReturnsFalseToken();
        allowlist.admitAsset(address(silent), 0, 1);
        allowlist.admitAsset(address(liar), 0, 1);
        uint256 a = _startIn(address(silent));
        uint256 b = _startIn(address(liar));
        silent.mint(alice, 100);
        liar.mint(alice, 100);
        vm.startPrank(alice);
        silent.approve(address(auction), 100);
        liar.approve(address(auction), 100);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransfer.TokenCallFailed.selector,
                address(silent),
                silent.transferFrom.selector
            )
        );
        auction.bid(a, address(0), _direct(alice, 100));
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransfer.TokenCallFailed.selector, address(liar), liar.transferFrom.selector
            )
        );
        auction.bid(b, address(0), _direct(alice, 100));
        vm.stopPrank();
    }

    function test_BlocklistedSellerIsEscrowedAndBlocklistedBidderClaimsElsewhere() public {
        BlocklistToken token = new BlocklistToken();
        allowlist.admitAsset(address(token), 0, 1);
        uint256 saleId = _startIn(address(token));
        _bidToken(token, saleId, alice, 100);
        _bidToken(token, saleId, bob, 200);
        token.setBlocked(seller, true);
        token.setBlocked(alice, true);
        _end(saleId);
        auction.settle(saleId);
        assertEq(escrow.owed(seller, address(token)), 150);
        assertEq(token.balanceOf(network), 50);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransfer.TokenCallFailed.selector, address(token), token.transfer.selector
            )
        );
        auction.claim(address(token), alice);
        vm.prank(alice);
        auction.claim(address(token), carol);
        assertEq(token.balanceOf(carol), 100);
        assertEq(token.balanceOf(address(auction)), 0);
    }

    function test_GasHungryTokenPayoutIsEscrowed() public {
        GasHungryToken token = new GasHungryToken();
        allowlist.admitAsset(address(token), 0, 1);
        uint256 saleId = _startIn(address(token));
        _bidToken(token, saleId, alice, 1_000);
        _end(saleId);
        auction.settle{ gas: 3_000_000 }(saleId);
        assertEq(escrow.owed(seller, address(token)), 750);
        assertEq(escrow.owed(network, address(token)), 250);
        assertEq(token.balanceOf(address(auction)), 0);
    }

    /// @dev The most expensive settlement: both payouts exhaust the token's transfer allowance and
    ///      fall back to the escrow, and the winner burns the whole delivery allowance. The whole
    ///      transaction (21,000 intrinsic, calldata, execution) stays far below the EIP-7825 cap
    ///      of 16,777,216 gas, which Foundry's Prague setting does not enforce by itself.
    function test_SettleWorstCaseFitsTheFusakaCap() public {
        GasBurnerToken token = new GasBurnerToken();
        allowlist.admitAsset(address(token), 0, 1);
        uint256 saleId = _startIn(address(token));
        HostileActor winner = new HostileActor();
        winner.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.BURN_GAS);
        token.mint(alice, 1_000);
        vm.startPrank(alice);
        token.approve(address(auction), 1_000);
        auction.bid(saleId, address(winner), _direct(alice, 1_000));
        vm.stopPrank();
        _end(saleId);
        bytes memory data = abi.encodeCall(auction.settle, (saleId));
        uint256 before = gasleft();
        (bool ok,) = address(auction).call(data);
        uint256 used = before - gasleft();
        assertTrue(ok);
        uint256 calldataCost;
        for (uint256 i; i < data.length; ++i) {
            calldataCost += data[i] == 0 ? 4 : 16;
        }
        uint256 total = 21_000 + calldataCost + used;
        console2.log("worst-case settle, whole transaction", total);
        assertLt(total, 2_000_000, "bounded by the payout and delivery caps");
        assertLt(total, 16_777_216);
        assertEq(escrow.owed(seller, address(token)), 750);
        assertEq(auction.pendingDelivery(saleId), address(winner));
    }

    function test_CallbackTokenCannotReenter() public {
        CallbackToken token = new CallbackToken();
        allowlist.admitAsset(address(token), 0, 1);
        uint256 saleId = _startIn(address(token));
        _bidToken(token, saleId, alice, 100);
        token.setHook(address(auction), abi.encodeCall(auction.settle, (saleId)));
        _bidToken(token, saleId, bob, 200);
        assertFalse(token.lastHookOk());
        assertEq(bytes4(token.lastHookResult()), REENTRY);
        assertEq(auction.auction(saleId).bidder, bob);
    }

    // --------------------------------------------------------------------- hostile actors

    function test_NoBidSettlementCannotBeBlockedByTheArtist() public {
        HostileActor artistWallet = new HostileActor();
        artistWallet.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.BURN_GAS);
        PrimaryTerms memory t = _terms(ETH);
        t.creator = address(artistWallet);
        stream.setTerms(t);
        uint256 saleId = _start();
        _end(saleId);
        auction.settle(saleId);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(auction.pendingDelivery(saleId), address(artistWallet));
    }

    function test_OutsidersCannotClaimSomeoneElsesCredit() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _bidEth(saleId, bob, 2 ether);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NothingToClaim.selector, carol, ETH));
        auction.claim(ETH, carol);
        assertEq(auction.claimable(alice, ETH), 1 ether);
    }
}
