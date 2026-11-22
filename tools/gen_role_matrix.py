#!/usr/bin/env python3
"""Generate the role and permission matrix, docs/audit/roles.md, from the genesis configuration.

The matrix lists every restricted function of every governed contract in
`config/genesis.core.example.json` (the plain-core stack, ADR 0010): its selector, the AccessManager role it maps to, the role's delay
class and delay, and who can cancel it while it waits. It also lists the single network
authority, the brake, the roles and their holders, the genesis-only bindings, the deferred functions, the genesis wiring calls
and the AccessManager's own administrative functions.

Before rendering it checks what it can check from the configuration alone: every selector is
the keccak-256 of its signature, every role named exists, every delay equals its role's
execution delay, and every note this script adds still names a configured function. The
deeper checks (compiled selectors, every `restricted` function in src/ mapped) are
`tools/check_genesis.py`'s.

Usage, from anywhere:
  python tools/gen_role_matrix.py            rewrite docs/audit/roles.md
  python tools/gen_role_matrix.py --check    fail if docs/audit/roles.md is not current (CI)
  python tools/gen_role_matrix.py --stdout   print the matrix

Standard library only. Keccak-256 comes from tools/content/keccak.py.
"""

from __future__ import annotations

import argparse
import difflib
import importlib.util
import json
import sys
from pathlib import Path

CONFIG = "config/genesis.core.example.json"
OUTPUT = "docs/audit/roles.md"

# Delay classes, as in src/governance/Roles.sol and tools/check_genesis.py.
CLASS_DELAY = {"immediate": 0, "24h": 86_400, "3d": 259_200, "7d": 604_800}
CLASS_NAME = {
    "immediate": "No delay",
    "24h": "24 hours",
    "3d": "3 days",
    "7d": "7 days",
}

