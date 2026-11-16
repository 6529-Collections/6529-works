// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";
import { IStream } from "src/interfaces/IStream.sol";

/// @notice C30 on the real stack: the sale adapters add no wait of their own after a pause. A
///         network `resume`, `cancel` or `unpause` that the access manager lets through lands at
///         once, inside the 3-day dispute pause; how long the network's own call takes is the
///         role map's (the second pass gives `cancel` and `resume` no delay). Fails without the
///         change: each was refused until 48 hours after the pause (`UnpauseTooEarly`).
contract PauseWindowTest is IntegrationBase {
    address internal bidder = makeAddr("bidder");

    function _disputed() internal returns (uint256 saleId, uint256 tokenId) {
        address artist = _actor("disputedArtist");
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        (saleId, tokenId) = _start(root, works, 0);
        _ethBid(saleId, bidder, 1 ether);
    }

    function test_Resume_TheNetworkResumesAtOnce() public {
        (uint256 saleId,) = _disputed();
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("dispute"));
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.PAUSED));
        vm.prank(hotAdmin);
        auction.resume(saleId);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.ACTIVE));
    }

    function test_Cancel_TheNetworkCancelsAtOnce() public {
        (uint256 saleId, uint256 tokenId) = _disputed();
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("dispute"));
        bytes32 outcome = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://upheld"
        );
        vm.prank(hotAdmin);
        auction.cancel(saleId, outcome);
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
    }

    function test_Unpause_TheNetworkUnpausesAtOnce() public {
        address[2] memory adapters = [address(auction), address(editionAuction)];
        for (uint256 i; i < adapters.length; ++i) {
            ISaleAdapter adapter = ISaleAdapter(adapters[i]);
            vm.prank(guardian1);
            adapter.pause();
            vm.expectEmit(address(adapter));
            emit ISaleAdapter.Unpaused(hotAdmin);
            vm.prank(hotAdmin);
            adapter.unpause();
            assertFalse(adapter.paused());
        }
    }

    function test_Unpause_WithoutAPauseStillReverts() public {
        vm.prank(hotAdmin);
        vm.expectRevert(ISaleAdapter.NotPaused.selector);
        auction.unpause();
    }
}
