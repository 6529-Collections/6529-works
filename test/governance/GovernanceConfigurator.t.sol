// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Roles } from "src/governance/Roles.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { GovernanceFixture } from "../helpers/GovernanceFixture.sol";
import { GovernedTargetMock, UnmanagedMock } from "../mocks/governance/GovernanceMocks.sol";

/// @notice The one-shot configurator, the configuration validator and the CI readback.
contract GovernanceConfiguratorTest is GovernanceFixture {
    function setUp() public {
        _deployUnconfigured();
    }

    function _expectConfigureRevert(GovernanceConfig.Config memory cfg, bytes memory err) internal {
        vm.expectRevert(err);
        configurator.configure(cfg, MANIFEST, _noWiring());
    }

    function _withGrant(uint64 role, address account)
        internal
        view
        returns (GovernanceConfig.Config memory cfg)
    {
        cfg = _config();
        GovernanceConfig.Grant[] memory grants = new GovernanceConfig.Grant[](cfg.grants.length + 1);
        for (uint256 i; i < cfg.grants.length; ++i) {
            grants[i] = cfg.grants[i];
        }
        grants[cfg.grants.length] = GovernanceConfig.Grant(role, account);
        cfg.grants = grants;
    }

    function _configured() internal {
        configurator.configure(_config(), MANIFEST, _noWiring());
        _accept();
    }

    // ---------------------------------------------------------------- happy path

    function test_ConfigureInstallsTheWholeEpochInOneTransaction() public {
        GovernanceConfig.Config memory cfg = _config();
        vm.expectEmit(address(manager));
        emit IAccessManager.RoleLabel(Roles.NETWORK, "NETWORK");
        vm.expectEmit(address(manager));
        emit WorksAccessManager.BrakeSet(address(0), brakeSafe);
        vm.expectEmit(address(manager));
        emit WorksAccessManager.NetworkTransferStarted(address(0), adminSafe);
        vm.expectEmit(address(configurator));
        emit GovernanceConfigurator.GovernanceConfigured(
            address(manager),
            keccak256(abi.encode(cfg)),
            MANIFEST,
            keccak256(abi.encode(_noWiring()))
        );
        configurator.configure(cfg, MANIFEST, _noWiring());

        (bool stillAdmin,) = manager.hasRole(Roles.ADMIN, address(configurator));
        assertFalse(stillAdmin, "configurator renounced");
        assertEq(manager.network(), address(0), "nobody is the network before it accepts");
        assertEq(manager.pendingNetwork(), adminSafe);
        assertEq(manager.brake(), brakeSafe);

        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfig.NetworkMismatch.selector, address(0), brakeSafe)
        );
        configurator.verify(cfg);
        _accept();
        configurator.verify(cfg);
    }

    function test_EveryRoleIsLabelledAndOperationalKeysAnswerToTheNetworkAtOnce() public {
        _configured();
        for (uint64 role = 1; role < Roles.COUNT; ++role) {
            if (!Roles.isKnown(role)) continue;
            assertEq(
                manager.getRoleAdmin(role), Roles.isNetworkRole(role) ? Roles.ADMIN : Roles.NETWORK
            );
            assertEq(manager.getRoleGuardian(role), Roles.ADMIN);
            assertEq(manager.getRoleGrantDelay(role), 0);
        }
        // A grant of an operational key is the network's, with no delay (integrator ruling 14).
        vm.prank(adminSafe);
        manager.grantRole(Roles.PAUSER, outsider, 0);
        (bool member,) = manager.hasRole(Roles.PAUSER, outsider);
        assertTrue(member);
    }

    function test_InitialGrantsAreActiveImmediately() public {
        configurator.configure(_config(), MANIFEST, _noWiring());
        vm.prank(guardianA);
        target.pause();
        assertTrue(target.paused());
    }

    function test_NoBrakeIsAllowed() public {
        GovernanceConfig.Config memory cfg = _config();
        cfg.brake = address(0);
        configurator.configure(cfg, MANIFEST, _noWiring());
        _accept();
        assertEq(manager.brake(), address(0));
        configurator.verify(cfg);
    }

    // ------------------------------------------------- manager provenance

    function test_ConfiguratorDeploysAndOwnsAWorksAccessManager() public {
        assertEq(address(configurator.worksManager()), address(manager));
        assertEq(configurator.deployer(), address(this));
        assertEq(address(manager).codehash, address(new WorksAccessManager(outsider)).codehash);
        assertNotEq(address(manager).codehash, address(new AccessManager(outsider)).codehash);
        (bool installer, uint32 delay) = manager.hasRole(Roles.ADMIN, address(configurator));
        assertTrue(installer);
        assertEq(delay, 0);
        (uint48 deployerAdmin,,,) = manager.getAccess(Roles.ADMIN, address(this));
        assertEq(deployerAdmin, 0, "the deployer never administers the manager");
    }

    function test_DeployerIsTheConstructorArgumentNotTheSender() public {
        // Deployed through a CREATE2 factory, as the deploy script does: the factory is the
        // sender, the operator is the deployer.
        address operator = makeAddr("operator");
        Create2Factory factory = new Create2Factory();
        bytes memory initcode =
            abi.encodePacked(type(GovernanceConfigurator).creationCode, abi.encode(operator));
        bytes32 salt = keccak256("6529-works/genesis/configurator");
        address predicted = vm.computeCreate2Address(salt, keccak256(initcode), address(factory));
        GovernanceConfigurator c = GovernanceConfigurator(factory.deploy(salt, initcode));
        assertEq(address(c), predicted);
        assertEq(c.deployer(), operator);
        assertEq(address(c.worksManager()), vm.computeCreateAddress(address(c), 1));

        target = new GovernedTargetMock(address(c.worksManager()), recipient0, verifier0);
        GovernanceConfig.Config memory cfg = _config();
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfigurator.NotDeployer.selector, address(factory))
        );
        vm.prank(address(factory));
        c.configure(cfg, MANIFEST, _noWiring());
        vm.prank(operator);
        c.configure(cfg, MANIFEST, _noWiring());
        (bool stillAdmin,) = c.worksManager().hasRole(Roles.ADMIN, address(c));
        assertFalse(stillAdmin);
    }

    function test_ZeroDeployerIsRejected() public {
        vm.expectRevert(GovernanceConfigurator.InvalidDeployer.selector);
        new GovernanceConfigurator(address(0));
    }

    function test_AForeignConfiguratorOnlyGovernsItsOwnManager() public {
        _configured();
        vm.prank(attacker);
        GovernanceConfigurator rogue = new GovernanceConfigurator(attacker);
        assertTrue(address(rogue.worksManager()) != address(manager));
        GovernanceConfig.Config memory cfg = _config();
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfig.InvalidTarget.selector, address(target))
        );
        vm.prank(attacker);
        rogue.configure(cfg, MANIFEST, _noWiring());
        configurator.verify(_config());
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

    // ------------------------------------------------------------- access control

    function test_OnlyDeployerCanConfigure() public {
        GovernanceConfig.Config memory cfg = _config();
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfigurator.NotDeployer.selector, attacker)
        );
        vm.prank(attacker);
        configurator.configure(cfg, MANIFEST, _noWiring());
    }

    function test_ConfigureIsOneShot() public {
        configurator.configure(_config(), MANIFEST, _noWiring());
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

    function test_RejectsAMissingNetwork() public {
        GovernanceConfig.Config memory cfg = _config();
        cfg.network = address(0);
        _expectConfigureRevert(
            cfg, abi.encodeWithSelector(GovernanceConfig.MissingNetwork.selector)
        );
    }

    function test_RejectsGrantsOfNetworkRoles() public {
        uint64[5] memory network = [
            Roles.ADMIN,
            Roles.NETWORK,
            Roles.PARAMETER_SETTER,
            Roles.FUNDS_SETTER,
            Roles.SUCCESSOR_SETTER
        ];
        for (uint256 i; i < network.length; ++i) {
            _expectConfigureRevert(
                _withGrant(network[i], outsider),
                abi.encodeWithSelector(GovernanceConfig.InvalidGrant.selector, network[i], outsider)
            );
        }
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
        uint64[3] memory unknown = [uint64(3), Roles.COUNT, Roles.PUBLIC];
        for (uint256 i; i < unknown.length; ++i) {
            _expectConfigureRevert(
                _withGrant(unknown[i], outsider),
                abi.encodeWithSelector(GovernanceConfig.InvalidGrant.selector, unknown[i], outsider)
            );
        }
        _expectConfigureRevert(
            _withGrant(Roles.KEEPER, keeper),
            abi.encodeWithSelector(GovernanceConfig.DuplicateGrant.selector, Roles.KEEPER, keeper)
        );
        // The very first grant is checked like the others.
        _expectConfigureRevert(
            _withGrant(Roles.PAUSER, guardianA),
            abi.encodeWithSelector(
                GovernanceConfig.DuplicateGrant.selector, Roles.PAUSER, guardianA
            )
        );
    }

    function test_OneKeyMayHoldSeveralOperationalRoles() public {
        GovernanceConfig.Config memory cfg = _withGrant(Roles.PLATFORM, guardianA);
        configurator.configure(cfg, MANIFEST, _noWiring());
        _accept();
        configurator.verify(cfg);
    }

    /// @dev The duplicate check compares roles for equality: a key may take a lower role after a
    ///      higher one (the platform key, PLATFORM first, then PAUSER).
    function test_OneKeyMayHoldALowerRoleAfterAHigherOne() public {
        GovernanceConfig.Config memory cfg = _withGrant(Roles.PAUSER, platform);
        configurator.configure(cfg, MANIFEST, _noWiring());
        _accept();
        configurator.verify(cfg);
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
        uint64[2] memory forbidden = [Roles.ADMIN, Roles.CURATION_SIGNER];
        for (uint256 i; i < forbidden.length; ++i) {
            GovernanceConfig.Config memory cfg = _config();
            cfg.targets[0].functions[0].role = forbidden[i];
            _expectConfigureRevert(
                cfg,
                abi.encodeWithSelector(
                    GovernanceConfig.InvalidFunctionRole.selector,
                    address(target),
                    GovernedTargetMock.pause.selector,
                    forbidden[i]
                )
            );
        }
        uint64[2] memory unknown = [uint64(3), Roles.PUBLIC];
        for (uint256 i; i < unknown.length; ++i) {
            GovernanceConfig.Config memory cfg = _config();
            cfg.targets[0].functions[7].role = unknown[i];
            _expectConfigureRevert(
                cfg, abi.encodeWithSelector(Roles.UnknownRole.selector, unknown[i])
            );
        }
    }

    // ------------------------------------------------------------- readback drift

    function test_ReadbackDetectsRemappedSelector() public {
        _configured();
        _adminExecute(
            abi.encodeCall(
                IAccessManager.setTargetFunctionRole,
                (address(target), _one(GovernedTargetMock.pause.selector), Roles.NETWORK)
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceConfig.FunctionRoleMismatch.selector,
                address(target),
                GovernedTargetMock.pause.selector,
                Roles.NETWORK
            )
        );
        configurator.verify(_config());
    }

    function test_ReadbackDetectsAKeyGivenADelay() public {
        _configured();
        bytes memory data =
            abi.encodeCall(IAccessManager.grantRole, (Roles.PAUSER, guardianA, 1 days));
        vm.prank(adminSafe);
        (bool ok,) = address(manager).call(data);
        assertTrue(ok);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceConfig.HolderMismatch.selector, Roles.PAUSER, guardianA
            )
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

    function test_ReadbackDetectsClosedTargetAndChangedRoleSettings() public {
        _configured();
        _adminExecute(abi.encodeCall(IAccessManager.setTargetClosed, (address(target), true)));
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfig.TargetMismatch.selector, address(target))
        );
        configurator.verify(_config());
        _adminExecute(abi.encodeCall(IAccessManager.setTargetClosed, (address(target), false)));

        _adminExecute(abi.encodeCall(IAccessManager.setRoleGuardian, (Roles.PAUSER, Roles.PAUSER)));
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfig.RoleMismatch.selector, Roles.PAUSER)
        );
        configurator.verify(_config());
    }

    /// @dev A selector remapped to a higher role than configured is drift, like one remapped
    ///      to a lower role.
    function test_ReadbackDetectsASelectorRemappedToAHigherRole() public {
        _configured();
        _adminExecute(
            abi.encodeCall(
                IAccessManager.setTargetFunctionRole,
                (address(target), _one(GovernedTargetMock.pause.selector), Roles.PLATFORM)
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceConfig.FunctionRoleMismatch.selector,
                address(target),
                GovernedTargetMock.pause.selector,
                Roles.PLATFORM
            )
        );
        configurator.verify(_config());
    }

    /// @dev An operational role's admin is the network role: an admin moved to `ADMIN` below
    ///      it, or to an operational role above it, is drift.
    function test_ReadbackDetectsARoleAdminMovedEitherWay() public {
        _configured();
        uint64[2] memory moved = [Roles.ADMIN, Roles.PLATFORM];
        for (uint256 i; i < moved.length; ++i) {
            _adminExecute(abi.encodeCall(IAccessManager.setRoleAdmin, (Roles.PAUSER, moved[i])));
            vm.expectRevert(
                abi.encodeWithSelector(GovernanceConfig.RoleMismatch.selector, Roles.PAUSER)
            );
            configurator.verify(_config());
        }
        _adminExecute(abi.encodeCall(IAccessManager.setRoleAdmin, (Roles.PAUSER, Roles.NETWORK)));
        configurator.verify(_config());
    }

    /// @dev A grant delay on a role, once in effect, is drift.
    function test_ReadbackDetectsARoleGivenAGrantDelay() public {
        _configured();
        _adminExecute(abi.encodeCall(IAccessManager.setGrantDelay, (Roles.PAUSER, 1 days)));
        vm.warp(block.timestamp + manager.minSetback());
        assertEq(manager.getRoleGrantDelay(Roles.PAUSER), 1 days);
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfig.RoleMismatch.selector, Roles.PAUSER)
        );
        configurator.verify(_config());
    }

    /// @dev Installing without a brake leaves the brake unset and logs no brake change.
    function test_NoBrakeLogsNoBrakeChange() public {
        GovernanceConfig.Config memory cfg = _config();
        cfg.brake = address(0);
        vm.recordLogs();
        configurator.configure(cfg, MANIFEST, _noWiring());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != WorksAccessManager.BrakeSet.selector, "no BrakeSet");
        }
        assertEq(manager.brake(), address(0));
    }

    function test_ReadbackDetectsAChangedNetworkOrBrake() public {
        _configured();
        _adminExecute(abi.encodeCall(WorksAccessManager.setBrake, (address(0))));
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfig.NetworkMismatch.selector, adminSafe, address(0))
        );
        configurator.verify(_config());
    }
}

/// @dev A minimal CREATE2 factory, like the deterministic deployer Foundry scripts use.
contract Create2Factory {
    function deploy(bytes32 salt, bytes memory initcode) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initcode, 0x20), mload(initcode), salt)
        }
        require(deployed != address(0), "create2 failed");
    }
}
