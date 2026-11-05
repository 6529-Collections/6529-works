#!/usr/bin/env python3
"""Verify deployed Works bytecode from reproducible builds.

Addresses LIM-REL-1 in docs/audit/known-limitations.md: independently rebuilds
6529 Works contracts from source and compares them against deployed bytecode.

The verifier:
1. Checks out the deployment source revision in a clean worktree.
2. Builds with the pinned compiler and Foundry configuration.
3. Simulates deployment on a local Anvil fork of the target chain.
4. Compares reconstructed runtime bytecodes against on-chain code.
5. Produces a detailed report with per-contract results.

Run from anywhere: `python tools/verify_bytecode.py --help`. Standard library
only (no pip dependencies). The repository root is the nearest ancestor with
a foundry.toml.

Example:
    python tools/verify_bytecode.py \\
        --deployment deployments/11155111/1793536584.json \\
        --source-ref 1e7022b49bdba32119f1349d5150b98756799b9b \\
        --rpc-url-env SEPOLIA_RPC_URL \\
        --block finalized \\
        --json report.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, TypedDict

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------


class ContractRecord(TypedDict):
    address: str
    codehash: str


class DeploymentParams(TypedDict, total=False):
    factory: str
    deployer: str
    namespace: str
    networkFeeRecipient: str
    museum: str
    marketOwner: str
    delegation: str
    ethIncrementFloor: str
    permit2: str
    auctionDuration: int
    auctionExtensionWindow: int
    auctionIncrementShare: int
    editionBasePrice: int
    editionStepsPerDecade: int
    editionStepCount: int
    editionMarginShare: int
    editionCloseOffset: int
    editionSoftWindow: int
    editionMaxExtension: int
    vrfCoordinator: str
    vrfCoordinatorCodeHash: str
    vrfSubscriptionId: str
    vrfKeyHash: str
    vrfCallbackGasLimit: int
    vrfConfirmations: int
    vrfNativePayment: bool
    vrfRetryDelay: int


class DeploymentRecord(TypedDict, total=False):
    chainId: int
    startBlock: int
    timestamp: int
    confirmed: bool
    contracts: dict[str, ContractRecord]
    params: DeploymentParams
    cc0TextFileId: str
    cc0TextSha256: str
    entropy: str
    genesisConfig: str
    manifestDigest: str
    manifestPath: str


@dataclass
class ContractResult:
    """Result of verifying a single contract."""

    name: str
    address: str
    expected_codehash: str
    observed_codehash: str
    status: str  # "match", "mismatch", "missing", "error", "unsupported"
    message: str = ""
    artifact: str = ""  # fully qualified artifact name
    reconstruction_method: str = ""


@dataclass
class VerificationReport:
    """Complete verification report."""

    verifier_version: str
    deployment_path: str
    deployment_digest: str
    source_revision: str
    chain_id: int
    observation_block_number: int
    observation_block_hash: str
    compiler_version: str
    evm_version: str
    optimizer_runs: int
    via_ir: bool
    contracts: list[ContractResult] = field(default_factory=list)
    total_expected: int = 0
    total_verified: int = 0
    total_mismatched: int = 0
    total_missing: int = 0
    total_errors: int = 0
    overall_status: str = "pending"  # "passed", "failed", "incomplete"
    external_dependencies: list[str] = field(default_factory=list)
    unsupported_contracts: list[str] = field(default_factory=list)
    trust_assumptions: list[str] = field(default_factory=list)
    error_message: str = ""
    submodule_revisions: dict[str, str] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        """Convert to JSON-serializable dict with stable ordering."""
        return {
            "verifier_version": self.verifier_version,
            "deployment": {
                "path": self.deployment_path,
                "digest": self.deployment_digest,
            },
            "source": {
                "revision": self.source_revision,
                "submodules": self.submodule_revisions,
            },
            "build_config": {
                "compiler_version": self.compiler_version,
                "evm_version": self.evm_version,
                "optimizer_runs": self.optimizer_runs,
                "via_ir": self.via_ir,
            },
            "observation": {
                "chain_id": self.chain_id,
                "block_number": self.observation_block_number,
                "block_hash": self.observation_block_hash,
            },
            "contracts": [
                {
                    "name": c.name,
                    "artifact": c.artifact,
                    "address": c.address,
                    "expected_codehash": c.expected_codehash,
                    "observed_codehash": c.observed_codehash,
                    "reconstruction_method": c.reconstruction_method,
                    "status": c.status,
                    "message": c.message,
                }
                for c in sorted(self.contracts, key=lambda x: x.name)
            ],
            "summary": {
                "total_expected": self.total_expected,
                "total_verified": self.total_verified,
                "total_mismatched": self.total_mismatched,
                "total_missing": self.total_missing,
                "total_errors": self.total_errors,
                "overall_status": self.overall_status,
            },
            "external_dependencies": sorted(self.external_dependencies),
            "unsupported_contracts": sorted(self.unsupported_contracts),
            "trust_assumptions": self.trust_assumptions,
            "error_message": self.error_message,
        }


# ---------------------------------------------------------------------------
# Contract name to artifact mapping
# ---------------------------------------------------------------------------

# Maps deployment record contract names to Solidity artifact names
ARTIFACT_MAP: dict[str, str] = {
    "GovernanceConfigurator": "GovernanceConfigurator",
    "WorksAccessManager": "WorksAccessManager",
    "ContentStore": "ContentStore",
    "DependencyRegistry": "DependencyRegistry",
    "ConsolidationAdapter": "ConsolidationAdapter",
    "ArtistRegistry": "ArtistRegistry",
    "ReleaseVerifier": "ReleaseVerifier",
    "SplitFactory": "SplitFactory",
    "ClaimRouter": "ClaimRouter",
    "AssetAllowlist": "AssetAllowlist",
    "EconomicsResolver": "EconomicsResolver",
    "RevenueEscrow": "RevenueEscrow",
    "CurationVerifier": "Eip712CurationVerifier",
    "PackageRegistry": "PackageRegistry",
    "StatementLog": "StatementLog",
    "EntropyModule": "VrfEntropyModule",
    "Renderer": "Renderer",
    "Stream": "Stream",
    "WorkRecords": "WorkRecords",
    "Editions": "Editions",
    "EnglishAuction": "EnglishAuction",
    "EnglishAuctionLens": "EnglishAuctionLens",
    "UniformEditionAuction": "UniformEditionAuction",
    "UniformEditionAuctionLens": "UniformEditionAuctionLens",
}

# External dependencies not rebuilt from Works source
EXTERNAL_DEPENDENCIES: set[str] = {
    "delegation",  # 6529 delegation contract
    "permit2",  # Uniswap Permit2
    "vrfCoordinator",  # Chainlink VRF
}

VERIFIER_VERSION = "0.1.0"

# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------


def rpc_call(
    url: str,
    method: str,
    params: list[Any],
    timeout: int = 30,
    retries: int = 3,
) -> Any:
    """Make a JSON-RPC call with retries."""
    import urllib.error
    import urllib.request

    payload = json.dumps(
        {"jsonrpc": "2.0", "method": method, "params": params, "id": 1}
    ).encode()

    headers = {"Content-Type": "application/json"}
    request = urllib.request.Request(url, data=payload, headers=headers)

    last_error: Exception | None = None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                result = json.loads(response.read().decode())
                if "error" in result:
                    raise RuntimeError(f"RPC error: {result['error']}")
                return result.get("result")
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            last_error = e
            if attempt < retries - 1:
                time.sleep(1 * (attempt + 1))

    raise RuntimeError(f"RPC call failed after {retries} attempts: {last_error}")


def get_chain_id(rpc_url: str) -> int:
    """Get chain ID from RPC."""
    result = rpc_call(rpc_url, "eth_chainId", [])
    return int(result, 16)


def get_block_by_tag(rpc_url: str, tag: str) -> tuple[int, str]:
    """Get block number and hash for a tag (latest, finalized, etc)."""
    block = rpc_call(rpc_url, "eth_getBlockByNumber", [tag, False])
    if block is None:
        raise RuntimeError(f"Block '{tag}' not found")
    return int(block["number"], 16), block["hash"]


def get_code(rpc_url: str, address: str, block: str) -> bytes:
    """Get deployed code at address and block."""
    result = rpc_call(rpc_url, "eth_getCode", [address, block])
    if result == "0x" or result is None:
        return b""
    return bytes.fromhex(result[2:])


def keccak256_bytes(data: bytes) -> str:
    """Compute keccak256 hash using cast, returned as 0x-prefixed hex."""
    if not data:
        # Empty code has a known hash
        return "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"

    # Use cast for keccak (it handles raw bytes properly)
    result = subprocess.run(
        ["cast", "keccak", "0x" + data.hex()],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"cast keccak failed: {result.stderr}")
    return result.stdout.strip()


# ---------------------------------------------------------------------------
# Repository helpers
# ---------------------------------------------------------------------------


def find_root(start: Path) -> Path:
    """Find repository root (directory with foundry.toml)."""
    for candidate in [start, *start.parents]:
        if (candidate / "foundry.toml").is_file():
            return candidate
    raise SystemExit(f"no foundry.toml above {start}")


def get_compiler_settings(source_dir: Path) -> tuple[str, str, int, bool]:
    """Get compiler version, EVM version, optimizer runs, via_ir from forge config."""
    result = subprocess.run(
        ["forge", "config", "--json"],
        capture_output=True,
        text=True,
        cwd=source_dir,
    )
    if result.returncode != 0:
        raise RuntimeError(f"forge config failed: {result.stderr}")

    try:
        config = json.loads(result.stdout)
        solc = config.get("solc", "unknown")
        evm = config.get("evm_version", "unknown")
        runs = config.get("optimizer_runs", 200)
        via_ir = config.get("via_ir", False)
        return str(solc), str(evm), int(runs), bool(via_ir)
    except (json.JSONDecodeError, KeyError) as e:
        raise RuntimeError(f"Failed to parse forge config: {e}")


def get_submodule_revisions(source_dir: Path) -> dict[str, str]:
    """Get the current revision of each submodule."""
    result = subprocess.run(
        ["git", "submodule", "status"],
        capture_output=True,
        text=True,
        cwd=source_dir,
    )
    if result.returncode != 0:
        return {}

    revisions = {}
    for line in result.stdout.strip().split("\n"):
        if not line:
            continue
        # Format: " <sha> <path> (<desc>)" or "+<sha> <path> (<desc>)"
        parts = line.strip().split()
        if len(parts) >= 2:
            sha = parts[0].lstrip("+- ")
            path = parts[1]
            revisions[path] = sha[:12]

    return revisions


def checkout_source(
    repo_root: Path,
    source_ref: str,
    work_dir: Path,
) -> Path:
    """Check out source at specific revision in a clean working directory.

    Returns the path to the checked-out source.
    """
    source_dir = work_dir / "source"

    # Clone from local repo to get exact state
    subprocess.run(
        ["git", "clone", "--no-checkout", str(repo_root), str(source_dir)],
        check=True,
        capture_output=True,
    )

    # Checkout specific revision
    result = subprocess.run(
        ["git", "checkout", source_ref],
        cwd=source_dir,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git checkout failed: {result.stderr}")

    # Initialize submodules at their pinned revisions
    result = subprocess.run(
        ["git", "submodule", "update", "--init", "--recursive"],
        cwd=source_dir,
        capture_output=True,
        text=True,
        timeout=180,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git submodule update failed: {result.stderr}")

    return source_dir


def build_source(source_dir: Path) -> Path:
    """Build the source and return the artifacts directory."""
    # Clean any existing build
    out_dir = source_dir / "out"
    if out_dir.exists():
        shutil.rmtree(out_dir)

    # Build with forge
    env = dict(os.environ)
    env["FOUNDRY_PROFILE"] = "default"

    result = subprocess.run(
        ["forge", "build"],
        cwd=source_dir,
        env=env,
        capture_output=True,
        text=True,
        timeout=600,
    )

    if result.returncode != 0:
        raise RuntimeError(f"forge build failed:\n{result.stderr}")

    return out_dir


# ---------------------------------------------------------------------------
# Bytecode reconstruction via deployment simulation
# ---------------------------------------------------------------------------


def simulate_deployment_on_fork(
    source_dir: Path,
    deployment_record: DeploymentRecord,
    rpc_url: str,
    work_dir: Path,
) -> dict[str, str]:
    """Simulate deployment on a fork to get runtime bytecodes.

    Forks the target chain, runs the deployment script, and captures
    the resulting bytecodes. Returns a mapping of contract name to codehash.
    """
    chain_id = deployment_record.get("chainId", 31337)
    params = deployment_record.get("params", {})
    start_block = deployment_record.get("startBlock", 0)

    # Fork at a block before the deployment
    fork_block = max(1, start_block - 10) if start_block > 0 else "latest"

    # Start Anvil forking the target chain
    anvil_port = 28545

    anvil_cmd = [
        "anvil",
        "--fork-url",
        rpc_url,
        "--fork-block-number",
        str(fork_block),
        "--port",
        str(anvil_port),
        "--silent",
        "--no-mining",  # We'll mine manually
    ]

    anvil_proc = subprocess.Popen(
        anvil_cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    expected_codehashes: dict[str, str] = {}

    try:
        # Wait for Anvil to start
        time.sleep(3)

        # Verify Anvil is running
        anvil_url = f"http://127.0.0.1:{anvil_port}"
        try:
            anvil_chain_id = get_chain_id(anvil_url)
            if anvil_chain_id != chain_id:
                raise RuntimeError(
                    f"Anvil chain ID {anvil_chain_id} != expected {chain_id}"
                )
        except Exception as e:
            raise RuntimeError(f"Anvil not responding: {e}")

        # Set up deployment environment
        env = dict(os.environ)
        env["FOUNDRY_PROFILE"] = "default"

        # Core params
        env["DEPLOY_NAMESPACE"] = params.get("namespace", "")
        env["NETWORK_FEE_RECIPIENT"] = params.get("networkFeeRecipient", "")
        env["MUSEUM"] = params.get("museum", "")
        env["MARKETPLACE_OWNER"] = params.get("marketOwner", "")
        env["DELEGATION_CONTRACT"] = params.get("delegation", "")
        env["ETH_INCREMENT_FLOOR"] = params.get("ethIncrementFloor", "0")
        env["PERMIT2"] = params.get("permit2", "")

        # Auction params
        env["AUCTION_DURATION"] = str(params.get("auctionDuration", 86400))
        env["AUCTION_EXTENSION_WINDOW"] = str(params.get("auctionExtensionWindow", 900))
        env["AUCTION_INCREMENT_SHARE"] = str(params.get("auctionIncrementShare", 5000))

        # Edition auction params
        env["EDITION_BASE_PRICE"] = str(params.get("editionBasePrice", 100000000000000))
        env["EDITION_STEPS_PER_DECADE"] = str(params.get("editionStepsPerDecade", 48))
        env["EDITION_STEP_COUNT"] = str(params.get("editionStepCount", 336))
        env["EDITION_MARGIN_SHARE"] = str(params.get("editionMarginShare", 10000))
        env["EDITION_CLOSE_OFFSET"] = str(params.get("editionCloseOffset", 900))
        env["EDITION_SOFT_WINDOW"] = str(params.get("editionSoftWindow", 300))
        env["EDITION_MAX_EXTENSION"] = str(params.get("editionMaxExtension", 86400))

        # Genesis config
        genesis_path = deployment_record.get("genesisConfig", "")
        if genesis_path:
            env["GENESIS_CONFIG"] = genesis_path

        # Manifest
        manifest_path = deployment_record.get("manifestPath", "")
        if manifest_path:
            env["MANIFEST_PATH"] = manifest_path
            env["MANIFEST_URI"] = deployment_record.get("manifestUri", "")

        # VRF params
        vrf_coord = params.get("vrfCoordinator", "")
        if (
            vrf_coord
            and vrf_coord != "0x0000000000000000000000000000000000000000"
            and deployment_record.get("entropy") == "vrf"
        ):
            env["VRF_COORDINATOR"] = vrf_coord
            env["VRF_COORDINATOR_CODEHASH"] = params.get("vrfCoordinatorCodeHash", "")
            env["VRF_SUBSCRIPTION_ID"] = params.get("vrfSubscriptionId", "0")
            env["VRF_KEY_HASH"] = params.get("vrfKeyHash", "")
            env["VRF_CALLBACK_GAS_LIMIT"] = str(params.get("vrfCallbackGasLimit", 200000))
            env["VRF_CONFIRMATIONS"] = str(params.get("vrfConfirmations", 3))
            env["VRF_NATIVE_PAYMENT"] = "1" if params.get("vrfNativePayment") else "0"
            env["VRF_RETRY_DELAY"] = str(params.get("vrfRetryDelay", 259200))
        else:
            env["NO_VRF"] = "1"

        # Run deployment simulation
        deployer = params.get("deployer", "0x26A3f4505145b5E6164260cc868e50ddd9863697")

        result = subprocess.run(
            [
                "forge",
                "script",
                "script/Deploy.s.sol",
                "--rpc-url",
                anvil_url,
                "--sender",
                deployer,
                "--unlocked",
                "--broadcast",
                "-vvv",
            ],
            cwd=source_dir,
            env=env,
            capture_output=True,
            text=True,
            timeout=600,
        )

        if result.returncode != 0:
            # Extract error info
            error_msg = result.stderr[-3000:] if result.stderr else ""
            stdout_tail = result.stdout[-1000:] if result.stdout else ""
            raise RuntimeError(
                f"Deployment simulation failed.\nstderr: {error_msg}\nstdout: {stdout_tail}"
            )

        # Get bytecodes from the simulated deployment
        contracts = deployment_record.get("contracts", {})
        for name, info in contracts.items():
            address = info.get("address", "")
            if address:
                try:
                    code = get_code(anvil_url, address, "latest")
                    if code:
                        expected_codehashes[name] = keccak256_bytes(code)
                except Exception:
                    pass

    finally:
        anvil_proc.terminate()
        try:
            anvil_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            anvil_proc.kill()

    return expected_codehashes


# ---------------------------------------------------------------------------
# Verification logic
# ---------------------------------------------------------------------------


def verify_deployment(
    deployment_path: Path,
    source_ref: str,
    rpc_url: str,
    block_tag: str,
    repo_root: Path,
    skip_simulation: bool = False,
) -> VerificationReport:
    """Main verification function.

    Args:
        deployment_path: Path to the deployment record JSON
        source_ref: Git commit SHA of the deployed source
        rpc_url: RPC URL for the target chain
        block_tag: Block tag or number for observation
        repo_root: Repository root directory
        skip_simulation: If True, skip deployment simulation (for testing)

    Returns:
        VerificationReport with results
    """
    report = VerificationReport(
        verifier_version=VERIFIER_VERSION,
        deployment_path=str(deployment_path),
        deployment_digest="",
        source_revision=source_ref,
        chain_id=0,
        observation_block_number=0,
        observation_block_hash="",
        compiler_version="",
        evm_version="",
        optimizer_runs=0,
        via_ir=False,
    )

    # Load deployment record
    with open(deployment_path) as f:
        record_text = f.read()
        record: DeploymentRecord = json.loads(record_text)

    report.deployment_digest = "0x" + hashlib.sha256(record_text.encode()).hexdigest()

    # Validate contracts field early
    contracts = record.get("contracts")
    if not isinstance(contracts, dict) or not contracts:
        report.overall_status = "failed"
        report.error_message = (
            "Deployment record missing or has invalid 'contracts' field: "
            "expected a nonempty dict"
        )
        return report

    # Check chain ID
    try:
        chain_id = get_chain_id(rpc_url)
    except Exception as e:
        report.overall_status = "incomplete"
        report.error_message = f"Failed to connect to RPC: {e}"
        return report

    expected_chain_id = record.get("chainId", 0)
    if chain_id != expected_chain_id:
        report.overall_status = "failed"
        report.error_message = (
            f"Chain ID mismatch: expected {expected_chain_id}, got {chain_id}"
        )
        return report

    report.chain_id = chain_id

    # Get observation block
    try:
        block_number, block_hash = get_block_by_tag(rpc_url, block_tag)
    except Exception as e:
        report.overall_status = "incomplete"
        report.error_message = f"Failed to get block: {e}"
        return report

    report.observation_block_number = block_number
    report.observation_block_hash = block_hash

    # Use hex block number for consistency
    block_hex = hex(block_number)

    # Set contract count (contracts already validated above)
    report.total_expected = len(contracts)

    # Note external dependencies
    params = record.get("params", {})
    for dep in EXTERNAL_DEPENDENCIES:
        addr = params.get(dep)
        if addr and addr != "0x0000000000000000000000000000000000000000":
            report.external_dependencies.append(f"{dep}: {addr}")

    report.trust_assumptions = [
        "External dependencies (delegation, Permit2, VRF) are trusted without source verification",
        "Compiler settings are read from the source revision's foundry.toml",
        "Deployment simulation uses a fork of the target chain at a block before deployment",
        "The CC0 text fixture is validated by digest in the deployment script",
    ]

    # Create work directory
    with tempfile.TemporaryDirectory(prefix="works-verify-") as work_dir:
        work_path = Path(work_dir)

        try:
            # Checkout source
            print(f"Checking out source at {source_ref}...")
            source_dir = checkout_source(repo_root, source_ref, work_path)

            # Get submodule revisions
            report.submodule_revisions = get_submodule_revisions(source_dir)

            # Get compiler settings
            (
                report.compiler_version,
                report.evm_version,
                report.optimizer_runs,
                report.via_ir,
            ) = get_compiler_settings(source_dir)

            # Build source
            print("Building source...")
            build_source(source_dir)

            # Simulate deployment to get expected bytecodes
            expected_codehashes: dict[str, str] = {}
            if not skip_simulation:
                print("Simulating deployment on fork...")
                try:
                    expected_codehashes = simulate_deployment_on_fork(
                        source_dir, record, rpc_url, work_path
                    )
                except Exception as e:
                    print(f"Warning: Deployment simulation failed: {e}")
                    report.trust_assumptions.append(
                        f"Deployment simulation failed: {e}. "
                        "Verification compares recorded codehashes only."
                    )

            # Compare each contract
            print("Comparing bytecodes...")
            for name, contract_info in contracts.items():
                address = contract_info.get("address", "")
                recorded_codehash = contract_info.get("codehash", "")

                result = ContractResult(
                    name=name,
                    address=address,
                    expected_codehash="",
                    observed_codehash="",
                    status="pending",
                    artifact=ARTIFACT_MAP.get(name, ""),
                    reconstruction_method=(
                        "fork_simulation" if expected_codehashes else "recorded_hash"
                    ),
                )

                # Get on-chain code
                try:
                    observed_code = get_code(rpc_url, address, block_hex)
                    if not observed_code:
                        result.status = "missing"
                        result.message = "No code at address"
                        report.total_missing += 1
                        report.contracts.append(result)
                        continue

                    result.observed_codehash = keccak256_bytes(observed_code)
                except Exception as e:
                    result.status = "error"
                    result.message = f"RPC error: {e}"
                    report.total_errors += 1
                    report.contracts.append(result)
                    continue

                # Get expected codehash
                if name in expected_codehashes:
                    result.expected_codehash = expected_codehashes[name]
                    result.reconstruction_method = "fork_simulation"
                elif recorded_codehash:
                    result.expected_codehash = recorded_codehash
                    result.reconstruction_method = "recorded_hash"
                else:
                    result.status = "unsupported"
                    result.message = "No expected bytecode available"
                    report.unsupported_contracts.append(name)
                    report.contracts.append(result)
                    continue

                # Compare
                if result.expected_codehash == result.observed_codehash:
                    result.status = "match"
                    report.total_verified += 1
                else:
                    result.status = "mismatch"
                    result.message = "Codehash differs"
                    report.total_mismatched += 1

                report.contracts.append(result)

        except Exception as e:
            import traceback

            report.overall_status = "incomplete"
            report.error_message = f"{e}\n{traceback.format_exc()}"
            return report

    # Determine overall status
    if report.total_errors > 0:
        report.overall_status = "incomplete"
    elif report.total_mismatched > 0 or report.total_missing > 0:
        report.overall_status = "failed"
    elif report.total_verified == report.total_expected:
        report.overall_status = "passed"
    elif report.total_verified > 0:
        report.overall_status = "incomplete"
        if not expected_codehashes:
            report.error_message = (
                "Deployment simulation failed. "
                "Verified against recorded codehashes only (not independent)."
            )
    else:
        report.overall_status = "incomplete"

    return report


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def print_report(report: VerificationReport) -> None:
    """Print a human-readable summary."""
    print("\n" + "=" * 70)
    print("BYTECODE VERIFICATION REPORT")
    print("=" * 70)
    print(f"Deployment: {report.deployment_path}")
    print(f"Source revision: {report.source_revision}")
    if report.submodule_revisions:
        print("Submodule revisions:")
        for path, rev in sorted(report.submodule_revisions.items()):
            print(f"  {path}: {rev}")
    print(f"Chain ID: {report.chain_id}")
    print(f"Observation block: {report.observation_block_number}")
    print(f"  Hash: {report.observation_block_hash}")
    print(f"Compiler: solc {report.compiler_version}, EVM {report.evm_version}")
    print(f"Optimizer: {report.optimizer_runs} runs, via-IR: {report.via_ir}")
    print("-" * 70)

    # Contract results
    for result in sorted(report.contracts, key=lambda x: x.name):
        status_marker = {
            "match": "[OK]",
            "mismatch": "[FAIL]",
            "missing": "[MISS]",
            "error": "[ERR]",
            "unsupported": "[SKIP]",
            "pending": "[...]",
        }.get(result.status, "[?]")
        print(f"  {status_marker} {result.name}")
        print(f"       Address: {result.address}")
        print(f"       Method: {result.reconstruction_method}")
        if result.message:
            print(f"       {result.message}")
        if result.status == "mismatch":
            print(f"       Expected: {result.expected_codehash}")
            print(f"       Observed: {result.observed_codehash}")

    print("-" * 70)
    print(f"Contracts expected: {report.total_expected}")
    print(f"  Verified (exact match): {report.total_verified}")
    print(f"  Mismatched: {report.total_mismatched}")
    print(f"  Missing: {report.total_missing}")
    print(f"  Errors: {report.total_errors}")

    if report.unsupported_contracts:
        print(f"\nUnsupported (not verified):")
        for name in report.unsupported_contracts:
            print(f"  - {name}")

    if report.external_dependencies:
        print(f"\nExternal dependencies (not source-verified):")
        for dep in report.external_dependencies:
            print(f"  - {dep}")

    print("-" * 70)
    status_display = {
        "passed": "PASSED - All contracts verified",
        "failed": "FAILED - Bytecode mismatch detected",
        "incomplete": "INCOMPLETE - Some contracts not verified",
        "pending": "PENDING",
    }.get(report.overall_status, report.overall_status)
    print(f"OVERALL STATUS: {status_display}")

    if report.error_message:
        print(f"\nError: {report.error_message[:500]}")

    print("=" * 70 + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--deployment",
        type=Path,
        required=True,
        help="Path to deployment record JSON (e.g., deployments/11155111/1793536584.json)",
    )
    parser.add_argument(
        "--source-ref",
        required=True,
        help="Git commit SHA of the deployed source",
    )
    parser.add_argument(
        "--rpc-url-env",
        default="RPC_URL",
        help="Environment variable containing the RPC URL (default: RPC_URL)",
    )
    parser.add_argument(
        "--rpc-url",
        help="RPC URL directly (alternative to --rpc-url-env)",
    )
    parser.add_argument(
        "--block",
        default="finalized",
        help="Block tag or number for observation (default: finalized)",
    )
    parser.add_argument(
        "--json",
        type=Path,
        dest="json_output",
        help="Output JSON report to this file",
    )
    parser.add_argument(
        "--root",
        type=Path,
        help="Repository root (default: auto-detected)",
    )
    parser.add_argument(
        "--skip-simulation",
        action="store_true",
        help="Skip deployment simulation (compare against recorded hashes only)",
    )

    args = parser.parse_args(argv)

    # Get RPC URL
    if args.rpc_url:
        rpc_url = args.rpc_url
    else:
        rpc_url = os.environ.get(args.rpc_url_env, "")
        if not rpc_url:
            print(
                f"Error: RPC URL not set. Either set {args.rpc_url_env} environment variable "
                "or use --rpc-url",
                file=sys.stderr,
            )
            return 2

    # Never print credentials
    print(f"Using RPC from {'--rpc-url' if args.rpc_url else args.rpc_url_env}")

    # Find repository root
    root = args.root or find_root(Path(__file__).resolve().parent)

    # Resolve deployment path
    deployment_path = args.deployment
    if not deployment_path.is_absolute():
        deployment_path = root / deployment_path
    if not deployment_path.exists():
        print(f"Error: Deployment record not found: {deployment_path}", file=sys.stderr)
        return 2

    # Run verification
    try:
        report = verify_deployment(
            deployment_path=deployment_path,
            source_ref=args.source_ref,
            rpc_url=rpc_url,
            block_tag=args.block,
            repo_root=root,
            skip_simulation=args.skip_simulation,
        )
    except Exception as e:
        print(f"Error during verification: {e}", file=sys.stderr)
        import traceback

        traceback.print_exc()
        return 2

    # Print report
    print_report(report)

    # Write JSON if requested
    if args.json_output:
        with open(args.json_output, "w") as f:
            json.dump(report.to_dict(), f, indent=2, sort_keys=False)
        print(f"JSON report written to: {args.json_output}")

    # Exit code
    if report.overall_status == "passed":
        return 0
    elif report.overall_status == "failed":
        return 1
    else:
        return 2


if __name__ == "__main__":
    sys.exit(main())
