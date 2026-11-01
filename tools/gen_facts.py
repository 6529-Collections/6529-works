#!/usr/bin/env python3
"""Generate docs/facts.json, the machine-readable facts the 6529.io site syncs, from the repo.

Nothing in the file is written by hand. Every value is read from the source that owns it:

  - deployed addresses: the newest deployment record of each network under deployments/, with
    the instance's date and source commit from that network's deployments README;
  - governed parameters and their launch defaults: the deploy script's defaults
    (`script/Deploy.s.sol`) and the contracts' constants and bounds under src/; the edition
    auction's launch configuration from `DeployV1.editionAuctionDefaults`, checked against ADR
    0005 §4 and the step ladder's defaults in code;
  - gas: ADR 0004's table (docs/adr/0004-gas-budgets-under-glamsterdam.md), with the labels the
    table's preface gives its columns;
  - collection names and symbols: the token contracts' sources;
  - status, release and links: the README's status table, the newest release notes under
    docs/releases/ and the CHANGELOG.

The site fetches the file at a pinned commit, so a fact that changes here reaches it on the
next sync. A source that no longer has the shape this script reads fails generation, rather
than leaving a stale or plausible value.

Usage, from anywhere:
  python tools/gen_facts.py            rewrite docs/facts.json
  python tools/gen_facts.py --check    fail if docs/facts.json is not current (CI, Docs job)
  python tools/gen_facts.py --stdout   print the facts

Standard library only.
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

OUTPUT = "docs/facts.json"
SCHEMA = "6529-works/facts/1"

README = "README.md"
CHANGELOG = "CHANGELOG.md"
RELEASES = "docs/releases"
DEPLOYMENTS = "deployments"
DEPLOY_SCRIPT = "script/Deploy.s.sol"
ADR_0004 = "docs/adr/0004-gas-budgets-under-glamsterdam.md"
GAS_TABLE_HEADING = "### The table"
ADR_0005 = "docs/adr/0005-stream-editions-auction.md"
EDITION_PARAMETERS_HEADING = "### 4. Governed parameters and delay classes"
STEP_LADDER = "src/interfaces/types/StepLadder.sol"
EDITION_AUCTION = "src/sales/UniformEditionAuction.sol"
EDITIONS = "src/editions/Editions.sol"
DEPLOY_LIBRARY = "script/DeployV1.sol"

# ADR 0005 §4's rows for the edition auction's `AuctionConfig`, by name (less any parenthetical).
EDITION_ROWS = {
    "marginShare": "Breadth margin",
    "stepsPerDecade": "Steps per decade",
    "basePrice": "Base price",
    "stepCount": "Steps",
    "closeOffset": "Close offset after the 1/1",
    "softWindow": "Soft-close window",
    "maxExtension": "Extension backstop",
}

# Chain IDs the facts name, and what the site calls them. A deployment directory of another
# chain (31337 is anvil) is not exported.
NETWORKS = {1: "mainnet", 11155111: "sepolia"}

# Pages the site links to, by key. Each must exist.
DOC_PATHS = {
    "specification": "docs/spec/README.md",
    "editionsAndSales": "docs/spec/editions-and-sales.md",
    "streamAndAuctions": "docs/spec/stream-and-auctions.md",
    "editionAuctionAdr": ADR_0005,
    "integrators": "docs/integrators/README.md",
    "addresses": "docs/integrators/addresses.md",
    "buyingBiddingSettling": "docs/integrators/buying-bidding-settling.md",
    "eventsAndIndexing": "docs/integrators/events-and-indexing.md",
    "auditPack": "docs/audit/README.md",
    "knownLimitations": "docs/audit/known-limitations.md",
    "roles": "docs/audit/roles.md",
    "glossary": "docs/glossary.md",
    "architecture": "docs/architecture.md",
    "adrs": "docs/adr/README.md",
    "gasTable": ADR_0004,
    "internalReview": "docs/security/internal-review-2026-10.md",
    "security": "SECURITY.md",
    "changelog": CHANGELOG,
}

SECONDS = {"seconds": 1, "minutes": 60, "hours": 3600, "days": 86400, "weeks": 604800}
WEI = {"wei": 1, "gwei": 10**9, "ether": 10**18}


class FactError(Exception):
    """A source no longer has the shape this generator reads."""


# ------------------------------------------------------------------ reading sources


def read(root: Path, rel: str) -> str:
    path = root / rel
    if not path.is_file():
        raise FactError(f"{rel}: missing")
    return path.read_text(encoding="utf-8").replace("\r\n", "\n")


def strip_comments(source: str) -> str:
    """Solidity source without comments (strings keep their contents)."""
    out, i, n = [], 0, len(source)
    while i < n:
        c = source[i]
        if c == '"' or c == "'":
            j = i + 1
            while j < n and source[j] != c:
                j += 2 if source[j] == "\\" else 1
            out.append(source[i : j + 1])
            i = j + 1
        elif source.startswith("//", i):
            j = source.find("\n", i)
            i = n if j < 0 else j
        elif source.startswith("/*", i):
            j = source.find("*/", i + 2)
            if j < 0:
                raise FactError("unterminated block comment")
            i = j + 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


NUMBER = re.compile(r"^(\d[\d_]*)(?:\.(\d[\d_]*))?(?:\s+(\w+))?$")


def literal(expr: str) -> int:
    """The value of a Solidity number literal with an optional time or ether unit:
    `5_000`, `24 hours`, `0.001 ether`, `1e15`."""
    expr = expr.strip()
    if re.fullmatch(r"\d+e\d+", expr):
        base, exp = expr.split("e")
        return int(base) * 10 ** int(exp)
    m = NUMBER.match(expr)
    if not m:
        raise FactError(f"not a number literal: {expr!r}")
    whole, frac, unit = m.group(1).replace("_", ""), (m.group(2) or "").replace("_", ""), m.group(3)
    scale = 1
    if unit is not None:
        if unit in SECONDS:
            scale = SECONDS[unit]
        elif unit in WEI:
            scale = WEI[unit]
        else:
            raise FactError(f"unknown unit {unit!r} in {expr!r}")
    value = int(whole) * scale + (int(frac) * scale // 10 ** len(frac) if frac else 0)
    if frac and int(frac) * scale % 10 ** len(frac):
        raise FactError(f"{expr!r} is not a whole number of base units")
    return value


class Constants:
    """Integer and string constants of Solidity files, resolving `Library.NAME` references."""

    def __init__(self, root: Path):
        self.root = root
        self._files: dict[str, dict[str, str]] = {}

    def _declarations(self, rel: str) -> dict[str, str]:
        if rel not in self._files:
            source = strip_comments(read(self.root, rel))
            found = {}
            for m in re.finditer(r"\bconstant\s+([A-Za-z_]\w*)\s*=\s*([^;]+);", source):
                found[m.group(1)] = " ".join(m.group(2).split())
            self._files[rel] = found
        return self._files[rel]

    def expression(self, rel: str, name: str) -> str:
        declared = self._declarations(rel)
        if name not in declared:
            raise FactError(f"{rel}: no constant {name}")
        return declared[name]

    def integer(self, rel: str, name: str) -> int:
        expr = self.expression(rel, name)
        ref = re.fullmatch(r"([A-Z]\w*)\.([A-Z_][A-Z0-9_]*)", expr)
        if ref:
            return self.integer(self._library(ref.group(1)), ref.group(2))
        if re.fullmatch(r"[A-Z_][A-Z0-9_]*", expr):
            return self.integer(rel, expr)
        return literal(expr)

    def string(self, rel: str, name: str) -> str:
        expr = self.expression(rel, name)
        m = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', expr)
        if not m:
            raise FactError(f"{rel}: {name} is not a string literal")
        return m.group(1)

    def _library(self, name: str) -> str:
        hits = sorted(
            p.relative_to(self.root).as_posix()
            for p in (self.root / "src").rglob(f"{name}.sol")
        )
        if len(hits) != 1:
            raise FactError(f"src/: expected one {name}.sol, found {len(hits)}")
        return hits[0]


def deploy_default(root: Path, env: str) -> int:
    """The launch default the deploy script uses when the environment does not set `env`."""
    source = strip_comments(read(root, DEPLOY_SCRIPT))
    m = re.search(r'_envUint\(\s*"' + re.escape(env) + r'"\s*,\s*([^)]+?)\s*\)', source)
    if not m:
        raise FactError(f"{DEPLOY_SCRIPT}: no default for {env}")
    return literal(m.group(1))


def ratio(value: int, denominator: int) -> dict:
    return {"value": value, "denominator": denominator}


# ------------------------------------------------------------------ status, release, links


def repository_url(root: Path) -> str:
    m = re.search(r"git clone [^\n]*?(https://github\.com/[\w.-]+/[\w.-]+?)(?:\.git)?\s", read(root, README))
    if not m:
        raise FactError(f"{README}: no `git clone` URL")
    return m.group(1)


def status(root: Path) -> dict:
    text = read(root, README)
    section = _section(text, "## Status", README)
    rows = dict(re.findall(r"^\| (\w[\w ]*?) \| (.+?) \|$", section, re.MULTILINE))
    for key in ("Maturity", "Mainnet"):
        if key not in rows:
            raise FactError(f"{README}: the status table has no {key} row")
    maturity = re.match(r"\*\*(.+?)\.?\*\*", rows["Maturity"])
    if not maturity:
        raise FactError(f"{README}: the Maturity row does not start in bold")
    mainnet = rows["Mainnet"].split(".")[0].strip()
    return {"maturity": maturity.group(1), "mainnet": mainnet}


def release(root: Path, repo: str) -> dict:
    notes = sorted((root / RELEASES).glob("v*.md"), key=lambda p: _version_key(p.stem))
    if not notes:
        raise FactError(f"{RELEASES}: no release notes")
    tag = notes[-1].stem
    m = re.search(r"^## " + re.escape(tag[1:]) + r" \((\d{4}-\d{2}-\d{2})\)$", read(root, CHANGELOG), re.MULTILINE)
    if not m:
        raise FactError(f"{CHANGELOG}: no `## {tag[1:]} (date)` section for {notes[-1].name}")
    return {
        "tag": tag,
        "date": m.group(1),
        "notes": notes[-1].relative_to(root).as_posix(),
        "url": f"{repo}/releases/tag/{tag}",
    }


def _version_key(stem: str) -> tuple:
    m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)(?:-([a-z]+)\.(\d+))?", stem)
    if not m:
        raise FactError(f"{RELEASES}/{stem}.md: not a version")
    major, minor, patch, pre, num = m.groups()
    # A final release sorts after its prereleases.
    return (int(major), int(minor), int(patch), pre is None, pre or "", int(num or 0))


def links(root: Path, repo: str, rel: dict) -> dict:
    for path in DOC_PATHS.values():
        if not (root / path).is_file():
            raise FactError(f"{path}: missing (a DOC_PATHS entry)")
    return {
        "repository": repo,
        "release": rel["url"],
        "docs": {key: f"{repo}/blob/main/{path}" for key, path in DOC_PATHS.items()},
    }


def _section(text: str, heading: str, where: str) -> str:
    start = text.find("\n" + heading)
    if start < 0:
        raise FactError(f"{where}: no `{heading}` section")
    level = heading.split(" ")[0]
    end = re.search(r"\n#{1," + str(len(level)) + r"} ", text[start + 1 :])
    return text[start + 1 : start + 1 + end.start()] if end else text[start + 1 :]


# ------------------------------------------------------------------ deployments


def deployments(root: Path) -> dict:
    """The newest record of each exported network: its instance, date, commit and addresses."""
    out = {}
    for chain_id, name in NETWORKS.items():
        directory = root / DEPLOYMENTS / str(chain_id)
        records = sorted(directory.glob("*.json")) if directory.is_dir() else []
        if not records:
            out[name] = {"chainId": chain_id, "deployed": False}
            continue
        newest = max(records, key=lambda p: _record(p)["timestamp"])
        data = _record(newest)
        if data.get("chainId") != chain_id:
            raise FactError(f"{newest.relative_to(root).as_posix()}: chainId is not {chain_id}")
        instance = _instance(data, newest, root)
        commit, date = _instance_notes(root, chain_id, instance)
        out[name] = {
            "chainId": chain_id,
            "deployed": True,
            "testnet": chain_id != 1,
            "instance": instance,
            "sourceCommit": commit,
            "deployedOn": date,
            "deployedAtTimestamp": data["timestamp"],
            "startBlock": data["startBlock"],
            "confirmed": data["confirmed"],
            "record": newest.relative_to(root).as_posix(),
            "contracts": {k: v["address"] for k, v in sorted(data["contracts"].items())},
        }
    return out


def _record(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    for key in ("chainId", "timestamp", "startBlock", "confirmed", "contracts", "genesisConfig"):
        if key not in data:
            raise FactError(f"{path.name}: no {key}")
    return data


def _instance(data: dict, path: Path, root: Path) -> str:
    m = re.fullmatch(r"config/([\w-]+)/genesis\.json", data["genesisConfig"])
    if not m:
        raise FactError(f"{path.relative_to(root).as_posix()}: genesisConfig names no instance")
    return m.group(1)


def _instance_notes(root: Path, chain_id: int, instance: str) -> tuple[str, str]:
    rel = f"{DEPLOYMENTS}/{chain_id}/README.md"
    text = read(root, rel)
    m = re.search(r"^## " + re.escape(instance) + r": (\d{1,2} \w+ \d{4})\b.*$", text, re.MULTILINE)
    if not m:
        raise FactError(f"{rel}: no `## {instance}: <date>` section")
    date = datetime.strptime(m.group(1), "%d %B %Y").replace(tzinfo=timezone.utc).date().isoformat()
    section = _section(text, m.group(0), rel)
    commit = re.search(r"^\| Source \| `main` at `([0-9a-f]{7,40})`", section, re.MULTILINE)
    if not commit:
        raise FactError(f"{rel}: the {instance} section has no Source row")
    return commit.group(1), date


# ------------------------------------------------------------------ parameters


def parameters(root: Path) -> dict:
    c = Constants(root)
    denominator = c.integer("src/economics/Splits.sol", "DENOMINATOR")
    auction = "src/sales/EnglishAuction.sol"
    resolver = "src/economics/EconomicsResolver.sol"
    return {
        "denominator": denominator,
        "oneOfOneAuction": {
            "source": [DEPLOY_SCRIPT, auction],
            "governedBy": "PARAMETER_SETTER",
            "durationSeconds": {
                "default": deploy_default(root, "AUCTION_DURATION"),
                "min": c.integer(auction, "MIN_DURATION"),
                "max": c.integer(auction, "MAX_DURATION"),
            },
            "antiSnipeWindowSeconds": {
                "default": deploy_default(root, "AUCTION_EXTENSION_WINDOW"),
                "min": c.integer(auction, "MIN_EXTENSION_WINDOW"),
                "max": c.integer(auction, "MAX_EXTENSION_WINDOW"),
            },
            "minimumIncrementShare": {
                "default": deploy_default(root, "AUCTION_INCREMENT_SHARE"),
                "min": c.integer(auction, "MIN_INCREMENT_SHARE"),
                "max": denominator,
                "denominator": denominator,
            },
            "minimumIncrementFloorWei": {
                "default": str(deploy_default(root, "ETH_INCREMENT_FLOOR")),
                "governedBy": "FUNDS_SETTER",
            },
            "maxDisputePauseSeconds": c.integer(auction, "_MAX_PAUSE"),
        },
        "editionAuction": edition_auction(root, c, denominator),
        "economics": {
            "source": [resolver],
            "governedBy": "FUNDS_SETTER",
            "royaltyRate": ratio(c.integer(resolver, "DEFAULT_ROYALTY_RATE"), denominator),
            "networkFeeShare": ratio(c.integer(resolver, "DEFAULT_FEE_SHARE"), denominator),
            "federatedNetworkFeeShare": ratio(c.integer(resolver, "FEDERATED_FEE_SHARE"), denominator),
        },
        "storage": {
            "source": ["src/content/ContentStore.sol", "src/content/Renderer.sol"],
            "maxChunks": c.integer("src/content/ContentStore.sol", "MAX_CHUNKS"),
            "chunkSizeBytes": c.integer("src/content/ContentStore.sol", "CHUNK_SIZE"),
            "inlineThresholdBytes": c.integer("src/content/Renderer.sol", "DEFAULT_INLINE_THRESHOLD"),
        },
        "governanceDelaysSeconds": {
            "source": ["src/governance/Roles.sol"],
            "immediate": c.integer("src/governance/Roles.sol", "IMMEDIATE"),
            "standard": c.integer("src/governance/Roles.sol", "STANDARD"),
            "funds": c.integer("src/governance/Roles.sol", "FUNDS"),
            "successor": c.integer("src/governance/Roles.sol", "SUCCESSOR"),
        },
    }


def edition_auction(root: Path, c: Constants, denominator: int) -> dict:
    """The edition auction's governed configuration: the launch values genesis deploys
    (`DeployV1.editionAuctionDefaults`), which ADR 0005 §4 and the step ladder's code defaults
    must equal, and the bounds fixed in code."""
    launch = _deploy_edition_defaults(root)
    decided = _edition_launch(root)
    for key, value in launch.items():
        if decided[key] != value:
            raise FactError(f"{DEPLOY_LIBRARY} and {ADR_0005} §4 disagree on {key}")
    for key, name in (
        ("basePrice", "DEFAULT_BASE_PRICE"),
        ("stepsPerDecade", "DEFAULT_STEPS_PER_DECADE"),
        ("stepCount", "DEFAULT_STEP_COUNT"),
    ):
        if launch[key] != c.integer(STEP_LADDER, name):
            raise FactError(f"{ADR_0005} §4 and {STEP_LADDER} {name} disagree on {key}")
    ladder = strip_comments(read(root, STEP_LADDER))
    m = re.search(r"function isStepsPerDecade\b[^{]*\{([^}]*)\}", ladder)
    if not m:
        raise FactError(f"{STEP_LADDER}: no isStepsPerDecade")
    allowed = sorted(int(v) for v in re.findall(r"stepsPerDecade\s*==\s*(\d+)", m.group(1)))
    if launch["stepsPerDecade"] not in allowed:
        raise FactError(f"{ADR_0005} §4: steps per decade not allowed by {STEP_LADDER}")
    low, high = c.integer(STEP_LADDER, "MIN_BASE_PRICE"), c.integer(STEP_LADDER, "MAX_BASE_PRICE")
    m = re.search(r"function isBasePrice\b[^{]*\{(.*?)\n    \}", ladder, re.S)
    if not m:
        raise FactError(f"{STEP_LADDER}: no isBasePrice")
    if "*= 10" not in m.group(1):
        raise FactError(f"{STEP_LADDER}: isBasePrice is no longer the power-of-ten rule")
    bases = []
    base = low
    while base <= high:
        bases.append(str(base))
        base *= 10
    if str(launch["basePrice"]) not in bases:
        raise FactError(f"the launch base price is not one {STEP_LADDER} allows")
    return {
        "source": [DEPLOY_LIBRARY, DEPLOY_SCRIPT, ADR_0005, STEP_LADDER, EDITION_AUCTION],
        "governedBy": "PARAMETER_SETTER",
        "currency": "ETH",
        "basePriceWei": {"default": str(launch["basePrice"]), "allowed": bases},
        "stepsPerDecade": {"default": launch["stepsPerDecade"], "allowed": allowed},
        "stepCount": {
            "default": launch["stepCount"],
            "min": c.integer(STEP_LADDER, "MIN_STEP_COUNT"),
            "max": c.integer(STEP_LADDER, "MAX_STEP_COUNT"),
            "minTopPriceWei": str(c.integer(STEP_LADDER, "MIN_TOP_PRICE")),
        },
        "breadthMargin": {
            "default": launch["marginShare"],
            "min": 0,
            "max": c.integer(EDITION_AUCTION, "_MAX_MARGIN_SHARE"),
            "denominator": denominator,
        },
        "closeOffsetSeconds": {
            "default": launch["closeOffset"],
            "min": 0,
            "max": c.integer(EDITION_AUCTION, "_MAX_CLOSE_OFFSET"),
        },
        "softCloseWindowSeconds": {
            "default": launch["softWindow"],
            "min": c.integer(EDITION_AUCTION, "_MIN_SOFT_WINDOW"),
            "max": c.integer(EDITION_AUCTION, "_MAX_SOFT_WINDOW"),
        },
        "extensionBackstopSeconds": {
            "default": launch["maxExtension"],
            "min": c.integer(EDITION_AUCTION, "_MIN_MAX_EXTENSION"),
            "max": c.integer(EDITION_AUCTION, "_MAX_MAX_EXTENSION"),
        },
        "payoutGas": c.integer(EDITION_AUCTION, "PAYOUT_GAS"),
        "settlementPerCall": {
            "bookWordsScanned": c.integer(EDITION_AUCTION, "_SCAN_WORDS"),
            "departuresSweptByTheClearingCall": c.integer(EDITION_AUCTION, "_SWEEP_FIRST"),
            "departuresSweptLater": c.integer(EDITION_AUCTION, "_SWEEP_CHUNK"),
        },
    }


def _deploy_edition_defaults(root: Path) -> dict:
    """`DeployV1.editionAuctionDefaults()`: the `AuctionConfig` genesis deploys."""
    source = strip_comments(read(root, DEPLOY_LIBRARY))
    m = re.search(r"function editionAuctionDefaults\b.*?AuctionConfig\(\{(.*?)\}\)", source, re.S)
    if not m:
        raise FactError(f"{DEPLOY_LIBRARY}: no editionAuctionDefaults")
    fields = dict(re.findall(r"(\w+)\s*:\s*([^,]+?)\s*(?:,|$)", m.group(1).strip()))
    if set(fields) != set(EDITION_ROWS):
        raise FactError(f"{DEPLOY_LIBRARY}: editionAuctionDefaults sets {sorted(fields)}")
    return {key: literal(value) for key, value in fields.items()}


def _edition_launch(root: Path) -> dict:
    """ADR 0005 §4's Default column, in base units (wei, seconds, parts of 100,000)."""
    table = _section(read(root, ADR_0005), EDITION_PARAMETERS_HEADING, ADR_0005)
    rows = {}
    for line in table.splitlines():
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) >= 2 and not set(cells[0]) <= {"-", " "}:
            rows[cells[0]] = cells[1]
    found = {}
    for key, label in EDITION_ROWS.items():
        hits = [cell for name, cell in rows.items() if re.sub(r"\s*\([^)]*\)$", "", name) == label]
        if len(hits) != 1:
            raise FactError(f"{ADR_0005} §4: expected one row {label!r}, found {len(hits)}")
        found[key] = _launch_value(key, hits[0])
    return found


