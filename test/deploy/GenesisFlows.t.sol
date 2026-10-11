// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { Statement } from "src/interfaces/IStatementLog.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_STREAM
} from "src/interfaces/types/EconomicsTypes.sol";
import { HASH_SHA256, HashRef } from "src/interfaces/types/HashRef.sol";
import {
    EditionFormat,
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
import { LockedTerms, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { MockEditionTarget } from "../mocks/sales/SaleMocks.sol";

/// @notice Integration finding G-1 on the deployed system: items priced in `CURRENCY_DEFAULT`
///         start in the genesis block, because genesis wires each product's first default
///         currency (otherwise a 14-day FUNDS_SETTER action). A real 6529 Stream work goes
///         through curation, the artist's acceptance and a signed move into the English
///         auction; a 6529 Editions gift uses a mock token until Editions (#14) merges.
contract GenesisFlowsTest is Test {
    /// Holders from the example JSON (pranked: only their addresses matter here).
    address internal constant PLATFORM = address(0xB051);
    address internal constant CURATOR = address(0xB061);
    string internal constant SIGNER_PLACEHOLDER = "0x000000000000000000000000000000000000b021";

    uint256 internal signerKey = uint256(keccak256("curation signer 1"));
    address internal signer;
    address internal artist;
    uint256 internal artistKey;

    DeployV1.Deployment internal d;
    DeployV1.Manifest internal manifest;
    MockEditionTarget internal editions;

    function _genesis(bool withDefaults) internal {
        signer = vm.addr(signerKey);
        (artist, artistKey) = makeAddrAndKey("artist");
        manifest = DeployV1.Manifest(keccak256("epoch-0 manifest"), "ar://epoch-0");
        // Curation signer 1 is a key the test holds.
        string memory json = vm.replace(
            vm.readFile("config/genesis.example.json"), SIGNER_PLACEHOLDER, vm.toString(signer)
        );

        DeployV1.Params memory p;
        p.deployer = address(this);
        p.namespace = keccak256("6529-works/genesis-flows");
        p.feeRecipient = makeAddr("feeRecipient");
        p.marketOwner = makeAddr("marketOwner");
        p.delegation = address(new DelegationManagementMock());
        p.cc0Text = bytes("CC0 1.0 Universal (test copy)");
        p.ethIncrementFloor = 0.001 ether;
        p.permit2 = DeployV1.CANONICAL_PERMIT2;
        p.auction = IEnglishAuction.AuctionConfig(24 hours, 15 minutes, 5_000);
        DeployV1.Deployment memory deployed = DeployV1.deploy(p);
        d = deployed;

        // A mock 6529 Editions on the fixed-price sale, listed by genesis wiring as the JSON
        // lists the real one once it lands; its edition 1 is a gift in CURRENCY_DEFAULT.
        editions = new MockEditionTarget();
        editions.setTerms(
            1,
            PrimaryTerms(
                SaleKind.FIXED_PRICE,
                CURRENCY_DEFAULT,
                0,
                "",
                makeAddr("seller"),
                p.feeRecipient,
                5_000,
                artist
            ),
            100
        );

        GovernanceConfig.Call[] memory fromJson = DeployV1.wiring(deployed, json, manifest);
        GovernanceConfig.Call[] memory calls = new GovernanceConfig.Call[](fromJson.length + 1);
        uint256 n;
        for (uint256 i; i < fromJson.length; ++i) {
            bytes4 selector = bytes4(fromJson[i].data);
            if (!withDefaults && selector == IAssetAllowlist.setDefaultCurrency.selector) continue;
            calls[n++] = fromJson[i];
        }
        calls[n++] = GovernanceConfig.Call(
            address(deployed.fixedPriceSale),
            abi.encodeCall(ISaleAdapter.setTarget, (address(editions), true))
        );
        assembly ("memory-safe") {
            mstore(calls, n)
        }
        DeployV1.install(deployed, DeployV1.config(deployed, json), manifest, calls);
    }

    // ------------------------------------------------------------------ a 6529 Stream work

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev One ORIGINAL work by the artist, priced in CURRENCY_DEFAULT, curated, accepted and
    ///      ready to start: returns the auction's `mintData`.
    function _curatedWork() internal returns (bytes memory mintData) {
        vm.prank(PLATFORM);
        uint256 collection = d.stream.createCollection("Genesis", keccak256("genesis"));

        bytes memory media = "a genesis work";
        bytes32 sha = sha256(media);
        bytes32[] memory chunks = new bytes32[](1);
        chunks[0] = keccak256(media);
        bytes32 fileId = d.contentStore
            .registerManifest(
                chunks, media.length, IContentStore.Encoding.Identity, "image/png", sha
            );
        MediaFile[] memory files = new MediaFile[](1);
        files[0] = MediaFile(fileId, sha, FileRole.PRIMARY);

        PackageItem memory item;
        item.kind = ItemKind.ORIGINAL;
        item.collectionId = collection;
        item.contentHash = sha;
        item.mediaHash = WorksHashing.mediaHash(files);
        item.recordFileId = DeployV1.uploadText(
            d.contentStore,
            bytes(
                '{"name":"Genesis","description":"A genesis work.","artists":["Artist"],'
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
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_DEFAULT, "");
        item.edition = EditionTerms(EditionFormat.FIXED, 0, 0, 0, address(0), bytes32(0), "");

        // A one-item package: the root is the item's leaf.
        bytes32 itemHash = WorksHashing.itemHash(item);
        bytes32 root = WorksHashing.leaf(itemHash);
        bytes32 evidence = keccak256(abi.encode("vote and TDH snapshot evidence", root));
        d.packageRegistry
            .registerPackage(
                root,
                evidence,
                abi.encode(
                    signer, _sign(signerKey, d.curationVerifier.approvalDigest(root, evidence))
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
        uint64 deadline = uint64(block.timestamp + 7 days);
        MoveAuthorization memory move = MoveAuthorization(
            0, deadline, _sign(artistKey, d.packageRegistry.moveDigest(root, itemHash, 0, deadline))
        );
        mintData = abi.encode(StreamMintRequest(root, item, new bytes32[](0), move));
    }

    function _giftPhase() internal view returns (IFixedPriceSale.Phase[] memory phases) {
        phases = new IFixedPriceSale.Phase[](1);
        phases[0] = IFixedPriceSale.Phase(
            uint64(block.timestamp), uint64(block.timestamp + 1 days), bytes32(0), 0, false, false
        );
    }

    // ------------------------------------------------------------------ G-1

    /// G-1: in the genesis block, with no time passing, a real 6529 Stream work priced in
    /// CURRENCY_DEFAULT starts its auction in ETH, and an Editions gift opens in ETH.
    function test_CurrencyDefaultItemsStartRightAfterGenesis() public {
        _genesis(true);
        uint256 genesisTime = block.timestamp;
        bytes memory mintData = _curatedWork();

        uint256 saleId = d.englishAuction.start(address(d.stream), mintData);
        assertEq(d.stream.totalMinted(), 1, "the work is minted into the auction");
        assertEq(d.englishAuction.lockedTerms(saleId).currency, CURRENCY_ETH, "auction in ETH");

        vm.prank(artist);
        uint256 giftId = d.fixedPriceSale
            .openSale(address(editions), 1, _giftPhase(), IFixedPriceSale.ArtistConsent(0, 0, ""));
        (LockedTerms memory terms,,) = d.fixedPriceSale.sale(giftId);
        assertEq(terms.currency, CURRENCY_ETH, "gift in ETH");

        assertEq(block.timestamp, genesisTime, "no time passed");
    }

    /// The control: without the genesis defaults, neither can start until FUNDS_SETTER's
    /// 14-day `setDefaultCurrency` runs.
    function test_WithoutGenesisDefaultsCurrencyDefaultItemsCannotStart() public {
        _genesis(false);
        bytes memory mintData = _curatedWork();
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.CurrencyNotConfigured.selector, PRODUCT_STREAM)
        );
        d.englishAuction.start(address(d.stream), mintData);

        IFixedPriceSale.Phase[] memory phases = _giftPhase();
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IEconomicsResolver.CurrencyNotAllowed.selector, CURRENCY_DEFAULT)
        );
        d.fixedPriceSale
            .openSale(address(editions), 1, phases, IFixedPriceSale.ArtistConsent(0, 0, ""));
    }
}
