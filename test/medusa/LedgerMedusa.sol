// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { StreamDirectory6529 } from "../../src/core/StreamDirectory6529.sol";
import { GovernedVault } from "../../src/economics/GovernedVault.sol";
import { IReleaseVerifier } from "../../src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitWallet } from "../../src/economics/interfaces/ISplitWallet.sol";
import { IArtistPayoutResolver } from "../../src/economics/interfaces/IArtistPayoutResolver.sol";
import { RevenueEscrow } from "../../src/economics/RevenueEscrow.sol";
import { SplitLedger } from "../../src/economics/SplitLedger.sol";
import { SplitVault } from "../../src/economics/SplitVault.sol";
import { Actor, Gate, MedusaBase, PlainToken } from "./MedusaBase.sol";

/// @dev The harness's own model of the escrow's expiry windows (ECO-45), window by window, under
///      an unclaimed period the network may change at any time (zero allowed). The escrow looks
///      at an account's windows only when it writes them (a deposit, a recovery to it, an expiry)
///      or when asked (`expirableAt`), each time under the period then in force: a closed window
///      whose last credit is a period old is aged, and stays aged whatever the period becomes;
///      the open window closes a period after it opened. Should the open window close while an
///      older closed window is not yet aged (the period grew), the two become one, due a period
///      after the later last credit. A credit joins the open window, or opens a new one.
library MedusaWindows {
    struct Window {
        uint256 amount;
        uint256 openedAt;
        uint256 lastAt;
        bool closed;
        bool aged;
    }

    struct Book {
        Window[] list;
    }

    /// The windows as the escrow sees them at `t` under `period`, without writing them.
    function rolled(Book storage b, uint256 t, uint256 period)
        internal
        view
        returns (Window[] memory ws)
    {
        uint256 n = b.list.length;
        ws = new Window[](n);
        for (uint256 i; i < n; ++i) {
            ws[i] = b.list[i];
        }
        for (uint256 i; i < n; ++i) {
            Window memory w = ws[i];
            if (w.closed && !w.aged && w.amount != 0 && t >= w.lastAt + period) w.aged = true;
        }
        if (n == 0) return ws;
        Window memory last = ws[n - 1];
        if (!last.closed && last.amount != 0 && t >= last.openedAt + period) {
            last.closed = true;
            for (uint256 i; i + 1 < n; ++i) {
                Window memory w = ws[i];
                if (w.closed && !w.aged && w.amount != 0) {
                    last.amount += w.amount;
                    if (w.openedAt < last.openedAt) last.openedAt = w.openedAt;
                    w.amount = 0;
                }
            }
            if (t >= last.lastAt + period) last.aged = true;
        }
    }

    /// The escrow writes the account's credit at `t`: the windows are aged as seen then.
    function roll(Book storage b, uint256 t, uint256 period) internal {
        Window[] memory ws = rolled(b, t, period);
        for (uint256 i; i < ws.length; ++i) {
            b.list[i] = ws[i];
        }
    }

    function credit(Book storage b, uint256 value, uint256 t, uint256 period) internal {
        roll(b, t, period);
        uint256 n = b.list.length;
        if (n != 0 && !b.list[n - 1].closed && b.list[n - 1].amount != 0) {
            b.list[n - 1].amount += value;
            b.list[n - 1].lastAt = t;
        } else {
            b.list.push(Window(value, t, t, false, false));
        }
    }

    /// What may move to the network at `t` under `period`.
    function expirable(Book storage b, uint256 t, uint256 period)
        internal
        view
        returns (uint256 sum)
    {
        Window[] memory ws = rolled(b, t, period);
        for (uint256 i; i < ws.length; ++i) {
            if (ws[i].aged) sum += ws[i].amount;
        }
    }

    /// The credit of every window that opened at least two periods before `t`, counting only
    /// windows opened after the period last changed: under one period, its last credit came
    /// within a period of its opening, so all of it must be expirable by `t`.
    function veryOld(Book storage b, uint256 t, uint256 period, uint256 changedAt)
        internal
        view
        returns (uint256 sum)
    {
        for (uint256 i; i < b.list.length; ++i) {
            Window storage w = b.list[i];
            if (w.openedAt >= changedAt && w.openedAt + 2 * period <= t) sum += w.amount;
        }
    }

    /// `expire` at `t`: every aged window's credit leaves; returns it.
    function expire(Book storage b, uint256 t, uint256 period) internal returns (uint256 sum) {
        roll(b, t, period);
        for (uint256 i; i < b.list.length; ++i) {
            if (b.list[i].aged) {
                sum += b.list[i].amount;
                b.list[i].amount = 0;
            }
        }
    }

    function takeAll(Book storage b) internal {
        for (uint256 i; i < b.list.length; ++i) {
            b.list[i].amount = 0;
        }
    }
}

/// @dev The ACCOUNTS module as the harness sets it: one artist, whose payout address the harness
///      rotates between two keys or freezes (zero, unresolved). The real `StreamDirectory6529`
///      answers the ledger's `payoutAddress` from it.
contract PayoutBook {
    address internal immutable _keeper;
    mapping(uint256 artistId => address) public payoutAddress;

    constructor() {
        _keeper = msg.sender;
    }

    function set(uint256 artistId, address payout) external {
        require(msg.sender == _keeper, "not keeper");
        payoutAddress[artistId] = payout;
    }
}