def _launch_value(key: str, cell: str) -> int:
    if key == "marginShare":
        m = re.search(r"\(([\d,]+) of ([\d,]+)\)", cell)
        if not m:
            raise FactError(f"{ADR_0005} §4: margin {cell!r} has no (n of d)")
        return _number(m.group(1))
    if key in ("stepsPerDecade", "stepCount"):
        return _number(cell)
    if key == "basePrice":
        m = re.fullmatch(r"([\d.]+) ETH", cell)
        if not m:
            raise FactError(f"{ADR_0005} §4: base price {cell!r} is not in ETH")
        return literal(m.group(1) + " ether")
    return literal(cell)


# ------------------------------------------------------------------ collections


def collections(root: Path) -> list[dict]:
    stream = strip_comments(read(root, "src/stream/Stream.sol"))
    m = re.search(r'\bERC721\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\)', stream)
    if not m:
        raise FactError("src/stream/Stream.sol: no ERC721(name, symbol)")
    c = Constants(root)
    return [
        {"contract": "Stream", "standard": "ERC-721", "name": m.group(1), "symbol": m.group(2)},
        {
            "contract": "Editions",
            "standard": "ERC-1155",
            "name": c.string(EDITIONS, "name"),
            "symbol": c.string(EDITIONS, "symbol"),
        },
    ]


