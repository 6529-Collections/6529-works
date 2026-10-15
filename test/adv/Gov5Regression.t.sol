// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Roles } from "src/governance/Roles.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice GOV-5 regression, on the real stack: the 48-hour UNPAUSER class counts from the pause.
///         An unpause or `resume(saleId)` executes no earlier than `pausedAt + Roles.STANDARD`,
///         even when it was scheduled (and matured) before the pause, so the guardians always
///         have the standard window to cancel it.
contract Gov5RegressionTest is IntegrationBase {
    address internal bidder = makeAddr("bidder");

    function test_GOV5_ResumeScheduledBeforeThePauseWaitsTwoDaysAfterIt() public {
        uint256 saleId = auction.saleIdOf(address(stream), stream.totalMinted() + 1);
        bytes memory resume = abi.encodeCall(auction.resume, (saleId));
        _schedule(hotAdmin, address(auction), resume);

        vm.warp(block.timestamp + 47 hours);
        address artist = _actor("disputedArtist");
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        (uint256 started, uint256 tokenId) = _start(root, works, 0);
        assertEq(started, saleId);
        _ethBid(saleId, bidder, 1 ether);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("dispute"));
        uint256 allowedAt = block.timestamp + Roles.STANDARD;

        // The matured operation cannot end the pause in the same block, nor a second early.
        vm.prank(hotAdmin);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnpauseTooEarly.selector, allowedAt));
        manager.execute(address(auction), resume);
        vm.warp(allowedAt - 1);
        vm.prank(hotAdmin);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnpauseTooEarly.selector, allowedAt));
        manager.execute(address(auction), resume);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.PAUSED));

        // A guardian cancels it within the window, and the upheld outcome's cancel then lands.
        vm.prank(guardian2);
        manager.cancel(hotAdmin, address(auction), resume);
        bytes32 outcome = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://upheld"
        );
        _govern(hotAdmin, address(auction), abi.encodeCall(auction.cancel, (saleId, outcome)));
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
    }

    function test_GOV5_ResumeLandsExactlyTwoDaysAfterThePause() public {
        address artist = _actor("rejectedDisputeArtist");
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        (uint256 saleId,) = _start(root, works, 0);
        _ethBid(saleId, bidder, 1 ether);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("dispute"));
        uint256 pausedAt = block.timestamp;
        bytes memory resume = abi.encodeCall(auction.resume, (saleId));
        _schedule(hotAdmin, address(auction), resume);
        vm.warp(pausedAt + Roles.STANDARD);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionResumed(
            saleId, uint64(auction.auction(saleId).endTime + Roles.STANDARD)
        );
        vm.prank(hotAdmin);
        manager.execute(address(auction), resume);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.ACTIVE));
    }

    function test_GOV5_UnpauseScheduledBeforeThePauseWaitsTwoDaysAfterIt() public {
        address[3] memory adapters = [address(fixedSale), address(dutchSale), address(auction)];
        for (uint256 i; i < adapters.length; ++i) {
            ISaleAdapter adapter = ISaleAdapter(adapters[i]);
            bytes memory unpause = abi.encodeCall(adapter.unpause, ());
            _schedule(hotAdmin, address(adapter), unpause);
            vm.warp(block.timestamp + 3 days);
            vm.expectEmit(address(adapter));
            emit ISaleAdapter.Paused(guardian1);
            vm.prank(guardian1);
            adapter.pause();
            uint256 allowedAt = block.timestamp + Roles.STANDARD;
            vm.prank(hotAdmin);
            vm.expectRevert(
                abi.encodeWithSelector(ISaleAdapter.UnpauseTooEarly.selector, allowedAt)
            );
            manager.execute(address(adapter), unpause);
            assertTrue(adapter.paused());
            vm.warp(allowedAt);
            vm.expectEmit(address(adapter));
            emit ISaleAdapter.Unpaused(address(manager));
            vm.prank(hotAdmin);
            manager.execute(address(adapter), unpause);
            assertFalse(adapter.paused());
        }
    }

    function test_GOV5_UnpauseWithoutAPauseStillReverts() public {
        bytes memory unpause = abi.encodeCall(fixedSale.unpause, ());
        _schedule(hotAdmin, address(fixedSale), unpause);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.prank(hotAdmin);
        vm.expectRevert(ISaleAdapter.NotPaused.selector);
        manager.execute(address(fixedSale), unpause);
    }
}
