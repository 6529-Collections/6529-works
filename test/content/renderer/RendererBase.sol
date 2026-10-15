// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { ContentBase } from "../ContentBase.sol";
import {
    MockDisputeLog,
    MockEditions,
    MockStream,
    MockWorkRecords
} from "../../mocks/RendererMocks.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { Renderer } from "src/content/Renderer.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { ItemKind, License, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { JsonEscape } from "src/libraries/JsonEscape.sol";
import { IRenderer } from "src/interfaces/IRenderer.sol";

/// @dev One attribute of a record.
struct Trait {
    string traitType;
    string value;
}

/// @dev The fields of a work record the renderer reads (`IWorkRecords`: keys `name`,
///      `description`, `artists`, `year`, `medium`, `dimensions`, `attributes`).
struct Rec {
    string name;
    string description;
    string[] artists;
    uint16 year;
    string medium;
    string dimensions;
    Trait[] attributes;
}

/// @dev Fixtures for the renderer tests: a real content store, a mock Stream and work-records
///      satellite, mock Editions and a mock statement log, plus helpers that build records and
///      read the renderer's output the way a client does.
abstract contract RendererBase is ContentBase {
    IContentStore.Encoding internal constant IDENTITY = IContentStore.Encoding.Identity;
    IContentStore.Encoding internal constant GZIP = IContentStore.Encoding.Gzip;
    IContentStore.Encoding internal constant BASE64 = IContentStore.Encoding.Base64;
    IContentStore.Encoding internal constant GZIP_BASE64 = IContentStore.Encoding.GzipBase64;
    uint256 internal constant ID = 7;
    uint256 internal constant THRESHOLD = 262_144;
    /// @dev The renderer's bounds on a record and a script (not getters of the renderer, to save
    ///      bytecode): the boundary tests fail if the renderer's own differ.
    uint256 internal constant MAX_ESCAPES = 512;
    uint256 internal constant MAX_ATTRIBUTES = 32;
    uint256 internal constant MAX_SCRIPT_LT = 1_024;
    uint256 internal constant SCRIPT_LIMIT = 8_192;
    uint256 internal constant PREVIEW_LIMIT = 65_536;
    uint256 internal constant MAX_INLINE_BYTES = 1_048_576;
    string internal constant PREFIX = "data:application/json;utf8,";

    MockStream internal stream;
    MockWorkRecords internal records;
    MockDisputeLog internal disputeLog;
    Renderer internal renderer;

    function setUp() public virtual {
        store = new ContentStore();
        stream = new MockStream();
        records = new MockWorkRecords();
        stream.setWorkRecords(address(records));
        disputeLog = new MockDisputeLog();
        renderer = new Renderer(store, IStatementLog(address(disputeLog)), THRESHOLD);
    }

    // ---------------------------------------------------------------- fixtures

    /// @dev Stores `stored` under `encoding` and uploads every chunk. The declared digest is the
    ///      SHA-256 of the stored bytes, which is all the renderer reports.
    function _file(bytes memory stored, IContentStore.Encoding encoding, string memory mime)
        internal
        returns (bytes32 fileId)
    {
        fileId = _unattested(stored, encoding, mime);
        if (encoding == BASE64 || encoding == GZIP_BASE64) _attest(fileId);
    }

    /// @dev Like `_file`, but a `Base64` file is not attested, whatever its text.
    function _unattested(bytes memory stored, IContentStore.Encoding encoding, string memory mime)
        internal
        returns (bytes32 fileId)
    {
        (bytes[] memory chunks, bytes32[] memory hashes) = _split(stored);
        fileId = store.registerManifest(hashes, stored.length, encoding, mime, sha256(stored));
        _uploadAll(chunks);
    }

    /// @dev The one-time strict check of a `Base64` file (decision H1). A file that is not strict
    ///      base64 stays unattested, which is what a renderer must find out.
    function _attest(bytes32 fileId) internal {
        // A file of many chunks takes several calls; a file that is not strict base64 reverts.
        try store.attestBase64(fileId) returns (bool done) {
            while (!done) done = store.attestBase64(fileId);
        } catch { }
    }

    function _attested(bytes32 fileId) internal view returns (bool) {
        return store.isBase64Attested(fileId);
    }

    /// @dev Like `_file`, but the last chunk is never uploaded.
    function _incompleteFile(
        bytes memory stored,
        IContentStore.Encoding encoding,
        string memory mime
    ) internal returns (bytes32 fileId) {
        (bytes[] memory chunks, bytes32[] memory hashes) = _split(stored);
        fileId = store.registerManifest(hashes, stored.length, encoding, mime, sha256(stored));
        for (uint256 i; i + 1 < chunks.length; ++i) {
            store.writeChunk(chunks[i]);
        }
    }

    function _rec() internal pure returns (Rec memory r) {
        r.name = "Title";
        r.description = "Description";
        r.artists = new string[](1);
        r.artists[0] = "Ada";
        r.year = 2026;
        r.medium = "Oil";
    }

    function _license() internal pure returns (License memory) {
        return License("CC0-1.0", bytes32(0));
    }

    function _core() internal pure returns (IStream.WorkCore memory core) {
        core.itemHash = bytes32(uint256(1));
        core.artistId = 1;
        core.kind = ItemKind.ORIGINAL;
    }

    /// @dev The record file the work points at, in the order RFC 8785 gives the keys.
    function _json(Rec memory r) internal pure returns (bytes memory out) {
        bytes memory artists = "[";
        for (uint256 i; i < r.artists.length; ++i) {
            artists = bytes.concat(artists, i == 0 ? bytes("") : bytes(","), _q(r.artists[i]));
        }
        bytes memory attrs = "[";
        for (uint256 i; i < r.attributes.length; ++i) {
            attrs = bytes.concat(
                attrs,
                i == 0 ? bytes("") : bytes(","),
                '{"trait_type":',
                _q(r.attributes[i].traitType),
                ',"value":',
                _q(r.attributes[i].value),
                "}"
            );
        }
        out = bytes.concat(
            '{"artists":',
            artists,
            "],",
            '"attributes":',
            attrs,
            "],",
            '"description":',
            _q(r.description),
            ',"dimensions":',
            _q(r.dimensions),
            ',"medium":',
            _q(r.medium),
            ',"name":',
            _q(r.name)
        );
        if (r.year != 0) out = bytes.concat(out, ',"year":', bytes(vm.toString(r.year)));
        out = bytes.concat(out, "}");
    }

    function _q(string memory s) internal pure returns (bytes memory) {
        return abi.encodePacked('"', JsonEscape.escape(s), '"');
    }

    /// @dev Makes work `ID` exist, with record `json` and `media`, on-chain complete, under CC0.
    function _installRaw(bytes memory json, MediaFile[] memory media) internal {
        _installRawAt(ID, json, media);
    }

    /// @dev As `_installRaw`, for work `id`.
    function _installRawAt(uint256 id, bytes memory json, MediaFile[] memory media) internal {
        bytes32 recordFile = _file(json, IDENTITY, "application/json");
        IWorkRecords.RecordInfo memory info;
        info.recordFileId = recordFile;
        info.licenseKey = WorksHashing.CC0_LICENSE_KEY;
        info.version = 1;
        info.onChainComplete = true;
        stream.setWork(id, _core());
        records.setRecord(id, info);
        records.setOpen(id, true);
        records.setMedia(id, media);
        records.setLicense(id, _license());
    }

    function _media(bytes32 primary, bytes32 preview) internal view returns (MediaFile[] memory m) {
        m = new MediaFile[](preview == 0 ? 1 : 2);
        m[0] = MediaFile(primary, _sha(primary), FileRole.PRIMARY);
        if (preview != 0) m[1] = MediaFile(preview, _sha(preview), FileRole.PREVIEW);
    }

    function _sha(bytes32 fileId) internal view returns (bytes32) {
        return store.sha256Of(fileId);
    }

    /// @dev Installs work `ID` with the default record and `primary` as its media.
    function _install(bytes32 primary) internal returns (Rec memory r) {
        r = _rec();
        _install(primary, r);
    }

    function _install(bytes32 primary, Rec memory r) internal {
        _installRaw(_json(r), _media(primary, 0));
    }

    function _install(bytes32 primary, bytes32 preview, Rec memory r) internal {
        _installRaw(_json(r), _media(primary, preview));
    }

    /// @dev Changes the record state of `ID`.
    function _setRecordInfo(IWorkRecords.RecordInfo memory info) internal {
        records.setRecord(ID, info);
    }

    function _info() internal view returns (IWorkRecords.RecordInfo memory) {
        return records.record(ID);
    }

    /// @dev Closes or opens the record of `ID` (decision E9).
    function _setOpen(bool open) internal {
        records.setOpen(ID, open);
    }

    // ---------------------------------------------------------------- reading the output

    /// @dev Asserts that work `ID` renders from Stream alone with `record_status` `status` (no
    ///      media, no license) and that `fullTokenURI` refuses it. Returns the name.
    function _assertCoreOnly(string memory status) internal returns (string memory name) {
        string memory j = _out();
        assertEq(_str(j, ".record_status"), status);
        assertEq(_str(j, ".description"), "The work record is not available.");
        assertFalse(_has(j, ".image"));
        assertFalse(_has(j, ".animation_url"));
        assertFalse(_has(j, ".media_url"));
        assertFalse(_has(j, ".license"));
        assertFalse(_has(j, ".content_hash"));
        assertTrue(_hasAttr(j, "Artist ID"));
        vm.expectRevert(
            abi.encodeWithSelector(IRenderer.RendererNotInlineable.selector, address(stream), ID)
        );
        renderer.fullTokenURI(address(stream), ID);
        return _str(j, ".name");
    }

    function _uri() internal view returns (string memory) {
        return renderer.tokenURI(address(stream), ID);
    }

    function _out() internal view returns (string memory) {
        return _decode(_uri());
    }

    /// @dev The JSON text of a `data:application/json;utf8,` URI. Fails on a `%` that is not
    ///      `%25` or `%23` and on a `#`, which a client could not carry through a URL.
    function _decode(string memory uri) internal pure returns (string memory) {
        bytes memory b = bytes(uri);
        bytes memory prefix = bytes(PREFIX);
        require(b.length >= prefix.length, "short");
        for (uint256 i; i < prefix.length; ++i) {
            require(b[i] == prefix[i], "prefix");
        }
        bytes memory out = new bytes(b.length - prefix.length);
        uint256 n;
        for (uint256 i = prefix.length; i < b.length; ++i) {
            bytes1 c = b[i];
            require(c != "#", "raw #");
            if (c == "%") {
                require(i + 2 < b.length && b[i + 1] == "2", "stray %");
                require(b[i + 2] == "5" || b[i + 2] == "3", "stray %");
                out[n++] = b[i + 2] == "5" ? bytes1("%") : bytes1("#");
                i += 2;
            } else {
                out[n++] = c;
            }
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
        return string(out);
    }

    /// @dev The JSON text after the prefix, for outputs too large to decode byte by byte. Only
    ///      valid when the test knows the output holds no `%` or `#` escapes.
    function _strip(string memory uri) internal pure returns (string memory) {
        uint256 n = bytes(PREFIX).length;
        return string(_slice(bytes(uri), n, bytes(uri).length - n));
    }

    function _has(string memory json, string memory key) internal view returns (bool) {
        return vm.keyExistsJson(json, key);
    }

    function _str(string memory json, string memory key) internal pure returns (string memory) {
        return vm.parseJsonString(json, key);
    }

    /// @dev The index of the attribute `name`, or the attribute count when there is none.
    function _attrIndex(string memory json, string memory name) internal view returns (uint256 i) {
        for (; _has(json, _at(i, "")); ++i) {
            if (_eq(_str(json, _at(i, ".trait_type")), name)) return i;
        }
    }

    function _attr(string memory json, string memory name) internal view returns (string memory) {
        uint256 i = _attrIndex(json, name);
        require(_has(json, _at(i, "")), string.concat("no trait ", name));
        return _str(json, _at(i, ".value"));
    }

    function _attrNum(string memory json, string memory name) internal view returns (uint256) {
        return vm.parseJsonUint(json, _at(_attrIndex(json, name), ".value"));
    }

    function _hasAttr(string memory json, string memory name) internal view returns (bool) {
        return _has(json, _at(_attrIndex(json, name), ""));
    }

    function _at(uint256 i, string memory field) internal pure returns (string memory) {
        return string.concat(".attributes[", vm.toString(i), "]", field);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _b64(bytes memory data) internal pure returns (string memory) {
        return Base64.encode(data);
    }
}
