// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { ItemKind, License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { Stream } from "src/stream/Stream.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { MockEditions, MockSaleAdapter } from "../mocks/stream/StreamMocks.sol";
import { RecordsFixture } from "./RecordsFixture.sol";

/// @notice The PR #22 review's proofs of concept, inverted into regressions: each one now
///         shows the fixed behaviour (or, for the media commitments, the documented curation
///         obligation).
contract ReviewRegressionsTest is RecordsFixture {
    /// @dev F1: SPDX's canonical casing mints, opens, amends and finalizes; CC0 stays
    ///      irrevocable whatever its case.
    function test_uppercaseSpdxMintsOpensAndAmends() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.license = _license("CC0-1.0");
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

    /// @dev L8: a non-default license's text must be registered, at open and at relicense.
    function test_licenseTextMustBeRegistered() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        bytes32 unknown = keccak256("no such text");
        item.license = License("MIT", unknown);
        uint256 tokenId = _mint(item);
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, unknown));
        records.openRecord(tokenId, item, media);
    }
}
