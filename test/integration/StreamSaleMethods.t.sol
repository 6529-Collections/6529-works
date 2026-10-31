// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { CURRENCY_ETH, PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import { SaleTerms } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { FixedPriceOneOfOneMock } from "../mocks/stream/OneOfOneSaleMocks.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Owner decision 15 on the real genesis deployment: 6529 Stream's 1/1 sale is pluggable.
///         A sale method added after launch is an adapter governance admits on Stream (the
///         30-day SUCCESSOR_SETTER class), with no new Stream; it sells exactly the items that
///         name its kind, end to end. Removing an adapter stops its new sales and never strands
///         a live one. The English auction, admitted at genesis, works as before.
contract StreamSaleMethodsTest is IntegrationBase {
    uint256 internal constant PRICE = 0.5 ether;

    FixedPriceOneOfOneMock internal fixedPrice;
    address internal artist;
    address internal buyer = makeAddr("fixedPriceBuyer");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("saleMethodArtist");
        fixedPrice = new FixedPriceOneOfOneMock();
        Work[] memory works = new Work[](3);
        works[0] = _work(artist, collectionId);
        works[0].item.sale = SaleTerms(fixedPrice.KIND(), CURRENCY_ETH, abi.encode(PRICE));
        works[1] = _work(artist, collectionId); // an English-auction work
        works[2] = _work(artist, collectionId);
        works[2].item.sale = SaleTerms(fixedPrice.KIND(), CURRENCY_ETH, abi.encode(PRICE));
        root = _publish(works);
        _keep(root, works);
    }

    function _admit(address adapter, bool admitted) internal {
        _govern(
            hotAdmin, address(stream), abi.encodeCall(stream.setAdmittedMinter, (adapter, admitted))
        );
    }

    /// @dev At genesis only the English auction mints; admission is a 30-day governed action.
    function test_GenesisAdmitsOnlyTheEnglishAuction() public view {
        assertTrue(stream.isAdmittedMinter(address(auction)));
        assertFalse(stream.isAdmittedMinter(address(fixedPrice)));
        (bool immediate, uint32 delay) =
            manager.canCall(hotAdmin, address(stream), stream.setAdmittedMinter.selector);
        assertFalse(immediate);
        assertEq(delay, 30 days, "the successor class");
    }

    /// @dev An unadmitted adapter is refused, even for an item that names its kind.
    function test_AnUnadmittedAdapterIsRefused() public {
        bytes memory data = _mintData(root, _package(root), 0);
        vm.deal(buyer, PRICE);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(fixedPrice))
        );
        fixedPrice.buy{ value: PRICE }(address(stream), data);
    }

    /// @dev A second sale method, admitted after launch, sells a 6529 Stream 1/1 end to end: it
    ///      mints into its custody, takes the item's price, pays the network fee and the artist's
    ///      split, delivers the work and settles the primary sale. Each adapter sells only its
    ///      own kind.
    function test_ASecondAdmittedAdapterSellsAWorkEndToEnd() public {
        _admit(address(fixedPrice), true);
        Work[] memory works = _package(root);
        bytes memory data = _mintData(root, works, 0);
        address feeRecipient = economics.networkFeeRecipient(PRODUCT_STREAM);
        uint256 feeBefore = feeRecipient.balance;
        vm.deal(buyer, PRICE);
        vm.prank(buyer);
        uint256 tokenId = fixedPrice.buy{ value: PRICE }(address(stream), data);

        assertEq(stream.ownerOf(tokenId), buyer);
        assertTrue(stream.primarySaleSettled(tokenId));
        assertEq(stream.primaryTerms(tokenId, "").saleKind, fixedPrice.KIND());
        address seller = stream.primaryTerms(tokenId, "").seller;
        uint256 fee = feeRecipient.balance - feeBefore;
        assertEq(fee, PRICE / 4, "the 25% network share");
        assertEq(seller.balance, PRICE - fee, "the artist's split");
        // The work is a full 6529 Stream work: its record opens like any other.
        records.openRecord(tokenId, works[0].item, works[0].media);
        assertTrue(records.isOpen(tokenId));

        // The English auction cannot start this sale method's item, nor the adapter an English
        // item.
        data = _mintData(root, works, 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintTarget.SaleKindMismatch.selector, fixedPrice.KIND(), SaleKind.ENGLISH_AUCTION
            )
        );
        auction.start(address(stream), data);
        data = _mintData(root, works, 1);
        vm.deal(buyer, PRICE);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintTarget.SaleKindMismatch.selector, SaleKind.ENGLISH_AUCTION, fixedPrice.KIND()
            )
        );
        fixedPrice.buy{ value: PRICE }(address(stream), data);
    }

    /// @dev The English auction works exactly as before beside a second adapter: it starts,
    ///      takes a bid and settles its own items, and reports its own kind.
    function test_TheEnglishAuctionIsUnchangedBesideASecondAdapter() public {
        _admit(address(fixedPrice), true);
        (uint256 saleId, uint256 tokenId) = _start(root, _package(root), 1);
        assertEq(stream.primaryTerms(tokenId, "").saleKind, SaleKind.ENGLISH_AUCTION);
        address bidder = makeAddr("englishBidder");
        _ethBid(saleId, bidder, 1 ether);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), bidder);
        assertTrue(stream.primarySaleSettled(tokenId));
    }

    /// @dev The de-admission rule: removing an adapter stops its new sales at once, and never
    ///      strands a live one. Here governance removes the English auction itself while an
    ///      auction with a bid is running: no new auction can start, and the running one still
    ///      settles to its winner, because Stream gates settlement on the adapter that minted
    ///      the token, not on its current admission.
    function test_RemovingAnAdapterStopsNewSalesButNeverStrandsALiveOne() public {
        Work[] memory works = _package(root);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 1);
        address bidder = makeAddr("liveBidder");
        _ethBid(saleId, bidder, 1 ether);

        _admit(address(auction), false); // 30 days: the auction has ended meanwhile
        assertFalse(stream.isAdmittedMinter(address(auction)));
        Work memory next = _work(artist, collectionId);
        bytes32 nextRoot = _publish(_one(next));
        _keep(nextRoot, _one(next));
        bytes memory data = _mintData(nextRoot, _one(next), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(auction))
        );
        auction.start(address(stream), data);

        auction.settle(saleId);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(stream.ownerOf(tokenId), bidder);
        assertTrue(stream.primarySaleSettled(tokenId));
    }
}
