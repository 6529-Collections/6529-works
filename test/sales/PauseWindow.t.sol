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

    function test_Resume_MaturedBeforeThePauseLandsAtOnce() public {
        uint256 saleId =
            auction.saleIdOf(address(stream), IStream(address(stream)).totalMinted() + 1);
        bytes memory resume = abi.encodeCall(auction.resume, (saleId));
        _schedule(hotAdmin, address(auction), resume);
        vm.warp(block.timestamp + 3 days);
        (uint256 started,) = _disputed();
        assertEq(started, saleId);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("dispute"));
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.PAUSED));
        vm.prank(hotAdmin);
        manager.execute(address(auction), resume);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.ACTIVE));
    }

    function test_Cancel_MaturedBeforeThePauseLandsAtOnce() public {
        uint256 t1 = block.timestamp + 3 days;
        uint256 snap = vm.snapshotState();
        vm.warp(t1);
        (uint256 saleId, uint256 tokenId) = _disputed();
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("dispute"));
        bytes32 predicted = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://upheld"
        );
        vm.revertToState(snap);
        bytes memory cancel = abi.encodeCall(auction.cancel, (saleId, predicted));
        _schedule(hotAdmin, address(auction), cancel);
        vm.warp(t1);
        (uint256 again, uint256 sameToken) = _disputed();
        assertEq(again, saleId);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("dispute"));
        assertEq(
            _platformStatement(
                address(stream), sameToken, StatementKinds.DISPUTE_OUTCOME, "ar://upheld"
            ),
            predicted
        );
        vm.prank(hotAdmin);
        manager.execute(address(auction), cancel);
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
    }

    function test_Unpause_MaturedBeforeThePauseLandsAtOnce() public {
        address[2] memory adapters = [address(auction), address(editionAuction)];
        for (uint256 i; i < adapters.length; ++i) {
            ISaleAdapter adapter = ISaleAdapter(adapters[i]);
            bytes memory unpause = abi.encodeCall(adapter.unpause, ());
            _schedule(hotAdmin, address(adapter), unpause);
            vm.warp(block.timestamp + 3 days);
            vm.prank(guardian1);
            adapter.pause();
            vm.expectEmit(address(adapter));
            emit ISaleAdapter.Unpaused(address(manager));
            vm.prank(hotAdmin);
            manager.execute(address(adapter), unpause);
            assertFalse(adapter.paused());
        }
    }

    function test_Unpause_WithoutAPauseStillReverts() public {
        bytes memory unpause = abi.encodeCall(ISaleAdapter.unpause, ());
        _schedule(hotAdmin, address(auction), unpause);
        vm.warp(block.timestamp + 3 days);
        vm.prank(hotAdmin);
        vm.expectRevert(ISaleAdapter.NotPaused.selector);
        manager.execute(address(auction), unpause);
    }
}
