// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { LockedTerms, Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { BlocklistToken, FeeOnTransferToken, MockERC20 } from "../mocks/EconomicsMocks.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice MONEY-1 regression, on the real stack: NFT delivery never depends on a payout
///         succeeding. When an admitted ERC-20 changes behaviour after the bids (a transfer fee,
///         or a block on the auction itself, so even the escrow route fails), settlement still
///         delivers the work and credits each failed payout to its wallet; anyone pays the
///         credit out with `claimFor` once the token works again, to that wallet only.
contract Money1RegressionTest is IntegrationBase {
    address internal artist;
    address internal bidder1 = makeAddr("bidder1");
    address internal bidder2 = makeAddr("bidder2");

    function setUp() public override {
        super.setUp();
        artist = _actor("artist");
    }

    function _admit(MockERC20 token) internal {
        _govern(
            hotAdmin,
            address(allowlist),
            abi.encodeCall(allowlist.admitAsset, (address(token), 0, 1e15))
        );
    }

    function _bid(MockERC20 token, uint256 saleId, address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(auction), amount);
        auction.bid(saleId, address(0), Payment(PaymentMethod.DIRECT, who, amount, 0, 0, ""));
        vm.stopPrank();
    }

    function _auctionIn(MockERC20 token) internal returns (uint256 saleId, uint256 tokenId) {
        Work memory w = _work(artist, collectionId);
        w.item.sale.currency = address(token);
        Work[] memory works = _one(w);
        bytes32 root = _publish(works);
        (saleId, tokenId) = _start(root, works, 0);
        _bid(token, saleId, bidder1, 100e18);
        _bid(token, saleId, bidder2, 200e18);
    }

    function test_MONEY1_FeeSwitchAfterTheBidsDoesNotHoldTheWork() public {
        FeeOnTransferToken fee = new FeeOnTransferToken();
        fee.setFee(0);
        _admit(fee);
        (uint256 saleId, uint256 tokenId) = _auctionIn(fee);
        LockedTerms memory lt = auction.lockedTerms(saleId);
        uint256 feeAmount = 200e18 * uint256(lt.feeShare) / 100_000;

        fee.setFee(100);
        vm.warp(auction.auction(saleId).endTime);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(lt.seller, address(fee), saleId, 200e18 - feeAmount);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(lt.feeRecipient, address(fee), saleId, feeAmount);
        auction.settle(saleId);
        assertEq(IERC721(address(stream)).ownerOf(tokenId), bidder2, "the work is delivered");
        assertEq(auction.claimable(lt.seller, address(fee)), 200e18 - feeAmount);
        assertEq(auction.claimable(lt.feeRecipient, address(fee)), feeAmount);
        assertEq(fee.balanceOf(address(auction)), 300e18, "credits and refunds are all held");

        // While the token misbehaves the payout cannot go out, and the credit is kept.
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, address(fee))
        );
        auction.claimFor(lt.seller, address(fee));
        assertEq(auction.claimable(lt.seller, address(fee)), 200e18 - feeAmount);

        // Once it is fixed, anyone pays each wallet exactly; the refund is claimable as ever.
        fee.setFee(0);
        vm.prank(makeAddr("keeper"));
        auction.claimFor(lt.seller, address(fee));
        auction.claimFor(lt.feeRecipient, address(fee));
        assertEq(fee.balanceOf(lt.seller), 200e18 - feeAmount);
        assertEq(fee.balanceOf(lt.feeRecipient), feeAmount);
        vm.prank(bidder1);
        auction.claim(address(fee), bidder1);
        assertEq(fee.balanceOf(address(auction)), 0);
    }

    function test_MONEY1_ATokenThatBlocksTheAuctionDoesNotHoldTheWork() public {
        BlocklistToken usdb = new BlocklistToken();
        _admit(usdb);
        (uint256 saleId, uint256 tokenId) = _auctionIn(usdb);
        LockedTerms memory lt = auction.lockedTerms(saleId);
        usdb.setBlocked(address(auction), true);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        assertEq(IERC721(address(stream)).ownerOf(tokenId), bidder2);
        assertEq(
            auction.claimable(lt.seller, address(usdb))
                + auction.claimable(lt.feeRecipient, address(usdb)),
            200e18
        );
        usdb.setBlocked(address(auction), false);
        uint256 owed = auction.claimable(lt.seller, address(usdb));
        auction.claimFor(lt.seller, address(usdb));
        assertEq(usdb.balanceOf(lt.seller), owed);
    }

    /// @dev A wallet the token blocks, with the auction unblocked, still goes to the escrow as
    ///      before: only a payout that cannot be made at all is credited here.
    function test_MONEY1_ABlockedWalletIsStillPaidThroughTheEscrow() public {
        BlocklistToken usdb = new BlocklistToken();
        _admit(usdb);
        (uint256 saleId,) = _auctionIn(usdb);
        LockedTerms memory lt = auction.lockedTerms(saleId);
        usdb.setBlocked(lt.seller, true);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        assertEq(auction.claimable(lt.seller, address(usdb)), 0, "not credited here");
        assertGt(escrow.owed(lt.seller, address(usdb)), 0, "escrowed for the seller");
    }

    function test_MONEY1_OnlyTheAuctionRunsAPayoutFrame() public {
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidRecipient.selector, address(this))
        );
        auction.settlePayout(address(1), address(2), 3);
    }

    /// @dev `claimFor` pushes an ERC-20 credit to its own account only; it refuses ETH (L5), whose
    ///      credits are bidders' refunds, claimed by the bidder to an address it chooses.
    function test_MONEY1_ClaimForPaysOnlyTheAccountItself() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        token.setFee(0);
        _admit(token);
        _auctionIn(token);
        assertEq(auction.claimable(bidder1, address(token)), 100e18);
        address keeper = makeAddr("keeper");
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Claimed(bidder1, address(token), bidder1, 100e18);
        vm.prank(keeper);
        assertEq(auction.claimFor(bidder1, address(token)), 100e18);
        assertEq(token.balanceOf(bidder1), 100e18);
        assertEq(token.balanceOf(keeper), 0);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.NothingToClaim.selector, bidder1, address(token))
        );
        auction.claimFor(bidder1, address(token));
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.InvalidRecipient.selector, address(0)));
        auction.claimFor(address(0), address(token));

        // ETH: an outbid bidder's refund stays its own to claim, wherever it chooses.
        Work[] memory works = _one(_work(artist, collectionId));
        (uint256 ethSale,) = _start(_publish(works), works, 0);
        _ethBid(ethSale, bidder1, 1 ether);
        _ethBid(ethSale, bidder2, 2 ether);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.InvalidAsset.selector, address(0)));
        auction.claimFor(bidder1, address(0));
        assertEq(auction.claimable(bidder1, address(0)), 1 ether);
    }
}
