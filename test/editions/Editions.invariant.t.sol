// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { EditionFormat, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { EditionsBase } from "./EditionsBase.sol";
import { EditionsHandler } from "./EditionsHandler.sol";

/// @notice Stateful invariants of 6529 Editions over three editions: a FIXED edition of 20 sold
///         at fixed price, an uncapped OPEN edition with a one-day Dutch window, and an OPEN
///         edition of 30 with a 12-hour fixed-price window.
contract EditionsInvariantTest is StdInvariant, EditionsBase {
    EditionsHandler internal handler;
    uint256[] internal ids;
    bytes32[] internal contentIds;
    address[] internal royaltyReceivers;
    uint256[] internal royaltyAmounts;

    function setUp() public override {
        super.setUp();
        PackageItem[] memory items = new PackageItem[](3);
        items[0] = _fixedItem(20);
        items[1] = _openItem(1 days, 0);
        items[2] = _item(EditionFormat.OPEN, 30, 12 hours, SaleKind.FIXED_PRICE);
        for (uint256 i; i < items.length; ++i) {
            uint256 id = _create(items[i]);
            ids.push(id);
            contentIds.push(items[i].contentId);
            (address receiver, uint256 amount) = editions.royaltyInfo(id, 1 ether);
            royaltyReceivers.push(receiver);
            royaltyAmounts.push(amount);
        }
        handler = new EditionsHandler(editions, stream, fixedAdapter, dutchAdapter, ids, items);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = EditionsHandler.buy.selector;
        selectors[1] = EditionsHandler.buy.selector; // purchases twice as often
        selectors[2] = EditionsHandler.buyWithWrongAdapter.selector;
        selectors[3] = EditionsHandler.mintAsOutsider.selector;
        selectors[4] = EditionsHandler.burnFromCustody.selector;
        selectors[5] = EditionsHandler.transfer.selector;
        selectors[6] = EditionsHandler.warp.selector;
        selectors[7] = EditionsHandler.recreate.selector;
        selectors[8] = EditionsHandler.moveMaster.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// @notice Every mint matched the model: within size, inside the OPEN window, right sale
    ///         kind, MINTER only; and no copy was accepted late or beyond the size.
    function invariant_MintsFollowEditionTerms() public view {
        assertEq(handler.unexpected(), 0, "an outcome differed from the edition terms");
        assertEq(handler.lateMints(), 0, "a copy was minted after the window closed");
        assertEq(handler.overCapMints(), 0, "a copy was minted beyond the size");
    }

    /// @notice Supply: `minted` counts every copy ever minted, never exceeds the size, and the
    ///         holders' balances equal minted minus burned.
    function invariant_SupplyAccounting() public view {
        address[] memory holders = handler.holders();
        for (uint256 i; i < ids.length; ++i) {
            IEditions.Edition memory e = editions.edition(ids[i]);
            assertEq(e.minted, handler.ghostMinted(ids[i]), "minted counter");
            if (e.terms.size != 0) assertLe(e.minted, e.terms.size, "size cap");
            uint256 sum;
            for (uint256 h; h < holders.length; ++h) {
                sum += editions.balanceOf(holders[h], ids[i]);
            }
            assertEq(sum, e.minted - handler.ghostBurned(ids[i]), "balances");
        }
    }

    /// @notice An OPEN window starts at the first mint and never moves; FIXED has none.
    function invariant_WindowStartsOnce() public view {
        for (uint256 i; i < ids.length; ++i) {
            IEditions.Edition memory e = editions.edition(ids[i]);
            assertEq(e.windowStart, handler.ghostWindowStart(ids[i]), "window start");
            if (e.terms.format == EditionFormat.FIXED) assertEq(e.windowStart, 0);
        }
    }

    /// @notice The link and the locked terms never change: both directions, the content and the
    ///         royalty.
    function invariant_LinkAndRoyaltyFixed() public view {
        for (uint256 i; i < ids.length; ++i) {
            (address s, uint256 workId, bytes32 contentId) = editions.masterOf(ids[i]);
            assertEq(s, address(stream));
            assertEq(workId, ids[i]);
            assertEq(contentId, contentIds[i]);
            (address linked, uint256 editionId) = stream.editionOf(ids[i]);
            assertEq(linked, address(editions));
            assertEq(editionId, ids[i]);
            (address receiver, uint256 amount) = editions.royaltyInfo(ids[i], 1 ether);
            assertEq(receiver, royaltyReceivers[i]);
            assertEq(amount, royaltyAmounts[i]);
        }
    }
}
