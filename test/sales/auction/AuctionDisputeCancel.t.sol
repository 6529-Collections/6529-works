// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { IntegrationBase } from "../../integration/IntegrationBase.sol";

/// @notice An English auction's governed `cancel` after an upheld dispute, on the real stack: it
///         must cite the token's current latest dispute outcome, recorded after the dispute
///         pause. An outcome recorded before the pause, about the token or about its package
///         item before the mint, cannot cancel the auction; a fresh one can.
contract AuctionDisputeCancelTest is IntegrationBase {
    address internal artist;
    address internal bidder = makeAddr("disputeBidder");

    function setUp() public override {
        super.setUp();
        artist = _actor("disputedArtist");
    }

    function _cancel(uint256 saleId, bytes32 outcome) internal {
        _govern(hotAdmin, address(auction), abi.encodeCall(auction.cancel, (saleId, outcome)));
    }

    function _expectCancelRefused(uint256 saleId, bytes32 outcome) internal {
        bytes memory data = abi.encodeCall(auction.cancel, (saleId, outcome));
        _schedule(hotAdmin, address(auction), data);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.OutcomeNotRecorded.selector, saleId, outcome)
        );
        manager.execute(address(auction), data);
    }

    /// Regression: LIFECYCLE-4 (docs/security/internal-review-2026-10.md)
    function test_Cancel_RefusesAnOutcomeRecordedBeforeThePause() public {
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);
        _ethBid(saleId, bidder, 1 ether);
        bytes32 early = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://earlier-outcome"
        );
        assertEq(statements.latestDisputeOutcome(address(stream), tokenId), early);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("dispute"));
        _expectCancelRefused(saleId, early);

        bytes32 fresh = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://upheld-after-pause"
        );
        bytes memory data = abi.encodeCall(auction.cancel, (saleId, fresh));
        _schedule(hotAdmin, address(auction), data);
        vm.warp(block.timestamp + 48 hours);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionCancelled(saleId, fresh);
        vm.prank(hotAdmin);
        manager.execute(address(auction), data);
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
    }

    /// Regression: LIFECYCLE-4 (docs/security/internal-review-2026-10.md)
    function test_Cancel_RefusesAnItemOutcomeRecordedBeforeTheMint() public {
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        bytes32 itemOutcome = _platformStatement(
            address(0),
            uint256(WorksHashing.itemHash(works[0].item)),
            StatementKinds.DISPUTE_OUTCOME,
            "ar://item-outcome-before-mint"
        );
        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);
        _ethBid(saleId, bidder, 1 ether);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("dispute"));
        _expectCancelRefused(saleId, itemOutcome);

        bytes32 fresh = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://upheld-after-pause"
        );
        _cancel(saleId, fresh);
        assertEq(auction.claimable(bidder, address(0)), 1 ether, "the bid is credited back");
    }

    /// Regression: LIFECYCLE-4 (docs/security/internal-review-2026-10.md)
    function test_Cancel_OnlyTheLatestOutcomeCancels() public {
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("dispute"));
        bytes32 first = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://first-outcome"
        );
        bytes32 second = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://second-outcome"
        );
        _expectCancelRefused(saleId, first);
        _expectCancelRefused(saleId, bytes32(0));
        _cancel(saleId, second);
    }
}
