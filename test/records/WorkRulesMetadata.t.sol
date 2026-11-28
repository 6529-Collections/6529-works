// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { Vm } from "forge-std/Vm.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { WorkRules } from "src/records/WorkRules.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { CodeRenderer, RulesChunkStore } from "../mocks/records/RulesMocks.sol";
import { RulesFixture } from "./RulesFixture.sol";

/// @notice What a marketplace is told and shown when a work's record changes, on the real
///         `WorkRules`, `WorkDelivery` and `StreamWorkFacts6529`: every change of the record
///         that metadata shows emits ERC-4906 `MetadataUpdate` on the work's token, and a call
///         that changes nothing emits none (RND-27); and a pinned renderer whose code changed
///         stops both `tokenURI` and the edition's `uri`, whatever the RENDERER module is
///         (RND-2).
contract WorkRulesMetadataTest is RulesFixture {
    address internal s;
    uint64 internal deadline;

    function setUp() public override {
        super.setUp();
        s = address(stream);
        deadline = uint64(block.timestamp + 1 days);
    }

    function _open(uint256 salt) internal returns (uint256 id, PackageItem memory item) {
        (id, item,) = _work(stream, salt);
    }

    function _artistFinalize(uint256 id) internal {
        bytes32 state = _state(id);
        vm.prank(artist);
        rules.finalize(s, id, state);
    }

    /// @dev The next call must make the token emit `MetadataUpdate(id)`.
    function _expectRefresh(uint256 id) internal {
        vm.expectEmit(s);
        emit IERC4906.MetadataUpdate(id);
    }

    /// @dev How many ERC-4906 events (single or batch) the token emitted in the recorded logs.
    function _refreshes(Vm.Log[] memory logs) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != s) continue;
            bytes32 topic = logs[i].topics[0];
            if (
                topic == IERC4906.MetadataUpdate.selector
                    || topic == IERC4906.BatchMetadataUpdate.selector
            ) ++count;
        }
    }

    // ------------------------------------------------------------------ RND-27: the record

    /// RND-27: finalizing a work, which pins its renderer, refreshes its token.
    function test_Finalize_EmitsMetadataUpdateOnTheToken() public {
        (uint256 id,) = _open(1);
        bytes32 state = _state(id);
        _expectRefresh(id);
        vm.prank(artist);
        rules.finalize(s, id, state);
        assertTrue(facts.factsOf(s, id).finalized);
    }

    /// RND-27: a new license refreshes the token.
    function test_Relicense_EmitsMetadataUpdateOnTheToken() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        item.license = License("MIT", mitText);
        uint256 id = _mintItem(stream, item);
        facts.open(s, id, item, media);

        License memory next = License("CC-BY-4.0", mitText);
        bytes32 state = _state(id);
        bytes32 structHash = keccak256(
            abi.encode(
                rules.RELICENSE_TYPEHASH(),
                s,
                id,
                WorksHashing.licenseKey(next.spdxId),
                next.textFileId,
                state,
                deadline
            )
        );
        bytes[] memory consents = _both(structHash);
        _expectRefresh(id);
        rules.relicense(s, id, next, item, state, deadline, consents);
        assertEq(facts.factsOf(s, id).licenseId, "CC-BY-4.0");
    }

    /// RND-27: a repinned renderer refreshes the token.
    function test_RepinRenderer_EmitsMetadataUpdateOnTheToken() public {
        (uint256 id,) = _open(1);
        _artistFinalize(id);
        CodeRenderer next = new CodeRenderer(1);
        bytes32 state = _state(id);
        _expectRefresh(id);
        rules.repinRenderer(s, id, address(next), state);
        assertEq(stream.rendererOf(id), address(next));
    }

    /// RND-27: moving a file to another chunk store refreshes the token.
    function test_SetFileStore_EmitsMetadataUpdateOnTheToken() public {
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(1, FileRole.PRIMARY, true);
        media[1] = _mediaFile(2, FileRole.PREVIEW, false);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(stream, item);
        facts.open(s, id, item, media);
        RulesChunkStore chunks = new RulesChunkStore();
        rules.addStore(address(chunks), address(chunks).codehash);
        chunks.put(_mediaBytes(2));

        _expectRefresh(id);
        vm.prank(artist);
        rules.setFileStore(s, id, media[1].fileId, 1);
        assertEq(rules.fileStore(s, id, media[1].fileId), 1);
    }

    /// RND-27: the on-chain-complete mark, which lets the renderer inline the work, refreshes
    /// the token once; marking it again changes nothing and emits nothing.
    function test_MarkOnChainComplete_EmitsMetadataUpdateOnceOnTheToken() public {
        (uint256 id,) = _open(1);
        vm.expectEmit(address(facts));
        emit IWorkFacts.OnChainComplete(s, id);
        _expectRefresh(id);
        facts.markOnChainComplete(s, id);
        assertTrue(facts.factsOf(s, id).onChainComplete);

        vm.recordLogs();
        facts.markOnChainComplete(s, id);
        assertEq(_refreshes(vm.getRecordedLogs()), 0, "already marked");
    }

    /// RND-27: a preferred locator and a locator marked dead each refresh the token.
    function test_Delivery_APreferenceAndADeadLocatorEmitMetadataUpdateOnTheToken() public {
        (uint256 id,, MediaFile[] memory media) = _work(stream, 1);
        bytes32 file = media[0].fileId;
        delivery.addLocator(s, id, file, Locator(LocatorKind.ARWEAVE, CA.arweave("1")));
        delivery.addLocator(s, id, file, Locator(LocatorKind.ARWEAVE, CA.arweave("2")));

        _expectRefresh(id);
        delivery.setFilePreference(s, id, file, 0);
        assertEq(delivery.filePreference(s, id, file), 0);

        _expectRefresh(id);
        delivery.markLocatorDead(s, id, file, 1);
        assertEq(delivery.deadLocators(s, id, file), 2, "bit 1: the second locator");
    }

    /// RND-27, the other side: a call that leaves the record as it is (the same record file,
    /// the same license, the renderer already pinned) emits no ERC-4906 event.
    function test_NoOps_EmitNoMetadataUpdate() public {
        (uint256 id, PackageItem memory item) = _open(1);
        bytes32 version = _state(id);
        vm.recordLogs();
        vm.prank(artist);
        rules.setRecord(s, id, item.recordFileId, bytes32(0));
        rules.relicense(s, id, _cc0(), item, 0, 0, new bytes[](0));
        assertEq(_refreshes(vm.getRecordedLogs()), 0, "the same record and license");
        assertEq(_state(id), version, "nothing changed");

        _artistFinalize(id);
        version = _state(id);
        vm.recordLogs();
        rules.repinRenderer(s, id, address(renderer), 0);
        assertEq(_refreshes(vm.getRecordedLogs()), 0, "the renderer already pinned");
        assertEq(_state(id), version, "nothing changed");
    }

    // ------------------------------------------------------------------ GV-18: the rate

    /// GV-18: the network's change of a work's royalty rate is logged by the token with the
    /// work and its new rate, and by the rules module with the work's new version.
    function test_SetRoyaltyRate_EmitsRoyaltySetOnTheTokenAndBumpsTheVersion() public {
        (uint256 id, PackageItem memory item) = _open(1);
        uint24 rate = 10_000;
        bytes32 state = _state(id);
        bytes[] memory consents = _both(
            keccak256(abi.encode(rules.ROYALTY_RATE_TYPEHASH(), s, id, rate, state, deadline))
        );
        address receiver = stream.workOf(id).royaltyReceiver;
        vm.expectEmit(address(rules));
        emit WorkRules.VersionBumped(s, id, 1);
        vm.expectEmit(s);
        emit IStream.RoyaltySet(id, receiver, rate);
        rules.setRoyaltyRate(s, id, rate, item, state, deadline, consents);
        assertEq(stream.workOf(id).royaltyRate, rate);
    }

    // ------------------------------------------------------------------ RND-2: the pin

    /// RND-2: once the code at a finalized work's pinned renderer differs from the pinned hash,
    /// `tokenURI` and the edition's `uri` both revert with `RendererCodeChanged`. Installing a
    /// working RENDERER module does not bring them back: there is no fallback. Restoring the
    /// pinned code does.
    function test_Uri_AndTokenURIRevertWhenThePinnedRendererCodeChanged() public {
        (uint256 id,) = _open(1);
        sale.createEdition(address(editions), id, 10, address(0xED), 6529);
        _artistFinalize(id);
        address pinned = address(renderer);
        assertEq(facts.rendererOf(s, id), pinned);
        string memory drawn = stream.tokenURI(id);
        assertEq(editions.uri(id), drawn);

        bytes memory original = pinned.code;
        vm.etch(pinned, address(new CodeRenderer(7)).code);
        bytes memory changed =
            abi.encodeWithSelector(IWorkFacts.RendererCodeChanged.selector, pinned);
        vm.expectRevert(changed);
        stream.tokenURI(id);
        vm.expectRevert(changed);
        editions.uri(id);

        // A working RENDERER module is not used in its place.
        CodeRenderer module = new CodeRenderer(1);
        _install(s, Slots.RENDERER, address(module));
        assertEq(stream.moduleOf(Slots.RENDERER), address(module));
        vm.expectRevert(changed);
        stream.tokenURI(id);
        vm.expectRevert(changed);
        editions.uri(id);

        vm.etch(pinned, original);
        assertEq(stream.tokenURI(id), drawn);
        assertEq(editions.uri(id), drawn);
    }
}
