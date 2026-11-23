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
PERIOD = 180 * 86400  # the launch value of Directory.unclaimedPeriod(), as a test input
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
        self._views.setdefault(("unclaimedPeriod", None), k.word(PERIOD))

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
        self.assertEqual(self._run(released=100, now=1_000 + PERIOD), ["mark"])

    def test_APendingMatureMarkIsForfeited(self) -> None:
        self.assertEqual(self._run(released=60, now=1_000 + PERIOD), ["forfeit"])

    def test_APendingYoungMarkKeepsItsClock(self) -> None:
        self.assertEqual(self._run(released=60, now=1_000 + PERIOD - 1), [])

    def test_TheNetworksCurrentPeriodDecides(self) -> None:
        # The period is the network's setting, read on every run: a shorter one forfeits sooner.
        seller, network = "0x" + "11" * 20, "0x" + "fe" * 20
        payees = k.royalty_payees(seller, network, 25_000)
        views = {
            ("markOf", 0): k.word(100) + k.word(1_000),
            ("released", 0): k.word(60),
            ("unclaimedPeriod", None): k.word(10),
        }
        keeper = FakeKeeper(views, {"WalletCreated": [_wallet_log(payees)]})
        keeper.step_marks(1_010, mark=False)
        self.assertEqual([name for name, _ in keeper.sends], ["forfeit"])


def _work(outcome: int = 0, receiver: str = ZERO) -> bytes:
    """`Stream6529.workOf`: eleven words; the outcome is word 6, the royalty receiver word 7."""
    words = [0] * 11
    words[6] = outcome
    words[7] = int(receiver, 16)
    return b"".join(k.word(x) for x in words)


def _facts(opened: bool, finalized: bool = False, on_chain: bool = False) -> bytes:
    """`StreamWorkFacts6529.factsOf`: an offset, then the struct head (opened is word 3)."""
    head = [0, 0, 0, int(opened), int(finalized), int(on_chain)] + [0] * 5
    return k.word(32) + b"".join(k.word(x) for x in head)


class ExpireRuleTest(unittest.TestCase):
    """Only money that has itself waited the unclaimed period in force goes to the network: the
    English auction's `expiresAt`, the edition auction's `creditOf` (total, aged, since) with
    `StreamDirectory6529.unclaimedPeriod()`, and the escrow's `expirableAt`."""

    def _sends(self, aged: int, since: int, now: int, period: int = PERIOD) -> list[str]:
        account = "0x" + "00" * 12 + "ab" * 20
        log = {"topics": ["0x0", account, account], "data": "0x"}
        views = {
            ("unclaimedPeriod", None): k.word(period),
            ("creditOf", None): k.word(5) + k.word(aged) + k.word(since),
            ("expiresAt", None): k.word(since + period if aged else 0),
            ("expirableAt", None): k.word(aged if aged and now >= since + period else 0),
        }
        keeper = FakeKeeper(views, {"Credited": [log]})
        for name in ("EnglishAuction", "UniformEditionAuction", "RevenueEscrow"):
            keeper.c[name] = name
        keeper.step_expire(now)
        return [name for name, _ in keeper.sends]

    def test_AnAgedCreditPastThePeriodExpires(self) -> None:
        sends = self._sends(aged=3, since=1_000, now=1_000 + PERIOD)
        self.assertEqual(sends, ["expireCredit", "expireCredit", "expire"])

    def test_ACreditBeforeThePeriodWaits(self) -> None:
        self.assertEqual(self._sends(aged=3, since=1_000, now=1_000 + PERIOD - 1), [])

    def test_MoneyThatIsNotAgedNeverExpires(self) -> None:
        self.assertEqual(self._sends(aged=0, since=1_000, now=1_000 + 10 * PERIOD), [])

    def test_TheNetworksCurrentPeriodDecides(self) -> None:
        sends = self._sends(aged=3, since=1_000, now=1_010, period=10)
        self.assertEqual(sends, ["expireCredit", "expireCredit", "expire"])

    def test_TheEditionAuctionExpiresInEth(self) -> None:
        account = "0x" + "00" * 12 + "ab" * 20
        views = {("creditOf", None): k.word(5) + k.word(5) + k.word(0)}
        keeper = FakeKeeper(views, {})
        keeper.c["UniformEditionAuction"] = "UniformEditionAuction"
        keeper.logs = lambda contract, sig: (
            [{"topics": ["0x0", account]}] if contract == "UniformEditionAuction" else []
        )
        keeper.step_expire(PERIOD)
        (name, args), = keeper.sends
        self.assertEqual((name, args[1]), ("expireCredit", k.ETH))


