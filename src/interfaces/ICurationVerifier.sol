// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICurationVerifier
/// @notice The pluggable answer to "is this package approved?" (ADR 0001 section 3
///         "Verification"). The package registry depends on this function only.
/// @dev The evidence hash commits to the published vote snapshot, TDH snapshot and rule
///      parameters. The v1 verifier is `ICurationSignerVerifier`. A verifier backed by the 6529
///      chain replaces it later through a 30-day governed swap in the package registry, and may
///      interpret `attestation` differently. Trust boundary: until then, contracts trust the
///      curation signer, not the vote itself.
interface ICurationVerifier {
    /// @notice Whether `packageRoot` is approved with `evidenceHash`.
    /// @dev Must not revert for a well-formed but invalid attestation: it returns false and the
    ///      caller fails closed.
    function isApproved(bytes32 packageRoot, bytes32 evidenceHash, bytes calldata attestation)
        external
        view
        returns (bool);
}

/// @title ICurationSignerVerifier
/// @notice The v1 curation verifier: EIP-712 attestations by curation-signer keys, with an
///         immediate per-signer kill switch (ADR 0001 sections 3 and 13).
/// @dev `attestation` is `abi.encode(address signer, bytes signature)`, the signature being over
///      `PackageApproval(bytes32 packageRoot,bytes32 evidenceHash)` in this verifier's EIP-712
///      domain. A signer counts while it holds the CURATION_SIGNER role with no execution delay
///      and is not disabled. Disabling is immediate and one-way (GUARDIAN role); only the
///      separate `enableSigner` (SUCCESSOR_SETTER role, 30-day delay) restores a signer, so a
///      compromised key is cut off at once and can come back only slowly and publicly.
///      Disabling affects packages registered afterwards; an approval already registered is
///      withdrawn with `IPackageRegistry.revokePackage`.
interface ICurationSignerVerifier is ICurationVerifier {
    /// @notice The guardian disabled `signer`.
    event SignerDisabled(address indexed signer);
    /// @notice A disabled `signer` was enabled again after the 30-day delay.
    event SignerEnabled(address indexed signer);

    /// @notice `signer` is already disabled.
    error SignerAlreadyDisabled(address signer);
    /// @notice `signer` is not disabled.
    error SignerNotDisabled(address signer);

    /// @notice Disables `signer`: its attestations stop counting at once. GUARDIAN role.
    function disableSigner(address signer) external;

    /// @notice Re-enables a disabled `signer`. SUCCESSOR_SETTER role (30-day delay).
    function enableSigner(address signer) external;

    /// @notice Whether `signer` is disabled.
    function isDisabled(address signer) external view returns (bool);

    /// @notice Whether an attestation by `signer` counts now: it holds the CURATION_SIGNER role
    ///         with no execution delay and is not disabled.
    function isSignerActive(address signer) external view returns (bool);

    /// @notice The EIP-712 digest a curation signer signs for a package approval.
    function approvalDigest(bytes32 packageRoot, bytes32 evidenceHash)
        external
        view
        returns (bytes32);
}
