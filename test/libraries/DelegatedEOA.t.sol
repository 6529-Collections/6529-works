// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DelegatedEOA } from "src/libraries/DelegatedEOA.sol";

contract DelegatedEOAHarness {
    function isDelegated(address account) external view returns (bool) {
        return DelegatedEOA.isDelegated(account);
    }

    function delegateOf(address account) external view returns (address) {
        return DelegatedEOA.delegateOf(account);
    }
}

contract DelegateImplementation {
    function ping() external pure returns (uint256) {
        return 7;
    }
}

contract DelegatedEOATest is Test {
    DelegatedEOAHarness internal harness;
    DelegateImplementation internal implementation;

    function setUp() public {
        harness = new DelegatedEOAHarness();
        implementation = new DelegateImplementation();
    }

    function test_PlainEOAIsNotDelegated() public view {
        address eoa = vm.addr(0xA11CE);
        assertFalse(harness.isDelegated(eoa));
        assertEq(harness.delegateOf(eoa), address(0));
    }

    function test_ContractIsNotDelegated() public view {
        assertFalse(harness.isDelegated(address(implementation)));
        assertEq(harness.delegateOf(address(implementation)), address(0));
    }

    function test_SignedDelegationIsDetected() public {
        uint256 key = 0xB0B;
        address eoa = vm.addr(key);
        vm.signAndAttachDelegation(address(implementation), key);
        assertEq(eoa.code.length, 23);
        assertTrue(harness.isDelegated(eoa));
        assertEq(harness.delegateOf(eoa), address(implementation));
        // The designator really delegates execution.
        assertEq(DelegateImplementation(eoa).ping(), 7);
    }

    function test_EtchedDesignatorIsDetected() public {
        address account = makeAddr("account");
        address delegate = makeAddr("delegate");
        vm.etch(account, abi.encodePacked(hex"ef0100", delegate));
        assertTrue(harness.isDelegated(account));
        assertEq(harness.delegateOf(account), delegate);
    }

    function test_OtherLengthsAreNotDelegated() public {
        address account = makeAddr("account");
        address delegate = makeAddr("delegate");
        // revm (like mainnet since EIP-3541) cannot hold 0xef01 code of another length, so
        // the length check is defense in depth; exercise it with neighbouring sizes.
        vm.etch(account, abi.encodePacked(hex"000100", delegate, hex"00"));
        assertFalse(harness.isDelegated(account));
        assertEq(harness.delegateOf(account), address(0));
        vm.etch(account, abi.encodePacked(hex"000100", bytes19(bytes20(delegate))));
        assertFalse(harness.isDelegated(account));
        assertEq(harness.delegateOf(account), address(0));
    }

    function test_EtchingMalformedDesignatorIsImpossible() public {
        address account = makeAddr("account");
        vm.expectRevert();
        this.etchExternal(account, abi.encodePacked(hex"ef0100", makeAddr("delegate"), hex"00"));
    }

    function etchExternal(address account, bytes calldata code) external {
        vm.etch(account, code);
    }

    function test_WrongPrefixIsNotDelegated() public {
        address account = makeAddr("account");
        address delegate = makeAddr("delegate");
        bytes3[4] memory prefixes = [bytes3(0x000100), 0xfe0100, 0xef0000, 0x00ef01];
        for (uint256 i; i < prefixes.length; ++i) {
            vm.etch(account, abi.encodePacked(prefixes[i], delegate));
            assertFalse(harness.isDelegated(account));
            assertEq(harness.delegateOf(account), address(0));
        }
    }

    function testFuzz_TwentyThreeByteCode(bytes3 prefix, address delegate) public {
        // revm rejects any other 0xef01-prefixed code (see the test above).
        vm.assume(bytes2(prefix) != 0xef01 || prefix == bytes3(0xef0100));
        address account = makeAddr("fuzzed");
        vm.etch(account, abi.encodePacked(prefix, delegate));
        bool expected = prefix == bytes3(0xef0100);
        assertEq(harness.isDelegated(account), expected);
        assertEq(harness.delegateOf(account), expected ? delegate : address(0));
    }
}
