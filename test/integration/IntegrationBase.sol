// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IERC5267 } from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { Role, Statement } from "src/interfaces/IStatementLog.sol";
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
import { WorksDeployment } from "./WorksDeployment.sol";

/// @notice Actors, package building, signatures and sale helpers shared by the end-to-end flows.
/// @dev Every helper drives the real contracts the way an off-chain tool or a wallet would: it
///      signs EIP-712 digests read from the contracts, builds OpenZeppelin `MerkleProof` trees over
///      `WorksHashing.leaf(itemHash)` and submits ordinary transactions.
abstract contract IntegrationBase is WorksDeployment {
    /// @dev A package item with the media list its `mediaHash` commits to.
    struct Work {
        PackageItem item;
        MediaFile[] media;
    }

    /// @dev EIP-7825 (Fusaka): no transaction may carry more than 2^24 gas.
    uint256 internal constant TX_GAS_CAP = 1 << 24;
    uint256 internal constant START_BUDGET = 350_000;
    uint256 internal constant TOKEN_URI_BUDGET = 8_000_000;
    /// @dev The selector of `Error(string)`, what a failed `require` with a message reverts with.
    bytes4 internal constant ERROR_STRING = 0x08c379a0;

    mapping(address account => uint256 pk) internal keyOf;
    mapping(uint256 artistId => uint256 nonce) internal nextMoveNonce;
    uint256 internal collectionId;
    uint256 private _salt;
    /// @dev Packages kept across calls (memory cannot outlive a call), by root.
    mapping(bytes32 root => Work[]) private _packages;

    function setUp() public virtual {
        _deployWorks();
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

    /// @dev The EIP-712 digest of `structHash` in `target`'s own domain (read with EIP-5267), as
    ///      a wallet computes it for a contract that exposes no digest helper.
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
        w.media[0] = MediaFile(fileId, sha, FileRole.PRIMARY);
        w.item = _item(
            lead, collection, sha, w.media, _record(string.concat("Work ", vm.toString(salt)))
        );
    }

    function _item(
        address lead,
        uint256 collection,
        bytes32 contentHash,
        MediaFile[] memory media,
        bytes32 recordFileId
    ) internal view returns (PackageItem memory item) {
        item.kind = ItemKind.ORIGINAL;
        item.collectionId = collection;
        item.contentHash = contentHash;
        item.mediaHash = WorksHashing.mediaHash(media);
        item.recordFileId = recordFileId;
        item.parties = new Party[](1);
        item.parties[0] = Party(lead, PartyRole.ARTIST);
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(uint256(uint160(lead)), address(0), 100_000);
        item.license = License("CC0-1.0", cc0TextFileId);
        item.seedPolicy = SeedPolicy.NONE;
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        item.edition = EditionTerms(EditionFormat.FIXED, 0, 0, 0, address(0), bytes32(0), "");
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

    /// @dev Keeps `works` under `root` in storage, field by field (Solidity cannot copy nested
    ///      struct arrays from memory to storage).
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
        bytes memory signature = _sign(signer1, verifier.approvalDigest(root, evidence));
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
        uint256 id = artists.artistIdOf(account);
        address signer = id == 0 ? account : artists.authorityOf(id);
        bytes memory signature = _sign(signer, registry.acceptanceDigest(root, a));
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
        uint256 artistId = artists.artistIdOf(item.parties[0].account);
        return _mintDataSignedBy(
            root, works, index, artists.authorityOf(artistId), nextMoveNonce[artistId]++
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
        MoveAuthorization memory move = MoveAuthorization(nonce, deadline, _sign(authority, digest));
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
    }

    function _ethBid(uint256 saleId, address bidder, uint256 amount) internal {
        vm.deal(bidder, bidder.balance + amount);
        vm.prank(bidder);
        auction.bid{ value: amount }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, bidder, amount, 0, 0, "")
        );
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

    // ------------------------------------------------------------------ assertions

    /// @dev An integration finding still open: `call` (an external `check_*` function of this
    ///      contract asserting the intended behavior) must fail, with the custom error `reason`
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

    // ------------------------------------------------------------------ gas

    uint256[4] internal base64Sizes = [uint256(32_768), 65_536, 131_072, 262_144];
    uint256[2] internal identitySizes = [uint256(32_768), 65_536];

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
        w.media[0] = MediaFile(fileId, sha, FileRole.PRIMARY);
        w.item = _item(lead, collectionId, sha, w.media, _record(name));
    }

    /// @dev The `tokenURI` gas matrix (ADR 0001 section 8, ADR 0003): one work per row, sold,
    ///      opened, attested and synced on-chain, then `Stream.tokenURI` measured from a cold
    ///      start through the whole path (Stream, WorkRecords, the renderer, the content store,
    ///      the statement log). Rows: 32, 64, 128 and 256 KiB of base64-stored media, and 32 and
    ///      64 KiB of identity media. Each row must fit 8M gas and inline exactly when the
    ///      renderer's cost-weighted threshold allows it.
    function _tokenUriMatrix(address lead, address reader) internal {
        Work[] memory works = new Work[](6);
        for (uint256 i; i < 4; ++i) {
            bytes memory media = _bytes(base64Sizes[i] / 4 * 3, i);
            works[i] = _storedWork(
                lead,
                bytes(Base64.encode(media)),
                IContentStore.Encoding.Base64,
                sha256(media),
                string.concat("Base64 ", vm.toString(base64Sizes[i]))
            );
        }
        for (uint256 i; i < 2; ++i) {
            bytes memory media = _bytes(identitySizes[i], 10 + i);
            works[4 + i] = _storedWork(
                lead,
                media,
                IContentStore.Encoding.Identity,
                sha256(media),
                string.concat("Identity ", vm.toString(identitySizes[i]))
            );
        }
        bytes32 root = _publish(works);
        uint256[] memory ids = new uint256[](6);
        for (uint256 i; i < 6; ++i) {
            (, ids[i]) = _start(root, works, i);
            records.openRecord(ids[i], works[i].item, works[i].media);
            if (i < 4) {
                while (!store.attestBase64(works[i].media[0].fileId)) { }
            }
            records.syncOnChain(ids[i]);
        }
        console2.log("Stream.tokenURI gas, cold (stored bytes of the primary file)");
        for (uint256 i; i < 6; ++i) {
            (, uint256 used) =
                _measure(reader, address(stream), abi.encodeCall(stream.tokenURI, (ids[i])), 0);
            string memory label = i < 4
                ? string.concat("  base64   ", vm.toString(base64Sizes[i]))
                : string.concat("  identity ", vm.toString(identitySizes[i - 4]));
            console2.log(label, used);
            assertLe(used, TOKEN_URI_BUDGET, label);
            bool inlined = _contains(stream.tokenURI(ids[i]), "data:image/png;base64,");
            // Base64 inlines up to the 256 KiB threshold; identity media counts eight times, so
            // 32 KiB inlines and 64 KiB falls back to its locator.
            assertEq(inlined, i != 5, string.concat(label, ": inline as expected"));
        }
    }

    /// @dev Calldata gas: the EIP-2028 price and the EIP-7623 floor.
    function _calldataGas(bytes memory data)
        internal
        pure
        returns (uint256 standard, uint256 floor)
    {
        uint256 zeros;
        for (uint256 i; i < data.length; ++i) {
            if (data[i] == 0) ++zeros;
        }
        uint256 nonzero = data.length - zeros;
        standard = zeros * 4 + nonzero * 16;
        floor = (zeros + nonzero * 4) * 10;
    }

    /// @dev The whole transaction: intrinsic, calldata (or its floor) and measured execution.
    function _txGas(bytes memory data, uint256 execution) internal pure returns (uint256 total) {
        (uint256 standard, uint256 floor) = _calldataGas(data);
        total = 21_000 + standard + execution;
        if (21_000 + floor > total) total = 21_000 + floor;
    }

    /// @dev Cools every deployed contract (accounts and storage), as at the start of a new
    ///      transaction.
    function _coolAll() internal {
        address[22] memory all = [
            address(store),
            address(dependencies),
            address(consolidation),
            address(artists),
            address(releaseVerifier),
            address(splitFactory),
            address(allowlist),
            address(economics),
            address(escrow),
            address(verifier),
            address(registry),
            address(statements),
            address(renderer),
            address(entropy),
            address(stream),
            address(records),
            address(editions),
            address(auction),
            address(fixedSale),
            address(dutchSale),
            address(manager),
            address(delegation)
        ];
        for (uint256 i; i < all.length; ++i) {
            vm.cool(all[i]);
        }
    }

    /// @dev Calls `target` with `data` as `from` (and `value`) from a cold start and returns the
    ///      whole-transaction gas: 21,000, the calldata (or its EIP-7623 floor) and the called
    ///      frame's own execution gas before refunds (`vm.lastCallGas`), which is what a
    ///      transaction to `target` executes: its target is warm and its value is free. A revert
    ///      bubbles up.
    function _measure(address from, address target, bytes memory data, uint256 value)
        internal
        returns (uint256 total, uint256 execution)
    {
        vm.deal(from, from.balance + value);
        _coolAll();
        vm.prank(from);
        (bool ok, bytes memory reason) = target.call{ value: value }(data);
        execution = _lastCallGasUsed();
        _bubble(ok, reason);
        total = _txGas(data, execution);
    }

    /// @dev `vm.lastCallGas().gasTotalUsed`, read by hand: the pinned forge-std declares a sixth
    ///      `Gas` field (`gasStateUsed`) that Foundry 1.7.1 does not return yet, so the typed
    ///      call fails to decode.
    function _lastCallGasUsed() internal view returns (uint256 used) {
        (bool ok, bytes memory ret) =
            address(vm).staticcall(abi.encodeWithSignature("lastCallGas()"));
        require(ok && ret.length >= 64, "lastCallGas");
        assembly ("memory-safe") {
            used := mload(add(ret, 0x40))
        }
    }
}