class AttestTest(unittest.TestCase):
    def _sends(self, complete: set[int]) -> list[str]:
        media = k.Dyn(k.word(2) + k.word(1) + k.word(0) + k.word(0) + k.word(2) + k.word(0) + k.word(1))
        views = {
            ("factsOf", None): _facts(opened=True),
            ("isComplete", None): lambda f: k.word(int(int.from_bytes(f, "big") in complete)),
        }
        keeper = FakeKeeper(views, {})
        keeper.c["Stream6529"] = "0x" + "57" * 20
        keeper.step_attest({1: {}}, {1: (k.Dyn(b""), media)})
        return [name for name, _ in keeper.sends]

    def test_AttestsEachIncompleteFileFirst(self) -> None:
        self.assertEqual(self._sends(complete={1}), ["attestComplete"])

    def test_MarksTheWorkOnceEveryFileIsComplete(self) -> None:
        self.assertEqual(self._sends(complete={1, 2}), ["markOnChainComplete"])


class RescueReportTest(unittest.TestCase):
    def test_ReportsOnlyOnceTheNetworksRescuePeriodHasPassed(self) -> None:
        minter = "0x" + "aa" * 20
        views = {
            ("rescueDelay", None): k.word(100),
            ("workOf", None): _work(),
            ("minterOf", None): k.word(1) + k.word(1_000),  # removed at t = 1,000
            ("ownerOf", None): k.word(minter),
        }
        works = {1: {"minter": minter}}
        for now, due in ((1_099, False), (1_100, True)):
            keeper = FakeKeeper(dict(views), {})
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                keeper.step_rescues(works, now)
            self.assertEqual("due   rescue of work 1" in out.getvalue(), due, now)
            self.assertEqual(keeper.sends, [])  # never sent: rescue is the network's action

    def test_ABurnedTokenWithNoOutcomeIsSkipped(self) -> None:
        # A sale cancelled after a dispute burns its token: `workOf` still answers with no
        # outcome and `ownerOf` reverts (seen on Sepolia r7). The step goes on to the next work.
        minter = "0x" + "aa" * 20

        def owner_of(token_id):
            if token_id == 1:
                raise k.Reverted("ERC721NonexistentToken(1)")
            return k.word(minter)

        views = {
            ("rescueDelay", None): k.word(100),
            ("workOf", None): _work(),
            ("minterOf", None): k.word(1) + k.word(1_000),
            ("ownerOf", None): owner_of,
        }
        keeper = FakeKeeper(views, {})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            keeper.step_rescues({1: {"minter": minter}, 2: {"minter": minter}}, 1_100)
        self.assertNotIn("due   rescue of work 1", out.getvalue())
        self.assertIn("due   rescue of work 2", out.getvalue())


class AdoptReportTest(unittest.TestCase):
    """An edition the network moved to the edition auction with no sale there is reported; the
    adoption itself is the network's action."""

    def _out(self, moved_to: str, open_already: bool) -> str:
        adapter = "0x" + "ed" * 20
        log = {"topics": ["0x0", hex(7), "0x" + "00" * 32, "0x" + "00" * 12 + moved_to[2:]]}
        keeper = FakeKeeper({("saleIdOf", None): k.word(1)}, {"EditionRebound": [log]})
        keeper.c.update(UniformEditionAuction=adapter, StreamEditions6529="0x" + "e1" * 20)
        keeper.rpc = type("R", (), {"ok": lambda self, to, data, sender: open_already})()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            keeper.step_adopt()
        self.assertEqual(keeper.sends, [])
        return out.getvalue()

    def test_AMovedEditionWithNoSaleIsReported(self) -> None:
        self.assertIn("due   adopt of edition 7", self._out("0x" + "ed" * 20, False))

    def test_AnAdoptedEditionIsNot(self) -> None:
        self.assertEqual(self._out("0x" + "ed" * 20, True), "")

    def test_AnEditionMovedElsewhereIsNot(self) -> None:
        self.assertEqual(self._out("0x" + "99" * 20, False), "")


