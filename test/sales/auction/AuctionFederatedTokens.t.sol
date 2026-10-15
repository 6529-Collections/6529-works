// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH, PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
import { LockedTerms, Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { MockMintTarget } from "../../mocks/sales/AuctionMocks.sol";
import { MockFederationRegistry } from "../../mocks/sales/SaleMocks.sol";
import { SalesStackBase } from "../SalesStackBase.sol";

/// @notice English auctions of federated tokens, on the real stack with a mock federated token
///         and registry. A federated auction pays its registry fee share to the economics
///         resolver's federated network fee recipient, never to the fee recipient the token
///         reports, as the fixed-price and Dutch adapters do. A federated auction whose contract
///         is delisted mid-auction takes no more bids (ADR 0001 section 16: a delisted contract
///         cannot sell through the network's adapters), and its settlement credits the high bid
///         back and gives the work to its artist.
contract AuctionFederatedTokensTest is SalesStackBase {
    /// Regression: MARKET-5 (docs/security/internal-review-2026-10.md)
    function test_Bid_ADelistedFederatedAuctionStopsSelling() public {
        (MockFederationRegistry reg, MockMintTarget fed) =
            _federated(makeAddr("fedSeller"), economics.networkFeeRecipient(PRODUCT_FEDERATED));
        uint256 saleId = auction.start(address(fed), "");
        _ethBid(saleId, collector, 0.5 ether);

        reg.setStatus(address(fed), IFederationRegistry.Status.DELISTED, keccak256("vote"));
        assertFalse(auction.isTarget(address(fed)));

        address late = makeAddr("lateBidder");
        vm.deal(late, 2 ether);
        vm.prank(late);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(fed))
        );
        auction.bid{ value: 2 ether }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, late, 2 ether, 0, 0, "")
        );

        vm.warp(auction.auction(saleId).endTime);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(collector, CURRENCY_ETH, saleId, 0.5 ether);
        auction.settle(saleId);
        assertEq(fed.ownerOf(1), artist, "the work goes to its artist, nothing confiscated");
        assertEq(auction.claimable(collector, CURRENCY_ETH), 0.5 ether, "the bid is credited");
        assertEq(address(auction).balance, 0.5 ether, "nothing was paid out");
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));
    }

    /// Regression: MARKET-5 (docs/security/internal-review-2026-10.md)
    function test_Bid_ARelistedContractSellsAgain() public {
        (MockFederationRegistry reg, MockMintTarget fed) =
            _federated(makeAddr("fedSeller"), economics.networkFeeRecipient(PRODUCT_FEDERATED));
        uint256 saleId = auction.start(address(fed), "");
        reg.setStatus(address(fed), IFederationRegistry.Status.DELISTED, keccak256("vote"));
        reg.setStatus(address(fed), IFederationRegistry.Status.ACTIVE, keccak256("appeal"));
        _ethBid(saleId, collector, 0.5 ether);
        _settleAtEnd(saleId);
        assertEq(fed.ownerOf(1), collector);
    }

    /// Regression: MARKET-3 (docs/security/internal-review-2026-10.md)
    function test_Settle_AFederatedAuctionPaysTheNetworksFederatedRecipient() public {
        address artistSeller = makeAddr("fedSellerWallet");
        address artistSideWallet = makeAddr("artistSideWallet");
        (, MockMintTarget fed) = _federated(artistSeller, artistSideWallet);
        address networkFederated = economics.networkFeeRecipient(PRODUCT_FEDERATED);
        assertTrue(networkFederated != artistSideWallet);
        assertEq(address(auction.economicsResolver()), address(economics));
        uint256 networkBefore = networkFederated.balance;

        uint256 saleId = auction.start(address(fed), "");
        LockedTerms memory lt = auction.lockedTerms(saleId);
        assertEq(lt.feeShare, 10_000, "the registry's fee share");
        assertEq(lt.feeRecipient, networkFederated, "the network's federated recipient");
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);

        assertEq(artistSideWallet.balance, 0, "nothing to the token's own recipient");
        assertEq(artistSeller.balance, 0.9 ether);
        assertEq(networkFederated.balance - networkBefore, 0.1 ether);
    }

    /// Regression: MARKET-3 (docs/security/internal-review-2026-10.md)
    /// @dev A listed 6529 Stream work keeps the fee recipient locked in its token.
    function test_Settle_ListedWorksKeepTheirOwnFeeRecipient() public {
        Work[] memory works = _package(root);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 2);
        assertEq(
            auction.lockedTerms(saleId).feeRecipient, stream.primaryTerms(tokenId, "").feeRecipient
        );
    }
}
