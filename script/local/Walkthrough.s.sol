// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {
    IERC721Metadata
} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IGovernedVault } from "src/economics/interfaces/IGovernedVault.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Outcome, Slots, Work } from "src/interfaces/core/CoreTypes.sol";
import { IAccounts } from "src/interfaces/core/IAccounts.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { IWorkRules } from "src/interfaces/core/IWorkRules.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStatementLog, Statement } from "src/interfaces/IStatementLog.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH, PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
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
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";

interface ICurationDigest {
    function approvalDigest(bytes32 packageRoot, bytes32 evidenceHash, uint256 signerEpoch)
        external
        view
        returns (bytes32);
    function signerEpoch(address signer) external view returns (uint256);
}

interface IRegistryDigests {
    function acceptanceDigest(bytes32 packageRoot, PartyAcceptance calldata acceptance)
        external
        view
        returns (bytes32);
    function moveDigest(bytes32 packageRoot, bytes32 itemHash, uint256 nonce, uint64 deadline)
        external
        view
        returns (bytes32);
}

interface IDeployer {
    function deploy(bytes32 salt, bytes calldata config) external returns (address token);
}

interface IItemApproval {
    function approveItem(address token, bytes32 itemHash, uint24 royaltyRate) external;
}

interface IConsent {
    function consentDigest(address subject, bytes32 what) external view returns (bytes32);
}

