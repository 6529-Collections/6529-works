// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IStreamExtension } from "src/interfaces/IStreamExtension.sol";
import { IStreamViews } from "src/interfaces/IStreamViews.sol";
import { StreamViews } from "src/stream/StreamViews.sol";

/// @notice The extension's own answers, called directly: the collection-name rule answers
///         true or false (never reverts), and ERC-165 names exactly its three interfaces.
contract StreamViewsTest is Test {
    StreamViews internal views = new StreamViews();

    function test_IsValidCollectionName_AnswersEveryNameWithoutReverting() public view {
        assertTrue(views.isValidCollectionName("Works"));
        string[7] memory bad = [
            "", "a<b", 'a"b', "a\\b", string(hex"610a"), string(hex"617f"), string(bytes(hex"61ff"))
        ];
        for (uint256 i; i < bad.length; ++i) {
            assertFalse(views.isValidCollectionName(bad[i]));
        }
        bytes memory longest = new bytes(views.MAX_NAME_BYTES());
        for (uint256 i; i < longest.length; ++i) {
            longest[i] = "a";
        }
        assertTrue(views.isValidCollectionName(string(longest)));
        assertFalse(views.isValidCollectionName(string(abi.encodePacked(longest, "a"))));
    }

    function test_SupportsInterface_OnlyTheExactIds() public view {
        bytes4[3] memory ids = [
            type(IERC165).interfaceId,
            type(IStreamExtension).interfaceId,
            type(IStreamViews).interfaceId
        ];
        for (uint256 i; i < ids.length; ++i) {
            assertTrue(views.supportsInterface(ids[i]));
            assertFalse(views.supportsInterface(bytes4(uint32(ids[i]) - 1)));
            assertFalse(views.supportsInterface(bytes4(uint32(ids[i]) + 1)));
        }
        assertFalse(views.supportsInterface(0xffffffff));
    }
}
