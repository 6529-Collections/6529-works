// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { Statement } from "src/interfaces/IStatementLog.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_STREAM
} from "src/interfaces/types/EconomicsTypes.sol";
import { HASH_SHA256, HashRef } from "src/interfaces/types/HashRef.sol";
import {
    EditionTerms,
    ItemKind,
    License,
    MoveAuthorization,
    PackageItem,
    Party,
    PartyAcceptance,
    PartyRole,
    SaleTerms,
    SeedPolicy,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { LockedTerms, Payment, PaymentMethod, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { IEnglishAuctionFull } from "test/helpers/IEnglishAuctionFull.sol";

/// @notice Integration finding G-1 on the deployed system: items priced in `CURRENCY_DEFAULT`
///         start without waiting out FUNDS_SETTER's 14-day `setDefaultCurrency`, because
///         genesis wires each product's first default currency. Real contracts throughout: a
///         curated 6529 Stream work starts its auction in the genesis block, and its 6529
///         Stream Editions auction (ETH-only, so it needs no default currency) opens beside it.
contract GenesisFlowsTest is Test {
    /// Holders from the example JSON (pranked: only their addresses matter here).
    address internal constant PLATFORM = address(0xB051);
    address internal constant CURATOR = address(0xB061);
    string internal constant SIGNER_PLACEHOLDER = "0x000000000000000000000000000000000000b021";

    uint256 internal signerKey = uint256(keccak256("curation signer 1"));
    address internal signer;
    address internal artist;
    uint256 internal artistKey;
    uint256 internal collection;
    uint256 internal moveNonce;
    uint256 internal works;

    DeployV1.Deployment internal d;

    function _genesis(bool withDefaults) internal {
        signer = vm.addr(signerKey);
        (artist, artistKey) = makeAddrAndKey("artist");
        DeployV1.Manifest memory manifest =
            DeployV1.Manifest(keccak256("epoch-0 manifest"), "ar://epoch-0");
        // Curation signer 1 is a key the test holds.
        string memory json = vm.replace(
            vm.readFile("config/genesis.example.json"), SIGNER_PLACEHOLDER, vm.toString(signer)
        );

        DeployV1.Params memory p;
        p.deployer = address(this);
        p.namespace = keccak256("6529-works/genesis-flows");
        p.feeRecipient = makeAddr("feeRecipient");
        p.museum = makeAddr("museum");
        p.marketOwner = makeAddr("marketOwner");
        p.delegation = address(new DelegationManagementMock());
        p.cc0Text = vm.readFileBinary("test/fixtures/cc0-legalcode.txt");
        p.ethIncrementFloor = 0.001 ether;
        p.permit2 = DeployV1.CANONICAL_PERMIT2;
        p.auction = IEnglishAuction.AuctionConfig(24 hours, 15 minutes, 5_000);
        p.editionAuction = DeployV1.editionAuctionDefaults();
        DeployV1.Deployment memory deployed = DeployV1.deploy(p);
        d = deployed;

        GovernanceConfig.Call[] memory calls = DeployV1.wiring(deployed, json, manifest);
        if (!withDefaults) {
            uint256 n;
            for (uint256 i; i < calls.length; ++i) {
                if (bytes4(calls[i].data) != IAssetAllowlist.setDefaultCurrency.selector) {
                    calls[n++] = calls[i];
                }
            }
            assembly ("memory-safe") {
                mstore(calls, n)
            }
        }
        DeployV1.install(deployed, DeployV1.config(deployed, json), manifest, calls);
        vm.prank(PLATFORM);
        collection = deployed.stream.createCollection("Genesis", keccak256("genesis"));
    }

    // ------------------------------------------------------------------ curated works

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev One work by the artist, alone in a package that is curated (signer approval and
    ///      curator statement) and accepted by the artist; returns the auction's `mintData`.
    function _curatedWork(ItemKind kind, address currency, EditionTerms memory edition)
        internal
        returns (bytes memory mintData, PackageItem memory item, bytes32 root)
    {
        bytes memory media = abi.encodePacked("a genesis work #", vm.toString(++works));
        bytes32 sha = sha256(media);
        bytes32[] memory chunks = new bytes32[](1);
        chunks[0] = keccak256(media);
        MediaFile[] memory files = new MediaFile[](1);
        files[0] = MediaFile(
            d.contentStore
                .registerManifest(
                    chunks, media.length, IContentStore.Encoding.Identity, "image/png", sha
                ),
            sha,
            FileRole.PRIMARY
        );

        item.kind = kind;
        item.collectionId = collection;
        item.contentHash = sha;
        item.mediaHash = WorksHashing.mediaHash(files);
        item.recordFileId = DeployV1.uploadText(
            d.contentStore,
            abi.encodePacked(
                '{"name":"Genesis ',
                vm.toString(works),
                '","description":"A genesis work.","artists":["Artist"],',
                '"year":2026,"medium":"Digital","dimensions":"1000x1000"}'
            ),
            "application/json"
        );
        item.parties = new Party[](1);
        item.parties[0] = Party(artist, PartyRole.ARTIST);
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(uint256(uint160(artist)), address(0), 100_000);
        item.license = License("CC0-1.0", d.cc0TextFileId);
        item.seedPolicy = SeedPolicy.NONE;
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, currency, "");
        item.edition = edition;

        // A one-item package: the root is the item's leaf.
        bytes32 itemHash = WorksHashing.itemHash(item);
        root = WorksHashing.leaf(itemHash);
        _curate(root);
        uint64 deadline = uint64(block.timestamp + 7 days);
        uint256 nonce = moveNonce++;
        MoveAuthorization memory move = MoveAuthorization(
            nonce,
            deadline,
            _sign(artistKey, d.packageRegistry.moveDigest(root, itemHash, nonce, deadline))
        );
        mintData = abi.encode(StreamMintRequest(root, item, new bytes32[](0), move));
    }

    function _curate(bytes32 root) internal {
        bytes32 evidence = keccak256(abi.encode("vote and TDH snapshot evidence", root));
        d.packageRegistry
            .registerPackage(
                root,
                evidence,
                abi.encode(
                    signer,
                    _sign(
                        signerKey,
                        d.curationVerifier
                        .approvalDigest(root, evidence, d.curationVerifier.signerEpoch(signer))
                    )
                )
            );
        vm.prank(CURATOR);
        d.statementLog
            .appendCurator(
                Statement(
                    address(0),
                    uint256(root),
                    StatementKinds.CURATION_EVIDENCE,
                    keccak256("6529-works/curation-evidence/1"),
                    HashRef(HASH_SHA256, evidence),
                    "ar://curation-evidence",
                    bytes32(0),
                    bytes32(0)
                )
            );
        PartyAcceptance memory acceptance = PartyAcceptance(
            artist,
            keccak256(abi.encode("6529 profile", artist)),
            keccak256(abi.encode("6529 profile document", artist)),
            uint64(block.timestamp + 1 days)
        );
        d.packageRegistry
            .acceptPackage(
                root,
                acceptance,
                _sign(artistKey, d.packageRegistry.acceptanceDigest(root, acceptance))
            );
    }

    function _noEdition() internal pure returns (EditionTerms memory) {
        return EditionTerms(0, address(0), bytes32(0), "");
    }

    /// @dev Edition terms for the uniform-price edition auction, capped at 100.
    function _editionTerms() internal pure returns (EditionTerms memory) {
        return EditionTerms(100, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
    }

    // ------------------------------------------------------------------ G-1

    /// G-1: in the genesis block, with no time passing, a curated 6529 Stream work priced in
    /// CURRENCY_DEFAULT starts its auction in ETH.
    function test_ACurrencyDefaultStreamWorkStartsInTheGenesisBlock() public {
        _genesis(true);
        uint256 genesisTime = block.timestamp;
        (bytes memory mintData,,) = _curatedWork(ItemKind.ORIGINAL, CURRENCY_DEFAULT, _noEdition());
        uint256 saleId = d.englishAuction.start(address(d.stream), mintData);
        assertEq(d.stream.totalMinted(), 1, "the work is minted into the auction");
        assertEq(
            IEnglishAuctionFull(address(d.englishAuction)).lockedTerms(saleId).currency,
            CURRENCY_ETH,
            "auction in ETH"
        );
        assertEq(block.timestamp, genesisTime, "no time passed");
    }

    /// G-1 for 6529 Stream Editions: in the genesis block, the edition auction opens beside its
    /// master's 1/1 auction (anyone may open it from the 1/1's start; ADR 0005), on the genesis
    /// wiring alone.
    function test_TheEditionAuctionOpensBesideItsMasterInTheGenesisBlock() public {
        _genesis(true);
        uint256 genesisTime = block.timestamp;
        (bytes memory mintData, PackageItem memory item,) =
            _curatedWork(ItemKind.EDITION_MASTER, CURRENCY_ETH, _editionTerms());
        d.englishAuction.start(address(d.stream), mintData);
        uint256 workId = d.stream.totalMinted();
        uint256 saleId = d.editionAuction.saleIdOf(address(d.editions), workId);
        vm.prank(makeAddr("anyone"));
        assertEq(d.editionAuction.open(address(d.editions), workId, abi.encode(item)), saleId);
        IUniformEditionAuction.Auction memory a =
            IUniformEditionAuction(address(d.editionAuction)).auction(saleId);
        assertEq(uint8(a.status), uint8(IUniformEditionAuction.AuctionStatus.OPEN));
        assertEq(a.maxCount, 100, "the creator's cap");
        assertEq(a.master, address(d.stream));
        assertEq(block.timestamp, genesisTime, "no time passed");
    }

    /// The control: without the genesis defaults, the work cannot start until FUNDS_SETTER's
    /// 14-day `setDefaultCurrency` runs.
    function test_WithoutGenesisDefaultsCurrencyDefaultItemsCannotStart() public {
        _genesis(false);
        (bytes memory mintData,,) = _curatedWork(ItemKind.ORIGINAL, CURRENCY_DEFAULT, _noEdition());
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.CurrencyNotConfigured.selector, PRODUCT_STREAM)
        );
        d.englishAuction.start(address(d.stream), mintData);
    }
}
