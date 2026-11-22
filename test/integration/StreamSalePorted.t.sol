// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEnglishAuctionRefusal } from "src/interfaces/IEnglishAuctionRefusal.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { MintFacts, MintTerms, Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IModules } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_STREAM
} from "src/interfaces/types/EconomicsTypes.sol";
import { SaleTerms, StreamMintRequest } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice A second 1/1 sale method for 6529 Stream, as a test double: a minter the network adds
///         (`addMinter`, active after the module delay) that asks the package registry, the
///         Stream mint policy, to authorize a request and sells only items naming its own kind.
///         It can sell at a fixed price in ETH, or be driven step by step (settle with an outcome,
///         burn, hand a work out of custody) by the state suite.
contract PortedSaleAdapter {
    uint256 internal constant DENOMINATOR = 100_000;

    error SaleKindMismatch(bytes32 saleKind);
    error WrongCurrency(address currency);
    error WrongPrice(uint256 paid, uint256 price);
    error PayFailed(address to);

    bytes32 public immutable KIND;
    IMintPolicy public immutable policy;

    mapping(uint256 tokenId => MintTerms) internal _terms;

    constructor(bytes32 kind, IMintPolicy policy_) {
        KIND = kind;
        policy = policy_;
    }

    /// @notice Authorizes `request` with the policy and mints the work into this contract.
    function start(address token, bytes calldata request) public returns (uint256 tokenId) {
        (MintFacts memory f, MintTerms memory t) = policy.authorize(token, request);
        if (t.saleKind != KIND) revert SaleKindMismatch(t.saleKind);
        tokenId = IStream(token).mint(address(this), f);
        _terms[tokenId] = t;
    }

    /// @notice Buys the item at the price its sale params name, in ETH only: the network's
    ///         share to its fee recipient, the rest to the seller, the outcome recorded, the work
    ///         delivered to the buyer.
    function buy(address token, bytes calldata request) external payable returns (uint256 id) {
        StreamMintRequest memory req = abi.decode(request, (StreamMintRequest));
        if (req.item.sale.currency != CURRENCY_ETH) revert WrongCurrency(req.item.sale.currency);
        id = start(token, request);
        MintTerms memory t = _terms[id];
        uint256 price = abi.decode(t.params, (uint256));
        if (msg.value != price) revert WrongPrice(msg.value, price);
        uint256 fee = price * t.feeShare / DENOMINATOR;
        _pay(t.feeRecipient, fee);
        _pay(t.seller, price - fee);
        IStream(token).recordPrimarySale(id, true, msg.sender, price);
        IERC721(token).transferFrom(address(this), msg.sender, id);
    }

    function terms(uint256 tokenId) external view returns (MintTerms memory) {
        return _terms[tokenId];
    }

    function settleWith(address token, uint256 id, bool sold, address buyer) external {
        IStream(token).recordPrimarySale(id, sold, buyer, sold ? 1 : 0);
    }

    function burn(address token, uint256 id) external {
        IStream(token).burn(id);
    }

    function deliver(address token, uint256 id, address to) external {
        IERC721(token).transferFrom(address(this), to, id);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    function _pay(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert PayFailed(to);
    }
}

/// @notice Re-ported from `StreamSaleMethods` and `StreamSaleNeverRefused` (owner decision 15,
///         AUC-38) onto the deployed plain-core stack.
///         - 6529 Stream's 1/1 sale is pluggable: a sale method added after launch is a minter
///           the network adds (immediate, active after the 7-day module delay) with no new
///           Stream; it sells exactly the items naming its kind, end to end. Removing a minter
///           stops its new sales and never strands a live one.
///         - A 6529 Stream sale is never closed as refused: `settleOrRefund` is shut for Stream
///           whatever happens to its dependencies, and a gas-starved call changes nothing.
contract StreamSalePortedTest is IntegrationBase {
    uint256 internal constant PRICE = 0.5 ether;
    bytes32 internal constant FIXED_PRICE = keccak256("FIXED_PRICE_1OF1");

    PortedSaleAdapter internal fixedPrice;
    address internal artist;
    address internal buyer = makeAddr("fixedPriceBuyer");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("saleMethodArtist");
        fixedPrice = new PortedSaleAdapter(FIXED_PRICE, registry);
        Work[] memory works = new Work[](4);
        works[0] = _work(artist, collectionId);
        works[0].item.sale = SaleTerms(FIXED_PRICE, CURRENCY_ETH, abi.encode(PRICE));
        works[1] = _work(artist, collectionId); // an English-auction work
        works[2] = _work(artist, collectionId);
        works[2].item.sale = SaleTerms(FIXED_PRICE, CURRENCY_ETH, abi.encode(PRICE));
        works[3] = _work(artist, collectionId); // the fixed-price kind, but not in ETH
        works[3].item.sale = SaleTerms(FIXED_PRICE, CURRENCY_DEFAULT, abi.encode(PRICE));
        root = _publish(works);
        _keep(root, works);
    }

    /// @dev The network adds `minter` to 6529 Stream and waits out the module delay.
    function _addMinter(address minter) internal {
        _asNetwork(address(stream), abi.encodeCall(IModules.addMinter, (minter)));
        vm.warp(stream.minterOf(minter).activeFrom);
    }

    function _buy(uint256 index) internal returns (uint256) {
        bytes memory data = _mintData(root, _package(root), index);
        vm.deal(buyer, PRICE);
        vm.prank(buyer);
        return fixedPrice.buy{ value: PRICE }(address(stream), data);
    }

    // ------------------------------------------------------------------ sale methods

    /// @dev At genesis only the English auction mints on Stream; adding one is the network's
    ///      immediate call, the minter active after the module delay (7 days at launch).
    function test_GenesisAddsOnlyTheEnglishAuction() public view {
        assertTrue(stream.isMinter(address(auction)));
        assertFalse(stream.isMinter(address(fixedPrice)));
        (bool immediate,) = manager.canCall(network, address(stream), IModules.addMinter.selector);
        assertTrue(immediate, "the network's immediate call");
        assertEq(stream.moduleDelay(), 7 days, "active after the module delay");
    }

    /// @dev A minter not added, or added and still waiting, is refused by the policy, even for
    ///      an item that names its kind; nothing mints.
    function test_AnUnaddedOrWaitingMinterIsRefused() public {
        bytes memory data = _mintData(root, _package(root), 0);
        bytes memory refused = abi.encodeWithSelector(
            IMintPolicy.NotSaleContract.selector, address(stream), address(fixedPrice)
        );
        vm.deal(buyer, 2 * PRICE);
        vm.prank(buyer);
        vm.expectRevert(refused);
        fixedPrice.buy{ value: PRICE }(address(stream), data);

        _asNetwork(address(stream), abi.encodeCall(IModules.addMinter, (address(fixedPrice))));
        vm.warp(stream.minterOf(address(fixedPrice)).activeFrom - 1);
        vm.prank(buyer);
        vm.expectRevert(refused);
        fixedPrice.buy{ value: PRICE }(address(stream), data);
        assertEq(stream.totalMinted(), 0, "nothing minted");
    }

    /// @dev Stream and its policy leave an item's currency to its sale method: this ETH-only
    ///      method refuses an item naming any other, and nothing mints.
    function test_TheMethodRefusesACurrencyItDoesNotTake() public {
        _addMinter(address(fixedPrice));
        bytes memory data = _mintData(root, _package(root), 3);
        vm.deal(buyer, PRICE);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(PortedSaleAdapter.WrongCurrency.selector, CURRENCY_DEFAULT)
        );
        fixedPrice.buy{ value: PRICE }(address(stream), data);
        assertEq(stream.totalMinted(), 0, "nothing minted");
    }

    /// @dev A second sale method, added after launch, sells a 6529 Stream 1/1 end to end: it
    ///      mints into its custody, takes the item's price, pays the network's share and the
    ///      artist's split, records the sale and delivers the work. Each method sells only its
    ///      own kind.
    function test_ASecondMinterSellsAWorkEndToEnd() public {
        _addMinter(address(fixedPrice));
        Work[] memory works = _package(root);
        address feeRecipient = economics.networkFeeRecipient(PRODUCT_STREAM);
        uint256 feeBefore = feeRecipient.balance;
        uint256 tokenId = _buy(0);

        assertEq(stream.ownerOf(tokenId), buyer);
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.SOLD));
        MintTerms memory t = fixedPrice.terms(tokenId);
        assertEq(t.saleKind, FIXED_PRICE);
        uint256 fee = feeRecipient.balance - feeBefore;
        assertEq(fee, PRICE * t.feeShare / 100_000, "the network's share");
        assertGt(fee, 0);
        assertEq(t.seller.balance, PRICE - fee, "the artist's split");
        // A full 6529 Stream work: its record opens like any other.
        _open(tokenId, works[0]);
        assertTrue(facts.factsOf(address(stream), tokenId).opened);

        // The English auction cannot start this method's item, nor this method an English one.
        bytes memory data = _mintData(root, works, 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.InvalidSaleTerms.selector, address(stream), uint256(0)
            )
        );
        auction.start(address(stream), data);
        data = _mintData(root, works, 1);
        vm.deal(buyer, PRICE);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                PortedSaleAdapter.SaleKindMismatch.selector, SaleKind.ENGLISH_AUCTION
            )
        );
        fixedPrice.buy{ value: PRICE }(address(stream), data);
    }

    /// @dev The English auction works exactly as before beside a second minter.
    function test_TheEnglishAuctionIsUnchangedBesideASecondMinter() public {
        _addMinter(address(fixedPrice));
        (uint256 saleId, uint256 tokenId) = _start(root, _package(root), 1);
        address bidder = makeAddr("englishBidder");
        _ethBid(saleId, bidder, 1 ether);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), bidder);
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.SOLD));
    }

    /// @dev Removing a minter stops its new sales at once and never strands a live one: the
    ///      network removes the English auction itself while an auction with a bid runs; no new
    ///      auction starts, and the running one still settles to its winner (a removed minter
    ///      still records the sales it holds).
    function test_RemovingAMinterStopsNewSalesButNeverStrandsALiveOne() public {
        Work[] memory works = _package(root);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 1);
        address bidder = makeAddr("liveBidder");
        _ethBid(saleId, bidder, 1 ether);

        _asNetwork(address(stream), abi.encodeCall(IModules.removeMinter, (address(auction))));
        assertFalse(stream.isMinter(address(auction)));
        Work memory next = _work(artist, collectionId);
        bytes32 nextRoot = _publish(_one(next));
        bytes memory data = _mintData(nextRoot, _one(next), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintPolicy.NotSaleContract.selector, address(stream), address(auction)
            )
        );
        auction.start(address(stream), data);

        _settleAtEnd(saleId);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(stream.ownerOf(tokenId), bidder);
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.SOLD));
    }

    // ------------------------------------------------------------------ never refused

    /// @dev An edition master whose 1/1 is started and whose edition sale is open.
    function _startMaster(address lead)
        internal
        returns (uint256 oneSaleId, uint256 tokenId, uint256 editionSale)
    {
        Work[] memory works = _one(_asMaster(_work(lead, collectionId), 10));
        bytes32 masterRoot = _publish(works);
        (oneSaleId, tokenId) = _start(masterRoot, works, 0);
        editionSale = editionAuction.open(
            address(editions), tokenId, abi.encode(works[0].item, masterRoot, _proofOf(works, 0))
        );
    }

    /// @dev The review's reproduction: Stream's economics resolver `museum()` reverts. An unbid
    ///      master's `settle` fails, and `settleOrRefund` refuses a Stream sale for 60 days and
    ///      beyond; once the dependency answers again the work goes to the museum, the edition
    ///      sale settles and the edition bidder gets the copy.
    function test_AnUnbidMasterWhoseDependencyFailsIsNeverRefused() public {
        address fan = makeAddr("neverRefusedFan");
        (uint256 oneSaleId, uint256 tokenId, uint256 editionSale) =
            _startMaster(_actor("neverRefusedArtist"));
        IUniformEditionAuction ea = IUniformEditionAuction(address(editionAuction));
        uint256 price = ea.stepPrice(editionSale, 40);
        vm.deal(fan, price);
        vm.prank(fan);
        uint256 bidId = ea.bid{ value: price }(editionSale, 40, 1);

        vm.warp(auction.auction(oneSaleId).endTime);
        vm.mockCallRevert(
            address(economics), abi.encodeWithSelector(IEconomicsResolver.museum.selector), ""
        );
        vm.expectRevert();
        auction.settle(oneSaleId);
        bytes memory refused =
            abi.encodeWithSelector(IEnglishAuctionRefusal.SaleNotRefusable.selector, oneSaleId);
        vm.expectRevert(refused);
        auction.refusableAt(oneSaleId);
        for (uint256 day = 1; day <= 60; day += 7) {
            vm.warp(auction.auction(oneSaleId).endTime + day * 1 days);
            vm.expectRevert(refused);
            auction.settleOrRefund(oneSaleId);
        }
        assertEq(stream.ownerOf(tokenId), address(auction), "still in custody");
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.NONE));

        vm.clearMockedCalls();
        auction.settle(oneSaleId);
        assertEq(stream.ownerOf(tokenId), museum, "the unsold work went to the museum");
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.UNSOLD));
        assertTrue(ea.settle(editionSale, new uint256[](0)));
        vm.prank(fan);
        (uint256 won,) = ea.claimBid(editionSale, bidId, fan);
        assertEq(won, 1, "the edition bidder's copy");
        assertEq(editions.balanceOf(fan, tokenId), 1);
    }

    /// @dev A keeper sending too little gas cannot refuse a Stream sale with a bid: the exit is
    ///      shut before any gas check. A `settle` with too little gas either reverts and changes
    ///      nothing, or completes the sale to the winner (the plain core's settle needs less
    ///      than the retired one; the delivery's own gas is checked before it is sent); it never
    ///      closes the sale any other way. A full `settle` then sells.
    function test_AGasStarvedCallCannotRefuseAStreamSale() public {
        (uint256 oneSaleId, uint256 tokenId,) = _startMaster(_actor("starvedArtist"));
        address winner = makeAddr("neverRefusedWinner");
        _ethBid(oneSaleId, winner, 1 ether);
        vm.warp(auction.auction(oneSaleId).endTime + 30 days);
        uint256 reverted;
        for (uint256 limit = 50_000; limit <= 400_000; limit += 50_000) {
            (bool ok, bytes memory data) = address(auction).call{ gas: limit }(
                abi.encodeCall(IEnglishAuctionRefusal.settleOrRefund, (oneSaleId))
            );
            assertFalse(ok, "never succeeds");
            assertEq(bytes4(data), IEnglishAuctionRefusal.SaleNotRefusable.selector);
            uint256 snapshot = vm.snapshotState();
            (ok,) = address(auction).call{ gas: limit }(
                abi.encodeCall(IEnglishAuction.settle, (oneSaleId))
            );
            if (ok) {
                assertEq(stream.ownerOf(tokenId), winner, "a starved settle that lands sells");
                assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.SOLD));
                assertEq(auction.claimable(winner), 0);
            } else {
                ++reverted;
                assertEq(
                    uint8(auction.auction(oneSaleId).state),
                    uint8(IEnglishAuction.AuctionState.ENDED),
                    "nothing changed"
                );
                assertEq(stream.ownerOf(tokenId), address(auction));
            }
            vm.revertToStateAndDelete(snapshot);
        }
        assertGt(reverted, 0, "the smallest budgets revert");
        auction.settle(oneSaleId);
        assertEq(stream.ownerOf(tokenId), winner, "sold");
        assertEq(auction.claimable(winner), 0, "nothing credited back");
    }
}
