// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

// The shared setup of the examples: the whole 6529 Stream stack, deployed and configured by the
// deploy library the deploy script broadcasts (script/DeployCore.sol), with the committed
// genesis policy (config/genesis.core.example.json). Only two things differ from a real
// deployment: the network is one test key that accepts at once, and the first curation signer
// is a test key, so the examples can sign approvals.
//
// The helpers below do what the off-chain parts of the system do (uploading files, building a
// package and its Merkle tree, the curation signer's approval, the artist's signatures). The
// calls each example demonstrates are the ones a client makes.

import { Test } from "forge-std/Test.sol";
import { DeployCore } from "script/DeployCore.sol";
import { VerifyCore } from "script/VerifyCore.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { StreamDirectory6529 } from "src/core/StreamDirectory6529.sol";
import { StreamEditions6529 } from "src/core/StreamEditions6529.sol";
import { Stream6529 } from "src/core/Stream6529.sol";
import { StreamWorkFacts6529 } from "src/core/StreamWorkFacts6529.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { Eip712CurationVerifier } from "src/curation/Eip712CurationVerifier.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IndependentStreamRegistry } from "src/independent/IndependentStreamRegistry.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
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
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StreamHashing } from "src/interfaces/types/StreamHashing.sol";
import { SaleStarter } from "src/sales/SaleStarter.sol";
import { DelegationManagementMock } from "test/mocks/identity/DelegationManagementMock.sol";

