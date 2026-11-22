// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Renderer } from "src/content/Renderer.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IWorkPowers, WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { Facts, Outcome, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { IWorkRules } from "src/interfaces/core/IWorkRules.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { WorkRules } from "src/records/WorkRules.sol";
import { RecordFlowsBase } from "./RecordFlowsBase.sol";

/// @notice A work's record through its whole life on the real stack, `WorkRules` (the RECORDS
///         module) over `WorkFacts` (the permanent record): opened by `SaleStarter` or by anyone,
///         edited by the artist, relicensed with every party's consent and the network's call,
///         finalized by the artist or by anyone 14 days after a notice that follows the sale's
///         outcome, then fixed; media fixed from the start; CC0 never left; one-way locks; the
///         network's repin before the pin is locked; a finalized work drawn by its pinned
///         renderer whatever the token's RENDERER module becomes.
contract RecordLifecycleTest is RecordFlowsBase {
    address internal lead;
    address internal collector = makeAddr("recordCollector");
    address internal stranger = makeAddr("recordStranger");
    bytes32 internal byText;

    function setUp() public override {
        super.setUp();
        lead = _actor("recordLead");
        byText = _storeText(bytes("Creative Commons Attribution 4.0 (fixture text)"), "text/plain");
    }

    function _finalizeAsLead(uint256 tokenId) internal {
        bytes32 state = _state(tokenId);
        vm.prank(lead);
        rules.finalize(address(stream), tokenId, state);
    }

    function _facts(uint256 tokenId) internal view returns (Facts memory) {
        return facts.factsOf(address(stream), tokenId);
    }

    // ------------------------------------------------------------------ opening

    /// @dev `SaleStarter` opens the record in the start transaction; nobody opens it twice.
    function test_Record_SaleStarterOpensItOnce() public {
        Work[] memory works = _one(_work(lead, collectionId));
        (, uint256 tokenId) = _startAndOpen(_publish(works), works, 0);
        Facts memory f = _facts(tokenId);
        assertTrue(f.opened);
        assertEq(f.recordFileId, works[0].item.recordFileId);
        assertEq(f.media.length, 1);
        assertEq(f.media[0].fileId, works[0].media[0].fileId);
        assertEq(f.licenseId, "CC0-1.0");
        assertEq(f.licenseTextFileId, cc0TextFileId);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.RecordAlreadyOpen.selector, address(stream), tokenId)
        );
        _open(tokenId, works[0]);
    }

    /// @dev Started directly, the record stays closed (no edit, no finalize) until anyone opens
    ///      it with the exact item and media; other media are refused.
    function test_Record_AnyoneOpensWithTheExactItem() public {
        Work[] memory works = _one(_work(lead, collectionId));
        (, uint256 tokenId) = _start(_publish(works), works, 0);
        bytes32 next = _record("Edited before open");
        vm.prank(lead);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.RecordNotOpen.selector, address(stream), tokenId)
        );
        rules.setRecord(address(stream), tokenId, next, bytes32(0));

        Work memory other = _work(lead, collectionId);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, address(stream), tokenId)
        );
        facts.open(address(stream), tokenId, works[0].item, other.media);

        vm.prank(stranger);
        _open(tokenId, works[0]);
        assertTrue(_facts(tokenId).opened);
    }

    // ------------------------------------------------------------------ the artist's edits

    function test_Record_ArtistEditsUntilFinalizeThenItIsFixed() public {
        Work[] memory works = _one(_work(lead, collectionId));
        (, uint256 tokenId) = _startAndOpen(_publish(works), works, 0);
        bytes32 next = _record("Second record");
        bytes32 state = _state(tokenId);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWorkRules.NotWorkArtist.selector, address(stream), tokenId, stranger
            )
        );
        rules.setRecord(address(stream), tokenId, next, state);
        // Nobody but the RECORDS module writes to the permanent record.
        vm.prank(lead);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.NotRecordsModule.selector, address(stream), lead)
        );
        facts.setRecord(address(stream), tokenId, next);
        // A record file that is only registered is refused.
        bytes memory text = bytes('{"name":"off-chain"}');
        bytes32 offChain =
            _registerOnly(text, IContentStore.Encoding.Identity, "application/json", sha256(text));
        vm.prank(lead);
        vm.expectRevert(abi.encodeWithSelector(WorkRules.InvalidRecordFile.selector, offChain));
        rules.setRecord(address(stream), tokenId, offChain, state);

        vm.prank(lead);
        rules.setRecord(address(stream), tokenId, next, state);
        assertEq(_facts(tokenId).recordFileId, next);
        assertTrue(_contains(stream.tokenURI(tokenId), '"name":"Second record"'));
        // The state moved: an edit at the old state is refused.
        bytes32 third = _record("Third record");
        bytes32 now_ = _state(tokenId);
        vm.prank(lead);
        vm.expectRevert(abi.encodeWithSelector(IWorkRules.StateHashMismatch.selector, state, now_));
        rules.setRecord(address(stream), tokenId, third, state);

        // The artist finalizes at any time, before the sale ends; then the record is fixed.
        vm.prank(lead);
        rules.finalize(address(stream), tokenId, now_);
        assertTrue(_facts(tokenId).finalized);
        bytes32 finalState = _state(tokenId);
        vm.prank(lead);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.WorkIsFinalized.selector, address(stream), tokenId)
        );
        rules.setRecord(address(stream), tokenId, third, finalState);
        assertEq(_facts(tokenId).recordFileId, next);
    }

    // ------------------------------------------------------------------ the finalize notice

    /// @dev Anyone else finalizes only after the sale's outcome, 14 days after a notice: refused
    ///      before the outcome, refused one second before the notice ends, done at its end, as
    ///      the record then stands (the artist's edit during the notice included).
    function test_Record_AnyoneFinalizesFourteenDaysAfterTheNoticeThatFollowsTheOutcome() public {
        Work[] memory works = _one(_work(lead, collectionId));
        (uint256 saleId, uint256 tokenId) = _startAndOpen(_publish(works), works, 0);
        _ethBid(saleId, collector, 1 ether);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWorkRules.NotWorkArtist.selector, address(stream), tokenId, stranger
            )
        );
        rules.finalize(address(stream), tokenId, bytes32(0));

        _settleAtEnd(saleId);
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.SOLD));
        uint256 noticeAt = block.timestamp;
        vm.expectEmit(address(rules));
        emit IWorkRules.FinalizeNoticeRecorded(address(stream), tokenId, noticeAt + 14 days);
        vm.prank(stranger);
        rules.finalize(address(stream), tokenId, bytes32(0));
        assertEq(rules.finalizeNoticeAt(address(stream), tokenId), noticeAt);
        assertFalse(_facts(tokenId).finalized, "a notice only");

        // The artist may still edit during the notice.
        bytes32 edited = _record("Edited during the notice");
        bytes32 noticeState = _state(tokenId);
        vm.prank(lead);
        rules.setRecord(address(stream), tokenId, edited, noticeState);

        vm.warp(noticeAt + FINALIZE_NOTICE - 1);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWorkRules.FinalizeNotDue.selector,
                address(stream),
                tokenId,
                noticeAt + FINALIZE_NOTICE
            )
        );
        rules.finalize(address(stream), tokenId, bytes32(0));

        vm.warp(noticeAt + FINALIZE_NOTICE);
        vm.prank(stranger);
        rules.finalize(address(stream), tokenId, bytes32(0)); // no state hash checked
        Facts memory f = _facts(tokenId);
        assertTrue(f.finalized);
        assertEq(f.recordFileId, edited, "as the record then stood");
        assertEq(f.renderer, address(renderer), "the RENDERER module pinned");
        assertEq(f.rendererCodeHash, address(renderer).codehash);

        bytes32 doneState = _state(tokenId);
        vm.prank(lead);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.WorkIsFinalized.selector, address(stream), tokenId)
        );
        rules.finalize(address(stream), tokenId, doneState);
    }

    // ------------------------------------------------------------------ relicensing

    /// @dev Every party consents (counted by account) and the network calls; a missing or
    ///      foreign consent, a stranger's call and a replayed consent are refused. Then CC0,
    ///      which is never left and always names the deployment's CC0 text.
    function test_Record_RelicenseNeedsEveryConsentAndTheNetworkThenCc0IsNeverLeft() public {
        address collab = _actor("recordCollaborator");
        Work memory w = _withCollaboratorSorted(_work(lead, collectionId), collab, 30_000);
        w.item.license = License("CC-BY-4.0", byText);
        Work[] memory works = _one(w);
        uint256 tokenId = _soldAndOpen(_publish(works), works, 0, collector, 1 ether);
        assertEq(_facts(tokenId).licenseId, "CC-BY-4.0");
        assertTrue(_contains(stream.tokenURI(tokenId), "CC-BY-4.0"));
        _relicenseRefusalsThenMit(tokenId, w, collab);
        _relicenseToCc0ThenKept(tokenId, w, collab);
    }

    function _relicenseRefusalsThenMit(uint256 tokenId, Work memory w, address collab) internal {
        License memory mit =
            License("MIT", _storeText(bytes("MIT License (fixture text)"), "text/plain"));
        // One consent of two.
        _governExpectRevert(
            network,
            address(rules),
            _relicenseCall(tokenId, w, mit, _list(lead)),
            abi.encodeWithSelector(IWorkRules.InvalidConsent.selector, address(stream), tokenId)
        );
        // The collaborator's place signed by someone else.
        {
            address impostor = _actor("recordImpostor");
            _governExpectRevert(
                network,
                address(rules),
                _relicenseCall(tokenId, w, mit, _list(lead, impostor)),
                abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, impostor)
            );
        }
        // Every consent, but not the network's call.
        bytes memory call = _relicenseCall(tokenId, w, mit, _list(lead, collab));
        {
            vm.prank(stranger);
            (bool ok, bytes memory reason) = address(rules).call(call);
            assertFalse(ok);
            assertEq(
                reason,
                abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
            );
        }
        // Consents to another license, signed at the same state.
        bytes memory other = _relicenseCall(
            tokenId,
            w,
            License("Apache-2.0", _storeText(bytes("Apache License 2.0 (fixture)"), "text/plain")),
            _list(lead, collab)
        );
        bytes32 before = _state(tokenId);
        _asNetwork(address(rules), call);
        assertEq(_facts(tokenId).licenseId, "MIT");
        assertEq(_facts(tokenId).licenseTextFileId, mit.textFileId);
        // Every consent given at the earlier state is spent: the state moved.
        bytes32 after_ = _state(tokenId);
        _governExpectRevert(
            network,
            address(rules),
            other,
            abi.encodeWithSelector(IWorkRules.StateHashMismatch.selector, before, after_)
        );
    }

    /// @dev To CC0 with its own text; then CC0 is kept, its text included.
    function _relicenseToCc0ThenKept(uint256 tokenId, Work memory w, address collab) internal {
        _asNetwork(
            address(rules),
            _relicenseCall(tokenId, w, License("CC0-1.0", cc0TextFileId), _list(lead, collab))
        );
        assertEq(WorksHashing.licenseKey(_facts(tokenId).licenseId), WorksHashing.CC0_LICENSE_KEY);
        License memory mit =
            License("MIT", _storeText(bytes("MIT License (after CC0)"), "text/plain"));
        _governExpectRevert(
            network,
            address(rules),
            _relicenseCall(tokenId, w, mit, _list(lead, collab)),
            abi.encodeWithSelector(IWorkFacts.InvalidLicense.selector)
        );
        bytes32 otherText = _storeText(bytes("CC0 1.0 Universal (another text)"), "text/plain");
        _governExpectRevert(
            network,
            address(rules),
            _relicenseCall(tokenId, w, License("CC0-1.0", otherText), _list(lead, collab)),
            abi.encodeWithSelector(IWorkFacts.InvalidLicense.selector)
        );
        assertEq(_facts(tokenId).licenseTextFileId, cc0TextFileId);
    }

    /// @dev After finalize a new license's text must be complete on-chain, not only registered.
    function test_Record_AFinalizedWorkNeedsAnOnChainLicenseText() public {
        Work memory w = _work(lead, collectionId);
        w.item.license = License("CC-BY-4.0", byText);
        Work[] memory works = _one(w);
        uint256 tokenId = _soldAndOpen(_publish(works), works, 0, collector, 1 ether);
        _finalizeAsLead(tokenId);

        bytes memory text = bytes("MIT License (fixture), off-chain only");
        License memory mit = License(
            "MIT", _registerOnly(text, IContentStore.Encoding.Identity, "text/plain", sha256(text))
        );
        _governExpectRevert(
            network,
            address(rules),
            _relicenseCall(tokenId, w, mit, _list(lead)),
            abi.encodeWithSelector(IWorkFacts.InvalidLicense.selector)
        );
        _writeChunks(text);
        _asNetwork(address(rules), _relicenseCall(tokenId, w, mit, _list(lead)));
        assertEq(_facts(tokenId).licenseId, "MIT");
    }

    // ------------------------------------------------------------------ locks and the pin

    /// @dev The license lock (the artist's renunciation with the network's call) is one-way:
    ///      every later relicense is refused, and renouncing it again changes nothing.
    function test_Record_LicenseLockIsOneWay() public {
        Work memory w = _work(lead, collectionId);
        w.item.license = License("CC-BY-4.0", byText);
        Work[] memory works = _one(w);
        uint256 tokenId = _soldAndOpen(_publish(works), works, 0, collector, 1 ether);

        (bytes32 state, uint64 deadline, bytes memory proof) =
            _renounceArgs(tokenId, WorkPowers.RELICENSE, lead);
        bytes memory renounce = abi.encodeCall(
            rules.renounce, (address(stream), tokenId, WorkPowers.RELICENSE, state, deadline, proof)
        );
        // The license power needs the network's call too.
        vm.prank(stranger);
        (bool ok, bytes memory reason) = address(rules).call(renounce);
        assertFalse(ok);
        assertEq(
            reason,
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        _asNetwork(address(rules), renounce);
        assertTrue(_facts(tokenId).licenseLocked);
        assertEq(rules.renouncedPowers(address(stream), tokenId), WorkPowers.RELICENSE);

        License memory mit = License("MIT", _storeText(bytes("MIT License (lock)"), "text/plain"));
        _governExpectRevert(
            network,
            address(rules),
            _relicenseCall(tokenId, w, mit, _list(lead)),
            abi.encodeWithSelector(
                IWorkPowers.PowerRenounced.selector, address(stream), tokenId, WorkPowers.RELICENSE
            )
        );
        // Again: a no-op, from anyone.
        bytes32 version = _state(tokenId);
        rules.renounce(address(stream), tokenId, WorkPowers.RELICENSE, bytes32(0), 0, "");
        assertEq(_state(tokenId), version);
        assertTrue(_facts(tokenId).licenseLocked);
    }

    /// @dev A finalized work is drawn by its pinned renderer whatever the token's RENDERER module
    ///      becomes; the network repins it (not before finalize) until the artist renounces the
    ///      repin power, after which the pin is fixed for good.
    function test_Record_PinnedRendererRepinBeforeLockThenFixed() public {
        Work[] memory works = new Work[](2);
        works[0] = _storedWork(
            lead, _bytes(600, 1), IContentStore.Encoding.Identity, sha256(_bytes(600, 1)), "Pinned"
        );
        works[1] = _storedWork(
            lead, _bytes(600, 2), IContentStore.Encoding.Identity, sha256(_bytes(600, 2)), "Open"
        );
        bytes32 root = _publish(works);
        uint256 pinned = _soldAndOpen(root, works, 0, collector, 1 ether);
        uint256 open = _soldAndOpen(root, works, 1, collector, 1 ether);
        facts.markOnChainComplete(address(stream), pinned);
        facts.markOnChainComplete(address(stream), open);
        _finalizeAsLead(pinned);
        string memory pinnedUri = stream.tokenURI(pinned);
        assertTrue(_contains(pinnedUri, '"image":"data:image/png;base64,'), "inlined");
        assertTrue(_contains(stream.tokenURI(open), '"image":"data:image/png;base64,'), "inlined");

        // A renderer that inlines nothing becomes the token's RENDERER module.
        Renderer next =
            new Renderer(IContentStore(address(store)), IStatementLog(address(statements)), 1);
        _asNetwork(
            address(stream), abi.encodeCall(stream.proposeModule, (Slots.RENDERER, address(next)))
        );
        vm.warp(block.timestamp + stream.moduleDelay());
        stream.activateModule(Slots.RENDERER);
        assertEq(stream.rendererOf(open), address(next));
        assertFalse(_contains(stream.tokenURI(open), "data:image/png"), "the new module draws it");
        assertEq(stream.rendererOf(pinned), address(renderer));
        assertEq(stream.tokenURI(pinned), pinnedUri, "the pinned renderer draws it");

        // No repin before finalize.
        _governExpectRevert(
            network,
            address(rules),
            abi.encodeCall(
                rules.repinRenderer, (address(stream), open, address(next), _state(open))
            ),
            abi.encodeWithSelector(IWorkFacts.WorkNotFinalized.selector, address(stream), open)
        );
        // The network's repin, no artist signature.
        _govern(
            network,
            address(rules),
            abi.encodeCall(
                rules.repinRenderer, (address(stream), pinned, address(next), _state(pinned))
            )
        );
        assertEq(stream.rendererOf(pinned), address(next));
        assertEq(_facts(pinned).rendererCodeHash, address(next).codehash);
        assertFalse(_contains(stream.tokenURI(pinned), "data:image/png"));

        // The artist renounces the repin power (anyone relays; no network call needed).
        (bytes32 state, uint64 deadline, bytes memory proof) =
            _renounceArgs(pinned, WorkPowers.RENDERER_REPIN, lead);
        vm.prank(stranger);
        rules.renounce(address(stream), pinned, WorkPowers.RENDERER_REPIN, state, deadline, proof);
        assertTrue(_facts(pinned).repinLocked);
        _governExpectRevert(
            network,
            address(rules),
            abi.encodeCall(
                rules.repinRenderer, (address(stream), pinned, address(renderer), _state(pinned))
            ),
            abi.encodeWithSelector(
                IWorkPowers.PowerRenounced.selector,
                address(stream),
                pinned,
                WorkPowers.RENDERER_REPIN
            )
        );
        assertEq(stream.rendererOf(pinned), address(next));
    }

    /// @dev Whatever happens to the record, the media stay the files the item committed to.
    function test_Record_MediaNeverChange() public {
        Work[] memory works = _one(_work(lead, collectionId));
        uint256 tokenId = _soldAndOpen(_publish(works), works, 0, collector, 1 ether);
        bytes32 mediaBefore = keccak256(abi.encode(_facts(tokenId).media));
        bytes32 edited = _record("Edited");
        bytes32 state = _state(tokenId);
        vm.prank(lead);
        rules.setRecord(address(stream), tokenId, edited, state);
        _asNetwork(
            address(rules),
            _relicenseCall(tokenId, works[0], License("CC0-1.0", cc0TextFileId), _list(lead))
        );
        _finalizeAsLead(tokenId);
        assertEq(keccak256(abi.encode(_facts(tokenId).media)), mediaBefore);
        assertEq(_facts(tokenId).media[0].fileId, works[0].media[0].fileId);
    }
}
