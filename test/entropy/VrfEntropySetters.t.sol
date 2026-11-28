// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { EntropyBase } from "./EntropyBase.sol";
import { MockVrfWrapper } from "test/mocks/entropy/EntropyMocks.sol";

/// @notice Two governed setters of the entropy module. What `setWrapper` installs (ENT-22): a
///         contract with code and the pinned code hash, never an EIP-7702 delegated account,
///         whose code its key holder can change at will. And the event of
///         `lowerCallbackGasLimit` (GV-18): the configuration before and after.
contract VrfEntropySettersTest is EntropyBase {
    MockVrfWrapper internal wrapper;

    function setUp() public override {
        super.setUp();
        wrapper = new MockVrfWrapper();
        vm.startPrank(admin);
        manager.setTargetFunctionRole(
            address(module), _selector(module.setWrapper.selector), Roles.SUCCESSOR_SETTER
        );
        manager.setTargetFunctionRole(
            address(module),
            _selector(module.lowerCallbackGasLimit.selector),
            Roles.SUCCESSOR_SETTER
        );
        vm.stopPrank();
    }

    /// GV-18: lowering the callback gas limit emits `ConfigSet` with the whole configuration
    /// before and after; a refused lowering emits nothing and changes nothing.
    function test_LowerCallbackGasLimit_EmitsTheOldAndTheNewConfiguration() public {
        VrfEntropyModule.VrfConfig memory previous = module.config();
        VrfEntropyModule.VrfConfig memory next = module.config();
        next.callbackGasLimit = module.MIN_CALLBACK_GAS();
        assertLt(next.callbackGasLimit, previous.callbackGasLimit);

        vm.startPrank(successor);
        vm.expectRevert(IEntropyModule.ExpectedValueMismatch.selector);
        module.lowerCallbackGasLimit(previous.callbackGasLimit + 1, next.callbackGasLimit);
        vm.expectRevert(IEntropyModule.InvalidConfig.selector);
        module.lowerCallbackGasLimit(previous.callbackGasLimit, next.callbackGasLimit - 1);
        assertEq(module.config().callbackGasLimit, previous.callbackGasLimit, "unchanged");

        vm.expectEmit(address(module));
        emit VrfEntropyModule.ConfigSet(previous, next);
        module.lowerCallbackGasLimit(previous.callbackGasLimit, next.callbackGasLimit);
        vm.stopPrank();
        assertEq(module.config().callbackGasLimit, next.callbackGasLimit);
    }

    /// ENT-22: a delegated account is refused as the wrapper even when the hash given is the
    /// hash of its delegation designator; the contract it delegates to installs.
    function test_SetWrapper_RefusesADelegatedAccount() public {
        address delegated = makeAddr("delegated wrapper");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(wrapper)));
        bytes32 designatorHash = delegated.codehash;
        assertTrue(designatorHash != address(wrapper).codehash);

        vm.startPrank(successor);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, delegated));
        module.setWrapper(address(0), delegated, designatorHash);
        assertEq(module.wrapper(), address(0), "nothing installed");

        vm.expectEmit(address(module));
        emit IEntropyModule.WrapperSet(address(0), address(wrapper), address(wrapper).codehash);
        module.setWrapper(address(0), address(wrapper), address(wrapper).codehash);
        vm.stopPrank();
        assertEq(module.wrapper(), address(wrapper));
    }

    /// ENT-22: an account without code is refused whichever hash is given for it (zero for an
    /// account that does not exist, the empty-code hash for one that does).
    function test_SetWrapper_RefusesAnAccountWithoutCode() public {
        address empty = makeAddr("no code");
        bytes32[3] memory hashes = [bytes32(0), keccak256(""), empty.codehash];
        vm.startPrank(successor);
        for (uint256 i; i < hashes.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, empty));
            module.setWrapper(address(0), empty, hashes[i]);
        }
        vm.stopPrank();
        assertEq(module.wrapper(), address(0));
    }
}
