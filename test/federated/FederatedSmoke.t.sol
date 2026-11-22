// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { FederationFixture } from "./FederationFixture.sol";

contract FederatedSmokeTest is FederationFixture {
    function test_Smoke_MintSellAndRecord() public {
        uint256 id = _fedSell(1, collector);
        assertEq(fStream.ownerOf(id), collector);
        assertEq(uint8(fStream.workOf(id).outcome), uint8(Outcome.SOLD));
        assertTrue(fStream.hasMinted(address(fedSale)));
        (address r, uint256 amt) = fStream.royaltyInfo(id, 1 ether);
        assertTrue(r != address(0));
        assertEq(amt, 0.05 ether);
    }
}
