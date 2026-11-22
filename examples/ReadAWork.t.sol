// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Example: read everything a marketplace or wallet shows for one 6529 Stream work, and the
// network's settings that a careful collector may want to watch.
//
// The reads are plain view calls on the permanent contracts (ADR 0010): `Stream` for ownership,
// the facts fixed at mint and how the first sale ended; `WorkFacts` for the work's permanent
// record (media, record file, license, the renderer pinned at finalization); the renderer for
// the metadata. A front end makes the same calls with `cast call` or a library such as viem;
// the cast versions are in examples/README.md.

import { Vm } from "forge-std/Vm.sol";
import { Collection, Facts, Outcome, Slots, Work } from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IWorkRules } from "src/interfaces/core/IWorkRules.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { ExampleBase } from "./ExampleBase.sol";

contract ExampleReadAWork is ExampleBase {
    address internal collector = makeAddr("collector");
    uint256 internal tokenId;
    bytes32 internal itemHash;
    bytes32 internal primaryFile;
    uint256 internal constant PRICE = 1 ether;

    function setUp() public override {
        super.setUp();
        Package memory pkg = _original();
        primaryFile = pkg.media[0].fileId;
        vm.recordLogs();
        tokenId = _sell(pkg, collector, PRICE);
        itemHash = stream.itemHashOf(tokenId);
        // The artist finalizes the record: from now on its facts and its renderer are fixed.
        IWorkRules rules = IWorkRules(d.workRules);
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        vm.prank(artist);
        rules.finalize(address(stream), tokenId, state);
    }

    function test_ReadAWork() public view {
        // 1. Who owns it. 6529 Stream is a plain OpenZeppelin ERC-721: ownerOf and transfers
        //    never call another contract.
        assertEq(stream.ownerOf(tokenId), collector);

        // 2. What Stream keeps for it: one plain struct. The item hash commits to the approved
        //    item (content, media, parties, payees, license, sale terms); the artist ID, the
        //    collection, the serial, the kind and the seed never change after mint.
        Work memory work = stream.workOf(tokenId);
        assertEq(work.itemHash, itemHash);
        assertEq(work.artistId, uint160(artist), "the artist ID is the account's root wallet");
        assertEq(work.collectionId, 1);
        assertEq(work.serial, 1, "first work in the collection");

        // 3. Its collection.
        Collection memory c = stream.collectionOf(work.collectionId);
        assertEq(c.name, "Genesis");

        // 4. How the first sale ended. The outcome is stored; the price is only logged
        //    (`PrimarySale`, see test_ThePriceIsInTheLog).
        assertEq(uint8(work.outcome), uint8(Outcome.SOLD));

        // 5. The permanent record in WorkFacts: the media (fixed when the record opens), the
        //    descriptive record file (fixed at finalize), the license, and the pinned renderer.
        Facts memory f = facts.factsOf(address(stream), tokenId);
        assertTrue(f.opened && f.finalized);
        assertEq(f.media.length, 1);
        assertEq(f.media[0].fileId, primaryFile, "the primary file is first");
        assertEq(f.licenseId, "CC0-1.0");
        assertEq(f.licenseTextFileId, d.cc0TextFileId, "the CC0 text stored at genesis");
        // The record file itself is in the content store: read it whole.
        IContentStore.FileInfo memory info = store.fileInfo(f.recordFileId);
        bytes memory record = store.read(f.recordFileId, 0, info.length);
        assertEq(bytes1(record[0]), bytes1("{"), "JSON");

        // 6. Who draws it: the renderer pinned at finalize (before that, the token's RENDERER
        //    module). `tokenURI` asks it and never falls back to another one.
        assertEq(stream.rendererOf(tokenId), f.renderer);
        assertEq(f.renderer, stream.moduleOf(Slots.RENDERER), "the module in force when pinned");
        assertEq(f.rendererCodeHash, f.renderer.codehash);
        string memory uri = stream.tokenURI(tokenId);
        assertEq(_prefix(uri, 27), "data:application/json;utf8,", "JSON metadata, inline");

        // 7. Royalties (ERC-2981): read from Stream's own storage, no other contract asked.
        (address receiver, uint256 amount) = stream.royaltyInfo(tokenId, PRICE);
        assertEq(receiver, work.royaltyReceiver);
        assertEq(amount, PRICE * work.royaltyRate / 100_000);
    }

    function test_ThePriceIsInTheLog() public view {
        // Read the PrimarySale event (an indexer does the same from eth_getLogs).
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IStream.PrimarySale.selector;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(stream) || logs[i].topics[0] != topic) continue;
            assertEq(uint256(logs[i].topics[1]), tokenId);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), collector, "the buyer");
            (Outcome outcome, uint256 price) = abi.decode(logs[i].data, (Outcome, uint256));
            assertEq(uint8(outcome), uint8(Outcome.SOLD));
            assertEq(price, PRICE);
            found = true;
        }
        assertTrue(found);
    }

    function test_ReadTheNetworksSettings() public view {
        // The waiting periods in the permanent contracts are the network's settings, not fixed
        // promises: each has a launch value and the network may change it at once (an event
        // carries the old and the new value). Read them; never assume a number.
        assertEq(stream.moduleDelay(), 7 days, "before an added module or minter takes effect");
        assertEq(stream.rescueDelay(), 14 days, "after a minter's removal, before a rescue");
        assertEq(editions.rebindDelay(), 14 days, "after a minter's removal, before a rebind");
        assertEq(directory.unclaimedPeriod(), 180 days, "before unclaimed money can be swept");

        // The modules in force, and whether one is announced (`readyAt` zero: none).
        assertEq(stream.moduleOf(Slots.TERMS), d.streamTerms);
        assertEq(stream.pendingModule(Slots.TERMS).readyAt, 0);
        assertTrue(stream.isMinter(address(auction)));
    }

    function _prefix(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = bytes(s)[i];
        }
        return string(out);
    }
}
