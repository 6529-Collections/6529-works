// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { IndSale, IndependentStreamFixture } from "./IndependentStreamFixture.sol";

/// @notice The Independent Stream module after the reviews: each sale contract mints for one form
///         of token (review C I-4), and no item approval is used while the artist's account may not
///         act (review C M-2).
contract IndependentStreamRegistryFixesTest is IndependentStreamFixture {
    function test_Form_ASaleContractMintsOnlyItsForm() public {
        IndSale editionSale = new IndSale();
        registry.setAdapter(address(editionSale), IIndependentStreamRegistry.Form.ERC1155, true);
        assertTrue(registry.canMint(address(fStream), address(indSale)));
        assertFalse(registry.canMint(address(fEditions), address(indSale)));
        assertTrue(registry.canMint(address(fEditions), address(editionSale)));
        assertFalse(registry.canMint(address(fStream), address(editionSale)));
        assertFalse(fEditions.isMinter(address(indSale)));
        assertFalse(fStream.isMinter(address(editionSale)));
        IIndependentStreamRegistry.SaleContract memory s =
            registry.saleContractOf(address(editionSale));
        assertEq(uint8(s.form), uint8(IIndependentStreamRegistry.Form.ERC1155));
    }

    function test_Form_APairMintsForNoToken() public {
        IndSale s = new IndSale();
        registry.setAdapter(address(s), IIndependentStreamRegistry.Form.PAIR, true);
        assertFalse(registry.canMint(address(fStream), address(s)));
        assertFalse(registry.canMint(address(fEditions), address(s)));
    }

    function test_Form_ReAddedWithAnotherForm() public {
        registry.setAdapter(address(indSale), IIndependentStreamRegistry.Form.ERC721, false);
        skip(1);
        vm.expectEmit(address(registry));
        emit IIndependentStreamRegistry.SaleContractSet(
            address(indSale), IIndependentStreamRegistry.Form.ERC1155, uint48(block.timestamp), 0
        );
        registry.setAdapter(address(indSale), IIndependentStreamRegistry.Form.ERC1155, true);
        assertFalse(registry.canMint(address(fStream), address(indSale)));
        assertTrue(registry.canMint(address(fEditions), address(indSale)));
    }

    function test_Authorize_RefusesWhileTheAccountIsFrozen() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        accountsModule.freeze(fArtistId);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamRegistry.AccountCannotAct.selector, fArtistId)
        );
        indSale.start(address(registry), address(fStream), _request(item, media, new bytes[](0)));
        accountsModule.unfreeze(fArtistId);
        indSale.start(address(registry), address(fStream), _request(item, media, new bytes[](0)));
    }
}
