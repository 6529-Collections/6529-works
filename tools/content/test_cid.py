"""Tests of the `cid` helper (`cid.py`): the fixed IPFS profile of ADR 0001 section 8.

What the CIDs are checked against:

- Published answers. `hello world` and the empty file are kubo's well-known CIDv1 raw blocks
  (`hello world` is also an IPIP-0499 test vector), and the IPIP-0499 fixture's one-byte leaf.
- The IPIP-0499 fixtures' root blocks (`golden/ipip-0499-blocks.json`), including the 174-link
  node and the rebalanced two-level root of kubo's default 256 KiB / 174-link layout. Each block
  is first authenticated by its own CID (its SHA-256 is the CID's digest), then decoded here with
  an independent protobuf reader, and `cid.py` must re-encode it byte for byte from its links.
  That fixes the dag-pb and UnixFS encoding: links before data, empty link names, `Tsize`,
  `filesize` and unpacked `blocksizes`.
- An independent statement of the balanced layout (full subtrees of `max_links ** (depth - 1)`
  leaves, left to right), at small chunk and fan-out sizes where every shape is reachable.
- kubo itself, when an `ipfs` binary is on the PATH (otherwise skipped).
- The locator rule of `WorkRecords._checkUri`, and Python's own base32 (`base64.b32encode`).
"""

from __future__ import annotations

import base64
import contextlib
import hashlib
import io
import json
import os
import random
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.content import cid as c
from tools.content import cid_golden
from tools.content.cli import main

BLOCKS = Path(__file__).resolve().parent / "golden" / "ipip-0499-blocks.json"
_B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def _unb58(text: str) -> bytes:
    n = 0
    for char in text:
        n = n * 58 + _B58.index(char)
    return n.to_bytes(34, "big")


def _varint(data: bytes, i: int) -> tuple[int, int]:
    value = shift = 0
    while True:
        byte = data[i]
        i += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return value, i


def _fields(data: bytes) -> list[tuple[int, int | bytes]]:
    """A protobuf message as (field number, value) pairs, in order (varint and bytes only)."""
    out: list[tuple[int, int | bytes]] = []
    i = 0
    while i < len(data):
        key, i = _varint(data, i)
        if key & 7 == 0:
            value, i = _varint(data, i)
            out.append((key >> 3, value))
        elif key & 7 == 2:
            length, i = _varint(data, i)
            out.append((key >> 3, data[i : i + length]))
            i += length
        else:
            raise ValueError(f"wire type {key & 7}")
    return out


def _decode_node(block: bytes) -> tuple[list[c.Node], list[bytes], int, list[int]]:
    """A dag-pb UnixFS file node: its links (as `cid.Node`s), their names, the filesize, and the
    order of its top-level fields."""
    fields = _fields(block)
    links = [_fields(v) for f, v in fields if f == 2]  # type: ignore[arg-type]
    data = next(v for f, v in fields if f == 1)
    unixfs = _fields(data)  # type: ignore[arg-type]
    assert dict(unixfs)[1] == 2, "a UnixFS File"
    sizes = [v for f, v in unixfs if f == 4]
    children = []
    names = []
    for link, size in zip(links, sizes, strict=True):
        d = dict(link)
        children.append(c.Node(d[1], d[3], size))  # type: ignore[arg-type]
        names.append(d[2])  # type: ignore[arg-type]
    return children, names, dict(unixfs)[3], [f for f, _ in fields]  # type: ignore[return-value]


