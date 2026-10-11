// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DelegatedEOA
/// @notice Detects EIP-7702 delegated accounts, whose code is the 23-byte designator
///         `0xef0100 || delegate`. This is the one shared copy for every v1 contract.
/// @dev Differs from OpenZeppelin's `EIP7702Utils.fetchDelegate`, which copies the
///      account's whole code and checks only the prefix: this version requires the
///      exact 23-byte length and copies only those 23 bytes.
library DelegatedEOA {
    /// @notice The EIP-7702 delegation designator prefix (magic `0xef01`, version `0x00`).
    bytes3 internal constant PREFIX = 0xef0100;

    /// @notice The length of a delegation designator: three prefix bytes plus an address.
    uint256 internal constant DESIGNATOR_LENGTH = 23;

    /// @notice Returns whether `account` currently carries an EIP-7702 delegation.
    function isDelegated(address account) internal view returns (bool) {
        return _designatorWord(account) >> 232 == uint24(PREFIX);
    }

    /// @notice Returns the delegate of `account`, or zero when it is not delegated.
    function delegateOf(address account) internal view returns (address delegate) {
        uint256 word = _designatorWord(account);
        // Bits 231..72 hold the delegate; truncation drops the prefix above them.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (word >> 232 == uint24(PREFIX)) delegate = address(uint160(word >> 72));
    }

    /// @dev The first 23 code bytes, left-aligned, or zero unless the code is exactly 23 bytes.
    function _designatorWord(address account) private view returns (uint256 word) {
        if (account.code.length != DESIGNATOR_LENGTH) return 0;
        assembly ("memory-safe") {
            // Scratch use of free memory; nothing is allocated and the slot is not read back.
            let scratch := mload(0x40)
            mstore(scratch, 0)
            extcodecopy(account, scratch, 0, 23)
            word := mload(scratch)
        }
    }
}
