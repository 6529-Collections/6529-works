// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { Editions } from "src/core/Editions.sol";
import { Edition, Minter, PendingModule, Slots } from "src/interfaces/core/CoreTypes.sol";
import { CoreFixture } from "../mocks/core/CoreFixture.sol";
import { HostileModule, MockSale } from "../mocks/core/CoreMocks.sol";
import { EditionsCoreIndexer } from "./EditionsCoreIndexer.sol";

/// @notice Log replay of 6529 Stream Editions (`src/core/Editions.sol`): a history that emits
///         every event the contract can emit rebuilds, from its logs alone (and block times),
///         every getter: each edition's minter, maximum, count, seal and royalties, every
///         balance, the owner, the contract URI, both waiting periods, the module slots, a
///         pending module and every minter's standing.
contract LogReplayEditionsCoreTest is CoreFixture {
    Editions internal ed;
    EditionsCoreIndexer internal indexer;
    MockSale internal second;
    address[4] internal holders;
    uint256[3] internal ids;

    function setUp() public override {
        super.setUp();
        second = new MockSale();
        holders = [collector, makeAddr("a"), makeAddr("b"), address(sale)];
        vm.recordLogs();
        address[] memory minters = new address[](1);
        minters[0] = address(sale);
        ed = new Editions(address(manager), address(stream), marketOwner, address(terms), minters);
        indexer = new EditionsCoreIndexer(address(ed), ed.rebindDelay(), ed.moduleDelay());
        _sync();
    }

    function _sync() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        indexer.ingest(logs, block.timestamp);
    }

    function test_EveryEditionsEventReplaysToTheSameState() public {
        for (uint256 i; i < 3; ++i) {
            ids[i] = _sell(i + 1, collector);
        }
        sale.createEdition(address(ed), ids[0], 10, address(0xFEE), 6529);
        sale.createEdition(address(ed), ids[1], 0, address(0xBEE), 100_000);
        sale.createEdition(address(ed), ids[2], 5, address(0), 0);
        _sync();
        sale.mintEdition(address(ed), holders[1], ids[0], 4, 1 ether);
        sale.mintEdition(address(ed), holders[2], ids[1], 7, 2 ether);
        vm.prank(holders[1]);
        ed.safeTransferFrom(holders[1], holders[2], ids[0], 1, "");
        uint256[] memory batchIds = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        (batchIds[0], batchIds[1], amounts[0], amounts[1]) = (ids[0], ids[1], 1, 3);
        vm.prank(holders[2]);
        ed.safeBatchTransferFrom(holders[2], collector, batchIds, amounts, "");
        vm.prank(collector);
        ed.burn(ids[1], 2);
        sale.seal(address(ed), ids[0], 6);
        terms.setEditionRoyalty(address(ed), ids[1], address(0xCAFE), 777);
        vm.prank(address(terms));
        ed.emitMetadataUpdate(ids[0], ids[2]);
        _sync();
        // The network's settings and the owner.
        ed.setOwner(makeAddr("newOwner"));
        ed.setContractURI("ipfs://editions");
        ed.setRebindDelay(3 days);
        ed.setModuleDelay(2 days);
        _sync();
        // A module announced, one installed, a minter added, the first removed, an edition
        // rebound to the new one.
        HostileModule pending = new HostileModule();
        ed.proposeModule(Slots.TERMS, address(pending));
        ed.addMinter(address(second));
        _sync();
        skip(2 days);
        ed.activateModule(Slots.TERMS);
        ed.proposeModule(Slots.TERMS, address(new HostileModule()));
        ed.removeMinter(address(sale));
        _sync();
        skip(3 days);
        ed.rebind(ids[2], address(second));
        second.mintEdition(address(ed), holders[1], ids[2], 2, 0);
        _sync();

        // Every getter, from logs alone.
        assertEq(indexer.owner(), ed.owner());
        assertEq(indexer.contractURI(), ed.contractURI());
        assertEq(indexer.rebindDelay(), ed.rebindDelay());
        assertEq(indexer.moduleDelay(), ed.moduleDelay());
        assertEq(indexer.moduleOf(Slots.TERMS), ed.moduleOf(Slots.TERMS));
        assertEq(indexer.moduleOf(Slots.TERMS), address(pending));
        assertEq(
            abi.encode(indexer.pendingModule(Slots.TERMS)),
            abi.encode(ed.pendingModule(Slots.TERMS))
        );
        address[2] memory minters = [address(sale), address(second)];
        for (uint256 m; m < 2; ++m) {
            assertEq(abi.encode(indexer.minterOf(minters[m])), abi.encode(ed.minterOf(minters[m])));
        }
        assertTrue(ed.minterOf(address(sale)).removedAt != 0);
        for (uint256 i; i < 3; ++i) {
            assertEq(abi.encode(indexer.editionOf(ids[i])), abi.encode(ed.editionOf(ids[i])));
            for (uint256 a; a < holders.length; ++a) {
                assertEq(indexer.balanceOf(ids[i], holders[a]), ed.balanceOf(holders[a], ids[i]));
            }
        }
        // The history reached every kind of state.
        Edition memory e0 = ed.editionOf(ids[0]);
        assertTrue(e0.supplySealed);
        assertEq(ed.editionOf(ids[2]).minter, address(second));
        assertEq(ed.editionOf(ids[1]).royaltyReceiver, address(0xCAFE));
        PendingModule memory p = ed.pendingModule(Slots.TERMS);
        assertTrue(p.readyAt != 0);
        Minter memory m2 = ed.minterOf(address(second));
        assertTrue(m2.activeFrom != 0);
    }
}