/// @title Walkthrough
/// @notice One curated work's whole life on a local anvil deployment of the plain core, plus one
///         federated work and one module swap, in four phases that `script/local/walkthrough.sh`
///         runs with the clock moved forward between them:
///         - `curate()`: a collection; the work's files stored in the content store; its one-item
///           package approved by a curation signer and accepted by the artist; the 1/1 auction
///           started with a bid; the edition auction opened beside it with two bids; a competing
///           1/1 bid; the seller vault deployed and the work's record opened. The same artist
///           deploys a federated 1/1 contract, lists it, approves one work, and a collector
///           starts its auction with a bid.
///         - `settle()` (after the 1/1's end): both 1/1 auctions settle, the outbid bidder claims
///           the refund, the artist finalizes the record, `tokenURI`, and the network proposes a
///           new renderer for 6529 Stream.
///         - `editions()` (after the edition close): the edition auction settles, both bidders
///           claim copies and refunds, the artist releases the seller vault and the network's fee
///           vault forwards to the fee recipient.
///         - `swap()` (after the module waiting period): anyone activates the proposed renderer;
///           the finalized work keeps the renderer it pinned.
/// @dev For a local node only. Every account is one of anvil's default accounts (the public test
///      mnemonic below), broadcast with `--unlocked`; EIP-712 signatures use the same test keys.
///      Account indices match script/local/make_genesis.py. `WALKTHROUGH_RECORD` is the
///      deployment record `script/DeployCore.s.sol` wrote; `WALKTHROUGH_STATE` is a file this
///      script writes in phase 1 (the federated token and the sale IDs) and reads afterwards.
contract Walkthrough is Script {
    /// @dev Anvil's default mnemonic: public test keys, never used outside a local node.
    string internal constant MNEMONIC =
        "test test test test test test test test test test test junk";
    uint32 internal constant NETWORK = 1;
    uint32 internal constant SIGNER = 2;
    uint32 internal constant PLATFORM = 4;
    uint32 internal constant CURATOR = 5;
    uint32 internal constant ARTIST = 6;
    uint32 internal constant BIDDER_A = 7;
    uint32 internal constant BIDDER_B = 8;
    uint32 internal constant KEEPER = 9;

    uint256 internal constant FIRST_BID = 0.1 ether;
    uint256 internal constant SECOND_BID = 0.2 ether;
    uint256 internal constant FEDERATED_BID = 0.06 ether;
    /// @dev The federated work's royalty rate, out of 100,000.
    uint24 internal constant FEDERATED_RATE = 5_000;
    /// @dev Edition bids: (ladder step, copies). Every 48 steps multiply the price by 10, from
    ///      the base price of 0.0001 ETH at step 0.
    uint256 internal constant EDITION_STEP_A = 90;
    uint256 internal constant EDITION_COPIES_A = 3;
    uint256 internal constant EDITION_STEP_B = 96;
    uint256 internal constant EDITION_COPIES_B = 2;

    error Check(string what);

    struct Addrs {
        address store;
        address facts;
        address registry;
        address verifier;
        address statements;
        address stream;
        address editions;
        address rules;
        address english;
        address editionAuction;
        address splits;
        address feeVault;
        address economics;
        address accounts;
        address federation;
        address streamDeployer;
        address directory;
        address renderer;
        bytes32 cc0FileId;
    }

    struct Art {
        PackageItem item;
        MediaFile[] media;
        bytes32 root;
        bytes media0;
        bytes recordJson;
    }

    // ------------------------------------------------------------------ setup

    function _key(uint32 index) internal pure returns (uint256) {
        return vm.deriveKey(MNEMONIC, index);
    }

    function _addr(uint32 index) internal pure returns (address) {
        return vm.addr(_key(index));
    }

    function _sign(uint32 index, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key(index), digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The proof the accounts module checks: the signing wallet, then the signature.
    function _proof(uint32 index, bytes32 digest) internal pure returns (bytes memory) {
        return abi.encodePacked(_addr(index), _sign(index, digest));
    }

    function _addrs() internal view returns (Addrs memory a) {
        string memory json = vm.readFile(vm.envString("WALKTHROUGH_RECORD"));
        a.store = vm.parseJsonAddress(json, ".ContentStore");
        a.facts = vm.parseJsonAddress(json, ".WorkFacts");
        a.registry = vm.parseJsonAddress(json, ".PackageRegistry");
        a.verifier = vm.parseJsonAddress(json, ".CurationVerifier");
        a.statements = vm.parseJsonAddress(json, ".StatementLog");
        a.stream = vm.parseJsonAddress(json, ".Stream");
        a.editions = vm.parseJsonAddress(json, ".Editions");
        a.rules = vm.parseJsonAddress(json, ".WorkRules");
        a.english = vm.parseJsonAddress(json, ".EnglishAuction");
        a.editionAuction = vm.parseJsonAddress(json, ".UniformEditionAuction");
        a.splits = vm.parseJsonAddress(json, ".SplitFactory");
        a.feeVault = vm.parseJsonAddress(json, ".FeeRecipientVault");
        a.economics = vm.parseJsonAddress(json, ".EconomicsResolver");
        a.accounts = vm.parseJsonAddress(json, ".Accounts");
        a.federation = vm.parseJsonAddress(json, ".FederationRegistry");
        a.streamDeployer = vm.parseJsonAddress(json, ".FederatedStreamDeployer");
        a.directory = vm.parseJsonAddress(json, ".Directory");
        a.renderer = vm.parseJsonAddress(json, ".Renderer");
        a.cc0FileId = IWorkFacts(a.facts).cc0TextFileId();
    }

    function _state() internal view returns (address fedToken, uint256 fedSale) {
        string memory json = vm.readFile(vm.envString("WALKTHROUGH_STATE"));
        fedToken = vm.parseJsonAddress(json, ".federatedToken");
        fedSale = vm.parseJsonUint(json, ".federatedSale");
    }

    function _check(bool ok, string memory what) internal pure {
        if (!ok) revert Check(what);
    }

    /// @dev The 6529 Stream work, rebuilt the same way in every phase: a small SVG stored in the
    ///      content store, a JSON record, CC0, the artist as the only party and payee, an
    ///      edition master sold by the English auction with a uniform-price edition auction in
    ///      ETH, capped at 100 copies.
    function _work(Addrs memory a, uint256 collectionId) internal pure returns (Art memory w) {
        w.media0 = bytes(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'>"
            "<rect width='10' height='10' fill='#2b6cb0'/></svg>"
        );
        w.recordJson = bytes(
            '{"name":"Local Walkthrough","description":"A work minted by the local walkthrough.",'
            '"artists":["Anvil Artist"],"year":2026,"medium":"SVG","dimensions":"10x10"}'
        );
        w.media = new MediaFile[](1);
        w.media[0] = MediaFile(
            _fileId(a, w.media0, "image/svg+xml"), sha256(w.media0), uint8(FileRole.PRIMARY)
        );
        w.item = _baseItem(a, collectionId, w.media, _fileId(a, w.recordJson, "application/json"));
        w.item.kind = uint8(ItemKind.EDITION_MASTER);
        w.item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        w.item.edition = EditionTerms(100, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        // A one-item package: the root is the item's leaf, and its Merkle proof is empty.
        w.root = WorksHashing.leaf(WorksHashing.itemHash(w.item));
    }

    /// @dev The federated work: another SVG, an original with no edition, in the artist's own
    ///      federated 1/1 contract (collection 1, created by its constructor).
    function _federatedWork(Addrs memory a) internal pure returns (Art memory w) {
        w.media0 = bytes(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'>"
            "<circle cx='5' cy='5' r='4' fill='#c05621'/></svg>"
        );
        w.recordJson = bytes(
            '{"name":"Local Federated Work","description":"A federated work of the local '
            'walkthrough.","artists":["Anvil Artist"],"year":2026}'
        );
        w.media = new MediaFile[](1);
        w.media[0] = MediaFile(
            _fileId(a, w.media0, "image/svg+xml"), sha256(w.media0), uint8(FileRole.PRIMARY)
        );
        w.item = _baseItem(a, 1, w.media, _fileId(a, w.recordJson, "application/json"));
        w.item.kind = uint8(ItemKind.ORIGINAL);
        w.item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        w.item.edition = EditionTerms(0, CURRENCY_ETH, bytes32(0), "");
    }

    function _baseItem(
        Addrs memory a,
        uint256 collectionId,
        MediaFile[] memory media,
        bytes32 recordFileId
    ) internal pure returns (PackageItem memory item) {
        address artist = _addr(ARTIST);
        item.collectionId = collectionId;
        item.contentHash = media[0].sha256Hash;
        item.mediaHash = WorksHashing.mediaHash(media);
        item.recordFileId = recordFileId;
        item.parties = new Party[](1);
        item.parties[0] = Party(artist, uint8(PartyRole.ARTIST));
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(uint256(uint160(artist)), address(0), 100_000);
        item.license = License("CC0-1.0", a.cc0FileId);
        item.seedPolicy = uint8(SeedPolicy.NONE);
    }

    /// @dev The content store's file ID for `data` stored as one Identity chunk.
    function _fileId(Addrs memory a, bytes memory data, string memory mime)
        internal
        pure
        returns (bytes32)
    {
        bytes32[] memory chunks = new bytes32[](1);
        chunks[0] = keccak256(data);
        return IContentStore(a.store)
            .manifestId(
                chunks, data.length, uint8(IContentStore.Encoding.Identity), mime, sha256(data)
            );
    }

    function _upload(Addrs memory a, bytes memory data, string memory mime) internal {
        (bytes32 hash,) = IContentStore(a.store).writeChunk(data);
        bytes32[] memory chunks = new bytes32[](1);
        chunks[0] = hash;
        IContentStore(a.store)
            .registerManifest(
                chunks, data.length, uint8(IContentStore.Encoding.Identity), mime, sha256(data)
            );
    }

    function _evidence(bytes32 root) internal pure returns (bytes32) {
        return keccak256(abi.encode("local walkthrough: vote and TDH snapshot evidence", root));
    }

    // ------------------------------------------------------------------ phase 1

    function curate() external {
        Addrs memory a = _addrs();
        console2.log("== phase 1: curate, start with a bid, edition bids, a federated work ==");

        vm.startBroadcast(_addr(PLATFORM));
        uint256 collectionId = IStream(a.stream).createCollection("Local Walkthrough", bytes32(0));
        vm.stopBroadcast();
        console2.log("collection created by the platform key:", collectionId);

        // Anyone stores the work's files in the content store (here the artist).
        Art memory w = _work(a, collectionId);
        vm.startBroadcast(_addr(ARTIST));
        _upload(a, w.media0, "image/svg+xml");
        _upload(a, w.recordJson, "application/json");
        vm.stopBroadcast();
        console2.log("media and record stored in the content store; media file ID:");
        console2.logBytes32(w.media[0].fileId);

        _registerPackage(a, w.root);
        _acceptPackage(a, w.root);
        uint256 saleId = _startWithBid(a, w);
        uint256 tokenId = IEnglishAuction(a.english).auction(saleId).tokenId;

        // The keeper opens the edition auction beside the 1/1 (it creates the edition and
        // deploys the seller and royalty vaults); two collectors bid.
        IUniformEditionAuction ea = IUniformEditionAuction(a.editionAuction);
        vm.startBroadcast(_addr(KEEPER));
        uint256 editionSale =
            ea.open(a.editions, tokenId, abi.encode(w.item, w.root, new bytes32[](0)));
        vm.stopBroadcast();
        console2.log("edition auction opened; sale ID:", editionSale);
        _editionBid(ea, editionSale, BIDDER_A, EDITION_STEP_A, EDITION_COPIES_A);
        _editionBid(ea, editionSale, KEEPER, EDITION_STEP_B, EDITION_COPIES_B);

        // Bidder B outbids bidder A on the 1/1.
        vm.startBroadcast(_addr(BIDDER_B));
        IEnglishAuction(a.english).bid{ value: SECOND_BID }(saleId, address(0));
        vm.stopBroadcast();
        _check(IEnglishAuction(a.english).claimable(_addr(BIDDER_A)) == FIRST_BID, "A credited");
        console2.log("competing 1/1 bid of 0.2 ETH by bidder B; bidder A credited (wei):");
        console2.log(FIRST_BID);

        // Anyone opens the work's record in WorkFacts with the exact item and media.
        vm.startBroadcast(_addr(KEEPER));
        IWorkFacts(a.facts).open(a.stream, tokenId, w.item, w.media);
        vm.stopBroadcast();
        _check(IWorkFacts(a.facts).factsOf(a.stream, tokenId).opened, "record opened");
        console2.log("record opened in WorkFacts for token", tokenId);

        (address fedToken, uint256 fedSale) = _federated(a);
        string memory o = "walk";
        vm.serializeAddress(o, "federatedToken", fedToken);
        string memory out = vm.serializeUint(o, "federatedSale", fedSale);
        vm.writeJson(out, vm.envString("WALKTHROUGH_STATE"));
    }

    /// @dev The curation signer attests the package root, the keeper registers it, and the
    ///      curator appends the curation evidence statement.
    function _registerPackage(Addrs memory a, bytes32 root) internal {
        bytes32 evidence = _evidence(root);
        address signer = _addr(SIGNER);
        bytes32 approval = ICurationDigest(a.verifier)
            .approvalDigest(root, evidence, ICurationDigest(a.verifier).signerEpoch(signer));
        vm.startBroadcast(_addr(KEEPER));
        IPackageRegistry(a.registry)
            .registerPackage(root, evidence, abi.encode(signer, _sign(SIGNER, approval)));
        vm.stopBroadcast();
        vm.startBroadcast(_addr(CURATOR));
        IStatementLog(a.statements)
            .appendCurator(
                Statement(
                    address(0),
                    uint256(root),
                    StatementKinds.CURATION_EVIDENCE,
                    keccak256("6529-works/curation-evidence/1"),
                    HashRef(HASH_SHA256, evidence),
                    "ar://local-walkthrough-evidence",
                    bytes32(0),
                    bytes32(0)
                )
            );
        vm.stopBroadcast();
        console2.log("package registered, approved by curation signer", signer);
        console2.logBytes32(root);
    }

    /// @dev The artist accepts the package; the first acceptance creates the artist's account.
    function _acceptPackage(Addrs memory a, bytes32 root) internal {
        address artist = _addr(ARTIST);
        PartyAcceptance memory acceptance = _acceptance(artist);
        bytes memory proof =
            _proof(ARTIST, IRegistryDigests(a.registry).acceptanceDigest(root, acceptance));
        vm.startBroadcast(artist);
        uint256 artistId = IPackageRegistry(a.registry).acceptPackage(root, acceptance, proof);
        vm.stopBroadcast();
        console2.log("artist accepted the package; artist ID:", artistId);
    }

    function _acceptance(address artist) internal view returns (PartyAcceptance memory) {
        return PartyAcceptance(
            artist,
            keccak256(abi.encode("6529 profile", artist)),
            keccak256(abi.encode("6529 profile document", artist)),
            uint64(block.timestamp + 1 days)
        );
    }

    /// @dev The artist signs "move to Stream" (nonce 0); bidder A starts the 1/1 auction with a
    ///      first bid (the work is minted into the auction's custody).
    function _startWithBid(Addrs memory a, Art memory w) internal returns (uint256 saleId) {
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes32 digest = IRegistryDigests(a.registry)
            .moveDigest(w.root, WorksHashing.itemHash(w.item), 0, deadline);
        bytes memory request = abi.encode(
            StreamMintRequest(
                w.root,
                w.item,
                new bytes32[](0),
                MoveAuthorization(0, deadline, _proof(ARTIST, digest))
            )
        );
        vm.startBroadcast(_addr(BIDDER_A));
        saleId = IEnglishAuction(a.english).startWithBid{ value: FIRST_BID }(
            a.stream, request, address(0)
        );
        vm.stopBroadcast();
        IEnglishAuction.Auction memory au = IEnglishAuction(a.english).auction(saleId);
        console2.log("1/1 auction started with a 0.1 ETH bid by bidder A; sale ID:", saleId);
        console2.log("  token ID:", au.tokenId);
        console2.log("  ends at:", uint256(au.endTime));
        _check(IERC721(a.stream).ownerOf(au.tokenId) == a.english, "minted into custody");
    }

    function _editionBid(
        IUniformEditionAuction ea,
        uint256 sale,
        uint32 bidder,
        uint256 step,
        uint256 copies
    ) internal {
        uint256 value = copies * ea.stepPrice(sale, step);
        vm.startBroadcast(_addr(bidder));
        uint256 bidId = ea.bid{ value: value }(sale, step, copies);
        vm.stopBroadcast();
        console2.log("edition bid by account", bidder);
        console2.log("  bid ID, step, copies:", bidId, step, copies);
        console2.log("  escrowed (wei):", value);
    }

    /// @dev The artist deploys a federated 1/1 contract from the approved template, lists it in
    ///      the federation module (one consent signature; the account already exists), approves
    ///      one work; bidder B stores nothing and starts its auction with a bid.
    function _federated(Addrs memory a) internal returns (address token, uint256 saleId) {
        Art memory w = _federatedWork(a);
        address artist = _addr(ARTIST);
        bytes memory config = abi.encode(
            "Anvil Artist Works",
            "AAW",
            a.facts,
            a.directory,
            uint256(uint160(artist)),
            artist,
            a.renderer
        );
        vm.startBroadcast(artist);
        _upload(a, w.media0, "image/svg+xml");
        _upload(a, w.recordJson, "application/json");
        token = IDeployer(a.streamDeployer).deploy(bytes32("walkthrough"), config);
        vm.stopBroadcast();
        _list(a, token);
        vm.startBroadcast(artist);
        IItemApproval(a.federation)
            .approveItem(token, WorksHashing.itemHash(w.item), FEDERATED_RATE);
        vm.stopBroadcast();

        bytes memory request =
            abi.encode(IFederatedStream.FederatedMint(w.item, w.media, new bytes[](0)));
        vm.startBroadcast(_addr(BIDDER_B));
        saleId = IEnglishAuction(a.english).startWithBid{ value: FEDERATED_BID }(
            token, request, address(0)
        );
        vm.stopBroadcast();
        console2.log("federated auction started with a 0.06 ETH bid by bidder B; sale ID:");
        console2.log(saleId);
    }

    /// @dev Lists `token` in the federation module with the artist's consent to the network's
    ///      current fee share.
    function _list(Addrs memory a, address token) internal {
        uint64 deadline = uint64(block.timestamp + 1 days);
        uint32 share = IEconomicsResolver(a.economics).economics(PRODUCT_FEDERATED).feeShare;
        bytes32 subject = IFederationRegistry(a.federation)
            .listingSubject(token, IFederationRegistry.Form.ERC721, address(0), share, deadline);
        PartyAcceptance memory profile = _acceptance(_addr(ARTIST));
        IFederationRegistry.Join memory j;
        j.deployer = a.streamDeployer;
        j.profileId = profile.profileId;
        j.profileDocHash = profile.profileDocHash;
        j.deadline = deadline;
        j.consent = _proof(ARTIST, IConsent(a.accounts).consentDigest(a.federation, subject));
        vm.startBroadcast(_addr(ARTIST));
        IFederationRegistry(a.federation).register(token, j);
        vm.stopBroadcast();
        console2.log("federated 1/1 contract deployed and listed:", token);
        console2.log("  network fee share (of 100,000):", uint256(share));
    }

    // ------------------------------------------------------------------ phase 2

    function settle() external {
        Addrs memory a = _addrs();
        console2.log("== phase 2: settle, refund, finalize, tokenURI, propose a renderer ==");
        uint256 tokenId = IStream(a.stream).totalMinted();
        uint256 saleId = IEnglishAuction(a.english).saleIdOf(a.stream, tokenId);
        (address fedToken, uint256 fedSale) = _state();
        IEnglishAuction english = IEnglishAuction(a.english);

        vm.startBroadcast(_addr(KEEPER));
        english.settle(saleId);
        english.settle(fedSale);
        vm.stopBroadcast();
        _check(IERC721(a.stream).ownerOf(tokenId) == _addr(BIDDER_B), "1/1 delivered");
        console2.log("1/1 settled; owner:", IERC721(a.stream).ownerOf(tokenId));
        uint256 fedId = english.auction(fedSale).tokenId;
        _check(IERC721(fedToken).ownerOf(fedId) == _addr(BIDDER_B), "federated delivered");
        console2.log("federated work settled; owner:", IERC721(fedToken).ownerOf(fedId));

        address bidderA = _addr(BIDDER_A);
        vm.startBroadcast(bidderA);
        uint256 refund = english.claim(bidderA);
        vm.stopBroadcast();
        _check(refund == FIRST_BID, "refund");
        console2.log("bidder A claimed the outbid refund (wei):", refund);

        // The artist (any wallet of the account) finalizes at the state it saw; the record is
        // frozen and the current renderer pinned.
        Art memory fw = _federatedWork(a);
        vm.startBroadcast(_addr(KEEPER));
        IWorkFacts(a.facts).open(fedToken, fedId, fw.item, fw.media);
        vm.stopBroadcast();
        vm.startBroadcast(_addr(ARTIST));
        IWorkRules(a.rules)
            .finalize(a.stream, tokenId, IWorkRules(a.rules).workStateHash(a.stream, tokenId));
        IWorkRules(a.rules)
            .finalize(fedToken, fedId, IWorkRules(a.rules).workStateHash(fedToken, fedId));
        vm.stopBroadcast();
        _check(IWorkFacts(a.facts).factsOf(a.stream, tokenId).finalized, "finalized");
        console2.log(
            "artist finalized both records; pinned renderer:",
            IWorkFacts(a.facts).rendererOf(a.stream, tokenId)
        );

        string memory uri = IERC721Metadata(a.stream).tokenURI(tokenId);
        _check(bytes(uri).length > 0, "tokenURI");
        console2.log("tokenURI length (bytes):", bytes(uri).length);
        console2.log("tokenURI starts:", _prefix(uri, 60));
        console2.log(
            "federated tokenURI length (bytes):",
            bytes(IERC721Metadata(fedToken).tokenURI(fedId)).length
        );

        // The module mechanism: the network proposes a new renderer for 6529 Stream (a second
        // instance of the same renderer, deployed by the keeper); it waits `moduleDelay`.
        bytes memory code = bytes.concat(
            vm.getCode("Renderer.sol:Renderer"), abi.encode(a.store, a.statements, uint256(262_144))
        );
        vm.startBroadcast(_addr(KEEPER));
        address next;
        assembly ("memory-safe") {
            next := create(0, add(code, 0x20), mload(code))
        }
        vm.stopBroadcast();
        _check(next != address(0), "renderer deployed");
        vm.startBroadcast(_addr(NETWORK));
        IModuleSlots(a.stream).proposeModule(Slots.RENDERER, next);
        vm.stopBroadcast();
        console2.log("network proposed renderer", next);
        console2.log(
            "  ready at:", uint256(IModuleSlots(a.stream).pendingModule(Slots.RENDERER).readyAt)
        );
        console2.log("  moduleDelay (seconds):", uint256(IModuleSlots(a.stream).moduleDelay()));
    }

    function _prefix(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length <= n) return s;
        bytes memory out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = b[i];
        }
        return string(out);
    }

    // ------------------------------------------------------------------ phase 3

    function editions() external {
        Addrs memory a = _addrs();
        console2.log("== phase 3: settle the editions, claim, release ==");
        uint256 tokenId = IStream(a.stream).totalMinted();
        Art memory w = _work(a, IStream(a.stream).collectionCount());
        IUniformEditionAuction ea = IUniformEditionAuction(a.editionAuction);
        uint256 editionSale = ea.saleIdOf(a.editions, tokenId);

        vm.startBroadcast(_addr(KEEPER));
        bool settled = ea.settle(editionSale, new uint256[](0));
        vm.stopBroadcast();
        _check(settled, "edition auction settled in one call");
        IUniformEditionAuction.Settlement memory s = ea.settlement(editionSale);
        console2.log("edition auction settled; copies sold:", s.count);
        console2.log("  clearing price (wei):", s.price);

        // Bid IDs count from 1 in each sale, in the order phase 1 placed them.
        _claim(a, ea, editionSale, 1, BIDDER_A, tokenId);
        _claim(a, ea, editionSale, 2, KEEPER, tokenId);

        // Proceeds: the artist pulls its share of the seller vault (paid to the payout address
        // the accounts module answers through Directory), and the network's fee vault forwards
        // the fees to its destination.
        address seller = ISplitFactory(a.splits).walletFor(w.item.payees, bytes32(0));
        _check(seller.code.length > 0, "seller vault deployed");
        address artist = _addr(ARTIST);
        uint256 before = artist.balance;
        vm.startBroadcast(artist);
        uint256 released =
            ISplitWallet(a.splits).release(w.item.payees, bytes32(0), CURRENCY_ETH, 0);
        vm.stopBroadcast();
        _check(released > 0, "artist release");
        console2.log("seller vault:", seller);
        console2.log("artist released from the seller vault (wei):", released);
        before;

        address destination = IGovernedVault(a.feeVault).destination();
        before = destination.balance;
        vm.startBroadcast(_addr(KEEPER));
        uint256 sent = IGovernedVault(a.feeVault).forward(CURRENCY_ETH, type(uint256).max);
        vm.stopBroadcast();
        _check(sent > 0, "network forward");
        console2.log("network fee vault forwarded to", destination);
        console2.log("  amount (wei):", sent);
    }

    function _claim(
        Addrs memory a,
        IUniformEditionAuction ea,
        uint256 sale,
        uint256 bidId,
        uint32 bidder,
        uint256 tokenId
    ) internal {
        address account = _addr(bidder);
        vm.startBroadcast(account);
        (uint256 won, uint256 refund) = ea.claimBid(sale, bidId, account);
        vm.stopBroadcast();
        _check(won > 0, "copies won");
        console2.log("bid claimed by account", bidder);
        console2.log("  copies won, refund (wei):", won, refund);
        console2.log("  edition balance:", IERC1155(a.editions).balanceOf(account, tokenId));
    }

    // ------------------------------------------------------------------ phase 4

    function swap() external {
        Addrs memory a = _addrs();
        console2.log("== phase 4: activate the proposed renderer ==");
        uint256 tokenId = IStream(a.stream).totalMinted();
        address next = IModuleSlots(a.stream).pendingModule(Slots.RENDERER).module;
        vm.startBroadcast(_addr(KEEPER));
        IModuleSlots(a.stream).activateModule(Slots.RENDERER);
        vm.stopBroadcast();
        _check(IModuleSlots(a.stream).moduleOf(Slots.RENDERER) == next, "renderer swapped");
        _check(IStream(a.stream).rendererOf(tokenId) == a.renderer, "finalized work keeps its pin");
        console2.log("renderer activated by anyone after the wait:", next);
        console2.log("finalized token still renders with:", IStream(a.stream).rendererOf(tokenId));
        Work memory work = IStream(a.stream).workOf(tokenId);
        _check(work.outcome == Outcome.SOLD, "outcome");
        console2.log("token outcome SOLD; artist ID:", work.artistId);
        _check(IAccounts(a.accounts).isWallet(work.artistId, _addr(ARTIST)), "artist wallet");
    }
}
