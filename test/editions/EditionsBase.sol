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
import {
    EditionsAdapterMock,
    EditionsArtistsMock,
    EditionsEconomicsMock,
    EditionsRegistryMock,
    EditionsRendererMock,
    EditionsStreamMock,
    EditionsWorkRecordsMock
} from "../mocks/editions/EditionsMocks.sol";

/// @dev Deploys 6529 Editions against mocks of Stream, the package registry, the economics
///      resolver, the artist registry, the work-records satellite and the renderer, under a plain
///      OpenZeppelin AccessManager with the role IDs of `src/governance/Roles.sol` and zero
///      delays, plus a fixed-price and a Dutch adapter admitted as minters (decision E4) through
///      the governed setter, mapped here to the 30-day SUCCESSOR_SETTER role. Genesis wiring is
///      complete:
///      Stream and the registry bind Editions, and Editions binds the work-records satellite
///      (ADMIN, the default role of unmapped selectors).
abstract contract EditionsBase is Test {
    uint64 internal constant SUCCESSOR_SETTER = 11;
    uint64 internal constant PARAMETER_SETTER = 9;
    uint64 internal constant FUNDS_SETTER = 10;
    uint256 internal constant PRICE = 0.01 ether;
    /// @dev Stream's auction custody, which holds a master until its auction settles.
    address internal constant CUSTODY = address(0xA0C7);
    /// @dev The master's auction winner.
    address internal constant COLLECTOR = address(0xC011);

    AccessManager internal manager;
    EditionsRegistryMock internal registry;
    EditionsEconomicsMock internal economics;
    EditionsArtistsMock internal artists;
    EditionsRendererMock internal renderer;
    EditionsStreamMock internal stream;
    Editions internal editions;
    EditionsAdapterMock internal fixedAdapter;
    EditionsAdapterMock internal dutchAdapter;
    EditionsWorkRecordsMock internal workRecordsMock;

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
        editions =
            new Editions(address(manager), address(stream), address(stream).codehash, marketOwner);
        workRecordsMock = new EditionsWorkRecordsMock();
        stream.bind(address(workRecordsMock), address(editions));
        registry.bindCallers(address(stream), address(editions));
        fixedAdapter = new EditionsAdapterMock(SaleKind.FIXED_PRICE);
        dutchAdapter = new EditionsAdapterMock(SaleKind.DUTCH);

        vm.startPrank(admin);
        manager.setTargetFunctionRole(
            address(editions), _one(Editions.setAdmittedMinter.selector), SUCCESSOR_SETTER
        );
        manager.setTargetFunctionRole(
            address(editions), _one(IEditions.setContractURI.selector), PARAMETER_SETTER
        );
        manager.setTargetFunctionRole(
            address(editions), _one(IEditions.setOwner.selector), FUNDS_SETTER
        );
        manager.grantRole(SUCCESSOR_SETTER, governor, 0);
        manager.grantRole(PARAMETER_SETTER, governor, 0);
        manager.grantRole(FUNDS_SETTER, governor, 0);
        editions.bindWorkRecords(address(workRecordsMock));
        vm.stopPrank();
        vm.startPrank(governor);
        editions.setAdmittedMinter(address(fixedAdapter), true);
        editions.setAdmittedMinter(address(dutchAdapter), true);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- package items

    /// @dev An EDITION_MASTER item with fresh content: the lead artist and a collaborator, a
    ///      canonical payee list (fixed payee first, then the artist ID), CC0.
    function _item(EditionFormat format, uint64 size, uint64 window, bytes32 saleKind)
        internal
        returns (PackageItem memory item)
    {
        item.kind = ItemKind.EDITION_MASTER;
        item.collectionId = 1;
        item.contentHash = sha256(abi.encode("content", ++_contentNonce));
        item.mediaHash = keccak256(abi.encode("media", _contentNonce));
        item.recordFileId = keccak256(abi.encode("record", _contentNonce));
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
    }

    function _fixedItem(uint64 size) internal returns (PackageItem memory) {
        return _item(EditionFormat.FIXED, size, 0, SaleKind.FIXED_PRICE);
    }

    function _openItem(uint64 window, uint64 size) internal returns (PackageItem memory) {
        return _item(EditionFormat.OPEN, size, window, SaleKind.DUTCH);
    }

    /// @dev Mints a master into auction custody (consuming its item) and settles the auction to
    ///      a collector.
    function _master(PackageItem memory item) internal returns (uint256 id) {
        id = _masterInAuction(item);
        stream.settle(id, COLLECTOR);
    }

    /// @dev A master whose auction has not settled (live or paused for a dispute).
    function _masterInAuction(PackageItem memory item) internal returns (uint256) {
        return stream.mintMaster(item, CUSTODY);
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
