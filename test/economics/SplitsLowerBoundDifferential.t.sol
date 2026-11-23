// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";

/// @notice The calldata binary search `SplitLedger._payNetwork` used before the plain-code pass
///         (commit d730f736), kept only to compare against.
library OldPayNetworkSearch {
    function find(ISplitWallet.Payee[] calldata payees, address net)
        internal
        pure
        returns (uint256 i)
    {
        uint256 hi = payees.length;
        assembly ("memory-safe") {
            for { } lt(i, hi) { } {
                let mid := shr(1, add(i, hi))
                let at := add(payees.offset, mul(mid, 0x60))
                switch and(iszero(calldataload(at)), lt(calldataload(add(at, 0x20)), net))
                case 1 { i := add(mid, 1) }
                default { hi := mid }
            }
        }
    }
}

/// @notice Both searches on the same calldata.
contract SearchHarness {
    function oldFind(ISplitWallet.Payee[] calldata payees, address net)
        external
        pure
        returns (uint256)
    {
        return OldPayNetworkSearch.find(payees, net);
    }

    function newFind(ISplitWallet.Payee[] calldata payees, address net)
        external
        pure
        returns (uint256)
    {
        return Splits.lowerBound(payees, net);
    }

    function oldGas(ISplitWallet.Payee[] calldata payees, address net)
        external
        view
        returns (uint256 used)
    {
        uint256 start = gasleft();
        OldPayNetworkSearch.find(payees, net);
        used = start - gasleft();
    }

    function newGas(ISplitWallet.Payee[] calldata payees, address net)
        external
        view
        returns (uint256 used)
    {
        uint256 start = gasleft();
        Splits.lowerBound(payees, net);
        used = start - gasleft();
    }
}

/// @notice `Splits.lowerBound` (the plain search the split ledger now uses to find the network
///         fee vault after a release) answers exactly as the assembly search it replaced, on
///         canonical lists and on any other list, for any account looked for.
contract SplitsLowerBoundDifferentialTest is Test {
    SearchHarness internal h;

    function setUp() public {
        h = new SearchHarness();
    }

    /// A canonical list: `fixed` fixed payees with ascending accounts, then artist payees with
    /// ascending IDs.
    function _canonical(uint256 seed, uint256 count, uint256 fixedCount)
        internal
        pure
        returns (ISplitWallet.Payee[] memory payees)
    {
        payees = new ISplitWallet.Payee[](count);
        uint160 account;
        uint256 id;
        for (uint256 i; i < count; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            if (i < fixedCount) {
                account += uint160(1 + seed % 2 ** 150);
                payees[i] = ISplitWallet.Payee(0, address(account), 1);
            } else {
                id += 1 + seed % 2 ** 100;
                payees[i] = ISplitWallet.Payee(id, address(0), 1);
            }
        }
    }

    function testFuzz_SameAnswerOnCanonicalLists(
        uint256 seed,
        uint8 countSeed,
        uint8 fixedSeed,
        uint8 pick,
        bool present
    ) public view {
        uint256 count = bound(countSeed, 0, Splits.MAX_PAYEES);
        uint256 fixedCount = count == 0 ? 0 : bound(fixedSeed, 0, count);
        ISplitWallet.Payee[] memory payees = _canonical(seed, count, fixedCount);
        address net = address(uint160(uint256(keccak256(abi.encode(seed, "net")))));
        if (present && fixedCount != 0) net = payees[bound(pick, 0, fixedCount - 1)].account;
        assertEq(h.newFind(payees, net), h.oldFind(payees, net));
    }

    function testFuzz_SameAnswerOnAnyList(ISplitWallet.Payee[] calldata payees, address net)
        public
        view
    {
        vm.assume(payees.length <= 2 * Splits.MAX_PAYEES);
        assertEq(h.newFind(payees, net), h.oldFind(payees, net));
    }

    function test_EveryPositionOfTheNetwork() public view {
        for (uint256 count = 1; count <= Splits.MAX_PAYEES; ++count) {
            ISplitWallet.Payee[] memory payees = _canonical(count, count, count);
            for (uint256 at; at < count; ++at) {
                address net = payees[at].account;
                assertEq(h.newFind(payees, net), at);
                assertEq(h.oldFind(payees, net), at);
            }
        }
    }

    /// The worst case on the largest list: the plain search's gas, logged beside the old one's.
    function test_WorstCaseGas() public {
        ISplitWallet.Payee[] memory payees = _canonical(1, Splits.MAX_PAYEES, Splits.MAX_PAYEES);
        address net = address(type(uint160).max);
        uint256 oldUsed = h.oldGas(payees, net);
        uint256 newUsed = h.newGas(payees, net);
        emit log_named_uint("old search gas, 64 payees", oldUsed);
        emit log_named_uint("plain search gas, 64 payees", newUsed);
        assertLt(newUsed, 5_000, "a few thousand gas at most");
    }
}
