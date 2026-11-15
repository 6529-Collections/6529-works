// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import {
    ReturnDataMock,
    GasBurnerMock,
    ReturnBombMock,
    Erc165Shapes
} from "../mocks/libraries/AdversarialTargets.sol";

/// @dev Exposes the forward-all family and its users as external functions.
contract ForwardAllHarness {
    function tryReadAll(address target, bytes calldata input, uint256 maxReturn)
        external
        view
        returns (bool, bytes memory)
    {
        return BoundedCall.tryReadAll(target, input, maxReturn);
    }

    function tryCallAll(address target, uint256 value, bytes calldata input, uint256 maxReturn)
        external
        returns (bool, bytes memory)
    {
        return BoundedCall.tryCallAll(target, value, input, maxReturn);
    }

    function tryReadWordAll(address target, bytes calldata input)
        external
        view
        returns (bool, bytes32)
    {
        return BoundedCall.tryReadWordAll(target, input);
    }

    function supportsERC165(address account) external view returns (bool) {
        return BoundedCall.supportsERC165(account);
    }

    function supportsInterface(address account, bytes4 id) external view returns (bool) {
        return BoundedCall.supportsInterface(account, id);
    }

    function supportsInterfaceUnchecked(address account, bytes4 id) external view returns (bool) {
        return BoundedCall.supportsInterfaceUnchecked(account, id);
    }

    function ozSupportsERC165(address account) external view returns (bool) {
        return ERC165Checker.supportsERC165(account);
    }

    function ozSupportsInterface(address account, bytes4 id) external view returns (bool) {
        return ERC165Checker.supportsInterface(account, id);
    }

    function ozSupportsInterfaceUnchecked(address account, bytes4 id) external view returns (bool) {
        return ERC165Checker.supportsERC165InterfaceUnchecked(account, id);
    }

    receive() external payable { }
}

/// @dev Burns `numerator / denominator` of the gas it receives, then reverts with one word.
contract FractionBurner {
    uint256 internal immutable numerator;
    uint256 internal immutable denominator;

    constructor(uint256 numerator_, uint256 denominator_) {
        numerator = numerator_;
        denominator = denominator_;
    }

    fallback() external {
        uint256 stop = gasleft() - (gasleft() * numerator) / denominator;
        while (gasleft() > stop) { }
        assembly ("memory-safe") {
            mstore(0, 0xdead)
            revert(0, 32)
        }
    }
}

