"""Command line: `python -m tools.conventions <command>`. Exit codes: 0 ok, 1 refused or invalid,
2 bad input. Every command reads JSON files and prints JSON; none makes a network call. Only
signature checks run `cast`: `control-proof verify` for a signer without code or with an EIP-7702 delegation, and
`custody check` for an attestation given without `signatureValid`."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Sequence

from tools.content.errors import ToolError

from . import card as card_module
from . import control_proof, custody, eip712, floor, grade, jcs
from .schema import validate

EXIT_NOT_OK = 1
EXIT_ERROR = 2


def _load(path: str) -> dict:
    """A JSON object from `path`; anything else is bad input (exit 2), never a traceback."""
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except OSError as exc:
        raise ToolError(f"cannot read {path}: {exc.strerror or exc}") from None
    except ValueError as exc:
        raise ToolError(f"{path} is not JSON: {exc}") from None
    except RecursionError:
        raise ToolError(f"{path} nests too deeply") from None
    if not isinstance(value, dict):
        raise ToolError(f"{path} must hold a JSON object, not {type(value).__name__}")
    return value


def _print(value: Any) -> None:
    print(json.dumps(value, indent=2, ensure_ascii=False))


def _blob(spec: Any, base: Path, what: str) -> bytes:
    """`{"file": path}` (relative to the input file) or `{"hex": "0x…"}`."""
    if isinstance(spec, dict) and "file" in spec:
        try:
            return (base / spec["file"]).read_bytes()
        except OSError as exc:
            raise ToolError(f"cannot read {what} {spec['file']}: {exc.strerror or exc}") from None
    if isinstance(spec, dict) and isinstance(spec.get("hex"), str) and spec["hex"].startswith("0x"):
        return bytes.fromhex(spec["hex"][2:])
    raise ToolError(f"{what} must be {{\"file\": path}} or {{\"hex\": \"0x…\"}}")


def cmd_validate(args: argparse.Namespace) -> int:
    data = Path(args.file).read_bytes()
    doc = jcs.parse(data)
    errors = validate(doc, args.schema)
    if args.canonical and jcs.canonicalize(doc) != data:
        errors.append("/: not in RFC 8785 canonical form")
    _print({"valid": not errors, "errors": errors})
    return 0 if not errors else EXIT_NOT_OK


def cmd_canonical(args: argparse.Namespace) -> int:
    sys.stdout.buffer.write(jcs.canonicalize(jcs.parse(Path(args.file).read_bytes())))
    return 0


def cmd_floor(args: argparse.Namespace) -> int:
    spec = _load(args.input)
    base = Path(args.input).resolve().parent
    contents = {k.lower(): _blob(v, base, f"contents[{k}]") for k, v in spec.get("contents", {}).items()}
    observed = dict(spec.get("observed", {}))
    fetched = {}
    for uri, value in observed.get("fetched", {}).items():
        if value is None:
            fetched[uri] = None
        elif isinstance(value, dict) and "sha256" in value:
            fetched[uri] = value["sha256"]
        else:
            fetched[uri] = _blob(value, base, f"fetched[{uri}]")
    observed["fetched"] = fetched
    result = floor.check_floor(spec["package"], spec["policy"], contents, observed)
    _print(result)
    return 0 if result["ok"] else EXIT_NOT_OK


def cmd_card(args: argparse.Namespace) -> int:
    result = card_module.build_card(_load(args.input))
    _print({"card": result.card, "notes": result.notes} if args.notes else result.card)
    return 0


def cmd_grade(args: argparse.Namespace) -> int:
    _print(grade.grade(_load(args.card)))
    return 0


def cmd_control_digest(args: argparse.Namespace) -> int:
    doc = _load(args.file)
    errors = validate(doc, "control-proof")
    if errors:
        raise ToolError("not a valid control-proof.v1 document: " + errors[0])
    print("0x" + eip712.control_digest(doc["message"]).hex())
    return 0


def cmd_control_verify(args: argparse.Namespace) -> int:
    doc = _load(args.file)
    ctx = _load(args.context)
    store = control_proof.MemoryNonceStore()
    for issued in ctx.get("challenges", []):  # the challenges the venue issued (DCL-24 step 1)
        store.add(issued["message"] if "message" in issued else issued)
    verdict = control_proof.verify_response(
        doc, venue=ctx["venue"], chain_id=ctx["chainId"], now=ctx["now"], store=store,
        official_tokens=ctx["officialTokens"], block=ctx["block"], head_block=ctx["headBlock"],
        signer_code=bytes.fromhex(ctx.get("signerCode", "0x")[2:]), ownership=ctx["ownership"],
        consolidation=ctx.get("consolidation"),
        freshness_blocks=ctx.get("freshnessBlocks", control_proof.DEFAULT_FRESHNESS_BLOCKS),
        accept_pending_delivery=ctx.get("acceptPendingDelivery", False),
        accept_young_consolidation=ctx.get("acceptYoungConsolidation", False),
    )  # fmt: skip
    _print(verdict.__dict__)
    return 0 if verdict.accepted else EXIT_NOT_OK


def cmd_custody_digest(args: argparse.Namespace) -> int:
    doc = _load(args.file)
    errors = validate(doc, "custody-attestation")
    if errors:
        raise ToolError("not a valid custody-attestation.v1 document: " + errors[0])
    print("0x" + custody.attestation_digest(doc).hex())
    return 0


def cmd_custody_check(args: argparse.Namespace) -> int:
    spec = _load(args.input)
    base = Path(args.input).resolve().parent
    declarations = spec.get("declarations")
    if isinstance(declarations, str):
        declarations = _load(str(base / declarations))
    if declarations is not None and validate(declarations, "declarations"):
        raise ToolError("the declarations document is not valid declarations.v1")
    attestations = []
    for att in spec.get("attestations", []):
        att = dict(att)
        if isinstance(att.get("document"), str):
            att["document"] = _load(str(base / att["document"]))
        if "signatureValid" not in att and not validate(att["document"], "custody-attestation"):
            code = bytes.fromhex(att.get("custodianCode", "0x")[2:])
            att["signatureValid"] = custody.attestation_signature(att["document"], code=code).valid
        attestations.append(att)
    _print(custody.evaluate_custody(declarations, attestations, spec["now"], work=spec["work"]))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="python -m tools.conventions", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("validate", help="validate a document against a convention schema")
    p.add_argument("schema", help="schema short name, e.g. declarations or promise-card")
    p.add_argument("file")
    p.add_argument("--canonical", action="store_true", help="also require RFC 8785 canonical bytes")
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser("canonical", help="print a JSON document's RFC 8785 canonical bytes")
    p.add_argument("file")
    p.set_defaults(func=cmd_canonical)

    p = sub.add_parser("floor", help="the conservation-floor check before attestation (DCL-5)")
    p.add_argument("input", help="JSON: package, policy, contents, observed")
    p.set_defaults(func=cmd_floor)

    p = sub.add_parser("card", help="build a promise card from reads at one block (DCL-26 to DCL-29)")
    p.add_argument("input", help="JSON: reads and documents (see tools/conventions/README.md)")
    p.add_argument("--notes", action="store_true", help="also print why states were chosen")
    p.set_defaults(func=cmd_card)

    p = sub.add_parser("grade", help="grade a promise card under rubric 1 (DCL-30)")
    p.add_argument("card")
    p.set_defaults(func=cmd_grade)

    p = sub.add_parser("control-proof", help="control-proof digest and verifier (DCL-23 to DCL-25)")
    cp = p.add_subparsers(dest="action", required=True)
    q = cp.add_parser("digest", help="the EIP-712 digest of a control-proof.v1 document")
    q.add_argument("file")
    q.set_defaults(func=cmd_control_digest)
    q = cp.add_parser("verify", help="run DCL-24 steps 2 to 6 against a context file")
    q.add_argument("file")
    q.add_argument("--context", required=True, help="JSON: venue, chainId, now, reads at B")
    q.set_defaults(func=cmd_control_verify)

    p = sub.add_parser("custody", help="custody attestations (DCL-19 to DCL-22)")
    cp = p.add_subparsers(dest="action", required=True)
    q = cp.add_parser("digest", help="the EIP-712 digest of a custody-attestation.v1 document")
    q.add_argument("file")
    q.set_defaults(func=cmd_custody_digest)
    q = cp.add_parser("check", help="which attestations count, recognized and stale")
    q.add_argument("input", help="JSON: work {chainId, contract, tokenId}, declarations, attestations, now")
    q.set_defaults(func=cmd_custody_check)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (ToolError, KeyError, ValueError, TypeError) as exc:
        detail = f"missing member {exc}" if isinstance(exc, KeyError) else str(exc)
        print(f"error: {detail}", file=sys.stderr)
        return EXIT_ERROR
    except OSError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_ERROR
