// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { EditionTerms } from "../interfaces/types/PackageTypes.sol";

/// @title EditionRules
/// @notice The one definition of valid edition terms (ADR 0001 section 6, as amended by ADR
///         0005), applied by the package registry, which refuses an EDITION_MASTER item with
///         invalid terms when it admits it. The edition sale contract checks the terms of its
///         own kind when it opens a sale and creates the edition.
/// @dev Internal functions only, so nothing here is linked. Never reverts on malformed input.
///      Sale methods stay extensible (ADR 0005): a sale kind is a label a sale contract claims
///      (`ISaleAdapter.saleKind`), and its `currency` and `params` are opaque here. The rule
///      checks only the generic shape; the kind's sale contract validates the rest when it
///      opens a sale (the edition auction requires `SaleKind.UNIFORM_AUCTION`, ETH, and empty
///      params: every edition sale closes a fixed 15 minutes after its 1/1) and refuses terms
///      it cannot sell. Terms naming a kind no sale contract serves are valid, so their edition
///      waits for such a contract.
library EditionRules {
    /// @notice The most bytes of `params` an edition may carry: 64, two words (ADR 0005 §12).
    ///         The master's 1/1 `start` carries the item, so the bound keeps every start row
    ///         inside its gas ceiling.
    /// @dev The design rule: edition sale params are at most two words. A sale method that
    ///      needs more commits to a hash of it here and takes the full data when its sale opens,
    ///      checking it against that hash: for example, `params = abi.encode(keccak256(extra))`
    ///      and `open`'s `data = abi.encode(item, extra)`, refused unless `keccak256(extra)`
    ///      matches. The item, and with it the hash, is the one the master token stored
    ///      (`IStream.itemHashOf`), which the sale contract checks when it opens the sale.
    uint256 internal constant MAX_PARAMS_BYTES = 64;

    /// @notice Whether edition terms are valid: a nonzero sale kind and at most
    ///         `MAX_PARAMS_BYTES` of params. Any `maxCount` (zero means no cap) and any currency.
    function isValid(EditionTerms calldata t) internal pure returns (bool) {
        return t.saleKind != 0 && t.params.length <= MAX_PARAMS_BYTES;
    }
}
