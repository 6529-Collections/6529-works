// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
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
import { LockedTerms, Payment, PaymentMethod, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";

/// @notice Integration finding G-1 on the deployed system: items priced in `CURRENCY_DEFAULT`
///         start without waiting out FUNDS_SETTER's 14-day `setDefaultCurrency`, because
///         genesis wires each product's first default currency. Real contracts throughout: a
///         curated 6529 Stream work starts its auction in the genesis block, and a 6529
///         Editions gift opens as soon as its master's auction settles.
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
        return EditionTerms(EditionFormat.FIXED, 0, 0, 0, address(0), bytes32(0), "");
    }

    /// @dev A free edition of 100, priced in CURRENCY_DEFAULT, sold at a fixed price.
    function _giftEdition() internal pure returns (EditionTerms memory) {
        return
            EditionTerms(EditionFormat.FIXED, 100, 0, 0, CURRENCY_DEFAULT, SaleKind.FIXED_PRICE, "");
    }

    /// @dev Auctions an EDITION_MASTER (priced in ETH) to one bidder, settles it and creates its
    ///      edition: returns the edition ID.
    function _settledMasterEdition() internal returns (uint256 editionId) {
        (bytes memory mintData, PackageItem memory item, bytes32 root) =
            _curatedWork(ItemKind.EDITION_MASTER, CURRENCY_ETH, _giftEdition());
        uint256 saleId = d.englishAuction.start(address(d.stream), mintData);
        uint256 workId = d.stream.totalMinted();
        address collector = makeAddr("collector");
        vm.deal(collector, 1 ether);
        vm.prank(collector);
        d.englishAuction.bid{ value: 1 ether }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, collector, 1 ether, 0, 0, "")
        );
        vm.warp(d.englishAuction.auction(saleId).endTime);
        d.englishAuction.settle(saleId);
        editionId = d.editions.createEdition(workId, item, root, new bytes32[](0));
    }

    function _giftPhase() internal view returns (IFixedPriceSale.Phase[] memory phases) {
        phases = new IFixedPriceSale.Phase[](1);
        phases[0] = IFixedPriceSale.Phase(
            uint64(block.timestamp), uint64(block.timestamp + 1 days), bytes32(0), 0, false, false
        );
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
        assertEq(d.englishAuction.lockedTerms(saleId).currency, CURRENCY_ETH, "auction in ETH");
        assertEq(block.timestamp, genesisTime, "no time passed");
    }

    /// G-1 for 6529 Editions: a free edition in CURRENCY_DEFAULT opens in ETH as soon as its
    /// master's auction settles, a day after genesis, not 14 days.
    function test_ACurrencyDefaultEditionGiftOpensOnceItsMasterSettles() public {
        _genesis(true);
        uint256 genesisTime = block.timestamp;
        uint256 editionId = _settledMasterEdition();
        vm.prank(artist);
        uint256 giftId = d.fixedPriceSale
            .openSale(
                address(d.editions),
                editionId,
                _giftPhase(),
                IFixedPriceSale.ArtistConsent(0, 0, "")
            );
        (LockedTerms memory terms,,) = d.fixedPriceSale.sale(giftId);
        assertEq(terms.currency, CURRENCY_ETH, "gift in ETH");
        assertEq(terms.price, 0, "a gift");
        assertLt(block.timestamp - genesisTime, 14 days, "well inside FUNDS_SETTER's delay");
    }

    /// The control: without the genesis defaults, neither can start until FUNDS_SETTER's
    /// 14-day `setDefaultCurrency` runs.
    function test_WithoutGenesisDefaultsCurrencyDefaultItemsCannotStart() public {
        _genesis(false);
        (bytes memory mintData,,) = _curatedWork(ItemKind.ORIGINAL, CURRENCY_DEFAULT, _noEdition());
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.CurrencyNotConfigured.selector, PRODUCT_STREAM)
        );
        d.englishAuction.start(address(d.stream), mintData);

        uint256 editionId = _settledMasterEdition();
        IFixedPriceSale.Phase[] memory phases = _giftPhase();
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IEconomicsResolver.CurrencyNotAllowed.selector, CURRENCY_DEFAULT)
        );
        d.fixedPriceSale
            .openSale(
                address(d.editions), editionId, phases, IFixedPriceSale.ArtistConsent(0, 0, "")
            );
    }
}
