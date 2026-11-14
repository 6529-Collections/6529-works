"""EIP-712 digests of the two convention typed-data messages, and the signature check readers run.

- `CustodyAttestation` (DCL-19), domain `{name: "6529 Works Custody Attestation", version: "1",
  chainId}`;
- `ControlProof` (DCL-23), domain `{name: "6529 Works Control Proof", version: "1", chainId}`.

Neither domain has a verifying contract, so the domain type is
`EIP712Domain(string name,string version,uint256 chainId)`.

`verify_signature` follows `SignatureVerifier.isValid` (DCL-20, DCL-24 step 3): low-s ECDSA for an
account without code; for an EIP-7702 delegated account (`0xef0100 || delegate`), ECDSA against
the account first, then ERC-1271; ERC-1271 otherwise. This module has no secp256k1 code: public-key
recovery is a pluggable callable. The default, `cast_ecdsa_verifier`, shells out to Foundry's
`cast wallet verify --no-hash`. Everything the contract checks before recovery (length, `v`,
`r`, low `s`, ERC-2098 unpacking) is done here, so a backend only ever sees a normalized 65-byte
`r || s || v` signature. The ERC-1271 call is the caller's: it must be made at the reader's
block and return true only for exactly 32 bytes holding `0x1626ba7e`.
"""

from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass
from typing import Any, Callable, Mapping

from tools.content.errors import ToolError
from tools.content.keccak import keccak256

DOMAIN_TYPE = b"EIP712Domain(string name,string version,uint256 chainId)"
DOMAIN_TYPEHASH = keccak256(DOMAIN_TYPE)

CUSTODY_DOMAIN_NAME = "6529 Works Custody Attestation"
CUSTODY_TYPE = (
    b"CustodyAttestation(address token,uint256 tokenId,bytes32 objectId,uint8 status,uint64 asOf,"
    b"address successor,bytes32 evidenceHash)"
)
CUSTODY_TYPEHASH = keccak256(CUSTODY_TYPE)

CONTROL_DOMAIN_NAME = "6529 Works Control Proof"
CONTROL_TYPE = (
    b"ControlProof(string venue,bytes32 nonce,uint64 issuedAt,uint64 expiresAt,uint256 chainId,"
    b"address token,uint256 tokenId,address holder,address signer)"
)
CONTROL_TYPEHASH = keccak256(CONTROL_TYPE)

SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
HALF_N = SECP256K1_N // 2
MAX_SIGNATURE_LENGTH = 4096
ERC1271_MAGIC = bytes.fromhex("1626ba7e")
DELEGATION_PREFIX = bytes.fromhex("ef0100")
ZERO_ADDRESS = "0x" + "00" * 20

#: `(signer, digest, signature65) -> bool`: does the normalized signature recover to `signer`?
EcdsaVerifier = Callable[[str, bytes, bytes], bool]
#: `(signer, digest, signature) -> bool`: `isValidSignature` at the reader's block.
Erc1271Verifier = Callable[[str, bytes, bytes], bool]


# --- ABI words ---


def _uint(value: Any, bits: int, what: str) -> bytes:
    if isinstance(value, str):
        if not value.isdigit():
            raise ToolError(f"{what} is not a decimal integer")
        value = int(value)
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value < 2**bits:
        raise ToolError(f"{what} is not a uint{bits}")
    return value.to_bytes(32, "big")


def _hex(value: Any, size: int, what: str) -> bytes:
    if not isinstance(value, str) or not value.startswith("0x") or len(value) != 2 + 2 * size:
        raise ToolError(f"{what} is not 0x and {size} bytes of hex")
    try:
        return bytes.fromhex(value[2:])
    except ValueError:
        raise ToolError(f"{what} is not hex") from None


def _address(value: Any, what: str) -> bytes:
    return bytes(12) + _hex(value, 20, what)


def domain_separator(name: str, chain_id: int) -> bytes:
    return keccak256(
        DOMAIN_TYPEHASH
        + keccak256(name.encode("utf-8"))
        + keccak256(b"1")
        + _uint(chain_id, 256, "chainId")
    )


def _digest(name: str, chain_id: int, struct_hash: bytes) -> bytes:
    return keccak256(b"\x19\x01" + domain_separator(name, chain_id) + struct_hash)


def custody_struct_hash(message: Mapping[str, Any]) -> bytes:
    return keccak256(
        CUSTODY_TYPEHASH
        + _address(message["token"], "token")
        + _uint(message["tokenId"], 256, "tokenId")
        + _hex(message["objectId"], 32, "objectId")
        + _uint(message["status"], 8, "status")
        + _uint(message["asOf"], 64, "asOf")
        + _address(message["successor"], "successor")
        + _hex(message["evidenceHash"], 32, "evidenceHash")
    )


def custody_digest(chain_id: int, message: Mapping[str, Any]) -> bytes:
    """DCL-19: the digest a custodian signs, in the domain of the work's chain."""
    return _digest(CUSTODY_DOMAIN_NAME, chain_id, custody_struct_hash(message))


