// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IWorkDelivery, IWorkLocators } from "src/interfaces/IWorkDelivery.sol";
import { FileRole, Locator, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { HandlerReach } from "../helpers/HandlerReach.sol";
import { RecordsFixture } from "./RecordsFixture.sol";
import { WorkDeliveryHandler } from "./WorkDeliveryHandler.sol";

/// @notice Stateful invariants of the delivery contracts (WS-19 to WS-22, WS-39, WS-40) over
///         three open works of two media files each, in three collections, through finalize,
///         on-chain sync and replacement of the delivery contract by real and hostile ones:
///         locators are append-only and within their quotas, dead marks only gain, every real
///         delivery contract resolves a file's preferred locator in WS-21's order, and the
///         records satellite serves the current delivery's answer only when it is well formed.
///         Run with the foundry.toml campaign (256 runs x depth 128, `fail_on_revert`); the
///         three state invariants read every file of every installed delivery contract, so they
///         are checked after every fourth call (every call in the `deep` profile), as the other
///         campaigns whose checks read many contracts are; each action checks its own outcome.
contract WorkDeliveryInvariantTest is RecordsFixture {
    WorkDeliveryHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new WorkDeliveryHandler(records, artist, platform, storageOperator, governor);
        vm.startPrank(platform);
        uint256 second = stream.createCollection("Second", keccak256("second"));
        uint256 third = stream.createCollection("Third", keccak256("third"));
        vm.stopPrank();
        uint256[3] memory collections = [collectionId, second, third];
        for (uint256 i; i < 3; ++i) {
            MediaFile[] memory media = new MediaFile[](2);
            media[0] = _mediaFile(10 * i, FileRole.PRIMARY, true);
            media[1] = _mediaFile(10 * i + 1, FileRole.PREVIEW, true);
            PackageItem memory item = _recordsItem(i, media);
            item.collectionId = collections[i];
            uint256 tokenId = _mint(item);
            records.openRecord(tokenId, item, media);
            bytes32[] memory files = new bytes32[](2);
            (files[0], files[1]) = (media[0].fileId, media[1].fileId);
            handler.addWork(tokenId, files, collections[i]);
        }
        handler.setCollectionCount(stream.collectionCount());
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.addLocator.selector;
        selectors[1] = handler.addLocator.selector; // locators twice as often
        selectors[2] = handler.addLocator.selector;
        selectors[3] = handler.markDead.selector;
        selectors[4] = handler.setFilePreference.selector;
        selectors[5] = handler.setCollectionKind.selector;
        selectors[6] = handler.setGlobalKind.selector;
        selectors[7] = handler.finalize.selector;
        selectors[8] = handler.sync.selector;
        selectors[9] = handler.replaceDelivery.selector;
        selectors[10] = handler.setFilePreference.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// INV-WD-1 (WS-19, WS-20): in every real delivery contract ever installed, each file's
    /// locators are exactly the ones the model appended, in order (append-only: none removed,
    /// reordered or rewritten), at most 16; the artist added at most 8 and only before
    /// finalize, the platform at most 8 before finalize and at most the artist's unused slots
    /// more after; the counts, the artist mask and the dead mask match the model, and a dead
    /// mark never clears.
    /// forge-config: default.invariant.check_interval = 4
    /// forge-config: deep.invariant.check_interval = 1
    function invariant_LocatorsAppendOnlyAndBounded() public view {
        for (uint256 d; d < handler.deliveryCount(); ++d) {
            if (!handler.isReal(d)) continue;
            IWorkLocators delivery_ = IWorkLocators(handler.deliveries(d));
            for (uint256 i; i < handler.tokenCount(); ++i) {
                uint256 t = handler.tokens(i);
                bytes32[] memory files = handler.filesOf(t);
                for (uint256 j; j < files.length; ++j) {
                    _checkLocators(d, delivery_, t, files[j]);
                }
            }
        }
    }

    function _checkLocators(uint256 d, IWorkLocators delivery_, uint256 t, bytes32 f)
        internal
        view
    {
        Locator[] memory stored = delivery_.locators(t, f);
        (uint8[] memory kinds, string[] memory uris) = handler.modelLocators(d, t, f);
        assertEq(stored.length, kinds.length, "locator count");
        assertLe(stored.length, 16, "at most 16 per file");
        for (uint256 k; k < stored.length; ++k) {
            assertEq(uint8(stored[k].kind), kinds[k], "kind");
            assertEq(stored[k].uri, uris[k], "uri");
        }
        (uint256 artistN, uint256 platformN, uint256 byArtist, uint256 dead,) =
            handler.modelCounts(d, t, f);
        (uint256 a, uint256 p, uint256 mask) = delivery_.locatorCounts(t, f);
        assertEq(a, artistN, "artist count");
        assertEq(p, platformN, "platform count");
        assertEq(mask, byArtist, "artist mask");
        assertLe(a, 8, "artist quota");
        assertLe(a + p, 16, "file quota");
        if (!handler.finalized(t)) assertLe(p, 8, "platform quota before finalize");
        assertEq(delivery_.deadLocators(t, f), dead, "dead mask");
    }

    /// INV-WD-2 (WS-21, WS-22): every real delivery contract ever installed, served or not,
    /// answers each file's preferred locator in WS-21's order over its own locators: the file's
    /// live preferred index, the collection's kind, the global kind, the first live locator,
    /// the implicit ONCHAIN copy of a synced work, else nothing; a dead locator is never
    /// served, and the stored file preference names a locator of that file or none.
    /// forge-config: default.invariant.check_interval = 4
    /// forge-config: deep.invariant.check_interval = 1
    function invariant_PreferenceResolutionOrder() public view {
        for (uint256 d; d < handler.deliveryCount(); ++d) {
            if (!handler.isReal(d)) continue;
            IWorkDelivery delivery_ = IWorkDelivery(handler.deliveries(d));
            for (uint256 i; i < handler.tokenCount(); ++i) {
                uint256 t = handler.tokens(i);
                bytes32[] memory files = handler.filesOf(t);
                for (uint256 j; j < files.length; ++j) {
                    (IWorkDelivery.Location memory got, uint256 index) =
                        delivery_.preferredLocator(t, files[j]);
                    (uint8 kind, string memory uri, uint256 want) =
                        handler.expectedLocator(d, t, files[j]);
                    assertEq(got.kind, kind, "preferred kind");
                    assertEq(got.uri, uri, "preferred uri");
                    assertEq(index, want, "preferred index");
                    (,,, uint256 dead, uint256 pref) = handler.modelCounts(d, t, files[j]);
                    if (want != type(uint256).max) assertEq((dead >> want) & 1, 0, "dead served");
                    assertEq(IWorkLocators(address(delivery_)).filePreference(t, files[j]), pref);
                }
            }
        }
    }

    /// INV-WD-3 (WS-39, WS-40): the records satellite names the delivery contract governance
    /// installed last, each installed contract named its predecessor, and `preferredLocator`
    /// serves the current contract's answer only when it is well formed: a real successor's
    /// own resolution; under a hostile one its one well-formed answer, else the work's own
    /// (the ONCHAIN copy of a synced work, else nothing), never another locator. Facts the
    /// delivery reads (finalized, on-chain complete) match the model.
    /// forge-config: default.invariant.check_interval = 4
    /// forge-config: deep.invariant.check_interval = 1
    function invariant_RecordsServeOnlyWellFormedAnswers() public view {
        assertEq(records.delivery(), handler.deliveries(handler.current()), "current delivery");
        for (uint256 d = 1; d < handler.deliveryCount(); ++d) {
            assertEq(
                IWorkDelivery(handler.deliveries(d)).predecessor(),
                handler.predecessorOf(d),
                "predecessor"
            );
        }
        for (uint256 i; i < handler.tokenCount(); ++i) {
            uint256 t = handler.tokens(i);
            assertEq(records.record(t).finalized, handler.finalized(t), "finalized");
            assertEq(records.record(t).onChainComplete, handler.synced(t), "on-chain complete");
            bytes32[] memory files = handler.filesOf(t);
            for (uint256 j; j < files.length; ++j) {
                (IWorkDelivery.Location memory got, uint256 index) =
                    records.preferredLocator(t, files[j]);
                (uint8 kind, string memory uri, uint256 want) = handler.expectedServed(t, files[j]);
                assertEq(got.kind, kind, "served kind");
                assertEq(got.uri, uri, "served uri");
                assertEq(index, want, "served index");
            }
        }
    }

    /// INV-WD-4: every action had the outcome the model predicts: strangers, the artist after
    /// finalize, a duplicate URI, a malformed URI, a full quota, a dead or missing index, an
    /// unknown collection, a stale compare-and-set value and a stranger's replacement are all
    /// refused (a permitted caller's locator refusal with `InvalidLocator`), and everything the
    /// rules allow succeeds.
    function invariant_EveryCallHadThePredictedOutcome() public view {
        assertEq(handler.violations(), 0);
    }

    /// @notice Handler self-test: every action changes the delivery contracts or the records
    ///         satellite, or (stale replacements) is refused there; locators are added and
    ///         refused, marked dead, preferred, and served through real and hostile
    ///         replacements. Then every invariant holds.
    function test_HandlerPathsReachState() public {
        uint8 w = HandlerReach.WRITES;
        uint8 wr = HandlerReach.WRITES | HandlerReach.REFUSED;
        HandlerReach.Expect[] memory e = new HandlerReach.Expect[](9);
        e[0] = HandlerReach.Expect(handler.addLocator.selector, wr);
        e[1] = HandlerReach.Expect(handler.markDead.selector, wr);
        e[2] = HandlerReach.Expect(handler.setFilePreference.selector, wr);
        e[3] = HandlerReach.Expect(handler.setCollectionKind.selector, wr);
        e[4] = HandlerReach.Expect(handler.setGlobalKind.selector, w);
        e[5] = HandlerReach.Expect(handler.finalize.selector, wr);
        e[6] = HandlerReach.Expect(handler.sync.selector, w);
        e[7] = HandlerReach.Expect(handler.replaceDelivery.selector, wr);
        e[8] = HandlerReach.Expect(handler.addLocator.selector, wr);
        HandlerReach.covers(targetSelectors()[0].selectors, e);
        // The first delivery, the records satellite, and every contract the handler can create
        // in a run (its replacement delivery contracts, real or scripted).
        address[] memory sut = new address[](42);
        sut[0] = address(delivery);
        sut[1] = address(records);
        for (uint256 n = 1; n <= 40; ++n) {
            sut[n + 1] = vm.computeCreateAddress(address(handler), n);
        }
        HandlerReach.Tally[] memory t = new HandlerReach.Tally[](e.length);
        uint256 replaced;
        uint256 hostile;
        uint256 refusedAdds;
        uint256 deaths;
        for (uint256 run; run < 6; ++run) {
            uint256 snapshot = vm.snapshotState();
            HandlerReach.add(t, HandlerReach.drive(address(handler), e, sut, 14, run));
            replaced += handler.replacements();
            refusedAdds += handler.refusedAdds();
            deaths += handler.deaths();
            for (uint256 d; d < handler.deliveryCount(); ++d) {
                if (!handler.isReal(d)) ++hostile;
            }
            if (run < 5) vm.revertToState(snapshot);
        }
        HandlerReach.check(e, t);
        assertGt(replaced, 0);
        assertGt(hostile, 0);
        assertGt(refusedAdds, 0);
        assertGt(deaths, 0);
        assertGt(handler.added(), 0);
        invariant_LocatorsAppendOnlyAndBounded();
        invariant_PreferenceResolutionOrder();
        invariant_RecordsServeOnlyWellFormedAnswers();
        invariant_EveryCallHadThePredictedOutcome();
    }
}
