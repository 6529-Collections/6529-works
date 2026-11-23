// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Which dispute outcome cancels a paused sale, on the deployed stack with the real
///         statement log (DSP-18): only the token's own latest outcome. An outcome recorded for
///         the work's item, and an outcome a later one superseded, cannot cancel.
contract DisputeCancelOutcomeTest is IntegrationBase {
    address internal bidder = makeAddr("outcomeBidder");

    /// @dev A sale with one bid, paused by a pauser key.
    function _pausedSale() internal returns (uint256 saleId, uint256 tokenId) {
        Work[] memory works = _one(_work(_actor("outcomeArtist"), collectionId));
        bytes32 root = _publish(works);
        (saleId, tokenId) = _start(root, works, 0);
        _ethBid(saleId, bidder, 1 ether);
        vm.prank(pauser1);
        auction.pause(saleId, keccak256("dispute"));
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.PAUSED));
    }

    function _outcome(address token, uint256 id, string memory uri) internal returns (bytes32) {
        return _platformStatement(token, id, StatementKinds.DISPUTE_OUTCOME, uri);
    }

    function _expectNotRecorded(uint256 saleId, bytes32 outcome) internal {
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.OutcomeNotRecorded.selector, saleId, outcome)
        );
        auction.cancel(saleId, outcome);
    }

    /// DSP-18: an outcome recorded for the item, not for the token, is what readers see for
    /// the token while it has none of its own, yet it cannot cancel the sale; the token's own
    /// outcome can.
    function test_Cancel_AnItemOutcomeCannotCancel() public {
        (uint256 saleId, uint256 tokenId) = _pausedSale();
        bytes32 itemOutcome =
            _outcome(address(0), uint256(stream.itemHashOf(tokenId)), "ar://item-outcome");
        assertEq(
            statements.latestDisputeOutcome(address(stream), tokenId),
            itemOutcome,
            "readers see the item's outcome"
        );
        (bytes32 own,) = statements.disputeOutcomeOf(address(stream), tokenId);
        assertEq(own, bytes32(0), "the token has no outcome of its own");

        _expectNotRecorded(saleId, itemOutcome);
        assertEq(stream.ownerOf(tokenId), address(auction), "still in custody");

        bytes32 ownOutcome = _outcome(address(stream), tokenId, "ar://token-outcome");
        vm.prank(network);
        auction.cancel(saleId, ownOutcome);
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        assertEq(auction.claimable(bidder), 1 ether);
    }

    /// DSP-18: of two outcomes recorded for the token after the pause, only the latest
    /// cancels; the one it superseded is refused.
    function test_Cancel_ASupersededOutcomeCannotCancel() public {
        (uint256 saleId, uint256 tokenId) = _pausedSale();
        bytes32 first = _outcome(address(stream), tokenId, "ar://first-outcome");
        bytes32 latest = _outcome(address(stream), tokenId, "ar://latest-outcome");
        assertTrue(first != latest);
        (bytes32 recorded,) = statements.disputeOutcomeOf(address(stream), tokenId);
        assertEq(recorded, latest);

        _expectNotRecorded(saleId, first);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.PAUSED));

        vm.prank(network);
        auction.cancel(saleId, latest);
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        assertEq(stream.totalBurned(), 1);
    }
}
