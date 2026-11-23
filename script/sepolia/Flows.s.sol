// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { IWorkRules } from "src/interfaces/core/IWorkRules.sol";
import { IGovernedVault } from "src/economics/interfaces/IGovernedVault.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { IIndependentStream } from "src/interfaces/IIndependentStream.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStatementLog, Statement } from "src/interfaces/IStatementLog.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH, PRODUCT_INDEPENDENT } from "src/interfaces/types/EconomicsTypes.sol";
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

interface IIndependentDeployer {
    function deploy(bytes32 salt, bytes calldata config) external returns (address token);
}

interface IConsentDigest {
    function consentDigest(address subject, bytes32 what) external view returns (bytes32);
}

/// @title Flows
/// @notice Encodes the flows run on a Sepolia rehearsal of the plain core (ADR 0010; round r6
///         on), against the deployment record `FLOWS_RECORD` names (`script/DeployCore.s.sol`
///         writes it): the content uploads, one curated package of ten works, its approval and
///         acceptance, the 1/1 starts and bids, the edition auctions that run beside the edition
///         masters' 1/1s (open, which creates the edition; bids, raises, settlement with the
///         per-settler departure sweep, claims), a pauser's dispute pause and the network's
///         cancel that voids an edition sale, record opening and finalizing, the VRF request, the
///         releases to the artist and the network, and an artist's own Independent Stream 1/1
///         contract (deployed from the approved template, listed, one work approved and sold by
///         the shared English auction).
/// @dev It holds no key. Only `broadcastB64Chunk` broadcasts, from the script's sender; every
///      other entry point reads the live chain (run it with `--rpc-url`) and prints lines for a
///      driver to act on:
///      - `TX <label> <from> <to> <value> <calldata>`: a transaction to send, where `<from>` names
///        the account that must send it (`any`, `platform`, `curator`, `artist`, or an address),
///        or `safe:<address>` for a call a Safe makes (the driver collects its owners'
///        signatures and relays `execTransaction`);
///      - `SIGN <label> <signer> <digest>`: an EIP-712 digest, read from the contract that checks
///        it, for `<signer>` to sign without hashing again;
///      - `INFO <key> <value>`.
///      The package is deterministic: the same artist and collections always give the same
///      files, items and root, so every step can be re-run and re-derived.
///      `script/sepolia/flows.ps1` is the driver.
contract Flows is Script {
    /// @notice The deployment in the record has no entropy module (deployed without VRF).
    error NoEntropyModule();

    using Strings for uint256;
    using Strings for address;

    /// @dev Seeds every file, record and evidence hash. It is kept from r1 so that every instance
    ///      shares one package (same files and root).
    string internal constant LABEL = "6529-works/sepolia-r1/flows";
    /// @dev The rehearsals' artist (a throwaway testnet key).
    address internal constant DEFAULT_ARTIST = 0x111Cb972e6734feA580D403555a2a0ed4Cd3Ae1B;
    /// @dev Curation signer 1 of r5 and r6 (holds CURATION_SIGNER); `FLOWS_SIGNER` overrides.
    address internal constant DEFAULT_SIGNER = 0xa901A777C41e36B4Bd1caD3101140D8D12C5f9C9;
    uint256 internal constant ITEMS = 10;
    /// @dev The capped master's creator cap on its edition count; the other masters have none.
    uint32 internal constant EDITION_CAP = 3;

    /// @dev Item roles in the package.
    uint256 internal constant ITEM_FIRST_START = 0;
    uint256 internal constant ITEM_SECOND_START = 1;
    uint256 internal constant ITEM_STEADY_START = 2;
    uint256 internal constant ITEM_START_WITH_BID = 3;
    uint256 internal constant ITEM_CONTENT = 4;
    uint256 internal constant ITEM_MASTER = 5;
    uint256 internal constant ITEM_VRF = 6;
    uint256 internal constant ITEM_NEW_COLLECTION = 7;
    /// @dev An edition master whose creator caps the edition (`EDITION_CAP`): the cut step.
    uint256 internal constant ITEM_CAPPED_MASTER = 8;
    /// @dev An uncapped edition master whose 1/1 a pauser pauses for a dispute.
    uint256 internal constant ITEM_DISPUTE_MASTER = 9;

    struct Addrs {
        address store;
        address facts;
        address registry;
        address verifier;
        address statements;
        address artists;
        address stream;
        address rules;
        address editions;
        address auction;
        address entropy;
        address editionAuction;
        address splits;
        address feeVault;
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

    /// @dev The deployment record (`FLOWS_RECORD`): one `<name>: <address>` object, as
    ///      `script/DeployCore.s.sol` writes it.
    function _record() internal view returns (string memory) {
        return vm.readFile(vm.envString("FLOWS_RECORD"));
    }

    function _addrs() internal view returns (Addrs memory a) {
        string memory json = _record();
        a.store = vm.parseJsonAddress(json, ".ContentStore");
        a.facts = vm.parseJsonAddress(json, ".StreamWorkFacts6529");
        a.registry = vm.parseJsonAddress(json, ".PackageRegistry");
        a.verifier = vm.parseJsonAddress(json, ".CurationVerifier");
        a.statements = vm.parseJsonAddress(json, ".StatementLog");
        a.artists = vm.parseJsonAddress(json, ".Accounts");
        // `FLOWS_TOKEN` names another 1/1 token for the steps that take a token ID (bid, settle,
        // finalize, englishState): an artist's Independent Stream contract.
        a.stream = vm.envOr("FLOWS_TOKEN", vm.parseJsonAddress(json, ".Stream6529"));
        a.rules = vm.parseJsonAddress(json, ".WorkRules");
        a.editions = vm.parseJsonAddress(json, ".StreamEditions6529");
        a.auction = vm.parseJsonAddress(json, ".EnglishAuction");
        a.editionAuction = vm.parseJsonAddress(json, ".UniformEditionAuction");
        a.splits = vm.parseJsonAddress(json, ".SplitFactory");
        a.feeVault = vm.parseJsonAddress(json, ".FeeRecipientVault");
        if (vm.keyExistsJson(json, ".EntropyModule")) {
            a.entropy = vm.parseJsonAddress(json, ".EntropyModule");
        }
        a.cc0TextFileId = IWorkFacts(a.facts).cc0TextFileId();
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
            .manifestId(
                _chunkHashes(a, f.stored), f.stored.length, uint8(f.encoding), f.mime, f.sha
            );
    }

    function _registered(Addrs memory a, bytes32 fileId) internal view returns (bool) {
        try IContentStore(a.store).fileInfo(fileId) returns (IContentStore.FileInfo memory) {
            return true;
        } catch (bytes memory reason) {
            // Only the store's unknown-file error means "not registered"; anything else (a
            // wrong address, an RPC failure) fails the run instead of planning bad uploads.
            if (reason.length == 36 && bytes4(reason) == IContentStore.ContentFileUnknown.selector) return false;
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    // ------------------------------------------------------------------ the package

    function _work(Addrs memory a, uint256 i) internal view returns (Work memory w) {
        address lead = _artist();
        File memory primary = _primary(i);
        w.media = new MediaFile[](1);
        w.media[0] = MediaFile(_fileId(a, primary), primary.sha, uint8(FileRole.PRIMARY));
        PackageItem memory item;
        bool master = _isMaster(i);
        item.kind = master ? uint8(ItemKind.EDITION_MASTER) : uint8(ItemKind.ORIGINAL);
        item.collectionId = i == ITEM_NEW_COLLECTION ? _collection2() : _collection();
        item.contentHash = primary.sha;
        item.mediaHash = WorksHashing.mediaHash(w.media);
        item.recordFileId = _fileId(a, _recordFile(i));
        item.parties = new Party[](1);
        item.parties[0] = Party(lead, uint8(PartyRole.ARTIST));
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(uint256(uint160(lead)), address(0), 100_000);
        item.license = License("CC0-1.0", a.cc0TextFileId);
        item.seedPolicy = i == ITEM_VRF ? uint8(SeedPolicy.VRF) : uint8(SeedPolicy.NONE);
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        item.edition = master
            ? EditionTerms(
                i == ITEM_CAPPED_MASTER ? EDITION_CAP : 0,
                CURRENCY_ETH,
                SaleKind.UNIFORM_AUCTION,
                ""
            )
            : EditionTerms(0, address(0), bytes32(0), "");
        w.item = item;
    }

    /// @dev Items 5, 8 and 9 are edition masters: uncapped, capped and the disputed one.
    function _isMaster(uint256 i) internal pure returns (bool) {
        return i == ITEM_MASTER || i == ITEM_CAPPED_MASTER || i == ITEM_DISPUTE_MASTER;
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
                        (
                            _chunkHashes(a, f.stored),
                            f.stored.length,
                            uint8(f.encoding),
                            f.mime,
                            f.sha
                        )
                    )
                );
            }
            if (!store.isBase64Attested(fileId)) {
                _tx(
                    string.concat("attestBase64-", size),
                    "any",
                    a.store,
                    0,
                    abi.encodeCall(IContentStore.attestBase64, (fileId, type(uint256).max))
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
                        (
                            _chunkHashes(a, r.stored),
                            r.stored.length,
                            uint8(r.encoding),
                            r.mime,
                            r.sha
                        )
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
                        (
                            _chunkHashes(a, p.stored),
                            p.stored.length,
                            uint8(p.encoding),
                            p.mime,
                            p.sha
                        )
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
        _signApproval(a, root);
        _sign(
            "acceptance",
            _acceptanceSigner(a),
            IDigests(a.registry).acceptanceDigest(root, _acceptance(_artist(), acceptDeadline))
        );
    }

    /// @dev The curation signer's approval digest; it binds the signer's current epoch.
    function _signApproval(Addrs memory a, bytes32 root) internal view {
        address signer = vm.envOr("FLOWS_SIGNER", DEFAULT_SIGNER);
        ICurationDigest verifier = ICurationDigest(a.verifier);
        _sign(
            "approval",
            signer,
            verifier.approvalDigest(root, _evidence(root), verifier.signerEpoch(signer))
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
    ///         registers the artist. `signature` is the artist's raw signature; the proof the
    ///         registry reads is `abi.encodePacked(wallet, signature)` (IAccounts).
    function acceptTx(uint64 deadline, bytes calldata signature) external view {
        Addrs memory a = _addrs();
        bytes32 root = _root(_leaves(_works(a)));
        _tx(
            "acceptPackage",
            "any",
            a.registry,
            0,
            abi.encodeCall(
                IPackageRegistry.acceptPackage,
                (
                    root,
                    _acceptance(_artist(), deadline),
                    abi.encodePacked(_acceptanceSigner(a), signature)
                )
            )
        );
    }

    /// @dev The wallet that signs the acceptance, as `package()` resolves it: the artist key
    ///      before it registers, then its account's current root (which a root change moves).
    function _acceptanceSigner(Addrs memory a) internal view returns (address) {
        address lead = _artist();
        uint256 artistId = IArtistRegistry(a.artists).artistIdOf(lead);
        return artistId == 0 ? lead : IArtistRegistry(a.artists).authorityOf(artistId);
    }

    // ------------------------------------------------------------------ 3. the auction

    /// @notice The move digest the lead artist's authority signs for item `index`.
    function moveDigest(uint256 index, uint256 nonce, uint64 deadline) external view {
        Addrs memory a = _addrs();
        Work[] memory works = _works(a);
        bytes32 root = _root(_leaves(works));
        uint256 artistId = IArtistRegistry(a.artists).artistIdOf(_artist());
        require(artistId != 0, "artist not registered: accept the package first");
        _sign(
            string.concat("move-", index.toString()),
            _moveSigner(a, artistId),
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
        // The move proof names the signing wallet (IAccounts): the account's root, or the
        // consolidated wallet `FLOWS_MOVE_SIGNER` names.
        IArtistRegistry artists = IArtistRegistry(a.artists);
        address root = _moveSigner(a, artists.artistIdOf(_artist()));
        return abi.encode(
            StreamMintRequest(
                _root(leaves),
                works[index].item,
                _proof(leaves, index),
                MoveAuthorization(nonce, deadline, abi.encodePacked(root, signature))
            )
        );
    }

    /// @dev The wallet that signs a move: `FLOWS_MOVE_SIGNER` when set (a wallet consolidated with
    ///      the artist's account, which acts for it), else the account's root.
    function _moveSigner(Addrs memory a, uint256 artistId) internal view returns (address) {
        address signer = vm.envOr("FLOWS_MOVE_SIGNER", address(0));
        return signer != address(0) ? signer : IArtistRegistry(a.artists).authorityOf(artistId);
    }

    /// @notice `SaleStarter.start` of item `index` (anyone sends it): the auction, the seller and
    ///         royalty vaults and the record in one transaction.
    function starterTx(uint256 index, uint256 nonce, uint64 deadline, bytes calldata signature)
        external
        view
    {
        Addrs memory a = _addrs();
        address starter = vm.parseJsonAddress(_record(), ".SaleStarter");
        _tx(
            string.concat("saleStarter-", index.toString()),
            "any",
            starter,
            0,
            abi.encodeWithSignature(
                "start(address,address,bytes,(bytes32,bytes32,uint8)[])",
                a.auction,
                a.stream,
                _mintData(a, index, nonce, deadline, signature),
                _works(a)[index].media
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
                (a.stream, _mintData(a, index, nonce, deadline, signature), address(0))
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
            abi.encodeCall(IEnglishAuction.bid, (saleId, address(0)))
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

    /// @notice `StreamWorkFacts6529.open` of Stream token `tokenId`, minted from item `index`
    ///         (anyone).
    function openRecordTx(uint256 index, uint256 tokenId) external view {
        Addrs memory a = _addrs();
        Work memory w = _works(a)[index];
        _tx(
            string.concat("openRecord-", tokenId.toString()),
            "any",
            a.facts,
            0,
            abi.encodeCall(IWorkFacts.open, (a.stream, tokenId, w.item, w.media))
        );
    }

    /// @notice The artist finalizes Stream token `tokenId`'s record at its current state
    ///         (`WorkRules.finalize`; a wallet of the artist's account sends it). It pins the
    ///         token's current renderer.
    function finalizeTx(uint256 tokenId) external view {
        Addrs memory a = _addrs();
        bytes32 state = IWorkRules(a.rules).workStateHash(a.stream, tokenId);
        _info("stateHash", vm.toString(state));
        _tx(
            string.concat("finalize-", tokenId.toString()),
            "artist",
            a.rules,
            0,
            abi.encodeCall(IWorkRules.finalize, (a.stream, tokenId, state))
        );
    }

    /// @notice `requestSeed` for the VRF item (anyone).
    function requestSeedTx() external view {
        Addrs memory a = _addrs();
        if (a.entropy == address(0)) revert NoEntropyModule();
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

    // ------------------------------------------------------------------ 5. the edition auction

    function _uea(Addrs memory a) internal pure returns (IUniformEditionAuction) {
        require(a.editionAuction != address(0), "record has no UniformEditionAuction");
        return IUniformEditionAuction(a.editionAuction);
    }

    /// @dev The edition sale of master token `tokenId` (sale IDs are derived).
    function _editionSale(Addrs memory a, uint256 tokenId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(a.editions, tokenId)));
    }

    /// @notice `open` of the edition auction beside master token `tokenId`, minted from item
    ///         `index` (anyone: the keeper batches it with the 1/1's start). It creates the
    ///         edition and deploys the seller and royalty vaults.
    function openEditionTx(uint256 index, uint256 tokenId) external view {
        Addrs memory a = _addrs();
        require(_isMaster(index), "not an edition master item");
        uint256 saleId = _editionSale(a, tokenId);
        require(_uea(a).saleIdOf(a.editions, tokenId) == saleId, "sale ID derivation");
        _info("saleId", saleId.toString());
        Work[] memory works = _works(a);
        bytes32[] memory leaves = _leaves(works);
        // The item, its package root and its proof.
        bytes memory data = abi.encode(works[index].item, _root(leaves), _proof(leaves, index));
        _tx(
            string.concat("openEdition-", tokenId.toString()),
            "any",
            a.editionAuction,
            0,
            abi.encodeCall(IUniformEditionAuction.open, (a.editions, tokenId, data))
        );
    }

    /// @notice A bid of `quantity` units at `step` on master `tokenId`'s edition sale, paying
    ///         its exact escrow.
    function editionBidTx(uint256 tokenId, address bidder, uint256 step, uint256 quantity)
        external
        view
    {
        Addrs memory a = _addrs();
        IUniformEditionAuction uea = _uea(a);
        uint256 saleId = _editionSale(a, tokenId);
        uint256 price = uea.stepPrice(saleId, step);
        _info("saleId", saleId.toString());
        _info("price", price.toString());
        _info("nextBidId", (uint256(uea.auction(saleId).bidCount) + 1).toString());
        _tx(
            string.concat("editionBid-", tokenId.toString()),
            bidder.toHexString(),
            a.editionAuction,
            price * quantity,
            abi.encodeCall(IUniformEditionAuction.bid, (saleId, step, quantity))
        );
    }

    /// @notice `raise` of bid `bidId` on master `tokenId`'s edition sale to `newStep`, paying the
    ///         exact difference; the bidder sends it.
    function editionRaiseTx(uint256 tokenId, uint256 bidId, uint256 newStep) external view {
        Addrs memory a = _addrs();
        IUniformEditionAuction uea = _uea(a);
        uint256 saleId = _editionSale(a, tokenId);
        IUniformEditionAuction.Bid memory b = uea.bidOf(saleId, bidId);
        uint256 paid =
            uint256(b.quantity) * (uea.stepPrice(saleId, newStep) - uea.stepPrice(saleId, b.step));
        _info("fromStep", uint256(b.step).toString());
        _tx(
            string.concat("editionRaise-", tokenId.toString()),
            b.bidder.toHexString(),
            a.editionAuction,
            paid,
            abi.encodeCall(IUniformEditionAuction.raise, (saleId, bidId, newStep))
        );
    }

    /// @notice `settle` of master `tokenId`'s edition sale by `settler` with the rest of its own
    ///         departure sweep, as the keeper sends it: before the clearing call every settler's
    ///         order is the whole sorted log (`settlementOrder`), after it the settler's own rest
    ///         (`settlementOrderFor`).
    function editionSettleTx(uint256 tokenId, address settler) external view {
        Addrs memory a = _addrs();
        uint256 saleId = _editionSale(a, tokenId);
        IUniformEditionAuction.AuctionStatus status = _uea(a).auction(saleId).status;
        uint256[] memory order = status == IUniformEditionAuction.AuctionStatus.SETTLING
            ? IUniformEditionAuctionLens(a.editionAuction).settlementOrderFor(saleId, settler)
            : _uea(a).settlementOrder(saleId);
        _settleTx(a, tokenId, saleId, settler, order);
    }

    /// @notice `settle` with an explicit `order`: for showing that a settler whose order skips a
    ///         departure strands only its own sweep.
    function editionSettleOrderTx(uint256 tokenId, address settler, uint256[] calldata order)
        external
        view
    {
        Addrs memory a = _addrs();
        _settleTx(a, tokenId, _editionSale(a, tokenId), settler, order);
    }

    function _settleTx(
        Addrs memory a,
        uint256 tokenId,
        uint256 saleId,
        address settler,
        uint256[] memory order
    ) internal pure {
        string memory list;
        for (uint256 i; i < order.length; ++i) {
            list = string.concat(list, i == 0 ? "" : ",", order[i].toString());
        }
        _info("order", string.concat("[", list, "]"));
        _tx(
            string.concat("editionSettle-", tokenId.toString()),
            settler.toHexString(),
            a.editionAuction,
            0,
            abi.encodeCall(IUniformEditionAuction.settle, (saleId, order))
        );
    }

    /// @notice `claimBid` by the bidder of bid `bidId`, copies and refund to itself.
    function claimBidTx(uint256 tokenId, uint256 bidId) external view {
        Addrs memory a = _addrs();
        uint256 saleId = _editionSale(a, tokenId);
        address bidder = _uea(a).bidOf(saleId, bidId).bidder;
        _outcome(a, saleId, bidId);
        _tx(
            string.concat("claimBid-", tokenId.toString(), "-", bidId.toString()),
            bidder.toHexString(),
            a.editionAuction,
            0,
            abi.encodeCall(IUniformEditionAuction.claimBid, (saleId, bidId, bidder))
        );
    }

    /// @notice `claimBidFor` of bid `bidId` (anyone: the keeper pushes the claim; the refund is
    ///         credited to the bidder).
    function claimBidForTx(uint256 tokenId, uint256 bidId) external view {
        Addrs memory a = _addrs();
        uint256 saleId = _editionSale(a, tokenId);
        _outcome(a, saleId, bidId);
        _tx(
            string.concat("claimBidFor-", tokenId.toString(), "-", bidId.toString()),
            "any",
            a.editionAuction,
            0,
            abi.encodeCall(IUniformEditionAuction.claimBidFor, (saleId, bidId))
        );
    }

    function _outcome(Addrs memory a, uint256 saleId, uint256 bidId) internal view {
        IUniformEditionAuction.BidOutcome memory o = _uea(a).bidOutcome(saleId, bidId);
        _info("unitsWon", o.unitsWon.toString());
        _info("refund", o.refund.toString());
        _info("isFinal", o.isFinal ? "true" : "false");
    }

    /// @notice `account` claims its ETH credits to itself: from the English auction (outbid
    ///         refunds, `claim(to)`) or the edition auction (`claimBidFor` refunds,
    ///         `claim(currency, to)`).
    function claimCreditsTx(address adapter, address account) external view {
        Addrs memory a = _addrs();
        _tx(
            "claimCredits",
            account.toHexString(),
            adapter,
            0,
            adapter == a.auction
                ? abi.encodeCall(IEnglishAuction.claim, (account))
                : abi.encodeWithSignature("claim(address,address)", CURRENCY_ETH, account)
        );
    }

    /// @notice The edition sale's clocks, status and live result, as INFO lines.
    function editionState(uint256 tokenId) external view {
        Addrs memory a = _addrs();
        IUniformEditionAuction uea = _uea(a);
        uint256 saleId = _editionSale(a, tokenId);
        IUniformEditionAuction.EndTimes memory e = uea.endTimes(saleId);
        IUniformEditionAuction.Auction memory s = uea.auction(saleId);
        _info("saleId", saleId.toString());
        _info("status", uint256(s.status).toString());
        _info("bidCount", uint256(s.bidCount).toString());
        _info("liveUnits", uint256(s.liveUnits).toString());
        _info("oneOfOneEnd", uint256(e.oneOfOneEnd).toString());
        _info("closeAt", uint256(e.closeAt).toString());
        _info("softEnd", uint256(e.softEnd).toString());
        _info("endTime", uint256(e.endTime).toString());
        _info("backstop", uint256(e.backstop).toString());
        _info("oneOfOneState", uint256(e.oneOfOneState).toString());
        _info("biddingOpen", e.biddingOpen ? "true" : "false");
        if (s.status == IUniformEditionAuction.AuctionStatus.VOID) return;
        IUniformEditionAuction.Clearing memory c = uea.clearing(saleId);
        _info("count", c.count.toString());
        _info("step", c.step.toString());
        _info("price", c.price.toString());
        _info("revenue", c.revenue.toString());
        _info("rationed", c.rationed ? "true" : "false");
        _info("cutUnits", c.cutUnits.toString());
        _info("cutoff", c.cutoff.toString());
        _info("departures", uea.departures(saleId, c.step).length.toString());
    }

    /// @notice Master or work `tokenId`'s 1/1 English auction, as INFO lines.
    function englishState(uint256 tokenId) external view {
        Addrs memory a = _addrs();
        uint256 saleId = _oneOfOneSale(a, tokenId);
        IEnglishAuction.Auction memory s = IEnglishAuction(a.auction).auction(saleId);
        _info("saleId", saleId.toString());
        _info("state", uint256(s.state).toString());
        _info("endTime", uint256(s.endTime).toString());
        _info("bidder", s.bidder.toHexString());
        _info("bid", s.bid.toString());
        _info("pausedAt", uint256(s.pausedAt).toString());
        if (s.state == IEnglishAuction.AuctionState.ACTIVE) {
            _info("minimumBid", IEnglishAuction(a.auction).minimumBid(saleId).toString());
        }
    }

    // ------------------------------------------------------------------ 6. payouts

    /// @notice The artist releases its share of item `index`'s seller vault. The split ledger
    ///         pays the payout address the accounts module answers through Directory, and only
    ///         that address may release it.
    function releaseTx(uint256 index) external view {
        Addrs memory a = _addrs();
        ISplitWallet.Payee[] memory payees = _works(a)[index].item.payees;
        _info("vault", vm.toString(ISplitFactory(a.splits).walletFor(payees, bytes32(0))));
        _tx(
            string.concat("release-", index.toString()),
            "artist",
            a.splits,
            0,
            abi.encodeCall(ISplitWallet.release, (payees, bytes32(0), CURRENCY_ETH, 0))
        );
    }

    /// @notice The network fee vault forwards its whole ETH balance to its destination (anyone).
    function forwardTx() external view {
        Addrs memory a = _addrs();
        _info("destination", vm.toString(IGovernedVault(a.feeVault).destination()));
        _tx(
            "forwardFees",
            "any",
            a.feeVault,
            0,
            abi.encodeCall(IGovernedVault.forward, (CURRENCY_ETH, type(uint256).max))
        );
    }

    // ------------------------------------------------------------------ 7. disputes

    /// @dev The disputed 1/1's English auction sale.
    function _oneOfOneSale(Addrs memory a, uint256 tokenId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(a.stream, tokenId)));
    }

    /// @notice A pauser key pauses master `tokenId`'s 1/1 for a dispute (PAUSER, no delay; the
    ///         pause ends by itself after 3 days). `guardian` is the pauser's account: a key sends
    ///         it directly, a Safe (an account with code) through its owners.
    function pauseTx(uint256 tokenId, address guardian) external view {
        Addrs memory a = _addrs();
        string memory from = guardian.code.length == 0
            ? guardian.toHexString()
            : string.concat("safe:", guardian.toHexString());
        _tx(
            string.concat("pause-", tokenId.toString()),
            from,
            a.auction,
            0,
            abi.encodeWithSignature(
                "pause(uint256,bytes32)",
                _oneOfOneSale(a, tokenId),
                keccak256(abi.encode(LABEL, "dispute", tokenId))
            )
        );
    }

    /// @notice The high bidder withdraws its 1/1 bid while the 1/1 is paused (credited back).
    function englishWithdrawTx(uint256 tokenId) external view {
        Addrs memory a = _addrs();
        uint256 saleId = _oneOfOneSale(a, tokenId);
        _tx(
            string.concat("withdrawBid-", tokenId.toString()),
            IEnglishAuction(a.auction).auction(saleId).bidder.toHexString(),
            a.auction,
            0,
            abi.encodeCall(IEnglishAuction.withdrawBid, (saleId))
        );
    }

    /// @notice PLATFORM records the dispute's outcome about Stream token `tokenId` (the
    ///         statement a cancel must cite).
    function outcomeTx(uint256 tokenId) external view {
        Addrs memory a = _addrs();
        bytes memory text =
            abi.encodePacked(LABEL, " dispute outcome: upheld, token ", tokenId.toString());
        _tx(
            string.concat("disputeOutcome-", tokenId.toString()),
            "platform",
            a.statements,
            0,
            abi.encodeCall(
                IStatementLog.appendPlatform,
                (Statement(
                        a.stream,
                        tokenId,
                        StatementKinds.DISPUTE_OUTCOME,
                        keccak256("6529-works/dispute-outcome/1"),
                        HashRef(HASH_SHA256, sha256(text)),
                        "ar://sepolia-r4-flows-dispute-outcome",
                        bytes32(0),
                        bytes32(0)
                    ))
            )
        );
    }

    /// @dev The cancel of `tokenId`'s 1/1, citing the token's latest outcome.
    function _cancelData(Addrs memory a, uint256 tokenId) internal view returns (bytes memory) {
        (bytes32 outcome,) = IStatementLog(a.statements).disputeOutcomeOf(a.stream, tokenId);
        require(outcome != 0, "no dispute outcome recorded");
        _info("outcomeRef", vm.toString(outcome));
        return abi.encodeCall(IEnglishAuction.cancel, (_oneOfOneSale(a, tokenId), outcome));
    }

    /// @notice The network cancels `tokenId`'s paused 1/1 (no delay, at any moment of the
    ///         pause). `network` is the network Safe.
    function cancelTx(uint256 tokenId, address network) external view {
        Addrs memory a = _addrs();
        _tx(
            string.concat("cancel-", tokenId.toString()),
            string.concat("safe:", network.toHexString()),
            a.auction,
            0,
            _cancelData(a, tokenId)
        );
    }

    // ------------------------------------------------------------------ 8. Independent Stream

    /// @dev The Independent Stream work's two files, both stored whole in the content store: a
    ///      small SVG and its JSON record.
    function _independentFiles() internal pure returns (File memory media, File memory rec) {
        media.stored = bytes(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'>"
            "<circle cx='5' cy='5' r='4' fill='#c05621'/></svg>"
        );
        media.encoding = IContentStore.Encoding.Identity;
        media.mime = "image/svg+xml";
        media.sha = sha256(media.stored);
        rec.stored = bytes(
            '{"name":"Flows Independent #1","description":"An Independent Stream work of a Sepolia '
            'rehearsal.","artists":["r1 Flows Artist"],"year":2026}'
        );
        rec.encoding = IContentStore.Encoding.Identity;
        rec.mime = "application/json";
        rec.sha = sha256(rec.stored);
    }

    /// @dev The Independent Stream work: an original with no edition, in collection 1 of the
    ///      artist's own 1/1 contract (its constructor creates that collection).
    function _independentWork(Addrs memory a) internal view returns (Work memory w) {
        (File memory media, File memory rec) = _independentFiles();
        address lead = _artist();
        w.media = new MediaFile[](1);
        w.media[0] = MediaFile(_fileId(a, media), media.sha, uint8(FileRole.PRIMARY));
        PackageItem memory item;
        item.kind = uint8(ItemKind.ORIGINAL);
        item.collectionId = 1;
        item.contentHash = media.sha;
        item.mediaHash = WorksHashing.mediaHash(w.media);
        item.recordFileId = _fileId(a, rec);
        item.parties = new Party[](1);
        item.parties[0] = Party(lead, uint8(PartyRole.ARTIST));
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(uint256(uint160(lead)), address(0), 100_000);
        item.license = License("CC0-1.0", a.cc0TextFileId);
        item.seedPolicy = uint8(SeedPolicy.NONE);
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        item.edition = EditionTerms(0, CURRENCY_ETH, bytes32(0), "");
        w.item = item;
    }

    function _storeTx(Addrs memory a, string memory name, File memory f) internal view {
        if (IContentStore(a.store).chunkPointer(keccak256(f.stored)) == address(0)) {
            _tx(
                string.concat("writeChunk-", name),
                "any",
                a.store,
                0,
                abi.encodeCall(IContentStore.writeChunk, (f.stored))
            );
        }
        if (!_registered(a, _fileId(a, f))) {
            _tx(
                string.concat("registerManifest-", name),
                "any",
                a.store,
                0,
                abi.encodeCall(
                    IContentStore.registerManifest,
                    (_chunkHashes(a, f.stored), f.stored.length, uint8(f.encoding), f.mime, f.sha)
                )
            );
        }
    }

    /// @notice The uploads of the Independent Stream work's media and record (anyone); prints
    ///         only what the chain does not have yet.
    function independentContent() external view {
        Addrs memory a = _addrs();
        (File memory media, File memory rec) = _independentFiles();
        _storeTx(a, "independent-media", media);
        _storeTx(a, "independent-record", rec);
    }

    /// @notice The artist deploys its own Independent Stream 1/1 contract from the approved
    ///         template (`IndependentStream721Deployer.deploy`), with the deployment's renderer.
    ///         The address is read from a simulated call and printed as `INFO token`.
    function independentDeployTx(bytes32 salt) external {
        string memory json = _record();
        address artist = _artist();
        address deployer = vm.parseJsonAddress(json, ".IndependentStream721Deployer");
        bytes memory config = abi.encode(
            "Flows Independent",
            "FLOWSIND",
            vm.parseJsonAddress(json, ".StreamWorkFacts6529"),
            vm.parseJsonAddress(json, ".StreamDirectory6529"),
            uint256(uint160(artist)),
            artist,
            vm.parseJsonAddress(json, ".Renderer")
        );
        vm.prank(artist);
        address token = IIndependentDeployer(deployer).deploy(salt, config);
        _info("token", vm.toString(token));
        _tx(
            "independentDeploy",
            "artist",
            deployer,
            0,
            abi.encodeCall(IIndependentDeployer.deploy, (salt, config))
        );
    }

    function _listingSubject(string memory json, address token, uint64 deadline)
        internal
        view
        returns (address module, bytes32 subject)
    {
        module = vm.parseJsonAddress(json, ".IndependentStreamRegistry");
        uint32 share =
            IEconomicsResolver(vm.parseJsonAddress(json, ".EconomicsResolver"))
        .economics(PRODUCT_INDEPENDENT)
        .feeShare;
        subject = IIndependentStreamRegistry(module)
            .listingSubject(
                token, IIndependentStreamRegistry.Form.ERC721, address(0), share, deadline
            );
    }

    /// @notice The consent digest a wallet of the artist's account signs to list `token` in the
    ///         Independent Stream module at the network's current fee share.
    function independentConsent(address token, uint64 deadline) external view {
        Addrs memory a = _addrs();
        (address module, bytes32 subject) = _listingSubject(_record(), token, deadline);
        _sign(
            "consent",
            _acceptanceSigner(a),
            IConsentDigest(a.artists).consentDigest(module, subject)
        );
    }

    /// @notice The artist lists `token` (`register`, with the consent signature) and approves the
    ///         Independent Stream work for one mint (`approveItem`, at `royaltyRate` out of
    ///         100,000). The artist's account must exist already (it accepted the curated
    ///         package). The registration is planned only for a token that is not listed yet.
    function independentListTx(
        address token,
        uint64 deadline,
        bytes calldata signature,
        uint24 royaltyRate
    ) external view {
        Addrs memory a = _addrs();
        address module = _registerTx(a, token, deadline, signature);
        bytes32 itemHash = WorksHashing.itemHash(_independentWork(a).item);
        _info("itemHash", vm.toString(itemHash));
        _tx(
            "independentApproveItem",
            "artist",
            module,
            0,
            abi.encodeWithSignature(
                "approveItem(address,bytes32,uint24)", token, itemHash, royaltyRate
            )
        );
    }

    /// @dev Plans `register` for `token` unless the module lists it already, so a re-run after a
    ///      failed approval sends only the approval. Returns the Independent Stream module.
    function _registerTx(Addrs memory a, address token, uint64 deadline, bytes calldata signature)
        internal
        view
        returns (address module)
    {
        string memory json = _record();
        address artist = _artist();
        (module,) = _listingSubject(json, token, deadline);
        IIndependentStreamRegistry.Status status =
        IIndependentStreamRegistry(module).entry(token).status;
        _info("listingStatus", uint256(status).toString());
        if (status != IIndependentStreamRegistry.Status.NONE) return module;
        IIndependentStreamRegistry.Join memory j;
        j.deployer = vm.parseJsonAddress(json, ".IndependentStream721Deployer");
        j.profileId = _profileId(artist);
        j.profileDocHash = _profileDoc(artist);
        j.deadline = deadline;
        j.consent = abi.encodePacked(_acceptanceSigner(a), signature);
        _tx(
            "independentRegister",
            "artist",
            module,
            0,
            abi.encodeCall(IIndependentStreamRegistry.register, (token, j))
        );
    }

    /// @notice `startWithBid` of the Independent Stream work on `token`, an ETH bid of `amount`
    ///         that `bidder` sends to the shared English auction.
    function independentStartTx(address token, address bidder, uint256 amount) external view {
        Addrs memory a = _addrs();
        Work memory w = _independentWork(a);
        _tx(
            "independentStartWithBid",
            bidder.toHexString(),
            a.auction,
            amount,
            abi.encodeCall(
                IEnglishAuction.startWithBid,
                (
                    token,
                    abi.encode(IIndependentStream.IndependentMint(w.item, w.media, new bytes[](0))),
                    address(0)
                )
            )
        );
    }

    /// @notice `StreamWorkFacts6529.open` of the Independent Stream work, minted as `tokenId` of
    ///         `token` (anyone).
    function independentOpenRecordTx(address token, uint256 tokenId) external view {
        Addrs memory a = _addrs();
        Work memory w = _independentWork(a);
        _tx(
            "independentOpenRecord",
            "any",
            a.facts,
            0,
            abi.encodeCall(IWorkFacts.open, (token, tokenId, w.item, w.media))
        );
    }
}
