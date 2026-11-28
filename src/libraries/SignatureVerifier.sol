// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { BoundedCall } from "./BoundedCall.sol";
import { DelegatedEOA } from "./DelegatedEOA.sol";

/// @title SignatureVerifier
/// @notice The one shared signature check for artist, collaborator, identity and curation
///         payloads (ADR 0001 section 11 "Hardening"). It never tracks replay: callers bind digests
///         to nonces or deadlines and must never key replay protection on signature bytes,
///         because a 65-byte signature and its ERC-2098 form are both accepted.
/// @dev Built on OpenZeppelin 5 `ECDSA.parse`/`ECDSA.tryRecover` (low-s, non-zero signer).
///      Differences from OpenZeppelin `SignatureChecker.isValidSignatureNow`:
///      - 64-byte ERC-2098 signatures are accepted for EOAs (OZ's bytes overload rejects them);
///      - an EIP-7702 delegated EOA is first checked by `ecrecover` against the account itself,
///        then by ERC-1271 through its delegate (OZ only tries ERC-1271);
///      - ERC-1271 forwards all the gas EIP-150 allows, as OZ does, but a check that fails while
///        leaving only the retained share reverts with `BoundedCall.BoundedCallShortfall`
///        instead of reading as "invalid" (`BoundedCall.tryReadWordAll`), and it requires
///        exactly 32 bytes of return data holding exactly the magic value (OZ accepts longer
///        return data);
///      - signatures longer than {MAX_SIGNATURE_LENGTH} are rejected before any call.
///      No gas number is compiled in: what a wallet's check may cost is bounded only by the
///      transaction's gas, so a future repricing or a heavier account cannot be locked out.
library SignatureVerifier {
    /// @notice The largest signature, in bytes, that is considered at all: 64 KiB. A safety
    ///         bound against unbounded memory work, not a policy: it is above every standardised
    ///         signature, including the largest post-quantum one (SLH-DSA, FIPS 205, at most
    ///         49,856 bytes) with room for an ERC-1271 wallet's own wrapping, and it bounds the
    ///         memory a check copies (the signature twice, about 45,000 gas) whatever the
    ///         calldata carries, for callers that check several signatures in one transaction.
    uint256 internal constant MAX_SIGNATURE_LENGTH = 65_536;

    /// @notice The signature is not a valid signature of the payload by `signer`: malformed,
    ///         from another key, or refused by `signer`'s ERC-1271 check.
    /// @param signer The account the signature had to verify against.
    error InvalidSignature(address signer);
    /// @notice The signed payload's deadline has passed. A deadline is inclusive: a payload is
    ///         valid while `block.timestamp <= deadline`.
    /// @param deadline The payload's deadline, in seconds since the epoch.
    error SignatureExpired(uint256 deadline);

    /// @notice Reverts with `InvalidSignature(signer)` unless `isValid(signer, digest, signature)`.
    /// @param signer The account the signature must verify against.
    /// @param digest The signed digest.
    /// @param signature The signature bytes.
    function check(address signer, bytes32 digest, bytes memory signature) internal view {
        if (!isValid(signer, digest, signature)) revert InvalidSignature(signer);
    }

    /// @notice Reverts with `SignatureExpired(deadline)` once `block.timestamp` is past
    ///         `deadline`.
    /// @param deadline The payload's deadline, inclusive.
    function checkDeadline(uint256 deadline) internal view {
        // A deadline is a wall-clock bound by design; validator timestamp drift is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
    }

    /// @notice Returns whether `signature` is valid for `digest` from `signer`.
    /// @param signer The account the signature must verify against; zero is never valid.
    /// @param digest The signed digest.
    /// @param signature The signature bytes: 65 or 64 (ERC-2098) bytes for an EOA, anything up to
    ///        {MAX_SIGNATURE_LENGTH} for an ERC-1271 contract.
    /// @return Whether the signature verifies.
    /// @dev Reverts with `BoundedCall.BoundedCallShortfall` when an ERC-1271 check fails while
    ///      leaving only the share of gas EIP-150 retained: the transaction needs more gas.
    function isValid(address signer, bytes32 digest, bytes memory signature)
        internal
        view
        returns (bool)
    {
        if (signer == address(0) || signature.length > MAX_SIGNATURE_LENGTH) return false;
        if (signer.code.length == 0) return isValidECDSA(signer, digest, signature);
        if (DelegatedEOA.isDelegated(signer) && isValidECDSA(signer, digest, signature)) {
            return true;
        }
        return isValidERC1271(signer, digest, signature);
    }

    /// @notice Low-s ECDSA over a 65-byte `r || s || v` or 64-byte ERC-2098 `r || vs`
    ///         signature, with `v` in {27, 28}.
    /// @param signer The expected signer.
    /// @param digest The signed digest.
    /// @param signature The signature bytes.
    /// @return Whether `signature` recovers to `signer`.
    function isValidECDSA(address signer, bytes32 digest, bytes memory signature)
        internal
        pure
        returns (bool)
    {
        if (signature.length != 64 && signature.length != 65) return false;
        (uint8 v, bytes32 r, bytes32 s) = ECDSA.parse(signature);
        if (v != 27 && v != 28) return false;
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, v, r, s);
        return err == ECDSA.RecoverError.NoError && recovered == signer;
    }

    /// @notice ERC-1271, forwarding all the gas EIP-150 allows, with an exact 32-byte
    ///         magic-value return. A shortfall reverts with `BoundedCall.BoundedCallShortfall`.
    /// @param signer The contract asked to approve the signature.
    /// @param digest The signed digest.
    /// @param signature The signature bytes, passed through unchanged.
    /// @return Whether `signer` returned exactly the ERC-1271 magic value.
    function isValidERC1271(address signer, bytes32 digest, bytes memory signature)
        internal
        view
        returns (bool)
    {
        (bool ok, bytes32 word) = BoundedCall.tryReadWordAll(
            signer, abi.encodeCall(IERC1271.isValidSignature, (digest, signature))
        );
        return ok && word == bytes32(IERC1271.isValidSignature.selector);
    }
}
