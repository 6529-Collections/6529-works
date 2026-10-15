// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
import { LockedTerms } from "src/interfaces/types/SaleTypes.sol";
import { MockMintTarget } from "../mocks/sales/AuctionMocks.sol";
import { MarketPoCBase } from "./MarketPoCBase.sol";

/// @notice MARKET-3 regression, on the real stack with a mock federated token and registry: a
///         federated auction pays its registry fee share to the economics resolver's federated
///         network fee recipient, never to the fee recipient the token reports, as the
///         fixed-price and Dutch adapters do.
contract Market3RegressionTest is MarketPoCBase {
    function test_MARKET3_FederatedAuctionPaysTheNetworksFederatedRecipient() public {
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

    /// @dev A listed 6529 Stream work keeps the fee recipient locked in its token.
    function test_MARKET3_ListedWorksKeepTheirOwnFeeRecipient() public {
        Work[] memory works = _package(root);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 2);
        assertEq(
            auction.lockedTerms(saleId).feeRecipient, stream.primaryTerms(tokenId, "").feeRecipient
        );
    }
}
