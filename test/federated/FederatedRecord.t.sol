// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederatedToken } from "src/interfaces/IFederatedToken.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IStreamViews } from "src/interfaces/IStreamViews.sol";
import { IWorkDelivery } from "src/interfaces/IWorkDelivery.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PrimaryOutcome, PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice A federated work's record and its rendering through the shared renderer: the
///         artist's record changes until finalize, the pin, lower-only royalties, locators,
///         on-chain completeness, the dispute burn, and tokenURI built from the template's own
///         record.
contract FederatedRecordTest is FederationBase {
    address internal collector = makeAddr("collector");

    function setUp() public override {
        super.setUp();
        _joinedFed();
    }

    function _opened() internal returns (Work memory w, uint256 saleId, uint256 tokenId) {
        w = _fedWork(fedArtist);
        (saleId, tokenId) = _startFed(w);
    }

    function test_Render_TheSharedRendererReadsTheTemplatesRecord() public {
        (Work memory w, uint256 saleId, uint256 tokenId) = _opened();
        assertEq(fed.workRecords(), address(fed));
        assertTrue(fed.isOpen(tokenId));
        IStreamViews.WorkCore memory core = fed.work(tokenId);
        assertEq(core.itemHash, _itemHash(w));
        assertEq(core.artistId, uint160(fedArtist));
        assertEq(core.collectionId, 1);
        assertEq(fed.collection(1).name, "Artist Works");
        IWorkRecords.RecordInfo memory r = fed.record(tokenId);
        assertEq(r.recordFileId, w.item.recordFileId);
        assertEq(r.mediaHash, w.item.mediaHash);
        assertEq(r.licenseKey, WorksHashing.licenseKey("CC0-1.0"));
        MediaFile[] memory media = fed.mediaOf(tokenId);
        assertEq(media.length, 1);
        assertEq(media[0].sha256Hash, w.item.contentHash);
        string memory uri = fed.tokenURI(tokenId);
        assertTrue(_contains(uri, "data:application/json"), "a data URI");
    }

    function test_Record_ChangesUntilFinalizeThenThePinHolds() public {
        (Work memory w, uint256 saleId, uint256 tokenId) = _opened();
        bytes32 next = _record("Renamed");
        vm.prank(collector);
        vm.expectRevert(abi.encodeWithSelector(IFederatedToken.NotArtist.selector, collector));
        fed.setRecord(tokenId, next);
        vm.expectEmit(address(fed));
        emit IFederatedStream.RecordChanged(1, next);
        vm.prank(fedArtist);
        fed.setRecord(tokenId, next);
        assertEq(fed.record(tokenId).recordFileId, next);
        assertEq(fed.record(tokenId).version, 1);
        vm.expectEmit(address(fed));
        emit IFederatedStream.Finalized(1, address(renderer), address(renderer).codehash);
        vm.prank(fedArtist);
        fed.finalize(tokenId);
        assertTrue(fed.record(tokenId).finalized);
        assertEq(fed.rendererOf(tokenId), address(renderer));
        vm.prank(fedArtist);
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.WorkFinalized.selector, 1));
        fed.setRecord(tokenId, w.item.recordFileId);
    }

    function test_Royalty_OnlyFalls() public {
        (Work memory w, uint256 saleId, uint256 tokenId) = _opened();
        vm.prank(fedArtist);
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.InvalidRoyaltyRate.selector, RATE));
        fed.setRoyaltyRate(tokenId, RATE);
        vm.expectEmit(address(fed));
        emit IFederatedStream.RoyaltyRateChanged(1, RATE, 0);
        vm.prank(fedArtist);
        fed.setRoyaltyRate(tokenId, 0);
        (, uint256 amount) = fed.royaltyInfo(tokenId, 1 ether);
        assertEq(amount, 0, "no floor");
    }

    function test_Locator_TheArtistPointsEachFileSomewhere() public {
        (Work memory w, uint256 saleId, uint256 tokenId) = _opened();
        bytes32 fileId = w.media[0].fileId;
        vm.prank(fedArtist);
        fed.setLocator(tokenId, 0, 1, "ar://primary");
        (IWorkDelivery.Location memory l, uint256 index) = fed.preferredLocator(tokenId, fileId);
        assertEq(index, 0);
        assertEq(l.kind, 1);
        assertEq(l.uri, "ar://primary");
        vm.prank(fedArtist);
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.UnknownWork.selector, tokenId));
        fed.setLocator(tokenId, 1, 1, "ar://none");
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.UnknownWork.selector, tokenId));
        fed.preferredLocator(tokenId, keccak256("not a file"));
    }

    function test_SyncOnChain_OnlyOnceEveryFileIsComplete() public {
        (Work memory w, uint256 saleId, uint256 tokenId) = _opened();
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.UnknownWork.selector, tokenId));
        fed.syncOnChain(tokenId);
        Work memory onChain = _storedWork(fedArtist);
        (, uint256 stored) = _startFed(fed, fedArtist, onChain, RATE);
        fed.syncOnChain(stored);
        assertTrue(fed.record(stored).onChainComplete);
    }

    /// @dev Finalizing and marking a work on-chain complete set separate flags: neither clears
    ///      the other, in either order.
    function test_SyncOnChainAndFinalize_KeepEachOthersFlag() public {
        (, uint256 first) = _startFed(fed, fedArtist, _storedWork(fedArtist), RATE);
        fed.syncOnChain(first);
        vm.prank(fedArtist);
        fed.finalize(first);
        assertTrue(fed.record(first).finalized);
        assertTrue(fed.record(first).onChainComplete, "finalize keeps on-chain complete");
        (, uint256 second) = _startFed(fed, fedArtist, _storedWork(fedArtist), RATE);
        vm.prank(fedArtist);
        fed.finalize(second);
        fed.syncOnChain(second);
        assertTrue(fed.record(second).onChainComplete);
        assertTrue(fed.record(second).finalized, "the sync keeps finalized");
    }

    function test_Burn_OnlyTheMintingAdapterBeforeSettlement() public {
        (Work memory w, uint256 saleId, uint256 tokenId) = _opened();
        vm.expectRevert(
            abi.encodeWithSelector(IFederatedStream.NotMintingAdapter.selector, address(this))
        );
        fed.burn(tokenId, 1);
        vm.startPrank(address(auction));
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        fed.burn(tokenId, 0);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        fed.burn(tokenId, 2);
        fed.burn(tokenId, 1);
        vm.stopPrank();
        assertEq(fed.liveTokenOf(1), 0);
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.UnknownWork.selector, tokenId));
        fed.work(tokenId);
    }

    function test_SettlePrimary_OnlyTheMintingAdapterOnce() public {
        (Work memory w, uint256 saleId, uint256 tokenId) = _opened();
        vm.expectRevert(
            abi.encodeWithSelector(IFederatedStream.NotMintingAdapter.selector, address(this))
        );
        fed.settlePrimary(tokenId, PrimaryOutcome.SOLD, collector, address(0), 1);
        _settleAtEnd(saleId);
        vm.prank(address(auction));
        vm.expectRevert(
            abi.encodeWithSelector(IFederatedStream.SaleAlreadySettled.selector, tokenId)
        );
        fed.settlePrimary(tokenId, PrimaryOutcome.SOLD, collector, address(0), 1);
    }

    function test_SettlePrimary_RefusesAMalformedOutcome() public {
        (,, uint256 tokenId) = _opened();
        bytes4 invalid = IFederatedStream.InvalidSaleOutcome.selector;
        vm.startPrank(address(auction));
        vm.expectRevert(invalid);
        fed.settlePrimary(tokenId, PrimaryOutcome.SOLD, address(0), address(0), 1);
        vm.expectRevert(invalid);
        fed.settlePrimary(tokenId, PrimaryOutcome.NONE, address(0), address(0), 0);
        vm.expectRevert(invalid);
        fed.settlePrimary(tokenId, PrimaryOutcome.UNBID, collector, address(0), 0);
        vm.expectRevert(invalid);
        fed.settlePrimary(tokenId, PrimaryOutcome.FROZEN_OUT, address(0), address(0), 1);
        // NONE is never a sale, even with a buyer; RESCUED is no outcome of this template.
        vm.expectRevert(invalid);
        fed.settlePrimary(tokenId, PrimaryOutcome.NONE, collector, address(0), 1);
        vm.expectRevert(invalid);
        fed.settlePrimary(tokenId, PrimaryOutcome.RESCUED, address(0), address(0), 0);
        vm.stopPrank();
        (,, uint8 state) = fed.tokenInfo(tokenId);
        assertEq(state, 1, "still in sale");
    }

    function test_SettlePrimary_FrozenOutTakesTheTokenHome() public {
        (,, uint256 tokenId) = _opened();
        vm.expectEmit(address(fed));
        emit IFederatedStream.PrimarySaleSettled(
            tokenId, PrimaryOutcome.FROZEN_OUT, address(0), address(0), 0
        );
        vm.prank(address(auction));
        fed.settlePrimary(tokenId, PrimaryOutcome.FROZEN_OUT, address(0), address(0), 0);
        assertEq(fed.ownerOf(tokenId), address(fed));
    }

    function test_SettlePrimary_UnsoldRefusedWhenTheAdapterNoLongerHoldsTheToken() public {
        (,, uint256 tokenId) = _opened();
        vm.startPrank(address(auction));
        fed.transferFrom(address(auction), collector, tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC721Errors.ERC721IncorrectOwner.selector, address(auction), tokenId, collector
            )
        );
        fed.settlePrimary(tokenId, PrimaryOutcome.UNBID, address(0), address(0), 0);
        vm.stopPrank();
        assertEq(fed.ownerOf(tokenId), collector);
    }

    function test_Burn_RefusesAWrongAmountASettledSaleAndAMovedToken() public {
        (, uint256 saleId, uint256 tokenId) = _opened();
        vm.prank(address(auction));
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        fed.burn(tokenId, 2);
        // The adapter moved the token out of its custody: it can no longer burn it.
        vm.startPrank(address(auction));
        fed.transferFrom(address(auction), collector, tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC721Errors.ERC721IncorrectOwner.selector, address(auction), tokenId, collector
            )
        );
        fed.burn(tokenId, 1);
        vm.stopPrank();
        vm.prank(collector);
        fed.transferFrom(collector, address(auction), tokenId);
        _settleAtEnd(saleId);
        vm.prank(address(auction));
        vm.expectRevert(
            abi.encodeWithSelector(IFederatedStream.SaleAlreadySettled.selector, tokenId)
        );
        fed.burn(tokenId, 1);
    }

    function test_primaryTerms_UnknownTokenAndAMintedOne() public {
        (Work memory w,, uint256 tokenId) = _opened();
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.UnknownWork.selector, 99));
        fed.primaryTerms(99, "");
        PrimaryTerms memory p = fed.primaryTerms(tokenId, "");
        assertEq(p.seller, splitFactory.walletFor(w.item.payees, 0));
        assertEq(p.feeShare, FED_SHARE);
        assertEq(p.creator, address(fed));
    }

    function test_collection_OnlyTheOne() public {
        _opened();
        IStreamViews.Collection memory c = fed.collection(1);
        assertEq(c.name, fed.name());
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.UnknownWork.selector, 2));
        fed.collection(2);
    }

    /// @dev A work whose media are uploaded in full, so `syncOnChain` can mark it complete.
    function _storedWork(address artist) internal returns (Work memory sw) {
        sw = _work(artist, 0);
        bytes memory media = abi.encodePacked("stored federated media ", vm.toString(gasleft()));
        bytes32 sha = sha256(media);
        bytes32 fileId = _upload(media, IContentStore.Encoding.Identity, "image/png", sha);
        sw.media[0] = MediaFile(fileId, sha, 0);
        sw.item = _item(artist, 0, sha, sw.media, sw.item.recordFileId);
    }
}