class RoyaltyVaultTest(unittest.TestCase):
    """A missing royalty vault is deployed when the sale's fee terms derive the work's receiver,
    and only reported otherwise."""

    def _sends(self, derived: bool) -> list[str]:
        seller, fee, receiver = "0x" + "11" * 20, "0x" + "fe" * 20, "0x" + "77" * 20
        views = {
            ("workOf", None): _work(receiver=receiver),
            ("isWallet", None): lambda w: k.word(int(w.lower() == seller)),
            ("saleIdOf", None): k.word(9),
            ("auction", None): k.word(0) * 3 + k.word(25_000),
            ("networkFeeRecipient", None): k.word(fee),
            ("walletFor", None): k.word(receiver if derived else "0x" + "33" * 20),
        }
        keeper = FakeKeeper(views, {})
        keeper.c.update(Stream6529="0x" + "57" * 20, EnglishAuction="ea", EconomicsResolver="er")
        with contextlib.redirect_stdout(io.StringIO()):
            keeper.ensure_vaults(1, None, {"seller": seller})
        return [(name, args[0]) for name, args in keeper.sends]

    def test_ADerivedReceiverIsDeployed(self) -> None:
        payees = k.royalty_payees("0x" + "11" * 20, "0x" + "fe" * 20, 25_000)
        self.assertEqual(self._sends(derived=True), [("createWallet", payees)])

    def test_AReceiverTheTermsDoNotDeriveIsOnlyReported(self) -> None:
        self.assertEqual(self._sends(derived=False), [])


class RecordTest(unittest.TestCase):
    def test_BothRecordShapesAreRead(self) -> None:
        flat = {"chainId": 31337, "Stream6529": "0x" + "57" * 20, "startBlock": 0}
        nested = {"contracts": {"Stream6529": {"address": "0x" + "57" * 20}}}
        self.assertEqual(k.contracts_of(flat), {"Stream6529": "0x" + "57" * 20})
        self.assertEqual(k.contracts_of(nested), {"Stream6529": "0x" + "57" * 20})


def _item(kind: int, content: bytes) -> k.Dyn:
    """A minimal PackageItem encoding: the kind, the content hash and an empty payee list."""
    return k.Dyn(k.encode(kind, 0, content, 0, 0, 0, k.Dyn(k.word(0)), k.Dyn(k.word(0))))


