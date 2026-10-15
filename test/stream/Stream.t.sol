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
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Roles } from "src/governance/Roles.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { CURRENCY_DEFAULT, WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import {
    ItemKind,
    License,
    MoveAuthorization,
    PackageItem,
    Party,
    PartyRole,
    SeedPolicy,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { Stream } from "src/stream/Stream.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import {
    MockEconomics,
    MockEditions,
    MockPackageRegistry,
    MockRenderer,
    MockSaleAdapter,
    MockWorkRecords,
    RoyaltyProbe
} from "../mocks/stream/StreamMocks.sol";
import { RecordsFixture } from "./RecordsFixture.sol";
import { StreamFixture } from "./StreamFixture.sol";
import { Dependency } from "src/libraries/Dependency.sol";

contract StreamTest is StreamFixture {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    // ------------------------------------------------------------------------------ deploy

    function test_constructor_wiringAndEvents() public view {
        assertEq(stream.packageRegistry(), address(registry));
        assertEq(stream.artistRegistry(), address(artists));
        assertEq(stream.economics(), address(econ));
        assertEq(stream.entropyModule(), address(entropy));
        assertEq(stream.splitFactory(), address(splitFactory));
        assertEq(stream.defaultRenderer(), address(renderer));
        assertEq(stream.owner(), marketOwner);
        assertEq(stream.workRecords(), address(0));
        assertEq(stream.editions(), address(0));
        assertEq(stream.name(), "6529 Stream");
        assertEq(stream.symbol(), "STREAM");
        assertEq(stream.totalMinted(), 0);
        assertEq(stream.totalSupply(), 0);
        assertEq(stream.collectionCount(), 1);
        assertTrue(stream.isAdmittedMinter(address(auction)));
    }

    function _deploy(address reg, address art, address eco, address ent, address ren)
        internal
        returns (Stream)
    {
        return new Stream(address(manager), reg, art, eco, ent, ren, ren.codehash, marketOwner);
    }

    function test_constructor_rejectsBadDependencies() public {
        address eoa = makeAddr("eoa");
        address r = address(registry);
        address a = address(artists);
        address e = address(econ);
        address n = address(entropy);
        address d = address(renderer);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        _deploy(eoa, a, e, n, d);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        _deploy(r, eoa, e, n, d);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        _deploy(r, a, eoa, n, d);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        _deploy(r, a, e, eoa, d);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        _deploy(r, a, e, n, eoa);
        // A contract without the right ERC-165 answer is rejected too.
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, a));
        _deploy(a, a, e, n, d);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, r));
        _deploy(r, a, e, n, r);
        assertEq(_deploy(r, a, e, address(0), d).entropyModule(), address(0));
    }

    function test_constructor_pinsRendererCodeHash() public {
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(renderer))
        );
        new Stream(
            address(manager),
            address(registry),
            address(artists),
            address(econ),
            address(entropy),
            address(renderer),
            keccak256("wrong"),
            marketOwner
        );
    }

    /// @dev The split factory comes from the economics resolver and gets the same install check:
    ///      code and no EIP-7702 delegation (it implements no ERC-165).
    function test_constructor_checksTheResolversSplitFactory() public {
        address eoa = makeAddr("factory eoa");
        address delegated = makeAddr("delegated factory");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(splitFactory)));
        address[2] memory refused = [eoa, delegated];
        for (uint256 i; i < refused.length; ++i) {
            address e = address(new MockEconomics(_defaultTerms(), refused[i]));
            vm.expectRevert(
                abi.encodeWithSelector(Dependency.InvalidDependency.selector, refused[i])
            );
            _deploy(address(registry), address(artists), e, address(entropy), address(renderer));
        }
    }

    function test_constructor_rejectsDelegatedAccount() public {
        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(renderer)));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, delegated));
        _deploy(address(registry), address(artists), address(econ), address(entropy), delegated);
    }

    // ------------------------------------------------------------------------ admitted minters

    function test_setAdmittedMinter() public {
        MockSaleAdapter other = new MockSaleAdapter(SaleKind.ENGLISH_AUCTION);
        vm.expectEmit(address(stream));
        emit IMintTarget.AdmittedMinterSet(address(other), true);
        vm.prank(governor);
        stream.setAdmittedMinter(address(other), true);
        assertTrue(stream.isAdmittedMinter(address(other)));
        (uint256 tokenId,) = other.start(stream, _request(_item(1)));
        (uint256 disputed,) = other.start(stream, _request(_item(3)));

        // Removal stops new mints; the minting adapter still finishes its running sales.
        vm.expectEmit(address(stream));
        emit IMintTarget.AdmittedMinterSet(address(other), false);
        vm.prank(governor);
        stream.setAdmittedMinter(address(other), false);
        assertFalse(stream.isAdmittedMinter(address(other)));
        bytes memory data = _request(_item(2));
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(other))
        );
        other.start(stream, data);
        other.settle(stream, tokenId);
        assertTrue(stream.primarySaleSettled(tokenId));
        other.burn(stream, disputed, 1);
        assertEq(stream.totalSupply(), 1);
    }

    function test_setAdmittedMinter_reverts() public {
        address eoa = makeAddr("eoa");
        vm.startPrank(governor);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        stream.setAdmittedMinter(eoa, true);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(econ))
        );
        stream.setAdmittedMinter(address(econ), true);
        vm.stopPrank();
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.setAdmittedMinter(address(auction), false);
    }

    // -------------------------------------------------------------------------------- mint

    function test_mint_storesWorkAndReturnsTerms() public {
        PackageItem memory item = _item(1);
        bytes32 itemHash = WorksHashing.itemHash(item);
        bytes memory data = _request(item);

        vm.expectEmit(address(stream));
        emit IStream.WorkMinted(
            1,
            collectionId,
            itemHash,
            1,
            uint256(uint160(artist)),
            ItemKind.ORIGINAL,
            keccak256("root"),
            item.contentHash,
            item.mediaHash,
            item.recordFileId
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

        IStream.WorkCore memory w = stream.work(1);
        assertEq(w.itemHash, itemHash);
        assertEq(w.artistId, uint256(uint160(artist)));
        assertEq(w.collectionId, collectionId);
        assertEq(w.serial, 1);
        assertEq(uint8(w.kind), uint8(ItemKind.ORIGINAL));
        assertEq(uint8(w.seedPolicy), uint8(SeedPolicy.NONE));
        assertEq(w.seller, seller);
        assertEq(w.royaltyReceiver, _defaultRoyaltyWallet());
        assertEq(w.royaltyRate, 6_529);
        assertEq(stream.artistOf(1), uint256(uint160(artist)));
        assertFalse(stream.primarySaleSettled(1));
        assertEq(stream.totalMinted(), 1);
        assertEq(stream.totalSupply(), 1);
        assertEq(stream.collection(collectionId).minted, 1);
        assertTrue(registry.isConsumed(itemHash));
        assertEq(registry.lastRoot(), keccak256("root"));
        assertEq(registry.lastProofLength(), 2);
        assertEq(registry.lastMoveNonce(), 7);
    }

    function test_mint_assignsGlobalIdsAndPerCollectionSerials() public {
        vm.prank(platform);
        uint256 second = stream.createCollection("Second", bytes32(0));
        PackageItem memory b = _item(2);
        b.collectionId = second;
        assertEq(_mint(_item(1)), 1);
        assertEq(_mint(b), 2);
        assertEq(_mint(_item(3)), 3);
        assertEq(stream.work(1).serial, 1);
        assertEq(stream.work(2).serial, 1);
        assertEq(stream.work(3).serial, 2);
        assertEq(stream.collection(collectionId).minted, 2);
        assertEq(stream.collection(second).minted, 1);
    }

    /// @dev The item's currency passes through unresolved: the adapter resolves
    ///      `CURRENCY_DEFAULT` and checks the allowlist when it locks the currency.
    function test_mint_passesCurrencyThrough() public {
        PackageItem memory item = _item(1);
        item.sale.currency = CURRENCY_DEFAULT;
        (, PrimaryTerms memory terms) = auction.start(stream, _request(item));
        assertEq(terms.currency, CURRENCY_DEFAULT);
        item = _item(2);
        item.sale.currency = address(0xBEEF);
        (, terms) = auction.start(stream, _request(item));
        assertEq(terms.currency, address(0xBEEF));
    }

    /// @dev `coreOf` is the cheap read the records satellite uses; it agrees with `work` and
    ///      reverts for an unminted or burned token.
    function test_coreOf() public {
        PackageItem memory item = _item(1);
        item.seedPolicy = SeedPolicy.ARTIST;
        item.seed = keccak256("seed");
        item.kind = ItemKind.EDITION_MASTER;
        uint256 tokenId = _mint(item);
        (
            bytes32 itemHash,
            uint256 artistId,
            uint256 collection,
            ItemKind kind,
            SeedPolicy seedPolicy,
            uint32 royaltyRate
        ) = stream.coreOf(tokenId);
        IStream.WorkCore memory w = stream.work(tokenId);
        assertEq(itemHash, WorksHashing.itemHash(item));
        assertEq(itemHash, w.itemHash);
        assertEq(artistId, w.artistId);
        assertEq(collection, collectionId);
        assertEq(uint8(kind), uint8(ItemKind.EDITION_MASTER));
        assertEq(uint8(seedPolicy), uint8(SeedPolicy.ARTIST));
        assertEq(royaltyRate, w.royaltyRate);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, tokenId + 1));
        stream.coreOf(tokenId + 1);
        auction.burn(stream, tokenId, 1);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, tokenId));
        stream.coreOf(tokenId);
    }

    function test_mint_artistSeedAndEditionMaster() public {
        PackageItem memory item = _item(1);
        item.seedPolicy = SeedPolicy.ARTIST;
        item.seed = keccak256("seed");
        item.kind = ItemKind.EDITION_MASTER;
        uint256 tokenId = _mint(item);
        assertEq(uint8(stream.work(tokenId).kind), uint8(ItemKind.EDITION_MASTER));
        assertEq(uint8(stream.work(tokenId).seedPolicy), uint8(SeedPolicy.ARTIST));
    }

    function test_mint_vrfNeedsDeliveredSeed() public {
        PackageItem memory item = _item(1);
        item.seedPolicy = SeedPolicy.VRF;
        bytes32 itemHash = WorksHashing.itemHash(item);
        bytes memory data = _request(item);
        vm.expectRevert(abi.encodeWithSelector(IStream.SeedNotDelivered.selector, itemHash));
        auction.start(stream, data);
        entropy.deliver(itemHash, keccak256("vrf"));
        (uint256 tokenId,) = auction.start(stream, data);
        assertEq(uint8(stream.work(tokenId).seedPolicy), uint8(SeedPolicy.VRF));
    }

    function test_mint_vrfRejectedWithoutEntropyModule() public {
        Stream noVrf = _deploy(
            address(registry), address(artists), address(econ), address(0), address(renderer)
        );
        _map(address(noVrf), noVrf.setAdmittedMinter.selector, Roles.SUCCESSOR_SETTER);
        _map(address(noVrf), noVrf.createCollection.selector, Roles.PLATFORM);
        vm.prank(governor);
        noVrf.setAdmittedMinter(address(auction), true);
        vm.prank(platform);
        noVrf.createCollection("c", bytes32(0));
        PackageItem memory item = _item(1);
        item.seedPolicy = SeedPolicy.VRF;
        bytes memory data = _request(item);
        vm.expectRevert(IStream.InvalidSeedPolicy.selector);
        auction.start(noVrf, data);
    }

    function test_mint_revertsForUnadmittedCaller() public {
        bytes memory data = _request(_item(1));
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, outsider));
        stream.mint(outsider, 0, 1, data);
    }

    function test_mint_revertsForWrongShape() public {
        bytes memory data = _request(_item(1));
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.startRaw(stream, outsider, 0, 1, data);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.startRaw(stream, address(auction), 1, 1, data);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.startRaw(stream, address(auction), 0, 2, data);
    }

    function test_mint_revertsForWrongAdapterKind() public {
        auction.setSaleKind(SaleKind.FIXED_PRICE);
        bytes memory data = _request(_item(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintTarget.SaleKindMismatch.selector,
                SaleKind.ENGLISH_AUCTION,
                SaleKind.FIXED_PRICE
            )
        );
        auction.start(stream, data);
    }

    /// @dev `_consume` forwards `data[32:]` as `consume`'s arguments without re-encoding. This
    ///      pins the layout it relies on: after the leading offset word, the encoding of a
    ///      `StreamMintRequest` is byte for byte the encoding of `(packageRoot, item, proof,
    ///      move)`, for any number of parties, payees, proof nodes and signature bytes.
    function testFuzz_mintRequestEncodesAsConsumeArguments(
        uint8 parties,
        uint8 proofLength,
        uint8 signatureLength
    ) public view {
        PackageItem memory item = _item(1);
        item.parties = new Party[](bound(parties, 1, 16));
        for (uint256 i; i < item.parties.length; ++i) {
            item.parties[i] = Party(address(uint160(0x1000 + i)), PartyRole.COLLABORATOR);
        }
        bytes32[] memory proof = new bytes32[](bound(proofLength, 0, 32));
        for (uint256 i; i < proof.length; ++i) {
            proof[i] = keccak256(abi.encode(i));
        }
        MoveAuthorization memory move =
            MoveAuthorization(9, 1 days, new bytes(bound(signatureLength, 0, 130)));
        bytes memory request = abi.encode(StreamMintRequest(keccak256("root"), item, proof, move));
        bytes memory arguments = abi.encode(keccak256("root"), item, proof, move);
        assertEq(uint256(bytes32(request)), 32);
        assertEq(request.length, arguments.length + 32);
        assertEq(keccak256(_tail(request)), keccak256(arguments));
        assertEq(
            abi.encodeCall(IPackageRegistry.consume, (keccak256("root"), item, proof, move)),
            bytes.concat(IPackageRegistry.consume.selector, _tail(request))
        );
    }

    function _tail(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 32);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 32];
        }
    }

    function test_mint_revertsForMalformedData() public {
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.start(stream, new bytes(159));
        bytes memory data = _request(_item(1));
        assembly ("memory-safe") {
            mstore(add(data, 0x20), 0x40)
        }
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.start(stream, data);
    }

    function test_mint_revertsForStreamRuleBreaks() public {
        PackageItem memory item = _item(1);
        item.sale.saleKind = SaleKind.FIXED_PRICE;
        _expectInvalid(item, abi.encodeWithSelector(IStream.InvalidItemSale.selector));

        item = _item(1);
        item.sale.params = hex"01";
        _expectInvalid(item, abi.encodeWithSelector(IStream.InvalidItemSale.selector));

        item = _item(1);
        item.parties = new Party[](0);
        _expectInvalid(item, abi.encodeWithSelector(IStream.InvalidLeadArtist.selector));

        item = _item(1);
        item.collectionId = 99;
        _expectInvalid(item, abi.encodeWithSelector(IStream.UnknownCollection.selector, 99));

        item = _item(1);
        item.seedPolicy = SeedPolicy.ARTIST;
        _expectInvalid(item, abi.encodeWithSelector(IStream.InvalidSeedPolicy.selector));

        item = _item(1);
        item.seed = keccak256("stray");
        _expectInvalid(item, abi.encodeWithSelector(IStream.InvalidSeedPolicy.selector));

        item = _item(1);
        item.seedPolicy = SeedPolicy.VRF;
        item.seed = keccak256("stray");
        _expectInvalid(item, abi.encodeWithSelector(IStream.InvalidSeedPolicy.selector));

        // A license ID `WorkRecords` would refuse, so the work could never open.
        string[4] memory badIds = ["", "CC BY 4.0", "cc_by", string(new bytes(65))];
        for (uint256 i; i < badIds.length; ++i) {
            item = _item(1);
            item.license.spdxId = badIds[i];
            _expectInvalid(item, abi.encodeWithSelector(IStream.InvalidLicenseId.selector));
        }
    }

    /// @dev SPDX IDs keep their original case, so the canonical `CC0-1.0` mints.
    function test_mint_acceptsMixedCaseLicenseId() public {
        PackageItem memory item = _item(1);
        item.license = _license("CC0-1.0");
        _mint(item);
        item = _item(2);
        item.license = _license("LicenseRef-6529.Works+1");
        _mint(item);
    }

    /// @dev Covers the `reentrancy-no-eth` triage row: even if the (trusted, immutable)
    ///      registry re-entered `mint` through an admitted adapter during `consume`, nothing
    ///      read before the call is used after it, so IDs and serials stay consistent. The
    ///      inner mint takes ID 1 and serial 1; the outer one ID 2 and serial 2.
    function test_mint_reentrantRegistryKeepsCountersConsistent() public {
        PackageItem memory outer = _item(1);
        PackageItem memory inner = _item(2);
        registry.setReentry(
            address(auction), abi.encodeCall(auction.start, (stream, _request(inner)))
        );
        (uint256 tokenId,) = auction.start(stream, _request(outer));
        assertEq(tokenId, 2);
        assertEq(stream.totalMinted(), 2);
        assertEq(stream.work(1).itemHash, WorksHashing.itemHash(inner));
        assertEq(stream.work(2).itemHash, WorksHashing.itemHash(outer));
        assertEq(stream.work(1).serial, 1);
        assertEq(stream.work(2).serial, 2);
        assertEq(stream.collection(collectionId).minted, 2);
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
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.start(stream, data);
        registry.setArtistOverride(uint256(type(uint160).max) + 1);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.start(stream, data);
    }

    function test_mint_revertsForUnusableEconomics() public {
        bytes memory data = _request(_item(1));
        WorkTerms memory bad = _defaultTerms();
        bad.royaltyRate = 100_001;
        _expectBadTerms(bad, data);
        bad = _defaultTerms();
        bad.feeShare = 100_000;
        _expectBadTerms(bad, data);
        bad = _defaultTerms();
        bad.feeRecipient = address(0);
        _expectBadTerms(bad, data);
        bad = _defaultTerms();
        bad.feeRecipient = seller;
        _expectBadTerms(bad, data);
    }

    /// @dev The seller wallet is derived from the item's payees by the split factory, which
    ///      validates the list: a malformed one fails the start with the factory's error.
    function test_mint_sellerIsThePayeesWallet() public {
        PackageItem memory item = _item(1);
        item.payees = new ISplitWallet.Payee[](2);
        item.payees[0] = ISplitWallet.Payee(0, address(0x1000), 40_000);
        item.payees[1] = ISplitWallet.Payee(0, address(0x2000), 60_000);
        (, PrimaryTerms memory terms) = auction.start(stream, _request(item));
        assertEq(terms.seller, _sellerOf(item.payees));
        assertEq(stream.work(1).seller, _sellerOf(item.payees));
        assertTrue(terms.seller != seller);

        item = _item(2);
        item.payees[0].share = 99_999;
        bytes memory data = _request(item);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.SharesDoNotSum.selector, 99_999));
        auction.start(stream, data);
    }

    function test_mint_noFeeMeansSellerReceivesRoyalties() public {
        econ.setTerms(WorkTerms(seller, address(0), 0, address(0), 6_529));
        uint256 tokenId = _mint(1);
        (address receiver, uint256 amount) = stream.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, seller);
        assertEq(amount, 0.06529 ether);
        assertEq(stream.primaryTerms(tokenId, "").feeRecipient, address(0));
    }

    /// @dev Stream does not consult the currency allowlist; the adapter does, when it locks
    ///      the currency, so a blocked currency is not Stream's revert.
    function test_mint_leavesCurrencyCheckToAdapter() public {
        PackageItem memory item = _item(1);
        item.sale.currency = address(0xBEEF);
        econ.setBlocked(address(0xBEEF), true);
        (, PrimaryTerms memory terms) = auction.start(stream, _request(item));
        assertEq(terms.currency, address(0xBEEF));
    }

    // ----------------------------------------------------------------------- primaryTerms

    function test_primaryTerms_previewMatchesMint() public {
        bytes memory data = _request(_item(1));
        PrimaryTerms memory preview = stream.primaryTerms(0, data);
        (, PrimaryTerms memory terms) = auction.start(stream, data);
        assertEq(abi.encode(preview), abi.encode(terms));
    }

    function test_primaryTerms_mintedTokenKeepsLockedTerms() public {
        PackageItem memory first = _item(1);
        first.sale.currency = address(0xC0FFEE);
        (, PrimaryTerms memory locked) = auction.start(stream, _request(first));
        address otherFee = makeAddr("otherFee");
        econ.setTerms(WorkTerms(seller, otherFee, 10_000, address(0), 6_529));
        (, PrimaryTerms memory second) = auction.start(stream, _request(_item(2)));
        assertEq(second.feeRecipient, otherFee);

        // The adapter owns the currency: only the sale kind, seller, fee and creator are set.
        PrimaryTerms memory read = stream.primaryTerms(1, "");
        assertEq(read.saleKind, SaleKind.ENGLISH_AUCTION);
        assertEq(read.currency, address(0));
        assertEq(read.price, 0);
        assertEq(read.seller, locked.seller);
        assertEq(read.feeRecipient, locked.feeRecipient);
        assertEq(read.feeShare, locked.feeShare);
        assertEq(read.creator, artist);
        assertEq(stream.primaryTerms(2, "garbage").feeShare, 10_000);
        assertEq(stream.primaryTerms(2, "").feeRecipient, otherFee);
        assertEq(stream.work(2).royaltyReceiver, _royaltyWallet(seller, otherFee, 10_000));

        // The creator is resolved when read, so recovery redirects a no-bid return.
        address recovered = makeAddr("recovered");
        artists.setAuthority(uint256(uint160(artist)), recovered);
        assertEq(stream.primaryTerms(1, "").creator, recovered);
    }

    function test_primaryTerms_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, 1));
        stream.primaryTerms(1, "");
        PackageItem memory item = _item(1);
        item.parties[0] = Party(makeAddr("stranger"), PartyRole.ARTIST);
        bytes memory data = _request(item);
        vm.expectRevert(IStream.InvalidLeadArtist.selector);
        stream.primaryTerms(0, data);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        stream.primaryTerms(0, new bytes(10));
    }

    // ---------------------------------------------------------------------- primary sale

    function test_markPrimarySettled_byMintingAdapterOnly() public {
        _mint(1);
        _mint(2);
        MockSaleAdapter other = new MockSaleAdapter(SaleKind.ENGLISH_AUCTION);
        vm.prank(governor);
        stream.setAdmittedMinter(address(other), true);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotMintingAdapter.selector, address(other)));
        other.settle(stream, 1);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotMintingAdapter.selector, outsider));
        vm.prank(outsider);
        stream.markPrimarySettled(1);

        vm.expectEmit(address(stream));
        emit IStream.PrimarySaleSettled(1);
        auction.settle(stream, 1);
        assertTrue(stream.primarySaleSettled(1));
        assertFalse(stream.primarySaleSettled(2));
        // Settled before delivery: a pending claim does not block the edition.
        assertEq(stream.ownerOf(1), address(auction));
        vm.recordLogs();
        auction.settle(stream, 1);
        assertEq(vm.getRecordedLogs().length, 0);

        auction.burn(stream, 2, 1);
        assertFalse(stream.primarySaleSettled(2));
        assertFalse(stream.primarySaleSettled(3));
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, 3));
        auction.settle(stream, 3);
    }

    function test_transfersDoNotSettle() public {
        _mint(1);
        auction.deliver(address(stream), 1, makeAddr("collector"));
        assertFalse(stream.primarySaleSettled(1));
    }

    // -------------------------------------------------------------------------------- burn

    function test_burn_leavesGapAndCountsSupply() public {
        _mint(1);
        _mint(2);
        vm.expectEmit(address(stream));
        emit Transfer(address(auction), address(0), 1);
        auction.burn(stream, 1, 1);
        assertEq(stream.totalMinted(), 2);
        assertEq(stream.totalSupply(), 1);
        assertEq(stream.balanceOf(address(auction)), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        stream.ownerOf(1);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, 1));
        stream.work(1);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, 1));
        stream.artistOf(1);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, 1));
        stream.royaltyInfo(1, 1 ether);
        assertEq(_mint(3), 3);
    }

    /// @dev Curation review: an upheld dispute burns the copier's work; releasing its content
    ///      hash lets the real artist mint the same media, and tombstones the copier's item.
    function test_releaseContent_afterBurnLetsTheRealArtistMint() public {
        PackageItem memory copy = _item(1);
        bytes32 copyHash = WorksHashing.itemHash(copy);
        uint256 tokenId = _mint(copy);

        PackageItem memory original = _item(1);
        original.recordFileId = keccak256("the original record");
        bytes memory data = _request(original);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockPackageRegistry.ContentUsed.selector, copy.contentHash, copyHash
            )
        );
        auction.start(stream, data);

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotBurned.selector, tokenId));
        stream.releaseContent(tokenId, copy.contentHash, 7);
        auction.burn(stream, tokenId, 1);

        vm.prank(governor);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockPackageRegistry.NotConsumedBy.selector, keccak256("other"), copyHash
            )
        );
        stream.releaseContent(tokenId, keccak256("other"), 7);

        // Governed (PARAMETER_SETTER): nobody else may release.
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.releaseContent(tokenId, copy.contentHash, 7);

        vm.expectEmit(address(registry));
        emit MockPackageRegistry.ContentReleased(copy.contentHash, copyHash, 7);
        vm.prank(governor);
        stream.releaseContent(tokenId, copy.contentHash, 7);
        assertTrue(registry.isTombstoned(copyHash));
        assertEq(registry.consumedItemOf(copy.contentHash), bytes32(0));

        (uint256 realId,) = auction.start(stream, data);
        assertEq(realId, tokenId + 1);
        assertEq(registry.consumedItemOf(copy.contentHash), WorksHashing.itemHash(original));
    }

    function test_releaseContent_reverts() public {
        vm.startPrank(governor);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotBurned.selector, 0));
        stream.releaseContent(0, bytes32(0), 7);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotBurned.selector, 1));
        stream.releaseContent(1, bytes32(0), 7);
        vm.stopPrank();
        uint256 tokenId = _mint(1);
        auction.burn(stream, tokenId, 1);
        bytes32 contentHash = _item(1).contentHash;
        vm.startPrank(governor);
        stream.releaseContent(tokenId, contentHash, 7);
        // A second release finds nothing to free.
        bytes32 itemHash = WorksHashing.itemHash(_item(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                MockPackageRegistry.NotConsumedBy.selector, contentHash, itemHash
            )
        );
        stream.releaseContent(tokenId, contentHash, 7);
        vm.stopPrank();
    }

    /// @dev After a sale nothing is confiscated (ADR 0001 section 12): a settled token can
    ///      never be burned, even back in the minting adapter's custody.
    function test_burn_neverAfterSettlement() public {
        _mint(1);
        auction.settle(stream, 1);
        vm.expectRevert(abi.encodeWithSelector(IStream.SaleAlreadySettled.selector, 1));
        auction.burn(stream, 1, 1);
        address collector = makeAddr("collector");
        auction.deliver(address(stream), 1, collector);
        vm.prank(collector);
        stream.transferFrom(collector, address(auction), 1);
        vm.expectRevert(abi.encodeWithSelector(IStream.SaleAlreadySettled.selector, 1));
        auction.burn(stream, 1, 1);
    }

    /// @dev Removal stops new mints, not the adapter's cancel: it still burns the unsettled
    ///      token it minted, as it still settles.
    function test_burn_byRemovedMintingAdapter() public {
        _mint(1);
        _mint(2);
        vm.prank(governor);
        stream.setAdmittedMinter(address(auction), false);
        bytes memory data = _request(_item(3));
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(auction))
        );
        auction.start(stream, data);
        auction.burn(stream, 1, 1);
        auction.settle(stream, 2);
        assertEq(stream.totalSupply(), 1);
        assertTrue(stream.primarySaleSettled(2));
    }

    /// @dev Only the adapter that minted a token may burn it, even if another admitted adapter
    ///      holds it.
    function test_burn_onlyByMintingAdapter() public {
        _mint(1);
        MockSaleAdapter other = new MockSaleAdapter(SaleKind.ENGLISH_AUCTION);
        vm.prank(governor);
        stream.setAdmittedMinter(address(other), true);
        auction.deliver(address(stream), 1, address(other));
        vm.expectRevert(abi.encodeWithSelector(IStream.NotMintingAdapter.selector, address(other)));
        other.burn(stream, 1, 1);
    }

    function test_burn_reverts() public {
        _mint(1);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
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
        vm.expectRevert(abi.encodeWithSelector(IStream.NotMintingAdapter.selector, outsider));
        stream.burn(1, 1);
    }

    // ------------------------------------------------------------------------- collections

    function test_createCollection() public {
        vm.expectEmit(address(stream));
        emit IStream.CollectionCreated(2, unicode"Ünïcode", keccak256("m"));
        vm.prank(platform);
        assertEq(stream.createCollection(unicode"Ünïcode", keccak256("m")), 2);
        IStream.Collection memory c = stream.collection(2);
        assertEq(c.name, unicode"Ünïcode");
        assertEq(c.metadataHash, keccak256("m"));
        assertEq(c.minted, 0);
        assertEq(stream.collectionCount(), 2);
    }

    function test_createCollection_reverts() public {
        vm.startPrank(platform);
        vm.expectRevert(IStream.InvalidCollectionName.selector);
        stream.createCollection("", bytes32(0));
        vm.expectRevert(IStream.InvalidCollectionName.selector);
        stream.createCollection(string(new bytes(257)), bytes32(0));
        vm.expectRevert(IStream.InvalidCollectionName.selector);
        stream.createCollection(string(bytes(hex"c0af")), bytes32(0));
        vm.stopPrank();
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.createCollection("x", bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownCollection.selector, 0));
        stream.collection(0);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownCollection.selector, 2));
        stream.collection(2);
    }

    // ----------------------------------------------------------------------------- royalty

    function test_royaltyInfo_exactAtLaunchRate() public {
        _mint(1);
        (address receiver, uint256 amount) = stream.royaltyInfo(1, 1 ether);
        assertEq(receiver, _defaultRoyaltyWallet());
        assertEq(amount, 0.06529 ether);
    }

    function test_royaltyInfo_receiverIsCanonicalForEitherAddressOrder() public {
        address low = address(1);
        address high = address(type(uint160).max);
        assertTrue(low < seller && seller < high);
        econ.setTerms(WorkTerms(seller, low, 25_000, address(0), 6_529));
        uint256 a = _mint(1);
        econ.setTerms(WorkTerms(seller, high, 25_000, address(0), 6_529));
        uint256 b = _mint(2);
        (address ra,) = stream.royaltyInfo(a, 1);
        (address rb,) = stream.royaltyInfo(b, 1);
        assertEq(ra, _royaltyWallet(seller, low, 25_000));
        assertEq(rb, _royaltyWallet(seller, high, 25_000));
        assertTrue(ra != rb);
    }

    /// @dev The receiver is exactly the royalty wallet the sale side pays: the real
    ///      `SplitFactory` deploys it at that address, salt zero, for the canonical list of the
    ///      fee recipient's share and the seller's rest; with no fee it is the seller itself.
    function testFuzz_royaltyInfo_isTheFactoryWallet(address payee, address fee, uint32 feeShare)
        public
    {
        vm.assume(payee != address(0) && fee != address(0));
        PackageItem memory item = _item(1);
        item.payees[0] = ISplitWallet.Payee(0, payee, 100_000);
        address sellerWallet = _sellerOf(item.payees);
        vm.assume(fee != sellerWallet);
        feeShare = uint32(bound(feeShare, 1, 99_999));
        econ.setTerms(WorkTerms(sellerWallet, fee, feeShare, address(0), 6_529));
        uint256 tokenId = _mint(item);
        assertEq(stream.work(tokenId).seller, sellerWallet);
        (address receiver,) = stream.royaltyInfo(tokenId, 1 ether);

        ISplitWallet.Payee[] memory payees = new ISplitWallet.Payee[](2);
        ISplitWallet.Payee memory feePayee = ISplitWallet.Payee(0, fee, feeShare);
        ISplitWallet.Payee memory sellerPayee =
            ISplitWallet.Payee(0, sellerWallet, 100_000 - feeShare);
        (payees[0], payees[1]) =
            fee < sellerWallet ? (feePayee, sellerPayee) : (sellerPayee, feePayee);
        address deployed = splitFactory.createWallet(payees, bytes32(0));
        assertEq(receiver, deployed);
        assertTrue(splitFactory.isWallet(receiver));
        assertEq(splitFactory.configOf(receiver), keccak256(abi.encode(payees)));
        assertEq(stream.work(tokenId).royaltyReceiver, deployed);
    }

    function test_royaltyInfo_noFeeIsTheSeller() public {
        econ.setTerms(WorkTerms(seller, feeRecipient, 0, address(0), 6_529));
        uint256 tokenId = _mint(1);
        (address receiver,) = stream.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, seller);
        assertFalse(splitFactory.isWallet(receiver));
    }

    function testFuzz_royaltyInfo_matchesMulDiv(uint256 price, uint32 rate) public {
        rate = uint32(bound(rate, 0, 100_000));
        _bindMocks();
        _mint(1);
        recordsMock.setRoyaltyRate(stream, 1, rate);
        (address receiver, uint256 amount) = stream.royaltyInfo(1, price);
        assertEq(receiver, _defaultRoyaltyWallet());
        assertEq(amount, Math.mulDiv(price, rate, 100_000));
        assertLe(amount, price);
    }

    /// @dev RC1's Medium finding: `royaltyInfo` returned zero when about 3M gas did not remain.
    ///      Here, at any gas limit, the call either reverts or returns the exact royalty.
    function testFuzz_royaltyInfo_neverZeroForLackOfGas(uint256 gasLimit, uint256 price) public {
        gasLimit = bound(gasLimit, 0, 80_000);
        price = bound(price, 100_000, type(uint128).max);
        _mint(1);
        RoyaltyProbe probe = new RoyaltyProbe();
        (bool ok, address receiver, uint256 amount) =
            probe.probe(address(stream), 1, price, gasLimit);
        if (ok) {
            assertEq(receiver, _defaultRoyaltyWallet());
            assertEq(amount, Math.mulDiv(price, 6_529, 100_000));
            assertGt(amount, 0);
        }
    }

    function test_royaltyInfo_succeedsWithModestBudget() public {
        _mint(1);
        RoyaltyProbe probe = new RoyaltyProbe();
        (bool ok,, uint256 amount) = probe.probe(address(stream), 1, 1 ether, 60_000);
        assertTrue(ok);
        assertEq(amount, 0.06529 ether);
    }

    function test_royaltyInfo_revertsForUnknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, 1));
        stream.royaltyInfo(1, 1 ether);
    }

    // ------------------------------------------------------------------------------ hooks

    function test_setRoyaltyRate_fromRecords() public {
        _bindMocks();
        _mint(1);
        vm.expectEmit(address(stream));
        emit IStream.RoyaltyRateChanged(1, 6_529, 10_000);
        recordsMock.setRoyaltyRate(stream, 1, 10_000);
        IStream.WorkCore memory w = stream.work(1);
        assertEq(w.royaltyReceiver, _defaultRoyaltyWallet());
        assertEq(w.royaltyRate, 10_000);
        vm.expectRevert(abi.encodeWithSelector(IStream.InvalidRoyaltyRate.selector, 100_001));
        recordsMock.setRoyaltyRate(stream, 1, 100_001);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, 2));
        recordsMock.setRoyaltyRate(stream, 2, 1);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnboundCaller.selector, outsider));
        stream.setRoyaltyRate(1, 1);
    }

    function test_emitMetadataUpdate_fromRecords() public {
        _bindMocks();
        vm.expectEmit(address(stream));
        emit MetadataUpdate(4);
        recordsMock.refresh(stream, 4, 4);
        vm.expectEmit(address(stream));
        emit BatchMetadataUpdate(1, 9);
        recordsMock.refresh(stream, 1, 9);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnboundCaller.selector, outsider));
        stream.emitMetadataUpdate(1, 1);
    }

    function test_hooks_revertBeforeBinding() public {
        _mint(1);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnboundCaller.selector, address(this)));
        stream.setRoyaltyRate(1, 1);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnboundCaller.selector, address(this)));
        stream.emitMetadataUpdate(1, 1);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnboundCaller.selector, address(this)));
        stream.linkEdition(1, 1);
    }

    // ---------------------------------------------------------------------------- binding

    function test_bind_oncePerTargetWithEvents() public {
        MockWorkRecords r = new MockWorkRecords(address(stream));
        MockEditions e = new MockEditions(address(stream));
        vm.expectEmit(address(stream));
        emit IStream.Bound("WORK_RECORDS", address(r));
        stream.bindWorkRecords(address(r));
        assertEq(stream.workRecords(), address(r));
        assertEq(stream.editions(), address(0));
        vm.expectEmit(address(stream));
        emit IStream.Bound("EDITIONS", address(e));
        stream.bindEditions(address(e));
        assertEq(stream.editions(), address(e));
        vm.expectRevert(
            abi.encodeWithSelector(IStream.AlreadyBound.selector, bytes32("WORK_RECORDS"))
        );
        stream.bindWorkRecords(address(r));
        vm.expectRevert(abi.encodeWithSelector(IStream.AlreadyBound.selector, bytes32("EDITIONS")));
        stream.bindEditions(address(e));
    }

    function test_bind_reverts() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        stream.bindWorkRecords(eoa);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        stream.bindEditions(eoa);
        // Each target must answer ERC-165 for its own interface.
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(editionsMock))
        );
        stream.bindWorkRecords(address(editionsMock));
        MockWorkRecords r = new MockWorkRecords(address(stream));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(r)));
        stream.bindEditions(address(r));
        // A satellite serving another Stream is refused: the bind is one-shot.
        MockWorkRecords foreignRecords = new MockWorkRecords(address(econ));
        MockEditions foreignEditions = new MockEditions(address(econ));
        vm.expectRevert(
            abi.encodeWithSelector(IStream.InvalidBinding.selector, address(foreignRecords))
        );
        stream.bindWorkRecords(address(foreignRecords));
        vm.expectRevert(
            abi.encodeWithSelector(IStream.InvalidBinding.selector, address(foreignEditions))
        );
        stream.bindEditions(address(foreignEditions));
        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(r)));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, delegated));
        stream.bindWorkRecords(delegated);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.bindWorkRecords(address(r));
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.bindEditions(address(editionsMock));
    }

    // ---------------------------------------------------------------------------- editions

    function test_linkEdition() public {
        _bindMocks();
        PackageItem memory item = _item(1);
        item.kind = ItemKind.EDITION_MASTER;
        _mint(item);
        (address e, uint256 id) = stream.editionOf(1);
        assertEq(e, address(0));
        assertEq(id, 0);
        auction.settle(stream, 1);
        vm.expectEmit(address(stream));
        emit IStream.EditionLinked(1, address(editionsMock), 1);
        vm.expectEmit(address(stream));
        emit MetadataUpdate(1);
        editionsMock.link(stream, 1, 1);
        (e, id) = stream.editionOf(1);
        assertEq(e, address(editionsMock));
        assertEq(id, 1);
        vm.expectRevert(abi.encodeWithSelector(IStream.EditionLinkInvalid.selector, 1));
        editionsMock.link(stream, 1, 1);
    }

    function test_linkEdition_reverts() public {
        _bindMocks();
        _mint(1);
        PackageItem memory master = _item(2);
        master.kind = ItemKind.EDITION_MASTER;
        _mint(master);
        // The master's primary sale has not settled.
        vm.expectRevert(abi.encodeWithSelector(IStream.EditionLinkInvalid.selector, 2));
        editionsMock.link(stream, 2, 2);
        auction.settle(stream, 1);
        auction.settle(stream, 2);
        vm.expectRevert(abi.encodeWithSelector(IStream.EditionLinkInvalid.selector, 1));
        editionsMock.link(stream, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(IStream.EditionLinkInvalid.selector, 2));
        editionsMock.link(stream, 2, 3);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, 5));
        editionsMock.link(stream, 5, 5);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnboundCaller.selector, outsider));
        stream.linkEdition(2, 2);
    }

    // --------------------------------------------------------------------------- rendering

    function test_tokenURI_forwardsToDefaultThenPin() public {
        _bindMocks();
        _mint(1);
        assertEq(stream.rendererOf(1), address(renderer));
        assertEq(stream.tokenURI(1), renderer.tokenURI(address(stream), 1));
        MockRenderer pinned = new MockRenderer("pinned");
        recordsMock.setPin(1, address(pinned));
        assertEq(stream.rendererOf(1), address(pinned));
        assertEq(stream.tokenURI(1), pinned.tokenURI(address(stream), 1));
    }

    function test_tokenURI_revertsForUnknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, 1));
        stream.tokenURI(1);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, 1));
        stream.rendererOf(1);
    }

    function test_setDefaultRenderer() public {
        _bindMocks();
        _mint(1);
        _mint(2);
        MockRenderer next = new MockRenderer("next");
        vm.expectEmit(address(stream));
        emit IStream.DefaultRendererSet(address(renderer), address(next), address(next).codehash);
        vm.expectEmit(address(stream));
        emit BatchMetadataUpdate(1, 2);
        vm.prank(governor);
        stream.setDefaultRenderer(address(renderer), address(next), address(next).codehash);
        assertEq(stream.defaultRenderer(), address(next));
        assertEq(stream.rendererOf(1), address(next));
        assertEq(editionsMock.notifiedAll(), 1);
    }

    function test_setDefaultRenderer_reverts() public {
        MockRenderer next = new MockRenderer("next");
        bytes32 codeHash = address(next).codehash;
        vm.startPrank(governor);
        vm.expectRevert(IStream.ExpectedValueMismatch.selector);
        stream.setDefaultRenderer(address(next), address(next), codeHash);
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        stream.setDefaultRenderer(address(renderer), eoa, codeHash);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(econ))
        );
        stream.setDefaultRenderer(address(renderer), address(econ), address(econ).codehash);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(next))
        );
        stream.setDefaultRenderer(address(renderer), address(next), keccak256("wrong"));
        vm.stopPrank();
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.setDefaultRenderer(address(renderer), address(next), codeHash);
    }

    function test_setDefaultRenderer_quietBeforeFirstMintAndBinding() public {
        MockRenderer next = new MockRenderer("next");
        vm.recordLogs();
        vm.prank(governor);
        stream.setDefaultRenderer(address(renderer), address(next), address(next).codehash);
        assertEq(vm.getRecordedLogs().length, 1);
    }

    // ------------------------------------------------------------------------- marketplace

    function test_contractURI() public {
        vm.expectEmit(address(stream));
        emit IStream.ContractURISet("", "ipfs://contract");
        vm.expectEmit(address(stream));
        emit IStream.ContractURIUpdated();
        vm.prank(governor);
        stream.setContractURI("ipfs://contract");
        assertEq(stream.contractURI(), "ipfs://contract");
        vm.expectEmit(address(stream));
        emit IStream.ContractURISet("ipfs://contract", "ipfs://next");
        vm.prank(governor);
        stream.setContractURI("ipfs://next");
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.setContractURI("x");
    }

    function test_setOwner() public {
        address next = makeAddr("nextOwner");
        vm.expectEmit(address(stream));
        emit IStream.OwnershipTransferred(marketOwner, next);
        vm.prank(governor);
        stream.setOwner(marketOwner, next);
        assertEq(stream.owner(), next);
        vm.prank(governor);
        vm.expectRevert(IStream.ExpectedValueMismatch.selector);
        stream.setOwner(marketOwner, next);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        stream.setOwner(next, outsider);
    }

    function test_stateChangingFunctionsAreNonPayable() public {
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
        assertTrue(stream.supportsInterface(type(IStream).interfaceId));
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

    function _expectInvalid(PackageItem memory item, bytes memory reason) internal {
        bytes memory data = _request(item);
        vm.expectRevert(reason);
        auction.start(stream, data);
    }

    function _expectBadTerms(WorkTerms memory terms, bytes memory data) internal {
        econ.setTerms(terms);
        vm.expectRevert(IStream.InvalidWorkTerms.selector);
        auction.start(stream, data);
        econ.setTerms(_defaultTerms());
    }
}