/// @dev Stateful harness for Medusa (docs/testing/README.md, second fuzzer) over the money
///      contracts: the real `SplitLedger` with its `SplitVault` wallets, `RevenueEscrow` and the
///      network fee vault (`GovernedVault`), behind a stub authority whose one governor holds
///      every role at zero delay.
///
///      The harness keeps its own model of the payout rules, written from
///      docs/spec/economics-and-payouts.md (ECO-9 to ECO-45) and not from the code or from the
///      Forge handler in test/economics/invariant/: what every wallet received, what every payee
///      released, every mark, every escrow credit and its clock, every signed-release nonce, and
///      what every account holds. Before each call it predicts whether the call succeeds; after
///      it, it applies the spec's effect to the model. The `property_` functions compare the
///      model with the contracts. No cheatcodes: time passes by Medusa's block timestamp delay,
///      or by the Forge runner's clock contract.
///
///      The ledger's resolver is the real `StreamDirectory6529`, whose unclaimed period the
///      governor changes mid-run (`setPeriod`, zero allowed); the ledger's forfeits and the
///      escrow's windows read it, and the model keeps its own copy.
///
///      Wallets: W0 is a royalty wallet `(fee vault 10%, alice 90%)`, deployed at construction;
///      W1 and W1b are the same three-payee list `(alice 30%, bob 30%, artist 7 40%)` under salts
///      0 and 1, deployed by the `createWallet` action, so payments may reach them first (ECO-11)
///      and W1b is W1's equivalent replacement for `recover` (ECO-28).
contract LedgerMedusa is MedusaBase {
    uint256 internal constant DENOMINATOR = 100_000;
    uint256 internal constant ARTIST = 7;
    uint256 internal constant WALLETS = 3;
    uint256 internal constant MAX_PAYMENT = 1e24;

    SplitLedger public ledger;
    RevenueEscrow public escrow;
    GovernedVault public vault;
    PlainToken public token;
    PayoutBook public book;
    StreamDirectory6529 public directory;
    Gate public gate;

    Actor public governor;
    Actor public alice;
    Actor public bob;
    Actor public keyA;
    Actor public keyB;
    Actor public stranger;
    Actor public sinkA;
    Actor public sinkB;

    ISplitWallet.Payee[] internal _royaltyPayees;
    ISplitWallet.Payee[] internal _splitPayees;
    address[WALLETS] public wallets;
    uint256 public networkIndex;
    address[] internal _tracked;
    uint256[6] internal _nonces = [uint256(0), 1, 255, 256, 257, 511];

    // The model.
    bool[WALLETS] public mDeployed;
    mapping(uint256 w => mapping(address asset => uint256)) public mReceived;
    mapping(uint256 w => mapping(address asset => mapping(uint256 i => uint256))) public mReleased;
    mapping(uint256 w => mapping(address asset => mapping(uint256 i => uint256))) public
        mMarkTarget;
    mapping(uint256 w => mapping(address asset => mapping(uint256 i => uint256))) public mMarkAt;
    mapping(uint256 w => mapping(address asset => mapping(uint256 i => bool))) public mMarked;
    mapping(address account => mapping(address asset => uint256)) public mBal;
    mapping(address account => mapping(address asset => uint256)) public mOwed;
    /// @dev The escrow credits lot by lot, with their windows (R12, ECO-45).
    mapping(address account => mapping(address asset => MedusaWindows.Book)) internal mBooks;
    mapping(address asset => uint256) public mTotalOwed;
    mapping(address account => address) public mConsent;
    mapping(address account => mapping(uint256 nonce => bool)) public mNonce;
    mapping(address account => bool) public mRefuse;
    address public mPayout;
    address public mDestination;
    uint64 public mRevision = 1;
    /// @dev The unclaimed period the model expects the Directory to answer, and when it last
    ///      changed.
    uint256 public mPeriod = 180 days;
    uint256 public mPeriodChangedAt;

    bool public unauthorizedSucceeded;
    bool public networkLeftDue;

    constructor() payable {
        governor = new Actor();
        alice = new Actor();
        bob = new Actor();
        keyA = new Actor();
        keyB = new Actor();
        stranger = new Actor();
        sinkA = new Actor();
        sinkB = new Actor();
        token = new PlainToken();
        book = new PayoutBook();
        gate = new Gate(address(governor));
        vault = new GovernedVault(address(gate), address(sinkA));
        directory = new StreamDirectory6529(
            address(gate), address(book), address(0), address(0), address(0)
        );
        ledger = new SplitLedger(IArtistPayoutResolver(address(directory)), address(vault));
        escrow = new RevenueEscrow(address(gate), ledger);
        book.set(ARTIST, address(keyA));
        mPayout = address(keyA);
        mDestination = address(sinkA);

        _pushSorted(_royaltyPayees, address(vault), 10_000, address(alice), 90_000);
        networkIndex = _royaltyPayees[0].account == address(vault) ? 0 : 1;
        _pushSorted(_splitPayees, address(alice), 30_000, address(bob), 30_000);
        _splitPayees.push(ISplitWallet.Payee(ARTIST, address(0), 40_000));

        wallets[0] = _predict(_royaltyPayees, 0);
        wallets[1] = _predict(_splitPayees, 0);
        wallets[2] = _predict(_splitPayees, bytes32(uint256(1)));
        require(ledger.createWallet(_royaltyPayees, 0) == wallets[0], "W0 address");
        mDeployed[0] = true;

        _tracked = [
            address(alice),
            address(bob),
            address(keyA),
            address(keyB),
            address(stranger),
            address(sinkA),
            address(sinkB),
            address(vault),
            address(escrow),
            wallets[0],
            wallets[1],
            wallets[2]
        ];
    }

    receive() external payable { }

    // ---------------------------------------------------------------------------------------
    // Actions: wallets and releases
    // ---------------------------------------------------------------------------------------

    /// Pays a wallet directly, deployed or not: ETH from the harness or freshly minted tokens.
    function pay(uint8 w, bool eth, uint256 amount) public {
        w = uint8(w % WALLETS);
        amount = 1 + amount % MAX_PAYMENT;
        address asset = _asset(eth);
        if (eth) {
            if (address(this).balance < amount) return;
            (bool ok,) = wallets[w].call{ value: amount }("");
            _record(ok, true, "pay ETH");
            if (!ok) return;
        } else {
            token.mint(wallets[w], amount);
        }
        mReceived[w][asset] += amount;
        mBal[wallets[w]][asset] += amount;
    }

    /// Deploys W1 or W1b. Anyone may, for any canonical list, and again changes nothing (ECO-10).
    function createWallet(bool second) public {
        uint256 w = second ? 2 : 1;
        bytes memory data =
            abi.encodeCall(ledger.createWallet, (_splitPayees, bytes32(uint256(w - 1))));
        (bool ok, bytes memory ret) = _expect(stranger, address(ledger), data, true, "createWallet");
        if (ok) {
            if (abi.decode(ret, (address)) != wallets[w]) _record(false, true, "wallet address");
            mDeployed[w] = true;
        }
    }

    /// `release`: anyone for a fixed payee, to its account; only the payout address for the
    /// artist payee (ECO-15, ECO-16).
    function release(uint8 w, bool eth, uint8 index, uint8 who) public {
        w = uint8(w % WALLETS);
        uint256 i = index % _count(w);
        Actor caller = _caller(who);
        address asset = _asset(eth);
        address account = _account(w, i);
        bool authorized = !_isArtist(w, i) || address(caller) == account;
        uint256 due = _due(w, asset, i);
        bool expected = mDeployed[w] && account != address(0) && authorized && due != 0
            && _accepts(account, asset);
        bytes memory data = abi.encodeCall(ledger.release, (_payees(w), _salt(w), asset, i));
        (bool ok,) = _expect(caller, address(ledger), data, expected, "release");
        if (ok) {
            if (!authorized) unauthorizedSucceeded = true;
            _applyRelease(w, asset, i, account, due);
        }
    }

    /// `releaseTo`: only the payee's current payout address, to any valid recipient (ECO-17).
    function releaseTo(uint8 w, bool eth, uint8 index, uint8 who, uint8 to) public {
        w = uint8(w % WALLETS);
        _releaseTo(w, index % _count(w), _caller(who), _recipient(w, to), _asset(eth));
    }

    function _releaseTo(uint256 w, uint256 i, Actor caller, address recipient, address asset)
        internal
    {
        address account = _account(w, i);
        bool authorized = account != address(0) && address(caller) == account;
        uint256 due = _due(w, asset, i);
        bool expected = mDeployed[w] && authorized && _validRecipient(w, recipient) && due != 0
            && _accepts(recipient, asset);
        bytes memory data = _releaseToCall(w, asset, i, recipient);
        (bool ok,) = _expect(caller, address(ledger), data, expected, "releaseTo");
        if (ok) {
            if (!authorized) unauthorizedSucceeded = true;
            _applyRelease(w, asset, i, recipient, due);
        }
    }

    /// `releaseWithAuthorization` submitted by a stranger: the signer must be the payee's payout
    /// address, the deadline not passed, the nonce unused, the wallet the one named, and the
    /// amount at most what is releasable; a failed one keeps its nonce (ECO-20 to ECO-22).
    function releaseSigned(
        uint8 w,
        bool eth,
        uint8 index,
        uint8 signer,
        uint8 shape,
        uint8 nonceSel,
        uint8 to
    ) public {
        w = uint8(w % WALLETS);
        uint256 i = index % _count(w);
        (IReleaseVerifier.Authorization memory auth, bool authorized) =
            _authorization(w, eth, i, signer, shape, nonceSel, to);
        _signedRelease(w, i, auth, authorized);
    }

    function _signedRelease(
        uint256 w,
        uint256 i,
        IReleaseVerifier.Authorization memory auth,
        bool authorized
    ) internal {
        uint256 due = _due(w, auth.asset, i);
        bool expected = mDeployed[w] && authorized && _validRecipient(w, auth.recipient)
            && auth.amount != 0 && auth.amount <= due && _accepts(auth.recipient, auth.asset);
        bytes memory data =
            abi.encodeCall(ledger.releaseWithAuthorization, (_payees(w), _salt(w), auth, ""));
        (bool ok,) = _expect(stranger, address(ledger), data, expected, "releaseWithAuthorization");
        if (ok) {
            if (!authorized) unauthorizedSucceeded = true;
            mNonce[auth.account][auth.nonce] = true;
            _applyRelease(w, auth.asset, i, auth.recipient, auth.amount);
        }
    }

    /// Builds the authorization `shape` describes, has its signer approve it unless told not
    /// to, and says whether the spec lets it authorize the release (ECO-20).
    function _authorization(
        uint256 w,
        bool eth,
        uint256 i,
        uint8 signer,
        uint8 shape,
        uint8 nonceSel,
        uint8 to
    ) internal returns (IReleaseVerifier.Authorization memory auth, bool authorized) {
        auth.wallet = shape & 8 != 0 ? wallets[(w + 1) % WALLETS] : wallets[w];
        auth.asset = _asset(eth);
        auth.payee = i;
        auth.account = address(_caller(signer));
        auth.recipient = _recipient(w, to);
        auth.nonce = _nonces[nonceSel % _nonces.length];
        bool late = shape & 16 != 0 && block.timestamp > 0;
        auth.deadline = late ? block.timestamp - 1 : block.timestamp + 1 days;
        uint256 due = _due(w, auth.asset, i);
        uint256 kind = shape % 4;
        auth.amount = kind == 0 ? 0 : kind == 1 ? due : kind == 2 ? due + 1 : due / 2;
        bool approve = shape & 32 == 0;
        if (approve) Actor(payable(auth.account)).approve(_digest(auth));
        authorized = auth.account == _account(w, i) && auth.account != address(0) && approve
            && !late && !mNonce[auth.account][auth.nonce] && auth.wallet == wallets[w];
    }

    /// `revokeNonce` burns one of the caller's nonces, once (ECO-21).
    function revokeNonce(uint8 who, uint8 nonceSel) public {
        Actor caller = _caller(who);
        uint256 nonce = _nonces[nonceSel % _nonces.length];
        bool expected = !mNonce[address(caller)][nonce];
        bytes memory data = abi.encodeCall(ledger.revokeNonce, (nonce));
        (bool ok,) = _expect(caller, address(ledger), data, expected, "revokeNonce");
        if (ok) mNonce[address(caller)][nonce] = true;
    }

    /// `mark`: anyone, for a deployed wallet's payee with something releasable, unless a running
    /// mark the payee has not released past would be replaced (ECO-44).
    function mark(uint8 w, bool eth, uint8 index) public {
        w = uint8(w % WALLETS);
        uint256 i = index % _count(w);
        address asset = _asset(eth);
        uint256 due = _due(w, asset, i);
        uint256 done = mReleased[w][asset][i];
        bool pending = mMarked[w][asset][i] && done < mMarkTarget[w][asset][i];
        bool expected = mDeployed[w] && due != 0 && !pending;
        bytes memory data = abi.encodeCall(ledger.mark, (_payees(w), _salt(w), asset, i));
        (bool ok,) = _expect(stranger, address(ledger), data, expected, "mark");
        if (ok) {
            mMarked[w][asset][i] = true;
            mMarkTarget[w][asset][i] = done + due;
            mMarkAt[w][asset][i] = block.timestamp;
        }
    }

    /// `forfeit`: anyone, once the unclaimed period in force now has passed since the mark, of what of the marked level is unreleased, at
    /// most what is releasable now; it pays the network and clears the mark (ECO-44).
    function forfeit(uint8 w, bool eth, uint8 index) public {
        w = uint8(w % WALLETS);
        uint256 i = index % _count(w);
        address asset = _asset(eth);
        uint256 target = mMarkTarget[w][asset][i];
        uint256 done = mReleased[w][asset][i];
        uint256 amount = target > done ? target - done : 0;
        uint256 due = _due(w, asset, i);
        if (amount > due) amount = due;
        bool matured = mMarked[w][asset][i] && block.timestamp >= mMarkAt[w][asset][i] + mPeriod;
        bytes memory data = abi.encodeCall(ledger.forfeit, (_payees(w), _salt(w), asset, i));
        (bool ok,) = _expect(stranger, address(ledger), data, matured && amount != 0, "forfeit");
        if (ok) {
            mMarked[w][asset][i] = false;
            _applyRelease(w, asset, i, address(vault), amount);
        }
    }

    /// The artist's payout address moves between two keys, or freezes (ECO-16, ECO-18).
    function setPayout(uint8 sel) public {
        address next = sel % 3 == 0 ? address(keyA) : sel % 3 == 1 ? address(keyB) : address(0);
        book.set(ARTIST, next);
        mPayout = next;
    }

    /// Alice or Bob starts or stops refusing ETH: a payee that cannot receive blocks only its
    /// own share (ECO-15).
    function toggleRefuse(bool bobSel) public {
        Actor who = bobSel ? bob : alice;
        bool next = !mRefuse[address(who)];
        who.setRefuseETH(next);
        mRefuse[address(who)] = next;
    }

    /// `setUnclaimedPeriod` on the Directory: governed; any value, zero included. It reaches
    /// marks already made and escrow windows already open or closed, never an amount already
    /// aged (ECO-44, ECO-45).
    function setPeriod(uint8 sel, bool asGovernor) public {
        uint256 k = sel % 5;
        uint48 next = k == 0 ? 0 : k == 1 ? 3 days : k == 2 ? 30 days : k == 3 ? 180 days : 400 days;
        bytes memory data = abi.encodeCall(directory.setUnclaimedPeriod, (next));
        (bool ok,) = _expect(
            asGovernor ? governor : stranger, address(directory), data, asGovernor, "setPeriod"
        );
        if (!ok) return;
        if (!asGovernor) unauthorizedSucceeded = true;
        mPeriod = next;
        mPeriodChangedAt = block.timestamp;
    }

    // ---------------------------------------------------------------------------------------
    // Actions: the escrow
    // ---------------------------------------------------------------------------------------

    /// A credit for a wallet, an account or the fee vault (ECO-27).
    function deposit(uint8 sel, bool eth, uint256 amount) public {
        address account = _creditee(sel);
        amount = 1 + amount % MAX_PAYMENT;
        address asset = _asset(eth);
        bytes memory data;
        uint256 value;
        if (eth) {
            if (address(this).balance < amount) return;
            data = abi.encodeCall(escrow.depositETH, (account));
            value = amount;
        } else {
            token.mint(address(this), amount);
            token.approve(address(escrow), amount);
            data = abi.encodeCall(escrow.depositERC20, (account, asset, amount));
        }
        (bool ok,) = address(escrow).call{ value: value }(data);
        _record(ok, true, "deposit");
        if (!ok) return;
        mTotalOwed[asset] += amount;
        mBal[address(escrow)][asset] += amount;
        _addCredit(account, asset, amount);
    }

    /// `flush`: anyone, only to the credited account; a refused flush keeps the credit.
    function flush(uint8 sel, bool eth) public {
        address account = _creditee(sel);
        address asset = _asset(eth);
        uint256 amount = mOwed[account][asset];
        bool expected = amount != 0 && _accepts(account, asset);
        bytes memory data = abi.encodeCall(escrow.flush, (account, asset));
        (bool ok,) = _expect(stranger, address(escrow), data, expected, "flush");
        if (!ok) return;
        mOwed[account][asset] = 0;
        MedusaWindows.takeAll(mBooks[account][asset]);
        mTotalOwed[asset] -= amount;
        _move(address(escrow), account, asset, amount);
        for (uint256 w; w < WALLETS; ++w) {
            if (wallets[w] == account) mReceived[w][asset] += amount;
        }
    }

    /// Alice names the replacement a governed recovery of her credit may use (ECO-28).
    function consent(uint8 repSel) public {
        address rep = _replacement(repSel);
        bool expected = rep != address(escrow) && rep != address(alice);
        bytes memory data = abi.encodeCall(escrow.consentToRecovery, (rep));
        (bool ok,) = _expect(alice, address(escrow), data, expected, "consentToRecovery");
        if (ok) mConsent[address(alice)] = rep;
    }

    /// `recover`: governed; a factory wallet's credit only to a distinct deployed wallet with
    /// the same list, the network's own credit anywhere but zero, the escrow or itself, and
    /// anyone else's only to the replacement it consented to, once (ECO-28).
    function recover(uint8 sel, uint8 repSel, bool eth, bool asGovernor) public {
        address account = _creditee(sel);
        address rep = _replacement(repSel);
        address asset = _asset(eth);
        uint256 amount = mOwed[account][asset];
        uint256 w = _walletIndex(account);
        bool consented = false;
        bool allowed;
        if (w < WALLETS && mDeployed[w]) {
            uint256 r = _walletIndex(rep);
            allowed = r < WALLETS && r != w && w != 0 && r != 0 && mDeployed[r];
        } else if (account == address(vault)) {
            allowed = rep != address(0) && rep != address(escrow) && rep != address(vault);
        } else {
            allowed = rep != address(0) && mConsent[account] == rep;
            consented = true;
        }
        bool expected = asGovernor && amount != 0 && allowed;
        bytes memory data = abi.encodeCall(escrow.recover, (account, rep, asset));
        (bool ok,) =
            _expect(asGovernor ? governor : stranger, address(escrow), data, expected, "recover");
        if (!ok) return;
        if (!asGovernor) unauthorizedSucceeded = true;
        if (consented) mConsent[account] = address(0);
        mOwed[account][asset] = 0;
        MedusaWindows.takeAll(mBooks[account][asset]);
        _addCredit(rep, asset, amount);
    }

    /// `expire`: anyone; it moves the credits of every aged window (see `MedusaWindows`), never
    /// the fee vault's own credit; they become a credit of the fee vault (ECO-45).
    function expire(uint8 sel, bool eth) public {
        address account = _creditee(sel);
        address asset = _asset(eth);
        MedusaWindows.Book storage book = mBooks[account][asset];
        uint256 due = MedusaWindows.expirable(book, block.timestamp, mPeriod);
        bool expected = account != address(vault) && due != 0;
        bytes memory data = abi.encodeCall(escrow.expire, (account, asset));
        (bool ok,) = _expect(stranger, address(escrow), data, expected, "expire");
        if (!ok) return;
        if (MedusaWindows.expire(book, block.timestamp, mPeriod) != due) {
            _record(false, true, "expired amount");
        }
        mOwed[account][asset] -= due;
        _addCredit(address(vault), asset, due);
    }

    /// Tokens sent to the escrow without a deposit: owed to nobody.
    function donate(uint256 amount) public {
        amount = 1 + amount % MAX_PAYMENT;
        token.mint(address(escrow), amount);
        mBal[address(escrow)][address(token)] += amount;
    }

    /// `sweepExcess`: governed, exactly `balance - totalOwed`, never a credit (ECO-40).
    function sweep(bool eth, uint8 toSel, bool asGovernor) public {
        address asset = _asset(eth);
        address to = toSel % 4 == 0
            ? address(sinkB)
            : toSel % 4 == 1 ? address(alice) : toSel % 4 == 2 ? address(0) : address(escrow);
        uint256 held = mBal[address(escrow)][asset];
        uint256 excess = held > mTotalOwed[asset] ? held - mTotalOwed[asset] : 0;
        bool expected = asGovernor && to != address(0) && to != address(escrow) && excess != 0
            && _accepts(to, asset);
        bytes memory data = abi.encodeCall(escrow.sweepExcess, (asset, to));
        (bool ok,) = _expect(
            asGovernor ? governor : stranger, address(escrow), data, expected, "sweepExcess"
        );
        if (!ok) return;
        if (!asGovernor) unauthorizedSucceeded = true;
        _move(address(escrow), to, asset, excess);
    }

    // ---------------------------------------------------------------------------------------
    // Actions: the fee vault
    // ---------------------------------------------------------------------------------------

    /// `forward`: anyone, only to the destination (ECO-41).
    function forward(bool eth, uint8 amountSel) public {
        address asset = _asset(eth);
        uint256 held = mBal[address(vault)][asset];
        uint256 k = amountSel % 3;
        uint256 amount = k == 0 ? type(uint256).max : k == 1 ? held / 2 : held + 1;
        uint256 sent = k == 0 ? held : amount;
        bytes memory data = abi.encodeCall(vault.forward, (asset, amount));
        (bool ok,) = _expect(stranger, address(vault), data, sent != 0 && sent <= held, "forward");
        if (ok) _move(address(vault), mDestination, asset, sent);
    }

    /// `setDestination`: governed, compare-and-set on the revision (ECO-41).
    function setDestination(bool asGovernor, bool wrongRevision, uint8 nextSel) public {
        address next = nextSel % 4 == 0
            ? address(sinkA)
            : nextSel % 4 == 1 ? address(sinkB) : nextSel % 4 == 2 ? address(0) : address(vault);
        uint64 revision = wrongRevision ? mRevision + 1 : mRevision;
        bool expected = asGovernor && !wrongRevision && next != address(0) && next != address(vault);
        bytes memory data = abi.encodeCall(vault.setDestination, (revision, next));
        (bool ok,) = _expect(
            asGovernor ? governor : stranger, address(vault), data, expected, "setDestination"
        );
        if (!ok) return;
        if (!asGovernor) unauthorizedSucceeded = true;
        mDestination = next;
        ++mRevision;
    }

    /// `releaseToDestination`: anyone; the vault releases its own share of W0 to its
    /// destination. Any other payee's index is refused, since the vault is not its account.
    function releaseToDestination(bool eth, uint8 index) public {
        uint256 i = index % 3;
        address asset = _asset(eth);
        uint256 due = i < 2 ? _due(0, asset, i) : 0;
        bool expected = i == networkIndex && due != 0;
        bytes memory data = abi.encodeCall(
            vault.releaseToDestination, (ledger, _royaltyPayees, bytes32(0), asset, i)
        );
        (bool ok,) = _expect(stranger, address(vault), data, expected, "releaseToDestination");
        if (ok) _applyRelease(0, asset, i, mDestination, due);
    }

    // ---------------------------------------------------------------------------------------
    // Properties
    // ---------------------------------------------------------------------------------------

    function property_ModelPredictsEveryOutcome() public view returns (bool) {
        return !outcomeMismatch;
    }

    /// ECO-14, INV-ECO-1, INV-ECO-12: every wallet's balance plus everything released equals
    /// everything it received, and every account holds exactly what the model moved to it.
    function property_WalletsConserveValue() public view returns (bool) {
        for (uint256 a; a < 2; ++a) {
            address asset = _asset(a == 0);
            for (uint256 w; w < WALLETS; ++w) {
                uint256 sum;
                for (uint256 i; i < _count(w); ++i) {
                    sum += mReleased[w][asset][i];
                }
                uint256 total = ledger.totalReleased(wallets[w], asset);
                if (total != sum || _balanceOf(wallets[w], asset) + total != mReceived[w][asset]) {
                    return false;
                }
            }
            for (uint256 k; k < _tracked.length; ++k) {
                if (_balanceOf(_tracked[k], asset) != mBal[_tracked[k]][asset]) return false;
            }
        }
        return true;
    }

    /// ECO-13, INV-ECO-2, ECO-44: each payee's releases equal the model's and never exceed
    /// `floor(received * share / 100,000)`; every mark is within the entitlement.
    function property_ReleasedWithinEntitlement() public view returns (bool) {
        for (uint256 a; a < 2; ++a) {
            address asset = _asset(a == 0);
            for (uint256 w; w < WALLETS; ++w) {
                for (uint256 i; i < _count(w); ++i) {
                    uint256 done = ledger.released(wallets[w], asset, i);
                    uint256 cap = _entitlement(mReceived[w][asset], _share(w, i));
                    if (done != mReleased[w][asset][i] || done > cap) return false;
                    (uint256 target, uint256 markedAt) = ledger.markOf(wallets[w], asset, i);
                    if (target > cap) return false;
                    if (mMarked[w][asset][i]) {
                        if (target != mMarkTarget[w][asset][i] || markedAt != mMarkAt[w][asset][i])
                        {
                            return false;
                        }
                    } else if (target != 0 || markedAt != 0) {
                        return false;
                    }
                }
            }
        }
        return true;
    }

    /// INV-ECO-5: released plus releasable equals received up to fewer than `payeeCount` units.
    function property_DustIsBounded() public view returns (bool) {
        for (uint256 a; a < 2; ++a) {
            address asset = _asset(a == 0);
            for (uint256 w; w < WALLETS; ++w) {
                ISplitWallet.Payee[] memory payees = _payees(w);
                uint256 accounted;
                for (uint256 i; i < payees.length; ++i) {
                    accounted += ledger.released(wallets[w], asset, i)
                    + ledger.releasable(payees, _salt(w), asset, i);
                }
                uint256 received = mReceived[w][asset];
                if (accounted > received || received - accounted >= payees.length) return false;
            }
        }
        return true;
    }

    /// ECO-27, INV-ECO-6, ECO-40, ECO-45: the escrow holds at least what it owes, per asset;
    /// every credit, what of it may expire now and later, and the totals match the model; what
    /// may expire is never early and always includes every window opened 360 days before.
    function property_EscrowIsSolvent() public view returns (bool) {
        for (uint256 a; a < 2; ++a) {
            address asset = _asset(a == 0);
            if (escrow.totalOwed(asset) != mTotalOwed[asset]) return false;
            if (_balanceOf(address(escrow), asset) < mTotalOwed[asset]) return false;
            uint256 sum;
            for (uint256 k; k < _tracked.length; ++k) {
                address account = _tracked[k];
                uint256 owed = escrow.owed(account, asset);
                if (owed != mOwed[account][asset]) return false;
                if (account != address(vault) && !_expiryMatches(account, asset)) return false;
                sum += owed;
            }
            if (sum != mTotalOwed[asset]) return false;
        }
        return escrow.recoveryConsent(address(alice)) == mConsent[address(alice)]
            && directory.unclaimedPeriod() == mPeriod;
    }

    /// ECO-15 to ECO-17, ECO-5: no release by anyone but who the spec allows, no governed call
    /// by anyone but the governor, ever succeeded; nonces match the model (ECO-20, ECO-21).
    function property_NoUnauthorizedRelease() public view returns (bool) {
        if (unauthorizedSucceeded) return false;
        for (uint256 who; who < 5; ++who) {
            address account = address(_caller(uint8(who)));
            for (uint256 k; k < _nonces.length; ++k) {
                if (ledger.nonceUsed(account, _nonces[k]) != mNonce[account][_nonces[k]]) {
                    return false;
                }
            }
        }
        return vault.destination() == mDestination && vault.destinationRevision() == mRevision;
    }

    /// ECO-43, INV-ECO-14: after every release of another payee of W0, nothing is left due to
    /// the network in that asset.
    function property_NetworkShareIsPaidOrDue() public view returns (bool) {
        return !networkLeftDue;
    }

    // ---------------------------------------------------------------------------------------
    // Model helpers
    // ---------------------------------------------------------------------------------------

    /// A release of `amount` of payee `i` of wallet `w` to `recipient`, then the network's push
    /// when W0 names the vault and another payee was released.
    function _applyRelease(uint256 w, address asset, uint256 i, address recipient, uint256 amount)
        internal
    {
        mReleased[w][asset][i] += amount;
        _move(wallets[w], recipient, asset, amount);
        if (w != 0 || i == networkIndex) return;
        uint256 due = _due(0, asset, networkIndex);
        if (due != 0) {
            mReleased[0][asset][networkIndex] += due;
            _move(wallets[0], address(vault), asset, due);
        }
        if (ledger.releasable(_royaltyPayees, 0, asset, networkIndex) != 0) networkLeftDue = true;
    }

    function _releaseToCall(uint256 w, address asset, uint256 i, address recipient)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(ledger.releaseTo, (_payees(w), _salt(w), asset, i, recipient));
    }

    function _addCredit(address account, address asset, uint256 amount) internal {
        mOwed[account][asset] += amount;
        MedusaWindows.credit(mBooks[account][asset], amount, block.timestamp, mPeriod);
    }

    function _expiryMatches(address account, address asset) internal view returns (bool) {
        MedusaWindows.Book storage book = mBooks[account][asset];
        uint256 t = block.timestamp;
        uint256 p = mPeriod;
        uint256[4] memory at = [t, t + p / 2, t + p, t + 2 * p];
        for (uint256 i; i < 4; ++i) {
            uint256 e = escrow.expirableAt(account, asset, at[i]);
            if (e != MedusaWindows.expirable(book, at[i], p)) return false;
            if (e < MedusaWindows.veryOld(book, at[i], p, mPeriodChangedAt)) return false;
        }
        return true;
    }

    function _move(address from, address to, address asset, uint256 amount) internal {
        mBal[from][asset] -= amount;
        mBal[to][asset] += amount;
    }

    function _due(uint256 w, address asset, uint256 i) internal view returns (uint256) {
        return _entitlement(mReceived[w][asset], _share(w, i)) - mReleased[w][asset][i];
    }

    /// Plain `floor(received * share / 100,000)`: payments are bounded, so it cannot overflow.
    function _entitlement(uint256 received, uint256 share) internal pure returns (uint256) {
        return received * share / DENOMINATOR;
    }

    function _accepts(address to, address asset) internal view returns (bool) {
        return asset != address(0) || !mRefuse[to];
    }

    function _validRecipient(uint256 w, address to) internal view returns (bool) {
        return to != address(0) && to != wallets[w] && to != address(ledger);
    }

    function _account(uint256 w, uint256 i) internal view returns (address) {
        return _isArtist(w, i) ? mPayout : _payees(w)[i].account;
    }

    function _isArtist(uint256 w, uint256 i) internal view returns (bool) {
        return _payees(w)[i].artistId != 0;
    }

    function _share(uint256 w, uint256 i) internal view returns (uint256) {
        return _payees(w)[i].share;
    }

    function _count(uint256 w) internal pure returns (uint256) {
        return w == 0 ? 2 : 3;
    }

    function _payees(uint256 w) internal view returns (ISplitWallet.Payee[] memory) {
        return w == 0 ? _royaltyPayees : _splitPayees;
    }

    function _salt(uint256 w) internal pure returns (bytes32) {
        return w == 2 ? bytes32(uint256(1)) : bytes32(0);
    }

    function _asset(bool eth) internal view returns (address) {
        return eth ? address(0) : address(token);
    }

    function _caller(uint8 who) internal view returns (Actor) {
        uint256 k = who % 5;
        return k == 0 ? alice : k == 1 ? bob : k == 2 ? keyA : k == 3 ? keyB : stranger;
    }

    function _recipient(uint256 w, uint8 to) internal view returns (address) {
        uint256 k = to % 9;
        if (k < 5) return address(_caller(uint8(k)));
        return k == 5 ? address(sinkB) : k == 6 ? wallets[w] : k == 7 ? address(ledger) : address(0);
    }

    function _creditee(uint8 sel) internal view returns (address) {
        uint256 k = sel % 5;
        return k < 3 ? wallets[k] : k == 3 ? address(alice) : address(vault);
    }

    function _replacement(uint8 sel) internal view returns (address) {
        uint256 k = sel % 9;
        if (k < 3) return wallets[k];
        return k == 3
            ? address(alice)
            : k == 4
                ? address(bob)
                : k == 5
                    ? address(sinkB)
                    : k == 6 ? address(0) : k == 7 ? address(escrow) : address(vault);
    }

    function _walletIndex(address account) internal view returns (uint256) {
        for (uint256 w; w < WALLETS; ++w) {
            if (wallets[w] == account) return w;
        }
        return type(uint256).max;
    }

    function _balanceOf(address account, address asset) internal view returns (uint256) {
        return asset == address(0) ? account.balance : token.balanceOf(account);
    }

    /// The wallet address the spec derives (ECO-9), computed here rather than asked of the
    /// ledger: CREATE2 over the vault's documented init code.
    function _predict(ISplitWallet.Payee[] storage payees, bytes32 salt)
        internal
        view
        returns (address)
    {
        bytes32 walletSalt = keccak256(abi.encode(keccak256(abi.encode(payees)), salt));
        bytes32 h = keccak256(
            abi.encodePacked(
                bytes1(0xff), address(ledger), walletSalt, keccak256(SplitVault.INIT_CODE)
            )
        );
        return address(uint160(uint256(h)));
    }

    /// The EIP-712 digest of a release authorization, computed from the spec's type string
    /// rather than asked of the ledger.
    function _digest(IReleaseVerifier.Authorization memory auth) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("6529 Stream Release Verifier"),
                keccak256("1"),
                block.chainid,
                address(ledger)
            )
        );
        bytes32 typeHash = keccak256(
            "ReleaseAuthorization(address wallet,address asset,uint256 payee,address account,address recipient,uint256 amount,uint256 nonce,uint256 deadline)"
        );
        return
            keccak256(abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(typeHash, auth))));
    }

    function _pushSorted(
        ISplitWallet.Payee[] storage list,
        address a,
        uint32 shareA,
        address b,
        uint32 shareB
    ) internal {
        if (a < b) {
            list.push(ISplitWallet.Payee(0, a, shareA));
            list.push(ISplitWallet.Payee(0, b, shareB));
        } else {
            list.push(ISplitWallet.Payee(0, b, shareB));
            list.push(ISplitWallet.Payee(0, a, shareA));
        }
    }
}
