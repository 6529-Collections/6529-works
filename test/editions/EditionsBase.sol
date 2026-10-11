// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Editions } from "src/editions/Editions.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { CURRENCY_ETH, Payee } from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionFormat,
    EditionTerms,
    ItemKind,
    License,
    PackageItem,
    Party,
    PartyRole,
    SaleTerms,
    SeedPolicy
} from "src/interfaces/types/PackageTypes.sol";
import { DutchParams, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import {
    EditionsAdapterMock,
    EditionsArtistsMock,
    EditionsEconomicsMock,
    EditionsRegistryMock,
    EditionsRendererMock,
    EditionsStreamMock
} from "../mocks/editions/EditionsMocks.sol";

/// @dev Deploys 6529 Editions against mocks of Stream, the package registry, the economics
///      resolver, the artist registry and the renderer, under a plain OpenZeppelin AccessManager
///      with the role IDs of `src/governance/Roles.sol` (governance lane) and zero delays, plus a
///      fixed-price and a Dutch adapter holding MINTER.
abstract contract EditionsBase is Test {
    uint64 internal constant MINTER = 6;
    uint64 internal constant PARAMETER_SETTER = 9;
    uint64 internal constant FUNDS_SETTER = 10;
    uint256 internal constant PRICE = 0.01 ether;
    /// @dev Stream's auction custody, which holds a master until its auction settles.
    address internal constant CUSTODY = address(0xA0C7);

    AccessManager internal manager;
    EditionsRegistryMock internal registry;
    EditionsEconomicsMock internal economics;
    EditionsArtistsMock internal artists;
    EditionsRendererMock internal renderer;
    EditionsStreamMock internal stream;
    Editions internal editions;
    EditionsAdapterMock internal fixedAdapter;
    EditionsAdapterMock internal dutchAdapter;

    address internal admin = makeAddr("admin");
    address internal governor = makeAddr("governor");
    address internal marketOwner = makeAddr("marketOwner");
    address internal artist = makeAddr("artist");
    address internal collaborator = makeAddr("collaborator");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal buyer = makeAddr("buyer");
    address internal outsider = makeAddr("outsider");

    uint256 internal _contentNonce;

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        manager = new AccessManager(admin);
        registry = new EditionsRegistryMock();
        economics = new EditionsEconomicsMock(feeRecipient);
        artists = new EditionsArtistsMock();
        renderer = new EditionsRendererMock("default");
        stream = new EditionsStreamMock(
            address(registry), address(economics), address(artists), address(renderer)
        );
        registry.setStream(address(stream));
        editions = new Editions(address(manager), address(stream), marketOwner);
        stream.setEditions(address(editions));
        registry.setSystem(address(editions));
        fixedAdapter = new EditionsAdapterMock(SaleKind.FIXED_PRICE);
        dutchAdapter = new EditionsAdapterMock(SaleKind.DUTCH);

        vm.startPrank(admin);
        bytes4[] memory minting = new bytes4[](2);
        minting[0] = IMintTarget.mint.selector;
        minting[1] = IMintTarget.burn.selector;
        manager.setTargetFunctionRole(address(editions), minting, MINTER);
        manager.setTargetFunctionRole(
            address(editions), _one(IEditions.setContractURI.selector), PARAMETER_SETTER
        );
        manager.setTargetFunctionRole(
            address(editions), _one(IEditions.setOwner.selector), FUNDS_SETTER
        );
        manager.grantRole(MINTER, address(fixedAdapter), 0);
        manager.grantRole(MINTER, address(dutchAdapter), 0);
        manager.grantRole(PARAMETER_SETTER, governor, 0);
        manager.grantRole(FUNDS_SETTER, governor, 0);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- package items

    /// @dev An EDITION_MASTER item with fresh, registered content: the lead artist and a
    ///      collaborator, a canonical payee list (fixed payee first, then the artist ID), CC0.
    function _item(EditionFormat format, uint64 size, uint64 window, bytes32 saleKind)
        internal
        returns (PackageItem memory item)
    {
        item.kind = ItemKind.EDITION_MASTER;
        item.collectionId = 1;
        item.contentId = keccak256(abi.encode("content", ++_contentNonce));
        item.metadataHash = keccak256(abi.encode("record", _contentNonce));
        item.parties = new Party[](2);
        item.parties[0] = Party(artist, PartyRole.ARTIST);
        item.parties[1] = Party(collaborator, PartyRole.COLLABORATOR);
        item.payees = new Payee[](2);
        item.payees[0] = Payee(0, collaborator, 20_000);
        item.payees[1] = Payee(uint256(uint160(artist)), address(0), 80_000);
        item.license = License("CC0-1.0", keccak256("CC0 1.0 legal code"));
        item.seedPolicy = SeedPolicy.NONE;
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        bytes memory params =
            saleKind == SaleKind.DUTCH ? abi.encode(DutchParams(PRICE / 10, 1 days, 0)) : bytes("");
        item.edition = EditionTerms(format, size, window, PRICE, CURRENCY_ETH, saleKind, params);
        registry.setContent(item.contentId, sha256(abi.encode(item.contentId)));
    }

    function _fixedItem(uint64 size) internal returns (PackageItem memory) {
        return _item(EditionFormat.FIXED, size, 0, SaleKind.FIXED_PRICE);
    }

    function _openItem(uint64 window, uint64 size) internal returns (PackageItem memory) {
        return _item(EditionFormat.OPEN, size, window, SaleKind.DUTCH);
    }

    /// @dev Approves a one-item package and mints its master into auction custody.
    function _master(PackageItem memory item) internal returns (uint256) {
        return _masterIn(_root(item), item);
    }

    function _masterIn(bytes32 root, PackageItem memory item) internal returns (uint256) {
        registry.approve(root);
        return stream.mintMaster(root, item, CUSTODY);
    }

    function _root(PackageItem memory item) internal pure returns (bytes32) {
        return WorksHashing.leaf(WorksHashing.itemHash(item));
    }

    function _create(PackageItem memory item) internal returns (uint256 id) {
        id = _master(item);
        editions.createEdition(id, item);
    }

    function _one(bytes4 selector) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = selector;
    }

    function _calldataGas(bytes memory callData) internal pure returns (uint256 gas) {
        for (uint256 i; i < callData.length; ++i) {
            gas += callData[i] == 0 ? 4 : 16;
        }
    }
}