/// @notice Stream's behaviour where the work-records satellite takes part: the license checks
///         at mint that keep every work openable, burns by the minting adapter, the one-shot
///         satellite bindings, edition links, and the rate `coreOf` reports after a re-rate.
contract StreamWithRecordsTest is RecordsFixture {
    /// Regression: F1 (M2) in the reviews of #22
    /// @dev A license ID `WorkRecords` would refuse never mints, so no license can leave a work
    ///      unopenable.
    function test_mint_refusesALicenseIdTheRecordsWouldRefuse() public {
        string[4] memory badIds = ["", "CC BY 4.0", "cc_by", string(new bytes(65))];
        for (uint256 i; i < badIds.length; ++i) {
            MediaFile[] memory media = _single(i, true);
            PackageItem memory item = _recordsItem(i, media);
            item.license = License(badIds[i], bytes32(0));
            bytes memory data = _request(item);
            vm.expectRevert(IStream.InvalidLicenseId.selector);
            auction.start(stream, data);
        }
    }

    /// Regression: F2 (M3) in the reviews of #22
    /// @dev A removed adapter still cancels and burns the disputed token it minted.
    function test_burn_aRemovedAdapterStillBurnsItsDisputedToken() public {
        uint256 tokenId = _mint(1);
        vm.prank(governor);
        stream.setAdmittedMinter(address(auction), false);
        auction.burn(stream, tokenId, 1);
        assertEq(stream.totalSupply(), 0);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, tokenId));
        stream.work(tokenId);
    }

    /// Regression: F2b (M3) in the reviews of #22
    /// @dev An admitted adapter that did not mint a token cannot burn it, even while
    ///      it holds it.
    function test_burn_refusesAnAdmittedAdapterThatDidNotMint() public {
        uint256 tokenId = _mint(1);
        MockSaleAdapter other = new MockSaleAdapter(SaleKind.ENGLISH_AUCTION);
        vm.prank(governor);
        stream.setAdmittedMinter(address(other), true);
        address collector = makeAddr("collector");
        auction.deliver(address(stream), tokenId, collector);
        vm.prank(collector);
        stream.transferFrom(collector, address(other), tokenId);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotMintingAdapter.selector, address(other)));
        other.burn(stream, tokenId, 1);
        assertEq(stream.totalSupply(), 1);
    }

    /// Regression: F3 (L1) in the reviews of #22
    /// @dev A one-shot bind refuses a satellite serving another Stream and accepts the
    ///      fresh Stream's own.
    function test_bind_refusesASatelliteOfAnotherStream() public {
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

    /// Regression: F4 in the reviews of #22
    /// @dev Stream links an edition only to a settled master (D14, defence in depth).
    function test_linkEdition_needsASettledMaster() public {
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

    /// Regression: F5 (L2) in the reviews of #22
    /// @dev A zero fee may come with a zero fee recipient, and the start reports it;
    ///      a nonzero fee needs a recipient.
    function test_mint_aZeroFeeAllowsAZeroRecipient() public {
        econ.setTerms(WorkTerms(seller, address(0), 0, address(0), 6_529));
        (uint256 tokenId, PrimaryTerms memory terms) = auction.start(stream, _request(_item(1)));
        assertEq(terms.feeRecipient, address(0));
        assertEq(terms.feeShare, 0);
        assertEq(stream.primaryTerms(tokenId, "").feeRecipient, address(0));
        (address receiver,) = stream.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, seller);

        econ.setTerms(WorkTerms(seller, address(0), 1, address(0), 6_529));
        bytes memory data = _request(_item(2));
        vm.expectRevert(IStream.InvalidWorkTerms.selector);
        auction.start(stream, data);
    }

    /// Regression: L5 in the reviews of #22
    /// @dev The master's current rate is readable through `coreOf`, so an edition created
    ///      after a rate change can inherit it.
    function test_coreOf_reportsTheCurrentRate() public {
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

    /// Regression: a nit (S3) in the reviews of #22
    /// @dev The license-ID length bound is exact. 64 valid characters mint, 65 do not.
    function test_mint_licenseIdLengthBoundIsExact() public {
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
        vm.expectRevert(IStream.InvalidLicenseId.selector);
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

    /// Regression: the reviews of #22
    /// @dev Re-admission keeps the index, so a removed and re-admitted adapter still
    ///      burns its token; a never-admitted holder (index 0) cannot.
    function test_burn_readmittedAdapterBurnsAndNeverAdmittedCannot() public {
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
            abi.encodeWithSelector(IStream.NotMintingAdapter.selector, address(stranger))
        );
        stranger.burn(stream, second, 1);
    }

    /// Regression: the reviews of #22
    /// @dev The minting adapter cannot burn after settlement.
    function test_burn_refusedAfterSettlement() public {
        uint256 tokenId = _mint(1);
        auction.settle(stream, tokenId);
        vm.expectRevert(abi.encodeWithSelector(IStream.SaleAlreadySettled.selector, tokenId));
        auction.burn(stream, tokenId, 1);
    }
}
