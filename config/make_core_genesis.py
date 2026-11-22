"""Write config/genesis.core.example.json: the governance policy of the plain-core stack.

The plain core (docs/adr/0010-plain-permanent-core.md) replaces the bind-once wiring with
constructor arguments and adds the network's settings. This file is generated so every selector
is computed from its signature, never typed by hand. Run from the repository root:

    python config/make_core_genesis.py           # write
    python config/make_core_genesis.py --check   # fail if the committed file differs

It replaced config/genesis.example.json at integration; tools/check_genesis.py checks it against
the build.

Role choices:
- Every waiting period in a permanent contract is a setting the network changes at once, so the
  setters, the module and minter functions, `rescue` and `rebind` map to NETWORK (no role delay):
  the wait that applies is the contract's own setting, not a role delay stacked on it.
- Functions that exist today keep today's class.
- Standard library only.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "config" / "genesis.core.example.json"
# The network, role table, holders and manager placeholders are kept from the committed file.
OLD = OUT

CLASS = {
    "NETWORK": ("immediate", 0),
    "PAUSER": ("immediate", 0),
    "STORAGE_OPERATOR": ("immediate", 0),
    "PLATFORM": ("immediate", 0),
    "CURATOR": ("immediate", 0),
    "PARAMETER_SETTER": ("24h", 86400),
    "FUNDS_SETTER": ("3d", 259200),
    "SUCCESSOR_SETTER": ("7d", 604800),
}


def _keccak():
    path = ROOT / "tools" / "content" / "keccak.py"
    spec = importlib.util.spec_from_file_location("works_keccak_genesis", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.keccak256


KECCAK = _keccak()


def selector(signature: str) -> str:
    return "0x" + KECCAK(signature.encode("ascii"))[:4].hex()


def fn(signature: str, role: str, note: str | None = None, via: str | None = None) -> dict:
    cls, delay = CLASS[role]
    row = {
        "signature": signature,
        "selector": selector(signature),
        "role": role,
        "class": cls,
        "delay": delay,
    }
    if note:
        row["note"] = note
    if via:
        row["via"] = via
    return row


IND_STREAM = "src/independent/IndependentStream6529.sol:IndependentStream6529"
IND_EDITIONS = "src/independent/IndependentStreamEditions6529.sol:IndependentStreamEditions6529"

# The module and minter functions every token contract and the Directory share.
SLOTS = [
    fn("proposeModule(bytes32,address)", "NETWORK", "takes effect after moduleDelay, the contract's own setting"),
    fn("removeModule(bytes32)", "NETWORK", "at once"),
    fn("cancelModule(bytes32)", "NETWORK", "withdraws an announced module before it takes effect; at once"),
    fn("setModuleDelay(uint48)", "NETWORK", "the network's setting, 7 days at launch; zero allowed"),
]
MINTERS = [
    fn("addMinter(address)", "NETWORK", "active after moduleDelay"),
    fn("removeMinter(address)", "NETWORK", "at once"),
]
STATEMENT = "(address,uint256,bytes32,bytes32,(uint16,bytes32),string,bytes32,bytes32)"
AUCTION_CONFIG = "(uint32,uint32,uint32,uint32)"
EDITION_CONFIG = "(uint96,uint16,uint16,uint32,uint32,uint32)"
VRF_CONFIG = "(uint256,bytes32,uint32,uint16,bool)"


def contract(name, address, artifact, implementation, functions, note=None):
    implementation = implementation or artifact
    row = {
        "name": name,
        "artifact": artifact,
        "implementation": implementation,
        "address": address,
        "status": "implemented",
        "functions": functions,
        "genesisOnly": [],
        "deferred": [],
    }
    return row


CONTRACTS = [
    contract(
        "Stream6529", "0x000000000000000000000000000000000000a001",
        "src/core/Stream6529.sol:Stream6529", "src/core/Stream6529.sol:Stream6529",
        [
            fn("createCollection(string,bytes32)", "PLATFORM"),
            fn("setContractURI(string)", "PARAMETER_SETTER"),
            fn("setOwner(address)", "FUNDS_SETTER", "the marketplace owner; no protocol power"),
            *SLOTS,
            *MINTERS,
            fn("setRescueDelay(uint48)", "NETWORK", "the network's setting, 14 days at launch; zero allowed"),
            fn("rescue(uint256,address)", "NETWORK", "only a token a removed minter holds unsold, once rescueDelay has passed since the removal"),
        ],
    ),
    contract(
        "StreamEditions6529", "0x000000000000000000000000000000000000a003",
        "src/core/StreamEditions6529.sol:StreamEditions6529", "src/core/StreamEditions6529.sol:StreamEditions6529",
        [
            fn("setContractURI(string)", "PARAMETER_SETTER"),
            fn("setOwner(address)", "FUNDS_SETTER", "the marketplace owner; no protocol power"),
            *SLOTS,
            *MINTERS,
            fn("setRebindDelay(uint48)", "NETWORK", "the network's setting, 14 days at launch; zero allowed"),
            fn("rebind(uint256,address)", "NETWORK", "only an edition with no copies and no seal, once rebindDelay has passed since its minter's removal"),
        ],
    ),
    contract(
        "StreamDirectory6529", "0x000000000000000000000000000000000000a017",
        "src/core/StreamDirectory6529.sol:StreamDirectory6529", "src/core/StreamDirectory6529.sol:StreamDirectory6529",
        [
            *SLOTS,
            fn("setUnclaimedPeriod(uint48)", "NETWORK", "the network's setting, 180 days at launch; read by SplitLedger and RevenueEscrow; zero allowed"),
            fn("setRescueDelay(uint48)", "NETWORK", "asked by every Independent Stream token for its own setting", IND_STREAM),
            fn("rescue(uint256,address)", "NETWORK", "asked by every Independent Stream token", IND_STREAM),
            fn("setRebindDelay(uint48)", "NETWORK", "asked by every Independent Stream Editions token for its own setting", IND_EDITIONS),
            fn("rebind(uint256,address)", "NETWORK", "asked by every Independent Stream Editions token", IND_EDITIONS),
        ],
    ),
    contract(
        "WorkRules", "0x000000000000000000000000000000000000a002",
        "src/records/WorkRules.sol:WorkRules", None,
        [
            fn("relicense(address,uint256,(string,bytes32),(uint8,uint256,bytes32,bytes32,bytes32,(address,uint8)[],(uint256,address,uint32)[],(string,bytes32),uint8,bytes32,(bytes32,address,bytes),(uint32,address,bytes32,bytes)),bytes32,uint64,bytes[])", "FUNDS_SETTER"),
            fn("setRoyaltyRate(address,uint256,uint24,(uint8,uint256,bytes32,bytes32,bytes32,(address,uint8)[],(uint256,address,uint32)[],(string,bytes32),uint8,bytes32,(bytes32,address,bytes),(uint32,address,bytes32,bytes)),bytes32,uint64,bytes[])", "FUNDS_SETTER"),
            fn("repinRenderer(address,uint256,address,bytes32)", "SUCCESSOR_SETTER"),
            fn("renounce(address,uint256,uint16,bytes32,uint64,bytes)", "PARAMETER_SETTER"),
            fn("setDelivery(address,address)", "SUCCESSOR_SETTER"),
            fn("addStore(address,bytes32)", "SUCCESSOR_SETTER"),
            fn("retireStore(uint256)", "PARAMETER_SETTER"),
            fn("setFileStore(address,uint256,bytes32,uint256)", "STORAGE_OPERATOR", "or a wallet of the lead artist's account"),
        ],
        "RECORDS module of Stream and, through Directory, of Independent Stream tokens",
    ),
    contract(
        "WorkDelivery", "0x000000000000000000000000000000000000a011",
        "src/stream/WorkDelivery.sol:WorkDelivery", None,
        [
            fn("setPreferredKind(address,uint8)", "STORAGE_OPERATOR"),
            fn("setCollectionPreferredKind(address,uint256,uint8)", "STORAGE_OPERATOR"),
            fn("setFilePreference(address,uint256,bytes32,uint256)", "STORAGE_OPERATOR"),
            fn("addLocator(address,uint256,bytes32,(uint8,string))", "PLATFORM"),
            fn("markLocatorDead(address,uint256,bytes32,uint256)", "STORAGE_OPERATOR"),
        ],
        "Keyed by token",
    ),
    contract(
        "StreamTerms", "0x000000000000000000000000000000000000a018",
        "src/terms/StreamTerms.sol:StreamTerms", None,
        [
            fn("lowerFeeShare(address,uint256,address,address,uint32,uint32)", "PARAMETER_SETTER", "lower only"),
            fn("setEditions(address,address)", "SUCCESSOR_SETTER", "pairs a token with its editions contract"),
        ],
        "TERMS module of Stream, Editions and Independent Stream tokens",
    ),
    contract(
        "PackageRegistry", "0x000000000000000000000000000000000000a004",
        "src/curation/PackageRegistry.sol:PackageRegistry", None,
        [
            fn("revokePackage(bytes32,bytes32)", "NETWORK"),
            fn("setVerifier(address,address,bytes32)", "SUCCESSOR_SETTER"),
            fn("killSignerApprovals(address)", "NETWORK"),
            fn("releaseContent(address,uint256,bytes32,uint256)", "PARAMETER_SETTER"),
            fn("setEntropyModule(address,address)", "SUCCESSOR_SETTER", "also set once at genesis"),
        ],
        "The mint policy; content release moved in from Stream",
    ),
    contract(
        "CurationVerifier", "0x000000000000000000000000000000000000a005",
        "src/curation/Eip712CurationVerifier.sol:Eip712CurationVerifier", None,
        [fn("disableSigner(address)", "NETWORK"), fn("enableSigner(address)", "SUCCESSOR_SETTER")],
    ),
    contract(
        "Accounts", "0x000000000000000000000000000000000000a006",
        "src/identity/Accounts.sol:Accounts", None,
        [
            fn("setConsolidationSource(address,address,bytes32)", "SUCCESSOR_SETTER"),
            fn("resolveContested(uint256,bool,bytes32)", "PARAMETER_SETTER"),
            fn("freeze(uint256)", "NETWORK"),
            fn("unfreeze(uint256)", "NETWORK"),
            fn("cancelReplacement(uint256)", "NETWORK"),
            fn("cancelOwnChange(uint256)", "NETWORK"),
            fn("stageReplacement(uint256,(address,address,bytes32,bytes32),bytes32,uint64,bytes)", "PARAMETER_SETTER"),
            fn("setPackageRegistry(address,address)", "SUCCESSOR_SETTER"),
        ],
        "The ACCOUNTS module behind Directory",
    ),
    contract(
        "StatementLog", "0x000000000000000000000000000000000000a007",
        "src/records/StatementLog.sol:StatementLog", "src/records/StatementLog.sol:StatementLog",
        [
            fn(f"appendCurator({STATEMENT})", "CURATOR"),
            fn(f"appendPlatform({STATEMENT})", "PLATFORM"),
            fn(f"appendGovernanceManifest({STATEMENT})", "SUCCESSOR_SETTER"),
            fn("setArtistResolver(address,address,bytes32)", "SUCCESSOR_SETTER"),
        ],
    ),
    contract(
        "EnglishAuction", "0x000000000000000000000000000000000000a008",
        "src/sales/EnglishAuction.sol:EnglishAuction", None,
        [
            fn("pause()", "PAUSER"),
            fn("unpause()", "NETWORK"),
            fn("pause(uint256,bytes32)", "PAUSER"),
            fn("resume(uint256)", "NETWORK"),
            fn("cancel(uint256,bytes32)", "NETWORK"),
            fn(f"setConfig({AUCTION_CONFIG},{AUCTION_CONFIG})", "PARAMETER_SETTER"),
            fn("setStreamPolicy(address,address)", "SUCCESSOR_SETTER", "the mint policy for 6529 Stream"),
        ],
        "ETH only; the minter of Stream",
    ),
    contract(
        "UniformEditionAuction", "0x000000000000000000000000000000000000a009",
        "src/sales/UniformEditionAuction.sol:UniformEditionAuction", None,
        [
            fn("pause()", "PAUSER"),
            fn("unpause()", "NETWORK"),
            fn(f"setConfig({EDITION_CONFIG},{EDITION_CONFIG})", "PARAMETER_SETTER"),
            fn("setTarget(address,bool)", "SUCCESSOR_SETTER"),
            fn("setLimits(uint256,uint256)", "PARAMETER_SETTER"),
            fn("adopt(address,uint256,bytes)", "NETWORK", "opens the sale of an edition the network rebound to this auction"),
            fn("closeEdition(address,uint256)", "NETWORK", "seals at zero an edition rebound to this auction that has no sale here"),
        ],
        "The minter of Editions",
    ),
    contract(
        "EconomicsResolver", "0x000000000000000000000000000000000000a00b",
        "src/economics/EconomicsResolver.sol:EconomicsResolver", None,
        [
            fn("setFeeTerms(bytes32,uint64,address,uint32)", "FUNDS_SETTER"),
            fn("setRoyaltyRate(bytes32,uint64,uint32)", "PARAMETER_SETTER"),
            fn("setDefaultLicense(bytes32,uint64,(string,bytes32))", "PARAMETER_SETTER"),
            fn("setMuseum(uint64,address)", "FUNDS_SETTER"),
        ],
    ),
    contract(
        "AssetAllowlist", "0x000000000000000000000000000000000000a00c",
        "src/economics/AssetAllowlist.sol:AssetAllowlist", None,
        [
            fn("setIncrementFloor(address,uint64,uint256)", "PARAMETER_SETTER"),
            fn("setOpeningBid(address,uint64,uint256)", "PARAMETER_SETTER"),
        ],
        "ETH only: opening bid and increment floor",
    ),
    contract(
        "RevenueEscrow", "0x000000000000000000000000000000000000a00d",
        "src/economics/RevenueEscrow.sol:RevenueEscrow", "src/economics/RevenueEscrow.sol:RevenueEscrow",
        [fn("recover(address,address,address)", "FUNDS_SETTER"), fn("sweepExcess(address,address)", "FUNDS_SETTER")],
    ),
    contract(
        "FeeRecipientVault", "0x000000000000000000000000000000000000a013",
        "src/economics/GovernedVault.sol:GovernedVault", "src/economics/GovernedVault.sol:GovernedVault",
        [fn("setDestination(uint64,address)", "FUNDS_SETTER")],
    ),
    contract(
        "MuseumVault", "0x000000000000000000000000000000000000a014",
        "src/economics/GovernedVault.sol:GovernedVault", "src/economics/GovernedVault.sol:GovernedVault",
        [fn("setDestination(uint64,address)", "SUCCESSOR_SETTER")],
    ),
    contract(
        "DependencyRegistry", "0x000000000000000000000000000000000000a00e",
        "src/content/DependencyRegistry.sol:DependencyRegistry", "src/content/DependencyRegistry.sol:DependencyRegistry",
        [fn("register(bytes32,bytes32,bytes32)", "PARAMETER_SETTER"), fn("deprecate(bytes32,bytes32)", "NETWORK")],
    ),
    contract(
        "EntropyModule", "0x000000000000000000000000000000000000a00f",
        "src/entropy/VrfEntropyModule.sol:VrfEntropyModule", "src/entropy/VrfEntropyModule.sol:VrfEntropyModule",
        [
            fn(f"setConfig({VRF_CONFIG},{VRF_CONFIG})", "PARAMETER_SETTER"),
            fn("setCoordinator(address,address,bytes32)", "SUCCESSOR_SETTER"),
            fn("lowerCallbackGasLimit(uint32,uint32)", "SUCCESSOR_SETTER"),
            fn("setWrapper(address,address,bytes32)", "SUCCESSOR_SETTER"),
        ],
    ),
    contract(
        "IndependentStreamRegistry", "0x000000000000000000000000000000000000a015",
        "src/independent/IndependentStreamRegistry.sol:IndependentStreamRegistry", None,
        [
            fn("approveTemplate(address,uint32,uint8)", "PARAMETER_SETTER"),
            fn("revokeTemplate(address)", "PARAMETER_SETTER"),
            fn("setAdapter(address,uint8,bool)", "SUCCESSOR_SETTER"),
            fn("suspendTemplate(address)", "PARAMETER_SETTER"),
            fn("resumeTemplate(address)", "PARAMETER_SETTER"),
            fn("setStatus(address[],uint8,bytes32)", "PARAMETER_SETTER"),
            fn("reinstateTemplate(address)", "PARAMETER_SETTER"),
            fn("setAccountDelisted(uint256,bool,bytes32)", "PARAMETER_SETTER"),
            fn("lowerFeeShare(address,uint32)", "PARAMETER_SETTER", "lower only"),
            fn("releaseContent(address,uint256,bytes32,uint256)", "PARAMETER_SETTER"),
            fn("setEntropyModule(address)", "SUCCESSOR_SETTER", "also set once at genesis"),
        ],
        "The INDEPENDENT_STREAM module behind Directory",
    ),
    contract(
        "IndependentEditionAuction", "0x000000000000000000000000000000000000a016",
        "src/independent/IndependentEditionAuction.sol:IndependentEditionAuction", None,
        [
            fn("pause()", "PAUSER"),
            fn("unpause()", "NETWORK"),
            fn(f"setConfig({EDITION_CONFIG},{EDITION_CONFIG})", "PARAMETER_SETTER"),
            fn("setLimits(uint256,uint256)", "PARAMETER_SETTER"),
            fn("adopt(address,uint256,bytes)", "NETWORK", "opens the sale of an edition the network rebound to this auction"),
            fn("closeEdition(address,uint256)", "NETWORK", "seals at zero an edition rebound to this auction that has no sale here"),
        ],
    ),
]

# PackageRegistry.bindStream runs once, at genesis, and is mapped to no role afterwards.
for _c in CONTRACTS:
    if _c["name"] == "PackageRegistry":
        _c["genesisOnly"] = [{"signature": "bindStream(address)", "selector": selector("bindStream(address)")}]

WIRING = [
    ("PackageRegistry", "bindStream(address)", ["Stream6529"], "the one Stream the package registry admits for"),
    ("PackageRegistry", "setEntropyModule(address,address)", ["0x0000000000000000000000000000000000000000", "EntropyModule"], "left out when there is no entropy module"),
    ("UniformEditionAuction", "setTarget(address,bool)", ["StreamEditions6529", True], None),
    (
        "AssetAllowlist",
        "setOpeningBid(address,uint64,uint256)",
        ["0x0000000000000000000000000000000000000000", 1, 50000000000000000],
        "ETH opening bid 0.05 ETH: a 1-wei self-bid cannot keep an unsold work from the museum",
    ),
    ("IndependentStreamRegistry", "setAdapter(address,uint8,bool)", ["EnglishAuction", 0, True], None),
    ("IndependentStreamRegistry", "setAdapter(address,uint8,bool)", ["IndependentEditionAuction", 1, True], None),
    ("IndependentStreamRegistry", "approveTemplate(address,uint32,uint8)", ["IndependentStream721Deployer", 1, 0], None),
    ("IndependentStreamRegistry", "approveTemplate(address,uint32,uint8)", ["IndependentStreamEditionsDeployer", 1, 1], None),
    ("IndependentStreamRegistry", "setEntropyModule(address)", ["EntropyModule"], "left out when there is no entropy module"),
    ("StatementLog", f"appendGovernanceManifest({STATEMENT})", [], None),
]


def build() -> dict:
    old = json.loads(OLD.read_text(encoding="utf-8"))
    wiring = []
    for target, signature, args, note in WIRING:
        row = {"contract": target, "signature": signature, "args": args}
        if note:
            row["note"] = note
        wiring.append(row)
    return {
        "schema": "6529-works/governance-genesis/2",
        "description": (
            "Example genesis configuration of the plain-core stack (ADR 0010). One network address "
            "holds every network role; operational keys are the only holders; no brake at launch. "
            "Genesis modules and minters are constructor arguments of Stream, Editions and "
            "Directory, so no bind is wired. Every waiting period in a permanent contract is a "
            "setting of the network, changed at once (NETWORK role, no role delay): moduleDelay "
            "7 days, rescueDelay 14 days, rebindDelay 14 days, unclaimedPeriod 180 days at launch. "
            "Role delays are also the network's: a class's delay holds until a 7-day remap changes "
            "it. Every address is a placeholder. Generated by config/make_core_genesis.py."
        ),
        "sources": [
            "docs/adr/0010-plain-permanent-core.md (the seam and the settings)",
            "src/governance/Roles.sol (role IDs and delays)",
            "src/interfaces/core/ and the module implementations (selectors)",
        ],
        "network": old["network"],
        "roles": old["roles"],
        "holders": old["holders"],
        "peers": [
            {"name": "SplitFactory", "address": "0x000000000000000000000000000000000000a010", "note": "the split ledger; unowned; its payout resolver is Directory"},
            {"name": "StreamWorkFacts6529", "address": "0x000000000000000000000000000000000000a019", "note": "the permanent record of every work; unowned"},
            {"name": "WorksAccessManager", "address": "0x000000000000000000000000000000000000a0ff", "note": "configurator.worksManager(); the subject of the epoch-0 manifest"},
        ],
        "manager": old["manager"],
        "contracts": CONTRACTS,
        "wiring": wiring,
        "settings": [
            {"contract": "Stream6529", "getter": "moduleDelay()", "launch": 604800},
            {"contract": "Stream6529", "getter": "rescueDelay()", "launch": 1209600},
            {"contract": "StreamEditions6529", "getter": "moduleDelay()", "launch": 604800},
            {"contract": "StreamEditions6529", "getter": "rebindDelay()", "launch": 1209600},
            {"contract": "StreamDirectory6529", "getter": "moduleDelay()", "launch": 604800},
            {"contract": "StreamDirectory6529", "getter": "unclaimedPeriod()", "launch": 15552000},
        ],
        "initialInstalls": {
            "constructor": "Genesis modules and minters of Stream, Editions and Directory (their addresses are predicted before deployment); every immutable dependency and every dependency pinned by code hash.",
            "wiring": "The package registry's Stream bind and entropy module, the edition auction's sale target, the ETH opening bid, the Independent Stream module's adapters, templates and entropy module, and the epoch-0 governance manifest.",
            "grants": "Curation signers are active once granted CURATION_SIGNER in holders.",
        },
        "unusedRoles": [
            {"role": "MINTER", "note": "Minting is gated by each token's own minter list (addMinter, after moduleDelay), not by a role."},
            {"role": "KEEPER", "note": "Every upkeep call is permissionless; no selector maps to KEEPER."},
        ],
    }


def main() -> int:
    text = json.dumps(build(), indent=2) + "\n"
    if "--check" in sys.argv[1:]:
        if OUT.read_text(encoding="utf-8") != text:
            print(f"{OUT.relative_to(ROOT)} is stale: run python config/make_core_genesis.py")
            return 1
        print(f"{OUT.relative_to(ROOT)} is current")
        return 0
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
