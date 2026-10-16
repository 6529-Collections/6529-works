// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Dependency } from "src/libraries/Dependency.sol";

contract DependencyHarness {
    function isInstallable(address dependency) external view returns (bool) {
        return Dependency.isInstallable(dependency);
    }

    function isInstallableAs(address dependency, bytes4 interfaceId) external view returns (bool) {
        return Dependency.isInstallable(dependency, interfaceId);
    }

    function check(address dependency) external view {
        Dependency.check(dependency);
    }

    function checkAs(address dependency, bytes4 interfaceId) external view {
        Dependency.check(dependency, interfaceId);
    }

    function checkPinned(address dependency, bytes32 codeHash) external view {
        Dependency.checkPinned(dependency, codeHash);
    }

    function checkPinnedAs(address dependency, bytes4 interfaceId, bytes32 codeHash) external view {
        Dependency.checkPinned(dependency, interfaceId, codeHash);
    }

    function checkUnchanged(address dependency, bytes32 codeHash) external view {
        Dependency.checkUnchanged(dependency, codeHash);
    }
}

/// @dev Declares ERC-165 and one other interface by ERC-165.
contract InterfaceAnswer is IERC165 {
    bytes4 internal immutable declared;

    constructor(bytes4 declared_) {
        declared = declared_;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == declared;
    }
}

/// @dev Code without ERC-165.
contract NoInterface {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @notice The one install check and the use-time pin check: code, the EIP-7702 refusal, ERC-165,
///         and both sides of each code-hash comparison, tested on the library itself so the
///         mutation tool's first pass (`test/libraries`) sees them.
contract DependencyTest is Test {
    bytes4 internal constant ID = 0x12345678;

    DependencyHarness internal harness;
    InterfaceAnswer internal dependency; // installable as `ID`
    address internal delegated; // an EIP-7702 account delegating to `dependency`

    function setUp() public {
        harness = new DependencyHarness();
        dependency = new InterfaceAnswer(ID);
        delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(dependency)));
    }

    function test_IsInstallable_NeedsCode() public {
        assertTrue(harness.isInstallable(address(dependency)));
        assertTrue(harness.isInstallableAs(address(dependency), ID));
        address[2] memory codeless = [address(0), makeAddr("an account")];
        for (uint256 i; i < codeless.length; ++i) {
            assertFalse(harness.isInstallable(codeless[i]));
            assertFalse(harness.isInstallableAs(codeless[i], ID));
        }
    }

    /// @dev A delegated account runs its delegate's code, so it answers ERC-165 as the delegate
    ///      does; only the delegation check refuses it.
    function test_IsInstallable_RefusesAnEip7702DelegatedAccount() public view {
        assertTrue(InterfaceAnswer(delegated).supportsInterface(ID), "answers as its delegate");
        assertFalse(harness.isInstallable(delegated));
        assertFalse(harness.isInstallableAs(delegated, ID));
    }

    function test_IsInstallable_NeedsTheInterfaceByErc165() public {
        assertFalse(harness.isInstallableAs(address(dependency), 0x87654321));
        address plain = address(new NoInterface());
        assertTrue(harness.isInstallable(plain));
        assertFalse(harness.isInstallableAs(plain, ID));
    }

    function test_Check_RevertsForEveryRefusal() public {
        address plain = address(new NoInterface());
        harness.check(address(dependency));
        harness.check(plain);
        harness.checkAs(address(dependency), ID);

        address[3] memory refused = [address(0), makeAddr("an account"), delegated];
        for (uint256 i; i < refused.length; ++i) {
            _expectInvalid(refused[i]);
            harness.check(refused[i]);
            _expectInvalid(refused[i]);
            harness.checkAs(refused[i], ID);
        }
        _expectInvalid(plain);
        harness.checkAs(plain, ID);
    }

    function test_CheckPinned_RefusesAPinOnEitherSideOfTheCodeHash() public {
        address target = address(dependency);
        uint256 actual = uint256(target.codehash);
        harness.checkPinned(target, bytes32(actual));
        harness.checkPinnedAs(target, ID, bytes32(actual));

        bytes32[2] memory wrong = [bytes32(actual - 1), bytes32(actual + 1)];
        for (uint256 i; i < wrong.length; ++i) {
            _expectInvalid(target);
            harness.checkPinned(target, wrong[i]);
            _expectInvalid(target);
            harness.checkPinnedAs(target, ID, wrong[i]);
        }
    }

    /// @dev A pin that matches is not enough: the dependency must still be installable.
    function test_CheckPinned_RefusesAMatchingPinOnAnUninstallableAddress() public {
        address codeless = makeAddr("an account");
        address[2] memory refused = [codeless, delegated];
        for (uint256 i; i < refused.length; ++i) {
            bytes32 pin = refused[i].codehash;
            _expectInvalid(refused[i]);
            harness.checkPinned(refused[i], pin);
            _expectInvalid(refused[i]);
            harness.checkPinnedAs(refused[i], ID, pin);
        }
        address plain = address(new NoInterface());
        harness.checkPinned(plain, plain.codehash);
        _expectInvalid(plain);
        harness.checkPinnedAs(plain, ID, plain.codehash);
    }

    function test_CheckUnchanged_RefusesCodeOnEitherSideOfThePin() public {
        address target = address(dependency);
        uint256 actual = uint256(target.codehash);
        harness.checkUnchanged(target, bytes32(actual));

        bytes32[2] memory pins = [bytes32(actual - 1), bytes32(actual + 1)];
        for (uint256 i; i < pins.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(Dependency.DependencyCodeChanged.selector, target)
            );
            harness.checkUnchanged(target, pins[i]);
        }
    }

    function _expectInvalid(address target) internal {
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, target));
    }
}
