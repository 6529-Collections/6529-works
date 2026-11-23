// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IIndependentStreamMembership } from "src/interfaces/IIndependentStreamMembership.sol";
import { Outcome, PendingModule, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IModules, IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IndependentIntegrationBase } from "./IndependentIntegrationBase.sol";

/// @notice The module and minter lifecycle through governance on the real deployed stack: the
///         network announces a module in a slot of Stream, Editions and Directory and adds a
///         minter; each is refused before `moduleDelay` and active after, and removed at once.
///         Every waiting-period setting (`moduleDelay`, `rescueDelay`, `rebindDelay`,
///         `unclaimedPeriod`) is the network's, changed at once; an announcement or a minter
///         already pending keeps the time it was given. A removed minter's unsold work is rescued
///         once `rescueDelay` has passed.
contract ModuleLifecycleTest is IndependentIntegrationBase {
    uint48 internal constant DELAY = 7 days;

    address internal stranger = makeAddr("stranger");

    // ------------------------------------------------------------------ module slots

    function test_ModuleLifecycle_AStreamModuleWaitsTheDelayAndIsRemovedAtOnce() public {
        uint256 tokenId = _liveStreamWork();
        address next = _newRenderer();
        uint48 readyAt = uint48(block.timestamp) + DELAY;

        vm.expectEmit(address(stream));
        emit IModuleSlots.ModuleProposed(Slots.RENDERER, next, readyAt);
        _asNetwork(
            address(stream), abi.encodeCall(IModuleSlots.proposeModule, (Slots.RENDERER, next))
        );
        PendingModule memory p = stream.pendingModule(Slots.RENDERER);
        assertEq(p.module, next);
        assertEq(p.readyAt, readyAt);
        _activateRefusedUntil(address(stream), Slots.RENDERER, readyAt);
        assertEq(stream.moduleOf(Slots.RENDERER), next);
        assertEq(stream.rendererOf(tokenId), next, "an open work draws with the new renderer");
        assertEq(stream.pendingModule(Slots.RENDERER).readyAt, 0, "the announcement is used");

        // Removed at once: nothing draws an unfinalized work.
        _asNetwork(address(stream), abi.encodeCall(IModuleSlots.removeModule, (Slots.RENDERER)));
        assertEq(stream.moduleOf(Slots.RENDERER), address(0));
        assertEq(stream.rendererOf(tokenId), address(0));
        vm.expectRevert();
        stream.tokenURI(tokenId);
    }

    function test_ModuleLifecycle_AnEditionsModuleWaitsTheDelay() public {
        address next = _newStreamTerms();
        _asNetwork(
            address(editions), abi.encodeCall(IModuleSlots.proposeModule, (Slots.TERMS, next))
        );
        _activateRefusedUntil(address(editions), Slots.TERMS, uint48(block.timestamp) + DELAY);
        assertEq(editions.moduleOf(Slots.TERMS), next);
        _asNetwork(address(editions), abi.encodeCall(IModuleSlots.removeModule, (Slots.TERMS)));
        assertEq(editions.moduleOf(Slots.TERMS), address(0));
    }

    function test_ModuleLifecycle_ADirectoryModuleWaitsTheDelayAndReachesEveryIndependentToken()
        public
    {
        (IndependentStream6529 fStream,) = _listPair(_actor("lifecycleArtist"));
        address next = _newStreamTerms();
        _asNetwork(
            address(directory),
            abi.encodeCall(IModuleSlots.proposeModule, (Slots.INDEPENDENT_TERMS, next))
        );
        assertEq(fStream.moduleOf(Slots.TERMS), address(terms), "not before the wait");
        _activateRefusedUntil(
            address(directory), Slots.INDEPENDENT_TERMS, uint48(block.timestamp) + DELAY
        );
        assertEq(
            fStream.moduleOf(Slots.TERMS), next, "every Independent Stream token reads it at once"
        );

        // Emptying INDEPENDENT_STREAM stops Independent Stream minting at once, and nothing else.
        assertTrue(fStream.isMinter(address(auction)));
        _asNetwork(
            address(directory),
            abi.encodeCall(IModuleSlots.removeModule, (Slots.INDEPENDENT_STREAM))
        );
        assertFalse(fStream.isMinter(address(auction)));
        assertEq(auction.policyOf(address(fStream)), address(0));
    }

    function test_ModuleLifecycle_OnlyTheNetworkAnnouncesAndRemoves() public {
        address next = _newRenderer();
        address[3] memory targets = [address(stream), address(editions), address(directory)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(stranger);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
            );
            IModuleSlots(targets[i]).proposeModule(Slots.RENDERER, next);
            vm.prank(stranger);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
            );
            IModuleSlots(targets[i]).removeModule(Slots.TERMS);
        }
        // An announcement without code is refused.
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.InvalidModule.selector, stranger));
        stream.proposeModule(Slots.RENDERER, stranger);
    }

    // ------------------------------------------------------------------ minters

    function test_ModuleLifecycle_AMinterWaitsTheDelayAndIsRemovedAtOnce() public {
        address second = _newEnglishAuction(address(registry));
        uint48 activeFrom = uint48(block.timestamp) + DELAY;
        vm.expectEmit(address(stream));
        emit IModules.MinterAdded(second, activeFrom);
        _asNetwork(address(stream), abi.encodeCall(IModules.addMinter, (second)));
        assertEq(stream.minterOf(second).activeFrom, activeFrom);
        assertFalse(stream.isMinter(second));

        Work[] memory works = new Work[](2);
        works[0] = _work(_actor("minterArtist"), collectionId);
        works[1] = _work(_actor("minterArtist2"), collectionId);
        bytes32 root = _publish(works);
        bytes memory request = _mintData(root, works, 0);
        vm.warp(activeFrom - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.NotSaleContract.selector, address(stream), second)
        );
        IEnglishAuction(second).start(address(stream), request);

        vm.warp(activeFrom);
        assertTrue(stream.isMinter(second));
        uint256 saleId = IEnglishAuction(second).start(address(stream), request);
        uint256 tokenId = stream.totalMinted();
        assertEq(stream.ownerOf(tokenId), second, "minted into the new minter's custody");
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        IEnglishAuction(second).bid{ value: 1 ether }(saleId, address(0));
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IModules.MinterAlreadyAdded.selector, second));
        stream.addMinter(second);

        // Removed at once: it mints nothing new and still finishes its sale.
        vm.expectEmit(address(stream));
        emit IModules.MinterRemoved(second);
        _asNetwork(address(stream), abi.encodeCall(IModules.removeMinter, (second)));
        assertFalse(stream.isMinter(second));
        assertEq(stream.minterOf(second).removedAt, block.timestamp);
        bytes memory nextRequest = _mintData(root, works, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.NotSaleContract.selector, address(stream), second)
        );
        IEnglishAuction(second).start(address(stream), nextRequest);
        vm.warp(IEnglishAuction(second).auction(saleId).endTime);
        IEnglishAuction(second).settle(saleId);
        assertEq(stream.ownerOf(tokenId), stranger);
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.SOLD));
    }

    function test_ModuleLifecycle_AnEditionsMinterWaitsTheDelay() public {
        address lens = deployment.editionAuctionLens;
        address second = _deployArtifact(
            "UniformEditionAuction.sol:UniformEditionAuction",
            bytes.concat(
                abi.encode(
                    address(manager),
                    address(escrow),
                    address(directory),
                    address(editions),
                    address(auction),
                    lens,
                    lens.codehash
                ),
                params.editionAuctionConfig
            )
        );
        _asNetwork(address(editions), abi.encodeCall(IModules.addMinter, (second)));
        vm.warp(block.timestamp + DELAY - 1);
        assertFalse(editions.isMinter(second));
        vm.warp(block.timestamp + 1);
        assertTrue(editions.isMinter(second));
        _asNetwork(address(editions), abi.encodeCall(IModules.removeMinter, (second)));
        assertFalse(editions.isMinter(second));
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, second));
        editions.removeMinter(second);
    }

    // ------------------------------------------------------------------ settings

    function test_ModuleLifecycle_EveryWaitingPeriodIsTheNetworksAtOnce() public {
        address[3] memory slots = [address(stream), address(editions), address(directory)];
        for (uint256 i; i < 3; ++i) {
            (bool immediate, uint32 delay) =
                manager.canCall(network, slots[i], IModuleSlots.setModuleDelay.selector);
            assertTrue(immediate && delay == 0, "no role delay on top of the setting");
            vm.expectEmit(slots[i]);
            emit IModuleSlots.ModuleDelaySet(DELAY, 2 days);
            _asNetwork(slots[i], abi.encodeCall(IModuleSlots.setModuleDelay, (2 days)));
            assertEq(IModuleSlots(slots[i]).moduleDelay(), 2 days);
            vm.prank(stranger);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
            );
            IModuleSlots(slots[i]).setModuleDelay(0);
        }

        vm.expectEmit(address(stream));
        emit IStream.RescueDelaySet(14 days, 3 days);
        _asNetwork(address(stream), abi.encodeCall(IStream.setRescueDelay, (3 days)));
        assertEq(stream.rescueDelay(), 3 days);

        vm.expectEmit(address(editions));
        emit IEditions.RebindDelaySet(14 days, 4 days);
        _asNetwork(address(editions), abi.encodeCall(IEditions.setRebindDelay, (4 days)));
        assertEq(editions.rebindDelay(), 4 days);

        vm.expectEmit(address(directory));
        emit IDirectory.UnclaimedPeriodSet(180 days, 90 days);
        _asNetwork(address(directory), abi.encodeCall(IDirectory.setUnclaimedPeriod, (90 days)));
        assertEq(directory.unclaimedPeriod(), 90 days);

        // Zero is allowed: a module announced now is ready now.
        _asNetwork(address(stream), abi.encodeCall(IModuleSlots.setModuleDelay, (0)));
        address next = _newRenderer();
        _asNetwork(
            address(stream), abi.encodeCall(IModuleSlots.proposeModule, (Slots.RENDERER, next))
        );
        stream.activateModule(Slots.RENDERER);
        assertEq(stream.moduleOf(Slots.RENDERER), next);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        stream.setRescueDelay(0);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        directory.setUnclaimedPeriod(0);
    }

    function test_ModuleLifecycle_TheNetworkSetsEveryIndependentTokensWaitThroughTheDirectory()
        public
    {
        address artist = _actor("delayArtist");
        (IndependentStream6529 fStream,) = _listPair(artist);
        vm.prank(network);
        fStream.setModuleDelay(1 days);
        assertEq(fStream.moduleDelay(), 1 days);
        vm.prank(network);
        fStream.setRescueDelay(2 days);
        assertEq(fStream.rescueDelay(), 2 days);
        // The artist administers the renderer, not the wait.
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotNetwork.selector, artist)
        );
        fStream.setModuleDelay(0);
    }

    function test_ModuleLifecycle_APendingAnnouncementKeepsTheTimeItWasGiven() public {
        address first = _newRenderer();
        uint48 readyAt = uint48(block.timestamp) + DELAY;
        _asNetwork(
            address(stream), abi.encodeCall(IModuleSlots.proposeModule, (Slots.RENDERER, first))
        );
        address minter = _newEnglishAuction(address(registry));
        _asNetwork(address(stream), abi.encodeCall(IModules.addMinter, (minter)));

        // Longer: the pending ones keep 7 days.
        _asNetwork(address(stream), abi.encodeCall(IModuleSlots.setModuleDelay, (30 days)));
        assertEq(stream.pendingModule(Slots.RENDERER).readyAt, readyAt);
        assertEq(stream.minterOf(minter).activeFrom, readyAt);
        // Shorter: they still wait 7 days.
        _asNetwork(address(stream), abi.encodeCall(IModuleSlots.setModuleDelay, (1 days)));
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.RENDERER)
        );
        stream.activateModule(Slots.RENDERER);
        assertFalse(stream.isMinter(minter));

        vm.warp(readyAt);
        stream.activateModule(Slots.RENDERER);
        assertEq(stream.moduleOf(Slots.RENDERER), first);
        assertTrue(stream.isMinter(minter));

        // A new announcement takes the setting in force.
        address second = _newRenderer();
        _asNetwork(
            address(stream), abi.encodeCall(IModuleSlots.proposeModule, (Slots.RENDERER, second))
        );
        assertEq(stream.pendingModule(Slots.RENDERER).readyAt, block.timestamp + 1 days);
    }

    // ------------------------------------------------------------------ rescue

    function test_ModuleLifecycle_ARemovedMintersUnsoldWorkIsRescuedAfterTheDelay() public {
        Work[] memory works = _one(_work(_actor("rescueArtist"), collectionId));
        bytes32 root = _publish(works);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);
        address bidder = makeAddr("rescueBidder");
        _ethBid(saleId, bidder, 1 ether);

        // Not rescuable while its minter is active.
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, tokenId));
        stream.rescue(tokenId, museum);

        _asNetwork(address(stream), abi.encodeCall(IModules.removeMinter, (address(auction))));
        uint256 removedAt = block.timestamp;
        vm.warp(removedAt + 14 days - 1);
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, tokenId));
        stream.rescue(tokenId, museum);

        // The wait in force at the rescue decides.
        _asNetwork(address(stream), abi.encodeCall(IStream.setRescueDelay, (30 days)));
        vm.warp(removedAt + 14 days);
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, tokenId));
        stream.rescue(tokenId, museum);
        _asNetwork(address(stream), abi.encodeCall(IStream.setRescueDelay, (14 days)));

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        stream.rescue(tokenId, stranger);
        vm.expectEmit(address(stream));
        emit IStream.WorkRescued(tokenId, address(auction), museum);
        _asNetwork(address(stream), abi.encodeCall(IStream.rescue, (tokenId, museum)));
        assertEq(stream.ownerOf(tokenId), museum);
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.RESCUED));

        // The auction closes the sale with the bid credited back.
        vm.expectEmit(address(auction));
        emit IEnglishAuction.RescuedSaleClosed(saleId);
        auction.settle(saleId);
        assertEq(auction.claimable(bidder), 1 ether);
    }

    function test_ModuleLifecycle_AIndependentWorkIsRescuedAfterItsSaleContractIsRemoved() public {
        address artist = _actor("indRescueArtist");
        (IndependentStream6529 fStream,) = _listPair(artist);
        (,, uint256 tokenId) = _fedApproveAndStart(address(fStream), artist);
        _asNetwork(
            address(independentStream),
            abi.encodeCall(
                independentStream.setAdapter,
                (address(auction), IIndependentStreamRegistry.Form.ERC721, false)
            )
        );
        uint256 removedAt = block.timestamp;
        assertFalse(fStream.isMinter(address(auction)));
        vm.warp(removedAt + fStream.rescueDelay() - 1);
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, tokenId));
        fStream.rescue(tokenId, artist);
        vm.warp(removedAt + fStream.rescueDelay());
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamMembership.NotNetwork.selector, stranger)
        );
        fStream.rescue(tokenId, artist);
        vm.prank(network);
        fStream.rescue(tokenId, artist);
        assertEq(fStream.ownerOf(tokenId), artist);
        assertEq(uint8(fStream.workOf(tokenId).outcome), uint8(Outcome.RESCUED));
    }

    // ------------------------------------------------------------------ helpers

    /// @dev A 6529 Stream work in a running sale, its record opened (not finalized).
    function _liveStreamWork() internal returns (uint256 tokenId) {
        Work[] memory works = _one(_work(_actor("liveArtist"), collectionId));
        bytes32 root = _publish(works);
        (, tokenId) = _start(root, works, 0);
        _open(tokenId, works[0]);
    }

    /// @dev `activateModule` is refused one second before `readyAt` and works at it (by anyone).
    function _activateRefusedUntil(address target, bytes32 slot, uint48 readyAt) internal {
        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, slot));
        IModuleSlots(target).activateModule(slot);
        vm.warp(readyAt);
        vm.prank(stranger);
        IModuleSlots(target).activateModule(slot);
    }
}
