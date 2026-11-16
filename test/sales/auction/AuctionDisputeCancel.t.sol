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

    /// @dev The network's cancels of `saleId`: each `refused` outcome is refused
    ///      (`OutcomeNotRecorded`) and `accepted` cancels the sale. Every call is scheduled at
    ///      once and executed after the role's delay (none, or one wait, inside the 3-day pause).
    function _cancels(uint256 saleId, bytes32[] memory refused, bytes32 accepted) internal {
        (bool immediate, uint32 delay) =
            manager.canCall(hotAdmin, address(auction), IEnglishAuction.cancel.selector);
        if (!immediate) {
            for (uint256 i; i < refused.length; ++i) {
                _schedule(
                    hotAdmin, address(auction), abi.encodeCall(auction.cancel, (saleId, refused[i]))
                );
            }
            _schedule(
                hotAdmin, address(auction), abi.encodeCall(auction.cancel, (saleId, accepted))
            );
            vm.warp(block.timestamp + delay);
        }
        for (uint256 i; i < refused.length; ++i) {
            bytes memory data = abi.encodeCall(auction.cancel, (saleId, refused[i]));
            vm.prank(hotAdmin);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IEnglishAuction.OutcomeNotRecorded.selector, saleId, refused[i]
                )
            );
            if (immediate) _call(data);
            else manager.execute(address(auction), data);
        }
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionCancelled(saleId, accepted);
        vm.prank(hotAdmin);
        if (immediate) {
            _call(abi.encodeCall(auction.cancel, (saleId, accepted)));
        } else {
            manager.execute(address(auction), abi.encodeCall(auction.cancel, (saleId, accepted)));
        }
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
    }

    function _call(bytes memory data) internal {
        (bool ok, bytes memory reason) = address(auction).call(data);
        _bubble(ok, reason);
    }

    function _one(bytes32 a) internal pure returns (bytes32[] memory list) {
        list = new bytes32[](1);
        list[0] = a;
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
        bytes32 fresh = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://upheld-after-pause"
        );
        _cancels(saleId, _one(early), fresh);
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
        bytes32 fresh = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://upheld-after-pause"
        );
        _cancels(saleId, _one(itemOutcome), fresh);
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
        bytes32[] memory refused = new bytes32[](2);
        (refused[0], refused[1]) = (first, bytes32(0));
        _cancels(saleId, refused, second);
    }
}
