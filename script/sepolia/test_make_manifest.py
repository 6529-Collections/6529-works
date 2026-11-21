"""Unit tests for make_manifest.safes_from_genesis (standard library only).

Run: python -m unittest discover -s script/sepolia -p "test_*.py"
"""
import json
import unittest
from pathlib import Path

import make_manifest

REPO = Path(__file__).resolve().parents[2]


def safe(address, threshold, owners):
    return {"address": address, "threshold": threshold, "owners": owners, "version": "Safe 1.4.1"}


PREV = {
    "hot-admin": safe("0x00000000000000000000000000000000000000A1", 2, ["0x01", "0x02", "0x03"]),
    "guardian-1": safe("0x00000000000000000000000000000000000000B1", 2, ["0x04", "0x05", "0x06"]),
    "guardian-2": safe("0x00000000000000000000000000000000000000b2", 2, ["0x07", "0x08", "0x09"]),
}


class SafesFromGenesis(unittest.TestCase):
    def test_network_and_safe_holders(self):
        genesis = {
            "network": "0x00000000000000000000000000000000000000a1",
            "holders": [
                {"role": "PAUSER", "account": "0x00000000000000000000000000000000000000B1"},
                {"role": "PAUSER", "account": "0x00000000000000000000000000000000000000B2"},
                {"role": "CURATION_SIGNER", "account": "0x00000000000000000000000000000000000000C1"},
            ],
        }
        out = make_manifest.safes_from_genesis(genesis, PREV)
        self.assertEqual(list(out), ["network", "pauser-1", "pauser-2"])
        self.assertEqual(out["network"]["address"], genesis["network"])
        self.assertEqual(out["network"]["owners"], ["0x01", "0x02", "0x03"])
        self.assertEqual(out["pauser-2"]["threshold"], 2)
        self.assertEqual(out["pauser-2"]["owners"], ["0x07", "0x08", "0x09"])
        self.assertNotIn("hot-admin", out)
        self.assertNotIn("guardian-1", out)

    def test_unknown_network_has_null_details(self):
        genesis = {"network": "0x00000000000000000000000000000000000000D1", "holders": []}
        out = make_manifest.safes_from_genesis(genesis, PREV)
        self.assertEqual(list(out), ["network"])
        self.assertIsNone(out["network"]["owners"])
        self.assertIsNone(out["network"]["threshold"])
        self.assertIn("fill in", out["network"]["note"])

    def test_pre_single_network_genesis_is_refused(self):
        with self.assertRaises(ValueError):
            make_manifest.safes_from_genesis({"holders": []}, PREV)

    def test_r4_manifest_with_a_single_network_genesis(self):
        # What `make_genesis.py r5 r4` writes: the network is r4's hot admin Safe and the pausers
        # are r4's guardian Safes; the curation signers and other keys are plain keys.
        prev = json.loads((REPO / "config/sepolia-r4/manifest-epoch0.json").read_text(encoding="utf-8"))
        r4 = json.loads((REPO / "config/sepolia-r4/genesis.json").read_text(encoding="utf-8"))
        pausers = [h for h in r4["holders"] if h["role"] == "PAUSER"]
        keys = [h for h in r4["holders"] if h["role"] == "CURATION_SIGNER"]
        genesis = {"network": prev["safes"]["hot-admin"]["address"], "holders": pausers + keys}
        out = make_manifest.safes_from_genesis(genesis, prev["safes"])
        self.assertEqual(list(out), ["network", "pauser-1", "pauser-2", "pauser-3"])
        self.assertEqual(out["network"]["owners"], prev["safes"]["hot-admin"]["owners"])
        for i in (1, 2, 3):
            self.assertEqual(out[f"pauser-{i}"], {k: prev["safes"][f"guardian-{i}"][k]
                                                 for k in ("address", "threshold", "owners", "version")})


if __name__ == "__main__":
    unittest.main()