# ------------------------------------------------------------------ gas (ADR 0004)


def gas(root: Path) -> dict:
    text = read(root, ADR_0004)
    section = _section(text, GAS_TABLE_HEADING, ADR_0004)
    preface, _, rest = section.partition("\n| Operation |")
    if not rest:
        raise FactError(f"{ADR_0004}: the table has no Operation header")
    header = "| Operation |" + rest.split("\n", 1)[0]
    columns = [cell.strip() for cell in header.strip("|").split("|")]
    expected = ["Operation", "Prague gas", "Prague ceiling", "New slots", "New accounts", "Sepolia gas"]
    if columns != expected:
        raise FactError(f"{ADR_0004}: table columns are {columns}, expected {expected}")
    rehearsal = re.search(r"Sepolia\s+gas is the receipt on the (r\d+) rehearsal\s+\(`([0-9a-f]+)`", preface)
    if not rehearsal:
        raise FactError(f"{ADR_0004}: the preface names no Sepolia rehearsal")
    _, measured = _instance_notes(root, 11155111, f"sepolia-{rehearsal.group(1)}")
    rows = []
    for line in rest.split("\n")[2:]:
        if not line.startswith("|"):
            break
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) != len(expected):
            raise FactError(f"{ADR_0004}: row {line!r} has {len(cells)} cells")
        rows.append(_gas_row(cells, rehearsal.group(1)))
    if not rows:
        raise FactError(f"{ADR_0004}: the table has no rows")
    return {
        "source": f"{ADR_0004}#the-table",
        "labels": {
            "pragueGas": "Prague gas of the whole transaction (intrinsic, calldata and execution), "
            "measured by test/integration/GasReport.t.sol",
            "pragueCeiling": "the CI ceiling: a budget, or a regression ceiling",
            "newSlots": "new storage slots the operation writes; newSlotsBudgeted marks the "
            "counts the start budget gates",
            "sepoliaGas": f"the Sepolia receipt (Glamsterdam pricing) on rehearsal "
            f"{rehearsal.group(1)}, source {rehearsal.group(2)}, unless the row names another "
            "rehearsal or a simulation",
        },
        "sepoliaLabel": f"Sepolia {rehearsal.group(1)}, Glamsterdam, measured {_long_date(measured)}",
        "rows": rows,
    }


