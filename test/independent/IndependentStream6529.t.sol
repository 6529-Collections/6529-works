// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { IIndependentStreamMembership } from "src/interfaces/IIndependentStreamMembership.sol";
import { IIndependentStream } from "src/interfaces/IIndependentStream.sol";
import { Outcome, PendingModule, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IModules, IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { MockRenderer, MockSale } from "../mocks/core/CoreMocks.sol";
import { IndependentTokenFixture } from "./IndependentTokenFixture.sol";

/// @notice `IndependentStream6529`: the plain permanent ERC-721 with the Independent Stream gate.
///         Every hook, every function the token adds, and the three settings it holds
///         (`rescueDelay`, `moduleDelay` of its renderer slot), through the real contract.
contract IndependentStreamTest is IndependentTokenFixture {
    uint64 internal constant RESCUER = 7;

    // ------------------------------------------------------------------------ construction

    function test_Constructor_SetsTheTokenAndItsOneCollection() public view {
        assertEq(fs.name(), "Ind Works");
        assertEq(fs.symbol(), "IND");
        assertEq(fs.facts(), address(facts));
        assertEq(fs.directory(), address(directory));
        assertEq(fs.artistId(), IND_ARTIST);
        assertEq(fs.owner(), marketOwner);
        assertEq(fs.collectionCount(), 1);
        assertEq(fs.collectionOf(1).name, "Ind Works");
        assertTrue(fs.collectionOf(1).exists);
        assertEq(fs.moduleOf(Slots.RENDERER), address(renderer));
        assertEq(fs.moduleDelay(), 7 days);
        assertEq(fs.rescueDelay(), 14 days);
    }

    function test_Constructor_LogsTheOwnerTheCollectionAndTheRenderer() public {
        vm.expectEmit();
        emit IStream.OwnershipTransferred(address(0), marketOwner);
        vm.expectEmit();
        emit IStream.CollectionCreated(1, "N", bytes32(0));
        vm.expectEmit();
        emit IModuleSlots.ModuleSet(Slots.RENDERER, address(0), address(renderer));
        new IndependentStream6529(
            "N", "S", address(facts), address(directory), 1, marketOwner, address(renderer)
        );
    }

    function test_Constructor_WithoutARendererLeavesTheSlotEmpty() public {
        IndependentStream6529 t = new IndependentStream6529(
            "N", "S", address(facts), address(directory), 1, marketOwner, address(0)
        );
        assertEq(t.moduleOf(Slots.RENDERER), address(0));
    }

    function test_Constructor_RefusesAnUnusableArgument() public {
        vm.expectRevert(IIndependentStreamMembership.InvalidConfig.selector);
        new IndependentStream6529("N", "S", address(facts), address(0), 1, marketOwner, address(0));
        vm.expectRevert(IIndependentStreamMembership.InvalidConfig.selector);
        new IndependentStream6529(
            "N", "S", address(facts), address(directory), 0, marketOwner, address(0)
        );
        vm.expectRevert(IIndependentStreamMembership.InvalidConfig.selector);
        new IndependentStream6529(
            "N",
            "S",
            address(facts),
            address(directory),
            uint256(type(uint160).max) + 1,
            marketOwner,
            address(0)
        );
        vm.expectRevert(IIndependentStreamMembership.InvalidConfig.selector);
        new IndependentStream6529(
            "N", "S", address(0), address(directory), 1, marketOwner, address(0)
        );
    }

    // ------------------------------------------------------------------------ module slots

    function test_ModuleOf_SharedSlotsAreTheDirectorysAndFollowIt() public {
        assertEq(fs.moduleOf(Slots.TERMS), address(terms));
        assertEq(fs.moduleOf(Slots.RECORDS), address(records));
        assertEq(fs.moduleOf(Slots.ACCOUNTS), address(0));
        assertEq(fs.moduleOf(Slots.INDEPENDENT_STREAM), address(0));
        assertEq(fs.moduleOf("OTHER"), address(0));
        directory.removeModule(Slots.INDEPENDENT_TERMS);
        assertEq(fs.moduleOf(Slots.TERMS), address(0), "follows the directory");
    }

    function test_ProposeModule_TheArtistAnnouncesARendererThatAnyoneInstallsAfterTheWait() public {
        MockRenderer next = new MockRenderer();
        uint48 readyAt = uint48(block.timestamp) + 7 days;
        vm.expectEmit(address(fs));
        emit IModuleSlots.ModuleProposed(Slots.RENDERER, address(next), readyAt);
        vm.prank(artistWallet2);
        fs.proposeModule(Slots.RENDERER, address(next));
        PendingModule memory p = fs.pendingModule(Slots.RENDERER);
        assertEq(p.module, address(next));
        assertEq(p.readyAt, readyAt);

        vm.warp(readyAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.RENDERER)
        );
        fs.activateModule(Slots.RENDERER);
        vm.warp(readyAt);
        vm.expectEmit(address(fs));
        emit IModuleSlots.ModuleSet(Slots.RENDERER, address(renderer), address(next));
        vm.prank(stranger);
        fs.activateModule(Slots.RENDERER);
        assertEq(fs.moduleOf(Slots.RENDERER), address(next));
        assertEq(fs.pendingModule(Slots.RENDERER).readyAt, 0);
    }

    function test_ProposeModule_OnlyAWalletOfTheArtist() public {
        MockRenderer next = new MockRenderer();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotArtist.selector, stranger)
        );
        fs.proposeModule(Slots.RENDERER, address(next));
        // The network is not the artist here.
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotArtist.selector, address(this))
        );
        fs.proposeModule(Slots.RENDERER, address(next));
        // A wallet the accounts module withdraws loses the power at once.
        accounts.setWallet(IND_ARTIST, artistWallet, false);
        vm.prank(artistWallet);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotArtist.selector, artistWallet)
        );
        fs.proposeModule(Slots.RENDERER, address(next));
    }

    function test_ProposeModule_OnlyTheRendererSlotAndOnlyCode() public {
        vm.startPrank(artistWallet);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStream.NotLocalSlot.selector, Slots.TERMS)
        );
        fs.proposeModule(Slots.TERMS, address(terms));
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStream.NotLocalSlot.selector, Slots.RECORDS)
        );
        fs.removeModule(Slots.RECORDS);
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.InvalidModule.selector, stranger));
        fs.proposeModule(Slots.RENDERER, stranger);
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStream.NotLocalSlot.selector, Slots.TERMS)
        );
        fs.activateModule(Slots.TERMS);
        assertEq(fs.pendingModule(Slots.TERMS).module, address(0));
    }

    function test_RemoveModule_TheArtistEmptiesTheSlotAndItsAnnouncementAtOnce() public {
        MockRenderer next = new MockRenderer();
        vm.startPrank(artistWallet);
        fs.proposeModule(Slots.RENDERER, address(next));
        vm.expectEmit(address(fs));
        emit IModuleSlots.ModuleSet(Slots.RENDERER, address(renderer), address(0));
        fs.removeModule(Slots.RENDERER);
        vm.stopPrank();
        assertEq(fs.moduleOf(Slots.RENDERER), address(0));
        assertEq(fs.pendingModule(Slots.RENDERER).readyAt, 0);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotArtist.selector, stranger)
        );
        fs.removeModule(Slots.RENDERER);
    }

    // ---------------------------------------------------------------- moduleDelay (setting)

    function test_SetModuleDelay_OnlyTheNetworkAndLogsOldAndNew() public {
        vm.prank(artistWallet);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotNetwork.selector, artistWallet)
        );
        fs.setModuleDelay(1 days);
        vm.expectEmit(address(fs));
        emit IModuleSlots.ModuleDelaySet(7 days, 1 days);
        fs.setModuleDelay(1 days);
        assertEq(fs.moduleDelay(), 1 days);
    }

    /// The renderer cannot be installed before the wait in force when it was announced.
    function testFuzz_ModuleDelay_AnActivationBeforeThePeriodIsRefused(uint48 period, uint48 at)
        public
    {
        period = uint48(bound(period, 1, 3650 days));
        fs.setModuleDelay(period);
        MockRenderer next = new MockRenderer();
        uint256 start = block.timestamp;
        vm.prank(artistWallet);
        fs.proposeModule(Slots.RENDERER, address(next));
        at = uint48(bound(at, 0, period - 1));
        vm.warp(start + at);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.RENDERER)
        );
        fs.activateModule(Slots.RENDERER);
        vm.warp(start + period);
        fs.activateModule(Slots.RENDERER);
        assertEq(fs.moduleOf(Slots.RENDERER), address(next));
    }

    function test_ModuleDelay_ZeroInstallsAtOnce() public {
        fs.setModuleDelay(0);
        MockRenderer next = new MockRenderer();
        vm.prank(artistWallet);
        fs.proposeModule(Slots.RENDERER, address(next));
        fs.activateModule(Slots.RENDERER);
        assertEq(fs.moduleOf(Slots.RENDERER), address(next));
    }

    function test_ModuleDelay_AnAnnouncementKeepsTheTimeItWasGiven() public {
        MockRenderer next = new MockRenderer();
        vm.prank(artistWallet);
        fs.proposeModule(Slots.RENDERER, address(next));
        uint48 readyAt = fs.pendingModule(Slots.RENDERER).readyAt;
        fs.setModuleDelay(0);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.RENDERER)
        );
        fs.activateModule(Slots.RENDERER);
        fs.setModuleDelay(30 days);
        vm.warp(readyAt);
        fs.activateModule(Slots.RENDERER);
        assertEq(fs.moduleOf(Slots.RENDERER), address(next));
    }

    // ------------------------------------------------------------------------- minting

    function test_Mint_ByASaleContractTheGateAdmits() public {
        assertTrue(fs.isMinter(address(sale)));
        assertFalse(fs.hasMinted(address(sale)));
        vm.expectEmit(address(fs));
        emit IStream.WorkMinted(1, 1, IND_ARTIST, address(sale), 1, _ffacts(1));
        uint256 id = _fmint(1);
        assertEq(id, 1);
        assertEq(fs.ownerOf(1), address(sale));
        assertTrue(fs.hasMinted(address(sale)));
        assertEq(fs.workOf(1).serial, 1);
        assertEq(_fmint(2), 2);
        assertEq(fs.collectionOf(1).minted, 2);
    }

    function test_Mint_RefusedForAContractTheGateDoesNotAdmit() public {
        MockSale other = new MockSale();
        assertFalse(fs.isMinter(address(other)));
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(other)));
        other.mint(address(fs), _facts(1));
        // The same contract admitted for 6529 Stream is not admitted here.
        assertTrue(stream.isMinter(address(sale)));
        gate.setMinter(address(fs), address(sale), false);
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(sale)));
        _fmint(1);
    }

    function test_Mint_AnEmptyIndependentStreamSlotStopsMintingOnly() public {
        uint256 sold = _fsell(1, collector);
        uint256 held = _fmint(2);
        directory.removeModule(Slots.INDEPENDENT_STREAM);
        assertFalse(fs.isMinter(address(sale)));
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(sale)));
        _fmint(3);
        // Everything else still works.
        sale.record(address(fs), held, false, address(0), 0);
        vm.prank(collector);
        fs.transferFrom(collector, stranger, sold);
        assertEq(fs.ownerOf(sold), stranger);
        (address r,) = fs.royaltyInfo(sold, 1 ether);
        assertEq(r, address(0xFEE));
    }

    function test_CreateCollection_RefusedEvenForTheArtist() public {
        vm.prank(artistWallet);
        vm.expectRevert(IIndependentStream.OneCollection.selector);
        fs.createCollection("Second", bytes32(0));
        vm.expectRevert(IIndependentStream.OneCollection.selector);
        fs.createCollection("Second", bytes32(0));
        assertEq(fs.collectionCount(), 1);
    }

    // ---------------------------------------------------------- finishing a sale (hasMinted)

    function test_Record_ARemovedSaleContractStillFinishesItsSale() public {
        uint256 id = _fmint(1);
        _gateRemove(address(sale), block.timestamp);
        assertFalse(fs.isMinter(address(sale)));
        vm.expectEmit(address(fs));
        emit IStream.PrimarySale(id, Outcome.SOLD, collector, 2 ether);
        sale.record(address(fs), id, true, collector, 2 ether);
        assertEq(uint8(fs.workOf(id).outcome), uint8(Outcome.SOLD));
    }

    function test_Burn_ARemovedSaleContractStillBurnsAnUnsoldToken() public {
        uint256 id = _fmint(1);
        directory.removeModule(Slots.INDEPENDENT_STREAM);
        sale.burn(address(fs), id);
        assertEq(fs.totalBurned(), 1);
        vm.expectRevert();
        fs.ownerOf(id);
    }

    function test_Record_AHolderThatNeverMintedHereCannotRecordOrBurn() public {
        // A sale contract mints straight to another sale contract the gate also admits.
        MockSale other = new MockSale();
        gate.setMinter(address(fs), address(other), true);
        uint256 id = sale.mintTo(address(fs), address(other), _ffacts(1));
        assertFalse(fs.hasMinted(address(other)));
        vm.expectRevert(abi.encodeWithSelector(IStream.NotInPrimarySale.selector, id));
        other.record(address(fs), id, true, collector, 1);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotInPrimarySale.selector, id));
        other.burn(address(fs), id);
    }

    function test_Record_OnceOnly() public {
        uint256 id = _fmint(1);
        sale.record(address(fs), id, false, address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotInPrimarySale.selector, id));
        sale.record(address(fs), id, true, collector, 1);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotInPrimarySale.selector, id));
        sale.burn(address(fs), id);
    }

    // ------------------------------------------------------------------------- rescue

    function test_Rescue_TheNetworkMovesATokenARemovedSaleContractStillHolds() public {
        uint256 id = _fmint(1);
        _gateRemove(address(sale), block.timestamp);
        vm.warp(block.timestamp + 14 days);
        vm.expectEmit(address(fs));
        emit IStream.PrimarySale(id, Outcome.RESCUED, address(0), 0);
        vm.expectEmit(address(fs));
        emit IStream.WorkRescued(id, address(sale), collector);
        fs.rescue(id, collector);
        assertEq(fs.ownerOf(id), collector);
        assertEq(uint8(fs.workOf(id).outcome), uint8(Outcome.RESCUED));
    }

    function test_Rescue_OnlyTheNetwork() public {
        uint256 id = _fmint(1);
        _gateRemove(address(sale), block.timestamp);
        vm.warp(block.timestamp + 14 days);
        vm.prank(artistWallet);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotNetwork.selector, artistWallet)
        );
        fs.rescue(id, artistWallet);
    }

    function test_Rescue_RefusedWithoutARemovalOrAfterAnOutcome() public {
        uint256 id = _fmint(1);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
        fs.rescue(id, collector);
        _gateRemove(address(sale), block.timestamp);
        sale.record(address(fs), id, false, address(0), 0);
        vm.warp(block.timestamp + 14 days);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
        fs.rescue(id, collector);
    }

    function test_Rescue_RefusedForAnEmptyIndependentStreamSlot() public {
        uint256 id = _fmint(1);
        _gateRemove(address(sale), block.timestamp);
        vm.warp(block.timestamp + 14 days);
        directory.removeModule(Slots.INDEPENDENT_STREAM);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
        fs.rescue(id, collector);
    }

    /// A gate that says a collector was a removed sale contract reaches nothing: only an account
    /// that minted here counts.
    function test_Rescue_ALyingGateCannotMakeACollectorRescuable() public {
        uint256 id = sale.mintTo(address(fs), collector, _ffacts(1));
        gate.remove(collector, 1);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
        fs.rescue(id, stranger);
        assertEq(fs.ownerOf(id), collector);
    }

    // ---------------------------------------------------------------- rescueDelay (setting)

    function test_SetRescueDelay_OnlyTheNetworkAndLogsOldAndNew() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotNetwork.selector, stranger)
        );
        fs.setRescueDelay(1);
        vm.expectEmit(address(fs));
        emit IStream.RescueDelaySet(14 days, 3 days);
        fs.setRescueDelay(3 days);
        assertEq(fs.rescueDelay(), 3 days);
    }

    function testFuzz_RescueDelay_ARescueBeforeThePeriodIsRefused(uint48 period, uint48 at) public {
        period = uint48(bound(period, 1, 3650 days));
        fs.setRescueDelay(period);
        uint256 id = _fmint(1);
        uint256 removedAt = block.timestamp;
        _gateRemove(address(sale), removedAt);
        at = uint48(bound(at, 0, period - 1));
        vm.warp(removedAt + at);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
        fs.rescue(id, collector);
        vm.warp(removedAt + period);
        fs.rescue(id, collector);
        assertEq(fs.ownerOf(id), collector);
    }

    function test_RescueDelay_ZeroRescuesAtTheRemoval() public {
        fs.setRescueDelay(0);
        uint256 id = _fmint(1);
        _gateRemove(address(sale), block.timestamp);
        fs.rescue(id, collector);
        assertEq(fs.ownerOf(id), collector);
    }

    /// The period is read when the rescue is attempted: a change applies to removals already made.
    function test_RescueDelay_TheValueInForceAtTheAttemptDecides() public {
        uint256 id = _fmint(1);
        uint256 removedAt = block.timestamp;
        _gateRemove(address(sale), removedAt);
        vm.warp(removedAt + 2 days);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
        fs.rescue(id, collector);
        fs.setRescueDelay(1 days);
        fs.rescue(id, collector);
        assertEq(fs.ownerOf(id), collector);
    }

    function test_RescueDelay_ReAddingTheSaleContractClearsItsRemoval() public {
        uint256 id = _fmint(1);
        _gateRemove(address(sale), block.timestamp);
        gate.setMinter(address(fs), address(sale), true);
        gate.remove(address(sale), 0);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
        fs.rescue(id, collector);
    }

    // ------------------------------------------------------- the network (directory authority)

    /// The network is whoever the directory's AccessManager lets call the same function on the
    /// directory at once; a role with an execution delay is refused.
    function test_Network_IsTheDirectorysAuthorityForTheSameSelectorAtOnce() public {
        address rescuer = makeAddr("rescuer");
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IStream.setRescueDelay.selector;
        manager.setTargetFunctionRole(address(directory), selectors, RESCUER);
        vm.prank(rescuer);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotNetwork.selector, rescuer)
        );
        fs.setRescueDelay(1);
        manager.grantRole(RESCUER, rescuer, 0);
        vm.prank(rescuer);
        fs.setRescueDelay(1);
        assertEq(fs.rescueDelay(), 1);
        // The admin no longer holds the remapped selector.
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotNetwork.selector, address(this))
        );
        fs.setRescueDelay(2);
        // A delayed role cannot act here.
        address slow = makeAddr("slow");
        manager.grantRole(RESCUER, slow, 1 days);
        vm.prank(slow);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotNetwork.selector, slow)
        );
        fs.setRescueDelay(3);
    }

    /// A call relayed through the manager's `execute` reaches the token with the manager as
    /// caller, and the token refuses it: the network calls an Independent Stream token directly.
    function test_Network_ACallRelayedThroughTheManagerIsRefused() public {
        bytes memory data = abi.encodeCall(IStream.setRescueDelay, (5));
        uint48 before = fs.rescueDelay();
        vm.expectRevert(
            abi.encodeWithSelector(
                IIndependentStreamMembership.NotNetwork.selector, address(manager)
            )
        );
        manager.execute(address(fs), data);
        assertEq(fs.rescueDelay(), before);
        // The same holder, calling the token itself, is the network.
        fs.setRescueDelay(5);
        assertEq(fs.rescueDelay(), 5);
    }

    function test_Network_FollowsTheDirectorysAuthority() public {
        assertEq(IAccessManaged(address(directory)).authority(), address(manager));
        uint256 id = _fmint(1);
        _gateRemove(address(sale), block.timestamp);
        vm.warp(block.timestamp + 14 days);
        fs.rescue(id, collector);
        assertEq(fs.ownerOf(id), collector);
    }

    // ------------------------------------------------------------------------- admin

    function test_Admin_AnyWalletOfTheArtistSetsTheOwnerAndContractURI() public {
        vm.prank(artistWallet);
        vm.expectEmit(address(fs));
        emit IStream.OwnershipTransferred(marketOwner, stranger);
        fs.setOwner(stranger);
        vm.prank(artistWallet2);
        vm.expectEmit(address(fs));
        emit IStream.ContractURIUpdated();
        fs.setContractURI("ipfs://ind");
        assertEq(fs.owner(), stranger);
        assertEq(fs.contractURI(), "ipfs://ind");
    }

    function test_Admin_RefusedForOthersAndForAnEmptyAccountsSlot() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotArtist.selector, stranger)
        );
        fs.setOwner(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotArtist.selector, address(this))
        );
        fs.setContractURI("x");
        directory.removeModule(Slots.ACCOUNTS);
        vm.prank(artistWallet);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotArtist.selector, artistWallet)
        );
        fs.setOwner(stranger);
    }

    // -------------------------------------------------------------- terms, records, views

    function test_Royalty_OnlyTheSharedTermsModule() public {
        uint256 id = _fmint(1);
        terms.setRoyalty(address(fs), id, stranger, 100);
        (address r, uint256 amount) = fs.royaltyInfo(id, 100_000);
        assertEq(r, stranger);
        assertEq(amount, 100);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.NotModule.selector, Slots.TERMS, address(this))
        );
        fs.setRoyalty(id, stranger, 1);
        vm.prank(address(records));
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.NotModule.selector, Slots.TERMS, address(records))
        );
        fs.lockRoyaltyRate(id);
        terms.lockRoyaltyRate(address(fs), id);
        vm.expectRevert(IStream.InvalidRoyalty.selector);
        terms.setRoyalty(address(fs), id, stranger, 101);
        directory.removeModule(Slots.INDEPENDENT_TERMS);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.NotModule.selector, Slots.TERMS, address(terms))
        );
        terms.setRoyalty(address(fs), id, collector, 100);
    }

    function test_EmitMetadataUpdate_FromFactsAndTheSharedModulesOnly() public {
        vm.expectEmit(address(fs));
        emit IERC4906.MetadataUpdate(3);
        terms.refresh(address(fs), 3, 3);
        vm.prank(address(records));
        vm.expectEmit(address(fs));
        emit IERC4906.BatchMetadataUpdate(1, 9);
        fs.emitMetadataUpdate(1, 9);
        vm.prank(address(facts));
        fs.emitMetadataUpdate(1, 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotMetadataSource.selector, stranger));
        fs.emitMetadataUpdate(1, 1);
    }

    function test_TokenURI_DrawnByTheTokensRenderer() public {
        uint256 id = _fmint(1);
        assertEq(fs.rendererOf(id), address(renderer));
        assertEq(fs.tokenURI(id), "data:,mock");
        vm.prank(artistWallet);
        fs.removeModule(Slots.RENDERER);
        vm.expectRevert();
        fs.tokenURI(id);
        assertEq(fs.ownerOf(id), address(sale), "ownership never depends on a module");
    }

    function test_SupportsInterface() public view {
        assertTrue(fs.supportsInterface(type(IERC165).interfaceId));
        assertTrue(fs.supportsInterface(type(IERC721).interfaceId));
        assertTrue(fs.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(fs.supportsInterface(bytes4(0x49064906)));
        assertTrue(fs.supportsInterface(type(IStream).interfaceId));
        assertTrue(fs.supportsInterface(type(IModuleSlots).interfaceId));
        assertTrue(fs.supportsInterface(type(IIndependentStream).interfaceId));
        assertTrue(fs.supportsInterface(type(IIndependentStreamMembership).interfaceId));
        assertFalse(fs.supportsInterface(type(IModules).interfaceId));
        assertFalse(fs.supportsInterface(0xffffffff));
    }

    // ------------------------------------------------- boundaries found by the mutation campaign

    function test_Constructor_LogsTheFirstModuleDelay() public {
        vm.expectEmit();
        emit IModuleSlots.ModuleDelaySet(0, 7 days);
        new IndependentStream6529(
            "N", "S", address(facts), address(directory), 1, marketOwner, address(renderer)
        );
    }

    function test_Constructor_WithoutARendererLogsNoModuleSet() public {
        vm.recordLogs();
        new IndependentStream6529(
            "N", "S", address(facts), address(directory), 1, marketOwner, address(0)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(logs.length, 0, "the construction logs");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IModuleSlots.ModuleSet.selector, "no ModuleSet");
        }
    }

    /// The announcement belongs to the RENDERER slot alone: no other slot reads it.
    function test_PendingModule_OnlyTheRendererSlotReadsTheAnnouncement() public {
        MockRenderer next = new MockRenderer();
        vm.prank(artistWallet);
        fs.proposeModule(Slots.RENDERER, address(next));
        assertEq(fs.pendingModule(Slots.RENDERER).module, address(next));
        bytes32[4] memory others =
            [Slots.RECORDS, Slots.TERMS, bytes32(0), bytes32(type(uint256).max)];
        for (uint256 i; i < others.length; ++i) {
            PendingModule memory p = fs.pendingModule(others[i]);
            assertEq(p.module, address(0));
            assertEq(p.readyAt, 0);
        }
    }

    function test_ActivateModule_StillInstallsAfterTheReadyTime() public {
        MockRenderer next = new MockRenderer();
        vm.prank(artistWallet);
        fs.proposeModule(Slots.RENDERER, address(next));
        vm.warp(block.timestamp + 7 days + 1);
        fs.activateModule(Slots.RENDERER);
        assertEq(fs.moduleOf(Slots.RENDERER), address(next));
    }

    /// With nothing announced, nobody can empty the renderer slot through `activateModule`.
    function test_ActivateModule_RefusedWithNothingAnnounced() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.RENDERER)
        );
        fs.activateModule(Slots.RENDERER);
        // Nor a second time after an announcement was installed.
        MockRenderer next = new MockRenderer();
        vm.prank(artistWallet);
        fs.proposeModule(Slots.RENDERER, address(next));
        vm.warp(block.timestamp + 7 days);
        fs.activateModule(Slots.RENDERER);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.RENDERER)
        );
        fs.activateModule(Slots.RENDERER);
        assertEq(fs.moduleOf(Slots.RENDERER), address(next));
    }

    function test_CancelModule_TheArtistWithdrawsTheAnnouncement() public {
        MockRenderer next = new MockRenderer();
        vm.prank(artistWallet);
        fs.proposeModule(Slots.RENDERER, address(next));
        vm.expectEmit(address(fs));
        emit IModuleSlots.ModuleCancelled(Slots.RENDERER, address(next));
        vm.prank(artistWallet2);
        fs.cancelModule(Slots.RENDERER);
        PendingModule memory p = fs.pendingModule(Slots.RENDERER);
        assertEq(p.module, address(0));
        assertEq(p.readyAt, 0);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.RENDERER)
        );
        fs.activateModule(Slots.RENDERER);
        assertEq(fs.moduleOf(Slots.RENDERER), address(renderer));
    }

    function test_CancelModule_RefusedWithNothingAnnouncedForOthersAndForASharedSlot() public {
        vm.prank(artistWallet);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.RENDERER)
        );
        fs.cancelModule(Slots.RENDERER);
        MockRenderer next = new MockRenderer();
        vm.prank(artistWallet);
        fs.proposeModule(Slots.RENDERER, address(next));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotArtist.selector, stranger)
        );
        fs.cancelModule(Slots.RENDERER);
        vm.prank(artistWallet);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStream.NotLocalSlot.selector, Slots.TERMS)
        );
        fs.cancelModule(Slots.TERMS);
        assertEq(fs.pendingModule(Slots.RENDERER).module, address(next));
    }

    function test_SupportsInterface_RefusesIdsBelowAndAboveItsOwn() public view {
        assertFalse(fs.supportsInterface(0x00000001));
        assertFalse(fs.supportsInterface(0xfffffffe));
    }

    /// The minter recorded is the contract that called `mint`, whoever started the transaction.
    function test_Mint_RecordsTheMintingContractWhateverTheTransactionOrigin() public {
        _fmint(1);
        MockSale other = new MockSale();
        gate.setMinter(address(fs), address(other), true);
        // The transaction's origin is an account that minted here before.
        vm.prank(stranger, address(sale));
        uint256 id = other.mint(address(fs), _ffacts(2));
        assertTrue(fs.hasMinted(address(other)));
        other.record(address(fs), id, true, collector, 1 ether);
        assertEq(uint8(fs.workOf(id).outcome), uint8(Outcome.SOLD));
    }
}
