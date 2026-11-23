// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Edition } from "src/interfaces/core/CoreTypes.sol";
import { EditionsFixture } from "./EditionsFixture.sol";
import { EditionsHandler } from "./EditionsHandler.sol";

/// @notice Stateful invariants of 6529 Stream Editions (256 runs, depth 128, `fail_on_revert`):
///         copies minted never pass the maximum; a sealed maximum never changes; an edition's
///         minter changes only by `rebind`, and only with no seal and the rebind wait
///         in force passed since its minter's removal (the handler checks the rule on every
///         attempt); balances plus burned copies equal the copies minted.
contract EditionsInvariantTest is EditionsFixture {
    EditionsHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new EditionsHandler(editions, stream, sale, address(this));
        targetContract(address(handler));
    }

    function invariant_MintedNeverPassesTheMaximum() public view {
        for (uint256 i; i < handler.idCount(); ++i) {
            Edition memory e = editions.editionOf(handler.ids(i));
            assertLe(e.minted, e.maxSupply);
        }
    }

    function invariant_ASealedMaximumNeverChanges() public view {
        for (uint256 i; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            Edition memory e = editions.editionOf(id);
            assertEq(e.supplySealed, handler.ghostSealed(id));
            if (e.supplySealed) assertEq(e.maxSupply, handler.ghostSealedMax(id));
        }
    }

    function invariant_TheMinterChangesOnlyByItsRules() public view {
        for (uint256 i; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            assertEq(editions.editionOf(id).minter, handler.ghostMinter(id));
        }
    }

    function invariant_BalancesPlusBurnedEqualMinted() public view {
        for (uint256 i; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            uint256 sum = handler.ghostBurned(id);
            for (uint256 h; h < 3; ++h) {
                sum += editions.balanceOf(handler.holders(h), id);
            }
            assertEq(sum, editions.editionOf(id).minted);
        }
    }
}
