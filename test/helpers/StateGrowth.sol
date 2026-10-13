// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm, VmSafe } from "forge-std/Vm.sol";

/// @notice The state a transaction creates, counted from a Foundry state-diff recording
///         (`vm.startStateDiffRecording` / `vm.stopAndReturnStateDiff`). ADR 0004 caps these
///         counts per operation, because Glamsterdam prices state creation far above Prague and
///         Foundry 1.7.1 can only measure Prague gas.
/// @dev Definitions:
///      - **New slot:** a storage slot whose value was zero when the recording started and is
///        non-zero at the end. Each slot counts once, however many times it is written. A write
///        that a revert undid does not count, and neither does a slot written from zero and
///        cleared again (zero to zero), or a non-zero slot that was overwritten or cleared.
///      - **New account:** an account that was empty when first touched (no code, nonce zero,
///        balance zero) and is not empty at the end: a contract creation, or ETH sent to a fresh
///        address. Calls that leave an account empty (a precompile, a zero-value call, a value
///        transfer that reverted) do not count.
///
///      Call `count` right after `vm.stopAndReturnStateDiff()`, before anything else changes
///      state: it checks every slot's computed final value against `vm.load`, so a change in how
///      Foundry orders or flags the recorded accesses fails loudly instead of miscounting.
///
///      Recording changes gas: Foundry reads each account and slot it records, which warms it
///      before the opcode pays for it. Never measure gas in a recorded run; count the growth in
///      one run and measure the gas in another from the same snapshot.
library StateGrowth {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev A storage slot written from zero, with its final value.
    struct Slot {
        address account;
        bytes32 slot;
        bytes32 value;
    }

    struct Growth {
        uint256 slots;
        uint256 accounts;
        Slot[] newSlots;
        address[] newAccounts;
    }

    /// @dev One distinct storage slot seen in the recording.
    struct SlotState {
        address account;
        bytes32 slot;
        bytes32 initial;
        bytes32 last;
    }

    /// @notice The new slots and new accounts in `accesses`, counted and listed.
    function count(Vm.AccountAccess[] memory accesses)
        internal
        view
        returns (Growth memory growth)
    {
        growth.newSlots = newSlots(accesses);
        growth.newAccounts = newAccounts(accesses);
        growth.slots = growth.newSlots.length;
        growth.accounts = growth.newAccounts.length;
    }

    /// @notice Storage slots that went from zero to non-zero.
    function newSlots(Vm.AccountAccess[] memory accesses)
        internal
        view
        returns (Slot[] memory found)
    {
        SlotState[] memory seen = new SlotState[](_storageAccessCount(accesses));
        uint256 distinct;
        // The recording is chronological: a call's accesses follow its caller's earlier ones,
        // and a `Resume` entry carries the caller's accesses after the call returns.
        for (uint256 i; i < accesses.length; ++i) {
            Vm.StorageAccess[] memory sa = accesses[i].storageAccesses;
            for (uint256 j; j < sa.length; ++j) {
                uint256 k = _find(seen, distinct, sa[j].account, sa[j].slot);
                if (k == distinct) {
                    // First touch: its previous value is the value before the transaction.
                    seen[k] = SlotState(
                        sa[j].account, sa[j].slot, sa[j].previousValue, sa[j].previousValue
                    );
                    ++distinct;
                }
                // A write in a frame that reverted (or whose caller reverted) was undone.
                if (sa[j].isWrite && !sa[j].reverted) seen[k].last = sa[j].newValue;
            }
        }
        found = new Slot[](distinct);
        uint256 n;
        for (uint256 k; k < distinct; ++k) {
            require(
                seen[k].last == VM.load(seen[k].account, seen[k].slot),
                "StateGrowth: recorded diff disagrees with state"
            );
            if (seen[k].initial == bytes32(0) && seen[k].last != bytes32(0)) {
                found[n++] = Slot(seen[k].account, seen[k].slot, seen[k].last);
            }
        }
        assembly ("memory-safe") {
            mstore(found, n)
        }
    }

    /// @notice Accounts that were empty when first touched and are not empty now.
    function newAccounts(Vm.AccountAccess[] memory accesses)
        internal
        view
        returns (address[] memory found)
    {
        address[] memory seen = new address[](accesses.length);
        found = new address[](accesses.length);
        uint256 distinct;
        uint256 n;
        for (uint256 i; i < accesses.length; ++i) {
            address account = accesses[i].account;
            bool known;
            for (uint256 k; k < distinct && !known; ++k) {
                known = seen[k] == account;
            }
            if (known) continue;
            seen[distinct++] = account;
            if (_emptyBefore(accesses[i]) && !_empty(account)) found[n++] = account;
        }
        assembly ("memory-safe") {
            mstore(found, n)
        }
    }

    /// @dev Whether the account was empty before this access. Foundry 1.7.1 reports a created
    ///      account as `initialized` (it reads it after the creation), so a creation is judged by
    ///      the nonce and balance it had before: a CREATE cannot land on code.
    function _emptyBefore(Vm.AccountAccess memory access) private pure returns (bool) {
        if (access.kind == VmSafe.AccountAccessKind.Create) {
            return access.oldNonce == 0 && access.oldBalance == 0;
        }
        return !access.initialized;
    }

    function _empty(address account) private view returns (bool) {
        return account.code.length == 0 && account.balance == 0 && VM.getNonce(account) == 0;
    }

    function _storageAccessCount(Vm.AccountAccess[] memory accesses)
        private
        pure
        returns (uint256 total)
    {
        for (uint256 i; i < accesses.length; ++i) {
            total += accesses[i].storageAccesses.length;
        }
    }

    function _find(SlotState[] memory seen, uint256 distinct, address account, bytes32 slot)
        private
        pure
        returns (uint256 k)
    {
        for (; k < distinct; ++k) {
            if (seen[k].account == account && seen[k].slot == slot) return k;
        }
    }
}
