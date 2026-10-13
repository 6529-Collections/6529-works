// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm, VmSafe } from "forge-std/Vm.sol";

/// @notice The state a transaction creates, and the accounts it reaches, from a Foundry
///         state-diff recording (`vm.startStateDiffRecording` / `vm.stopAndReturnStateDiff`).
///         ADR 0004 caps the creation per operation, because Glamsterdam prices it far above
///         Prague and Foundry 1.7.1 can only measure Prague gas.
/// @dev The recording only names the candidates: every storage slot and every account the call
///      accessed. Whether each one is new is read from the state itself, before and after the
///      call, so the result does not depend on how Foundry orders or flags the recorded accesses
///      (a write in a frame that halted out of gas or on `INVALID` is undone even when the
///      recording does not mark it reverted).
///      - **New slot:** a slot that is zero before the call and non-zero after it. A slot
///        written several times counts once; a write that was undone, a zero-to-zero write and
///        an overwrite or clearing of a non-zero slot do not count. Transient storage is never
///        a slot.
///      - **New account:** an account that is empty before the call (no code, nonce zero,
///        balance zero) and not empty after it: a contract creation, or ETH sent to an empty
///        address (a precompile included, when it is empty). The sender is never new: a real
///        transaction's sender pays for it.
///      - **Cold accounts:** the accounts a real transaction would first reach cold under
///        EIP-2929. Every account the call reached, except its sender and target (warm from
///        the start), the precompiles 0x01 to 0x11, the cheatcode address, and the accounts the
///        call created (warmed by their creation).
///
///      Recording changes gas: Foundry reads each account and slot it records, and once a test
///      has recorded, every later account and slot access in that test is priced warm. Never
///      measure gas in or after a recording; measure first, then record from the same snapshot.
library StateGrowth {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint160 private constant LAST_PRECOMPILE = 0x11;

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
        address[] coldAccounts;
    }

    /// @notice What the recorded call created, and the accounts it reached cold.
    /// @param accesses The recording of exactly one call.
    /// @param preCall A state snapshot taken just before that call. The current state must be
    ///        the call's final state; it is restored before this returns.
    /// @param sender The transaction's sender.
    /// @param target The transaction's target.
    function count(
        Vm.AccountAccess[] memory accesses,
        uint256 preCall,
        address sender,
        address target
    ) internal returns (Growth memory growth) {
        (address[] memory slotAccounts, bytes32[] memory slots) = _candidateSlots(accesses);
        address[] memory accounts = _candidateAccounts(accesses);

        bytes32[] memory slotsAfter = new bytes32[](slots.length);
        bool[] memory existsAfter = new bool[](accounts.length);
        _read(slotAccounts, slots, accounts, slotsAfter, existsAfter);
        // The state before the call, then back to the state after it.
        uint256 postCall = VM.snapshotState();
        require(VM.revertToState(preCall), "StateGrowth: no pre-call snapshot");
        bytes32[] memory slotsBefore = new bytes32[](slots.length);
        bool[] memory existsBefore = new bool[](accounts.length);
        _read(slotAccounts, slots, accounts, slotsBefore, existsBefore);
        require(VM.revertToStateAndDelete(postCall), "StateGrowth: no post-call snapshot");

        growth.newSlots = new Slot[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            if (slotsBefore[i] == bytes32(0) && slotsAfter[i] != bytes32(0)) {
                growth.newSlots[growth.slots++] = Slot(slotAccounts[i], slots[i], slotsAfter[i]);
            }
        }
        _truncate(growth.newSlots, growth.slots);
        growth.newAccounts = new address[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            if (!existsBefore[i] && existsAfter[i] && accounts[i] != sender) {
                growth.newAccounts[growth.accounts++] = accounts[i];
            }
        }
        _truncate(growth.newAccounts, growth.accounts);
        growth.coldAccounts = _cold(accesses, accounts, sender, target);
    }

    // ------------------------------------------------------------------ candidates

    /// @dev Every distinct (account, slot) the recording accessed, reads included.
    function _candidateSlots(Vm.AccountAccess[] memory accesses)
        private
        pure
        returns (address[] memory accounts, bytes32[] memory slots)
    {
        uint256 total;
        for (uint256 i; i < accesses.length; ++i) {
            total += accesses[i].storageAccesses.length;
        }
        accounts = new address[](total);
        slots = new bytes32[](total);
        uint256 n;
        for (uint256 i; i < accesses.length; ++i) {
            Vm.StorageAccess[] memory sa = accesses[i].storageAccesses;
            for (uint256 j; j < sa.length; ++j) {
                bool known;
                for (uint256 k; k < n && !known; ++k) {
                    known = accounts[k] == sa[j].account && slots[k] == sa[j].slot;
                }
                if (known) continue;
                accounts[n] = sa[j].account;
                slots[n] = sa[j].slot;
                ++n;
            }
        }
        _truncate(accounts, n);
        _truncate(slots, n);
    }

    /// @dev Every distinct account the recording accessed, other than the cheatcode address.
    function _candidateAccounts(Vm.AccountAccess[] memory accesses)
        private
        pure
        returns (address[] memory accounts)
    {
        accounts = new address[](accesses.length);
        uint256 n;
        for (uint256 i; i < accesses.length; ++i) {
            address account = accesses[i].account;
            if (account == address(VM) || _contains(accounts, n, account)) continue;
            accounts[n++] = account;
        }
        _truncate(accounts, n);
    }

    /// @dev The candidates a real transaction reaches cold (EIP-2929).
    function _cold(
        Vm.AccountAccess[] memory accesses,
        address[] memory accounts,
        address sender,
        address target
    ) private pure returns (address[] memory cold) {
        cold = new address[](accounts.length);
        uint256 n;
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            if (account == sender || account == target) continue;
            if (uint160(account) != 0 && uint160(account) <= LAST_PRECOMPILE) continue;
            if (_created(accesses, account)) continue;
            cold[n++] = account;
        }
        _truncate(cold, n);
    }

    function _created(Vm.AccountAccess[] memory accesses, address account)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < accesses.length; ++i) {
            if (
                accesses[i].kind == VmSafe.AccountAccessKind.Create
                    && accesses[i].account == account
            ) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ state

    function _read(
        address[] memory slotAccounts,
        bytes32[] memory slots,
        address[] memory accounts,
        bytes32[] memory slotValues,
        bool[] memory exists
    ) private view {
        for (uint256 i; i < slots.length; ++i) {
            slotValues[i] = VM.load(slotAccounts[i], slots[i]);
        }
        for (uint256 i; i < accounts.length; ++i) {
            address a = accounts[i];
            exists[i] = a.code.length != 0 || a.balance != 0 || VM.getNonce(a) != 0;
        }
    }

    // ------------------------------------------------------------------ arrays

    function _contains(address[] memory list, uint256 n, address account)
        private
        pure
        returns (bool)
    {
        for (uint256 k; k < n; ++k) {
            if (list[k] == account) return true;
        }
        return false;
    }

    function _truncate(address[] memory list, uint256 n) private pure {
        assembly ("memory-safe") {
            mstore(list, n)
        }
    }

    function _truncate(bytes32[] memory list, uint256 n) private pure {
        assembly ("memory-safe") {
            mstore(list, n)
        }
    }

    function _truncate(Slot[] memory list, uint256 n) private pure {
        assembly ("memory-safe") {
            mstore(list, n)
        }
    }
}
