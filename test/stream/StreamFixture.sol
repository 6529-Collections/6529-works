// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SplitFactory } from "src/economics/SplitFactory.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Roles } from "src/governance/Roles.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionFormat,
    EditionTerms,
    ItemKind,
    License,
    MoveAuthorization,
    PackageItem,
    Party,
    PartyRole,
    SaleTerms,
    SeedPolicy,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Stream } from "src/stream/Stream.sol";
import {
    MockArtistRegistry,
    MockEconomics,
    MockEditions,
    MockEntropy,
    MockPackageRegistry,
    MockRenderer,
    MockSaleAdapter,
    MockWorkRecords
} from "../mocks/stream/StreamMocks.sol";

/// @notice Deploys 6529 Stream behind an OpenZeppelin AccessManager with mocks for every other
///         lane's contract, and offers item and mint helpers.
abstract contract StreamFixture is Test {
    address internal governor = makeAddr("governor");
    address internal platform = makeAddr("platform");
    address internal outsider = makeAddr("outsider");
    address internal marketOwner = makeAddr("marketOwner");
    /// @dev The seller wallet of `_item`'s payees (the artist alone), set in `setUp`: Stream
    ///      derives it with the split factory.
    address internal seller;
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal royaltyWallet = makeAddr("royaltyWallet");

    uint256 internal artistKey = 0xA11CE;
    address internal artist;

    AccessManager internal manager;
    MockPackageRegistry internal registry;
    MockArtistRegistry internal artists;
    SplitFactory internal splitFactory;
    MockEconomics internal econ;
    MockEntropy internal entropy;
    MockRenderer internal renderer;
    MockSaleAdapter internal auction;
    MockWorkRecords internal recordsMock;
    MockEditions internal editionsMock;
    Stream internal stream;

    uint256 internal collectionId;

    function setUp() public virtual {
        artist = vm.addr(artistKey);
        manager = new AccessManager(address(this));
        registry = new MockPackageRegistry();
        artists = new MockArtistRegistry();
        renderer = new MockRenderer("default");
        splitFactory = new SplitFactory(
            IArtistPayoutResolver(address(artists)), IReleaseVerifier(address(renderer))
        );
        seller = _sellerOf(_item(0).payees);
        econ = new MockEconomics(_defaultTerms(), address(splitFactory));
        entropy = new MockEntropy();
        auction = new MockSaleAdapter(SaleKind.ENGLISH_AUCTION);
        stream = new Stream(
            address(manager),
            address(registry),
            address(artists),
            address(econ),
            address(entropy),
            address(renderer),
            address(renderer).codehash,
            marketOwner
        );
        editionsMock = new MockEditions(address(stream));
        registry.bindStream(address(stream));
        _configureRoles();
        artists.register(artist);
        vm.prank(platform);
        collectionId = stream.createCollection("Genesis", keccak256("genesis"));
    }

    function _defaultTerms() internal view returns (WorkTerms memory) {
        return WorkTerms(seller, feeRecipient, 25_000, royaltyWallet, 6_529);
    }

    function _configureRoles() internal {
        _map(address(stream), stream.setAdmittedMinter.selector, Roles.SUCCESSOR_SETTER);
        _map(address(stream), stream.createCollection.selector, Roles.PLATFORM);
        _map(address(stream), stream.setContractURI.selector, Roles.PARAMETER_SETTER);
        _map(address(stream), stream.setOwner.selector, Roles.FUNDS_SETTER);
        _map(address(stream), stream.setDefaultRenderer.selector, Roles.SUCCESSOR_SETTER);
        manager.grantRole(Roles.PLATFORM, platform, 0);
        manager.grantRole(Roles.PARAMETER_SETTER, governor, 0);
        manager.grantRole(Roles.FUNDS_SETTER, governor, 0);
        manager.grantRole(Roles.SUCCESSOR_SETTER, governor, 0);
        vm.prank(governor);
        stream.setAdmittedMinter(address(auction), true);
    }

    function _map(address target, bytes4 selector, uint64 role) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(target, selectors, role);
    }

    /// @dev Binds a mock records satellite and the mock Editions (the test is the admin).
    function _bindMocks() internal {
        recordsMock = new MockWorkRecords(address(stream));
        stream.bindWorkRecords(address(recordsMock));
        stream.bindEditions(address(editionsMock));
    }

    /// @dev The royalty receiver Stream derives: the seller with no fee, else the salt-zero
    ///      wallet for the canonical `(feeRecipient, seller)` list.
    function _royaltyWallet(address sellerWallet, address fee, uint32 feeShare)
        internal
        view
        returns (address)
    {
        if (feeShare == 0) return sellerWallet;
        ISplitWallet.Payee[] memory payees = new ISplitWallet.Payee[](2);
        ISplitWallet.Payee memory a = ISplitWallet.Payee(0, fee, feeShare);
        ISplitWallet.Payee memory b =
            ISplitWallet.Payee(0, sellerWallet, Splits.DENOMINATOR - feeShare);
        (payees[0], payees[1]) = fee < sellerWallet ? (a, b) : (b, a);
        return splitFactory.walletFor(payees, bytes32(0));
    }

    /// @dev The seller wallet Stream derives for `payees`: the salt-zero split wallet.
    function _sellerOf(ISplitWallet.Payee[] memory payees) internal view returns (address) {
        return splitFactory.walletFor(payees, bytes32(0));
    }

    function _defaultRoyaltyWallet() internal view returns (address) {
        return _royaltyWallet(seller, feeRecipient, 25_000);
    }

    /// @dev A license whose text file is the one-chunk `text/plain` file of the ID's bytes
    ///      (the records fixture registers the texts its tests use).
    function _license(string memory spdx) internal pure returns (License memory) {
        return License(spdx, _textFileId(bytes(spdx)));
    }

    /// @dev The content-store file ID (`IContentStore.manifestId`) of a one-chunk `Identity`
    ///      `text/plain` file holding `text`, declaring `keccak256(text)` as its SHA-256 (the
    ///      store does not recompute it). No precompile is called, so the helper can sit in the
    ///      arguments of a call under `vm.prank` or `vm.expectRevert`.
    function _textFileId(bytes memory text) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(text);
        string memory mime = "text/plain";
        return keccak256(
            abi.encode(hashes, text.length, IContentStore.Encoding.Identity, mime, keccak256(text))
        );
    }

    /// @dev An ORIGINAL item by `artist` in the fixture collection; `salt` varies the content.
    function _item(uint256 salt) internal view returns (PackageItem memory item) {
        item.kind = ItemKind.ORIGINAL;
        item.collectionId = collectionId;
        item.contentHash = keccak256(abi.encode("content", salt));
        item.mediaHash = keccak256(abi.encode("media", salt));
        item.recordFileId = keccak256(abi.encode("record", salt));
        item.parties = new Party[](1);
        item.parties[0] = Party(artist, PartyRole.ARTIST);
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(uint256(uint160(artist)), address(0), 100_000);
        item.license = _license("cc0-1.0");
        item.seedPolicy = SeedPolicy.NONE;
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, address(0), "");
        item.edition = EditionTerms(EditionFormat.FIXED, 0, 0, 0, address(0), bytes32(0), "");
    }

    function _request(PackageItem memory item) internal pure returns (bytes memory) {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = keccak256("sibling0");
        proof[1] = keccak256("sibling1");
        return abi.encode(
            StreamMintRequest(
                keccak256("root"), item, proof, MoveAuthorization(7, 1 days, new bytes(65))
            )
        );
    }

    function _mint(PackageItem memory item) internal returns (uint256 tokenId) {
        (tokenId,) = auction.start(stream, _request(item));
    }

    function _mint(uint256 salt) internal returns (uint256 tokenId) {
        return _mint(_item(salt));
    }
}