def _reference(data: bytes, chunk_size: int, max_links: int) -> str:
    """The balanced layout stated independently: with `n` leaves and depth `d` the least with
    `max_links ** d >= n`, the root's children are consecutive groups of `max_links ** (d - 1)`
    leaves, each a full subtree of depth `d - 1` (a single leaf at depth 0)."""
    chunks = [data[i : i + chunk_size] for i in range(0, len(data), chunk_size)] or [b""]
    leaves = [c.Node(c.binary_cid(c.CODEC_RAW, x), len(x), len(x)) for x in chunks]
    if len(leaves) == 1:
        return c.text_cid(leaves[0].cid)

    def tree(group: list[c.Node], depth: int) -> c.Node:
        if depth == 0:
            return group[0]
        width = max_links ** (depth - 1)
        children = [tree(group[i : i + width], depth - 1) for i in range(0, len(group), width)]
        block = c.dag_pb_node(children)
        return c.Node(
            c.binary_cid(c.CODEC_DAG_PB, block),
            len(block) + sum(x.tsize for x in children),
            sum(x.filesize for x in children),
        )

    depth = 1
    while max_links**depth < len(leaves):
        depth += 1
    return c.text_cid(tree(leaves, depth).cid)


class PublishedAnswersTest(unittest.TestCase):
    def test_empty_file(self) -> None:
        result = c.cid_of_bytes(b"")
        self.assertEqual(result.cid, "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku")
        self.assertEqual((result.size, result.depth, result.kind), (0, 0, "raw"))

    def test_hello_world(self) -> None:
        self.assertEqual(
            c.cid_of_bytes(b"hello world").cid,
            "bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e",
        )

    def test_the_ipip_fixture_one_byte_leaf(self) -> None:
        # The second leaf of IPIP-0499's 1,048,577-byte vector (see the blocks below).
        self.assertEqual(
            c.cid_of_bytes(b"\x0e").cid,
            "bafkreicnpm7pomakz5ymrewygj63qjzpkrbuvw6gdjhbgcswhs2zudipi4",
        )


class Ipip0499BlocksTest(unittest.TestCase):
    def setUp(self) -> None:
        self.blocks = json.loads(BLOCKS.read_text(encoding="utf-8"))["blocks"]

    def _digest(self, text: str) -> bytes:
        if text.startswith("Qm"):
            multihash = _unb58(text)
            self.assertEqual(multihash[:2], b"\x12\x20")
            return multihash[2:]
        return c.describe(text)[2]

    def test_every_block_is_authentic_and_reencodes_byte_for_byte(self) -> None:
        for entry in self.blocks:
            with self.subTest(cid=entry["cid"]):
                block = bytes.fromhex(entry["hex"][2:])
                self.assertEqual(hashlib.sha256(block).digest(), self._digest(entry["cid"]))
                children, names, filesize, order = _decode_node(block)
                self.assertEqual(c.dag_pb_node(children), block, "cid.py's encoding")
                self.assertEqual(set(names), {b""}, "every link name present and empty")
                self.assertEqual(order[-1], 1, "links before data")
                self.assertEqual(filesize, sum(x.filesize for x in children))

    def test_default_profile_shapes(self) -> None:
        by_cid = {b["cid"]: bytes.fromhex(b["hex"][2:]) for b in self.blocks}
        full, _, size, _ = _decode_node(by_cid["QmUbBALi174SnogsUzLpYbD4xPiBSFANF4iztWCsHbMKh2"])
        self.assertEqual(len(full), c.MAX_LINKS)
        self.assertEqual(size, c.MAX_LINKS * c.CHUNK_SIZE)
        root, _, size, _ = _decode_node(by_cid["QmV81WL765sC8DXsRhE5fJv2rwhS4icHRaf3J9Zk5FdRnW"])
        self.assertEqual(size, c.MAX_LINKS * c.CHUNK_SIZE + 1)
        self.assertEqual(len(root), 2, "rebalanced: the full node, then a node for the tail")
        self.assertEqual(root[0].cid, b"\x12\x20" + hashlib.sha256(
            by_cid["QmUbBALi174SnogsUzLpYbD4xPiBSFANF4iztWCsHbMKh2"]
        ).digest())
        self.assertEqual(root[0].tsize, len(by_cid["QmUbBALi174SnogsUzLpYbD4xPiBSFANF4iztWCsHbMKh2"])
                         + sum(x.tsize for x in full), "Tsize sums the subtree")

    def test_raw_leaves_are_linked_by_their_length(self) -> None:
        entry = next(b for b in self.blocks if b["cid"].startswith("bafy"))
        children, _, size, _ = _decode_node(bytes.fromhex(entry["hex"][2:]))
        self.assertEqual(size, (1 << 20) + 1)
        for child in children:
            self.assertEqual(child.cid[:2], bytes([1, c.CODEC_RAW]))
            self.assertEqual(child.tsize, child.filesize)


