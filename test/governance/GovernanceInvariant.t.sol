// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { GovernanceFixture } from "../helpers/GovernanceFixture.sol";
import { GovernedTargetMock } from "../mocks/governance/GovernanceMocks.sol";

/// @notice Random actors hand the network over, accept, try to grant themselves network roles,
///         grant and revoke operational keys, brake, cancel and run operations. Every call that
///         the rules refuse is caught, so the campaign keeps going.
contract GovernanceHandler is Test {
    WorksAccessManager internal immutable manager;
    GovernedTargetMock internal immutable target;
    address internal immutable brakeSafe;
    address[] public actors;

    constructor(WorksAccessManager manager_, GovernedTargetMock target_, address brake_) {
        manager = manager_;
        target = target_;
        brakeSafe = brake_;
        for (uint256 i; i < 5; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
        actors.push(manager_.network());
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Whoever is asked schedules, waits and executes `data` on the manager, if it can.
    function _run(address caller, address to, bytes memory data) internal {
        vm.prank(caller);
        try manager.schedule(to, data, 0) returns (bytes32 id, uint32) {
            vm.warp(manager.getSchedule(id));
            vm.prank(caller);
            try manager.execute(to, data) { } catch { }
        } catch {
            vm.prank(caller);
            (bool ok,) = to.call(data);
            ok;
        }
    }

    function transfer(uint256 by, uint256 to) external {
        _run(
            _actor(by),
            address(manager),
            abi.encodeCall(WorksAccessManager.transferNetwork, (_actor(to)))
        );
    }

    uint256 public accepted;

    function accept(uint256 by) external {
        vm.prank(_actor(by));
        try manager.acceptNetwork() {
            ++accepted;
        } catch { }
    }

    function grantNetworkRole(uint256 by, uint256 to, uint8 pick) external {
        uint64[5] memory roles = [
            Roles.ADMIN,
            Roles.NETWORK,
            Roles.PARAMETER_SETTER,
            Roles.FUNDS_SETTER,
            Roles.SUCCESSOR_SETTER
        ];
        _run(
            _actor(by),
            address(manager),
            abi.encodeCall(IAccessManager.grantRole, (roles[pick % 5], _actor(to), 0))
        );
    }

    function grantOperational(uint256 by, uint256 to, bool revoke) external {
        bytes memory data = revoke
            ? abi.encodeCall(IAccessManager.revokeRole, (Roles.PLATFORM, _actor(to)))
            : abi.encodeCall(IAccessManager.grantRole, (Roles.PLATFORM, _actor(to), 0));
        _run(_actor(by), address(manager), data);
    }

    function brakeAndRun(uint256 by, uint256 fee) external {
        address caller = _actor(by);
        bytes memory data = abi.encodeCall(GovernedTargetMock.setFee, (fee));
        vm.prank(caller);
        try manager.schedule(address(target), data, 0) returns (bytes32 id, uint32) {
            vm.prank(brakeSafe);
            try manager.brakeOnce(id) { } catch { }
            uint48 at = manager.notBefore(id);
            vm.warp(at == 0 ? manager.getSchedule(id) : at);
            vm.prank(caller);
            try manager.execute(address(target), data) { } catch { }
        } catch { }
    }

    function renounce(uint256 by, uint8 pick) external {
        address who = _actor(by);
        vm.prank(who);
        try manager.renounceRole(pick % 2 == 0 ? Roles.ADMIN : Roles.PLATFORM, who) { } catch { }
    }
}

/// @notice Exactly one address holds the network roles, and it is `network()`, whatever the
///         actors do.
contract GovernanceInvariantTest is StdInvariant, GovernanceFixture {
    GovernanceHandler internal handler;

    function setUp() public {
        _deployGovernance();
        handler = new GovernanceHandler(manager, target, brakeSafe);
        targetContract(address(handler));
    }

    function invariant_ExactlyOneAddressHoldsTheNetworkRoles() public view {
        address network = manager.network();
        assertTrue(network != address(0));
        uint64[5] memory roles = [
            Roles.ADMIN,
            Roles.NETWORK,
            Roles.PARAMETER_SETTER,
            Roles.FUNDS_SETTER,
            Roles.SUCCESSOR_SETTER
        ];
        uint256 n = handler.actorCount();
        for (uint256 r; r < roles.length; ++r) {
            uint256 holders;
            for (uint256 i; i < n; ++i) {
                address a = handler.actors(i);
                (bool member, uint32 delay) = manager.hasRole(roles[r], a);
                if (!member) continue;
                ++holders;
                assertEq(a, network);
                assertEq(delay, Roles.executionDelay(roles[r]));
            }
            (bool configurator,) = manager.hasRole(roles[r], address(configurator));
            assertFalse(configurator);
            assertEq(holders, 1);
        }
    }
}