# Notes the matrix adds to configured functions, keyed by (contract, signature); a contract of
# "*" matches every contract. Each key must name at least one configured function, so a
# renamed or removed function fails generation instead of leaving a stale note.
NOTES: dict[tuple[str, str], str] = {
    # The permanent contracts (ADR 0010). Their waiting periods are the network's settings,
    # listed under "Settings of the permanent contracts".
    ("*", "proposeModule(bytes32,address)"):
        "Announces a module; anyone installs it once `moduleDelay()` has passed. An announcement "
        "keeps the time it was given if the setting changes.",
    ("*", "removeModule(bytes32)"): "At once.",
    ("*", "setModuleDelay(uint48)"):
        "A setting of the network: at once, no floor, zero allowed; `ModuleDelaySet` logs the "
        "old and the new value.",
    ("*", "addMinter(address)"): "Active once `moduleDelay()` has passed.",
    ("*", "removeMinter(address)"):
        "At once: it mints nothing new and still finishes what it started.",
    ("Stream", "setRescueDelay(uint48)"):
        "A setting of the network, at once, zero allowed; read when a rescue is attempted.",
    ("Stream", "rescue(uint256,address)"):
        "Only a token a removed minter still holds with no outcome, once `rescueDelay()` has "
        "passed since the removal. It can never reach a token a collector holds.",
    ("Editions", "setRebindDelay(uint48)"):
        "A setting of the network, at once, zero allowed; read when a rebind is attempted.",
    ("Editions", "rebind(uint256,address)"):
        "Only an edition with no copies and no seal, once `rebindDelay()` has passed since its "
        "minter was removed; the new minter adopts it.",
    ("Directory", "setUnclaimedPeriod(uint48)"):
        "A setting of the network, at once, zero allowed. The split ledger and the escrow read "
        "it when a forfeit or an expiry is attempted, so a change applies to marks and credits "
        "already running.",
    ("Stream", "createCollection(string,bytes32)"): "A collection's name never changes.",
    ("*", "setOwner(address)"): "The marketplace `owner()`.",
    ("*", "setContractURI(string)"): "Contract-level metadata (ERC-7572).",
    # The modules: replaceable; their compiled numbers are theirs.
    ("WorkRules", "relicense(address,uint256,(string,bytes32),(uint8,uint256,bytes32,bytes32,bytes32,(address,uint8)[],(uint256,address,uint32)[],(string,bytes32),uint8,bytes32,(bytes32,address,bytes),(uint32,address,bytes32,bytes)),bytes32,uint64,bytes[])"):
        "Also needs every party's signed consent. `WorkFacts` refuses to leave CC0 or pass a lock.",
    ("WorkRules", "setRoyaltyRate(address,uint256,uint24,(uint8,uint256,bytes32,bytes32,bytes32,(address,uint8)[],(uint256,address,uint32)[],(string,bytes32),uint8,bytes32,(bytes32,address,bytes),(uint32,address,bytes32,bytes)),bytes32,uint64,bytes[])"):
        "Also needs every party's signed consent; refused once the rate is locked in the token.",
    ("WorkRules", "repinRenderer(address,uint256,address,bytes32)"):
        "Refused for good once the lead artist renounced the repin power (a lock in `WorkFacts`).",
    ("WorkRules", "renounce(address,uint256,uint16,bytes32,uint64,bytes)"):
        "Relays the artist's signature; the royalty and license powers also need this role.",
    ("WorkRules", "setDelivery(address,address)"):
        "Replaces the delivery contract (locators and preferences). No fact of any work changes.",
    ("WorkRules", "addStore(address,bytes32)"):
        "Adds a store media may be found complete in, for good; code-hash pinned.",
    ("WorkRules", "retireStore(uint256)"): "Nothing new is counted against a retired store.",
    ("WorkDelivery", "addLocator(address,uint256,bytes32,(uint8,string))"):
        "The work's artist may also call it directly before finalize.",
    ("WorkDelivery", "markLocatorDead(address,uint256,bytes32,uint256)"):
        "A dead locator is passed over by every delivery tier.",
    ("StreamTerms", "lowerFeeShare(address,uint256,address,address,uint32,uint32)"):
        "Lower only; deploys the new royalty vault before it points the token at it, and "
        "applies to the edition too.",
    ("PackageRegistry", "releaseContent(address,uint256,bytes32,uint256)"):
        "After an upheld dispute, a burned token's content may be minted again for the artist.",
    ("PackageRegistry", "revokePackage(bytes32,bytes32)"):
        "Also revokes a root before it is registered.",
    ("PackageRegistry", "setVerifier(address,address,bytes32)"):
        "Never back to a retired verifier.",
    ("PackageRegistry", "killSignerApprovals(address)"):
        "Every unminted approval the signer gave stops counting.",
    ("CurationVerifier", "disableSigner(address)"):
        "Ends the signer's epoch; only `enableSigner` undoes it, under a new epoch.",
    ("CurationVerifier", "enableSigner(address)"): "Starts a new signer epoch.",
    ("Accounts", "freeze(uint256)"):
        "A freeze lasts 14 days (compiled in this module): no wallet acts and payouts read zero. "
        "A freeze blocks a contest of a replacement, and the network can end a freeze and place "
        "another.",
    ("Accounts", "cancelReplacement(uint256)"): "Withdraws the network's own pending replacement.",
    ("Accounts", "cancelOwnChange(uint256)"):
        "Cancels an account's own pending change; the account may stage a new one.",
    ("Accounts", "stageReplacement(uint256,(address,address,bytes32,bytes32),bytes32,uint64,bytes)"):
        "Needs the new root's acceptance; 14 days' notice (compiled in this module); any wallet "
        "of the account may contest during it unless the account is frozen.",
    ("Accounts", "setConsolidationSource(address,address,bytes32)"):
        "Code hash re-checked at every use.",
    ("Accounts", "resolveContested(uint256,bool,bytes32)"):
        "Must cite the DISPUTE_OUTCOME statement recorded after the contest.",
    ("FederationRegistry", "setAccountDelisted(uint256,bool,bytes32)"):
        "Delisting stops new mints for the account's federated contracts at once.",
    ("FederationRegistry", "lowerFeeShare(address,uint32)"): "Lower only.",
    ("FederationRegistry", "reinstateTemplate(address)"):
        "Moves a revoked template version back to approved.",
    ("StatementLog", "appendCurator((address,uint256,bytes32,bytes32,(uint16,bytes32),string,"
     "bytes32,bytes32))"): "Keep the grant zero-delay: a relayed `appendSigned` refuses a "
     "delayed signer, and a delayed holder could only schedule this call.",
    ("StatementLog", "appendPlatform((address,uint256,bytes32,bytes32,(uint16,bytes32),string,"
     "bytes32,bytes32))"): "PLATFORM is the only writer of DISPUTE_OUTCOME, here or by a relayed "
     "`appendSigned`. Keep the grant zero-delay, as for `appendCurator`.",
    ("StatementLog", "appendGovernanceManifest((address,uint256,bytes32,bytes32,(uint16,bytes32),"
     "string,bytes32,bytes32))"): "One entry per configuration epoch; also wired at genesis.",
    ("StatementLog", "setArtistResolver(address,address,bytes32)"):
        "Code hash re-checked at every artist statement.",
    ("*", "pause()"): "Stops new sales only; running sales, settlement and claims continue.",
    ("*", "unpause()"): "No wait of its own: the network lifts the pause at once.",
    ("EnglishAuction", "pause(uint256,bytes32)"):
        "Dispute pause: one per auction, ending by itself after 3 days (compiled in this module).",
    ("EnglishAuction", "resume(uint256)"): "At any moment of the pause.",
    ("EnglishAuction", "cancel(uint256,bytes32)"):
        "Upheld dispute, at any moment of the pause, citing the token's DISPUTE_OUTCOME; burns "
        "the token and refunds the bid.",
    ("*", "setTarget(address,bool)"): "Also a genesis wiring call.",
    ("AssetAllowlist", "setOpeningBid(address,uint64,uint256)"):
        "The English auction's least first bid in ETH; also a genesis wiring call.",
    ("EconomicsResolver", "setFeeTerms(bytes32,uint64,address,uint32)"):
        "New works only; refuses a fee recipient that could never be paid.",
    ("EconomicsResolver", "setRoyaltyRate(bytes32,uint64,uint32)"): "New works only.",
    ("EconomicsResolver", "setDefaultLicense(bytes32,uint64,(string,bytes32))"): "New works only.",
    ("EconomicsResolver", "setMuseum(uint64,address)"):
        "Where unsold 6529 Stream works go at settlement; refuses zero and a contract that could "
        "never hold a work.",
    ("FeeRecipientVault", "setDestination(uint64,address)"):
        "Where every held and future network fee goes.",
    ("MuseumVault", "setDestination(uint64,address)"):
        "Where every museum-held work and payout goes.",
    ("RevenueEscrow", "recover(address,address,address)"): "Only to an identical-configuration "
     "replacement wallet, or to the replacement the account itself named; the network's own "
     "parked credits need no consent.",
    ("DependencyRegistry", "register(bytes32,bytes32,bytes32)"):
        "The file must be complete on chain; a registered version never changes.",
    ("DependencyRegistry", "deprecate(bytes32,bytes32)"): "A one-way flag; the version stays readable.",
    ("EntropyModule", "lowerCallbackGasLimit(uint32,uint32)"): "Never below the floor.",
}

