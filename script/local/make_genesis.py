"""Writes the local walkthrough's genesis file: the committed policy with anvil's test accounts.

Usage: python script/local/make_genesis.py

Reads config/genesis.example.json (the committed policy), replaces the placeholder network and
every placeholder holder with an account of anvil's default test mnemonic ("test test ... junk",
public test keys that exist only on a local node), and writes config/local/genesis.anvil.json,
which .gitignore keeps out of the repository. Only the network, the holders and the description
change, as `tools/check_genesis.py --config` allows. script/local/walkthrough.sh runs it.
"""
import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# Anvil's default accounts, by mnemonic index (`cast wallet address --mnemonic
# "test test test test test test test test test test test junk" --mnemonic-index <i>`).
ANVIL = {
    1: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    2: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
    3: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
    4: "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65",
    5: "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc",
    10: "0xBcd4042DE499D14e55001CcbB24a551F3b954096",
    11: "0x71bE63f3384f5fb98995898A86B02Fb2426c5788",
    12: "0xFABB0ac9d68B0B445fB7357272Ff202C5651694a",
    13: "0x1CBd3b2770909D4e10f157cABC84C7264073C9Ec",
}

# The placeholder each anvil account replaces; script/local/Walkthrough.s.sol uses the same
# indices (0 is the deployer, 6 the artist, 7 to 9 the bidders and keeper, 14 the fee recipient).
NETWORK = (1, "Network (anvil account 1)")
HOLDERS = {
    "0x000000000000000000000000000000000000b011": (10, "Pauser key 1 (anvil account 10)"),
    "0x000000000000000000000000000000000000b012": (11, "Pauser key 2 (anvil account 11)"),
    "0x000000000000000000000000000000000000b013": (12, "Pauser key 3 (anvil account 12)"),
    "0x000000000000000000000000000000000000b021": (2, "Curation signer 1 (anvil account 2)"),
    "0x000000000000000000000000000000000000b022": (3, "Curation signer 2 (anvil account 3)"),
    "0x000000000000000000000000000000000000b031": (13, "Storage operator (anvil account 13)"),
    "0x000000000000000000000000000000000000b051": (4, "Platform (anvil account 4)"),
    "0x000000000000000000000000000000000000b061": (5, "Curator (anvil account 5)"),
}


def main():
    genesis = json.loads((REPO / "config/genesis.example.json").read_text(encoding="utf-8"))
    genesis["network"] = ANVIL[NETWORK[0]]
    for h in genesis["holders"]:
        index, label = HOLDERS[h["account"].lower()]
        h["account"], h["label"] = ANVIL[index], label
    genesis["description"] = (
        "Local walkthrough genesis (script/local): the committed policy with anvil's public "
        "test accounts as the network and holders. For a local node only."
    )
    text = json.dumps(genesis, indent=2, ensure_ascii=False) + "\n"
    # No network or holder placeholder (0x...b0xx) may survive.
    assert not re.search(r"0x0{36}b0[0-9a-f]{2}", text, re.I)
    out = REPO / "config/local/genesis.anvil.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8", newline="\n")
    print("wrote", out.relative_to(REPO).as_posix())


if __name__ == "__main__":
    main()
