// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC1155Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { GasBurnerWallet } from "../../mocks/sales/SaleMocks.sol";
import {
    CopyRefusingBidder,
    EthRefusingHolder,
    ReentrantBidder,
    ReentrantSeller
} from "../../mocks/sales/EditionAuctionMocks.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice Hostile ERC-1155 receivers, ETH receivers and payout wallets against the edition
///         auction: re-entry through the copy hook and through the refund is refused by the guard
///         on every entry point, a receiver that refuses copies cannot block its own claim
///         elsewhere or anyone else's, and a wallet that refuses, re-enters or burns gas is paid
///         in the escrow without blocking settlement.
contract UniformEditionAuctionHostileTest is EditionAuctionBase {
    address internal alice = makeAddr("alice");

    function test_Reentry_ThroughTheCopyHookIsRefused() public {
        for (uint8 mode; mode < 3; ++mode) {
            uint256 snapshot = vm.snapshotState();
            uint256 saleId = _open(0);
            ReentrantBidder hostile = new ReentrantBidder(ua);
            uint256 price = 2 * _price(saleId, 50);
            vm.deal(address(hostile), price);
            hostile.setTarget(saleId, 1, mode);
            vm.prank(address(hostile));
            auction.bid{ value: price }(saleId, 50, 2);
            _bid(saleId, alice, 40, 1);
            _settle(saleId);
            // The winner claims to itself: its hook re-enters, the guard refuses, the claim lands.
            hostile.claimBid(1, address(hostile));
            assertTrue(hostile.attempted(), "re-entered");
            assertEq(
                bytes4(hostile.lastRevert()),
                ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
            );
            assertEq(editions.balanceOf(address(hostile), ID), 2);
            assertFalse(_live(saleId, 1), "claimed once");
            vm.revertToState(snapshot);
        }
    }

    function test_Reentry_ThroughTheRefundIsRefused() public {
        uint256 saleId = _open(0);
        ReentrantBidder hostile = new ReentrantBidder(ua);
        // A losing bid: its claim only refunds, through the ETH receive.
        uint256 price = _price(saleId, 10);
        vm.deal(address(hostile), price);
        hostile.setTarget(saleId, 1, 0);
        vm.prank(address(hostile));
        auction.bid{ value: price }(saleId, 10, 1);
        _bid(saleId, alice, 200, 1);
        _settle(saleId);
        hostile.claimBid(1, address(hostile));
        assertTrue(hostile.attempted());
        assertEq(
            bytes4(hostile.lastRevert()),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(address(hostile).balance, price);
    }

    function test_CopyRefusingBidder_ClaimsElsewhere() public {
        uint256 saleId = _open(0);
        CopyRefusingBidder refuser = new CopyRefusingBidder();
        uint256 price = 3 * _price(saleId, 60);
        vm.deal(address(this), price);
        refuser.bid{ value: price }(ua, saleId, 60, 3);
        _bid(saleId, alice, 60, 1);
        _settle(saleId);
        // Neither its own claim nor a pushed one can mint to it.
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(refuser))
        );
        refuser.claimBid(ua, saleId, 1, address(refuser));
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(refuser))
        );
        auction.claimBidFor(saleId, 1);
        // Others are not blocked, and the refuser claims to an address that accepts.
        vm.prank(alice);
        auction.claimBid(saleId, 2, alice);
        address vault = makeAddr("vault");
        (uint256 won, uint256 refund) = refuser.claimBid(ua, saleId, 1, vault);
        assertEq(won, 3);
        assertEq(refund, 0);
        assertEq(editions.balanceOf(vault, ID), 3);
    }

    function test_RefusingAndReentrantWalletsAreEscrowed() public {
        ReentrantSeller reentrant = new ReentrantSeller();
        EthRefusingHolder refusingFee = new EthRefusingHolder();
        economics.set(address(reentrant), address(refusingFee), FEE_SHARE);
        uint256 saleId = _open(0);
        reentrant.setTarget(ua, saleId);
        _bid(saleId, alice, 100, 4);
        _settle(saleId);
        uint256 revenue = 4 * _price(saleId, 100);
        uint256 fee = revenue * FEE_SHARE / 100_000;
        assertEq(escrow.owed(address(reentrant), address(0)), revenue - fee);
        assertEq(escrow.owed(address(refusingFee), address(0)), fee);
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
        );
        assertEq(_claimAll(saleId), 4);
        _assertConserved();
    }

    function test_GasBurningSellerIsEscrowedWithinItsAllowance() public {
        GasBurnerWallet burner = new GasBurnerWallet();
        economics.set(address(burner), networkFee, FEE_SHARE);
        uint256 saleId = _open(0);
        _bid(saleId, alice, 100, 1);
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
        uint256 gasBefore = gasleft();
        auction.settle(saleId, new uint256[](0));
        uint256 used = gasBefore - gasleft();
        assertLt(used, 400_000, "the burner gets its 100,000 and no more");
        uint256 revenue = _price(saleId, 100);
        assertEq(escrow.owed(address(burner), address(0)), revenue - revenue * FEE_SHARE / 100_000);
    }

    function test_Settle_NeedsGasForTheFullPayoutAllowance() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 100, 1);
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
        // A settler that cannot forward the payout allowance cannot force the escrow route.
        (bool ok,) = address(auction).call{ gas: 120_000 }(
            abi.encodeCall(IUniformEditionAuction.settle, (saleId, new uint256[](0)))
        );
        assertFalse(ok);
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.OPEN));
    }
}
