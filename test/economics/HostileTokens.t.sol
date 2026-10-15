// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SplitWallet } from "src/economics/SplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    BlocklistToken,
    FeeOnTransferToken,
    MockERC20,
    NoReturnToken,
    NonCanonicalTrueToken,
    RebasingToken,
    RevertOnZeroToken,
    SenderFeeToken,
    ReturnsFalseToken
} from "../mocks/economics/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

/// @notice The hostile-token matrix. Every money path (payment with escrow fallback, escrow
///         deposit, wallet release, escrow flush) is run against fee-on-transfer, no-return,
///         returns-false, rebasing and USDC-style blocklisting tokens. Each must either revert
///         atomically or route to escrow, and leave no residue: no balance, credit or allowance
///         changes after a revert.
contract HostileTokenMatrixTest is EconomicsBase {
    uint256 internal constant AMOUNT = 1000;
    address internal depositor = makeAddr("depositor");
    SplitWallet internal wallet;

    struct Snapshot {
        uint256 payer;
        uint256 wallet;
        uint256 escrow;
        uint256 owed;
        uint256 totalOwed;
        uint256 allowance;
        uint256 released;
    }

    function setUp() public override {
        super.setUp();
        wallet = _wallet(_list(_fixed(alice, 60_000), _fixed(bob, 40_000)));
    }

    function _fund(MockERC20 t) internal {
        t.mint(address(payer), 10 * AMOUNT);
        t.mint(depositor, 10 * AMOUNT);
        vm.prank(depositor);
        t.approve(address(escrow), type(uint256).max);
    }

    function _snap(address t) internal view returns (Snapshot memory s) {
        s.payer = IERC20(t).balanceOf(address(payer));
        s.wallet = IERC20(t).balanceOf(address(wallet));
        s.escrow = IERC20(t).balanceOf(address(escrow));
        s.owed = escrow.owed(address(wallet), t);
        s.totalOwed = escrow.totalOwed(t);
        s.allowance = IERC20(t).allowance(address(payer), address(escrow));
        s.released = wallet.totalReleased(t);
    }

    function _assertNoResidue(address t, Snapshot memory before) internal view {
        Snapshot memory afterwards = _snap(t);
        assertEq(afterwards.payer, before.payer, "payer residue");
        assertEq(afterwards.wallet, before.wallet, "wallet residue");
        assertEq(afterwards.escrow, before.escrow, "escrow residue");
        assertEq(afterwards.owed, before.owed, "credit residue");
        assertEq(afterwards.totalOwed, before.totalOwed, "total credit residue");
        assertEq(afterwards.allowance, before.allowance, "allowance residue");
        assertEq(afterwards.released, before.released, "release residue");
    }

    function _mismatch(address t) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, t);
    }

    function _failed(address t, bytes4 selector) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(TokenTransfer.TokenCallFailed.selector, t, selector);
    }

    // ---------------------------------------------------------------- fee-on-transfer

    function test_FeeOnTransfer_PaymentRevertsAtomically() public {
        FeeOnTransferToken t = new FeeOnTransferToken();
        _fund(t);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_mismatch(address(t)));
        payer.payERC20(address(wallet), address(t), AMOUNT);
        _assertNoResidue(address(t), before);
    }

    function test_FeeOnTransfer_EscrowDepositReverts() public {
        FeeOnTransferToken t = new FeeOnTransferToken();
        _fund(t);
        Snapshot memory before = _snap(address(t));
        vm.prank(depositor);
        vm.expectRevert(_mismatch(address(t)));
        escrow.depositERC20(address(wallet), address(t), AMOUNT);
        _assertNoResidue(address(t), before);
    }

    function test_FeeOnTransfer_ReleaseReverts() public {
        FeeOnTransferToken t = new FeeOnTransferToken();
        t.mint(address(wallet), AMOUNT);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_mismatch(address(t)));
        wallet.release(address(t), 0);
        _assertNoResidue(address(t), before);
        assertEq(wallet.recordedObserved(address(t)), 0);
    }

    function test_FeeOnTransfer_FlushRevertsAndKeepsCredit() public {
        FeeOnTransferToken t = new FeeOnTransferToken();
        _fund(t);
        t.setFee(0);
        vm.prank(depositor);
        escrow.depositERC20(address(wallet), address(t), AMOUNT);
        t.setFee(100);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_mismatch(address(t)));
        escrow.flush(address(wallet), address(t));
        _assertNoResidue(address(t), before);
        assertEq(before.owed, AMOUNT);
    }

    /// @dev Review L-3, ported from `test_PoC_SenderSideFeeFailsClosedEverywhere`: a fee charged
    ///      to the sender leaves the recipient whole, so only the sender-side check catches it.
    function test_SenderFee_FailsClosedOnEveryPath() public {
        SenderFeeToken t = new SenderFeeToken();
        _fund(t);
        t.mint(address(wallet), AMOUNT);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_mismatch(address(t)));
        wallet.release(address(t), 0);
        vm.expectRevert(_mismatch(address(t)));
        payer.payERC20(address(wallet), address(t), AMOUNT);
        vm.prank(depositor);
        vm.expectRevert(_mismatch(address(t)));
        escrow.depositERC20(address(wallet), address(t), AMOUNT);
        _assertNoResidue(address(t), before);
    }

    // ---------------------------------------------------------------- non-canonical true

    /// @dev Review L-3: a token that returns the word 2 is not returning `true`.
    function test_NonCanonicalTrue_FailsClosedOnEveryPath() public {
        NonCanonicalTrueToken t = new NonCanonicalTrueToken();
        _fund(t);
        t.mint(address(wallet), AMOUNT);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_failed(address(t), IERC20.transfer.selector));
        wallet.release(address(t), 0);
        vm.expectRevert(_failed(address(t), IERC20.transfer.selector));
        payer.payERC20(address(wallet), address(t), AMOUNT);
        vm.prank(depositor);
        vm.expectRevert(_failed(address(t), IERC20.transferFrom.selector));
        escrow.depositERC20(address(wallet), address(t), AMOUNT);
        _assertNoResidue(address(t), before);
    }

    // ---------------------------------------------------------------- odd return shapes

    /// @dev Only a 32-byte word of exactly 0 or 1 is an answer: a `true` with more data after
    ///      it, or a word whose upper bits are set, fails closed; a `balanceOf` that returns more
    ///      than one word fails the read; a reverting `approve` fails the escrow route
    ///      (mutation testing: each of these was unpinned).
    function test_OddReturnShapes_FailClosed() public {
        for (uint8 mode = 1; mode <= 2; ++mode) {
            OddReturnToken t = new OddReturnToken();
            t.mint(address(wallet), AMOUNT);
            t.setMode(mode);
            vm.expectRevert(_failed(address(t), IERC20.transfer.selector));
            wallet.release(address(t), 0);
        }
        OddReturnToken r = new OddReturnToken();
        r.mint(address(wallet), AMOUNT);
        r.setMode(3);
        vm.expectRevert(abi.encodeWithSelector(TokenTransfer.TokenReadFailed.selector, address(r)));
        wallet.release(address(r), 0);

        OddReturnToken a = new OddReturnToken();
        _fund(a);
        a.setMode(4);
        Snapshot memory before = _snap(address(a));
        vm.expectRevert(_failed(address(a), IERC20.approve.selector));
        payer.payERC20(address(wallet), address(a), AMOUNT);
        _assertNoResidue(address(a), before);
    }

    /// @dev Balances above 2**128 are read and moved exactly.
    function test_HugeBalancesAreReadExactly() public {
        MockERC20 t = new MockERC20("Huge", "HUGE");
        uint256 huge = (1 << 200) + 12_345;
        t.mint(address(wallet), huge);
        uint256 iAlice = _indexOf(wallet, alice);
        uint256 paid = wallet.release(address(t), iAlice);
        assertEq(paid, Splits.entitlement(huge, 60_000));
        assertEq(t.balanceOf(alice), paid);
        assertEq(t.balanceOf(address(wallet)), huge - paid);
    }

    // ---------------------------------------------------------------- reverts on zero

    /// @dev Ported from the review: a token that reverts on zero-value moves never sees one.
    function test_RevertOnZero_NeverSeesAZeroMove() public {
        RevertOnZeroToken t = new RevertOnZeroToken();
        // A 1-in-100,000 payee: 99 units round its entitlement to zero.
        SplitWallet w = _wallet(_list(_fixed(alice, 1), _fixed(bob, D - 1)));
        uint256 iAlice = _indexOf(w, alice);
        t.mint(address(payer), 1000);
        assertFalse(payer.payERC20(address(w), address(t), 0));
        assertFalse(payer.payERC20(address(w), address(t), 99));
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, address(t), iAlice)
        );
        w.release(address(t), iAlice);
        assertEq(w.release(address(t), _indexOf(w, bob)), 98);
    }

    // ---------------------------------------------------------------- no return value

    function test_NoReturn_PaymentRevertsAtomically() public {
        NoReturnToken t = new NoReturnToken();
        _fund(t);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_failed(address(t), IERC20.transfer.selector));
        payer.payERC20(address(wallet), address(t), AMOUNT);
        _assertNoResidue(address(t), before);
    }

    function test_NoReturn_EscrowDepositReverts() public {
        NoReturnToken t = new NoReturnToken();
        _fund(t);
        Snapshot memory before = _snap(address(t));
        vm.prank(depositor);
        vm.expectRevert(_failed(address(t), IERC20.transferFrom.selector));
        escrow.depositERC20(address(wallet), address(t), AMOUNT);
        _assertNoResidue(address(t), before);
    }

    function test_NoReturn_ReleaseReverts() public {
        NoReturnToken t = new NoReturnToken();
        t.mint(address(wallet), AMOUNT);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_failed(address(t), IERC20.transfer.selector));
        wallet.release(address(t), 0);
        _assertNoResidue(address(t), before);
    }

    function test_NoReturn_FlushRevertsAndKeepsCredit() public {
        NoReturnToken t = new NoReturnToken();
        _fund(t);
        t.setSilent(false);
        vm.prank(depositor);
        escrow.depositERC20(address(wallet), address(t), AMOUNT);
        t.setSilent(true);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_failed(address(t), IERC20.transfer.selector));
        escrow.flush(address(wallet), address(t));
        _assertNoResidue(address(t), before);
    }

    // ---------------------------------------------------------------- returns false

    function test_ReturnsFalse_PaymentTriesEscrowThenRevertsAtomically() public {
        ReturnsFalseToken t = new ReturnsFalseToken();
        _fund(t);
        Snapshot memory before = _snap(address(t));
        // The refused transfer routes to escrow, whose pull is refused too: the whole payment
        // reverts, including the approval it made.
        vm.expectRevert(_failed(address(t), IERC20.transferFrom.selector));
        payer.payERC20(address(wallet), address(t), AMOUNT);
        _assertNoResidue(address(t), before);
    }

    function test_ReturnsFalse_LyingTokenThatMovesFundsReverts() public {
        ReturnsFalseToken t = new ReturnsFalseToken();
        _fund(t);
        t.setMode(2);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_mismatch(address(t)));
        payer.payERC20(address(wallet), address(t), AMOUNT);
        _assertNoResidue(address(t), before);
    }

    function test_ReturnsFalse_EscrowDepositReverts() public {
        ReturnsFalseToken t = new ReturnsFalseToken();
        _fund(t);
        Snapshot memory before = _snap(address(t));
        vm.prank(depositor);
        vm.expectRevert(_failed(address(t), IERC20.transferFrom.selector));
        escrow.depositERC20(address(wallet), address(t), AMOUNT);
        _assertNoResidue(address(t), before);
    }

    function test_ReturnsFalse_ReleaseReverts() public {
        ReturnsFalseToken t = new ReturnsFalseToken();
        t.mint(address(wallet), AMOUNT);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_failed(address(t), IERC20.transfer.selector));
        wallet.release(address(t), 0);
        _assertNoResidue(address(t), before);
    }

    function test_ReturnsFalse_FlushRevertsAndKeepsCredit() public {
        ReturnsFalseToken t = new ReturnsFalseToken();
        _fund(t);
        t.setMode(0);
        vm.prank(depositor);
        escrow.depositERC20(address(wallet), address(t), AMOUNT);
        t.setMode(1);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_failed(address(t), IERC20.transfer.selector));
        escrow.flush(address(wallet), address(t));
        _assertNoResidue(address(t), before);
    }

    /// @dev The escrow route approves the escrow first; a token that refuses the approval
    ///      (returns `false`) fails the whole payment, the approval included.
    function test_ReturnsFalse_RefusedApprovalRevertsTheEscrowRouteAtomically() public {
        ApprovalRefusingToken t = new ApprovalRefusingToken();
        _fund(t);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_failed(address(t), IERC20.approve.selector));
        payer.payERC20(address(wallet), address(t), AMOUNT);
        _assertNoResidue(address(t), before);
    }

    /// @dev A refusal must move nothing: a token that returns `false` after taking the payer's
    ///      tokens without delivering them (or delivering without taking) is a balance mismatch,
    ///      not a refusal to route around (mutation testing: the check once needed both sides to
    ///      move to count).
    function test_ReturnsFalse_OneSidedMoveIsAMismatchNotARefusal() public {
        for (uint8 side; side < 2; ++side) {
            OneSidedFalseToken t = new OneSidedFalseToken(side);
            _fund(t);
            Snapshot memory before = _snap(address(t));
            vm.expectRevert(_mismatch(address(t)));
            payer.payERC20(address(wallet), address(t), AMOUNT);
            _assertNoResidue(address(t), before);
        }
    }

    // ---------------------------------------------------------------- rebasing

    function test_Rebasing_RoundingPaymentRevertsAtomically() public {
        RebasingToken t = new RebasingToken();
        t.setIndex(3e18);
        _fund(t);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_mismatch(address(t)));
        payer.payERC20(address(wallet), address(t), 10);
        _assertNoResidue(address(t), before);
    }

    function test_Rebasing_RoundingDepositAndReleaseRevert() public {
        RebasingToken t = new RebasingToken();
        t.setIndex(3e18);
        _fund(t);
        // 1001 shares: no payee entitlement is a whole number of shares.
        t.mint(address(wallet), 3003);
        Snapshot memory before = _snap(address(t));
        vm.prank(depositor);
        vm.expectRevert(_mismatch(address(t)));
        escrow.depositERC20(address(wallet), address(t), 10);
        vm.expectRevert(_mismatch(address(t)));
        wallet.release(address(t), 0);
        _assertNoResidue(address(t), before);
    }

    function test_Rebasing_NegativeRebaseFreezesReleasesWithoutLoss() public {
        RebasingToken t = new RebasingToken();
        t.mint(address(wallet), AMOUNT);
        wallet.release(address(t), _indexOf(wallet, alice));
        t.setIndex(0.9e18);
        uint256 iBob = _indexOf(wallet, bob);
        Snapshot memory before = _snap(address(t));
        // 600 released to alice; the 400 left shrink to 360.
        vm.expectRevert(
            abi.encodeWithSelector(
                ISplitWallet.ObservedDecreased.selector, address(t), AMOUNT, 600 + 360
            )
        );
        wallet.release(address(t), iBob);
        _assertNoResidue(address(t), before);
    }

    function test_Rebasing_PositiveRebaseIsSplitByShare() public {
        RebasingToken t = new RebasingToken();
        t.mint(address(wallet), AMOUNT);
        t.setIndex(2e18);
        assertEq(wallet.release(address(t), _indexOf(wallet, alice)), 1200);
        assertEq(wallet.release(address(t), _indexOf(wallet, bob)), 800);
    }

    function test_Rebasing_EscrowShortfallRevertsFlushAndKeepsCredit() public {
        RebasingToken t = new RebasingToken();
        _fund(t);
        vm.prank(depositor);
        escrow.depositERC20(address(wallet), address(t), AMOUNT);
        t.setIndex(0.5e18);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_mismatch(address(t)));
        escrow.flush(address(wallet), address(t));
        _assertNoResidue(address(t), before);
    }

    // ---------------------------------------------------------------- blocklist (USDC-style)

    function test_Blocklist_BlockedWalletPaymentRoutesToEscrow() public {
        BlocklistToken t = new BlocklistToken();
        _fund(t);
        t.setBlocked(address(wallet), true);
        assertTrue(payer.payERC20(address(wallet), address(t), AMOUNT));
        assertEq(escrow.owed(address(wallet), address(t)), AMOUNT);
        assertEq(t.balanceOf(address(escrow)), AMOUNT);
        assertEq(t.allowance(address(payer), address(escrow)), 0);
    }

    function test_Blocklist_BlockedPayerRevertsAtomically() public {
        BlocklistToken t = new BlocklistToken();
        _fund(t);
        t.setBlocked(address(payer), true);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_failed(address(t), IERC20.transferFrom.selector));
        payer.payERC20(address(wallet), address(t), AMOUNT);
        _assertNoResidue(address(t), before);
    }

    function test_Blocklist_BlockedWalletAndEscrowRevertsAtomically() public {
        BlocklistToken t = new BlocklistToken();
        _fund(t);
        t.setBlocked(address(wallet), true);
        t.setBlocked(address(escrow), true);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_failed(address(t), IERC20.transferFrom.selector));
        payer.payERC20(address(wallet), address(t), AMOUNT);
        _assertNoResidue(address(t), before);
    }

    function test_Blocklist_BlockedPayeeReleaseRevertsAndRedirectWorks() public {
        BlocklistToken t = new BlocklistToken();
        t.mint(address(wallet), AMOUNT);
        t.setBlocked(alice, true);
        uint256 iAlice = _indexOf(wallet, alice);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_failed(address(t), IERC20.transfer.selector));
        wallet.release(address(t), iAlice);
        _assertNoResidue(address(t), before);
        vm.prank(alice);
        wallet.releaseTo(address(t), iAlice, bob);
        assertEq(t.balanceOf(bob), 600);
    }

    function test_Blocklist_BlockedWalletFlushKeepsCreditUntilUnblocked() public {
        BlocklistToken t = new BlocklistToken();
        _fund(t);
        t.setBlocked(address(wallet), true);
        payer.payERC20(address(wallet), address(t), AMOUNT);
        Snapshot memory before = _snap(address(t));
        vm.expectRevert(_failed(address(t), IERC20.transfer.selector));
        escrow.flush(address(wallet), address(t));
        _assertNoResidue(address(t), before);
        t.setBlocked(address(wallet), false);
        escrow.flush(address(wallet), address(t));
        assertEq(t.balanceOf(address(wallet)), AMOUNT);
        assertEq(escrow.totalOwed(address(t)), 0);
    }
}

