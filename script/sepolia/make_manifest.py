"""Writes a Sepolia rehearsal's epoch-0 governance manifest, config/sepolia-<new>/manifest-epoch0.json.

Usage: python script/sepolia/make_manifest.py <new> <prev> <commit> [<simulation output>]
       python script/sepolia/make_manifest.py r4 r3 1e7022b4...          # first pass
       python script/sepolia/make_manifest.py r4 r3 1e7022b4... sim.txt  # final pass

The manifest is hashed into genesis, but no contract address depends on it, so it is written in
two passes: without a simulation output its contracts are null; with one (the output of
`script/sepolia/deploy.ps1` without -Broadcast, which prints the returned `Deployment`), the
addresses come from the simulation. Then simulate again: the addresses must not move. The
`safes` section follows the new genesis (config/sepolia-<new>/genesis.json, single network):
the network address and every holder that is a Safe of the earlier instance's manifest, each
with that Safe's owners, threshold and version (the same throwaway Safes); a network address
that is not one of those Safes is written with null details, to fill in before publishing. Safes
first used by the new instance are read from config/sepolia-<new>/accounts.json (`safes`) when
that file exists. The `keys` section lists the new genesis's operational keys.
Every deployment input comes from config/sepolia-<new>/deploy.env.
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
    "artistRegistry", "splitFactory", "feeRecipientVault", "museumVault", "claimRouter",
    "assetAllowlist", "economicsResolver", "revenueEscrow", "curationVerifier", "packageRegistry",
    "statementLog",
    "entropyModule", "renderer", "stream", "workRecords", "workDelivery", "editions",
    "englishAuctionLens", "englishAuction", "editionAuctionLens", "editionAuction",
    "federationRegistry", "federatedEditionAuctionLens", "federatedEditionAuction",
    "federatedStreamDeployer", "federatedEditionsDeployer", "saleStarter",
]


def env(new):
    out = {}
    for line in (REPO / f"config/sepolia-{new}/deploy.env").read_text(encoding="utf-8").splitlines():
        m = re.match(r"^\s*([A-Z0-9_]+)=(.*)$", line)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def safes_from_genesis(genesis, prev_safes):
    """The manifest's `safes` section for a single-network genesis.

    `network` is the genesis network address; each holder whose account is a Safe of the earlier
    manifest is listed as `<role>-<n>` (by role, in genesis order). Owners, threshold and version
    are copied from that earlier Safe, matched by address; holders that are plain keys are not
    Safes and stay out. A network that is no earlier Safe gets null details and a note.
    """
    if not genesis.get("network"):
        raise ValueError("the genesis names no network address (pre-single-network genesis)")
    known = {s["address"].lower(): s for s in prev_safes.values()}

    def entry(address):
        s = known.get(address.lower())
        if s is None:
            return {"address": address, "threshold": None, "owners": None, "version": None,
                    "note": "Not a Safe of the earlier manifest: fill in before publishing."}
        return {"address": address, "threshold": s["threshold"], "owners": list(s["owners"]),
                "version": s["version"]}

    out = {"network": entry(genesis["network"])}
    counts = {}
    for h in genesis["holders"]:
        if h["account"].lower() not in known:
            continue
        role = h["role"].lower().replace("_", "-")
        counts[role] = counts.get(role, 0) + 1
        out[f"{role}-{counts[role]}"] = entry(h["account"])
    return out


def keys_from_genesis(genesis):
    """The manifest's `keys` section: the genesis file's operational keys, by role."""
    of = {}
    for h in genesis["holders"]:
        of.setdefault(h["role"], []).append(h["account"])

    def one(role):
        accounts = of.get(role, [])
        if len(accounts) != 1:
            raise ValueError(f"{role}: expected one holder, found {len(accounts)}")
        return accounts[0]

    return {
        "pausers": of.get("PAUSER", []),
        "curationSigners": of.get("CURATION_SIGNER", []),
        "storageOperator": one("STORAGE_OPERATOR"),
        "platform": one("PLATFORM"),
        "curator": one("CURATOR"),
    }


def new_safes(new):
    """Safes first used by instance `new`, from config/sepolia-<new>/accounts.json (`safes`, as
    in a manifest: address, threshold, owners, version), so the `safes` section can name them."""
    path = REPO / f"config/sepolia-{new}/accounts.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8")).get("safes", {})


def merge_safes(prev_safes, new):
    """Earlier and new Safe records keyed by normalized address: for an address both describe,
    the new record (config/sepolia-<new>/accounts.json) wins, whatever either label is."""
    out = {}
    for s in list(prev_safes.values()) + list(new.values()):
        out[s["address"].lower()] = s
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
    g = json.loads((REPO / genesis).read_text(encoding="utf-8"))
    m["safes"] = safes_from_genesis(g, merge_safes(m["safes"], new_safes(new)))
    m["keys"] = keys_from_genesis(g)
    m["signatures"] = "Unsigned: testnet rehearsal. A mainnet manifest is signed by the network Safe's signers."
    for name, s in m["safes"].items():
        if s["owners"] is None:
            print(f"warning: safes.{name} ({s['address']}) needs its owners, threshold and version",
                  file=sys.stderr)
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
    # The deploy's defaults (script/Deploy.s.sol) unless the env file sets them.
    vrf["callbackGasLimit"] = int(e.get("VRF_CALLBACK_GAS_LIMIT", 200000))
    vrf["confirmations"] = int(e.get("VRF_CONFIRMATIONS", 3))
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
