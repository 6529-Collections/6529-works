// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BoundedParameter
/// @notice Raise-only governed parameters, such as gas limits: each step at most doubles the
///         value, and no value ever exceeds an absolute ceiling fixed in the target's code
///         (ADR 0001 §7 and §13.9). The direction rule lives here because `AccessManager` only
///         sees selectors.
library BoundedParameter {
    /// @notice An initial value is zero or a ceiling is zero.
    error ParameterZero();
    /// @notice `proposed` does not exceed `current`.
    error ParameterNotRaised(uint256 current, uint256 proposed);
    /// @notice `proposed` is more than twice `current`.
    error ParameterStepTooLarge(uint256 current, uint256 proposed);
    /// @notice `proposed` exceeds the absolute ceiling.
    error ParameterAboveCeiling(uint256 proposed, uint256 ceiling);

    /// @notice Validates a constructor value: nonzero (so it can be raised) and within the
    ///         nonzero `ceiling`.
    function initial(uint256 value, uint256 ceiling) internal pure returns (uint256) {
        if (value == 0 || ceiling == 0) revert ParameterZero();
        if (value > ceiling) revert ParameterAboveCeiling(value, ceiling);
        return value;
    }

    /// @notice Validates a raise from `current` to `proposed` and returns `proposed`.
    /// @dev `proposed - current > current` is the overflow-free form of `proposed > 2 * current`.
    function raise(uint256 current, uint256 proposed, uint256 ceiling)
        internal
        pure
        returns (uint256)
    {
        if (proposed <= current) revert ParameterNotRaised(current, proposed);
        if (proposed > ceiling) revert ParameterAboveCeiling(proposed, ceiling);
        if (proposed - current > current) revert ParameterStepTooLarge(current, proposed);
        return proposed;
    }
}
