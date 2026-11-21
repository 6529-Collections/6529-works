"""Tests for the reference keeper (keeper/keeper.py).

Run from the repository root: `python -m unittest keeper.test_keeper` (or
`python keeper/test_keeper.py`).

The unit tests need nothing. The end-to-end tests need `forge` and `anvil` on the PATH: they run
the Foundry fixture keeper/test/KeeperFixture.t.sol once (the whole system deployed with the
committed genesis, a curated two-work package and the artist's signed start requests), load its
state into a fresh anvil node per test, and run the keeper there with `--unlocked` (anvil's own
dev accounts sign; no private key appears anywhere). Without anvil or forge they are skipped,
unless KEEPER_E2E_REQUIRE=1 is set, in which case a missing prerequisite fails (the convention
of tools/content/test_anvil.py).
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
_SPEC = importlib.util.spec_from_file_location("keeper_under_test", HERE / "keeper.py")
k = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = k  # before exec: @dataclass resolves annotations through it
_SPEC.loader.exec_module(k)

REQUIRED = os.environ.get("KEEPER_E2E_REQUIRE") == "1"
DAY = 86400
ZERO = "0x" + "00" * 20


# ------------------------------------------------------------------ unit tests


class EncodingTest(unittest.TestCase):
    def test_SelectorAndTopicUseKeccak(self) -> None:
        self.assertEqual(k.selector("transfer(address,uint256)").hex(), "a9059cbb")
        self.assertEqual(
            k.topic("Transfer(address,address,uint256)"),
            "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
        )

    def test_EncodeStaticAndDynamic(self) -> None:
        # f(uint256 7, bytes 0xabcd): head 7 and offset 0x40, then length 2 and padded data.
        data = k.encode(7, k.blob(bytes.fromhex("abcd")))
        self.assertEqual(
            data.hex(),
            "07".rjust(64, "0") + "40".rjust(64, "0") + "02".rjust(64, "0") + "abcd".ljust(64, "0"),
        )

    def test_RoyaltyPayeesAreSortedByAddress(self) -> None:
        high, low = "0x" + "ff" * 20, "0x" + "01" * 20
        payees = k.payee_list(k.royalty_payees(high, low, 25_000))
        self.assertEqual(payees, [(0, low, 25_000), (0, high, 75_000)])

    def test_DynamicArrayOffsets(self) -> None:
        a, b = k.Dyn(k.word(1)), k.Dyn(k.word(2) + k.word(3))
        out = k.array([a, b], True)
        self.assertEqual(k.w(out, 0), 2)  # length
        self.assertEqual((k.w(out, 1), k.w(out, 2)), (64, 96))  # offsets after the length


class FakeKeeper(k.Keeper):
    """A keeper whose views are a table and whose sends are recorded."""

    def __init__(self, views: dict, logs: dict) -> None:
        names = {n: n for n in ("SplitFactory", "ClaimRouter")}
        super().__init__(rpc=None, c=names, sender=ZERO, cast_signing=[])
        self.c["FeeRecipientVault"] = "0x" + "fe" * 20
        self._views, self._logs, self.sends = views, logs, []
        self._views.setdefault(("MAX_CONTINUE_CLAIMS", None), k.word(8))

    def view(self, contract, signature, *args):
        """The table's answer for (name, last argument), else for (name, None); a callable
        answer is called with the arguments."""
        name = signature.split("(")[0]
        for key in ((name, args[-1] if args else None), (name, None)):
            if key in self._views:
                answer = self._views[key]
                return answer(*args) if callable(answer) else answer
        raise KeyError((name, args))

    def logs(self, contract, sig):
        return self._logs.get(sig.split("(")[0], [])

    def send(self, contract, signature, *args, label):
        self.sends.append((signature.split("(")[0], args))
        return True


def _wallet_log(payees: k.Dyn) -> dict:
    data = k.encode(0, payees)
    return {"topics": ["0x0", "0x" + "00" * 12 + "ab" * 20], "data": "0x" + data.hex()}


class ReleaseRuleTest(unittest.TestCase):
    """The ClaimRouter batch rule: the network's own index is left out when another payee of the
    same wallet and asset is released in the batch, and included when it is the only one due."""

    def _run(self, seller_due: int, network_due: int) -> list[int]:
        seller, network = "0x" + "11" * 20, "0x" + "fe" * 20
        payees = k.royalty_payees(seller, network, 25_000)  # seller first (lower address)
        views = {("releasable", 0): k.word(seller_due), ("releasable", 1): k.word(network_due)}
        keeper = FakeKeeper(views, {"WalletCreated": [_wallet_log(payees)]})
        keeper.step_release()
        if not keeper.sends:
            return []
        (name, (claims, mode)), = keeper.sends
        self.assertEqual((name, mode), ("claim", 1))
        count = k.w(claims, 0)
        # Element i starts at its offset after the length word; a claim is (payees, salt,
        # asset, index), so the index is its fourth head word.
        return [k.w(claims[32 + k.w(claims, 1 + i) :], 3) for i in range(count)]

    def test_LeavesOutTheNetworkWhenTheSellerIsReleased(self) -> None:
        self.assertEqual(self._run(seller_due=3, network_due=1), [0])

    def test_IncludesTheNetworkWhenItIsTheOnlyOneDue(self) -> None:
        self.assertEqual(self._run(seller_due=0, network_due=1), [1])

    def test_NothingDueSendsNothing(self) -> None:
        self.assertEqual(self._run(seller_due=0, network_due=0), [])


class ReleaseBatchTest(unittest.TestCase):
    def test_ContinueModeBatchesStayWithinTheRoutersLimit(self) -> None:
        # Nine wallets, each with its seller due: the router takes at most MAX_CONTINUE_CLAIMS
        # (8) items in continue mode and refuses a larger batch whole.
        payees = k.royalty_payees("0x" + "11" * 20, "0x" + "fe" * 20, 25_000)
        views = {("releasable", 0): k.word(1), ("releasable", 1): k.word(0)}
        keeper = FakeKeeper(views, {"WalletCreated": [_wallet_log(payees)] * 9})
        keeper.step_release()
        self.assertEqual([k.w(claims, 0) for _, (claims, _) in keeper.sends], [8, 1])


class MarkRuleTest(unittest.TestCase):
    """A mark stays recorded after its payee releases up to it: only a mark not yet reached is
    pending (forfeited when mature); a reached one is replaced by a new mark."""

    def _run(self, released: int, now: int) -> list[str]:
        seller, network = "0x" + "11" * 20, "0x" + "fe" * 20
        payees = k.royalty_payees(seller, network, 25_000)  # seller is index 0
        views = {
            ("markOf", 0): k.word(100) + k.word(1_000),  # target 100, marked at t = 1,000
            ("released", 0): k.word(released),
            ("releasable", 0): k.word(5),
        }
        keeper = FakeKeeper(views, {"WalletCreated": [_wallet_log(payees)]})
        keeper.step_marks(now, mark=True)
        return [name for name, _ in keeper.sends]

    def test_AReachedMarkIsReplaced(self) -> None:
        self.assertEqual(self._run(released=100, now=1_000 + k.MARK_EXPIRY), ["mark"])

    def test_APendingMatureMarkIsForfeited(self) -> None:
        self.assertEqual(self._run(released=60, now=1_000 + k.MARK_EXPIRY), ["forfeit"])

    def test_APendingYoungMarkKeepsItsClock(self) -> None:
        self.assertEqual(self._run(released=60, now=1_000 + k.MARK_EXPIRY - 1), [])


def _item(kind: int, content: bytes) -> k.Dyn:
    """A minimal PackageItem encoding: the kind, the content hash and an empty payee list."""
    return k.Dyn(k.encode(kind, 0, content, 0, 0, 0, k.Dyn(k.word(0)), k.Dyn(k.word(0))))


class WorkGuardTest(unittest.TestCase):
    def test_OpenSkipsASaleWhoseWorkIsNotInTheSnapshot(self) -> None:
        # Work 2 was minted (and its record opened) after this run read WorkMinted.
        stream = "0x" + "57" * 20
        sale = {"topics": ["0x0", hex(1), "0x" + "00" * 12 + stream[2:], hex(2)], "data": "0x"}
        keeper = FakeKeeper({}, {"SaleStarted": [sale]})
        keeper.c["Stream"] = stream
        items = {2: (_item(k.EDITION_MASTER, k.word(7)), k.Dyn(b""))}
        keeper.step_open({1: {"root": k.word(0), "content": k.word(9)}}, items)
        self.assertEqual(keeper.sends, [])

    def test_ABurnedWorkDoesNotStopTheVaultsStep(self) -> None:
        # primaryTerms reverts for a burned work (UnknownWork); the later work still gets its vaults.
        def terms(token_id, _data):
            if token_id == 1:
                raise k.Reverted("UnknownWork(1)")
            return k.word(0) * 5 + k.word("0x" + "11" * 20) + k.word("0x" + "fe" * 20) + k.word(25_000)

        views = {("primaryTerms", None): terms, ("walletFor", None): k.word(0x99), ("isWallet", None): k.word(0)}
        keeper = FakeKeeper(views, {})
        works = {t: {"root": k.word(0), "content": k.word(t)} for t in (1, 2)}
        keeper.step_vaults(works, {})
        self.assertEqual([name for name, _ in keeper.sends], ["createWallet"])

    def test_StartFinishesTheNewestWorkWithTheRequestsContent(self) -> None:
        # Work 1 was burned and its content released; work 2 re-minted it, started directly.
        content = k.word(7)
        keeper = FakeKeeper(
            {("consumedItemOf", None): k.word(1), ("isOpen", None): lambda t: k.word(1 if t == 1 else 0)},
            {},
        )
        keeper.starts = [{"name": "r", "content": content, "payees": None, "item": b"", "media": b""}]
        keeper.ensure_vaults = lambda token_id, payees: None
        keeper.step_start({1: {"content": content}, 2: {"content": content}})
        (name, args), = keeper.sends
        self.assertEqual((name, args[0]), ("openRecord", 2))


class SignaturesTest(unittest.TestCase):
    """Every function and event signature the keeper hand-writes is in the exported ABIs (abi/,
    tools/export_abis.py), so a renamed or reshaped function fails here, not on chain."""

    def test_EverySignatureIsInTheExportedAbis(self) -> None:
        spec = importlib.util.spec_from_file_location("export_abis", ROOT / "tools" / "export_abis.py")
        ea = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ea)
        known = set()
        for path in (ROOT / "abi").rglob("*.json"):
            if path.name != "manifest.json":
                known |= {ea.signature(e) for e in json.loads(path.read_text("utf-8")) if "name" in e}
        source = (HERE / "keeper.py").read_text(encoding="utf-8")
        used = set()
        joined = re.sub(r'"\s*\n\s*"', "", source)  # adjacent string literals
        for literal in re.findall(r'"([^"]*)"', joined):
            # f-strings name the shared type strings: {ITEM}, {MEDIA}, {PAYEES}.
            literal = re.sub(r"\{(\w+)\}", lambda m: str(getattr(k, m.group(1), m.group(0))), literal)
            if re.fullmatch(r"[A-Za-z]\w*\(.*\)", literal):
                used.add(literal)
        self.assertGreater(len(used), 25)
        self.assertEqual(sorted(used - known), [])


class RequestTest(unittest.TestCase):
    def _request(self, **extra: str) -> dict:
        proof = k.array([k.word(0xAA), k.word(0xBB)], False)
        body = k.encode(k.word(0x55), _item(k.EDITION_MASTER, k.word(7)), proof, k.blob(b"move"))
        raw = {"mintData": "0x" + k.encode(k.Dyn(body)).hex(), "media": "0x" + k.word(32).hex() + k.word(0).hex()}
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "r.json"
            path.write_text(json.dumps(dict(raw, **extra)), "utf-8")
            return k.load_request(path), proof

    def test_ProofDefaultsToTheOneInMintData(self) -> None:
        request, proof = self._request()
        self.assertEqual(request["proof"], proof)
        self.assertEqual(k.w(request["item"], k.ITEM_KIND), k.EDITION_MASTER)

    def test_AnExplicitProofIsKept(self) -> None:
        empty = k.array([], False)
        request, _ = self._request(proof="0x" + k.encode(empty).hex())
        self.assertEqual(request["proof"], empty)

    def test_TheModuleIsRegisteredUnderItsOwnName(self) -> None:
        # @dataclass resolves Keeper's string annotations through sys.modules[Keeper.__module__];
        # running this file directly (`python keeper/test_keeper.py`) needs that entry.
        self.assertIs(sys.modules[k.Keeper.__module__], k)

    def test_RejectsMintDataNotEncodedAsOneTuple(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "bad.json"
            path.write_text(json.dumps({"mintData": "0x" + k.word(64).hex(), "media": "0x"}), "utf-8")
            with self.assertRaises(SystemExit):
                k.load_request(path)


# ------------------------------------------------------------------ end to end on anvil

_fixture: Path | None = None
_tmp: tempfile.TemporaryDirectory | None = None


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _build_fixture() -> Path:
    """Runs the Foundry fixture once and writes genesis.json, deployment.json and starts/."""
    global _tmp
    _tmp = tempfile.TemporaryDirectory()
    out = Path(_tmp.name)
    env = dict(os.environ, KEEPER_FIXTURE_DIR=out.as_posix())
    run = subprocess.run(
        ["forge", "test", "--match-path", "keeper/test/KeeperFixture.t.sol", "-vv"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
    )
    if run.returncode != 0:
        raise AssertionError("the keeper fixture failed:\n" + run.stdout[-3000:] + run.stderr[-3000:])
    (out / "starts").mkdir()
    record = None
    for name, body in re.findall(r"KEEPER_FIXTURE (\w+) (\{.*\})", run.stdout):
        if name == "deployment":
            record = json.loads(body)
            (out / "deployment.json").write_text(body, encoding="utf-8")
        else:
            (out / "starts" / f"{name}.json").write_text(body, encoding="utf-8")
    state = json.loads((out / "state.json").read_text(encoding="utf-8"))
    genesis = {
        "config": {"chainId": 31337},
        "timestamp": hex(record["timestamp"]),
        "gasLimit": hex(30_000_000),
        "difficulty": "0x0",
        "alloc": state,
    }
    (out / "genesis.json").write_text(json.dumps(genesis), encoding="utf-8")
    return out


def setUpModule() -> None:
    global _fixture
    missing = [tool for tool in ("anvil", "forge", "cast") if shutil.which(tool) is None]
    if missing:
        if REQUIRED:
            raise AssertionError(f"missing on the PATH: {', '.join(missing)}")
        return
    os.environ.setdefault("NO_PROXY", "127.0.0.1")
    _fixture = _build_fixture()


def tearDownModule() -> None:
    if _tmp is not None:
        _tmp.cleanup()


class Chain:
    """A fresh anvil node loaded with the fixture's state, and the test's helpers on it."""

    def __init__(self) -> None:
        port = _free_port()
        self.url = f"http://127.0.0.1:{port}"
        self.node = subprocess.Popen(
            ["anvil", "--port", str(port), "--init", str(_fixture / "genesis.json"),
             "--hardfork", "prague", "--silent"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.rpc = k.Rpc(self.url)
        deadline = time.time() + 30
        while True:
            try:
                self.accounts = self.rpc.request("eth_accounts", [])
                break
            except Exception:  # noqa: BLE001 - still starting
                if time.time() > deadline or self.node.poll() is not None:
                    raise
                time.sleep(0.2)
        record = json.loads((_fixture / "deployment.json").read_text(encoding="utf-8"))
        self.c = {name: v["address"] for name, v in record["contracts"].items()}
        self.keeper_address = self.accounts[1]

    def close(self) -> None:
        self.node.terminate()
        try:
            self.node.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.node.kill()

    def keeper(self, *extra: str, starts: Path | None = None) -> str:
        """Runs the keeper once and returns what it printed."""
        args = [
            "--rpc-url", self.url,
            "--deployment", str(_fixture / "deployment.json"),
            "--from", self.keeper_address,
            "--starts", str(starts or _fixture / "starts"),
        ]
        if "--dry-run" not in extra:
            args.append("--unlocked")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            k.main(args + list(extra))
        return out.getvalue()

    def view(self, contract: str, signature: str, *args) -> bytes:
        return self.rpc.call(self.c[contract], k.call_data(signature, *args))

    def send(self, sender: str, contract: str, signature: str, *args, value: int = 0) -> None:
        data = "0x" + k.call_data(signature, *args).hex()
        tx = {"from": sender, "to": self.c[contract], "data": data, "value": hex(value)}
        receipt = self._mined(self.rpc.request("eth_sendTransaction", [tx]))
        assert receipt["status"] == "0x1", f"{signature} reverted"

    def pay(self, sender: str, to: str, value: int) -> None:
        tx = {"from": sender, "to": to, "value": hex(value)}
        self._mined(self.rpc.request("eth_sendTransaction", [tx]))

    def _mined(self, tx_hash: str) -> dict:
        for _ in range(200):
            receipt = self.rpc.request("eth_getTransactionReceipt", [tx_hash])
            if receipt is not None:
                return receipt
            time.sleep(0.05)
        raise AssertionError("not mined")

    def warp(self, seconds: int) -> None:
        self.rpc.request("evm_increaseTime", [seconds])
        self.rpc.request("evm_mine", [])

    def balance(self, account: str) -> int:
        return int(self.rpc.request("eth_getBalance", [account, "latest"]), 16)

    def block(self) -> int:
        return int(self.rpc.request("eth_blockNumber", []), 16)

    # -------------------------------------------------------------- reads used by the tests

    def sale(self, token_id: int) -> int:
        sig = "saleIdOf(address,uint256)"
        return k.w(self.view("EnglishAuction", sig, self.c["Stream"], token_id), 0)

    def edition_sale(self, token_id: int) -> int:
        sig = "saleIdOf(address,uint256)"
        return k.w(self.view("UniformEditionAuction", sig, self.c["Editions"], token_id), 0)

    def eth_bid(self, bidder: str, token_id: int) -> int:
        sale = self.sale(token_id)
        amount = k.w(self.view("EnglishAuction", "minimumBid(uint256)", sale), 0)
        payment = k.Dyn(k.encode(0, bidder, amount, 0, 0, k.blob(b"")))
        sig = "bid(uint256,address,(uint8,address,uint256,uint256,uint256,bytes))"
        self.send(bidder, "EnglishAuction", sig, sale, ZERO, payment, value=amount)
        return amount


class _E2E(unittest.TestCase):
    def setUp(self) -> None:
        if _fixture is None:
            self.skipTest("anvil, forge or cast is not on the PATH")
        self.chain = Chain()
        self.addCleanup(self.chain.close)


class FullSaleTest(_E2E):
    def test_AFullSaleRunByTheKeeper(self) -> None:
        ch = self.chain
        alice, bob = ch.accounts[2], ch.accounts[3]

        # Run 1: both works start through SaleStarter, with their vaults and records, and the
        # edition master's edition sale opens.
        out = ch.keeper()
        self.assertIn("sent  start start0 through SaleStarter", out)
        self.assertIn("sent  start start1 through SaleStarter", out)
        self.assertIn("sent  open the edition sale of work 1", out)
        for token_id in (1, 2):
            self.assertEqual(k.w(ch.view("WorkRecords", "isOpen(uint256)", token_id), 0), 1)
            terms = ch.view("Stream", "primaryTerms(uint256,bytes)", token_id, k.blob(b""))
            self.assertEqual(k.w(ch.view("SplitFactory", "isWallet(address)", k.a(terms, 5)), 0), 1)
        self.assertIn("done: 0 sent", ch.keeper(), "nothing more is due")

        # Bids: Alice is outbid by Bob on the master's 1/1; both bid for copies.
        first = ch.eth_bid(alice, 1)
        ch.eth_bid(bob, 1)
        ch.eth_bid(alice, 2)
        sale = ch.edition_sale(1)
        for bidder, step, qty in ((alice, 10, 2), (bob, 4, 1)):
            price = k.w(ch.view("UniformEditionAuction", "stepPrice(uint256,uint256)", sale, step), 0)
            sig = "bid(uint256,uint256,uint256)"
            ch.send(bidder, "UniformEditionAuction", sig, sale, step, qty, value=price * qty)

        # Nothing is due before the end.
        self.assertIn("done: 0 sent", ch.keeper())

        # Run 2, after the 1/1s end and the edition close: settle both 1/1s, create the
        # edition, settle the edition sale.
        ch.warp(DAY + 16 * 60)
        out = ch.keeper()
        for line in (
            "settle 1/1 sale of token 1",
            "settle 1/1 sale of token 2",
            "createEdition 1",
            "settle edition sale of edition 1",
        ):
            self.assertIn("sent  " + line, out)
        self.assertEqual(k.a(ch.view("Stream", "ownerOf(uint256)", 1), 0), bob.lower())
        status = k.w(ch.view("UniformEditionAuction", "auction(uint256)", sale), 4)
        self.assertEqual(status, k.EA_SETTLED)
        self.assertIn("done: 0 sent", ch.keeper(), "a second run finds nothing due")

        # A release: a marketplace pays work 1's royalty; the keeper pushes the seller wallet's
        # share through the ClaimRouter, which pays the network its share in the same call,
        # and leaves the network's own index out of the batch.
        receiver = k.a(ch.view("Stream", "royaltyInfo(uint256,uint256)", 1, 10**18), 0)
        ch.pay(alice, receiver, 10**17)
        terms = ch.view("Stream", "primaryTerms(uint256,bytes)", 1, k.blob(b""))
        seller, fee = k.a(terms, 5), self.chain.c["FeeRecipientVault"]
        seller_before, fee_before = ch.balance(seller), ch.balance(fee)
        out = ch.keeper("--release", "--steps", "")
        self.assertIn("sent  push", out)
        self.assertGreater(ch.balance(seller), seller_before)
        self.assertEqual(ch.balance(fee) - fee_before, 10**17 * k.w(terms, 7) // 100_000)
        self.assertEqual(ch.balance(receiver), 0, "the royalty wallet is empty")

        # Credits: Alice's outbid credit, unclaimed for 180 days, goes to the network.
        credit = ch.view("EnglishAuction", "claimable(address,address)", alice, ZERO)
        self.assertEqual(k.w(credit, 0), first)
        ch.warp(181 * DAY)
        out = ch.keeper()
        self.assertIn(f"sent  expire {alice.lower()}'s credit on EnglishAuction", out)
        self.assertEqual(k.w(ch.view("EnglishAuction", "claimable(address,address)", alice, ZERO), 0), 0)

        # Finalize: with --notice the keeper records the notice; 14 days later it finalizes.
        out = ch.keeper("--notice", "--steps", "")
        self.assertIn("sent  record the finalize notice of work 1", out)
        self.assertIn("done: 0 sent", ch.keeper("--steps", "finalize"), "not due yet")
        ch.warp(14 * DAY)
        self.assertIn("sent  finalize work 1", ch.keeper("--steps", "finalize"))
        self.assertEqual(k.w(ch.view("WorkRecords", "record(uint256)", 1), 4), 1, "finalized")

        # Marks: with --mark the keeper marks the artist's unclaimed sale proceeds; 180 days
        # later it forfeits them to the network.
        out = ch.keeper("--mark", "--steps", "")
        self.assertIn("sent  mark payee 0 of", out)
        ch.warp(181 * DAY)
        fee_before = ch.balance(fee)
        self.assertIn("sent  forfeit payee 0 of", ch.keeper("--steps", "forfeit"))
        self.assertGreater(ch.balance(fee), fee_before)


class AlreadyDoneTest(_E2E):
    def _start_directly(self, index: int) -> None:
        raw = json.loads((_fixture / "starts" / f"start{index}.json").read_text("utf-8"))
        mint = bytes.fromhex(raw["mintData"][2:])
        stream, anyone = self.chain.c["Stream"], self.chain.accounts[5]
        self.chain.send(anyone, "EnglishAuction", "start(address,bytes)", stream, k.blob(mint))

    def test_SomeoneStartedFirst(self) -> None:
        ch = self.chain
        self._start_directly(1)  # the original, work 1 on chain: no vaults, no record
        terms = ch.view("Stream", "primaryTerms(uint256,bytes)", 1, k.blob(b""))
        self.assertEqual(k.w(ch.view("SplitFactory", "isWallet(address)", k.a(terms, 5)), 0), 0)
        # The keeper holds only that request: SaleStarter is not tried for it (it would revert);
        # its vaults and record are finished with the permissionless calls instead.
        with tempfile.TemporaryDirectory() as d:
            shutil.copy(_fixture / "starts" / "start1.json", d)
            out = ch.keeper(starts=Path(d))
            self.assertNotIn("start start1", out)
            self.assertIn("sent  createWallet seller vault of work 1", out)
            self.assertIn("sent  createWallet royalty vault of work 1", out)
            self.assertIn("sent  openRecord 1 (started by someone else)", out)
            self.assertEqual(k.w(ch.view("WorkRecords", "isOpen(uint256)", 1), 0), 1)
            self.assertIn("done: 0 sent", ch.keeper(starts=Path(d)))
        # With every request, it starts the other work through SaleStarter as usual.
        self.assertIn("sent  start start0 through SaleStarter", ch.keeper())

    def test_SomeoneElseSettledAndCreated(self) -> None:
        ch = self.chain
        ch.keeper()  # starts both, opens the edition sale
        ch.warp(DAY + 16 * 60)
        stranger = ch.accounts[6]
        ch.send(stranger, "EnglishAuction", "settle(uint256)", ch.sale(1))
        request = k.load_request(_fixture / "starts" / "start0.json")
        ch.send(stranger, "Editions", f"createEdition(uint256,{k.ITEM})", 1, request["item"])
        out = ch.keeper()
        self.assertNotIn("settle 1/1 sale of token 1", out)
        self.assertNotIn("createEdition 1", out)
        self.assertIn("sent  settle 1/1 sale of token 2", out)
        self.assertIn("sent  settle edition sale of edition 1", out)

    def test_RequestWithoutASeparateProofOpensTheEditionSale(self) -> None:
        # start0 is the edition master of a two-item package: its open needs the Merkle proof,
        # which the keeper takes from mintData when the request has no "proof" field.
        raw = json.loads((_fixture / "starts" / "start0.json").read_text("utf-8"))
        self.assertNotEqual(k.load_request(_fixture / "starts" / "start0.json")["proof"], k.array([], False))
        del raw["proof"]
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "start0.json").write_text(json.dumps(raw), "utf-8")
            out = self.chain.keeper(starts=Path(d))
        self.assertIn("sent  open the edition sale of work 1", out)

    def test_DryRunSendsNothing(self) -> None:
        ch = self.chain
        before = ch.block()
        out = ch.keeper("--dry-run")
        self.assertIn("plan  start start0 through SaleStarter", out)
        self.assertEqual(ch.block(), before)
        self.assertEqual(k.w(ch.view("Stream", "totalMinted()"), 0), 0)


if __name__ == "__main__":
    unittest.main()
