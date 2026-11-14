#!/usr/bin/env python3
"""Generate JSON evidence from a Verify.s.sol run.

Wraps `forge script script/Verify.s.sol` to produce a structured evidence file that
records the inputs, environment and result.

Verify.s.sol rebuilds from source and recomputes every address: 23 contracts use
CREATE2, whose addresses commit to the initcode (creation code plus constructor
arguments); WorksAccessManager uses CREATE from the configurator at nonce 1.
Verify also compares runtime code hashes against the deployment record. This tool
packages that verification as documented evidence.

Example:
    python tools/verify_evidence.py \\
        --deployment deployments/11155111/1793536584.json \\
        --manifest config/sepolia-r4/manifest-epoch0.json \\
        --rpc-url-env SEPOLIA_RPC_URL \\
        --output evidence.json

Run from a commit whose src/ and script/ match the deployment (the record's merge
commit, or a checkout of the source revision with the record and config copied in).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

TOOL_VERSION = "0.1.1"


def sanitize_error(message: str) -> str:
    """Remove potential credentials from error messages."""
    # Remove anything that looks like an API key or token in a URL path
    sanitized = re.sub(
        r"(https?://[^/\s]+)/[^\s]*",
        r"\1/<redacted>",
        str(message),
    )
    # Also redact common API key patterns
    sanitized = re.sub(
        r"[a-fA-F0-9]{32,}",
        "<redacted>",
        sanitized,
    )
    return sanitized


@dataclass
class VerifyEvidence:
    """Evidence from a Verify.s.sol run."""

    tool_version: str
    timestamp: str
    result: str  # "passed", "failed", "error"

    # Source
    git_commit: str
    git_branch: str
    submodule_revisions: dict[str, str]

    # Build environment
    solc_version: str
    evm_version: str
    optimizer_runs: int
    via_ir: bool
    foundry_version: str

    # Inputs
    deployment_path: str
    deployment_sha256: str
    manifest_path: str
    manifest_sha256: str
    chain_id: int

    # Verify settings
    allow_pending_operations: bool = False

    # Observation point
    block_number: int = 0
    block_hash: str = ""
    block_timestamp: str = ""

    # Verify output
    verify_stdout: str = ""
    verify_stderr: str = ""
    verify_exit_code: int = 0

    # Summary from deployment record
    contract_count: int = 0
    contract_names: list[str] = field(default_factory=list)

    error_message: str = ""

    def to_dict(self) -> dict[str, Any]:
        """Convert to JSON-serializable dict."""
        return {
            "tool_version": self.tool_version,
            "timestamp": self.timestamp,
            "result": self.result,
            "source": {
                "git_commit": self.git_commit,
                "git_branch": self.git_branch,
                "submodules": self.submodule_revisions,
            },
            "build": {
                "solc_version": self.solc_version,
                "evm_version": self.evm_version,
                "optimizer_runs": self.optimizer_runs,
                "via_ir": self.via_ir,
                "foundry_version": self.foundry_version,
            },
            "inputs": {
                "deployment_path": self.deployment_path,
                "deployment_sha256": self.deployment_sha256,
                "manifest_path": self.manifest_path,
                "manifest_sha256": self.manifest_sha256,
                "chain_id": self.chain_id,
            },
            "verify_settings": {
                "allow_pending_operations": self.allow_pending_operations,
            },
            "observation": {
                "block_number": self.block_number,
                "block_hash": self.block_hash,
                "block_timestamp": self.block_timestamp,
            },
            "contracts": {
                "count": self.contract_count,
                "names": sorted(self.contract_names),
            },
            "verify": {
                "exit_code": self.verify_exit_code,
                "stdout_tail": self.verify_stdout[-2000:] if self.verify_stdout else "",
                "stderr_tail": self.verify_stderr[-1000:] if self.verify_stderr else "",
            },
            "error_message": sanitize_error(self.error_message) if self.error_message else "",
        }


def sha256_file(path: Path) -> str:
    """Compute SHA-256 of a file, returned as 0x-prefixed hex."""
    with open(path, "rb") as f:
        return "0x" + hashlib.sha256(f.read()).hexdigest()


def get_git_info(repo_root: Path) -> tuple[str, str]:
    """Get current git commit SHA and branch name."""
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        cwd=repo_root,
    )
    branch = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        capture_output=True,
        text=True,
        cwd=repo_root,
    )
    return (
        commit.stdout.strip() if commit.returncode == 0 else "unknown",
        branch.stdout.strip() if branch.returncode == 0 else "unknown",
    )


def get_submodule_revisions(repo_root: Path) -> dict[str, str]:
    """Get current revision of each submodule."""
    result = subprocess.run(
        ["git", "submodule", "status"],
        capture_output=True,
        text=True,
        cwd=repo_root,
    )
    if result.returncode != 0:
        return {}

    revisions = {}
    for line in result.stdout.strip().split("\n"):
        if not line:
            continue
        parts = line.strip().split()
        if len(parts) >= 2:
            sha = parts[0].lstrip("+-")
            path = parts[1]
            revisions[path] = sha[:12]
    return revisions


class ForgeConfigError(Exception):
    """Raised when forge config cannot be read or is invalid."""

    pass


def get_forge_config(repo_root: Path) -> tuple[str, str, int, bool]:
    """Get solc version, EVM version, optimizer runs, via_ir from forge config.

    Raises ForgeConfigError if forge config fails or returns invalid data.
    """
    result = subprocess.run(
        ["forge", "config", "--json"],
        capture_output=True,
        text=True,
        cwd=repo_root,
    )
    if result.returncode != 0:
        raise ForgeConfigError(f"forge config failed: {result.stderr[:200]}")

    try:
        config = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        raise ForgeConfigError(f"forge config returned invalid JSON: {e}")

    # Require essential fields
    if "solc" not in config:
        raise ForgeConfigError("forge config missing 'solc' field")
    if "evm_version" not in config:
        raise ForgeConfigError("forge config missing 'evm_version' field")

    try:
        optimizer_runs = int(config.get("optimizer_runs", 200))
    except (ValueError, TypeError) as e:
        raise ForgeConfigError(f"invalid optimizer_runs value: {e}")

    return (
        str(config["solc"]),
        str(config["evm_version"]),
        optimizer_runs,
        bool(config.get("via_ir", False)),
    )


def get_foundry_version() -> str:
    """Get Foundry version string."""
    result = subprocess.run(
        ["forge", "--version"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        # Format: "forge 0.2.0 (abc1234 2024-01-01T00:00:00.000000000Z)"
        return result.stdout.strip().split("\n")[0]
    return "unknown"


def rpc_call(url: str, method: str, params: list[Any], timeout: int = 30) -> Any:
    """Make a JSON-RPC call."""
    import urllib.error
    import urllib.request

    payload = json.dumps(
        {"jsonrpc": "2.0", "method": method, "params": params, "id": 1}
    ).encode()

    headers = {"Content-Type": "application/json"}
    request = urllib.request.Request(url, data=payload, headers=headers)

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = json.loads(response.read().decode())
            if "error" in result:
                raise RuntimeError(f"RPC error: {result['error']}")
            return result.get("result")
    except urllib.error.URLError as e:
        # Sanitize error to avoid leaking credentials
        raise RuntimeError(f"RPC connection failed: {sanitize_error(str(e))}")
    except Exception as e:
        raise RuntimeError(f"RPC call failed: {sanitize_error(str(e))}")


def get_block_info(rpc_url: str, tag: str = "finalized") -> tuple[int, str, str]:
    """Get block number, hash, and timestamp."""
    block = rpc_call(rpc_url, "eth_getBlockByNumber", [tag, False])
    if block is None:
        raise RuntimeError(f"Block '{tag}' not found")

    number = int(block["number"], 16)
    block_hash = block["hash"]
    timestamp = int(block["timestamp"], 16)
    dt = datetime.fromtimestamp(timestamp, tz=timezone.utc)

    return number, block_hash, dt.isoformat()


def get_chain_id(rpc_url: str) -> int:
    """Get chain ID from RPC."""
    result = rpc_call(rpc_url, "eth_chainId", [])
    return int(result, 16)


def find_root(start: Path) -> Path:
    """Find repository root (directory with foundry.toml)."""
    for candidate in [start, *start.parents]:
        if (candidate / "foundry.toml").is_file():
            return candidate
    raise SystemExit(f"no foundry.toml above {start}")


def run_verify(
    repo_root: Path,
    deployment_path: Path,
    manifest_path: Path,
    rpc_url: str,
    block_number: int | None = None,
    allow_pending: bool = False,
) -> tuple[int, str, str]:
    """Run Verify.s.sol and return exit code, stdout, stderr."""
    # Start with minimal env, explicitly set ALLOW_PENDING_OPERATIONS
    env = dict(os.environ)
    env["DEPLOYMENT"] = str(deployment_path)
    env["MANIFEST_PATH"] = str(manifest_path)

    # Explicitly set (not inherit) ALLOW_PENDING_OPERATIONS
    env["ALLOW_PENDING_OPERATIONS"] = "1" if allow_pending else "0"

    cmd = [
        "forge",
        "script",
        "script/Verify.s.sol",
        "--rpc-url",
        rpc_url,
    ]

    if block_number is not None:
        cmd.extend(["--fork-block-number", str(block_number)])

    result = subprocess.run(
        cmd,
        cwd=repo_root,
        env=env,
        capture_output=True,
        text=True,
        timeout=300,
    )

    return result.returncode, result.stdout, result.stderr


def generate_evidence(
    deployment_path: Path,
    manifest_path: Path,
    rpc_url: str,
    repo_root: Path,
    block_tag: str = "finalized",
    allow_pending: bool = False,
) -> VerifyEvidence:
    """Generate evidence from a Verify.s.sol run."""
    timestamp = datetime.now(timezone.utc).isoformat()

    # Load deployment record
    with open(deployment_path) as f:
        record = json.load(f)

    contracts = record.get("contracts", {})
    chain_id = record.get("chainId", 0)

    # Get source info
    git_commit, git_branch = get_git_info(repo_root)
    submodules = get_submodule_revisions(repo_root)

    # Get build config - fail if unavailable
    try:
        solc, evm, runs, via_ir = get_forge_config(repo_root)
    except ForgeConfigError as e:
        # Return error evidence if we can't read forge config
        return VerifyEvidence(
            tool_version=TOOL_VERSION,
            timestamp=timestamp,
            result="error",
            git_commit=git_commit,
            git_branch=git_branch,
            submodule_revisions=submodules,
            solc_version="unknown",
            evm_version="unknown",
            optimizer_runs=0,
            via_ir=False,
            foundry_version=get_foundry_version(),
            deployment_path=str(deployment_path),
            deployment_sha256=sha256_file(deployment_path),
            manifest_path=str(manifest_path),
            manifest_sha256=sha256_file(manifest_path),
            chain_id=chain_id,
            allow_pending_operations=allow_pending,
            contract_count=len(contracts),
            contract_names=list(contracts.keys()),
            error_message=f"Failed to read forge config: {e}",
        )

    foundry = get_foundry_version()

    # Initialize evidence
    evidence = VerifyEvidence(
        tool_version=TOOL_VERSION,
        timestamp=timestamp,
        result="pending",
        git_commit=git_commit,
        git_branch=git_branch,
        submodule_revisions=submodules,
        solc_version=solc,
        evm_version=evm,
        optimizer_runs=runs,
        via_ir=via_ir,
        foundry_version=foundry,
        deployment_path=str(deployment_path),
        deployment_sha256=sha256_file(deployment_path),
        manifest_path=str(manifest_path),
        manifest_sha256=sha256_file(manifest_path),
        chain_id=chain_id,
        allow_pending_operations=allow_pending,
        contract_count=len(contracts),
        contract_names=list(contracts.keys()),
    )

    # Get block info
    try:
        actual_chain_id = get_chain_id(rpc_url)
        if actual_chain_id != chain_id:
            evidence.result = "error"
            evidence.error_message = (
                f"Chain ID mismatch: expected {chain_id}, got {actual_chain_id}"
            )
            return evidence

        block_num, block_hash, block_ts = get_block_info(rpc_url, block_tag)
        evidence.block_number = block_num
        evidence.block_hash = block_hash
        evidence.block_timestamp = block_ts
    except Exception as e:
        evidence.result = "error"
        evidence.error_message = f"Failed to get block info: {sanitize_error(str(e))}"
        return evidence

    # Run Verify.s.sol
    try:
        exit_code, stdout, stderr = run_verify(
            repo_root=repo_root,
            deployment_path=deployment_path,
            manifest_path=manifest_path,
            rpc_url=rpc_url,
            block_number=evidence.block_number,
            allow_pending=allow_pending,
        )
        evidence.verify_exit_code = exit_code
        evidence.verify_stdout = stdout
        evidence.verify_stderr = stderr

        if exit_code == 0:
            evidence.result = "passed"
        else:
            evidence.result = "failed"
            # Extract error from output
            if "Error" in stderr:
                evidence.error_message = stderr.split("Error")[-1][:500].strip()
            elif "revert" in stdout.lower():
                for line in stdout.split("\n"):
                    if "revert" in line.lower():
                        evidence.error_message = line.strip()[:500]
                        break

    except subprocess.TimeoutExpired:
        evidence.result = "error"
        evidence.error_message = "Verify.s.sol timed out after 300 seconds"
    except Exception as e:
        evidence.result = "error"
        evidence.error_message = f"Failed to run Verify.s.sol: {sanitize_error(str(e))}"

    return evidence


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--deployment",
        type=Path,
        required=True,
        help="Path to deployment record JSON",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        required=True,
        help="Path to manifest file",
    )
    parser.add_argument(
        "--rpc-url-env",
        default="RPC_URL",
        help="Environment variable containing RPC URL (default: RPC_URL)",
    )
    parser.add_argument(
        "--rpc-url",
        help="RPC URL directly (alternative to --rpc-url-env)",
    )
    parser.add_argument(
        "--block",
        default="finalized",
        help="Block tag for observation (default: finalized)",
    )
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        help="Output JSON evidence file (default: stdout)",
    )
    parser.add_argument(
        "--allow-pending",
        action="store_true",
        help="Allow pending manager operations (sets ALLOW_PENDING_OPERATIONS=1)",
    )
    parser.add_argument(
        "--root",
        type=Path,
        help="Repository root (default: auto-detected)",
    )

    args = parser.parse_args(argv)

    # Get RPC URL
    if args.rpc_url:
        rpc_url = args.rpc_url
    else:
        rpc_url = os.environ.get(args.rpc_url_env, "")
        if not rpc_url:
            print(
                f"Error: Set {args.rpc_url_env} or use --rpc-url",
                file=sys.stderr,
            )
            return 2

    # Find repo root
    root = args.root or find_root(Path(__file__).resolve().parent)

    # Resolve paths
    deployment = args.deployment
    if not deployment.is_absolute():
        deployment = root / deployment
    if not deployment.exists():
        print(f"Error: Deployment not found: {deployment}", file=sys.stderr)
        return 2

    manifest = args.manifest
    if not manifest.is_absolute():
        manifest = root / manifest
    if not manifest.exists():
        print(f"Error: Manifest not found: {manifest}", file=sys.stderr)
        return 2

    # Generate evidence
    print(f"Running Verify.s.sol against {deployment.name}...", file=sys.stderr)
    evidence = generate_evidence(
        deployment_path=deployment,
        manifest_path=manifest,
        rpc_url=rpc_url,
        repo_root=root,
        block_tag=args.block,
        allow_pending=args.allow_pending,
    )

    # Output
    output_json = json.dumps(evidence.to_dict(), indent=2)

    if args.output:
        with open(args.output, "w") as f:
            f.write(output_json)
            f.write("\n")
        print(f"Evidence written to: {args.output}", file=sys.stderr)
    else:
        print(output_json)

    # Print summary (sanitize any error messages)
    print(f"\n{'=' * 60}", file=sys.stderr)
    print(f"Result: {evidence.result.upper()}", file=sys.stderr)
    print(f"Commit: {evidence.git_commit[:12]}", file=sys.stderr)
    if evidence.block_hash:
        print(
            f"Block: {evidence.block_number} ({evidence.block_hash[:18]}...)",
            file=sys.stderr,
        )
    print(f"Contracts: {evidence.contract_count}", file=sys.stderr)
    if evidence.error_message:
        print(f"Error: {sanitize_error(evidence.error_message)[:200]}", file=sys.stderr)
    print("=" * 60, file=sys.stderr)

    # Exit code
    if evidence.result == "passed":
        return 0
    elif evidence.result == "failed":
        return 1
    else:
        return 2


if __name__ == "__main__":
    sys.exit(main())
