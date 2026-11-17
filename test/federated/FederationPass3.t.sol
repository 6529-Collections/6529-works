// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FederatedStream } from "src/federated/FederatedStream.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH, PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryOutcome } from "src/interfaces/types/SaleTypes.sol";
import { Burner } from "../helpers/GasRule.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice A federated work's license text meets 6529 Stream's frozen-license rule; a federated
///         1/1 sale's fee recipient is the one locked at start; the registry's batches are
///         bounded so a governed batch always fits a transaction.
contract FederationPass3Test is FederationBase {
    address internal collector = makeAddr("collector");

    function setUp() public override {
        super.setUp();
        _joinedFed();
    }

    // ------------------------------------------------------------------ the license text

    /// @dev A text registered with `n` unwritten chunks.
    function _textOf(uint256 n) internal returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            hashes[i] = keccak256(abi.encode("license text chunk", n, i));
        }
        uint256 size = store.CHUNK_SIZE();
        return store.registerManifest(
            hashes,
            (n - 1) * size + 1,
            uint8(IContentStore.Encoding.Identity),
            "text/plain",
            keccak256(abi.encode("license text", n))
        );
    }

    /// @dev One stored chunk registered with digest kind 1 (not SHA-256).
    function _otherDigestKind(bytes memory data) internal returns (bytes32) {
        store.writeChunk(data);
        (bytes32 list,) = store.writeChunk(abi.encodePacked(keccak256(data)));
        bytes32[] memory lists = new bytes32[](1);
        lists[0] = list;
        return store.registerManifestList(
            lists,
            1,
            data.length,
            uint8(IContentStore.Encoding.Identity),
            "text/plain",
            keccak256(data),
            1
        );
    }

    function _startWith(License memory lic, bytes memory reason)
        internal
        returns (uint256 tokenId)
    {
        Work memory w = _fedWork(fedArtist);
        w.item.license = lic;
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        if (reason.length != 0) vm.expectRevert(reason);
        uint256 saleId = auction.start(address(fed), _mintData(w));
        if (reason.length == 0) tokenId = auction.auction(saleId).tokenId;
    }

    /// @dev Pass 3: the license is fixed from the first mint, so its text must already be a
    ///      registered SHA-256 file of at most 16 chunks, as a frozen license in 6529 Stream's
    ///      records.
    function test_License_TheTextIsARegisteredSha256FileOfAtMostSixteenChunks() public {
        bytes32 unknown = keccak256("no such file");
        _startWith(
            License("CC-BY-4.0", unknown),
            abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, unknown)
        );
        bytes32 other = _otherDigestKind("CC-BY-4.0 legal code, other digest");
        _startWith(
            License("CC-BY-4.0", other),
            abi.encodeWithSelector(IFederatedStream.InvalidLicenseText.selector, other)
        );
        bytes32 long = _textOf(17);
        _startWith(
            License("CC-BY-4.0", long),
            abi.encodeWithSelector(IFederatedStream.InvalidLicenseText.selector, long)
        );
        _startWith(License("CC-BY-4.0", _textOf(16)), "");
    }

    /// @dev Finalize needs the license text complete in the content store; anyone may write
    ///      the chunks, so a work is never stuck.
    function test_License_FinalizeNeedsTheTextOnChain() public {
        bytes memory text = "CC-BY-4.0 legal code, federated";
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(text);
        bytes32 id = store.registerManifest(
            hashes, text.length, uint8(IContentStore.Encoding.Identity), "text/plain", sha256(text)
        );
        uint256 tokenId = _startWith(License("CC-BY-4.0", id), "");
        vm.prank(fedArtist);
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.InvalidLicenseText.selector, id));
        fed.finalize(tokenId);
        vm.prank(collector);
        store.writeChunk(text);
        vm.prank(fedArtist);
        fed.finalize(tokenId);
    }

    // ------------------------------------------------------------------ the fee recipient

    /// @dev A governance change of the federated fee recipient between start and settlement
    ///      does not redirect the running sale's fee: the recipient was locked at start.
    function test_FeeRecipient_TheOneCurrentAtSettlement() public {
        (uint256 saleId,) = _startFed(_fedWork(fedArtist));
        _ethBid(saleId, collector, 1 ether);
        address next = makeAddr("nextFeeRecipient");
        (uint64 revision,,) = economics.revisions(PRODUCT_FEDERATED);
        _govern(
            hotAdmin,
            address(economics),
            abi.encodeCall(economics.setFeeTerms, (PRODUCT_FEDERATED, revision, next, FED_SHARE))
        );
        assertEq(economics.networkFeeRecipient(PRODUCT_FEDERATED), next);
        uint256 before = networkFee.balance;
        auction.settle(saleId);
        // R18: the share is locked at start; the recipient is the resolver's at settlement.
        assertEq(networkFee.balance, before, "not the recipient current at start");
        assertEq(next.balance, 0.1 ether, "the recipient current at settlement");
    }

    // ------------------------------------------------------------------ batch bounds

    function _addresses(uint256 n) internal pure returns (address[] memory list) {
        list = new address[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = address(uint160(0x6529_0000 + i));
        }
    }

    /// @dev A status batch takes at most `MAX_BATCH` contracts: at the bound it runs, above it
    ///      it refuses.
    function test_Batch_BoundedAtMaxBatch() public {
        uint256 bound = fedRegistry.MAX_BATCH();
        assertEq(bound, 256);
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(
                fedRegistry.setStatus, (_addresses(bound), IFederationRegistry.Status.DELISTED, "")
            )
        );
        bytes memory tooMany = abi.encodeCall(
            fedRegistry.setStatus, (_addresses(bound + 1), IFederationRegistry.Status.DELISTED, "")
        );
        (, uint32 delay) = manager.canCall(hotAdmin, address(fedRegistry), bytes4(tooMany));
        vm.prank(hotAdmin);
        manager.schedule(address(fedRegistry), tooMany, 0);
        vm.warp(block.timestamp + delay);
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(FederationRegistry.BatchTooLarge.selector, bound + 1)
        );
        manager.execute(address(fedRegistry), tooMany);
    }

    /// @dev The bound's arithmetic: the worst element of a `setStatus` batch (a cold listed
    ///      contract read and written DELISTED in the directory) costs under 20,000 gas, so
    ///      `MAX_BATCH` of them fit well inside EIP-7825's 2^24 cap.
    function test_Batch_TheWorstElementFitsTheBound() public {
        uint256 n = 4;
        address[] memory tokens = new address[](n);
        for (uint256 i; i < n; ++i) {
            address a = _actor(string.concat("batchArtist", vm.toString(i)));
            FederatedStream t = _deployStream(a);
            _join(address(t), a);
            tokens[i] = address(t);
        }
        _coolAll();
        for (uint256 i; i < n; ++i) {
            vm.cool(tokens[i]);
        }
        vm.cool(address(artists));
        uint256 single;
        uint256 rest;
        vm.startPrank(address(fedRegistry));
        for (uint256 i; i < n; ++i) {
            uint256 g = gasleft();
            artists.federatedListing(tokens[i]);
            artists.setFederatedStatus(tokens[i], IArtistRegistry.FederationStatus.DELISTED, "");
            if (i == 0) single = g - gasleft();
            else rest += g - gasleft();
        }
        vm.stopPrank();
        uint256 perElement = rest / (n - 1);
        emit log_named_uint("setStatus, one cold element (gas)", single);
        emit log_named_uint("setStatus, per further cold element (gas)", perElement);
        assertLt(perElement, 20_000);
        assertLt(fedRegistry.MAX_BATCH() * 20_000 + single, uint256(1 << 24) / 3);
    }

    // ------------------------------------------------------------------ packed words

    /// @dev A work of `Limits.MAX_MEDIA_FILES` files, the last with role 15: every role is kept
    ///      in its own four bits below the count, so the count stays 32 and each file reads back
    ///      with its role.
    function test_Roles_ThirtyTwoFilesKeepEveryRoleAndTheCount() public {
        uint256 n = Limits.MAX_MEDIA_FILES;
        Work memory w = _fedWork(fedArtist);
        MediaFile[] memory media = new MediaFile[](n);
        media[0] = w.media[0];
        for (uint256 i = 1; i < n; ++i) {
            bytes memory data = abi.encodePacked("federated role file ", vm.toString(i));
            bytes32 sha = sha256(data);
            bytes32 fileId = _registerOnly(data, IContentStore.Encoding.Identity, "image/png", sha);
            media[i] = MediaFile(fileId, sha, uint8(1 + i % 15));
        }
        media[n - 1].role = 15;
        w.media = media;
        w.item = _item(fedArtist, 0, w.item.contentHash, media, w.item.recordFileId);
        (, uint256 tokenId) = _startFed(w);
        MediaFile[] memory read = fed.mediaOf(tokenId);
        assertEq(read.length, n, "the count");
        for (uint256 i; i < n; ++i) {
            assertEq(read[i].fileId, media[i].fileId);
            assertEq(read[i].role, media[i].role);
        }
        vm.prank(fedArtist);
        fed.setLocator(tokenId, n - 1, 1, "ar://last");
        (, uint256 index) = fed.preferredLocator(tokenId, media[n - 1].fileId);
        assertEq(index, n - 1);
        vm.prank(fedArtist);
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.UnknownWork.selector, tokenId));
        fed.setLocator(tokenId, n, 1, "ar://none");
    }

    /// @dev The approval word (status byte, 24-bit rate, work ID above bit 32) at its bounds: the
    ///      highest rate is kept beside the work ID through a restart, and one above it refuses.
    function test_Packed_TheApprovalWordKeepsTheHighestRateBesideTheWork() public {
        uint32 top = 100_000;
        Work memory w = _fedWork(fedArtist);
        bytes32 h = _itemHash(w);
        vm.prank(fedArtist);
        vm.expectRevert(
            abi.encodeWithSelector(IFederatedStream.InvalidRoyaltyRate.selector, top + 1)
        );
        fed.approveItem(h, top + 1);
        (uint256 saleId, uint256 tokenId) = _startFed(fed, fedArtist, w, top);
        (,,,,, uint32 rate) = fed.coreOf(tokenId);
        assertEq(rate, top);
        (, uint256 amount) = fed.royaltyInfo(tokenId, 1 ether);
        assertEq(amount, 1 ether);
        _settleAtEnd(saleId);
        vm.prank(fedArtist);
        fed.approveItem(h, top);
        uint256 again = auction.start(address(fed), _mintData(w));
        uint256 next = auction.auction(again).tokenId;
        assertEq(fed.liveTokenOf(1), next, "the same work");
        (,,,,, rate) = fed.coreOf(next);
        assertEq(rate, top);
    }

    /// @dev The sale word (currency in bits 0 to 159, price above) at its bounds: an all-ones
    ///      currency and a price one below the 96-bit cap read back exactly; a larger price
    ///      saturates at the cap and never touches the currency.
    function test_Packed_TheSaleWordKeepsCurrencyAndPriceApart() public {
        address currency = address(type(uint160).max);
        (, uint256 first) = _startFed(_fedWork(fedArtist));
        vm.prank(address(auction));
        fed.settlePrimary(first, PrimaryOutcome.SOLD, collector, currency, type(uint96).max - 1);
        (, address c, uint256 price) = fed.primarySale(first);
        assertEq(c, currency);
        assertEq(price, type(uint96).max - 1);
        (, uint256 second) = _startFed(_fedWork(fedArtist));
        vm.prank(address(auction));
        fed.settlePrimary(second, PrimaryOutcome.SOLD, collector, currency, type(uint256).max);
        (, c, price) = fed.primarySale(second);
        assertEq(c, currency);
        assertEq(price, type(uint96).max);
    }

    // ------------------------------------------------------------------ the default renderer

    /// @dev The default renderer is compare-and-set and its event names the renderer replaced: a
    ///      call prepared against the earlier renderer cannot replace the one installed after it.
    function test_Renderer_CompareAndSetNamingThePrevious() public {
        (, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        Burner next = new Burner(address(renderer), 0);
        vm.expectEmit(address(fed));
        emit IFederatedStream.DefaultRendererSet(
            address(renderer), address(next), address(next).codehash
        );
        vm.prank(fedArtist);
        fed.setDefaultRenderer(address(renderer), address(next), address(next).codehash);
        assertEq(fed.rendererOf(tokenId), address(next));
        bytes32 rendererHash = address(renderer).codehash;
        vm.prank(fedArtist);
        vm.expectRevert(IFederatedStream.ExpectedValueMismatch.selector);
        fed.setDefaultRenderer(address(renderer), address(renderer), rendererHash);
        assertEq(fed.rendererOf(tokenId), address(next), "the stale call changed nothing");
    }
}
