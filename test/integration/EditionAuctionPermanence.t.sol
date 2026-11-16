// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IMintPolicy } from "src/interfaces/IMintPolicy.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { EditionAuctionStack } from "./EditionAuctionStack.sol";
import { DependencyStandIn } from "./StreamDependencies.t.sol";

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
        editions.createEdition(tokenId, w.item);
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

    /// @dev M-1 (review A): creating a settled master's edition reads only permanent facts (the
    ///      item hash Stream stored, Stream's content record), never the replaceable mint
    ///      policy. A master sells and settles; before its edition is created, governance
    ///      replaces the policy with a blank successor that answers nothing but ERC-165 and its
    ///      artist registry. The edition is still created, its sale settles, and the edition
    ///      bidder claims the copy. Before the fix `createEdition` read `packageOf` and
    ///      `claimContent` from the successor and reverted, and the sale could only be abandoned.
    function test_M1_APolicyReplacementNeverStrandsASettledMastersEdition() public {
        (, Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) =
            _startMaster(_actor("swapArtist"), 0);
        _editionBid(saleId, fan, 40, 1);
        _ethBid(oneSaleId, other, 1 ether);
        _settleAtEnd(oneSaleId);
        assertTrue(stream.primarySaleSettled(tokenId), "the master settled before the swap");
        assertFalse(editions.exists(tokenId), "its edition not created yet");

        address previous = stream.packageRegistry();
        address blank = address(new DependencyStandIn(type(IMintPolicy).interfaceId));
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.setDependency, ("PACKAGE_REGISTRY", previous, blank))
        );
        assertEq(stream.packageRegistry(), blank);

        vm.prank(makeAddr("anyone"));
        editions.createEdition(tokenId, w.item);
        assertTrue(editions.exists(tokenId));
        _settleEditions(saleId);
        vm.prank(fan);
        (uint256 won,) = editionAuction.claimBid(saleId, 1, fan);
        assertEq(won, 1);
        assertEq(editions.balanceOf(fan, tokenId), 1, "the edition copy");
    }

    /// @dev L-4 (review A): the abandonment delay's 120-day minimum assumed Stream's 90-day
    ///      rescue floor. Governance lengthens Stream's rescue delay to 180 days; a master that
    ///      cannot settle then keeps its edition sale open for the 90 extra days too, in the lens
    ///      and in the adapter, so a rescue under the longer delay can still land first.
    function test_L4_ALongerRescueDelayLengthensTheAbandonment() public {
        _govern(
            hotAdmin, address(stream), abi.encodeWithSignature("setRescueDelay(uint256)", 180 days)
        );
        (,, uint256 oneSaleId, uint256 tokenId, uint256 saleId) =
            _startMaster(_actor("slowRescueArtist"), 0);
        _editionBid(saleId, fan, 40, 1);
        vm.mockCallRevert(
            address(economics), abi.encodeWithSelector(IEconomicsResolver.museum.selector), "broken"
        );
        vm.warp(auction.auction(oneSaleId).endTime);
        vm.expectRevert();
        auction.settle(oneSaleId);
        uint256 end = ea.endTimes(saleId).endTime;
        (, uint256 abandonAt) =
            IUniformEditionAuctionLens(address(editionAuction)).abandonable(saleId);
        assertEq(abandonAt, end + 150 days + 90 days, "the delay plus the rescue lengthening");
        vm.warp(end + 150 days);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
        editionAuction.abandon(saleId);
        vm.warp(end + 240 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
        editionAuction.abandon(saleId);
        vm.warp(end + 240 days);
        vm.expectEmit(address(editions));
        emit IEditions.EditionSupplySealed(tokenId, 0);
        editionAuction.abandon(saleId);
    }

    /// @dev Review E, N-2, on the real Stream: once governance removes the English auction, its
    ///      works keep the rescue delay Stream locked then, so later lengthenings do not reach
    ///      their edition sales; while it is admitted the delay in force applies, and however long
    ///      governance makes it, it adds at most the 730-day rescue cap. Fails without the change:
    ///      the abandonment follows the live delay, without bound.
    function test_N2_ARemovalLocksTheDelayAndTheCapBoundsTheWait() public {
        (,, uint256 oneSaleId,, uint256 saleId) = _startMaster(_actor("cappedRescueArtist"), 0);
        _editionBid(saleId, fan, 40, 1);
        vm.mockCallRevert(
            address(economics), abi.encodeWithSelector(IEconomicsResolver.museum.selector), "broken"
        );
        vm.warp(auction.auction(oneSaleId).endTime);
        vm.expectRevert();
        auction.settle(oneSaleId);
        uint256 end = ea.endTimes(saleId).endTime;
        IUniformEditionAuctionLens l = IUniformEditionAuctionLens(address(editionAuction));
        _govern(
            hotAdmin, address(stream), abi.encodeWithSignature("setRescueDelay(uint256)", 180 days)
        );
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.setAdmittedMinter, (address(auction), false))
        );
        // Governance removed it after the end: Stream rescues from the removal, so the floor
        // moves with it (the automated review of 16 November 2026).
        uint256 late = block.timestamp - end;
        _govern(
            hotAdmin, address(stream), abi.encodeWithSignature("setRescueDelay(uint256)", 360 days)
        );
        _govern(
            hotAdmin, address(stream), abi.encodeWithSignature("setRescueDelay(uint256)", 720 days)
        );
        (, uint256 at) = l.abandonable(saleId);
        assertEq(at, end + 150 days + 90 days + late, "the 180 days locked at the removal");
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.setAdmittedMinter, (address(auction), true))
        );
        (, at) = l.abandonable(saleId);
        assertEq(at, end + 150 days + 630 days, "admitted again: the 720 days in force");
        _govern(
            hotAdmin, address(stream), abi.encodeWithSignature("setRescueDelay(uint256)", 1440 days)
        );
        _govern(
            hotAdmin, address(stream), abi.encodeWithSignature("setRescueDelay(uint256)", 2880 days)
        );
        (, at) = l.abandonable(saleId);
        assertEq(at, end + 150 days + 730 days, "capped");
        vm.warp(at - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
        editionAuction.abandon(saleId);
        vm.warp(at);
        editionAuction.abandon(saleId);
        assertEq(uint8(ea.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
    }

    /// @dev Review C, F16: `open` confirms each payout wallet through the ledger
    ///      (`createWallet`, idempotent for a wallet it deployed), never by code at the predicted
    ///      address. Code planted at the seller's predicted address is refused, so no edition
    ///      revenue can be routed to it; a wallet the ledger deployed earlier is confirmed and the
    ///      sale opens.
    function test_F16_OpenNeverAcceptsCodeAtAPredictedWalletAddress() public {
        Work memory w = _masterWork(_actor("plantedArtist"), 0);
        bytes32 root = _publish(_one(w));
        (, uint256 tokenId) = _start(root, _one(w), 0);
        address seller = _editionSeller(w);
        vm.etch(seller, hex"00");
        bytes memory data = abi.encode(w.item);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitFactory.WalletAddressMismatch.selector, seller, address(0))
        );
        editionAuction.open(address(editions), tokenId, data);

        // A wallet the ledger deployed earlier is confirmed, not refused.
        Work memory v = _masterWork(_actor("deployedArtist"), 0);
        bytes32 root2 = _publish(_one(v));
        (, uint256 tokenId2) = _start(root2, _one(v), 0);
        splitFactory.createWallet(v.item.payees, bytes32(0));
        assertTrue(splitFactory.isWallet(_editionSeller(v)));
        editionAuction.open(address(editions), tokenId2, abi.encode(v.item));
    }
}
