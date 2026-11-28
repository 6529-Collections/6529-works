// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";

/// @notice A caller that settles an ended, unsold English auction sale and offers the work
///         again in one transaction, so no other call can land between the two: what an edition
///         sale that followed the first sale must not be moved by. Anyone may make both calls.
contract SettleAndRestart {
    function run(IEnglishAuction auction, uint256 saleId) external {
        auction.settle(saleId);
        auction.restart(saleId);
    }
}
