// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Roles } from "src/governance/Roles.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { GovernanceFixture } from "../helpers/GovernanceFixture.sol";
import { GovernedTargetMock } from "../mocks/GovernanceMocks.sol";

/// @notice A compromised admin Safe schedules random hostile operations; two vigilant
///         guardians cancel everything before time moves on. With `fail_on_revert`, any
///         cancel the guardians are not entitled to fails the campaign.
contract CompromisedAdminHandler is Test {
    struct Pending {
        address to;
        bytes data;
        address canceller;
        address victim;
    }

    WorksAccessManager internal immutable manager;
    GovernedTargetMock internal immutable target;
    AccessManager internal immutable rogue;
    address internal immutable admin;
    address internal immutable guardianA;
    address internal immutable guardianB;
    address internal immutable attacker;

    GovernanceConfigurator internal immutable configurator;
    bytes internal encodedConfig;
    Pending[] internal pending;
    uint256 public scheduled;
    uint256 public cancelled;
    bool public prematureExecution;
    bool public selfRescue;

    /// @param actors The admin Safe, guardian A, guardian B and the attacker, in that order.
    constructor(
        GovernanceConfigurator configurator_,
        bytes memory encodedConfig_,
        WorksAccessManager manager_,
        GovernedTargetMock target_,
        address[4] memory actors
    ) {
        configurator = configurator_;
        encodedConfig = encodedConfig_;
        manager = manager_;
        target = target_;
        (admin, guardianA, guardianB, attacker) = (actors[0], actors[1], actors[2], actors[3]);
        rogue = new AccessManager(actors[3]);
    }

    /// @dev The hostile menu. Returns the call, the guardian that cancels it, and the guardian
    ///      it revokes (zero if none), which must never be the canceller.
    function _hostile(uint256 menu, uint256 arg)
        internal
        view
        returns (address to, bytes memory data, address canceller, address revoked)
    {
        address victim = arg % 2 == 0 ? guardianA : guardianB;
        address other = victim == guardianA ? guardianB : guardianA;
        uint64 role = uint64(arg % Roles.COUNT);
        uint64 nonAdmin = uint64(1 + arg % (Roles.COUNT - 1));
        to = address(manager);
        canceller = guardianA;
        uint256 m = menu % 19;
        if (m < 2) {
            uint64 revokedRole = m == 0 ? Roles.GUARDIAN : Roles.PAUSER;
            data = abi.encodeCall(IAccessManager.revokeRole, (revokedRole, victim));
            (canceller, revoked) = (other, victim);
        } else if (m == 2) {
            data = abi.encodeCall(IAccessManager.grantRole, (Roles.ADMIN, attacker, 0));
        } else if (m == 3) {
            data = abi.encodeCall(IAccessManager.grantRole, (role, attacker, 0));
        } else if (m == 4) {
            data = abi.encodeCall(IAccessManager.setGrantDelay, (role, 0));
        } else if (m == 5) {
            address t = arg % 2 == 0 ? address(target) : address(manager);
            data = abi.encodeCall(IAccessManager.setTargetAdminDelay, (t, 0));
        } else if (m == 6) {
            data = abi.encodeCall(
                IAccessManager.setTargetFunctionRole,
                (
                    address(target),
                    _one(GovernedTargetMock.setRecipient.selector),
                    Roles.PARAMETER_SETTER
                )
            );
        } else if (m == 7) {
            data = abi.encodeCall(
                IAccessManager.setTargetFunctionRole,
                (address(manager), _one(IAccessManager.revokeRole.selector), Roles.ADMIN)
            );
        } else if (m == 8) {
            data = abi.encodeCall(IAccessManager.setRoleGuardian, (nonAdmin, Roles.ADMIN));
        } else if (m == 9) {
            data = abi.encodeCall(IAccessManager.setRoleAdmin, (nonAdmin, Roles.KEEPER));
        } else if (m == 10) {
            data = abi.encodeCall(IAccessManager.setTargetClosed, (address(target), true));
        } else if (m == 11) {
            data = abi.encodeCall(IAccessManager.updateAuthority, (address(target), address(rogue)));
        } else if (m == 12) {
            data = abi.encodeCall(IAccessManager.labelRole, (nonAdmin, "pwned"));
        } else if (m == 13) {
            data = abi.encodeCall(IAccessManager.grantRole, (Roles.ADMIN, admin, 0));
        } else {
            to = address(target);
            if (m == 14) {
                data =
                    abi.encodeCall(GovernedTargetMock.setRecipient, (target.recipient(), attacker));
            } else if (m == 15) {
                data = abi.encodeCall(GovernedTargetMock.setVerifier, (target.verifier(), attacker));
            } else if (m == 16) {
                data = abi.encodeCall(GovernedTargetMock.setFee, (arg));
            } else if (m == 17) {
                data = abi.encodeCall(GovernedTargetMock.adminOnly, ()); // unmapped: ADMIN
            } else {
                // Direct target migration; its role mapping is locked by OpenZeppelin.
                data = abi.encodeCall(IAccessManaged.setAuthority, (address(rogue)));
            }
        }
    }

    function _one(bytes4 selector) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = selector;
    }

    /// @notice The admin schedules a hostile operation. Scheduling itself must always work.
    function scheduleHostile(uint256 menu, uint256 arg) external {
        (address to, bytes memory data, address canceller, address revoked) = _hostile(menu, arg);
        if (manager.getSchedule(manager.hashOperation(admin, to, data)) != 0) return;
        vm.prank(admin);
        manager.schedule(to, data, 0);
        pending.push(Pending(to, data, canceller, revoked));
        ++scheduled;
    }

    /// @notice The admin tries to execute a pending operation early.
    function tryExecute(uint256 index) external {
        if (pending.length == 0) return;
        Pending memory op = pending[index % pending.length];
        vm.prank(admin);
        try manager.execute(op.to, op.data) {
            prematureExecution = true;
        } catch { }
    }

    /// @notice The admin calls a hostile function directly, bypassing `execute`.
    function tryDirect(uint256 menu, uint256 arg) external {
        (address to, bytes memory data,,) = _hostile(menu, arg);
        vm.prank(admin);
        (bool ok,) = to.call(data);
        if (ok) prematureExecution = true;
    }

    /// @notice A guardian tries to cancel a pending revocation of its own role.
    function tryGuardianSelfRescue(uint256 index) external {
        if (pending.length == 0) return;
        Pending memory op = pending[index % pending.length];
        if (op.victim == address(0)) return;
        vm.prank(op.victim);
        try manager.cancel(admin, op.to, op.data) {
            selfRescue = true;
        } catch { }
    }

    /// @notice Time passes, but only after the guardians have cancelled everything pending.
    function warp(uint256 seconds_) external {
        for (uint256 i; i < pending.length; ++i) {
            vm.prank(pending[i].canceller);
            manager.cancel(admin, pending[i].to, pending[i].data);
            ++cancelled;
        }
        delete pending;
        vm.warp(block.timestamp + bound(seconds_, 1 hours, 40 days));
        configurator.verify(manager, abi.decode(encodedConfig, (GovernanceConfig.Config)));
    }
}

