// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { WorkFacts } from "src/core/WorkFacts.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { Facts, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";

/// @notice A token contract as `WorkFacts` sees it: the item hash of each token, its modules,
///         and a metadata hook that does nothing.
contract SymFactsToken {
    mapping(uint256 tokenId => bytes32) public itemHashOf;
    mapping(bytes32 slot => address) public moduleOf;

    function setItemHash(uint256 tokenId, bytes32 h) external {
        itemHashOf[tokenId] = h;
    }

    function setModule(bytes32 slot, address module) external {
        moduleOf[slot] = module;
    }

    function emitMetadataUpdate(uint256, uint256) external { }
}

/// @notice A content store whose answers the proof sets: one file description and one
///         completeness answer for every file, and the SHA-256 digest of each file.
contract SymFactsStore {
    mapping(bytes32 fileId => bytes32) public sha256Of;
    uint256 public chunkCount = 1;
    uint8 public digestKind;
    uint8 public encoding;
    bool public complete = true;

    function setSha(bytes32 fileId, bytes32 digest) external {
        sha256Of[fileId] = digest;
    }

    function set(uint256 chunkCount_, uint8 digestKind_, uint8 encoding_, bool complete_) external {
        (chunkCount, digestKind, encoding, complete) =
        (chunkCount_, digestKind_, encoding_, complete_);
    }

    function isComplete(bytes32) external view returns (bool) {
        return complete;
    }

    function fileInfo(bytes32) external view returns (IContentStore.FileInfo memory info) {
        info.chunkCount = chunkCount;
        info.digestKind = digestKind;
        info.encoding = encoding;
    }
}

/// @notice A renderer: any contract with code.
contract SymFactsRenderer {
    function tokenURI(address, uint256) external pure returns (string memory) {
        return "data:,";
    }
}