def _long_date(iso: str) -> str:
    day = datetime.strptime(iso, "%Y-%m-%d")
    return f"{day.day} {day.strftime('%B %Y')}"


def _plain(cell: str) -> str:
    return cell.replace("`", "").replace("**", "")


def _number(text: str) -> int:
    return int(text.replace(",", ""))


def _gas_row(cells: list[str], rehearsal: str) -> dict:
    operation, prague, ceiling, slots, accounts, sepolia = cells
    row: dict = {"operation": _plain(operation)}
    m = re.fullmatch(r"(at most )?([\d,]+)( of execution)?", prague)
    if not m:
        raise FactError(f"ADR 0004 gas row {operation!r}: Prague gas {prague!r}")
    row["pragueGas"] = _number(m.group(2))
    if m.group(1):
        row["pragueGasIsMaximum"] = True
    if m.group(3):
        row["pragueGasIsExecution"] = True
    m = re.fullmatch(r"([\d,]+)(?: \((regression)\)| (of execution))?", ceiling)
    if m:
        kind = "regression" if m.group(2) else "execution" if m.group(3) else "budget"
        row["pragueCeiling"] = {"gas": _number(m.group(1)), "kind": kind}
    elif ceiling == "—":
        row["pragueCeiling"] = None
    else:
        raise FactError(f"ADR 0004 gas row {operation!r}: ceiling {ceiling!r}")
    m = re.fullmatch(r"(\*\*)?(\d+)(\*\*)?", slots)
    ranged = re.fullmatch(r"(\d+) to (\d+)(?: \((.+)\))?", slots)
    if m and bool(m.group(1)) == bool(m.group(3)):
        row["newSlots"] = int(m.group(2))
        if m.group(1):
            row["newSlotsBudgeted"] = True
    elif ranged:
        row["newSlots"] = int(ranged.group(2))
        row["newSlotsRange"] = [int(ranged.group(1)), int(ranged.group(2))]
        if ranged.group(3):
            row["newSlotsNote"] = _plain(ranged.group(3))
    else:
        raise FactError(f"ADR 0004 gas row {operation!r}: slots {slots!r}")
    if not accounts.isdigit():
        raise FactError(f"ADR 0004 gas row {operation!r}: accounts {accounts!r}")
    row["newAccounts"] = int(accounts)
    m = re.fullmatch(r"([\d,]+)(?: \((r\d+|sim\.)\))?", sepolia)
    if m:
        source = m.group(2) or rehearsal
        row["sepoliaGas"] = {
            "gas": _number(m.group(1)),
            "source": f"{rehearsal} simulation" if source == "sim." else source,
        }
    elif sepolia == "—":
        row["sepoliaGas"] = None
    else:
        row["sepoliaGas"] = {"note": _plain(sepolia)}
    return row


