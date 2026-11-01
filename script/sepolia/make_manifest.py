"""Writes a Sepolia rehearsal's epoch-0 governance manifest, config/sepolia-<new>/manifest-epoch0.json.

Usage: python script/sepolia/make_manifest.py <new> <prev> <commit> [<simulation output>]
       python script/sepolia/make_manifest.py r4 r3 1e7022b4...          # first pass
       python script/sepolia/make_manifest.py r4 r3 1e7022b4... sim.txt  # final pass

The manifest is hashed into genesis, but no contract address depends on it, so it is written in
two passes: without a simulation output its contracts are null; with one (the output of
`script/sepolia/deploy.ps1` without -Broadcast, which prints the returned `Deployment`), the
addresses come from the simulation. Then simulate again: the addresses must not move. The
Safes and their owners come from the earlier instance's manifest (the same throwaway Safes),
and every deployment input from config/sepolia-<new>/deploy.env.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
# `DeployV1.Deployment`'s fields, in deploy order (the manager is created by the configurator).
CONTRACTS = [
    "configurator", "manager", "contentStore", "dependencyRegistry", "consolidationAdapter",
    "artistRegistry", "releaseVerifier", "splitFactory", "claimRouter", "assetAllowlist",
    "economicsResolver", "revenueEscrow", "curationVerifier", "packageRegistry", "statementLog",
    "entropyModule", "renderer", "stream", "workRecords", "editions", "englishAuctionLens",
    "englishAuction", "editionAuctionLens", "editionAuction",
]


def env(new):
    out = {}
    for line in (REPO / f"config/sepolia-{new}/deploy.env").read_text(encoding="utf-8").splitlines():
        m = re.match(r"^\s*([A-Z0-9_]+)=(.*)$", line)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def sha(path):
    return hashlib.sha256((REPO / path).read_bytes()).hexdigest()


def main(new, prev, commit, sim_path=None):
    assert re.fullmatch(r"[0-9a-f]{40}", commit), commit
    e = env(new)
    m = json.loads((REPO / f"config/sepolia-{prev}/manifest-epoch0.json").read_text(encoding="utf-8"))
    label = f"6529-works/sepolia/{new}"
    m["deployment"] = f"sepolia-{new}"
    m["source"]["commit"] = commit
    m["namespace"] = {"label": label, "keccak256": e["DEPLOY_NAMESPACE"]}
    genesis = f"config/sepolia-{new}/genesis.json"
    m["genesis"] = {"path": genesis, "sha256": sha(genesis)}
    m["policy"] = {"path": "config/genesis.example.json", "sha256": sha("config/genesis.example.json")}
    m["deployer"] = e["DEPLOYER"]
    duration = int(e.get("AUCTION_DURATION", 86400))
    m["parameters"] = {
        "networkFeeRecipient": e["NETWORK_FEE_RECIPIENT"],
        "marketplaceOwner": e["MARKETPLACE_OWNER"],
        "museum": e["MUSEUM"],
        "museumNote": "The testnet museum: a dedicated EOA the operator holds, with no role.",
        "auctionDuration": duration,
        "auctionDurationNote": (
            "The mainnet default." if duration == 86400
            else "Testnet deviation: 1 hour (the governed minimum); mainnet is 24 hours." if duration == 3600
            else f"Testnet deviation: {duration} seconds; mainnet is 24 hours."
        ),
    }
    vrf = m["dependencies"]["vrf"]
    vrf["coordinator"] = e["VRF_COORDINATOR"]
    vrf["subscriptionId"] = e["VRF_SUBSCRIPTION_ID"]
    vrf["keyHash"] = e["VRF_KEY_HASH"]
    vrf["nativePayment"] = e.get("VRF_NATIVE_PAYMENT") == "1"
    if sim_path is None:
        m["contracts"] = {k: None for k in CONTRACTS}
    else:
        sim = Path(sim_path).read_text(encoding="utf-8")
        found = dict(re.findall(r"\b(\w+): (0x[0-9a-fA-F]{40})\b", sim))
        m["contracts"] = {k: found[k] for k in CONTRACTS}
        cc0 = re.search(r"cc0TextFileId: (0x[0-9a-f]{64})", sim).group(1)
        assert cc0 == m["license"]["contentStoreFileId"], cc0
    out = REPO / f"config/sepolia-{new}/manifest-epoch0.json"
    out.write_text(json.dumps(m, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
    print(json.dumps(m["contracts"], indent=1))
    print("sha256", hashlib.sha256(out.read_bytes()).hexdigest())


if __name__ == "__main__":
    main(*sys.argv[1:5])
