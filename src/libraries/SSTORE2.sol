// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SSTORE2
/// @notice Content-addressed byte storage in contract code: `write` deploys `0x00 || data` as
///         runtime code by CREATE2 with `salt = keccak256(data)`, so a pointer depends only on
///         the writing contract and the bytes, and writing the same bytes again is a no-op.
/// @dev The leading STOP byte means a pointer can never execute. One chunk holds at most
///      24,575 bytes so that STOP plus data fits EIP-170. Reads check the STOP prefix, and
///      {readVerified} also checks the bytes against an expected keccak256 hash, which callers
///      should use whenever a pointer did not come from their own {write}.
library SSTORE2 {
    /// @notice The largest chunk: EIP-170's 24,576-byte code limit minus the STOP byte.
    uint256 internal constant MAX_CHUNK_LENGTH = 24_575;

    /// @dev Creation preamble returning everything after its 11 bytes as runtime code:
    ///      PUSH1 0x0b, MSIZE, DUP2, CODESIZE, SUB, DUP1, SWAP3, MSIZE, CODECOPY, RETURN,
    ///      followed by the STOP byte that leads the runtime code.
    bytes12 private constant PREAMBLE = 0x600B5981380380925939F300;

    /// @notice `write` was given `length` bytes, more than `MAX_CHUNK_LENGTH`.
    error SSTORE2ChunkTooLarge(uint256 length);
    /// @notice The CREATE2 deployment of a chunk did not produce the predicted pointer.
    error SSTORE2WriteFailed();
    /// @notice `pointer` has no code, or its code does not start with the STOP byte.
    error SSTORE2InvalidPointer(address pointer);
    /// @notice The range `[start, end)` is reversed or ends past the `size` data bytes behind
    ///         the pointer.
    error SSTORE2OutOfBounds(uint256 start, uint256 end, uint256 size);
    /// @notice The data behind `pointer` does not hash (keccak256) to the expected hash.
    error SSTORE2HashMismatch(address pointer);

    /// @notice Stores `data` and returns its pointer, deploying it only if absent.
    function write(bytes memory data) internal returns (address pointer) {
        if (data.length > MAX_CHUNK_LENGTH) revert SSTORE2ChunkTooLarge(data.length);
        bytes memory code = abi.encodePacked(PREAMBLE, data);
        bytes32 salt = keccak256(data);
        pointer = _predict(address(this), salt, keccak256(code));
        // A CREATE2 collision would burn all forwarded gas, so check first. Only this
        // contract can deploy at the pointer, and only these exact bytes.
        if (pointer.code.length != 0) return pointer;
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 0x20), mload(code), salt)
        }
        if (deployed != pointer) revert SSTORE2WriteFailed();
    }

    /// @notice The pointer at which `deployer` stores `data` with {write}.
    function pointerOf(address deployer, bytes memory data) internal pure returns (address) {
        return _predict(deployer, keccak256(data), keccak256(abi.encodePacked(PREAMBLE, data)));
    }

    /// @notice The number of data bytes behind `pointer`.
    function size(address pointer) internal view returns (uint256) {
        uint256 codeLength = pointer.code.length;
        uint256 first = 1;
        if (codeLength != 0) {
            assembly ("memory-safe") {
                // Copy one code byte into scratch space. `mload(0)` reads a full word, but
                // only its most significant byte (the copied code byte) is meaningful; the
                // other 31 bytes are stale scratch contents and `byte(0, ...)` discards them.
                extcodecopy(pointer, 0, 0, 1)
                first := byte(0, mload(0))
            }
        }
        if (first != 0) revert SSTORE2InvalidPointer(pointer);
        return codeLength - 1;
    }

    /// @notice All data bytes behind `pointer`.
    function read(address pointer) internal view returns (bytes memory) {
        return _copy(pointer, 0, size(pointer));
    }

    /// @notice Data bytes `[start, end)` behind `pointer`.
    function read(address pointer, uint256 start, uint256 end)
        internal
        view
        returns (bytes memory)
    {
        uint256 total = size(pointer);
        if (start > end || end > total) revert SSTORE2OutOfBounds(start, end, total);
        return _copy(pointer, start, end - start);
    }

    /// @notice All data bytes behind `pointer`, which must hash to `expectedHash`.
    function readVerified(address pointer, bytes32 expectedHash)
        internal
        view
        returns (bytes memory data)
    {
        data = read(pointer);
        if (keccak256(data) != expectedHash) revert SSTORE2HashMismatch(pointer);
    }

    function _copy(address pointer, uint256 start, uint256 length)
        private
        view
        returns (bytes memory data)
    {
        data = new bytes(length);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 0x20), add(start, 1), length)
        }
    }

    function _predict(address deployer, bytes32 salt, bytes32 codeHash)
        private
        pure
        returns (address)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, codeHash))))
        );
    }
}
