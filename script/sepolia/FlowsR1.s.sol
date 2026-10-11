// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStatementLog, Statement } from "src/interfaces/IStatementLog.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
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
import { Payment, PaymentMethod, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";

interface ICurationDigest {
    function approvalDigest(bytes32 packageRoot, bytes32 evidenceHash)
        external
        view
        returns (bytes32);
}

interface IDigests {
    function acceptanceDigest(bytes32 packageRoot, PartyAcceptance calldata acceptance)
        external
        view
        returns (bytes32);
    function moveDigest(bytes32 packageRoot, bytes32 itemHash, uint256 nonce, uint64 deadline)
        external
        view
        returns (bytes32);
}

/// @title FlowsR1
/// @notice Encodes the v1 flows run on the Sepolia rehearsal r1 deployment
///         (`deployments/11155111/1791746472.json`): the content uploads, one curated package of
///         eight works, its approval and acceptance, the auction starts, bids, record opening, the
///         VRF request and, after the 24-hour auction, settlement and the linked edition.
/// @dev It never broadcasts and holds no key. Each entry point reads the live chain (run it with
///      `--rpc-url`) and prints lines for a driver to act on:
///      - `TX <label> <from> <to> <value> <calldata>`: a transaction to send, where `<from>` names
///        the account that must send it (`any`, `platform`, `curator`, `artist`, or an address);
///      - `SIGN <label> <signer> <digest>`: an EIP-712 digest, read from the contract that checks
///        it, for `<signer>` to sign without hashing again;
///      - `INFO <key> <value>`.
///      The package is deterministic: the same artist and collections always give the same
///      files, items and root, so every step can be re-run and re-derived.
///      `script/sepolia/flows-r1.ps1` is the driver used for r1.
contract FlowsR1 is Script {
    using Strings for uint256;
    using Strings for address;

    string internal constant RECORD = "deployments/11155111/1791746472.json";
    string internal constant LABEL = "6529-works/sepolia-r1/flows";
    /// @dev The r1 artist (a throwaway testnet key).
    address internal constant DEFAULT_ARTIST = 0x111Cb972e6734feA580D403555a2a0ed4Cd3Ae1B;
    /// @dev Curation signer 1 of r1 (holds CURATION_SIGNER).
    address internal constant DEFAULT_SIGNER = 0xc7091A91Fa76f7494a3b847B6A08f164C7097830;
    uint256 internal constant ITEMS = 8;
    uint256 internal constant EDITION_PRICE = 0.0001 ether;
    uint64 internal constant EDITION_SIZE = 10;

    /// @dev Item roles in the package.
    uint256 internal constant ITEM_FIRST_START = 0;
    uint256 internal constant ITEM_SECOND_START = 1;
    uint256 internal constant ITEM_STEADY_START = 2;
    uint256 internal constant ITEM_START_WITH_BID = 3;
    uint256 internal constant ITEM_CONTENT = 4;
    uint256 internal constant ITEM_MASTER = 5;
    uint256 internal constant ITEM_VRF = 6;
    uint256 internal constant ITEM_NEW_COLLECTION = 7;

    struct Addrs {
        address store;
        address registry;
        address verifier;
        address statements;
        address artists;
        address stream;
        address records;
        address editions;
        address auction;
        address fixedSale;
        address entropy;
        bytes32 cc0TextFileId;
    }

    struct Work {
        PackageItem item;
        MediaFile[] media;
    }

    /// @dev A file as the store sees it.
    struct File {
        bytes stored;
        IContentStore.Encoding encoding;
        string mime;
        bytes32 sha;
    }

    // ------------------------------------------------------------------ inputs

    function _addrs() internal view returns (Addrs memory a) {
        string memory json = vm.readFile(RECORD);
        a.store = vm.parseJsonAddress(json, ".contracts.ContentStore.address");
        a.registry = vm.parseJsonAddress(json, ".contracts.PackageRegistry.address");
        a.verifier = vm.parseJsonAddress(json, ".contracts.CurationVerifier.address");
        a.statements = vm.parseJsonAddress(json, ".contracts.StatementLog.address");
        a.artists = vm.parseJsonAddress(json, ".contracts.ArtistRegistry.address");
        a.stream = vm.parseJsonAddress(json, ".contracts.Stream.address");
        a.records = vm.parseJsonAddress(json, ".contracts.WorkRecords.address");
        a.editions = vm.parseJsonAddress(json, ".contracts.Editions.address");
        a.auction = vm.parseJsonAddress(json, ".contracts.EnglishAuction.address");
        a.fixedSale = vm.parseJsonAddress(json, ".contracts.FixedPriceSale.address");
        a.entropy = vm.parseJsonAddress(json, ".contracts.EntropyModule.address");
        a.cc0TextFileId = vm.parseJsonBytes32(json, ".cc0TextFileId");
    }

    function _artist() internal view returns (address) {
        return vm.envOr("FLOWS_ARTIST", DEFAULT_ARTIST);
    }

    function _collection() internal view returns (uint256) {
        return vm.envOr("FLOWS_COLLECTION", uint256(1));
    }

    function _collection2() internal view returns (uint256) {
        return vm.envOr("FLOWS_COLLECTION2", uint256(2));
    }

    // ------------------------------------------------------------------ deterministic content

    /// @dev `n` pseudo-random bytes from `seed`.
    function _bytes(uint256 n, bytes32 seed) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; i += 32) {
            bytes32 word = keccak256(abi.encode(seed, i));
            for (uint256 j; j < 32 && i + j < n; ++j) {
                out[i + j] = word[j];
            }
        }
    }

    /// @dev The decoded media sizes of the three measured base64 files: 1,024, 8,192 and
    ///      24,572 stored bytes (one chunk each; a full chunk is 24,575).
    function _b64MediaSize(uint256 k) internal pure returns (uint256) {
        return k == 0 ? 768 : k == 1 ? 6144 : 18_429;
    }

    /// @dev Measured file `k` (0, 1, 2): pseudo-random media stored as `Base64`.
    function _b64File(uint256 k) internal pure returns (File memory f) {
        bytes memory media =
            _bytes(_b64MediaSize(k), keccak256(abi.encode(LABEL, "base64 media", k)));
        f.stored = bytes(Base64.encode(media));
        f.encoding = IContentStore.Encoding.Base64;
        f.mime = "image/png";
        f.sha = sha256(media);
    }

    /// @dev The registered-only primary file of item `i` (never uploaded: the off-chain default).
    function _plainFile(uint256 i) internal pure returns (File memory f) {
        f.stored = abi.encodePacked(LABEL, " media of item ", i.toString());
        f.encoding = IContentStore.Encoding.Identity;
        f.mime = "image/png";
        f.sha = sha256(f.stored);
    }

    /// @dev The descriptive record of item `i` (uploaded: one `Identity` chunk of JSON).
    function _recordFile(uint256 i) internal pure returns (File memory f) {
        f.stored = abi.encodePacked(
            '{"name":"r1 flows #',
            i.toString(),
            '","description":"A Sepolia rehearsal r1 work used to measure gas under Glamsterdam.",',
            '"artists":["r1 Flows Artist"],"year":2026,"medium":"Digital","dimensions":"1000x1000"}'
        );
        f.encoding = IContentStore.Encoding.Identity;
        f.mime = "application/json";
        f.sha = sha256(f.stored);
    }

    /// @dev The primary file of item `i`: a measured base64 file for items 0, 1 and 4.
    function _primary(uint256 i) internal pure returns (File memory) {
        if (i == ITEM_FIRST_START) return _b64File(0);
        if (i == ITEM_SECOND_START) return _b64File(1);
        if (i == ITEM_CONTENT) return _b64File(2);
        return _plainFile(i);
    }

    function _chunkHashes(Addrs memory a, bytes memory stored)
        internal
        view
        returns (bytes32[] memory hashes)
    {
        uint256 size = IContentStore(a.store).CHUNK_SIZE();
        hashes = new bytes32[]((stored.length + size - 1) / size);
        for (uint256 i; i < hashes.length; ++i) {
            hashes[i] = keccak256(_slice(stored, i * size, size));
        }
    }

    function _slice(bytes memory data, uint256 from, uint256 max)
        internal
        pure
        returns (bytes memory out)
    {
        uint256 n = data.length - from < max ? data.length - from : max;
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = data[from + i];
        }
    }

    function _fileId(Addrs memory a, File memory f) internal view returns (bytes32) {
        return IContentStore(a.store)
            .manifestId(_chunkHashes(a, f.stored), f.stored.length, f.encoding, f.mime, f.sha);
    }

    function _registered(Addrs memory a, bytes32 fileId) internal view returns (bool) {
        try IContentStore(a.store).fileInfo(fileId) returns (IContentStore.FileInfo memory) {
            return true;
        } catch {
            return false;
        }
    }

    // ------------------------------------------------------------------ the package

    function _work(Addrs memory a, uint256 i) internal view returns (Work memory w) {
        address lead = _artist();
        File memory primary = _primary(i);
        w.media = new MediaFile[](1);
        w.media[0] = MediaFile(_fileId(a, primary), primary.sha, FileRole.PRIMARY);
        PackageItem memory item;
        item.kind = i == ITEM_MASTER ? ItemKind.EDITION_MASTER : ItemKind.ORIGINAL;
        item.collectionId = i == ITEM_NEW_COLLECTION ? _collection2() : _collection();
        item.contentHash = primary.sha;
        item.mediaHash = WorksHashing.mediaHash(w.media);
        item.recordFileId = _fileId(a, _recordFile(i));
        item.parties = new Party[](1);
        item.parties[0] = Party(lead, PartyRole.ARTIST);
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(uint256(uint160(lead)), address(0), 100_000);
        item.license = License("CC0-1.0", a.cc0TextFileId);
        item.seedPolicy = i == ITEM_VRF ? SeedPolicy.VRF : SeedPolicy.NONE;
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        item.edition = i == ITEM_MASTER
            ? EditionTerms(
                EditionFormat.FIXED,
                EDITION_SIZE,
                0,
                EDITION_PRICE,
                CURRENCY_ETH,
                SaleKind.FIXED_PRICE,
                ""
            )
            : EditionTerms(EditionFormat.FIXED, 0, 0, 0, address(0), bytes32(0), "");
        w.item = item;
    }

    function _works(Addrs memory a) internal view returns (Work[] memory works) {
        works = new Work[](ITEMS);
        for (uint256 i; i < ITEMS; ++i) {
            works[i] = _work(a, i);
        }
    }

    function _leaves(Work[] memory works) internal pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](works.length);
        for (uint256 i; i < works.length; ++i) {
            leaves[i] = WorksHashing.leaf(WorksHashing.itemHash(works[i].item));
        }
    }

    function _hashPair(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x < y ? keccak256(abi.encode(x, y)) : keccak256(abi.encode(y, x));
    }

    function _next(bytes32[] memory level) internal pure returns (bytes32[] memory next) {
        next = new bytes32[]((level.length + 1) / 2);
        for (uint256 i; i < next.length; ++i) {
            next[i] =
                2 * i + 1 < level.length ? _hashPair(level[2 * i], level[2 * i + 1]) : level[2 * i];
        }
    }

    /// @dev A sorted-pair Merkle root; an odd node is carried up unchanged (as the integration
    ///      tests build it, checked there against OpenZeppelin `MerkleProof`).
    function _root(bytes32[] memory level) internal pure returns (bytes32) {
        while (level.length > 1) {
            level = _next(level);
        }
        return level[0];
    }

    function _proof(bytes32[] memory level, uint256 index)
        internal
        pure
        returns (bytes32[] memory proof)
    {
        bytes32[] memory path = new bytes32[](32);
        uint256 n;
        while (level.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < level.length) path[n++] = level[sibling];
            level = _next(level);
            index /= 2;
        }
        proof = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            proof[i] = path[i];
        }
    }

    function _evidence(bytes32 root) internal pure returns (bytes32) {
        return keccak256(abi.encode(LABEL, "curation evidence", root));
    }

    function _profileId(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode("6529 profile", account));
    }

    function _profileDoc(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode("6529 profile document", account));
    }

    // ------------------------------------------------------------------ output

    function _tx(
        string memory label,
        string memory from,
        address to,
        uint256 value,
        bytes memory data
    ) internal pure {
        console2.log(
            string.concat(
                "TX ",
                label,
                " ",
                from,
                " ",
                to.toHexString(),
                " ",
                value.toString(),
                " ",
                vm.toString(data)
            )
        );
    }

    function _sign(string memory label, address signer, bytes32 digest) internal pure {
        console2.log(
            string.concat("SIGN ", label, " ", signer.toHexString(), " ", vm.toString(digest))
        );
    }

    function _info(string memory key, string memory value) internal pure {
        console2.log(string.concat("INFO ", key, " ", value));
    }

    // ------------------------------------------------------------------ 1. content

    /// @notice The uploads: the three measured base64 files (chunk, manifest, attestation), each
    ///         item's record (chunk and manifest) and each registered-only primary file. Prints
    ///         only what the chain does not have yet.
    function content() external view {
        Addrs memory a = _addrs();
        IContentStore store = IContentStore(a.store);
        for (uint256 k; k < 3; ++k) {
            File memory f = _b64File(k);
            bytes32 fileId = _fileId(a, f);
            string memory size = f.stored.length.toString();
            _info(string.concat("b64-", size, "-fileId"), vm.toString(fileId));
            _info(string.concat("b64-", size, "-k"), k.toString());
            if (store.chunkPointer(keccak256(f.stored)) == address(0)) {
                _tx(
                    string.concat("writeChunk-b64-", size),
                    "any",
                    a.store,
                    0,
                    abi.encodeCall(IContentStore.writeChunk, (f.stored))
                );
            }
            if (!_registered(a, fileId)) {
                _tx(
                    string.concat("registerManifest-b64-", size),
                    "any",
                    a.store,
                    0,
                    abi.encodeCall(
                        IContentStore.registerManifest,
                        (_chunkHashes(a, f.stored), f.stored.length, f.encoding, f.mime, f.sha)
                    )
                );
            }
            if (!store.isBase64Attested(fileId)) {
                _tx(
                    string.concat("attestBase64-", size),
                    "any",
                    a.store,
                    0,
                    abi.encodeCall(IContentStore.attestBase64, (fileId))
                );
            }
        }
        for (uint256 i; i < ITEMS; ++i) {
            File memory r = _recordFile(i);
            bytes32 recordId = _fileId(a, r);
            if (store.chunkPointer(keccak256(r.stored)) == address(0)) {
                _tx(
                    string.concat("writeChunk-record-", i.toString()),
                    "any",
                    a.store,
                    0,
                    abi.encodeCall(IContentStore.writeChunk, (r.stored))
                );
            }
            if (!_registered(a, recordId)) {
                _tx(
                    string.concat("registerManifest-record-", i.toString()),
                    "any",
                    a.store,
                    0,
                    abi.encodeCall(
                        IContentStore.registerManifest,
                        (_chunkHashes(a, r.stored), r.stored.length, r.encoding, r.mime, r.sha)
                    )
                );
            }
            File memory p = _primary(i);
            if (p.encoding == IContentStore.Encoding.Identity && !_registered(a, _fileId(a, p))) {
                _tx(
                    string.concat("registerManifest-media-", i.toString()),
                    "any",
                    a.store,
                    0,
                    abi.encodeCall(
                        IContentStore.registerManifest,
                        (_chunkHashes(a, p.stored), p.stored.length, p.encoding, p.mime, p.sha)
                    )
                );
            }
        }
    }

    /// @notice Broadcasts `writeChunk` of measured file `k` from the script's sender. Used for
    ///         the 24 KB chunk, whose calldata is longer than a Windows command line allows
    ///         `cast send` to take. Broadcast with `--skip-simulation` so the node estimates gas.
    function broadcastB64Chunk(uint256 k) external {
        Addrs memory a = _addrs();
        bytes memory stored = _b64File(k).stored;
        vm.startBroadcast();
        IContentStore(a.store).writeChunk(stored);
        vm.stopBroadcast();
    }

    // ------------------------------------------------------------------ 2. package and consent

    /// @notice The package root, its items and the two digests to sign before registration: the
    ///         curation signer's approval and the artist's acceptance (with `acceptDeadline`).
    function package(uint64 acceptDeadline) external view {
        Addrs memory a = _addrs();
        Work[] memory works = _works(a);
        bytes32 root = _root(_leaves(works));
        _info("root", vm.toString(root));
        _info("evidence", vm.toString(_evidence(root)));
        for (uint256 i; i < ITEMS; ++i) {
            _info(
                string.concat("item-", i.toString()),
                vm.toString(WorksHashing.itemHash(works[i].item))
            );
        }
        (IPackageRegistry.PackageStatus status,,) = IPackageRegistry(a.registry).packageOf(root);
        _info("status", uint256(status).toString());
        _sign(
            "approval",
            vm.envOr("FLOWS_SIGNER", DEFAULT_SIGNER),
            ICurationDigest(a.verifier).approvalDigest(root, _evidence(root))
        );
        address lead = _artist();
        uint256 artistId = IArtistRegistry(a.artists).artistIdOf(lead);
        _sign(
            "acceptance",
            artistId == 0 ? lead : IArtistRegistry(a.artists).authorityOf(artistId),
            IDigests(a.registry).acceptanceDigest(root, _acceptance(lead, acceptDeadline))
        );
    }

    function _acceptance(address account, uint64 deadline)
        internal
        pure
        returns (PartyAcceptance memory)
    {
        return PartyAcceptance(account, _profileId(account), _profileDoc(account), deadline);
    }

    /// @notice `registerPackage` with curation signer 1's approval signature (anyone sends it).
    function registerTx(bytes calldata approval) external view {
        Addrs memory a = _addrs();
        bytes32 root = _root(_leaves(_works(a)));
        _tx(
            "registerPackage",
            "any",
            a.registry,
            0,
            abi.encodeCall(
                IPackageRegistry.registerPackage,
                (
                    root,
                    _evidence(root),
                    abi.encode(vm.envOr("FLOWS_SIGNER", DEFAULT_SIGNER), approval)
                )
            )
        );
    }

    /// @notice The CURATOR's `CURATION_EVIDENCE` statement for the root.
    function curatorTx() external view {
        Addrs memory a = _addrs();
        bytes32 root = _root(_leaves(_works(a)));
        _tx(
            "appendCurator",
            "curator",
            a.statements,
            0,
            abi.encodeCall(
                IStatementLog.appendCurator,
                (Statement(
                        address(0),
                        uint256(root),
                        StatementKinds.CURATION_EVIDENCE,
                        keccak256("6529-works/curation-evidence/1"),
                        HashRef(HASH_SHA256, _evidence(root)),
                        "ar://sepolia-r1-flows-curation-evidence",
                        bytes32(0),
                        bytes32(0)
                    ))
            )
        );
    }

    /// @notice The artist's `acceptPackage` (relayed: anyone sends it). The first acceptance
    ///         registers the artist.
    function acceptTx(uint64 deadline, bytes calldata signature) external view {
        Addrs memory a = _addrs();
        bytes32 root = _root(_leaves(_works(a)));
        _tx(
            "acceptPackage",
            "any",
            a.registry,
            0,
            abi.encodeCall(
                IPackageRegistry.acceptPackage, (root, _acceptance(_artist(), deadline), signature)
            )
        );
    }

    // ------------------------------------------------------------------ 3. the auction

    /// @notice The move digest the lead artist's authority signs for item `index`.
    function moveDigest(uint256 index, uint256 nonce, uint64 deadline) external view {
        Addrs memory a = _addrs();
        Work[] memory works = _works(a);
        bytes32 root = _root(_leaves(works));
        uint256 artistId = IArtistRegistry(a.artists).artistIdOf(_artist());
        _sign(
            string.concat("move-", index.toString()),
            IArtistRegistry(a.artists).authorityOf(artistId),
            IDigests(a.registry)
                .moveDigest(root, WorksHashing.itemHash(works[index].item), nonce, deadline)
        );
    }

    function _mintData(
        Addrs memory a,
        uint256 index,
        uint256 nonce,
        uint64 deadline,
        bytes memory signature
    ) internal view returns (bytes memory) {
        Work[] memory works = _works(a);
        bytes32[] memory leaves = _leaves(works);
        return abi.encode(
            StreamMintRequest(
                _root(leaves),
                works[index].item,
                _proof(leaves, index),
                MoveAuthorization(nonce, deadline, signature)
            )
        );
    }

    /// @notice `start` of item `index` (anyone sends it).
    function startTx(uint256 index, uint256 nonce, uint64 deadline, bytes calldata signature)
        external
        view
    {
        Addrs memory a = _addrs();
        _tx(
            string.concat("start-", index.toString()),
            "any",
            a.auction,
            0,
            abi.encodeCall(
                IEnglishAuction.start, (a.stream, _mintData(a, index, nonce, deadline, signature))
            )
        );
    }

    /// @notice `startWithBid` of item `index`, an ETH bid of `amount` that `bidder` sends.
    function startWithBidTx(
        uint256 index,
        uint256 nonce,
        uint64 deadline,
        bytes calldata signature,
        address bidder,
        uint256 amount
    ) external view {
        Addrs memory a = _addrs();
        _tx(
            string.concat("startWithBid-", index.toString()),
            bidder.toHexString(),
            a.auction,
            amount,
            abi.encodeCall(
                IEnglishAuction.startWithBid,
                (
                    a.stream,
                    _mintData(a, index, nonce, deadline, signature),
                    address(0),
                    Payment(PaymentMethod.DIRECT, bidder, amount, 0, 0, "")
                )
            )
        );
    }

    /// @notice An ETH bid of `amount` by `bidder` on Stream token `tokenId`.
    function bidTx(uint256 tokenId, address bidder, uint256 amount) external view {
        Addrs memory a = _addrs();
        uint256 saleId = IEnglishAuction(a.auction).saleIdOf(a.stream, tokenId);
        _info("saleId", saleId.toString());
        _info("minimumBid", IEnglishAuction(a.auction).minimumBid(saleId).toString());
        _tx(
            string.concat("bid-", tokenId.toString()),
            bidder.toHexString(),
            a.auction,
            amount,
            abi.encodeCall(
                IEnglishAuction.bid,
                (saleId, address(0), Payment(PaymentMethod.DIRECT, bidder, amount, 0, 0, ""))
            )
        );
    }

    /// @notice `settle` of Stream token `tokenId` (anyone, after the end).
    function settleTx(uint256 tokenId) external view {
        Addrs memory a = _addrs();
        uint256 saleId = IEnglishAuction(a.auction).saleIdOf(a.stream, tokenId);
        _info("endTime", uint256(IEnglishAuction(a.auction).auction(saleId).endTime).toString());
        _tx(
            string.concat("settle-", tokenId.toString()),
            "any",
            a.auction,
            0,
            abi.encodeCall(IEnglishAuction.settle, (saleId))
        );
    }

    // ------------------------------------------------------------------ 4. records and VRF

    /// @notice `openRecord` of Stream token `tokenId`, minted from item `index` (anyone).
    function openRecordTx(uint256 index, uint256 tokenId) external view {
        Addrs memory a = _addrs();
        Work memory w = _works(a)[index];
        _tx(
            string.concat("openRecord-", tokenId.toString()),
            "any",
            a.records,
            0,
            abi.encodeCall(IWorkRecords.openRecord, (tokenId, w.item, w.media))
        );
    }

    /// @notice `requestSeed` for the VRF item (anyone).
    function requestSeedTx() external view {
        Addrs memory a = _addrs();
        Work[] memory works = _works(a);
        bytes32[] memory leaves = _leaves(works);
        _info("itemHash", vm.toString(WorksHashing.itemHash(works[ITEM_VRF].item)));
        _tx(
            "requestSeed",
            "any",
            a.entropy,
            0,
            abi.encodeCall(
                IEntropyModule.requestSeed,
                (works[ITEM_VRF].item, _root(leaves), _proof(leaves, ITEM_VRF))
            )
        );
    }

    // ------------------------------------------------------------------ 5. the edition

    /// @notice `createEdition` for the master minted as Stream token `workId` (anyone, after the
    ///         master's sale settled).
    function createEditionTx(uint256 workId) external view {
        Addrs memory a = _addrs();
        Work[] memory works = _works(a);
        bytes32[] memory leaves = _leaves(works);
        _tx(
            string.concat("createEdition-", workId.toString()),
            "any",
            a.editions,
            0,
            abi.encodeCall(
                IEditions.createEdition,
                (workId, works[ITEM_MASTER].item, _root(leaves), _proof(leaves, ITEM_MASTER))
            )
        );
    }

    /// @notice The PLATFORM's `openSale` of edition `editionId`: one public phase from `start`
    ///         to `end` at the package price, without the artist's consent.
    function openSaleTx(uint256 editionId, uint64 start, uint64 end) external view {
        Addrs memory a = _addrs();
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](1);
        phases[0] = IFixedPriceSale.Phase(start, end, bytes32(0), 0, false, false);
        _tx(
            string.concat("openSale-", editionId.toString()),
            "platform",
            a.fixedSale,
            0,
            abi.encodeCall(
                IFixedPriceSale.openSale,
                (a.editions, editionId, phases, IFixedPriceSale.ArtistConsent(0, 0, ""))
            )
        );
    }

    /// @notice A public-phase purchase of `quantity` copies by `buyer`, paid in ETH.
    function purchaseTx(uint256 saleId, address buyer, uint256 quantity) external view {
        uint256 total = EDITION_PRICE * quantity;
        _tx(
            string.concat("purchase-", saleId.toString(), "-", quantity.toString()),
            buyer.toHexString(),
            _addrs().fixedSale,
            total,
            abi.encodeCall(
                IFixedPriceSale.purchase,
                (
                    IFixedPriceSale.Purchase(saleId, 0, buyer, quantity, 0, 0),
                    new bytes32[](0),
                    Payment(PaymentMethod.DIRECT, buyer, total, 0, 0, "")
                )
            )
        );
    }
}
