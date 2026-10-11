"""Ethereum addresses: parsing and EIP-55 checksums."""

from __future__ import annotations

import re

from .errors import ToolError
from .keccak import keccak256

_ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}")


def checksum_address(address: bytes) -> str:
    """The EIP-55 mixed-case form of a 20-byte address."""
    if len(address) != 20:
        raise ToolError("an address is 20 bytes")
    lower = address.hex()
    digest = keccak256(lower.encode("ascii")).hex()
    return "0x" + "".join(c.upper() if c.isalpha() and int(digest[i], 16) >= 8 else c
                          for i, c in enumerate(lower))


def parse_address(text: str) -> bytes:
    """A 20-byte address from `0x` + 40 hex digits. Mixed-case input must carry a valid EIP-55
    checksum; all-lowercase and all-uppercase input are accepted as unchecksummed."""
    if not _ADDRESS.fullmatch(text):
        raise ToolError(f"{text!r} is not a 0x-prefixed 20-byte address")
    digits = text[2:]
    raw = bytes.fromhex(digits)
    if digits != digits.lower() and digits != digits.upper() and checksum_address(raw) != text:
        raise ToolError(f"{text} has an invalid EIP-55 checksum (expected {checksum_address(raw)})")
    return raw
