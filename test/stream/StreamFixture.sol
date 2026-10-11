// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Stream } from "src/stream/Stream.sol";
import { IStreamCore } from "src/stream/IStreamCore.sol";
import { WorkTerms, Payee } from "src/interfaces/types/EconomicsTypes.sol";
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
import { PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import {
    MockArtistRegistry,
    MockEconomics,
    MockEditions,
    MockPackageRegistry,
    MockRenderer,
    MockSaleAdapter,
    MockWorkRecords
} from "../mocks/stream/StreamMocks.sol";

/// @notice Role IDs mirrored from the governance lane's `src/governance/Roles.sol` (PR #7).
/// @dev TODO(integration): import `Roles` once the governance lane is merged.
library StreamRoles {
    uint64 internal constant ADMIN = 0;
    uint64 internal constant STORAGE_OPERATOR = 5;
    uint64 internal constant MINTER = 6;
    uint64 internal constant PLATFORM = 8;
    uint64 internal constant PARAMETER_SETTER = 9;
    uint64 internal constant FUNDS_SETTER = 10;
    uint64 internal constant SUCCESSOR_SETTER = 11;
}

/// @notice Deploys 6529 Stream behind an OpenZeppelin AccessManager with mocks for every other
///         lane's contract, and offers item and mint helpers.
abstract contract StreamFixture is Test {
    address internal governor = makeAddr("governor");
    address internal platform = makeAddr("platform");
    address internal outsider = makeAddr("outsider");
    address internal marketOwner = makeAddr("marketOwner");
    address internal seller = makeAddr("sellerWallet");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal royaltyWallet = makeAddr("royaltyWallet");

    uint256 internal artistKey = 0xA11CE;
    address internal artist;

    AccessManager internal manager;
    MockPackageRegistry internal registry;
    MockArtistRegistry internal artists;
    MockEconomics internal econ;
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
        econ = new MockEconomics(_defaultTerms());
        renderer = new MockRenderer("default");
        auction = new MockSaleAdapter(SaleKind.ENGLISH_AUCTION);
        stream = new Stream(
            address(manager),
            address(registry),
            address(artists),
            address(econ),
            address(renderer),
            marketOwner,
            _license("CC0-1.0")
        );
        _configureRoles();
        artists.register(artist);
        vm.prank(platform);
        collectionId = stream.createCollection("Genesis", keccak256("genesis"));
    }

    function _defaultTerms() internal view returns (WorkTerms memory) {
        return WorkTerms(seller, feeRecipient, 25_000, royaltyWallet, 6_529);
    }

    function _configureRoles() internal {
        _map(stream.mint.selector, StreamRoles.MINTER);
        _map(stream.burn.selector, StreamRoles.MINTER);
        _map(stream.createCollection.selector, StreamRoles.PLATFORM);
        _map(stream.setContractURI.selector, StreamRoles.PARAMETER_SETTER);
        _map(stream.setOwner.selector, StreamRoles.FUNDS_SETTER);
        _map(stream.setDefaultRenderer.selector, StreamRoles.SUCCESSOR_SETTER);
        manager.grantRole(StreamRoles.MINTER, address(auction), 0);
        manager.grantRole(StreamRoles.PLATFORM, platform, 0);
        manager.grantRole(StreamRoles.PARAMETER_SETTER, governor, 0);
        manager.grantRole(StreamRoles.FUNDS_SETTER, governor, 0);
        manager.grantRole(StreamRoles.SUCCESSOR_SETTER, governor, 0);
    }

    function _map(bytes4 selector, uint64 role) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(address(stream), selectors, role);
    }

    /// @dev Binds mock records and editions satellites (the test contract is the admin).
    function _bindSatellites() internal {
        recordsMock = new MockWorkRecords();
        editionsMock = new MockEditions();
        stream.bindRecords(address(recordsMock));
        stream.bindEditions(address(editionsMock));
    }

    function _license(string memory spdx) internal pure returns (License memory) {
        return License(spdx, keccak256(bytes(spdx)));
    }

    /// @dev An ORIGINAL item by `artist` in the fixture collection; `salt` varies the content.
    function _item(uint256 salt) internal view returns (PackageItem memory item) {
        item.kind = ItemKind.ORIGINAL;
        item.collectionId = collectionId;
        item.contentId = keccak256(abi.encode("content", salt));
        item.metadataHash = keccak256(abi.encode("record", salt));
        item.parties = new Party[](1);
        item.parties[0] = Party(artist, PartyRole.ARTIST);
        item.payees = new Payee[](1);
        item.payees[0] = Payee(uint256(uint160(artist)), address(0), 100_000);
        item.license = _license("CC0-1.0");
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
