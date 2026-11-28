// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Vm, VmSafe } from "forge-std/Vm.sol";
import { StateGrowth } from "../helpers/StateGrowth.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Whole-transaction Prague gas and state growth of one call on the deployed stack, the
///         measurement every integration gas suite shares (ADR 0004, ADR 0010).
/// @dev Two measures per call:
///      - **Prague gas.** Foundry has no Glamsterdam EVM, so every figure is the gas the
///        transaction uses at Prague costs: 21,000 intrinsic, the calldata (EIP-2028, or the
///        EIP-7623 floor when higher) and the execution, before refunds. The execution is the
///        called frame's own gas (`vm.lastCallGas`) with every contract's storage cooled first,
///        plus 2,500 for each account a real transaction would reach cold but this test had
///        already touched: Foundry cannot cool accounts (`_measureGrowth`).
///      - **State growth.** The exact new storage slots and new accounts, counted by
///        `StateGrowth` from a state-diff recording.
///      Recording changes gas: once a test has recorded, every later account and slot access in
///      that test is priced warm. Every helper here measures first and records second, from one
///      snapshot; `_requireCooling` fails a measurement taken after a recording.
abstract contract GasBase is IntegrationBase {
    /// @dev EIP-2929: the first access to an account costs 2,600, a warm one 100.
    uint256 internal constant COLD_ACCOUNT_SURCHARGE = 2500;
    /// @dev ADR 0004: a metadata view fits 8M Prague gas.
    uint256 internal constant TOKEN_URI_BUDGET = 8_000_000;

    /// @dev Read by `_requireCooling`.
    uint256 private _coolProbe = 1;

    // ------------------------------------------------------------------ transaction gas

    /// @dev Calldata gas: the EIP-2028 price and the EIP-7623 floor.
    function _calldataGas(bytes memory data)
        internal
        pure
        returns (uint256 standard, uint256 floor)
    {
        uint256 zeros;
        for (uint256 i; i < data.length; ++i) {
            if (data[i] == 0) ++zeros;
        }
        uint256 nonzero = data.length - zeros;
        standard = zeros * 4 + nonzero * 16;
        floor = (zeros + nonzero * 4) * 10;
    }

    /// @dev The whole transaction: intrinsic, calldata (or its floor) and measured execution.
    function _txGas(bytes memory data, uint256 execution) internal pure returns (uint256 total) {
        (uint256 standard, uint256 floor) = _calldataGas(data);
        total = 21_000 + standard + execution;
        if (21_000 + floor > total) total = 21_000 + floor;
    }

    // ------------------------------------------------------------------ cooling

    /// @dev Every account whose storage `_coolAll` cools: every contract of the deployment and
    ///      the two mocked external systems. A suite that measures calls into other accounts
    ///      (split vaults) adds them.
    function _cooled() internal view virtual returns (address[] memory all) {
        address[36] memory list = [
            address(store),
            address(facts),
            address(directory),
            address(feeVault),
            address(museumVault),
            address(ledger),
            address(claimRouter),
            address(escrow),
            address(stream),
            address(editions),
            address(consolidation),
            address(accounts),
            address(allowlist),
            address(economics),
            address(verifier),
            address(registry),
            address(statements),
            address(entropy),
            address(dependencies),
            address(renderer),
            address(rules),
            address(delivery),
            address(terms),
            address(auction),
            address(editionLens),
            address(editionAuction),
            address(independentStream),
            deployment.independentStream721Deployer,
            deployment.independentStreamEditionsDeployer,
            deployment.independentEditionAuctionLens,
            deployment.independentEditionAuction,
            address(starter),
            address(manager),
            address(configurator),
            address(delegation),
            address(coordinator)
        ];
        all = new address[](list.length);
        uint256 n;
        for (uint256 i; i < list.length; ++i) {
            if (list[i] != address(0)) all[n++] = list[i];
        }
        assembly ("memory-safe") {
            mstore(all, n)
        }
    }

    /// @dev Cools the storage of every account in `_cooled`, as at the start of a new
    ///      transaction, and checks that cooling works. `vm.cool` cools storage slots but not
    ///      the accounts themselves: `_measureGrowth` adds the cold-account cost.
    function _coolAll() internal {
        address[] memory all = _cooled();
        for (uint256 i; i < all.length; ++i) {
            vm.cool(all[i]);
        }
        _requireCooling();
    }

    /// @dev Fails when `vm.cool` does not cool. Once a state-diff recording has run in a test,
    ///      Foundry prices every account and slot as warm for the rest of that test (even after a
    ///      state revert), so a later measurement would come out tens of thousands of gas low.
    ///      The probe is a word of this contract's own storage: cooled, its next read must cost
    ///      the cold price (2,100) again.
    function _requireCooling() internal {
        uint256 warmed = _coolProbe;
        vm.cool(address(this));
        uint256 before = gasleft();
        uint256 cooled = _coolProbe;
        uint256 used = before - gasleft();
        require(
            used > 2000 && warmed == cooled,
            "vm.cool did not cool: measure gas before any state-diff recording in the test"
        );
    }

    // ------------------------------------------------------------------ measuring

    /// @dev Calls `target` with `data` as `from` (and `value`) with every contract's storage
    ///      cooled, and returns the whole-transaction gas: 21,000, the calldata (or its EIP-7623
    ///      floor) and the called frame's own execution gas before refunds (`vm.lastCallGas`),
    ///      which is what a transaction to `target` executes: its target is warm and its value is
    ///      free. A revert bubbles up. The accounts the call reaches are priced as warm or cold as
    ///      this test left them; `_measureGrowth` corrects that.
    function _measure(address from, address target, bytes memory data, uint256 value)
        internal
        returns (uint256 total, uint256 execution)
    {
        vm.deal(from, from.balance + value);
        _coolAll();
        vm.prank(from);
        (bool ok, bytes memory reason) = target.call{ value: value }(data);
        execution = _lastCallGasUsed();
        _bubble(ok, reason);
        total = _txGas(data, execution);
    }

    /// @dev Which accounts of `_probeSet` are warm at this point of the test: an account the
    ///      test function touched earlier is warm, one touched only in `setUp` (a separate
    ///      transaction) or never is cold.
    struct Warmth {
        address[] accounts;
        bool[] warm;
    }

    /// @dev Every account a measured call may reach besides its sender and target, whose warmth
    ///      `_measureGrowth` probes: by default the contracts `_coolAll` cools and the vaults'
    ///      first destinations. A suite adds its actors and wallets. Computed from a snapshot, so
    ///      the calls it makes warm nothing.
    function _probeSet() internal virtual returns (address[] memory accounts_) {
        address[] memory cooled = _cooled();
        accounts_ = new address[](cooled.length + 2);
        for (uint256 i; i < cooled.length; ++i) {
            accounts_[i] = cooled[i];
        }
        accounts_[cooled.length] = feeSafe;
        accounts_[cooled.length + 1] = museumSafe;
    }

    /// @dev Probes the warmth of every account in `_probeSet`, then restores the state (and with
    ///      it the warmth). Must run before any state-diff recording in the test.
    function _warmth() internal returns (Warmth memory w) {
        uint256 snapshot = vm.snapshotState();
        w.accounts = _probeSet();
        vm.revertToState(snapshot);
        w.warm = new bool[](w.accounts.length);
        for (uint256 i; i < w.accounts.length; ++i) {
            w.warm[i] = _isWarm(w.accounts[i]);
        }
        vm.revertToStateAndDelete(snapshot);
    }

    /// @dev Whether `account` is warm: its first `EXTCODESIZE` costs 100, not 2,600.
    function _isWarm(address account) internal view returns (bool) {
        uint256 size;
        uint256 before = gasleft();
        assembly ("memory-safe") {
            size := extcodesize(account)
        }
        uint256 used = before - gasleft();
        return used < 1000 && size != type(uint256).max;
    }

    /// @dev How many of `cold` (the accounts a real transaction reaches cold) the measured run
    ///      priced warm. Each must have been probed, so none is counted twice or missed.
    function _warmButCold(Warmth memory w, address[] memory cold)
        internal
        view
        returns (uint256 n)
    {
        for (uint256 i; i < cold.length; ++i) {
            uint256 k;
            while (k < w.accounts.length && w.accounts[k] != cold[i]) ++k;
            if (k == w.accounts.length) {
                revert(
                    string.concat(
                        "the call reached an account _probeSet does not probe: ",
                        vm.getLabel(cold[i])
                    )
                );
            }
            if (w.warm[k]) ++n;
        }
    }

    /// @dev The Prague gas of a real transaction, and the state it creates (ADR 0004).
    ///      - **Gas:** `_measure`, plus 2,500 for each account that a real transaction reaches
    ///        cold (`StateGrowth`'s cold accounts) but the measured run reached warm.
    ///      - **Growth:** the new storage slots and new accounts, counted by `StateGrowth`.
    ///      The call runs twice from one snapshot: measured first, then recorded. The recorded
    ///      run's state, the same as the measured run's, is the one that remains.
    function _measureGrowth(address from, address target, bytes memory data, uint256 value)
        internal
        returns (uint256 total, uint256 execution, StateGrowth.Growth memory growth)
    {
        Warmth memory w = _warmth();
        uint256 preCall = vm.snapshotState();
        (, execution) = _measure(from, target, data, value);
        vm.revertToStateAndDelete(preCall);
        growth = _growth(from, target, data, value);
        execution += COLD_ACCOUNT_SURCHARGE * _warmButCold(w, growth.coldAccounts);
        total = _txGas(data, execution);
    }

    /// @dev The state growth and cold accounts of calling `target` with `data` as `from` (and
    ///      `value`), from a state diff recorded around the call alone. A revert bubbles up.
    ///      Checks that every account whose storage the call reached is one `_coolAll` cools, so
    ///      no measured slot was left warm.
    function _growth(address from, address target, bytes memory data, uint256 value)
        internal
        returns (StateGrowth.Growth memory growth)
    {
        vm.deal(from, from.balance + value);
        uint256 preCall = vm.snapshotState();
        vm.prank(from);
        vm.startStateDiffRecording();
        (bool ok, bytes memory reason) = target.call{ value: value }(data);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        _bubble(ok, reason);
        _requireCooled(accesses);
        growth = StateGrowth.count(accesses, preCall, from, target);
        vm.deleteStateSnapshot(preCall);
    }

    /// @dev Every account whose storage the recorded call reached is cooled by `_coolAll`, or
    ///      was created by the call (its storage starts cold).
    function _requireCooled(Vm.AccountAccess[] memory accesses) internal view {
        address[] memory cooled = _cooled();
        for (uint256 i; i < accesses.length; ++i) {
            Vm.StorageAccess[] memory sa = accesses[i].storageAccesses;
            for (uint256 j; j < sa.length; ++j) {
                if (_listed(cooled, sa[j].account) || _createdBy(accesses, sa[j].account)) {
                    continue;
                }
                revert(
                    string.concat(
                        "measured storage that _coolAll does not cool: ", vm.toString(sa[j].account)
                    )
                );
            }
        }
    }

    function _listed(address[] memory list, address account) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == account) return true;
        }
        return false;
    }

    function _createdBy(Vm.AccountAccess[] memory accesses, address account)
        internal
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

    /// @dev `vm.lastCallGas().gasTotalUsed`, read by hand: the pinned forge-std declares a sixth
    ///      `Gas` field (`gasStateUsed`) that Foundry 1.7.1 does not return yet, so the typed call
    ///      fails to decode. The layout is checked, so a drift fails instead of reading the wrong
    ///      field: five or six words, a used gas below the frame's limit and the cap, and
    ///      limit = used + remaining.
    function _lastCallGasUsed() internal view returns (uint256 used) {
        (bool ok, bytes memory ret) =
            address(vm).staticcall(abi.encodeWithSignature("lastCallGas()"));
        require(ok && (ret.length == 160 || ret.length == 192), "lastCallGas: layout");
        uint256 limit;
        uint256 remaining;
        assembly ("memory-safe") {
            limit := mload(add(ret, 0x20))
            used := mload(add(ret, 0x40))
            remaining := mload(add(ret, 0xa0))
        }
        require(used != 0 && used < TX_GAS_CAP && limit == used + remaining, "lastCallGas: values");
    }
}
