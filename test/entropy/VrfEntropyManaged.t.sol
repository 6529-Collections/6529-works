// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { BoundedParameter } from "src/governance/BoundedParameter.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { PackageItem, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { GovernanceFixture } from "test/helpers/GovernanceFixture.sol";
import { MockPackageRegistry, MockVrfCoordinator } from "test/mocks/EntropyMocks.sol";
import { EntropyItems } from "./EntropyBase.sol";

/// @notice The module under the real `WorksAccessManager`, configured the way a deploy script
///         must (`GovernanceConfigurator`): the delay classes of its two governed selectors, the
///         guardians' veto, no role on `requestSeed`, and no payable function.
contract VrfEntropyManagedTest is GovernanceFixture, EntropyItems {
    MockVrfCoordinator internal coordinator;
    MockPackageRegistry internal registry;
    VrfEntropyModule internal module;

    function _vrfConfig() internal pure returns (VrfEntropyModule.VrfConfig memory) {
        return VrfEntropyModule.VrfConfig({
            subscriptionId: 1,
            keyHash: keccak256("lane"),
            callbackGasLimit: 200_000,
            confirmations: 3,
            nativePayment: false
        });
    }

    function setUp() public {
        _deployUnconfigured();
        coordinator = new MockVrfCoordinator();
        registry = new MockPackageRegistry();
        module = new VrfEntropyModule(
            address(manager),
            address(coordinator),
            address(coordinator).codehash,
            _vrfConfig(),
            3 days,
            IPackageRegistry(address(registry)),
            address(registry).codehash
        );

        // The selector-to-class mapping the deploy configuration must carry.
        GovernanceConfig.FunctionRole[] memory functions = new GovernanceConfig.FunctionRole[](3);
        functions[0] =
            GovernanceConfig.FunctionRole(module.setConfig.selector, Roles.PARAMETER_SETTER);
        functions[1] =
            GovernanceConfig.FunctionRole(module.setCoordinator.selector, Roles.SUCCESSOR_SETTER);
        functions[2] = GovernanceConfig.FunctionRole(
            module.lowerCallbackGasLimit.selector, Roles.SUCCESSOR_SETTER
        );
        GovernanceConfig.Config memory cfg;
        cfg.grants = _grants();
        cfg.targets = new GovernanceConfig.Target[](1);
        cfg.targets[0] = GovernanceConfig.Target(address(module), functions);
        configurator.configure(cfg, MANIFEST, _noWiring());
        _settle();
    }

    function _setConfigData(uint16 confirmations) internal view returns (bytes memory) {
        VrfEntropyModule.VrfConfig memory next = _vrfConfig();
        next.confirmations = confirmations;
        return abi.encodeCall(module.setConfig, (_vrfConfig(), next));
    }

    function test_SetConfigIsInTheStandardClass() public {
        bytes memory data = _setConfigData(5);
        bytes32 id = _schedule(adminSafe, address(module), data);
        assertEq(manager.getSchedule(id), block.timestamp + 48 hours);

        vm.warp(manager.getSchedule(id) - 1);
        vm.prank(adminSafe);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        manager.execute(address(module), data);

        vm.warp(manager.getSchedule(id));
        vm.prank(adminSafe);
        manager.execute(address(module), data);
        assertEq(module.config().confirmations, 5);
    }

    function test_SetCoordinatorIsInTheSuccessorClass() public {
        MockVrfCoordinator next = new MockVrfCoordinator();
        bytes memory data = abi.encodeCall(
            module.setCoordinator, (address(coordinator), address(next), address(next).codehash)
        );
        bytes32 id = _schedule(adminSafe, address(module), data);
        assertEq(manager.getSchedule(id), block.timestamp + 30 days);

        vm.warp(manager.getSchedule(id));
        vm.prank(adminSafe);
        manager.execute(address(module), data);
        assertEq(module.coordinator(), address(next));
    }

    function test_AGuardianCancelsAPendingCoordinatorSwap() public {
        MockVrfCoordinator next = new MockVrfCoordinator();
        bytes memory data = abi.encodeCall(
            module.setCoordinator, (address(coordinator), address(next), address(next).codehash)
        );
        bytes32 id = _schedule(adminSafe, address(module), data);

        vm.prank(guardianA);
        manager.cancel(adminSafe, address(module), data);

        vm.warp(manager.getSchedule(id));
        vm.prank(adminSafe);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                adminSafe,
                address(module),
                module.setCoordinator.selector
            )
        );
        manager.execute(address(module), data);
        assertEq(module.coordinator(), address(coordinator));
    }

    /// @dev Executes `data` on the module through the manager after its delay.
    function _governed(bytes memory data) internal {
        bytes32 id = _schedule(adminSafe, address(module), data);
        vm.warp(manager.getSchedule(id));
        vm.prank(adminSafe);
        manager.execute(address(module), data);
    }

    function _lowerData(uint32 expected, uint32 next) internal view returns (bytes memory) {
        return abi.encodeCall(module.lowerCallbackGasLimit, (expected, next));
    }

    /// @dev DEPS-5: the raise-only limit could not come back down, so a coordinator maximum
    ///      Chainlink lowered below it ended VRF for the deployment (6529 Stream pins the module).
    ///      A lowering in the 30-day class restores requests; `setConfig` still cannot lower.
    function test_ALoweredCoordinatorMaximumIsFollowedInTheSuccessorClass() public {
        VrfEntropyModule.VrfConfig memory raised = _vrfConfig();
        raised.callbackGasLimit = 400_000;
        _governed(abi.encodeCall(module.setConfig, (_vrfConfig(), raised)));
        coordinator.setMaxGasLimit(300_000);

        PackageItem memory item = _makeItem(0, SeedPolicy.VRF);
        bytes32 packageRoot = WorksHashing.leaf(_hash(item));
        registry.setStatus(packageRoot, IPackageRegistry.PackageStatus.APPROVED);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(MockVrfCoordinator.GasLimitTooBig.selector, 400_000, 300_000)
        );
        module.requestSeed(item, packageRoot, new bytes32[](0));

        VrfEntropyModule.VrfConfig memory lower = _vrfConfig();
        lower.callbackGasLimit = 300_000;
        bytes memory viaSetConfig = abi.encodeCall(module.setConfig, (raised, lower));
        bytes32 id = _schedule(adminSafe, address(module), viaSetConfig);
        vm.warp(manager.getSchedule(id));
        vm.prank(adminSafe);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedParameter.ParameterNotRaised.selector, 400_000, 300_000)
        );
        manager.execute(address(module), viaSetConfig);

        bytes memory data = _lowerData(400_000, 300_000);
        id = _schedule(adminSafe, address(module), data);
        assertEq(manager.getSchedule(id), block.timestamp + 30 days, "the successor class");
        vm.warp(manager.getSchedule(id));
        vm.expectEmit(false, false, false, true, address(module));
        emit VrfEntropyModule.ConfigSet(raised, lower);
        vm.prank(adminSafe);
        manager.execute(address(module), data);
        assertEq(module.config().callbackGasLimit, 300_000);

        vm.prank(outsider);
        uint256 requestId = module.requestSeed(item, packageRoot, new bytes32[](0));
        coordinator.fulfill(requestId, 5);
        assertEq(module.seedOf(_hash(item)), bytes32(uint256(5)));
    }

    function test_ALoweringStaysAboveTheFloorAndBelowTheCurrentLimit() public {
        uint32 floor = module.MIN_CALLBACK_GAS();
        bytes[3] memory refused = [
            _lowerData(200_000, floor - 1),
            _lowerData(200_000, 200_000),
            _lowerData(200_000, 300_000)
        ];
        for (uint256 i; i < refused.length; ++i) {
            bytes32 id = _schedule(adminSafe, address(module), refused[i]);
            vm.warp(manager.getSchedule(id));
            vm.prank(adminSafe);
            vm.expectRevert(IEntropyModule.InvalidConfig.selector);
            manager.execute(address(module), refused[i]);
        }
        bytes memory stale = _lowerData(250_000, floor);
        bytes32 staleId = _schedule(adminSafe, address(module), stale);
        vm.warp(manager.getSchedule(staleId));
        vm.prank(adminSafe);
        vm.expectRevert(IEntropyModule.ExpectedValueMismatch.selector);
        manager.execute(address(module), stale);

        _governed(_lowerData(200_000, floor));
        assertEq(module.config().callbackGasLimit, floor);
    }

    function test_OnlyTheSettersCanCallTheGovernedFunctions() public {
        VrfEntropyModule.VrfConfig memory current = _vrfConfig();
        address[3] memory callers = [outsider, keeper, guardianA];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManaged.AccessManagedUnauthorized.selector, callers[i]
                )
            );
            vm.prank(callers[i]);
            module.setConfig(current, current);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManaged.AccessManagedUnauthorized.selector, callers[i]
                )
            );
            vm.prank(callers[i]);
            module.setCoordinator(address(coordinator), address(coordinator), bytes32(0));
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManaged.AccessManagedUnauthorized.selector, callers[i]
                )
            );
            vm.prank(callers[i]);
            module.lowerCallbackGasLimit(200_000, 100_000);
        }
    }

    function test_AnyoneMayRequestASeedUnderTheRealManager() public {
        PackageItem memory item = _makeItem(0, SeedPolicy.VRF);
        bytes32 packageRoot = WorksHashing.leaf(_hash(item));
        registry.setStatus(packageRoot, IPackageRegistry.PackageStatus.APPROVED);
        vm.prank(outsider);
        uint256 id = module.requestSeed(item, packageRoot, new bytes32[](0));
        coordinator.fulfill(id, 77);
        assertEq(module.seedOf(_hash(item)), bytes32(uint256(77)));
    }

    function test_NothingIsPayable() public {
        PackageItem memory item = _makeItem(0, SeedPolicy.VRF);
        assertFalse(_acceptsValue(address(module), _setConfigData(5)));
        assertFalse(
            _acceptsValue(
                address(module),
                abi.encodeCall(module.setCoordinator, (address(0), address(0), bytes32(0)))
            )
        );
        assertFalse(
            _acceptsValue(
                address(module),
                abi.encodeCall(module.requestSeed, (item, bytes32(0), new bytes32[](0)))
            )
        );
        assertFalse(_acceptsValue(address(module), _lowerData(200_000, 100_000)));
        assertFalse(
            _acceptsValue(
                address(module), abi.encodeCall(module.rawFulfillRandomWords, (1, new uint256[](1)))
            )
        );
    }
}