class LayoutTest(unittest.TestCase):
    def test_matches_the_independent_layout_at_small_sizes(self) -> None:
        rng = random.Random(6529)
        for max_links in (2, 3, 5):
            for n_chunks in range(1, max_links**3 + 3):
                data = rng.randbytes(n_chunks * 3 - rng.randrange(3))
                with self.subTest(max_links=max_links, chunks=n_chunks):
                    self.assertEqual(
                        c.cid_of_bytes(data, chunk_size=3, max_links=max_links).cid,
                        _reference(data, 3, max_links),
                    )

    def test_depth_grows_exactly_past_each_full_level(self) -> None:
        for n, depth in ((1, 0), (2, 1), (3, 1), (4, 2), (9, 2), (10, 3)):
            with self.subTest(chunks=n):
                self.assertEqual(c.cid_of_bytes(bytes(n), chunk_size=1, max_links=3).depth, depth)

    def test_a_stream_of_short_reads_gives_the_same_cid(self) -> None:
        data = random.Random(1).randbytes(3 * c.CHUNK_SIZE + 17)

        class Trickle(io.RawIOBase):
            def __init__(self) -> None:
                self.position = 0

            def readable(self) -> bool:
                return True

            def readinto(self, buffer) -> int:  # type: ignore[no-untyped-def]
                n = min(len(buffer), 1000, len(data) - self.position)
                buffer[:n] = data[self.position : self.position + n]
                self.position += n
                return n

        streamed = c.cid_of_stream(Trickle())  # type: ignore[arg-type]
        self.assertEqual(streamed.cid, c.cid_of_bytes(data).cid)

    def test_chunk_boundaries(self) -> None:
        one = c.cid_of_bytes(bytes(c.CHUNK_SIZE))
        self.assertEqual((one.kind, one.chunks), ("raw", 1))
        self.assertEqual(one.cid, c.text_cid(c.binary_cid(c.CODEC_RAW, bytes(c.CHUNK_SIZE))))
        two = c.cid_of_bytes(bytes(c.CHUNK_SIZE + 1))
        self.assertEqual((two.kind, two.chunks, two.depth), ("dag-pb", 2, 1))
        self.assertTrue(two.cid.startswith("bafybei"))

    def test_bad_parameters_are_refused(self) -> None:
        with self.assertRaises(ValueError):
            c.cid_of_bytes(b"x", chunk_size=0)
        with self.assertRaises(ValueError):
            c.cid_of_bytes(b"x", max_links=1)


class EncodingTest(unittest.TestCase):
    def test_base32_is_rfc4648_lowercase_unpadded(self) -> None:
        rng = random.Random(7)
        for length in range(0, 40):
            data = rng.randbytes(length)
            expected = base64.b32encode(data).decode().rstrip("=").lower()
            self.assertEqual(c.base32(data), expected)
            self.assertEqual(c.unbase32(expected), data)

    def test_varint(self) -> None:
        self.assertEqual(c.varint(0), b"\x00")
        self.assertEqual(c.varint(127), b"\x7f")
        self.assertEqual(c.varint(128), b"\x80\x01")
        self.assertEqual(c.varint(262_144), b"\x80\x80\x10")
        with self.assertRaises(ValueError):
            c.varint(-1)

    def test_describe(self) -> None:
        raw = c.cid_of_bytes(b"hello world").cid
        self.assertEqual(c.describe(raw), (1, c.CODEC_RAW, hashlib.sha256(b"hello world").digest()))
        v0 = "Qmf412jQZiuVUtdgnB36FXFX7xg5V6KEbSJ4dpQuhkLyfD"
        for bad in (v0, raw[:-1] + "b", raw.upper()):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                c.describe(bad)