/// @dev Refuses transfers and approvals by returning `false` (and moving nothing).
contract ApprovalRefusingToken is ReturnsFalseToken {
    function approve(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev `transfer` returns `false` but moves one side only: side 0 takes the sender's tokens and
///      credits nobody, side 1 credits the recipient and takes nothing.
contract OneSidedFalseToken is MockERC20("OneSided", "ONE") {
    uint8 internal immutable side;

    constructor(uint8 side_) {
        side = side_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (side == 0) _balances[msg.sender] -= amount;
        else _balances[to] += amount;
        return false;
    }
}

/// @dev Mode 1: `transfer` moves and returns a word with its upper bits set over a `true`.
///      Mode 2: `transfer` moves and returns `true` followed by a second word. Mode 3:
///      `balanceOf` returns two words. Mode 4: `transfer` refuses (returns false) and
///      `approve` reverts.
contract OddReturnToken is MockERC20("Odd", "ODD") {
    uint8 public mode;

    function setMode(uint8 mode_) external {
        mode = mode_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == 4) return false;
        _transfer(msg.sender, to, amount);
        if (mode == 1) {
            assembly ("memory-safe") {
                mstore(0, add(shl(128, 1), 1))
                return(0, 32)
            }
        }
        if (mode == 2) {
            assembly ("memory-safe") {
                mstore(0, 1)
                mstore(32, 1)
                return(0, 64)
            }
        }
        return true;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (mode == 4) revert("no approvals");
        return super.approve(spender, amount);
    }

    function balanceOf(address account) public view override returns (uint256) {
        uint256 held = _balances[account];
        if (mode == 3) {
            assembly ("memory-safe") {
                mstore(0, held)
                mstore(32, 0)
                return(0, 64)
            }
        }
        return held;
    }
}
