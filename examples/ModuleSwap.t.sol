// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Example: what a module swap looks like to an integrator.
//
// The permanent contracts (Stream, Editions, Directory) keep their rules in replaceable modules,
// one per named slot (Slots.RENDERER, Slots.TERMS, Slots.RECORDS, ...), and sell through
// minters. The network changes a module in two steps: it proposes one (`ModuleProposed`, with
// the time it becomes ready), and after the contract's `moduleDelay`, a network setting, anyone
// activates it (`ModuleSet`). A new minter is added with the same wait (`MinterAdded`, with the
// time it becomes active); a removal takes effect at once. Nothing a module does can move a
// token or change the facts of a finished work: a finalized work keeps the renderer pinned at
// its finalization.
//
// An integrator watches four events on each permanent contract: ModuleProposed, ModuleSet,
// MinterAdded and MinterRemoved (plus ModuleDelaySet, which changes how long the next proposal
// waits); and reads `moduleOf`, `pendingModule`, `isMinter` and `rendererOf`.

import { Vm } from "forge-std/Vm.sol";
import { Renderer } from "src/content/Renderer.sol";
import { PendingModule, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IModules, IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IWorkRules } from "src/interfaces/core/IWorkRules.sol";
import { SaleStarter } from "src/sales/SaleStarter.sol";
import { ExampleBase } from "./ExampleBase.sol";

contract ExampleModuleSwap is ExampleBase {
    address internal collector = makeAddr("collector");
    uint256 internal finalized; // a work whose record is finalized: its renderer is pinned
    uint256 internal unfinalized; // a work whose record is still open
    address internal oldRenderer;
    Renderer internal next;

    function setUp() public override {
        super.setUp();
        finalized = _sell(_original(), collector, 1 ether);
        unfinalized = _sell(_original(), collector, 1 ether);
        // The artist finalizes the first work's record at the state it saw.
        IWorkRules rules = IWorkRules(d.workRules);
        bytes32 state = rules.workStateHash(address(stream), finalized);
        vm.prank(artist);
        rules.finalize(address(stream), finalized, state);
        oldRenderer = stream.moduleOf(Slots.RENDERER);
        next = new Renderer(IContentStore(address(store)), IStatementLog(d.statementLog), 262_144);
    }

    function test_ARendererSwap() public {
        // 1. The network proposes a new renderer. The event carries the time it becomes ready.
        vm.recordLogs();
        vm.prank(network);
        stream.proposeModule(Slots.RENDERER, address(next));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], IModuleSlots.ModuleProposed.selector);
        assertEq(logs[0].topics[1], Slots.RENDERER);
        (address proposed, uint48 readyAt) = abi.decode(logs[0].data, (address, uint48));
        assertEq(proposed, address(next));
        assertEq(readyAt, block.timestamp + stream.moduleDelay(), "7 days at launch");

        // 2. While it waits, the old module is in force and the proposal is readable.
        PendingModule memory p = stream.pendingModule(Slots.RENDERER);
        assertEq(p.module, address(next));
        assertEq(p.readyAt, readyAt);
        assertEq(stream.moduleOf(Slots.RENDERER), oldRenderer);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.RENDERER)
        );
        stream.activateModule(Slots.RENDERER);

        // A change of the delay by the network does not move a pending proposal: it keeps the
        // time it was given.
        vm.prank(network);
        stream.setModuleDelay(0);
        assertEq(stream.pendingModule(Slots.RENDERER).readyAt, readyAt);

        // 3. Once ready, anyone activates it (`ModuleSet` with the previous and the new).
        vm.warp(readyAt);
        vm.expectEmit(address(stream));
        emit IModuleSlots.ModuleSet(Slots.RENDERER, oldRenderer, address(next));
        stream.activateModule(Slots.RENDERER);
        assertEq(stream.moduleOf(Slots.RENDERER), address(next));
        assertEq(stream.pendingModule(Slots.RENDERER).readyAt, 0, "nothing pending");

        // 4. What changed for the works: an open record now draws with the new renderer; a
        //    finalized one keeps the renderer pinned when it was finalized (WorkFacts), so its
        //    metadata does not move. Refresh cached metadata on ModuleSet for open works.
        assertEq(stream.rendererOf(unfinalized), address(next));
        assertEq(stream.rendererOf(finalized), oldRenderer);
        assertEq(facts.rendererOf(address(stream), finalized), oldRenderer);
        assertGt(bytes(stream.tokenURI(unfinalized)).length, 0);
        assertGt(bytes(stream.tokenURI(finalized)).length, 0);
    }

    function test_AMinterIsAddedAfterTheWaitAndRemovedAtOnce() public {
        // A stand-in for a new sale contract (any contract with code can be proposed).
        address minter = address(new SaleStarter());
        uint48 activeFrom = uint48(block.timestamp) + stream.moduleDelay();
        vm.expectEmit(address(stream));
        emit IModules.MinterAdded(minter, activeFrom);
        vm.prank(network);
        stream.addMinter(minter);
        assertFalse(stream.isMinter(minter), "not before activeFrom");
        vm.warp(activeFrom);
        assertTrue(stream.isMinter(minter));

        vm.expectEmit(address(stream));
        emit IModules.MinterRemoved(minter);
        vm.prank(network);
        stream.removeMinter(minter);
        assertFalse(stream.isMinter(minter), "removed at once");
    }
}
