// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { RulesFixture } from "../records/RulesFixture.sol";

/// @notice `StreamWorkFacts6529` pins only an installable contract as a renderer (review B, B-1):
///         never an EIP-7702 delegated account, whose designator its key holder can change at will.
contract WorkFactsFixesTest is RulesFixture {
    address internal b;

    function setUp() public override {
        super.setUp();
        b = address(bare);
    }

    function _finalized(uint256 salt) internal returns (uint256 id) {
        (id,,) = _work(bare, salt);
        records.finalize(b, id);
    }

    function test_Repin_RefusesADelegatedAccount() public {
        uint256 id = _finalized(1);
        address eoa = makeAddr("delegated");
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(renderer)));
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RendererCodeChanged.selector, eoa));
        records.repin(b, id, eoa);
        assertEq(facts.rendererOf(b, id), address(renderer));
    }

    function test_Finalize_RefusesADelegatedRendererModule() public {
        (uint256 id,,) = _work(bare, 1);
        address eoa = address(renderer);
        // The token's RENDERER module turns out to be a delegated account at finalize.
        vm.etch(eoa, abi.encodePacked(hex"ef0100", makeAddr("delegate")));
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RendererCodeChanged.selector, eoa));
        records.finalize(b, id);
        assertFalse(facts.factsOf(b, id).finalized);
    }

    /// The rule is exactly `Dependency.isInstallable`. Code starting with `0xef` other than a
    /// designator cannot exist on chain (EIP-3541), so the fuzzer skips it.
    function testFuzz_Pin_SameRuleAsDependency(bytes memory code) public {
        vm.assume(code.length <= 64 && (code.length == 0 || code[0] != 0xef));
        uint256 id = _finalized(2);
        address target = makeAddr("target");
        vm.etch(target, code);
        bool installable = DependencyProbe.installable(target);
        if (!installable) {
            vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RendererCodeChanged.selector, target));
        }
        records.repin(b, id, target);
    }

    /// 23 bytes of code that are not a designator are a contract, and are pinned.
    function test_Pin_TwentyThreeBytesThatAreNoDesignator() public {
        uint256 id = _finalized(3);
        address c = makeAddr("c");
        vm.etch(c, abi.encodePacked(hex"600000", address(renderer)));
        records.repin(b, id, c);
        assertEq(facts.rendererOf(b, id), c);
    }

    /// 23 bytes whose first three sort above the designator's prefix are a contract too.
    function test_Pin_TwentyThreeBytesAboveTheDesignatorPrefix() public {
        uint256 id = _finalized(4);
        address c = makeAddr("c");
        vm.etch(c, abi.encodePacked(hex"fe0000", address(renderer)));
        assertTrue(DependencyProbe.installable(c));
        records.repin(b, id, c);
        assertEq(facts.rendererOf(b, id), c);
    }
}

/// @notice `Dependency.isInstallable`, callable from a test.
library DependencyProbe {
    function installable(address a) internal view returns (bool) {
        return Dependency.isInstallable(a);
    }
}
