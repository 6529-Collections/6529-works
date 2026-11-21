// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStatementLog, Statement } from "src/interfaces/IStatementLog.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
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
import { Payment, PaymentMethod, SaleKind } from "src/interfaces/types/SaleTypes.sol";
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

/// @title Walkthrough
/// @notice One curated work's whole life on a local anvil deployment, in three phases that
///         `script/local/walkthrough.sh` runs with the clock moved forward between them:
///         - `curate()`: a collection, the work's files stored on-chain, its one-item package
///           approved by a curation signer and accepted by the artist, the artist's move
///           signature, the 1/1 auction started with a bid, its edition auction opened beside it,
///           two edition bids and a competing 1/1 bid;
///         - `settle()` (after the 1/1's end): settle the 1/1, the outbid bidder's refund, create
///           the edition, open the work's record, the artist finalizes it, `tokenURI`;
///         - `editions()` (after the edition close): settle the edition auction, both bidders
///           claim their copies, the artist releases the seller wallet and the network's fee vault
///           forwards to the fee recipient.
/// @dev For a local node only. Every account is one of anvil's default accounts (the public
///      test mnemonic below), broadcast with `--unlocked`; EIP-712 signatures use the same test
///      keys. Account indices match script/local/make_genesis.py. The work is deterministic, so
///      each phase rebuilds it from the chain. The deployment record is `WALKTHROUGH_RECORD`.
contract Walkthrough is Script {
    /// @dev Anvil's default mnemonic: public test keys, never used outside a local node.
    string internal constant MNEMONIC =
        "test test test test test test test test test test test junk";
    uint32 internal constant SIGNER = 2;
    uint32 internal constant PLATFORM = 4;
    uint32 internal constant CURATOR = 5;
    uint32 internal constant ARTIST = 6;
    uint32 internal constant BIDDER_A = 7;
    uint32 internal constant BIDDER_B = 8;
    uint32 internal constant KEEPER = 9;

    uint256 internal constant FIRST_BID = 0.1 ether;
    uint256 internal constant SECOND_BID = 0.2 ether;
    /// @dev Edition bids: (ladder step, copies). Every 48 steps multiply the price by 10, from
    ///      the base price of 0.0001 ETH at step 0.
    uint256 internal constant EDITION_STEP_A = 90;
    uint256 internal constant EDITION_COPIES_A = 3;
    uint256 internal constant EDITION_STEP_B = 96;
    uint256 internal constant EDITION_COPIES_B = 2;

    struct Addrs {
        address store;
        address registry;
        address verifier;
        address statements;
        address stream;
        address records;
        address english;
        address editionAuction;
        address editions;
        address splits;
        address feeVault;
        uint256 cc0FileId;
    }

    struct Work {
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

    function _addrs() internal view returns (Addrs memory a) {
        string memory json = vm.readFile(vm.envString("WALKTHROUGH_RECORD"));
        a.store = vm.parseJsonAddress(json, ".contracts.ContentStore.address");
        a.registry = vm.parseJsonAddress(json, ".contracts.PackageRegistry.address");
        a.verifier = vm.parseJsonAddress(json, ".contracts.CurationVerifier.address");
        a.statements = vm.parseJsonAddress(json, ".contracts.StatementLog.address");
        a.stream = vm.parseJsonAddress(json, ".contracts.Stream.address");
        a.records = vm.parseJsonAddress(json, ".contracts.WorkRecords.address");
        a.english = vm.parseJsonAddress(json, ".contracts.EnglishAuction.address");
        a.editionAuction = vm.parseJsonAddress(json, ".contracts.UniformEditionAuction.address");
        a.editions = vm.parseJsonAddress(json, ".contracts.Editions.address");
        a.splits = vm.parseJsonAddress(json, ".contracts.SplitFactory.address");
        a.feeVault = vm.parseJsonAddress(json, ".contracts.FeeRecipientVault.address");
        a.cc0FileId = uint256(vm.parseJsonBytes32(json, ".cc0TextFileId"));
    }

    /// @dev The work, rebuilt the same way in every phase: a small SVG stored on-chain, a JSON
    ///      record, CC0, the artist as the only party and payee, an edition master sold by the
    ///      English auction with a uniform-price edition auction in ETH, capped at 100 copies.
    function _work(Addrs memory a, uint256 collectionId) internal pure returns (Work memory w) {
        w.media0 = bytes(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'>"
            "<rect width='10' height='10' fill='#2b6cb0'/></svg>"
        );
        w.recordJson = bytes(
            '{"name":"Local Walkthrough","description":"A work minted by the local walkthrough.",'
            '"artists":["Anvil Artist"],"year":2026,"medium":"SVG","dimensions":"10x10"}'
        );
        bytes32 sha = sha256(w.media0);
        w.media = new MediaFile[](1);
        w.media[0] = MediaFile(_fileId(a, w.media0, "image/svg+xml"), sha, uint8(FileRole.PRIMARY));

        address artist = _addr(ARTIST);
        w.item.kind = uint8(ItemKind.EDITION_MASTER);
        w.item.collectionId = collectionId;
        w.item.contentHash = sha;
        w.item.mediaHash = WorksHashing.mediaHash(w.media);
        w.item.recordFileId = _fileId(a, w.recordJson, "application/json");
        w.item.parties = new Party[](1);
        w.item.parties[0] = Party(artist, uint8(PartyRole.ARTIST));
        w.item.payees = new ISplitWallet.Payee[](1);
        w.item.payees[0] = ISplitWallet.Payee(uint256(uint160(artist)), address(0), 100_000);
        w.item.license = License("CC0-1.0", bytes32(a.cc0FileId));
        w.item.seedPolicy = uint8(SeedPolicy.NONE);
        w.item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        w.item.edition = EditionTerms(100, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        // A one-item package: the root is the item's leaf, and its Merkle proof is empty.
        w.root = WorksHashing.leaf(WorksHashing.itemHash(w.item));
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

    function _upload(Addrs memory a, bytes memory data, string memory mime)
        internal
        returns (bytes32 fileId)
    {
        (bytes32 hash,) = IContentStore(a.store).writeChunk(data);
        bytes32[] memory chunks = new bytes32[](1);
        chunks[0] = hash;
        fileId = IContentStore(a.store)
            .registerManifest(
                chunks, data.length, uint8(IContentStore.Encoding.Identity), mime, sha256(data)
            );
    }

    function _evidence(bytes32 root) internal pure returns (bytes32) {
        return keccak256(abi.encode("local walkthrough: vote and TDH snapshot evidence", root));
    }

    function _saleIds(Addrs memory a, uint256 tokenId)
        internal
        pure
        returns (uint256 oneOfOne, uint256 editionSale)
    {
        oneOfOne = IEnglishAuction(a.english).saleIdOf(a.stream, tokenId);
        editionSale = IUniformEditionAuction(a.editionAuction).saleIdOf(a.editions, tokenId);
    }

    // ------------------------------------------------------------------ phase 1

    function curate() external {
        Addrs memory a = _addrs();
        console2.log("== phase 1: curate, start, bid ==");

        // PLATFORM creates the collection.
        vm.startBroadcast(_addr(PLATFORM));
        uint256 collectionId = IStream(a.stream).createCollection("Local Walkthrough", bytes32(0));
        vm.stopBroadcast();
        console2.log("collection created by the platform key:", collectionId);

        // Anyone stores the work's files in the content store (here the artist).
        Work memory w = _work(a, collectionId);
        vm.startBroadcast(_addr(ARTIST));
        _upload(a, w.media0, "image/svg+xml");
        _upload(a, w.recordJson, "application/json");
        vm.stopBroadcast();
        console2.log("media and record stored on-chain; media file ID:");
        console2.logBytes32(w.media[0].fileId);

        _registerPackage(a, w.root);
        _acceptPackage(a, w.root);
        uint256 saleId = _startWithBid(a, w);
        uint256 tokenId = IStream(a.stream).totalMinted();

        // The keeper opens the edition auction beside the 1/1 (ADR 0005); two collectors bid.
        IUniformEditionAuction ea = IUniformEditionAuction(a.editionAuction);
        vm.startBroadcast(_addr(KEEPER));
        uint256 editionSale =
            ea.open(a.editions, tokenId, abi.encode(w.item, w.root, new bytes32[](0)));
        vm.stopBroadcast();
        console2.log("edition auction opened; sale ID:", editionSale);
        _editionBid(ea, editionSale, BIDDER_A, EDITION_STEP_A, EDITION_COPIES_A);
        _editionBid(ea, editionSale, KEEPER, EDITION_STEP_B, EDITION_COPIES_B);

        // Bidder B outbids bidder A on the 1/1.
        address bidderB = _addr(BIDDER_B);
        vm.startBroadcast(bidderB);
        IEnglishAuction(a.english).bid{ value: SECOND_BID }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, bidderB, SECOND_BID, 0, 0, "")
        );
        vm.stopBroadcast();
        console2.log("competing 1/1 bid of 0.2 ETH by bidder B; next minimum (wei):");
        console2.log(IEnglishAuction(a.english).minimumBid(saleId));
    }

    /// @dev The curation signer attests the package root, anyone registers it, and CURATOR
    ///      appends the curation evidence statement.
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

    /// @dev The artist accepts the package; the first acceptance registers the artist's account.
    function _acceptPackage(Addrs memory a, bytes32 root) internal {
        address artist = _addr(ARTIST);
        PartyAcceptance memory acceptance = PartyAcceptance(
            artist,
            keccak256(abi.encode("6529 profile", artist)),
            keccak256(abi.encode("6529 profile document", artist)),
            uint64(block.timestamp + 1 days)
        );
        bytes memory signature = abi.encodePacked(
            artist, _sign(ARTIST, IRegistryDigests(a.registry).acceptanceDigest(root, acceptance))
        );
        vm.startBroadcast(artist);
        uint256 artistId = IPackageRegistry(a.registry).acceptPackage(root, acceptance, signature);
        vm.stopBroadcast();
        console2.log("artist accepted the package; artist ID:", artistId);
    }

    /// @dev The artist signs "move to Stream" (nonce 0); bidder A starts the 1/1 auction with a
    ///      first bid.
    function _startWithBid(Addrs memory a, Work memory w) internal returns (uint256 saleId) {
        address artist = _addr(ARTIST);
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes32 digest = IRegistryDigests(a.registry)
            .moveDigest(w.root, WorksHashing.itemHash(w.item), 0, deadline);
        bytes memory mintData = abi.encode(
            StreamMintRequest(
                w.root,
                w.item,
                new bytes32[](0),
                MoveAuthorization(0, deadline, abi.encodePacked(artist, _sign(ARTIST, digest)))
            )
        );
        address bidderA = _addr(BIDDER_A);
        Payment memory payment = Payment(PaymentMethod.DIRECT, bidderA, FIRST_BID, 0, 0, "");
        vm.startBroadcast(bidderA);
        saleId = IEnglishAuction(a.english).startWithBid{ value: FIRST_BID }(
            a.stream, mintData, address(0), payment
        );
        vm.stopBroadcast();
        console2.log("1/1 auction started with a 0.1 ETH bid by bidder A; sale ID:", saleId);
        console2.log("  token ID:", IStream(a.stream).totalMinted());
        console2.log("  ends at:", IEnglishAuction(a.english).auction(saleId).endTime);
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

    // ------------------------------------------------------------------ phase 2

    function settle() external {
        Addrs memory a = _addrs();
        console2.log("== phase 2: settle the 1/1, edition, record, finalize ==");
        uint256 tokenId = IStream(a.stream).totalMinted();
        Work memory w = _work(a, IStream(a.stream).collectionCount());
        (uint256 saleId,) = _saleIds(a, tokenId);

        vm.startBroadcast(_addr(KEEPER));
        IEnglishAuction(a.english).settle(saleId);
        vm.stopBroadcast();
        console2.log("1/1 settled; owner:", IERC721(a.stream).ownerOf(tokenId));

        address bidderA = _addr(BIDDER_A);
        vm.startBroadcast(bidderA);
        uint256 refund = ISaleAdapter(a.english).claim(CURRENCY_ETH, bidderA);
        vm.stopBroadcast();
        console2.log("bidder A pulled the outbid refund (wei):", refund);

        vm.startBroadcast(_addr(KEEPER));
        IEditions(a.editions).createEdition(tokenId, w.item);
        IWorkRecords(a.records).openRecord(tokenId, w.item, w.media);
        vm.stopBroadcast();
        console2.log("edition created and the work's record opened");

        address artist = _addr(ARTIST);
        bytes32 state = IWorkRecords(a.records).workStateHash(tokenId);
        vm.startBroadcast(artist);
        IWorkRecords(a.records).finalize(tokenId, state);
        vm.stopBroadcast();
        console2.log(
            "artist finalized the record; pinned renderer:",
            IWorkRecords(a.records).pinnedRenderer(tokenId)
        );

        string memory uri = IERC721Metadata(a.stream).tokenURI(tokenId);
        console2.log("tokenURI length (bytes):", bytes(uri).length);
        console2.log("tokenURI starts:", _prefix(uri, 60));
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
        Work memory w = _work(a, IStream(a.stream).collectionCount());
        (, uint256 editionSale) = _saleIds(a, tokenId);
        IUniformEditionAuction ea = IUniformEditionAuction(a.editionAuction);

        vm.startBroadcast(_addr(KEEPER));
        bool settled = ea.settle(editionSale, new uint256[](0));
        vm.stopBroadcast();
        require(settled, "edition auction not settled in one call");
        IUniformEditionAuction.Settlement memory s = ea.settlement(editionSale);
        console2.log("edition auction settled; copies sold:", s.count);
        console2.log("  clearing price (wei):", s.price);

        // Bid IDs count from 1 in each sale, in the order phase 1 placed them.
        _claim(a, ea, editionSale, 1, BIDDER_A, tokenId);
        _claim(a, ea, editionSale, 2, KEEPER, tokenId);

        // Proceeds: anyone deploys the seller wallet (the artist's split) at its predicted
        // address; the artist pulls its share, and the network's fee vault forwards the fees.
        vm.startBroadcast(_addr(KEEPER));
        address seller = ISplitFactory(a.splits).createWallet(w.item.payees, bytes32(0));
        vm.stopBroadcast();
        address artist = _addr(ARTIST);
        uint256 before = artist.balance;
        vm.startBroadcast(artist);
        ISplitWallet(a.splits).release(w.item.payees, bytes32(0), CURRENCY_ETH, 0);
        vm.stopBroadcast();
        console2.log("seller wallet:", seller);
        console2.log("artist released from the seller wallet (wei):", artist.balance - before);

        address destination = IGovernedVault(a.feeVault).destination();
        before = destination.balance;
        vm.startBroadcast(_addr(KEEPER));
        IGovernedVault(a.feeVault).forward(CURRENCY_ETH, type(uint256).max);
        vm.stopBroadcast();
        console2.log("network fee vault forwarded to", destination);
        console2.log("  amount (wei):", destination.balance - before);
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
        console2.log("bid claimed by account", bidder);
        console2.log("  copies won, refund (wei):", won, refund);
        console2.log("  edition balance:", IERC1155(a.editions).balanceOf(account, tokenId));
    }
}
