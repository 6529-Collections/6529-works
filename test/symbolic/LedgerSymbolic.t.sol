// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { Splits } from "src/economics/Splits.sol";
import { SplitVault } from "src/economics/SplitVault.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitLedger } from "src/economics/interfaces/ISplitLedger.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";

/// @dev Shared helpers for the stateful proofs in test/symbolic (docs/testing/README.md,
///      "Symbolic"). The name avoids "Symbolic" so Halmos's contract filter skips it.
abstract contract SymHelpers is Test {
    /// @dev Calls `target` as `caller` and returns whether it succeeded and the revert selector.
    function _call(address caller, address target, bytes memory data)
        internal
        returns (bool ok, bytes4 err)
    {
        bytes memory ret;
        vm.prank(caller);
        (ok, ret) = target.call(data);
        if (!ok && ret.length >= 4) err = bytes4(ret);
    }

    // Branch-free Boolean helpers, after 6529-provenance's RegistrySymbolic.t.sol. Solidity
    // compiles `&&`, `||` and `?:` to jumps, and Halmos splits the paths at each jump on a
    // symbolic value; these compile to single opcodes.

    function _and(bool a, bool b) internal pure returns (bool r) {
        assembly ("memory-safe") {
            r := and(a, b)
        }
    }

    function _or(bool a, bool b) internal pure returns (bool r) {
        assembly ("memory-safe") {
            r := or(a, b)
        }
    }

    function _not(bool a) internal pure returns (bool r) {
        assembly ("memory-safe") {
            r := iszero(a)
        }
    }

    function _toUint(bool a) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := a
        }
    }

    function _pick(bool flag, uint256 whenTrue, uint256 whenFalse)
        internal
        pure
        returns (uint256 r)
    {
        assembly ("memory-safe") {
            r := xor(whenFalse, mul(xor(whenTrue, whenFalse), flag))
        }
    }

    function _pickAddr(bool flag, address whenTrue, address whenFalse)
        internal
        pure
        returns (address r)
    {
        assembly ("memory-safe") {
            r := xor(whenFalse, mul(xor(whenTrue, whenFalse), flag))
        }
    }
}

/// @dev An artist payout resolver that answers whatever the proof set.
contract SymResolver is IArtistPayoutResolver {
    mapping(uint256 => address) public payout;
    /// @dev `IDirectory.unclaimedPeriod`, read by the ledger at a forfeit.
    uint48 public unclaimedPeriod = 180 days;

    function setUnclaimedPeriod(uint48 next) external {
        unclaimedPeriod = next;
    }

    function set(uint256 artistId, address account) external {
        payout[artistId] = account;
    }

    function payoutAddress(uint256 artistId) external view returns (address) {
        return payout[artistId];
    }
}

/// @dev Accepts ETH from anyone: the network fee vault in the ledger proofs.
contract SymSink {
    receive() external payable { }
}

/// @dev An ERC-1271 payout account that accepts every signature, so the signed-release proofs
///      test the ledger's replay rules for every authorization, not the signature scheme.
contract SymSigner {
    receive() external payable { }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    function revoke(SplitLedger ledger, uint256 nonce) external {
        ledger.revokeNonce(nonce);
    }
}

/// @dev Refuses ETH, so a release to it fails at the payment.
contract SymRefuser { }

