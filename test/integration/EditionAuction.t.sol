// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IModules } from "src/interfaces/core/IModules.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { EditionAuctionStack } from "./EditionAuctionStack.sol";

/// @notice The edition auction end to end on the deployed stack (D138-D141): the worked
///         examples, the cap with FIFO and a hole, the soft close and its backstop, a dispute
///         pause holding settlement, settlement waiting for a final 1/1, a sale without bids, the
///         open's checks, the seal at the count and the cap, a second adapter refused an existing
///         edition, a removed adapter's winners still claiming, the split wallets deployed at
///         open, and the abandonment floor.
contract EditionAuctionIntegrationTest is EditionAuctionStack {
    uint256 internal constant DENOMINATOR = 100_000;

    address internal artist;
    address internal collector = makeAddr("oneOfOneCollector");

    function setUp() public override {
        super.setUp();
        artist = _actor("masterArtist");
    }

    /// @dev PLAN appendix C, trace 2: 80 editions at 0.0511 ETH, 4.088 ETH raised, the network
    ///      paid its share and the seller the rest; every bid claimed, exactly 80 minted, the
    ///      loser refunded in full, the adapter empty.
    function test_EditionAuction_WorkedExample() public {
        (, Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) =
            _startMaster(artist, 0);
        address[5] memory bidders =
            [makeAddr("b1"), makeAddr("b2"), makeAddr("b3"), makeAddr("b4"), makeAddr("b5")];
        uint16[5] memory steps = [uint16(192), 158, 144, 130, 96];
        uint32[5] memory quantities = [uint32(1), 9, 20, 50, 200];
        for (uint256 i; i < 5; ++i) {
            _editionBid(saleId, bidders[i], steps[i], quantities[i]);
        }
        _ethBid(oneSaleId, collector, 1 ether);
        IUniformEditionAuction.Clearing memory c = ea.clearing(saleId);
        assertEq(c.count, 80);
        assertEq(c.price, 0.0511 ether);
        assertEq(c.revenue, 4.088 ether);
        uint256 share = ea.auction(saleId).feeShare;
        uint256 fee = c.revenue - c.revenue * (DENOMINATOR - share) / DENOMINATOR;
        assertEq(c.networkFee, fee, "the network fee");
        assertEq(ea.endTimes(saleId).endTime, auction.auction(oneSaleId).endTime + 15 minutes);

        _settleAtEnd(oneSaleId);
        assertEq(stream.ownerOf(tokenId), collector);
        address seller = _editionSeller(w);
        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = networkFee.balance;
        _settleEditions(saleId);
        assertEq(seller.balance - sellerBefore, c.revenue - fee, "the seller's share");
        assertEq(networkFee.balance - feeBefore, fee, "the network's share");

        assertEq(_claimFive(saleId, tokenId, bidders), 80);
        assertEq(editions.editionOf(tokenId).minted, 80);
        assertEq(editions.editionOf(tokenId).maxSupply, 80, "sealed at the count");
        assertEq(editions.editionOf(tokenId).minter, address(editionAuction));
        assertEq(editions.balanceOf(bidders[4], tokenId), 0);
        assertEq(bidders[4].balance, 200 * 0.01 ether, "the loser gets everything back");
        assertEq(address(editionAuction).balance, 0);
    }

    function _claimFive(uint256 saleId, uint256 tokenId, address[5] memory bidders)
        internal
        returns (uint256 minted)
    {
        for (uint256 i; i < 5; ++i) {
            vm.prank(bidders[i]);
            (uint256 won, uint256 refund) = editionAuction.claimBid(saleId, i + 1, bidders[i]);
            minted += won;
            assertEq(editions.balanceOf(bidders[i], tokenId), won);
            assertEq(bidders[i].balance, refund);
        }
    }

    /// @dev PLAN appendix C, trace 3: a cap of 60, B2 raised out of the cut step; the sweep
    ///      closes the hole and exactly 60 are minted; pushed claims credit the refunds.
    function test_EditionAuction_CapFifoHole() public {
        (,, uint256 oneSaleId, uint256 tokenId, uint256 saleId) = _startMaster(artist, 60);
        _editionBid(saleId, makeAddr("A"), 192, 1);
        _editionBid(saleId, makeAddr("B"), 158, 9);
        _editionBid(saleId, makeAddr("C"), 144, 5);
        _editionBid(saleId, makeAddr("B1"), 130, 20);
        uint256 b2 = _editionBid(saleId, makeAddr("B2"), 130, 15);
        _editionBid(saleId, makeAddr("B3"), 130, 10);
        _editionBid(saleId, makeAddr("B4"), 130, 20);
        _editionRaise(saleId, b2, 144);
        assertEq(ea.clearing(saleId).cutoff, 45);
        _settleAtEnd(oneSaleId);
        _settleEditions(saleId);
        assertEq(ea.settlement(saleId).count, 60);
        uint256 minted;
        for (uint256 bidId = 1; bidId <= 7; ++bidId) {
            (uint256 won,) = editionAuction.claimBidFor(saleId, bidId);
            minted += won;
        }
        assertEq(minted, 60);
        assertEq(editions.editionOf(tokenId).minted, 60);
        assertEq(eaLens.claimable(makeAddr("B2"), CURRENCY_ETH), 0.7335 ether);
        assertEq(eaLens.claimable(makeAddr("B4"), CURRENCY_ETH), 20 * 0.0511 ether);
        vm.prank(makeAddr("B4"));
        editionAuction.claim(CURRENCY_ETH, makeAddr("B4"));
        assertEq(makeAddr("B4").balance, 20 * 0.0511 ether);
    }

    /// @dev D140: the 1/1 keeps its anti-snipe and the edition close moves with it; past the
    ///      old close an edition bid is still accepted.
    function test_EditionAuction_OneOfOneAntiSnipeMovesTheEditionClose() public {
        (,, uint256 oneSaleId,, uint256 saleId) = _startMaster(artist, 0);
        uint64 end = auction.auction(oneSaleId).endTime;
        vm.warp(end - 1);
        _ethBid(oneSaleId, collector, 1 ether);
        uint64 extended = auction.auction(oneSaleId).endTime;
        assertEq(extended, end - 1 + EXTENSION_WINDOW);
        vm.warp(end + 15 minutes);
        _editionBid(saleId, makeAddr("late"), 10, 1);
        assertEq(ea.endTimes(saleId).closeAt, extended + 15 minutes);
        // The edition's own soft close: a bid in its last 5 minutes extends it.
        vm.warp(extended + 15 minutes - 1);
        _editionBid(saleId, makeAddr("sniper"), 11, 1);
        assertEq(ea.endTimes(saleId).endTime, extended + 15 minutes - 1 + 5 minutes);
    }

    /// @dev The soft close holds at most `maxExtension` (24 hours) past the close: a chain of
    ///      last-window bids stops there, and a bid at the backstop is refused.
    function test_EditionAuction_SoftCloseHoldsAtTheBackstop() public {
        (,, uint256 oneSaleId,, uint256 saleId) = _startMaster(artist, 0);
        uint256 closeAt = ea.endTimes(saleId).closeAt;
        uint256 backstop = closeAt + ea.auction(saleId).terms.maxExtension;
        assertEq(ea.endTimes(saleId).backstop, backstop);
        _settleAtEnd(oneSaleId);
        address chaser = makeAddr("chaser");
        uint256 step;
        for (uint256 n; ea.endTimes(saleId).endTime < backstop; ++n) {
            assertLt(n, 400, "the chain of soft-close bids does not stop at the backstop");
            vm.warp(ea.endTimes(saleId).endTime - 1);
            _editionBid(saleId, chaser, ++step % 300, 1);
            assertLe(ea.endTimes(saleId).endTime, backstop, "never past the backstop");
        }
        assertEq(ea.endTimes(saleId).endTime, backstop);
        vm.warp(backstop);
        uint256 price = ea.stepPrice(saleId, 1);
        vm.deal(chaser, price);
        vm.prank(chaser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.BiddingClosed.selector, saleId, uint64(backstop)
            )
        );
        editionAuction.bid{ value: price }(saleId, 1, 1);
        _settleEditions(saleId);
        assertEq(
            uint8(ea.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
        );
    }

    /// @dev A dispute raised while the 1/1 is live holds the edition settlement past the edition
    ///      close for as long as the 1/1 is paused; bidding continues meanwhile, with no end.
    function test_EditionAuction_DisputePauseHoldsTheEditionSettlement() public {
        (,, uint256 oneSaleId,, uint256 saleId) = _startMaster(artist, 0);
        _editionBid(saleId, makeAddr("fan"), 40, 2);
        uint64 end = auction.auction(oneSaleId).endTime;
        vm.warp(end - 1 hours);
        _pauseOneOfOne(oneSaleId);
        vm.warp(end + 1 days);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, saleId)
        );
        editionAuction.settle(saleId, new uint256[](0));
        _editionBid(saleId, makeAddr("late"), 41, 1);
        assertEq(ea.endTimes(saleId).endTime, end + 15 minutes, "no end while paused");
        assertTrue(ea.endTimes(saleId).biddingOpen);
    }

    /// @dev The 1/1 can be paused only while live; the edition sale settles only once the 1/1
    ///      settled, which is final: no settle call can pay or mint while the 1/1 could still be
    ///      cancelled.
    function test_EditionAuction_SettlementWaitsForAFinalOneOfOne() public {
        (,, uint256 oneSaleId,, uint256 saleId) = _startMaster(artist, 0);
        _editionBid(saleId, makeAddr("low"), 0, 3);
        _editionBid(saleId, makeAddr("high"), 300, 1);
        _ethBid(oneSaleId, collector, 1 ether);
        uint64 end = auction.auction(oneSaleId).endTime;
        vm.warp(end);
        vm.prank(pauser1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                oneSaleId,
                IEnglishAuction.AuctionState.ENDED
            )
        );
        auction.pause(oneSaleId, bytes32("late dispute"));
        vm.warp(end + 15 minutes);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, saleId)
        );
        editionAuction.settle(saleId, new uint256[](0));
        auction.settle(oneSaleId);
        // A book 38 words wide: the first call scans, the second clears.
        assertFalse(editionAuction.settle(saleId, new uint256[](0)), "the first scanning call");
        assertEq(
            uint8(ea.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLING)
        );
        assertTrue(editionAuction.settle(saleId, new uint256[](0)), "the clearing call");
        (uint256 won,) = editionAuction.claimBidFor(saleId, 2);
        assertEq(won, 1);
    }

    /// @dev D141: no edition bids, no copies: the sale settles at zero, the edition is sealed at
    ///      zero, nothing is paid.
    function test_EditionAuction_NoEditionBidsNoCopies() public {
        (,, uint256 oneSaleId, uint256 tokenId, uint256 saleId) = _startMaster(artist, 0);
        _ethBid(oneSaleId, collector, 1 ether);
        _settleAtEnd(oneSaleId);
        uint256 feeBefore = networkFee.balance;
        _settleEditions(saleId);
        assertEq(ea.settlement(saleId).count, 0);
        assertTrue(editions.editionOf(tokenId).supplySealed);
        assertEq(editions.editionOf(tokenId).maxSupply, 0);
        assertEq(networkFee.balance, feeBefore);
    }

    /// @dev An edition sale opens only for a master, with its stored item, while its 1/1 runs,
    ///      once.
    function test_EditionAuction_OpenChecksTheMaster() public {
        (Work memory w, uint256 oneSaleId, uint256 tokenId) = _startUnopened(artist, 0);
        Work memory other = _masterWork(artist, 7);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.InvalidSaleTerms.selector, address(editions), tokenId
            )
        );
        editionAuction.open(address(editions), tokenId, _openData(other));
        // A work that is not a master.
        Work memory original = _work(artist, collectionId);
        Work[] memory originals = _one(original);
        bytes32 originalRoot = _publish(originals);
        (, uint256 originalId) = _start(originalRoot, originals, 0);
        assertEq(original.item.kind, uint8(ItemKind.ORIGINAL));
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.InvalidSaleTerms.selector, address(editions), originalId
            )
        );
        editionAuction.open(address(editions), originalId, _openData(original));
        // Only 6529 Stream Editions.
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(stream))
        );
        editionAuction.open(address(stream), tokenId, _openData(w));

        uint256 saleId = editionAuction.open(address(editions), tokenId, _openData(w));
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.AuctionExists.selector, saleId)
        );
        editionAuction.open(address(editions), tokenId, _openData(w));

        // Too late: past the edition close of a 1/1 that has ended.
        (Work memory late, uint256 lateSale, uint256 lateId) = _startUnopened(artist, 0);
        uint256 lateEnd = auction.auction(lateSale).endTime;
        vm.warp(lateEnd + 15 minutes);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.BiddingClosed.selector,
                ea.saleIdOf(address(editions), lateId),
                uint64(lateEnd + 15 minutes)
            )
        );
        editionAuction.open(address(editions), lateId, _openData(late));
        oneSaleId;
    }

    /// @dev A 1/1 cancelled before its edition sale opened leaves nothing to open against.
    function test_EditionAuction_ACancelledOneOfOneCannotOpen() public {
        (Work memory w, uint256 oneSaleId, uint256 tokenId) = _startUnopened(artist, 0);
        _cancelOneOfOne(oneSaleId, tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.NoOneOfOneAuction.selector, address(stream), tokenId
            )
        );
        editionAuction.open(address(editions), tokenId, _openData(w));
    }

    /// @dev The clearing seals the edition at the count: a cap of 5 against 8 units of demand
    ///      sells 5, the edition holds at 5, and nothing past it can be minted or sealed again.
    function test_EditionAuction_TheSealAndTheCapHold() public {
        (,, uint256 oneSaleId, uint256 tokenId, uint256 saleId) = _startMaster(artist, 5);
        assertEq(editions.editionOf(tokenId).maxSupply, 5, "the creator's cap at open");
        assertFalse(editions.editionOf(tokenId).supplySealed);
        _editionBid(saleId, makeAddr("x"), 20, 4);
        _editionBid(saleId, makeAddr("y"), 20, 4);
        _settleAtEnd(oneSaleId);
        _settleEditions(saleId);
        assertEq(ea.settlement(saleId).count, 5);
        assertTrue(editions.editionOf(tokenId).supplySealed);
        assertEq(editions.editionOf(tokenId).maxSupply, 5);
        (uint256 wonX,) = editionAuction.claimBidFor(saleId, 1);
        (uint256 wonY,) = editionAuction.claimBidFor(saleId, 2);
        assertEq(wonX, 4, "first in, filled first");
        assertEq(wonY, 1);
        assertEq(editions.editionOf(tokenId).minted, 5);
        // Only the edition's minter mints or seals, and the seal is final.
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, tokenId, address(this))
        );
        editions.mint(address(this), tokenId, 1, 0);
        vm.prank(address(editionAuction));
        vm.expectRevert(abi.encodeWithSelector(IEditions.SupplyExceeded.selector, tokenId));
        editions.mint(address(this), tokenId, 1, 0);
        vm.prank(address(editionAuction));
        vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidSeal.selector, tokenId));
        editions.seal(tokenId, 6);
    }

    /// @dev `open` deploys the seller's and royalty receiver's split wallets before any money is
    ///      owed to them; the edition records the royalty wallet and the master's rate.
    function test_EditionAuction_WalletsDeployedAtOpen() public {
        (Work memory w, uint256 oneSaleId, uint256 tokenId) = _startUnopened(artist, 0);
        address seller = _editionSeller(w);
        address royalty = _editionRoyalty(w);
        assertEq(seller.code.length, 0, "no seller wallet before the open");
        assertEq(royalty.code.length, 0, "no royalty wallet before the open");
        uint256 saleId = editionAuction.open(address(editions), tokenId, _openData(w));
        assertTrue(seller.code.length != 0, "the seller wallet");
        assertTrue(royalty.code.length != 0, "the royalty wallet");
        assertEq(editions.editionOf(tokenId).royaltyReceiver, royalty);
        assertEq(editions.editionOf(tokenId).royaltyRate, stream.workOf(tokenId).royaltyRate);
        _editionBid(saleId, makeAddr("fan"), 40, 2);
        _settleAtEnd(oneSaleId);
        uint256 before = seller.balance;
        _settleEditions(saleId);
        assertGt(seller.balance, before, "paid to the deployed wallet");
    }

    /// @dev A second adapter, a minter of Editions, cannot open an edition another adapter
    ///      created: `StreamEditions6529.create` refuses it, so one edition has one sale.
    function test_EditionAuction_ASecondAdapterCannotOpenAnExistingEdition() public {
        UniformEditionAuction second = _wiredEditionAuction();
        (, Work memory w,,, uint256 saleId) = _startMaster(artist, 0);
        uint256 tokenId = ea.auction(saleId).id;
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionExists.selector, tokenId));
        second.open(address(editions), tokenId, _openData(w));
        // Whichever adapter opens first holds the edition.
        (Work memory w2,, uint256 token2) = _startUnopened(artist, 0);
        second.open(address(editions), token2, _openData(w2));
        assertEq(editions.editionOf(token2).minter, address(second));
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionExists.selector, token2));
        editionAuction.open(address(editions), token2, _openData(w2));
    }

    /// @dev The network removes the adapter after its sale settled (and sealed the edition):
    ///      every winner still claims exactly the count, since a removed minter mints up to
    ///      the seal, and the removed adapter opens nothing new.
    function test_EditionAuction_ARemovedAdaptersWinnersStillClaim() public {
        (,, uint256 oneSaleId, uint256 tokenId, uint256 saleId) = _startMaster(artist, 10);
        address fan1 = makeAddr("fan1");
        address fan2 = makeAddr("fan2");
        _editionBid(saleId, fan1, 30, 6);
        _editionBid(saleId, fan2, 25, 8);
        _settleAtEnd(oneSaleId);
        _settleEditions(saleId);
        assertEq(ea.settlement(saleId).count, 10, "the cap binds");
        _asNetwork(
            address(editions), abi.encodeCall(editions.removeMinter, (address(editionAuction)))
        );
        assertFalse(editions.isMinter(address(editionAuction)));
        vm.prank(fan1);
        (uint256 won1,) = editionAuction.claimBid(saleId, 1, fan1);
        vm.prank(fan2);
        (uint256 won2,) = editionAuction.claimBid(saleId, 2, fan2);
        assertEq(won1 + won2, 10);
        assertEq(editions.editionOf(tokenId).minted, 10);
        assertEq(editions.balanceOf(fan1, tokenId) + editions.balanceOf(fan2, tokenId), 10);

        (Work memory w2,, uint256 token2) = _startUnopened(artist, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IModules.NotMinter.selector, address(editionAuction))
        );
        editionAuction.open(address(editions), token2, _openData(w2));
    }

    /// @dev R16: an upheld dispute burns the master; the abandonment floor is the stored close
    ///      plus 21 days, and abandoning voids the sale (sealed at zero, refunds in full).
    function test_EditionAuction_AbandonOnlyAfterTheFloor() public {
        (,, uint256 oneSaleId, uint256 tokenId, uint256 saleId) = _startMaster(artist, 0);
        address fan = makeAddr("fan");
        _editionBid(saleId, fan, 40, 2);
        uint256 close = ea.endTimes(saleId).closeAt;
        _cancelOneOfOne(oneSaleId, tokenId);
        vm.warp(close + 21 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
        editionAuction.abandon(saleId);
        vm.warp(close + 21 days);
        vm.expectEmit(address(editions));
        emit IEditions.EditionSupplySealed(tokenId, 0);
        vm.prank(makeAddr("anyone"));
        editionAuction.abandon(saleId);
        assertEq(uint8(ea.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        uint256 escrowed = 2 * ea.stepPrice(saleId, 40);
        vm.prank(fan);
        (uint256 won, uint256 refund) = editionAuction.claimBid(saleId, 1, fan);
        assertEq(won, 0);
        assertEq(refund, escrowed);
        assertEq(fan.balance, escrowed, "refunded in full");
    }

    /// @dev A sale whose 1/1 settles normally is never abandonable, however late.
    function test_EditionAuction_ASettledOneOfOneIsNeverAbandoned() public {
        (,, uint256 oneSaleId,, uint256 saleId) = _startMaster(artist, 0);
        _editionBid(saleId, makeAddr("fan"), 40, 2);
        _settleAtEnd(oneSaleId);
        vm.warp(ea.endTimes(saleId).endTime + 400 days);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
        editionAuction.abandon(saleId);
        _settleEditions(saleId);
        (uint256 won,) = editionAuction.claimBidFor(saleId, 1);
        assertEq(won, 2);
    }
}

/// @notice `adopt` and `rebind` on the deployed stack: the network moves an edition its sale
///         contract never sealed to another adapter `rebindDelay` (14 days
///         at launch, read when the rebind is attempted) after the first one's removal; the old
///         sale then voids with full refunds, and the new adapter adopts the edition and sells
///         it. Refused before the delay, by anyone but the network, and for an edition with
///         a seal.
contract EditionAuctionRebindTest is EditionAuctionStack {
    address internal artist;
    address internal collector = makeAddr("rebindCollector");
    address internal fan = makeAddr("rebindFan");
    address internal stranger = makeAddr("rebindStranger");
    UniformEditionAuction internal second;
    IUniformEditionAuction internal sv;

    function setUp() public override {
        super.setUp();
        artist = _actor("rebindArtist");
        second = _wiredEditionAuction();
        sv = IUniformEditionAuction(address(second));
    }

    /// @dev A master whose 1/1 sold and settled, with an edition bid on the genesis adapter
    ///      left unsettled.
    function _soldMasterWithAnOpenEditionSale()
        internal
        returns (Work memory w, uint256 tokenId, uint256 saleId)
    {
        uint256 oneSaleId;
        (, w, oneSaleId, tokenId, saleId) = _startMaster(artist, 0);
        _editionBid(saleId, fan, 40, 2);
        _ethBid(oneSaleId, collector, 1 ether);
        _settleAtEnd(oneSaleId);
    }

    function _removeGenesisAdapter() internal returns (uint256 removedAt) {
        removedAt = block.timestamp;
        _asNetwork(
            address(editions), abi.encodeCall(editions.removeMinter, (address(editionAuction)))
        );
    }

    function _rebindAsNetwork(uint256 tokenId) internal {
        vm.prank(network);
        editions.rebind(tokenId, address(second));
    }

    function _expectNotRebindable(uint256 tokenId) internal {
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, tokenId));
        editions.rebind(tokenId, address(second));
    }

    function test_Rebind_TheNetworkMovesAnUnsoldEditionAndTheNewAdapterSellsIt() public {
        (Work memory w, uint256 tokenId, uint256 saleId) = _soldMasterWithAnOpenEditionSale();
        // Adopt is refused while the edition is the genesis adapter's.
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.InvalidSaleTerms.selector, address(editions), tokenId
            )
        );
        second.adopt(address(editions), tokenId, _openData(w));

        uint256 removedAt = _removeGenesisAdapter();
        vm.warp(removedAt + 14 days - 1);
        _expectNotRebindable(tokenId);
        vm.warp(removedAt + 14 days);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        editions.rebind(tokenId, address(second));
        // Only to an active minter.
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, tokenId));
        editions.rebind(tokenId, stranger);

        vm.expectEmit(address(editions));
        emit IEditions.EditionRebound(tokenId, address(editionAuction), address(second));
        _rebindAsNetwork(tokenId);
        assertEq(editions.editionOf(tokenId).minter, address(second));

        // The old sale voids at settlement: the fan's bid comes back in full, nothing is
        // paid, and the edition is left unsealed for its new adapter.
        uint256 feeBefore = networkFee.balance;
        assertTrue(editionAuction.settle(saleId, new uint256[](0)));
        assertEq(uint8(ea.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertFalse(editions.editionOf(tokenId).supplySealed);
        vm.prank(fan);
        (uint256 won, uint256 refund) = editionAuction.claimBid(saleId, 1, fan);
        assertEq(won, 0);
        assertEq(refund, 2 * ea.stepPrice(saleId, 40));
        assertEq(networkFee.balance, feeBefore);

        // Adopt: the network only; the master's sale ended, so the sale runs on its own.
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        second.adopt(address(editions), tokenId, _openData(w));
        vm.prank(network);
        uint256 adopted = second.adopt(address(editions), tokenId, _openData(w));
        IUniformEditionAuction.EndTimes memory e = sv.endTimes(adopted);
        assertEq(e.closeAt, block.timestamp + 1 days + 15 minutes, "runs a day on its own");
        address buyer = makeAddr("adoptedBuyer");
        uint256 price = 3 * sv.stepPrice(adopted, 50);
        vm.deal(buyer, price);
        vm.prank(buyer);
        second.bid{ value: price }(adopted, 50, 3);
        _settleEditionsOn(second, adopted);
        assertEq(sv.settlement(adopted).count, 3);
        vm.prank(buyer);
        (won,) = second.claimBid(adopted, 1, buyer);
        assertEq(won, 3);
        assertEq(editions.balanceOf(buyer, tokenId), 3, "minted by the new adapter");
        assertEq(editions.editionOf(tokenId).maxSupply, 3, "sealed by the new adapter");
    }

    /// @dev `rebindDelay` is read when the rebind is attempted: lowered after the removal, it
    ///      applies at once; raised, it holds a rebind the old value would allow.
    function test_Rebind_TheDelayIsReadAtTheAttempt() public {
        (, uint256 tokenA,) = _soldMasterWithAnOpenEditionSale();
        (, uint256 tokenB,) = _soldMasterWithAnOpenEditionSale();
        uint256 removedAt = _removeGenesisAdapter();
        vm.warp(removedAt + 7 days);
        _expectNotRebindable(tokenA);
        _asNetwork(address(editions), abi.encodeCall(editions.setRebindDelay, (7 days)));
        _rebindAsNetwork(tokenA);
        assertEq(editions.editionOf(tokenA).minter, address(second));

        _asNetwork(address(editions), abi.encodeCall(editions.setRebindDelay, (30 days)));
        vm.warp(removedAt + 14 days);
        _expectNotRebindable(tokenB);
        vm.warp(removedAt + 30 days);
        _rebindAsNetwork(tokenB);
        assertEq(editions.editionOf(tokenB).minter, address(second));
    }

    /// @dev An edition with copies, or sealed at zero by a sale without bids, never moves; nor
    ///      one whose minter was never removed.
    function test_Rebind_RefusedForCopiesASealOrAnActiveMinter() public {
        (,, uint256 soldOne, uint256 sold, uint256 soldSale) = _startMaster(artist, 0);
        _editionBid(soldSale, fan, 40, 2);
        (,, uint256 emptyOne, uint256 empty, uint256 emptySale) = _startMaster(artist, 0);
        _settleAtEnd(soldOne);
        _settleAtEnd(emptyOne);
        _settleEditions(soldSale);
        _settleEditions(emptySale);
        editionAuction.claimBidFor(soldSale, 1);
        assertEq(editions.editionOf(sold).minted, 2);
        assertTrue(editions.editionOf(empty).supplySealed);
        (, uint256 unsold,) = _soldMasterWithAnOpenEditionSale();

        vm.warp(block.timestamp + 30 days);
        _expectNotRebindable(unsold);
        _removeGenesisAdapter();
        vm.warp(block.timestamp + 30 days);
        _expectNotRebindable(sold);
        _expectNotRebindable(empty);
        _rebindAsNetwork(unsold);
    }
}
