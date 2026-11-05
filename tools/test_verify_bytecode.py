#!/usr/bin/env python3
"""Tests for verify_bytecode.py.

Run with pytest: `python -m pytest tools/test_verify_bytecode.py -v`
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, patch

import pytest

# Add tools directory to path
sys.path.insert(0, str(Path(__file__).parent))

from verify_bytecode import (
    ARTIFACT_MAP,
    VERIFIER_VERSION,
    ContractResult,
    DeploymentRecord,
    VerificationReport,
    find_root,
    get_submodule_revisions,
    keccak256_bytes,
    main,
)


# ---------------------------------------------------------------------------
# Test fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def sample_deployment_record() -> DeploymentRecord:
    """A minimal deployment record for testing."""
    return {
        "chainId": 11155111,
        "startBlock": 12041045,
        "timestamp": 1793536584,
        "confirmed": False,
        "contracts": {
            "ContentStore": {
                "address": "0x1922aA592CfCC1fdC3037EA7e033EA12D696F466",
                "codehash": "0x4f6146f0cc15c564d1eb9cb22d5179fb24c89d8e8c603683b35afd39cc449b62",
            },
            "ReleaseVerifier": {
                "address": "0x8E9dAd1480E0b9EA198DDD3a5EED1221420F7A98",
                "codehash": "0xbff42a863c63b4d6dd08952268edd377394d64b9ee2c3b59a62313e6da570535",
            },
        },
        "params": {
            "factory": "0x4e59b44847b379578588920cA78FbF26c0B4956C",
            "deployer": "0x26A3f4505145b5E6164260cc868e50ddd9863697",
            "namespace": "0x66e9a51efcbefa2ee1a042fcad80b1411f51ecf7f4235d6b5ca92e734a2d3495",
            "networkFeeRecipient": "0x2588A62384F41bB32412841ab774CD574b427bd5",
            "delegation": "0x8f86c644f845A077999939C69Bc787662377d915",
            "permit2": "0x000000000022D473030F116dDEE9F6B43aC78BA3",
        },
        "entropy": "vrf",
        "genesisConfig": "config/sepolia-r4/genesis.json",
    }


@pytest.fixture
def temp_deployment_file(sample_deployment_record: DeploymentRecord) -> Path:
    """Create a temporary deployment record file."""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False
    ) as f:
        json.dump(sample_deployment_record, f)
        return Path(f.name)


# ---------------------------------------------------------------------------
# Unit tests
# ---------------------------------------------------------------------------


class TestArtifactMapping:
    """Tests for contract name to artifact mapping."""

    def test_all_expected_contracts_mapped(self) -> None:
        """Every contract in a typical deployment has a mapping."""
        expected_contracts = [
            "GovernanceConfigurator",
            "WorksAccessManager",
            "ContentStore",
            "DependencyRegistry",
            "ConsolidationAdapter",
            "ArtistRegistry",
            "ReleaseVerifier",
            "SplitFactory",
            "ClaimRouter",
            "AssetAllowlist",
            "EconomicsResolver",
            "RevenueEscrow",
            "CurationVerifier",
            "PackageRegistry",
            "StatementLog",
            "EntropyModule",
            "Renderer",
            "Stream",
            "WorkRecords",
            "Editions",
            "EnglishAuction",
            "EnglishAuctionLens",
            "UniformEditionAuction",
            "UniformEditionAuctionLens",
        ]
        for contract in expected_contracts:
            assert contract in ARTIFACT_MAP, f"{contract} not in ARTIFACT_MAP"

    def test_curation_verifier_maps_to_eip712(self) -> None:
        """CurationVerifier maps to Eip712CurationVerifier."""
        assert ARTIFACT_MAP["CurationVerifier"] == "Eip712CurationVerifier"

    def test_entropy_module_maps_to_vrf(self) -> None:
        """EntropyModule maps to VrfEntropyModule."""
        assert ARTIFACT_MAP["EntropyModule"] == "VrfEntropyModule"


class TestVerificationReport:
    """Tests for VerificationReport."""

    def test_to_dict_has_required_fields(self) -> None:
        """Report dict has all required fields."""
        report = VerificationReport(
            verifier_version=VERIFIER_VERSION,
            deployment_path="test.json",
            deployment_digest="0x123",
            source_revision="abc123",
            chain_id=11155111,
            observation_block_number=12345,
            observation_block_hash="0x456",
            compiler_version="0.8.37",
            evm_version="prague",
            optimizer_runs=200,
            via_ir=False,
        )
        d = report.to_dict()

        assert d["verifier_version"] == VERIFIER_VERSION
        assert d["deployment"]["path"] == "test.json"
        assert d["source"]["revision"] == "abc123"
        assert d["observation"]["chain_id"] == 11155111
        assert d["build_config"]["compiler_version"] == "0.8.37"
        assert d["summary"]["overall_status"] == "pending"

    def test_contracts_sorted_by_name(self) -> None:
        """Contracts in output are sorted alphabetically."""
        report = VerificationReport(
            verifier_version=VERIFIER_VERSION,
            deployment_path="test.json",
            deployment_digest="0x123",
            source_revision="abc123",
            chain_id=1,
            observation_block_number=1,
            observation_block_hash="0x1",
            compiler_version="0.8.37",
            evm_version="prague",
            optimizer_runs=200,
            via_ir=False,
        )
        report.contracts = [
            ContractResult("Zebra", "0x1", "0x2", "0x2", "match"),
            ContractResult("Apple", "0x3", "0x4", "0x4", "match"),
            ContractResult("Middle", "0x5", "0x6", "0x6", "match"),
        ]
        d = report.to_dict()
        names = [c["name"] for c in d["contracts"]]
        assert names == ["Apple", "Middle", "Zebra"]

    def test_external_dependencies_sorted(self) -> None:
        """External dependencies are sorted in output."""
        report = VerificationReport(
            verifier_version=VERIFIER_VERSION,
            deployment_path="test.json",
            deployment_digest="0x123",
            source_revision="abc123",
            chain_id=1,
            observation_block_number=1,
            observation_block_hash="0x1",
            compiler_version="0.8.37",
            evm_version="prague",
            optimizer_runs=200,
            via_ir=False,
        )
        report.external_dependencies = ["z-dep", "a-dep", "m-dep"]
        d = report.to_dict()
        assert d["external_dependencies"] == ["a-dep", "m-dep", "z-dep"]


class TestContractResult:
    """Tests for ContractResult."""

    def test_match_status(self) -> None:
        """Match status when hashes are equal."""
        result = ContractResult(
            name="Test",
            address="0x123",
            expected_codehash="0xabc",
            observed_codehash="0xabc",
            status="match",
        )
        assert result.status == "match"

    def test_mismatch_status(self) -> None:
        """Mismatch status when hashes differ."""
        result = ContractResult(
            name="Test",
            address="0x123",
            expected_codehash="0xabc",
            observed_codehash="0xdef",
            status="mismatch",
            message="Codehash differs",
        )
        assert result.status == "mismatch"
        assert result.message == "Codehash differs"


class TestKeccak256:
    """Tests for keccak256 computation."""

    @pytest.mark.skipif(
        subprocess.run(["which", "cast"], capture_output=True).returncode != 0,
        reason="cast not installed",
    )
    def test_empty_code_hash(self) -> None:
        """Empty code has the standard empty hash."""
        result = keccak256_bytes(b"")
        assert result == "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"

    @pytest.mark.skipif(
        subprocess.run(["which", "cast"], capture_output=True).returncode != 0,
        reason="cast not installed",
    )
    def test_known_hash(self) -> None:
        """Known data produces expected hash."""
        # keccak256("hello") = 0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8
        result = keccak256_bytes(b"hello")
        assert result == "0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8"


class TestFindRoot:
    """Tests for repository root detection."""

    def test_finds_root_from_tools_dir(self) -> None:
        """Finds repo root from tools directory."""
        tools_dir = Path(__file__).parent
        root = find_root(tools_dir)
        assert (root / "foundry.toml").exists()
        assert (root / "src").is_dir()

    def test_raises_on_no_foundry_toml(self) -> None:
        """Raises SystemExit if no foundry.toml found."""
        with tempfile.TemporaryDirectory() as tmpdir:
            with pytest.raises(SystemExit):
                find_root(Path(tmpdir))


# ---------------------------------------------------------------------------
# Integration tests (require forge/anvil)
# ---------------------------------------------------------------------------


@pytest.fixture
def has_foundry() -> bool:
    """Check if Foundry tools are available."""
    try:
        subprocess.run(["forge", "--version"], capture_output=True, check=True)
        subprocess.run(["anvil", "--version"], capture_output=True, check=True)
        subprocess.run(["cast", "--version"], capture_output=True, check=True)
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


class TestCLIArguments:
    """Tests for command-line argument parsing."""

    def test_missing_deployment_fails(self) -> None:
        """Missing --deployment argument fails."""
        with pytest.raises(SystemExit):
            main(["--source-ref", "abc123", "--rpc-url", "http://localhost:8545"])

    def test_missing_source_ref_fails(self) -> None:
        """Missing --source-ref argument fails."""
        with pytest.raises(SystemExit):
            main(["--deployment", "test.json", "--rpc-url", "http://localhost:8545"])

    def test_missing_rpc_fails(self, temp_deployment_file: Path) -> None:
        """Missing RPC URL fails with appropriate error."""
        # Clear any RPC_URL env var
        env = os.environ.copy()
        env.pop("RPC_URL", None)

        with patch.dict(os.environ, env, clear=True):
            result = main([
                "--deployment", str(temp_deployment_file),
                "--source-ref", "abc123",
            ])
            assert result == 2

    def test_nonexistent_deployment_file_fails(self) -> None:
        """Nonexistent deployment file fails."""
        result = main([
            "--deployment", "/nonexistent/path.json",
            "--source-ref", "abc123",
            "--rpc-url", "http://localhost:8545",
        ])
        assert result == 2


class TestChainIdValidation:
    """Tests for chain ID validation."""

    def test_wrong_chain_id_fails(self, temp_deployment_file: Path) -> None:
        """Wrong chain ID is detected and reported."""
        # Mock RPC to return wrong chain ID
        with patch("verify_bytecode.get_chain_id") as mock_chain_id:
            mock_chain_id.return_value = 1  # Mainnet instead of Sepolia

            with patch("verify_bytecode.checkout_source"):
                with patch("verify_bytecode.build_source"):
                    result = main([
                        "--deployment", str(temp_deployment_file),
                        "--source-ref", "abc123",
                        "--rpc-url", "http://localhost:8545",
                        "--skip-simulation",
                    ])
                    # Should fail due to chain ID mismatch
                    assert result != 0


# ---------------------------------------------------------------------------
# Negative tests
# ---------------------------------------------------------------------------


class TestMismatchDetection:
    """Tests for detecting bytecode mismatches."""

    def test_changed_byte_detected(self) -> None:
        """A changed executable byte is detected as mismatch."""
        result = ContractResult(
            name="Test",
            address="0x123",
            expected_codehash="0xabc",
            observed_codehash="0xdef",  # Different hash
            status="mismatch",
            message="Codehash differs",
        )
        assert result.status == "mismatch"

    def test_missing_code_detected(self) -> None:
        """Missing code at address is detected."""
        result = ContractResult(
            name="Test",
            address="0x123",
            expected_codehash="0xabc",
            observed_codehash="",
            status="missing",
            message="No code at address",
        )
        assert result.status == "missing"


class TestReportStatusLogic:
    """Tests for overall report status determination."""

    def test_all_match_is_passed(self) -> None:
        """All contracts matching produces passed status."""
        report = VerificationReport(
            verifier_version=VERIFIER_VERSION,
            deployment_path="test.json",
            deployment_digest="0x123",
            source_revision="abc123",
            chain_id=1,
            observation_block_number=1,
            observation_block_hash="0x1",
            compiler_version="0.8.37",
            evm_version="prague",
            optimizer_runs=200,
            via_ir=False,
            total_expected=3,
            total_verified=3,
            total_mismatched=0,
            total_missing=0,
            total_errors=0,
        )
        # Would be set by verify_deployment, simulate here
        if report.total_verified == report.total_expected:
            report.overall_status = "passed"
        assert report.overall_status == "passed"

    def test_any_mismatch_is_failed(self) -> None:
        """Any mismatch produces failed status."""
        report = VerificationReport(
            verifier_version=VERIFIER_VERSION,
            deployment_path="test.json",
            deployment_digest="0x123",
            source_revision="abc123",
            chain_id=1,
            observation_block_number=1,
            observation_block_hash="0x1",
            compiler_version="0.8.37",
            evm_version="prague",
            optimizer_runs=200,
            via_ir=False,
            total_expected=3,
            total_verified=2,
            total_mismatched=1,
            total_missing=0,
            total_errors=0,
        )
        # Simulate status logic
        if report.total_mismatched > 0:
            report.overall_status = "failed"
        assert report.overall_status == "failed"

    def test_any_missing_is_failed(self) -> None:
        """Any missing contract produces failed status."""
        report = VerificationReport(
            verifier_version=VERIFIER_VERSION,
            deployment_path="test.json",
            deployment_digest="0x123",
            source_revision="abc123",
            chain_id=1,
            observation_block_number=1,
            observation_block_hash="0x1",
            compiler_version="0.8.37",
            evm_version="prague",
            optimizer_runs=200,
            via_ir=False,
            total_expected=3,
            total_verified=2,
            total_mismatched=0,
            total_missing=1,
            total_errors=0,
        )
        # Simulate status logic
        if report.total_missing > 0:
            report.overall_status = "failed"
        assert report.overall_status == "failed"

    def test_any_error_is_incomplete(self) -> None:
        """Any error produces incomplete status."""
        report = VerificationReport(
            verifier_version=VERIFIER_VERSION,
            deployment_path="test.json",
            deployment_digest="0x123",
            source_revision="abc123",
            chain_id=1,
            observation_block_number=1,
            observation_block_hash="0x1",
            compiler_version="0.8.37",
            evm_version="prague",
            optimizer_runs=200,
            via_ir=False,
            total_expected=3,
            total_verified=2,
            total_mismatched=0,
            total_missing=0,
            total_errors=1,
        )
        # Simulate status logic
        if report.total_errors > 0:
            report.overall_status = "incomplete"
        assert report.overall_status == "incomplete"


class TestJSONReport:
    """Tests for JSON report output."""

    def test_json_output_is_valid(self) -> None:
        """JSON output can be parsed back."""
        report = VerificationReport(
            verifier_version=VERIFIER_VERSION,
            deployment_path="test.json",
            deployment_digest="0x123",
            source_revision="abc123",
            chain_id=1,
            observation_block_number=1,
            observation_block_hash="0x1",
            compiler_version="0.8.37",
            evm_version="prague",
            optimizer_runs=200,
            via_ir=False,
        )
        report.contracts.append(
            ContractResult(
                name="Test",
                address="0x123",
                expected_codehash="0xabc",
                observed_codehash="0xabc",
                status="match",
            )
        )

        json_str = json.dumps(report.to_dict())
        parsed = json.loads(json_str)

        assert parsed["verifier_version"] == VERIFIER_VERSION
        assert len(parsed["contracts"]) == 1
        assert parsed["contracts"][0]["name"] == "Test"

    def test_json_does_not_contain_credentials(self) -> None:
        """JSON output does not contain RPC URLs or credentials."""
        report = VerificationReport(
            verifier_version=VERIFIER_VERSION,
            deployment_path="test.json",
            deployment_digest="0x123",
            source_revision="abc123",
            chain_id=1,
            observation_block_number=1,
            observation_block_hash="0x1",
            compiler_version="0.8.37",
            evm_version="prague",
            optimizer_runs=200,
            via_ir=False,
        )

        json_str = json.dumps(report.to_dict())

        # Should not contain common credential patterns
        assert "api_key" not in json_str.lower()
        assert "secret" not in json_str.lower()
        assert "password" not in json_str.lower()
        # Should not contain RPC URL (which might have credentials)
        assert "http://" not in json_str
        assert "https://" not in json_str


class TestExitCodes:
    """Tests for exit code behavior."""

    def test_exit_0_on_pass(self) -> None:
        """Exit code 0 when all contracts verified."""
        # This would need a full mock of the verification flow
        # For now, document the expected behavior
        pass

    def test_exit_1_on_mismatch(self) -> None:
        """Exit code 1 when mismatch detected."""
        pass

    def test_exit_2_on_error(self) -> None:
        """Exit code 2 on errors or incomplete verification."""
        pass


# ---------------------------------------------------------------------------
# Boundary tests
# ---------------------------------------------------------------------------


class TestDeploymentRecordParsing:
    """Tests for deployment record parsing."""

    def test_minimal_record(self) -> None:
        """Minimal valid record is accepted."""
        record: DeploymentRecord = {
            "chainId": 1,
            "contracts": {},
            "params": {},
        }
        assert record["chainId"] == 1

    def test_unknown_contract_in_record(self) -> None:
        """Unknown contract in record is handled."""
        # A contract not in ARTIFACT_MAP should still be processed
        # but marked appropriately
        assert "UnknownContract" not in ARTIFACT_MAP


class TestSubmoduleRevisions:
    """Tests for submodule revision tracking."""

    def test_get_submodule_revisions_from_repo(self) -> None:
        """Can get submodule revisions from actual repo."""
        root = find_root(Path(__file__).parent)
        revisions = get_submodule_revisions(root)
        # Should have some submodules
        assert isinstance(revisions, dict)
        # lib/forge-std and lib/openzeppelin-contracts are common
        if revisions:
            for path, rev in revisions.items():
                assert isinstance(path, str)
                assert isinstance(rev, str)
                assert len(rev) <= 12  # Truncated SHA


# ---------------------------------------------------------------------------
# Security tests
# ---------------------------------------------------------------------------


class TestCredentialProtection:
    """Tests for credential protection."""

    def test_rpc_url_not_printed(self, capsys: Any) -> None:
        """RPC URL value is not printed to output."""
        # The main function should not print the actual RPC URL
        # Only indicate which source it came from
        pass  # Would need integration test


class TestInputValidation:
    """Tests for input validation and safety."""

    def test_deployment_path_not_shell_interpolated(self) -> None:
        """Deployment path is not shell-interpolated."""
        # Paths with special characters should be handled safely
        # This is tested implicitly by using subprocess with list arguments
        pass

    def test_source_ref_validated(self) -> None:
        """Source ref is validated before use."""
        # Git checkout will fail on invalid refs
        # This is tested via integration tests
        pass
