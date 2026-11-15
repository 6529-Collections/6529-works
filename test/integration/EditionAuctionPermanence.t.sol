// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { EditionAuctionStack } from "./EditionAuctionStack.sol";

/// @notice The permanence changes of the edition auction on the real, wired stack: an edition's
///         own open period, the exit when its master can never be settled, and its split
///         wallets deployed before any money is owed to them (EA-17 to EA-19).
contract EditionAuctionPermanenceTest is EditionAuctionStack {
    address internal fan = makeAddr("permanenceFan");
    address internal other = makeAddr("permanenceOther");

    /// @dev `open` deploys the seller's and royalty receiver's split wallets, so the payout of
    ///      both the 1/1 and the edition reaches deployed code, never an empty address.
    function test_Wallets_DeployedAtOpenBeforeAnyPayment() public {
        address lead = _actor("walletsArtist");
        Work memory w = _masterWork(lead, 0);
        assertEq(_editionSeller(w).code.length, 0, "no seller wallet before the open");
        assertEq(_editionRoyalty(w).code.length, 0, "no royalty wallet before the open");
        bytes32 root = _publish(_one(w));
        (uint256 oneSaleId, uint256 tokenId) = _start(root, _one(w), 0);
        uint256 saleId = editionAuction.open(address(editions), tokenId, abi.encode(w.item));
        address seller = _editionSeller(w);
        assertTrue(seller.code.length != 0, "the seller wallet");
        assertTrue(_editionRoyalty(w).code.length != 0, "the royalty wallet");
        assertTrue(splitFactory.isWallet(seller));
        _editionBid(saleId, fan, 40, 2);
        _settleOneOfOneAndCreate(oneSaleId, root, w);
        uint256 before = seller.balance;
        _settleEditions(saleId);
        assertGt(seller.balance, before, "paid to the deployed wallet");
        assertEq(IEditions(address(editions)).edition(tokenId).maxSupply, 2, "sealed at 2");
    }

    /// @dev A seven-day window: the 1/1 sells and settles, bids keep arriving for a week, the
    ///      sale settles after its own close and seals at the count sold.
    function test_Window_ASevenDayEditionOnTheRealStack() public {
        Work memory w = _masterWork(_actor("windowArtist"), 0);
        w.item.edition.params = abi.encode(uint256(7 days));
        bytes32 root = _publish(_one(w));
        (uint256 oneSaleId, uint256 tokenId) = _start(root, _one(w), 0);
        uint256 saleId = editionAuction.open(address(editions), tokenId, abi.encode(w.item));
        assertEq(ea.auction(saleId).terms.closeOffset, 7 days);
        _editionBid(saleId, fan, 40, 1);
        _ethBid(oneSaleId, other, 1 ether);
        _settleOneOfOneAndCreate(oneSaleId, root, w);
        vm.warp(block.timestamp + 6 days);
        assertTrue(ea.endTimes(saleId).biddingOpen, "still open six days after the 1/1");
        _editionBid(saleId, other, 41, 2);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, saleId)
        );
        editionAuction.settle(saleId, new uint256[](0));
        _settleEditions(saleId);
        assertEq(IEditions(address(editions)).edition(tokenId).maxSupply, 3);
        vm.prank(other);
        (uint256 won,) = editionAuction.claimBid(saleId, 2, other);
        assertEq(won, 2);
    }

    /// @dev The review's case (REVIEW-sal16 F1, now with the exit): an unbid master whose
    ///      settlement fails because Stream's economics dependency cannot name the museum. The
    ///      English auction never refuses a Stream sale, so the master waits; the edition sale
    ///      cannot settle; after its end plus the 150-day delay, anyone abandons it, every edition
    ///      bid is refunded in full, and the edition is sealed at zero. A later repair settles
    ///      the master and lets the edition be created, with no copy ever mintable.
    function test_Abandon_AStreamMasterThatCannotSettle() public {
        (bytes32 root, Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) =
            _startMaster(_actor("stuckArtist"), 0);
        _editionBid(saleId, fan, 40, 2);
        _stickAndAbandon(oneSaleId, tokenId, saleId);
        // The repair: the master goes to the museum, the edition can be created, but sealed at 0.
        vm.clearMockedCalls();
        auction.settle(oneSaleId);
        assertEq(
            uint8(auction.auction(oneSaleId).state), uint8(IEnglishAuction.AuctionState.SETTLED)
        );
        editions.createEdition(tokenId, w.item, root, _proofOf(_one(w), 0));
        IEditions.Edition memory ed = IEditions(address(editions)).edition(tokenId);
        assertEq(ed.maxSupply, 0, "no copy can ever exist");
        assertTrue(ed.supplySealed);
    }

    /// @dev Breaks the museum read, shows the master and the sale waiting, abandons the sale at
    ///      its end plus 150 days, and claims the one bid's full refund.
    function _stickAndAbandon(uint256 oneSaleId, uint256 tokenId, uint256 saleId) internal {
        vm.mockCallRevert(
            address(economics), abi.encodeWithSelector(IEconomicsResolver.museum.selector), "broken"
        );
        vm.warp(auction.auction(oneSaleId).endTime);
        vm.expectRevert();
        auction.settle(oneSaleId);
        uint256 end = ea.endTimes(saleId).endTime;
        vm.warp(end);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, saleId)
        );
        editionAuction.settle(saleId, new uint256[](0));
        // Merely slow until the delay passes.
        vm.warp(end + 150 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
        editionAuction.abandon(saleId);
        vm.warp(end + 150 days);
        vm.expectEmit(address(editions));
        emit IEditions.EditionSupplySealed(tokenId, 0);
        vm.prank(other);
        editionAuction.abandon(saleId);
        uint256 escrowed = 2 * ea.stepPrice(saleId, 40);
        uint256 before = fan.balance;
        vm.prank(fan);
        (uint256 won, uint256 refund) = editionAuction.claimBid(saleId, 1, fan);
        assertEq(won, 0);
        assertEq(refund, escrowed);
        assertEq(fan.balance - before, escrowed, "refunded in full");
    }

    /// @dev The same master, repaired before the delay passes: it settles, the sale settles as
    ///      usual, and abandonment is refused.
    function test_Abandon_ARepairedMasterSettlesInstead() public {
        (bytes32 root, Work memory w, uint256 oneSaleId,, uint256 saleId) =
            _startMaster(_actor("repairedArtist"), 0);
        _editionBid(saleId, fan, 40, 2);
        vm.mockCallRevert(
            address(economics), abi.encodeWithSelector(IEconomicsResolver.museum.selector), "broken"
        );
        vm.warp(auction.auction(oneSaleId).endTime + 31 days);
        vm.clearMockedCalls();
        _settleOneOfOneAndCreate(oneSaleId, root, w);
        vm.warp(ea.endTimes(saleId).endTime + 200 days);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
        editionAuction.abandon(saleId);
        _settleEditions(saleId);
        vm.prank(fan);
        (uint256 won,) = editionAuction.claimBid(saleId, 1, fan);
        assertEq(won, 2);
    }
}
