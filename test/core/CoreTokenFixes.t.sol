// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {
    Minter,
    MintFacts,
    Outcome,
    PendingModule,
    Slots
} from "src/interfaces/core/CoreTypes.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { MockRenderer, MockSale } from "../mocks/core/CoreMocks.sol";
import { IndependentTokenFixture } from "../independent/IndependentTokenFixture.sol";

/// @notice The fixes to the permanent tokens after the plain-core reviews: a removed edition
///         minter seals nothing and mints only what it sealed before its removal; a cancelled
///         minter addition never counts as a minter; `rescue` refuses the token contract itself;
///         a pending module can be withdrawn; an Independent Stream token takes its own artist
///         only.
contract CoreTokenFixesTest is IndependentTokenFixture {
    address internal buyer = makeAddr("buyer");
    MockSale internal other;

    function setUp() public override {
        super.setUp();
        other = new MockSale();
    }

    function _edition(uint256 n, uint40 cap) internal returns (uint256 id) {
        id = _sell(n, collector);
        sale.createEdition(address(editions), id, cap, address(0xFEE), 6529);
    }

    // ------------------------------------------------- a removed edition minter (review A M-1)

    function test_RemovedEditionMinter_CannotSealOrMintAnOpenEdition() public {
        uint256 id = _edition(1, 0);
        editions.removeMinter(address(sale));
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, id, address(sale))
        );
        sale.seal(address(editions), id, type(uint40).max);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, id, address(sale))
        );
        sale.mintEdition(address(editions), buyer, id, 1, 0);
        assertEq(editions.editionOf(id).minted, 0);
        assertFalse(editions.editionOf(id).supplySealed);
    }

    function test_RemovedEditionMinter_MintsWhatItSealedBeforeItsRemoval() public {
        uint256 id = _edition(1, 0);
        sale.seal(address(editions), id, 5);
        editions.removeMinter(address(sale));
        sale.mintEdition(address(editions), buyer, id, 5, 1 ether);
        assertEq(editions.balanceOf(buyer, id), 5);
        vm.expectRevert(abi.encodeWithSelector(IEditions.SupplyExceeded.selector, id));
        sale.mintEdition(address(editions), buyer, id, 1, 1 ether);
    }

    function test_RemovedEditionMinter_OpenEditionWaitsForTheRebind() public {
        uint256 id = _edition(1, 10);
        editions.removeMinter(address(sale));
        assertEq(editions.minterRemovedAt(address(sale)), block.timestamp);
        editions.addMinter(address(other));
        skip(editions.rebindDelay());
        vm.expectRevert();
        sale.seal(address(editions), id, 0);
        editions.rebind(id, address(other));
        other.seal(address(editions), id, 3);
        other.mintEdition(address(editions), buyer, id, 3, 0);
        assertEq(editions.editionOf(id).maxSupply, 3);
    }

    /// @dev A minter added again gets no new power during its new wait, as on the ERC-721: it
    ///      seals nothing and mints only an edition sealed before its removal.
    function test_RemovedEditionMinter_AddedAgainGainsNothingDuringItsWait() public {
        uint256 open = _edition(1, 10);
        uint256 sealedBefore = _edition(2, 10);
        sale.seal(address(editions), sealedBefore, 4);
        editions.removeMinter(address(sale));
        editions.addMinter(address(sale));
        assertEq(editions.minterRemovedAt(address(sale)), 0);
        assertFalse(editions.isMinter(address(sale)), "waiting");

        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, open, address(sale))
        );
        sale.seal(address(editions), open, 2);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, open, address(sale))
        );
        sale.mintEdition(address(editions), buyer, open, 1, 0);
        assertFalse(editions.editionOf(open).supplySealed);
        assertEq(editions.editionOf(open).minted, 0);
        // What it sealed before its removal is still served.
        sale.mintEdition(address(editions), buyer, sealedBefore, 4, 0);
        assertEq(editions.balanceOf(buyer, sealedBefore), 4);

        // Active again: its open edition is its own to seal and mint.
        vm.warp(editions.minterOf(address(sale)).activeFrom);
        sale.seal(address(editions), open, 2);
        sale.mintEdition(address(editions), buyer, open, 2, 0);
        assertEq(editions.editionOf(open).maxSupply, 2);
    }

    /// @dev An edition with copies and no seal at its minter's removal is not stuck: the network
    ///      rebinds it under the same wait, and the new minter seals at or above the copies.
    function test_RemovedEditionMinter_AnEditionWithCopiesAndNoSealIsRebound() public {
        uint256 id = _edition(1, 10);
        sale.mintEdition(address(editions), buyer, id, 3, 0);
        editions.removeMinter(address(sale));
        editions.addMinter(address(other));
        skip(editions.rebindDelay() - 1);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, id));
        editions.rebind(id, address(other));
        skip(1);
        vm.expectEmit(address(editions));
        emit IEditions.EditionRebound(id, address(sale), address(other));
        editions.rebind(id, address(other));
        assertEq(editions.editionOf(id).minter, address(other));
        assertEq(editions.editionOf(id).minted, 3, "the copies stay");
        assertEq(editions.balanceOf(buyer, id), 3);

        vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidSeal.selector, id));
        other.seal(address(editions), id, 2);
        other.seal(address(editions), id, 3);
        assertEq(editions.editionOf(id).maxSupply, 3);
        vm.expectRevert(abi.encodeWithSelector(IEditions.SupplyExceeded.selector, id));
        other.mintEdition(address(editions), buyer, id, 1, 0);
    }

    function test_IndependentRemovedEditionMinter_CannotSeal() public {
        uint256 id = _fsell(1, collector);
        sale.createEdition(address(fe), id, 0, address(0xFEE), 6529);
        _gateRemove(address(sale), block.timestamp);
        assertEq(fe.minterRemovedAt(address(sale)), block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, id, address(sale))
        );
        sale.seal(address(fe), id, type(uint40).max);
    }

    function testFuzz_RemovedEditionMinter_NeverPassesWhatWasSealed(uint40 sealAt, uint40 more)
        public
    {
        sealAt = uint40(bound(sealAt, 0, 1000));
        uint256 id = _edition(1, 0);
        sale.seal(address(editions), id, sealAt);
        editions.removeMinter(address(sale));
        if (more > sealAt) {
            vm.expectRevert(abi.encodeWithSelector(IEditions.SupplyExceeded.selector, id));
        }
        sale.mintEdition(address(editions), buyer, id, more, 0);
        assertLe(editions.editionOf(id).minted, sealAt);
    }

    // ---------------------------------------------- a cancelled minter addition (review A L-1)

    function test_CancelledMinter_LeavesNoRecordAndNeverCountsAsActive() public {
        stream.addMinter(address(other));
        uint48 activeFrom = stream.minterOf(address(other)).activeFrom;
        // A token with no outcome that `other` holds (minted to it by `sale`).
        uint256 tokenId = sale.mintTo(address(stream), address(other), _facts(1));
        stream.removeMinter(address(other));
        Minter memory m = stream.minterOf(address(other));
        assertEq(m.activeFrom, 0);
        assertEq(m.removedAt, 0);
        assertEq(m.firstActiveFrom, 0);
        vm.warp(activeFrom + stream.rescueDelay());
        vm.expectRevert(abi.encodeWithSelector(IStream.NotInPrimarySale.selector, tokenId));
        other.burn(address(stream), tokenId);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotInPrimarySale.selector, tokenId));
        other.record(address(stream), tokenId, true, buyer, 1);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, tokenId));
        stream.rescue(tokenId, collector);
    }

    function test_CancelledMinter_AddedAgainStartsAFreshRecord() public {
        stream.addMinter(address(other));
        stream.removeMinter(address(other));
        skip(1 days);
        stream.addMinter(address(other));
        Minter memory m = stream.minterOf(address(other));
        assertEq(m.firstActiveFrom, m.activeFrom);
        assertEq(m.activeFrom, block.timestamp + stream.moduleDelay());
    }

    function test_CancelledEditionsMinter_IsNeverRemoved() public {
        editions.addMinter(address(other));
        editions.removeMinter(address(other));
        assertEq(editions.minterRemovedAt(address(other)), 0);
        assertEq(editions.minterOf(address(other)).activeFrom, 0);
    }

    function test_ReAddedMinterCancelled_KeepsItsStandingFromTheFirstTime() public {
        uint256 tokenId = _mint(1);
        stream.removeMinter(address(sale));
        stream.addMinter(address(sale));
        Minter memory m = stream.minterOf(address(sale));
        assertLt(m.firstActiveFrom, m.activeFrom);
        // Cancelled during the new wait: it was active before, so it is a removed minter.
        stream.removeMinter(address(sale));
        assertEq(stream.minterOf(address(sale)).removedAt, block.timestamp);
        skip(stream.rescueDelay());
        stream.rescue(tokenId, collector);
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.RESCUED));
    }

    function test_ReAddedMinter_StillWaitsBeforeSettlingAgain() public {
        uint256 tokenId = _mint(1);
        stream.removeMinter(address(sale));
        stream.addMinter(address(sale));
        vm.expectRevert(abi.encodeWithSelector(IStream.NotInPrimarySale.selector, tokenId));
        sale.record(address(stream), tokenId, true, buyer, 1);
        skip(stream.moduleDelay());
        sale.record(address(stream), tokenId, true, buyer, 1);
    }

    // ------------------------------------------------------------------- rescue (review A I-5)

    function test_Rescue_RefusesTheTokenContractItselfAndZero() public {
        uint256 tokenId = _mint(1);
        stream.removeMinter(address(sale));
        skip(stream.rescueDelay());
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(stream))
        );
        stream.rescue(tokenId, address(stream));
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0))
        );
        stream.rescue(tokenId, address(0));
        stream.rescue(tokenId, collector);
        assertEq(stream.ownerOf(tokenId), collector);
    }

    function test_IndependentRescue_RefusesTheTokenContractItself() public {
        uint256 tokenId = _fmint(1);
        _gateRemove(address(sale), block.timestamp);
        skip(fs.rescueDelay());
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(fs))
        );
        fs.rescue(tokenId, address(fs));
    }

    // ----------------------------------------------------- cancelling an announcement (I-1)

    function test_CancelModule_KeepsTheLiveModule() public {
        MockRenderer next = new MockRenderer();
        stream.proposeModule(Slots.RENDERER, address(next));
        vm.expectEmit(address(stream));
        emit IModuleSlots.ModuleCancelled(Slots.RENDERER, address(next));
        stream.cancelModule(Slots.RENDERER);
        PendingModule memory p = stream.pendingModule(Slots.RENDERER);
        assertEq(p.readyAt, 0);
        assertEq(stream.moduleOf(Slots.RENDERER), address(renderer));
        skip(7 days);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.RENDERER)
        );
        stream.activateModule(Slots.RENDERER);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.RENDERER)
        );
        stream.cancelModule(Slots.RENDERER);
    }

    function test_CancelModule_TheAdminOnly() public {
        stream.proposeModule(Slots.RENDERER, address(new MockRenderer()));
        vm.prank(collector);
        vm.expectRevert();
        stream.cancelModule(Slots.RENDERER);
        directory.proposeModule(Slots.ACCOUNTS, address(new MockRenderer()));
        directory.cancelModule(Slots.ACCOUNTS);
        assertEq(directory.pendingModule(Slots.ACCOUNTS).readyAt, 0);
        assertEq(directory.moduleOf(Slots.ACCOUNTS), address(accounts));
    }

    function test_IndependentCancelModule_TheArtistsRendererSlot() public {
        MockRenderer next = new MockRenderer();
        vm.prank(artistWallet);
        fs.proposeModule(Slots.RENDERER, address(next));
        vm.prank(stranger);
        vm.expectRevert();
        fs.cancelModule(Slots.RENDERER);
        vm.prank(artistWallet2);
        fs.cancelModule(Slots.RENDERER);
        assertEq(fs.pendingModule(Slots.RENDERER).readyAt, 0);
        assertEq(fs.moduleOf(Slots.RENDERER), address(renderer));
        vm.prank(artistWallet);
        vm.expectRevert();
        fs.cancelModule(Slots.TERMS);
    }

    // ----------------------------------------------- an Independent Stream token's artist (review
    // A L-5)

    function test_IndependentStream_RefusesAnotherArtistsWork() public {
        MintFacts memory f = _facts(1);
        f.artistId = ARTIST;
        vm.expectRevert(IStream.InvalidMint.selector);
        sale.mint(address(fs), f);
        f.artistId = IND_ARTIST;
        uint256 tokenId = sale.mint(address(fs), f);
        assertEq(fs.workOf(tokenId).artistId, IND_ARTIST);
    }

    function testFuzz_IndependentStream_TakesOnlyItsOwnArtist(uint160 artistId) public {
        vm.assume(artistId != 0);
        MintFacts memory f = _facts(1);
        f.artistId = artistId;
        if (artistId != IND_ARTIST) vm.expectRevert(IStream.InvalidMint.selector);
        sale.mint(address(fs), f);
    }

    function test_Stream_TakesEveryArtist() public {
        MintFacts memory f = _facts(1);
        f.artistId = IND_ARTIST;
        sale.mint(address(stream), f);
    }
}
