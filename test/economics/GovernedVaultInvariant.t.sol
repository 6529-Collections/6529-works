// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Test } from "forge-std/Test.sol";
import { GovernedVault } from "src/economics/GovernedVault.sol";
import { IGovernedVault } from "src/economics/interfaces/IGovernedVault.sol";
import { ISplitLedger } from "src/economics/interfaces/ISplitLedger.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Roles } from "src/governance/Roles.sol";
import { HandlerReach } from "../helpers/HandlerReach.sol";
import {
    BlocklistToken,
    FeeOnTransferToken,
    MockERC20,
    NoReturnToken,
    ToggleRecipient
} from "../mocks/economics/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";
import { VaultTest721, VaultTest1155 } from "./GovernedVault.t.sol";

/// @notice A destination that, whenever the vault pays it ETH, tries to make itself the
///         destination (it holds no role) and to pull the rest of the vault's ETH. It accepts no
///         ERC-721 or ERC-1155.
contract ReenteringDestination {
    GovernedVault internal immutable vault;
    uint256 public seizeAttempts;
    uint256 public seized;

    constructor(GovernedVault vault_) {
        vault = vault_;
    }

    receive() external payable {
        if (msg.sender != address(vault)) return;
        ++seizeAttempts;
        try vault.setDestination(vault.destinationRevision(), address(this)) {
            ++seized;
        } catch { }
        if (address(vault).balance != 0) {
            try vault.forward(address(0), type(uint256).max) { } catch { }
        }
    }
}

