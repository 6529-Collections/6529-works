// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ContentStore } from "src/content/ContentStore.sol";
import { Renderer } from "src/content/Renderer.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { EditionTerms, ItemKind, License } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { StreamViews } from "src/stream/StreamViews.sol";
import { WorkDelivery } from "src/stream/WorkDelivery.sol";
import { ReplayBase } from "./ReplayBase.sol";

/// @notice Log replay of 6529 Stream and `WorkRecords` (WS-44 "logs only", WS-23, AUC-43,
///         AUC-44, INV-STR-1, INV-STR-6, INV-STR-8, INV-STR-12): a history that emits every
///         event of both rebuilds, from their logs alone, every work's owner, core record,
///         terms, sale outcome, burn and content release, and every record's file, license,
///         version, finalization, pin, renounced powers and on-chain cursors.
contract LogReplayStreamTest is ReplayBase {
    address internal artist;
    address internal rightful;
    address internal buyer = makeAddr("replayBuyer");
    address internal operator = makeAddr("replayOperator");
    address internal holder = makeAddr("replayHolder");
    address internal bidder = makeAddr("replayBidder");
    bytes32 internal rootA;
    bytes32 internal rootB;
    bytes internal masterMedia = "replay master media, registered before upload";
    bytes internal copiedMedia = "replay media the dispute is about";
    bytes32 internal byText;

    function setUp() public override {
        super.setUp();
        artist = _actor("replayArtist");
        rightful = _actor("replayRightful");
        byText = _storeText("Creative Commons Attribution 4.0 (replay fixture)", "text/plain");
        Work[] memory works = new Work[](4);
        works[0] = _mediaWork(artist, _bytes(store.CHUNK_SIZE() + 50, 9), true, "Replay 0");
        works[0].item.license = License("CC-BY-4.0", byText);
        works[1] = _mediaWork(artist, masterMedia, false, "Replay master");
        works[1].item.kind = uint8(ItemKind.EDITION_MASTER);
        works[1].item.edition = EditionTerms(10, address(0), SaleKind.UNIFORM_AUCTION, "");
        works[2] = _mediaWork(artist, copiedMedia, false, "Replay copy");
        works[3] = _mediaWork(artist, "replay media rescued", false, "Replay rescued");
        rootA = _publish(works);
        _keep(rootA, works);
        Work[] memory original = new Work[](1);
        original[0] = _mediaWork(rightful, copiedMedia, false, "Replay original");
        rootB = _publish(original);
        _keep(rootB, original);
        _sync();
    }

    function _mediaWork(address lead, bytes memory media, bool upload, string memory name)
        internal
        returns (Work memory w)
    {
        bytes32 sha = sha256(media);
        IContentStore.Encoding id = IContentStore.Encoding.Identity;
        bytes32 fileId = upload
            ? _upload(media, id, "image/png", sha)
            : _registerOnly(media, id, "image/png", sha);
        w.media = new MediaFile[](1);
        w.media[0] = MediaFile(fileId, sha, uint8(FileRole.PRIMARY));
        w.item = _item(lead, collectionId, sha, w.media, _record(name));
    }

    function test_EveryStreamAndRecordsEventReplaysToTheSameState() public {
        (uint256 t0, uint256 t1) = _sales();
        _disputeAndRelease();
        _marketplace(t0);
        _recordLifecycle(t0);
        _storesNoticeAndRepin(t1);
        _rescue();
        _assertEveryEventReplayed("Stream", streamIdx, new string[](0));
        _assertEveryEventReplayed("WorkRecords", recordsIdx, _list("EIP712DomainChanged()"));
    }

    /// @dev Two works sold; the master's edition is created (`EditionLinked`).
    function _sales() internal returns (uint256 t0, uint256 t1) {
        Work[] memory works = _package(rootA);
        t0 = _sell(rootA, works, 0, buyer, 1 ether);
        t1 = _sell(rootA, works, 1, buyer, 1 ether);
        editions.createEdition(t1, works[1].item);
        _sync();
    }

    /// @dev An upheld dispute burns the copy before settlement (DSP-20); the network releases its
    ///      content to the rightful artist, whose item then consumes it and ends unbid (AUC-44).
    function _disputeAndRelease() internal {
        Work[] memory works = _package(rootA);
        (uint256 saleId, uint256 copy) = _start(rootA, works, 2);
        _ethBid(saleId, bidder, 1 ether);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("replay dispute"));
        bytes32 outcome = _platformStatement(
            address(stream), copy, StatementKinds.DISPUTE_OUTCOME, "ar://replay-upheld"
        );
        _govern(hotAdmin, address(auction), abi.encodeCall(auction.cancel, (saleId, outcome)));
        _sync();
        uint256 rightfulId = artists.artistIdOf(rightful);
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.releaseContent, (copy, sha256(copiedMedia), rightfulId))
        );
        _sync();
        (uint256 originalSale,) = _start(rootB, _package(rootB), 0);
        _settleAtEnd(originalSale);
        _sync();
        assertEq(stream.releasedTo(sha256(copiedMedia)), rightfulId, "the release is kept");
    }

    function _marketplace(uint256 t0) internal {
        vm.startPrank(buyer);
        stream.approve(bidder, t0);
        stream.setApprovalForAll(operator, true);
        vm.stopPrank();
        _sync();
        vm.prank(operator);
        stream.transferFrom(buyer, holder, t0);
        _govern(hotAdmin, address(stream), abi.encodeCall(stream.setContractURI, ("ar://replay")));
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.setOwner, (marketOwner, makeAddr("nextMarketOwner")))
        );
        PrimaryTerms memory terms = stream.primaryTerms(t0, "");
        uint32 share = terms.feeShare / 2;
        _deployLoweredVault(terms.seller, terms.feeRecipient, share);
        _govern(hotAdmin, address(stream), abi.encodeCall(stream.lowerFeeShare, (t0, share)));
        vm.prank(platform);
        stream.createCollection("Replay", keccak256("replay collection"));
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(
                stream.setDependency, ("EXTENSION", stream.extension(), address(new StreamViews()))
            )
        );
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(
                stream.setDependency, ("ENTROPY_MODULE", address(entropy), address(entropy))
            )
        );
        _sync();
    }

    /// @dev Open, amend, sync on-chain in two calls, relicense, re-rate, finalize, renounce.
    function _recordLifecycle(uint256 t0) internal {
        Work memory w = _package(rootA)[0];
        records.openRecord(t0, w.item, w.media);
        _sync();
        bytes32 next = _record("Replay 0, second record");
        bytes32 state = records.workStateHash(t0);
        vm.prank(artist);
        records.setRecord(t0, next, state);
        _sync();
        records.syncOnChain(t0, 0, 1);
        _sync();
        records.syncOnChain(t0, 0, 10);
        _sync();
        assertTrue(records.record(t0).onChainComplete);
        _govern(
            hotAdmin, address(records), _relicenseCall(t0, w, License("CC0-1.0", cc0TextFileId))
        );
        _sync();
        _govern(hotAdmin, address(records), _rerateCall(t0, w, 2_500));
        _sync();
        state = records.workStateHash(t0);
        vm.prank(artist);
        records.finalize(t0, state);
        _sync();
        _renounce(t0, WorkPowers.RENDERER_REPIN);
        _sync();
    }

    /// @dev The master: media completed through an added store, then upgraded to the content
    ///      store (WS-43); finalized by anyone after the notice (C9); a new default renderer and
    ///      the errata repin (C8); a new delivery contract (WS-39).
    function _storesNoticeAndRepin(uint256 t1) internal {
        Work memory w = _package(rootA)[1];
        records.openRecord(t1, w.item, w.media);
        ContentStore other = new ContentStore();
        other.writeChunk(masterMedia);
        _govern(
            hotAdmin,
            address(records),
            abi.encodeCall(records.addStore, (address(other), address(other).codehash))
        );
        vm.prank(artist);
        records.syncOnChain(t1, 1, 10);
        _sync();
        _govern(hotAdmin, address(records), abi.encodeCall(records.retireStore, (1)));
        store.writeChunk(masterMedia);
        records.syncOnChain(t1, 0, 10);
        _sync();
        vm.prank(buyer);
        records.finalize(t1, bytes32(0));
        _sync();
        vm.warp(block.timestamp + 14 days);
        vm.prank(buyer);
        records.finalize(t1, bytes32(0));
        _sync();
        Renderer nextRenderer = new Renderer(
            IContentStore(address(store)), IStatementLog(address(statements)), 131_072
        );
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(
                stream.setDefaultRenderer,
                (address(renderer), address(nextRenderer), address(nextRenderer).codehash)
            )
        );
        _sync();
        _govern(
            hotAdmin,
            address(records),
            abi.encodeCall(
                records.repinRenderer,
                (
                    t1,
                    address(nextRenderer),
                    address(nextRenderer).codehash,
                    records.workStateHash(t1)
                )
            )
        );
        _sync();
        WorkDelivery nextDelivery = new WorkDelivery(
            address(manager), address(records), address(stream), address(delivery)
        );
        _govern(
            hotAdmin,
            address(records),
            abi.encodeCall(records.setDelivery, (address(delivery), address(nextDelivery)))
        );
        _sync();
    }

    /// @dev A work stranded in a removed adapter's custody for 14 days goes to the museum
    ///      (owner decisions 20 and 28), and the adapter is admitted again with its old ID.
    function _rescue() internal {
        (, uint256 stranded) = _start(rootA, _package(rootA), 3);
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.setAdmittedMinter, (address(auction), false))
        );
        _sync();
        vm.warp(block.timestamp + 14 days);
        _govern(hotAdmin, address(stream), abi.encodeCall(stream.rescueToMuseum, (stranded)));
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.setAdmittedMinter, (address(auction), true))
        );
        _sync();
    }

    // ------------------------------------------------------------------ signed calls

    function _consent(bytes32 structHash) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](1);
        sigs[0] =
            abi.encodePacked(artist, _sign(artist, _typedDigest(address(records), structHash)));
    }

    function _relicenseCall(uint256 tokenId, Work memory w, License memory next)
        internal
        view
        returns (bytes memory)
    {
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes32 structHash = keccak256(
            abi.encode(
                Typehashes.RELICENSE,
                tokenId,
                WorksHashing.licenseKey(next.spdxId),
                next.textFileId,
                state,
                deadline
            )
        );
        return abi.encodeCall(
            records.relicense, (tokenId, next, w.item, state, deadline, _consent(structHash))
        );
    }

    function _rerateCall(uint256 tokenId, Work memory w, uint32 rate)
        internal
        view
        returns (bytes memory)
    {
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes32 structHash =
            keccak256(abi.encode(Typehashes.ROYALTY_RATE_CHANGE, tokenId, rate, state, deadline));
        return abi.encodeCall(
            records.setRoyaltyRate, (tokenId, rate, w.item, state, deadline, _consent(structHash))
        );
    }

    function _renounce(uint256 tokenId, uint16 powers) internal {
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 structHash =
            keccak256(abi.encode(Typehashes.RENOUNCE_POWERS, tokenId, powers, state, deadline));
        bytes memory sig = _sign(artist, _typedDigest(address(records), structHash));
        records.renounce(tokenId, powers, state, deadline, abi.encodePacked(artist, sig));
    }

    // ------------------------------------------------------------------ negative controls

    /// @dev Slot 12 holds the marketplace owner: a value no `OwnershipTransferred` logged.
    function test_StreamIndexerDetectsStateThatLogsDoNotExplain() public {
        vm.store(address(stream), bytes32(uint256(12)), bytes32(uint256(uint160(holder))));
        vm.expectRevert();
        streamIdx.assertMatches();
    }

    /// @dev Slot 3 holds the delivery contract: a value no `DeliverySet` logged.
    function test_RecordsIndexerDetectsStateThatLogsDoNotExplain() public {
        vm.store(address(records), bytes32(uint256(3)), bytes32(uint256(uint160(holder))));
        vm.expectRevert();
        recordsIdx.assertMatches();
    }

    // ------------------------------------------------------------------ genesis and finalize

    /// @notice Stream's constructor logs a `DependencySet` for each of its four mutable genesis
    ///         dependencies (mint policy, economics resolver, entropy module, view extension), so
    ///         a logs-only reader knows `economics()` and `entropyModuleOf(tokenId)` from
    ///         deployment on (WS-44, ADR 0007).
    /// @dev Was an open finding of the replay lane; the review fixes added the events.
    function test_StreamGenesisDependenciesReplayFromStreamsLogs() public view {
        assertEq(streamIdx.dependency("ECONOMICS"), stream.economics(), "economics from logs");
        assertEq(
            streamIdx.dependency("ENTROPY_MODULE"), stream.entropyModule(), "entropy from logs"
        );
        assertEq(
            streamIdx.dependency("PACKAGE_REGISTRY"), stream.packageRegistry(), "policy from logs"
        );
        assertEq(streamIdx.dependency("EXTENSION"), stream.extension(), "extension from logs");
        assertTrue(streamIdx.dependency("ECONOMICS") != address(0), "economics logged");
    }

    /// @notice `WorkFinalized` carries the renderer code hash `finalize` pins, so `WorkRecords`'
    ///         own logs rebuild it.
    /// @dev Was an open finding of the replay lane; the review fixes added `codeHash`.
    function test_FinalizedRendererCodeHashReplaysFromWorkRecordsLogs() public {
        (uint256 t0,) = _sales();
        Work memory w = _package(rootA)[0];
        records.openRecord(t0, w.item, w.media);
        bytes32 state = records.workStateHash(t0);
        vm.prank(artist);
        records.finalize(t0, state);
        _sync();
        assertEq(recordsIdx.pinnedCodeHash(address(renderer)), address(renderer).codehash);
        recordsIdx.assertMatches();
    }
}
