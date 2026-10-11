// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICurationVerifier
/// @notice The pluggable answer to "is this package approved?" (ADR 0001 section 3
///         "Verification").
/// @dev The v1 verifier checks an EIP-712 attestation by the curation signer over
///      `PackageApproval(bytes32 packageRoot,bytes32 evidenceHash)` in the verifier's own domain;
///      `attestation` is that signature. The evidence hash commits to the published vote
///      snapshot, TDH snapshot and rule parameters. A verifier backed by the 6529 chain replaces
///      it later through a 30-day governed swap in the package registry, and may interpret
///      `attestation` differently. Trust boundary: until then, contracts trust the curation
///      signer, not the vote itself.
interface ICurationVerifier {
    /// @notice Whether `packageRoot` is approved with `evidenceHash`.
    /// @dev Must not revert for a well-formed but invalid attestation: it returns false and the
    ///      caller fails closed.
    function isApproved(bytes32 packageRoot, bytes32 evidenceHash, bytes calldata attestation)
        external
        view
        returns (bool);
}
