// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { CURRENCY_DEFAULT, CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { EditionsBase } from "./EditionsBase.sol";
import { RevertingReceiver1155 } from "../mocks/editions/EditionsMocks.sol";

/// @notice Sealing an edition's supply at its sale's settlement (owner decision, 15 November
///         2026; ED-25), the price record of every primary mint (`EditionPrimaryMint`, ED-26) and
///         the locked-terms event (ED-27). Without the seal, a bound adapter could mint an
///         uncapped edition without limit forever, even after its removal (LIM-EA-10).
contract EditionsSealTest is EditionsBase {
    address internal constant TOKEN = address(0x20);

    // ------------------------------------------------------------------ seal

    function test_Seal_LowersTheMaximumOnceAndWinnersClaimWithinIt() public {
        uint256 id = _create(_item(0));
        adapter.buy(editions, id, buyer, 2); // a sale that mints as it sells
        vm.expectEmit(true, false, false, true, address(editions));
        emit IEditions.EditionSupplySealed(id, 5);
        adapter.seal(editions, id, 5);
        IEditions.Edition memory e = editions.edition(id);
        assertTrue(e.supplySealed);
        assertEq(e.maxSupply, 5);
        assertEq(e.terms.maxCount, 0, "the approved terms are unchanged");

        // Winners claim the three still owed, in pieces; nothing past the seal.
        adapter.buy(editions, id, outsider, 1);
        adapter.buy(editions, id, buyer, 2);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        adapter.buy(editions, id, buyer, 1);
        assertEq(editions.edition(id).minted, 5);

        // Once: nothing reopens or lowers it again.
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionSealed.selector, id));
        adapter.seal(editions, id, 5);
    }

    function test_Seal_OnlyTheBoundAdapter() public {
        uint256 id = _create(_item(10));
        // Unbound: no adapter's sale has opened it.
        vm.expectRevert(abi.encodeWithSelector(IEditions.MinterMismatch.selector, id, address(0)));
        adapter.seal(editions, id, 0);
        adapter.buy(editions, id, buyer, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.MinterMismatch.selector, id, address(adapter))
        );
        secondAdapter.seal(editions, id, 1);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, outsider));
        editions.sealSupply(id, 1);
        // An unknown edition is unbound.
        vm.expectRevert(abi.encodeWithSelector(IEditions.MinterMismatch.selector, 999, address(0)));
        adapter.seal(editions, 999, 0);
    }

    function test_Seal_NeverBelowMintedNorAboveTheMaximum() public {
        uint256 id = _create(_item(10));
        adapter.buy(editions, id, buyer, 4);
        vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidSealCount.selector, id, 3));
        adapter.seal(editions, id, 3);
        vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidSealCount.selector, id, 11));
        adapter.seal(editions, id, 11);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.InvalidSealCount.selector, id, type(uint256).max)
        );
        adapter.seal(editions, id, type(uint256).max);
        // A creator cap lower than demand: the sale sold the cap, and seals at it.
        adapter.seal(editions, id, 10);
        assertEq(editions.edition(id).maxSupply, 10);
    }

    function testFuzz_Seal_SupplyNeverExceedsTheSealedCount(
        uint32 cap,
        uint256 before,
        uint256 count,
        uint256 claim
    ) public {
        uint256 id = _create(_item(cap));
        uint256 max = cap == 0 ? type(uint40).max : cap;
        before = bound(before, 0, max < 1000 ? max : 1000);
        if (before != 0) adapter.buy(editions, id, buyer, before);
        else adapter.bind(editions, id, _itemOf(id));
        count = bound(count, before, max);
        adapter.seal(editions, id, count);
        claim = bound(claim, 1, type(uint64).max);
        if (claim > count - before) {
            vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        }
        adapter.buy(editions, id, buyer, claim);
        assertLe(editions.edition(id).minted, count);
    }

    /// @dev A sale that sold nothing seals at zero even before the edition exists (the edition
    ///      auction opens with the 1/1 and may close without bids); creating the edition later
    ///      keeps the zero, so no adapter can ever mint it.
    function test_Seal_ZeroBeforeTheEditionExists() public {
        PackageItem memory item = _item(0);
        uint256 id = _master(item);
        adapter.bind(editions, id, item);
        vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidSealCount.selector, id, 1));
        adapter.seal(editions, id, 1);
        vm.expectEmit(true, false, false, true, address(editions));
        emit IEditions.EditionSupplySealed(id, 0);
        adapter.seal(editions, id, 0);

        _createEdition(id, item);
        IEditions.Edition memory e = editions.edition(id);
        assertTrue(e.supplySealed);
        assertEq(e.maxSupply, 0);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        adapter.buy(editions, id, buyer, 1);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionSealed.selector, id));
        adapter.seal(editions, id, 0);
    }

    /// @dev Removal never strands a winner (the removed adapter still seals and its winners
    ///      claim) and never leaves it more than its winners are owed (no mint before the seal,
    ///      none past it).
    function test_Seal_RemovalStrandsNoWinnerAndLeavesNoExtraPower() public {
        uint256 id = _create(_item(0));
        adapter.buy(editions, id, buyer, 1);
        vm.prank(governor);
        editions.setAdmittedMinter(address(adapter), false);
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(adapter))
        );
        adapter.buy(editions, id, buyer, 1);
        adapter.seal(editions, id, 4);
        adapter.buy(editions, id, outsider, 3);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, id));
        adapter.buy(editions, id, outsider, 1);
        assertEq(editions.balanceOf(outsider, id), 3);
    }

    /// @dev A winner whose contract refuses its copies fails only its own claim: the seal and
    ///      every other winner's claim go through, and its share stays claimable to another
    ///      address of its choosing (the adapter's business).
    function test_Seal_ARefusingRecipientBlocksNoOne() public {
        uint256 id = _create(_item(0));
        adapter.bind(editions, id, _itemOf(id));
        adapter.seal(editions, id, 3);
        address refusing = address(new RevertingReceiver1155());
        vm.expectRevert(RevertingReceiver1155.Refused.selector);
        adapter.buy(editions, id, refusing, 1);
        adapter.buy(editions, id, buyer, 2);
        adapter.buy(editions, id, outsider, 1);
        assertEq(editions.edition(id).minted, 3);
    }

    // ------------------------------------------------------------------ price record

    function test_Mint_LogsCurrencyAndUnitPriceBeforeTheTransfer() public {
        uint256 id = _create(_item(0));
        adapter.setPrice(CURRENCY_ETH, 0.042 ether);
        vm.expectEmit(true, true, false, true, address(editions));
        emit IEditions.EditionPrimaryMint(id, buyer, 3, CURRENCY_ETH, 0.042 ether);
        vm.expectEmit(true, true, true, true, address(editions));
        emit IERC1155.TransferSingle(address(adapter), address(0), buyer, id, 3);
        adapter.buy(editions, id, buyer, 3);
        // A giveaway reports zero.
        adapter.setPrice(CURRENCY_ETH, 0);
        vm.expectEmit(true, true, false, true, address(editions));
        emit IEditions.EditionPrimaryMint(id, outsider, 1, CURRENCY_ETH, 0);
        adapter.buy(editions, id, outsider, 1);
    }

    function test_Mint_CurrencyMustBeTheTermsOwn() public {
        uint256 id = _create(_item(0));
        adapter.setPrice(TOKEN, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.CurrencyMismatch.selector, CURRENCY_ETH, TOKEN)
        );
        adapter.buy(editions, id, buyer, 1);

        // Terms naming an ERC-20 refuse ETH and accept that token.
        PackageItem memory item = _item(0);
        item.edition.currency = TOKEN;
        uint256 tokenEdition = _create(item);
        adapter.setPrice(CURRENCY_ETH, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.CurrencyMismatch.selector, TOKEN, CURRENCY_ETH)
        );
        adapter.buy(editions, tokenEdition, buyer, 1);
        adapter.setPrice(TOKEN, 7);
        adapter.buy(editions, tokenEdition, buyer, 1);

        // Terms naming the product default take the currency the adapter resolved.
        item = _item(0);
        item.edition.currency = CURRENCY_DEFAULT;
        uint256 defaultEdition = _create(item);
        vm.expectEmit(true, true, false, true, address(editions));
        emit IEditions.EditionPrimaryMint(defaultEdition, buyer, 1, TOKEN, 7);
        adapter.buy(editions, defaultEdition, buyer, 1);
        adapter.setPrice(CURRENCY_ETH, 8);
        adapter.buy(editions, defaultEdition, buyer, 1);
    }

    // ------------------------------------------------------------------ helpers

    mapping(uint256 => bytes) internal _items;

    function _itemOf(uint256 id) internal view returns (PackageItem memory) {
        return abi.decode(_items[id], (PackageItem));
    }

    function _create(PackageItem memory item) internal override returns (uint256 id) {
        id = super._create(item);
        _items[id] = abi.encode(item);
    }
}
