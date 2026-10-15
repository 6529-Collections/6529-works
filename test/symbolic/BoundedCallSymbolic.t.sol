// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";

/// @dev Returns exactly `size` bytes, each 32-byte word of them `fill`, or reverts with them.
contract SizedReturn {
    uint256 internal immutable size;
    bytes32 internal immutable fill;
    bool internal immutable reverts;

    constructor(uint256 size_, bytes32 fill_, bool reverts_) {
        size = size_;
        fill = fill_;
        reverts = reverts_;
    }

    fallback() external {
        uint256 n = size;
        bytes32 w = fill;
        bool r = reverts;
        assembly ("memory-safe") {
            for { let i := 0 } lt(i, n) { i := add(i, 32) } { mstore(i, w) }
            if r { revert(0, n) }
            return(0, n)
        }
    }
}

/// @notice Halmos proofs for `BoundedCall` (docs/testing/README.md, "Symbolic").
/// @dev The gas rule is proved total: it never reverts, for every 256-bit input. Its exact
///      value (`available >= gasLimit + ceil(gasLimit / 63) + buffer`) is not proved here: the
///      solver does not decide the division by 63 within the CI budget, even for 64-bit gas
///      amounts, so the boundary unit tests in test/libraries/BoundedCall.t.sol cover it.
///      Return-size handling is proved for every `maxReturn` and every returned content, over
///      an enumerated set of return sizes around the word boundaries. `decodeString` is proved
///      for every content of buffers of 64 to 128 bytes, which covers string lengths 0 to 64
///      with every padding shape.
contract BoundedCallSymbolicTest is Test {
    // ---------------------------------------------------------------- gas rule

    /// @notice No input overflows or reverts: the rule is total over every 256-bit input.
    function check_hasSufficientGas_neverReverts(
        uint256 available,
        uint256 gasLimit,
        uint256 buffer
    ) public view {
        try this.hasSufficientGas(available, gasLimit, buffer) { }
        catch {
            assert(false);
        }
    }

    function hasSufficientGas(uint256 available, uint256 gasLimit, uint256 buffer)
        external
        pure
        returns (bool)
    {
        return BoundedCall.hasSufficientGas(available, gasLimit, buffer);
    }

    // ---------------------------------------------------------------- return size

    function _sizes() internal pure returns (uint256[9] memory) {
        return [uint256(0), 1, 31, 32, 33, 63, 64, 65, 96];
    }

    /// @notice A target that returns `size` bytes is read in full exactly when `size` is at most
    ///         `maxReturn`; otherwise nothing is copied and the read reports failure. Every
    ///         content, `maxReturn` and gas limit, for each size in `_sizes`.
    function check_tryRead_copiesOnlyWhatFits(
        bytes32 fill,
        uint256 maxReturn,
        uint256 gasLimit,
        uint8 pick
    ) public {
        uint256[9] memory sizes = _sizes();
        vm.assume(pick < sizes.length);
        // One path per size: the size must be concrete, so it is chosen by branching.
        for (uint256 i; i < sizes.length; ++i) {
            if (pick != i) continue;
            address target = address(new SizedReturn(sizes[i], fill, false));
            (bool ok, bytes memory result) = BoundedCall.tryRead(target, "", gasLimit, maxReturn, 0);
            if (sizes[i] <= maxReturn) {
                assert(ok);
                assert(result.length == sizes[i]);
                for (uint256 j; j < result.length; ++j) {
                    assert(result[j] == fill[j % 32]);
                }
            } else {
                assert(!ok);
                assert(result.length == 0);
            }
        }
    }

    /// @notice A reverting target and an address without code are failures, whatever they
    ///         return and whatever `maxReturn` allows.
    function check_tryRead_failuresCopyNothing(
        bytes32 fill,
        uint256 maxReturn,
        address empty,
        uint8 pick
    ) public {
        vm.assume(empty.code.length == 0);
        uint256[9] memory sizes = _sizes();
        vm.assume(pick < sizes.length);
        for (uint256 i; i < sizes.length; ++i) {
            if (pick != i) continue;
            address target = address(new SizedReturn(sizes[i], fill, true));
            (bool ok, bytes memory result) = BoundedCall.tryRead(target, "", 50_000, maxReturn, 0);
            assert(!ok && result.length == 0);
        }
        (bool ok2, bytes memory result2) = BoundedCall.tryRead(empty, "", 50_000, maxReturn, 0);
        assert(!ok2 && result2.length == 0);
    }

    /// @notice `readWord` returns the word exactly when the target returns 32 bytes. Any other
    ///         size reverts: `BoundedCallFailed` when it is too long to copy, and
    ///         `BoundedCallMalformedReturn` when it is shorter. (With too little gas left the read
    ///         reverts first, with `BoundedCallInsufficientGas`, whatever the size.)
    function check_readWord_acceptsExactlyOneWord(bytes32 fill, uint8 pick) public {
        uint256[9] memory sizes = _sizes();
        vm.assume(pick < sizes.length);
        // One path per size: the size must be concrete, so it is chosen by branching.
        for (uint256 i; i < sizes.length; ++i) {
            if (pick != i) continue;
            address target = address(new SizedReturn(sizes[i], fill, false));
            try this.readWord(target) returns (bytes32 word) {
                assert(sizes[i] == 32 && word == fill);
            } catch (bytes memory reason) {
                bytes4 selector = bytes4(reason);
                if (selector != BoundedCall.BoundedCallInsufficientGas.selector) {
                    assert(sizes[i] != 32);
                    bytes4 expected = sizes[i] > 32
                        ? BoundedCall.BoundedCallFailed.selector
                        : BoundedCall.BoundedCallMalformedReturn.selector;
                    assert(selector == expected);
                }
            }
        }
    }

    function readWord(address target) external view returns (bytes32) {
        return BoundedCall.readWord(target, "", 50_000, 0);
    }

    // ---------------------------------------------------------------- decodeString

    /// @dev `length` bytes of `c0 ++ c1` as a fresh `bytes` (at most 64).
    function _content(bytes32 c0, bytes32 c1, uint256 length)
        internal
        pure
        returns (bytes memory s)
    {
        s = new bytes(64);
        assembly ("memory-safe") {
            mstore(add(s, 0x20), c0)
            mstore(add(s, 0x40), c1)
            mstore(s, length)
        }
    }

    /// @dev An accepted buffer is the canonical encoding of the value it decodes to, within
    ///      `maxLength`.
    function _canonical(bytes memory data, uint256 maxLength) internal pure {
        (bool ok, string memory value) = BoundedCall.decodeString(data, maxLength);
        if (ok) {
            assert(bytes(value).length <= maxLength);
            assert(keccak256(abi.encode(value)) == keccak256(data));
        }
    }

    /// @notice Only canonical encodings are accepted (offset 32, the stated length, zero
    ///         padding, nothing trailing): every accepted buffer re-encodes to itself. Every
    ///         offset word, content and `maxLength`; every length word up to 64 (one path each,
    ///         since an accepted length sizes a copy) in 64, 96 and 128-byte buffers.
    function check_decodeString_acceptsOnlyCanonical(
        bytes32 offset,
        bytes32 c0,
        bytes32 c1,
        uint256 maxLength,
        uint256 length
    ) public pure {
        vm.assume(length <= 64);
        for (uint256 l; l <= 64; ++l) {
            if (length != l) continue;
            _canonical(abi.encodePacked(offset, l), maxLength);
            _canonical(abi.encodePacked(offset, l, c0), maxLength);
            _canonical(abi.encodePacked(offset, l, c0, c1), maxLength);
        }
    }

    /// @notice A length word above 64 is never accepted from a buffer of at most 128 bytes,
    ///         whatever its value (unbounded, up to 2**256 - 1) and whatever `maxLength`.
    function check_decodeString_rejectsLengthsPastTheBuffer(
        bytes32 offset,
        uint256 length,
        bytes32 c0,
        bytes32 c1,
        uint256 maxLength
    ) public pure {
        vm.assume(length > 64);
        (bool ok,) = BoundedCall.decodeString(abi.encodePacked(offset, length), maxLength);
        assert(!ok);
        (ok,) = BoundedCall.decodeString(abi.encodePacked(offset, length, c0), maxLength);
        assert(!ok);
        (ok,) = BoundedCall.decodeString(abi.encodePacked(offset, length, c0, c1), maxLength);
        assert(!ok);
    }

    /// @notice Every canonical encoding of a string within `maxLength` is accepted and decodes
    ///         to that string. Every content of strings of lengths 0 to 64; every `maxLength`.
    function check_decodeString_acceptsEveryCanonicalEncoding(
        bytes32 c0,
        bytes32 c1,
        uint256 maxLength,
        uint256 length
    ) public pure {
        vm.assume(length <= 64);
        for (uint256 l; l <= 64; ++l) {
            if (length != l) continue;
            bytes memory s = _content(c0, c1, l);
            (bool ok, string memory value) =
                BoundedCall.decodeString(abi.encode(string(s)), maxLength);
            assert(ok == (l <= maxLength));
            if (ok) assert(keccak256(bytes(value)) == keccak256(s));
        }
    }
}
