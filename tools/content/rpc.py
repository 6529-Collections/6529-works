"""Read-only JSON-RPC access to a content store, over `urllib`.

Only `eth_call`, `eth_getCode`, `eth_chainId` and `eth_estimateGas` are used. Nothing here can
change chain state or sign anything: `eth_estimateGas` only simulates a call. The endpoint URL
often carries an API key, so it is never printed: errors and reports name only its scheme, host
and port.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any
from urllib.parse import urlsplit

from . import abi
from .address import checksum_address
from .errors import AbiError, RevertError, RpcError, ToolError
from .plan import CHUNK_SIZE as LAYOUT_CHUNK_SIZE
from .plan import MAX_CHUNKS as LAYOUT_MAX_CHUNKS

MAX_RESPONSE_BYTES = 128 * 1024 * 1024  # a full file is about 25 MB of hex, with headroom
DEFAULT_TIMEOUT = 30.0


class JsonRpc:
    """A minimal JSON-RPC 2.0 client for one HTTP(S) endpoint."""

    def __init__(self, url: str, timeout: float = DEFAULT_TIMEOUT) -> None:
        parts = urlsplit(url)
        if parts.scheme not in ("http", "https") or not parts.hostname:
            raise ToolError("the RPC URL must be an http:// or https:// URL")
        self._url = url
        self._timeout = timeout
        self._next_id = 0
        port = f":{parts.port}" if parts.port else ""
        self.label = f"{parts.scheme}://{parts.hostname}{port}"

    def request(self, method: str, params: list[Any]) -> Any:
        self._next_id += 1
        payload = json.dumps(
            {"jsonrpc": "2.0", "id": self._next_id, "method": method, "params": params}
        ).encode("utf-8")
        request = urllib.request.Request(
            self._url,
            data=payload,
            headers={"Content-Type": "application/json", "User-Agent": "6529-works-content/1"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self._timeout) as response:  # noqa: S310
                body = response.read(MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as exc:
            raise RpcError(f"{self.label} answered HTTP {exc.code}") from None
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            reason = getattr(exc, "reason", exc)
            raise RpcError(f"cannot reach {self.label}: {reason}") from None
        if len(body) > MAX_RESPONSE_BYTES:
            raise RpcError(f"{self.label} sent an oversized response")
        try:
            message = json.loads(body)
        except ValueError:
            raise RpcError(f"{self.label} did not answer with JSON") from None
        if not isinstance(message, dict):
            raise RpcError(f"{self.label} sent an unexpected response")
        error = message.get("error")
        if error is not None:
            raise _error_from(self.label, error)
        if "result" not in message:
            raise RpcError(f"{self.label} sent a response with no result")
        return message["result"]

    def eth_call(self, to: bytes, data: bytes) -> bytes:
        result = self.request(
            "eth_call", [{"to": checksum_address(to), "data": "0x" + data.hex()}, "latest"]
        )
        return _hex_bytes(result, "eth_call result")

    def get_code(self, address: bytes) -> bytes:
        result = self.request("eth_getCode", [checksum_address(address), "latest"])
        return _hex_bytes(result, "eth_getCode result")

    def chain_id(self) -> int:
        return _hex_quantity(self.request("eth_chainId", []), "eth_chainId result")

    def estimate_gas(self, to: bytes, data: bytes) -> int:
        """The node's `eth_estimateGas` for a zero-value call with this calldata, on the latest
        state. A node with the default RPC gas cap answers at most 50M."""
        result = self.request(
            "eth_estimateGas", [{"to": checksum_address(to), "data": "0x" + data.hex()}]
        )
        return _hex_quantity(result, "eth_estimateGas result")


def _hex_bytes(value: Any, what: str) -> bytes:
    if not isinstance(value, str) or not value.startswith("0x") or len(value) % 2:
        raise RpcError(f"{what} is not 0x-prefixed hex")
    try:
        return bytes.fromhex(value[2:])
    except ValueError:
        raise RpcError(f"{what} is not valid hex") from None


def _hex_quantity(value: Any, what: str) -> int:
    if not isinstance(value, str) or not value.startswith("0x") or len(value) < 3:
        raise RpcError(f"{what} is not a 0x-prefixed quantity")
    try:
        return int(value[2:], 16)
    except ValueError:
        raise RpcError(f"{what} is not a valid quantity") from None


def _error_from(label: str, error: Any) -> RpcError:
    """A JSON-RPC error object as an exception; a revert (with its data) becomes `RevertError`."""
    if not isinstance(error, dict):
        return RpcError(f"{label} returned an error")
    message = str(error.get("message", "error"))[:200]
    data = error.get("data")
    if isinstance(data, dict):  # some nodes nest the revert data
        data = data.get("data")
    revert = b""
    if isinstance(data, str) and data.startswith("0x") and len(data) % 2 == 0:
        try:
            revert = bytes.fromhex(data[2:])
        except ValueError:
            revert = b""
    if "revert" in message.lower() or error.get("code") == 3:
        return RevertError(abi.describe_revert(revert) if revert else message, revert)
    return RpcError(f"{label} returned an error: {message}")


class StoreClient:
    """Typed read access to a deployed `ContentStore`."""

    def __init__(self, rpc: JsonRpc, store: bytes) -> None:
        self.rpc = rpc
        self.store = store

    def _call(self, data: bytes) -> bytes:
        ret = self.rpc.eth_call(self.store, data)
        if not ret:
            raise AbiError("the call returned no data (is --store a ContentStore?)")
        return ret

    def check_contract(self) -> None:
        """Fail early if there is no contract at the address, or its layout constants differ from
        the ones this tool hashes with."""
        if not self.rpc.get_code(self.store):
            raise ToolError(f"no contract at {checksum_address(self.store)} on {self.rpc.label}")
        chunk_size = abi.decode_uint(self._call(abi.encode_call(abi.CHUNK_SIZE)))
        max_chunks = abi.decode_uint(self._call(abi.encode_call(abi.MAX_CHUNKS)))
        if chunk_size != LAYOUT_CHUNK_SIZE or max_chunks != LAYOUT_MAX_CHUNKS:
            raise ToolError(
                f"the store reports CHUNK_SIZE {chunk_size} and MAX_CHUNKS {max_chunks}, not "
                f"{LAYOUT_CHUNK_SIZE} and {LAYOUT_MAX_CHUNKS}; this tool cannot verify it"
            )

    def file_info(self, file_id: bytes) -> abi.FileInfoData | None:
        """The manifest's declared fields, or `None` if no manifest is registered."""
        try:
            return abi.decode_file_info(self._call(abi.encode_call(abi.FILE_INFO, file_id)))
        except RevertError as exc:
            if exc.data[:4] == abi.CONTENT_FILE_UNKNOWN:
                return None
            raise

    def chunk_hash(self, file_id: bytes, index: int) -> bytes:
        return abi.decode_bytes32(self._call(abi.encode_call(abi.CHUNK_HASH, file_id, index)))

    def missing_chunks(self, file_id: bytes) -> list[int]:
        return abi.decode_uint_array(self._call(abi.encode_call(abi.MISSING_CHUNKS, file_id)))

    def read_chunk(self, file_id: bytes, index: int) -> bytes:
        return abi.decode_bytes(self._call(abi.encode_call(abi.READ_CHUNK, file_id, index)))

    def is_base64_attested(self, file_id: bytes) -> bool | None:
        """Whether `attestBase64` has validated the whole file, or `None` if this store has no
        attestation (a deployment from before it existed reverts on the unknown selector)."""
        try:
            return abi.decode_bool(self._call(abi.encode_call(abi.IS_BASE64_ATTESTED, file_id)))
        except RevertError as exc:
            if not exc.data:
                return None
            raise

    def attest_chunks_per_call(self) -> int | None:
        """The store's `ATTEST_CHUNKS_PER_CALL`, or `None` if it has no attestation."""
        try:
            return abi.decode_uint(self._call(abi.encode_call(abi.ATTEST_CHUNKS_PER_CALL)))
        except RevertError as exc:
            if not exc.data:
                return None
            raise

    def chunk_pointer(self, digest: bytes) -> bytes | None:
        """The contract holding the chunk with this hash, or `None` if it is not stored."""
        return abi.decode_address(self._call(abi.encode_call(abi.CHUNK_POINTER, digest)))
