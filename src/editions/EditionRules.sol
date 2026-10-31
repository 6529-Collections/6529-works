// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CURRENCY_ETH } from "../interfaces/types/EconomicsTypes.sol";
import { EditionTerms } from "../interfaces/types/PackageTypes.sol";
import { SaleKind } from "../interfaces/types/SaleTypes.sol";

/// @title EditionRules
/// @notice The one definition of valid edition terms (ADR 0001 section 6, as amended by ADR
///         0005), shared by the package registry, which refuses an EDITION_MASTER item with
///         invalid terms at `consume`, and 6529 Stream Editions, which re-checks them at
///         `createEdition`. One rule in both places means a master that can mint can always get
///         its edition.
/// @dev Internal functions only, so nothing here is linked. Never reverts on malformed input.
///      Sale methods stay extensible (owner decision 14): a sale kind is a label a sale adapter
///      claims (`ISaleAdapter.saleKind`), so terms may name a kind no adapter serves yet, and a
///      later adapter, admitted by governance, sells them without a redeployment. The rule
///      checks only what this contract knows: the uniform-price edition auction's own shape,
///      and for any other kind a label and bounded params; that kind's adapter validates its
///      currency and params when it opens a sale.
library EditionRules {
    /// @notice The most bytes of `params` an edition may carry, so that `createEdition`, which
    ///         stores them, fits the EIP-7825 transaction cap for any valid terms.
    uint256 internal constant MAX_PARAMS_BYTES = 1_024;

    /// @notice Whether edition terms are valid. Any `maxCount` is valid; zero means no cap.
    ///         - `SaleKind.UNIFORM_AUCTION`, v1's edition sale: ETH only, and no params;
    ///         - any other kind: a nonzero label other than `SaleKind.ENGLISH_AUCTION` (the 1/1
    ///           sale), with at most `MAX_PARAMS_BYTES` of params.
    function isValid(EditionTerms calldata t) internal pure returns (bool) {
        if (t.saleKind == SaleKind.UNIFORM_AUCTION) {
            return t.currency == CURRENCY_ETH && t.params.length == 0;
        }
        return t.saleKind != 0 && t.saleKind != SaleKind.ENGLISH_AUCTION
            && t.params.length <= MAX_PARAMS_BYTES;
    }
}
