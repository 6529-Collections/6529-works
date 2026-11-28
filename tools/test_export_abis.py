"""Unit tests for export_abis.py, which sits beside this file.

Run with `python tools/test_export_abis.py` or, from the repository root,
`python -m tools.test_export_abis`. The last test also checks the real build in out/ against the
interface IDs that test/interfaces/InterfacesCompile.t.sol pins; it is skipped when out/ has not
been built.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "export_abis", Path(__file__).with_name("export_abis.py")
)
ea = importlib.util.module_from_spec(_SPEC)
sys.modules["export_abis"] = ea
_SPEC.loader.exec_module(ea)

ROOT = Path(__file__).resolve().parents[1]


def _fn(name: str, *types: str, mutability: str = "nonpayable") -> dict:
    return {
        "type": "function",
        "name": name,
        "inputs": [{"name": "", "type": t, "internalType": t} for t in types],
        "outputs": [],
        "stateMutability": mutability,
    }


# The contracts with a full ABI, and what each forwards to, written out here rather than read
# from the exporter, so dropping one from export_abis.FORWARDED fails the tests.
EXPECTED_FORWARDED = {
    "UniformEditionAuction": "UniformEditionAuctionLens",
    "IndependentEditionAuction": "IndependentEditionAuctionLens",
}
# Where each forwarding contract is declared (the exporter matches by source path).
FORWARDED_SOURCES = {
    "UniformEditionAuction": "src/sales/UniformEditionAuction.sol",
    "IndependentEditionAuction": "src/independent/IndependentEditionAuction.sol",
}


def _sel(sig: str, value: int) -> tuple[str, str]:
    return sig, f"{value:08x}"


class FakeRepo:
    """A throwaway repository with src/ sources and forge-style artifacts in out/."""

    def __init__(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)
        (self.root / "foundry.toml").write_text("", encoding="utf-8")

    def source(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def artifact(
        self, rel: str, name: str, abi: list, selectors: dict, folder: str = ""
    ) -> None:
        # forge nests an artifact under part of its path when two sources share a file name.
        path = self.root / "out" / folder / Path(rel).name / f"{name}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        data = {
            "abi": abi,
            "bytecode": {"object": "0x6000"},
            "deployedBytecode": {"object": "0x6000"},
            "methodIdentifiers": selectors,
            "metadata": {
                "compiler": {"version": "0.8.37+commit.f401782d"},
                "settings": {"compilationTarget": {rel: name}},
            },
        }
        path.write_text(json.dumps(data), encoding="utf-8")

    def close(self) -> None:
        self._dir.cleanup()


def _standard(repo: FakeRepo) -> None:
    """A parent interface, a child that overloads one of its names, a contract, a library, an
    abstract contract, an external interface and the three forwarded pairs."""
    repo.source(
        "src/interfaces/IParent.sol",
        "interface IParent {\n  function pause() external;\n  function a(uint256 x) external;\n}\n",
    )
    repo.source(
        "src/interfaces/IChild.sol",
        "// interface Fake { function nope() external; }\n"
        "interface IChild is IParent {\n"
        "  /* function hidden() external; */\n"
        "  function pause(uint256 id, bytes32 ref) external;\n"
        '  function b(string calldata s) external; // "function c("\n'
        "}\n",
    )
    repo.source("src/interfaces/external/IOther.sol", "interface IOther { function o() external; }\n")
    repo.source("src/Thing.sol", "contract Thing is IChild {\n function pause() external {}\n}\n")
    repo.source("src/Lib.sol", "library Lib { function f() external {} }\n")
    repo.source("src/Base.sol", "abstract contract Base { function g() external {} }\n")
    parent = [_fn("pause"), _fn("a", "uint256")]
    parent_sel = dict([_sel("pause()", 0x8456CB59), _sel("a(uint256)", 0x00000F00)])
    child = parent + [_fn("pause", "uint256", "bytes32"), _fn("b", "string")]
    child_sel = dict(parent_sel, **dict([_sel("pause(uint256,bytes32)", 0x0000000F), _sel("b(string)", 0x00F00000)]))
    repo.artifact("src/interfaces/IParent.sol", "IParent", parent, parent_sel)
    repo.artifact("src/interfaces/IChild.sol", "IChild", child, child_sel)
    repo.artifact("src/interfaces/external/IOther.sol", "IOther", [_fn("o")], {"o()": "11111111"})
    event = {"type": "event", "name": "Done", "inputs": [], "anonymous": False}
    repo.artifact("src/Thing.sol", "Thing", list(reversed(child)) + [event], child_sel)
    repo.artifact("src/Lib.sol", "Lib", [_fn("f")], {"f()": "22222222"})
    repo.artifact("src/Base.sol", "Base", [_fn("g")], {"g()": "33333333"})
    for name, lens in EXPECTED_FORWARDED.items():
        repo.source(FORWARDED_SOURCES[name], f"contract {name} {{ function own() external {{}} }}\n")
        kind = "interface" if lens.startswith("I") else "contract"
        folder = "src/interfaces" if kind == "interface" else "src"
        repo.source(f"{folder}/{lens}.sol", f"{kind} {lens} {{ function view1() external; }}\n")
        repo.artifact(FORWARDED_SOURCES[name], name, [_fn("own")], {"own()": "44444444"})
        ctor = {"type": "constructor", "inputs": [], "stateMutability": "nonpayable"}
        # write1 changes state, like a lens's masterTerms: the auction's read-only staticcall
        # cannot serve it, so it stays out of the full ABI.
        lens_abi = [_fn("view1", mutability="view"), _fn("own"), _fn("write1"), ctor]
        lens_sel = {"view1()": "55555555", "own()": "44444444", "write1()": "77777777"}
        repo.artifact(f"{folder}/{lens}.sol", lens, lens_abi, lens_sel)


class ExportTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = FakeRepo()
        _standard(self.repo)

    def tearDown(self) -> None:
        self.repo.close()

    def _run(self, *args: str) -> tuple[int, str]:
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            code = ea.main(["--root", str(self.repo.root), *args])
        return code, err.getvalue()

    def _manifest(self) -> dict:
        data = (self.repo.root / "abi" / "manifest.json").read_text(encoding="utf-8")
        return {c["name"]: c for c in json.loads(data)["contracts"]}

    def test_ExportsContractsAndPublicInterfacesOnly(self) -> None:
        self.assertEqual(self._run()[0], 0)
        names = set(self._manifest())
        self.assertIn("Thing", names)
        self.assertIn("IParent", names)
        self.assertIn("IChild", names)
        for excluded in ("Lib", "Base", "IOther"):
            self.assertNotIn(excluded, names)

    def test_InterfaceIdCountsOwnFunctionsOnlyAndSeparatesOverloads(self) -> None:
        self._run()
        m = self._manifest()
        self.assertEqual(m["IParent"]["interfaceId"], f"0x{0x8456CB59 ^ 0x00000F00:08x}")
        # pause(uint256,bytes32) and b(string); not the inherited pause() or a(uint256), nor the
        # commented-out and string-literal "functions".
        self.assertEqual(m["IChild"]["interfaceId"], f"0x{0x0000000F ^ 0x00F00000:08x}")
        self.assertNotIn("interfaceId", m["Thing"])

    def test_OutputIsSortedAndCarriesNoBytecodeOrMetadata(self) -> None:
        self._run()
        text = (self.repo.root / "abi" / "Thing.json").read_text(encoding="utf-8")
        abi = json.loads(text)
        # The artifact lists them reversed; the export orders by kind, name and signature.
        self.assertEqual(
            [ea.signature(e) for e in abi],
            ["a(uint256)", "b(string)", "pause()", "pause(uint256,bytes32)", "Done()"],
        )
        self.assertEqual([e["type"] for e in abi][-1], "event")
        for word in ("bytecode", "metadata", "0x6000", "compilationTarget"):
            self.assertNotIn(word, text)
        entry = self._manifest()["Thing"]
        self.assertEqual((entry["functions"], entry["events"], entry["errors"]), (4, 1, 0))
        self.assertEqual(entry["solc"], "0.8.37+commit.f401782d")
        self.assertEqual(entry["source"], "src/Thing.sol")

    def test_ExportIsDeterministicAndHashesTheBytes(self) -> None:
        self._run()
        first = ea.existing(self.repo.root / "abi")
        self._run()
        self.assertEqual(first, ea.existing(self.repo.root / "abi"))
        import hashlib

        entry = self._manifest()["Thing"]
        self.assertEqual(entry["sha256"], hashlib.sha256(first["Thing.json"]).hexdigest())

    def test_FullAbiMergesTheForwardedSurface(self) -> None:
        self._run()
        m = self._manifest()
        fulls = {p.name for p in (self.repo.root / "abi" / "full").glob("*.json")}
        self.assertEqual(fulls, {f"{name}.json" for name in EXPECTED_FORWARDED})
        for name, lens in EXPECTED_FORWARDED.items():
            self.assertEqual(m[name]["forwardsTo"], lens)
            self.assertEqual(m[name]["fullAbi"], f"full/{name}.json")
            full = json.loads((self.repo.root / "abi" / "full" / f"{name}.json").read_text("utf-8"))
            sigs = [ea.signature(e) for e in full]
            # No duplicate, no constructor, and not the lens's state-changing write1.
            self.assertEqual(sigs, ["own()", "view1()"], name)
            lens_abi = json.loads((self.repo.root / "abi" / f"{lens}.json").read_text("utf-8"))
            self.assertIn("write1()", [ea.signature(e) for e in lens_abi], lens)

    def test_CheckPassesOnAFreshExport(self) -> None:
        self._run()
        self.assertEqual(self._run("--check"), (0, ""))

    def test_CheckFailsOnDriftMissingAndStaleFiles(self) -> None:
        self._run()
        abi = self.repo.root / "abi"
        (abi / "Thing.json").write_text("[]\n", encoding="utf-8")
        (abi / "IParent.json").unlink()
        (abi / "Gone.json").write_text("[]\n", encoding="utf-8")
        code, err = self._run("--check")
        self.assertEqual(code, 1)
        self.assertIn("abi/Thing.json: differs", err)
        self.assertIn("abi/IParent.json: missing", err)
        self.assertIn("abi/Gone.json: committed but not produced", err)

    def test_CheckWritesNothing(self) -> None:
        self.assertEqual(self._run("--check")[0], 1)
        self.assertFalse((self.repo.root / "abi").exists())

    def test_WriteRemovesStaleFiles(self) -> None:
        self._run()
        (self.repo.root / "abi" / "Gone.json").write_text("[]\n", encoding="utf-8")
        self._run()
        self.assertFalse((self.repo.root / "abi" / "Gone.json").exists())

    def test_LeftoverArtifactsOfARestoredCacheAreSkipped(self) -> None:
        # A restored `out/` can hold artifacts of a deleted source and of a contract its source
        # no longer declares. Neither is part of the build, so neither is exported.
        self._run()
        before = sorted(p.name for p in (self.repo.root / "abi").glob("*.json"))
        self.repo.artifact("src/sales/Deleted.sol", "Deleted", [_fn("old")], {"old()": "66666666"})
        self.repo.artifact("src/Thing.sol", "Renamed", [_fn("old")], {"old()": "66666666"})
        self.assertEqual(self._run("--check"), (0, ""))
        self._run()
        after = sorted(p.name for p in (self.repo.root / "abi").glob("*.json"))
        self.assertEqual(after, before)

    def test_APlainCoreNamesakeIsExportedUnderCore(self) -> None:
        self.repo.source("src/core/Thing.sol", "contract Thing { function fresh() external {} }\n")
        self.repo.artifact("src/core/Thing.sol", "Thing", [_fn("fresh")], {"fresh()": "66666666"}, "core")
        self.assertEqual(self._run()[0], 0)
        manifest = json.loads((self.repo.root / "abi" / "manifest.json").read_text("utf-8"))
        by_file = {c["abi"]: c for c in manifest["contracts"]}
        self.assertEqual(by_file["Thing.json"]["source"], "src/Thing.sol")
        self.assertEqual(by_file["core/Thing.json"]["source"], "src/core/Thing.sol")
        self.assertEqual(by_file["core/Thing.json"]["name"], "Thing")
        self.assertTrue((self.repo.root / "abi" / "core" / "Thing.json").is_file())
        self.assertEqual(self._run("--check")[0], 0)

    def test_TwoNamesakesOutsideTheCoreFail(self) -> None:
        self.repo.source("src/other/Thing.sol", "contract Thing { function x() external {} }\n")
        self.repo.artifact("src/other/Thing.sol", "Thing", [_fn("x")], {"x()": "66666666"}, "other")
        code, err = self._run()
        self.assertEqual(code, 2)
        self.assertIn("two exported contracts are named Thing", err)

    def test_AForwardedSurfaceMissingFromTheBuildFails(self) -> None:
        for f in (self.repo.root / "out" / "UniformEditionAuctionLens.sol").glob("*.json"):
            f.unlink()
        (self.repo.root / "src" / "UniformEditionAuctionLens.sol").unlink()
        code, err = self._run()
        self.assertEqual(code, 2)
        self.assertIn("forwards to UniformEditionAuctionLens, which the build lacks", err)

    def test_InterfaceIdLeavesOutASameArityInheritedOverload(self) -> None:
        # Solidity accepts a child's f(address) beside its parent's f(uint256); the child's ID
        # counts only f(address).
        self.repo.source("src/interfaces/IP2.sol", "interface IP2 {\n  function f(uint256 x) external;\n}\n")
        self.repo.source(
            "src/interfaces/IC2.sol", "interface IC2 is IP2 {\n  function f(address a) external;\n}\n"
        )
        parent_sel = {"f(uint256)": "000000f0"}
        self.repo.artifact("src/interfaces/IP2.sol", "IP2", [_fn("f", "uint256")], parent_sel)
        child = [_fn("f", "uint256"), _fn("f", "address")]
        self.repo.artifact("src/interfaces/IC2.sol", "IC2", child, dict(parent_sel, **{"f(address)": "00000f00"}))
        self.assertEqual(self._run(), (0, ""))
        self.assertEqual(self._manifest()["IC2"]["interfaceId"], "0x00000f00")

    def test_WriteAndCheckLeaveUnmanagedFilesAlone(self) -> None:
        self._run()
        readme = self.repo.root / "abi" / "README.md"
        readme.write_text("notes\n", encoding="utf-8")
        self.assertEqual(self._run("--check"), (0, ""))
        self._run()
        self.assertTrue(readme.is_file())

    def _assert_export_refused(self, needle: str) -> None:
        before = ea.existing(self.repo.root / "abi")
        code, err = self._run()
        self.assertEqual(code, 2)
        self.assertIn(needle, err)
        self.assertEqual(ea.existing(self.repo.root / "abi"), before, "the export is unchanged")
        self.assertEqual(self._run("--check")[0], 2)

    def test_MalformedArtifactsFailWithTheirPath(self) -> None:
        self._run()
        path = self.repo.root / "out" / "IParent.sol" / "IParent.json"
        good = path.read_text(encoding="utf-8")
        for bad in (good[: len(good) // 2], "[]", good.replace('"abi": [', '"abi": null, "x": [', 1)):
            path.write_text(bad, encoding="utf-8")
            self._assert_export_refused(str(path))

    def test_ADeclaredContractMissingFromTheBuildFails(self) -> None:
        self._run()
        (self.repo.root / "out" / "IParent.sol" / "IParent.json").unlink()
        self._assert_export_refused("missing from the build: IParent")

    def _open_gate(self, built: bool = True) -> None:
        rel = "script/sepolia/SepoliaOpenGate.sol"
        self.repo.source(
            rel,
            "interface IGateTarget { function t() external; }\n"
            "contract SepoliaOpenGate { function open() external {} }\n",
        )
        self.repo.source("script/Other.s.sol", "contract Other { function x() external {} }\n")
        self.repo.artifact("script/Other.s.sol", "Other", [_fn("x")], {"x()": "88888888"})
        self.repo.artifact(rel, "IGateTarget", [_fn("t")], {"t()": "99999999"})
        if built:
            self.repo.artifact(rel, "SepoliaOpenGate", [_fn("open")], {"open()": "aaaaaaaa"})

    def test_TheTestOnlyOpenGateIsExportedAndMarked(self) -> None:
        self._open_gate()
        self.assertEqual(self._run()[0], 0)
        manifest = self._manifest()
        gate = manifest["SepoliaOpenGate"]
        self.assertIs(gate["testOnly"], True)
        self.assertEqual(gate["source"], "script/sepolia/SepoliaOpenGate.sol")
        self.assertEqual((gate["kind"], gate["functions"]), ("contract", 1))
        self.assertTrue((self.repo.root / "abi" / "SepoliaOpenGate.json").is_file())
        # Nothing else outside src/ is exported, and no protocol contract is marked.
        self.assertNotIn("Other", manifest)
        self.assertNotIn("IGateTarget", manifest)
        self.assertNotIn("testOnly", manifest["Thing"])
        self.assertEqual(self._run("--check")[0], 0)

    def test_ATestOnlyContractMissingFromTheBuildFails(self) -> None:
        self._open_gate(built=False)
        self._assert_export_refused("missing from the build: SepoliaOpenGate")

    def test_NoBuildFailsClearly(self) -> None:
        import shutil

        shutil.rmtree(self.repo.root / "out")
        code, err = self._run()
        self.assertEqual(code, 2)
        self.assertIn("run `forge build` first", err)


class OwnFunctionsTest(unittest.TestCase):
    def test_CountsTopLevelParameters(self) -> None:
        body = ea.strip_solidity(
            "function a() external;\n"
            "function b(uint256[] calldata x, (uint256, address) memory y) external;\n"
            "function c(mapping(uint256 => uint256) storage m) internal;\n"
        )
        self.assertEqual(ea.own_functions(body), [("a", 0), ("b", 2), ("c", 1)])

    def test_ABlockCommentSeparatesTokens(self) -> None:
        body = ea.strip_solidity("function/* note */f() external;\nfunction/**/g(uint256 x) external;")
        self.assertEqual(ea.own_functions(body), [("f", 0), ("g", 1)])

    def test_SameArityOverloadsCountOncePerDeclaration(self) -> None:
        body = ea.strip_solidity("function f(uint256 x) external;\nfunction f(address a) external;")
        self.assertEqual(ea.own_functions(body), [("f", 1), ("f", 1)])


class InterfaceIdTest(unittest.TestCase):
    ABI = [_fn("f", "uint256"), _fn("f", "address"), _fn("g")]
    SELECTORS = {"f(uint256)": "000000f0", "f(address)": "00000f00", "g()": "0000f000"}

    def test_ASameArityInheritedOverloadIsLeftOut(self) -> None:
        # The child declares f(address); its parent declares f(uint256).
        value = ea.interface_id(self.ABI, self.SELECTORS, [("f", 1)], {"f(uint256)"})
        self.assertEqual(value, "0x00000f00")

    def test_TwoOwnOverloadsOfOneArityAreBothCounted(self) -> None:
        value = ea.interface_id(self.ABI, self.SELECTORS, [("f", 1), ("f", 1), ("g", 0)], set())
        self.assertEqual(value, f"0x{0xF0 ^ 0xF00 ^ 0xF000:08x}")

    def test_AnAmbiguousMatchFails(self) -> None:
        with self.assertRaises(ea.ExportError):
            ea.interface_id(self.ABI, self.SELECTORS, [("f", 1)], None)

    def test_ParentsAreReadFromTheDeclaration(self) -> None:
        code = ea.strip_solidity("interface IC is IA, Lib.IB /* x */ {\n function f() external;\n}")
        self.assertEqual(ea.declarations(code)[0][3], ["IA", "Lib.IB"])


@unittest.skipUnless((ROOT / "out" / "Stream6529.sol" / "Stream6529.json").is_file(), "out/ not built")
class RealBuildTest(unittest.TestCase):
    """The exporter's interface IDs equal the IDs the Solidity suite pins with
    `type(I).interfaceId`."""

    def test_InterfaceIdsMatchThePinnedOnes(self) -> None:
        found = ea.collect(ROOT, ROOT / "out")
        manifest = json.loads(ea.render(found)[ea.MANIFEST])
        # The pinned IDs are the old interfaces'; a plain-core namesake is under core/.
        ids = {
            c["name"]: c.get("interfaceId")
            for c in manifest["contracts"]
            if not c["abi"].startswith(ea.CORE_PREFIX)
        }
        pinned = re.findall(
            r"type\((\w+)\)\.interfaceId,\s*bytes4\((0x[0-9a-f]{8})\)",
            (ROOT / "test" / "interfaces" / "InterfacesCompile.t.sol").read_text("utf-8"),
        )
        self.assertGreater(len(pinned), 20)
        for name, value in pinned:
            self.assertEqual(ids.get(name), value, name)


if __name__ == "__main__":
    unittest.main()
