// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Roles } from "src/governance/Roles.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { GovernanceFixture } from "../helpers/GovernanceFixture.sol";
import { GovernedTargetMock, UnmanagedMock } from "../mocks/GovernanceMocks.sol";

/// @notice The one-shot configurator, the configuration validator and the CI readback.
contract GovernanceConfiguratorTest is GovernanceFixture {
    function setUp() public {
        configurator = new GovernanceConfigurator();
        manager = new WorksAccessManager(address(configurator));
        target = new GovernedTargetMock(address(manager), recipient0, verifier0);
    }

    function _expectConfigureRevert(GovernanceConfig.Config memory cfg, bytes memory err) internal {
        vm.expectRevert(err);
        configurator.configure(manager, cfg, MANIFEST);
    }

    function _withGrant(uint64 role, address account)
        internal
        view
        returns (GovernanceConfig.Config memory)
    {
        return _append(_config(), role, account);
    }

    function _append(GovernanceConfig.Config memory cfg, uint64 role, address account)
        internal
        pure
        returns (GovernanceConfig.Config memory)
    {
        GovernanceConfig.Grant[] memory grants = new GovernanceConfig.Grant[](cfg.grants.length + 1);
        for (uint256 i; i < cfg.grants.length; ++i) {
            grants[i] = cfg.grants[i];
        }
        grants[cfg.grants.length] = GovernanceConfig.Grant(role, account);
        cfg.grants = grants;
        return cfg;
    }

    function _withoutGrant(uint256 index)
        internal
        view
        returns (GovernanceConfig.Config memory cfg)
    {
        cfg = _config();
        GovernanceConfig.Grant[] memory grants = new GovernanceConfig.Grant[](cfg.grants.length - 1);
        for (uint256 i; i < grants.length; ++i) {
            grants[i] = cfg.grants[i < index ? i : i + 1];
        }
        cfg.grants = grants;
    }

    // ---------------------------------------------------------------- happy path

    function test_ConfigureInstallsTheWholeEpochInOneTransaction() public {
        GovernanceConfig.Config memory cfg = _config();
        vm.expectEmit(address(manager));
        emit IAccessManager.RoleLabel(Roles.GUARDIAN, "GUARDIAN");
        vm.expectEmit(address(configurator));
        emit GovernanceConfigurator.GovernanceConfigured(
            address(manager), keccak256(abi.encode(cfg)), MANIFEST
        );
        configurator.configure(manager, cfg, MANIFEST);

        (bool stillAdmin,) = manager.hasRole(Roles.ADMIN, address(configurator));
        assertFalse(stillAdmin, "configurator renounced");
        (bool isAdmin, uint32 delay) = manager.hasRole(Roles.ADMIN, adminSafe);
        assertTrue(isAdmin);
        assertEq(delay, 30 days);
        (bool isMeta, uint32 metaDelay) = manager.hasRole(Roles.META, adminSafe);
        assertTrue(isMeta);
        assertEq(metaDelay, 30 days);

        // Grant and target-admin delays take effect after minSetback; readback then passes.
        _settle();
        configurator.verify(manager, cfg);
    }

    function test_EveryRoleIsLabelledGuardedAndDelayed() public {
        configurator.configure(manager, _config(), MANIFEST);
        _settle();
        for (uint64 role = 1; role < Roles.COUNT; ++role) {
            assertEq(manager.getRoleAdmin(role), Roles.ADMIN);
            assertEq(manager.getRoleGuardian(role), Roles.GUARDIAN);
            assertEq(manager.getRoleGrantDelay(role), Roles.grantDelay(role));
        }
        assertEq(manager.getRoleGrantDelay(Roles.ADMIN), 30 days);
        assertEq(manager.getTargetAdminDelay(address(manager)), 30 days);
        assertEq(manager.getTargetAdminDelay(address(target)), 30 days);
    }

    function test_ReadbackFailsBeforeDelaysSettle() public {
        configurator.configure(manager, _config(), MANIFEST);
        vm.expectRevert(abi.encodeWithSelector(GovernanceConfig.RoleMismatch.selector, Roles.ADMIN));
        configurator.verify(manager, _config());
    }

    function test_InitialGrantsAreActiveImmediately() public {
        configurator.configure(manager, _config(), MANIFEST);
        vm.prank(guardianA);
        target.pause();
        assertTrue(target.paused());
    }

    // ------------------------------------------------------------- access control

    function test_OnlyDeployerCanConfigure() public {
        GovernanceConfig.Config memory cfg = _config();
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfigurator.NotDeployer.selector, attacker)
        );
        vm.prank(attacker);
        configurator.configure(manager, cfg, MANIFEST);
    }

    function test_ConfigureIsOneShot() public {
        configurator.configure(manager, _config(), MANIFEST);
        _expectConfigureRevert(
            _config(),
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector,
                address(configurator),
                Roles.ADMIN
            )
        );
    }

    function test_VerifyRejectsAManagerTheConfiguratorStillAdministers() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceConfigurator.ConfiguratorStillAdmin.selector, address(manager)
            )
        );
        configurator.verify(manager, _config());
    }

    // ------------------------------------------------------------- grant validation

    function test_RejectsFewerThanTwoGuardians() public {
        _expectConfigureRevert(
            _withoutGrant(2), abi.encodeWithSelector(GovernanceConfig.TooFewGuardians.selector, 1)
        );
    }

    function test_RejectsMissingAdminPauserOrUnpauser() public {
        _expectConfigureRevert(
            _withoutGrant(0),
            abi.encodeWithSelector(GovernanceConfig.MissingHolder.selector, Roles.ADMIN)
        );
        GovernanceConfig.Config memory cfg = _withoutGrant(4);
        cfg.grants[3] = GovernanceConfig.Grant(Roles.KEEPER, guardianA); // drop both pausers
        _expectConfigureRevert(
            cfg, abi.encodeWithSelector(GovernanceConfig.MissingHolder.selector, Roles.PAUSER)
        );
        _expectConfigureRevert(
            _withoutGrant(5),
            abi.encodeWithSelector(GovernanceConfig.MissingHolder.selector, Roles.UNPAUSER)
        );
    }

    function test_RejectsInvalidGrants() public {
        _expectConfigureRevert(
            _withGrant(Roles.KEEPER, address(0)),
            abi.encodeWithSelector(GovernanceConfig.InvalidGrant.selector, Roles.KEEPER, address(0))
        );
        _expectConfigureRevert(
            _withGrant(Roles.META, outsider),
            abi.encodeWithSelector(GovernanceConfig.InvalidGrant.selector, Roles.META, outsider)
        );
        _expectConfigureRevert(
            _withGrant(Roles.KEEPER, address(configurator)),
            abi.encodeWithSelector(
                GovernanceConfig.InvalidGrant.selector, Roles.KEEPER, address(configurator)
            )
        );
        _expectConfigureRevert(
            _withGrant(Roles.PUBLIC, outsider),
            abi.encodeWithSelector(Roles.UnknownRole.selector, Roles.PUBLIC)
        );
        _expectConfigureRevert(
            _withGrant(Roles.KEEPER, keeper),
            abi.encodeWithSelector(GovernanceConfig.DuplicateGrant.selector, Roles.KEEPER, keeper)
        );
    }

    function test_RejectsGuardianHoldingAProposerRole() public {
        uint64[5] memory proposers = [
            Roles.ADMIN,
            Roles.UNPAUSER,
            Roles.PARAMETER_SETTER,
            Roles.FUNDS_SETTER,
            Roles.SUCCESSOR_SETTER
        ];
        for (uint256 i; i < proposers.length; ++i) {
            _expectConfigureRevert(
                _withGrant(proposers[i], guardianB),
                abi.encodeWithSelector(
                    GovernanceConfig.GuardianIsProposer.selector, guardianB, proposers[i]
                )
            );
        }
        // The reverse order: a proposer later granted GUARDIAN.
        _expectConfigureRevert(
            _withGrant(Roles.GUARDIAN, adminSafe),
            abi.encodeWithSelector(
                GovernanceConfig.GuardianIsProposer.selector, adminSafe, Roles.ADMIN
            )
        );
    }

    function test_RejectsSharedPauseAndUnpauseHolder() public {
        _expectConfigureRevert(
            _append(_withGrant(Roles.PAUSER, keeper), Roles.UNPAUSER, keeper),
            abi.encodeWithSelector(GovernanceConfig.PauserIsUnpauser.selector, keeper)
        );
        _expectConfigureRevert(
            _withGrant(Roles.PAUSER, adminSafe),
            abi.encodeWithSelector(GovernanceConfig.PauserIsUnpauser.selector, adminSafe)
        );
    }

    // ------------------------------------------------------------ target validation

    function test_RejectsInvalidTargets() public {
        GovernanceConfig.Config memory cfg = _config();
        address[4] memory bad = [
            address(manager), // the manager configures itself
            outsider, // no code
            address(new UnmanagedMock()), // no authority()
            address(new GovernedTargetMock(address(0xdead), recipient0, verifier0)) // other authority
        ];
        for (uint256 i; i < bad.length; ++i) {
            cfg.targets[0].target = bad[i];
            _expectConfigureRevert(
                cfg, abi.encodeWithSelector(GovernanceConfig.InvalidTarget.selector, bad[i])
            );
        }
    }

    function test_RejectsDuplicateTarget() public {
        GovernanceConfig.Config memory cfg = _config();
        GovernanceConfig.Target[] memory targets = new GovernanceConfig.Target[](2);
        targets[0] = cfg.targets[0];
        targets[1] = cfg.targets[0];
        cfg.targets = targets;
        _expectConfigureRevert(
            cfg, abi.encodeWithSelector(GovernanceConfig.InvalidTarget.selector, address(target))
        );
    }

    function test_RejectsOneSelectorInTwoClasses() public {
        GovernanceConfig.Config memory cfg = _config();
        cfg.targets[0].functions[7] =
            GovernanceConfig.FunctionRole(GovernedTargetMock.setFee.selector, Roles.FUNDS_SETTER);
        _expectConfigureRevert(
            cfg,
            abi.encodeWithSelector(
                GovernanceConfig.DuplicateSelector.selector,
                address(target),
                GovernedTargetMock.setFee.selector
            )
        );
    }

    function test_RejectsFunctionRolesThatMustNotCall() public {
        uint64[3] memory forbidden = [Roles.ADMIN, Roles.META, Roles.CURATION_SIGNER];
        for (uint256 i; i < forbidden.length; ++i) {
            GovernanceConfig.Config memory cfg = _config();
            cfg.targets[0].functions[7].role = forbidden[i];
            _expectConfigureRevert(
                cfg,
                abi.encodeWithSelector(
                    GovernanceConfig.InvalidFunctionRole.selector,
                    address(target),
                    GovernedTargetMock.keep.selector,
                    forbidden[i]
                )
            );
        }
        GovernanceConfig.Config memory pub = _config();
        pub.targets[0].functions[7].role = Roles.PUBLIC;
        _expectConfigureRevert(
            pub, abi.encodeWithSelector(Roles.UnknownRole.selector, Roles.PUBLIC)
        );
    }

    // ------------------------------------------------------------- readback drift

    function _configured() internal {
        configurator.configure(manager, _config(), MANIFEST);
        _settle();
    }

    function test_ReadbackDetectsRemappedSelector() public {
        _configured();
        _adminExecute(
            abi.encodeCall(
                IAccessManager.setTargetFunctionRole,
                (address(target), _one(GovernedTargetMock.setFee.selector), Roles.FUNDS_SETTER)
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceConfig.FunctionRoleMismatch.selector,
                address(target),
                GovernedTargetMock.setFee.selector,
                Roles.FUNDS_SETTER
            )
        );
        configurator.verify(manager, _config());
    }

    function test_ReadbackDetectsPendingDelayReduction() public {
        _configured();
        _adminExecute(
            abi.encodeCall(IAccessManager.grantRole, (Roles.PARAMETER_SETTER, adminSafe, 0))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceConfig.HolderMismatch.selector, Roles.PARAMETER_SETTER, adminSafe
            )
        );
        configurator.verify(manager, _config());
    }

    function test_ReadbackDetectsGuardianPendingForAProposerRole() public {
        _configured();
        _adminExecute(
            abi.encodeCall(IAccessManager.grantRole, (Roles.PARAMETER_SETTER, guardianA, 48 hours))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceConfig.GuardianIsProposer.selector, guardianA, Roles.PARAMETER_SETTER
            )
        );
        configurator.verify(manager, _config());
    }

    function test_ReadbackDetectsPauserGrantedUnpause() public {
        GovernanceConfig.Config memory cfg = _withGrant(Roles.PAUSER, keeper);
        configurator.configure(manager, cfg, MANIFEST);
        _settle();
        configurator.verify(manager, cfg);
        _adminExecute(abi.encodeCall(IAccessManager.grantRole, (Roles.UNPAUSER, keeper, 48 hours)));
        vm.expectRevert(abi.encodeWithSelector(GovernanceConfig.PauserIsUnpauser.selector, keeper));
        configurator.verify(manager, cfg);
    }

    function test_ReadbackDetectsClosedTargetAndStrippedGuardian() public {
        _configured();
        _adminExecute(abi.encodeCall(IAccessManager.setTargetClosed, (address(target), true)));
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfig.TargetMismatch.selector, address(target))
        );
        configurator.verify(manager, _config());

        _adminExecute(abi.encodeCall(IAccessManager.setRoleGuardian, (Roles.META, Roles.ADMIN)));
        vm.expectRevert(abi.encodeWithSelector(GovernanceConfig.RoleMismatch.selector, Roles.META));
        configurator.verify(manager, _config());
    }

    function test_ReadbackDetectsMissingHolder() public {
        _configured();
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfig.HolderMismatch.selector, Roles.MINTER, outsider)
        );
        configurator.verify(manager, _withGrant(Roles.MINTER, outsider));
    }
}
