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


class KeysFromGenesis(unittest.TestCase):
    def test_keys_by_role(self):
        genesis = {"holders": [
            {"role": "PAUSER", "account": "0x11"}, {"role": "PAUSER", "account": "0x12"},
            {"role": "CURATION_SIGNER", "account": "0x21"}, {"role": "CURATION_SIGNER", "account": "0x22"},
            {"role": "STORAGE_OPERATOR", "account": "0x31"}, {"role": "PLATFORM", "account": "0x51"},
            {"role": "CURATOR", "account": "0x61"},
        ]}
        out = make_manifest.keys_from_genesis(genesis)
        self.assertEqual(out["pausers"], ["0x11", "0x12"])
        self.assertEqual(out["curationSigners"], ["0x21", "0x22"])
        self.assertEqual((out["storageOperator"], out["platform"], out["curator"]), ("0x31", "0x51", "0x61"))

    def test_missing_single_holder_is_refused(self):
        with self.assertRaises(ValueError):
            make_manifest.keys_from_genesis({"holders": [{"role": "PLATFORM", "account": "0x51"}]})

    def test_r5_keys_match_its_committed_manifest(self):
        # The keys the writer derives from r5's genesis are exactly the committed manifest's:
        # the same addresses in the same order, and the same single-holder roles.
        g = json.loads((REPO / "config/sepolia-r5/genesis.json").read_text(encoding="utf-8"))
        m = json.loads((REPO / "config/sepolia-r5/manifest-epoch0.json").read_text(encoding="utf-8"))
        self.assertEqual(make_manifest.keys_from_genesis(g), m["keys"])


class MergeSafes(unittest.TestCase):
    OLD = {"pauser-1": safe("0x00000000000000000000000000000000000000A1", 2, ["0x01", "0x02", "0x03"])}

    def test_new_record_wins_for_the_same_address_whatever_the_labels(self):
        new = safe("0x00000000000000000000000000000000000000a1", 3, ["0x04", "0x05", "0x06"])
        for label in ("network", "network-r6", "pauser-1", "a"):
            merged = make_manifest.merge_safes(self.OLD, {label: new})
            self.assertEqual(len(merged), 1)
            out = make_manifest.safes_from_genesis(
                {"network": "0x00000000000000000000000000000000000000A1", "holders": []}, merged)
            self.assertEqual(out["network"]["threshold"], 3)
            self.assertEqual(out["network"]["owners"], ["0x04", "0x05", "0x06"])

    def test_distinct_addresses_are_kept(self):
        new = {"network": safe("0x00000000000000000000000000000000000000B1", 2, ["0x07"])}
        self.assertEqual(len(make_manifest.merge_safes(self.OLD, new)), 2)

    def test_r5_manifest_safes_are_reproduced(self):
        r4 = json.loads((REPO / "config/sepolia-r4/manifest-epoch0.json").read_text(encoding="utf-8"))
        r5 = json.loads((REPO / "config/sepolia-r5/manifest-epoch0.json").read_text(encoding="utf-8"))
        g = json.loads((REPO / "config/sepolia-r5/genesis.json").read_text(encoding="utf-8"))
        merged = make_manifest.merge_safes(r4["safes"], make_manifest.new_safes("r5"))
        self.assertEqual(make_manifest.safes_from_genesis(g, merged), r5["safes"])


class R6Manifest(unittest.TestCase):
    """The r6 manifest (the plain core, ADR 0010): every contract DeployCore.s.sol prints, the core
    policy, the four settings' launch values, and no Permit2 dependency."""

    def setUp(self):
        self.m = json.loads((REPO / "config/sepolia-r6/manifest-epoch0.json").read_text(encoding="utf-8"))

    def test_names_every_contract_of_the_deployment(self):
        # r6 was deployed before the rename of 28 November 2026; its manifest is kept as
        # deployed and names the manager by its earlier name.
        earlier = {"WorksAccessManager": "StreamAccessManager"}
        self.assertEqual(
            [earlier.get(k, k) for k in self.m["contracts"]], make_manifest.CONTRACTS)
        self.assertEqual(len(set(make_manifest.CONTRACTS)), len(make_manifest.CONTRACTS))

    def test_policy_settings_and_dependencies(self):
        self.assertEqual(self.m["policy"]["path"], make_manifest.POLICY)
        g = json.loads((REPO / "config/sepolia-r6/genesis.json").read_text(encoding="utf-8"))
        self.assertEqual(self.m["settings"], g["settings"])
        self.assertNotIn("permit2", self.m["dependencies"])
        self.assertEqual(self.m["safes"]["network"]["address"], g["network"])


if __name__ == "__main__":
    unittest.main()