class LocatorRuleTest(unittest.TestCase):
    def test_every_profile_cid_is_accepted(self) -> None:
        rng = random.Random(11)
        for codec in (c.CODEC_RAW, c.CODEC_DAG_PB):
            for _ in range(200):
                text = c.text_cid(c.binary_cid(codec, rng.randbytes(8)))
                self.assertTrue(c.locator_accepted("ipfs://" + text), text)

    def test_what_work_records_refuses(self) -> None:
        good = "ipfs://" + c.cid_of_bytes(b"hello world").cid
        dag_cbor = "ipfs://" + c.text_cid(bytes([1, 0x71, 0x12, 0x20]) + bytes(32))
        refused = [
            good + "/file.png",  # a path: `ipfs add -w` style
            good.upper(),
            good.replace("ipfs://", "ipfs://ipfs/"),
            good[:-1],
            good[:-1] + "b",  # non-zero padding bits
            "ipfs://Qmf412jQZiuVUtdgnB36FXFX7xg5V6KEbSJ4dpQuhkLyfD",  # CIDv0
            dag_cbor,
            "ar://" + good[7:],
        ]
        for uri in refused:
            with self.subTest(uri=uri):
                self.assertFalse(c.locator_accepted(uri))


class CommittedVectorsTest(unittest.TestCase):
    def test_vectors_and_solidity_data_are_fresh(self) -> None:
        self.assertEqual(cid_golden.check(), [])

    def test_pattern_chunks_differ(self) -> None:
        data = cid_golden.pattern(3 * c.CHUNK_SIZE)
        chunks = {data[i : i + c.CHUNK_SIZE] for i in range(0, len(data), c.CHUNK_SIZE)}
        self.assertEqual(len(chunks), 3)


@unittest.skipUnless(shutil.which("ipfs"), "kubo (`ipfs`) is not on the PATH")
class KuboAgreementTest(unittest.TestCase):
    """Every golden vector against kubo's own answer (`cid.KUBO_COMMAND`, offline)."""

    def test_kubo_agrees(self) -> None:
        document = cid_golden.build()
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, IPFS_PATH=str(Path(tmp) / "repo"))
            subprocess.run(
                ["ipfs", "init", "--profile=test"], env=env, capture_output=True, check=True
            )
            for spec, vector in zip(cid_golden.SPECS, document["vectors"], strict=True):
                path = Path(tmp) / spec[0]
                path.write_bytes(cid_golden.spec_input(spec))
                command = c.KUBO_COMMAND.split()[:-1] + [str(path)]
                out = subprocess.run(command, env=env, capture_output=True, text=True, check=True)
                with self.subTest(vector=spec[0]):
                    self.assertEqual(out.stdout.strip(), vector["cid"])


class CliTest(unittest.TestCase):
    def _run(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = main(["cid", *args])
        return code, out.getvalue(), err.getvalue()

    def test_prints_the_locator_and_warns_about_wrapping(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "hello.txt"
            path.write_bytes(b"hello world")
            code, out, err = self._run(str(path))
            self.assertEqual(code, 0)
            self.assertIn("ipfs://bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e", out)
            self.assertIn("--wrap-with-directory", err)
            self.assertIn(c.KUBO_COMMAND, err)
            code, out, err = self._run(str(path), "--json", "-q")
            self.assertEqual(code, 0)
            self.assertEqual(err, "")
            report = json.loads(out)
            self.assertTrue(report["locatorAccepted"])
            self.assertEqual(report["root"], "raw")

    def test_a_missing_file_is_an_input_error(self) -> None:
        code, _, err = self._run("no-such-file.bin")
        self.assertEqual(code, 2)
        self.assertIn("cannot read", err)


if __name__ == "__main__":
    unittest.main()