/// @notice Drives the network fee vault (a `GovernedVault`, the split ledger's network and a
///         fixed payee of a royalty wallet) with ETH, a plain ERC-20, a token that returns
///         nothing, a blocklist token, a fee-on-transfer token, ERC-721 works and ERC-1155
///         copies; anyone forwards, governance changes the destination by compare-and-set, and
///         the destinations include a contract that refuses ETH when closed and one that
///         re-enters. Each action predicts its outcome; balances are tracked for every account
///         that could receive anything.
contract GovernedVaultHandler is Test {
    address internal constant ETH = address(0);
    uint256 internal constant ASSETS = 5;
    uint256 internal constant WORKS = 6;
    uint256 internal constant EDITION = 7;

    GovernedVault public immutable vault;
    ISplitLedger internal immutable ledger;
    address public immutable network;
    address public immutable stranger = makeAddr("vaultStranger");
    address internal immutable funder = makeAddr("vaultFunder");
    VaultTest721 public immutable works;
    VaultTest1155 public immutable editions;
    ToggleRecipient public immutable toggle;
    ReenteringDestination public immutable reenter;
    BlocklistToken internal immutable blocklist;
    FeeOnTransferToken internal immutable feeToken;

    /// @dev ETH, then the four ERC-20s.
    address[ASSETS] public assets;
    /// @dev Every account that may ever receive from the vault: the destination pool, then the
    ///      network, the stranger and the royalty wallet's other payee.
    address[] public universe;
    /// @dev Destinations governance picks from; index 4 and 5 are refused (zero, the vault).
    address[6] internal _candidates;

    ISplitWallet.Payee[] internal _payees;
    address public royaltyWallet;
    uint256 internal _vaultIndex;

    address public ghostDestination;
    uint64 public ghostRevision = 1;
    mapping(address asset => uint256) public vaultModel;
    mapping(address account => mapping(address asset => uint256)) public received;
    mapping(uint256 id => address) public holderOf;
    uint256 public worksMinted;
    mapping(address account => uint256) public copiesOf;

    uint256 public violations;
    uint256 public forwards;
    uint256 public refusedForwards;
    uint256 public destinationChanges;
    uint256 public refusedChanges;
    /// @notice Destination changes that succeeded with a wrong revision or from a stranger.
    uint256 public wrongChanges;
    uint256 public releasedToDestination;

    constructor(
        GovernedVault vault_,
        ISplitLedger ledger_,
        address network_,
        MockERC20 plain,
        address seller
    ) {
        (vault, ledger, network) = (vault_, ledger_, network_);
        works = new VaultTest721();
        editions = new VaultTest1155();
        toggle = new ToggleRecipient();
        reenter = new ReenteringDestination(vault_);
        blocklist = new BlocklistToken();
        feeToken = new FeeOnTransferToken();
        assets = [
            ETH, address(plain), address(new NoReturnToken()), address(blocklist), address(feeToken)
        ];
        ghostDestination = vault_.destination();
        _candidates = [
            ghostDestination,
            makeAddr("secondSafe"),
            address(toggle),
            address(reenter),
            address(0),
            address(vault_)
        ];
        for (uint256 i; i < 4; ++i) {
            universe.push(_candidates[i]);
        }
        universe.push(network_);
        universe.push(stranger);
        universe.push(seller);
        // The royalty wallet: the seller 75%, the vault 25%, in canonical order.
        ISplitWallet.Payee memory a = ISplitWallet.Payee(0, seller, 75_000);
        ISplitWallet.Payee memory b = ISplitWallet.Payee(0, address(vault_), 25_000);
        (ISplitWallet.Payee memory x, ISplitWallet.Payee memory y) =
            seller < address(vault_) ? (a, b) : (b, a);
        _payees.push(x);
        _payees.push(y);
        _vaultIndex = seller < address(vault_) ? 1 : 0;
        royaltyWallet = ledger_.createWallet(_payees, bytes32(0));
    }

    function universeCount() external view returns (uint256) {
        return universe.length;
    }

    function balanceOf(address asset, address account) public view returns (uint256) {
        return asset == ETH ? account.balance : MockERC20(asset).balanceOf(account);
    }

    // ------------------------------------------------------------------------------- actions

    /// @dev Someone pays the vault directly.
    function fund(uint256 assetSeed, uint256 amount) external {
        address asset = assets[assetSeed % ASSETS];
        amount = bound(amount, 1, 1e24);
        if (asset == ETH) {
            vm.deal(funder, amount);
            vm.prank(funder);
            (bool ok,) = address(vault).call{ value: amount }("");
            if (!ok) ++violations;
        } else {
            MockERC20(asset).mint(address(vault), amount);
        }
        vaultModel[asset] += amount;
    }

    /// @dev Anyone forwards an amount (or everything) to the destination. Refused: nothing to
    ///      forward, more than held, a destination that refuses ETH, a blocked party, a token
    ///      that delivers less than sent.
    function forward(uint256 assetSeed, uint256 amountSeed, bool all, uint8 callerSeed) external {
        address asset = assets[assetSeed % ASSETS];
        address to = ghostDestination;
        uint256 held = vaultModel[asset];
        uint256 sent = all ? held : bound(amountSeed, 0, held + 2);
        bool expected = sent != 0 && sent <= held;
        if (asset == ETH && to == address(toggle) && !toggle.open()) expected = false;
        if (
            asset == address(blocklist)
                && (blocklist.blocked(address(vault)) || blocklist.blocked(to))
        ) {
            expected = false;
        }
        if (asset == address(feeToken) && sent * feeToken.feeBps() / 10_000 != 0) {
            expected = false;
        }
        address caller = universe[callerSeed % universe.length];
        vm.prank(caller);
        try vault.forward(asset, all ? type(uint256).max : sent) returns (uint256 out) {
            if (!expected || out != sent) ++violations;
            vaultModel[asset] -= sent;
            received[to][asset] += sent;
            if (asset == ETH && to == address(reenter)) {
                // The re-entering destination pulls the rest, still to itself.
                received[to][ETH] += vaultModel[ETH];
                vaultModel[ETH] = 0;
            }
            ++forwards;
        } catch {
            if (expected) ++violations;
            ++refusedForwards;
        }
    }

    /// @dev A work reaches the vault (an unbid work the museum keeps, say).
    function mintWork() external {
        if (worksMinted == WORKS) return;
        works.safeMint(address(vault), ++worksMinted);
        holderOf[worksMinted] = address(vault);
    }

    /// @dev Anyone forwards a work; a destination that cannot hold ERC-721s refuses it.
    function forwardWork(uint256 idSeed) external {
        if (worksMinted == 0) return;
        uint256 id = idSeed % worksMinted + 1;
        address to = ghostDestination;
        bool expected = holderOf[id] == address(vault) && to.code.length == 0;
        vm.prank(stranger);
        try vault.forwardERC721(address(works), id) {
            if (!expected) ++violations;
            holderOf[id] = to;
        } catch {
            if (expected) ++violations;
        }
    }

    function mintCopies(uint256 amount) external {
        amount = bound(amount, 1, 50);
        editions.mint(address(vault), EDITION, amount);
        copiesOf[address(vault)] += amount;
    }

    /// @dev Anyone forwards edition copies; more than held, or a destination that cannot hold
    ///      ERC-1155s, is refused.
    function forwardCopies(uint256 amount) external {
        address to = ghostDestination;
        amount = bound(amount, 1, copiesOf[address(vault)] + 2);
        bool expected = amount <= copiesOf[address(vault)] && to.code.length == 0;
        vm.prank(stranger);
        try vault.forwardERC1155(address(editions), EDITION, amount) {
            if (!expected) ++violations;
            copiesOf[address(vault)] -= amount;
            copiesOf[to] += amount;
        } catch {
            if (expected) ++violations;
        }
    }

    /// @dev The network (or, one time in four, the stranger) sets the destination, with the
    ///      current revision or a stale or future one, to a candidate (zero and the vault
    ///      itself are refused).
    function setDestination(uint256 destSeed, uint8 revisionSkew, uint8 who) external {
        address next = _candidates[destSeed % _candidates.length];
        uint64 revision = revisionSkew % 4 == 0
            ? ghostRevision + 1
            : revisionSkew % 4 == 1 ? ghostRevision - 1 : ghostRevision;
        address caller = who % 4 == 0 ? stranger : network;
        bool expected = caller == network && revision == ghostRevision && next != address(0)
            && next != address(vault);
        vm.prank(caller);
        try vault.setDestination(revision, next) {
            if (!expected) ++violations;
            if (caller != network || revision != ghostRevision) ++wrongChanges;
            ghostDestination = next;
            ++ghostRevision;
            ++destinationChanges;
        } catch {
            if (expected) ++violations;
            ++refusedChanges;
        }
    }

    /// @dev Royalties reach the wallet in which the vault is a payee.
    function payRoyalty(uint256 assetSeed, uint256 amount) external {
        address asset = assets[assetSeed % 4];
        amount = bound(amount, 1, 1e22);
        if (asset == ETH) vm.deal(royaltyWallet, royaltyWallet.balance + amount);
        else MockERC20(asset).mint(royaltyWallet, amount);
    }

    /// @dev Anyone pushes the vault's share to the vault (an inflow, measured).
    function pushShare(uint256 assetSeed) external {
        address asset = assets[assetSeed % 4];
        uint256 before = balanceOf(asset, address(vault));
        vm.prank(stranger);
        try ledger.release(_payees, bytes32(0), asset, _vaultIndex) {
            vaultModel[asset] += balanceOf(asset, address(vault)) - before;
        } catch { }
    }

    /// @dev Anyone releases the vault's share straight to the destination: what the ledger
    ///      releases arrives there and the vault's own holdings do not move.
    function releaseToDestination(uint256 assetSeed) external {
        address asset = assets[assetSeed % 4];
        address to = ghostDestination;
        uint256 vaultBefore = balanceOf(asset, address(vault));
        vm.prank(stranger);
        try vault.releaseToDestination(ledger, _payees, bytes32(0), asset, _vaultIndex) returns (
            uint256 amount
        ) {
            // The ledger pays the destination itself (the re-entering one acts only on the
            // vault's payments).
            received[to][asset] += amount;
            // The vault, as the ledger's network, may be paid its own network share here.
            uint256 vaultAfter = balanceOf(asset, address(vault));
            if (vaultAfter < vaultBefore) ++violations;
            vaultModel[asset] += vaultAfter - vaultBefore;
            ++releasedToDestination;
        } catch { }
    }

    function toggleBlock(bool blockVault) external {
        address who = blockVault ? address(vault) : ghostDestination;
        blocklist.setBlocked(who, !blocklist.blocked(who));
    }

    function toggleOpen() external {
        toggle.setOpen(!toggle.open());
    }

    function setSilent(bool silent) external {
        NoReturnToken(assets[2]).setSilent(silent);
    }
}

