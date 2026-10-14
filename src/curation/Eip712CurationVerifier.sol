// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Roles } from "../governance/Roles.sol";
import { ICurationSignerVerifier, ICurationVerifier } from "../interfaces/ICurationVerifier.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";

/// @title Eip712CurationVerifier
/// @notice The v1 curation verifier: a `Typehashes.PACKAGE_APPROVAL` attestation by an active
///         curation signer (ADR 0001 sections 3 and 13).
/// @dev Signers are the AccessManager's `Roles.CURATION_SIGNER` members with no execution delay,
///      so the 30-day grant delay governs who becomes a signer. The deploy configuration grants
///      the role to at least two keys, so the guardian can cut one off with `disableSigner` and
///      curation continues on the other. Replay needs no tracking here: the registry stores each
///      package root once. The approval digest binds this contract and the chain ID, so an
///      attestation is valid for one verifier deployment only.
///
///      Epochs. Every approval binds the signer's epoch at signing ({signerEpoch}): the time its
///      current CURATION_SIGNER grant took effect and the number of times it was disabled or
///      enabled. Disabling a signer, or revoking its role, therefore ends every approval it
///      signed so far, and re-enabling it, or granting the role to the same key again, starts a
///      new epoch, so approvals signed in between never count either. The signer re-signs
///      what it still approves. Approvals still never expire with
///      time (ADR 0001 section 3).
contract Eip712CurationVerifier is ICurationSignerVerifier, AccessManaged, EIP712 {
    /// @dev Whether the signer is disabled, and how many times it was disabled or enabled.
    struct SignerState {
        bool disabled;
        uint64 changes;
    }

    mapping(address signer => SignerState) private _signers;

    /// @param authority_ The AccessManager that governs this verifier and holds the signer role.
    constructor(address authority_)
        AccessManaged(authority_)
        EIP712(Typehashes.CURATION_VERIFIER_NAME, Typehashes.DOMAIN_VERSION)
    { }

    /// @inheritdoc ICurationVerifier
    /// @dev `attestation` must be the canonical `abi.encode(address signer, bytes signature)`;
    ///      any other shape returns `(false, address(0))` rather than reverting. The signature
    ///      must be over the signer's current epoch.
    function isApproved(bytes32 packageRoot, bytes32 evidenceHash, bytes calldata attestation)
        external
        view
        returns (bool approved, address signer)
    {
        bytes calldata signature;
        (approved, signer, signature) = _decode(attestation);
        approved = approved && isSignerActive(signer)
            && SignatureVerifier.isValid(
                signer, approvalDigest(packageRoot, evidenceHash, signerEpoch(signer)), signature
            );
        if (!approved) signer = address(0);
    }

    /// @inheritdoc ICurationSignerVerifier
    /// @dev Governed: map to GUARDIAN with no delay. Any address may be disabled in advance.
    ///      Ends the signer's epoch, so no approval it signed so far counts again.
    function disableSigner(address signer) external restricted {
        SignerState storage s = _signers[signer];
        if (s.disabled) revert SignerAlreadyDisabled(signer);
        s.disabled = true;
        ++s.changes;
        emit SignerDisabled(signer);
    }

    /// @inheritdoc ICurationSignerVerifier
    /// @dev Governed: map to SUCCESSOR_SETTER (30 days). The signer starts a new epoch, so
    ///      nothing signed while it was disabled counts.
    function enableSigner(address signer) external restricted {
        SignerState storage s = _signers[signer];
        if (!s.disabled) revert SignerNotDisabled(signer);
        s.disabled = false;
        ++s.changes;
        emit SignerEnabled(signer);
    }

    /// @inheritdoc ICurationSignerVerifier
    function isDisabled(address signer) external view returns (bool) {
        return _signers[signer].disabled;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(ICurationVerifier).interfaceId
            || interfaceId == type(ICurationSignerVerifier).interfaceId;
    }

    /// @inheritdoc ICurationSignerVerifier
    /// @dev Holds `Roles.CURATION_SIGNER` with no execution delay and is not disabled.
    function isSignerActive(address signer) public view returns (bool) {
        if (_signers[signer].disabled) return false;
        (bool member, uint32 delay) =
            IAccessManager(authority()).hasRole(Roles.CURATION_SIGNER, signer);
        return member && delay == 0;
    }

    /// @inheritdoc ICurationSignerVerifier
    /// @dev `since << 64 | changes`: `since` is when the signer's CURATION_SIGNER grant takes
    ///      or took effect (zero without a grant); a revocation deletes it and a new grant sets a
    ///      later one. `changes` counts `disableSigner` and `enableSigner` calls.
    function signerEpoch(address signer) public view returns (uint256) {
        (uint48 since,,,) = IAccessManager(authority()).getAccess(Roles.CURATION_SIGNER, signer);
        return uint256(since) << 64 | _signers[signer].changes;
    }

    /// @notice The EIP-712 digest a curation signer signs to approve a package root, at its
    ///         epoch `signerEpoch` (read with {signerEpoch}).
    function approvalDigest(bytes32 packageRoot, bytes32 evidenceHash, uint256 signerEpoch_)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(Typehashes.PACKAGE_APPROVAL, packageRoot, evidenceHash, signerEpoch_)
            )
        );
    }

    /// @dev Decodes the exact canonical encoding without reverting: a 32-byte address word, the
    ///      offset 0x40, a length word, then that many bytes zero-padded to a whole word, and
    ///      nothing after them. Any other shape (dirty padding, trailing bytes) fails.
    function _decode(bytes calldata a)
        private
        pure
        returns (bool ok, address signer, bytes calldata signature)
    {
        signature = a[0:0];
        if (a.length < 96) return (false, address(0), signature);
        uint256 word = uint256(bytes32(a[0:32]));
        uint256 length = uint256(bytes32(a[64:96]));
        if (
            word >> 160 != 0 || uint256(bytes32(a[32:64])) != 64
                || length > SignatureVerifier.MAX_SIGNATURE_LENGTH
                || a.length != 96 + length + (32 - length % 32) % 32
        ) return (false, address(0), signature);
        uint256 pad = a.length - 96 - length;
        // The padding is the last `pad` bytes: shifting them to the top must leave zero.
        if (pad != 0 && uint256(bytes32(a[a.length - 32:])) << (256 - pad * 8) != 0) {
            return (false, address(0), signature);
        }
        // The upper 96 bits are zero (checked above), so the cast keeps every bit.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, address(uint160(word)), a[96:96 + length]);
    }
}
