// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Facts, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { HostileModule } from "../mocks/core/CoreMocks.sol";
import { RulesFixture } from "./RulesFixture.sol";

/// @notice `WorkRules` against hostile neighbours: an accounts module or a TERMS module that
///         reverts, lies or burns its gas. Every failure fails closed: the call reverts and no
///         fact changes; nothing returns a default.
contract WorkRulesHostileTest is RulesFixture {
    address internal s;
    HostileModule internal hostile;

    function setUp() public override {
        super.setUp();
        s = address(stream);
        hostile = new HostileModule();
    }

    function _installAccounts(address module) internal {
        directory.setModuleDelay(0);
        directory.proposeModule(Slots.ACCOUNTS, module);
        directory.activateModule(Slots.ACCOUNTS);
    }

    function test_Hostile_AMissingOrRevertingAccountsModuleStopsEditsOnly() public {
        (uint256 id,,) = _work(stream, 1);
        bytes32 next = _record(2);
        bytes32 state = _state(id);
        bytes32 before = keccak256(abi.encode(facts.factsOf(s, id)));
        directory.removeModule(Slots.ACCOUNTS);
        vm.prank(artist);
        vm.expectRevert();
        rules.setRecord(s, id, next, state);
        // A module with no such function reverts too: no default answer.
        _installAccounts(address(hostile));
        vm.prank(artist);
        vm.expectRevert();
        rules.setRecord(s, id, next, state);
        vm.prank(artist);
        vm.expectRevert();
        rules.finalize(s, id, state);
        assertEq(keccak256(abi.encode(facts.factsOf(s, id))), before);
        // The token still works.
        sale.record(s, id, true, collector, 1);
        sale.send(s, id, collector);
        assertEq(stream.ownerOf(id), collector);
    }

    /// @dev A lying accounts module can make anyone the artist of every work: it can then edit
    ///      and finalize records within what `StreamWorkFacts6529` allows, and nothing more.
    function test_Hostile_ALyingAccountsModuleStaysInsideWhatWorkFactsAllows() public {
        (uint256 id,,) = _work(stream, 1);
        signers.setWallet(uint160(artist), stranger, true);
        bytes32 state = _state(id);
        vm.prank(stranger);
        rules.finalize(s, id, state);
        bytes32 next = _record(2);
        state = _state(id);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.WorkIsFinalized.selector, s, id));
        rules.setRecord(s, id, next, state);
        Facts memory f = facts.factsOf(s, id);
        assertTrue(f.finalized);
        assertEq(f.licenseId, "CC0-1.0");
    }

    function test_Hostile_ARevertingTermsModuleStopsRefreshesAndRateChanges() public {
        (uint256 id,,) = _work(stream, 1);
        _install(s, Slots.TERMS, address(hostile));
        bytes32 next = _record(2);
        bytes32 state = _state(id);
        vm.prank(artist);
        vm.expectRevert();
        rules.setRecord(s, id, next, state);
        // Without a TERMS module, edits go on (no edition to refresh).
        stream.removeModule(Slots.TERMS);
        vm.prank(artist);
        rules.setRecord(s, id, next, state);
        assertEq(facts.factsOf(s, id).recordFileId, next);
    }

    function test_Hostile_AGasBurningRendererPinFailsOnlyTokenUri() public {
        (uint256 id,,) = _work(stream, 1);
        hostile.setMode(HostileModule.Mode.BURN_GAS);
        _install(s, Slots.RENDERER, address(hostile));
        bytes32 state = _state(id);
        vm.prank(artist);
        rules.finalize(s, id, state);
        // The pin is the module the token named; it fails only tokenURI.
        assertEq(facts.rendererOf(s, id), address(hostile));
        vm.expectRevert();
        stream.tokenURI{ gas: 1_000_000 }(id);
        assertEq(stream.ownerOf(id), address(sale));
    }
}
