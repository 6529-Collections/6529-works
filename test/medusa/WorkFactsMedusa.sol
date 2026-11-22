// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ContentStore } from "src/content/ContentStore.sol";
import { Stream6529 } from "src/core/Stream6529.sol";
import { StreamWorkFacts6529 } from "src/core/StreamWorkFacts6529.sol";
import { Facts, MintFacts, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, PackageItem, Party } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { MockRecords, MockRenderer, MockSale, MockTerms } from "../mocks/core/CoreMocks.sol";
import { Actor, Gate, MedusaBase } from "./MedusaBase.sol";

/// @dev Stateful harness for Medusa (docs/testing/README.md, second fuzzer) over the real
///      `StreamWorkFacts6529`, the real core `Stream6529` it records and the real `ContentStore`,
///      with a pass-through RECORDS module (`MockRecords`, the "records module actor"), two
///      renderers that take turns in Stream's RENDERER slot, and a stranger who calls
///      `StreamWorkFacts6529` directly.
///
///      The model is written from the guarantees `IWorkFacts` and `StreamWorkFacts6529` state (ADR
///      0010) and docs/spec/works-and-storage.md, not from the code: which works are minted from
///      which item, which files the store holds complete, each record's media, record file,
///      license, locks, finalization and pinned renderer, and the RENDERER slot. Licenses and files
///      come from fixed tables whose properties the harness states by hand (which identifiers are
///      valid SPDX, which are CC0, which texts are small, registered or complete), so the model
///      never asks the contract or its libraries. It predicts every call's outcome; the
///      `property_*` functions compare the model with the contracts after every call.
contract WorkFactsMedusa is MedusaBase {
    uint256 internal constant CONTENTS = 4;
    uint256 internal constant LICENSES = 9;
    uint256 internal constant RECORD_FILES = 5;
    uint256 internal constant MAX_TOKENS = 8;

    StreamWorkFacts6529 public facts;
    Stream6529 public stream;
    ContentStore public store;
    MockRecords public records;
    MockSale public sale;
    MockRenderer public rendererA;
    MockRenderer public rendererB;
    MockRenderer public rendererC;
    Gate public gate;
    Actor public governor;
    Actor public stranger;
    Actor public artist;

    // The fixed files. Uploadable ones start incomplete: media, the secondary file, record R1
    // and license text T_INC.
    bytes32 public cc0Text;
    bytes32 public mitText;
    bytes32 public bigText; // 17 chunks: never small enough
    bytes32 public incText; // one chunk, complete once uploaded
    bytes32 public unregText; // never registered
    bytes32[RECORD_FILES] public recordFiles; // R0 good; R1 good once uploaded; R2 two chunks;
    // R3 base64-encoded; R4 never registered
    bytes32[CONTENTS] public mediaFiles;
    bytes32[CONTENTS] public mediaSha;
    bytes32 public secondaryFile;
    bytes32 public secondarySha;
    mapping(bytes32 fileId => bytes) internal _data;

    // The model.
    mapping(bytes32 fileId => bool) public mComplete;
    address public mRenderer;
    uint256 public mTokens;
    mapping(uint256 content => bool) public mContentUsed;
    mapping(uint256 id => uint256) public mContent;
    mapping(uint256 id => uint8) public mMediaSel;
    mapping(uint256 id => uint256) public mItemLicense;
    mapping(uint256 id => uint256) public mItemRecord;
    mapping(uint256 id => bool) public mOpened;
    mapping(uint256 id => bytes32) public mRecord;
    mapping(uint256 id => uint256) public mLicense;
    mapping(uint256 id => bool) public mFinalized;
    mapping(uint256 id => address) public mPin;
    mapping(uint256 id => bool) public mLicenseLocked;
    mapping(uint256 id => bool) public mRepinLocked;
    mapping(uint256 id => bool) public mOnChain;
    mapping(uint256 id => bool) public mWasCc0;

    constructor() payable {
        governor = new Actor();
        stranger = new Actor();
        artist = new Actor();
        gate = new Gate(address(governor));
        store = new ContentStore();
        _registerFiles();
        facts = new StreamWorkFacts6529(address(store), cc0Text);
        rendererA = new MockRenderer();
        rendererB = new MockRenderer();
        rendererC = new MockRenderer();
        sale = new MockSale();
        records = new MockRecords(facts);
        address[] memory minters = new address[](1);
        minters[0] = address(sale);
        stream = new Stream6529(
            address(gate),
            address(facts),
            address(governor),
            address(rendererA),
            address(new MockTerms()),
            address(records),
            minters
        );
        mRenderer = address(rendererA);
        _must(governor, address(stream), abi.encodeCall(stream.createCollection, ("Works", 0)));
        _must(governor, address(stream), abi.encodeCall(stream.setModuleDelay, (0)));
    }

    // ---------------------------------------------------------------------------------------
    // The fixed tables
    // ---------------------------------------------------------------------------------------

    /// License `k`: its identifier and text file.
    function license(uint256 k) public view returns (License memory) {
        if (k == 0) return License("CC0-1.0", cc0Text);
        if (k == 1) return License("cc0-1.0", mitText);
        if (k == 2) return License("MIT", mitText);
        if (k == 3) return License("", mitText);
        if (k == 4) return License("MIT License", mitText);
        if (k == 5) return License("Apache-2.0", bigText);
        if (k == 6) return License("MIT", incText);
        if (k == 7) return License("Cc0-1.0", cc0Text);
        return License("MIT", unregText);
    }

    /// Licenses 0, 1 and 7 are CC0 in some case; 1 names another text.
    function _isCc0(uint256 k) internal pure returns (bool) {
        return k == 0 || k == 1 || k == 7;
    }

    /// Licenses 3 (empty) and 4 (a space) are not valid SPDX identifiers.
    function _validId(uint256 k) internal pure returns (bool) {
        return k != 3 && k != 4;
    }

    /// A CC0 license names the deployment's CC0 text.
    function _cc0TextOk(uint256 k) internal pure returns (bool) {
        return !_isCc0(k) || k != 1;
    }

    /// The text is registered with a SHA-256 digest and at most 16 chunks.
    function _textUsable(uint256 k) internal pure returns (bool) {
        return k != 5 && k != 8;
    }

    function _textComplete(uint256 k) internal view returns (bool) {
        return _textUsable(k) && (k != 6 || mComplete[incText]);
    }

    /// Record file `r` can be frozen: registered, one chunk, stored as it is, SHA-256, complete.
    function _recordGood(bytes32 fileId) internal view returns (bool) {
        return (fileId == recordFiles[0] || fileId == recordFiles[1]) && mComplete[fileId];
    }

    /// Media `sel` of content `c`: 0 the primary file; 1 primary and secondary; 2 two primary
    /// files (roles wrong); 3 the primary file under a declared SHA-256 the store does not hold.
    function media(uint256 c, uint8 sel) public view returns (MediaFile[] memory m) {
        m = new MediaFile[](sel == 0 || sel == 3 ? 1 : 2);
        m[0] = MediaFile(mediaFiles[c], mediaSha[c], 0);
        if (sel == 3) m[0].sha256Hash = keccak256(abi.encode("declared", c));
        if (sel == 1) m[1] = MediaFile(secondaryFile, secondarySha, 1);
        if (sel == 2) m[1] = MediaFile(secondaryFile, secondarySha, 0);
    }

    function item(uint256 c, uint8 mediaSel, uint256 lic, uint256 rec)
        public
        view
        returns (PackageItem memory it)
    {
        MediaFile[] memory m = media(c, mediaSel);
        it.collectionId = 1;
        it.contentHash = m[0].sha256Hash;
        it.mediaHash = keccak256(abi.encode(WorksHashing.MEDIA_DOMAIN, m));
        it.recordFileId = recordFiles[rec];
        it.parties = new Party[](1);
        it.parties[0] = Party(address(artist), 0);
        it.license = license(lic);
    }

    // ---------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------

    /// A work is minted from an item of a content, a media shape, a license and a record file.
    /// A content's primary file is minted once (shape 3 declares another content).
    function mint(uint8 contentSel, uint8 mediaSel, uint8 licSel, bool secondRecord) public {
        if (mTokens >= MAX_TOKENS) return;
        uint256 c = contentSel % CONTENTS;
        uint8 ms = mediaSel % 4;
        uint256 lic = licSel % LICENSES;
        uint256 rec = secondRecord ? 1 : 0;
        uint256 key = ms == 3 ? c + CONTENTS : c;
        MintFacts memory f;
        f.itemHash = WorksHashing.itemHash(item(c, ms, lic, rec));
        f.contentHash = item(c, ms, lic, rec).contentHash;
        f.artistId = 1;
        f.collectionId = 1;
        (bool ok, bytes memory ret) =
            address(sale).call(abi.encodeCall(MockSale.mint, (address(stream), f)));
        _record(ok, !mContentUsed[key], "mint");
        if (!ok) return;
        uint256 id = abi.decode(ret, (uint256));
        _record(id == ++mTokens, true, "token id");
        mContentUsed[key] = true;
        mContent[id] = c;
        mMediaSel[id] = ms;
        mItemLicense[id] = lic;
        mItemRecord[id] = rec;
    }

    /// Anyone uploads one of the uploadable files.
    function upload(uint8 sel) public {
        uint256 k = sel % (CONTENTS + 3);
        bytes32 fileId = k < CONTENTS
            ? mediaFiles[k]
            : k == CONTENTS ? secondaryFile : k == CONTENTS + 1 ? recordFiles[1] : incText;
        (bool ok,) = address(store).call(abi.encodeCall(store.writeChunk, (_data[fileId])));
        _record(ok, true, "upload");
        if (ok) mComplete[fileId] = true;
    }

    /// `open`: anyone, once, for a live work, with the exact item it was minted from and the
    /// media that item committed to, each held by the store under its declared SHA-256, the
    /// primary file first and only first; a CC0 license must name the CC0 text. `shape` passes
    /// another item, other media, or a token that does not exist.
    function open(uint256 tokenSel, uint8 shape) public {
        uint256 id = 1 + tokenSel % (mTokens + 1);
        uint256 form = shape % 4;
        uint256 c = mContent[id];
        uint8 ms = mMediaSel[id];
        uint256 lic = mItemLicense[id];
        PackageItem memory it = item(c, ms, lic, mItemRecord[id]);
        if (form == 1) it.seed = bytes32(uint256(1)); // another item
        MediaFile[] memory m = media(c, form == 2 ? (ms + 1) % 4 : ms);
        bool exists = id <= mTokens;
        bool expected = exists && !mOpened[id] && form == 0 && ms < 2 && _cc0TextOk(lic);
        bytes memory data =
            abi.encodeCall(facts.open, (address(stream), form == 3 ? 99 : id, it, m));
        (bool ok,) = _expect(stranger, address(facts), data, expected, "open");
        if (!ok) return;
        mOpened[id] = true;
        mRecord[id] = recordFiles[mItemRecord[id]];
        mLicense[id] = lic;
        mWasCc0[id] = _isCc0(lic);
    }

    /// `markOnChainComplete`: anyone, for an open record whose media the store holds complete;
    /// once marked, again changes nothing.
    function markOnChain(uint256 tokenSel) public {
        uint256 id = 1 + tokenSel % (mTokens + 1);
        bool complete =
            mComplete[mediaFiles[mContent[id]]] && (mMediaSel[id] != 1 || mComplete[secondaryFile]);
        bool expected = mOpened[id] && (mOnChain[id] || complete);
        bytes memory data = abi.encodeCall(facts.markOnChainComplete, (address(stream), id));
        (bool ok,) = _expect(stranger, address(facts), data, expected, "markOnChainComplete");
        if (ok) mOnChain[id] = true;
    }

    /// `setRecord` through the RECORDS module (or by the stranger directly): an open record not
    /// yet finalized; any file ID.
    function setRecord(uint256 tokenSel, uint8 recSel, bool direct) public {
        uint256 id = 1 + tokenSel % (mTokens + 1);
        bytes32 next = recordFiles[recSel % RECORD_FILES];
        bool expected = !direct && mOpened[id] && !mFinalized[id];
        bool ok;
        if (direct) {
            bytes memory data = abi.encodeCall(facts.setRecord, (address(stream), id, next));
            (ok,) = _expect(stranger, address(facts), data, false, "setRecord direct");
        } else {
            bytes memory data = abi.encodeCall(MockRecords.setRecord, (address(stream), id, next));
            (ok,) = _call(data, expected, "setRecord");
        }
        // An unexpected success is not applied: the record must then differ from the model.
        if (ok && expected) mRecord[id] = next;
    }

    /// `setLicense` through the RECORDS module: an open record whose license is not locked; a
    /// CC0 license only to CC0; a valid identifier; a CC0 license names the CC0 text; a usable
    /// text, complete once the work is finalized.
    function setLicense(uint256 tokenSel, uint8 licSel) public {
        uint256 id = 1 + tokenSel % (mTokens + 1);
        uint256 next = licSel % LICENSES;
        bool expected = mOpened[id] && !mLicenseLocked[id]
            && !(_isCc0(mLicense[id]) && !_isCc0(next)) && _validId(next) && _cc0TextOk(next)
            && _textUsable(next) && (!mFinalized[id] || _textComplete(next));
        bytes memory data =
            abi.encodeCall(MockRecords.setLicense, (address(stream), id, license(next)));
        (bool ok,) = _call(data, expected, "setLicense");
        if (!ok) return;
        mLicense[id] = next;
        if (_isCc0(next)) mWasCc0[id] = true;
    }

    /// `finalize` through the RECORDS module: an open record not yet finalized, a RENDERER
    /// module installed (it is pinned), a good complete record file, a valid identifier and a
    /// complete usable license text.
    function finalize(uint256 tokenSel) public {
        uint256 id = 1 + tokenSel % (mTokens + 1);
        uint256 lic = mLicense[id];
        bool expected = mOpened[id] && !mFinalized[id] && mRenderer != address(0)
            && _recordGood(mRecord[id]) && _validId(lic) && _textComplete(lic);
        (bool ok,) =
            _call(abi.encodeCall(MockRecords.finalize, (address(stream), id)), expected, "finalize");
        if (!ok) return;
        mFinalized[id] = true;
        mPin[id] = mRenderer;
    }

    /// `repin` through the RECORDS module: a finalized work whose pin is not locked, to a
    /// renderer with code.
    function repin(uint256 tokenSel, uint8 rSel) public {
        uint256 id = 1 + tokenSel % (mTokens + 1);
        uint256 k = rSel % 4;
        address r = k == 0
            ? address(rendererA)
            : k == 1 ? address(rendererB) : k == 2 ? address(rendererC) : address(0xD00D);
        bool expected = mFinalized[id] && !mRepinLocked[id] && k != 3;
        (bool ok,) =
            _call(abi.encodeCall(MockRecords.repin, (address(stream), id, r)), expected, "repin");
        if (ok) mPin[id] = r;
    }

    /// `lock` through the RECORDS module: an open record; the license needs a valid identifier
    /// and a usable text; the pin needs a finalized work. Locking again is allowed.
    function lock(uint256 tokenSel, bool lic, bool pin) public {
        uint256 id = 1 + tokenSel % (mTokens + 1);
        uint256 cur = mLicense[id];
        bool expected = mOpened[id] && (!lic || (_validId(cur) && _textUsable(cur)))
            && (!pin || mFinalized[id]);
        (bool ok,) = _call(
            abi.encodeCall(MockRecords.lock, (address(stream), id, lic, pin)), expected, "lock"
        );
        if (!ok) return;
        if (lic) mLicenseLocked[id] = true;
        if (pin) mRepinLocked[id] = true;
    }

    /// The network empties Stream's RENDERER slot, or installs renderer A or B (the module delay
    /// is zero, so announce and install follow at once).
    function setRenderer(uint8 sel) public {
        uint256 k = sel % 3;
        if (k == 0) {
            _must(governor, address(stream), abi.encodeCall(stream.removeModule, (Slots.RENDERER)));
            mRenderer = address(0);
            return;
        }
        address r = k == 1 ? address(rendererA) : address(rendererB);
        _must(governor, address(stream), abi.encodeCall(stream.proposeModule, (Slots.RENDERER, r)));
        _must(stranger, address(stream), abi.encodeCall(stream.activateModule, (Slots.RENDERER)));
        mRenderer = r;
    }

    // ---------------------------------------------------------------------------------------
    // Properties
    // ---------------------------------------------------------------------------------------

    function property_ModelPredictsEveryOutcome() public view returns (bool) {
        return !outcomeMismatch;
    }

    /// Media are the files the item committed to, fixed when the record opens.
    function property_MediaFixedAfterOpen() public view returns (bool) {
        for (uint256 id = 1; id <= mTokens + 1; ++id) {
            Facts memory f = facts.factsOf(address(stream), id);
            if (f.opened != mOpened[id]) return false;
            if (!mOpened[id]) {
                if (f.media.length != 0) return false;
                continue;
            }
            MediaFile[] memory m = media(mContent[id], mMediaSel[id]);
            if (f.media.length != m.length) return false;
            for (uint256 i; i < m.length; ++i) {
                if (f.media[i].fileId != m[i].fileId || f.media[i].role != m[i].role) return false;
            }
        }
        return true;
    }

    /// The record file is the model's: it changed only before finalize.
    function property_RecordFixedAfterFinalize() public view returns (bool) {
        for (uint256 id = 1; id <= mTokens; ++id) {
            if (facts.factsOf(address(stream), id).recordFileId != mRecord[id]) return false;
        }
        return true;
    }

    /// The license is the model's; a work that was ever CC0 is CC0 still, naming the CC0 text.
    function property_Cc0NeverLeft() public view returns (bool) {
        for (uint256 id = 1; id <= mTokens; ++id) {
            if (!mOpened[id]) continue;
            Facts memory f = facts.factsOf(address(stream), id);
            License memory l = license(mLicense[id]);
            if (
                keccak256(bytes(f.licenseId)) != keccak256(bytes(l.spdxId))
                    || f.licenseTextFileId != l.textFileId
            ) return false;
            if (mWasCc0[id] && (!_isCc0(mLicense[id]) || f.licenseTextFileId != cc0Text)) {
                return false;
            }
        }
        return true;
    }

    /// Finalized, both locks and on-chain-complete are the model's, which only ever sets them.
    function property_LocksOneWay() public view returns (bool) {
        for (uint256 id = 1; id <= mTokens; ++id) {
            Facts memory f = facts.factsOf(address(stream), id);
            if (
                f.finalized != mFinalized[id] || f.licenseLocked != mLicenseLocked[id]
                    || f.repinLocked != mRepinLocked[id] || f.onChainComplete != mOnChain[id]
            ) return false;
        }
        return true;
    }

    /// Every finalized work pins a renderer with code, the one the model expects; an unfinalized
    /// work pins nothing and draws with the RENDERER module, whatever it is now.
    function property_FinalizeNeedsARenderer() public view returns (bool) {
        if (stream.moduleOf(Slots.RENDERER) != mRenderer) return false;
        for (uint256 id = 1; id <= mTokens; ++id) {
            address pinned = facts.rendererOf(address(stream), id);
            if (pinned != mPin[id] || (mFinalized[id] && pinned.code.length == 0)) return false;
            if (stream.rendererOf(id) != (mFinalized[id] ? mPin[id] : mRenderer)) return false;
        }
        return true;
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    /// A call through the RECORDS module.
    function _call(bytes memory data, bool expected, string memory what)
        internal
        returns (bool ok, bytes memory ret)
    {
        (ok, ret) = address(records).call(data);
        _record(ok, expected, what);
    }

    function _registerFiles() internal {
        cc0Text = _file("CC0 1.0 Universal (harness copy)", "text/plain", 0, true);
        mitText = _file("MIT License (harness copy)", "text/plain", 0, true);
        incText = _file("MIT License (harness copy, uploaded later)", "text/plain", 0, false);
        unregText = keccak256("never registered");
        bigText = _manyChunks(17, "big license");
        recordFiles[0] = _file('{"name":"record 0"}', "application/json", 0, true);
        recordFiles[1] = _file('{"name":"record 1"}', "application/json", 0, false);
        recordFiles[2] = _manyChunks(2, "two-chunk record");
        recordFiles[3] = _file("eyJuYW1lIjoicmVjb3JkIDMifQ==", "application/json", 2, true);
        recordFiles[4] = keccak256("record never registered");
        for (uint256 c; c < CONTENTS; ++c) {
            bytes memory data = abi.encode("media", c);
            mediaFiles[c] = _file(data, "image/png", 0, false);
            mediaSha[c] = sha256(data);
        }
        bytes memory extra = abi.encode("secondary media");
        secondaryFile = _file(extra, "image/png", 0, false);
        secondarySha = sha256(extra);
    }

    /// Registers a one-chunk file (SHA-256 digest), uploaded now or left for `upload`.
    function _file(bytes memory data, string memory mime, uint8 encoding, bool now_)
        internal
        returns (bytes32 fileId)
    {
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(data);
        fileId = store.registerManifest(hashes, data.length, encoding, mime, sha256(data));
        _data[fileId] = data;
        if (now_) {
            store.writeChunk(data);
            mComplete[fileId] = true;
        }
    }

    /// Registers a file of `n` chunks that are never uploaded.
    function _manyChunks(uint256 n, string memory tag) internal returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            hashes[i] = keccak256(abi.encode(tag, i));
        }
        uint256 length = (n - 1) * store.CHUNK_SIZE() + 1;
        return store.registerManifest(hashes, length, 0, "text/plain", keccak256(bytes(tag)));
    }
}
