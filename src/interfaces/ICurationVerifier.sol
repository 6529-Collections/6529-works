// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ICurationVerifier
/// @notice The pluggable answer to "is this package approved, and by whom?" (ADR 0001 section 3
///         "Verification"). The package registry depends on this function only.
/// @dev The evidence hash commits to the published vote snapshot, TDH snapshot and rule
///      parameters, and to the curation signer's check of every declared SHA-256 against the
///      decoded media bytes. The v1 verifier is `ICurationSignerVerifier`. A verifier backed by
///      the 6529 chain replaces it later through a 30-day governed swap in the package registry.
///      Trust boundary: until then, contracts trust the curation signer, not the vote itself.
interface ICurationVerifier is IERC165 {
    /// @notice Whether `packageRoot` is approved with `evidenceHash`, and the attester.
    /// @dev Must not revert for a well-formed but invalid attestation: it returns
    ///      `(false, address(0))` and the caller fails closed.
    /// @param packageRoot The package root to check.
    /// @param evidenceHash The evidence hash the approval must bind.
    /// @param attestation The verifier-specific approval proof.
    /// @return approved True if the attestation approves `packageRoot` with `evidenceHash`.
    /// @return signer The attesting signer, or zero when not approved.
    function isApproved(bytes32 packageRoot, bytes32 evidenceHash, bytes calldata attestation)
        external
        view
        returns (bool approved, address signer);
}

/// @title ICurationSignerVerifier
/// @notice The v1 curation verifier: EIP-712 attestations by curation-signer keys, with an
///         immediate per-signer kill switch (ADR 0001 sections 3 and 13).
/// @dev `attestation` is `abi.encode(address signer, bytes signature)`, the signature being a
///      `Typehashes.PACKAGE_APPROVAL` signature in this verifier's domain over the signer's current
///      `signerEpoch`. A curation signer key is never an on-chain caller: it only signs. It counts
///      while it holds the CURATION_SIGNER role with no execution delay and is not disabled.
///      Disabling is immediate and one-way (GUARDIAN role); only `enableSigner` (SUCCESSOR_SETTER
///      role, 30-day delay) restores a signer, at a new epoch: an approval made before the disable
///      never counts again (nor does one made under a revoked grant of the role), and one signed
///      during the disable cannot name the re-enable's epoch. Disabling affects packages registered
///      afterwards; an approval already registered is withdrawn with
///      `IPackageRegistry.revokePackage`.
interface ICurationSignerVerifier is ICurationVerifier {
    /// @notice The guardian disabled `signer`.
    /// @param signer The disabled address.
    event SignerDisabled(address indexed signer);
    /// @notice A disabled `signer` was enabled again after the 30-day delay.
    /// @param signer The enabled address.
    event SignerEnabled(address indexed signer);

    /// @notice `signer` is already disabled.
    error SignerAlreadyDisabled(address signer);
    /// @notice `signer` is not disabled.
    error SignerNotDisabled(address signer);

    /// @notice Disables `signer`: its attestations stop counting at once. GUARDIAN role.
    /// @param signer The address to disable, with or without the CURATION_SIGNER role; an
    ///        already disabled one reverts with `SignerAlreadyDisabled`.
    function disableSigner(address signer) external;
    /// @notice Re-enables a disabled `signer`. SUCCESSOR_SETTER role (30-day delay).
    /// @param signer The disabled address to enable; one not disabled reverts with
    ///        `SignerNotDisabled`.
    function enableSigner(address signer) external;
    /// @notice Whether `signer` is disabled.
    /// @param signer The address to check.
    /// @return True if `signer` is disabled.
    function isDisabled(address signer) external view returns (bool);
    /// @notice Whether an attestation by `signer` counts now.
    /// @param signer The address to check.
    /// @return True if `signer` holds CURATION_SIGNER with no execution delay and is not disabled.
    function isSignerActive(address signer) external view returns (bool);
    /// @notice The epoch an approval by `signer` must bind to count now. It changes whenever the
    ///         signer is disabled or enabled (salted from that block, so it cannot be computed
    ///         earlier), or its CURATION_SIGNER role is granted anew.
    /// @param signer The curation signer.
    /// @return The signer's current epoch.
    function signerEpoch(address signer) external view returns (uint256);
}
