// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Splits } from "src/economics/Splits.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";

/// @notice Halmos proof for the split payee rules (docs/testing/README.md, "Symbolic").
/// @dev The share arithmetic of `Splits.entitlement` (it equals `mulDiv`, no payee exceeds what
///      was observed, the shares sum to at most it with bounded dust) is NOT proved here: every
///      formulation tried (full width, `observed` below 2**128, 2**64 and the denominator, and a
///      multiplication-only specification) times out in yices and z3 after 5 to 15 minutes,
///      because each needs the solver to reason about a 256-bit division. Those properties are
///      fuzzed instead, over the full range, in test/economics/SplitMath.t.sol, and held by the
///      economics invariants (`invariant_DustIsBounded`, `invariant_ReleasedWithinEntitlement`).
contract SplitsSymbolicTest is Test {
    uint256 internal constant D = Splits.DENOMINATOR;

    /// @notice The royalty payee list is canonical for every seller, fee recipient and fee
    ///         share the callers allow: `validate` accepts it, it holds both parties in address
    ///         order, and the shares are the fee and its complement.
    function check_royaltyPayees_isCanonical(address seller, address feeRecipient, uint32 feeShare)
        public
        view
    {
        vm.assume(seller != address(0) && feeRecipient != address(0) && seller != feeRecipient);
        vm.assume(feeShare != 0 && feeShare < D);
        ISplitWallet.Payee[] memory payees = Splits.royaltyPayees(seller, feeRecipient, feeShare);
        try this.validate(payees) { }
        catch {
            assert(false);
        }
        assert(payees.length == 2);
        assert(payees[0].account < payees[1].account);
        (ISplitWallet.Payee memory s, ISplitWallet.Payee memory f) =
            payees[0].account == seller ? (payees[0], payees[1]) : (payees[1], payees[0]);
        assert(s.account == seller && f.account == feeRecipient);
        assert(s.share == D - feeShare && f.share == feeShare);
        assert(s.artistId == 0 && f.artistId == 0);
    }

    /// @dev External so a revert in `validate` can be caught and turned into a failure.
    function validate(ISplitWallet.Payee[] memory payees) external pure {
        Splits.validate(payees);
    }

    function _accepts(ISplitWallet.Payee[] memory payees) internal view returns (bool) {
        try this.validate(payees) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev The rule as written in `Splits.validate`'s NatSpec, payee by payee.
    function _canonical(ISplitWallet.Payee[] memory p) internal pure returns (bool) {
        uint256 total;
        for (uint256 i; i < p.length; ++i) {
            bool artist = p[i].artistId != 0;
            bool fixedPayee = p[i].account != address(0);
            if (artist == fixedPayee || p[i].share == 0) return false;
            if (i != 0) {
                (uint256 a0, address x0) = (p[i - 1].artistId, p[i - 1].account);
                (uint256 a1, address x1) = (p[i].artistId, p[i].account);
                if (!(a0 < a1 || (a0 == a1 && x0 < x1))) return false;
            }
            total += p[i].share;
        }
        return p.length != 0 && total == D;
    }

    /// @notice `validate` accepts a list of one, two or three payees exactly when it is
    ///         canonical: each payee fixed or artist-resolved (never both, never neither) with a
    ///         non-zero share, strictly ascending by `(artistId, account)`, shares summing to the
    ///         denominator. Every field of every payee is symbolic; longer lists are fuzzed.
    function check_validate_acceptsExactlyTheCanonicalLists(
        ISplitWallet.Payee memory a,
        ISplitWallet.Payee memory b,
        ISplitWallet.Payee memory c
    ) public view {
        ISplitWallet.Payee[] memory one = new ISplitWallet.Payee[](1);
        one[0] = a;
        assert(_accepts(one) == _canonical(one));
        ISplitWallet.Payee[] memory two = new ISplitWallet.Payee[](2);
        (two[0], two[1]) = (a, b);
        assert(_accepts(two) == _canonical(two));
        ISplitWallet.Payee[] memory three = new ISplitWallet.Payee[](3);
        (three[0], three[1], three[2]) = (a, b, c);
        assert(_accepts(three) == _canonical(three));
        // The empty list is refused.
        assert(!_accepts(new ISplitWallet.Payee[](0)));
    }
}
