"""Unit tests for verify_evidence.py.

Run with `python tools/test_verify_evidence.py` or, from the repository root,
`python -m tools.test_verify_evidence`.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "verify_evidence", Path(__file__).with_name("verify_evidence.py")
)
ve = importlib.util.module_from_spec(_SPEC)
sys.modules["verify_evidence"] = ve
_SPEC.loader.exec_module(ve)


class TestSha256File(unittest.TestCase):
    """Test SHA-256 file hashing."""

    def test_known_hash(self) -> None:
        """Empty file has known SHA-256."""
        with tempfile.NamedTemporaryFile(mode="wb", delete=False) as f:
            f.write(b"")
            path = Path(f.name)

        try:
            result = ve.sha256_file(path)
            # SHA-256 of empty string
            self.assertEqual(
                result,
                "0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            )
        finally:
            path.unlink()

    def test_hello_world(self) -> None:
        """Hello world has known SHA-256."""
        with tempfile.NamedTemporaryFile(mode="wb", delete=False) as f:
            f.write(b"Hello, World!")
            path = Path(f.name)

        try:
            result = ve.sha256_file(path)
            self.assertEqual(
                result,
                "0xdffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f",
            )
        finally:
            path.unlink()


class TestVerifyEvidence(unittest.TestCase):
    """Test VerifyEvidence dataclass."""

    def test_to_dict(self) -> None:
        """Evidence converts to dict with expected structure."""
        evidence = ve.VerifyEvidence(
            tool_version="0.1.0",
            timestamp="2026-11-06T12:00:00+00:00",
            result="passed",
            git_commit="abc123def456",
            git_branch="main",
            submodule_revisions={"lib/forge-std": "abc123"},
            solc_version="0.8.28",
            evm_version="cancun",
            optimizer_runs=200,
            via_ir=True,
            foundry_version="forge 0.2.0",
            deployment_path="deployments/11155111/123.json",
            deployment_sha256="0xabc",
            manifest_path="config/manifest.json",
            manifest_sha256="0xdef",
            chain_id=11155111,
            block_number=12345678,
            block_hash="0x123",
            block_timestamp="2026-11-06T12:00:00+00:00",
            contract_count=24,
            contract_names=["Stream", "Editions"],
        )

        d = evidence.to_dict()

        self.assertEqual(d["tool_version"], "0.1.0")
        self.assertEqual(d["result"], "passed")
        self.assertEqual(d["source"]["git_commit"], "abc123def456")
        self.assertEqual(d["build"]["solc_version"], "0.8.28")
        self.assertEqual(d["inputs"]["chain_id"], 11155111)
        self.assertEqual(d["observation"]["block_number"], 12345678)
        self.assertEqual(d["contracts"]["count"], 24)
        self.assertIn("Editions", d["contracts"]["names"])

    def test_to_dict_is_json_serializable(self) -> None:
        """Evidence dict is JSON serializable."""
        evidence = ve.VerifyEvidence(
            tool_version="0.1.0",
            timestamp="2026-11-06T12:00:00+00:00",
            result="failed",
            git_commit="abc",
            git_branch="main",
            submodule_revisions={},
            solc_version="0.8.28",
            evm_version="cancun",
            optimizer_runs=200,
            via_ir=False,
            foundry_version="forge 0.2.0",
            deployment_path="test.json",
            deployment_sha256="0x123",
            manifest_path="manifest.json",
            manifest_sha256="0x456",
            chain_id=1,
            block_number=1,
            block_hash="0x1",
            block_timestamp="2026-11-06T12:00:00+00:00",
            error_message="Test error",
        )

        # Should not raise
        json_str = json.dumps(evidence.to_dict())
        self.assertIn('"result": "failed"', json_str)
        self.assertIn('"error_message": "Test error"', json_str)


class TestCli(unittest.TestCase):
    """Test CLI argument parsing."""

    def test_missing_rpc_url(self) -> None:
        """Missing RPC URL returns error."""
        import os

        # Ensure env var is not set
        env_backup = os.environ.get("RPC_URL")
        if "RPC_URL" in os.environ:
            del os.environ["RPC_URL"]

        try:
            with tempfile.NamedTemporaryFile(
                mode="w", suffix=".json", delete=False
            ) as f:
                json.dump({"chainId": 1, "contracts": {}}, f)
                deployment = Path(f.name)

            with tempfile.NamedTemporaryFile(
                mode="w", suffix=".json", delete=False
            ) as f:
                json.dump({}, f)
                manifest = Path(f.name)

            try:
                result = ve.main(
                    [
                        "--deployment",
                        str(deployment),
                        "--manifest",
                        str(manifest),
                    ]
                )
                self.assertEqual(result, 2)
            finally:
                deployment.unlink()
                manifest.unlink()
        finally:
            if env_backup is not None:
                os.environ["RPC_URL"] = env_backup

    def test_missing_deployment(self) -> None:
        """Missing deployment file returns error."""
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            json.dump({}, f)
            manifest = Path(f.name)

        try:
            result = ve.main(
                [
                    "--deployment",
                    "/nonexistent/path.json",
                    "--manifest",
                    str(manifest),
                    "--rpc-url",
                    "http://localhost:8545",
                ]
            )
            self.assertEqual(result, 2)
        finally:
            manifest.unlink()


class TestFindRoot(unittest.TestCase):
    """Test repository root finding."""

    def test_finds_root_from_tools(self) -> None:
        """Finds root from tools directory."""
        tools_dir = Path(__file__).parent
        root = ve.find_root(tools_dir)
        self.assertTrue((root / "foundry.toml").exists())

    def test_raises_if_no_foundry_toml(self) -> None:
        """Raises if no foundry.toml found."""
        with tempfile.TemporaryDirectory() as tmpdir:
            with self.assertRaises(SystemExit):
                ve.find_root(Path(tmpdir))


if __name__ == "__main__":
    unittest.main()
