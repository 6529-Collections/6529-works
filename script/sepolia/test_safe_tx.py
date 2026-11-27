"""Tests of the Safe transaction digest script/sepolia/flows.ps1 has its Safe owners sign.

Run: python -m unittest discover -s script/sepolia -p "test_*.py"

Standard library only. Three things are checked:

1. The vectors. Each expected digest below was answered by `getTransactionHash` of the Sepolia
   network Safe of rounds r5 to r8 (0x54a7...4454, Safe 1.4.1) for a made-up transaction, read
   through two public endpoints on 27 November 2026. An implementation in this file, written
   from EIP-712 and independent of the PowerShell one, reproduces each of them.
2. SafeTx.ps1, when PowerShell and `cast` are installed (skipped otherwise): `Get-SafeTxDigest`
   gives the same digests offline, `Assert-SafeTxDigest` refuses a different answer and
   `Assert-SepoliaChain` refuses another chain ID.
3. flows.ps1 signs the digest it computed and compared, and nothing else, in `Send-Safe`.

Nothing here reads a key, signs or sends.
"""
import re
import shutil
import subprocess
import unittest
from pathlib import Path

import make_record

HERE = Path(__file__).resolve().parent
SAFE = "0x54a769fe591c3F47CF83d30b69e576497CE34454"
ZERO = "0x" + "00" * 20
CHAIN_ID = 11155111
DOMAIN_TYPE = "EIP712Domain(uint256 chainId,address verifyingContract)"
SAFE_TX_TYPE = (
    "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,"
    "uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"
)
# The Safe's `domainSeparator()` on Sepolia.
DOMAIN_SEPARATOR = "0xf2688e3204ad6d3bff83e4d9f93fa2f36ae8a0635d33470687053fa83c98a17d"
# (to, value, data, nonce) -> the Safe's own `getTransactionHash`.
VECTORS = [
    (
        "0x00000000000000000000000000000000000065A9", 0, "0xa503fb3e", 7,
        "0xa1a4efec30dbed38a72aa4de61b9f1e3385fb0c4ce4f3f01277ec3e61500882a",
    ),
    (
        "0x1111111111111111111111111111111111111111", 10**15, "0x", 123456,
        "0x41603ce67bcd4b763c52453d867918048748fdcff8906c93f89999208a650551",
    ),
    (
        "0x2222222222222222222222222222222222222222", 0,
        "0x33c95bb50000000000000000000000003333333333333333333333333333333333333333", 0,
        "0xee538d99faf4e7c90b6e748ec42d4808d80452f92a6c0b92aad444f6f0b8a751",
    ),
]


def keccak(data: bytes) -> bytes:
    return bytes.fromhex(make_record.keccak(data))


def word(value) -> bytes:
    """One ABI word: an address or bytes32 as hex, or a number."""
    if isinstance(value, bytes):
        assert len(value) == 32
        return value
    if isinstance(value, str):
        return bytes.fromhex(value[2:]).rjust(32, b"\x00")
    return value.to_bytes(32, "big")


def domain_separator(chain_id: int, safe: str) -> bytes:
    return keccak(word(keccak(DOMAIN_TYPE.encode())) + word(chain_id) + word(safe))


def digest(safe: str, to: str, value: int, data: str, nonce: int, chain_id: int = CHAIN_ID) -> str:
    """The EIP-712 digest of a Safe transaction with operation 0 and no gas refund."""
    struct = keccak(
        word(keccak(SAFE_TX_TYPE.encode())) + word(to) + word(value)
        + word(keccak(bytes.fromhex(data[2:]))) + word(0) + word(0) + word(0) + word(0)
        + word(ZERO) + word(ZERO) + word(nonce)
    )
    return "0x" + keccak(b"\x19\x01" + domain_separator(chain_id, safe) + struct).hex()


class Reference(unittest.TestCase):
    def test_the_type_hashes_are_the_ones_safetx_ps1_pins(self):
        text = (HERE / "SafeTx.ps1").read_text(encoding="utf-8")
        self.assertIn(f"$SafeDomainTypehash = '0x{keccak(DOMAIN_TYPE.encode()).hex()}'", text)
        self.assertIn(f"$SafeTxTypehash = '0x{keccak(SAFE_TX_TYPE.encode()).hex()}'", text)
        self.assertIn(f"$SepoliaChainId = '{CHAIN_ID}'", text)

    def test_the_domain_separator_is_the_safes(self):
        self.assertEqual("0x" + domain_separator(CHAIN_ID, SAFE).hex(), DOMAIN_SEPARATOR)

    def test_each_vector_is_the_safes_own_transaction_hash(self):
        for to, value, data, nonce, expected in VECTORS:
            self.assertEqual(digest(SAFE, to, value, data, nonce), expected)

    def test_every_field_and_the_chain_change_the_digest(self):
        to, value, data, nonce, expected = VECTORS[0]
        self.assertNotEqual(digest(SAFE, VECTORS[1][0], value, data, nonce), expected)
        self.assertNotEqual(digest(SAFE, to, value + 1, data, nonce), expected)
        self.assertNotEqual(digest(SAFE, to, value, data + "00", nonce), expected)
        self.assertNotEqual(digest(SAFE, to, value, data, nonce + 1), expected)
        self.assertNotEqual(digest(to, to, value, data, nonce), expected)
        self.assertNotEqual(digest(SAFE, to, value, data, nonce, chain_id=1), expected)


