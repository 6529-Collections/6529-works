// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IndependentStreamEditions6529 } from "src/independent/IndependentStreamEditions6529.sol";
import { IIndependentStreamMembership } from "src/interfaces/IIndependentStreamMembership.sol";
import { Edition, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IModules, IModuleSlots } from "src/interfaces/core/IModules.sol";
import { MockSale } from "../mocks/core/CoreMocks.sol";
import { IndependentTokenFixture } from "./IndependentTokenFixture.sol";

/// @notice `IndependentStreamEditions6529`: the plain permanent ERC-1155 with the Independent
///         Stream gate, and its setting `rebindDelay`, through the real contract.
contract IndependentStreamEditionsTest is IndependentTokenFixture {
    uint256 internal master;
    MockSale internal next;

    function setUp() public override {
        super.setUp();
        master = _fmint(1);
        next = new MockSale();
        gate.setMinter(address(fe), address(next), true);
    }

    function test_Constructor_SetsThePartnerAndTheArtist() public view {
        assertEq(fe.name(), "Ind Editions");
        assertEq(fe.symbol(), "INDED");
        assertEq(fe.stream(), address(fs));
        assertEq(fe.directory(), address(directory));
        assertEq(fe.artistId(), IND_ARTIST);
        assertEq(fe.owner(), marketOwner);
        assertEq(fe.rebindDelay(), 14 days);
    }

    function test_Constructor_RefusesAnUnusableArgument() public {
        vm.expectRevert(IIndependentStreamMembership.InvalidConfig.selector);
        new IndependentStreamEditions6529("N", "S", address(0), address(directory), 1, marketOwner);
        vm.expectRevert(IIndependentStreamMembership.InvalidConfig.selector);
        new IndependentStreamEditions6529("N", "S", address(fs), address(0), 1, marketOwner);
        vm.expectRevert(IIndependentStreamMembership.InvalidConfig.selector);
        new IndependentStreamEditions6529("N", "S", address(fs), address(directory), 0, marketOwner);
    }

    function test_ModuleOf_OnlyTermsIsTheDirectorysIndependentTerms() public view {
        assertEq(fe.moduleOf(Slots.TERMS), address(terms));
        assertEq(fe.moduleOf(Slots.RECORDS), address(0));
        assertEq(fe.moduleOf(Slots.RENDERER), address(0));
    }

    function test_Create_ByASaleContractTheGateAdmitsForALiveMaster() public {
        vm.expectEmit(address(fe));
        emit IEditions.EditionCreated(master, address(sale), 50, address(0xFEE), 700);
        sale.createEdition(address(fe), master, 50, address(0xFEE), 700);
        Edition memory e = fe.editionOf(master);
        assertEq(e.minter, address(sale));
        assertEq(e.maxSupply, 50);
        MockSale other = new MockSale();
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(other)));
        other.createEdition(address(fe), 2, 1, address(0), 0);
        vm.expectRevert();
        sale.createEdition(address(fe), 99, 1, address(0), 0); // no such master
    }

    function test_Mint_AnUnsealedEditionNeedsTheGateASealedOneDoesNot() public {
        sale.createEdition(address(fe), master, 10, address(0xFEE), 700);
        sale.mintEdition(address(fe), collector, master, 2, 1 ether);
        // Left open when the gate reports the sale contract removed: no mint and no seal.
        uint256 snap = vm.snapshotState();
        _gateRemove(address(sale), block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, master, address(sale))
        );
        sale.mintEdition(address(fe), collector, master, 1, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, master, address(sale))
        );
        sale.seal(address(fe), master, 5);
        vm.revertToState(snap);
        // Sealed before the removal: it still mints up to the seal.
        sale.seal(address(fe), master, 5);
        _gateRemove(address(sale), block.timestamp);
        sale.mintEdition(address(fe), collector, master, 3, 1 ether);
        assertEq(fe.balanceOf(collector, master), 5);
        vm.expectRevert(abi.encodeWithSelector(IEditions.SupplyExceeded.selector, master));
        sale.mintEdition(address(fe), collector, master, 1, 1 ether);
    }

    function test_Mint_AnEmptyIndependentStreamSlotStopsCreatingAndUnsealedMinting() public {
        sale.createEdition(address(fe), master, 10, address(0xFEE), 700);
        directory.removeModule(Slots.INDEPENDENT_STREAM);
        assertFalse(fe.isMinter(address(sale)));
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(sale)));
        sale.createEdition(address(fe), master, 1, address(0), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, master, address(sale))
        );
        sale.mintEdition(address(fe), collector, master, 1, 1);
    }

    /// @dev With no Independent Stream module nothing new is sealed, whether or not the module
    ///      had removed the sale contract: every sale contract reads as removed. An edition
    ///      sealed before still mints up to its seal, and copies still move.
    function test_Seal_AnEmptyIndependentStreamSlotSealsNothingNew() public {
        uint256 sealedBefore = _fmint(2);
        sale.createEdition(address(fe), master, 10, address(0xFEE), 700);
        sale.createEdition(address(fe), sealedBefore, 10, address(0xFEE), 700);
        sale.mintEdition(address(fe), collector, sealedBefore, 1, 1);
        sale.seal(address(fe), sealedBefore, 3);
        directory.removeModule(Slots.INDEPENDENT_STREAM);
        assertEq(fe.minterRemovedAt(address(sale)), block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, master, address(sale))
        );
        sale.seal(address(fe), master, 0);
        assertFalse(fe.editionOf(master).supplySealed);
        // No rebind either, even with no wait: no contract may mint.
        fe.setRebindDelay(0);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, master));
        fe.rebind(master, address(next));
        // What was sealed before is unchanged, and transfers ask nobody.
        sale.mintEdition(address(fe), collector, sealedBefore, 2, 1);
        assertEq(fe.balanceOf(collector, sealedBefore), 3);
        vm.prank(collector);
        fe.safeTransferFrom(collector, address(0xB0B), sealedBefore, 1, "");
        assertEq(fe.balanceOf(address(0xB0B), sealedBefore), 1);
    }

    /// @dev With a module in the slot again, the sale contract it does not report removed seals
    ///      as before.
    function test_Seal_AModuleInTheSlotAgainRestoresTheSeal() public {
        sale.createEdition(address(fe), master, 10, address(0xFEE), 700);
        directory.removeModule(Slots.INDEPENDENT_STREAM);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, master, address(sale))
        );
        sale.seal(address(fe), master, 0);
        directory.setModuleDelay(0);
        directory.proposeModule(Slots.INDEPENDENT_STREAM, address(gate));
        directory.activateModule(Slots.INDEPENDENT_STREAM);
        assertEq(fe.minterRemovedAt(address(sale)), 0);
        sale.seal(address(fe), master, 0);
        assertTrue(fe.editionOf(master).supplySealed);
    }

    // ------------------------------------------------------------------------- rebind

    function test_Rebind_TheNetworkMovesAStuckEditionAfterTheRemoval() public {
        sale.createEdition(address(fe), master, 10, address(0xFEE), 700);
        _gateRemove(address(sale), block.timestamp);
        vm.warp(block.timestamp + 14 days);
        vm.expectEmit(address(fe));
        emit IEditions.EditionRebound(master, address(sale), address(next));
        fe.rebind(master, address(next));
        assertEq(fe.editionOf(master).minter, address(next));
        next.mintEdition(address(fe), collector, master, 1, 1);
    }

    function test_Rebind_OnlyTheNetwork() public {
        sale.createEdition(address(fe), master, 10, address(0xFEE), 700);
        _gateRemove(address(sale), block.timestamp);
        vm.warp(block.timestamp + 14 days);
        vm.prank(artistWallet);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotNetwork.selector, artistWallet)
        );
        fe.rebind(master, address(next));
    }

    function test_Rebind_AnEditionWithCopiesAndNoSealIsRebound() public {
        sale.createEdition(address(fe), master, 10, address(0xFEE), 700);
        sale.mintEdition(address(fe), collector, master, 2, 1);
        _gateRemove(address(sale), block.timestamp);
        vm.warp(block.timestamp + 14 days);
        fe.rebind(master, address(next));
        assertEq(fe.editionOf(master).minter, address(next));
        assertEq(fe.editionOf(master).minted, 2);
        vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidSeal.selector, master));
        next.seal(address(fe), master, 1);
        next.seal(address(fe), master, 2);
        assertEq(fe.editionOf(master).maxSupply, 2);
    }

    function test_Rebind_RefusedWithASealOrToAContractTheGateRefuses() public {
        sale.createEdition(address(fe), master, 10, address(0xFEE), 700);
        sale.mintEdition(address(fe), collector, master, 1, 1);
        sale.seal(address(fe), master, 5);
        _gateRemove(address(sale), block.timestamp);
        vm.warp(block.timestamp + 14 days);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, master));
        fe.rebind(master, address(next));

        uint256 m2 = 2;
        gate.setMinter(address(fs), address(next), true);
        assertEq(next.mint(address(fs), _ffacts(2)), m2);
        next.createEdition(address(fe), m2, 10, address(0xFEE), 700);
        _gateRemove(address(next), block.timestamp);
        MockSale third = new MockSale();
        vm.warp(block.timestamp + 14 days);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, m2));
        fe.rebind(m2, address(third)); // the gate does not admit `third`
        gate.setMinter(address(fe), address(third), true);
        fe.rebind(m2, address(third));
        assertEq(fe.editionOf(m2).minter, address(third));
    }

    function test_SetRebindDelay_OnlyTheNetworkAndLogsOldAndNew() public {
        vm.prank(artistWallet);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotNetwork.selector, artistWallet)
        );
        fe.setRebindDelay(1);
        vm.expectEmit(address(fe));
        emit IEditions.RebindDelaySet(14 days, 2 days);
        fe.setRebindDelay(2 days);
        assertEq(fe.rebindDelay(), 2 days);
    }

    function testFuzz_RebindDelay_ARebindBeforeThePeriodIsRefused(uint48 period, uint48 at) public {
        period = uint48(bound(period, 1, 3650 days));
        fe.setRebindDelay(period);
        sale.createEdition(address(fe), master, 10, address(0xFEE), 700);
        uint256 removedAt = block.timestamp;
        _gateRemove(address(sale), removedAt);
        at = uint48(bound(at, 0, period - 1));
        vm.warp(removedAt + at);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, master));
        fe.rebind(master, address(next));
        vm.warp(removedAt + period);
        fe.rebind(master, address(next));
    }

    function test_RebindDelay_ZeroAndTheValueInForceAtTheAttemptDecides() public {
        sale.createEdition(address(fe), master, 10, address(0xFEE), 700);
        _gateRemove(address(sale), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, master));
        fe.rebind(master, address(next));
        fe.setRebindDelay(0);
        fe.rebind(master, address(next));
        assertEq(fe.editionOf(master).minter, address(next));
    }

    // ------------------------------------------------------------- terms, admin, views

    function test_Royalty_OnlyTheSharedTermsModule() public {
        sale.createEdition(address(fe), master, 10, address(0xFEE), 700);
        terms.setEditionRoyalty(address(fe), master, stranger, 900);
        (address r, uint256 amount) = fe.royaltyInfo(master, 100_000);
        assertEq(r, stranger);
        assertEq(amount, 900);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.NotModule.selector, Slots.TERMS, address(this))
        );
        fe.setRoyalty(master, stranger, 1);
    }

    function test_EmitMetadataUpdate_FromTermsAndTheStreamsRecordsModule() public {
        vm.prank(address(terms));
        fe.emitMetadataUpdate(1, 1);
        vm.prank(address(records));
        fe.emitMetadataUpdate(1, 2);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotMetadataSource.selector, stranger));
        fe.emitMetadataUpdate(1, 1);
    }

    function test_Admin_AnyWalletOfTheArtist() public {
        vm.prank(artistWallet2);
        fe.setOwner(stranger);
        vm.prank(artistWallet);
        fe.setContractURI("ipfs://ed");
        assertEq(fe.owner(), stranger);
        assertEq(fe.contractURI(), "ipfs://ed");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotArtist.selector, stranger)
        );
        fe.setOwner(stranger);
    }

    function test_Uri_DrawnByTheMastersRenderer() public {
        sale.createEdition(address(fe), master, 10, address(0xFEE), 700);
        assertEq(fe.uri(master), "data:,mock");
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 7));
        fe.uri(7);
    }

    /// @dev A master burned in sale custody keeps its record: `uri` of the copies already held
    ///      still answers, and the burned master has no `tokenURI`.
    function test_Uri_StillDrawnAfterTheMasterIsBurned() public {
        sale.createEdition(address(fe), master, 10, address(0xFEE), 700);
        sale.mintEdition(address(fe), stranger, master, 2, 0.1 ether);
        assertEq(fe.uri(master), "data:,mock");
        sale.burn(address(fs), master);
        assertEq(fe.uri(master), "data:,mock", "the copies still have metadata");
        assertEq(fe.balanceOf(stranger, master), 2);
        assertEq(fs.rendererOf(master), address(renderer));
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, master)
        );
        fs.tokenURI(master);
    }

    function test_SupportsInterface() public view {
        assertTrue(fe.supportsInterface(type(IERC165).interfaceId));
        assertTrue(fe.supportsInterface(type(IERC1155).interfaceId));
        assertTrue(fe.supportsInterface(type(IEditions).interfaceId));
        assertTrue(fe.supportsInterface(type(IIndependentStreamMembership).interfaceId));
        assertFalse(fe.supportsInterface(type(IModules).interfaceId));
    }

    function test_SupportsInterface_RefusesIdsBelowAndAboveItsOwn() public view {
        assertFalse(fe.supportsInterface(0x00000001));
        assertFalse(fe.supportsInterface(0xffffffff));
    }
}