/// @notice ECO-41 as stateful invariants: the governed vault moves what it holds only to its
///         destination, the destination changes only by the network's compare-and-set call,
///         and a release of the vault's payee share goes to the destination. Run with the
///         foundry.toml campaign (256 runs x depth 128, `fail_on_revert`).
contract GovernedVaultInvariantTest is EconomicsBase {
    GovernedVaultHandler internal handler;
    address internal network = makeAddr("vaultNetwork");

    function setUp() public override {
        super.setUp();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IGovernedVault.setDestination.selector;
        manager.setTargetFunctionRole(address(feeVault), selectors, Roles.FUNDS_SETTER);
        manager.grantRole(Roles.FUNDS_SETTER, network, 0);
        handler = new GovernedVaultHandler(
            feeVault, ISplitLedger(address(ledger)), network, token, makeAddr("royaltySeller")
        );
        bytes4[] memory s = new bytes4[](14);
        s[0] = handler.fund.selector;
        s[1] = handler.forward.selector;
        s[2] = handler.forward.selector;
        s[3] = handler.mintWork.selector;
        s[4] = handler.forwardWork.selector;
        s[5] = handler.mintCopies.selector;
        s[6] = handler.forwardCopies.selector;
        s[7] = handler.setDestination.selector;
        s[8] = handler.payRoyalty.selector;
        s[9] = handler.pushShare.selector;
        s[10] = handler.releaseToDestination.selector;
        s[11] = handler.toggleBlock.selector;
        s[12] = handler.toggleOpen.selector;
        s[13] = handler.setSilent.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: s }));
    }

    /// INV-ECO-15 (ECO-41): the vault holds exactly what reached it less what it forwarded, and
    /// every account that could receive anything (each destination candidate, the network, a
    /// stranger, the royalty wallet's other payee) holds exactly what it received while it was
    /// the destination, through `forward` or `releaseToDestination`, and nothing otherwise;
    /// every work and copy is held by the vault or by the destination it was forwarded to.
    function invariant_HoldingsLeaveOnlyToTheDestination() public view {
        for (uint256 a; a < 5; ++a) {
            address asset = handler.assets(a);
            assertEq(
                handler.balanceOf(asset, address(feeVault)), handler.vaultModel(asset), "vault"
            );
            for (uint256 i; i < handler.universeCount(); ++i) {
                address account = handler.universe(i);
                assertEq(
                    handler.balanceOf(asset, account), handler.received(account, asset), "account"
                );
            }
        }
        VaultTest721 works = handler.works();
        for (uint256 id = 1; id <= handler.worksMinted(); ++id) {
            assertEq(works.ownerOf(id), handler.holderOf(id), "work");
        }
        VaultTest1155 editions = handler.editions();
        assertEq(editions.balanceOf(address(feeVault), 7), handler.copiesOf(address(feeVault)));
        for (uint256 i; i < handler.universeCount(); ++i) {
            address account = handler.universe(i);
            assertEq(editions.balanceOf(account, 7), handler.copiesOf(account), "copies");
        }
    }

    /// INV-ECO-16 (ECO-41): the destination is the one the network last set with the current
    /// revision, never zero or the vault, and the revision counts the changes; a stale or
    /// future revision, a stranger's call, and the re-entering destination's attempts to make
    /// itself the destination never succeed.
    function invariant_DestinationIsCompareAndSetByTheNetwork() public view {
        address d = feeVault.destination();
        assertEq(d, handler.ghostDestination(), "destination");
        assertEq(feeVault.destinationRevision(), handler.ghostRevision(), "revision");
        assertTrue(d != address(0) && d != address(feeVault), "a valid destination");
        assertEq(handler.reenter().seized(), 0, "seized by the destination");
        assertEq(handler.wrongChanges(), 0, "a change without the current revision or role");
    }

    /// INV-ECO-17: every forward and destination change had the outcome the model predicts:
    /// nothing to forward, more than held, a refusing destination, a blocked party, a token
    /// that delivers less than sent, a destination that cannot hold works, a stale revision and
    /// a stranger are refused, and everything else succeeds with exactly the predicted amount.
    function invariant_EveryCallHadThePredictedOutcome() public view {
        assertEq(handler.violations(), 0);
    }

    /// @notice Handler self-test: every action changes the vault, the tokens, the ledger or the
    ///         destination contracts, or is refused by the vault; forwards land and are refused,
    ///         the destination changes and is refused, a share is released to it. Then every
    ///         invariant holds.
    function test_HandlerPathsReachState() public {
        uint8 w = HandlerReach.WRITES;
        uint8 wr = HandlerReach.WRITES | HandlerReach.REFUSED;
        HandlerReach.Expect[] memory e = new HandlerReach.Expect[](13);
        e[0] = HandlerReach.Expect(handler.fund.selector, w);
        e[1] = HandlerReach.Expect(handler.forward.selector, wr);
        e[2] = HandlerReach.Expect(handler.mintWork.selector, w);
        e[3] = HandlerReach.Expect(handler.forwardWork.selector, wr);
        e[4] = HandlerReach.Expect(handler.mintCopies.selector, w);
        e[5] = HandlerReach.Expect(handler.forwardCopies.selector, wr);
        e[6] = HandlerReach.Expect(handler.setDestination.selector, wr);
        e[7] = HandlerReach.Expect(handler.payRoyalty.selector, w);
        e[8] = HandlerReach.Expect(handler.pushShare.selector, wr);
        e[9] = HandlerReach.Expect(handler.releaseToDestination.selector, wr);
        e[10] = HandlerReach.Expect(handler.toggleBlock.selector, w);
        e[11] = HandlerReach.Expect(handler.toggleOpen.selector, w);
        e[12] = HandlerReach.Expect(handler.setSilent.selector, w);
        HandlerReach.covers(targetSelectors()[0].selectors, e);
        address[] memory sut = new address[](11);
        sut[0] = address(feeVault);
        sut[1] = address(ledger);
        sut[2] = address(handler.works());
        sut[3] = address(handler.editions());
        sut[4] = address(handler.toggle());
        sut[5] = address(handler.reenter());
        for (uint256 a = 1; a < 5; ++a) {
            sut[5 + a] = handler.assets(a);
        }
        sut[10] = handler.royaltyWallet();
        // Sixteen campaign-length runs (10 rounds of 13 actions), each from the starting state
        // but the last, tallied together.
        HandlerReach.Tally[] memory t = new HandlerReach.Tally[](e.length);
        uint256[7] memory n;
        for (uint256 run; run < 16; ++run) {
            uint256 snapshot = vm.snapshotState();
            HandlerReach.add(t, HandlerReach.drive(address(handler), e, sut, 10, run));
            n[0] += handler.forwards();
            n[1] += handler.refusedForwards();
            n[2] += handler.destinationChanges();
            n[3] += handler.refusedChanges();
            n[4] += handler.releasedToDestination();
            n[5] += handler.reenter().seizeAttempts();
            n[6] += address(handler.reenter()).balance;
            if (run < 15) vm.revertToState(snapshot);
        }
        HandlerReach.check(e, t);
        assertGt(n[0], 0, "forwards");
        assertGt(n[1], 0, "refused forwards");
        assertGt(n[2], 0, "destination changes");
        assertGt(n[3], 0, "refused changes");
        assertGt(n[4], 0, "released to the destination");
        assertGt(n[5], 0, "re-entries by the destination");
        assertGt(n[6], 0, "ETH pulled by the re-entering destination");
        invariant_HoldingsLeaveOnlyToTheDestination();
        invariant_DestinationIsCompareAndSetByTheNetwork();
        invariant_EveryCallHadThePredictedOutcome();
    }
}
