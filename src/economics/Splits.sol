// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "./interfaces/ISplitWallet.sol";

/// @title Splits
/// @notice Payee-list rules and share maths shared by the split factory and split wallets.
/// @dev Rates use a 100,000 denominator so the 6.529% royalty is exact (ADR 0001 section 7).
///      Internal functions only, so nothing here is a linked library.
library Splits {
    /// @notice The share denominator: 100,000 parts make the whole.
    uint32 internal constant DENOMINATOR = 100_000;

    /// @notice The most payees one wallet may have; it bounds wallet deployment gas.
    uint256 internal constant MAX_PAYEES = 64;

    /// @notice Reverts unless `payees` is a canonical payee list: 1 to {MAX_PAYEES} entries, each
    ///         exactly fixed or exactly artist-resolved with a non-zero share, strictly ascending
    ///         by `(artistId, account)` (fixed payees first, so no duplicates), shares summing to
    ///         {DENOMINATOR}.
    function validate(ISplitWallet.Payee[] memory payees) internal pure {
        uint256 count = payees.length;
        if (count == 0 || count > MAX_PAYEES) revert ISplitWallet.PayeeCountOutOfRange(count);
        uint256 total = 0;
        for (uint256 i; i < count; ++i) {
            ISplitWallet.Payee memory p = payees[i];
            if ((p.artistId == 0) == (p.account == address(0)) || p.share == 0) {
                revert ISplitWallet.InvalidPayee(i);
            }
            if (i != 0 && !_sortsBefore(payees[i - 1], p)) {
                revert ISplitWallet.PayeesNotCanonical(i);
            }
            total += p.share;
        }
        if (total != DENOMINATOR) revert ISplitWallet.SharesDoNotSum(total);
    }

    /// @notice A payee's cumulative entitlement: `floor(observed * share / DENOMINATOR)`, computed
    ///         without overflow for any `observed`.
    /// @dev Across all payees the entitlements fall short of `observed` by at most `count - 1`
    ///      units, and that dust never grows as receipts accumulate. Exact and overflow-free for
    ///      every `share <= DENOMINATOR` (a canonical payee's always is), the form 6529 Stream's
    ///      `royaltyInfo` uses: with `observed = q * DENOMINATOR + r`, the floor is
    ///      `q * share + floor(r * share / DENOMINATOR)`, where `q * share <= observed` and
    ///      `r * share < DENOMINATOR ** 2`. It replaces a full-width `mulDiv`, which cost each
    ///      split wallet several hundred bytes of code.
    function entitlement(uint256 observed, uint32 share) internal pure returns (uint256) {
        return (observed / DENOMINATOR) * share + (observed % DENOMINATOR) * share / DENOMINATOR;
    }

    /// @notice The canonical payee list of a work's royalty wallet (ADR 0001 section 7): the
    ///         seller wallet takes `DENOMINATOR - feeShare` and the network fee recipient takes
    ///         `feeShare`, both as fixed payees in address order. `feeShare` must be non-zero and
    ///         below {DENOMINATOR}; with a zero fee share the seller wallet is the royalty wallet.
    function royaltyPayees(address seller, address feeRecipient, uint32 feeShare)
        internal
        pure
        returns (ISplitWallet.Payee[] memory payees)
    {
        ISplitWallet.Payee memory sellerPayee =
            ISplitWallet.Payee(0, seller, DENOMINATOR - feeShare);
        ISplitWallet.Payee memory feePayee = ISplitWallet.Payee(0, feeRecipient, feeShare);
        payees = new ISplitWallet.Payee[](2);
        (payees[0], payees[1]) =
            seller < feeRecipient ? (sellerPayee, feePayee) : (feePayee, sellerPayee);
    }

    function _sortsBefore(ISplitWallet.Payee memory a, ISplitWallet.Payee memory b)
        private
        pure
        returns (bool)
    {
        return a.artistId < b.artistId || (a.artistId == b.artistId && a.account < b.account);
    }
}
