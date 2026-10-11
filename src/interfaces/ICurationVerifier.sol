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
    function isApproved(bytes32 packageRoot, bytes32 evidenceHash, bytes calldata attestation)
        external
        view
        returns (bool approved, address signer);
}

/// @title ICurationSignerVerifier
/// @notice The v1 curation verifier: EIP-712 attestations by curation-signer keys, with an
///         immediate per-signer kill switch (ADR 0001 sections 3 and 13).
/// @dev `attestation` is `abi.encode(address signer, bytes signature)`, the signature being a
///      `Typehashes.PACKAGE_APPROVAL` signature in this verifier's domain. A curation signer key
///      is never an on-chain caller: it only signs. It counts while it holds the CURATION_SIGNER
///      role with no execution delay and is not disabled. Disabling is immediate and one-way
///      (GUARDIAN role); only `enableSigner` (SUCCESSOR_SETTER role, 30-day delay) restores a
///      signer. Disabling affects packages registered afterwards; an approval already registered
///      is withdrawn with `IPackageRegistry.revokePackage`.
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
    /// @notice Whether an attestation by `signer` counts now.
    function isSignerActive(address signer) external view returns (bool);
}
