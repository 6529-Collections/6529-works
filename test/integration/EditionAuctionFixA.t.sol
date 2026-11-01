// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EconomicsResolver } from "src/economics/EconomicsResolver.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { PRODUCT_EDITIONS } from "src/interfaces/types/EconomicsTypes.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { EditionAuctionStack } from "./EditionAuctionStack.sol";

/// @notice Regressions of the rc.2 seven-lens review, fix pass A, on the real stack.
///         F1 (LC-1, MONEY-L1, G-1): after a governed economics replacement (owner decision 16),
///         an edition sale pays exactly the economics 6529 Stream Editions locks and reports,
///         whether the edition auction was deployed before the switch or not.
///         F3 (markets M-1): a bid placed during a 1/1 dispute pause cannot be withdrawn, so a
///         pause cannot be used to spoof demand.
contract EditionAuctionFixATest is EditionAuctionStack {
    address internal artist;
    address internal collector = makeAddr("fixACollector");
    address internal newFee = makeAddr("replacementNetworkFee");

    function setUp() public override {
        super.setUp();
        artist = _actor("fixAArtist");
    }

    function _replaceEconomics() internal returns (EconomicsResolver next) {
        next = new EconomicsResolver(
            address(manager), allowlist, splitFactory, newFee, museum, cc0TextFileId
        );
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.setDependency, ("ECONOMICS", address(economics), address(next)))
        );
        assertEq(stream.economics(), address(next));
        assertEq(address(editions.economics()), address(next), "Editions follows Stream");
    }

    /// @dev Runs `saleId` to the end and checks that the fee went to the recipient the edition
    ///      records, and to no other.
    function _settleAndCheckTheRecordedSplitWasPaid(
        bytes32 root,
        Work memory w,
        uint256 oneSaleId,
        uint256 tokenId,
        uint256 saleId
    ) internal {
        _settleOneOfOneAndCreate(oneSaleId, root, w);
        IEditions.Edition memory e = editions.edition(tokenId);
        IUniformEditionAuction.Auction memory a = ea.auction(saleId);
        assertEq(a.seller, e.seller, "the sale locked the edition's seller");
        assertEq(a.feeRecipient, e.feeRecipient, "and its fee recipient");
        assertEq(a.feeShare, e.feeShare, "and its fee share");
        uint256 revenue = ea.clearing(saleId).revenue;
        uint256 fee = revenue * e.feeShare / 100_000;
        assertGt(fee, 0);
        uint256 recordedBefore = e.feeRecipient.balance;
        uint256 otherBefore = networkFee.balance;
        _settleEditions(saleId);
        assertEq(e.feeRecipient.balance - recordedBefore, fee, "the recorded recipient was paid");
        if (e.feeRecipient != networkFee) {
            assertEq(networkFee.balance, otherBefore, "the replaced resolver's recipient was not");
        }
    }

    /// @dev LC-1 and MONEY-L1: the genesis edition auction after an economics replacement.
    function test_F1_TheEditionAuctionFollowsAnEconomicsReplacement() public {
        EconomicsResolver next = _replaceEconomics();
        (bytes32 root, Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) =
            _startMaster(artist, 0);
        IUniformEditionAuction.Auction memory a = ea.auction(saleId);
        assertEq(a.feeRecipient, newFee, "the sale locked the replacement's recipient");
        assertEq(a.seller, next.newWorkTerms(PRODUCT_EDITIONS, w.item.payees).seller);
        _editionBid(saleId, makeAddr("fan"), 100, 10);
        _ethBid(oneSaleId, collector, 1 ether);
        _settleAndCheckTheRecordedSplitWasPaid(root, w, oneSaleId, tokenId, saleId);
        assertEq(editions.edition(tokenId).feeRecipient, newFee);
    }

    /// @dev G-1: an edition auction deployed BEFORE the switch (as the runbook's replacement
    ///      set is) pays the replacement's terms after it: it holds no economics of its own.
    function test_F1_AnAuctionDeployedBeforeTheSwitchPaysTheReplacement() public {
        UniformEditionAuction successor = _newEditionAuction();
        _govern(
            hotAdmin,
            address(editions),
            abi.encodeCall(editions.setAdmittedMinter, (address(successor), true))
        );
        _govern(
            hotAdmin,
            address(successor),
            abi.encodeCall(successor.setTarget, (address(editions), true))
        );
        _replaceEconomics();
        Work memory w = _masterWork(artist, 0);
        bytes32 root = _publish(_one(w));
        (uint256 oneSaleId, uint256 tokenId) = _start(root, _one(w), 0);
        uint256 saleId = successor.open(address(editions), tokenId, abi.encode(w.item));
        IUniformEditionAuction s = IUniformEditionAuction(address(successor));
        assertEq(s.auction(saleId).feeRecipient, newFee, "the successor pays the replacement");
        uint256 amount = 10 * s.stepPrice(saleId, 100);
        address fan = makeAddr("fan");
        vm.deal(fan, amount);
        vm.prank(fan);
        successor.bid{ value: amount }(saleId, 100, 10);
        _ethBid(oneSaleId, collector, 1 ether);
        _settleOneOfOneAndCreate(oneSaleId, root, w);
        IEditions.Edition memory e = editions.edition(tokenId);
        assertEq(e.minter, address(successor));
        assertEq(e.feeRecipient, newFee);
        uint256 fee = s.clearing(saleId).revenue * e.feeShare / 100_000;
        uint256 before = newFee.balance;
        vm.warp(s.endTimes(saleId).endTime);
        IUniformEditionAuctionLens l = IUniformEditionAuctionLens(address(successor));
        for (
            uint256 i; !successor.settle(saleId, l.settlementOrderFor(saleId, address(this))); ++i) {
            require(i < 8, "settlement does not advance");
        }
        assertEq(newFee.balance - before, fee, "the recorded recipient was paid");
    }

    /// @dev Markets M-1: a dispute pause no longer lets a spoofer post demand and withdraw it. A
    ///      bid placed during the pause is firm; a bid placed before it may still leave.
    function test_F3_APauseSpoofIsFirm() public {
        (bytes32 root, Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) =
            _startMaster(artist, 10);
        address honest = makeAddr("honest");
        address early = makeAddr("early");
        address spoofer = makeAddr("spoofer");
        uint256 honestBid = _editionBid(saleId, honest, 140, 10);
        uint256 earlyBid = _editionBid(saleId, early, 120, 2);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(guardian1);
        auction.pause(oneSaleId, keccak256("dispute"));
        uint256 pausedAt = block.timestamp;
        uint256 spoofBid = _editionBid(saleId, spoofer, 150, 10);
        IUniformEditionAuctionLens l = IUniformEditionAuctionLens(address(editionAuction));
        assertTrue(l.canWithdraw(saleId, earlyBid), "a bid from before the pause may leave");
        assertFalse(l.canWithdraw(saleId, spoofBid), "a bid placed during the pause may not");
        assertTrue(ea.endTimes(saleId).withdrawalsOpen);
        // In the pause's last second, the spoof is still firm.
        vm.warp(pausedAt + 7 days);
        vm.prank(spoofer);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.WithdrawalsClosed.selector, saleId)
        );
        editionAuction.withdrawBid(saleId, spoofBid, spoofer);
        // The early bidder leaves, as decision 12 intends.
        vm.prank(early);
        editionAuction.withdrawBid(saleId, earlyBid, early);
        // A raise during the pause is new demand: firm too.
        uint256 topUp = 10 * (ea.stepPrice(saleId, 151) - ea.stepPrice(saleId, 140));
        vm.deal(honest, topUp);
        vm.prank(honest);
        editionAuction.raise{ value: topUp }(saleId, honestBid, 151);
        assertFalse(l.canWithdraw(saleId, honestBid), "a raise restarts the placement");
        vm.prank(honest);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.WithdrawalsClosed.selector, saleId)
        );
        editionAuction.withdrawBid(saleId, honestBid, honest);
        // The spoof stayed in the book to the end: it was demand, with its escrow at risk.
        vm.warp(pausedAt + 7 days + 1);
        _ethBid(oneSaleId, collector, 1 ether);
        _settleOneOfOneAndCreate(oneSaleId, root, w);
        _settleEditions(saleId);
        assertEq(ea.settlement(saleId).count, 10);
        assertEq(ea.bidOf(saleId, spoofBid).quantity, 10, "the spoof was never withdrawn");
        assertEq(editions.edition(tokenId).minter, address(editionAuction));
    }
}
