// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStreamExtension } from "src/interfaces/IStreamExtension.sol";
import { IStreamViews } from "src/interfaces/IStreamViews.sol";
import { IWorkDelivery } from "src/interfaces/IWorkDelivery.sol";
import { WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { StreamLayout } from "src/stream/StreamLayout.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice A view extension that answers Stream's fallback views with other facts: another
///         serial, no seed policy and another collection name; anything else reverts.
contract HostileExtension {
    bool public broken;

    function setBroken(bool on) external {
        broken = on;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IStreamExtension).interfaceId || id == 0x01ffc9a7;
    }

    function work(uint256) external view returns (IStreamViews.WorkCore memory w) {
        require(!broken, "broken");
        w.itemHash = keccak256("another item");
        w.artistId = 999;
        w.collectionId = 1;
        w.serial = 999;
    }

    function collection(uint256) external view returns (IStreamViews.Collection memory c) {
        require(!broken, "broken");
        c.name = "Another name";
    }

    fallback() external {
        revert("hostile");
    }
}

/// @notice A delivery contract answering every `preferredLocator` with one raw answer, or burning
///         all the gas it is given.
contract RawDelivery {
    address public immutable records;
    address public immutable predecessor;
    bytes internal _raw;
    bool internal _burn;

    constructor(address records_, address predecessor_) {
        records = records_;
        predecessor = predecessor_;
    }

    function set(bytes memory raw, bool burn) external {
        _raw = raw;
        _burn = burn;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IWorkDelivery).interfaceId || id == 0x01ffc9a7;
    }

    function preferredLocator(uint256, bytes32) external view returns (bytes memory) {
        if (_burn) {
            while (true) { }
        }
        bytes memory raw = _raw;
        assembly ("memory-safe") {
            return(add(raw, 0x20), mload(raw))
        }
    }
}

