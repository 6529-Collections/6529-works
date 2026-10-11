"""Unit tests for check_genesis.py, which sits beside this file.

Run with `python tools/test_check_genesis.py` or, from the repository root,
`python -m tools.test_check_genesis`.
"""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "check_genesis", Path(__file__).with_name("check_genesis.py")
)
cg = importlib.util.module_from_spec(_SPEC)
sys.modules["check_genesis"] = cg
_SPEC.loader.exec_module(cg)

FOO = """// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Foo {
    function setFee(uint256 fee) external restricted { }
    function bindStream(address peer)
        external
        restricted
    { }
    function setAdmittedMinter(address minter, bool admitted) external restricted { }
    function fee() external view returns (uint256) { return 1; }
    // function ghost() external restricted { }
    /* function ghost2() external restricted { } */
    string internal constant NOTE = "function ghost3() external restricted { }";
}
"""

METHODS = {
    "setFee(uint256)": "11111111",
    "bindStream(address)": "22222222",
    "setAdmittedMinter(address,bool)": "33333333",
    "fee()": "44444444",
}

CONFIG = {
    "roles": [
        {"name": "PARAMETER_SETTER", "executionDelay": 172800},
        {"name": "SUCCESSOR_SETTER", "executionDelay": 2592000},
    ],
    "peers": [{"name": "Peer", "address": "0x" + "00" * 19 + "01"}],
    "contracts": [
        {
            "name": "Foo",
            "address": "0x" + "00" * 19 + "0f",
            "artifact": "src/x/Foo.sol:Foo",
            "implementation": "src/x/Foo.sol:Foo",
            "functions": [
                {"signature": "setFee(uint256)", "selector": "0x11111111",
                 "role": "PARAMETER_SETTER", "class": "standard", "delay": 172800},
                {"signature": "setAdmittedMinter(address,bool)", "selector": "0x33333333",
                 "role": "SUCCESSOR_SETTER", "class": "successor", "delay": 2592000},
            ],
            "genesisOnly": [{"signature": "bindStream(address)", "selector": "0x22222222"}],
            "deferred": [],
        }
    ],
    "wiring": [
        {"contract": "Foo", "signature": "bindStream(address)", "args": ["Peer"],
         "calldata": "0x22222222" + "00" * 31 + "01"},
    ],
}


class TempRepo:
    """A throwaway repository with src/, out/ and config/."""

    def __init__(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)
        (self.root / "foundry.toml").write_text("[profile.default]\n", encoding="utf-8")
        self.config = copy.deepcopy(CONFIG)
        self.source("x/Foo.sol", FOO)
        self.artifact("Foo.sol", "Foo", METHODS)

    def source(self, relative: str, text: str) -> None:
        path = self.root / "src" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def artifact(self, file: str, contract: str, methods: dict) -> None:
        path = self.root / "out" / file / f"{contract}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"methodIdentifiers": methods}), encoding="utf-8")

    def problems(self) -> list[str]:
        return cg.check(
            self.config, cg.artifact_ids(self.root / "out"), cg.scan_sources(self.root / "src")
        )

    def run(self) -> tuple[int, str]:
        path = self.root / "config.json"
        path.write_text(json.dumps(self.config), encoding="utf-8")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cg.main(
                ["--root", str(self.root), "--config", str(path), "--artifacts",
                 str(self.root / "out")]
            )
        return code, out.getvalue()

    def close(self) -> None:
        self._dir.cleanup()


class CheckGenesisTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = TempRepo()
        self.foo = self.repo.config["contracts"][0]

    def tearDown(self) -> None:
        self.repo.close()

    def assertProblem(self, fragment: str) -> None:
        problems = self.repo.problems()
        self.assertTrue(any(fragment in p for p in problems), f"{fragment!r} not in {problems}")

    # -- source scanning ----------------------------------------------------------------

    def test_scan_finds_multiline_headers_and_ignores_comments_and_strings(self) -> None:
        found = cg.restricted_functions(FOO)
        self.assertEqual(found, {"Foo": {"setFee", "bindStream", "setAdmittedMinter"}})

    def test_scan_attributes_functions_to_their_contract(self) -> None:
        text = "contract A { function a() external restricted {} }\n" \
               "contract B { function b() external {} function c() external restricted {} }"
        self.assertEqual(cg.restricted_functions(text), {"A": {"a"}, "B": {"c"}})

    def test_scan_reads_restricted_after_other_modifiers(self) -> None:
        text = "contract A { function a(uint256 x) external nonReentrant restricted returns (bool) {} }"
        self.assertEqual(cg.restricted_functions(text), {"A": {"a"}})

    def test_scan_keeps_functions_in_their_own_contract_body(self) -> None:
        text = (
            "contract A { function a() external {} }\n"
            "contract B { function b() external restricted {} }"
        )
        self.assertEqual(cg.restricted_functions(text), {"B": {"b"}})

    def test_bases_parse_constructor_arguments_and_qualified_names(self) -> None:
        decl = cg.declarations(
            "contract C is A(1, f(2)), Lib.B, D { function x() external restricted {} }"
        )["C"]
        self.assertEqual(decl.bases, ["A", "B", "D"])
        self.assertFalse(decl.abstract)

    # -- inheritance ----------------------------------------------------------------------

    BASE = "abstract contract Base { function pauseAll() external restricted { } }"

    def _inherit(self) -> None:
        self.repo.source("x/Base.sol", self.BASE)
        self.repo.source("x/Foo.sol", FOO.replace("contract Foo {", "contract Foo is Base {"))
        self.repo.artifact("Foo.sol", "Foo", {**METHODS, "pauseAll()": "88888888"})

    def test_abstract_base_functions_count_for_their_concrete_children(self) -> None:
        self._inherit()
        scanned = cg.scan_sources(self.repo.root / "src")
        self.assertEqual(scanned["src/x/Foo.sol:Foo"],
                         {"setFee", "bindStream", "setAdmittedMinter", "pauseAll"})
        self.assertNotIn("src/x/Base.sol:Base", scanned)
        self.assertProblem("restricted pauseAll() in src/x/Foo.sol:Foo is not mapped")

    def test_abstract_base_is_not_an_unconfigured_contract(self) -> None:
        self._inherit()
        self.foo["deferred"] = [{"signature": "pauseAll()", "selector": "0x88888888"}]
        self.assertEqual(self.repo.problems(), [])

    def test_every_concrete_child_of_a_base_must_be_configured(self) -> None:
        self._inherit()
        self.foo["deferred"] = [{"signature": "pauseAll()", "selector": "0x88888888"}]
        self.repo.source("y/Bar.sol", "contract Bar is Base { }")
        self.assertProblem("src/y/Bar.sol:Bar has restricted functions but no contract")

    def test_inheritance_is_transitive(self) -> None:
        self.repo.source("x/Base.sol", self.BASE)
        self.repo.source("x/Mid.sol", "abstract contract Mid is Base(1) { }")
        self.repo.source("y/Bar.sol", "contract Bar is Mid, Other { }")
        self.assertEqual(
            cg.scan_sources(self.repo.root / "src")["src/y/Bar.sol:Bar"], {"pauseAll"}
        )

    # -- pending lanes ----------------------------------------------------------------------

    def _pending_contract(self) -> dict:
        pending = {
            "name": "Later",
            "address": "0x" + "00" * 19 + "0e",
            "artifact": "src/later/Later.sol:Later",
            "implementation": "src/later/Later.sol:Later",
            "functions": [{"signature": "setLater(uint256)", "selector": "0x12345678",
                           "role": "PARAMETER_SETTER", "class": "standard", "delay": 172800}],
            "genesisOnly": [{"signature": "bindStream(address)", "selector": "0x7d4b8f67"}],
            "deferred": [],
        }
        self.repo.config["contracts"].append(pending)
        self.repo.config["wiring"].append(
            {"contract": "Later", "signature": "bindStream(address)", "args": ["Peer"],
             "calldata": "0x7d4b8f67" + "00" * 31 + "01"}
        )
        return pending

    def test_contract_whose_source_is_not_merged_yet_passes_as_pending(self) -> None:
        self._pending_contract()
        present = cg.source_present(self.repo.root)
        problems = cg.check(
            self.repo.config, cg.artifact_ids(self.repo.root / "out"),
            cg.scan_sources(self.repo.root / "src"), present,
        )
        self.assertEqual(problems, [])
        self.assertEqual(cg.pending(self.repo.config, present), ["Later"])
        code, out = self.repo.run()
        self.assertEqual(code, 0, out)
        self.assertIn("pending (not merged yet): Later", out)

    def test_pending_contract_is_checked_in_full_once_its_source_lands(self) -> None:
        self._pending_contract()
        self.repo.source("later/Later.sol", "contract Later { function setLater(uint256 x) "
                         "external restricted {} function bindStream(address a) external "
                         "restricted {} function other() external restricted {} }")
        self.repo.artifact("Later.sol", "Later", {"setLater(uint256)": "12345678",
                                                   "bindStream(address)": "7d4b8f67",
                                                   "other()": "99999999"})
        code, out = self.repo.run()
        self.assertEqual(code, 1, out)
        self.assertIn("restricted other() in src/later/Later.sol:Later is not mapped", out)

    def test_pending_contract_still_needs_valid_roles_and_wiring(self) -> None:
        pending = self._pending_contract()
        pending["functions"][0]["role"] = "SYSTEM"
        self.repo.config["wiring"][-1]["signature"] = "setLater(uint256)"
        problems = cg.check(
            self.repo.config, cg.artifact_ids(self.repo.root / "out"),
            cg.scan_sources(self.repo.root / "src"), cg.source_present(self.repo.root),
        )
        self.assertTrue(any("unknown role SYSTEM" in p for p in problems), problems)
        self.assertTrue(any("not a genesis function" in p for p in problems), problems)

    # -- the clean case -----------------------------------------------------------------

    def test_clean_configuration_passes(self) -> None:
        self.assertEqual(self.repo.problems(), [])
        code, out = self.repo.run()
        self.assertEqual(code, 0, out)
        self.assertIn("1 contracts and 1 wiring calls match the build", out)

    # -- compiled ABI ---------------------------------------------------------------------

    def test_selector_mismatch_fails(self) -> None:
        self.foo["functions"][0]["selector"] = "0x99999999"
        self.assertProblem("setFee(uint256) selector 0x99999999 != compiled 0x11111111")

    def test_signature_missing_from_the_abi_fails(self) -> None:
        self.foo["functions"][0]["signature"] = "setFee(uint128)"
        self.assertProblem("functions setFee(uint128) is not a method of src/x/Foo.sol:Foo")

    # -- restricted coverage ------------------------------------------------------------

    def test_unlisted_restricted_function_fails(self) -> None:
        self.repo.source("x/Foo.sol", FOO.replace(
            "function fee()", "function setOther(uint256 x) external restricted { }\n    function fee()"
        ))
        self.repo.artifact("Foo.sol", "Foo", {**METHODS, "setOther(uint256)": "55555555"})
        self.assertProblem("restricted setOther(uint256) in src/x/Foo.sol:Foo is not mapped")

    def test_every_overload_of_a_restricted_function_is_required(self) -> None:
        self.repo.artifact("Foo.sol", "Foo", {**METHODS, "setFee(uint256,bool)": "66666666"})
        self.assertProblem("restricted setFee(uint256,bool)")

    def test_deferred_entries_count_as_covered(self) -> None:
        self.repo.source("x/Foo.sol", FOO.replace(
            "function fee()", "function bindLater(address x) external restricted { }\n    function fee()"
        ))
        self.repo.artifact("Foo.sol", "Foo", {**METHODS, "bindLater(address)": "77777777"})
        self.foo["deferred"] = [{"signature": "bindLater(address)", "selector": "0x77777777"}]
        self.assertEqual(self.repo.problems(), [])

    def test_restricted_contract_missing_from_the_configuration_fails(self) -> None:
        self.repo.source("y/Bar.sol", "contract Bar { function set() external restricted {} }")
        self.assertProblem("src/y/Bar.sol:Bar has restricted functions but no contract")

    def test_pending_interface_without_implementation_reports_the_unconfigured_source(self) -> None:
        self.foo["implementation"] = None
        self.assertProblem("src/x/Foo.sol:Foo has restricted functions but no contract")

    # -- roles and delays -----------------------------------------------------------------

    def test_delay_or_class_mismatch_fails(self) -> None:
        self.foo["functions"][0]["delay"] = 0
        self.assertProblem("setFee(uint256) delay 0 / class standard does not match")
        self.foo["functions"][0]["delay"] = 172800
        self.foo["functions"][0]["class"] = "funds"
        self.assertProblem("setFee(uint256) delay 172800 / class funds does not match")

    def test_unknown_role_fails(self) -> None:
        self.foo["functions"][0]["role"] = "SYSTEM"
        self.assertProblem("setFee(uint256) has unknown role SYSTEM")

    # -- wiring -------------------------------------------------------------------------

    def test_genesis_only_entry_must_be_wired(self) -> None:
        self.repo.config["wiring"] = []
        self.assertProblem("genesis-only bindStream(address) is not wired")

    def test_deferred_entry_must_not_be_wired(self) -> None:
        self.foo["deferred"] = self.foo.pop("genesisOnly")
        self.foo["genesisOnly"] = []
        self.assertProblem("deferred bindStream(address) is wired")

    def test_wiring_a_non_genesis_function_fails(self) -> None:
        self.repo.config["wiring"].append(
            {"contract": "Foo", "signature": "setFee(uint256)", "args": [],
             "calldata": "0x11111111" + "00" * 32}
        )
        self.assertProblem("Foo.setFee(uint256): not a genesis function")

    def test_wiring_calldata_must_start_with_the_selector(self) -> None:
        self.repo.config["wiring"][0]["calldata"] = "0x33333333" + "00" * 32
        self.assertProblem("calldata selector 0x33333333 != 0x22222222")

    def test_wiring_literal_arguments_are_not_names(self) -> None:
        self.repo.config["wiring"][0]["args"] = ["0x" + "00" * 19 + "01"]
        self.assertEqual(self.repo.problems(), [])

    def test_wiring_unknown_contract_and_argument_fail(self) -> None:
        self.repo.config["wiring"][0]["args"] = ["Nobody"]
        self.assertProblem("argument Nobody names no contract or peer")
        self.repo.config["wiring"].append(
            {"contract": "Ghost", "signature": "bindStream(address)", "calldata": "0x22222222"}
        )
        self.assertProblem("Ghost.bindStream(address): unknown contract")

    def test_wiring_calldata_must_be_even_length_hex(self) -> None:
        for bad in ("0x2222222", "22222222" + "00" * 32, "0x2222zz22" + "00" * 32, "0x"):
            self.repo.config["wiring"][0]["calldata"] = bad
            self.assertProblem("calldata is not 0x-prefixed, even-length hex with a selector")

    def test_wiring_calldata_length_must_match_static_arguments(self) -> None:
        self.repo.config["wiring"][0]["calldata"] = "0x22222222"
        self.assertProblem("calldata has 0 argument bytes, expected 32")
        self.repo.config["wiring"][0]["calldata"] = "0x22222222" + "00" * 64
        self.assertProblem("calldata has 64 argument bytes, expected 32")

    def test_wiring_arguments_must_encode_their_named_peers(self) -> None:
        self.repo.config["wiring"][0]["calldata"] = "0x22222222" + "00" * 31 + "02"
        self.assertProblem("argument 0 is not the address of Peer")
        self.repo.config["wiring"] = [
            {"contract": "Foo", "signature": "bindStream(address)", "args": ["Peer"],
             "calldata": "0x22222222" + "00" * 31 + "01"},
            {"contract": "Foo", "signature": "setAdmittedMinter(address,bool)",
             "args": ["Peer", True], "calldata": "0x33333333" + "00" * 31 + "01" + "00" * 32},
        ]
        self.assertProblem("argument 1 is not true")

    def test_dynamic_signatures_skip_the_length_check(self) -> None:
        self.assertIsNone(cg._static_params("append((address,uint256),string)"))
        self.assertEqual(cg._static_params("setTarget(address,bool)"), ["address", "bool"])
        self.assertEqual(cg._static_params("pause()"), [])

    # -- malformed input fails closed ---------------------------------------------------

    def _main_error(self, *argv: str) -> str:
        with self.assertRaises(SystemExit) as raised, contextlib.redirect_stdout(io.StringIO()):
            cg.main(["--root", str(self.repo.root), *argv])
        return str(raised.exception)

    def test_missing_or_invalid_configuration_fails_with_a_message(self) -> None:
        missing = self.repo.root / "nope.json"
        self.assertIn("cannot read the genesis configuration", self._main_error("--config", str(missing)))
        bad = self.repo.root / "bad.json"
        bad.write_text("{not json", encoding="utf-8")
        self.assertIn("cannot read the genesis configuration", self._main_error("--config", str(bad)))
        bad.write_text("[]", encoding="utf-8")
        self.assertIn("must be a JSON object", self._main_error("--config", str(bad)))

    def test_missing_keys_fail_with_a_message(self) -> None:
        del self.foo["artifact"]
        path = self.repo.root / "config.json"
        path.write_text(json.dumps(self.repo.config), encoding="utf-8")
        error = self._main_error("--config", str(path), "--artifacts", str(self.repo.root / "out"))
        self.assertIn("malformed configuration (KeyError", error)

    def test_malformed_artifact_reference_and_artifact_fail_with_a_message(self) -> None:
        self.foo["artifact"] = "Foo"
        with self.assertRaises(SystemExit) as raised:
            self.repo.problems()
        self.assertIn("malformed artifact reference", str(raised.exception))
        self.foo["artifact"] = "src/x/Foo.sol:Foo"
        (self.repo.root / "out" / "Foo.sol" / "Foo.json").write_text("{}", encoding="utf-8")
        with self.assertRaises(SystemExit) as raised:
            self.repo.problems()
        self.assertIn("no methodIdentifiers object", str(raised.exception))

    # -- command line -----------------------------------------------------------------------

    def test_main_fails_with_a_problem_count(self) -> None:
        self.foo["functions"][0]["selector"] = "0x99999999"
        code, out = self.repo.run()
        self.assertEqual(code, 1)
        self.assertIn("FAIL Foo: functions setFee(uint256) selector", out)
        self.assertIn("genesis configuration: 1 problem(s)", out)

    def test_missing_artifact_stops_with_a_message(self) -> None:
        self.foo["artifact"] = "src/x/Missing.sol:Missing"
        with self.assertRaises(SystemExit) as raised:
            self.repo.problems()
        self.assertIn("run forge build", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
