// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FederatedStream } from "src/federated/FederatedStream.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederatedToken } from "src/interfaces/IFederatedToken.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryOutcome, PrimarySettlement } from "src/interfaces/types/SaleTypes.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice The stream template's own effects, each pinned: who may change a work's locators and
///         the default renderer, what every record change logs and counts, what an unsold
///         settlement returns, the license read, and the pinned-code checks on renderers and
///         the content store.
contract FederatedStreamEffectsTest is FederationBase {
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        _joinedFed();
    }

    function _opened() internal returns (Work memory w, uint256 saleId, uint256 tokenId) {
        w = _fedWork(fedArtist);
        (saleId, tokenId) = _startFed(w);
    }

    function test_OnlyTheArtist_SetsLocatorsAndTheDefaultRenderer() public {
        (,, uint256 tokenId) = _opened();
        bytes memory notArtist =
            abi.encodeWithSelector(IFederatedToken.NotArtist.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(notArtist);
        fed.setLocator(tokenId, 0, 1, "ar://x");
        vm.expectRevert(notArtist);
        fed.setDefaultRenderer(address(renderer), address(renderer), address(renderer).codehash);
        vm.stopPrank();
    }

    function test_Constructor_ChecksTheContentStore() public {
        IFederatedStream.Config memory c = _streamConfig(fedArtist);
        c.contentStore = stranger;
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        new FederatedStream(c);
    }

    function test_ApproveItem_Logs() public {
        bytes32 h = _itemHash(_fedWork(fedArtist));
        vm.expectEmit(address(fed));
        emit IFederatedStream.ItemApproval(h, RATE, true);
        vm.prank(fedArtist);
        fed.approveItem(h, RATE);
    }

    function test_SettlePrimary_AnUnsoldTokenComesHomeAndSaysSo() public {
        (,, uint256 tokenId) = _opened();
        vm.prank(address(auction));
        PrimarySettlement memory s =
            fed.settlePrimary(tokenId, PrimaryOutcome.UNBID, address(0), address(0), 0);
        assertEq(s.holder, address(fed));
        assertEq(fed.ownerOf(tokenId), address(fed));
    }

    /// @dev Every change to a work's record logs it and its metadata refresh; the record changes
    ///      also count toward its version.
    function test_Record_EveryChangeLogsAndCounts() public {
        (,, uint256 tokenId) = _opened();
        bytes32 next = _record("Renamed");
        vm.startPrank(fedArtist);
        vm.expectEmit(address(fed));
        emit IFederatedStream.RecordChanged(1, next);
        vm.expectEmit(address(fed));
        emit IFederatedToken.MetadataUpdate(tokenId);
        fed.setRecord(tokenId, next);
        assertEq(fed.record(tokenId).version, 1);

        vm.expectEmit(address(fed));
        emit IFederatedStream.RoyaltyRateChanged(1, RATE, 0);
        vm.expectEmit(address(fed));
        emit IFederatedToken.MetadataUpdate(tokenId);
        fed.setRoyaltyRate(tokenId, 0);
        assertEq(fed.record(tokenId).version, 2);

        vm.expectEmit(address(fed));
        emit IFederatedStream.LocatorSet(1, 0, 1, "ar://x");
        vm.expectEmit(address(fed));
        emit IFederatedToken.MetadataUpdate(tokenId);
        fed.setLocator(tokenId, 0, 1, "ar://x");

        vm.expectEmit(address(fed));
        emit IFederatedStream.Finalized(1, address(renderer), address(renderer).codehash);
        vm.expectEmit(address(fed));
        emit IFederatedToken.MetadataUpdate(tokenId);
        fed.finalize(tokenId);
        vm.stopPrank();
        assertEq(fed.record(tokenId).version, 3);
    }

    function test_SyncOnChain_LogsTheCompletion() public {
        Work memory w = _work(fedArtist, 0);
        bytes memory media = abi.encodePacked("stored effects media");
        bytes32 sha = sha256(media);
        bytes32 fileId = _upload(media, IContentStore.Encoding.Identity, "image/png", sha);
        w.media[0].fileId = fileId;
        w.media[0].sha256Hash = sha;
        w.item = _item(fedArtist, 0, sha, w.media, w.item.recordFileId);
        (, uint256 tokenId) = _startFed(w);
        vm.expectEmit(address(fed));
        emit IFederatedStream.OnChainComplete(1);
        vm.expectEmit(address(fed));
        emit IFederatedToken.MetadataUpdate(tokenId);
        fed.syncOnChain(tokenId);
    }

    function test_LicenseOf_TheItemsLicense() public {
        (Work memory w,, uint256 tokenId) = _opened();
        License memory l = fed.licenseOf(tokenId);
        assertEq(l.spdxId, w.item.license.spdxId);
        assertEq(l.textFileId, w.item.license.textFileId);
        assertEq(l.spdxId, "CC0-1.0");
    }

    /// @dev A renderer whose code no longer matches its pin is refused when a work pins it, when
    ///      a work is rendered through it, and when it is installed with the wrong hash.
    function test_Renderer_CodeThatChangedIsRefused() public {
        (,, uint256 tokenId) = _opened();
        address r = address(renderer);
        bytes32 pinned = r.codehash;
        vm.prank(fedArtist);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, r));
        fed.setDefaultRenderer(r, r, keccak256("another build"));
        vm.etch(r, abi.encodePacked(r.code, uint8(0)));
        assertTrue(r.codehash != pinned);
        vm.expectRevert(abi.encodeWithSelector(Dependency.DependencyCodeChanged.selector, r));
        fed.rendererOf(tokenId);
        vm.prank(fedArtist);
        vm.expectRevert(abi.encodeWithSelector(Dependency.DependencyCodeChanged.selector, r));
        fed.finalize(tokenId);
    }
}