/// @dev Forwards every call with all the gas it may to `next` and bubbles its result: one more
///      frame between a caller and whatever runs out of gas.
contract Forwarder {
    address internal immutable next;

    constructor(address next_) {
        next = next_;
    }

    fallback() external {
        address to = next;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := staticcall(gas(), to, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

/// @notice The forward-all family of `BoundedCall` (the gas rule): the three outcomes, the 1/8
///         threshold and its depth, bounded return data and ERC-165 equivalence with
///         OpenZeppelin. The library users are stressed in `GasRuleLibraries.t.sol`.
contract BoundedCallForwardAllTest is Test {
    ForwardAllHarness internal harness;
    ReturnDataMock internal target;

    function setUp() public {
        harness = new ForwardAllHarness();
        target = new ReturnDataMock();
    }

    function _shortfallOf(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, who);
    }

    // ---------------------------------------------------------------- outcomes

    function test_TryReadAll_AnswerRefusalAndOversize() public {
        target.configure(hex"0102", false);
        (bool ok, bytes memory data) = harness.tryReadAll(address(target), "", 2);
        assertTrue(ok);
        assertEq(data, hex"0102");

        // One byte more than the cap: a refusal, nothing copied.
        (ok, data) = harness.tryReadAll(address(target), "", 1);
        assertFalse(ok);
        assertEq(data.length, 0);

        // A revert with plenty of gas left: a refusal carrying its revert data when it fits.
        target.configure(hex"cafe", true);
        (ok, data) = harness.tryReadAll(address(target), "", 2);
        assertFalse(ok);
        assertEq(data, hex"cafe");
        (ok, data) = harness.tryReadAll(address(target), "", 1);
        assertFalse(ok);
        assertEq(data.length, 0);

        // No code: the EVM's empty success; callers judge the shape.
        (ok, data) = harness.tryReadAll(address(0xC0DE), "", 32);
        assertTrue(ok);
        assertEq(data.length, 0);
    }

    function test_TryReadWordAll_OnlyExactlyOneWordIsAnAnswer() public {
        bytes[5] memory wrong =
            [bytes(""), new bytes(31), new bytes(33), new bytes(64), abi.encodePacked(uint8(1))];
        for (uint256 i; i < wrong.length; ++i) {
            target.configure(wrong[i], false);
            (bool ok, bytes32 word) = harness.tryReadWordAll(address(target), "");
            assertFalse(ok);
            assertEq(word, 0);
        }
        target.configure(abi.encode(uint256(7)), false);
        (bool good, bytes32 answer) = harness.tryReadWordAll(address(target), "");
        assertTrue(good);
        assertEq(uint256(answer), 7);
        target.configure(abi.encode(uint256(7)), true);
        (good, answer) = harness.tryReadWordAll(address(target), "");
        assertFalse(good, "a reverted word is a refusal");
        assertEq(answer, 0);
    }

    function test_TryCallAll_SendsValueAndRefusesWhatItCannotPay() public {
        vm.deal(address(harness), 1 ether);
        address payee = makeAddr("payee");
        (bool ok, bytes memory data) = harness.tryCallAll(payee, 0.4 ether, "", 0);
        assertTrue(ok);
        assertEq(data.length, 0);
        assertEq(payee.balance, 0.4 ether);
        // More than the balance fails at once with the gas unspent: a refusal, at any limit.
        (ok,) = harness.tryCallAll{ gas: 100_000 }(payee, 2 ether, "", 0);
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- shortfall

    /// @dev A callee that runs out of gas is a shortfall at every gas limit, for every form.
    function test_Shortfall_EveryFormRevertsWithTheDedicatedError() public {
        GasBurnerMock burner = new GasBurnerMock();
        uint256[4] memory limits = [uint256(50_000), 300_000, 3_000_000, 30_000_000];
        for (uint256 i; i < limits.length; ++i) {
            vm.expectRevert(_shortfallOf(address(burner)));
            harness.tryReadAll{ gas: limits[i] }(address(burner), "", 32);
            vm.expectRevert(_shortfallOf(address(burner)));
            harness.tryReadWordAll{ gas: limits[i] }(address(burner), "");
            vm.expectRevert(_shortfallOf(address(burner)));
            harness.tryCallAll{ gas: limits[i] }(address(burner), 0, "", 32);
            vm.expectRevert(_shortfallOf(address(burner)));
            harness.supportsInterface{ gas: limits[i] }(address(burner), 0x12345678);
        }
    }

    /// @dev Where OpenZeppelin's 30,000-gas probe answers "not supported" for a callee that runs
    ///      out of gas, the forward-all probe reverts.
    function test_Shortfall_Erc165NeverReadsAsNotSupported() public {
        GasBurnerMock burner = new GasBurnerMock();
        assertFalse(harness.ozSupportsInterface{ gas: 1_000_000 }(address(burner), 0x12345678));
        vm.expectRevert(_shortfallOf(address(burner)));
        harness.supportsERC165{ gas: 1_000_000 }(address(burner));
        vm.expectRevert(_shortfallOf(address(burner)));
        harness.supportsInterfaceUnchecked{ gas: 1_000_000 }(address(burner), 0x12345678);
    }

    /// @dev The threshold is 1/8 of the gas held before the call: a callee that burns 80% of
    ///      what it gets and reverts has refused; one that burns 95% (leaving about 6% with the
    ///      retained 1/64) reads as a shortfall, so its caller retries with more gas.
    function test_Shortfall_ThresholdIsOneEighthOfTheGasBefore() public {
        FractionBurner mostly = new FractionBurner(80, 100);
        (bool ok, bytes memory data) = harness.tryReadAll{ gas: 2_000_000 }(address(mostly), "", 32);
        assertFalse(ok);
        assertEq(abi.decode(data, (uint256)), 0xdead);

        FractionBurner nearly = new FractionBurner(95, 100);
        vm.expectRevert(_shortfallOf(address(nearly)));
        harness.tryReadAll{ gas: 2_000_000 }(address(nearly), "", 32);
    }

    /// @dev An out-of-gas up to eight frames below the caller, each forwarding all it may and
    ///      bubbling the failure, still reads as a shortfall, not a refusal.
    function test_Shortfall_DetectedThroughEightNestedFrames() public {
        address next = address(new GasBurnerMock());
        for (uint256 depth = 1; depth <= 8; ++depth) {
            vm.expectRevert(_shortfallOf(next));
            harness.tryReadAll{ gas: 5_000_000 }(next, "", 32);
            vm.expectRevert(_shortfallOf(next));
            harness.tryReadWordAll{ gas: 5_000_000 }(next, "");
            next = address(new Forwarder(next));
        }
    }

    /// @dev Return data is never copied beyond the cap: a 96 KB answer whose first word would be
    ///      accepted is refused, and the caller pays only for the callee's own memory.
    function test_ReturnData_IsCopiedOnlyUpToTheCap() public {
        ReturnBombMock bomb = new ReturnBombMock(96 * 1024, bytes32(uint256(1)));
        uint256 before = gasleft();
        (bool ok, bytes memory data) = harness.tryReadAll(address(bomb), "", 32);
        assertLt(before - gasleft(), 60_000, "nothing copied");
        assertFalse(ok);
        assertEq(data.length, 0);
        (bool word,) = harness.tryReadWordAll(address(bomb), "");
        assertFalse(word);
        // OpenZeppelin's probe semantics: at least one word, non-zero first word.
        assertTrue(harness.supportsInterfaceUnchecked(address(bomb), 0x12345678));
    }

    // ---------------------------------------------------------------- ERC-165 equivalence

    function test_Erc165_SameAnswersAsOpenZeppelinForEveryShape() public {
        bytes4 declared = 0x12345678;
        bytes4[3] memory ids = [declared, bytes4(0x87654321), type(IERC165).interfaceId];
        address[] memory accounts = new address[](9);
        for (uint256 s; s < 7; ++s) {
            accounts[s] = address(new Erc165Shapes(Erc165Shapes.Shape(s), declared));
        }
        accounts[7] = makeAddr("no code");
        accounts[8] = address(target); // returns its configured empty answer to everything
        for (uint256 a; a < accounts.length; ++a) {
            string memory which = vm.toString(a);
            assertEq(
                harness.supportsERC165(accounts[a]), harness.ozSupportsERC165(accounts[a]), which
            );
            for (uint256 i; i < ids.length; ++i) {
                assertEq(
                    harness.supportsInterface(accounts[a], ids[i]),
                    harness.ozSupportsInterface(accounts[a], ids[i]),
                    which
                );
                assertEq(
                    harness.supportsInterfaceUnchecked(accounts[a], ids[i]),
                    harness.ozSupportsInterfaceUnchecked(accounts[a], ids[i]),
                    which
                );
            }
        }
    }
}