def control_struct_hash(message: Mapping[str, Any]) -> bytes:
    venue = message["venue"]
    if not isinstance(venue, str):
        raise ToolError("venue is not a string")
    return keccak256(
        CONTROL_TYPEHASH
        + keccak256(venue.encode("utf-8"))
        + _hex(message["nonce"], 32, "nonce")
        + _uint(message["issuedAt"], 64, "issuedAt")
        + _uint(message["expiresAt"], 64, "expiresAt")
        + _uint(message["chainId"], 256, "chainId")
        + _address(message["token"], "token")
        + _uint(message["tokenId"], 256, "tokenId")
        + _address(message["holder"], "holder")
        + _address(message["signer"], "signer")
    )


def control_digest(message: Mapping[str, Any], domain_chain_id: int | None = None) -> bytes:
    """DCL-23: the digest a wallet signs. The domain's chain ID defaults to `message.chainId`; a
    verifier passes its own chain so that a mismatch changes the digest."""
    chain = message["chainId"] if domain_chain_id is None else domain_chain_id
    return _digest(CONTROL_DOMAIN_NAME, chain, control_struct_hash(message))


# --- signatures ---


def parse_ecdsa(signature: bytes) -> tuple[int, int, int] | None:
    """`(v, r, s)` of a 65-byte `r || s || v` or a 64-byte ERC-2098 `r || vs`, else None."""
    if len(signature) == 65:
        return signature[64], int.from_bytes(signature[:32], "big"), int.from_bytes(signature[32:64], "big")
    if len(signature) == 64:
        vs = int.from_bytes(signature[32:], "big")
        return 27 + (vs >> 255), int.from_bytes(signature[:32], "big"), vs & ((1 << 255) - 1)
    return None


def ecdsa_problem(signature: bytes) -> str | None:
    """Why `SignatureVerifier.isValidECDSA` would refuse before recovering, or None."""
    parsed = parse_ecdsa(signature)
    if parsed is None:
        return "an ECDSA signature is 64 or 65 bytes"
    v, r, s = parsed
    if v not in (27, 28):
        return "v is not 27 or 28"
    if not 0 < r < SECP256K1_N:
        return "r is out of range"
    if not 0 < s <= HALF_N:
        return "s is zero or not in the lower half of the curve order"
    return None


def normalized_65(signature: bytes) -> bytes:
    v, r, s = parse_ecdsa(signature)  # type: ignore[misc]
    return r.to_bytes(32, "big") + s.to_bytes(32, "big") + bytes([v])


def cast_ecdsa_verifier(signer: str, digest: bytes, signature65: bytes) -> bool:
    """Recover with Foundry's `cast wallet verify --no-hash` (the digest is signed as is)."""
    cast = shutil.which("cast")
    if cast is None:
        raise ToolError("cast (Foundry) is not on PATH: install Foundry or pass an ECDSA verifier")
    result = subprocess.run(
        [cast, "wallet", "verify", "--no-hash", "--address", signer, "0x" + digest.hex(),
         "0x" + signature65.hex()],
        capture_output=True, text=True, timeout=60, check=False,
    )  # fmt: skip
    if result.returncode == 0 and "Validation succeeded" in result.stdout:
        return True
    if "Validation failed" in result.stdout + result.stderr:
        return False
    raise ToolError(f"cast wallet verify failed: {(result.stderr or result.stdout).strip()}")


@dataclass(frozen=True)
class SignatureCheck:
    valid: bool
    path: str  # "ecdsa", "7702-ecdsa", "7702-erc1271", "erc1271" or "none"
    reason: str = ""


def is_delegated(code: bytes) -> bool:
    """EIP-7702 delegation designator: exactly `0xef0100 || 20-byte delegate`."""
    return len(code) == 23 and code.startswith(DELEGATION_PREFIX)


def verify_signature(
    signer: str,
    digest: bytes,
    signature: bytes,
    *,
    code: bytes,
    ecdsa: EcdsaVerifier | None = None,
    erc1271: Erc1271Verifier | None = None,
) -> SignatureCheck:
    """DCL-20 / DCL-24 step 3, as `SignatureVerifier.isValid`. `code` is the signer's code at the
    reader's block (empty for an account without code)."""
    ecdsa = ecdsa or cast_ecdsa_verifier
    if signer.lower() == ZERO_ADDRESS:
        return SignatureCheck(False, "none", "the zero address never signs")
    if len(signature) > MAX_SIGNATURE_LENGTH:
        return SignatureCheck(False, "none", f"a signature is at most {MAX_SIGNATURE_LENGTH} bytes")

    def by_ecdsa(path: str) -> SignatureCheck:
        problem = ecdsa_problem(signature)
        if problem:
            return SignatureCheck(False, path, problem)
        if ecdsa(signer, digest, normalized_65(signature)):
            return SignatureCheck(True, path)
        return SignatureCheck(False, path, "the signature does not recover to the signer")

    def by_erc1271(path: str) -> SignatureCheck:
        if erc1271 is None:
            raise ToolError(f"{signer} has code: an ERC-1271 check at the reader's block is needed")
        if erc1271(signer, digest, signature):
            return SignatureCheck(True, path)
        return SignatureCheck(False, path, "isValidSignature did not return the magic value")

    if not code:
        return by_ecdsa("ecdsa")
    if is_delegated(code):
        first = by_ecdsa("7702-ecdsa")
        if first.valid:
            return first
        return by_erc1271("7702-erc1271")
    return by_erc1271("erc1271")
