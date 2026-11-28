"""Completes a Sepolia deployment record with what the chain and the round's inputs say.

Usage: python script/sepolia/make_record.py <record.json> <round> <commit> [--confirmed] [rpc]
       python script/sepolia/make_record.py deployments/11155111/core-1795412520.json r6 2aac8579...

`script/DeployCore.s.sol` writes `deployments/<chain>/core-<timestamp>.json`: one
`<name>: <address>` object with the deployer, the delegation contract and the last block before
the deployment (`forkBlock`). The scripts read those keys and keep reading them. This tool adds,
in the same file, what a reader of the record needs and the fact sheet (`tools/gen_facts.py`)
reads:

- `chainId`, `instance`, `timestamp` (the record's own, from its file name), `sourceCommit`;
- `startBlock` and `endBlock`: the first and last block of the deployment's transactions
  (the first creation and the `configure` call), found from each contract's creation;
- `genesisConfig` and `genesisSha256`, `manifest` (path, SHA-256 and URI: the epoch-0 entry of
  the governance chain) and `namespace`, from `config/sepolia-<round>/deploy.env`;
- `contracts`: every contract with its address, runtime code hash, creation transaction and
  block (the manager is created inside the configurator's creation);
- `confirmed`: whether `script/VerifyCore.s.sol` passed against the chain (`--confirmed`).

It reads the chain only (`eth_chainId`, `eth_getCode`, `eth_call`); nothing is signed or sent.
Each contract's creation transaction and block come from forge's broadcast cache of the run
(`broadcast/DeployCore.s.sol/<chain>/run-latest.json`, not committed).
"""
import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CHAIN_ID = 11155111
# Keys of the record that are not contracts of the deployment.
NOT_CONTRACTS = ("deployer", "delegation", "forkBlock")
ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}")


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json", "User-Agent": "curl/8.0"})
    out = json.loads(urllib.request.urlopen(req, timeout=120).read())
    if "error" in out:
        raise SystemExit(f"{method}: {out['error']}")
    return out["result"]


def env(round_):
    out = {}
    for line in (REPO / f"config/sepolia-{round_}/deploy.env").read_text(encoding="utf-8").splitlines():
        m = re.match(r"^\s*([A-Z0-9_]+)=(.*)$", line)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def flat(record):
    """The contracts of a record: its `<name>: <address>` entries."""
    return {n: a for n, a in record.items()
            if n not in NOT_CONTRACTS and isinstance(a, str) and ADDRESS.fullmatch(a)}


def created_by(factory, salt):
    """`CoreFactory.addressOf(salt)`: the first CREATE address of the salt's one-use proxy."""
    proxy_code = bytes.fromhex("67363d3d37363d34f03d5260086018f3")
    proxy = bytes.fromhex(keccak(bytes([0xFF]) + bytes.fromhex(factory[2:]) + bytes.fromhex(salt[2:])
                                 + bytes.fromhex(keccak(proxy_code))))[12:]
    return "0x" + keccak(bytes.fromhex("d694") + proxy + bytes([1]))[24:]


def creations(run):
    """Address (lower case) -> (transaction hash, block) from forge's broadcast cache. A
    broadcast with --skip-simulation records no created contracts for a call, so a factory
    `create(salt, code)` is mapped to the address the factory creates for that salt."""
    blocks = {r["transactionHash"]: int(r["blockNumber"], 16) for r in run["receipts"]}
    out = {}
    for t in run["transactions"]:
        made = [c["address"] for c in t.get("additionalContracts") or [] if c and c.get("address")]
        if t.get("contractAddress") and str(t.get("transactionType", "")).startswith("CREATE"):
            made.append(t["contractAddress"])
        arguments = t.get("arguments") or []
        if t.get("transactionType") == "CALL" and t.get("function") == "create(bytes32,bytes)" and arguments:
            made.append(created_by(t["contractAddress"], arguments[0]))
        for a in made:
            out[a.lower()] = (t["hash"], blocks[t["hash"]])
    return out, sorted(blocks.values())


def sha256_hex(path):
    return hashlib.sha256((REPO / path).read_bytes()).hexdigest()


def main(argv):
    confirmed = "--confirmed" in argv
    args = [a for a in argv if a != "--confirmed"]
    record_path, round_, commit = args[:3]
    url = args[3] if len(args) > 3 else "https://ethereum-sepolia-rpc.publicnode.com"
    assert re.fullmatch(r"r\d+", round_), round_
    assert re.fullmatch(r"[0-9a-f]{40}", commit), commit
    if int(rpc(url, "eth_chainId", []), 16) != CHAIN_ID:
        raise SystemExit("the RPC is not Sepolia")
    path = REPO / record_path
    record = json.loads(path.read_text(encoding="utf-8"))
    stamp = re.fullmatch(r"core-(\d+)\.json", path.name)
    assert stamp, path.name
    e = env(round_)
    names = flat(record)
    run = json.loads((REPO / f"broadcast/DeployCore.s.sol/{CHAIN_ID}/run-latest.json").read_text(encoding="utf-8"))
    made, blocks = creations(run)
    # The manager is created by the configurator's constructor: read it from the configurator
    # (`streamManager()`).
    manager = checksum(rpc(url, "eth_call", [{"to": names["GovernanceConfigurator"], "data": "0x34fe2676"}, "latest"])[-40:])
    contracts = {}
    for name, address in sorted({**names, "StreamAccessManager": manager}.items()):
        code = bytes.fromhex(rpc(url, "eth_getCode", [address, "latest"])[2:])
        if not code:
            raise SystemExit(f"{name} ({address}): no code")
        # The manager has no transaction of its own: it is created in the configurator's.
        key = address.lower() if name != "StreamAccessManager" else names["GovernanceConfigurator"].lower()
        if key not in made:
            raise SystemExit(f"{name} ({address}): no creation transaction in the broadcast cache")
        tx, block = made[key]
        contracts[name] = {"address": address, "codehash": "0x" + keccak(code), "creationTx": tx, "block": block}
    genesis = e["GENESIS_CONFIG"]
    manifest = e["MANIFEST_PATH"]
    record.update({
        "chainId": CHAIN_ID,
        "instance": f"sepolia-{round_}",
        "timestamp": int(stamp.group(1)),
        "sourceCommit": commit,
        "startBlock": blocks[0],
        "endBlock": blocks[-1],
        "confirmed": confirmed,
        "namespace": e["DEPLOY_NAMESPACE"],
        "genesisConfig": genesis,
        "genesisSha256": "0x" + sha256_hex(genesis),
        "manifest": {"path": manifest, "sha256": "0x" + sha256_hex(manifest), "uri": e["MANIFEST_URI"]},
        "contracts": contracts,
    })
    path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
    print(f"{path.name}: {len(contracts)} contracts, blocks {blocks[0]} to {blocks[-1]}, confirmed {confirmed}")


def checksum(address):
    """An address (40 hex digits) in EIP-55 mixed case."""
    lower = address.lower().removeprefix("0x")
    digest = keccak(lower.encode("ascii"))
    return "0x" + "".join(c.upper() if int(h, 16) >= 8 else c for c, h in zip(lower, digest))


def keccak(data):
    """Keccak-256 as hex, with the repository's own implementation (tools/content/keccak.py)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("stream_keccak_record", REPO / "tools/content/keccak.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.keccak256(data).hex()


if __name__ == "__main__":
    main(sys.argv[1:])