/// @notice Halmos proofs of the split ledger's state rules on the real `SplitLedger` and its
///         66-byte wallets (docs/testing/README.md, "Symbolic"). Every proof is ETH-only: the
///         ERC-20 path differs in the balance reads, which the unit and invariant suites cover.
/// @dev Payee accounts are fixed EOA-like addresses; receipts are 64-bit so the share division
///      stays inside what the solver decides (a 256-bit division times out, see
///      `SplitsSymbolicTest`).
contract LedgerSymbolicTest is SymHelpers {
    uint32 internal constant D = 100_000;
    uint256 internal constant ARTIST = 7;
    address internal constant ETH = address(0);
    address internal constant A = address(0xA001);
    address internal constant B = address(0xA002);
    address internal constant C = address(0xA003);
    address internal constant HIGH = address(0xf00000000000000000000000000000000000000f);

    SplitLedger internal ledger;
    SymResolver internal resolver;
    SymSink internal network;

    function setUp() public {
        resolver = new SymResolver();
        network = new SymSink();
        ledger = new SplitLedger(resolver, address(network));
    }

    // ---------------------------------------------------------------------------------------
    // Entitlement: ECO-13, INV-ECO-2
    // ---------------------------------------------------------------------------------------

    /// @notice ECO-13, INV-ECO-2: whatever its share and the receipts, a payee's releases add up
    ///         to exactly `Splits.entitlement(observed, share)` at its last release, so never
    ///         more; a release that arrives between two others only adds what the new receipts
    ///         entitle it to; a repeat at the same receipts releases nothing; every wei that
    ///         leaves the wallet is counted in `totalReleased`; the other payee is untouched.
    /// @dev Bounds: 2 fixed payees with any shares summing to 100,000; either payee; two
    ///      deposits of any 64-bit amount, a release after each. Not proved here: that the
    ///      formula equals `floor(observed * share / 100,000)`, and that the payees'
    ///      entitlements sum to at most `observed` with dust below the payee count. Both are
    ///      256-bit division facts the solver does not decide (see `SplitsSymbolicTest`); with
    ///      both payees released in one proof the paths (about 1,350, each with division terms)
    ///      did not finish in 30 minutes. They stay with the fuzz tests and the economics
    ///      invariants.
    function check_release_neverExceedsEntitlement(uint64 r1, uint64 r2, uint32 s0, bool second)
        public
    {
        vm.assume(s0 != 0 && s0 < D);
        ISplitWallet.Payee[] memory p = new ISplitWallet.Payee[](2);
        p[0] = ISplitWallet.Payee(0, A, s0);
        p[1] = ISplitWallet.Payee(0, B, D - s0);
        address wallet = ledger.createWallet(p, bytes32(0));
        uint256 i = second ? 1 : 0;
        vm.deal(wallet, r1);
        // A concrete index per branch: a symbolic payee index would make a symbolic calldata
        // offset, which Halmos cannot follow.
        if (second) _checkRelease(p, wallet, 1, r1);
        else _checkRelease(p, wallet, 0, r1);
        vm.deal(wallet, wallet.balance + r2);
        uint256 received = uint256(r1) + r2;
        if (second) _checkRelease(p, wallet, 1, received);
        else _checkRelease(p, wallet, 0, received);
        assert(ledger.released(wallet, ETH, 1 - i) == 0);
        assert(wallet.balance + ledger.totalReleased(wallet, ETH) == received);
        assert(ledger.totalReleased(wallet, ETH) == ledger.released(wallet, ETH, i));
    }

    /// @dev Releases payee `index` at receipts `observed`; a success leaves the payee's total
    ///      at exactly the formula, pays its account the difference, and a repeat releases
    ///      nothing.
    function _checkRelease(
        ISplitWallet.Payee[] memory p,
        address wallet,
        uint256 index,
        uint256 observed
    ) internal {
        uint256 before = ledger.released(wallet, ETH, index);
        uint256 paidBefore = p[index].account.balance;
        (bool ok,) = _call(C, address(ledger), abi.encodeCall(ledger.release, (p, 0, ETH, index)));
        uint256 after_ = ledger.released(wallet, ETH, index);
        if (!ok) {
            assert(after_ == before);
            return;
        }
        assert(after_ == Splits.entitlement(observed, p[index].share));
        assert(p[index].account.balance - paidBefore == after_ - before);
        (bool again, bytes4 err) =
            _call(C, address(ledger), abi.encodeCall(ledger.release, (p, 0, ETH, index)));
        assert(!again && err == ISplitWallet.NothingToRelease.selector);
    }

    // ---------------------------------------------------------------------------------------
    // Who is paid: ECO-15, ECO-16, ECO-17
    // ---------------------------------------------------------------------------------------

    /// @notice ECO-15, ECO-17: anyone may release a fixed payee, and the money goes to that
    ///         payee's account and nowhere else; `releaseTo` succeeds only for the payee's own
    ///         account as caller and never pays zero, the wallet or the ledger.
    /// @dev Bounds: any caller; any 64-bit receipts; two fixed payees; the recipient one of
    ///      zero, the wallet, the ledger, the payee itself and another account (a symbolic
    ///      recipient address multiplies the paths past the time budget).
    function check_release_paysOnlyThePayeesOwnAccount(
        address caller,
        uint8 recipientKind,
        uint64 receipts,
        bool viaReleaseTo
    ) public {
        (ISplitWallet.Payee[] memory p, address wallet) = _pair();
        vm.deal(wallet, receipts);
        vm.assume(caller != wallet && caller != address(ledger));
        // A and C start empty, so their balances afterwards are what they were paid.
        address recipient = recipientKind == 0
            ? address(0)
            : recipientKind == 1
                ? wallet
                : recipientKind == 2 ? address(ledger) : recipientKind == 3 ? A : C;
        uint256 due = Splits.entitlement(receipts, 60_000);

        (bool ok, bytes4 err) = _call(
            caller,
            address(ledger),
            viaReleaseTo
                ? abi.encodeCall(ledger.releaseTo, (p, 0, ETH, 0, recipient))
                : abi.encodeCall(ledger.release, (p, 0, ETH, 0))
        );
        uint256 paid = ledger.released(wallet, ETH, 0);
        assert(B.balance == 0 && ledger.released(wallet, ETH, 1) == 0);
        assert(paid == _pick(ok, due, 0));
        assert(wallet.balance == uint256(receipts) - paid);
        if (!viaReleaseTo) {
            assert(ok == (due != 0) && A.balance == paid);
        } else if (caller != A) {
            assert(!ok && err == ISplitWallet.NotPayoutAddress.selector);
        } else if (recipientKind <= 2) {
            assert(!ok && err == ISplitWallet.InvalidRecipient.selector);
        } else {
            assert(ok == (due != 0) && recipient.balance == paid);
        }
    }

    /// @notice ECO-16: an artist-resolved payee is released only by the artist's payout address
    ///         at the time of the call, by `release` or `releaseTo`; after the payout address
    ///         changes, the old one releases nothing, and nobody can push the share to it.
    /// @dev Bounds: any caller; any 64-bit receipts; the old and the new payout address and the
    ///      recipient fixed accounts (symbolic ones multiply the paths past the time budget).
    function check_artistPayee_onlyTheCurrentPayoutReleases(
        address caller,
        uint64 receipts,
        bool viaReleaseTo
    ) public {
        address oldPayout = address(0xB001);
        address newPayout = address(0xB002);
        address recipient = address(0xB003);
        ISplitWallet.Payee[] memory p = new ISplitWallet.Payee[](2);
        p[0] = ISplitWallet.Payee(0, A, 50_000);
        p[1] = ISplitWallet.Payee(ARTIST, address(0), 50_000);
        address wallet = ledger.createWallet(p, bytes32(0));
        vm.assume(caller != wallet && caller != address(ledger));
        vm.deal(wallet, receipts);
        resolver.set(ARTIST, oldPayout);
        resolver.set(ARTIST, newPayout);
        uint256 oldBefore = oldPayout.balance;

        bytes memory data = viaReleaseTo
            ? abi.encodeCall(ledger.releaseTo, (p, 0, ETH, 1, recipient))
            : abi.encodeCall(ledger.release, (p, 0, ETH, 1));
        (bool ok, bytes4 err) = _call(caller, address(ledger), data);
        if (caller != newPayout) {
            assert(!ok && err == ISplitWallet.NotPayoutAddress.selector);
            assert(ledger.released(wallet, ETH, 1) == 0);
        } else {
            assert(ok == (Splits.entitlement(receipts, 50_000) != 0));
        }
        assert(oldPayout.balance == oldBefore);
    }

    // ---------------------------------------------------------------------------------------
    // Signed releases: ECO-20, ECO-21, ECO-22
    // ---------------------------------------------------------------------------------------

    /// @notice ECO-20: a signed release works once per `(account, nonce)`: a second
    ///         authorization with the same nonce reverts with `NonceAlreadyUsed` whatever its
    ///         other fields, and so does one whose nonce the account revoked; an authorization
    ///         names one wallet and expires at its deadline.
    /// @dev Bounds: any nonce, amounts, recipients and deadline; the payout account is an
    ///      ERC-1271 contract that accepts every signature, so only the ledger's rules decide.
    function check_signedRelease_nonceIsSingleUse(
        uint256 nonce,
        uint64 receipts,
        uint64 amount1,
        uint64 amount2,
        uint256 deadline,
        uint8 action
    ) public {
        SymSigner signer = new SymSigner();
        ISplitWallet.Payee[] memory p = _signerWallet(address(signer));
        address wallet = ledger.walletFor(p, 0);
        vm.deal(wallet, receipts);
        IReleaseVerifier.Authorization memory auth = IReleaseVerifier.Authorization(
            wallet, ETH, 0, address(signer), A, amount1, nonce, deadline
        );
        // Actions 0 to 2 test the nonce and the wallet, so their authorizations are in time.
        if (action < 3) vm.assume(deadline >= block.timestamp);

        if (action == 0) {
            // Replay: the same nonce twice.
            (bool ok1,) = _call(B, address(ledger), _signed(p, auth));
            vm.assume(ok1);
            assert(ledger.nonceUsed(address(signer), nonce));
            auth.amount = amount2;
            auth.recipient = B;
            (bool ok2, bytes4 err2) = _call(B, address(ledger), _signed(p, auth));
            assert(!ok2 && err2 == IReleaseVerifier.NonceAlreadyUsed.selector);
        } else if (action == 1) {
            // Revocation: the account spends the nonce first.
            signer.revoke(ledger, nonce);
            (bool ok, bytes4 err) = _call(B, address(ledger), _signed(p, auth));
            assert(!ok && err == IReleaseVerifier.NonceAlreadyUsed.selector);
            assert(ledger.released(wallet, ETH, 0) == 0);
        } else if (action == 2) {
            // Another wallet: the same payees under another salt.
            address other = ledger.createWallet(p, bytes32(uint256(1)));
            vm.deal(other, receipts);
            (bool ok, bytes4 err) = _call(B, address(ledger), _signed(p, auth, bytes32(uint256(1))));
            assert(!ok && err == ISplitWallet.WrongWallet.selector);
            assert(!ledger.nonceUsed(address(signer), nonce));
        } else {
            // The deadline.
            (bool ok, bytes4 err) = _call(B, address(ledger), _signed(p, auth));
            if (block.timestamp > deadline) {
                assert(!ok && err == SignatureVerifier.SignatureExpired.selector);
            }
            assert(ok == ledger.nonceUsed(address(signer), nonce));
        }
    }

    /// @notice ECO-21: replay protection is a bitmap keyed on `(account, nonce)`: using one nonce
    ///         marks exactly that nonce, for exactly that account, and no other nonce in its word
    ///         or any other word.
    /// @dev Unbounded: any account, any two nonces, any other account.
    function check_nonces_inOneWordAreIndependent(
        address account,
        address other,
        uint256 used,
        uint256 probe
    ) public {
        vm.assume(other != account);
        vm.prank(account);
        ledger.revokeNonce(used);
        assert(ledger.nonceUsed(account, probe) == (probe == used));
        assert(!ledger.nonceUsed(other, probe));
        // A second nonce in the same word is independent of the first.
        uint256 sibling = (used & ~uint256(0xff)) | (probe & 0xff);
        vm.assume(sibling != used);
        assert(!ledger.nonceUsed(account, sibling));
        vm.prank(account);
        ledger.revokeNonce(sibling);
        assert(ledger.nonceUsed(account, used) && ledger.nonceUsed(account, sibling));
    }

    /// @notice ECO-22: a signed release that fails, for an amount above what is releasable or
    ///         a payment the recipient refuses, leaves its nonce unused and nothing released.
    /// @dev Bounds: any 64-bit receipts and amount, any nonce; the recipient refuses or accepts.
    function check_failedSignedRelease_keepsItsNonce(
        uint256 nonce,
        uint64 receipts,
        uint256 amount,
        bool refusingRecipient
    ) public {
        // The all-due sentinel is not an amount.
        vm.assume(amount != type(uint256).max);
        SymSigner signer = new SymSigner();
        ISplitWallet.Payee[] memory p = _signerWallet(address(signer));
        address wallet = ledger.walletFor(p, 0);
        vm.deal(wallet, receipts);
        address recipient = refusingRecipient ? address(new SymRefuser()) : A;
        IReleaseVerifier.Authorization memory auth = IReleaseVerifier.Authorization(
            wallet, ETH, 0, address(signer), recipient, amount, nonce, type(uint256).max
        );
        uint256 due = Splits.entitlement(receipts, 60_000);
        (bool ok, bytes4 err) = _call(B, address(ledger), _signed(p, auth));
        assert(ok == ledger.nonceUsed(address(signer), nonce));
        if (amount > due) assert(!ok && err == ISplitWallet.AmountExceedsReleasable.selector);
        if (refusingRecipient) assert(!ok);
        if (!ok) assert(ledger.released(wallet, ETH, 0) == 0 && wallet.balance == receipts);
        else assert(ledger.released(wallet, ETH, 0) == amount && recipient.balance == amount);
    }

    // ---------------------------------------------------------------------------------------
    // The vault: ECO-39
    // ---------------------------------------------------------------------------------------

    /// @notice ECO-39: a wallet's code is the documented 66 bytes; any caller but its ledger
    ///         that sends calldata is refused and moves nothing, whatever the calldata; anyone may
    ///         send it plain ETH.
    /// @dev Bounds: any caller but the ledger; calldata of 1, 4, 36 and 100 bytes of any content
    ///      (an instruction is at least 64 bytes); any ETH value.
    function check_vault_obeysOnlyItsLedger(
        address caller,
        bytes32 w0,
        bytes32 w1,
        bytes32 w2,
        uint8 shape,
        uint64 value
    ) public {
        ISplitWallet.Payee[] memory p = new ISplitWallet.Payee[](2);
        p[0] = ISplitWallet.Payee(0, A, 60_000);
        p[1] = ISplitWallet.Payee(0, B, 40_000);
        address wallet = ledger.createWallet(p, bytes32(0));
        assert(
            keccak256(wallet.code)
                == keccak256(
                    abi.encodePacked(bytes1(0x73), address(ledger), SplitVault.RUNTIME_TAIL)
                )
        );
        assert(wallet.code.length == 66);
        vm.assume(caller != address(ledger) && caller != wallet);
        vm.deal(wallet, 1 ether);
        vm.deal(caller, value);

        bytes memory data = abi.encodePacked(w0, w1, w2, bytes4(w0));
        uint256 length = shape == 0 ? 1 : shape == 1 ? 4 : shape == 2 ? 36 : 100;
        assembly ("memory-safe") {
            mstore(data, length)
        }
        vm.prank(caller);
        (bool ok,) = wallet.call{ value: value }(data);
        assert(!ok && wallet.balance == 1 ether);

        vm.prank(caller);
        (ok,) = wallet.call{ value: value }("");
        assert(ok && wallet.balance == 1 ether + uint256(value));
    }

    // ---------------------------------------------------------------------------------------
    // Unclaimed shares: ECO-44, INV-ECO-14
    // ---------------------------------------------------------------------------------------

    /// @notice ECO-44, INV-ECO-14: a mark records the payee's entitlement at the time; a running
    ///         mark cannot be replaced; a forfeit succeeds only once the unclaimed period the
    ///         resolver answers (its launch value here) has passed since the mark,
    ///         pays the network only what of the marked level the payee has not released (so
    ///         never money that arrived after the mark), counts as released for the payee, and
    ///         clears the mark.
    /// @dev Bounds: any 64-bit receipts before and after the mark, any payee release before the
    ///      forfeit, any delays below 2**32 seconds; two fixed payees.
    function check_mark_cannotBeReplacedAndForfeitWaits180Days(
        uint64 before,
        uint64 later,
        uint32 remarkDelay,
        uint32 forfeitDelay,
        bool payeeReleases
    ) public {
        (ISplitWallet.Payee[] memory p, address wallet) = _pair();
        vm.deal(wallet, before);
        uint256 markedAt = block.timestamp;
        (bool marked,) = _call(C, address(ledger), abi.encodeCall(ledger.mark, (p, 0, ETH, 0)));
        vm.assume(marked);
        (uint256 target, uint256 markTime) = ledger.markOf(wallet, ETH, 0);
        assert(target == Splits.entitlement(before, 60_000) && markTime == markedAt);

        vm.deal(wallet, wallet.balance + later);
        vm.warp(markedAt + remarkDelay);
        // The re-mark's error is `MarkPending`, but it computes the entitlement at the new
        // receipts first, and the solver cannot rule out that computation's overflow checks
        // (a 256-bit division), so only the refusal and the unchanged mark are asserted.
        (bool remarked,) = _call(C, address(ledger), abi.encodeCall(ledger.mark, (p, 0, ETH, 0)));
        (uint256 target2, uint256 markTime2) = ledger.markOf(wallet, ETH, 0);
        assert(!remarked && target2 == target && markTime2 == markedAt);

        if (payeeReleases) ledger.release(p, 0, ETH, 0);
        vm.warp(markedAt + forfeitDelay);
        _checkForfeit(p, wallet, target, forfeitDelay >= 180 days, payeeReleases);
    }

    /// @notice ECO-44: the unclaimed period is the resolver's answer when the forfeit is
    ///         attempted (the `StreamDirectory6529`'s setting), whatever it is and whenever it
    ///         changed: a forfeit succeeds exactly when the period in force has passed since the
    ///         mark.
    /// @dev Bounds: any period and delay below 2**32 seconds, set after the mark.
    function check_forfeitWaitsThePeriodInForce(uint32 period, uint32 forfeitDelay) public {
        (ISplitWallet.Payee[] memory p, address wallet) = _pair();
        vm.deal(wallet, 1 ether);
        uint256 markedAt = block.timestamp;
        ledger.mark(p, 0, ETH, 0);
        resolver.setUnclaimedPeriod(period);
        vm.warp(markedAt + forfeitDelay);
        (bool ok, bytes4 err) =
            _call(C, address(ledger), abi.encodeCall(ledger.forfeit, (p, 0, ETH, 0)));
        assert(ok == (forfeitDelay >= period));
        if (!ok) assert(err == ISplitLedger.MarkNotDue.selector);
    }

    /// @dev Forfeits payee 0 and checks the outcome against the mark's `target`.
    function _checkForfeit(
        ISplitWallet.Payee[] memory p,
        address wallet,
        uint256 target,
        bool matured,
        bool payeeReleased
    ) internal {
        uint256 releasedBefore = ledger.released(wallet, ETH, 0);
        uint256 netBefore = address(network).balance;
        (bool ok, bytes4 err) =
            _call(C, address(ledger), abi.encodeCall(ledger.forfeit, (p, 0, ETH, 0)));
        uint256 paid = address(network).balance - netBefore;
        if (!matured) assert(!ok && err == ISplitLedger.MarkNotDue.selector);
        if (ok) {
            // Only the unreleased part of the marked level, never what arrived after the mark,
            // and the forfeit counts as released for the payee.
            assert(matured && paid != 0 && releasedBefore + paid <= target);
            assert(!payeeReleased || releasedBefore < target);
            assert(ledger.released(wallet, ETH, 0) == releasedBefore + paid);
            (uint256 cleared,) = ledger.markOf(wallet, ETH, 0);
            assert(cleared == 0);
        } else {
            assert(paid == 0);
        }
    }

    /// @dev Deploys the salt-zero wallet paying A 60% and B 40%.
    function _pair() internal returns (ISplitWallet.Payee[] memory p, address wallet) {
        p = new ISplitWallet.Payee[](2);
        p[0] = ISplitWallet.Payee(0, A, 60_000);
        p[1] = ISplitWallet.Payee(0, B, 40_000);
        wallet = ledger.createWallet(p, bytes32(0));
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    /// @dev Deploys the salt-zero wallet paying `signer` 60% and `HIGH` 40%. A deployed
    ///      contract's address sits below `HIGH`, so the signer is payee 0 of the canonical list.
    function _signerWallet(address signer) internal returns (ISplitWallet.Payee[] memory p) {
        p = new ISplitWallet.Payee[](2);
        p[0] = ISplitWallet.Payee(0, signer, 60_000);
        p[1] = ISplitWallet.Payee(0, HIGH, 40_000);
        ledger.createWallet(p, bytes32(0));
    }

    function _signed(ISplitWallet.Payee[] memory p, IReleaseVerifier.Authorization memory auth)
        internal
        pure
        returns (bytes memory)
    {
        return _signed(p, auth, bytes32(0));
    }

    function _signed(
        ISplitWallet.Payee[] memory p,
        IReleaseVerifier.Authorization memory auth,
        bytes32 salt
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(SplitLedger.releaseWithAuthorization, (p, salt, auth, hex"00"));
    }
}
