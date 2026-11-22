// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IModuleSlots, IModules } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { CoreFixture } from "../mocks/core/CoreFixture.sol";
import { MockRenderer, MockSale } from "../mocks/core/CoreMocks.sol";
import { ReplayIndexer } from "./ReplayIndexer.sol";
import { CoreDirectoryIndexer, StreamCoreIndexer } from "./StreamCoreIndexer.sol";

/// @notice Log replay of the permanent `Stream` and `Directory`: a history that emits every event
///         of both, from their deployment on, rebuilds every getter from their logs alone, and
///         the rebuilt values match the live contracts after each step.
contract LogReplayStreamCoreTest is CoreFixture {
    StreamCoreIndexer internal streamIdx;
    CoreDirectoryIndexer internal directoryIdx;

    function setUp() public override {
        vm.recordLogs();
        super.setUp();
        streamIdx = new StreamCoreIndexer(address(stream));
        directoryIdx = new CoreDirectoryIndexer(address(directory));
        _sync();
    }

    function _sync() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        streamIdx.ingest(logs, block.timestamp);
        directoryIdx.ingest(logs, block.timestamp);
        streamIdx.assertMatches();
        directoryIdx.assertMatches();
    }

    function test_Replay_EveryEventRebuildsEveryGetter() public {
        address buyer = makeAddr("buyer");
        address operator = makeAddr("operator");
        MockSale second = new MockSale();

        // Minters and modules.
        stream.addMinter(address(second));
        _sync();
        skip(7 days);
        stream.setModuleDelay(1 days);
        MockRenderer nextRenderer = new MockRenderer();
        stream.proposeModule(Slots.RENDERER, address(nextRenderer));
        _sync();
        skip(1 days);
        stream.activateModule(Slots.RENDERER);
        stream.proposeModule(Slots.TERMS, address(nextRenderer));
        _sync();
        stream.removeModule(Slots.TERMS); // also cancels the announcement
        stream.proposeModule(Slots.TERMS, address(terms));
        skip(1 days);
        stream.activateModule(Slots.TERMS);
        _sync();

        // Collections and works.
        stream.createCollection("Second", keccak256("second"));
        uint256 a = _mint(1);
        uint256 b = _mint(2);
        uint256 c = second.mint(address(stream), _facts(3));
        _sync();
        sale.record(address(stream), a, true, buyer, 2 ether);
        sale.send(address(stream), a, buyer);
        sale.record(address(stream), b, false, address(0), 0);
        second.burn(address(stream), c);
        uint256 d = second.mint(address(stream), _facts(3)); // the burned content again
        _sync();

        // Approvals and transfers.
        vm.prank(buyer);
        stream.approve(operator, a);
        _sync();
        vm.prank(buyer);
        stream.setApprovalForAll(operator, true);
        vm.prank(operator);
        stream.transferFrom(buyer, collector, a);
        _sync();

        // Royalties and metadata.
        terms.setRoyalty(address(stream), a, address(0xBEEF), 1000);
        terms.lockRoyaltyRate(address(stream), a);
        terms.refresh(address(stream), a, a);
        terms.refresh(address(stream), 1, 4);
        _sync();

        // Marketplace page.
        stream.setOwner(collector);
        stream.setContractURI("ipfs://page");
        _sync();

        // Rescue.
        stream.setRescueDelay(2 days);
        stream.removeMinter(address(second));
        _sync();
        skip(2 days);
        stream.rescue(d, marketOwner);
        _sync();
        stream.addMinter(address(second));
        _sync();

        // Directory.
        directory.setUnclaimedPeriod(90 days);
        directory.setModuleDelay(0);
        directory.proposeModule(Slots.ACCOUNTS, address(nextRenderer));
        directory.activateModule(Slots.ACCOUNTS);
        directory.removeModule(Slots.FEDERATION);
        _sync();

        bytes32[20] memory streamTopics = [
            IERC721.Transfer.selector,
            IERC721.Approval.selector,
            IERC721.ApprovalForAll.selector,
            IStream.WorkMinted.selector,
            IStream.PrimarySale.selector,
            IStream.WorkRescued.selector,
            IStream.RoyaltySet.selector,
            IStream.RoyaltyRateLocked.selector,
            IStream.CollectionCreated.selector,
            IStream.OwnershipTransferred.selector,
            IStream.ContractURIUpdated.selector,
            IStream.RescueDelaySet.selector,
            IModuleSlots.ModuleDelaySet.selector,
            IModuleSlots.ModuleProposed.selector,
            IModuleSlots.ModuleSet.selector,
            IModules.MinterAdded.selector,
            IModules.MinterRemoved.selector,
            IERC4906.MetadataUpdate.selector,
            IERC4906.BatchMetadataUpdate.selector,
            IAccessManaged.AuthorityUpdated.selector
        ];
        for (uint256 i; i < streamTopics.length; ++i) {
            assertGt(streamIdx.seen(streamTopics[i]), 0, vm.toString(streamTopics[i]));
        }
        bytes32[5] memory directoryTopics = [
            IModuleSlots.ModuleSet.selector,
            IModuleSlots.ModuleProposed.selector,
            IModuleSlots.ModuleDelaySet.selector,
            IDirectory.UnclaimedPeriodSet.selector,
            IAccessManaged.AuthorityUpdated.selector
        ];
        for (uint256 i; i < directoryTopics.length; ++i) {
            assertGt(directoryIdx.seen(directoryTopics[i]), 0, vm.toString(directoryTopics[i]));
        }
    }

    /// @dev A replay fails on an event the indexer does not know.
    function test_Replay_AnUnknownEventFails() public {
        Vm.Log[] memory logs = new Vm.Log[](1);
        logs[0].emitter = address(stream);
        logs[0].topics = new bytes32[](1);
        logs[0].topics[0] = keccak256("Unknown()");
        vm.expectRevert();
        streamIdx.ingest(logs, block.timestamp);
        ReplayIndexer(address(directoryIdx)).ingest(new Vm.Log[](0), block.timestamp);
    }
}
