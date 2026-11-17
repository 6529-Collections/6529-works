"""Unit tests for check_snapshots.py, which sits beside this file.

Run with `python tools/test_check_snapshots.py` or, from the repository root,
`python -m tools.test_check_snapshots`. Each test builds a small repository with hand-written
Foundry artifacts in a temporary directory, writes its snapshots, plants one change, and shows
that the checker reports it.
"""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "check_snapshots", Path(__file__).with_name("check_snapshots.py")
)
cs = importlib.util.module_from_spec(_SPEC)
sys.modules["check_snapshots"] = cs
_SPEC.loader.exec_module(cs)

SOURCE = """// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

interface IVault {
    function pay(address to, uint256 amount) external;
}

abstract contract VaultBase { }

contract Vault is VaultBase {
    struct Account {
        uint128 balance;
        uint64 since;
    }
}

library VaultMath { }
"""

VAULT_ABI = [
    {
        "type": "function",
        "name": "pay",
        "inputs": [
            {"name": "to", "type": "address", "internalType": "address"},
            {"name": "amount", "type": "uint256", "internalType": "uint256"},
        ],
        "outputs": [],
        "stateMutability": "nonpayable",
    },
    {
        "type": "function",
        "name": "account",
        "inputs": [{"name": "who", "type": "address", "internalType": "address"}],
        "outputs": [
            {
                "name": "",
                "type": "tuple",
                "internalType": "struct Vault.Account",
                "components": [
                    {"name": "balance", "type": "uint128", "internalType": "uint128"},
                    {"name": "since", "type": "uint64", "internalType": "uint64"},
                ],
            }
        ],
        "stateMutability": "view",
    },
    {
        "type": "event",
        "name": "Paid",
        "inputs": [
            {"name": "to", "type": "address", "indexed": True, "internalType": "address"},
            {"name": "amount", "type": "uint256", "indexed": False, "internalType": "uint256"},
        ],
        "anonymous": False,
    },
    {
        "type": "error",
        "name": "Insufficient",
        "inputs": [{"name": "needed", "type": "uint256", "internalType": "uint256"}],
    },
]

VAULT_LAYOUT = {
    "storage": [
        {"astId": 11, "contract": "src/Vault.sol:Vault", "label": "owner", "offset": 0, "slot": "0", "type": "t_address"},
        {
            "astId": 17,
            "contract": "src/Vault.sol:Vault",
            "label": "accounts",
            "offset": 0,
            "slot": "1",
            "type": "t_mapping(t_address,t_struct(Account)9_storage)",
        },
    ],
    "types": {
        "t_address": {"encoding": "inplace", "label": "address", "numberOfBytes": "20"},
        "t_mapping(t_address,t_struct(Account)9_storage)": {
            "encoding": "mapping",
            "key": "t_address",
            "label": "mapping(address => struct Vault.Account)",
            "numberOfBytes": "32",
            "value": "t_struct(Account)9_storage",
        },
        "t_struct(Account)9_storage": {
            "encoding": "inplace",
            "label": "struct Vault.Account",
            "members": [
                {"astId": 5, "contract": "src/Vault.sol:Vault", "label": "balance", "offset": 0, "slot": "0", "type": "t_uint128"},
                {"astId": 8, "contract": "src/Vault.sol:Vault", "label": "since", "offset": 16, "slot": "0", "type": "t_uint64"},
            ],
            "numberOfBytes": "32",
        },
        "t_uint128": {"encoding": "inplace", "label": "uint128", "numberOfBytes": "16"},
        "t_uint64": {"encoding": "inplace", "label": "uint64", "numberOfBytes": "8"},
    },
}

MATH_ABI = [{"type": "error", "name": "Overflow", "inputs": []}]


