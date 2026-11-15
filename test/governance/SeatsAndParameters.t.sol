// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { PermanenceFixture } from "./PermanenceFixture.sol";

/// @notice Seat caps (GV-40), the admin delay floor (GV-38), the manager's own configuration
///         lock (GV-39) and the governed parameters with compiled bounds (GV-41).
contract SeatsAndParametersTest is PermanenceFixture {
    function setUp() public {
        _deployGovernance();
    }

    function _grant(uint64 role, address account, uint32 delay) internal returns (bytes memory) {
        return abi.encodeCall(IAccessManager.grantRole, (role, account, delay));
    }

    function _scheduleReady(bytes memory data) internal {
        bytes32 id = _schedule(adminSafe, address(manager), data);
        vm.warp(manager.getSchedule(id));
    }

    // ------------------------------------------------------------------ seats

    function test_SeatsAreCountedFromGenesis() public view {
        address[] memory admins = manager.seatHolders(Roles.ADMIN);
        assertEq(admins.length, 2, "the configurator's seat was freed");
        assertTrue(
            (admins[0] == adminSafe && admins[1] == coldAdmin)
                || (admins[0] == coldAdmin && admins[1] == adminSafe)
        );
        assertEq(_guardianSeats(), 3);
        assertEq(manager.seatHolders(Roles.PLATFORM).length, 0, "other roles are not seated");
    }

    function test_AdminSeatsAreCappedAndAFreedSeatCanBeFilled() public {
        for (uint256 i; i < 3; ++i) {
            _adminExecute(
                _grant(Roles.ADMIN, makeAddr(string.concat("admin", vm.toString(i))), ADMIN_DELAY)
            );
        }
        assertEq(manager.seatHolders(Roles.ADMIN).length, 5);
        bytes memory sixth = _grant(Roles.ADMIN, makeAddr("sixth"), ADMIN_DELAY);
        _scheduleReady(sixth);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.SeatCapReached.selector, Roles.ADMIN, 5)
        );
        vm.prank(adminSafe);
        manager.execute(address(manager), sixth);

        _adminExecute(_revoke(Roles.ADMIN, makeAddr("admin0")));
        _adminExecute(sixth);
        assertEq(manager.seatHolders(Roles.ADMIN).length, 5);
    }

    function test_GuardianSeatsAreCappedAndPendingGrantsCount() public {
        for (uint256 i; i < 4; ++i) {
            // Executed but still in the 30-day grant delay: the seat is taken.
            _adminExecute(_grant(Roles.GUARDIAN, makeAddr(string.concat("g", vm.toString(i))), 0));
        }
        (bool active,) = manager.hasRole(Roles.GUARDIAN, makeAddr("g3"));
        assertFalse(active, "pending");
        assertEq(_guardianSeats(), 7);
        bytes memory eighth = _grant(Roles.GUARDIAN, makeAddr("eighth"), 0);
        _scheduleReady(eighth);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.SeatCapReached.selector, Roles.GUARDIAN, 7)
        );
        vm.prank(adminSafe);
        manager.execute(address(manager), eighth);
        // A renounced seat is freed at once.
        vm.prank(guardianA);
        manager.renounceRole(Roles.GUARDIAN, guardianA);
        assertEq(_guardianSeats(), 6);
    }

    function test_ARegrantToAnExistingHolderTakesNoNewSeat() public {
        _adminExecute(_grant(Roles.ADMIN, coldAdmin, 45 days));
        assertEq(manager.seatHolders(Roles.ADMIN).length, 2);
    }

    // ------------------------------------------------------------------ admin floor

    function test_AnAdminDelayBelowThirtyDaysIsRefused() public {
        bytes memory fast = _grant(Roles.ADMIN, makeAddr("fast"), ADMIN_DELAY - 1);
        _scheduleReady(fast);
        vm.expectRevert(
            abi.encodeWithSelector(
                WorksAccessManager.AdminDelayBelowFloor.selector, ADMIN_DELAY - 1
            )
        );
        vm.prank(adminSafe);
        manager.execute(address(manager), fast);
    }

    // ------------------------------------------------------------------ the manager's own config

    function test_TheManagersOwnSelectorsCannotBeRemapped() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = WorksAccessManager.registerSuccessor.selector;
        bytes memory remap = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (address(manager), selectors, Roles.PUBLIC)
        );
        _scheduleReady(remap);
        vm.expectRevert(WorksAccessManager.ManagerSelfConfiguration.selector);
        vm.prank(adminSafe);
        manager.execute(address(manager), remap);
    }

    // ------------------------------------------------------------------ parameters

    function test_DefaultsAndCompiledBounds() public view {
        uint32[6] memory defaults = [SLOW, ESCALATED, SILENCE, RECOVERY, uint32(5), uint32(7)];
        uint32[6] memory mins = [uint32(30 days), 60 days, 180 days, 90 days, 3, 3];
        uint32[6] memory maxs = [uint32(365 days), 730 days, 1095 days, 730 days, 16, 16];
        for (uint8 i; i < 6; ++i) {
            WorksAccessManager.Parameter p = WorksAccessManager.Parameter(i);
            assertEq(manager.parameter(p), defaults[i], "default");
            (uint32 min, uint32 max) = manager.parameterBounds(p);
            assertEq(min, mins[i], "min");
            assertEq(max, maxs[i], "max");
        }
    }

    function test_AParameterMovesThroughTheSlowLaneWithinItsBounds() public {
        WorksAccessManager.Parameter p = WorksAccessManager.Parameter.ESCALATED_DELAY;
        bytes memory raise = _setParameter(p, ESCALATED, 200 days);
        bytes32 id = _schedule(adminSafe, address(manager), raise);
        assertEq(manager.getSchedule(id), block.timestamp + SLOW, "slow lane");
        vm.warp(manager.getSchedule(id));
        vm.expectEmit(address(manager));
        emit WorksAccessManager.ParameterSet(p, ESCALATED, 200 days);
        vm.prank(adminSafe);
        manager.execute(address(manager), raise);
        assertEq(manager.parameter(p), 200 days);

        bytes memory stale = _setParameter(p, ESCALATED, 90 days);
        _scheduleReady(stale);
        vm.expectRevert(
            abi.encodeWithSelector(
                WorksAccessManager.ExpectedValueMismatch.selector, ESCALATED, 200 days
            )
        );
        vm.prank(adminSafe);
        manager.execute(address(manager), stale);

        bytes memory below = _setParameter(p, 200 days, 60 days - 1);
        _scheduleReady(below);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.ParameterOutOfBounds.selector, p, 60 days - 1)
        );
        vm.prank(adminSafe);
        manager.execute(address(manager), below);
    }

    function test_AnyGuardianStopsAParameterChangeWithoutAStrike() public {
        bytes memory cut =
            _setParameter(WorksAccessManager.Parameter.RECOVERY_SILENCE, SILENCE, 180 days);
        bytes32 id = _schedule(adminSafe, address(manager), cut);
        _cancel(guardianB, adminSafe, cut);
        assertEq(manager.getSchedule(id), 0);
        _schedule(adminSafe, address(manager), cut);
        assertEq(manager.getSchedule(id), block.timestamp + SLOW, "never escalated");
    }

    function test_ALowerSeatCapRefusesNewSeatsOnly() public {
        bytes memory cap = _setParameter(WorksAccessManager.Parameter.GUARDIAN_SEATS, 7, 3);
        _adminExecute(cap);
        assertEq(_guardianSeats(), 3, "existing seats stay");
        bytes memory fourth = _grant(Roles.GUARDIAN, makeAddr("fourth"), 0);
        _scheduleReady(fourth);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.SeatCapReached.selector, Roles.GUARDIAN, 3)
        );
        vm.prank(adminSafe);
        manager.execute(address(manager), fourth);
    }

    function test_TheRecoveryAddressIsSetInTheSlowLane() public {
        address r = makeAddr("recovery");
        bytes memory set = abi.encodeCall(WorksAccessManager.setRecoveryAddress, (address(0), r));
        bytes32 id = _schedule(adminSafe, address(manager), set);
        assertEq(manager.getSchedule(id), block.timestamp + SLOW);
        vm.warp(manager.getSchedule(id));
        vm.expectEmit(address(manager));
        emit WorksAccessManager.RecoveryAddressSet(address(0), r);
        vm.prank(adminSafe);
        manager.execute(address(manager), set);
        assertEq(manager.recoveryAddress(), r);

        bytes memory stale = abi.encodeCall(WorksAccessManager.setRecoveryAddress, (address(0), r));
        _scheduleReady(stale);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.ExpectedValueMismatch.selector, 0, uint160(r))
        );
        vm.prank(adminSafe);
        manager.execute(address(manager), stale);
    }
}
