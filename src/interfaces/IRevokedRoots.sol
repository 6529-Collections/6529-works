// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

/// @title IRevokedRoots
/// @notice What a mint policy asks the policy it replaces: whether a package root is revoked for
///         good. A replacement refuses every root the replaced policy reports, so a revocation
///         outlives the policy that recorded it.
interface IRevokedRoots {
    /// @notice Whether a root is revoked for good: revoked in this policy (also in advance),
    ///         registered in it by a signer whose approvals were killed since, or reported as
    ///         revoked by the policy this one replaces.
    /// @param packageRoot The package root.
    /// @return True if the root is revoked.
    function isRevoked(bytes32 packageRoot) external view returns (bool);
}
