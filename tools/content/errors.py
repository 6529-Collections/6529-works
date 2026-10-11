"""Exceptions shared by the content tooling."""

from __future__ import annotations


class ToolError(Exception):
    """A problem with the user's input or environment, reported without a traceback."""


class EncodingError(ToolError):
    """Stored bytes do not decode under their declared encoding."""


class AbiError(ToolError):
    """A call result is not valid ABI data for the expected return type."""


class RpcError(ToolError):
    """The JSON-RPC endpoint failed, or answered with something unusable."""


class RevertError(RpcError):
    """An `eth_call` reverted. `data` is the raw revert data (possibly empty)."""

    def __init__(self, message: str, data: bytes) -> None:
        super().__init__(message)
        self.data = data
