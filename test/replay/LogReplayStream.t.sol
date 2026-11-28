// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Outcome, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { ReplayBase } from "./ReplayBase.sol";
import { ReplayEvents } from "./ReplayEvents.sol";

/// @notice Log replay of 6529 Stream and the `StreamDirectory6529` on the deployed stack, from
///         their deployment on: a history that emits every event of both (curated sales, an unsold
///         work going to the museum, a dispute burning a work in its sale, approvals and an
///         operator's transfer, a royalty change and its lock through the rules module, a batch
///         metadata refresh, the network's settings, modules and minters, a rescue) rebuilds, from
///         their logs alone, every getter, and the rebuilt values match the live contracts after
///         each step. The negative controls show a value no log explains and a dropped log each
///         make the comparison fail.
contract LogReplayStreamTest is ReplayBase {
    address internal artist;
    address internal buyer = makeAddr("replayBuyer");
    address internal bidder = makeAddr("replayBidder");
    address internal operator = makeAddr("replayOperator");
    address internal holder = makeAddr("replayHolder");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("replayArtist");
        Work[] memory works = new Work[](5);
        for (uint256 i; i < 5; ++i) {
            works[i] = _work(artist, collectionId);
        }
        root = _publish(works);
        _keep(root, works);
        _sync();
    }

    function test_Stream_EveryEventReplaysToTheSameState() public {
        Work[] memory works = _package(root);
        // Two curated sales; a work no one bids on goes to the museum.
        uint256 t0 = _sell(root, works, 0, buyer, 1 ether);
        uint256 t1 = _sell(root, works, 1, buyer, 1 ether);
        (uint256 unsoldSale, uint256 t2) = _start(root, works, 2);
        _settleAtEnd(unsoldSale);
        _sync();
        assertEq(uint8(stream.workOf(t2).outcome), uint8(Outcome.UNSOLD));

        // An upheld dispute burns a work in its sale.
        (uint256 disputed, uint256 t3) = _start(root, works, 3);
        _ethBid(disputed, bidder, 1 ether);
        _govern(
            pauser1,
            address(auction),
            abi.encodeWithSignature("pause(uint256,bytes32)", disputed, bytes32("dispute"))
        );
        bytes32 outcome = _platformStatement(
            address(stream), t3, StatementKinds.DISPUTE_OUTCOME, "ar://replay-upheld"
        );
        _asNetwork(address(auction), abi.encodeCall(auction.cancel, (disputed, outcome)));
        _sync();
        assertEq(stream.totalBurned(), 1);

        // Approvals and an operator's transfer.
        vm.startPrank(buyer);
        stream.approve(bidder, t0);
        stream.setApprovalForAll(operator, true);
        vm.stopPrank();
        _sync();
        vm.prank(operator);
        stream.transferFrom(buyer, holder, t0);
        _sync();

        // A royalty change and its lock, through the rules module (RECORDS) and StreamTerms.
        _open(t1, works[1]);
        _setRoyaltyRate(t1, works[1], 7_500);
        _sync();
        _renounce(t1, artist, WorkPowers.ROYALTY_RATE);
        _sync();
        assertTrue(stream.workOf(t1).royaltyRateLocked);

        // A batch refresh through the delivery module.
        _govern(
            storageOperator,
            address(delivery),
            abi.encodeCall(delivery.setPreferredKind, (address(stream), LocatorKind.IPFS))
        );
        _sync();

        // The network's settings and the marketplace page.
        _asNetwork(address(stream), abi.encodeCall(stream.setContractURI, ("ar://replay")));
        _asNetwork(address(stream), abi.encodeCall(stream.setOwner, (makeAddr("nextOwner"))));
        vm.prank(platform);
        stream.createCollection("Replay", keccak256("replay collection"));
        _sync();

        // A module announced and installed after a shorter wait.
        _asNetwork(address(stream), abi.encodeCall(stream.setModuleDelay, (1 days)));
        _asNetwork(
            address(stream),
            abi.encodeCall(stream.proposeModule, (Slots.RENDERER, address(renderer)))
        );
        _sync();
        skip(1 days);
        stream.activateModule(Slots.RENDERER);
        _sync();

        // A sale contract removed with a work in its custody: the work is rescued after the
        // network's delay, and the sale contract is added again.
        (, uint256 t4) = _start(root, works, 4);
        _asNetwork(address(stream), abi.encodeCall(stream.setRescueDelay, (2 days)));
        _asNetwork(address(stream), abi.encodeCall(stream.removeMinter, (address(auction))));
        _sync();
        skip(2 days);
        _asNetwork(address(stream), abi.encodeCall(stream.rescue, (t4, museum)));
        _asNetwork(address(stream), abi.encodeCall(stream.addMinter, (address(auction))));
        _sync();
        assertEq(stream.ownerOf(t4), museum);
        assertEq(uint8(stream.workOf(t4).outcome), uint8(Outcome.RESCUED));

        _assertEveryEventReplayed("Stream6529", streamIdx, ReplayEvents.stream(), _none());
    }

    function test_Directory_EveryEventReplaysToTheSameState() public {
        _asNetwork(address(directory), abi.encodeCall(directory.setUnclaimedPeriod, (90 days)));
        _asNetwork(address(directory), abi.encodeCall(directory.setModuleDelay, (1 days)));
        address accountsModule = directory.moduleOf(Slots.ACCOUNTS);
        _asNetwork(
            address(directory),
            abi.encodeCall(directory.proposeModule, (Slots.ACCOUNTS, accountsModule))
        );
        _sync();
        skip(1 days);
        directory.activateModule(Slots.ACCOUNTS);
        _sync();
        _asNetwork(
            address(directory),
            abi.encodeCall(directory.proposeModule, (Slots.INDEPENDENT_RECORDS, address(rules)))
        );
        _sync();
        assertEq(directoryIdx.unclaimedPeriod(), 90 days);
        _assertEveryEventReplayed(
            "StreamDirectory6529", directoryIdx, ReplayEvents.directory(), _none()
        );
    }

    // ------------------------------------------------------------------ negative controls

    /// @dev Slot 10 holds the marketplace owner: a value no `OwnershipTransferred` logged.
    function test_Stream_ReplayFailsOnStateNoLogExplains() public {
        streamIdx.assertMatches();
        vm.store(address(stream), bytes32(uint256(10)), bytes32(uint256(uint160(holder))));
        vm.expectRevert();
        streamIdx.assertMatches();
    }

    /// @dev A sale whose `PrimarySale` log is dropped: the rebuilt outcome is stale.
    function test_Stream_ReplayFailsOnADroppedLog() public {
        _sell(root, _package(root), 0, buyer, 1 ether);
        _apply(_dropOne(address(stream), IStream.PrimarySale.selector));
        vm.expectRevert(bytes("work outcome: 1 != 0"));
        streamIdx.assertMatches();
    }

    /// @dev Slot 3 holds the unclaimed period: a value no `UnclaimedPeriodSet` logged.
    function test_Directory_ReplayFailsOnStateNoLogExplains() public {
        directoryIdx.assertMatches();
        vm.store(address(directory), bytes32(uint256(3)), bytes32(uint256(1 days)));
        vm.expectRevert(bytes("unclaimedPeriod: 86400 != 15552000"));
        directoryIdx.assertMatches();
    }

    /// @dev A period change whose log is dropped: the rebuilt period is stale.
    function test_Directory_ReplayFailsOnADroppedLog() public {
        _asNetwork(address(directory), abi.encodeCall(directory.setUnclaimedPeriod, (90 days)));
        _apply(_dropOne(address(directory), IDirectory.UnclaimedPeriodSet.selector));
        vm.expectRevert(bytes("unclaimedPeriod: 7776000 != 15552000"));
        directoryIdx.assertMatches();
    }
}
