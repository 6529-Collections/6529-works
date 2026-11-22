// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { FedSale, FederationFixture } from "./FederationFixture.sol";

/// @notice The federation module after the reviews: each sale contract mints for one form of
///         token (review C I-4), and no item approval is used while the artist's account may not
///         act (review C M-2).
contract FederationRegistryFixesTest is FederationFixture {
    function test_Form_ASaleContractMintsOnlyItsForm() public {
        FedSale editionSale = new FedSale();
        registry.setAdapter(address(editionSale), IFederationRegistry.Form.ERC1155, true);
        assertTrue(registry.canMint(address(fStream), address(fedSale)));
        assertFalse(registry.canMint(address(fEditions), address(fedSale)));
        assertTrue(registry.canMint(address(fEditions), address(editionSale)));
        assertFalse(registry.canMint(address(fStream), address(editionSale)));
        assertFalse(fEditions.isMinter(address(fedSale)));
        assertFalse(fStream.isMinter(address(editionSale)));
        IFederationRegistry.SaleContract memory s = registry.saleContractOf(address(editionSale));
        assertEq(uint8(s.form), uint8(IFederationRegistry.Form.ERC1155));
    }

    function test_Form_APairMintsForNoToken() public {
        FedSale s = new FedSale();
        registry.setAdapter(address(s), IFederationRegistry.Form.PAIR, true);
        assertFalse(registry.canMint(address(fStream), address(s)));
        assertFalse(registry.canMint(address(fEditions), address(s)));
    }

    function test_Form_ReAddedWithAnotherForm() public {
        registry.setAdapter(address(fedSale), IFederationRegistry.Form.ERC721, false);
        skip(1);
        vm.expectEmit(address(registry));
        emit IFederationRegistry.SaleContractSet(
            address(fedSale), IFederationRegistry.Form.ERC1155, uint48(block.timestamp), 0
        );
        registry.setAdapter(address(fedSale), IFederationRegistry.Form.ERC1155, true);
        assertFalse(registry.canMint(address(fStream), address(fedSale)));
        assertTrue(registry.canMint(address(fEditions), address(fedSale)));
    }

    function test_Authorize_RefusesWhileTheAccountIsFrozen() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        accountsModule.freeze(fArtistId);
        vm.expectRevert(
            abi.encodeWithSelector(IFederationRegistry.AccountCannotAct.selector, fArtistId)
        );
        fedSale.start(address(registry), address(fStream), _request(item, media, new bytes[](0)));
        accountsModule.unfreeze(fArtistId);
        fedSale.start(address(registry), address(fStream), _request(item, media, new bytes[](0)));
    }
}