# Notes that replace the configuration's own note for the manager's added functions (the
# `manager` section of the configuration), where the matrix states the rule more precisely.
MANAGER_NOTES: dict[str, str] = {
    "transferNetwork(address)": "Proposes the next network address (zero withdraws); it takes "
    "effect when that address calls `acceptNetwork`, and the old address then holds nothing.",
}

# The AccessManager's own restricted functions (OpenZeppelin 5.7.0, `_getAdminRestrictions`),
# and the target function every managed contract inherits from AccessManaged. "admin" is the
# ADMIN role's execution delay; "target" adds the target's admin delay (the larger applies).
MANAGER_FUNCTIONS: tuple[tuple[str, str, str, str], ...] = (
    ("grantRole(uint64,address,uint32)", "NETWORK, for an operational role", "none",
     "No grant delay. A network role can be granted to nobody (`NetworkRoleNotGrantable`)."),
    ("revokeRole(uint64,address)", "NETWORK, for an operational role", "none",
     "Takes effect at once."),
    ("renounceRole(uint64,address)", "The holder itself", "none",
     "Immediate; the second argument must be the caller."),
    ("labelRole(uint64,string)", "ADMIN", "admin", ""),
    ("setRoleAdmin(uint64,uint64)", "ADMIN", "admin", ""),
    ("setRoleGuardian(uint64,uint64)", "ADMIN", "admin", ""),
    ("setGrantDelay(uint64,uint32)", "ADMIN", "admin",
     "A reduction takes effect after its length, and never sooner than `minSetback()`."),
    ("setTargetAdminDelay(address,uint32)", "ADMIN", "admin",
     "A reduction takes effect after its length, and never sooner than `minSetback()`."),
    ("setTargetFunctionRole(address,bytes4[],uint64)", "ADMIN", "target", ""),
    ("setTargetClosed(address,bool)", "ADMIN", "target", ""),
    ("updateAuthority(address,address)", "ADMIN", "target",
     "Moves one target to another authority; it checks nothing about the new authority."),
    ("setAuthority(address)", "ADMIN, scheduled on the target itself", "target", ""),
)

