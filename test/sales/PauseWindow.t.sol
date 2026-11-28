// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice On the deployed stack under the genesis policy, the sale adapters add no wait of
///         their own after a pause: a pauser key pauses at once, and the network's `resume`,
///         `cancel` and `unpause` (NETWORK, no role delay) land at once, inside the 3-day dispute
///         pause. Re-ported from the retired `PauseWindow` suite (the adapters once refused each
///         until 48 hours after the pause).
contract PauseWindowTest is IntegrationBase {
    address internal bidder = makeAddr("bidder");

    function _disputed() internal returns (uint256 saleId, uint256 tokenId) {
        address artist = _actor("disputedArtist");
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        (saleId, tokenId) = _start(root, works, 0);
        _ethBid(saleId, bidder, 1 ether);
    }

    function _immediate(address caller, address target, bytes4 selector) internal view {
        (bool immediate, uint32 delay) = manager.canCall(caller, target, selector);
        assertTrue(immediate, "no role delay");
        assertEq(delay, 0);
    }

    function test_Resume_TheNetworkResumesAtOnce() public {
        (uint256 saleId,) = _disputed();
        _immediate(pauser1, address(auction), bytes4(keccak256("pause(uint256,bytes32)")));
        _immediate(network, address(auction), IEnglishAuction.resume.selector);
        vm.prank(pauser1);
        auction.pause(saleId, keccak256("dispute"));
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.PAUSED));
        vm.prank(network);
        auction.resume(saleId);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.ACTIVE));
    }

    function test_Cancel_TheNetworkCancelsAtOnce() public {
        (uint256 saleId, uint256 tokenId) = _disputed();
        _immediate(network, address(auction), IEnglishAuction.cancel.selector);
        vm.prank(pauser2);
        auction.pause(saleId, keccak256("dispute"));
        bytes32 outcome = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://upheld"
        );
        vm.prank(network);
        auction.cancel(saleId, outcome);
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        assertEq(auction.claimable(bidder), 1 ether, "the bid is credited back");
    }

    function test_Unpause_TheNetworkUnpausesAtOnce() public {
        address[2] memory adapters = [address(auction), address(editionAuction)];
        for (uint256 i; i < adapters.length; ++i) {
            ISaleAdapter adapter = ISaleAdapter(adapters[i]);
            _immediate(network, adapters[i], ISaleAdapter.unpause.selector);
            vm.prank(pauser3);
            adapter.pause();
            assertTrue(adapter.paused());
            vm.expectEmit(adapters[i]);
            emit ISaleAdapter.Unpaused(network);
            vm.prank(network);
            adapter.unpause();
            assertFalse(adapter.paused());
        }
    }

    function test_Unpause_WithoutAPauseStillReverts() public {
        vm.prank(network);
        vm.expectRevert(IEnglishAuction.NotPaused.selector);
        auction.unpause();
        vm.prank(network);
        vm.expectRevert(ISaleAdapter.NotPaused.selector);
        editionAuction.unpause();
    }
}
