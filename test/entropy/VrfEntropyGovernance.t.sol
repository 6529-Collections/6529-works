// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { BoundedParameter } from "src/governance/BoundedParameter.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { EntropyBase } from "./EntropyBase.sol";
import { MockVrfCoordinator } from "test/mocks/entropy/EntropyMocks.sol";
import { Dependency } from "src/libraries/Dependency.sol";

/// @notice The governed setters of the VRF entropy module: compare-and-set, raise-only gas limit,
///         coordinator swap, and the delay classes under a real AccessManager.
contract VrfEntropyGovernanceTest is EntropyBase {
    event ConfigSet(VrfEntropyModule.VrfConfig previous, VrfEntropyModule.VrfConfig next);
    event CoordinatorSet(address previous, address next, bytes32 codeHash);

    /// @dev The setter replaces the current configuration (read before the prank, which would
    ///      otherwise be spent on the read).
    function _setConfig(VrfEntropyModule.VrfConfig memory next) internal {
        VrfEntropyModule.VrfConfig memory current = module.config();
        vm.prank(setter);
        module.setConfig(current, next);
    }

    // ------------------------------------------------------------------ setConfig

    function test_SetConfig_UpdatesAndEmits() public {
        VrfEntropyModule.VrfConfig memory next = VrfEntropyModule.VrfConfig({
            subscriptionId: 0xBEEF,
            keyHash: keccak256("another-lane"),
            callbackGasLimit: 350_000,
            confirmations: 10,
            nativePayment: true
        });
        vm.expectEmit(false, false, false, true, address(module));
        emit ConfigSet(_config(), next);
        vm.prank(setter);
        module.setConfig(_config(), next);

        VrfEntropyModule.VrfConfig memory c = module.config();
        assertEq(c.subscriptionId, next.subscriptionId);
        assertEq(c.keyHash, next.keyHash);
        assertEq(c.callbackGasLimit, next.callbackGasLimit);
        assertEq(c.confirmations, next.confirmations);
        assertTrue(c.nativePayment);
    }

    function test_SetConfig_NeedsTheStandardClassRole() public {
        VrfEntropyModule.VrfConfig memory next = _config();
        next.confirmations = 5;
        address[4] memory callers = [stranger, other, successor, admin];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManaged.AccessManagedUnauthorized.selector, callers[i]
                )
            );
            vm.prank(callers[i]);
            module.setConfig(_config(), next);
        }
    }

    function test_SetConfig_StaleExpectedValueReverts() public {
        VrfEntropyModule.VrfConfig memory next = _config();
        next.confirmations = 5;
        VrfEntropyModule.VrfConfig memory stale = _config();
        stale.subscriptionId += 1;
        vm.expectRevert(IEntropyModule.ExpectedValueMismatch.selector);
        vm.prank(setter);
        module.setConfig(stale, next);

        stale = _config();
        stale.keyHash = bytes32(uint256(1));
        vm.expectRevert(IEntropyModule.ExpectedValueMismatch.selector);
        vm.prank(setter);
        module.setConfig(stale, next);

        stale = _config();
        stale.callbackGasLimit += 1;
        vm.expectRevert(IEntropyModule.ExpectedValueMismatch.selector);
        vm.prank(setter);
        module.setConfig(stale, next);

        stale = _config();
        stale.confirmations += 1;
        vm.expectRevert(IEntropyModule.ExpectedValueMismatch.selector);
        vm.prank(setter);
        module.setConfig(stale, next);

        stale = _config();
        stale.nativePayment = true;
        vm.expectRevert(IEntropyModule.ExpectedValueMismatch.selector);
        vm.prank(setter);
        module.setConfig(stale, next);
        assertEq(module.config().confirmations, CONFIRMATIONS);
    }

    function test_SetConfig_AnUnchangedGasLimitIsAllowed() public {
        VrfEntropyModule.VrfConfig memory next = _config();
        next.subscriptionId = 0xBEEF;
        _setConfig(next);
        assertEq(module.config().subscriptionId, 0xBEEF);
        assertEq(module.config().callbackGasLimit, GAS_LIMIT);
    }

    function test_SetConfig_GasLimitCanOnlyBeRaised() public {
        VrfEntropyModule.VrfConfig memory next = _config();
        next.callbackGasLimit = GAS_LIMIT - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                BoundedParameter.ParameterNotRaised.selector, GAS_LIMIT, GAS_LIMIT - 1
            )
        );
        vm.prank(setter);
        module.setConfig(_config(), next);

        next.callbackGasLimit = 2 * GAS_LIMIT;
        _setConfig(next);
        assertEq(module.config().callbackGasLimit, 2 * GAS_LIMIT);

        // It never goes back down.
        next.callbackGasLimit = GAS_LIMIT;
        VrfEntropyModule.VrfConfig memory current = module.config();
        vm.expectRevert(
            abi.encodeWithSelector(
                BoundedParameter.ParameterNotRaised.selector, 2 * GAS_LIMIT, GAS_LIMIT
            )
        );
        vm.prank(setter);
        module.setConfig(current, next);
    }

    function test_SetConfig_GasLimitAtMostDoublesPerStep() public {
        VrfEntropyModule.VrfConfig memory next = _config();
        next.callbackGasLimit = 2 * GAS_LIMIT + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                BoundedParameter.ParameterStepTooLarge.selector, GAS_LIMIT, 2 * GAS_LIMIT + 1
            )
        );
        vm.prank(setter);
        module.setConfig(_config(), next);

        // Doubling repeatedly reaches the ceiling and no further.
        uint32 limit = GAS_LIMIT;
        while (limit < module.MAX_CALLBACK_GAS()) {
            uint256 doubled = uint256(limit) * 2;
            next.callbackGasLimit =
                doubled > module.MAX_CALLBACK_GAS() ? module.MAX_CALLBACK_GAS() : uint32(doubled);
            _setConfig(next);
            limit = next.callbackGasLimit;
        }
        assertEq(module.config().callbackGasLimit, module.MAX_CALLBACK_GAS());

        next.callbackGasLimit = module.MAX_CALLBACK_GAS() + 1;
        VrfEntropyModule.VrfConfig memory atCeiling = module.config();
        vm.expectRevert(
            abi.encodeWithSelector(
                BoundedParameter.ParameterAboveCeiling.selector,
                module.MAX_CALLBACK_GAS() + 1,
                module.MAX_CALLBACK_GAS()
            )
        );
        vm.prank(setter);
        module.setConfig(atCeiling, next);
    }

    function test_SetConfig_RejectsInvalidFields() public {
        VrfEntropyModule.VrfConfig memory next = _config();
        next.subscriptionId = 0;
        vm.expectRevert(IEntropyModule.InvalidConfig.selector);
        vm.prank(setter);
        module.setConfig(_config(), next);

        next = _config();
        next.keyHash = 0;
        vm.expectRevert(IEntropyModule.InvalidConfig.selector);
        vm.prank(setter);
        module.setConfig(_config(), next);

        next = _config();
        next.confirmations = module.MIN_CONFIRMATIONS() - 1;
        vm.expectRevert(IEntropyModule.InvalidConfig.selector);
        vm.prank(setter);
        module.setConfig(_config(), next);

        next = _config();
        next.confirmations = module.MAX_CONFIRMATIONS() + 1;
        vm.expectRevert(IEntropyModule.InvalidConfig.selector);
        vm.prank(setter);
        module.setConfig(_config(), next);
    }

    /// @dev The gas-limit rule, for any proposal: below the module's floor is an invalid config;
    ///      unchanged is allowed; otherwise it must be raised, by at most double, to at most the
    ///      ceiling (`BoundedParameter`). Whatever is refused leaves the value.
    function testFuzz_SetConfig_GasLimitRule(uint32 proposed) public {
        VrfEntropyModule.VrfConfig memory next = _config();
        next.callbackGasLimit = proposed;
        bool accepted;
        if (proposed < module.MIN_CALLBACK_GAS()) {
            vm.expectRevert(IEntropyModule.InvalidConfig.selector);
        } else if (proposed == GAS_LIMIT) {
            accepted = true;
        } else if (proposed < GAS_LIMIT) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    BoundedParameter.ParameterNotRaised.selector, GAS_LIMIT, proposed
                )
            );
        } else if (proposed > module.MAX_CALLBACK_GAS()) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    BoundedParameter.ParameterAboveCeiling.selector,
                    proposed,
                    module.MAX_CALLBACK_GAS()
                )
            );
        } else if (proposed - GAS_LIMIT > GAS_LIMIT) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    BoundedParameter.ParameterStepTooLarge.selector, GAS_LIMIT, proposed
                )
            );
        } else {
            accepted = true;
        }
        vm.prank(setter);
        module.setConfig(_config(), next);
        assertEq(module.config().callbackGasLimit, accepted ? proposed : GAS_LIMIT);
    }

    function test_SetConfig_AndSetCoordinatorAreNonPayable() public {
        vm.deal(setter, 1 ether);
        vm.deal(successor, 1 ether);
        vm.prank(setter);
        (bool ok,) = address(module).call{ value: 1 }(
            abi.encodeCall(module.setConfig, (_config(), _config()))
        );
        assertFalse(ok);
        vm.prank(successor);
        (ok,) = address(module).call{ value: 1 }(
            abi.encodeCall(module.setCoordinator, (address(coordinator), address(this), bytes32(0)))
        );
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ setCoordinator

    function test_SetCoordinator_SwapsAndEmits() public {
        MockVrfCoordinator next = new MockVrfCoordinator();
        vm.expectEmit(false, false, false, true, address(module));
        emit CoordinatorSet(address(coordinator), address(next), address(next).codehash);
        _swap(address(next));
        assertEq(module.coordinator(), address(next));
    }

    function test_SetCoordinator_NeedsTheSuccessorClassRole() public {
        MockVrfCoordinator next = new MockVrfCoordinator();
        address[4] memory callers = [stranger, other, setter, admin];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManaged.AccessManagedUnauthorized.selector, callers[i]
                )
            );
            vm.prank(callers[i]);
            module.setCoordinator(address(coordinator), address(next), address(next).codehash);
        }
    }

    function test_SetCoordinator_RejectsStaleAndCodelessValues() public {
        MockVrfCoordinator next = new MockVrfCoordinator();
        vm.expectRevert(IEntropyModule.ExpectedValueMismatch.selector);
        vm.prank(successor);
        module.setCoordinator(address(next), address(next), address(next).codehash);

        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, 0));
        vm.prank(successor);
        module.setCoordinator(address(coordinator), address(0), bytes32(0));

        address delegated = makeAddr("delegated EOA");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(next)));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, delegated));
        vm.prank(successor);
        module.setCoordinator(address(coordinator), delegated, delegated.codehash);

        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        vm.prank(successor);
        module.setCoordinator(address(coordinator), stranger, stranger.codehash);
        assertEq(module.coordinator(), address(coordinator));
    }

    function test_SetCoordinator_ASwapToTheCurrentCoordinatorIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(coordinator))
        );
        vm.prank(successor);
        module.setCoordinator(
            address(coordinator), address(coordinator), address(coordinator).codehash
        );
    }

    /// @dev The new coordinator's code hash is pinned: a different contract at the address, or a
    ///      wrong hash, is refused.
    function test_SetCoordinator_PinsTheCodeHash() public {
        MockVrfCoordinator next = new MockVrfCoordinator();
        bytes32 wrong = keccak256("not the reviewed coordinator");
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(next))
        );
        vm.prank(successor);
        module.setCoordinator(address(coordinator), address(next), wrong);
        assertEq(module.coordinator(), address(coordinator));
    }

    function test_SetCoordinator_OldCoordinatorCanNoLongerDeliver() public {
        uint256 pendingId = _request(0);
        MockVrfCoordinator next = new MockVrfCoordinator();
        _swap(address(next));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEntropyModule.OnlyCoordinatorCanFulfill.selector,
                address(coordinator),
                address(next)
            )
        );
        coordinator.fulfill(pendingId, 1);
        assertFalse(module.isDelivered(items[0]));
    }

    function test_SetCoordinator_OrphanedRequestIsRerequestedThroughTheNewOne() public {
        uint256 orphan = _request(0);
        MockVrfCoordinator next = new MockVrfCoordinator();
        next.setNextId(1000);
        _swap(address(next));

        vm.warp(block.timestamp + RETRY_DELAY);
        uint256 fresh = module.requestSeed(_item(0), root, proofs[0]);
        assertEq(fresh, 1000);
        assertTrue(fresh != orphan);
        next.fulfill(fresh, 31337);
        assertEq(module.seedOf(items[0]), bytes32(uint256(31337)));
    }

    /// @dev Request IDs are scoped to the coordinator that issued them: a new coordinator may
    ///      reuse the numbers of the old one, and it cannot deliver what the old one issued.
    function test_SetCoordinator_RequestIdsAreScopedToTheirCoordinator() public {
        uint256 oldId = _request(0); // the old coordinator issues ID 1 for item 0
        MockVrfCoordinator next = new MockVrfCoordinator(); // and the new one also starts at 1
        _swap(address(next));

        // The new coordinator did not issue ID 1, so it cannot deliver it.
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.UnknownRequest.selector, oldId));
        next.deliver(address(module), oldId, _oneWord(5));

        // It can issue the same number for another item without a collision.
        uint256 newId = _request(1);
        assertEq(newId, oldId);
        next.fulfill(newId, 6);
        assertEq(module.seedOf(items[1]), bytes32(uint256(6)));
        assertFalse(module.isDelivered(items[0]));
    }

    function test_SetCoordinator_DeliveredSeedsSurviveTheSwap() public {
        uint256 id = _request(0);
        coordinator.fulfill(id, 8);
        MockVrfCoordinator next = new MockVrfCoordinator();
        _swap(address(next));
        assertTrue(module.isDelivered(items[0]));
        assertEq(module.seedOf(items[0]), bytes32(uint256(8)));
        // Nor can a new coordinator deliver the work again.
        vm.warp(block.timestamp + RETRY_DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.SeedAlreadyDelivered.selector, items[0])
        );
        module.requestSeed(_item(0), root, proofs[0]);
    }

    // ------------------------------------------------------------------ under the delay classes

    /// @dev With the 48-hour execution delay the standard class carries, a setter cannot call
    ///      directly; its scheduled call executes after the delay, and a second scheduled call
    ///      that was prepared against the old value is stale at execution (compare-and-set).
    function test_SetConfig_ScheduledThroughTheManagerAndStaleOperationsRevert() public {
        address delayed = makeAddr("delayed");
        vm.prank(admin);
        manager.grantRole(Roles.PARAMETER_SETTER, delayed, 48 hours);

        VrfEntropyModule.VrfConfig memory a = _config();
        a.confirmations = 5;
        VrfEntropyModule.VrfConfig memory b = _config();
        b.confirmations = 6;
        bytes memory dataA = abi.encodeCall(module.setConfig, (_config(), a));
        bytes memory dataB = abi.encodeCall(module.setConfig, (_config(), b));

        // A direct call needs the schedule first.
        bytes32 operationA = manager.hashOperation(delayed, address(module), dataA);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, operationA)
        );
        vm.prank(delayed);
        module.setConfig(_config(), a);

        vm.startPrank(delayed);
        manager.schedule(address(module), dataA, 0);
        manager.schedule(address(module), dataB, 0);
        // And it cannot execute before the 48 hours are over.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, operationA)
        );
        manager.execute(address(module), dataA);
        vm.warp(block.timestamp + 48 hours);
        manager.execute(address(module), dataA);
        assertEq(module.config().confirmations, 5);

        vm.expectRevert(IEntropyModule.ExpectedValueMismatch.selector);
        manager.execute(address(module), dataB);
        vm.stopPrank();
        assertEq(module.config().confirmations, 5);
    }
}