class WorkGuardTest(unittest.TestCase):
    def test_OpenSkipsASaleWhoseWorkIsNotInTheSnapshot(self) -> None:
        # Work 2 was minted (and its record opened) after this run read WorkMinted.
        stream = "0x" + "57" * 20
        sale = {"topics": ["0x0", hex(1), "0x" + "00" * 12 + stream[2:], hex(2)], "data": "0x"}
        keeper = FakeKeeper({}, {"SaleStarted": [sale]})
        keeper.c["Stream6529"] = stream
        items = {2: (_item(k.EDITION_MASTER, k.word(7)), k.Dyn(b""))}
        keeper.step_open({1: {"root": k.word(0), "content": k.word(9)}}, items)
        self.assertEqual(keeper.sends, [])

    def test_ABurnedWorkDoesNotStopTheVaultsStep(self) -> None:
        # workOf reverts for a burned work; the later work still gets its seller vault.
        def work(token_id):
            if token_id == 1:
                raise k.Reverted("ERC721NonexistentToken(1)")
            return _work()

        keeper = FakeKeeper({("workOf", None): work, ("isWallet", None): k.word(0)}, {})
        seller = "0x" + "11" * 20
        works = {t: {"root": k.word(0), "content": k.word(t), "seller": seller} for t in (1, 2)}
        items = {t: (_item(0, k.word(t)), k.Dyn(b"")) for t in (1, 2)}
        keeper.step_vaults(works, items)
        self.assertEqual(keeper.sends, [("createWallet", (k.item_payees(items[2][0]), 0))])

    def test_StartFinishesTheNewestWorkWithTheRequestsContent(self) -> None:
        # Work 1 was burned and its content released; work 2 re-minted it, started directly.
        content = k.word(7)
        keeper = FakeKeeper(
            {
                ("tokenOfContent", None): k.word(2),
                ("workOf", None): _work(),
                ("factsOf", None): lambda _token, t: _facts(opened=t == 1),
            },
            {},
        )
        keeper.c["Stream6529"] = "0x" + "57" * 20
        keeper.starts = [{"name": "r", "content": content, "payees": None, "item": b"", "media": b""}]
        keeper.ensure_vaults = lambda token_id, payees, minted: None
        keeper.step_start({1: {"content": content}, 2: {"content": content}})
        (name, args), = keeper.sends
        self.assertEqual((name, args[1]), ("open", 2))

    def test_ABurnedTokensContentIsStartedAgain(self) -> None:
        # tokenOfContent still names token 1, but it is burned: the request is started anew.
        def work(_t):
            raise k.Reverted("ERC721NonexistentToken(1)")

        keeper = FakeKeeper({("tokenOfContent", None): k.word(1), ("workOf", None): work}, {})
        for name in ("Stream6529", "EnglishAuction", "SaleStarter"):
            keeper.c[name] = "0x" + "57" * 20
        keeper.starts = [
            {"name": "r", "content": k.word(7), "payees": None, "item": b"", "media": k.Dyn(b""),
             "mintData": b""}
        ]
        keeper.step_start({})
        self.assertEqual([name for name, _ in keeper.sends], ["start"])


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
    """Runs the Foundry fixture once and writes genesis.json, deployment.json, chunk1.json and
    starts/."""
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
        elif name.startswith("start"):
            (out / "starts" / f"{name}.json").write_text(body, encoding="utf-8")
        else:
            (out / f"{name}.json").write_text(body, encoding="utf-8")
    if record is None:
        raise AssertionError("the keeper fixture logged no deployment:\n" + run.stdout[-3000:])
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
        self.c = k.contracts_of(record)
        self.network = record["Network"]
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
        return k.w(self.view("EnglishAuction", sig, self.c["Stream6529"], token_id), 0)

    def edition_sale(self, token_id: int) -> int:
        sig = "saleIdOf(address,uint256)"
        return k.w(self.view("UniformEditionAuction", sig, self.c["StreamEditions6529"], token_id), 0)

    def opened(self, token_id: int) -> dict[str, bool]:
        data = self.view("StreamWorkFacts6529", "factsOf(address,uint256)", self.c["Stream6529"], token_id)
        head = data[k.w(data, 0) :]
        return {"opened": bool(k.w(head, 3)), "finalized": bool(k.w(head, 4)),
                "onChain": bool(k.w(head, 5))}

    def seller(self, token_id: int) -> str:
        return k.a(self.view("EnglishAuction", "auction(uint256)", self.sale(token_id)), 2)

    def is_wallet(self, wallet: str) -> bool:
        return k.w(self.view("SplitFactory", "isWallet(address)", wallet), 0) == 1

    def eth_bid(self, bidder: str, token_id: int) -> int:
        sale = self.sale(token_id)
        amount = k.w(self.view("EnglishAuction", "minimumBid(uint256)", sale), 0)
        self.send(bidder, "EnglishAuction", "bid(uint256,address)", sale, bidder, value=amount)
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
        alice, bob, stranger = ch.accounts[2], ch.accounts[3], ch.accounts[6]

        # Run 1: both works start through SaleStarter, with their vaults and records, and the
        # edition master's edition sale opens (creating the edition). Work 1's media is stored;
        # work 2's chunk is not written yet, so only work 1 is marked complete on chain.
        out = ch.keeper()
        self.assertIn("sent  start start0 through SaleStarter", out)
        self.assertIn("sent  start start1 through SaleStarter", out)
        self.assertIn("sent  open the edition sale of work 1", out)
        self.assertIn("sent  mark work 1 complete on chain", out)
        self.assertNotIn("mark work 2 complete", out)
        for token_id in (1, 2):
            self.assertTrue(ch.opened(token_id)["opened"])
            self.assertTrue(ch.is_wallet(ch.seller(token_id)))
            receiver = k.a(ch.view("Stream6529", "workOf(uint256)", token_id), 7)
            self.assertTrue(ch.is_wallet(receiver), "royalty vault deployed by SaleStarter")
        minter = k.a(ch.view("StreamEditions6529", "editionOf(uint256)", 1), 0)
        self.assertEqual(minter, ch.c["UniformEditionAuction"].lower(), "the open created it")
        self.assertIn("done: 0 sent", ch.keeper(), "nothing more is due")

        # The missing chunk arrives; the next run marks work 2 complete.
        chunk = json.loads((_fixture / "chunk1.json").read_text("utf-8"))["data"]
        ch.send(stranger, "ContentStore", "writeChunk(bytes)", k.blob(bytes.fromhex(chunk[2:])))
        self.assertIn("sent  mark work 2 complete on chain", ch.keeper())
        self.assertTrue(ch.opened(2)["onChain"])

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

        # Run 2, after the 1/1s end and the edition close: settle both 1/1s and the edition
        # sale, which seals the edition at the count sold.
        ch.warp(DAY + 16 * 60)
        out = ch.keeper()
        for line in (
            "settle 1/1 sale of token 1",
            "settle 1/1 sale of token 2",
            "settle edition sale of edition 1",
        ):
            self.assertIn("sent  " + line, out)
        self.assertEqual(k.a(ch.view("Stream6529", "ownerOf(uint256)", 1), 0), bob.lower())
        status = k.w(ch.view("UniformEditionAuction", "auction(uint256)", sale), 4)
        self.assertEqual(status, k.EA_SETTLED)
        edition = ch.view("StreamEditions6529", "editionOf(uint256)", 1)
        self.assertEqual((k.w(edition, 1), k.w(edition, 3)), (3, 1), "sealed at three copies")
        self.assertIn("done: 0 sent", ch.keeper(), "a second run finds nothing due")

        # A stranger pushes Alice's edition claim: her copies are minted to her and the
        # difference to the clearing price is credited to her in the edition auction.
        ch.send(stranger, "UniformEditionAuction", "claimBidFor(uint256,uint256)", sale, 1)
        edition_credit = k.w(ch.view("UniformEditionAuction", "creditOf(address)", alice), 0)
        self.assertGreater(edition_credit, 0)

        # A release: a marketplace pays work 1's royalty; the keeper pushes the seller wallet's
        # share through the ClaimRouter, which pays the network its share in the same call,
        # and leaves the network's own index out of the batch.
        receiver = k.a(ch.view("Stream6529", "royaltyInfo(uint256,uint256)", 1, 10**18), 0)
        ch.pay(alice, receiver, 10**17)
        seller, fee = ch.seller(1), ch.c["FeeRecipientVault"]
        fee_share = k.w(ch.view("EnglishAuction", "auction(uint256)", ch.sale(1)), 3)
        seller_before, fee_before = ch.balance(seller), ch.balance(fee)
        out = ch.keeper("--release", "--steps", "")
        self.assertIn("sent  push", out)
        self.assertGreater(ch.balance(seller), seller_before)
        self.assertEqual(ch.balance(fee) - fee_before, 10**17 * fee_share // 100_000)
        self.assertEqual(ch.balance(receiver), 0, "the royalty wallet is empty")

        # Credits: Alice's outbid credit on the 1/1 and her edition refund, unclaimed for the
        # network's unclaimed period, go to the network; the period is read from the chain.
        self.assertEqual(k.w(ch.view("EnglishAuction", "claimable(address)", alice), 0), first)
        period = k.w(ch.view("StreamDirectory6529", "unclaimedPeriod()"), 0)
        ch.warp(period - 2 * DAY)
        self.assertIn("done: 0 sent", ch.keeper("--steps", "expire"), "not due yet")
        ch.warp(2 * DAY)
        out = ch.keeper("--steps", "expire")
        self.assertIn(f"sent  expire {alice.lower()}'s aged credit on EnglishAuction", out)
        self.assertIn(f"sent  expire {alice.lower()}'s aged credit on UniformEditionAuction", out)
        self.assertEqual(k.w(ch.view("EnglishAuction", "claimable(address)", alice), 0), 0)
        self.assertEqual(k.w(ch.view("UniformEditionAuction", "creditOf(address)", alice), 0), 0)

        # Finalize: with --notice the keeper records the notice; after the notice it finalizes.
        out = ch.keeper("--notice", "--steps", "")
        self.assertIn("sent  record the finalize notice of work 1", out)
        self.assertIn("done: 0 sent", ch.keeper("--steps", "finalize"), "not due yet")
        notice = k.w(ch.view("WorkRules", "FINALIZE_NOTICE()"), 0)
        ch.warp(notice)
        self.assertIn("sent  finalize work 1", ch.keeper("--steps", "finalize"))
        self.assertTrue(ch.opened(1)["finalized"])

        # Marks: with --mark the keeper marks the artist's unclaimed sale proceeds; after the
        # unclaimed period it forfeits them to the network.
        out = ch.keeper("--mark", "--steps", "")
        self.assertIn("sent  mark payee 0 of", out)
        ch.warp(period + 1)
        fee_before = ch.balance(fee)
        self.assertIn("sent  forfeit payee 0 of", ch.keeper("--steps", "forfeit"))
        self.assertGreater(ch.balance(fee), fee_before)


class AlreadyDoneTest(_E2E):
    def _start_directly(self, index: int) -> None:
        raw = json.loads((_fixture / "starts" / f"start{index}.json").read_text("utf-8"))
        mint = bytes.fromhex(raw["mintData"][2:])
        stream, anyone = self.chain.c["Stream6529"], self.chain.accounts[5]
        self.chain.send(anyone, "EnglishAuction", "start(address,bytes)", stream, k.blob(mint))

    def test_SomeoneStartedFirst(self) -> None:
        ch = self.chain
        self._start_directly(1)  # the original, work 1 on chain: no vaults, no record
        receiver = k.a(ch.view("Stream6529", "workOf(uint256)", 1), 7)
        self.assertFalse(ch.is_wallet(ch.seller(1)))
        self.assertFalse(ch.is_wallet(receiver))
        # The keeper holds only that request: SaleStarter is not tried for it (it would revert);
        # its vaults and record are finished with the permissionless calls instead.
        with tempfile.TemporaryDirectory() as d:
            shutil.copy(_fixture / "starts" / "start1.json", d)
            out = ch.keeper(starts=Path(d))
            self.assertNotIn("start start1", out)
            self.assertIn("sent  createWallet seller vault of work 1", out)
            self.assertIn("sent  createWallet royalty vault of work 1", out)
            self.assertIn("sent  open the record of work 1 (started by someone else)", out)
            self.assertTrue(ch.opened(1)["opened"])
            self.assertTrue(ch.is_wallet(receiver))
            self.assertIn("done: 0 sent", ch.keeper(starts=Path(d)))
        # With every request, it starts the other work through SaleStarter as usual.
        self.assertIn("sent  start start0 through SaleStarter", ch.keeper())

    def test_SomeoneElseSettled(self) -> None:
        ch = self.chain
        ch.keeper()  # starts both, opens the edition sale
        ch.warp(DAY + 16 * 60)
        stranger = ch.accounts[6]
        ch.send(stranger, "EnglishAuction", "settle(uint256)", ch.sale(1))
        out = ch.keeper()
        self.assertNotIn("settle 1/1 sale of token 1", out)
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
        self.assertEqual(k.w(ch.view("Stream6529", "totalMinted()"), 0), 0)


class NetworkActionsTest(_E2E):
    def test_ARescueIsReportedOnceTheNetworksRescuePeriodHasPassed(self) -> None:
        # The network removes the English auction as a minter while work 1 is unsold in its
        # custody. The keeper reports the rescue (the network's action) only after the
        # network's rescue period, read from the chain, and never sends it.
        ch = self.chain
        ch.keeper("--steps", "start")
        ch.send(ch.network, "Stream6529", "removeMinter(address)", ch.c["EnglishAuction"])
        delay = k.w(ch.view("Stream6529", "rescueDelay()"), 0)
        self.assertNotIn("due   rescue of work 1", ch.keeper("--steps", "rescues"))
        ch.warp(delay)
        out = ch.keeper("--steps", "rescues")
        self.assertIn("due   rescue of work 1", out)
        self.assertIn("done: 0 sent", out)


if __name__ == "__main__":
    unittest.main()
