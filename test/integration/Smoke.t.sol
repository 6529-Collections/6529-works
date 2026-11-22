// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IntegrationBase } from "./IntegrationBase.sol";

contract SmokeTest is IntegrationBase {
    function test_Smoke() public {
        address lead = _actor("lead");
        address alice = _actor("alice");
        Work[] memory works = _one(_work(lead, collectionId));
        bytes32 root = _publish(works);
        uint256 tokenId = _sell(root, works, 0, alice, 1 ether);
        assertEq(stream.ownerOf(tokenId), alice);
    }
}
