// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StateGrowth } from "./StateGrowth.sol";

/// @dev A contract whose constructor writes one slot.
contract GrowthChild {
    uint256 public value = 1;
}

/// @dev Storage, calls and value transfers in every shape `StateGrowth` must tell apart.
contract GrowthToy {
    mapping(uint256 key => uint256) public word;

    function set(uint256 key, uint256 value) external {
        word[key] = value;
    }

    function setTwice(uint256 key, uint256 first, uint256 second) external {
        word[key] = first;
        word[key] = second;
    }

    /// @dev Writes in a call that reverts, then optionally writes the same slot for real.
    function setInRevertedCall(uint256 key, uint256 value, uint256 after_) external {
        try this.setAndRevert(key, value) { } catch { }
        if (after_ != 0) word[key] = after_;
    }

    function setAndRevert(uint256 key, uint256 value) external {
        word[key] = value;
        revert("undone");
    }

    /// @dev The write succeeds in its own frame, but the frame that made it reverts.
    function setInCallerThatReverts(uint256 key, uint256 value) external {
        try this.callSetThenRevert(key, value) { } catch { }
    }

    function callSetThenRevert(uint256 key, uint256 value) external {
        this.set(key, value);
        revert("undone");
    }

    /// @dev Writes `key`, lets `callback` write it again through `set`, then clears it.
    function setReenterClear(uint256 key, GrowthCallback callback) external {
        word[key] = 1;
        callback.reenter(this, key);
        word[key] = 0;
    }

    function create() external returns (address) {
        return address(new GrowthChild());
    }

    function send(address to, uint256 amount) external payable {
        (bool ok,) = to.call{ value: amount }("");
        require(ok, "send failed");
    }

    function sendInRevertedCall(address to, uint256 amount) external payable {
        try this.sendAndRevert(to, amount) { } catch { }
    }

    function sendAndRevert(address to, uint256 amount) external {
        (bool ok,) = to.call{ value: amount }("");
        require(ok, "send failed");
        revert("undone");
    }

    receive() external payable { }
}

contract GrowthCallback {
    function reenter(GrowthToy toy, uint256 key) external {
        toy.set(key, 7);
    }
}

/// @notice `StateGrowth` on a toy contract: what counts as a new slot and as a new account.
contract StateGrowthTest is Test {
    GrowthToy internal toy;
    GrowthCallback internal callback;

    function setUp() public {
        toy = new GrowthToy();
        callback = new GrowthCallback();
        vm.deal(address(this), 10 ether);
    }

    function _grow(bytes memory data, uint256 value)
        internal
        returns (StateGrowth.Growth memory growth)
    {
        vm.startStateDiffRecording();
        (bool ok,) = address(toy).call{ value: value }(data);
        assertTrue(ok, "toy call");
        growth = StateGrowth.count(vm.stopAndReturnStateDiff());
    }

    function _assertGrowth(StateGrowth.Growth memory growth, uint256 slots, uint256 accounts)
        internal
        pure
    {
        assertEq(growth.slots, slots, "new slots");
        assertEq(growth.accounts, accounts, "new accounts");
    }

    function test_OneNewSlot() public {
        _assertGrowth(_grow(abi.encodeCall(toy.set, (1, 5)), 0), 1, 0);
    }

    function test_OverwriteIsNotNew() public {
        toy.set(1, 5);
        _assertGrowth(_grow(abi.encodeCall(toy.set, (1, 6)), 0), 0, 0);
    }

    function test_SeveralWritesToANewSlotCountOnce() public {
        _assertGrowth(_grow(abi.encodeCall(toy.setTwice, (1, 5, 6)), 0), 1, 0);
    }

    function test_ZeroToZeroIsNotNew() public {
        _assertGrowth(_grow(abi.encodeCall(toy.set, (1, 0)), 0), 0, 0);
        // Written from zero and cleared in the same transaction.
        _assertGrowth(_grow(abi.encodeCall(toy.setTwice, (1, 5, 0)), 0), 0, 0);
    }

    function test_NonZeroToZeroIsNotNew() public {
        toy.set(1, 5);
        _assertGrowth(_grow(abi.encodeCall(toy.set, (1, 0)), 0), 0, 0);
    }

    function test_WriteInARevertedCallIsNotNew() public {
        _assertGrowth(_grow(abi.encodeCall(toy.setInRevertedCall, (1, 5, 0)), 0), 0, 0);
        assertEq(toy.word(1), 0);
    }

    function test_WriteUndoneByTheCallersRevertIsNotNew() public {
        _assertGrowth(_grow(abi.encodeCall(toy.setInCallerThatReverts, (1, 5)), 0), 0, 0);
        assertEq(toy.word(1), 0);
    }

    function test_RevertedWriteThenARealWriteCountsOnce() public {
        _assertGrowth(_grow(abi.encodeCall(toy.setInRevertedCall, (1, 5, 6)), 0), 1, 0);
        assertEq(toy.word(1), 6);
    }

    /// @dev The caller's write after a re-entrant call is the final one: the recording must be
    ///      read in order, or the slot would look non-zero (and `count` would fail its check).
    function test_ReentrantWritesAreReadInOrder() public {
        _assertGrowth(_grow(abi.encodeCall(toy.setReenterClear, (1, callback)), 0), 0, 0);
    }

    function test_CreateIsANewAccountWithItsSlots() public {
        _assertGrowth(_grow(abi.encodeCall(toy.create, ()), 0), 1, 1);
    }

    function test_EthToAFreshAccountIsANewAccount() public {
        address fresh = makeAddr("fresh");
        _assertGrowth(_grow(abi.encodeCall(toy.send, (fresh, 1)), 1), 0, 1);
        assertEq(fresh.balance, 1);
    }

    function test_EthToAnExistingAccountIsNotNew() public {
        address funded = makeAddr("funded");
        vm.deal(funded, 1);
        _assertGrowth(_grow(abi.encodeCall(toy.send, (funded, 1)), 1), 0, 0);
    }

    function test_ZeroValueCallToAFreshAccountIsNotNew() public {
        _assertGrowth(_grow(abi.encodeCall(toy.send, (makeAddr("untouched"), 0)), 0), 0, 0);
    }

    function test_EthSentInARevertedCallIsNotANewAccount() public {
        address fresh = makeAddr("freshReverted");
        vm.deal(address(toy), 1);
        _assertGrowth(_grow(abi.encodeCall(toy.sendInRevertedCall, (fresh, 1)), 0), 0, 0);
        assertEq(fresh.balance, 0);
    }

    /// @dev The value the caller sends to an existing toy is a balance change, not new state.
    function test_ValueToTheTargetIsNotNew() public {
        _assertGrowth(_grow(abi.encodeCall(toy.send, (address(toy), 0)), 1), 0, 0);
    }
}
