// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Roles } from "src/governance/Roles.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { GovernanceFixture } from "../helpers/GovernanceFixture.sol";
import { GovernedTargetMock } from "../mocks/GovernanceMocks.sol";
import { Erc165PeerMock, WiringTargetMock } from "../mocks/GenesisWiringMocks.sol";

/// @notice The genesis wiring phase: one-shot binds and admitted-minter grants executed by the
///         configurator as zero-delay ADMIN, inside the configuring transaction.
contract GenesisWiringTest is GovernanceFixture {
    WiringTargetMock internal wired;
    Erc165PeerMock internal peerA;
    Erc165PeerMock internal peerB;

    function setUp() public {
        _deployUnconfigured();
        wired = new WiringTargetMock(address(manager));
        peerA = new Erc165PeerMock();
        peerB = new Erc165PeerMock();
    }

    /// @dev The default config plus `wired`, whose `bind` maps to the 30-day class after
    ///      genesis, like `setAdmittedMinter`.
    function _wiredConfig() internal view returns (GovernanceConfig.Config memory cfg) {
        cfg = _config();
        GovernanceConfig.Target[] memory targets = new GovernanceConfig.Target[](2);
        targets[0] = cfg.targets[0];
        GovernanceConfig.FunctionRole[] memory fns = new GovernanceConfig.FunctionRole[](2);
        fns[0] =
            GovernanceConfig.FunctionRole(WiringTargetMock.bind.selector, Roles.SUCCESSOR_SETTER);
        fns[1] =
            GovernanceConfig.FunctionRole(WiringTargetMock.refuse.selector, Roles.PARAMETER_SETTER);
        targets[1] = GovernanceConfig.Target(address(wired), fns);
        cfg.targets = targets;
    }

    function _call(address to, bytes memory data)
        internal
        pure
        returns (GovernanceConfig.Call memory)
    {
        return GovernanceConfig.Call(to, data);
    }

    function _binds() internal view returns (GovernanceConfig.Call[] memory wiring) {
        wiring = new GovernanceConfig.Call[](2);
        wiring[0] =
            _call(address(wired), abi.encodeCall(WiringTargetMock.bind, (1, address(peerA))));
        wiring[1] =
            _call(address(wired), abi.encodeCall(WiringTargetMock.bind, (2, address(peerB))));
    }

    function _expectWiringRevert(GovernanceConfig.Call[] memory wiring, bytes memory err) internal {
        GovernanceConfig.Config memory cfg = _wiredConfig();
        vm.expectRevert(err);
        configurator.configure(cfg, MANIFEST, wiring);
    }

    // ------------------------------------------------------------------ happy path

    function test_WiringExecutesOneShotBindsInTheConfiguringTransaction() public {
        GovernanceConfig.Config memory cfg = _wiredConfig();
        GovernanceConfig.Call[] memory wiring = _binds();
        vm.expectEmit(address(wired));
        emit WiringTargetMock.Bound(1, address(peerA));
        vm.expectEmit(address(wired));
        emit WiringTargetMock.Bound(2, address(peerB));
        vm.expectEmit(address(configurator));
        emit GovernanceConfigurator.GovernanceConfigured(
            address(manager), keccak256(abi.encode(cfg)), MANIFEST, keccak256(abi.encode(wiring))
        );
        configurator.configure(cfg, MANIFEST, wiring);
        assertEq(wired.bound(1), address(peerA));
        assertEq(wired.bound(2), address(peerB));

        _settle();
        configurator.verify(cfg);
    }

    function test_WiringRunsBeforeSelectorsAreMapped() public {
        // `bind` maps to SUCCESSOR_SETTER, which the configurator never holds, yet the wiring
        // call succeeds: it runs while every selector still resolves to the zero-delay ADMIN.
        configurator.configure(_wiredConfig(), MANIFEST, _binds());
        assertEq(
            manager.getTargetFunctionRole(address(wired), WiringTargetMock.bind.selector),
            Roles.SUCCESSOR_SETTER
        );
        (uint48 since,,,) = manager.getAccess(Roles.SUCCESSOR_SETTER, address(configurator));
        assertEq(since, 0);

        // After genesis the same kind of call is a 30-day, guardian-vetoable operation.
        (bool immediate, uint32 delay) =
            manager.canCall(adminSafe, address(wired), WiringTargetMock.bind.selector);
        assertFalse(immediate);
        assertEq(delay, 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManaged.AccessManagedUnauthorized.selector, address(configurator)
            )
        );
        vm.prank(address(configurator));
        wired.bind(3, address(peerA));
    }

    function test_ConfiguratorEndsWithNoRoleAfterWiring() public {
        configurator.configure(_wiredConfig(), MANIFEST, _binds());
        for (uint64 role; role < Roles.COUNT; ++role) {
            assertFalse(GovernanceConfig.hasRecord(manager, role, address(configurator)));
        }
    }

    function test_EmptyWiringIsAllowed() public {
        configurator.configure(_wiredConfig(), MANIFEST, _noWiring());
        assertEq(wired.bound(1), address(0));
    }

    // ------------------------------------------------------------------ failures abort all

    function test_RevertingWiringCallAbortsTheWholeConfiguration() public {
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](2);
        wiring[0] =
            _call(address(wired), abi.encodeCall(WiringTargetMock.bind, (1, address(peerA))));
        wiring[1] = _call(address(wired), abi.encodeCall(WiringTargetMock.refuse, ()));
        _expectWiringRevert(wiring, abi.encodeWithSelector(WiringTargetMock.Refused.selector));

        // Nothing happened: no bind, no role setup, and the configurator is still the admin.
        assertEq(wired.bound(1), address(0));
        assertEq(manager.getRoleGuardian(Roles.PAUSER), Roles.ADMIN);
        (bool stillAdmin,) = manager.hasRole(Roles.ADMIN, address(configurator));
        assertTrue(stillAdmin);
        (uint48 since,,,) = manager.getAccess(Roles.ADMIN, adminSafe);
        assertEq(since, 0);
    }

    function test_SilentWiringRevertIsNamedByIndex() public {
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](2);
        wiring[0] =
            _call(address(wired), abi.encodeCall(WiringTargetMock.bind, (1, address(peerA))));
        wiring[1] = _call(address(wired), abi.encodeCall(WiringTargetMock.silent, ()));
        _expectWiringRevert(
            wiring, abi.encodeWithSelector(GovernanceConfig.WiringCallFailed.selector, 1)
        );
    }

    function test_RepeatedOneShotBindAbortsTheWholeConfiguration() public {
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](2);
        wiring[0] =
            _call(address(wired), abi.encodeCall(WiringTargetMock.bind, (1, address(peerA))));
        wiring[1] =
            _call(address(wired), abi.encodeCall(WiringTargetMock.bind, (1, address(peerB))));
        _expectWiringRevert(
            wiring, abi.encodeWithSelector(WiringTargetMock.AlreadyBound.selector, 1)
        );
    }

    // ------------------------------------------------------------------ rejected wiring

    function test_RejectsWiringOnTheManagersRoleAdminFunctions() public {
        bytes[2] memory calls = [
            abi.encodeCall(IAccessManager.grantRole, (Roles.ADMIN, attacker, 0)),
            abi.encodeCall(
                IAccessManager.setTargetFunctionRole,
                (address(target), _one(GovernedTargetMock.setRecipient.selector), Roles.KEEPER)
            )
        ];
        for (uint256 i; i < calls.length; ++i) {
            GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](1);
            wiring[0] = _call(address(manager), calls[i]);
            _expectWiringRevert(
                wiring,
                abi.encodeWithSelector(
                    GovernanceConfig.InvalidWiringCall.selector, address(manager), bytes4(calls[i])
                )
            );
        }
    }

    function test_RejectsAccessManagementSelectorsOnAnyTarget() public {
        bytes4[15] memory selectors = [
            IAccessManager.labelRole.selector,
            IAccessManager.grantRole.selector,
            IAccessManager.revokeRole.selector,
            IAccessManager.renounceRole.selector,
            IAccessManager.setRoleAdmin.selector,
            IAccessManager.setRoleGuardian.selector,
            IAccessManager.setGrantDelay.selector,
            IAccessManager.setTargetFunctionRole.selector,
            IAccessManager.setTargetAdminDelay.selector,
            IAccessManager.setTargetClosed.selector,
            IAccessManager.updateAuthority.selector,
            IAccessManager.schedule.selector,
            IAccessManager.execute.selector,
            IAccessManager.cancel.selector,
            IAccessManaged.setAuthority.selector
        ];
        for (uint256 i; i < selectors.length; ++i) {
            GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](1);
            wiring[0] = _call(address(wired), abi.encodePacked(selectors[i], bytes32(0)));
            _expectWiringRevert(
                wiring,
                abi.encodeWithSelector(
                    GovernanceConfig.InvalidWiringCall.selector, address(wired), selectors[i]
                )
            );
        }
    }

    function test_RejectsWiringOnAnUnconfiguredTarget() public {
        WiringTargetMock stranger = new WiringTargetMock(address(manager));
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](1);
        wiring[0] =
            _call(address(stranger), abi.encodeCall(WiringTargetMock.bind, (1, address(peerA))));
        _expectWiringRevert(
            wiring,
            abi.encodeWithSelector(
                GovernanceConfig.InvalidWiringCall.selector,
                address(stranger),
                WiringTargetMock.bind.selector
            )
        );
    }

    function test_RejectsWiringWithoutASelector() public {
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](1);
        wiring[0] = _call(address(wired), hex"0102");
        _expectWiringRevert(
            wiring,
            abi.encodeWithSelector(
                GovernanceConfig.InvalidWiringCall.selector, address(wired), bytes4(0)
            )
        );
    }

    function test_RejectsMoreThanTheWiringBound() public {
        uint256 count = GovernanceConfig.MAX_WIRING_CALLS + 1;
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](count);
        for (uint256 i; i < count; ++i) {
            wiring[i] =
                _call(address(wired), abi.encodeCall(WiringTargetMock.bind, (i, address(peerA))));
        }
        _expectWiringRevert(
            wiring, abi.encodeWithSelector(GovernanceConfig.TooManyWiringCalls.selector, count)
        );
    }

    function test_OnlyTheDeployerCanWire() public {
        GovernanceConfig.Config memory cfg = _wiredConfig();
        GovernanceConfig.Call[] memory wiring = _binds();
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfigurator.NotDeployer.selector, attacker)
        );
        vm.prank(attacker);
        configurator.configure(cfg, MANIFEST, wiring);
    }

    function test_StockManagerTargetCannotBeWired() public {
        // Wiring calls can only reach targets the configuration validated as governed by the
        // configurator's own manager.
        AccessManager stock = new AccessManager(address(this));
        GovernedTargetMock foreign = new GovernedTargetMock(address(stock), recipient0, verifier0);
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](1);
        wiring[0] = _call(address(foreign), abi.encodeCall(GovernedTargetMock.keep, ()));
        _expectWiringRevert(
            wiring,
            abi.encodeWithSelector(
                GovernanceConfig.InvalidWiringCall.selector,
                address(foreign),
                GovernedTargetMock.keep.selector
            )
        );
    }
}
