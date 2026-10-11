// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CURRENCY_DEFAULT } from "../interfaces/types/EconomicsTypes.sol";
import { EditionFormat, EditionTerms } from "../interfaces/types/PackageTypes.sol";
import { SaleKind } from "../interfaces/types/SaleTypes.sol";
import { DutchPricing } from "../sales/DutchPricing.sol";

/// @title EditionRules
/// @notice The one definition of valid edition terms (ADR 0001 section 6), shared by the package
///         registry, which refuses an EDITION_MASTER item with invalid terms at `consume`, and
///         6529 Editions, which re-checks them at `createEdition`. One rule in both places means
///         a master that can mint can always get its edition, and an edition that exists can
///         always be sold by its adapter.
/// @dev Internal functions only, so nothing here is linked. Never reverts on malformed input: the
///      Dutch params are read word by word rather than with `abi.decode`.
library EditionRules {
    /// @dev `abi.encode(DutchParams)`: three static words.
    uint256 private constant DUTCH_PARAMS_LENGTH = 96;

    /// @notice Whether edition terms are valid:
    ///         - a nonzero price names an explicit currency (`CURRENCY_DEFAULT` only when free);
    ///         - FIXED has a nonzero size and no window, OPEN has a nonzero window;
    ///         - FIXED_PRICE carries no params; DUTCH carries exactly `abi.encode(DutchParams)`
    ///           with a schedule `DutchPricing.isValid` accepts (resting price at most the start
    ///           price, a duration when the price falls, steps dividing the duration);
    ///         - no other sale kind.
    function isValid(EditionTerms calldata t) internal pure returns (bool) {
        if (t.currency == CURRENCY_DEFAULT && t.price != 0) return false;
        if (t.format == EditionFormat.FIXED ? t.size == 0 || t.window != 0 : t.window == 0) {
            return false;
        }
        if (t.saleKind == SaleKind.FIXED_PRICE) return t.params.length == 0;
        if (t.saleKind != SaleKind.DUTCH || t.params.length != DUTCH_PARAMS_LENGTH) return false;
        uint256 resting = uint256(bytes32(t.params[0:32]));
        uint256 duration = uint256(bytes32(t.params[32:64]));
        uint256 step = uint256(bytes32(t.params[64:96]));
        if (duration > type(uint64).max || step > type(uint64).max) return false;
        // casting to 'uint64' is safe because both values were just bounded by type(uint64).max
        // forge-lint: disable-next-line(unsafe-typecast)
        return DutchPricing.isValid(t.price, resting, uint64(duration), uint64(step));
    }
}