def powershell():
    return shutil.which("pwsh") or shutil.which("powershell")


@unittest.skipUnless(powershell() and shutil.which("cast"), "needs PowerShell and cast")
class SafeTxPs1(unittest.TestCase):
    def run_ps(self, command: str) -> subprocess.CompletedProcess:
        script = f"$ErrorActionPreference = 'Stop'; . '{HERE / 'SafeTx.ps1'}'; {command}"
        return subprocess.run(
            [powershell(), "-NoProfile", "-NonInteractive", "-Command", script],
            capture_output=True, text=True, timeout=300, check=False,
        )

    def test_the_digest_computed_offline_is_each_vector(self):
        for to, value, data, nonce, expected in VECTORS:
            done = self.run_ps(f"Get-SafeTxDigest '{SAFE}' '{to}' '{value}' '{data}' '{nonce}'")
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(done.stdout.strip(), expected)

    def test_an_input_that_is_not_what_it_should_be_is_refused(self):
        to, value, data, nonce, _ = VECTORS[0]
        for command in (
            f"Get-SafeTxDigest 'safe' '{to}' '{value}' '{data}' '{nonce}'",
            f"Get-SafeTxDigest '{SAFE}' '{to}' '0x10' '{data}' '{nonce}'",
            f"Get-SafeTxDigest '{SAFE}' '{to}' '{value}' 'a503fb3e' '{nonce}'",
            f"Get-SafeTxDigest '{SAFE}' '{to}' '{value}' '{data}' ''",
        ):
            self.assertNotEqual(self.run_ps(command).returncode, 0, command)

    def test_a_different_answer_from_the_endpoint_is_refused(self):
        local = VECTORS[0][4]
        same = self.run_ps(f"Assert-SafeTxDigest '{local}' '{local.upper().replace('0X', '0x')}'; 'signed'")
        self.assertEqual(same.returncode, 0, same.stderr)
        self.assertEqual(same.stdout.strip(), "signed")
        for remote in (VECTORS[1][4], "0x", "", local[:-2]):
            other = self.run_ps(f"Assert-SafeTxDigest '{local}' '{remote}'; 'signed'")
            self.assertNotEqual(other.returncode, 0, remote)
            self.assertNotIn("signed", other.stdout)
            self.assertIn("nothing is signed", other.stderr + other.stdout)

    def test_another_chain_is_refused(self):
        self.assertEqual(self.run_ps(f"Assert-SepoliaChain '{CHAIN_ID}'; 'ok'").stdout.strip(), "ok")
        for chain in ("1", "31337", "", "0xaa36a7"):
            done = self.run_ps(f"Assert-SepoliaChain '{chain}'; 'ok'")
            self.assertNotEqual(done.returncode, 0, chain)
            self.assertNotIn("ok", done.stdout)


class FlowsScript(unittest.TestCase):
    """`Send-Safe` signs the digest it computed and compared, after the chain check."""

    def setUp(self):
        text = (HERE / "flows.ps1").read_text(encoding="utf-8")
        match = re.search(r"\nfunction Send-Safe\(.*?\n}\n", text, re.S)
        self.assertIsNotNone(match)
        self.body = match.group(0)
        self.text = text

    def test_the_helper_is_loaded(self):
        self.assertIn(". (Join-Path $PSScriptRoot 'SafeTx.ps1')", self.text)

    def test_the_order_is_chain_digest_compare_sign(self):
        steps = [
            "Confirm-Chain",
            "$digest = Get-SafeTxDigest $Safe $To $Value $Calldata $nonce",
            "Assert-SafeTxDigest $digest $remote",
            "'wallet', 'sign', '--no-hash', $digest",
        ]
        positions = [self.body.find(step) for step in steps]
        self.assertNotIn(-1, positions, positions)
        self.assertEqual(positions, sorted(positions))

    def test_only_the_local_digest_is_signed(self):
        signed = re.findall(r"'sign', '--no-hash', (\$\w+)", self.body)
        self.assertEqual(signed, ["$digest"])
        self.assertEqual(self.body.count("$digest ="), 1)

    def test_every_signing_or_sending_function_checks_the_chain_first(self):
        for name in ("New-Signature", "Send-Planned", "Send-Safe", "Send-Broadcast"):
            match = re.search(rf"\nfunction {name}\(.*?\n}}\n", self.text, re.S)
            self.assertIsNotNone(match, name)
            body = match.group(0)
            self.assertIn("Confirm-Chain", body, name)
            self.assertLess(body.find("Confirm-Chain"), body.find("Invoke-Signed"), name)


if __name__ == "__main__":
    unittest.main()
