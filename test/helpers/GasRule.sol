// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";

/// @notice A dependency whose every call costs a configurable multiple of a base cost: it burns
///         `base * multiple` gas, then forwards the call to `inner` (a real contract or a mock)
///         and returns or reverts with exactly what `inner` returned. Wrap any dependency of a
///         permanent contract in one to stress that contract's gas rule (BoundedCall,
///         `docs/spec/README.md`): the answer must not change with the multiple, and running
///         short must revert with `BoundedCall.BoundedCallShortfall`, never yield an answer.
/// @dev When fewer than `base * multiple` gas are left, the burn runs out of gas for real (an
///      `invalid` opcode consumes everything), exactly like an honest callee that ran short.
///      Calls are forwarded with STATICCALL, so the wrapper works in a view; call
///      {burnerSetMutating} for a dependency whose calls write state. `inner` sees the burner as
///      `msg.sender`. The admin functions carry a `burner` prefix so that no wrapped interface
///      shares their selectors. Test code only: production contracts never wrap dependencies.
contract Burner {
    address public burnerInner;
    uint256 public burnerBase;
    uint256 public burnerMultiple = 1;
    bool public burnerMutating;

    constructor(address inner, uint256 base) {
        burnerInner = inner;
        burnerBase = base;
    }

    function burnerSetMultiple(uint256 multiple) external {
        burnerMultiple = multiple;
    }

    function burnerSetBase(uint256 base) external {
        burnerBase = base;
    }

    function burnerSetMutating(bool mutating) external {
        burnerMutating = mutating;
    }

    fallback() external payable {
        _burnAndForward();
    }

    /// @dev A plain ETH transfer is burned and forwarded too (a payee costing more).
    receive() external payable {
        _burnAndForward();
    }

    function _burnAndForward() private {
        uint256 amount = burnerBase * burnerMultiple;
        if (gasleft() < amount) {
            assembly ("memory-safe") {
                invalid()
            }
        }
        uint256 stop = gasleft() - amount;
        while (gasleft() > stop) { }
        address inner = burnerInner;
        bool mutating = burnerMutating;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok
            switch mutating
            case 0 { ok := staticcall(gas(), inner, 0, calldatasize(), 0, 0) }
            default { ok := call(gas(), inner, callvalue(), 0, calldatasize(), 0, 0) }
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

/// @notice Assertions of the gas rule for tests that wrap a dependency in a {Burner}:
///         - {_assertSameAtEveryMultiple}: with ample gas, the dependency costing 1x, 2x, 4x, 10x
///           and 100x its base gives byte-for-byte the same outcome (success or revert data);
///         - {_assertShortfallNeverAnswers}: across gas limits from far below to the least that
///           reproduces the ample-gas outcome, every call gives that outcome, the dedicated
///           shortfall error `BoundedCall.BoundedCallShortfall(burner)`, or an out-of-gas of the
///           caller itself (empty revert data), never any other answer, and at least one limit
///           gives the shortfall error.
///         Each call runs on a state snapshot that is restored after it, so state-changing calls
///         can be compared too.
/// @dev Usage: `Burner b = new Burner(address(dependency), 10_000);` wire `b` where the contract
///      under test expects the dependency, then call both assertions with the calldata of the
///      operation that reaches it. Name the tests `test_GasRule_*`.
abstract contract GasRuleAssertions is Test {
    /// @notice The multiples of the base cost every site is stressed at.
    uint256[5] internal gasRuleMultiples = [uint256(1), 2, 4, 10, 100];

    /// @notice How many gas limits {_assertShortfallNeverAnswers} tries below the least passing
    ///         limit.
    uint256 internal constant GAS_RULE_SAMPLES = 48;

    struct Outcome {
        bool ok;
        bytes data;
    }

    /// @notice The revert data of a shortfall at `target`.
    function _shortfall(address target) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, target);
    }

    /// @notice Calls `target` with `data` from `from` with at most `gasLimit` gas (zero: all the
    ///         gas the test has) and restores the state afterwards.
    function _try(address from, address target, bytes memory data, uint256 gasLimit)
        internal
        returns (Outcome memory o)
    {
        uint256 snapshot = vm.snapshotState();
        vm.prank(from);
        if (gasLimit == 0) (o.ok, o.data) = target.call(data);
        else (o.ok, o.data) = target.call{ gas: gasLimit }(data);
        vm.revertToState(snapshot);
    }

    /// @notice With ample gas, every multiple of `burner`'s base gives the 1x outcome. Returns it,
    ///         for the caller to check what it is. Leaves `burner` at 1x.
    function _assertSameAtEveryMultiple(
        Burner burner,
        address from,
        address target,
        bytes memory data
    ) internal returns (Outcome memory first) {
        for (uint256 i; i < gasRuleMultiples.length; ++i) {
            burner.burnerSetMultiple(gasRuleMultiples[i]);
            Outcome memory o = _try(from, target, data, 0);
            if (i == 0) {
                first = o;
                continue;
            }
            string memory label = string.concat(vm.toString(gasRuleMultiples[i]), "x the base cost");
            assertEq(o.ok, first.ok, label);
            assertEq(o.data, first.data, label);
        }
        burner.burnerSetMultiple(1);
    }

    /// @notice At `burner`'s current multiple: every gas limit from far below to the least that
    ///         gives the ample-gas outcome gives that outcome, `BoundedCallShortfall(burner)` or
    ///         an empty revert (the caller's own out-of-gas), and at least one gives the
    ///         shortfall error. Returns the ample-gas outcome and the least passing limit.
    function _assertShortfallNeverAnswers(
        Burner burner,
        address from,
        address target,
        bytes memory data
    ) internal returns (Outcome memory full, uint256 least) {
        full = _try(from, target, data, 0);
        least = _leastPassingGas(from, target, data, full);
        bytes memory shortfall = _shortfall(address(burner));
        uint256 shortfalls;
        for (uint256 i = 1; i <= GAS_RULE_SAMPLES; ++i) {
            // From 1/8 of the least passing limit up to one below it, denser near the top.
            uint256 g = least - (least * i * i) / (GAS_RULE_SAMPLES * GAS_RULE_SAMPLES * 8 / 7);
            if (g >= least) g = least - 1;
            Outcome memory o = _try(from, target, data, g);
            if (o.ok == full.ok && keccak256(o.data) == keccak256(full.data)) continue;
            assertFalse(o.ok, string.concat("a different answer at gas ", vm.toString(g)));
            if (keccak256(o.data) == keccak256(shortfall)) {
                ++shortfalls;
                continue;
            }
            assertEq(o.data.length, 0, string.concat("a different refusal at gas ", vm.toString(g)));
        }
        assertGt(shortfalls, 0, "no gas limit produced the shortfall error");
    }

    /// @dev The least gas limit that gives `full`, by bisection (outcomes are monotonic in the
    ///      limit for these call paths once it is high enough).
    function _leastPassingGas(address from, address target, bytes memory data, Outcome memory full)
        private
        returns (uint256)
    {
        uint256 low = 0;
        uint256 high = 30_000_000;
        Outcome memory top = _try(from, target, data, high);
        assertEq(keccak256(top.data), keccak256(full.data), "30M gas reproduces the outcome");
        while (low + 1 < high) {
            uint256 mid = (low + high) / 2;
            Outcome memory o = _try(from, target, data, mid);
            if (o.ok == full.ok && keccak256(o.data) == keccak256(full.data)) high = mid;
            else low = mid;
        }
        return high;
    }
}
