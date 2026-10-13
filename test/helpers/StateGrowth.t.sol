// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { StateGrowth } from "./StateGrowth.sol";

/// @dev A contract whose constructor writes one slot.
contract GrowthChild {
    uint256 public value = 1;

    function set(uint256 next) external {
        value = next;
    }
}

/// @dev Code run by `GrowthToy` through `delegatecall`: the same layout, so it writes the toy.
contract GrowthLogic {
    mapping(uint256 key => uint256) public word;

    function set(uint256 key, uint256 value) external {
        word[key] = value;
    }
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

    /// @dev Writes in a frame that halts: out of gas, or on `INVALID`.
    function setInHaltedCall(uint256 key, uint256 value, bool outOfGas) external {
        if (outOfGas) {
            try this.setThenBurn{ gas: 100_000 }(key, value) { } catch { }
        } else {
            try this.setThenInvalid(key, value) { } catch { }
        }
    }

    function setThenBurn(uint256 key, uint256 value) external {
        word[key] = value;
        for (uint256 i;; ++i) {
            word[key + 1 + (i % 2)] = i;
        }
    }

    function setThenInvalid(uint256 key, uint256 value) external {
        word[key] = value;
        assembly ("memory-safe") {
            invalid()
        }
    }

    /// @dev Writes `key`, lets `callback` write it again through `set`, then clears it.
    function setReenterClear(uint256 key, GrowthCallback callback) external {
        word[key] = 1;
        callback.reenter(this, key);
        word[key] = 0;
    }

    /// @dev Writes `key` around two calls to `child`, ending at zero, then writes `key + 1`.
    function interleave(uint256 key, GrowthChild child) external {
        word[key] = 1;
        child.set(2);
        word[key] = 0;
        child.set(3);
        word[key + 1] = 4;
    }

    function setByDelegatecall(GrowthLogic logic, uint256 key, uint256 value) external {
        (bool ok,) = address(logic).delegatecall(abi.encodeCall(GrowthLogic.set, (key, value)));
        require(ok, "delegatecall failed");
    }

    /// @dev Transient storage only: set, read and cleared within the call.
    function useTransient(uint256 key, uint256 value) external returns (uint256 read) {
        assembly ("memory-safe") {
            tstore(key, value)
            read := tload(key)
        }
    }

    function create() external returns (address) {
        return address(new GrowthChild());
    }

    /// @dev Reads the CREATE2 address first (a cold touch), then creates the contract there.
    function createAfterCheck(bytes32 salt) external returns (address created) {
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            salt,
                            keccak256(type(GrowthChild).creationCode)
                        )
                    )
                )
            )
        );
        require(predicted.code.length == 0, "already created");
        created = address(new GrowthChild{ salt: salt }());
        require(created == predicted, "prediction");
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