contract GovernanceInvariantTest is StdInvariant, GovernanceFixture {
    CompromisedAdminHandler internal handler;

    function setUp() public {
        _deployGovernance();
        handler = new CompromisedAdminHandler(
            configurator,
            abi.encode(_config()),
            manager,
            target,
            [adminSafe, guardianA, guardianB, attacker]
        );
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = CompromisedAdminHandler.scheduleHostile.selector;
        selectors[1] = CompromisedAdminHandler.tryExecute.selector;
        selectors[2] = CompromisedAdminHandler.tryDirect.selector;
        selectors[3] = CompromisedAdminHandler.tryGuardianSelfRescue.selector;
        selectors[4] = CompromisedAdminHandler.warp.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// One campaign, three properties: nothing a vetoed admin schedules changes the target or
    /// grants the attacker a role; nothing executes before its delay, directly or through
    /// `execute`; and no guardian ever cancels its own revocation. The full configuration
    /// readback runs in the handler at every warp, since only a flagged execution can change
    /// state between warps.
    function invariant_CompromisedAdminIsContained() public view {
        assertEq(target.authority(), address(manager));
        assertEq(target.recipient(), recipient0);
        assertEq(target.verifier(), verifier0);
        assertEq(target.fee(), 0);
        assertEq(target.adminCalls(), 0);
        for (uint64 role; role < Roles.COUNT; ++role) {
            (uint48 since,,,) = manager.getAccess(role, attacker);
            assertEq(since, 0, "attacker gained a role");
        }
        assertFalse(handler.prematureExecution(), "premature execution");
        assertFalse(handler.selfRescue(), "guardian cancelled its own revocation");
    }
}
