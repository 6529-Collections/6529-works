// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice CALLS-5, on the real stack: the auction refuses every safe transfer except its own
///         mint during a start, and documents that a plain `transferFrom` (which runs no hook)
///         strands the token, since nothing records who sent it. A governed rescue does not fit
///         the auction's EIP-170 headroom.
contract Calls5RegressionTest is IntegrationBase {
    address internal bidder = makeAddr("callsBidder");

    function _sold() internal returns (uint256 saleId, uint256 tokenId) {
        address artist = _actor("callsArtist");
        Work[] memory works = _one(_work(artist, collectionId));
        (saleId, tokenId) = _start(_publish(works), works, 0);
        _ethBid(saleId, bidder, 1 ether);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), bidder);
    }

    function test_CALLS5_SafeTransfersIntoTheAuctionAreRefused() public {
        (, uint256 tokenId) = _sold();
        vm.prank(bidder);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.InvalidTarget.selector, address(stream))
        );
        stream.safeTransferFrom(bidder, address(auction), tokenId);
        assertEq(stream.ownerOf(tokenId), bidder);
    }

    /// @dev The documented limit: a plain transfer cannot be refused or traced to its sender.
    function test_CALLS5_APlainTransferIsTheSendersLoss() public {
        (uint256 saleId, uint256 tokenId) = _sold();
        vm.prank(bidder);
        stream.transferFrom(bidder, address(auction), tokenId);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        auction.claimDelivery(saleId, bidder);
        assertEq(stream.ownerOf(tokenId), address(auction));
    }
}
