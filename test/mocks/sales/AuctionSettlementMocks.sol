// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PrimaryOutcome, PrimarySettlement } from "src/interfaces/types/SaleTypes.sol";
import { PlainMintTarget } from "./AuctionMocks.sol";

/// @notice A listed token whose settlement hook reports a fee share the test sets, which may
///         differ from the share its terms reported at the start: the English auction must bound
///         the share it settles on by the denominator.
contract SettlementShareTarget is PlainMintTarget {
    uint32 public settlementShare;
    bool public shareSet;

    function setSettlementShare(uint32 share) external {
        settlementShare = share;
        shareSet = true;
    }

    function settlePrimary(uint256, PrimaryOutcome, address, address, uint256)
        external
        view
        override
        returns (PrimarySettlement memory p)
    {
        (p.seller, p.feeRecipient, p.feeShare) =
        (_terms.seller, _terms.feeRecipient, shareSet ? settlementShare : _terms.feeShare);
    }
}
