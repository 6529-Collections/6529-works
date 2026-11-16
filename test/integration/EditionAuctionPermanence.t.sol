// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IMintPolicy } from "src/interfaces/IMintPolicy.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { EditionAuctionStack } from "./EditionAuctionStack.sol";
import { DependencyStandIn } from "./StreamDependencies.t.sol";

/// @notice The permanence changes of the edition auction on the real, wired stack: an edition's
///         fixed close (R20), the abandonment exit (R16), and its split wallets deployed before
///         any money is owed to them (EA-17 to EA-19).
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
        uint256 saleId = editionAuction.open(address(editions), tokenId, _openData(w));
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

    /// @dev R20 on the real stack: an edition whose terms name a close offset is refused, and a
    ///      sale closes exactly 15 minutes after its 1/1's final end.
    function test_Window_FifteenMinutesOnTheRealStack() public {
        Work memory w = _masterWork(_actor("windowArtist"), 0);
        w.item.edition.params = abi.encode(uint256(7 days));
        bytes32 root = _publish(_one(w));
        (, uint256 tokenId) = _start(root, _one(w), 0);
        bytes memory data = _openData(w);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.InvalidSaleTerms.selector, address(editions), tokenId
            )
        );
        editionAuction.open(address(editions), tokenId, data);
        (,, uint256 oneSaleId,, uint256 saleId) = _startMaster(_actor("windowArtist2"), 0);
        IUniformEditionAuction.EndTimes memory e = ea.endTimes(saleId);
        assertEq(e.closeAt, auction.auction(oneSaleId).endTime + 15 minutes);
    }

    /// @dev R16 and Part E 15: a Stream master whose settlement fails (Stream's economics cannot
    ///      name the museum) keeps its 1/1 ENDED, unsettled; the edition sale is never abandoned
    ///      while it is (anyone may settle the 1/1 once repaired). After the repair the master
    ///      settles; 21 days after the close `abandon` creates the missing edition and the sale
    ///      completes, copies minted.
    function test_Abandon_AStreamMasterWaitsForItsRepairThenCompletes() public {
        (, Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) =
            _startMaster(_actor("stuckArtist"), 0);
        _editionBid(saleId, fan, 40, 2);
        vm.mockCallRevert(
            address(economics), abi.encodeWithSelector(IEconomicsResolver.museum.selector), "broken"
        );
        vm.warp(auction.auction(oneSaleId).endTime);
        vm.expectRevert();
        auction.settle(oneSaleId);
        uint256 close = ea.endTimes(saleId).closeAt;
        vm.warp(close + 400 days);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
        editionAuction.abandon(saleId, abi.encode(w.item));
        // The repair: the master goes to the museum and is settled; its edition is missing.
        vm.clearMockedCalls();
        auction.settle(oneSaleId);
        assertTrue(stream.primarySaleSettled(tokenId));
        vm.prank(other);
        editionAuction.abandon(saleId, abi.encode(w.item));
        assertTrue(editions.exists(tokenId), "the edition was created");
        _settleEditions(saleId);
        vm.prank(fan);
        (uint256 won,) = editionAuction.claimBid(saleId, 1, fan);
        assertEq(won, 2, "copies minted");
    }

    /// @dev R16: an upheld dispute burns the master (its sale never completes); 21 days after
    ///      the close anyone abandons the edition sale: every bid refunded in full, the edition
    ///      sealed at zero.
    function test_Abandon_ACancelledMasterIsVoidedAndSealedAtZero() public {
        (, Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) =
            _startMaster(_actor("disputedArtist"), 0);
        _editionBid(saleId, fan, 40, 2);
        vm.prank(guardian1);
        auction.pause(oneSaleId, keccak256("dispute"));
        bytes32 outcome = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://upheld"
        );
        _govern(hotAdmin, address(auction), abi.encodeCall(auction.cancel, (oneSaleId, outcome)));
        uint256 close = ea.endTimes(saleId).closeAt;
        vm.warp(close + 21 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
        editionAuction.abandon(saleId, abi.encode(w.item));
        vm.warp(close + 21 days);
        vm.expectEmit(address(editions));
        emit IEditions.EditionSupplySealed(tokenId, 0);
        vm.prank(other);
        editionAuction.abandon(saleId, abi.encode(w.item));
        uint256 escrowed = 2 * ea.stepPrice(saleId, 40);
        uint256 before = fan.balance;
        vm.prank(fan);
        (uint256 won, uint256 refund) = editionAuction.claimBid(saleId, 1, fan);
        assertEq(won, 0);
        assertEq(refund, escrowed);
        assertEq(fan.balance - before, escrowed, "refunded in full");
    }

    /// @dev The same master, repaired: it settles, the edition is created, the sale settles as
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
        editionAuction.abandon(saleId, abi.encode(w.item));
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
        bytes memory data = _openData(w);
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
        editionAuction.open(address(editions), tokenId2, _openData(v));
    }
}
