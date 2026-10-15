// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { MarketPoCBase } from "./MarketPoCBase.sol";

/// @notice MARKET-2 regression, on the real stack: deprecating an auction's currency freezes the
///         auction, not just its bids. While frozen nothing settles, sold or unsold, and a
///         standing bidder may withdraw (the bid stays as the reserve). Once the currency is
///         re-admitted, the first `settle` reopens the auction for the governed duration. A
///         currency deprecated for 30 days lets anyone end the sale unsold: the bid is credited
///         back and the work goes to its artist.
contract Market2RegressionTest is MarketPoCBase {
    address internal alice = makeAddr("lowBidder");
    address internal bob = makeAddr("realBidder");

    function _freezeAnHourBeforeTheEnd() internal returns (uint256 saleId, uint256 tokenId) {
        Work[] memory works = _package(root);
        (saleId, tokenId) = _start(root, works, 2);
        _ethBid(saleId, alice, 0.01 ether);
        vm.warp(auction.auction(saleId).endTime - 1 hours);
        _govern(
            guardian1, address(allowlist), abi.encodeCall(allowlist.deprecateAsset, (CURRENCY_ETH))
        );
    }

    function _readmit() internal {
        (,, uint64 revision) = allowlist.assetConfig(CURRENCY_ETH);
        _govern(
            hotAdmin,
            address(allowlist),
            abi.encodeCall(allowlist.admitAsset, (CURRENCY_ETH, revision, 0.001 ether))
        );
    }

    function _bobBids(uint256 saleId, uint256 amount) internal {
        vm.deal(bob, amount);
        vm.prank(bob);
        auction.bid{ value: amount }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, bob, amount, 0, 0, "")
        );
    }

    function test_MARKET2_FrozenAuctionWaitsAndReopensAfterReadmission() public {
        (uint256 saleId, uint256 tokenId) = _freezeAnHourBeforeTheEnd();
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, CURRENCY_ETH)
        );
        auction.bid{ value: 10 ether }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, bob, 10 ether, 0, 0, "")
        );

        // The clock runs out, but the standing bid cannot settle while the currency is frozen.
        vm.warp(auction.auction(saleId).endTime);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, CURRENCY_ETH)
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

        _bobBids(saleId, 10 ether);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), bob, "the real bidder wins");
    }

    function test_MARKET2_WithdrawnWhileFrozenReopensForTheDurationWithAReserve() public {
        (uint256 saleId,) = _freezeAnHourBeforeTheEnd();
        vm.expectEmit(address(auction));
        emit IEnglishAuction.BidWithdrawn(saleId, alice, 0.01 ether);
        vm.prank(alice);
        auction.withdrawBid(saleId);
        assertEq(auction.claimable(alice, CURRENCY_ETH), 0.01 ether, "claims never wait");
        vm.prank(alice);
        auction.claim(CURRENCY_ETH, alice);

        vm.warp(auction.auction(saleId).endTime + 1 days);
        _readmit();
        auction.settle(saleId);
        assertEq(auction.auction(saleId).endTime, block.timestamp + AUCTION_DURATION);
        assertEq(auction.minimumBid(saleId), 0.01 ether, "the withdrawn bid is the reserve");
        _bobBids(saleId, 1 ether);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(auction.auction(saleId).tokenId), bob);
    }

    function test_MARKET2_ACurrencyThatNeverReturnsReleasesTheWorkToTheArtist() public {
        (uint256 saleId, uint256 tokenId) = _freezeAnHourBeforeTheEnd();
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        auction.withdrawBid(saleId);
        // With no standing bid there is nothing to pay: the work returns to its artist.
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), artist);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(address(auction).balance, 0.01 ether, "the credit is all the auction holds");
    }

    function test_MARKET2_WithdrawalNeedsAPauseOrAFreeze() public {
        Work[] memory works = _package(root);
        (uint256 saleId,) = _start(root, works, 2);
        _ethBid(saleId, alice, 0.01 ether);
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
        _govern(
            guardian1, address(allowlist), abi.encodeCall(allowlist.deprecateAsset, (CURRENCY_ETH))
        );
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

    function test_MARKET2_AnAuctionStartedAfterAFreezeSettlesNormally() public {
        _govern(
            guardian1, address(allowlist), abi.encodeCall(allowlist.deprecateAsset, (CURRENCY_ETH))
        );
        _readmit();
        Work[] memory works = _package(root);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 2);
        _ethBid(saleId, alice, 0.01 ether);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), alice, "no reopening for a freeze before the start");
    }

    // ------------------------------------------------------- review follow-ups (PR #57)

    /// @dev L2: a deprecation that never ends, with a high bidder who never withdraws, no longer
    ///      holds the work: 30 days into the freeze anyone ends the sale unsold, the bid is
    ///      credited back and the work goes to its artist.
    function test_MARKET2_AFrozenSaleEndsUnsoldThirtyDaysIntoTheFreeze() public {
        Work[] memory works = _package(root);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 2);
        address passive = makeAddr("passiveBidder");
        _ethBid(saleId, passive, 1 ether);
        _govern(
            guardian1, address(allowlist), abi.encodeCall(allowlist.deprecateAsset, (CURRENCY_ETH))
        );
        uint256 frozenAt = block.timestamp;
        vm.warp(frozenAt + 30 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, CURRENCY_ETH)
        );
        auction.settle(saleId);
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.NotHighBidder.selector, keeper));
        auction.withdrawBid(saleId);

        vm.warp(frozenAt + 30 days);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(passive, CURRENCY_ETH, saleId, 1 ether);
        vm.prank(keeper);
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), artist, "the work goes to its artist");
        assertEq(auction.claimable(passive, CURRENCY_ETH), 1 ether, "the bid is credited back");
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(address(auction).balance, 1 ether, "only the credit is held");
    }

    /// @dev L3: a withdrawal during a freeze does not let anyone end the auction unsold before
    ///      the currency returns (or the 30-day exit): the reopening keeps its promise.
    function test_MARKET2_NothingSettlesWhileFrozen() public {
        (uint256 saleId, uint256 tokenId) = _freezeAnHourBeforeTheEnd();
        vm.prank(alice);
        auction.withdrawBid(saleId);
        vm.warp(auction.auction(saleId).endTime);
        vm.prank(makeAddr("anyone"));
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, CURRENCY_ETH)
        );
        auction.settle(saleId);
        _readmit();
        auction.settle(saleId);
        assertEq(auction.auction(saleId).endTime, block.timestamp + AUCTION_DURATION);
        _bobBids(saleId, 1 ether);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), bob, "sold after the currency returned");
    }

    /// @dev L7: the reopening after a freeze is the governed duration, wherever the first settle
    ///      lands, so a standing low bidder cannot pick a quiet moment for a short window.
    function test_MARKET2_ReopeningAfterAFreezeIsTheDuration() public {
        Work[] memory works = _package(root);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 2);
        _ethBid(saleId, alice, 0.01 ether);
        vm.warp(block.timestamp + 1 hours);
        _govern(
            guardian1, address(allowlist), abi.encodeCall(allowlist.deprecateAsset, (CURRENCY_ETH))
        );
        _readmit();
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        auction.settle(saleId);
        assertEq(auction.auction(saleId).endTime, block.timestamp + AUCTION_DURATION);
        vm.warp(block.timestamp + 12 hours);
        _bobBids(saleId, 1 ether);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), bob);
    }
}
