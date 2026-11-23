"""Per-transaction gas of a Sepolia deploy: forge's Prague estimate, the gas limit sent, and the receipt.

Usage: python script/sepolia/deploy_gas.py <out.json> <record.json> [rpc]

Reads forge's broadcast cache of the last `script/DeployCore.s.sol` run on Sepolia (not
committed): `broadcast/DeployCore.s.sol/11155111/run-latest.json` (the receipts) and
`dry-run/run-latest.json`
(the simulation without --broadcast, whose gas is Foundry's Prague estimate times its 1.3
multiplier). The gas limit each transaction was sent with is read from the chain: with --slow
and --skip-simulation forge takes it from the node's eth_estimateGas (Glamsterdam costs) just
before sending, times the same multiplier. Every contract is created inside one transaction to
the deployer's `CoreFactory` (`create`); the deployment record (`<name>: <address>`) names the
contract each transaction created.
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_record import created_by  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
B = REPO / "broadcast/DeployCore.s.sol/11155111"
MULTIPLIER = 1.3


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json", "User-Agent": "curl/8.0"})
    out = json.loads(urllib.request.urlopen(req, timeout=120).read())
    if "error" in out:
        raise SystemExit(f"{method}: {out['error']}")
    return out["result"]


def label(t, names):
    """The contract a transaction created (through the factory), else forge's contract name.
    A broadcast with --skip-simulation records no created contracts for a call, so a factory
    `create(salt, code)` is named by the address the factory creates for that salt."""
    for c in t.get("additionalContracts") or []:
        name = names.get(c["address"].lower())
        if name:
            return name
    if t.get("transactionType") == "CALL" and t.get("function") == "create(bytes32,bytes)":
        name = names.get(created_by(t["contractAddress"], t["arguments"][0]).lower())
        if name:
            return name
    return t.get("contractName") or names.get((t.get("contractAddress") or "").lower()) or "?"


def main(out, record, url="https://ethereum-sepolia-rpc.publicnode.com"):
    rec = json.loads(Path(record).read_text(encoding="utf-8"))
    # The record also holds the deployer, the delegation contract and the fork block.
    skip = ("deployer", "delegation", "forkBlock")
    names = {a.lower(): n for n, a in rec.items()
             if n not in skip and isinstance(a, str) and re.fullmatch(r"0x[0-9a-fA-F]{40}", a)}
    run = json.loads((B / "run-latest.json").read_text(encoding="utf-8"))
    dry = json.loads((B / "dry-run/run-latest.json").read_text(encoding="utf-8"))
    assert len(run["transactions"]) == len(dry["transactions"]) == len(run["receipts"])
    receipts = {r["transactionHash"]: r for r in run["receipts"]}
    rows, cost = [], 0
    for i, (t, d) in enumerate(zip(run["transactions"], dry["transactions"])):
        assert label(t, names) == label(d, names), (i, label(t, names), label(d, names))
        name = label(t, names)
        r = receipts[t["hash"]]
        limit = int(rpc(url, "eth_getTransactionByHash", [t["hash"]])["gas"], 16)
        used = int(r["gasUsed"], 16)
        cost += used * int(r["effectiveGasPrice"], 16)
        fn = "create" if t["transactionType"] == "CREATE2" else (t.get("function") or "").split("(")[0]
        rows.append({
            "index": i,
            "contract": name,
            "function": fn,
            "address": t.get("contractAddress"),
            "pragueEstimate": round(int(d["transaction"]["gas"], 16) / MULTIPLIER),
            "gasLimit": limit,
            "nodeEstimate": round(limit / MULTIPLIER),
            "gasUsed": used,
            "status": r["status"],
            "block": int(r["blockNumber"], 16),
            "hash": t["hash"],
        })
        print(f"{i:2} {name:28} {fn:18} {rows[-1]['pragueEstimate']:>12,} "
              f"{rows[-1]['nodeEstimate']:>12,} {used:>12,} {r['status']}")
    total = sum(r["gasUsed"] for r in rows)
    print(f"total {total:,} gas, {cost / 1e18:.6f} ETH, blocks {rows[0]['block']} to {rows[-1]['block']}")
    Path(out).write_text(json.dumps({"rows": rows, "totalGasUsed": total, "costWei": str(cost)}, indent=1),
                         encoding="utf-8")


if __name__ == "__main__":
    main(*sys.argv[1:4])
