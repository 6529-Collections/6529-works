// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEnglishAuctionRefusal } from "src/interfaces/IEnglishAuctionRefusal.sol";
import { EditionAuctionStack } from "./EditionAuctionStack.sol";

/// @notice AUC-38 on the real stack (the review's F1): a 6529 Stream sale is never closed as
///         refused. If governance breaks Stream's economics dependency, an unbid master's
///         settlement fails until the repair, and `settleOrRefund` stays shut however long it
///         takes, so the artist can never take the unsold work and the master's edition sale is
///         never stranded. A gas-starved call cannot refuse a Stream sale either.
contract StreamSaleNeverRefusedTest is EditionAuctionStack {
    address internal artist;
    address internal fan = makeAddr("neverRefusedFan");

    function setUp() public override {
        super.setUp();
        artist = _actor("neverRefusedArtist");
    }

    /// @dev The review's reproduction: Stream's resolver `museum()` reverts after a dependency
    ///      replacement. `settle` fails, `settleOrRefund` refuses a Stream sale for 60 days and
    ///      beyond, and once the dependency is repaired the work goes to the museum, the edition
    ///      is created and the edition bidder gets the copy.
    function test_AnUnbidMasterWhoseDependencyFailsIsNeverRefused() public {
        (bytes32 root, Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) =
            _startMaster(artist, 0);
        uint256 bidId = _editionBid(saleId, fan, 40, 1);
        vm.warp(auction.auction(oneSaleId).endTime);
        vm.mockCallRevert(
            address(economics), abi.encodeWithSelector(IEconomicsResolver.museum.selector), ""
        );
        vm.expectRevert();
        auction.settle(oneSaleId);
        bytes memory refused =
            abi.encodeWithSelector(IEnglishAuctionRefusal.SaleNotRefusable.selector, oneSaleId);
        vm.expectRevert(refused);
        IEnglishAuctionRefusal(address(auction)).refusableAt(oneSaleId);
        for (uint256 day = 1; day <= 60; day += 7) {
            vm.warp(auction.auction(oneSaleId).endTime + day * 1 days);
            vm.prank(artist);
            vm.expectRevert(refused);
            IEnglishAuctionRefusal(address(auction)).settleOrRefund(oneSaleId);
        }
        assertEq(stream.ownerOf(tokenId), address(auction), "still in custody");
        assertFalse(stream.primarySaleSettled(tokenId));

        // Governance repairs the dependency: the sale settles as D140 says.
        vm.clearMockedCalls();
        auction.settle(oneSaleId);
        assertEq(stream.ownerOf(tokenId), museum, "the unsold work went to the museum");
        assertTrue(stream.primarySaleSettled(tokenId));
        editions.createEdition(tokenId, w.item);
        _settleEditions(saleId);
        vm.prank(fan);
        (uint256 won,) = editionAuction.claimBid(saleId, bidId, fan);
        assertEq(won, 1, "the edition bidder's copy");
    }

    /// @dev A keeper sending too little gas cannot refuse a Stream sale with a bid: the exit is
    ///      shut before any gas check, `settle` with too little gas reverts and changes nothing,
    ///      and a full `settle` then sells.
    function test_AGasStarvedCallCannotRefuseAStreamSale() public {
        (,, uint256 oneSaleId, uint256 tokenId,) = _startMaster(artist, 0);
        address winner = makeAddr("neverRefusedWinner");
        _ethBid(oneSaleId, winner, 1 ether);
        vm.warp(auction.auction(oneSaleId).endTime + 30 days);
        for (uint256 limit = 50_000; limit <= 400_000; limit += 50_000) {
            (bool ok, bytes memory data) = address(auction).call{ gas: limit }(
                abi.encodeCall(IEnglishAuctionRefusal.settleOrRefund, (oneSaleId))
            );
            assertFalse(ok, "never succeeds");
            assertEq(bytes4(data), IEnglishAuctionRefusal.SaleNotRefusable.selector);
            (ok,) = address(auction).call{ gas: limit }(
                abi.encodeCall(IEnglishAuction.settle, (oneSaleId))
            );
            assertFalse(ok, "a starved settle reverts");
            assertEq(
                uint8(auction.auction(oneSaleId).state),
                uint8(IEnglishAuction.AuctionState.ENDED),
                "nothing changed"
            );
        }
        auction.settle(oneSaleId);
        assertEq(stream.ownerOf(tokenId), winner, "sold");
        assertEq(auction.claimable(winner, address(0)), 0, "nothing credited back");
    }
}