/// @notice `StateGrowth` on a toy contract: what counts as a new slot, a new account and a cold
///         account, and that the state after the call is restored.
contract StateGrowthTest is Test {
    GrowthToy internal toy;
    GrowthCallback internal callback;
    GrowthChild internal child;
    GrowthLogic internal logic;

    function setUp() public {
        toy = new GrowthToy();
        callback = new GrowthCallback();
        child = new GrowthChild();
        logic = new GrowthLogic();
        vm.deal(address(this), 10 ether);
    }

    function _grow(bytes memory data, uint256 value)
        internal
        returns (StateGrowth.Growth memory growth)
    {
        uint256 preCall = vm.snapshotState();
        vm.startStateDiffRecording();
        (bool ok,) = address(toy).call{ value: value }(data);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertTrue(ok, "toy call");
        growth = StateGrowth.count(accesses, preCall, address(this), address(toy));
        vm.deleteStateSnapshot(preCall);
    }

    function _assertGrowth(StateGrowth.Growth memory growth, uint256 slots, uint256 accounts)
        internal
        pure
    {
        assertEq(growth.slots, slots, "new slots");
        assertEq(growth.newSlots.length, slots, "listed slots");
        assertEq(growth.accounts, accounts, "new accounts");
        assertEq(growth.newAccounts.length, accounts, "listed accounts");
    }

    // ------------------------------------------------------------------ slots

    function test_OneNewSlot() public {
        StateGrowth.Growth memory growth = _grow(abi.encodeCall(toy.set, (1, 5)), 0);
        _assertGrowth(growth, 1, 0);
        assertEq(growth.newSlots[0].account, address(toy));
        assertEq(growth.newSlots[0].value, bytes32(uint256(5)));
        assertEq(toy.word(1), 5, "the state after the call is restored");
    }

    function test_OverwriteIsNotNew() public {
        toy.set(1, 5);
        _assertGrowth(_grow(abi.encodeCall(toy.set, (1, 6)), 0), 0, 0);
        assertEq(toy.word(1), 6);
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

    function test_WriteInAFrameThatRanOutOfGasIsNotNew() public {
        _assertGrowth(_grow(abi.encodeCall(toy.setInHaltedCall, (1, 5, true)), 0), 0, 0);
        assertEq(toy.word(1), 0);
    }

    function test_WriteInAFrameThatHitInvalidIsNotNew() public {
        _assertGrowth(_grow(abi.encodeCall(toy.setInHaltedCall, (1, 5, false)), 0), 0, 0);
        assertEq(toy.word(1), 0);
    }

    /// @dev The caller's write after a re-entrant call is the final one.
    function test_ReentrantWritesEndingAtZeroAreNotNew() public {
        _assertGrowth(_grow(abi.encodeCall(toy.setReenterClear, (1, callback)), 0), 0, 0);
    }

    /// @dev The parent's slot ends at zero across two child calls; the child's slot was already
    ///      set by its constructor; only the parent's last write is new.
    function test_ParentWritingBetweenTwoChildCalls() public {
        StateGrowth.Growth memory growth = _grow(abi.encodeCall(toy.interleave, (1, child)), 0);
        _assertGrowth(growth, 1, 0);
        assertEq(growth.newSlots[0].account, address(toy));
        assertEq(child.value(), 3);
    }

    function test_AWriteThroughDelegatecallIsTheCallersSlot() public {
        StateGrowth.Growth memory growth =
            _grow(abi.encodeCall(toy.setByDelegatecall, (logic, 1, 5)), 0);
        _assertGrowth(growth, 1, 0);
        assertEq(growth.newSlots[0].account, address(toy));
        assertEq(logic.word(1), 0, "the logic's own storage is untouched");
    }

    function test_TransientStorageIsNeverASlot() public {
        _assertGrowth(_grow(abi.encodeCall(toy.useTransient, (1, 5)), 0), 0, 0);
    }

    // ------------------------------------------------------------------ accounts

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

    /// @dev An empty precompile that receives ETH becomes an account, like any address.
    function test_EthToAnEmptyPrecompileIsANewAccount() public {
        address identity = address(4);
        assertEq(identity.balance, 0);
        _assertGrowth(_grow(abi.encodeCall(toy.send, (identity, 1)), 1), 0, 1);
    }

    /// @dev The value the caller sends to an existing toy is a balance change, not new state.
    function test_ValueToTheTargetIsNotNew() public {
        _assertGrowth(_grow(abi.encodeCall(toy.send, (address(toy), 0)), 1), 0, 0);
    }

    // ------------------------------------------------------------------ cold accounts

    function test_ColdAccountsAreTheOnesReachedBeyondTheTarget() public {
        assertEq(_grow(abi.encodeCall(toy.set, (1, 5)), 0).coldAccounts.length, 0, "target only");

        address fresh = makeAddr("coldFresh");
        address[] memory cold = _grow(abi.encodeCall(toy.send, (fresh, 1)), 1).coldAccounts;
        assertEq(cold.length, 1);
        assertEq(cold[0], fresh);

        cold = _grow(abi.encodeCall(toy.setReenterClear, (1, callback)), 0).coldAccounts;
        assertEq(cold.length, 1, "the callback; the re-entered target is warm");
        assertEq(cold[0], address(callback));

        cold = _grow(abi.encodeCall(toy.setByDelegatecall, (logic, 1, 5)), 0).coldAccounts;
        assertEq(cold.length, 1);
        assertEq(cold[0], address(logic));
    }

    /// @dev An address the call touched before creating it paid the cold price at that touch.
    function test_AnAddressTouchedBeforeItsCreationIsCold() public {
        StateGrowth.Growth memory growth =
            _grow(abi.encodeCall(toy.createAfterCheck, (bytes32(uint256(1)))), 0);
        _assertGrowth(growth, 1, 1);
        assertEq(growth.coldAccounts.length, 1);
        assertEq(growth.coldAccounts[0], growth.newAccounts[0]);
    }

    function test_CreatedAccountsAndPrecompilesAreNotCold() public {
        assertEq(_grow(abi.encodeCall(toy.create, ()), 0).coldAccounts.length, 0, "created");
        assertEq(
            _grow(abi.encodeCall(toy.send, (address(4), 1)), 1).coldAccounts.length, 0, "precompile"
        );
    }
}