class TempRepo:
    def __init__(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.write("src/Vault.sol", SOURCE)
        self.vault = {
            "abi": copy.deepcopy(VAULT_ABI),
            "methodIdentifiers": {"pay(address,uint256)": "c4076876", "account(address)": "73b9aa91"},
            "storageLayout": copy.deepcopy(VAULT_LAYOUT),
        }
        self.math = {"abi": copy.deepcopy(MATH_ABI), "methodIdentifiers": {}}
        self.save()

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def save(self) -> None:
        self.write("out/Vault.sol/Vault.json", json.dumps(self.vault))
        self.write("out/Vault.sol/VaultMath.json", json.dumps(self.math))

    def run(self, *args: str) -> tuple[int, str]:
        with contextlib.redirect_stdout(io.StringIO()) as out:
            code = cs.main(list(args), root=self.root)
        return code, out.getvalue()

    def cleanup(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)


class CheckSnapshotsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = TempRepo()
        self.addCleanup(self.repo.cleanup)
        code, _ = self.repo.run("--update")
        self.assertEqual(code, 0)

    def assertDrift(self, needle: str) -> str:
        code, out = self.repo.run()
        self.assertEqual(code, 1, out)
        self.assertIn(needle, out)
        return out

    def test_TheSnapshotsMatchTheBuildTheyWereWrittenFrom(self) -> None:
        code, out = self.repo.run()
        self.assertEqual(code, 0, out)
        self.assertIn("2 contracts and libraries", out)

    def test_OnlyContractsAndLibrariesGetSnapshots(self) -> None:
        names = sorted(p.relative_to(self.repo.root / "test/snapshots").as_posix()
                       for p in (self.repo.root / "test/snapshots").rglob("*.json"))
        self.assertEqual(names, ["abi/Vault.json", "abi/VaultMath.json", "storage/Vault.json"])

    def test_TheAbiSnapshotCarriesSelectorsAndTopics(self) -> None:
        abi = json.loads((self.repo.root / "test/snapshots/abi/Vault.json").read_text(encoding="utf-8"))
        ids = {e["signature"]: e["id"] for e in abi if "signature" in e}
        self.assertEqual(ids["pay(address,uint256)"], "0xc4076876")
        self.assertEqual(ids["account(address)"], "0x73b9aa91")
        self.assertEqual(ids["Insufficient(uint256)"], "0x" + cs.keccak256(b"Insufficient(uint256)").hex()[:8])
        self.assertEqual(ids["Paid(address,uint256)"], "0x" + cs.keccak256(b"Paid(address,uint256)").hex())

    def test_TheStorageSnapshotHasNoAstIds(self) -> None:
        text = (self.repo.root / "test/snapshots/storage/Vault.json").read_text(encoding="utf-8")
        self.assertNotIn("astId", text)
        self.assertNotIn(")9_", text)
        self.assertIn('"struct Vault.Account"', text)

    def test_ARenamedParameterFails(self) -> None:
        self.repo.vault["abi"][0]["inputs"][0]["name"] = "recipient"
        self.repo.save()
        self.assertDrift('"name": "recipient"')

    def test_AChangedEventFails(self) -> None:
        self.repo.vault["abi"][2]["inputs"][1]["indexed"] = True
        self.repo.save()
        self.assertDrift("abi/Vault.json")

    def test_AnEventWithANewParameterTypeChangesItsTopic(self) -> None:
        self.repo.vault["abi"][2]["inputs"][1]["type"] = "uint128"
        self.repo.save()
        out = self.assertDrift("Paid(address,uint128)")
        self.assertIn(cs.keccak256(b"Paid(address,uint128)").hex(), out)

    def test_ANewErrorFails(self) -> None:
        self.repo.math["abi"].append({"type": "error", "name": "Underflow", "inputs": []})
        self.repo.save()
        self.assertDrift("Underflow()")

    def test_AMovedSlotFails(self) -> None:
        self.repo.vault["storageLayout"]["storage"][1]["slot"] = "2"
        self.repo.save()
        self.assertDrift('"slot": 2')

    def test_ARetypedStructMemberFails(self) -> None:
        member = self.repo.vault["storageLayout"]["types"]["t_struct(Account)9_storage"]["members"][1]
        member["type"] = "t_uint128"
        self.repo.save()
        self.assertDrift("storage/Vault.json")

    def test_AStructMemberMovedWithinItsSlotFails(self) -> None:
        member = self.repo.vault["storageLayout"]["types"]["t_struct(Account)9_storage"]["members"][1]
        member["offset"] = 20
        self.repo.save()
        self.assertDrift('"offset": 20')

    def test_ANewAstIdAloneChangesNothing(self) -> None:
        layout = self.repo.vault["storageLayout"]
        text = json.dumps(layout).replace("(Account)9_", "(Account)4242_").replace('"astId": 17', '"astId": 99')
        self.repo.vault["storageLayout"] = json.loads(text)
        self.repo.save()
        code, out = self.repo.run()
        self.assertEqual(code, 0, out)

    def test_ANewContractWithoutASnapshotFails(self) -> None:
        self.repo.write("src/Extra.sol", "contract Extra { }\n")
        self.repo.write("out/Extra.sol/Extra.json", json.dumps({"abi": [], "storageLayout": {"storage": [], "types": None}}))
        self.assertDrift("missing snapshot test/snapshots/abi/Extra.json")

    def test_ARemovedContractLeavesAStaleSnapshotThatFails(self) -> None:
        self.repo.write("src/Vault.sol", SOURCE.replace("library VaultMath { }", ""))
        self.assertDrift("stale snapshot test/snapshots/abi/VaultMath.json")

    def test_UpdateRewritesAndRemovesStaleSnapshots(self) -> None:
        self.repo.write("src/Vault.sol", SOURCE.replace("library VaultMath { }", ""))
        self.repo.vault["storageLayout"]["storage"][1]["slot"] = "2"
        self.repo.save()
        code, out = self.repo.run("--update")
        self.assertEqual(code, 0)
        self.assertIn("removed 1 stale", out)
        self.assertEqual(self.repo.run()[0], 0)

    def test_AnArtifactWithoutAStorageLayoutIsAnError(self) -> None:
        del self.repo.vault["storageLayout"]
        self.repo.save()
        code, out = self.repo.run()
        self.assertEqual(code, 2)
        self.assertIn("extra_output", out)

    def test_AMissingArtifactIsAnError(self) -> None:
        (self.repo.root / "out/Vault.sol/VaultMath.json").unlink()
        code, out = self.repo.run()
        self.assertEqual(code, 2)
        self.assertIn("forge build", out)


if __name__ == "__main__":
    unittest.main()
