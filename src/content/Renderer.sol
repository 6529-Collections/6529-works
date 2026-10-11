// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IContentStore } from "../interfaces/IContentStore.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IEntropyModule } from "../interfaces/IEntropyModule.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import { IStatementLog } from "../interfaces/IStatementLog.sol";
import { IStream } from "../interfaces/IStream.sol";
import { IWorkRecords } from "../interfaces/IWorkRecords.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "../interfaces/types/ContentTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { License, SeedPolicy } from "../interfaces/types/PackageTypes.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { JsonEscape } from "../libraries/JsonEscape.sol";
import { SSTORE2 } from "../libraries/SSTORE2.sol";
import { Utf8 } from "../libraries/Utf8.sol";
import { DataUri } from "./DataUri.sol";
import { HtmlScript } from "./HtmlScript.sol";
import { JsonScan } from "./JsonScan.sol";

/// @title Renderer
/// @notice Builds the metadata of 6529 Stream works and 6529 Editions editions (ADR 0001
///         section 8 "`tokenURI` size"). Immutable and stateless: it only reads.
/// @dev `tokenURI(token, id)` reads the token it is asked about (6529 Stream, or 6529 Editions,
///      which it recognises by ERC-165 and follows to the master), that Stream's `IWorkRecords`
///      satellite, the shared content store and optionally the statement log. A hostile `token`
///      can only change what its own call returns, so there is no list of tokens; every read is
///      a `BoundedCall` with its own gas and return-size cap and reverts if it fails (fail
///      closed).
///
///      The record. A work's descriptive record is a JSON file in the content store (stored as
///      `Identity`, at most `MAX_RECORD_BYTES`). The renderer reads it, checks it as UTF-8 and
///      with `JsonScan`, and copies the validated JSON text of `name`, `description`, `year`,
///      `medium`, `dimensions` and each of `artists` into the metadata (the `attributes` array
///      goes in as it is, after the renderer's own traits; other members are validated and
///      ignored). Until the work's record is open (`IWorkRecords.isOpen`) and its file is
///      complete, the work gets core-only metadata from Stream instead, and never a revert.
///
///      Output is `data:application/json;utf8,` followed by compact JSON, not base64, so the
///      media is not encoded twice. Every string from the Stream, a locator or the store is
///      checked as UTF-8 and escaped for JSON; the record, locators and strings alike are
///      percent-escaped for `%` and `#`, the only two bytes a non-base64 `data:` URI cannot
///      carry.
///
///      Media. The primary file is inlined when the work is on-chain complete, the file is
///      complete in the store, its cost-weighted size is at most the threshold, and its stored
///      encoding can be served as the media itself: `Base64` (the stored text is concatenated
///      as it is) and `Identity` (encoded here, and counted eight times). `Gzip`
///      and `GzipBase64` hold a compressed stream, not the media, so they are served by locator
///      only. A JavaScript primary (stored as `Identity`) is wrapped in a small HTML page that
///      sets `window.works` (see `SHELL_HEAD`), with `</script` and `<!--` neutralized.
///      Otherwise the preferred locator is given, plus a small on-chain preview if the work
///      lists a complete PREVIEW image. `fullTokenURI` raises the limit to 1 MiB and reverts
///      instead of falling back.
///
///      Memory. Media is read one store chunk at a time straight into the single output buffer
///      (a `readChunk` result is released as soon as it is copied), so there is no second copy
///      of the file; an `Identity` file adds one transient buffer for its raw bytes.
contract Renderer is IRenderer {
    /// @notice The largest threshold, and the largest primary file `fullTokenURI` inlines.
    uint256 public constant MAX_INLINE_BYTES = 1_048_576;
    /// @notice The threshold the deployment uses (ADR 0001: 256 KiB; the gas matrix in
    ///         `test/content/renderer/RendererGas.t.sol` shows it fits 8M gas).
    uint256 public constant DEFAULT_INLINE_THRESHOLD = 262_144;
    /// @notice The largest PREVIEW image, cost-weighted stored bytes, inlined next to a primary
    ///         file that is not.
    uint256 public constant PREVIEW_LIMIT = 65_536;
    /// @notice The largest JavaScript primary, in stored bytes, wrapped in the HTML page.
    uint256 public constant SCRIPT_LIMIT = 16_384;
    /// @notice The largest record file, in bytes: one store chunk.
    uint256 public constant MAX_RECORD_BYTES = Limits.MAX_RECORD_BYTES;
    /// @notice The most artists a record may list.
    uint256 public constant MAX_ARTISTS = Limits.MAX_ARTISTS;

    /// @notice The content store the media and records are read from (immutable).
    IContentStore public immutable contentStore;
    /// @notice The statement log whose `latestDisputeOutcome` is shown, or zero for none.
    IStatementLog public immutable statementLog;
    /// @inheritdoc IRenderer
    uint256 public immutable inlineThreshold;

    /// @dev Gas caps per read. A read gets exactly its cap (BoundedCall), so these bound the
    ///      cost of a hostile or broken target; they are ceilings, not estimates.
    uint256 private constant SMALL_GAS = 300_000;
    uint256 private constant CHUNK_GAS = 300_000;
    uint256 private constant COMPLETE_GAS = 700_000;
    /// @dev Gas the renderer needs after any one read returns (checked before the read).
    uint256 private constant AFTER_GAS = 50_000;
    /// @dev Return-size caps in bytes.
    uint256 private constant TEXT_RETURN = 4_096;
    uint256 private constant LOCATOR_RETURN = Limits.MAX_URI_BYTES + 256;
    uint256 private constant LOCATORS_RETURN =
        Limits.MAX_LOCATORS_PER_FILE * (Limits.MAX_URI_BYTES + 192) + 64;

    string private constant PREFIX = "data:application/json;utf8,";
    /// @dev The page around a JavaScript primary. `window.works` is the script's interface, public
    ///      and stable: `v` (the version of this interface, 1), `tokenId` and `seed` (`"0x"` hex,
    ///      or null when the work has no seed). A change to it needs a new `v`. The script text
    ///      follows `window.works={...};`.
    string private constant SHELL_HEAD = '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" '
        'content="width=device-width,initial-scale=1"><style>html,body{margin:0;height:100%;'
        "overflow:hidden}</style></head><body><script>window.works=";
    string private constant SHELL_TAIL = "</script></body></html>";

    /// @notice The threshold is zero or above `MAX_INLINE_BYTES`.
    error RendererThresholdInvalid(uint256 threshold);
    /// @notice A read of `target` failed: no code, a revert, out of its gas cap, or too much
    ///         return data. `selector` names the call.
    error RendererReadFailed(address target, bytes4 selector);
    /// @notice A string from the record, the Stream, a locator or the store is not well-formed
    ///         UTF-8.
    error RendererInvalidUtf8();
    /// @notice The work's data breaks a rule: no primary file first, a record that is too large
    ///         or not `Identity`, a missing or mistyped `name`, `year` or string, or an edition
    ///         whose content hash is not its master's.
    error RendererRecordInvalid(address token, uint256 tokenId);
    /// @notice `fullTokenURI` cannot inline the primary file: the work is not on-chain complete,
    ///         the file is incomplete, too large or not stored as `Identity` or `Base64`.
    error RendererNotInlineable(address token, uint256 tokenId);

    enum Mode {
        None,
        Locator, // `text` is the escaped URL
        Data, // `text` is a complete data URI
        Copy, // `text` is the data URI head; the stored base64 text follows
        Encode // `text` is the data URI head; the stored bytes follow, base64-encoded
    }

    /// @dev One media value of the JSON: a literal `text`, optionally followed by a file's bytes.
    struct Media {
        Mode mode;
        bytes32 fileId;
        uint256 length;
        bytes text;
    }

    /// @dev Everything one render reads, so helpers take one argument. `hash` is an edition's
    ///      content hash, which its master's primary file must have; `collection` is the
    ///      collection's name, empty without one.
    struct Ctx {
        address token;
        uint256 id;
        bool edition;
        bool open;
        bytes32 hash;
        address stream;
        uint256 workId;
        address records;
        IStream.WorkCore core;
        string collection;
        IWorkRecords.RecordInfo rec;
        MediaFile[] media;
        IContentStore.FileInfo primary;
        uint256 limit;
        bool strict;
    }

    /// @param store The content store.
    /// @param log The statement log to read dispute status from, or zero.
    /// @param threshold The largest cost-weighted primary file, in stored bytes, that `tokenURI`
    ///        inlines.
    constructor(IContentStore store, IStatementLog log, uint256 threshold) {
        if (threshold == 0 || threshold > MAX_INLINE_BYTES) {
            revert RendererThresholdInvalid(threshold);
        }
        contentStore = store;
        statementLog = log;
        inlineThreshold = threshold;
    }

    /// @notice ERC-165: `IRenderer` and `IERC165`.
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IRenderer).interfaceId || id == type(IERC165).interfaceId;
    }

    /// @inheritdoc IRenderer
    function tokenURI(address token, uint256 tokenId) external view returns (string memory) {
        return _render(token, tokenId, inlineThreshold, false);
    }

    /// @inheritdoc IRenderer
    function fullTokenURI(address token, uint256 tokenId) external view returns (string memory) {
        return _render(token, tokenId, MAX_INLINE_BYTES, true);
    }

    // ------------------------------------------------------------------ rendering

    function _render(address token, uint256 id, uint256 limit, bool strict)
        private
        view
        returns (string memory)
    {
        // slither-disable-next-line uninitialized-local
        Ctx memory c;
        (c.token, c.id, c.limit, c.strict) = (token, id, limit, strict);
        _load(c);
        c.open = abi.decode(
            _read(c.records, abi.encodeCall(IWorkRecords.isOpen, (c.workId)), SMALL_GAS, 32), (bool)
        );
        bool ready = c.open;
        bytes memory record = "";
        if (ready) {
            _loadRecord(c);
            (ready, record) = _record(c);
        }
        bytes[] memory t = new bytes[](MAX_ARTISTS + 8);
        if (!ready) return _coreOnly(c, t);
        (bytes memory head, uint256 n, bytes memory attributes) = _describe(c, record, t);
        n = _chainTraits(c, t, n);
        return _assemble(head, _media(c), _tail(c, t, n, attributes));
    }

    /// @dev Finds the work behind `c.token`/`c.id` and loads its core. An ERC-1155 token is an
    ///      edition: its ID is the master's Stream token ID, and the master (found through
    ///      `masterOf`) supplies the record, license and media.
    function _load(Ctx memory c) private view {
        (bool ok, bytes memory ret) = BoundedCall.tryRead(
            c.token,
            abi.encodeCall(IERC165.supportsInterface, (type(IERC1155).interfaceId)),
            SMALL_GAS,
            32,
            AFTER_GAS
        );
        if (ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1) {
            c.edition = true;
            (c.stream, c.workId, c.hash) = abi.decode(
                _read(c.token, abi.encodeCall(IEditions.masterOf, (c.id)), SMALL_GAS, 96),
                (address, uint256, bytes32)
            );
        } else {
            c.stream = c.token;
            c.workId = c.id;
        }
        c.core = abi.decode(
            _read(c.stream, abi.encodeCall(IStream.work, (c.workId)), SMALL_GAS, 288),
            (IStream.WorkCore)
        );
        c.records = abi.decode(
            _read(c.stream, abi.encodeCall(IStream.workRecords, ()), SMALL_GAS, 32), (address)
        );
        if (c.core.collectionId != 0) {
            c.collection =
            abi.decode(
                _read(
                    c.stream,
                    abi.encodeCall(IStream.collection, (c.core.collectionId)),
                    SMALL_GAS,
                    TEXT_RETURN
                ),
                (IStream.Collection)
            )
            .name;
        }
    }

    /// @dev Loads the record state and media of a work whose record is open.
    function _loadRecord(Ctx memory c) private view {
        c.rec = abi.decode(
            _read(c.records, abi.encodeCall(IWorkRecords.record, (c.workId)), SMALL_GAS, 256),
            (IWorkRecords.RecordInfo)
        );
        c.media = abi.decode(
            _read(
                c.records,
                abi.encodeCall(IWorkRecords.mediaOf, (c.workId)),
                SMALL_GAS,
                64 + 96 * Limits.MAX_MEDIA_FILES
            ),
            (MediaFile[])
        );
        if (
            c.media.length == 0 || c.media[0].role != FileRole.PRIMARY
                || (c.edition && c.media[0].sha256Hash != c.hash)
        ) revert RendererRecordInvalid(c.token, c.id);
        c.primary = _fileInfo(c.media[0].fileId);
    }

    /// @dev The record JSON, percent-escaped, or not ready if its file is not complete yet.
    function _record(Ctx memory c) private view returns (bool, bytes memory j) {
        bytes32 id = c.rec.recordFileId;
        IContentStore.FileInfo memory fi = _fileInfo(id);
        if (fi.encoding != IContentStore.Encoding.Identity || fi.length > MAX_RECORD_BYTES) {
            revert RendererRecordInvalid(c.token, c.id);
        }
        if (!_complete(id)) return (false, j);
        j = new bytes(fi.length);
        _copyFile(id, fi.length, _ptr(j));
        if (!Utf8.isValid(j)) revert RendererInvalidUtf8();
        // `%` and `#` occur only inside JSON strings, so escaping the whole file keeps it valid.
        return (true, bytes(DataUri.escape(string(j))));
    }

    /// @dev The head of the JSON (`{"name":...,"description":...`), the record's traits in `t`
    ///      (each artist, the year, the medium, the dimensions) and the inside of its
    ///      `attributes` array, if any.
    function _describe(Ctx memory c, bytes memory j, bytes[] memory t)
        private
        pure
        returns (bytes memory head, uint256 n, bytes memory attributes)
    {
        bytes32[] memory keys = new bytes32[](7);
        keys[0] = keccak256("name");
        keys[1] = keccak256("description");
        keys[2] = keccak256("artists");
        keys[3] = keccak256("year");
        keys[4] = keccak256("medium");
        keys[5] = keccak256("dimensions");
        keys[6] = keccak256("attributes");
        uint256[] memory s = JsonScan.object(j, keys);
        if (s[0] == 0) revert RendererRecordInvalid(c.token, c.id);
        head = abi.encodePacked(
            PREFIX, '{"name":', _text(c, j, s[0]), ',"description":', _text(c, j, s[1])
        );
        if (s[2] != 0) {
            uint256[] memory a = JsonScan.elements(j, s[2] >> 128, MAX_ARTISTS);
            for (uint256 i; i < a.length; ++i) {
                t[n++] = _trait("Artist", _text(c, j, a[i]));
            }
        }
        if (s[3] != 0) {
            bytes memory year = JsonScan.slice(j, s[3]);
            if (year[0] == '"' || year[0] > "9" || (year[0] < "0" && year[0] != "-")) {
                revert RendererRecordInvalid(c.token, c.id);
            }
            t[n++] = _trait("Year", year);
        }
        bytes memory medium = _text(c, j, s[4]);
        if (medium.length > 2) t[n++] = _trait("Medium", medium);
        bytes memory dimensions = _text(c, j, s[5]);
        if (dimensions.length > 2) t[n++] = _trait("Dimensions", dimensions);
        if (s[6] != 0) {
            attributes = JsonScan.slice(j, s[6]);
            if (attributes[0] != "[") revert RendererRecordInvalid(c.token, c.id);
            attributes = _inside(attributes);
        }
    }

    /// @dev The JSON string at `span` (quotes included), `""` if absent. Anything else reverts.
    function _text(Ctx memory c, bytes memory j, uint256 span)
        private
        pure
        returns (bytes memory text)
    {
        if (span == 0) return '""';
        text = JsonScan.slice(j, span);
        if (text[0] != '"') revert RendererRecordInvalid(c.token, c.id);
    }

    /// @dev What is between the brackets of the array text `a`, empty when only space is.
    function _inside(bytes memory a) private pure returns (bytes memory out) {
        uint256 first;
        uint256 last = a.length - 1; // the closing bracket
        while (first + 1 < last && _isSpace(a[first + 1])) ++first;
        if (first + 1 >= last) return "";
        out = new bytes(last - first - 1);
        assembly ("memory-safe") {
            mcopy(add(out, 0x20), add(add(a, 0x21), first), mload(out))
        }
    }

    function _isSpace(bytes1 b) private pure returns (bool) {
        return b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d;
    }

    // ------------------------------------------------------------------ media

    /// @dev Chooses the `image`, `animation_url` and `media_url` values:
    ///      - `media_url` is the primary's preferred locator, whenever it is not inlined;
    ///      - an image primary is the `image` (inline, or its locator), unless it is not
    ///        inlined and the work has a preview, which then is the `image`;
    ///      - any other primary is the `animation_url` (inline or its locator), and the
    ///        `image` is the preview (on-chain, else its locator).
    function _media(Ctx memory c) private view returns (Media[3] memory m) {
        Media memory p = _primary(c);
        Media memory v = _preview(c);
        if (p.mode == Mode.Locator) m[2] = p;
        if (_startsWith(bytes(c.primary.mimeType), "image/")) {
            m[0] = p.mode >= Mode.Data || v.mode == Mode.None ? p : v;
        } else {
            (m[0], m[1]) = (v, p);
        }
    }

    function _primary(Ctx memory c) private view returns (Media memory m) {
        bytes32 id = c.media[0].fileId;
        if (c.rec.onChainComplete && _weight(c.primary) <= c.limit && _complete(id)) {
            m = _inline(c, id, c.primary, true);
            if (m.mode != Mode.None) return m;
        }
        if (c.strict) revert RendererNotInlineable(c.token, c.id);
        return _locator(c, id);
    }

    /// @dev The first PREVIEW image of the work: inline if small and complete, else by locator.
    function _preview(Ctx memory c) private view returns (Media memory m) {
        for (uint256 i = 1; i < c.media.length; ++i) {
            if (c.media[i].role != FileRole.PREVIEW) continue;
            bytes32 id = c.media[i].fileId;
            IContentStore.FileInfo memory fi = _fileInfo(id);
            if (!_startsWith(bytes(fi.mimeType), "image/")) return m;
            if (_weight(fi) <= PREVIEW_LIMIT && _complete(id)) {
                m = _inline(c, id, fi, false);
                if (m.mode != Mode.None) return m;
            }
            return _locator(c, id);
        }
    }

    /// @dev The inline form of a complete file, or `None` if its encoding cannot be served.
    function _inline(Ctx memory c, bytes32 id, IContentStore.FileInfo memory fi, bool primary)
        private
        view
        returns (Media memory m)
    {
        IContentStore.Encoding enc = fi.encoding;
        if (primary && _isScript(fi.mimeType)) {
            return enc == IContentStore.Encoding.Identity && fi.length <= SCRIPT_LIMIT
                ? _shell(c, id, fi.length)
                : m;
        }
        if (enc == IContentStore.Encoding.Base64) m.mode = Mode.Copy;
        else if (enc == IContentStore.Encoding.Identity) m.mode = Mode.Encode;
        else return m;
        m.fileId = id;
        m.length = fi.length;
        m.text = _str(string.concat("data:", fi.mimeType, ";base64,"));
    }

    /// @dev A JavaScript file wrapped in an HTML page, as a base64 data URI. `None` if the script
    ///      is not UTF-8.
    function _shell(Ctx memory c, bytes32 id, uint256 length)
        private
        view
        returns (Media memory m)
    {
        bytes memory raw = new bytes(length);
        _copyFile(id, length, _ptr(raw));
        if (!Utf8.isValid(raw)) return m;
        bytes32 seed = _seed(c);
        bytes memory html = bytes.concat(
            bytes(SHELL_HEAD),
            abi.encodePacked(
                "{v:1,tokenId:",
                Strings.toString(c.id),
                ",seed:",
                seed == 0 ? bytes("null") : _quote(Strings.toHexString(uint256(seed), 32)),
                "};"
            ),
            bytes(HtmlScript.neutralize(string(raw))),
            bytes(SHELL_TAIL)
        );
        m.text = bytes.concat("data:text/html;base64,", bytes(Base64.encode(html)));
        m.mode = Mode.Data;
    }

    /// @dev The preferred locator of a file, else its first registered one (the preferred
    ///      locator is the implicit on-chain one when that kind is preferred and the file is
    ///      complete, and that has no URL).
    function _locator(Ctx memory c, bytes32 id) private view returns (Media memory m) {
        (bool ok, bytes memory ret) = BoundedCall.tryRead(
            c.records,
            abi.encodeCall(IWorkRecords.preferredLocator, (c.workId, id)),
            SMALL_GAS,
            LOCATOR_RETURN,
            AFTER_GAS
        );
        if (!ok) return m;
        // A file with no locator gives an empty one (kind NONE). The implicit on-chain locator
        // has no URL either, but copies may be registered, so only that case looks further.
        (Locator memory l,) = abi.decode(ret, (Locator, uint256));
        if (l.kind == LocatorKind.NONE) return m;
        if (l.kind != LocatorKind.ONCHAIN && bytes(l.uri).length != 0) {
            return Media(Mode.Locator, 0, 0, _str(l.uri));
        }
        Locator[] memory all = abi.decode(
            _read(
                c.records,
                abi.encodeCall(IWorkRecords.locators, (c.workId, id)),
                SMALL_GAS,
                LOCATORS_RETURN
            ),
            (Locator[])
        );
        for (uint256 i; i < all.length; ++i) {
            if (bytes(all[i].uri).length != 0) {
                return Media(Mode.Locator, 0, 0, _str(all[i].uri));
            }
        }
    }

    /// @dev Writes the whole JSON: the head, each non-empty media value as `,"key":"value"`,
    ///      and the tail. The file bytes go straight into the output buffer.
    function _assemble(bytes memory head, Media[3] memory m, bytes memory tail)
        private
        view
        returns (string memory)
    {
        bytes[3] memory keys =
            [bytes(',"image":"'), bytes(',"animation_url":"'), bytes(',"media_url":"')];
        uint256 total = head.length + tail.length;
        for (uint256 i; i < 3; ++i) {
            if (m[i].mode != Mode.None) total += keys[i].length + _size(m[i]) + 1;
        }
        bytes memory out = new bytes(total);
        uint256 p = _put(_ptr(out), head);
        for (uint256 i; i < 3; ++i) {
            if (m[i].mode == Mode.None) continue;
            p = _put(p, keys[i]);
            p = _put(p, m[i].text);
            if (m[i].mode == Mode.Copy) {
                _copyFile(m[i].fileId, m[i].length, p);
                p += m[i].length;
            } else if (m[i].mode == Mode.Encode) {
                p = _encodeFile(m[i], p);
            }
            p = _put(p, '"');
        }
        _put(p, tail);
        return string(out);
    }

    function _size(Media memory m) private pure returns (uint256) {
        if (m.mode == Mode.Copy) return m.text.length + m.length;
        if (m.mode == Mode.Encode) return m.text.length + (((m.length + 2) / 3) << 2);
        return m.text.length;
    }

    /// @dev Reads an `Identity` file, base64-encodes it into `dst` and releases the transient
    ///      buffers. Returns the end of the output.
    function _encodeFile(Media memory m, uint256 dst) private view returns (uint256) {
        uint256 mark;
        assembly ("memory-safe") {
            mark := mload(0x40)
        }
        bytes memory raw = new bytes(m.length);
        _copyFile(m.fileId, m.length, _ptr(raw));
        bytes memory text = bytes(Base64.encode(raw));
        uint256 end = _put(dst, text);
        assembly ("memory-safe") {
            mstore(0x40, mark)
        }
        return end;
    }

    /// @dev Copies a file's stored bytes to memory at `dst`, one chunk at a time. Each chunk is
    ///      released once copied, and must have the length the store's layout rule gives.
    function _copyFile(bytes32 id, uint256 length, uint256 dst) private view {
        uint256 done;
        for (uint256 i; done < length; ++i) {
            uint256 mark;
            assembly ("memory-safe") {
                mark := mload(0x40)
            }
            bytes memory chunk = bytes(
                BoundedCall.readString(
                    address(contentStore),
                    abi.encodeCall(IContentStore.readChunk, (id, i)),
                    CHUNK_GAS,
                    SSTORE2.MAX_CHUNK_LENGTH,
                    AFTER_GAS
                )
            );
            // The store's layout rule: full chunks, then the remainder.
            uint256 n = chunk.length;
            uint256 left = length - done;
            if (n != (left < SSTORE2.MAX_CHUNK_LENGTH ? left : SSTORE2.MAX_CHUNK_LENGTH)) {
                revert RendererReadFailed(address(contentStore), IContentStore.readChunk.selector);
            }
            assembly ("memory-safe") {
                mcopy(add(dst, done), add(chunk, 0x20), n)
                mstore(0x40, mark)
            }
            done += n;
        }
    }

    // ------------------------------------------------------------------ the rest of the JSON

    /// @dev What a work without an open record gets: its name from the collection and serial,
    ///      and the traits Stream itself knows. The artist is the lead artist's ID, since the
    ///      names are in the record.
    function _coreOnly(Ctx memory c, bytes[] memory t) private view returns (string memory) {
        bytes memory name = abi.encodePacked("6529 Works %23", Strings.toString(c.id));
        if (c.core.collectionId != 0) {
            name = abi.encodePacked(_str(c.collection), " %23", Strings.toString(c.core.serial));
        }
        t[0] = _trait("Artist ID", _quote(Strings.toHexString(c.core.artistId)));
        return string(
            abi.encodePacked(
                PREFIX,
                '{"name":"',
                name,
                '","description":"The work record is not open yet.","attributes":[',
                _join(t, _chainTraits(c, t, 1)),
                "]}"
            )
        );
    }

    /// @dev Adds the traits only the chain knows to `t`: the collection and serial, the master of
    ///      an edition, the seed and a dispute statement. Returns the new count.
    function _chainTraits(Ctx memory c, bytes[] memory t, uint256 n)
        private
        view
        returns (uint256)
    {
        if (c.core.collectionId != 0) {
            t[n++] = _trait("Collection", _quote(c.collection));
            t[n++] = _trait("Serial", bytes(Strings.toString(c.core.serial)));
        }
        if (c.edition) t[n++] = _trait("Edition of", bytes(Strings.toString(c.workId)));
        bytes32 seed = _seed(c);
        if (seed != 0) t[n++] = _trait("Seed", _quote(Strings.toHexString(uint256(seed), 32)));
        if (address(statementLog) != address(0)) {
            bytes32 entry = abi.decode(
                _read(
                    address(statementLog),
                    abi.encodeCall(IStatementLog.latestDisputeOutcome, (c.stream, c.workId)),
                    SMALL_GAS,
                    32
                ),
                (bytes32)
            );
            if (entry != 0) {
                t[n++] =
                    _trait("Dispute statement", _quote(Strings.toHexString(uint256(entry), 32)));
            }
        }
        return n;
    }

    /// @dev The JSON after the media: content type and hash, license, and the attributes (the
    ///      renderer's traits first, then the record's own).
    function _tail(Ctx memory c, bytes[] memory t, uint256 n, bytes memory attributes)
        private
        view
        returns (bytes memory)
    {
        License memory lic = abi.decode(
            _read(
                c.records,
                abi.encodeCall(IWorkRecords.licenseOf, (c.workId)),
                SMALL_GAS,
                Limits.MAX_LICENSE_ID_BYTES + 192
            ),
            (License)
        );
        bytes memory out = abi.encodePacked(
            ',"content_type":',
            _quote(c.primary.mimeType),
            ',"content_hash":"',
            Strings.toHexString(uint256(c.media[0].sha256Hash), 32),
            '","license":',
            _quote(lic.spdxId)
        );
        bytes memory url = _licenseUrl(lic.spdxId);
        if (url.length != 0) out = bytes.concat(out, ',"license_url":"', url, '"');
        bytes memory ours = _join(t, n);
        return bytes.concat(
            out,
            ',"attributes":[',
            ours,
            ours.length != 0 && attributes.length != 0 ? bytes(",") : bytes(""),
            attributes,
            "]}"
        );
    }

    /// @dev The SPDX page of a license identifier, with its original case (spdx.org URLs are case
    ///      sensitive), none for a `LicenseRef-` expression in any case. Text files have no
    ///      locators of their own (locators are for media files), so this is the license's URL.
    function _licenseUrl(string memory spdxId) private pure returns (bytes memory) {
        bytes memory id = bytes(spdxId);
        bytes memory prefix = "licenseref-";
        bool ref = id.length >= prefix.length;
        for (uint256 i; ref && i < prefix.length; ++i) {
            bytes1 b = id[i];
            ref = (b >= "A" && b <= "Z" ? bytes1(uint8(b) + 32) : b) == prefix[i];
        }
        if (id.length == 0 || ref) return "";
        return abi.encodePacked("https://spdx.org/licenses/", id, ".html");
    }

    /// @dev The seed of a seeded work, zero for none. Once the record is open the satellite has
    ///      it; before, only a VRF seed can be read, from the entropy module by item hash (an
    ///      ARTIST seed is stored when the record opens).
    function _seed(Ctx memory c) private view returns (bytes32 seed) {
        if (c.core.seedPolicy == SeedPolicy.NONE) return 0;
        if (c.open) {
            (, seed) = abi.decode(
                _read(c.records, abi.encodeCall(IWorkRecords.seedOf, (c.workId)), SMALL_GAS, 64),
                (SeedPolicy, bytes32)
            );
        } else if (c.core.seedPolicy == SeedPolicy.VRF) {
            address entropy = abi.decode(
                _read(c.stream, abi.encodeCall(IStream.entropyModule, ()), SMALL_GAS, 32), (address)
            );
            seed = abi.decode(
                _read(
                    entropy, abi.encodeCall(IEntropyModule.seedOf, (c.core.itemHash)), SMALL_GAS, 32
                ),
                (bytes32)
            );
        }
    }

    /// @dev `value` is JSON text: a quoted string or a number.
    function _trait(string memory key, bytes memory value) private pure returns (bytes memory) {
        return abi.encodePacked('{"trait_type":"', key, '","value":', value, "}");
    }

    /// @dev `t0,t1,...` from the first `n` items, in one allocation.
    function _join(bytes[] memory t, uint256 n) private pure returns (bytes memory out) {
        uint256 total = n == 0 ? 0 : n - 1;
        for (uint256 i; i < n; ++i) {
            total += t[i].length;
        }
        out = new bytes(total);
        uint256 p = _ptr(out);
        for (uint256 i; i < n; ++i) {
            if (i != 0) p = _put(p, ",");
            p = _put(p, t[i]);
        }
    }

    // ------------------------------------------------------------------ helpers

    function _read(address target, bytes memory input, uint256 gasLimit, uint256 maxReturn)
        private
        view
        returns (bytes memory ret)
    {
        bool ok;
        (ok, ret) = BoundedCall.tryRead(target, input, gasLimit, maxReturn, AFTER_GAS);
        // `input` is always an encoded call, so it holds a selector.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (!ok) revert RendererReadFailed(target, bytes4(input));
    }

    function _fileInfo(bytes32 id) private view returns (IContentStore.FileInfo memory) {
        return abi.decode(
            _read(
                address(contentStore), abi.encodeCall(IContentStore.fileInfo, (id)), SMALL_GAS, 512
            ),
            (IContentStore.FileInfo)
        );
    }

    function _complete(bytes32 id) private view returns (bool) {
        return abi.decode(
            _read(
                address(contentStore),
                abi.encodeCall(IContentStore.isComplete, (id)),
                COMPLETE_GAS,
                32
            ),
            (bool)
        );
    }

    /// @dev A string made safe for a JSON string inside a non-base64 data URI.
    function _str(string memory s) private pure returns (bytes memory) {
        if (!Utf8.isValid(bytes(s))) revert RendererInvalidUtf8();
        return bytes(DataUri.escape(JsonEscape.escape(s)));
    }

    function _quote(string memory s) private pure returns (bytes memory) {
        return abi.encodePacked('"', _str(s), '"');
    }

    /// @dev The cost-weighted size of a file: an `Identity` file counts eight times, because the
    ///      renderer has to base64-encode it (about 80 gas a byte, against 10 for copying base64
    ///      text that is already encoded).
    function _weight(IContentStore.FileInfo memory fi) private pure returns (uint256) {
        return fi.encoding == IContentStore.Encoding.Identity ? 8 * fi.length : fi.length;
    }

    function _isScript(string memory mime) private pure returns (bool) {
        bytes32 h = keccak256(bytes(mime));
        return h == keccak256("text/javascript") || h == keccak256("application/javascript");
    }

    function _startsWith(bytes memory s, bytes memory prefix) private pure returns (bool) {
        if (s.length < prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (s[i] != prefix[i]) return false;
        }
        return true;
    }

    function _ptr(bytes memory b) private pure returns (uint256 p) {
        assembly ("memory-safe") {
            p := add(b, 0x20)
        }
    }

    /// @dev Copies `b` to `p` and returns the address after it.
    function _put(uint256 p, bytes memory b) private pure returns (uint256) {
        assembly ("memory-safe") {
            mcopy(p, add(b, 0x20), mload(b))
        }
        return p + b.length;
    }
}
