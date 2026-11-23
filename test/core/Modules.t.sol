// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Modules } from "src/core/Modules.sol";
import { Minter, PendingModule } from "src/interfaces/core/CoreTypes.sol";
import { IModuleSlots, IModules } from "src/interfaces/core/IModules.sol";

contract ModulesHarness is Modules {
    constructor(address authority_, address genesisModule, address genesisMinter)
        AccessManaged(authority_)
    {
        _setModule("A", genesisModule);
        _addMinter(genesisMinter, uint48(block.timestamp));
    }

    /// @dev The slot check the token bases use (`_onlyTerms`), applied to slot "A".
    function onlyA() external view {
        if (msg.sender != moduleOf("A")) revert NotModule("A", msg.sender);
    }

    function wasActive(address a) external view returns (bool) {
        return _wasActiveMinter(a);
    }

    function removedAt(address a) external view returns (uint256) {
        return _removedAtOf(a);
    }
}

contract Code {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @notice `Modules`: adding modules and minters after the network's waiting period (7 days at
///         deployment), removing them at once.
contract ModulesTest is Test {
    AccessManager internal manager;
    ModulesHarness internal m;
    address internal genesisModule;
    address internal genesisMinter;
    address internal next;
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant A = "A";
    bytes32 internal constant B = "B";

    function setUp() public {
        vm.warp(1_800_000_000);
        manager = new AccessManager(address(this));
        genesisModule = address(new Code());
        genesisMinter = address(new Code());
        next = address(new Code());
        m = new ModulesHarness(address(manager), genesisModule, genesisMinter);
    }

    // ---------------------------------------------------------------- the setting

    function test_Delay_IsSevenDaysAtDeployment() public view {
        assertEq(m.moduleDelay(), 7 days);
    }

    function test_SetDelay_OnlyTheNetworkAtOnceWithOldAndNew() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        m.setModuleDelay(1 days);
        vm.expectEmit(address(m));
        emit IModuleSlots.ModuleDelaySet(7 days, 1 days);
        m.setModuleDelay(1 days);
        assertEq(m.moduleDelay(), 1 days);
    }

    function testFuzz_SetDelay_AppliesToLaterAdditions(uint48 delay, uint256 wait) public {
        delay = uint48(bound(delay, 1, 365 days));
        wait = bound(wait, 0, delay - 1);
        m.setModuleDelay(delay);
        m.proposeModule(B, next);
        m.addMinter(next);
        assertEq(m.pendingModule(B).readyAt, block.timestamp + delay);
        skip(wait);
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, B));
        m.activateModule(B);
        assertFalse(m.isMinter(next));
        skip(delay - wait);
        m.activateModule(B);
        assertTrue(m.isMinter(next));
    }

    function test_SetDelay_ZeroIsAllowed() public {
        m.setModuleDelay(0);
        m.proposeModule(B, next);
        m.activateModule(B);
        assertEq(m.moduleOf(B), next);
        m.addMinter(next);
        assertTrue(m.isMinter(next));
    }

    /// @dev A change does not move what is already pending, shorter or longer.
    function test_SetDelay_PendingAdditionsKeepTheirTime() public {
        m.proposeModule(B, next);
        m.addMinter(next);
        uint256 readyAt = block.timestamp + 7 days;
        m.setModuleDelay(0);
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, B));
        m.activateModule(B);
        assertFalse(m.isMinter(next));
        m.setModuleDelay(30 days);
        assertEq(m.pendingModule(B).readyAt, readyAt);
        assertEq(m.minterOf(next).activeFrom, readyAt);
        vm.warp(readyAt);
        m.activateModule(B);
        assertTrue(m.isMinter(next));
    }

    // ---------------------------------------------------------------- genesis

    function test_Genesis_ModuleAndMinterAreActiveAtOnce() public view {
        assertEq(m.moduleOf(A), genesisModule);
        assertTrue(m.isMinter(genesisMinter));
        assertTrue(m.wasActive(genesisMinter));
    }

    // ---------------------------------------------------------------- modules

    function test_Propose_OnlyTheNetwork() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        m.proposeModule(B, next);
    }

    function test_Propose_RefusesAnAddressWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.InvalidModule.selector, stranger));
        m.proposeModule(B, stranger);
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.InvalidModule.selector, address(0)));
        m.proposeModule(B, address(0));
    }

    function test_Propose_AnnouncesAndDoesNotInstall() public {
        vm.expectEmit(address(m));
        emit IModuleSlots.ModuleProposed(B, next, uint48(block.timestamp + 7 days));
        m.proposeModule(B, next);
        assertEq(m.moduleOf(B), address(0));
        PendingModule memory p = m.pendingModule(B);
        assertEq(p.module, next);
        assertEq(p.readyAt, block.timestamp + 7 days);
    }

    function testFuzz_Activate_NeverBeforeTheWait(uint256 wait) public {
        wait = bound(wait, 0, 7 days - 1);
        m.proposeModule(B, next);
        skip(wait);
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, B));
        m.activateModule(B);
        assertEq(m.moduleOf(B), address(0));
    }

    function test_Activate_AnyoneAfterSevenDays() public {
        m.proposeModule(A, next);
        skip(7 days);
        vm.expectEmit(address(m));
        emit IModuleSlots.ModuleSet(A, genesisModule, next);
        vm.prank(stranger);
        m.activateModule(A);
        assertEq(m.moduleOf(A), next);
        assertEq(m.pendingModule(A).readyAt, 0);
    }

    function test_Activate_NothingProposed() public {
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, B));
        m.activateModule(B);
    }

    function test_Propose_AgainRestartsTheWait() public {
        m.proposeModule(B, next);
        skip(6 days);
        address other = address(new Code());
        m.proposeModule(B, other);
        skip(1 days);
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, B));
        m.activateModule(B);
        skip(6 days);
        m.activateModule(B);
        assertEq(m.moduleOf(B), other);
    }

    function test_Remove_AtOnceAndDropsTheProposal() public {
        m.proposeModule(A, next);
        m.removeModule(A);
        assertEq(m.moduleOf(A), address(0));
        skip(7 days);
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, A));
        m.activateModule(A);
    }

    function test_Remove_OnlyTheNetwork() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        m.removeModule(A);
    }

    /// @dev A removed module comes back only through a new 7-day wait.
    function test_Remove_ThenAddAgainWaitsSevenDays() public {
        m.removeModule(A);
        m.proposeModule(A, genesisModule);
        skip(7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, A));
        m.activateModule(A);
        skip(1);
        m.activateModule(A);
        assertEq(m.moduleOf(A), genesisModule);
    }

    function test_OnlyModule() public {
        vm.prank(genesisModule);
        m.onlyA();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.NotModule.selector, A, stranger));
        m.onlyA();
    }

    // ---------------------------------------------------------------- minters

    function testFuzz_AddMinter_NeverActiveBeforeTheWait(uint256 wait) public {
        wait = bound(wait, 0, 7 days - 1);
        vm.expectEmit(address(m));
        emit IModules.MinterAdded(next, uint48(block.timestamp + 7 days));
        m.addMinter(next);
        skip(wait);
        assertFalse(m.isMinter(next));
        assertFalse(m.wasActive(next));
    }

    function test_AddMinter_ActiveAfterSevenDays() public {
        m.addMinter(next);
        skip(7 days);
        assertTrue(m.isMinter(next));
        assertTrue(m.wasActive(next));
    }

    function test_AddMinter_OnlyTheNetworkWithCodeAndNotTwice() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        m.addMinter(next);
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.InvalidModule.selector, stranger));
        m.addMinter(stranger);
        vm.expectRevert(abi.encodeWithSelector(IModules.MinterAlreadyAdded.selector, genesisMinter));
        m.addMinter(genesisMinter);
        // Adding again while waiting must not shorten the wait.
        m.addMinter(next);
        vm.expectRevert(abi.encodeWithSelector(IModules.MinterAlreadyAdded.selector, next));
        m.addMinter(next);
    }

    function test_RemoveMinter_AtOnceKeepsItsRecord() public {
        vm.expectEmit(address(m));
        emit IModules.MinterRemoved(genesisMinter);
        m.removeMinter(genesisMinter);
        assertFalse(m.isMinter(genesisMinter));
        assertTrue(m.wasActive(genesisMinter));
        assertEq(m.removedAt(genesisMinter), block.timestamp);
        Minter memory r = m.minterOf(genesisMinter);
        assertEq(r.removedAt, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, genesisMinter));
        m.removeMinter(genesisMinter);
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, stranger));
        m.removeMinter(stranger);
    }

    function test_RemoveMinter_ThenAddAgainWaitsSevenDays() public {
        m.removeMinter(genesisMinter);
        m.addMinter(genesisMinter);
        assertFalse(m.isMinter(genesisMinter));
        skip(7 days - 1);
        assertFalse(m.isMinter(genesisMinter));
        skip(1);
        assertTrue(m.isMinter(genesisMinter));
        assertEq(m.removedAt(genesisMinter), 0);
    }
}