_KECCAK = None


def keccak256(data: bytes) -> bytes:
    """Keccak-256 from tools/content/keccak.py, loaded by path (no package import needed)."""
    global _KECCAK
    if _KECCAK is None:
        path = Path(__file__).resolve().parent / "content" / "keccak.py"
        spec = importlib.util.spec_from_file_location("works_keccak", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _KECCAK = module.keccak256
    return _KECCAK(data)


def selector(signature: str) -> str:
    return "0x" + keccak256(signature.encode("ascii"))[:4].hex()


def format_delay(seconds: int) -> str:
    if seconds == 0:
        return "immediate"
    if seconds % 86_400 == 0 and seconds >= 3 * 86_400:
        return f"{seconds // 86_400} days"
    if seconds % 3_600 == 0:
        return f"{seconds // 3_600} hours"
    return f"{seconds} seconds"


def _split_top_level(params: str) -> list[str]:
    parts, depth, current = [], 0, []
    for c in params:
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        if c == "," and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(c)
    if current:
        parts.append("".join(current))
    return parts


def short_signature(signature: str, limit: int = 24) -> str:
    """The signature with every top-level tuple longer than `limit` characters shown as (…)."""
    name, _, rest = signature.partition("(")
    params = rest[:-1]
    shown = []
    for param in _split_top_level(params):
        if param.startswith("("):
            close = param.rfind(")")
            tuple_part, suffix = param[: close + 1], param[close + 1 :]
            if len(tuple_part) > limit:
                param = "(…)" + suffix
        shown.append(param)
    return f"{name}({','.join(shown)})"


def cancel_rule(delay: int) -> str:
    if delay == 0:
        return "No: executes at once"
    return "The network or the scheduler, during the delay; the brake may delay it once"


def holder_label(label: str) -> str:
    return label.split(" (", 1)[0]


class ConfigError(Exception):
    pass


def validate(config: dict) -> None:
    """Fail on anything the matrix would render wrongly."""
    roles = {r["name"]: r for r in config["roles"]}
    for role in config["roles"]:
        cls, delay = role["executionClass"], role["executionDelay"]
        if CLASS_DELAY.get(cls) != delay:
            raise ConfigError(f"role {role['name']}: execution class {cls!r} is not {delay} seconds")
        if role.get("grantDelay", 0) != 0:
            raise ConfigError(f"role {role['name']}: grant delays are not used")
    seen: set[tuple[str, str]] = set()
    for contract in config["contracts"]:
        name = contract["name"]
        for group in ("functions", "genesisOnly", "deferred"):
            for entry in contract.get(group) or []:
                sig = entry["signature"]
                if entry["selector"] != selector(sig):
                    raise ConfigError(f"{name}.{sig}: selector {entry['selector']} is not {selector(sig)}")
                seen.add((name, sig))
                if group != "functions":
                    continue
                role = roles.get(entry["role"])
                if role is None:
                    raise ConfigError(f"{name}.{sig}: unknown role {entry['role']!r}")
                if entry["delay"] != role["executionDelay"] or entry["class"] != role["executionClass"]:
                    raise ConfigError(f"{name}.{sig}: class or delay differs from role {entry['role']}")
    for holder in config["holders"]:
        if holder["role"] not in roles:
            raise ConfigError(f"holder {holder['label']!r}: unknown role {holder['role']!r}")
    for entry in (config.get("manager") or {}).get("functions", []):
        sig = entry["signature"]
        if entry["selector"] != selector(sig):
            raise ConfigError(f"manager.{sig}: selector {entry['selector']} is not {selector(sig)}")
        role = roles.get(entry["role"])
        if role is None:
            raise ConfigError(f"manager.{sig}: unknown role {entry['role']!r}")
        if entry["delay"] != role["executionDelay"] or entry["class"] != role["executionClass"]:
            raise ConfigError(f"manager.{sig}: class or delay differs from role {entry['role']}")
    for entry in (config.get("manager") or {}).get("open", []):
        sig = entry["signature"]
        if entry["selector"] != selector(sig):
            raise ConfigError(f"manager.{sig}: selector {entry['selector']} is not {selector(sig)}")
    contracts = {c["name"] for c in config["contracts"]}
    for call in config["wiring"]:
        if call["contract"] not in contracts:
            raise ConfigError(f"wiring call on unknown contract {call['contract']!r}")
    manager = {f["signature"] for f in (config.get("manager") or {}).get("functions", [])}
    for sig in MANAGER_NOTES:
        if config.get("manager") is not None and sig not in manager:
            raise ConfigError(f"manager note for {sig} names no configured manager function")
    for contract, sig in NOTES:
        if contract == "*":
            if not any(s == sig for _, s in seen):
                raise ConfigError(f"note for *.{sig} names no configured function")
        elif (contract, sig) not in seen:
            raise ConfigError(f"note for {contract}.{sig} names no configured function")


def note_for(contract: str, signature: str) -> str:
    return NOTES.get((contract, signature)) or NOTES.get(("*", signature), "")


def render(config: dict) -> str:
    validate(config)
    roles = config["roles"]
    by_name = {r["name"]: r for r in roles}
    admin_delay = by_name["ADMIN"]["executionDelay"]
    holders: dict[str, list[str]] = {}
    for h in config["holders"]:
        label = holder_label(h["label"])
        holders.setdefault(h["role"], [])
        if label not in holders[h["role"]]:
            holders[h["role"]].append(label)
    unused = {u["role"]: u["note"] for u in config.get("unusedRoles", [])}
    mapped = [(c["name"], f) for c in config["contracts"] for f in c.get("functions", [])]
    full_signatures: list[tuple[str, str]] = []

    out: list[str] = []
    w = out.append
    w(f"<!-- Generated by tools/gen_role_matrix.py from {CONFIG}. Do not edit by")
    w("     hand: change the configuration, then run `python tools/gen_role_matrix.py`. -->")
    w("")
    w("# Role and permission matrix")
    w("")
    w("Every restricted function of every governed 6529 Works contract: the AccessManager role it")
    w("maps to, the role's delay class and delay, and who can cancel it while it waits. Generated")
    w(f"from [`{CONFIG}`](../../{CONFIG}), the")
    w("committed genesis policy, by [`tools/gen_role_matrix.py`](../../tools/gen_role_matrix.py).")
    w("")
    w("> Pre-audit. See the [project status](../../README.md#status).")
    w("")
    w("Every address in the configuration is a placeholder; a deployment may change only its")
    w("holders, its network and brake addresses. `tools/check_genesis.py` checks the configuration against the compiled selectors and")
    w("every `restricted` function in `src/` (CI job Contracts), and")
    w("`python tools/gen_role_matrix.py --check` checks this page against the configuration (CI job")
    w("Docs).")
    w("")
    w("## The network and the brake")
    w("")
    w("One address, `network()`, holds every network role: ADMIN (7 days), NETWORK (no delay),")
    w("PARAMETER_SETTER (24 hours), FUNDS_SETTER (3 days) and SUCCESSOR_SETTER (7 days). Nobody")
    w("else can be granted them. Until the TDH bridge exists it is one 6529 Safe; it hands over")
    w("with `transferNetwork` (7 days) and the next address's `acceptNetwork`. A brake, if the")
    w("network sets one (none at launch), may delay any scheduled operation once by 7 days.")
    w("")
    w("A role's delay is the network's too: ADMIN can remap a selector to another role, or")
    w("change a role's delay, with one 7-day action, so a class's delay holds until such a remap")
    w("changes it. No delay on this page is a guarantee.")
    w("")
    settings = config.get("settings") or []
    if settings:
        w("## Settings of the permanent contracts")
        w("")
        w("There are no fixed waiting periods in the permanent contracts. Each wait is a stored")
        w("setting with a launch value, which the network changes at once (no floor, zero")
        w("allowed), with an event carrying the old and the new value. Read the getter; never")
        w("assume the number.")
        w("")
        w("| Contract | Setting | Launch value |")
        w("| --- | --- | --- |")
        for item in settings:
            w(f"| {item['contract']} | `{item['getter']}` | {format_delay(item['launch'])} |")
        w("")
    w("## How to read the matrix")
    w("")
    w("- **Role.** The selector's role in the `WorksAccessManager`. The network schedules a call")
    w("  whose role has a delay, waits the delay, then executes it.")
    w("- **Cancel.** A scheduled operation can be cancelled by the network or by whoever")
    w("  scheduled it before it executes; the brake can delay it once. A function with no delay")
    w("  executes at once, so there is nothing to cancel.")
    w("- **Expiry.** A scheduled operation must execute within 14 days of becoming executable")
    w("  (`expiration()`: one week plus the brake's 7 days), or it must be scheduled again.")
    w(f"- **Unmapped selectors** fall back to ADMIN and its delay ({format_delay(admin_delay)}).")
    w("- Long tuple parameters are shown as `(…)`; [Full signatures](#full-signatures) lists them.")
    w("- The rules behind the classes are in the [governance spec](../spec/governance.md).")
    w("")
    w("## Roles")
    w("")
    w("| Role | ID | Execution delay | Held by | Holders at genesis | Mapped selectors |")
    w("| --- | ---: | --- | --- | --- | ---: |")
    for r in roles:
        count = sum(1 for _, f in mapped if f["role"] == r["name"])
        who = ", ".join(holders.get(r["name"], [])) or "none"
        if r["name"] in unused:
            who += " (unused in v1)"
        held = "`network()` only" if r.get("network") else "operational keys"
        if r.get("network"):
            who = "the network"
        w(f"| `{r['name']}` | {r['id']} | {format_delay(r['executionDelay'])} | "
          f"{held} | {who} | {count} |")
    w("")
    w("Every operational role's admin is NETWORK, so the network grants and revokes those keys at")
    w("once; the network roles answer for `network()` only ([`Roles.sol`](../../src/governance/Roles.sol),")
    w("[`WorksAccessManager.sol`](../../src/governance/WorksAccessManager.sol)).")
    if unused:
        w("")
        for name, note in unused.items():
            w(f"- **`{name}` is unused in v1.** {note}")
    w("")
    w("## Delay classes")
    w("")
    w("| Class | Delay | Mapped selectors |")
    w("| --- | --- | ---: |")
    for cls, delay in CLASS_DELAY.items():
        count = sum(1 for _, f in mapped if f["class"] == cls)
        w(f"| {CLASS_NAME[cls]} | {format_delay(delay)} | {count} |")
    w(f"| **Total** | | **{len(mapped)}** |")
    w("")
    w("## Matrix by contract")
    for contract in config["contracts"]:
        functions = contract.get("functions", [])
        w("")
        w(f"### {contract['name']}")
        w("")
        source = contract["artifact"].split(":", 1)[0]
        w(f"Source: [`{source}`](../../{source}).")
        w("")
        if not functions:
            w("No mapped functions.")
            continue
        w("| Function | Selector | Role | Class | Delay | Cancel | Notes |")
        w("| --- | --- | --- | --- | --- | --- | --- |")
        for f in functions:
            short = short_signature(f["signature"])
            if short != f["signature"]:
                full_signatures.append((f["selector"], f["signature"]))
            w(f"| `{short}` | `{f['selector']}` | `{f['role']}` | {CLASS_NAME[f['class']]} | "
              f"{format_delay(f['delay'])} | {cancel_rule(f['delay'])} | "
              f"{note_for(contract['name'], f['signature'])} |")
    w("")
    w("## Genesis-only bindings")
    w("")
    bindings = [(c["name"], f) for c in config["contracts"] for f in c.get("genesisOnly") or []]
    if bindings:
        w("One-shot bindings between protocol contracts. The configurator executes them at")
        w("genesis as zero-delay ADMIN, before it maps any selector; each target refuses a second")
        w(f"call. They stay unmapped, so any later call resolves to ADMIN ({format_delay(admin_delay)}).")
        w("")
        w("| Contract | Function | Selector |")
        w("| --- | --- | --- |")
        for name, f in bindings:
            w(f"| {name} | `{f['signature']}` | `{f['selector']}` |")
    else:
        w("None. The genesis modules and minters of Stream, Editions and Directory are constructor")
        w("arguments (their addresses are predicted before deployment); every later addition waits")
        w("`moduleDelay()`.")
    deferred = [(c["name"], f) for c in config["contracts"] for f in c.get("deferred") or []]
    if deferred:
        w("")
        w("## Deferred")
        w("")
        w("Restricted functions neither mapped nor wired in v1. Until mapped, they resolve to ADMIN.")
        w("")
        w("| Contract | Function | Selector | Note |")
        w("| --- | --- | --- | --- |")
        for name, f in deferred:
            w(f"| {name} | `{f['signature']}` | `{f['selector']}` | {f.get('note', '')} |")
    w("")
    w("## Genesis wiring")
    w("")
    w("The calls `GovernanceConfigurator.configure` executes, in order, before it maps selectors")
    w("and renounces its installer record; it then proposes the network, which accepts.")
    w("`GovernanceConfig.isGenesisSelector` admits nothing else.")
    w("")
    w("| # | Contract | Call | Arguments |")
    w("| ---: | --- | --- | --- |")
    for i, call in enumerate(config["wiring"]):
        args = ", ".join(_format_arg(a) for a in call.get("args", []))
        if call.get("note"):
            args = f"{args} ({call['note']})" if args else call["note"]
        if not args and call.get("statement"):
            args = f"the epoch-0 `{call['statement']['kind']}` statement about the manager"
        w(f"| {i} | {call['contract']} | `{short_signature(call['signature'])}` | {args} |")
    w("")
    w("## The AccessManager's own functions")
    w("")
    w("Administration of the manager itself (OpenZeppelin 5.7.0). The delay is ADMIN's execution")
    w(f"delay ({format_delay(admin_delay)}); for functions that name a target, the target's admin")
    w("delay applies if it is longer; genesis sets no target admin delay.")
    w("")
    w("| Function | Selector | Caller | Delay | Cancel | Notes |")
    w("| --- | --- | --- | --- | --- | --- |")
    for sig, caller, kind, note in MANAGER_FUNCTIONS:
        delay = 0 if kind == "none" else admin_delay
        shown = format_delay(delay)
        if kind == "target":
            shown += " (or the target's admin delay)"
        cancel = cancel_rule(delay)
        w(f"| `{sig}` | `{selector(sig)}` | {caller} | {shown} | {cancel} | {note} |")
    for f in (config.get("manager") or {}).get("functions", []):
        note = MANAGER_NOTES.get(f["signature"], f.get("note", ""))
        w(f"| `{f['signature']}` | `{f['selector']}` | `{f['role']}` | "
          f"{format_delay(f['delay'])} | {cancel_rule(f['delay'])} | {note} |")
    for f in (config.get("manager") or {}).get("open", []):
        w(f"| `{f['signature']}` | `{f['selector']}` | No role (checked in the function) | "
          f"{format_delay(0)} | {cancel_rule(0)} | {f.get('note', '')} |")
    w("")
    w("`schedule`, `execute` and `cancel` are open to anyone and check the caller's permission")
    w("for the call they carry.")
    w("")
    w("## Full signatures")
    w("")
    if full_signatures:
        w("| Selector | Signature |")
        w("| --- | --- |")
        for sel, sig in full_signatures:
            w(f"| `{sel}` | `{sig}` |")
    else:
        w("No signature is abbreviated.")
    return "\n".join(out) + "\n"


def _format_arg(arg: object) -> str:
    if isinstance(arg, bool):
        return "`true`" if arg else "`false`"
    if arg == "0x" + "0" * 40:
        return "`address(0)` (ETH)"
    if isinstance(arg, str) and arg.startswith("0x"):
        return f"`{arg[:10]}…`" if len(arg) > 42 else f"`{arg}`"
    return str(arg) if not isinstance(arg, str) else arg


def repository_root() -> Path:
    return Path(__file__).resolve().parent.parent


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, help="repository root (default: parent of tools/)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help=f"fail if {OUTPUT} is not current")
    mode.add_argument("--stdout", action="store_true", help="print the matrix instead of writing it")
    args = parser.parse_args(argv)

    root = (args.root or repository_root()).resolve()
    # Until integration, the earlier stack's configuration is still committed beside this one.
    config = json.loads((root / CONFIG).read_text(encoding="utf-8"))
    try:
        text = render(config)
    except (ConfigError, KeyError) as error:
        print(f"FAIL {CONFIG}: {error}")
        return 1
    target = root / OUTPUT
    if args.stdout:
        sys.stdout.write(text)
        return 0
    if args.check:
        current = target.read_text(encoding="utf-8").replace("\r\n", "\n") if target.exists() else ""
        if current == text:
            print(f"role matrix: {OUTPUT} is current")
            return 0
        diff = difflib.unified_diff(
            current.splitlines(), text.splitlines(), f"{OUTPUT} (committed)", f"{OUTPUT} (generated)",
            lineterm="", n=1,
        )
        for line in list(diff)[:60]:
            print(line)
        print(f"FAIL {OUTPUT} is not current: run `python tools/gen_role_matrix.py` and commit it")
        return 1
    target.parent.mkdir(parents=True, exist_ok=True)
    with open(target, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    print(f"role matrix: wrote {OUTPUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
