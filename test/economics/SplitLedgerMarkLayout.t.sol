// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { ISplitLedger } from "src/economics/interfaces/ISplitLedger.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

/// @notice A payee's mark in the split ledger is one storage slot: the released level the payee
///         must reach in the low 208 bits and the time of the mark in the 48 bits above them.
///         The tests read the slot itself, so they fail if the mark grows to a second slot or
///         its two fields change place or width.
contract SplitLedgerMarkLayoutTest is EconomicsBase {
    /// @dev The slot of `_marks` in `SplitLedger` (test/snapshots/storage/SplitLedger.json).
    uint256 internal constant MARKS_SLOT = 7;

    function _markSlot(address wallet, address asset, uint256 index)
        internal
        pure
        returns (bytes32)
    {
        bytes32 byWallet = keccak256(abi.encode(wallet, MARKS_SLOT));
        bytes32 byAsset = keccak256(abi.encode(asset, byWallet));
        return keccak256(abi.encode(index, byAsset));
    }

    /// @dev A wallet with alice at 80% and the artist at 20%, holding `funded`.
    function _funded(uint256 funded)
        internal
        returns (address wallet, ISplitWallet.Payee[] memory payees, uint256 index)
    {
        wallet = _wallet(_list(_fixed(alice, 80_000), _artist(ARTIST, 20_000)));
        vm.deal(wallet, funded);
        index = _artistIndex(wallet, ARTIST);
        payees = _payeesOf(wallet);
    }

    function testFuzz_AMarkIsOneWord_TargetBelowTime(uint96 funded, uint48 time) public {
        funded = uint96(bound(funded, 5, type(uint96).max));
        time = uint48(bound(time, 1, type(uint48).max));
        (address wallet, ISplitWallet.Payee[] memory payees, uint256 index) = _funded(funded);
        uint256 target =
            uint256(funded) / 100_000 * 20_000 + uint256(funded) % 100_000 * 20_000 / 100_000;
        bytes32 slot = _markSlot(wallet, ETH, index);
        assertEq(vm.load(address(ledger), slot), bytes32(0), "no mark, an empty slot");

        vm.warp(time);
        vm.record();
        vm.expectEmit(address(ledger));
        emit ISplitLedger.Marked(wallet, ETH, index, target, time);
        ledger.mark(payees, bytes32(0), ETH, index);
        (, bytes32[] memory writes) = vm.accesses(address(ledger));
        assertGt(writes.length, 0, "a mark is written");
        for (uint256 i; i < writes.length; ++i) {
            assertEq(writes[i], slot, "a mark writes its one slot only");
        }

        assertEq(uint256(vm.load(address(ledger), slot)), uint256(time) << 208 | target, "the word");
        (uint256 gotTarget, uint256 gotTime) = ledger.markOf(wallet, ETH, index);
        assertEq(gotTarget, target);
        assertEq(gotTime, time);
    }

    /// @dev The widest values a mark can hold come back whole from the one slot.
    function test_AMarkAtTheWidthOfBothFieldsReadsBack() public {
        (address wallet,, uint256 index) = _funded(10 ether);
        bytes32 slot = _markSlot(wallet, ETH, index);
        vm.store(address(ledger), slot, bytes32(type(uint256).max));
        (uint256 target, uint256 markedAt) = ledger.markOf(wallet, ETH, index);
        assertEq(target, type(uint208).max);
        assertEq(markedAt, type(uint48).max);
    }

    /// @dev A forfeit clears the whole slot.
    function test_AForfeitEmptiesTheSlot() public {
        (address wallet, ISplitWallet.Payee[] memory payees, uint256 index) = _funded(10 ether);
        ledger.mark(payees, bytes32(0), ETH, index);
        bytes32 slot = _markSlot(wallet, ETH, index);
        assertTrue(vm.load(address(ledger), slot) != bytes32(0));
        vm.warp(block.timestamp + 365 days * 20);
        ledger.forfeit(payees, bytes32(0), ETH, index);
        assertEq(vm.load(address(ledger), slot), bytes32(0));
    }
}
