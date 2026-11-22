"""Writes a Sepolia rehearsal's genesis file: the committed policy with an earlier instance's holders.

Usage: python script/sepolia/make_genesis.py <new instance> <holders from instance>
       python script/sepolia/make_genesis.py r4 r3
       python script/sepolia/make_genesis.py r5 config/sepolia-r5/accounts.json

The second argument is an earlier instance, or an accounts file (a path ending in `.json`) that
names new holders: `network`, `description` (containing "rehearsal <new>") and `holders`, each
with `role`, `account` and `label`, in the committed policy's order within each role. It holds
public addresses only.

Reads config/genesis.example.json (the committed policy) and config/sepolia-<from>/genesis.json,
maps every placeholder holder of the policy, by role and position within the role, to the earlier
instance's holder and label, names the earlier instance's network (its `network`, or, for an
instance from before the single network address, its first ADMIN holder, the hot admin Safe), and
writes config/sepolia-<new>/genesis.json. Only the holders, the network and the description
change, which is what `tools/check_genesis.py --config` and the deploy script's
`DeployGuards.checkPolicy` allow. Run `tools/check_genesis.py --config` on the result.
"""
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def by_role(holders):
    out = {}
    for h in holders:
        out.setdefault(h["role"], []).append(h)
    return out


def from_accounts(path):
    """An accounts file as an earlier instance: `network`, `description` and `holders`
    (each `role`, `account`, `label`), listed in the committed policy's order within each role."""
    a = json.loads((REPO / path).read_text(encoding="utf-8"))
    assert re.fullmatch(r"0x[0-9a-fA-F]{40}", a["network"]), a["network"]
    for h in a["holders"]:
        assert re.fullmatch(r"0x[0-9a-fA-F]{40}", h["account"]), h
    return a


def main(new, old):
    assert re.fullmatch(r"r\d+", new), new
    example = json.loads((REPO / "config/genesis.example.json").read_text(encoding="utf-8"))
    if old.endswith(".json"):
        # A new set of holders: config/sepolia-<new>/accounts.json (public addresses only).
        prev = from_accounts(old)
    else:
        assert re.fullmatch(r"r\d+", old), old
        prev = json.loads((REPO / f"config/sepolia-{old}/genesis.json").read_text(encoding="utf-8"))
    ex_roles, prev_roles = by_role(example["holders"]), by_role(prev["holders"])
    assert set(ex_roles) <= set(prev_roles), set(ex_roles) - set(prev_roles)
    mapping = {}
    for role, hs in ex_roles.items():
        assert len(hs) == len(prev_roles[role]), role
        for e, h in zip(hs, prev_roles[role]):
            seen = mapping.get(e["account"])
            assert seen is None or seen == (h["account"], h["label"]), (role, e, h, seen)
            mapping[e["account"]] = (h["account"], h["label"])
    for h in example["holders"]:
        h["account"], h["label"] = mapping[h["account"]]
    example["network"] = prev.get("network") or prev_roles["ADMIN"][0]["account"]
    example["description"] = re.sub(r"rehearsal r\d+", f"rehearsal {new}", prev["description"], count=1)
    assert f"rehearsal {new}" in example["description"]
    text = json.dumps(example, indent=2, ensure_ascii=False) + "\n"
    # No holder placeholder (0x...b0xx) may survive.
    assert not re.search(r"0x0{36}b0[0-9a-f]{2}", text, re.I)
    out = REPO / f"config/sepolia-{new}/genesis.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8", newline="\n")
    for k, (a, label) in sorted(mapping.items()):
        print(k[-4:], a, label)
    print("wrote", out.relative_to(REPO).as_posix())


if __name__ == "__main__":
    main(*sys.argv[1:3])