/// @notice What the pinned renderer of a finalized work shows can be changed by no replaceable
///         contract (reviews A H-1 and B M2): it reads Stream's facts natively (`coreOf`,
///         `extsload`), never through the view extension; a delivery answer that is not UTF-8 is
///         no locator; and a work whose image primary is inlined never asks the delivery contract
///         for anything. Also the `tokenURI` budget with linked chunks (review B I4).
contract RendererPermanenceTest is IntegrationBase {
    address internal artist;
    address internal collector = makeAddr("permanenceCollector");
    /// @dev Finalized works, repin renounced: a primary served by locator, a VRF work, and an
    ///      on-chain image primary inlined beside a preview too large to inline.
    uint256 internal byLocator;
    uint256 internal vrfWork;
    uint256 internal inlined;

    function setUp() public override {
        super.setUp();
        artist = _actor("permanenceArtist");
        Work[] memory works = new Work[](3);
        works[0] = _work(artist, collectionId);
        works[1] = _work(artist, collectionId);
        works[1].item.seedPolicy = uint8(SeedPolicy.VRF);
        works[2] = _inlinedWithPreview();
        bytes32 root = _publish(works);
        _keep(root, works);
        uint256 requestId = entropy.requestSeed(works[1].item, root, _proofOf(works, 1));
        coordinator.fulfill(requestId, uint256(keccak256("permanence seed")));
        uint256[] memory ids = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            ids[i] = _sell(root, works, i, collector, 1 ether);
            records.openRecord(ids[i], works[i].item, works[i].media);
            if (i == 2) {
                _attestAll(works[2].media[0].fileId);
                records.syncOnChain(ids[i], 0, type(uint256).max);
            }
            bytes32 state = records.workStateHash(ids[i]);
            vm.prank(artist);
            records.finalize(ids[i], state);
            _renounce(ids[i], WorkPowers.RENDERER_REPIN);
        }
        (byLocator, vrfWork, inlined) = (ids[0], ids[1], ids[2]);
    }

    function _inlinedWithPreview() internal returns (Work memory w) {
        bytes memory png = _bytes(3_000, 77);
        bytes32 sha = sha256(png);
        bytes memory preview = _bytes(4_096, 78); // `Identity`: weight 32 KiB, over the bound
        w.media = new MediaFile[](2);
        w.media[0] = MediaFile(
            _upload(bytes(Base64.encode(png)), IContentStore.Encoding.Base64, "image/png", sha),
            sha,
            uint8(FileRole.PRIMARY)
        );
        w.media[1] = MediaFile(
            _upload(preview, IContentStore.Encoding.Identity, "image/png", sha256(preview)),
            sha256(preview),
            uint8(FileRole.PREVIEW)
        );
        w.item = _item(artist, collectionId, sha, w.media, _record("Inlined"));
    }

    function _renounce(uint256 tokenId, uint16 powers) internal {
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _sign(
            artist,
            _typedDigest(
                address(records),
                keccak256(abi.encode(Typehashes.RENOUNCE_POWERS, tokenId, powers, state, deadline))
            )
        );
        records.renounce(tokenId, powers, state, deadline, sig);
    }

    function _uris() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                stream.tokenURI(byLocator), stream.tokenURI(vrfWork), stream.tokenURI(inlined)
            )
        );
    }

    /// @dev The genesis extension: the one contract Stream's constructor creates.
    function _extension() internal view returns (address) {
        return vm.computeCreateAddress(address(stream), 1);
    }

    function _setDelivery(address next) internal {
        _govern(
            hotAdmin,
            address(records),
            abi.encodeCall(records.setDelivery, (records.delivery(), next))
        );
    }

    // ------------------------------------------------------------------ the view extension

    /// @dev Review A H-1: replacing the view extension, with one that answers other facts or one
    ///      that reverts, through the real 30-day path, changes no byte of a finalized work's
    ///      metadata: serial, collection name and seed are read from Stream itself.
    function test_AHostileExtensionNeitherChangesNorBreaksTokenUri() public {
        assertTrue(
            IStreamExtension(_extension()).supportsInterface(type(IStreamExtension).interfaceId)
        );
        bytes32 before = _uris();
        assertTrue(_contains(stream.tokenURI(vrfWork), '"trait_type":"Seed"'), "the seed is shown");
        HostileExtension hostile = new HostileExtension();
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.setDependency, ("EXTENSION", _extension(), address(hostile)))
        );
        // The fallback now answers the other facts...
        assertEq(IStreamViews(address(stream)).work(byLocator).serial, 999);
        // ...and the metadata does not move.
        assertEq(_uris(), before, "metadata unchanged");
        hostile.setBroken(true);
        assertEq(_uris(), before, "metadata unchanged with a reverting extension");
    }

    /// @dev Review E (missing test 4): the renderer decodes the collection name from Stream's
    ///      storage string in both forms, end to end. Names of 31 bytes (the short form's
    ///      largest), 32 and 73 bytes (the long form) and multibyte UTF-8 are written into the
    ///      name's slot (`StreamLayout.collectionSlot + 2`); `tokenURI` shows each exactly. A
    ///      wrong decode empties or garbles the name, which this catches (the budget test's
    ///      256-byte name only measures gas).
    function test_CollectionNamesOfEveryLengthAndMultibyteAreShownExactly() public {
        string[5] memory names = [
            "Thirty-one bytes, a short name.",
            "Thirty-two bytes of a long name!",
            "A collection name of seventy-three bytes, stored apart in its own words!!",
            unicode"Ünïcödé コレクション ✓",
            "A"
        ];
        assertEq(bytes(names[0]).length, 31);
        assertEq(bytes(names[1]).length, 32);
        assertEq(bytes(names[2]).length, 73);
        uint256 slot = uint256(StreamLayout.collectionSlot(collectionId)) + 2;
        for (uint256 i; i < names.length; ++i) {
            _storeString(slot, bytes(names[i]));
            assertEq(IStreamViews(address(stream)).collection(collectionId).name, names[i]);
            string memory uri = stream.tokenURI(byLocator);
            assertTrue(
                _contains(
                    uri, string.concat('{"trait_type":"Collection","value":"', names[i], '"}')
                ),
                names[i]
            );
        }
    }

    /// @dev Writes `value` at `slot` as Solidity lays out a storage string.
    function _storeString(uint256 slot, bytes memory value) internal {
        uint256 length = value.length;
        if (length < 32) {
            bytes32 head;
            assembly ("memory-safe") {
                head := mload(add(value, 0x20))
            }
            // The bytes in place, left-aligned, the rest zero, and twice the length in the low
            // byte.
            head = (head & ~bytes32((uint256(1) << (8 * (32 - length))) - 1)) | bytes32(length * 2);
            vm.store(address(stream), bytes32(slot), head);
            return;
        }
        vm.store(address(stream), bytes32(slot), bytes32(length * 2 + 1));
        bytes32 data = keccak256(abi.encode(slot));
        for (uint256 i; i * 32 < length; ++i) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(value, 0x20), mul(i, 0x20)))
            }
            vm.store(address(stream), bytes32(uint256(data) + i), word);
        }
    }

    // ------------------------------------------------------------------ the delivery contract

    /// @dev Review B M2: a delivery contract answering a URI with a byte from 0x80, a control
    ///      byte, a quote or a backslash changes no byte of a finalized work's `tokenURI` (the
    ///      records satellite serves the work's own answer: no locator) and never makes it
    ///      revert. A printable-ASCII URI is served as before.
    function test_AnUnusableLocatorLeavesTokenUriUnchanged() public {
        string memory before = stream.tokenURI(byLocator);
        assertFalse(_contains(before, "media_url"), "no locator to begin with");
        RawDelivery raw = new RawDelivery(address(records), records.delivery());
        _setDelivery(address(raw));
        bytes[5] memory bad = [
            bytes(hex"61723a2f2fff"),
            hex"61723a2f2fc3a9",
            hex"61723a2f2f0a",
            bytes('ar://x","image":"y'),
            hex"61723a2f2f5c22"
        ];
        for (uint256 i; i < bad.length; ++i) {
            raw.set(abi.encode(IWorkDelivery.Location(1, string(bad[i])), uint256(0)), false);
            assertEq(stream.tokenURI(byLocator), before, vm.toString(i));
        }
        raw.set(abi.encode(IWorkDelivery.Location(1, "ar://fine"), uint256(0)), false);
        assertTrue(_contains(stream.tokenURI(byLocator), '"media_url":"ar://fine"'));
    }

    /// @dev Review B M2: the preview is read only when it is used, so an inlined image primary
    ///      never asks the delivery contract: a delivery contract that burns all its gas leaves
    ///      such a work's metadata unchanged. A work served by locator reverts (shortfall) until
    ///      the delivery contract is replaced: the accepted limitation (LIM row).
    function test_AnInlinedImagePrimaryNeverAsksTheDeliveryContract() public {
        string memory before = stream.tokenURI(inlined);
        assertTrue(_contains(before, '"image":"data:image/png;base64,'), "inlined");
        RawDelivery raw = new RawDelivery(address(records), records.delivery());
        _setDelivery(address(raw));
        raw.set("", true);
        assertEq(stream.tokenURI(inlined), before, "unchanged");
        vm.expectRevert();
        this.uriOf{ gas: 16_000_000 }(byLocator);
    }

    function uriOf(uint256 tokenId) external view returns (string memory) {
        return stream.tokenURI(tokenId);
    }

    // ------------------------------------------------------------------ linked chunks

    /// @dev A file stored as linked chunks of `parts` equal parts each (never whole chunks).
    function _linkedUpload(bytes memory stored, uint256 parts, bytes32 sha)
        internal
        returns (bytes32 fileId)
    {
        uint256 size = store.CHUNK_SIZE();
        uint256 count = (stored.length + size - 1) / size;
        bytes32[] memory hashes = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            bytes memory chunk = _slice(stored, i * size, size);
            hashes[i] = keccak256(chunk);
            if (parts == 1) {
                store.writeChunk(chunk);
                continue;
            }
            uint256 n = parts < chunk.length ? parts : chunk.length;
            uint256 step = (chunk.length + n - 1) / n;
            uint256 k = (chunk.length + step - 1) / step;
            bytes32[] memory ph = new bytes32[](k);
            for (uint256 j; j < k; ++j) {
                (ph[j],) = store.writeChunk(_slice(chunk, j * step, step));
            }
            assertEq(store.linkChunk(ph), hashes[i]);
            assertEq(store.chunkPointer(hashes[i]), address(0), "linked, not whole");
        }
        fileId = store.registerManifest(
            hashes, stored.length, uint8(IContentStore.Encoding.Base64), "image/png", sha
        );
    }

    /// @dev Review B I4: the `tokenURI` budget with the primary at the renderer's 256 KiB
    ///      threshold stored as linked chunks. Each part costs one storage read and one code
    ///      copy per chunk read; the renderer reads a file only when no chunk has more than
    ///      `MAX_PARTS_PER_CHUNK` (4) parts (RND-26, WS-50), so a file of more is served by its
    ///      locator. Returns the call and the token.
    function _linkedRow(uint256 parts) internal returns (bytes memory call) {
        (call,) = _linkedWork(parts);
    }

    function _linkedWork(uint256 parts) internal returns (bytes memory call, uint256 tokenId) {
        bytes memory png = _bytes(262_144 / 4 * 3, 900 + parts);
        bytes32 sha = sha256(png);
        Work memory w;
        w.media = new MediaFile[](1);
        w.media[0] = MediaFile(
            _linkedUpload(bytes(Base64.encode(png)), parts, sha), sha, uint8(FileRole.PRIMARY)
        );
        w.item = _item(artist, collectionId, sha, w.media, _record("Linked"));
        Work[] memory works = _one(w);
        bytes32 root = _publish(works);
        (, tokenId) = _start(root, works, 0);
        records.openRecord(tokenId, w.item, w.media);
        _attestAll(w.media[0].fileId);
        records.syncOnChain(tokenId, 0, type(uint256).max);
        call = abi.encodeCall(stream.tokenURI, (tokenId));
        assertEq(
            _contains(stream.tokenURI(tokenId), '"image":"data:image/png;base64,'),
            parts <= 4,
            "inlined exactly up to the part bound"
        );
    }

    /// @dev Cold gas of `call`, as `TokenUriBudget` measures it (after every `_measure`).
    function _coldUsed(bytes memory call, uint256 used) internal returns (uint256) {
        return used + COLD_ACCOUNT_SURCHARGE
            * _growth(collector, address(stream), call, 0).coldAccounts.length;
    }

    /// @dev Whole chunks against 4 parts per chunk, the most the renderer reads from: each part
    ///      of each chunk read costs about 7,000 gas (one storage read and one code copy, and
    ///      the link's own word), about 78,000 per extra part per chunk of a 256 KiB primary (11
    ///      chunks). With every other
    ///      cap at once the bound holds 8M (`TokenUriBudget`'s linked row; WS-50, RND-26).
    function test_Budget_LinkedChunks() public {
        bytes memory a = _linkedRow(1);
        bytes memory b = _linkedRow(4);
        (, uint256 whole) = _measure(collector, address(stream), a, 0);
        (, uint256 linked) = _measure(collector, address(stream), b, 0);
        whole = _coldUsed(a, whole);
        linked = _coldUsed(b, linked);
        console2.log("tokenURI, 256 KiB primary, whole chunks:", whole);
        console2.log("tokenURI, 256 KiB primary, 4 parts per chunk:", linked);
        assertLt(linked, TOKEN_URI_BUDGET, "a light record within the 8M budget");
        uint256 perPart = (linked - whole) / (3 * 11);
        console2.log("gas per part per chunk read:", perPart);
        assertLt(perPart, 8_000, "the per-part cost the stated bound assumes");
    }

    /// @dev Anyone can link a chunk from up to 256 parts, before the artist writes it or
    ///      instead: a file with a chunk of more than 4 parts is served by its locator, so
    ///      `tokenURI` stays within its budget, and once anyone writes that chunk whole (or links
    ///      it from 4 parts or fewer) the file is inlined again: the part count only falls.
    function test_Budget_AHeavilyLinkedFileIsServedByLocatorUntilCompacted() public {
        (bytes memory call, uint256 tokenId) = _linkedWork(256);
        (, uint256 used) = _measure(collector, address(stream), call, 0);
        assertLt(_coldUsed(call, used), TOKEN_URI_BUDGET, "within the budget past the bound");
        bytes32 fileId = records.mediaOf(tokenId)[0].fileId;
        assertEq(store.maxParts(fileId), 256);
        uint256 count = store.fileInfo(fileId).chunkCount;
        uint256 size = store.CHUNK_SIZE();
        uint256 length = store.fileInfo(fileId).length;
        for (uint256 i; i < count; ++i) {
            store.writeChunk(store.read(fileId, i * size, i + 1 < count ? size : length - i * size));
        }
        assertEq(store.maxParts(fileId), 1, "whole now");
        assertTrue(_contains(stream.tokenURI(tokenId), '"image":"data:image/png;base64,'));
    }
}
