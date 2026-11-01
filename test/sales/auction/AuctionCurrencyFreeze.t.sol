// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { SalesStackBase } from "../SalesStackBase.sol";

/// @notice An English auction whose currency is deprecated, on the real stack: the deprecation
///         freezes the auction, not just its bids. The currency is an ERC-20: ETH is never
///         deprecated (`EthNotDeprecable`, the rc.2 review's MONEY-M1 and G-2), which the first
///         tests pin. While frozen nothing settles, sold or unsold,
///         and a standing bidder may withdraw (the bid stays as the reserve). Once the currency
///         is re-admitted (no sooner than 14 days after the deprecation), the first `settle`
///         reopens the auction for the governed duration. A currency deprecated for 30 days lets
///         anyone end the sale unsold: the bid is credited back and the work goes where an unbid
///         work goes, the 6529 Network Museum (D140, ADR 0005 owner decision 10; under rc.1 its
///         artist).
contract AuctionCurrencyFreezeTest is SalesStackBase {
    address internal alice = makeAddr("lowBidder");
    address internal bob = makeAddr("realBidder");
    /// @dev A package of plain 1/1s priced in the test ERC-20.
    bytes32 internal usdRoot;

    function setUp() public override {
        super.setUp();
        _admitUsd();
        Work[] memory works = new Work[](2);
        works[0] = _work(artist, collectionId);
        works[1] = _work(artist, collectionId);
        usdRoot = _publish(_inUsd(works));
        _keep(usdRoot, works);
    }

    /// @dev An ERC-20 sale of item `index` of the ERC-20 package.
    function _startUsd(uint256 index) internal returns (uint256 saleId, uint256 tokenId) {
        (saleId, tokenId) = _start(usdRoot, _package(usdRoot), index);
    }

    function _freezeAnHourBeforeTheEnd() internal returns (uint256 saleId, uint256 tokenId) {
        (saleId, tokenId) = _startUsd(0);
        _usdBid(saleId, alice, 10e18);
        vm.warp(auction.auction(saleId).endTime - 1 hours);
        _deprecateUsd();
    }

    function _readmit() internal {
        _readmitUsd();
    }

    function _bobBids(uint256 saleId, uint256 amount) internal {
        _usdBid(saleId, bob, amount);
    }

    // ------------------------------------------------------- ETH is never deprecated (F2)

    /// Regression: MONEY-M1 and G-2 in the rc.2 review
    /// @dev One guardian (GUARDIAN, immediate) cannot deprecate ETH, so it cannot freeze a live
    ///      ETH 1/1 that has a winning bid and, 30 days later, end it unsold into the museum: the
    ///      sale settles to its winner and pays its seller, and every later ETH sale runs.
    function test_DeprecateAsset_OneGuardianCannotFreezeEthSales() public {
        (uint256 saleId, uint256 tokenId) = _start(root, _package(root), 2);
        address winner = makeAddr("ethWinner");
        _ethBid(saleId, winner, 5 ether);
        address seller = stream.primaryTerms(tokenId, "").seller;
        uint256 sellerBefore = seller.balance;

        vm.prank(guardian1);
        vm.expectRevert(IAssetAllowlist.EthNotDeprecable.selector);
        allowlist.deprecateAsset(CURRENCY_ETH);
        assertTrue(allowlist.isActive(CURRENCY_ETH));

        // The freeze exit never opens: the sale settles to its winner as soon as it ends.
        vm.warp(block.timestamp + 30 days);
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), winner, "the winning bidder keeps the work it won");
        assertTrue(seller.balance > sellerBefore, "the artist's wallet is paid");
        assertEq(auction.claimable(winner, CURRENCY_ETH), 0, "nothing is refunded");
    }

    /// Regression: MONEY-M1 and G-2 in the rc.2 review
    /// @dev No role can deprecate ETH, through any governance path: the AccessManager executes
    ///      the call, and the allowlist refuses it.
    function test_DeprecateAsset_EthIsRefusedThroughGovernance() public {
        bytes memory call = abi.encodeCall(allowlist.deprecateAsset, (CURRENCY_ETH));
        vm.prank(guardian2);
        vm.expectRevert(IAssetAllowlist.EthNotDeprecable.selector);
        manager.execute(address(allowlist), call);
        (IAssetAllowlist.Status status,,) = allowlist.statusClock(CURRENCY_ETH);
        assertEq(uint8(status), uint8(IAssetAllowlist.Status.Active));
    }

    /// Regression: MARKET-2 (docs/security/internal-review-2026-10.md)
    function test_Settle_AFrozenAuctionWaitsAndReopensAfterReadmission() public {
        (uint256 saleId, uint256 tokenId) = _freezeAnHourBeforeTheEnd();
        usd.mint(bob, 100e18);
        vm.startPrank(bob);
        usd.approve(address(auction), 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, address(usd))
        );
        auction.bid(saleId, address(0), Payment(PaymentMethod.DIRECT, bob, 100e18, 0, 0, ""));
        vm.stopPrank();

        // The clock runs out, but the standing bid cannot settle while the currency is frozen.
        vm.warp(auction.auction(saleId).endTime);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, address(usd))
        );
        auction.settle(saleId);

        // Re-admission takes 14 days; the first settle then reopens the auction.
        _readmit();
        uint256 reopenedUntil = block.timestamp + AUCTION_DURATION;
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionResumed(saleId, uint64(reopenedUntil));
        auction.settle(saleId);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(a.endTime, reopenedUntil);
        assertEq(a.bidder, alice, "the standing bid is kept");

        _bobBids(saleId, 100e18);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), bob, "the real bidder wins");
    }

    /// Regression: MARKET-2 (docs/security/internal-review-2026-10.md)
    function test_WithdrawBid_WhileFrozenTheAuctionReopensForTheDurationWithAReserve() public {
        (uint256 saleId,) = _freezeAnHourBeforeTheEnd();
        vm.expectEmit(address(auction));
        emit IEnglishAuction.BidWithdrawn(saleId, alice, 10e18);
        vm.prank(alice);
        auction.withdrawBid(saleId);
        assertEq(auction.claimable(alice, address(usd)), 10e18, "claims never wait");
        vm.prank(alice);
        auction.claim(address(usd), alice);

        vm.warp(auction.auction(saleId).endTime + 1 days);
        _readmit();
        auction.settle(saleId);
        assertEq(auction.auction(saleId).endTime, block.timestamp + AUCTION_DURATION);
        assertEq(auction.minimumBid(saleId), 10e18, "the withdrawn bid is the reserve");
        _bobBids(saleId, 20e18);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(auction.auction(saleId).tokenId), bob);
    }

    /// Regression: MARKET-2 (docs/security/internal-review-2026-10.md)
    /// @dev Since ADR 0005 (owner decision 10) the released work goes to the museum, as an unbid
    ///      work does; under rc.1 it returned to its artist.
    function test_Settle_ACurrencyThatNeverReturnsReleasesTheWorkToTheMuseum() public {
        (uint256 saleId, uint256 tokenId) = _freezeAnHourBeforeTheEnd();
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        auction.withdrawBid(saleId);
        // With no standing bid there is nothing to pay: the work goes to the museum.
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), museum);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(usd.balanceOf(address(auction)), 10e18, "the credit is all the auction holds");
    }

    /// Regression: MARKET-2 (docs/security/internal-review-2026-10.md)
    function test_WithdrawBid_NeedsAPauseOrAFreeze() public {
        (uint256 saleId,) = _startUsd(0);
        _usdBid(saleId, alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ACTIVE
            )
        );
        auction.withdrawBid(saleId);
        // A settled sale's winner can never withdraw, even while the currency is frozen.
        _settleAtEnd(saleId);
        _deprecateUsd();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.SETTLED
            )
        );
        auction.withdrawBid(saleId);
    }

    /// Regression: MARKET-2 (docs/security/internal-review-2026-10.md)
    function test_Settle_AnAuctionStartedAfterAFreezeSettlesNormally() public {
        _deprecateUsd();
        _readmit();
        (uint256 saleId, uint256 tokenId) = _startUsd(0);
        _usdBid(saleId, alice, 10e18);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), alice, "no reopening for a freeze before the start");
    }

    /// Regression: MARKET-2 (docs/security/internal-review-2026-10.md); L2 in the review of #57
    /// @dev A deprecation that never ends, with a high bidder who never withdraws, no longer
    ///      holds the work: 30 days into the freeze anyone ends the sale unsold, the bid is
    ///      credited back and the work goes to the museum (ADR 0005, owner decision 10; under
    ///      rc.1 to its artist).
    function test_Settle_AFrozenSaleEndsUnsoldThirtyDaysIntoTheFreeze() public {
        (uint256 saleId, uint256 tokenId) = _startUsd(0);
        address passive = makeAddr("passiveBidder");
        _usdBid(saleId, passive, 100e18);
        uint256 frozenAt = _deprecateUsd();
        vm.warp(frozenAt + 30 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, address(usd))
        );
        auction.settle(saleId);
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NotHighBidder.selector, keeper));
        auction.withdrawBid(saleId);

        vm.warp(frozenAt + 30 days);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(passive, address(usd), saleId, 100e18);
        vm.prank(keeper);
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), museum, "the work goes to the museum");
        assertEq(stream.balanceOf(artist), 0, "not the artist");
        assertEq(auction.claimable(passive, address(usd)), 100e18, "the bid is credited back");
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(usd.balanceOf(address(auction)), 100e18, "only the credit is held");
    }

    /// Regression: MARKET-2 (docs/security/internal-review-2026-10.md); L3 in the review of #57
    /// @dev A withdrawal during a freeze does not let anyone end the auction unsold before
    ///      the currency returns (or the 30-day exit): the reopening keeps its promise.
    function test_Settle_NothingSettlesWhileFrozen() public {
        (uint256 saleId, uint256 tokenId) = _freezeAnHourBeforeTheEnd();
        vm.prank(alice);
        auction.withdrawBid(saleId);
        vm.warp(auction.auction(saleId).endTime);
        vm.prank(makeAddr("anyone"));
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, address(usd))
        );
        auction.settle(saleId);
        _readmit();
        auction.settle(saleId);
        assertEq(auction.auction(saleId).endTime, block.timestamp + AUCTION_DURATION);
        _bobBids(saleId, 20e18);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), bob, "sold after the currency returned");
    }

    /// Regression: MARKET-2 (docs/security/internal-review-2026-10.md); L7 in the review of #57
    /// @dev The reopening after a freeze is the governed duration, wherever the first settle
    ///      lands, so a standing low bidder cannot pick a quiet moment for a short window.
    function test_Settle_ReopeningAfterAFreezeIsTheDuration() public {
        (uint256 saleId, uint256 tokenId) = _startUsd(0);
        _usdBid(saleId, alice, 10e18);
        vm.warp(block.timestamp + 1 hours);
        _deprecateUsd();
        _readmit();
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        auction.settle(saleId);
        assertEq(auction.auction(saleId).endTime, block.timestamp + AUCTION_DURATION);
        vm.warp(block.timestamp + 12 hours);
        _bobBids(saleId, 20e18);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), bob);
    }

    /// Regression: MARKET-2 (docs/security/internal-review-2026-10.md); the review of #57
    /// @dev A re-admission scheduled before a deprecation, for its predictable revision, cannot
    ///      undo it in the same block: re-admission waits 14 days from the deprecation.
    function test_AdmitAsset_AReadmissionScheduledAheadCannotUndoADeprecation() public {
        (,, uint64 revision) = allowlist.assetConfig(address(usd));
        bytes memory admit =
            abi.encodeCall(allowlist.admitAsset, (address(usd), revision + 1, USD_FLOOR));
        _schedule(hotAdmin, address(allowlist), admit);
        vm.warp(block.timestamp + Roles.FUNDS);
        _deprecateUsd();
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetAllowlist.ReadmissionTooEarly.selector,
                address(usd),
                block.timestamp + Roles.FUNDS
            )
        );
        manager.execute(address(allowlist), admit);
        assertFalse(allowlist.isActive(address(usd)));
        // The guardians veto it; a fresh re-admission lands 14 days after the deprecation.
        vm.prank(guardian2);
        manager.cancel(hotAdmin, address(allowlist), admit);
        _readmitUsd();
        assertTrue(allowlist.isActive(address(usd)));
    }
}
