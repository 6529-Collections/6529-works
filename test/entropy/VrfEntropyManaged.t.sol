// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
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
        GovernanceConfig.FunctionRole[] memory functions = new GovernanceConfig.FunctionRole[](2);
        functions[0] =
            GovernanceConfig.FunctionRole(module.setConfig.selector, Roles.PARAMETER_SETTER);
        functions[1] =
            GovernanceConfig.FunctionRole(module.setCoordinator.selector, Roles.SUCCESSOR_SETTER);
        GovernanceConfig.Config memory cfg;
        cfg.grants = _grants();
        cfg.targets = new GovernanceConfig.Target[](1);
        cfg.targets[0] = GovernanceConfig.Target(address(module), functions);
        configurator.configure(cfg, MANIFEST);
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
        assertFalse(
            _acceptsValue(
                address(module), abi.encodeCall(module.rawFulfillRandomWords, (1, new uint256[](1)))
            )
        );
    }
}
