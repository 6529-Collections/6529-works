#!/usr/bin/env python3
"""Generate the role and permission matrix, docs/audit/roles.md, from the genesis configuration.

The matrix lists every restricted function of every governed contract in
`config/genesis.example.json`: its selector, the AccessManager role it maps to, the role's delay
class and delay, and whether a guardian can cancel it while it waits. It also lists the roles
and their holders, the genesis-only bindings, the deferred functions, the genesis wiring calls
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

CONFIG = "config/genesis.example.json"
OUTPUT = "docs/audit/roles.md"

# Delay classes, as in src/governance/Roles.sol and tools/check_genesis.py.
CLASS_DELAY = {"immediate": 0, "standard": 172_800, "funds": 1_209_600, "successor": 2_592_000}
CLASS_NAME = {
    "immediate": "Immediate",
    "standard": "Standard",
    "funds": "Funds and recipients",
    "successor": "Verifier and successor",
}

# Notes the matrix adds to configured functions, keyed by (contract, signature); a contract of
# "*" matches every contract. Each key must name at least one configured function, so a
# renamed or removed function fails generation instead of leaving a stale note.
NOTES: dict[tuple[str, str], str] = {
    ("Stream", "createCollection(string,bytes32)"): "Collection names are checked on-chain.",
    ("*", "setOwner(address,address)"): "The marketplace `owner()`; compare-and-set.",
    ("*", "setContractURI(string)"): "Contract-level metadata (ERC-7572).",
    ("Stream", "setDefaultRenderer(address,address,bytes32)"):
        "Compare-and-set; ERC-165 and code hash pinned. Finalized works keep their pin.",
    ("*", "setAdmittedMinter(address,bool)"): "Also a genesis wiring call.",
    ("Stream", "releaseContent(uint256,bytes32,uint256)"):
        "After an upheld dispute; scheduled with the auction's `cancel`, to execute after it.",
    ("WorkRecords", "addLocator(uint256,bytes32,(uint8,string))"):
        "The work's artist may also call it directly before finalize; PLATFORM's path is a "
        "`canCall` check in the contract and needs a zero-delay grant.",
    ("WorkRecords", "relicense(uint256,(string,bytes32),(uint8,uint256,bytes32,bytes32,bytes32,"
     "(address,uint8)[],(uint256,address,uint32)[],(string,bytes32),uint8,bytes32,"
     "(bytes32,address,bytes),(uint32,address,bytes32,bytes)),bytes32,uint64,bytes[])"): "Also needs every party's signed consent. CC0 is irrevocable.",
    ("WorkRecords", "setRoyaltyRate(uint256,uint32,(uint8,uint256,bytes32,bytes32,bytes32,"
     "(address,uint8)[],(uint256,address,uint32)[],(string,bytes32),uint8,bytes32,"
     "(bytes32,address,bytes),(uint32,address,bytes32,bytes)),bytes32,uint64,bytes[])"): "Also needs every party's signed consent; re-rates the linked edition.",
    ("WorkRecords", "repinRenderer(uint256,address,bytes32,bytes32,uint64,bytes)"):
        "The errata repin: also needs the lead artist's signature.",
    ("PackageRegistry", "revokePackage(bytes32,bytes32)"):
        "Also revokes a root before it is registered.",
    ("PackageRegistry", "setVerifier(address,address,bytes32)"):
        "Compare-and-set; never back to a retired verifier.",
    ("CurationVerifier", "disableSigner(address)"):
        "Ends the signer's epoch; only `enableSigner` undoes it, under a new epoch.",
    ("CurationVerifier", "enableSigner(address)"): "Starts a new signer epoch.",
    ("ArtistRegistry", "vetoChange(uint256)"): "Deletes a pending change; never redirects one.",
    ("ArtistRegistry", "stageOverride(uint256,uint8,(address,address,bytes32,bytes32),bytes32,"
     "uint64,bytes)"): "Starts a 180-day notice. An override that moves the authority "
     "restrains the artist until it ends.",
    ("ArtistRegistry", "setConsolidationSource(address,address,bytes32)"):
        "Compare-and-set; code hash re-checked at every use.",
    ("ArtistRegistry", "resolveContested(uint256,bool,bytes32)"):
        "Must cite the DISPUTE_OUTCOME statement recorded after the contest.",
    ("StatementLog", "appendCurator((address,uint256,bytes32,bytes32,(uint16,bytes32),string,"
     "bytes32,bytes32))"): "Keep the grant zero-delay: a relayed `appendSigned` refuses a "
     "delayed signer, and a delayed holder could only schedule this call.",
    ("StatementLog", "appendPlatform((address,uint256,bytes32,bytes32,(uint16,bytes32),string,"
     "bytes32,bytes32))"): "PLATFORM is the only writer of DISPUTE_OUTCOME, here or by a relayed "
     "`appendSigned`. Keep the grant zero-delay, as for `appendCurator`.",
    ("StatementLog", "appendGovernanceManifest((address,uint256,bytes32,bytes32,(uint16,bytes32),"
     "string,bytes32,bytes32))"): "One entry per configuration epoch; also wired at genesis.",
    ("StatementLog", "setArtistResolver(address,address,bytes32)"):
        "Compare-and-set; code hash re-checked at every artist statement.",
    ("*", "pause()"): "Stops `openSale` and `purchase`; closing a sale and claims still work.",
    ("EnglishAuction", "pause()"): "Stops new starts only; live auctions continue.",
    ("UniformEditionAuction", "pause()"):
        "Stops new `open` calls only; bids, raises, settlement and claims of open sales continue.",
    ("*", "unpause()"): "Refused until 48 hours after the pause, whenever it was scheduled.",
    ("EnglishAuction", "pause(uint256,bytes32)"):
        "Dispute pause: one per auction, lasting at most 7 days (`MAX_PAUSE`).",
    ("EnglishAuction", "resume(uint256)"):
        "Refused until 48 hours after the pause, whenever it was scheduled.",
    ("EnglishAuction", "cancel(uint256,bytes32)"):
        "Upheld dispute: while paused, citing the token's DISPUTE_OUTCOME recorded after the "
        "pause.",
    ("EnglishAuction", "setOpeningBid(address,uint256,uint256)"):
        "Per currency; compare-and-set, with a ceiling.",
    ("EnglishAuction", "setConfig((uint32,uint32,uint32),(uint32,uint32,uint32))"):
        "Duration, anti-snipe window and increment share; compare-and-set.",
    ("*", "setTarget(address,bool)"): "Also a genesis wiring call.",
    ("*", "setFederationRegistry(address,address)"): "v1.1: no registry is installed in v1.",
    ("UniformEditionAuction", "setConfig((uint96,uint16,uint16,uint32,uint32,uint32,uint32),"
     "(uint96,uint16,uint16,uint32,uint32,uint32,uint32))"):
        "Margin, step ladder, close offset, soft-close window and backstop; compare-and-set, "
        "with bounds in code. An auction keeps the values locked at its open.",
    ("EconomicsResolver", "setFeeTerms(bytes32,uint64,address,uint32)"):
        "New works only; compare-and-set on the product's revision; refuses a fee recipient "
        "that could never be paid.",
    ("EconomicsResolver", "setRoyaltyRate(bytes32,uint64,uint32)"):
        "New works only; compare-and-set on the product's revision.",
    ("EconomicsResolver", "setDefaultLicense(bytes32,uint64,(string,bytes32))"):
        "New works only; compare-and-set on the product's revision.",
    ("EconomicsResolver", "setMuseum(uint64,address)"):
        "The 6529 Network Museum (D140): every settlement afterwards, running sales included; "
        "compare-and-set on the museum's revision; refuses zero and a contract that could never "
        "hold a work.",
    ("AssetAllowlist", "admitAsset(address,uint64,uint256)"):
        "Compare-and-set; a re-admission waits 14 days from the deprecation.",
    ("AssetAllowlist", "setDefaultCurrency(bytes32,uint64,address)"):
        "Compare-and-set; also a genesis wiring call (ETH for each product).",
    ("AssetAllowlist", "deprecateAsset(address)"):
        "Halts sales in the asset; withdrawals and claims never stop.",
    ("RevenueEscrow", "recover(address,address,address)"): "Only to an identical-configuration "
     "replacement wallet, or to the replacement the account itself named.",
    ("DependencyRegistry", "register(bytes32,bytes32,bytes32)"):
        "The file must be complete on-chain; a registered version never changes.",
    ("DependencyRegistry", "deprecate(bytes32,bytes32)"): "A one-way flag; the version stays readable.",
    ("EntropyModule", "setConfig((uint256,bytes32,uint32,uint16,bool),(uint256,bytes32,uint32,"
     "uint16,bool))"): "Compare-and-set; the callback gas limit only rises (at most 2x a step).",
    ("EntropyModule", "lowerCallbackGasLimit(uint32,uint32)"): "Never below the floor.",
}

# Notes that replace the configuration's own note for the manager's added functions (the
# `manager` section of the configuration), where the matrix states the rule more precisely.
MANAGER_NOTES: dict[str, str] = {
    "suspend(uint64,address)": "Suspends a holder of a suspendable role at once. Lifted by an ADMIN "
    "`grantRole` or `revokeRole` of that role to that account (30 days), or by the holder's own "
    "`renounceRole`; no guardian can lift it.",
}

# The AccessManager's own restricted functions (OpenZeppelin 5.7.0, `_getAdminRestrictions`),
# and the target function every managed contract inherits from AccessManaged. "admin" is the
# ADMIN role's execution delay; "target" adds the target's admin delay (the larger applies).
MANAGER_FUNCTIONS: tuple[tuple[str, str, str, str], ...] = (
    ("grantRole(uint64,address,uint32)", "The role's admin (ADMIN for every role)", "admin",
     "The grant then waits the role's grant delay."),
    ("revokeRole(uint64,address)", "The role's admin (ADMIN for every role)", "admin",
     "Only a guardian or its scheduler can cancel it, and the account it revokes only if it "
     "scheduled it."),
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
    ("updateAuthority(address,address)", "ADMIN", "target", ""),
    ("setAuthority(address)", "ADMIN, scheduled on the target itself", "target",
     "Stock OpenZeppelin lets only ADMIN cancel this; the guardians can too."),
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


def guardian_cancel(delay: int) -> str:
    if delay == 0:
        return "No: executes at once"
    return "Yes: any guardian, during the delay"


def holder_label(label: str) -> str:
    return label.split(" (", 1)[0]


class ConfigError(Exception):
    pass


def validate(config: dict) -> None:
    """Fail on anything the matrix would render wrongly."""
    roles = {r["name"]: r for r in config["roles"]}
    for role in config["roles"]:
        for kind in ("execution", "grant"):
            cls, delay = role[f"{kind}Class"], role[f"{kind}Delay"]
            if CLASS_DELAY.get(cls) != delay:
                raise ConfigError(f"role {role['name']}: {kind} class {cls!r} is not {delay} seconds")
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
    w("<!-- Generated by tools/gen_role_matrix.py from config/genesis.example.json. Do not edit by")
    w("     hand: change the configuration, then run `python tools/gen_role_matrix.py`. -->")
    w("")
    w("# Role and permission matrix")
    w("")
    w("Every restricted function of every governed 6529 Works contract: the AccessManager role it")
    w("maps to, the role's delay class and delay, and whether a guardian can cancel it while it")
    w("waits. Generated from [`config/genesis.example.json`](../../config/genesis.example.json), the")
    w("committed genesis policy, by [`tools/gen_role_matrix.py`](../../tools/gen_role_matrix.py).")
    w("")
    w("> Pre-audit. See the [project status](../../README.md#status).")
    w("")
    w("Every address in the configuration is a placeholder; a deployment may change only its")
    w("holders. `tools/check_genesis.py` checks the configuration against the compiled selectors and")
    w("every `restricted` function in `src/` (CI job Contracts), and")
    w("`python tools/gen_role_matrix.py --check` checks this page against the configuration (CI job")
    w("Docs).")
    w("")
    w("## How to read the matrix")
    w("")
    w("- **Role.** The selector's role in the `WorksAccessManager`. A holder whose role has a delay")
    w("  schedules the call, waits the delay, then executes it.")
    w("- **Guardian cancel.** In [`WorksAccessManager`](../../src/governance/WorksAccessManager.sol)")
    w("  any GUARDIAN holder may cancel any scheduled operation before it executes (Rule 1), except")
    w("  an operation that revokes one of the guardian's own roles and that someone else scheduled")
    w("  (Rule 2). A role revocation on the manager that another account scheduled can be cancelled")
    w("  only by a guardian (Rule 3); a scheduler may always cancel its own operation. An immediate")
    w("  function executes at once, so there is nothing to cancel.")
    w("- **Expiry.** A scheduled operation must execute within one week of becoming executable")
    w("  (`expiration()`), or it must be scheduled again with the full delay.")
    w(f"- **Unmapped selectors** fall back to ADMIN and its delay ({format_delay(admin_delay)}).")
    w("- Long tuple parameters are shown as `(…)`; [Full signatures](#full-signatures) lists them.")
    w("- The rules behind the classes are in the [governance spec](../spec/governance.md).")
    w("")
    w("## Roles")
    w("")
    suspendable = any("suspendable" in r for r in roles)
    extra_head = " Guardian may suspend |" if suspendable else ""
    extra_rule = " --- |" if suspendable else ""
    w("| Role | ID | Execution delay | Grant delay | Holders at genesis | Mapped selectors |"
      + extra_head)
    w("| --- | ---: | --- | --- | --- | ---: |" + extra_rule)
    for r in roles:
        count = sum(1 for _, f in mapped if f["role"] == r["name"])
        who = ", ".join(holders.get(r["name"], [])) or "none"
        if r["name"] in unused:
            who += " (unused in v1)"
        extra = (" Yes |" if r.get("suspendable") else " No |") if suspendable else ""
        w(f"| `{r['name']}` | {r['id']} | {format_delay(r['executionDelay'])} | "
          f"{format_delay(r['grantDelay'])} | {who} | {count} |" + extra)
    w("")
    w("Every role's admin is ADMIN, and every role except ADMIN has GUARDIAN as its guardian")
    w("([`Roles.sol`](../../src/governance/Roles.sol)). Guardians hold only GUARDIAN and PAUSER.")
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
        w("| Function | Selector | Role | Class | Delay | Guardian cancel | Notes |")
        w("| --- | --- | --- | --- | --- | --- | --- |")
        for f in functions:
            short = short_signature(f["signature"])
            if short != f["signature"]:
                full_signatures.append((f["selector"], f["signature"]))
            w(f"| `{short}` | `{f['selector']}` | `{f['role']}` | {CLASS_NAME[f['class']]} | "
              f"{format_delay(f['delay'])} | {guardian_cancel(f['delay'])} | "
              f"{note_for(contract['name'], f['signature'])} |")
    w("")
    w("## Genesis-only bindings")
    w("")
    w("One-shot bindings between protocol contracts. The configurator executes them at genesis as")
    w("zero-delay ADMIN, before it maps any selector; each target refuses a second call. They stay")
    w(f"unmapped, so any later call resolves to ADMIN ({format_delay(admin_delay)}), which a guardian")
    w("can cancel.")
    w("")
    w("| Contract | Function | Selector |")
    w("| --- | --- | --- |")
    for contract in config["contracts"]:
        for f in contract.get("genesisOnly") or []:
            w(f"| {contract['name']} | `{f['signature']}` | `{f['selector']}` |")
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
    w("and renounces ADMIN. `GovernanceConfig.isGenesisSelector` admits nothing else.")
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
    w("delay applies if it is longer. Every target's admin delay is the successor class")
    w("(`GovernanceConfig.TARGET_ADMIN_DELAY`).")
    w("")
    w("| Function | Selector | Caller | Delay | Guardian cancel | Notes |")
    w("| --- | --- | --- | --- | --- | --- |")
    for sig, caller, kind, note in MANAGER_FUNCTIONS:
        delay = 0 if kind == "none" else admin_delay
        shown = format_delay(delay)
        if kind == "target":
            shown += " (or the target's admin delay)"
        cancel = guardian_cancel(delay)
        if sig.startswith("revokeRole"):
            cancel = "Yes, except by the account being revoked"
        w(f"| `{sig}` | `{selector(sig)}` | {caller} | {shown} | {cancel} | {note} |")
    for f in (config.get("manager") or {}).get("functions", []):
        note = MANAGER_NOTES.get(f["signature"], f.get("note", ""))
        w(f"| `{f['signature']}` | `{f['selector']}` | `{f['role']}` | "
          f"{format_delay(f['delay'])} | {guardian_cancel(f['delay'])} | {note} |")
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
