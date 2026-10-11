// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
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
        _deployUnconfigured();
    }

    function _expectConfigureRevert(GovernanceConfig.Config memory cfg, bytes memory err) internal {
        vm.expectRevert(err);
        configurator.configure(cfg, MANIFEST);
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

    /// @dev Drops every grant of `role`, or only `account`'s when it is nonzero.
    function _without(GovernanceConfig.Config memory cfg, uint64 role, address account)
        internal
        pure
        returns (GovernanceConfig.Config memory)
    {
        uint256 kept;
        GovernanceConfig.Grant[] memory grants = new GovernanceConfig.Grant[](cfg.grants.length);
        for (uint256 i; i < cfg.grants.length; ++i) {
            GovernanceConfig.Grant memory g = cfg.grants[i];
            if (g.role == role && (account == address(0) || g.account == account)) continue;
            grants[kept++] = g;
        }
        assembly ("memory-safe") {
            mstore(grants, kept)
        }
        cfg.grants = grants;
        return cfg;
    }

    function _configured() internal {
        configurator.configure(_config(), MANIFEST);
        _settle();
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
        configurator.configure(cfg, MANIFEST);

        (bool stillAdmin,) = manager.hasRole(Roles.ADMIN, address(configurator));
        assertFalse(stillAdmin, "configurator renounced");
        address[2] memory admins = [adminSafe, coldAdmin];
        for (uint256 i; i < admins.length; ++i) {
            (bool isAdmin, uint32 delay) = manager.hasRole(Roles.ADMIN, admins[i]);
            assertTrue(isAdmin);
            assertEq(delay, 30 days);
        }

        // Grant and target-admin delays take effect after minSetback; readback then passes.
        _settle();
        configurator.verify(cfg);
    }

    function test_EveryRoleIsLabelledGuardedAndDelayed() public {
        _configured();
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
        configurator.configure(_config(), MANIFEST);
        vm.expectRevert(abi.encodeWithSelector(GovernanceConfig.RoleMismatch.selector, Roles.ADMIN));
        configurator.verify(_config());
    }

    function test_InitialGrantsAreActiveImmediately() public {
        configurator.configure(_config(), MANIFEST);
        vm.prank(guardianA);
        target.pause();
        assertTrue(target.paused());
    }

    function test_SupportsHotAndColdAdmins() public {
        _configured();
        (bool hot,) = manager.hasRole(Roles.ADMIN, adminSafe);
        (bool cold,) = manager.hasRole(Roles.ADMIN, coldAdmin);
        assertTrue(hot && cold);
        (uint48 coldSetter,,,) = manager.getAccess(Roles.PARAMETER_SETTER, coldAdmin);
        assertEq(coldSetter, 0, "the cold admin holds ADMIN only");
    }

    // ------------------------------------------------- manager provenance (review M-1)

    function test_ConfiguratorDeploysAndOwnsAWorksAccessManager() public {
        assertEq(address(configurator.worksManager()), address(manager));
        assertEq(configurator.deployer(), address(this));
        assertEq(address(manager).codehash, address(new WorksAccessManager(outsider)).codehash);
        assertNotEq(address(manager).codehash, address(new AccessManager(outsider)).codehash);
        (bool configuratorAdmin, uint32 delay) = manager.hasRole(Roles.ADMIN, address(configurator));
        assertTrue(configuratorAdmin);
        assertEq(delay, 0);
        (uint48 deployerAdmin,,,) = manager.getAccess(Roles.ADMIN, address(this));
        assertEq(deployerAdmin, 0, "the deployer never administers the manager");
    }

    function test_TargetGovernedByAStockManagerIsRejected() public {
        AccessManager stock = new AccessManager(address(this));
        GovernanceConfig.Config memory cfg = _config();
        cfg.targets[0].target =
            address(new GovernedTargetMock(address(stock), recipient0, verifier0));
        _expectConfigureRevert(
            cfg,
            abi.encodeWithSelector(GovernanceConfig.InvalidTarget.selector, cfg.targets[0].target)
        );
    }

    function test_PreSeededManagerIsRejected() public {
        // A manager with another zero-delay admin cannot be configured or verified: the
        // configurator only ever touches the manager it deployed, and refuses targets wired
        // to any other manager.
        vm.prank(attacker);
        WorksAccessManager seeded = new WorksAccessManager(attacker);
        vm.prank(attacker);
        seeded.grantRole(Roles.ADMIN, address(configurator), 0);
        GovernanceConfig.Config memory cfg = _config();
        cfg.targets[0].target =
            address(new GovernedTargetMock(address(seeded), recipient0, verifier0));
        _expectConfigureRevert(
            cfg,
            abi.encodeWithSelector(GovernanceConfig.InvalidTarget.selector, cfg.targets[0].target)
        );
        assertNotEq(address(configurator.worksManager()), address(seeded));
    }

    // ------------------------------------------------------------- access control

    function test_OnlyDeployerCanConfigure() public {
        GovernanceConfig.Config memory cfg = _config();
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfigurator.NotDeployer.selector, attacker)
        );
        vm.prank(attacker);
        configurator.configure(cfg, MANIFEST);
    }

    function test_ConfigureIsOneShot() public {
        configurator.configure(_config(), MANIFEST);
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
        vm.expectRevert(GovernanceConfigurator.ConfiguratorStillAdmin.selector);
        configurator.verify(_config());
    }

    // ------------------------------------------------------------- grant validation

    function test_RejectsFewerThanTwoGuardians() public {
        GovernanceConfig.Config memory cfg = _without(_config(), Roles.GUARDIAN, guardianB);
        cfg = _without(cfg, Roles.GUARDIAN, guardianC);
        _expectConfigureRevert(
            cfg, abi.encodeWithSelector(GovernanceConfig.TooFewGuardians.selector, 1)
        );
    }

    function test_AcceptsTheTwoGuardianFloor() public {
        GovernanceConfig.Config memory cfg = _without(_config(), Roles.GUARDIAN, guardianC);
        configurator.configure(cfg, MANIFEST);
        _settle();
        configurator.verify(cfg);
    }

    function test_RejectsMissingAdminPauserOrUnpauser() public {
        _expectConfigureRevert(
            _without(_config(), Roles.ADMIN, address(0)),
            abi.encodeWithSelector(GovernanceConfig.MissingHolder.selector, Roles.ADMIN)
        );
        _expectConfigureRevert(
            _without(_config(), Roles.PAUSER, address(0)),
            abi.encodeWithSelector(GovernanceConfig.MissingHolder.selector, Roles.PAUSER)
        );
        _expectConfigureRevert(
            _without(_config(), Roles.UNPAUSER, address(0)),
            abi.encodeWithSelector(GovernanceConfig.MissingHolder.selector, Roles.UNPAUSER)
        );
    }

    function test_RejectsInvalidGrants() public {
        _expectConfigureRevert(
            _withGrant(Roles.KEEPER, address(0)),
            abi.encodeWithSelector(GovernanceConfig.InvalidGrant.selector, Roles.KEEPER, address(0))
        );
        _expectConfigureRevert(
            _withGrant(Roles.KEEPER, address(configurator)),
            abi.encodeWithSelector(
                GovernanceConfig.InvalidGrant.selector, Roles.KEEPER, address(configurator)
            )
        );
        _expectConfigureRevert(
            _withGrant(Roles.COUNT, outsider),
            abi.encodeWithSelector(Roles.UnknownRole.selector, Roles.COUNT)
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

    function test_RejectsGuardianHoldingAnyOtherRole() public {
        // Veto stays separate from action: GUARDIAN pairs with PAUSER and nothing else.
        for (uint64 role; role < Roles.COUNT; ++role) {
            if (role == Roles.GUARDIAN || role == Roles.PAUSER) continue;
            _expectConfigureRevert(
                _withGrant(role, guardianB),
                abi.encodeWithSelector(GovernanceConfig.GuardianHoldsRole.selector, guardianB, role)
            );
        }
        // The reverse order: an operational holder later granted GUARDIAN.
        _expectConfigureRevert(
            _withGrant(Roles.GUARDIAN, keeper),
            abi.encodeWithSelector(
                GovernanceConfig.GuardianHoldsRole.selector, keeper, Roles.KEEPER
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

    function test_CuratorAndPlatformMapToZeroDelayWriters() public {
        // The statement log refuses delayed writers, so both roles are immediate.
        _configured();
        (bool curatorImmediate,) =
            manager.canCall(curator, address(target), GovernedTargetMock.curate.selector);
        assertTrue(curatorImmediate);
        assertEq(Roles.executionDelay(Roles.PLATFORM), 0);
        (bool active, uint32 delay) = manager.hasRole(Roles.PLATFORM, platform);
        assertTrue(active);
        assertEq(delay, 0);
    }

    function test_RejectsFunctionRolesThatMustNotCall() public {
        uint64[2] memory forbidden = [Roles.ADMIN, Roles.CURATION_SIGNER];
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
        configurator.verify(_config());
    }

    function test_ReadbackDetectsPendingExecutionDelayReduction() public {
        _configured();
        _adminExecute(
            abi.encodeCall(IAccessManager.grantRole, (Roles.PARAMETER_SETTER, adminSafe, 0))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceConfig.HolderMismatch.selector, Roles.PARAMETER_SETTER, adminSafe
            )
        );
        configurator.verify(_config());
    }

    function test_ReadbackDetectsAdminDelayReduction() public {
        // An admin whose execution delay is being lowered is an unexpected fast admin.
        _configured();
        _adminExecute(abi.encodeCall(IAccessManager.grantRole, (Roles.ADMIN, coldAdmin, 0)));
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfig.HolderMismatch.selector, Roles.ADMIN, coldAdmin)
        );
        configurator.verify(_config());
        vm.warp(block.timestamp + 30 days); // the reduction has landed: still rejected
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfig.HolderMismatch.selector, Roles.ADMIN, coldAdmin)
        );
        configurator.verify(_config());
    }

    function test_ReadbackDetectsGuardianGainingAnyOtherRole() public {
        _configured();
        _adminExecute(abi.encodeCall(IAccessManager.grantRole, (Roles.MINTER, guardianA, 0)));
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceConfig.GuardianHoldsRole.selector, guardianA, Roles.MINTER
            )
        );
        configurator.verify(_config());
    }

    function test_ReadbackDetectsPauserGrantedUnpause() public {
        GovernanceConfig.Config memory cfg = _withGrant(Roles.PAUSER, keeper);
        configurator.configure(cfg, MANIFEST);
        _settle();
        configurator.verify(cfg);
        _adminExecute(abi.encodeCall(IAccessManager.grantRole, (Roles.UNPAUSER, keeper, 48 hours)));
        vm.expectRevert(abi.encodeWithSelector(GovernanceConfig.PauserIsUnpauser.selector, keeper));
        configurator.verify(cfg);
    }

    function test_ReadbackDetectsClosedTargetAndChangedGuardian() public {
        _configured();
        _adminExecute(abi.encodeCall(IAccessManager.setTargetClosed, (address(target), true)));
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfig.TargetMismatch.selector, address(target))
        );
        configurator.verify(_config());

        _adminExecute(abi.encodeCall(IAccessManager.setRoleGuardian, (Roles.PAUSER, Roles.ADMIN)));
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfig.RoleMismatch.selector, Roles.PAUSER)
        );
        configurator.verify(_config());
    }

    function test_ReadbackDetectsMissingHolder() public {
        _configured();
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfig.HolderMismatch.selector, Roles.MINTER, outsider)
        );
        configurator.verify(_withGrant(Roles.MINTER, outsider));
    }

    /// @dev Documented limitation (review L-3): OpenZeppelin exposes no getter for a pending
    ///      grant-delay or target-admin-delay change, so readback passes until the reduction
    ///      lands. Deployment CI scans `RoleGrantDelayChanged` and `TargetAdminDelayUpdated`
    ///      events for future effect times instead.
    function test_Limitation_ReadbackCannotSeePendingDelayReductions() public {
        _configured();
        bytes memory a = abi.encodeCall(IAccessManager.setGrantDelay, (Roles.ADMIN, 0));
        bytes memory b = abi.encodeCall(IAccessManager.setTargetAdminDelay, (address(target), 0));
        _schedule(adminSafe, address(manager), a);
        _schedule(adminSafe, address(manager), b);
        vm.warp(block.timestamp + 30 days);
        vm.recordLogs();
        vm.startPrank(adminSafe);
        manager.execute(address(manager), a);
        manager.execute(address(manager), b);
        vm.stopPrank();
        // The events carry the future effect time that CI must flag.
        assertGt(vm.getRecordedLogs().length, 0);
        configurator.verify(_config());
        vm.warp(block.timestamp + 30 days - 1);
        configurator.verify(_config());
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(GovernanceConfig.RoleMismatch.selector, Roles.ADMIN));
        configurator.verify(_config());
    }
}
