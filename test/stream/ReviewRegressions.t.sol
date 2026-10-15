// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { ItemKind, License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { Stream } from "src/stream/Stream.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { MockEditions, MockSaleAdapter } from "../mocks/stream/StreamMocks.sol";
import { console2 } from "forge-std/Test.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { RecordsFixture } from "./RecordsFixture.sol";

/// @notice The PR #22 reviews' proofs of concept (rounds 1 and 2), inverted into regressions:
///         each one now shows the fixed behaviour (or, for the media commitments, the
///         documented curation obligation).
contract ReviewRegressionsTest is RecordsFixture {
    /// @dev F1: SPDX's canonical casing mints, opens, amends and finalizes; CC0 stays
    ///      irrevocable whatever its case.
    function test_uppercaseSpdxMintsOpensAndAmends() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        // The deployment's CC0 text, under the identifier's canonical casing.
        item.license = License("CC0-1.0", records.cc0TextFileId());
        assertEq(WorksHashing.licenseKey("CC0-1.0"), WorksHashing.CC0_LICENSE_KEY);
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        assertEq(records.licenseOf(tokenId).spdxId, "CC0-1.0");
        assertEq(records.record(tokenId).licenseKey, WorksHashing.CC0_LICENSE_KEY);

        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes[] memory sigs = _both(_royaltyHash(tokenId, 10_000, state, deadline));
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, 10_000, item, state, deadline, sigs);
        assertEq(stream.work(tokenId).royaltyRate, 10_000);

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.LicenseIrrevocable.selector, tokenId));
        records.relicense(tokenId, _license("mit"), item, bytes32(0), 0, new bytes[](0));

        state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertTrue(records.record(tokenId).finalized);
    }

    /// @dev F1 (M2): a license ID `WorkRecords` would refuse never mints, so no license can
    ///      leave a work unopenable.
    function test_unopenableLicenseIdNeverMints() public {
        string[4] memory badIds = ["", "CC BY 4.0", "cc_by", string(new bytes(65))];
        for (uint256 i; i < badIds.length; ++i) {
            MediaFile[] memory media = _single(i, true);
            PackageItem memory item = _recordsItem(i, media);
            item.license = License(badIds[i], bytes32(0));
            bytes memory data = _request(item);
            vm.expectRevert(IStream.InvalidMintRequest.selector);
            auction.start(stream, data);
        }
    }

    /// @dev F1b: media commitments are not visible at mint. A mis-committed item mints and can
    ///      never open, which is why the curation signer's tooling MUST simulate `openRecord`
    ///      before attesting (a trust obligation, documented in `openRecord` and the README).
    function test_mediaCommitmentIsACurationObligation() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.contentHash = keccak256("not the primary");
        uint256 tokenId = _mint(item);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidRecordData.selector, tokenId));
        records.openRecord(tokenId, item, media);
    }

    /// @dev F2 (M3): a removed adapter still cancels and burns the disputed token it minted.
    function test_removedAdapterStillBurnsItsDisputedToken() public {
        uint256 tokenId = _mint(1);
        vm.prank(governor);
        stream.setAdmittedMinter(address(auction), false);
        auction.burn(stream, tokenId, 1);
        assertEq(stream.totalSupply(), 0);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, tokenId));
        stream.work(tokenId);
    }

    /// @dev F2b (M3): an admitted adapter that did not mint a token cannot burn it, even while
    ///      it holds it.
    function test_nonMintingAdmittedAdapterCannotBurn() public {
        uint256 tokenId = _mint(1);
        MockSaleAdapter other = new MockSaleAdapter(SaleKind.ENGLISH_AUCTION);
        vm.prank(governor);
        stream.setAdmittedMinter(address(other), true);
        address collector = makeAddr("collector");
        auction.deliver(address(stream), tokenId, collector);
        vm.prank(collector);
        stream.transferFrom(collector, address(other), tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(other))
        );
        other.burn(stream, tokenId, 1);
        assertEq(stream.totalSupply(), 1);
    }

    /// @dev F3 (L1): a one-shot bind refuses a satellite serving another Stream and accepts the
    ///      fresh Stream's own.
    function test_bindRefusesSatelliteOfAnotherStream() public {
        Stream fresh = new Stream(
            address(manager),
            address(registry),
            address(artists),
            address(econ),
            address(entropy),
            address(renderer),
            address(renderer).codehash,
            marketOwner
        );
        assertEq(records.stream(), address(stream));
        vm.expectRevert(abi.encodeWithSelector(IStream.InvalidBinding.selector, address(records)));
        fresh.bindWorkRecords(address(records));
        vm.expectRevert(
            abi.encodeWithSelector(IStream.InvalidBinding.selector, address(editionsMock))
        );
        fresh.bindEditions(address(editionsMock));

        WorkRecords own =
            new WorkRecords(address(manager), address(fresh), address(store), _license("cc0-1.0"));
        fresh.bindWorkRecords(address(own));
        assertEq(fresh.workRecords(), address(own));
        MockEditions ownEditions = new MockEditions(address(fresh));
        fresh.bindEditions(address(ownEditions));
        assertEq(fresh.editions(), address(ownEditions));
    }

    /// @dev F4: Stream links an edition only to a settled master (D14, defence in depth).
    function test_linkEditionNeedsSettledMaster() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.kind = ItemKind.EDITION_MASTER;
        uint256 tokenId = _mint(item);
        assertFalse(stream.primarySaleSettled(tokenId));
        vm.expectRevert(abi.encodeWithSelector(IStream.EditionLinkInvalid.selector, tokenId));
        editionsMock.link(stream, tokenId, tokenId);
        auction.settle(stream, tokenId);
        editionsMock.link(stream, tokenId, tokenId);
        (address e,) = stream.editionOf(tokenId);
        assertEq(e, address(editionsMock));
    }

    /// @dev F5 (L2): a zero fee may come with a zero fee recipient, and the start reports it;
    ///      a nonzero fee needs a recipient.
    function test_zeroFeeAllowsZeroRecipient() public {
        econ.setTerms(WorkTerms(seller, address(0), 0, address(0), 6_529));
        (uint256 tokenId, PrimaryTerms memory terms) = auction.start(stream, _request(_item(1)));
        assertEq(terms.feeRecipient, address(0));
        assertEq(terms.feeShare, 0);
        assertEq(stream.primaryTerms(tokenId, "").feeRecipient, address(0));
        (address receiver,) = stream.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, seller);

        econ.setTerms(WorkTerms(seller, address(0), 1, address(0), 6_529));
        bytes memory data = _request(_item(2));
        vm.expectRevert(IStream.InvalidMintRequest.selector);
        auction.start(stream, data);
    }

    /// @dev M4: a rate round trip A -> B -> A does not let the first consents replay; the
    ///      version moved, so the state hash they bind is gone.
    function test_rateRoundTripReplayBlocked() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 s0 = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes[] memory toB = _both(_royaltyHash(tokenId, 10_000, s0, deadline));
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, 10_000, item, s0, deadline, toB);
        bytes32 s1 = records.workStateHash(tokenId);
        bytes[] memory toA = _both(_royaltyHash(tokenId, 6_529, s1, deadline));
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, 6_529, item, s1, deadline, toA);
        bytes32 s2 = records.workStateHash(tokenId);
        assertTrue(s2 != s0);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.StateHashMismatch.selector, s0, s2));
        records.setRoyaltyRate(tokenId, 10_000, item, s0, deadline, toB);
        assertEq(stream.work(tokenId).royaltyRate, 6_529);
    }

    /// @dev L5: the master's current rate is readable through `coreOf`, so an edition created
    ///      after a rate change can inherit it.
    function test_coreOfReportsCurrentRate() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes[] memory sigs = _both(_royaltyHash(tokenId, 8_000, state, deadline));
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, 8_000, item, state, deadline, sigs);
        (,,,,, uint32 rate) = stream.coreOf(tokenId);
        assertEq(rate, 8_000);
    }

    // ------------------------------------------------------------------------------ round 2

    function _manifest(bytes32[] memory hashes, uint256 length, IContentStore.Encoding enc)
        internal
        returns (bytes32)
    {
        return store.registerManifest(hashes, length, enc, "application/json", keccak256("x"));
    }

    /// @dev The work's approved record is `bad`: finalize refuses it, and the artist replaces
    ///      it with a valid record and finalizes.
    function _fixRecord(uint256 tokenId, bytes32 bad) internal {
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownRecordFile.selector, bad));
        records.finalize(tokenId, state);
        bytes32 good = _record(99);
        vm.prank(artist);
        records.setRecord(tokenId, good, state);
        state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertEq(records.record(tokenId).recordFileId, good);
    }

    /// @dev N1a: an approved two-chunk record (longer than one content-store chunk) opens, and the
    ///      artist replaces it with `setRecord` before finalize.
    function test_twoChunkRecordOpensAndIsFixable() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256("chunk0");
        hashes[1] = keccak256("chunk1");
        item.recordFileId =
            _manifest(hashes, store.CHUNK_SIZE() + 100, IContentStore.Encoding.Identity);
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        assertTrue(records.isOpen(tokenId));
        _fixRecord(tokenId, item.recordFileId);
    }

    /// @dev N1b: an approved gzip-encoded record opens, and is fixable the same way.
    function test_gzipRecordOpensAndIsFixable() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        bytes memory data = bytes("gzip-stream");
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(data);
        item.recordFileId = _manifest(hashes, data.length, IContentStore.Encoding.Gzip);
        store.writeChunk(data);
        assertTrue(store.isComplete(item.recordFileId));
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        _fixRecord(tokenId, item.recordFileId);
    }

    /// @dev N1c: a license whose text file ID has no manifest opens. Finalize refuses it until
    ///      the parties and governance relicense to a stored text.
    function test_unregisteredLicenseTextOpensAndIsFixable() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        bytes32 unknown = keccak256("typo in the text file id");
        item.license = License("CC-BY-4.0", unknown);
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, unknown));
        records.finalize(tokenId, state);

        _relicense(tokenId, item, _license("CC-BY-4.0"));
        state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertEq(records.licenseOf(tokenId).textFileId, _license("CC-BY-4.0").textFileId);
    }

    /// @dev N1c for CC0, as the content review amended it: a CC0 license names the deployment's
    ///      CC0 text, so an approved CC0 license with a mistyped text cannot open (there is no
    ///      correction to make later), while the deployment's text in any casing opens and
    ///      finalizes; leaving CC0 stays refused.
    function test_cc0TextMustBeTheDeploymentText() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.license = License("CC0-1.0", keccak256("typo"));
        uint256 tokenId = _mint(item);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.openRecord(tokenId, item, media);

        media = _single(2, true);
        item = _recordsItem(2, media);
        item.license = License("CC0-1.0", records.cc0TextFileId());
        tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.LicenseIrrevocable.selector, tokenId));
        records.relicense(tokenId, _license("mit"), item, bytes32(0), 0, new bytes[](0));
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertEq(records.record(tokenId).licenseKey, WorksHashing.CC0_LICENSE_KEY);
    }

    function _relicense(uint256 tokenId, PackageItem memory item, License memory next) internal {
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
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
        bytes[] memory sigs = _both(structHash);
        vm.prank(governor);
        records.relicense(tokenId, next, item, state, deadline, sigs);
    }

    /// @dev N2: a finalized work's license text is on-chain. A registered but unstored text
    ///      blocks finalize until it is stored, and a finalized work's relicense needs a stored
    ///      text too.
    function test_finalizedLicenseTextIsStored() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.license = License("CC-BY-4.0", _registerTextOnly("CC-BY-4.0 legal code"));
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        records.syncOnChain(tokenId);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.finalize(tokenId, state);
        store.writeChunk("CC-BY-4.0 legal code");
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertTrue(records.record(tokenId).finalized);
        assertTrue(records.record(tokenId).onChainComplete);
        assertTrue(store.isComplete(records.licenseOf(tokenId).textFileId));

        License memory next = License("CC-BY-SA-4.0", _registerTextOnly("CC-BY-SA-4.0 code"));
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        this.relicenseAs(tokenId, item, next);
        store.writeChunk("CC-BY-SA-4.0 code");
        _relicense(tokenId, item, next);
        assertTrue(store.isComplete(records.licenseOf(tokenId).textFileId));
    }

    /// @dev An external hop so `vm.expectRevert` sees exactly the relicense call.
    function relicenseAs(uint256 tokenId, PackageItem memory item, License memory next) external {
        _relicense(tokenId, item, next);
    }

    /// @dev Nit (S3): the license-ID length bound is exact. 64 valid characters mint, 65 do not.
    function test_licenseIdLengthBoundIsExact() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.license = License(string(_repeatA(64)), _registerText("long id text"));
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        assertEq(bytes(records.licenseOf(tokenId).spdxId).length, 64);

        media = _single(2, true);
        item = _recordsItem(2, media);
        item.license = License(string(_repeatA(65)), bytes32(0));
        bytes memory data = _request(item);
        vm.expectRevert(IStream.InvalidMintRequest.selector);
        auction.start(stream, data);

        vm.prank(governor);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.relicense(
            tokenId, License(string(_repeatA(65)), bytes32(0)), item, bytes32(0), 0, new bytes[](0)
        );
    }

    function _repeatA(uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = "a";
        }
    }

    /// @dev Burns: re-admission keeps the index, so a removed and re-admitted adapter still
    ///      burns its token; a never-admitted holder (index 0) cannot.
    function test_burnReadmittedAndNeverAdmitted() public {
        uint256 tokenId = _mint(1);
        vm.startPrank(governor);
        stream.setAdmittedMinter(address(auction), false);
        stream.setAdmittedMinter(address(auction), true);
        vm.stopPrank();
        uint256 second = _mint(2);
        auction.burn(stream, tokenId, 1);

        MockSaleAdapter stranger = new MockSaleAdapter(SaleKind.ENGLISH_AUCTION);
        auction.deliver(address(stream), second, address(stranger));
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(stranger))
        );
        stranger.burn(stream, second, 1);
    }

    /// @dev The minting adapter cannot burn after settlement.
    function test_burnAfterSettlementRefused() public {
        uint256 tokenId = _mint(1);
        auction.settle(stream, tokenId);
        vm.expectRevert(abi.encodeWithSelector(IStream.SaleAlreadySettled.selector, tokenId));
        auction.burn(stream, tokenId, 1);
    }

    function _ipfs(string memory s) internal pure returns (Locator memory) {
        return CA.ipfsLocator(s);
    }

    /// @dev Locators: the quotas are independent; the duplicate set is shared, so either side
    ///      may add a URI first (it is still listed); duplicates compare exact bytes.
    function test_locatorQuotasAndSharedDuplicateSet() public {
        (uint256 tokenId,) = _work(1);
        bytes32 fileId = records.mediaOf(tokenId)[0].fileId;
        for (uint256 i; i < 8; ++i) {
            vm.prank(artist);
            records.addLocator(tokenId, fileId, _ipfs(vm.toString(i)));
        }
        vm.prank(artist);
        vm.expectRevert(IWorkRecords.InvalidLocator.selector);
        records.addLocator(tokenId, fileId, _ipfs("artist-9"));
        vm.prank(platform);
        records.addLocator(tokenId, fileId, _ipfs("p0"));
        vm.prank(platform);
        vm.expectRevert(IWorkRecords.InvalidLocator.selector);
        records.addLocator(tokenId, fileId, _ipfs("0"));
        // The same CID as a dag-pb root is another spelling, so another URI.
        vm.prank(platform);
        records.addLocator(tokenId, fileId, Locator(LocatorKind.IPFS, CA.ipfsRoot("0")));
        assertEq(records.locators(tokenId, fileId).length, 10);
    }

    /// @dev On-chain completeness needs every media file; until then ONCHAIN never resolves.
    function test_onChainNeedsEveryFile() public {
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(1, FileRole.PRIMARY, true);
        media[1] = _mediaFile(2, FileRole.PREVIEW, false);
        PackageItem memory item = _recordsItem(1, media);
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.NotOnChainComplete.selector, tokenId));
        records.syncOnChain(tokenId);
        (Locator memory loc, uint256 index) = records.preferredLocator(tokenId, media[0].fileId);
        assertEq(uint8(loc.kind), uint8(LocatorKind.NONE));
        assertEq(index, type(uint256).max);
        _upload(2);
        records.syncOnChain(tokenId);
        (loc,) = records.preferredLocator(tokenId, media[1].fileId);
        assertEq(uint8(loc.kind), uint8(LocatorKind.ONCHAIN));
    }

    /// @dev What the record checks cost, measured cold.
    function test_gas_recordChecks() public {
        (uint256 tokenId, PackageItem memory item, MediaFile[] memory media) = _minted(1, true);
        vm.cool(address(store));
        vm.cool(address(records));
        uint256 before = gasleft();
        records.openRecord(tokenId, item, media);
        console2.log("openRecord, 1 file, cold:", before - gasleft());
        bytes32 next = _record(2);
        bytes32 state = records.workStateHash(tokenId);
        vm.cool(address(store));
        vm.prank(artist);
        before = gasleft();
        records.setRecord(tokenId, next, state);
        console2.log("setRecord, cold store:", before - gasleft());
        state = records.workStateHash(tokenId);
        vm.cool(address(store));
        vm.prank(artist);
        before = gasleft();
        records.finalize(tokenId, state);
        console2.log("finalize, cold store:", before - gasleft());
    }
}
