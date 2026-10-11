"""Command-line interface: `python -m tools.content <plan|calls|verify|rebuild|golden>`."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Sequence

from . import calls as calls_module
from . import gas
from .address import parse_address
from .encoding import Encoding
from .errors import ToolError
from .plan import (
    ATTEST_CHUNKS_PER_CALL,
    CHUNK_SIZE,
    MAX_CHUNKS,
    hex0x,
    load_manifest,
    manifest_dict,
    manifest_json,
    max_input_bytes,
    parse_hex,
    plan_from_media,
    plan_from_stored,
    resolve_stored_path,
    write_new_file,
)
from .rpc import JsonRpc, StoreClient
from .verify import verify_file

EXIT_NOT_OK = 1
EXIT_ERROR = 2


def _eprint(message: str) -> None:
    print(message, file=sys.stderr)


def _progress(quiet: bool):
    return (lambda _message: None) if quiet else _eprint


def _read_file(path: Path, what: str) -> bytes:
    try:
        return Path(path).read_bytes()
    except OSError as exc:
        raise ToolError(f"cannot read {what} {path}: {exc.strerror or exc}") from exc


def _file_id(text: str) -> bytes:
    return parse_hex(text, "file ID", 32)


def _client(args: argparse.Namespace) -> StoreClient:
    url = args.rpc or os.environ.get("ETH_RPC_URL")
    if not url:
        raise ToolError("no RPC endpoint: pass --rpc URL or set ETH_RPC_URL")
    return StoreClient(JsonRpc(url), parse_address(args.store))


# --- plan ---


def cmd_plan(args: argparse.Namespace) -> int:
    source = Path(args.file)
    encoding = Encoding.parse(args.encoding)
    limit = max_input_bytes(encoding, args.already_encoded)
    try:
        size = source.stat().st_size
    except OSError as exc:
        raise ToolError(f"cannot read input file {source}: {exc.strerror or exc}") from exc
    if size > limit:
        raise ToolError(
            f"{source} is {size:,} bytes; a {encoding.label} input can be at most {limit:,} bytes "
            f"(the store holds {MAX_CHUNKS} chunks of {CHUNK_SIZE:,} bytes)"
        )
    data = _read_file(source, "input file")
    if args.already_encoded:
        plan = plan_from_stored(data, args.mime, encoding)
    else:
        plan = plan_from_media(data, args.mime, encoding)

    manifest_path = Path(args.out) if args.out else source.with_name(source.name + ".content.json")
    manifest_dir = manifest_path.resolve().parent
    copy_stored = not (plan.stored == data and source.resolve().parent == manifest_dir)
    if copy_stored:
        name = manifest_path.name
        stem = name[: -len(".json")] if name.endswith(".json") else name
        stored_path = manifest_path.with_name(stem + ".stored")
    else:
        stored_path = source  # the stream is the input file itself: no copy
    # Refuse before writing anything, so a refusal never leaves half of the output behind.
    for target in (manifest_path, stored_path) if copy_stored else (manifest_path,):
        if target.exists() and not args.force:
            raise ToolError(f"{target} already exists (use --force to overwrite)")
    if copy_stored:
        write_new_file(stored_path, plan.stored, args.force)
    write_new_file(
        manifest_path,
        manifest_json(manifest_dict(plan, stored_path.name, source.name)).encode("utf-8"),
        args.force,
    )

    count = len(plan.chunk_hashes)
    print(f"file ID       {hex0x(plan.file_id)}")
    print(f"mime type     {plan.mime_type}")
    print(f"encoding      {encoding.label} ({int(encoding)})")
    print(f"media         {plan.media_length:,} bytes, sha256 {hex0x(plan.media_sha256)}")
    print(f"stored        {plan.stored_length:,} bytes in {count} chunk(s) of {CHUNK_SIZE:,}")
    reproducible = "yes" if plan.reproducible else "NO (not this tool's encoder output)"
    print(f"reproducible  {reproducible}")
    print(f"manifest      {manifest_path}")
    print(f"stored stream {stored_path}")
    if not plan.reproducible:
        _eprint(
            "warning: re-encoding the decoded media does not give this stream. It is valid, but "
            "keep and publish this exact stream: the file ID commits to its bytes."
        )
    if encoding.uses_gzip or encoding.uses_base64:
        _eprint(
            "note: publish the stored stream itself (Arweave or IPFS) as the locator for this "
            "encoding; the file ID names these exact bytes."
        )
    return 0


# --- calls ---


def cmd_calls(args: argparse.Namespace) -> int:
    manifest_path = Path(args.manifest)
    manifest = load_manifest(manifest_path)
    store = parse_address(args.store)
    if args.stored:
        stored_path = Path(args.stored)
    elif manifest.stored_file:
        stored_path = resolve_stored_path(manifest_path, manifest.stored_file)
    else:
        raise ToolError("the manifest names no stored file; pass --stored PATH")
    stored = _read_file(stored_path, "stored stream")

    skip_register = False
    skip_attest = False
    present: set[bytes] = set()
    if args.only_missing:
        if not (args.rpc or os.environ.get("ETH_RPC_URL")):
            raise ToolError("--only-missing needs --rpc URL (or ETH_RPC_URL)")
        client = _client(args)
        client.check_contract()
        skip_register = client.file_info(manifest.file_id) is not None
        for digest in dict.fromkeys(manifest.chunk_hashes):
            if client.chunk_pointer(digest) is not None:
                present.add(digest)
        if manifest.encoding.uses_base64 and not args.no_attest:
            per_call = client.attest_chunks_per_call()
            if per_call is None:
                skip_attest = True
                _eprint("warning: this store has no attestBase64; no attest calls are emitted")
            elif per_call != ATTEST_CHUNKS_PER_CALL:
                raise ToolError(
                    f"the store's ATTEST_CHUNKS_PER_CALL is {per_call}, not "
                    f"{ATTEST_CHUNKS_PER_CALL}; this tool cannot size the attest calls for it"
                )
            else:
                skip_attest = client.is_base64_attested(manifest.file_id) is True

    plan = calls_module.build_calls(
        manifest, stored, register=args.register, skip_register=skip_register,
        present_chunk_hashes=present, attest=not args.no_attest, skip_attest=skip_attest,
    )
    document = calls_module.calls_document(
        plan, manifest.file_id, store, skipped_register=skip_register,
        skipped_chunks=len(present), skipped_attest=skip_attest,
    )
    out_dir = Path(args.out_dir) if args.out_dir else manifest_path.with_suffix(".calls")
    if out_dir.exists() and any(out_dir.iterdir()):
        if not args.force:
            raise ToolError(f"{out_dir} is not empty (use --force to overwrite)")
        # Drop the previous run's files so none is left behind that no longer matches calls.json.
        for stale in [*out_dir.glob("*.calldata"), out_dir / "send.sh", out_dir / "calls.json"]:
            stale.unlink(missing_ok=True)
    for call in plan:
        text = calls_module.calldata_file_text(call)
        write_new_file(out_dir / call.filename, text.encode(), True)
    script = calls_module.render_script(plan, manifest.file_id, store)
    write_new_file(out_dir / "send.sh", script.encode("utf-8"), True)
    write_new_file(out_dir / "calls.json", calls_module.calls_json(document).encode("utf-8"), True)

    total = document["totalGasEstimate"]
    largest = max((c.estimate for c in plan), key=lambda e: e.transaction, default=None)
    _eprint(f"{len(plan)} transaction(s) written to {out_dir}; nothing was sent")
    _eprint(f"estimated total {total:,} gas")
    attests = sum(c.name == "attestBase64" for c in plan)
    if attests:
        _eprint(
            f"{attests} attestBase64 call(s) come last: a renderer inlines a base64 file only "
            "once it is attested"
        )
    if skip_register or present or skip_attest:
        _eprint(
            f"skipped: manifest {'already registered' if skip_register else 'not yet registered'}"
            f", {len(present)} chunk(s) already stored"
            + (", already attested" if skip_attest else "")
        )
    if largest is not None:
        _eprint(
            f"largest transaction {largest.transaction:,} gas = {largest.cap_fraction:.0%} of the "
            f"EIP-7825 cap ({gas.TX_GAS_CAP:,})"
        )
        if not largest.has_margin:
            _eprint("warning: a transaction uses more than three quarters of the gas cap")
    if args.json:
        sys.stdout.write(calls_module.calls_json(document))
    else:
        sys.stdout.write(script)
    return 0


# --- verify and rebuild ---


def cmd_verify(args: argparse.Namespace) -> int:
    client = _client(args)
    result = verify_file(client, _file_id(args.file_id), _progress(args.quiet or args.json))
    report = result.report
    if args.json:
        print(json.dumps(report.to_dict(), indent=2))
    else:
        print(report.render())
    if not report.ok:
        return EXIT_NOT_OK
    if args.require_attested and report.encoding in ("base64", "gzipbase64"):
        if report.base64_attested is not True:
            _eprint("not attested: --require-attested was given")
            return EXIT_NOT_OK
    return 0


def cmd_rebuild(args: argparse.Namespace) -> int:
    out = Path(args.output)
    if out.exists() and not args.force:
        raise ToolError(f"{out} already exists (use --force to overwrite)")
    client = _client(args)
    result = verify_file(client, _file_id(args.file_id), _progress(args.quiet))
    if not result.report.ok or result.stored is None or result.media is None:
        print(result.report.render())
        _eprint("nothing was written: the file did not verify")
        return EXIT_NOT_OK
    data = result.stored if args.stored else result.media
    write_new_file(out, data, args.force)
    what = "stored (encoded) stream" if args.stored else "decoded media"
    print(f"wrote {len(data):,} bytes of {what} to {out}")
    print(f"media sha256 {hex0x(result.report.declared_media_sha256 or b'')} verified")
    if not result.report.reproducible:
        _eprint(
            "note: this tool's encoder would not reproduce the stored bytes; they are valid and "
            "verified, so publish them as they are if you need the encoded stream elsewhere"
        )
    return 0


# --- golden ---


def cmd_golden(args: argparse.Namespace) -> int:
    from . import golden

    return golden.run(write_files=args.write)


# --- parser ---


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m tools.content",
        description=(
            "Stage a work's bytes into the 6529 Works content store, and verify or rebuild them "
            "from the chain. Read-only: nothing is signed or sent."
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")

    p = sub.add_parser("plan", help="encode, chunk and hash a file; write a JSON manifest")
    p.add_argument("file", help="the media file (or, with --already-encoded, the stored stream)")
    p.add_argument(
        "--mime", required=True, help="MIME type, lowercase type/subtype, e.g. image/png"
    )
    p.add_argument(
        "--encoding", required=True, choices=[e.label for e in Encoding],
        help="how the bytes are stored on chain",
    )
    p.add_argument("-o", "--out", help="manifest path (default: <file>.content.json)")
    p.add_argument(
        "--already-encoded", action="store_true",
        help="FILE is already the encoded stream (for example fetched from Arweave)",
    )
    p.add_argument("--force", action="store_true", help="overwrite existing output files")
    p.set_defaults(func=cmd_plan)

    p = sub.add_parser("calls", help="emit the transactions (calldata and cast send lines)")
    p.add_argument("manifest", help="manifest.json from `plan`")
    p.add_argument("--store", required=True, help="address of the ContentStore")
    p.add_argument("--out-dir", help="where to write calldata files (default: <manifest>.calls)")
    p.add_argument(
        "--register", choices=("first", "last"), default="first",
        help="send registerManifest before (default) or after the chunks",
    )
    p.add_argument("--stored", help="the stored stream, if not the file the manifest names")
    p.add_argument(
        "--only-missing", action="store_true",
        help="ask the chain (needs --rpc) and skip what is already stored or registered",
    )
    p.add_argument("--rpc", help="JSON-RPC URL (default: $ETH_RPC_URL); only for --only-missing")
    p.add_argument(
        "--no-attest", action="store_true",
        help="omit the attestBase64 calls a Base64 or GzipBase64 file otherwise gets",
    )
    p.add_argument("--json", action="store_true", help="print calls.json instead of the script")
    p.add_argument("--force", action="store_true", help="write into a non-empty out-dir")
    p.set_defaults(func=cmd_calls)

    for name, help_text, func in (
        ("verify", "check a registered file against the chain (read-only)", cmd_verify),
        ("rebuild", "reconstruct the decoded media from the chain", cmd_rebuild),
    ):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("--rpc", help="JSON-RPC URL (default: $ETH_RPC_URL)")
        p.add_argument("--store", required=True, help="address of the ContentStore")
        p.add_argument("file_id", metavar="FILEID", help="0x-prefixed 32-byte file ID")
        p.add_argument("-q", "--quiet", action="store_true", help="no progress on stderr")
        if name == "verify":
            p.add_argument("--json", action="store_true", help="machine-readable report")
            p.add_argument(
                "--require-attested", action="store_true",
                help="exit 1 unless a Base64 or GzipBase64 file is attested (renderers need it)",
            )
        else:
            p.add_argument("-o", "--output", required=True, help="where to write the media")
            p.add_argument(
                "--stored", action="store_true",
                help="write the stored (encoded) stream instead of the decoded media",
            )
            p.add_argument("--force", action="store_true", help="overwrite the output file")
        p.set_defaults(func=func)

    p = sub.add_parser("golden", help="maintainers: regenerate or check the golden vectors")
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="rewrite vectors.json and the .sol data")
    mode.add_argument("--check", action="store_true", help="fail if any committed file is stale")
    p.set_defaults(func=cmd_golden)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except ToolError as exc:
        _eprint(f"error: {exc}")
        return EXIT_ERROR
    except BrokenPipeError:
        return 0
