// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Roles } from "src/governance/Roles.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";
import { SalesStackBase } from "./SalesStackBase.sol";

/// @notice The guardians' window after a pause, on the real stack: the 48-hour UNPAUSER class
///         counts from the pause. An adapter's `unpause` or the auction's `resume(saleId)`
///         executes no earlier than `pausedAt + Roles.STANDARD`, even when it was scheduled (and
///         matured) before the pause, so the guardians always have the standard window to
///         cancel it.
contract PauseWindowTest is IntegrationBase {
    address internal bidder = makeAddr("bidder");

    /// Regression: GOV-5 (docs/security/internal-review-2026-10.md)
    function test_Resume_ScheduledBeforeThePauseWaitsTwoDaysAfterIt() public {
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

    /// Regression: GOV-5 (docs/security/internal-review-2026-10.md)
    function test_Resume_LandsExactlyTwoDaysAfterThePause() public {
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

    /// Regression: GOV-5 (docs/security/internal-review-2026-10.md)
    function test_Unpause_ScheduledBeforeThePauseWaitsTwoDaysAfterIt() public {
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

    /// Regression: GOV-5 (docs/security/internal-review-2026-10.md)
    function test_Unpause_WithoutAPauseStillReverts() public {
        bytes memory unpause = abi.encodeCall(fixedSale.unpause, ());
        _schedule(hotAdmin, address(fixedSale), unpause);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.prank(hotAdmin);
        vm.expectRevert(ISaleAdapter.NotPaused.selector);
        manager.execute(address(fixedSale), unpause);
    }
}

/// @notice The same 48-hour window on the sales stack's package: a cancel scheduled before a
///         dispute pause waits for it like an unpause, and re-pausing after an unpause starts the
///         48 hours again.
contract PauseWindowSalesStackTest is SalesStackBase {
    /// Regression: LIFECYCLE-4 (docs/security/internal-review-2026-10.md); L4 in the review of #57
    /// @dev A cancel scheduled before the pause, for a predictable sale and outcome, cannot land
    ///      in the pause's own block; the guardians keep the 48-hour window to cancel it.
    function test_Cancel_ScheduledBeforeThePauseWaitsForItsWindow() public {
        uint256 t0 = block.timestamp;
        uint256 snap = vm.snapshotState();
        (uint256 saleId, uint256 tokenId) = _disputedNextWork(t0);
        bytes32 predicted = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://upheld"
        );
        vm.revertToState(snap);

        bytes memory cancel = abi.encodeCall(auction.cancel, (saleId, predicted));
        _schedule(hotAdmin, address(auction), cancel);
        (uint256 again, uint256 sameToken) = _disputedNextWork(t0);
        assertEq(again, saleId);
        assertEq(
            _platformStatement(
                address(stream), sameToken, StatementKinds.DISPUTE_OUTCOME, "ar://upheld"
            ),
            predicted
        );
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.UnpauseTooEarly.selector, block.timestamp + Roles.STANDARD
            )
        );
        manager.execute(address(auction), cancel);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.PAUSED));
        vm.prank(guardian2);
        manager.cancel(hotAdmin, address(auction), cancel);
    }

    function _disputedNextWork(uint256 t0) internal returns (uint256 saleId, uint256 tokenId) {
        vm.warp(t0 + 47 hours);
        Work[] memory works = _package(root);
        (saleId, tokenId) = _start(root, works, 2);
        _ethBid(saleId, makeAddr("bidder"), 1 ether);
        vm.warp(t0 + 49 hours);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("dispute"));
    }

    /// Regression: GOV-5 (docs/security/internal-review-2026-10.md)
    /// @dev Re-pausing after an unpause restarts the 48 hours.
    function test_Unpause_PauseUnpausePauseRestartsTheClock() public {
        _govern(guardian1, address(fixedSale), abi.encodeCall(fixedSale.pause, ()));
        bytes memory unpause = abi.encodeCall(fixedSale.unpause, ());
        _govern(hotAdmin, address(fixedSale), unpause);
        _schedule(hotAdmin, address(fixedSale), unpause);
        vm.warp(block.timestamp + Roles.STANDARD);
        _govern(guardian1, address(fixedSale), abi.encodeCall(fixedSale.pause, ()));
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.UnpauseTooEarly.selector, block.timestamp + Roles.STANDARD
            )
        );
        manager.execute(address(fixedSale), unpause);
        assertTrue(fixedSale.paused());
    }
}
