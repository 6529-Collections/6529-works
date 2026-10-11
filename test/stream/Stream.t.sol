// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {
    IERC721Metadata
} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import {
    ItemKind,
    License,
    PackageItem,
    Party,
    PartyRole,
    SeedPolicy
} from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { Stream } from "src/stream/Stream.sol";
import { IStreamCore } from "src/stream/IStreamCore.sol";
import {
    MockEditions,
    MockPackageRegistry,
    MockRenderer,
    MockSaleAdapter,
    MockWorkRecords,
    RoyaltyProbe
} from "../mocks/stream/StreamMocks.sol";
import { StreamFixture, StreamRoles } from "./StreamFixture.sol";

contract StreamTest is StreamFixture {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    // ------------------------------------------------------------------------------ deploy

    function test_constructor_wiringAndEvents() public view {
        assertEq(stream.packageRegistry(), address(registry));
        assertEq(stream.artistRegistry(), address(artists));
        assertEq(stream.economics(), address(econ));
        assertEq(stream.defaultRenderer(), address(renderer));
        assertEq(stream.owner(), marketOwner);
        assertEq(stream.records(), address(0));
        assertEq(stream.editions(), address(0));
        assertEq(stream.name(), "6529 Stream");
        assertEq(stream.symbol(), "STREAM");
        assertEq(stream.totalMinted(), 0);
        assertEq(stream.totalSupply(), 0);
    }

    function test_constructor_rejectsDependencyWithoutCode() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.InvalidDependency.selector, eoa));
        new Stream(
            address(manager),
            eoa,
            address(artists),
            address(econ),
            address(renderer),
            marketOwner,
            _license("CC0-1.0")
        );
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.InvalidDependency.selector, eoa));
        new Stream(
            address(manager),
            address(registry),
            eoa,
            address(econ),
            address(renderer),
            marketOwner,
            _license("CC0-1.0")
        );
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.InvalidDependency.selector, eoa));
        new Stream(
            address(manager),
            address(registry),
            address(artists),
            eoa,
            address(renderer),
            marketOwner,
            _license("CC0-1.0")
        );
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.InvalidDependency.selector, eoa));
        new Stream(
            address(manager),
            address(registry),
            address(artists),
            address(econ),
            eoa,
            marketOwner,
            _license("CC0-1.0")
        );
    }

    function test_constructor_rejectsDelegatedAccount() public {
        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(renderer)));
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.InvalidDependency.selector, delegated));
        new Stream(
            address(manager),
            address(registry),
            address(artists),
            address(econ),
            delegated,
            marketOwner,
            _license("CC0-1.0")
        );
    }

    // -------------------------------------------------------------------------------- mint

    function test_mint_storesWorkAndReturnsTerms() public {
        PackageItem memory item = _item(1);
        bytes32 itemHash = WorksHashing.itemHash(item);
        bytes memory data = _request(item);

        vm.expectEmit(address(stream));
        emit IStreamCore.WorkMinted(
            1,
            collectionId,
            itemHash,
            1,
            uint256(uint160(artist)),
            ItemKind.ORIGINAL,
            item.contentId,
            seller,
            royaltyWallet,
            6_529
        );
        vm.expectEmit(address(stream));
        emit Transfer(address(0), address(auction), 1);
        (uint256 tokenId, PrimaryTerms memory terms) = auction.start(stream, data);

        assertEq(tokenId, 1);
        assertEq(stream.ownerOf(1), address(auction));
        assertEq(terms.saleKind, SaleKind.ENGLISH_AUCTION);
        assertEq(terms.currency, address(0));
        assertEq(terms.price, 0);
        assertEq(terms.params.length, 0);
        assertEq(terms.seller, seller);
        assertEq(terms.feeRecipient, feeRecipient);
        assertEq(terms.feeShare, 25_000);
        assertEq(terms.creator, artist);
        assertFalse(terms.revealPending);

        IStreamCore.TokenInfo memory info = stream.work(1);
        assertEq(info.itemHash, itemHash);
        assertEq(info.artistId, uint256(uint160(artist)));
        assertEq(info.collectionId, collectionId);
        assertEq(info.serial, 1);
        assertEq(uint8(info.kind), uint8(ItemKind.ORIGINAL));
        assertFalse(info.editionLinked);
        assertEq(stream.itemHashOf(1), itemHash);
        (address receiver, uint32 rate) = stream.royaltyOf(1);
        assertEq(receiver, royaltyWallet);
        assertEq(rate, 6_529);
        assertEq(stream.licenseOf(1).spdxId, "CC0-1.0");
        assertEq(stream.totalMinted(), 1);
        assertEq(stream.totalSupply(), 1);
        assertEq(stream.collection(collectionId).minted, 1);
        assertTrue(registry.isConsumed(itemHash));
        assertEq(registry.lastRoot(), keccak256("root"));
        assertEq(registry.lastProof().length, 2);
        assertEq(registry.lastMoveNonce(), 7);
    }

    function test_mint_assignsGlobalIdsAndPerCollectionSerials() public {
        vm.prank(platform);
        uint256 second = stream.createCollection("Second", bytes32(0));
        PackageItem memory a = _item(1);
        PackageItem memory b = _item(2);
        b.collectionId = second;
        PackageItem memory c = _item(3);
        assertEq(_mint(a), 1);
        assertEq(_mint(b), 2);
        assertEq(_mint(c), 3);
        assertEq(stream.work(1).serial, 1);
        assertEq(stream.work(2).serial, 1);
        assertEq(stream.work(3).serial, 2);
        assertEq(stream.collection(collectionId).minted, 2);
        assertEq(stream.collection(second).minted, 1);
    }

    function test_mint_resolvesDefaultCurrencyAndFlagsVrf() public {
        PackageItem memory item = _item(1);
        item.sale.currency = address(type(uint160).max);
        item.seedPolicy = SeedPolicy.VRF;
        (, PrimaryTerms memory terms) = auction.start(stream, _request(item));
        assertEq(terms.currency, address(0));
        assertTrue(terms.revealPending);
    }

    function test_mint_acceptsArtistSeedAndEditionMaster() public {
        PackageItem memory item = _item(1);
        item.seedPolicy = SeedPolicy.ARTIST;
        item.seed = keccak256("seed");
        item.kind = ItemKind.EDITION_MASTER;
        uint256 tokenId = _mint(item);
        assertEq(uint8(stream.work(tokenId).kind), uint8(ItemKind.EDITION_MASTER));
    }

    function test_mint_revertsForOutsider() public {
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.mint(outsider, 0, 1, _request(_item(1)));
    }

    function test_mint_revertsForWrongShape() public {
        bytes memory data = _request(_item(1));
        vm.expectRevert(IStreamCore.InvalidMintRequest.selector);
        auction.startRaw(stream, outsider, 0, 1, data);
        vm.expectRevert(IStreamCore.InvalidMintRequest.selector);
        auction.startRaw(stream, address(auction), 1, 1, data);
        vm.expectRevert(IStreamCore.InvalidMintRequest.selector);
        auction.startRaw(stream, address(auction), 0, 2, data);
    }

    function test_mint_revertsForWrongAdapterKind() public {
        auction.setSaleKind(SaleKind.FIXED_PRICE);
        bytes memory data = _request(_item(1));
        vm.expectRevert(IStreamCore.InvalidMintRequest.selector);
        auction.start(stream, data);
    }

    function test_mint_revertsForMalformedData() public {
        vm.expectRevert(IStreamCore.InvalidMintRequest.selector);
        auction.start(stream, new bytes(159));
        bytes memory data = _request(_item(1));
        assembly ("memory-safe") {
            mstore(add(data, 0x20), 0x40)
        }
        vm.expectRevert(IStreamCore.InvalidMintRequest.selector);
        auction.start(stream, data);
    }

    function test_mint_revertsForStreamRuleBreaks() public {
        PackageItem memory item = _item(1);
        item.sale.saleKind = SaleKind.FIXED_PRICE;
        _expectInvalid(item);

        item = _item(1);
        item.sale.params = hex"01";
        _expectInvalid(item);

        item = _item(1);
        item.parties = new Party[](0);
        _expectInvalid(item);

        item = _item(1);
        item.collectionId = 99;
        _expectInvalid(item);

        item = _item(1);
        item.seedPolicy = SeedPolicy.ARTIST;
        _expectInvalid(item);

        item = _item(1);
        item.seed = keccak256("stray");
        _expectInvalid(item);

        item = _item(1);
        item.seedPolicy = SeedPolicy.VRF;
        item.seed = keccak256("stray");
        _expectInvalid(item);
    }

    function test_mint_revertsForInvalidLicense() public {
        PackageItem memory item = _item(1);
        item.license = _license("");
        bytes memory data = _request(item);
        vm.expectRevert(IStreamCore.InvalidLicense.selector);
        auction.start(stream, data);
        item.license = _license(string(new bytes(65)));
        data = _request(item);
        vm.expectRevert(IStreamCore.InvalidLicense.selector);
        auction.start(stream, data);
    }

    function test_mint_bubblesRegistryRevert() public {
        PackageItem memory item = _item(1);
        _mint(item);
        bytes memory data = _request(item);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockPackageRegistry.ItemConsumedAlready.selector, WorksHashing.itemHash(item)
            )
        );
        auction.start(stream, data);
    }

    function test_mint_revertsForUnusableArtistId() public {
        registry.setArtistOverride(0);
        bytes memory data = _request(_item(1));
        vm.expectRevert(IStreamCore.InvalidMintRequest.selector);
        auction.start(stream, data);
        registry.setArtistOverride(uint256(type(uint160).max) + 1);
        vm.expectRevert(IStreamCore.InvalidMintRequest.selector);
        auction.start(stream, data);
    }

    function test_mint_revertsForUnusableEconomics() public {
        bytes memory data = _request(_item(1));
        WorkTerms memory bad = _defaultTerms();
        bad.seller = address(0);
        _expectBadTerms(bad, data);
        bad = _defaultTerms();
        bad.royaltyReceiver = address(0);
        _expectBadTerms(bad, data);
        bad = _defaultTerms();
        bad.royaltyRate = 100_001;
        _expectBadTerms(bad, data);
        bad = _defaultTerms();
        bad.feeShare = 100_001;
        _expectBadTerms(bad, data);
    }

    function test_mint_bubblesCurrencyRejection() public {
        PackageItem memory item = _item(1);
        item.sale.currency = address(0xBEEF);
        econ.setBlocked(address(0xBEEF), true);
        bytes memory data = _request(item);
        vm.expectRevert();
        auction.start(stream, data);
    }

    function test_mint_deduplicatesLicenses() public {
        PackageItem memory a = _item(1);
        PackageItem memory b = _item(2);
        PackageItem memory c = _item(3);
        c.license = _license("CC-BY-4.0");
        _mint(a);
        _mint(b);
        _mint(c);
        assertEq(stream.licenseOf(1).spdxId, "CC0-1.0");
        assertEq(stream.licenseOf(2).spdxId, "CC0-1.0");
        assertEq(stream.licenseOf(3).spdxId, "CC-BY-4.0");
        assertEq(stream.licenseOf(3).textFileId, keccak256("CC-BY-4.0"));
    }

    function test_primaryTerms_matchesMint() public {
        PackageItem memory item = _item(1);
        bytes memory data = _request(item);
        PrimaryTerms memory preview = stream.primaryTerms(0, data);
        (, PrimaryTerms memory terms) = auction.start(stream, data);
        assertEq(abi.encode(preview), abi.encode(terms));
    }

    function test_primaryTerms_reverts() public {
        bytes memory data = _request(_item(1));
        vm.expectRevert(IStreamCore.InvalidMintRequest.selector);
        stream.primaryTerms(1, data);
        PackageItem memory item = _item(1);
        item.parties[0] = Party(makeAddr("stranger"), PartyRole.ARTIST);
        vm.expectRevert(IStreamCore.InvalidMintRequest.selector);
        stream.primaryTerms(0, _request(item));
    }

    // -------------------------------------------------------------------------------- burn

    function test_burn_leavesGapAndCountsSupply() public {
        _mint(1);
        _mint(2);
        bytes32 itemHash = stream.itemHashOf(1);
        vm.expectEmit(address(stream));
        emit Transfer(address(auction), address(0), 1);
        auction.burn(stream, 1, 1);
        assertEq(stream.totalMinted(), 2);
        assertEq(stream.totalSupply(), 1);
        assertEq(stream.balanceOf(address(auction)), 1);
        assertEq(stream.itemHashOf(1), itemHash);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        stream.ownerOf(1);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnknownWork.selector, 1));
        stream.work(1);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnknownWork.selector, 1));
        stream.royaltyInfo(1, 1 ether);
        assertEq(_mint(3), 3);
    }

    function test_burn_reverts() public {
        _mint(1);
        vm.expectRevert(IStreamCore.InvalidMintRequest.selector);
        auction.burn(stream, 1, 2);
        auction.deliver(address(stream), 1, outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC721Errors.ERC721IncorrectOwner.selector, address(auction), 1, outsider
            )
        );
        auction.burn(stream, 1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC721Errors.ERC721IncorrectOwner.selector, address(auction), 9, address(0)
            )
        );
        auction.burn(stream, 9, 1);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.burn(1, 1);
    }

    // ------------------------------------------------------------------------- collections

    function test_createCollection() public {
        vm.expectEmit(address(stream));
        emit IStreamCore.CollectionCreated(2, unicode"Ünïcode", keccak256("m"));
        vm.prank(platform);
        assertEq(stream.createCollection(unicode"Ünïcode", keccak256("m")), 2);
        IStreamCore.Collection memory c = stream.collection(2);
        assertEq(c.name, unicode"Ünïcode");
        assertEq(c.metadataHash, keccak256("m"));
        assertEq(c.minted, 0);
        assertEq(stream.collectionCount(), 2);
    }

    function test_createCollection_reverts() public {
        vm.startPrank(platform);
        vm.expectRevert(IStreamCore.InvalidCollection.selector);
        stream.createCollection("", bytes32(0));
        vm.expectRevert(IStreamCore.InvalidCollection.selector);
        stream.createCollection(string(new bytes(257)), bytes32(0));
        vm.expectRevert(IStreamCore.InvalidCollection.selector);
        stream.createCollection(string(bytes(hex"c0af")), bytes32(0));
        vm.stopPrank();
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.createCollection("x", bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnknownCollection.selector, 0));
        stream.collection(0);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnknownCollection.selector, 2));
        stream.collection(2);
    }

    // ----------------------------------------------------------------------------- royalty

    function test_royaltyInfo_exactAtLaunchRate() public {
        _mint(1);
        (address receiver, uint256 amount) = stream.royaltyInfo(1, 1 ether);
        assertEq(receiver, royaltyWallet);
        assertEq(amount, 0.06529 ether);
    }

    function testFuzz_royaltyInfo_matchesMulDiv(uint256 price, uint32 rate) public {
        rate = uint32(bound(rate, 0, 100_000));
        _bindSatellites();
        _mint(1);
        recordsMock.setRoyaltyRate(stream, 1, rate);
        (address receiver, uint256 amount) = stream.royaltyInfo(1, price);
        assertEq(receiver, royaltyWallet);
        assertEq(amount, Math.mulDiv(price, rate, 100_000));
        assertLe(amount, price);
    }

    /// @dev RC1's Medium finding: `royaltyInfo` returned zero when about 3M gas did not remain.
    ///      Here, at any gas limit, the call either reverts or returns the exact royalty.
    function testFuzz_royaltyInfo_neverZeroForLackOfGas(uint256 gasLimit, uint256 price) public {
        gasLimit = bound(gasLimit, 0, 60_000);
        price = bound(price, 100_000, type(uint128).max);
        _mint(1);
        RoyaltyProbe probe = new RoyaltyProbe();
        (bool ok, address receiver, uint256 amount) =
            probe.probe(address(stream), 1, price, gasLimit);
        if (ok) {
            assertEq(receiver, royaltyWallet);
            assertEq(amount, Math.mulDiv(price, 6_529, 100_000));
            assertGt(amount, 0);
        }
    }

    function test_royaltyInfo_succeedsWithSmallBudget() public {
        _mint(1);
        RoyaltyProbe probe = new RoyaltyProbe();
        (bool ok,, uint256 amount) = probe.probe(address(stream), 1, 1 ether, 30_000);
        assertTrue(ok);
        assertEq(amount, 0.06529 ether);
    }

    function test_royaltyInfo_revertsForUnknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnknownWork.selector, 1));
        stream.royaltyInfo(1, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnknownWork.selector, 1));
        stream.royaltyOf(1);
    }

    // ------------------------------------------------------------------------ records hooks

    function test_setLicense_fromRecords() public {
        _bindSatellites();
        PackageItem memory item = _item(1);
        item.license = _license("CC-BY-4.0");
        _mint(item);
        License memory next = _license("CC0-1.0");
        vm.expectEmit(address(stream));
        emit IStreamCore.LicenseChanged(1, _license("CC-BY-4.0"), next);
        vm.expectEmit(address(stream));
        emit MetadataUpdate(1);
        recordsMock.setLicense(stream, 1, next);
        assertEq(stream.licenseOf(1).spdxId, "CC0-1.0");
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.LicenseIrrevocable.selector, 1));
        recordsMock.setLicense(stream, 1, _license("CC-BY-4.0"));
    }

    function test_setLicense_cc0IsIrrevocableInAnyCase() public {
        _bindSatellites();
        PackageItem memory item = _item(1);
        item.license = _license("cc0-1.0");
        _mint(item);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.LicenseIrrevocable.selector, 1));
        recordsMock.setLicense(stream, 1, _license("MIT"));
        assertEq(stream.licenseKey("CC0-1.0"), keccak256("cc0-1.0"));
        assertEq(stream.licenseKey("Cc0-1.0"), stream.licenseKey("cC0-1.0"));
        assertEq(stream.licenseKey("MIT"), keccak256("mit"));
    }

    function testFuzz_licenseKey_lowercasesAsciiOnly(bytes memory raw) public view {
        bytes memory lower = bytes.concat(raw);
        for (uint256 i; i < lower.length; ++i) {
            if (lower[i] >= "A" && lower[i] <= "Z") lower[i] = bytes1(uint8(lower[i]) + 32);
        }
        assertEq(stream.licenseKey(string(raw)), keccak256(lower));
    }

    function test_setLicense_reverts() public {
        _bindSatellites();
        PackageItem memory item = _item(1);
        item.license = _license("CC-BY-4.0");
        _mint(item);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnboundCaller.selector, outsider));
        vm.prank(outsider);
        stream.setLicense(1, _license("CC0-1.0"));
        vm.expectRevert(IStreamCore.InvalidLicense.selector);
        recordsMock.setLicense(stream, 1, _license(""));
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnknownWork.selector, 2));
        recordsMock.setLicense(stream, 2, _license("CC0-1.0"));
    }

    function test_hooks_revertBeforeBinding() public {
        _mint(1);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnboundCaller.selector, address(this)));
        stream.setRoyaltyRate(1, 1);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnboundCaller.selector, address(this)));
        stream.refreshMetadata(1, 1);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnboundCaller.selector, address(this)));
        stream.setLicense(1, _license("MIT"));
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnboundCaller.selector, address(this)));
        stream.linkEdition(1, 1);
    }

    function test_setRoyaltyRate_fromRecords() public {
        _bindSatellites();
        _mint(1);
        vm.expectEmit(address(stream));
        emit IStreamCore.RoyaltyChanged(1, royaltyWallet, 6_529, 10_000);
        recordsMock.setRoyaltyRate(stream, 1, 10_000);
        (address receiver, uint32 rate) = stream.royaltyOf(1);
        assertEq(receiver, royaltyWallet);
        assertEq(rate, 10_000);
        vm.expectRevert(IStreamCore.InvalidRoyalty.selector);
        recordsMock.setRoyaltyRate(stream, 1, 100_001);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnboundCaller.selector, outsider));
        stream.setRoyaltyRate(1, 1);
    }

    function test_refreshMetadata_fromRecords() public {
        _bindSatellites();
        vm.expectEmit(address(stream));
        emit MetadataUpdate(4);
        recordsMock.refresh(stream, 4, 4);
        vm.expectEmit(address(stream));
        emit BatchMetadataUpdate(1, 9);
        recordsMock.refresh(stream, 1, 9);
    }

    // ---------------------------------------------------------------------------- bindings

    function test_bindings_onceAndEvents() public {
        MockWorkRecords r = new MockWorkRecords();
        MockEditions e = new MockEditions();
        vm.expectEmit(address(stream));
        emit IStreamCore.RecordsBound(address(r));
        stream.bindRecords(address(r));
        vm.expectEmit(address(stream));
        emit IStreamCore.EditionsBound(address(e));
        stream.bindEditions(address(e));
        assertEq(stream.records(), address(r));
        assertEq(stream.editions(), address(e));
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.AlreadyBound.selector, address(r)));
        stream.bindRecords(address(e));
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.AlreadyBound.selector, address(e)));
        stream.bindEditions(address(r));
    }

    function test_bindings_reverts() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.InvalidDependency.selector, eoa));
        stream.bindRecords(eoa);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.InvalidDependency.selector, eoa));
        stream.bindEditions(eoa);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.bindRecords(address(renderer));
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.bindEditions(address(renderer));
    }

    // ---------------------------------------------------------------------------- editions

    function test_linkEdition() public {
        _bindSatellites();
        PackageItem memory item = _item(1);
        item.kind = ItemKind.EDITION_MASTER;
        _mint(item);
        (address e, uint256 id) = stream.editionOf(1);
        assertEq(e, address(0));
        assertEq(id, 0);
        vm.expectEmit(address(stream));
        emit IStreamCore.EditionLinked(1, address(editionsMock), 1);
        vm.expectEmit(address(stream));
        emit MetadataUpdate(1);
        editionsMock.link(stream, 1, 1);
        (e, id) = stream.editionOf(1);
        assertEq(e, address(editionsMock));
        assertEq(id, 1);
        assertTrue(stream.work(1).editionLinked);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.EditionLinkInvalid.selector, 1));
        editionsMock.link(stream, 1, 1);
    }

    function test_linkEdition_reverts() public {
        _bindSatellites();
        _mint(1);
        PackageItem memory master = _item(2);
        master.kind = ItemKind.EDITION_MASTER;
        _mint(master);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.EditionLinkInvalid.selector, 1));
        editionsMock.link(stream, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.EditionLinkInvalid.selector, 2));
        editionsMock.link(stream, 2, 3);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnknownWork.selector, 5));
        editionsMock.link(stream, 5, 5);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnboundCaller.selector, outsider));
        stream.linkEdition(2, 2);
    }

    // --------------------------------------------------------------------------- rendering

    function test_tokenURI_forwardsToDefaultThenPin() public {
        _bindSatellites();
        _mint(1);
        assertEq(stream.rendererOf(1), address(renderer));
        assertEq(stream.tokenURI(1), renderer.tokenURI(address(stream), 1));
        MockRenderer pinned = new MockRenderer("pinned");
        recordsMock.setPin(1, address(pinned));
        assertEq(stream.rendererOf(1), address(pinned));
        assertEq(stream.tokenURI(1), pinned.tokenURI(address(stream), 1));
    }

    function test_tokenURI_revertsForUnknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnknownWork.selector, 1));
        stream.tokenURI(1);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnknownWork.selector, 1));
        stream.rendererOf(1);
    }

    function test_setDefaultRenderer() public {
        _mint(1);
        _mint(2);
        MockRenderer next = new MockRenderer("next");
        vm.expectEmit(address(stream));
        emit IStreamCore.DefaultRendererSet(address(renderer), address(next));
        vm.expectEmit(address(stream));
        emit BatchMetadataUpdate(1, 2);
        vm.prank(governor);
        stream.setDefaultRenderer(address(renderer), address(next));
        assertEq(stream.defaultRenderer(), address(next));
        assertEq(stream.rendererOf(1), address(next));
    }

    function test_setDefaultRenderer_reverts() public {
        MockRenderer next = new MockRenderer("next");
        vm.startPrank(governor);
        vm.expectRevert(IStreamCore.ExpectedValueMismatch.selector);
        stream.setDefaultRenderer(address(next), address(next));
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.InvalidDependency.selector, eoa));
        stream.setDefaultRenderer(address(renderer), eoa);
        vm.stopPrank();
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.setDefaultRenderer(address(renderer), address(next));
    }

    function test_setDefaultRenderer_noBatchEventBeforeFirstMint() public {
        MockRenderer next = new MockRenderer("next");
        vm.recordLogs();
        vm.prank(governor);
        stream.setDefaultRenderer(address(renderer), address(next));
        assertEq(vm.getRecordedLogs().length, 1);
    }

    // ------------------------------------------------------------------------- marketplace

    function test_contractURI() public {
        vm.expectEmit(address(stream));
        emit IStreamCore.ContractURIUpdated();
        vm.prank(governor);
        stream.setContractURI("ipfs://contract");
        assertEq(stream.contractURI(), "ipfs://contract");
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.setContractURI("x");
    }

    function test_setOwner() public {
        address next = makeAddr("nextOwner");
        vm.expectEmit(address(stream));
        emit IStreamCore.OwnershipTransferred(marketOwner, next);
        vm.prank(governor);
        stream.setOwner(marketOwner, next);
        assertEq(stream.owner(), next);
        vm.prank(governor);
        vm.expectRevert(IStreamCore.ExpectedValueMismatch.selector);
        stream.setOwner(marketOwner, next);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.setOwner(next, outsider);
    }

    function test_governedFunctionsAreNonPayable() public {
        vm.deal(governor, 1 ether);
        vm.prank(governor);
        (bool ok,) = address(stream).call{ value: 1 }(
            abi.encodeCall(stream.setOwner, (marketOwner, governor))
        );
        assertFalse(ok);
        vm.deal(address(auction), 1 ether);
        vm.prank(address(auction));
        (ok,) = address(stream).call{ value: 1 }(
            abi.encodeCall(stream.mint, (address(auction), 0, 1, _request(_item(1))))
        );
        assertFalse(ok);
    }

    function test_supportsInterface() public view {
        assertTrue(stream.supportsInterface(type(IERC165).interfaceId));
        assertTrue(stream.supportsInterface(type(IERC721).interfaceId));
        assertTrue(stream.supportsInterface(type(IERC721Metadata).interfaceId));
        assertTrue(stream.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(stream.supportsInterface(bytes4(0x49064906)));
        assertTrue(stream.supportsInterface(type(IMintTarget).interfaceId));
        assertTrue(stream.supportsInterface(type(IStreamCore).interfaceId));
        assertFalse(stream.supportsInterface(0xffffffff));
        assertFalse(stream.supportsInterface(0x12345678));
    }

    function test_transfersAreStandard() public {
        _mint(1);
        address collector = makeAddr("collector");
        auction.deliver(address(stream), 1, collector);
        assertEq(stream.ownerOf(1), collector);
        vm.prank(collector);
        stream.safeTransferFrom(collector, outsider, 1);
        assertEq(stream.ownerOf(1), outsider);
        assertEq(stream.totalSupply(), 1);
    }

    // ----------------------------------------------------------------------------- helpers

    function _expectInvalid(PackageItem memory item) internal {
        bytes memory data = _request(item);
        vm.expectRevert(IStreamCore.InvalidMintRequest.selector);
        auction.start(stream, data);
    }

    function _expectBadTerms(WorkTerms memory terms, bytes memory data) internal {
        econ.setTerms(terms);
        vm.expectRevert(IStreamCore.InvalidMintRequest.selector);
        auction.start(stream, data);
        econ.setTerms(_defaultTerms());
    }
}