abstract contract ExampleBase is Test {
    string internal constant GENESIS = "config/genesis.core.example.json";
    string internal constant CC0_FIXTURE = "test/fixtures/cc0-legalcode.txt";
    uint256 internal constant SIGNER_KEY = 0xC0FFEE;
    uint256 internal constant ARTIST_KEY = 0xA11CE;

    DeployCore.Deployment internal d;
    // The contracts an integrator talks to, typed.
    Stream6529 internal stream;
    StreamEditions6529 internal editions;
    StreamDirectory6529 internal directory;
    StreamWorkFacts6529 internal facts;
    ContentStore internal store;
    SplitLedger internal ledger;
    Accounts internal accounts;
    PackageRegistry internal registry;
    Eip712CurationVerifier internal verifier;
    IEnglishAuction internal auction;
    IUniformEditionAuction internal editionAuction;
    SaleStarter internal starter;
    IndependentStreamRegistry internal independentStream;

    address internal network = makeAddr("network");
    address internal deployer = makeAddr("deployer");
    address internal marketOwner = makeAddr("marketOwner");
    address internal museum = makeAddr("museum");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal platform;
    address internal signer = vm.addr(SIGNER_KEY);
    address internal artist = vm.addr(ARTIST_KEY);

    /// @dev A package kept across calls (memory does not outlive a call).
    struct Package {
        bytes32 root;
        PackageItem item;
        MediaFile[] media;
    }

    uint256 private _salt;
    uint256 private _nextNonce;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        DeployCore.Params memory p;
        p.deployer = deployer;
        p.namespace = keccak256("6529-stream/examples");
        p.feeRecipient = feeRecipient;
        p.museum = museum;
        p.marketOwner = marketOwner;
        p.delegation = address(new DelegationManagementMock());
        p.cc0Text = vm.readFileBinary(CC0_FIXTURE);
        p.ethIncrementFloor = 0.001 ether;
        p.auctionConfig = DeployCore.auctionConfig();
        p.editionAuctionConfig = DeployCore.editionAuctionConfig();
        d = DeployCore.deploy(p, address(this));

        string memory json = vm.readFile(GENESIS);
        DeployCore.Manifest memory manifest =
            DeployCore.Manifest(keccak256("examples manifest"), "ar://examples");
        GovernanceConfig.Config memory cfg = DeployCore.config(d, json);
        cfg.network = network;
        // The first curation signer of the genesis file becomes a test key; the platform key is
        // read as it is.
        bool replaced;
        for (uint256 i; i < cfg.grants.length; ++i) {
            if (cfg.grants[i].role == Roles.CURATION_SIGNER && !replaced) {
                cfg.grants[i].account = signer;
                replaced = true;
            }
            if (cfg.grants[i].role == Roles.PLATFORM) platform = cfg.grants[i].account;
        }
        GovernanceConfig.Call[] memory calls = DeployCore.wiring(d, json, manifest);
        vm.prank(deployer);
        DeployCore.install(d, cfg, manifest, calls);
        vm.prank(network);
        d.manager.acceptNetwork();
        VerifyCore.verify(p, d, cfg, true);

        stream = d.stream;
        editions = d.editions;
        directory = d.directory;
        facts = d.workFacts;
        store = d.contentStore;
        ledger = d.splitLedger;
        accounts = Accounts(d.accounts);
        registry = PackageRegistry(d.packageRegistry);
        verifier = Eip712CurationVerifier(d.curationVerifier);
        auction = IEnglishAuction(d.englishAuction);
        editionAuction = IUniformEditionAuction(d.editionAuction);
        starter = SaleStarter(d.saleStarter);
        independentStream = IndependentStreamRegistry(d.independentStreamRegistry);

        // The platform key creates collection 1, which the examples' works belong to.
        vm.prank(platform);
        stream.createCollection("Genesis", keccak256("genesis collection"));
    }

    // ------------------------------------------------------------------ content

    /// @dev Stores `data` as one complete single-chunk SHA-256 file. Anyone may write chunks
    ///      and register files; a file ID commits to its chunks, length, encoding, type and
    ///      digest.
    function _file(bytes memory data, string memory mime) internal returns (bytes32 fileId) {
        (bytes32 h,) = store.writeChunk(data);
        bytes32[] memory chunks = new bytes32[](1);
        chunks[0] = h;
        fileId = store.registerManifest(chunks, data.length, 0, mime, sha256(data));
    }

    /// @dev A descriptive record: one chunk of JSON.
    function _record(string memory name) internal returns (bytes32) {
        return _file(
            abi.encodePacked(
                '{"name":"',
                name,
                '","description":"An example work.","artists":["Example Artist"],',
                '"year":2026,"medium":"Digital","dimensions":"1000x1000"}'
            ),
            "application/json"
        );
    }

    // ------------------------------------------------------------------ packages

    /// @dev An ORIGINAL work by `artist`, paid in full to the artist's account, with one small
    ///      uploaded media file and an uploaded record, licensed CC0 with the deployment's text.
    function _original() internal returns (Package memory pkg) {
        return _work(uint8(ItemKind.ORIGINAL), 0);
    }

    /// @dev An EDITION_MASTER work: its 1/1 sells by English auction and up to `cap` copies by
    ///      the uniform-price edition auction.
    function _master(uint32 cap) internal returns (Package memory pkg) {
        return _work(uint8(ItemKind.EDITION_MASTER), cap);
    }

    function _work(uint8 kind, uint32 cap) internal returns (Package memory pkg) {
        uint256 n = ++_salt;
        bytes memory data = abi.encodePacked("example media #", vm.toString(n));
        bytes32 sha = sha256(data);
        pkg.media = new MediaFile[](1);
        pkg.media[0] = MediaFile(_file(data, "image/png"), sha, 0);
        PackageItem memory item;
        item.kind = kind;
        item.collectionId = 1;
        item.contentHash = sha;
        item.mediaHash = StreamHashing.mediaHash(pkg.media);
        item.recordFileId = _record(string.concat("Work ", vm.toString(n)));
        item.parties = new Party[](1);
        item.parties[0] = Party(artist, uint8(PartyRole.ARTIST));
        item.payees = new ISplitWallet.Payee[](1);
        // An artist-resolved payee: the artist ID, paid to the account's payout address.
        item.payees[0] = ISplitWallet.Payee(uint256(uint160(artist)), address(0), 100_000);
        item.license = License("CC0-1.0", d.cc0TextFileId);
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        if (kind == uint8(ItemKind.EDITION_MASTER)) {
            item.edition = EditionTerms(cap, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        } else {
            item.edition = EditionTerms(0, CURRENCY_ETH, bytes32(0), "");
        }
        pkg.item = item;
        // A one-item package: its root is the item's leaf and its proof is empty.
        pkg.root = StreamHashing.leaf(StreamHashing.itemHash(item));
        _publish(pkg.root);
    }

    /// @dev The curation signer approves the package (anyone may submit the attestation) and the
    ///      artist accepts it; the first acceptance creates the artist's account.
    function _publish(bytes32 root) internal {
        bytes32 evidence = keccak256(abi.encode("vote and TDH snapshot evidence", root));
        bytes32 digest = verifier.approvalDigest(root, evidence, verifier.signerEpoch(signer));
        registry.registerPackage(root, evidence, abi.encode(signer, _sign(SIGNER_KEY, digest)));
        PartyAcceptance memory a = PartyAcceptance(
            artist,
            keccak256(abi.encode("6529 profile", artist)),
            keccak256(abi.encode("6529 profile document", artist)),
            uint64(block.timestamp + 1 days)
        );
        registry.acceptPackage(root, a, _proof(ARTIST_KEY, registry.acceptanceDigest(root, a)));
    }

    /// @dev The start request: the artist's signed move of the item to 6529 Stream.
    function _request(Package memory pkg) internal returns (bytes memory) {
        uint256 nonce = _nextNonce++;
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest =
            registry.moveDigest(pkg.root, StreamHashing.itemHash(pkg.item), nonce, deadline);
        MoveAuthorization memory move =
            MoveAuthorization(nonce, deadline, _proof(ARTIST_KEY, digest));
        return abi.encode(StreamMintRequest(pkg.root, pkg.item, new bytes32[](0), move));
    }

    /// @dev Starts the work's sale through SaleStarter; returns the sale and token IDs.
    function _start(Package memory pkg) internal returns (uint256 saleId, uint256 tokenId) {
        saleId = starter.start(auction, address(stream), _request(pkg), pkg.media);
        tokenId = auction.auction(saleId).tokenId;
    }

    // ------------------------------------------------------------------ the auction

    function _bid(uint256 saleId, address bidder, uint256 amount) internal {
        vm.deal(bidder, bidder.balance + amount);
        vm.prank(bidder);
        auction.bid{ value: amount }(saleId, address(0));
    }

    function _settleAtEnd(uint256 saleId) internal {
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
    }

    /// @dev A work started, bid on once by `buyer` at `price` and settled.
    function _sell(Package memory pkg, address buyer, uint256 price)
        internal
        returns (uint256 tokenId)
    {
        uint256 saleId;
        (saleId, tokenId) = _start(pkg);
        _bid(saleId, buyer, price);
        _settleAtEnd(saleId);
    }

    // ------------------------------------------------------------------ signatures

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The proof the accounts module checks: the signing wallet, then its signature.
    function _proof(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        return abi.encodePacked(vm.addr(key), _sign(key, digest));
    }
}
