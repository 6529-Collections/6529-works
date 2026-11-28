// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
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

    /// @dev The payee is a plain address, so no payout address is asked of the frozen account:
    ///      the account's own state is the only thing that holds the approval back.
    /// Regression: M-2 in review C of the plain permanent core
    function test_Authorize_RefusesAPlainAddressPayeeWhileTheAccountIsFrozen() public {
        (PackageItem memory item, MediaFile[] memory media) = _plainPayeeItem(2);
        _approve(address(fStream), item, RATE);
        bytes memory request = _request(item, media, new bytes[](0));
        accountsModule.freeze(fArtistId);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamRegistry.AccountCannotAct.selector, fArtistId)
        );
        indSale.start(address(registry), address(fStream), request);
        assertFalse(registry.itemOf(address(fStream), _hash(item)).used, "approval not consumed");

        accountsModule.unfreeze(fArtistId);
        (uint256 tokenId,,) = indSale.start(address(registry), address(fStream), request);
        assertEq(fStream.ownerOf(tokenId), address(indSale), "minted once the freeze is lifted");
        assertTrue(registry.itemOf(address(fStream), _hash(item)).used, "approval consumed");
    }

    /// @dev A replacement staged by the network and not yet lapsed leaves the account with no
    ///      active authority. The payee is a plain address and the replacement keeps the payout
    ///      address, so only the account check stands between the old approval and a mint.
    /// Regression: M-2 in review C of the plain permanent core
    function test_Authorize_RefusesWhileAReplacementIsPending() public {
        (PackageItem memory item, MediaFile[] memory media) = _plainPayeeItem(3);
        _approve(address(fStream), item, RATE);
        bytes memory request = _request(item, media, new bytes[](0));
        address payout = accountsModule.payoutAddress(fArtistId);
        _stageReplacement(0xE5, payout);
        assertEq(accountsModule.activeAuthorityOf(fArtistId), address(0), "no active authority");
        assertEq(accountsModule.payoutAddress(fArtistId), payout, "payout address still served");
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamRegistry.AccountCannotAct.selector, fArtistId)
        );
        indSale.start(address(registry), address(fStream), request);
        assertFalse(registry.itemOf(address(fStream), _hash(item)).used, "approval not consumed");

        accountsModule.cancelReplacement(fArtistId);
        (uint256 tokenId,,) = indSale.start(address(registry), address(fStream), request);
        assertEq(fStream.ownerOf(tokenId), address(indSale), "minted once the replacement is gone");
    }

    /// @dev Item `n` of the fixture's artist with its whole payment to a plain address.
    function _plainPayeeItem(uint256 n)
        internal
        returns (PackageItem memory item, MediaFile[] memory media)
    {
        (item, media) = _item(n);
        item.payees[0] = ISplitWallet.Payee(0, makeAddr("plain payee"), 100_000);
    }

    function _hash(PackageItem memory item) internal pure returns (bytes32) {
        return WorksHashing.itemHash(item);
    }

    /// @dev The network stages a replacement of the artist's account to the wallet of `newKey`,
    ///      keeping the payout address.
    function _stageReplacement(uint256 newKey, address payout) internal {
        ArtistIdentity memory next = ArtistIdentity(vm.addr(newKey), payout, PROFILE, PROFILE_DOC);
        bytes32 evidence = keccak256("evidence");
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes memory acceptance =
            _sign(newKey, accountsModule.replacementDigest(fArtistId, next, evidence, deadline));
        accountsModule.stageReplacement(fArtistId, next, evidence, deadline, acceptance);
    }
}
