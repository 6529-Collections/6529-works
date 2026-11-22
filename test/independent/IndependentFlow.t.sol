// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { MintFacts, MintTerms, Outcome, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IModules } from "src/interfaces/core/IModules.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { MockRenderer } from "../mocks/core/CoreMocks.sol";
import { IndependentStreamFixture } from "./IndependentStreamFixture.sol";

/// @notice An Independent Stream artist's pair end to end on the real modules: listed through the
///         Independent Stream module, minted through its policy into a sale contract's custody, its
///         record opened and finalized in the shared `StreamWorkFacts6529`, its edition created,
///         paid through vaults whose payout the accounts module answers via the directory, and
///         stopped by delisting and freezing without touching anything a collector holds.
contract IndependentFlowTest is IndependentStreamFixture {
    function test_Flow_ListedPairAnswersTheGate() public view {
        assertTrue(fStream.isMinter(address(indSale)));
        assertTrue(fEditions.isMinter(address(indEdSale)));
        IIndependentStreamRegistry.Entry memory e = registry.entry(address(fEditions));
        assertEq(e.partner, address(fStream));
        assertEq(registry.entry(address(fStream)).partner, address(fEditions));
        assertEq(registry.feeShareOf(address(fStream)), SHARE);
        assertEq(accountsModule.authorityOf(fArtistId), artist, "identity created at listing");
    }

    function test_Flow_MintRecordFinalizeAndRender() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(1);
        _approve(address(fStream), item, RATE);
        (uint256 id, MintFacts memory f, MintTerms memory t) = indSale.start(
            address(registry), address(fStream), _request(item, media, new bytes[](0))
        );
        assertEq(fStream.itemHashOf(id), WorksHashing.itemHash(item));
        assertEq(fStream.workOf(id).artistId, fArtistId);
        assertEq(t.creator, address(fStream));
        assertTrue(f.royaltyReceiver.code.length != 0, "the royalty vault is deployed");
        (address receiver, uint256 amount) = fStream.royaltyInfo(id, 1 ether);
        assertEq(receiver, f.royaltyReceiver);
        assertEq(amount, 0.05 ether);

        // Anyone opens the record with the exact item; the shared RECORDS module finalizes it.
        facts.open(address(fStream), id, item, media);
        assertTrue(facts.factsOf(address(fStream), id).opened);
        records.finalize(address(fStream), id);
        assertEq(facts.rendererOf(address(fStream), id), address(renderer));
        assertEq(fStream.rendererOf(id), address(renderer));

        // The artist's later renderer change does not reach a finalized work.
        vm.prank(wallet);
        fStream.removeModule(Slots.RENDERER);
        assertEq(fStream.tokenURI(id), "data:,mock");
        indSale.record(address(fStream), id, true, collector, 1 ether);
        indSale.send(address(fStream), id, collector);
        assertEq(fStream.ownerOf(id), collector);
    }

    function test_Flow_AnEditionMasterAndItsEdition() public {
        (PackageItem memory item, MediaFile[] memory media) = _itemOf(5, 1, new address[](0));
        _approve(address(fStream), item, RATE);
        (uint256 id,,) = indSale.start(
            address(registry), address(fStream), _request(item, media, new bytes[](0))
        );
        indEdSale.createEdition(address(fEditions), id, 0, address(0xFEE), RATE);
        indEdSale.mintEdition(address(fEditions), collector, id, 3, 0.1 ether);
        indEdSale.seal(address(fEditions), id, 3);
        assertEq(fEditions.balanceOf(collector, id), 3);
        assertEq(fEditions.uri(id), "data:,mock");
    }

    function test_Flow_TheArtistIsPaidThroughTheDirectory() public {
        (, MintFacts memory f,) = _start(2);
        ISplitWallet.Payee[] memory payees = new ISplitWallet.Payee[](1);
        payees[0] = ISplitWallet.Payee(fArtistId, address(0), 100_000);
        assertEq(f.seller, ledger.walletFor(payees, bytes32(0)));
        vm.deal(f.seller, 1 ether);
        assertEq(indDirectory.payoutAddress(fArtistId), artist);
        vm.prank(artist);
        ledger.release(payees, bytes32(0), address(0), 0);
        assertGt(artist.balance, 0, "paid to the account's payout");
        // A frozen account's money stays in the vault.
        accountsModule.freeze(fArtistId);
        assertEq(indDirectory.payoutAddress(fArtistId), address(0));
        vm.deal(f.seller, 2 ether);
        vm.prank(artist);
        vm.expectRevert();
        ledger.release(payees, bytes32(0), address(0), 0);
    }

    function test_Flow_TheStatementLogResolverKnowsTheIndependentArtist() public {
        uint256 id = _fedMint(3);
        assertTrue(accountsModule.isArtist(address(fStream), id, artist));
        assertTrue(accountsModule.isArtist(address(fStream), id, wallet), "consolidated");
        assertFalse(accountsModule.isArtist(address(fStream), id, stranger));
    }

    function test_Flow_DelistingStopsMintingAndTouchesNothingHeld() public {
        uint256 sold = _fedSell(1, collector);
        uint256 held = _fedMint(2);
        address[] memory tokens = new address[](1);
        tokens[0] = address(fStream);
        registry.setStatus(tokens, IIndependentStreamRegistry.Status.DELISTED, bytes32("vote"));
        assertFalse(fStream.isMinter(address(indSale)));
        assertFalse(fEditions.isMinter(address(indEdSale)), "editions follow their stream");
        (PackageItem memory item, MediaFile[] memory media) = _item(4);
        _approve(address(fStream), item, RATE);
        vm.expectRevert();
        indSale.start(address(registry), address(fStream), _request(item, media, new bytes[](0)));
        // The running sale finishes; holders keep and move their tokens.
        indSale.record(address(fStream), held, false, address(0), 0);
        vm.prank(collector);
        fStream.transferFrom(collector, stranger, sold);
        assertEq(fStream.ownerOf(sold), stranger);
    }

    function test_Flow_AccountDelistingStopsEveryContractOfTheAccount() public {
        registry.setAccountDelisted(fArtistId, true, bytes32("vote"));
        assertFalse(fStream.isMinter(address(indSale)));
        assertFalse(fEditions.isMinter(address(indEdSale)));
        assertEq(
            uint8(registry.entry(address(fStream)).status),
            uint8(IIndependentStreamRegistry.Status.DELISTED)
        );
        registry.setAccountDelisted(fArtistId, false, bytes32("vote 2"));
        assertTrue(fStream.isMinter(address(indSale)));
    }

    function test_Flow_AFrozenArtistAdministersNothing() public {
        accountsModule.freeze(fArtistId);
        vm.prank(artist);
        vm.expectRevert();
        fStream.setContractURI("x");
        vm.prank(artist);
        vm.expectRevert();
        registry.approveItem(address(fStream), bytes32(uint256(1)), RATE);
    }

    function test_Flow_ALoweredShareAppliesToNewWorks() public {
        registry.lowerFeeShare(address(fStream), 2_500);
        (, MintFacts memory f, MintTerms memory t) = _start(6);
        assertEq(t.feeShare, 2_500);
        assertEq(
            f.royaltyReceiver, ledger.walletFor(Splits.royaltyPayees(f.seller, feeVault, 2_500), 0)
        );
    }

    function test_Flow_ARemovedSaleContractFinishesAndIsRescuedAfterTheDelay() public {
        uint256 id = _fedMint(7);
        registry.setAdapter(address(indSale), IIndependentStreamRegistry.Form.ERC721, false);
        assertFalse(fStream.isMinter(address(indSale)));
        vm.warp(block.timestamp + fStream.rescueDelay());
        fStream.rescue(id, collector);
        assertEq(fStream.ownerOf(id), collector);
        assertEq(uint8(fStream.workOf(id).outcome), uint8(Outcome.RESCUED));
    }

    function test_Flow_ReplacingTheIndependentStreamModuleChangesEveryTokensGateAtOnce() public {
        uint256 id = _fedMint(8);
        indDirectory.removeModule(Slots.INDEPENDENT_STREAM);
        assertFalse(fStream.isMinter(address(indSale)));
        indSale.record(address(fStream), id, true, collector, 1);
        assertEq(uint8(fStream.workOf(id).outcome), uint8(Outcome.SOLD));
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(indSale)));
        indSale.mint(address(fStream), _facts(9));
    }

    function test_Flow_TheArtistChangesTheRendererAfterTheWait() public {
        MockRenderer next = new MockRenderer();
        vm.prank(wallet);
        fStream.proposeModule(Slots.RENDERER, address(next));
        vm.warp(block.timestamp + fStream.moduleDelay());
        fStream.activateModule(Slots.RENDERER);
        assertEq(fStream.moduleOf(Slots.RENDERER), address(next));
    }

    function _start(uint256 n)
        internal
        returns (uint256 id, MintFacts memory f, MintTerms memory t)
    {
        (PackageItem memory item, MediaFile[] memory media) = _item(n);
        _approve(address(fStream), item, RATE);
        return
            indSale.start(
                address(registry), address(fStream), _request(item, media, new bytes[](0))
            );
    }
}
