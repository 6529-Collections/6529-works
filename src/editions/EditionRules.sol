// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EditionTerms } from "../interfaces/types/PackageTypes.sol";

/// @title EditionRules
/// @notice The one definition of valid edition terms (ADR 0001 section 6, as amended by ADR
///         0005), shared by the package registry, which refuses an EDITION_MASTER item with
///         invalid terms at `consume`, and 6529 Stream Editions, which re-checks them at
///         `createEdition`. One rule in both places means a master that can mint can always get
///         its edition.
/// @dev Internal functions only, so nothing here is linked. Never reverts on malformed input.
///      Sale methods stay extensible (ADR 0005, owner decision 14): a sale kind is a label a sale
///      adapter claims (`ISaleAdapter.saleKind`), and its `currency` and `params` are opaque
///      here. The rule checks only the generic shape; the kind's adapter validates the rest when
///      it opens a sale (the edition auction requires `SaleKind.UNIFORM_AUCTION`, ETH and empty
///      params) and refuses terms it cannot sell. Terms naming a kind no admitted adapter serves
///      are valid, so their edition waits for such an adapter (LIM-EA-8).
library EditionRules {
    /// @notice The most bytes of `params` an edition may carry, so that `createEdition`, which
    ///         stores them, fits the EIP-7825 transaction cap for any valid terms.
    uint256 internal constant MAX_PARAMS_BYTES = 1_024;

    /// @notice Whether edition terms are valid: a nonzero sale kind and at most
    ///         `MAX_PARAMS_BYTES` of params. Any `maxCount` (zero means no cap) and any currency.
    function isValid(EditionTerms calldata t) internal pure returns (bool) {
        return t.saleKind != 0 && t.params.length <= MAX_PARAMS_BYTES;
    }
}
