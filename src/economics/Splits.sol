// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
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
        uint256 total;
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
    ///      units, and that dust never grows as receipts accumulate.
    function entitlement(uint256 observed, uint32 share) internal pure returns (uint256) {
        return Math.mulDiv(observed, share, DENOMINATOR);
    }

    function _sortsBefore(ISplitWallet.Payee memory a, ISplitWallet.Payee memory b)
        private
        pure
        returns (bool)
    {
        return a.artistId < b.artistId || (a.artistId == b.artistId && a.account < b.account);
    }
}
