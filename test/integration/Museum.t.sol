// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IModules } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { SaleFlowBase } from "./SaleFlowBase.sol";

/// @notice Where a 6529 Stream work goes when its sale does not end with a buyer, on the deployed
///         stack. An unsold work goes to the 6529 Network Museum (the museum vault the resolver
///         names at settlement), recorded UNSOLD, with nothing paid. A work held unsold by a
///         minter the network removed may be rescued by the network once `rescueDelay` (its own
///         setting, read at the attempt) has passed since the removal; the auction then closes
///         that sale with the standing bid credited back.
contract MuseumTest is SaleFlowBase {
    address internal artist;
    address internal bidder = makeAddr("museumBidder");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("museumArtist");
        Work[] memory works = new Work[](3);
        for (uint256 i; i < 3; ++i) {
            works[i] = _work(artist, collectionId);
        }
        root = _publish(works);
        _keep(root, works);
    }

    // ------------------------------------------------------------------ unsold

    /// @dev With no bid the work goes to the museum vault, not its artist; nothing is paid.
    function test_Museum_UnbidWorkGoesToTheMuseum() public {
        Work[] memory works = _package(root);
        WorkTerms memory t = _terms(works[0]);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);
        assertEq(economics.museum(), museum, "the genesis museum is the museum vault");
        vm.warp(auction.auction(saleId).endTime);
        vm.expectEmit(address(stream));
        emit IStream.PrimarySale(tokenId, Outcome.UNSOLD, address(0), 0);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.SaleSettled(
            saleId,
            address(stream),
            tokenId,
            address(0),
            museum,
            1,
            address(0),
            0,
            t.seller,
            0,
            address(0),
            0
        );
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), museum, "the museum holds the work");
        assertEq(stream.balanceOf(artist), 0, "not the artist");
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.UNSOLD));
        assertEq(t.seller.balance, 0, "nothing paid");
        assertEq(networkFee.balance, 0);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));
    }

    /// @dev An unsold work never starts again.
    function test_Museum_AnUnsoldWorkNeverStartsAgain() public {
        Work[] memory works = _package(root);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);
        _settleAtEnd(saleId);
        bytes memory again = _mintData(root, works, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintPolicy.ContentUsed.selector, works[0].item.contentHash, tokenId
            )
        );
        auction.start(address(stream), again);
    }

    /// @dev The museum is read at settlement: a change that lands while the sale runs sends the
    ///      work to the new museum.
    function test_Museum_TheMuseumIsReadAtSettlement() public {
        (uint256 saleId, uint256 tokenId) = _start(root, _package(root), 0);
        address nextMuseum = makeAddr("nextMuseum");
        _asNetwork(
            address(economics),
            abi.encodeCall(economics.setMuseum, (economics.museumRevision(), nextMuseum))
        );
        assertEq(economics.museum(), nextMuseum);
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), nextMuseum);
    }

    /// @dev The artist cannot keep its work from the museum with a token bid: a first bid must
    ///      reach the 0.05 ETH opening bid, and one that does is a sale like any other.
    function test_Museum_ASelfBidMustReachTheOpeningBid() public {
        (uint256 saleId, uint256 tokenId) = _start(root, _package(root), 1);
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, OPENING_BID, 1));
        auction.bid{ value: 1 }(saleId, address(0));
        vm.prank(artist);
        auction.bid{ value: OPENING_BID }(saleId, address(0));
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), artist);
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.SOLD));
        assertEq(networkFee.balance, _fee(OPENING_BID, _terms(_package(root)[1]).feeShare));
    }

    // ------------------------------------------------------------------ rescue

    /// @dev The network removes the English auction as a minter of Stream.
    function _removeAuction() internal {
        _asNetwork(address(stream), abi.encodeCall(stream.removeMinter, (address(auction))));
        assertFalse(stream.isMinter(address(auction)));
    }

    function _rescue(uint256 tokenId, address to) internal {
        _asNetwork(address(stream), abi.encodeCall(stream.rescue, (tokenId, to)));
    }

    function _expectNotRescuable(uint256 tokenId) internal {
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, tokenId));
        stream.rescue(tokenId, museum);
    }

    /// @dev The whole path: a sale with a standing bid, the auction removed as a minter, the
    ///      rescue refused before `rescueDelay`, allowed after; the sale then closes with the bid
    ///      credited back and nothing recorded, paid or delivered.
    function test_Museum_RescueOfAWorkARemovedMinterHoldsAndTheSaleCloses() public {
        Work[] memory works = _package(root);
        WorkTerms memory t = _terms(works[0]);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);
        _ethBid(saleId, bidder, 1 ether);
        uint256 removedAt = block.timestamp;
        _removeAuction();
        assertEq(stream.minterOf(address(auction)).removedAt, removedAt);
        assertEq(stream.rescueDelay(), 14 days, "the launch value");

        // A removed minter starts nothing new.
        bytes memory next = _mintData(root, works, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintPolicy.NotSaleContract.selector, address(stream), address(auction)
            )
        );
        auction.start(address(stream), next);

        vm.warp(removedAt + 14 days - 1);
        _expectNotRescuable(tokenId);
        vm.warp(removedAt + 14 days);
        vm.expectEmit(address(stream));
        emit IStream.PrimarySale(tokenId, Outcome.RESCUED, address(0), 0);
        vm.expectEmit(address(stream));
        emit IStream.WorkRescued(tokenId, address(auction), museum);
        _rescue(tokenId, museum);
        assertEq(stream.ownerOf(tokenId), museum);
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.RESCUED));

        vm.expectEmit(address(auction));
        emit IEnglishAuction.Credited(bidder, address(0), saleId, 1 ether);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.RescuedSaleClosed(saleId);
        auction.settle(saleId);
        assertEq(auction.claimable(bidder), 1 ether, "the standing bid credited back");
        assertEq(stream.ownerOf(tokenId), museum, "the work stays where the rescue sent it");
        assertEq(t.seller.balance, 0, "nothing paid");
        assertEq(networkFee.balance, 0);
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        vm.prank(bidder);
        auction.claim(bidder);
        assertEq(bidder.balance, 1 ether);
        assertEq(address(auction).balance, 0);
    }

    /// @dev A rescue with no standing bid closes the sale with nothing to credit.
    function test_Museum_RescuedSaleWithNoBidClosesWithNothingToCredit() public {
        (uint256 saleId, uint256 tokenId) = _start(root, _package(root), 0);
        _removeAuction();
        vm.warp(block.timestamp + 14 days);
        _rescue(tokenId, museum);
        vm.recordLogs();
        auction.settle(saleId);
        assertEq(vm.getRecordedLogs().length, 1, "RescuedSaleClosed only");
        assertEq(address(auction).balance, 0, "nothing held");
    }

    /// @dev `rescueDelay` is read when a rescue is attempted: lowering it opens a rescue at once;
    ///      raising it closes one that the old value had opened.
    function test_Museum_RescueDelayIsReadAtTheAttempt() public {
        (uint256 saleId, uint256 tokenId) = _start(root, _package(root), 0);
        _ethBid(saleId, bidder, 1 ether);
        uint256 removedAt = block.timestamp;
        _removeAuction();

        vm.warp(removedAt + 15 days);
        _asNetwork(address(stream), abi.encodeCall(stream.setRescueDelay, (30 days)));
        _expectNotRescuable(tokenId);

        vm.expectEmit(address(stream));
        emit IStream.RescueDelaySet(30 days, 1 days);
        _asNetwork(address(stream), abi.encodeCall(stream.setRescueDelay, (1 days)));
        _rescue(tokenId, museum);
        assertEq(stream.ownerOf(tokenId), museum);
    }

    /// @dev Only the network rescues, and only a token a removed minter holds with no outcome.
    function test_Museum_RescueRefusals() public {
        Work[] memory works = _package(root);
        (uint256 runningSale, uint256 running) = _start(root, works, 0);
        (uint256 soldSale, uint256 sold) = _start(root, works, 1);
        (uint256 unbidSale, uint256 unbid) = _start(root, works, 2);
        _ethBid(soldSale, bidder, 1 ether);
        vm.warp(block.timestamp + 30 days);
        // The minter was never removed.
        _expectNotRescuable(running);

        auction.settle(soldSale);
        auction.settle(unbidSale);
        _removeAuction();
        vm.warp(block.timestamp + 30 days);
        _expectNotRescuable(sold); // held by its buyer, outcome SOLD
        _expectNotRescuable(unbid); // held by the museum, outcome UNSOLD

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        stream.rescue(running, stranger);
        _rescue(running, museum);
        _expectNotRescuable(running); // once
        auction.settle(runningSale);
    }

    /// @dev A removed minter still finishes a sale nobody rescued, as before.
    function test_Museum_ARemovedMinterStillSettlesItsSale() public {
        (uint256 saleId, uint256 tokenId) = _start(root, _package(root), 0);
        _ethBid(saleId, bidder, 1 ether);
        _removeAuction();
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), bidder);
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.SOLD));
        vm.warp(block.timestamp + 30 days);
        _expectNotRescuable(tokenId);
    }

    /// @dev A minter added again is no longer removed: what it holds is not rescuable.
    function test_Museum_AMinterAddedAgainStrandsNothing() public {
        (, uint256 tokenId) = _start(root, _package(root), 0);
        _removeAuction();
        _asNetwork(address(stream), abi.encodeCall(stream.addMinter, (address(auction))));
        vm.warp(block.timestamp + 30 days);
        assertTrue(stream.isMinter(address(auction)));
        _expectNotRescuable(tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(IModules.MinterAlreadyAdded.selector, address(auction))
        );
        vm.prank(network);
        stream.addMinter(address(auction));
    }
}