/// @notice Halmos proofs on the permanent record (`src/core/WorkFacts.sol`): the guarantees it
///         keeps whatever the token's RECORDS module does. Run with
///         `FOUNDRY_PROFILE=symbolic halmos --contract WorkFactsSymbolicTest`.
/// @dev Each proof prepares a starting state and then runs one action, and checks the rule
///      across that action. Each proof takes the starting states its rule depends on (stated on
///      the proof). A starting state is built by the RECORDS module from the opened
///      record, in this order, each step taken or not: replace the license (by "cc0-1.0" on the
///      CC0 token, "Apache-2.0" on the other) and the record file, finalize, lock the license,
///      lock the pin, mark the work on-chain complete. The action is any of the seven
///      `WorkFacts` writes (`open` again with the item the token was minted from,
///      `markOnChainComplete`, `setRecord`, `setLicense`, `finalize`, `repin`, `lock`), from any
///      caller (the RECORDS module or anyone else), with a symbolic record file, license text
///      file and lock flags.
///      Bounds: one action after each of the proof's starting states. One action from the opened
///      record takes 84 paths, so two in a row would take about 7,000 a proof, past the CI
///      budget; every rule here is a property of a single action, so one action from each
///      starting state is the step the rules need for those states, not for every state a longer
///      history could reach. Also: a
///      license identifier from a fixed list ("CC0-1.0", "cc0-1.0", "MIT", "", "M!T": CC0 in two
///      cases, a valid one, an empty one, an invalid one); a renderer from two (`R1`, `R2`) and a
///      RENDERER module of `R1` or none; the content store's answers (chunk count up to 255,
///      digest kind, encoding, completeness) symbolic but the same for every file. Token 1 opens
///      with CC0, token 2 with MIT.
contract WorkFactsSymbolicTest is Test {
    address internal constant MODULE = address(0xEC0D);
    bytes32 internal constant CC0_TEXT = keccak256("cc0 text");
    bytes32 internal constant MIT_TEXT = keccak256("mit text");

    WorkFacts internal facts;
    SymFactsToken internal token;
    SymFactsStore internal store;
    address internal r1;
    address internal r2;

    /// @dev What a step may change, read before and after it.
    struct Snap {
        bytes32 media;
        bytes32 recordFileId;
        bytes32 licenseId;
        bytes32 licenseText;
        address renderer;
        bool finalized;
        bool onChainComplete;
        bool licenseLocked;
        bool repinLocked;
    }

    function setUp() public {
        token = new SymFactsToken();
        store = new SymFactsStore();
        facts = new WorkFacts(address(store), CC0_TEXT);
        r1 = address(new SymFactsRenderer());
        r2 = address(new SymFactsRenderer());
        token.setModule(Slots.RECORDS, MODULE);
        token.setModule(Slots.RENDERER, r1);
        for (uint256 id = 1; id <= 2; ++id) {
            (PackageItem memory item, MediaFile[] memory media) = _item(id);
            for (uint256 i; i < media.length; ++i) {
                store.setSha(media[i].fileId, media[i].sha256Hash);
            }
            token.setItemHash(id, WorksHashing.itemHash(item));
            facts.open(address(token), id, item, media);
        }
    }

    // ------------------------------------------------------------------------------ proofs

    /// @notice The media of an open record never change, and the record never opens twice.
    /// @dev Bounds: as the contract's; either token; opened, or finalized.
    function check_media_fixedAfterOpen(
        bool cc0Work,
        uint8 start,
        address caller,
        uint8 action,
        bytes32 file,
        uint8 license,
        bool a,
        bool b,
        uint32 cfg
    ) public {
        uint256 id = cc0Work ? 1 : 2;
        (Snap memory before, Snap memory afterwards) =
            _run(id, start & 2, caller, action, file, license, a, b, cfg);
        assert(afterwards.media == before.media);
    }

    /// @notice After finalize the descriptive record never changes.
    /// @dev Bounds: as the contract's, on the MIT token; finalized, with the license and record
    ///      replaced before or not, the license locked or not.
    function check_record_fixedAfterFinalize(
        uint8 start,
        address caller,
        uint8 action,
        bytes32 file,
        uint8 license,
        bool a,
        bool b,
        uint32 cfg
    ) public {
        (Snap memory before, Snap memory afterwards) =
            _run(2, (start & 5) | 2, caller, action, file, license, a, b, cfg);
        assert(before.finalized);
        assert(afterwards.recordFileId == before.recordFileId);
    }

    /// @notice A CC0 license is never left and always names the deployment's CC0 text.
    /// @dev Bounds: as the contract's, on the CC0 token; the license re-cased before or not,
    ///      finalized or not, the license locked or not.
    function check_cc0_neverLeft(
        uint8 start,
        address caller,
        uint8 action,
        bytes32 file,
        uint8 license,
        bool a,
        bool b,
        uint32 cfg
    ) public {
        _run(1, start & 7, caller, action, file, license, a, b, cfg);
        Facts memory f = facts.factsOf(address(token), 1);
        assert(WorksHashing.licenseKey(f.licenseId) == WorksHashing.CC0_LICENSE_KEY);
        assert(f.licenseTextFileId == CC0_TEXT);
    }

    /// @notice `finalized`, `licenseLocked`, `repinLocked` and `onChainComplete` never go back to
    ///         false; a locked license never changes; a locked pin never changes.
    /// @dev Bounds: as the contract's, on the MIT token; every combination of finalized, license
    ///      locked, pin locked (finalized only) and on-chain complete.
    function check_locks_oneWay(
        uint8 start,
        address caller,
        uint8 action,
        bytes32 file,
        uint8 license,
        bool a,
        bool b,
        uint32 cfg
    ) public {
        (Snap memory x, Snap memory y) =
            _run(2, start & 30, caller, action, file, license, a, b, cfg);
        assert(!x.finalized || y.finalized);
        assert(!x.onChainComplete || y.onChainComplete);
        assert(!x.licenseLocked || y.licenseLocked);
        assert(!x.repinLocked || y.repinLocked);
        if (x.licenseLocked) assert(y.licenseId == x.licenseId && y.licenseText == x.licenseText);
        if (x.repinLocked) assert(y.renderer == x.renderer);
    }

    // ----------------------------------------------------------------------------- helpers

    /// @dev Item `id` and its two media files; token 1 is CC0, token 2 MIT.
    function _item(uint256 id)
        internal
        pure
        returns (PackageItem memory item, MediaFile[] memory media)
    {
        media = new MediaFile[](2);
        media[0] = MediaFile(bytes32(0x100 + id), keccak256(abi.encode("primary", id)), 0);
        media[1] = MediaFile(bytes32(0x200 + id), keccak256(abi.encode("preview", id)), 1);
        item.collectionId = 1;
        item.contentHash = media[0].sha256Hash;
        item.mediaHash = WorksHashing.mediaHash(media);
        item.recordFileId = bytes32(0x300 + id);
        item.license = id == 1 ? License("CC0-1.0", CC0_TEXT) : License("MIT", MIT_TEXT);
    }

    /// @dev Builds starting state `start` (bits 0 to 4, see the contract) of token `id` with a
    ///      store that accepts everything and `R1` as the RENDERER module. Each step is a plain
    ///      call that must succeed, so every starting state is one the contract reaches.
    function _prepare(uint256 id, uint8 start) internal {
        store.set(1, 0, 0, true);
        address t = address(token);
        vm.startPrank(MODULE);
        if (start & 1 != 0) {
            facts.setLicense(
                t, id, id == 1 ? License("cc0-1.0", CC0_TEXT) : License("Apache-2.0", MIT_TEXT)
            );
            facts.setRecord(t, id, bytes32(uint256(0x400 + id)));
        }
        if (start & 2 != 0) facts.finalize(t, id);
        if (start & 4 != 0) facts.lock(t, id, true, false);
        if (start & 8 != 0 && start & 2 != 0) facts.lock(t, id, false, true);
        vm.stopPrank();
        if (start & 16 != 0) facts.markOnChainComplete(t, id);
    }

    /// @dev Prepares `start`, sets the store and renderer from `cfg`, runs one action and returns
    ///      the record before and after it.
    function _run(
        uint256 id,
        uint8 start,
        address caller,
        uint8 action,
        bytes32 file,
        uint8 license,
        bool a,
        bool b,
        uint32 cfg
    ) internal returns (Snap memory before, Snap memory afterwards) {
        _prepare(id, start);
        _configure(cfg);
        before = _snap(id);
        _step(id, caller, action, file, license, a, b);
        afterwards = _snap(id);
    }

    /// @dev The store's answers and the RENDERER module from one word: chunk count (bits 0-7),
    ///      digest kind (8-15), encoding (16-23), completeness (bit 24), no renderer (bit 25).
    function _configure(uint32 cfg) internal {
        store.set(uint8(cfg), uint8(cfg >> 8), uint8(cfg >> 16), (cfg >> 24) & 1 == 1);
        token.setModule(Slots.RENDERER, (cfg >> 25) & 1 == 1 ? address(0) : r1);
    }

    function _license(uint8 i) internal pure returns (string memory) {
        if (i == 0) return "CC0-1.0";
        if (i == 1) return "cc0-1.0";
        if (i == 2) return "MIT";
        if (i == 3) return "";
        return "M!T";
    }

    /// @dev One action, any caller; the result is ignored (a refusal changes nothing).
    function _step(
        uint256 id,
        address caller,
        uint8 action,
        bytes32 file,
        uint8 license,
        bool a,
        bool b
    ) internal {
        bytes memory data;
        if (action == 0) {
            (PackageItem memory item, MediaFile[] memory media) = _item(id);
            data = abi.encodeCall(IWorkFacts.open, (address(token), id, item, media));
        } else if (action == 1) {
            data = abi.encodeCall(IWorkFacts.markOnChainComplete, (address(token), id));
        } else if (action == 2) {
            data = abi.encodeCall(IWorkFacts.setRecord, (address(token), id, file));
        } else if (action == 3) {
            data = abi.encodeCall(
                IWorkFacts.setLicense, (address(token), id, License(_license(license), file))
            );
        } else if (action == 4) {
            data = abi.encodeCall(IWorkFacts.finalize, (address(token), id));
        } else if (action == 5) {
            data = abi.encodeCall(IWorkFacts.repin, (address(token), id, a ? r1 : r2));
        } else {
            data = abi.encodeCall(IWorkFacts.lock, (address(token), id, a, b));
        }
        vm.prank(caller);
        (bool ok,) = address(facts).call(data);
        ok;
    }

    function _snap(uint256 id) internal view returns (Snap memory s) {
        Facts memory f = facts.factsOf(address(token), id);
        s.media = keccak256(abi.encode(f.media));
        s.recordFileId = f.recordFileId;
        s.licenseId = keccak256(bytes(f.licenseId));
        s.licenseText = f.licenseTextFileId;
        s.renderer = f.renderer;
        s.finalized = f.finalized;
        s.onChainComplete = f.onChainComplete;
        s.licenseLocked = f.licenseLocked;
        s.repinLocked = f.repinLocked;
    }
}
