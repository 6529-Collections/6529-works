"""The command line over the committed examples: validate (DCL-1), canonical (DCL-1), floor
(DCL-5), card (DCL-26), grade (DCL-30), control-proof digest (DCL-23) and verify (DCL-24),
custody digest (DCL-19) and check (DCL-21, DCL-22). Exit codes: 0 ok, 1 refused, 2 bad input."""

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

from tools.conventions import cli, eip712, testdata
from tools.conventions.testdata import EXAMPLES


def run(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = cli.main(list(argv))
    return code, out.getvalue(), err.getvalue()


class CliTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, name: str, value: Any) -> str:
        path = self.dir / name
        data = value if isinstance(value, bytes) else json.dumps(value).encode("utf-8")
        path.write_bytes(data)
        return str(path)

    def test_validate_every_example(self) -> None:
        for name, schema_name in testdata.EXAMPLE_SCHEMAS.items():
            with self.subTest(name):
                code, out, _ = run("validate", schema_name, str(EXAMPLES / name))
                self.assertEqual(code, 0, out)

    def test_validate_refusals(self) -> None:
        code, out, _ = run("validate", "declarations", self.write("bad.json", {"v": 1}))
        self.assertEqual(code, 1)
        self.assertIn("contentHash", out)
        code, out, _ = run("validate", "--canonical", "declarations", str(EXAMPLES / "declarations.json"))
        self.assertEqual(code, 1)
        self.assertIn("canonical", out)
        canonical = self.write("c.json", testdata.canonical(testdata.example("declarations.json")))
        self.assertEqual(run("validate", "--canonical", "declarations", canonical)[0], 0)

    def test_canonical(self) -> None:
        out = io.BytesIO()
        with contextlib.redirect_stdout(io.TextIOWrapper(out, encoding="utf-8")) as wrapper:
            code = cli.main(["canonical", str(EXAMPLES / "promise-card.json")])
            wrapper.flush()
        self.assertEqual(code, 0)
        self.assertEqual(out.getvalue(), testdata.canonical(testdata.example("promise-card.json")))

    def test_grade_example(self) -> None:
        code, out, _ = run("grade", str(EXAMPLES / "promise-card.json"))
        self.assertEqual((code, json.loads(out)), (0, testdata.example("promise-grade.json")))

    def test_digests(self) -> None:
        code, out, _ = run("control-proof", "digest", str(EXAMPLES / "control-proof.json"))
        self.assertEqual((code, out.strip()), (0, "0x2548db021144b031169071ded42000449c5128184168ca0bd94e5d56c4e0a057"))
        code, out, _ = run("custody", "digest", str(EXAMPLES / "custody-attestation.json"))
        self.assertEqual((code, out.strip()), (0, "0xa03cc2c3767834df2ef6c583fd5d08e6d65ddd616d2f90a96e0ad8e00e152e2a"))

    def test_floor(self) -> None:
        inp = testdata.still_floor_input()
        decl = inp["contents"].pop(testdata.DECL_FILE)
        self.write("decl.json", decl)
        inp["contents"] = {testdata.DECL_FILE: {"file": "decl.json"}}
        inp["observed"]["fetched"] = {uri: {"sha256": h} for uri, h in inp["observed"]["fetched"].items()}
        code, out, _ = run("floor", self.write("floor.json", inp))
        self.assertEqual(code, 0, out)
        self.assertTrue(json.loads(out)["ok"])
        inp["policy"]["workPowers"] = []  # an explicit list that names no power refuses ROYALTY_RATE
        code, out, _ = run("floor", self.write("floor2.json", inp))
        self.assertEqual(code, 1)
        self.assertFalse(json.loads(out)["ok"])

    def test_card(self) -> None:
        code, out, _ = run("card", self.write("card.json", testdata.example_card_inputs()))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["record"]["status"], "finalized")
        code, out, _ = run("card", "--notes", self.write("card.json", testdata.example_card_inputs()))
        self.assertEqual(set(json.loads(out)), {"card", "notes"})

    def test_control_proof_verify(self) -> None:
        ctx = {"venue": "https://gallery.example", "chainId": 11155111, "now": 1794787260,
               "challenges": [{"v": 1, "message": testdata.example("control-proof.json")["message"]}],
               "officialTokens": {"0x02617dbdc0b0521124cb4c2a3ef602977e29bd91": "stream"},
               "block": {"number": 1, "timestamp": 1794787250}, "headBlock": 1,
               "ownership": {"ownerOf": testdata.ANVIL_1}, "consolidation": {"isEstablished": False, "effectiveAt": 0}}
        with mock.patch.object(eip712, "cast_ecdsa_verifier", return_value=True):
            code, out, _ = run("control-proof", "verify", str(EXAMPLES / "control-proof.json"), "--context", self.write("ctx.json", ctx))
        self.assertEqual((code, json.loads(out)["step"]), (1, "DCL-25"))  # no established consolidation
        ctx["consolidation"]["isEstablished"] = True
        with mock.patch.object(eip712, "cast_ecdsa_verifier", return_value=True):
            code, out, _ = run("control-proof", "verify", str(EXAMPLES / "control-proof.json"), "--context", self.write("ctx.json", ctx))
        self.assertEqual((code, json.loads(out)["accepted"]), (0, True))
        ctx["venue"] = "https://other.example"
        code, out, _ = run("control-proof", "verify", str(EXAMPLES / "control-proof.json"), "--context", self.write("ctx.json", ctx))
        self.assertEqual((code, json.loads(out)["step"]), (1, "DCL-24.2"))

    def test_custody_check(self) -> None:
        work = {"chainId": 11155111, "contract": "0x02617dbdc0b0521124cb4c2a3ef602977e29bd91", "tokenId": "42"}
        spec = {"work": work, "declarations": str(EXAMPLES / "declarations.json"), "now": 1794787200,
                "attestations": [{"document": str(EXAMPLES / "custody-attestation.json"), "recordedAt": 1794700900,
                                  "posterRole": "OWNER", "poster": testdata.ANVIL_1, "signatureValid": True}]}  # fmt: skip
        code, out, _ = run("custody", "check", self.write("custody.json", spec))
        self.assertEqual(code, 0)
        self.assertTrue(json.loads(out)["entries"][0]["recognized"])
        other = dict(spec, work=dict(work, tokenId="43"))  # DCL-20: an attestation about another work
        code, out, _ = run("custody", "check", self.write("custody2.json", other))
        self.assertEqual(code, 0)
        result = json.loads(out)
        self.assertEqual(len(result["discarded"]), 1)
        self.assertEqual([e["status"] for e in result["entries"]], ["NONE"])
        code, _, err = run("custody", "check", self.write("custody3.json", {k: v for k, v in spec.items() if k != "work"}))
        self.assertEqual(code, 2)
        self.assertIn("work", err)

    def test_bad_input_exits_2(self) -> None:
        self.assertEqual(run("grade", str(self.dir / "missing.json"))[0], 2)
        self.assertEqual(run("grade", self.write("x.json", b"{"))[0], 2)
        self.assertEqual(run("card", self.write("y.json", {"reads": {}}))[0], 2)
        self.assertEqual(run("validate", "nope", str(EXAMPLES / "citation.json"))[0], 2)

    def test_non_object_json_input_exits_2(self) -> None:
        """An input file holding JSON that is not an object is bad input: exit 2 with a message,
        not a traceback."""
        for value in ([], 7, "x", None):
            path = self.write("v.json", value)
            for argv in (("floor", path), ("card", path), ("grade", path), ("custody", "check", path),
                         ("custody", "digest", path), ("control-proof", "digest", path),
                         ("control-proof", "verify", path, "--context", path)):  # fmt: skip
                with self.subTest(value=value, command=argv[0]):
                    code, _, err = run(*argv)
                    self.assertEqual(code, 2)
                    self.assertIn("must hold a JSON object", err)


if __name__ == "__main__":
    unittest.main()
