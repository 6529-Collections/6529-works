// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { Vm, VmSafe } from "forge-std/Vm.sol";

/// @notice Handler self-test support: shows that each action of an invariant handler reaches the
///         contracts under test, so a campaign cannot pass because its actions return early or
///         always revert inside the handler. Each action is called many times with pseudo-random
///         arguments (word sizes mixed so `bool`, `uint8`, `uint16`, `uint32` and `address`
///         parameters decode; a call that reverts is retried with new arguments), and the state
///         diff of every call is read back:
///
///         - WRITES: a call changed a storage slot or the balance of a contract under test and
///           was not reverted;
///         - REFUSED: a call reached a contract under test and that contract reverted (the
///           adversarial actions, whose point is to be refused there);
///         - CLOCK: a call moved `block.timestamp` or `block.number`;
///         - CALLED: a call reached a contract under test and that call returned (for actions
///           whose point is to leave the contract unchanged, such as a sync of a complete work).
///
///         `check` asserts every action reached each outcome its expectation names at least once.
///         A handler action made to return early (or to stop calling the contract) fails it.
library HandlerReach {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint8 internal constant WRITES = 1;
    uint8 internal constant REFUSED = 2;
    uint8 internal constant CLOCK = 4;
    uint8 internal constant CALLED = 8;

    /// @dev One action and the outcomes it must reach.
    struct Expect {
        bytes4 selector;
        uint8 outcomes;
    }

    /// @dev What the calls to one action reached.
    struct Tally {
        uint256 ran;
        uint256 writes;
        uint256 refused;
        uint256 clock;
        uint256 called;
    }

    /// @notice Calls the expected actions of `handler` `rounds` times each, in a pseudo-random
    ///         order, and tallies what every call reached in the contracts `sut`.
    function drive(
        address handler,
        Expect[] memory expect,
        address[] memory sut,
        uint256 rounds,
        uint256 seed
    ) internal returns (Tally[] memory t) {
        t = new Tally[](expect.length);
        uint256 total = rounds * expect.length;
        for (uint256 i; i < total; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 k = r % expect.length;
            uint256 free;
            assembly ("memory-safe") {
                free := mload(0x40)
            }
            // A call whose arguments do not decode reverts in the handler: draw new ones.
            for (uint256 tries; tries < 16; ++tries) {
                bytes memory data = abi.encodePacked(expect[k].selector, _args(r, tries));
                if (_once(handler, data, sut, t[k])) break;
            }
            // Nothing allocated for the call outlives it; release it so a long drive does not
            // run out of gas on memory.
            assembly ("memory-safe") {
                mstore(0x40, free)
            }
        }
    }

    /// @notice Adds the tallies `b` into `a` (several campaign-length runs, each from the
    ///         suite's starting state, tallied together).
    function add(Tally[] memory a, Tally[] memory b) internal pure {
        for (uint256 k; k < a.length; ++k) {
            a[k].ran += b[k].ran;
            a[k].writes += b[k].writes;
            a[k].refused += b[k].refused;
            a[k].clock += b[k].clock;
            a[k].called += b[k].called;
        }
    }

    function _once(address handler, bytes memory data, address[] memory sut, Tally memory t)
        private
        returns (bool ok)
    {
        uint256 time = block.timestamp;
        uint256 number = block.number;
        VM.startStateDiffRecording();
        (ok,) = handler.call(data);
        VmSafe.AccountAccess[] memory diff = VM.stopAndReturnStateDiff();
        if (ok) {
            ++t.ran;
            (bool wrote, bool refused, bool called) = _scan(diff, sut);
            if (wrote) ++t.writes;
            if (refused) ++t.refused;
            if (called) ++t.called;
        }
        if (ok && (block.timestamp != time || block.number != number)) ++t.clock;
    }

    /// @notice Fails unless every action reached each outcome its expectation names. Logs each
    ///         action's tally first (`-vv`): selector, calls that ran, wrote, were refused.
    function check(Expect[] memory expect, Tally[] memory t) internal pure {
        for (uint256 k; k < expect.length; ++k) {
            console2.log(
                VM.toString(abi.encodePacked(expect[k].selector)),
                t[k].ran,
                t[k].writes,
                t[k].refused
            );
        }
        for (uint256 k; k < expect.length; ++k) {
            string memory name = VM.toString(abi.encodePacked(expect[k].selector));
            require(t[k].ran > 0, string.concat("HandlerReach: never ran ", name));
            uint8 o = expect[k].outcomes;
            if (o & WRITES != 0) {
                require(t[k].writes > 0, string.concat("HandlerReach: never wrote ", name));
            }
            if (o & REFUSED != 0) {
                require(t[k].refused > 0, string.concat("HandlerReach: never refused ", name));
            }
            if (o & CLOCK != 0) {
                require(t[k].clock > 0, string.concat("HandlerReach: never moved clock ", name));
            }
            if (o & CALLED != 0) {
                require(t[k].called > 0, string.concat("HandlerReach: never called ", name));
            }
        }
    }

    /// @notice Fails unless every selector the suite targets has an expectation.
    function covers(bytes4[] memory targeted, Expect[] memory expect) internal pure {
        for (uint256 i; i < targeted.length; ++i) {
            bool found;
            for (uint256 k; k < expect.length; ++k) {
                if (expect[k].selector == targeted[i]) found = true;
            }
            require(
                found,
                string.concat(
                    "HandlerReach: no expectation for ", VM.toString(abi.encodePacked(targeted[i]))
                )
            );
        }
    }

    function _scan(VmSafe.AccountAccess[] memory diff, address[] memory sut)
        private
        pure
        returns (bool wrote, bool refused, bool called)
    {
        for (uint256 i; i < diff.length; ++i) {
            VmSafe.AccountAccess memory a = diff[i];
            if (_in(a.account, sut)) {
                bool call = a.kind == VmSafe.AccountAccessKind.Call;
                if (call && a.reverted) refused = true;
                if (call && !a.reverted) called = true;
                if (!a.reverted && a.oldBalance != a.newBalance) wrote = true;
            }
            for (uint256 j; j < a.storageAccesses.length; ++j) {
                VmSafe.StorageAccess memory s = a.storageAccesses[j];
                if (
                    s.isWrite && !s.reverted && s.previousValue != s.newValue && _in(s.account, sut)
                ) wrote = true;
            }
        }
    }

    function _in(address account, address[] memory sut) private pure returns (bool) {
        for (uint256 i; i < sut.length; ++i) {
            if (sut[i] == account) return true;
        }
        return false;
    }

    /// @dev Eight argument words; each is a full word or is reduced to fit a `bool`, a `uint8`,
    ///      a `uint16` or a `uint32`, so every small-typed parameter decodes in some calls.
    function _args(uint256 r, uint256 attempt) private pure returns (bytes memory out) {
        out = new bytes(256);
        for (uint256 w; w < 8; ++w) {
            uint256 x = uint256(keccak256(abi.encode(r, attempt, w)));
            // Weights out of 10: full word 2, bool 3, uint8 3, uint16 1, uint32 1.
            uint256 mode = x % 10;
            x >>= 8;
            if (mode >= 2 && mode < 5) x %= 2;
            else if (mode >= 5 && mode < 8) x %= 256;
            else if (mode == 8) x %= 65_536;
            else if (mode == 9) x %= 1 << 32;
            assembly ("memory-safe") {
                mstore(add(add(out, 32), mul(w, 32)), x)
            }
        }
    }
}