# ------------------------------------------------------------------ the file


def generate(root: Path) -> dict:
    repo = repository_url(root)
    rel = release(root, repo)
    return {
        "schema": SCHEMA,
        "generator": "tools/gen_facts.py",
        "note": "Generated from the repository's sources; do not edit. Pre-audit: no figure "
        "here is a mainnet deployment unless networks.mainnet.deployed is true.",
        "status": {**status(root), "release": rel["tag"], "releaseDate": rel["date"]},
        "networks": deployments(root),
        "collections": collections(root),
        "parameters": parameters(root),
        "gas": gas(root),
        "links": links(root, repo, rel),
    }


def render(facts: dict) -> str:
    return json.dumps(facts, indent=2, ensure_ascii=False) + "\n"


def repository_root() -> Path:
    return Path(__file__).resolve().parent.parent


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, help="repository root (default: parent of tools/)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help=f"fail if {OUTPUT} is not current")
    mode.add_argument("--stdout", action="store_true", help="print the facts instead of writing them")
    args = parser.parse_args(argv)

    root = (args.root or repository_root()).resolve()
    try:
        text = render(generate(root))
    except (FactError, KeyError, ValueError) as error:
        print(f"FAIL facts: {error}")
        return 1
    target = root / OUTPUT
    if args.stdout:
        sys.stdout.write(text)
        return 0
    if args.check:
        current = target.read_text(encoding="utf-8").replace("\r\n", "\n") if target.exists() else ""
        if current == text:
            print(f"facts: {OUTPUT} is current")
            return 0
        diff = difflib.unified_diff(
            current.splitlines(), text.splitlines(), f"{OUTPUT} (committed)", f"{OUTPUT} (generated)",
            lineterm="", n=1,
        )
        for line in list(diff)[:60]:
            print(line)
        print(f"FAIL {OUTPUT} is not current: run `python tools/gen_facts.py` and commit it")
        return 1
    target.parent.mkdir(parents=True, exist_ok=True)
    with open(target, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    print(f"facts: wrote {OUTPUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
