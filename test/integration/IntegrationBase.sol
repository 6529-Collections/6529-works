// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC5267 } from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { Statement } from "src/interfaces/IStatementLog.sol";
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
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { CoreIntegrationBase } from "./CoreIntegrationBase.sol";

/// @notice Actors, package building, signatures, content and sale helpers shared by the
///         end-to-end suites on the plain-core stack.
/// @dev Every helper drives the real contracts the way an off-chain tool or a wallet would: it
///      signs EIP-712 digests read from the contracts, builds sorted-pair Merkle trees over
///      `WorksHashing.leaf(itemHash)` and submits ordinary transactions.
abstract contract IntegrationBase is CoreIntegrationBase {
    /// @dev A package item with the media list its `mediaHash` commits to.
    struct Work {
        PackageItem item;
        MediaFile[] media;
    }

    /// @dev The English auction's genesis configuration (`DeployCore.auctionConfig`).
    uint32 internal constant AUCTION_DURATION = 24 hours;
    uint32 internal constant EXTENSION_WINDOW = 15 minutes;
    /// @dev The ETH opening bid the genesis wiring sets (`setOpeningBid`).
    uint256 internal constant OPENING_BID = 0.05 ether;
    /// @dev The compiled finalize notice of `WorkRules`.
    uint256 internal constant FINALIZE_NOTICE = 14 days;

    mapping(address account => uint256 pk) internal keyOf;
    mapping(uint256 artistId => uint256 nonce) internal nextMoveNonce;
    uint256 internal collectionId;
    uint256 private _salt;
    /// @dev Packages kept across calls (memory cannot outlive a call), by root.
    mapping(bytes32 root => Work[]) private _packages;

    function setUp() public virtual override {
        super.setUp();
        keyOf[signer1] = signer1Pk;
        keyOf[signer2] = signer2Pk;
        vm.prank(platform);
        collectionId = stream.createCollection("Genesis", keccak256("genesis collection"));
    }

    // ------------------------------------------------------------------ actors

    function _actor(string memory name) internal returns (address account) {
        uint256 pk;
        (account, pk) = makeAddrAndKey(name);
        keyOf[account] = pk;
    }

    function _sign(address account, bytes32 digest) internal view returns (bytes memory) {
        uint256 pk = keyOf[account];
        require(pk != 0, "no key for signer");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _profileId(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode("6529 profile", account));
    }

    function _profileDoc(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode("6529 profile document", account));
    }

    /// @dev The EIP-712 digest of `structHash` in `target`'s own domain (read with EIP-5267).
    function _typedDigest(address target, bytes32 structHash) internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifying,,) =
            IERC5267(target).eip712Domain();
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifying
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    // ------------------------------------------------------------------ works and packages

    /// @dev An ORIGINAL work by `lead` (sole payee, artist-resolved) in `collection`: a small
    ///      primary file registered in the store (not uploaded) and an uploaded JSON record.
    function _work(address lead, uint256 collection) internal returns (Work memory w) {
        uint256 salt = ++_salt;
        bytes memory media = abi.encodePacked("integration media #", vm.toString(salt));
        bytes32 sha = sha256(media);
        bytes32 fileId = _registerOnly(media, IContentStore.Encoding.Identity, "image/png", sha);
        w.media = new MediaFile[](1);
        w.media[0] = MediaFile(fileId, sha, uint8(FileRole.PRIMARY));
        w.item = _item(
            lead, collection, sha, w.media, _record(string.concat("Work ", vm.toString(salt)))
        );
    }

    /// @dev A work by `lead` whose primary file is `stored` (uploaded and complete).
    function _storedWork(
        address lead,
        bytes memory stored,
        IContentStore.Encoding encoding,
        bytes32 sha,
        string memory name
    ) internal returns (Work memory w) {
        bytes32 fileId = _upload(stored, encoding, "image/png", sha);
        w.media = new MediaFile[](1);
        w.media[0] = MediaFile(fileId, sha, uint8(FileRole.PRIMARY));
        w.item = _item(lead, collectionId, sha, w.media, _record(name));
    }

    function _item(
        address lead,
        uint256 collection,
        bytes32 contentHash,
        MediaFile[] memory media,
        bytes32 recordFileId
    ) internal view returns (PackageItem memory item) {
        item.kind = uint8(ItemKind.ORIGINAL);
        item.collectionId = collection;
        item.contentHash = contentHash;
        item.mediaHash = WorksHashing.mediaHash(media);
        item.recordFileId = recordFileId;
        item.parties = new Party[](1);
        item.parties[0] = Party(lead, uint8(PartyRole.ARTIST));
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(uint256(uint160(lead)), address(0), 100_000);
        item.license = License("CC0-1.0", cc0TextFileId);
        item.seedPolicy = uint8(SeedPolicy.NONE);
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        item.edition = EditionTerms(0, address(0), bytes32(0), "");
    }

    /// @dev Turns `w` into an edition master with `maxCount` copies sold by the uniform edition
    ///      auction (call before publishing: the item hash changes).
    function _asMaster(Work memory w, uint32 maxCount) internal pure returns (Work memory) {
        w.item.kind = uint8(ItemKind.EDITION_MASTER);
        w.item.edition = EditionTerms(maxCount, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        return w;
    }

    /// @dev Adds `collaborator` as a party and a payee with `share` of 100,000 (the lead keeps
    ///      the rest), payees in ascending artist ID. Call before publishing.
    function _withCollaborator(Work memory w, address collaborator, uint32 share)
        internal
        pure
        returns (Work memory)
    {
        Party[] memory parties = new Party[](2);
        parties[0] = w.item.parties[0];
        parties[1] = Party(collaborator, uint8(PartyRole.COLLABORATOR));
        w.item.parties = parties;
        ISplitWallet.Payee[] memory payees = new ISplitWallet.Payee[](2);
        payees[0] =
            ISplitWallet.Payee(uint256(uint160(parties[0].account)), address(0), 100_000 - share);
        payees[1] = ISplitWallet.Payee(uint256(uint160(collaborator)), address(0), share);
        // The ledger takes payees in ascending artist ID.
        if (payees[0].artistId > payees[1].artistId) {
            (payees[0], payees[1]) = (payees[1], payees[0]);
        }
        w.item.payees = payees;
        return w;
    }

    /// @dev Uploads a valid descriptive record (one `Identity` chunk of JSON).
    function _record(string memory name) internal returns (bytes32) {
        bytes memory json = abi.encodePacked(
            '{"name":"',
            name,
            '","description":"An integration test work.","artists":["Integration Artist"],',
            '"year":2026,"medium":"Digital","dimensions":"1000x1000"}'
        );
        return _storeText(json, "application/json");
    }

    function _leaves(Work[] memory works) internal pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](works.length);
        for (uint256 i; i < works.length; ++i) {
            leaves[i] = WorksHashing.leaf(WorksHashing.itemHash(works[i].item));
        }
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @dev A sorted-pair Merkle root; an odd node is carried up unchanged.
    function _root(bytes32[] memory level) internal pure returns (bytes32) {
        while (level.length > 1) {
            bytes32[] memory next = new bytes32[]((level.length + 1) / 2);
            for (uint256 i; i < next.length; ++i) {
                next[i] = 2 * i + 1 < level.length
                    ? _hashPair(level[2 * i], level[2 * i + 1])
                    : level[2 * i];
            }
            level = next;
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
            bytes32[] memory next = new bytes32[]((level.length + 1) / 2);
            for (uint256 i; i < next.length; ++i) {
                next[i] = 2 * i + 1 < level.length
                    ? _hashPair(level[2 * i], level[2 * i + 1])
                    : level[2 * i];
            }
            level = next;
            index /= 2;
        }
        proof = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            proof[i] = path[i];
        }
    }

    function _rootOf(Work[] memory works) internal pure returns (bytes32) {
        return _root(_leaves(works));
    }

    function _proofOf(Work[] memory works, uint256 index) internal pure returns (bytes32[] memory) {
        return _proof(_leaves(works), index);
    }

    function _one(Work memory w) internal pure returns (Work[] memory works) {
        works = new Work[](1);
        works[0] = w;
    }

    /// @dev Keeps `works` under `root` in storage, field by field.
    function _keep(bytes32 root, Work[] memory works) internal {
        Work[] storage list = _packages[root];
        for (uint256 i; i < works.length; ++i) {
            Work storage s = list.push();
            PackageItem memory item = works[i].item;
            s.item.kind = item.kind;
            s.item.collectionId = item.collectionId;
            s.item.contentHash = item.contentHash;
            s.item.mediaHash = item.mediaHash;
            s.item.recordFileId = item.recordFileId;
            for (uint256 j; j < item.parties.length; ++j) {
                s.item.parties.push(item.parties[j]);
            }
            for (uint256 j; j < item.payees.length; ++j) {
                s.item.payees.push(item.payees[j]);
            }
            s.item.license = item.license;
            s.item.seedPolicy = item.seedPolicy;
            s.item.seed = item.seed;
            s.item.sale = item.sale;
            s.item.edition = item.edition;
            for (uint256 j; j < works[i].media.length; ++j) {
                s.media.push(works[i].media[j]);
            }
        }
    }

    function _package(bytes32 root) internal view returns (Work[] memory works) {
        Work[] storage list = _packages[root];
        works = new Work[](list.length);
        for (uint256 i; i < works.length; ++i) {
            works[i] = list[i];
        }
    }

    // ------------------------------------------------------------------ curation and consent

    function _evidence(bytes32 root) internal pure returns (bytes32) {
        return keccak256(abi.encode("vote and TDH snapshot evidence", root));
    }

    /// @dev Curation signer 1 attests the root; anyone registers it; the CURATOR role appends
    ///      the evidence statement (subject `(address(0), uint256(root))`).
    function _approve(bytes32 root) internal {
        bytes32 evidence = _evidence(root);
        bytes memory signature = _sign(
            signer1, verifier.approvalDigest(root, evidence, verifier.signerEpoch(signer1))
        );
        registry.registerPackage(root, evidence, abi.encode(signer1, signature));
        vm.prank(curator);
        statements.appendCurator(
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
    }

    /// @dev `account` accepts `root`, signed by itself (no identity yet) or its authority.
    function _accept(bytes32 root, address account) internal {
        PartyAcceptance memory a = PartyAcceptance(
            account, _profileId(account), _profileDoc(account), uint64(block.timestamp + 1 days)
        );
        uint256 id = accounts.artistIdOf(account);
        address signer = id == 0 ? account : accounts.authorityOf(id);
        bytes memory signature =
            abi.encodePacked(signer, _sign(signer, registry.acceptanceDigest(root, a)));
        registry.acceptPackage(root, a, signature);
    }

    /// @dev Approves `works` as one package and records every party's acceptance.
    function _publish(Work[] memory works) internal returns (bytes32 root) {
        root = _rootOf(works);
        _approve(root);
        for (uint256 i; i < works.length; ++i) {
            Party[] memory parties = works[i].item.parties;
            for (uint256 j; j < parties.length; ++j) {
                if (registry.acceptedAs(root, parties[j].account) == 0) {
                    _accept(root, parties[j].account);
                }
            }
        }
    }

    /// @dev The start request for item `index`, with a fresh move nonce signed by the lead
    ///      artist's current authority.
    function _mintData(bytes32 root, Work[] memory works, uint256 index)
        internal
        returns (bytes memory)
    {
        PackageItem memory item = works[index].item;
        uint256 artistId = accounts.artistIdOf(item.parties[0].account);
        return _mintDataSignedBy(
            root, works, index, accounts.authorityOf(artistId), nextMoveNonce[artistId]++
        );
    }

    function _mintDataSignedBy(
        bytes32 root,
        Work[] memory works,
        uint256 index,
        address authority,
        uint256 nonce
    ) internal view returns (bytes memory) {
        PackageItem memory item = works[index].item;
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes32 digest = registry.moveDigest(root, WorksHashing.itemHash(item), nonce, deadline);
        MoveAuthorization memory move = MoveAuthorization(
            nonce, deadline, abi.encodePacked(authority, _sign(authority, digest))
        );
        return abi.encode(StreamMintRequest(root, item, _proofOf(works, index), move));
    }

    // ------------------------------------------------------------------ the auction

    /// @dev Starts item `index`; returns the sale ID and the new token ID.
    function _start(bytes32 root, Work[] memory works, uint256 index)
        internal
        returns (uint256 saleId, uint256 tokenId)
    {
        saleId = auction.start(address(stream), _mintData(root, works, index));
        tokenId = stream.totalMinted();
        assertEq(saleId, auction.saleIdOf(address(stream), tokenId), "sale ID");
        assertEq(auction.auction(saleId).tokenId, tokenId, "token ID");
    }

    /// @dev Starts item `index` through `SaleStarter`: vaults deployed and the record opened in
    ///      the same transaction.
    function _startAndOpen(bytes32 root, Work[] memory works, uint256 index)
        internal
        returns (uint256 saleId, uint256 tokenId)
    {
        saleId = starter.start(
            auction, address(stream), _mintData(root, works, index), works[index].media
        );
        tokenId = auction.auction(saleId).tokenId;
    }

    /// @dev Opens the record of `tokenId` (anyone may, with the item and its media).
    function _open(uint256 tokenId, Work memory w) internal {
        facts.open(address(stream), tokenId, w.item, w.media);
    }

    function _ethBid(uint256 saleId, address bidder, uint256 amount) internal {
        vm.deal(bidder, bidder.balance + amount);
        vm.prank(bidder);
        auction.bid{ value: amount }(saleId, address(0));
    }

    function _settleAtEnd(uint256 saleId) internal {
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
    }

    /// @dev Starts, takes one ETH bid from `bidder` and settles: a work sold for `price`.
    function _sell(bytes32 root, Work[] memory works, uint256 index, address bidder, uint256 price)
        internal
        returns (uint256 tokenId)
    {
        uint256 saleId;
        (saleId, tokenId) = _start(root, works, index);
        _ethBid(saleId, bidder, price);
        _settleAtEnd(saleId);
    }

    // ------------------------------------------------------------------ statements

    function _platformStatement(address token, uint256 id, bytes32 kind, string memory uri)
        internal
        returns (bytes32 entryHash)
    {
        vm.prank(platform);
        entryHash = statements.appendPlatform(
            Statement(
                token,
                id,
                kind,
                keccak256("6529-works/dispute-outcome/1"),
                HashRef(HASH_SHA256, keccak256(bytes(uri))),
                uri,
                bytes32(0),
                bytes32(0)
            )
        );
    }

    // ------------------------------------------------------------------ content

    /// @dev Uploads `stored` in `CHUNK_SIZE` chunks and registers its manifest. `sha` is the
    ///      decoded media's SHA-256 (the store does not recompute it).
    function _upload(
        bytes memory stored,
        IContentStore.Encoding encoding,
        string memory mime,
        bytes32 sha
    ) internal returns (bytes32 fileId) {
        bytes32[] memory hashes = _writeChunks(stored);
        fileId = store.registerManifest(hashes, stored.length, uint8(encoding), mime, sha);
    }

    /// @dev Registers the manifest of `stored` without uploading any chunk.
    function _registerOnly(
        bytes memory stored,
        IContentStore.Encoding encoding,
        string memory mime,
        bytes32 sha
    ) internal returns (bytes32 fileId) {
        fileId = store.registerManifest(
            _chunkHashes(stored), stored.length, uint8(encoding), mime, sha
        );
    }

    function _writeChunks(bytes memory stored) internal virtual returns (bytes32[] memory hashes) {
        uint256 size = store.CHUNK_SIZE();
        hashes = new bytes32[]((stored.length + size - 1) / size);
        for (uint256 i; i < hashes.length; ++i) {
            (hashes[i],) = store.writeChunk(_slice(stored, i * size, size));
        }
    }

    function _chunkHashes(bytes memory stored) internal view returns (bytes32[] memory hashes) {
        uint256 size = store.CHUNK_SIZE();
        hashes = new bytes32[]((stored.length + size - 1) / size);
        for (uint256 i; i < hashes.length; ++i) {
            hashes[i] = keccak256(_slice(stored, i * size, size));
        }
    }

    function _storeText(bytes memory text, string memory mime) internal returns (bytes32) {
        return _upload(text, IContentStore.Encoding.Identity, mime, sha256(text));
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

    /// @dev `n` pseudo-random bytes.
    function _bytes(uint256 n, uint256 seed) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; i += 32) {
            bytes32 word = keccak256(abi.encode(seed, i));
            for (uint256 j; j < 32 && i + j < n; ++j) {
                out[i + j] = word[j];
            }
        }
    }

    /// @dev Runs the permissionless base64 attestation to completion, bounded.
    function _attestAll(bytes32 fileId) internal {
        uint256 calls = store.MAX_CHUNKS() / 48 + 1;
        for (uint256 i; i < calls; ++i) {
            if (store.attestBase64(fileId, 48)) return;
        }
        revert("attestBase64 did not complete");
    }

    // ------------------------------------------------------------------ assertions

    /// @dev An integration finding still open: `call` (an external `check_*` function of this
    ///      contract asserting the intended behaviour) must fail, with the custom error `reason`
    ///      when it is nonzero, so an unrelated failure cannot pass for the finding. When the
    ///      finding is fixed this fails, and the check becomes a regular test.
    function _expectFailure(bytes memory call, bytes4 reason, string memory finding) internal {
        (bool ok, bytes memory returned) = address(this).call(call);
        assertFalse(ok, string.concat("finding fixed: make the check a regular test: ", finding));
        if (reason != bytes4(0)) {
            assertGe(returned.length, 4, finding);
            assertEq(bytes4(returned), reason, string.concat("unexpected failure: ", finding));
        }
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool same = true;
            for (uint256 j; same && j < n.length; ++j) {
                same = h[i + j] == n[j];
            }
            if (same) return true;
        }
        return false;
    }
}
