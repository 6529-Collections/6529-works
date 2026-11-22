// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEnglishAuctionRefusal } from "src/interfaces/IEnglishAuctionRefusal.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { PrimaryOutcome, PrimarySettlement } from "src/interfaces/types/SaleTypes.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice A template copy that refuses to settle on demand: the same code plus a switch, so a
///         different code hash governance must approve, as an audit would a faulty version.
contract FaultyFederatedStream is FederatedStream {
    bool public refuse;

    constructor(Config memory c) FederatedStream(c) { }

    function setRefuse(bool on) external {
        refuse = on;
    }

    function settlePrimary(
        uint256 tokenId,
        PrimaryOutcome outcome,
        address buyer,
        address currency,
        uint256 price
    ) public override returns (PrimarySettlement memory) {
        require(!refuse, "refused");
        return super.settlePrimary(tokenId, outcome, buyer, currency, price);
    }
}

/// @notice The English auction's refused-settlement exit (AUC-45) end to end against the real
///         template (it never refuses: `settleOrRefund` settles exactly as `settle`, well inside
///         the refusal gas) and against a deliberately faulty one (the sale closes with the bid
///         credited back, and the work returns to the template's own custody and restarts).
contract FederatedRefusalTest is FederationBase {
    address internal collector = makeAddr("collector");

    /// @dev The auction's own measured worst case (AUC-47, guarantee 1).
    uint256 internal constant AUCTION_WORST_CASE = 2_434_325;

    function test_RealTemplate_SettleOrRefundSettlesExactlyAsSettle() public {
        _joinedFed();
        (uint256 saleId, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        _ethBid(saleId, collector, 1 ether);
        uint256 end = auction.auction(saleId).endTime;
        vm.warp(end);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuctionRefusal.RefusalTooEarly.selector, saleId, end + REFUSAL_DELAY
            )
        );
        auction.settleOrRefund(saleId);
        vm.warp(end + REFUSAL_DELAY);
        uint256 feeBefore = networkFee.balance;
        auction.settleOrRefund{ gas: 6_000_000 }(saleId);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(fed.ownerOf(tokenId), collector);
        assertEq(networkFee.balance - feeBefore, 0.1 ether, "fee paid inside the attempt");
        (PrimaryOutcome outcome,,) = fed.primarySale(tokenId);
        assertEq(uint8(outcome), uint8(PrimaryOutcome.SOLD));
    }

    /// @dev Guarantee 1: the whole settlement, token calls included, fits the refusal gas less
    ///      the auction's own worst case. Measured with a sold sale (the dearest path) whose
    ///      buyer is a contract (the delivery hook runs).
    function test_RealTemplate_SettlementFitsTheRefusalGasBudget() public {
        _joinedFed();
        (uint256 saleId,) = _startFed(_fedWork(fedArtist));
        _ethBid(saleId, collector, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        uint256 before = gasleft();
        auction.settle(saleId);
        uint256 used = before - gasleft();
        emit log_named_uint("federated settle gas (Prague)", used);
        assertLt(used, REFUSAL_GAS - AUCTION_WORST_CASE, "inside refusalGas - 2.43M");
    }

    function test_FaultyTemplate_RefusedSaleCreditsTheBidAndTheWorkComesHome() public {
        FaultyFederatedStream bad = _faulty();
        Work memory w = _fedWork(fedArtist);
        (uint256 saleId, uint256 tokenId) = _startFed(bad, fedArtist, w, RATE);
        _ethBid(saleId, collector, 1 ether);
        bad.setRefuse(true);
        uint256 end = auction.auction(saleId).endTime;
        vm.warp(end);
        vm.expectRevert(bytes("refused"));
        auction.settle(saleId);
        vm.warp(end + REFUSAL_DELAY);
        uint256 feeBefore = networkFee.balance;
        vm.expectEmit(address(auction));
        emit IEnglishAuctionRefusal.SettlementRefused(saleId);
        auction.settleOrRefund{ gas: 6_000_000 }(saleId);
        assertEq(auction.claimable(collector, CURRENCY_ETH), 1 ether, "the bid is credited back");
        assertEq(networkFee.balance, feeBefore, "no sale, no fee");
        assertEq(bad.ownerOf(tokenId), address(auction), "a pending delivery");
        // Only the template (the creator it reports) can take the work back, to itself.
        vm.prank(fedArtist);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        auction.claimDelivery(saleId, fedArtist);
        vm.expectEmit(address(bad));
        emit IFederatedStream.WorkReturned(tokenId);
        bad.reclaim(tokenId);
        assertEq(bad.ownerOf(tokenId), address(bad));
        (,, uint8 state) = bad.tokenInfo(tokenId);
        assertEq(state, 5, "returned");
        (PrimaryOutcome outcome,,) = bad.primarySale(tokenId);
        assertEq(uint8(outcome), uint8(PrimaryOutcome.NONE), "never settled");
        // Re-auctioned with the artist's fresh approval.
        bad.setRefuse(false);
        vm.prank(fedArtist);
        bad.approveItem(_itemHash(w), RATE);
        uint256 again = auction.start(address(bad), _mintData(w));
        assertEq(auction.auction(again).tokenId, tokenId + 1);
        _ethBid(again, collector, 2 ether);
        _settleAtEnd(again);
        assertEq(bad.ownerOf(tokenId + 1), collector);
        assertEq(networkFee.balance - feeBefore, 0.2 ether, "the network paid on the real sale");
    }

    function test_FaultyTemplate_AnUnbidRefusedSaleAlsoComesHome() public {
        FaultyFederatedStream bad = _faulty();
        (uint256 saleId, uint256 tokenId) = _startFed(bad, fedArtist, _fedWork(fedArtist), RATE);
        bad.setRefuse(true);
        vm.warp(auction.auction(saleId).endTime + REFUSAL_DELAY);
        auction.settleOrRefund{ gas: 6_000_000 }(saleId);
        bad.reclaim(tokenId);
        assertEq(bad.ownerOf(tokenId), address(bad));
    }

    function test_Reclaim_OnlyAnUnsettledTokenHeldByItsAdapter() public {
        _joinedFed();
        (uint256 saleId, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        _ethBid(saleId, collector, 1 ether);
        // No pending delivery while the sale runs.
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        fed.reclaim(tokenId);
        _settleAtEnd(saleId);
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.WorkNotRestartable.selector, 1));
        fed.reclaim(tokenId);
    }

    /// @dev A token that was never minted has nothing to reclaim.
    function test_Reclaim_RefusesATokenNeverMinted() public {
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.WorkNotRestartable.selector, 0));
        fed.reclaim(999);
    }

    /// @dev A token its adapter burned (a cancelled sale) is unsettled but no longer held by the
    ///      adapter: nothing to reclaim, refused before any call to the adapter.
    function test_Reclaim_RefusesATokenItsAdapterBurned() public {
        _joinedFed();
        (, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        vm.prank(address(auction));
        fed.burn(tokenId, 1);
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.WorkNotRestartable.selector, 1));
        fed.reclaim(tokenId);
    }

    /// @dev The recorded sale price is capped at 2**96 - 1, the width it is stored in, rather
    ///      than wrapping; prices below the cap are kept exactly.
    function test_SettlePrimary_RecordsAPriceAboveTheStoredWidthAsTheCap() public {
        _joinedFed();
        (, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        uint256 huge = uint256(type(uint96).max) + 5;
        vm.prank(address(auction));
        fed.settlePrimary(tokenId, PrimaryOutcome.SOLD, collector, address(0), huge);
        (PrimaryOutcome outcome, address currency, uint256 price) = fed.primarySale(tokenId);
        assertEq(uint8(outcome), uint8(PrimaryOutcome.SOLD));
        assertEq(currency, address(0));
        assertEq(price, type(uint96).max);
        (, uint256 second) = _startFed(_fedWork(fedArtist));
        vm.prank(address(auction));
        fed.settlePrimary(second, PrimaryOutcome.SOLD, collector, address(0), 3 ether);
        (,, price) = fed.primarySale(second);
        assertEq(price, 3 ether);
    }

    function test_OnERC721Received_RefusesEverythingButItsOwnReturn() public {
        _joinedFed();
        (uint256 saleId, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
        bytes memory refused =
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(fed));
        vm.prank(collector);
        vm.expectRevert(refused);
        fed.safeTransferFrom(collector, address(fed), tokenId);
        vm.expectRevert(refused);
        fed.onERC721Received(address(auction), address(auction), tokenId, "");
    }

    function _faulty() internal returns (FaultyFederatedStream bad) {
        bad = FaultyFederatedStream(
            _copy(type(FaultyFederatedStream).creationCode, abi.encode(_streamConfig(fedArtist)))
        );
        _approveTemplate(
            fedRegistry,
            type(FaultyFederatedStream).creationCode,
            address(bad).codehash,
            99,
            IFederationRegistry.Form.ERC721
        );
        _join(address(bad), fedArtist);
    }
}
