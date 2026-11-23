// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Minter, PendingModule, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IModuleSlots, IModules } from "src/interfaces/core/IModules.sol";
import { CoreFixture } from "../mocks/core/CoreFixture.sol";
import { MockRenderer, MockSale } from "../mocks/core/CoreMocks.sol";

/// @notice The network's waiting-period setting `moduleDelay`, through the real `Stream6529` and
///         the real `StreamDirectory6529` (not a harness): only the network sets it, the event
///         carries old and new, an addition is refused before the period in force when it was made
///         has elapsed, zero works, and an addition already made keeps the time it was given.
contract StreamSettingsTest is CoreFixture {
    function _unauthorized(address caller) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller);
    }

    function _targets() internal view returns (IModuleSlots[2] memory) {
        return [IModuleSlots(address(stream)), IModuleSlots(address(directory))];
    }

    function testFuzz_ModuleDelay_OnlyTheNetworkEventCarriesOldAndNew(
        address caller,
        uint48 first,
        uint48 second
    ) public {
        vm.assume(caller != address(this));
        IModuleSlots[2] memory t = _targets();
        for (uint256 i; i < 2; ++i) {
            assertEq(t[i].moduleDelay(), 7 days);
            vm.prank(caller);
            vm.expectRevert(_unauthorized(caller));
            t[i].setModuleDelay(first);
            vm.expectEmit(address(t[i]));
            emit IModuleSlots.ModuleDelaySet(7 days, first);
            t[i].setModuleDelay(first);
            vm.expectEmit(address(t[i]));
            emit IModuleSlots.ModuleDelaySet(first, second);
            t[i].setModuleDelay(second);
            assertEq(t[i].moduleDelay(), second);
        }
    }

    /// @dev A proposed module is installed by anyone, never before the period in force when it
    ///      was proposed, always from then on; on both contracts.
    function testFuzz_ProposeModule_RefusedBeforeThePeriod(
        uint48 delay,
        uint256 wait,
        address anyone
    ) public {
        delay = uint48(bound(delay, 0, 3650 days));
        wait = bound(wait, 0, 3650 days);
        MockRenderer next = new MockRenderer();
        IModuleSlots[2] memory t = _targets();
        bytes32[2] memory slot = [Slots.RENDERER, Slots.ACCOUNTS];
        for (uint256 i; i < 2; ++i) {
            t[i].setModuleDelay(delay);
            uint48 readyAt = uint48(block.timestamp) + delay;
            vm.expectEmit(address(t[i]));
            emit IModuleSlots.ModuleProposed(slot[i], address(next), readyAt);
            t[i].proposeModule(slot[i], address(next));
            PendingModule memory p = t[i].pendingModule(slot[i]);
            assertEq(p.module, address(next));
            assertEq(p.readyAt, readyAt);
        }
        skip(wait);
        for (uint256 i; i < 2; ++i) {
            address before = t[i].moduleOf(slot[i]);
            vm.prank(anyone);
            if (wait < delay) {
                vm.expectRevert(
                    abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, slot[i])
                );
                t[i].activateModule(slot[i]);
                assertEq(t[i].moduleOf(slot[i]), before);
            } else {
                vm.expectEmit(address(t[i]));
                emit IModuleSlots.ModuleSet(slot[i], before, address(next));
                t[i].activateModule(slot[i]);
                assertEq(t[i].moduleOf(slot[i]), address(next));
                assertEq(t[i].pendingModule(slot[i]).readyAt, 0);
            }
        }
    }

    /// @dev A change of the setting does not touch an announcement already made, either way.
    function testFuzz_ModuleDelay_APendingModuleKeepsItsTime(uint48 later) public {
        // `Modules` adds the delay to a 48-bit time; a delay that overflows it refuses every
        // proposal (the network's setting, undone at once).
        later = uint48(bound(later, 0, 3650 days));
        MockRenderer next = new MockRenderer();
        IModuleSlots[2] memory t = _targets();
        bytes32[2] memory slot = [Slots.TERMS, Slots.INDEPENDENT_STREAM];
        for (uint256 i; i < 2; ++i) {
            t[i].proposeModule(slot[i], address(next));
            t[i].setModuleDelay(later);
        }
        skip(7 days - 1);
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, slot[i]));
            t[i].activateModule(slot[i]);
        }
        skip(1);
        for (uint256 i; i < 2; ++i) {
            t[i].activateModule(slot[i]);
            assertEq(t[i].moduleOf(slot[i]), address(next));
        }
        // A later proposal follows the new value.
        MockRenderer third = new MockRenderer();
        for (uint256 i; i < 2; ++i) {
            t[i].proposeModule(slot[i], address(third));
            assertEq(t[i].pendingModule(slot[i]).readyAt, uint48(block.timestamp) + later);
        }
    }

    function test_ModuleDelay_ZeroInstallsAtOnce() public {
        MockRenderer next = new MockRenderer();
        stream.setModuleDelay(0);
        directory.setModuleDelay(0);
        stream.proposeModule(Slots.RENDERER, address(next));
        stream.activateModule(Slots.RENDERER);
        directory.proposeModule(Slots.ACCOUNTS, address(next));
        directory.activateModule(Slots.ACCOUNTS);
        assertEq(stream.moduleOf(Slots.RENDERER), address(next));
        assertEq(directory.moduleOf(Slots.ACCOUNTS), address(next));
        MockSale minter = new MockSale();
        stream.addMinter(address(minter));
        assertTrue(stream.isMinter(address(minter)));
        minter.mint(address(stream), _facts(1));
    }

    function test_ProposeModule_Refusals() public {
        IModuleSlots[2] memory t = _targets();
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IModuleSlots.InvalidModule.selector, address(0)));
            t[i].proposeModule(Slots.TERMS, address(0));
            vm.expectRevert(abi.encodeWithSelector(IModuleSlots.InvalidModule.selector, collector));
            t[i].proposeModule(Slots.TERMS, collector);
            vm.expectRevert(
                abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, bytes32("NONE"))
            );
            t[i].activateModule(bytes32("NONE"));
        }
    }

    /// @dev Removal is at once, and also cancels an announcement.
    function test_RemoveModule_AtOnceAndCancelsAnAnnouncement() public {
        MockRenderer next = new MockRenderer();
        IModuleSlots[2] memory t = _targets();
        bytes32[2] memory slot = [Slots.RECORDS, Slots.INDEPENDENT_RECORDS];
        for (uint256 i; i < 2; ++i) {
            address before = t[i].moduleOf(slot[i]);
            t[i].proposeModule(slot[i], address(next));
            vm.expectEmit(address(t[i]));
            emit IModuleSlots.ModuleSet(slot[i], before, address(0));
            t[i].removeModule(slot[i]);
            assertEq(t[i].moduleOf(slot[i]), address(0));
            skip(7 days);
            vm.expectRevert(abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, slot[i]));
            t[i].activateModule(slot[i]);
        }
    }

    // ------------------------------------------------------------------------ minters (Stream)

    function testFuzz_AddMinter_RefusedBeforeThePeriodInForce(uint48 delay, uint256 wait) public {
        delay = uint48(bound(delay, 0, 3650 days));
        wait = bound(wait, 0, 3650 days);
        stream.setModuleDelay(delay);
        MockSale next = new MockSale();
        uint48 activeFrom = uint48(block.timestamp) + delay;
        vm.expectEmit(address(stream));
        emit IModules.MinterAdded(address(next), activeFrom);
        stream.addMinter(address(next));
        // A later change of the setting does not touch it.
        stream.setModuleDelay(0);
        skip(wait);
        if (wait < delay) {
            assertFalse(stream.isMinter(address(next)));
            vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(next)));
            next.mint(address(stream), _facts(1));
        } else {
            assertTrue(stream.isMinter(address(next)));
            next.mint(address(stream), _facts(1));
        }
    }

    function test_AddMinter_Refusals() public {
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.InvalidModule.selector, collector));
        stream.addMinter(collector);
        vm.expectRevert(abi.encodeWithSelector(IModules.MinterAlreadyAdded.selector, address(sale)));
        stream.addMinter(address(sale));
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, collector));
        stream.removeMinter(collector);
        stream.removeMinter(address(sale));
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(sale)));
        stream.removeMinter(address(sale));
    }

    function test_RemoveMinter_AtOnceAndAddedAgainWithANewWait() public {
        vm.expectEmit(address(stream));
        emit IModules.MinterRemoved(address(sale));
        stream.removeMinter(address(sale));
        assertFalse(stream.isMinter(address(sale)));
        Minter memory m = stream.minterOf(address(sale));
        assertEq(m.removedAt, block.timestamp);
        stream.addMinter(address(sale));
        m = stream.minterOf(address(sale));
        assertEq(m.removedAt, 0);
        assertEq(m.activeFrom, block.timestamp + 7 days);
        assertFalse(stream.isMinter(address(sale)));
        skip(7 days);
        assertTrue(stream.isMinter(address(sale)));
    }
}
