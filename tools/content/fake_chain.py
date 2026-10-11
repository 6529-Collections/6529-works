"""Test support: an in-memory `ContentStore` read model behind a local JSON-RPC server.

It answers exactly the read calls the tooling makes (`eth_call` on the store's views,
`eth_getCode`, `eth_chainId`), with the same ABI shapes and custom-error reverts as the real
contract, so `verify` and `rebuild` can be exercised end to end without a node. It is only a
model of the contract's reads; the real contract is checked by the Foundry golden test and by
`test_anvil.py`.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from . import abi
from .abi import uint_word
from .address import checksum_address
from .encoding import base64_attestation_problem
from .keccak import keccak256
from .plan import CHUNK_SIZE, MAX_CHUNKS, Plan

STORE_ADDRESS = bytes.fromhex("5fbdb2315678afecb367f032d93f642f64180aa3")
_STORE_TEXT = checksum_address(STORE_ADDRESS).lower()


class Revert(Exception):
    def __init__(self, data: bytes) -> None:
        super().__init__(data.hex())
        self.data = data


def _error(signature: str, *words: bytes) -> Revert:
    return Revert(abi.selector(signature) + b"".join(words))


class FakeStore:
    """The state and read functions of a `ContentStore`."""

    def __init__(self) -> None:
        self.files: dict[bytes, dict[str, Any]] = {}
        self.chunks: dict[bytes, bytes] = {}
        self.calls: list[bytes] = []  # every eth_call's calldata, for assertions
        self.tamper: dict[bytes, bytes] = {}  # chunk hash -> bytes served instead of the real ones
        self.attested: set[bytes] = set()
        self.supports_attest = True  # False models a store deployed before attestBase64

    # --- writes, as plain methods (the real contract takes calldata; see test_anvil.py) ---

    def write_chunk(self, data: bytes) -> bytes:
        if len(data) > CHUNK_SIZE:
            raise ValueError("chunk too large")
        digest = keccak256(data)
        self.chunks[digest] = data
        return digest

    def register(self, plan: Plan) -> bytes:
        self.files[plan.file_id] = {
            "sha256": plan.media_sha256,
            "length": plan.stored_length,
            "encoding": int(plan.encoding),
            "mime": plan.mime_type,
            "chunks": list(plan.chunk_hashes),
        }
        return plan.file_id

    def upload(self, plan: Plan, only: list[int] | None = None) -> None:
        for index, chunk in enumerate(plan.chunks()):
            if only is None or index in only:
                self.write_chunk(chunk)

    def attest(self, file_id: bytes) -> None:
        """Model of a completed `attestBase64` series: marks the file attested if its whole text
        passes the rule (here, this tool's own reading of it; the real contract is exercised in
        `test_anvil.py`)."""
        f = self.files[file_id]
        text = b"".join(self.chunks[digest] for digest in f["chunks"])
        if base64_attestation_problem(text) is not None:
            raise ValueError("would revert")
        self.attested.add(file_id)

    # --- reads ---

    def _file(self, file_id: bytes) -> dict[str, Any]:
        if file_id not in self.files:
            raise _error("ContentFileUnknown(bytes32)", file_id)
        return self.files[file_id]

    def _expected(self, f: dict[str, Any], index: int) -> int:
        remaining = f["length"] - index * CHUNK_SIZE
        return min(remaining, CHUNK_SIZE)

    def _present(self, f: dict[str, Any], index: int) -> bool:
        data = self.chunks.get(f["chunks"][index])
        return data is not None and len(data) == self._expected(f, index)

    def call(self, data: bytes) -> bytes:
        self.calls.append(data)
        sel, args = data[:4], data[4:]
        word = lambda i: args[32 * i : 32 * i + 32]  # noqa: E731
        if sel == abi.CHUNK_SIZE:
            return uint_word(CHUNK_SIZE)
        if sel == abi.MAX_CHUNKS:
            return uint_word(MAX_CHUNKS)
        if sel == abi.FILE_INFO:
            f = self._file(word(0))
            mime = f["mime"].encode()
            tail = uint_word(len(mime)) + mime + bytes(-len(mime) % 32)
            return (
                uint_word(32)
                + f["sha256"]
                + uint_word(f["length"])
                + uint_word(len(f["chunks"]))
                + uint_word(f["encoding"])
                + uint_word(5 * 32)
                + tail
            )
        if sel == abi.CHUNK_HASH:
            f = self._file(word(0))
            index = int.from_bytes(word(1), "big")
            if index >= len(f["chunks"]):
                raise _error("ContentChunkIndexOutOfBounds(bytes32,uint256)", word(0), word(1))
            return f["chunks"][index]
        if sel == abi.MISSING_CHUNKS:
            f = self._file(word(0))
            missing = [i for i in range(len(f["chunks"])) if not self._present(f, i)]
            return uint_word(32) + uint_word(len(missing)) + b"".join(uint_word(i) for i in missing)
        if sel == abi.READ_CHUNK:
            f = self._file(word(0))
            index = int.from_bytes(word(1), "big")
            if index >= len(f["chunks"]):
                raise _error("ContentChunkIndexOutOfBounds(bytes32,uint256)", word(0), word(1))
            digest = f["chunks"][index]
            if digest not in self.chunks:
                raise _error(
                    "ContentChunkMissing(bytes32,uint256,bytes32)", word(0), word(1), digest
                )
            body = self.tamper.get(digest, self.chunks[digest])
            if keccak256(body) != digest:
                raise _error("SSTORE2HashMismatch(address)", bytes(12) + STORE_ADDRESS)
            return uint_word(32) + uint_word(len(body)) + body + bytes(-len(body) % 32)
        if sel == abi.IS_BASE64_ATTESTED:
            if not self.supports_attest:
                raise Revert(b"")
            return uint_word(1 if word(0) in self.attested else 0)
        if sel == abi.ATTEST_CHUNKS_PER_CALL:
            if not self.supports_attest:
                raise Revert(b"")
            return uint_word(48)
        if sel == abi.CHUNK_POINTER:
            digest = word(0)
            return bytes(12) + STORE_ADDRESS if digest in self.chunks else bytes(32)
        raise Revert(b"")


class _Handler(BaseHTTPRequestHandler):
    server: "FakeChain"

    def log_message(self, *args: Any) -> None:  # keep test output quiet
        pass

    def do_POST(self) -> None:  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        reply: dict[str, Any] = {"jsonrpc": "2.0", "id": body["id"]}
        try:
            reply["result"] = self._dispatch(body["method"], body["params"])
        except Revert as exc:
            reply["error"] = {
                "code": 3,
                "message": "execution reverted",
                "data": "0x" + exc.data.hex(),
            }
        payload = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _dispatch(self, method: str, params: list[Any]) -> Any:
        store = self.server.store
        self.server.methods.append(method)
        if method == "eth_chainId":
            return "0x7a69"
        if method == "eth_getCode":
            return "0x6080" if params[0].lower() == _STORE_TEXT else "0x"
        if method == "eth_call":
            if params[0]["to"].lower() != _STORE_TEXT:
                return "0x"
            return "0x" + store.call(bytes.fromhex(params[0]["data"][2:])).hex()
        raise Revert(b"")


class FakeChain(ThreadingHTTPServer):
    """`with FakeChain() as chain:`; `chain.url` is the RPC endpoint, `chain.store` the model."""

    daemon_threads = True

    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), _Handler)
        self.store = FakeStore()
        self.methods: list[str] = []  # every JSON-RPC method received, for assertions
        self._thread = threading.Thread(target=self.serve_forever, daemon=True)

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server_address[1]}"

    def __enter__(self) -> "FakeChain":
        self._thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self.shutdown()
        self.server_close()

