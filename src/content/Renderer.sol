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
///      registered and complete, or when it is not acceptable, the work gets core-only metadata
///      from Stream with a `record_status` field (`not_open`, `incomplete` or `invalid`)
///      instead, and never a revert; `fullTokenURI` reverts for such a work. A record is not acceptable if it is not
///      `Identity`, is over `MAX_RECORD_BYTES` (12 KiB), is not UTF-8 or JSON (no key with a
///      backslash, no `\u0000`, lone surrogate or bad hex digit in an escape, no number of more
///      than 24 bytes or with more than two exponent digits, at most `JsonScan.MAX_VALUES`
///      units (values, keys and escapes), eight levels), has no name or a wrong type, lists
///      more than `MAX_ARTISTS` artists or `MAX_ATTRIBUTES` attributes, holds more than
///      `MAX_ESCAPES` `%` and `#`, gives a `year` that is not an integer of at most six digits,
///      or has an attribute that is not an object whose members are only `trait_type`, `value`,
///      `display_type` and `max_value`, each at most once, with a string `trait_type` and a
///      string or number `value`, or whose name is not printable ASCII, has a backslash or is
///      one the renderer writes itself in any case or spacing. These bounds are chosen together, so that a record at every one of them at once
///      still costs under 8M gas, whatever its bytes (`RendererGas.t.sol`: a row for every class
///      of byte, and every cap at once; `TokenUriBudget.t.sol`: the budget proof on the real
///      stack, with the records satellite's caps).
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
///      as it is, once the store has attested it as strict base64 with `isBase64Attested`, so
///      it cannot break out of the JSON string) and `Identity` (encoded here, and counted eight
///      times). `Gzip` and `GzipBase64` hold a compressed stream, not the media, so they are
///      served by locator only. A JavaScript primary (stored as `Identity`, and whose record
///      declares no `dependencies`) is wrapped in a small HTML page that sets `window.works` in a
///      script of its own (see `SHELL_HEAD`), with `</script` and `<!--` neutralized in the
///      artist's (see `HtmlScript` for what that changes; a script with more than
///      `MAX_SCRIPT_LT` `<` is not wrapped). Otherwise the preferred locator is
///      given, plus a small on-chain preview if the work lists a complete PREVIEW image: a
///      preview is inlined by the same rules as a primary, so an unattested `Base64` preview is
///      given by locator. A satellite that cannot answer for a locator fails the call.
///      `fullTokenURI` raises the limit to 1 MiB of cost-weighted size and reverts instead of
///      falling back: a `Base64` file is inlined up to 1 MiB, an `Identity` file up to 128 KiB.
///      It costs about 30M gas at 1 MiB, an `eth_call`, not a transaction.
///
///      Memory. Media is read one store chunk at a time straight into the single output buffer
///      (a `readChunk` result is released as soon as it is copied), so there is no second copy
///      of the file; an `Identity` file adds one transient buffer for its raw bytes.
contract Renderer is IRenderer {
    /// @notice The largest threshold, and the largest primary file `fullTokenURI` inlines.
    uint256 internal constant MAX_INLINE_BYTES = 1_048_576;
    /// @notice The threshold the deployment uses (ADR 0001: 256 KiB; the gas matrix in
    ///         `test/content/renderer/RendererGas.t.sol` shows it fits 8M gas).
    uint256 public constant DEFAULT_INLINE_THRESHOLD = 262_144;
    /// @notice The largest PREVIEW image, cost-weighted stored bytes, inlined next to a primary
    ///         file that is not.
    uint256 internal constant PREVIEW_LIMIT = 65_536;
    /// @notice The largest JavaScript primary, in stored bytes, that `tokenURI` wraps in the HTML
    ///         page (it has the 8M promise); `fullTokenURI` wraps a larger one, up to its size
    ///         limit.
    uint256 internal constant SCRIPT_LIMIT = 8_192;
    /// @notice The largest record file, in bytes: one store chunk.
    uint256 internal constant MAX_RECORD_BYTES = Limits.MAX_RECORD_BYTES;
    /// @notice The most artists a record may list.
    uint256 internal constant MAX_ARTISTS = Limits.MAX_ARTISTS;
    /// @notice The most attributes a record may list (each costs about 27,000 gas: its nine
    ///         units, and a second walk over it).
    uint256 internal constant MAX_ATTRIBUTES = 32;
    /// @notice The most `<` a script may hold and still be wrapped in the HTML page (each costs up
    ///         to about 2,800 gas to neutralize).
    uint256 internal constant MAX_SCRIPT_LT = 1_024;
    /// @notice The most `%` and `#` a record may hold (each costs about 200 gas to escape).
    uint256 internal constant MAX_ESCAPES = 512;

    /// @notice The content store the media and records are read from (immutable).
    IContentStore public immutable contentStore;
    /// @notice The statement log whose `latestDisputeOutcome` is shown, or zero for none.
    IStatementLog public immutable statementLog;
    /// @inheritdoc IRenderer
    uint256 public immutable inlineThreshold;

    /// @dev Gas caps per read. A read gets exactly its cap (BoundedCall), so these bound the
    ///      cost of a hostile or broken target; they are ceilings, not estimates. The media list
    ///      has its own: the satellite reads the store once per file, under 200,000 gas fully
    ///      cold at 32 files, and its cap leaves room for a repricing of cold reads, which would
    ///      otherwise break every large work's `tokenURI` (a finalized work pins its renderer).
    uint256 private constant SMALL_GAS = 300_000;
    uint256 private constant MEDIA_GAS = 1_000_000;
    uint256 private constant CHUNK_GAS = 300_000;
    uint256 private constant COMPLETE_GAS = 700_000;
    /// @dev Gas the renderer needs after any one read returns (checked before the read).
    uint256 private constant AFTER_GAS = 50_000;
    /// @dev Return-size caps in bytes.
    uint256 private constant TEXT_RETURN = 4_096;
    uint256 private constant LOCATOR_RETURN = Limits.MAX_URI_BYTES + 256;

    string private constant PREFIX = "data:application/json;utf8,";
    /// @dev The bytes an SPDX identifier is made of, as a bit set over ASCII: `A-Z a-z 0-9 . + -`.
    uint256 private constant SPDX_CHARS = 0x07fffffe07fffffe03ff680000000000;
    /// @dev The page around a JavaScript primary. `window.works` is the script's interface, public
    ///      and stable: `v` (the version of this interface, 1), `tokenId` and `seed` (`"0x"` hex,
    ///      or null when the work has no seed). A change to it needs a new `v`. It is set in a
    ///      script of its own, ahead of the artist's, which follows.
    string private constant SHELL_HEAD = '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1"><style>'
        "html,body{margin:0;height:100%;overflow:hidden}</style></head><body><script>"
        "window.works=";
    string private constant SHELL_TAIL = "</script></body></html>";

    /// @notice The threshold is zero or above `MAX_INLINE_BYTES`.
    error RendererThresholdInvalid(uint256 threshold);
    /// @notice A read of `target` failed: no code, a revert, out of its gas cap, or too much
    ///         return data. `selector` names the call.
    error RendererReadFailed(address target, bytes4 selector);
    /// @notice A string from the Stream, a locator or the store is not well-formed UTF-8.
    error RendererInvalidUtf8();
    /// @notice The work's data breaks a rule: no primary file first, or an edition whose content
    ///         hash is not its master's. (A bad record is not an error: it renders core-only.)
    error RendererRecordInvalid(address token, uint256 tokenId);
    /// @notice `fullTokenURI` cannot serve the work in full: its record is not open, incomplete or
    ///         invalid, or the primary file is not on-chain complete, is incomplete, too large,
    ///         not attested `Base64`, or not stored as `Identity` or `Base64`.
    error RendererNotInlineable(address token, uint256 tokenId);

    /// @dev What a work's record file is good for: not open yet, not completely uploaded,
    ///      unacceptable, or ready.
    enum RecordState {
        NotOpen,
        Incomplete,
        Invalid,
        Ready
    }

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
        bool deps;
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
            _word(c.records, IWorkRecords.isOpen.selector, c.workId, SMALL_GAS, 32), (bool)
        );
        RecordState state = RecordState.NotOpen;
        bytes memory record = "";
        if (c.open) {
            _loadRecord(c);
            (state, record) = _record(c);
        }
        bytes[] memory t = new bytes[](MAX_ARTISTS + 8);
        bytes memory head = "";
        bytes memory attributes = "";
        uint256 n = 0;
        if (state == RecordState.Ready) {
            bool ok = false;
            (ok, head, n, attributes) = _describe(c, record, t);
            if (!ok) state = RecordState.Invalid;
        }
        if (state != RecordState.Ready) {
            if (strict) revert RendererNotInlineable(token, id);
            return _coreOnly(c, t, state);
        }
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
                _word(c.token, IEditions.masterOf.selector, c.id, SMALL_GAS, 96),
                (address, uint256, bytes32)
            );
        } else {
            c.stream = c.token;
            c.workId = c.id;
        }
        c.core = abi.decode(
            _word(c.stream, IStream.work.selector, c.workId, SMALL_GAS, 288), (IStream.WorkCore)
        );
        c.records = abi.decode(
            _read(c.stream, abi.encodeCall(IStream.workRecords, ()), SMALL_GAS, 32), (address)
        );
        if (c.core.collectionId != 0) {
            c.collection =
            abi.decode(
                _word(
                    c.stream,
                    IStream.collection.selector,
                    c.core.collectionId,
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
            _word(c.records, IWorkRecords.record.selector, c.workId, SMALL_GAS, 256),
            (IWorkRecords.RecordInfo)
        );
        c.media = abi.decode(
            _word(
                c.records,
                IWorkRecords.mediaOf.selector,
                c.workId,
                MEDIA_GAS,
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

    /// @dev The record JSON, percent-escaped, and whether it is ready: not if its file is not
    ///      complete yet, and never if it is not `Identity`, is over one chunk, is not UTF-8, or
    ///      holds too many `%` and `#` to escape within the gas budget. A record file the store
    ///      does not answer for (an approved one whose manifest was never registered) is not
    ///      complete either: the store answered for the primary file in this same call, so the
    ///      failure is the unknown file, not a broken store.
    function _record(Ctx memory c) private view returns (RecordState, bytes memory j) {
        bytes32 id = c.rec.recordFileId;
        (bool known, bytes memory info) = BoundedCall.tryRead(
            address(contentStore),
            abi.encodeWithSelector(IContentStore.fileInfo.selector, id),
            SMALL_GAS,
            512,
            AFTER_GAS
        );
        if (!known) return (RecordState.Incomplete, j);
        IContentStore.FileInfo memory fi = abi.decode(info, (IContentStore.FileInfo));
        if (fi.encoding != IContentStore.Encoding.Identity || fi.length > MAX_RECORD_BYTES) {
            return (RecordState.Invalid, j);
        }
        if (!_complete(id)) return (RecordState.Incomplete, j);
        j = new bytes(fi.length);
        _copyFile(id, fi.length, _ptr(j));
        if (!Utf8.isValid(j)) return (RecordState.Invalid, j);
        // `%` and `#` occur only inside JSON strings, so escaping the whole file keeps it valid.
        (bool ok, string memory escaped) = DataUri.escape(string(j), MAX_ESCAPES);
        return ok ? (RecordState.Ready, bytes(escaped)) : (RecordState.Invalid, j);
    }

    /// @dev Reads the record: whether it is acceptable, the head of the JSON
    ///      (`{"name":...,"description":...`), the record's traits in `t` (each artist, the year,
    ///      the medium, the dimensions) and the inside of its `attributes` array. It also notes
    ///      in `c.deps` whether the record declares `dependencies`.
    function _describe(Ctx memory c, bytes memory j, bytes[] memory t)
        private
        pure
        returns (bool ok, bytes memory head, uint256 n, bytes memory attributes)
    {
        bytes32[] memory keys = new bytes32[](8);
        keys[0] = keccak256("name");
        keys[1] = keccak256("description");
        keys[2] = keccak256("artists");
        keys[3] = keccak256("year");
        keys[4] = keccak256("medium");
        keys[5] = keccak256("dimensions");
        keys[6] = keccak256("attributes");
        keys[7] = keccak256("dependencies");
        uint256[] memory s;
        (ok, s) = JsonScan.object(j, keys);
        bytes memory name = _text(j, s[0], true);
        bytes memory description = _text(j, s[1], false);
        bytes memory medium = _text(j, s[4], false);
        bytes memory dimensions = _text(j, s[5], false);
        // A name is required and not empty (`""` is two bytes); a wrong type is empty text.
        if (!ok || name.length < 3 || description.length == 0) return _bad();
        if (medium.length == 0 || dimensions.length == 0) return _bad();
        head = abi.encodePacked(PREFIX, '{"name":', name, ',"description":', description);
        if (s[2] != 0) {
            uint256[] memory a;
            (ok, a) = JsonScan.elements(j, s[2] >> 128, MAX_ARTISTS);
            for (uint256 i; ok && i < a.length; ++i) {
                bytes memory artist = _text(j, a[i], true);
                ok = artist.length > 2;
                t[n++] = _trait("Artist", artist);
            }
            if (!ok) return _bad();
        }
        if (s[3] != 0) {
            bytes memory year = JsonScan.slice(j, s[3]);
            if (!_year(year)) return _bad();
            t[n++] = _trait("Year", year);
        }
        if (medium.length > 2) t[n++] = _trait("Medium", medium);
        if (dimensions.length > 2) t[n++] = _trait("Dimensions", dimensions);
        if (s[6] != 0) {
            (ok, attributes) = _attributes(j, s[6]);
            if (!ok) return _bad();
        }
        // A script that needs libraries cannot be wrapped: v1 bundles nothing.
        c.deps = s[7] != 0 && JsonScan.slice(j, s[7]).length > 2;
        ok = true;
    }

    function _bad() private pure returns (bool, bytes memory, uint256, bytes memory) {
        return (false, "", 0, "");
    }

    /// @dev The inside of the record's `attributes` array, if every element is an object of the
    ///      OpenSea attribute keys only (`trait_type`, `value`, `display_type`, `max_value`, each
    ///      at most once), with a printable ASCII `trait_type` that is not one of the renderer's
    ///      own (`_reserved`) and a string or number `value`. The renderer's traits are the only
    ///      ones it vouches for.
    function _attributes(bytes memory j, uint256 span) private pure returns (bool, bytes memory) {
        bytes32[] memory keys = new bytes32[](4);
        bytes32 k0 = keccak256("trait_type");
        bytes32 k1 = keccak256("value");
        bytes32 k2 = keccak256("display_type");
        bytes32 k3 = keccak256("max_value");
        assembly ("memory-safe") {
            mstore(add(keys, 0x20), k0)
            mstore(add(keys, 0x40), k1)
            mstore(add(keys, 0x60), k2)
            mstore(add(keys, 0x80), k3)
        }
        (bool ok, uint256[] memory a) = JsonScan.records(j, span >> 128, keys, MAX_ATTRIBUTES);
        // Each element: its span, then those of its four members (zero if absent).
        for (uint256 i; ok && i < a.length; i += 5) {
            if (
                a[i + 1] == 0 || a[i + 2] == 0 || _reserved(JsonScan.slice(j, a[i + 1]))
                    || !_scalar(j[a[i + 2] >> 128])
            ) return (false, "");
        }
        // The text between the brackets (an array has at least the two).
        uint256 start = (span >> 128) + 1;
        uint256 end = (span & type(uint128).max) - 1;
        return (ok, a.length == 0 ? bytes("") : JsonScan.slice(j, (start << 128) | end));
    }

    /// @dev Whether the quoted trait name `t` (a span, so never empty) is unacceptable: not a
    ///      string; not printable ASCII (a letter of another script, an invisible character or a
    ///      no-break space can make a name display like another); a backslash (an escape could
    ///      spell any name); two spaces in a row (displays collapse them); or one of the names
    ///      the renderer writes itself, in any case and with any spaces (so `SEED`, `Serial `
    ///      and `ArtistID` are refused). With the rest refused, case and spacing are the only
    ///      ways left for a name to look like a reserved one.
    ///
    ///      The bytes are checked a word at a time (a few gas a byte): with `x = word ^ (b *
    ///      ones)`, `~(((x & 0x7f..) + 0x7f..) | x) & 0x80..` marks the top bit of exactly the
    ///      bytes equal to `b`. A name of more than 33 bytes holds at least 17 other characters
    ///      than spaces (no two spaces in a row), more than any reserved name, so only a shorter
    ///      one is compared: its characters other than spaces, lowered (OR 0x20 lowers a letter
    ///      and turns no other printable byte into one), by the first four bytes of their hash.
    ///      A clash with another name only makes that record render core-only, so four bytes
    ///      are enough.
    function _reserved(bytes memory t) private pure returns (bool bad) {
        assembly ("memory-safe") {
            let p := add(t, 0x20)
            let e := add(p, mload(t))
            let ones := div(not(0), 255)
            let high := shl(7, ones)
            let low := mul(ones, 0x7f)
            bad := iszero(eq(byte(0, mload(p)), 0x22))
            let spaces := 0
            for { let q := p } and(iszero(bad), lt(q, e)) { q := add(q, 32) } {
                let w := mload(q)
                let x := xor(w, mul(ones, 0x20))
                let s := and(not(or(add(and(x, low), low), x)), high)
                // Two spaces in a row, in this word or across from the last word's last byte.
                let z := and(s, or(shl(8, s), shl(248, spaces)))
                spaces := s
                // A byte of 0x80 or more, a backslash or DEL.
                x := xor(w, mul(ones, 0x5c))
                let y := xor(w, low)
                z := or(
                    or(z, and(w, high)),
                    and(not(and(or(add(and(x, low), low), x), or(add(and(y, low), low), y))), high)
                )
                // The bytes at and after `e` are not part of the name.
                if lt(sub(e, q), 32) { z := and(z, not(shr(shl(3, sub(e, q)), not(0)))) }
                bad := iszero(iszero(z))
            }
            if and(iszero(bad), lt(mload(t), 36)) {
                // Scratch space holds the lowered letters.
                let k := 0
                for { let q := add(p, 1) } lt(q, sub(e, 1)) { q := add(q, 1) } {
                    let c := byte(0, mload(q))
                    if xor(c, 0x20) {
                        mstore8(k, or(c, 0x20))
                        k := add(k, 1)
                    }
                }
                if lt(k, 17) {
                    // `bytes4(keccak256(name))` of each name the renderer writes, lowered and
                    // without spaces: "artist", "artistid", "year", "medium", "dimensions",
                    // "collection", "serial", "editionof", "seed", "disputestatement". (A test
                    // checks every one.)
                    let h := shr(224, keccak256(0, k))
                    bad := or(
                        or(
                            or(
                                or(eq(h, 0xf8c87671), eq(h, 0x0dda829c)),
                                or(eq(h, 0xb4c11afb), eq(h, 0x3ab0b674))
                            ),
                            or(
                                or(eq(h, 0xd59243b9), eq(h, 0xa77d3cda)),
                                or(eq(h, 0x077e5ff4), eq(h, 0x63553a94))
                            )
                        ),
                        or(eq(h, 0x66a80b61), eq(h, 0xad290f14))
                    )
                }
            }
        }
    }

    /// @dev A string or number (what a trait value can be).
    function _scalar(bytes1 first) private pure returns (bool) {
        return first == '"' || first == "-" || (first >= "0" && first <= "9");
    }

    /// @dev A whole number of at most six digits, with an optional minus sign.
    function _year(bytes memory y) private pure returns (bool ok) {
        uint256 i = y[0] == "-" ? 1 : 0; // a span is never empty
        ok = y.length > i && y.length - i <= 6;
        for (; ok && i < y.length; ++i) {
            ok = y[i] >= "0" && y[i] <= "9";
        }
    }

    /// @dev The JSON string at `span` (quotes included); `""` if absent and not `required`. Empty
    ///      (which is no valid text) if it is anything else. A span is never empty.
    function _text(bytes memory j, uint256 span, bool required)
        private
        pure
        returns (bytes memory text)
    {
        if (span == 0) return required ? bytes("") : bytes('""');
        text = JsonScan.slice(j, span);
        if (text[0] != '"') return "";
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
        if (_isImage(c.primary.mimeType)) {
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
            if (!_isImage(fi.mimeType)) return m;
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
            // `fullTokenURI` (strict) has no 8M promise: its limit is the size check before.
            return enc == IContentStore.Encoding.Identity && (fi.length <= SCRIPT_LIMIT || c.strict)
                && !c.deps
                ? _shell(c, id, fi.length)
                : m;
        }
        if (enc == IContentStore.Encoding.Base64) {
            // Concatenated as stored, so only text the store has checked as strict base64.
            if (!_attested(id)) return m;
            m.mode = Mode.Copy;
        } else if (enc == IContentStore.Encoding.Identity) {
            m.mode = Mode.Encode;
        } else {
            return m;
        }
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
        (bool ok, string memory safe) = HtmlScript.neutralize(string(raw), MAX_SCRIPT_LT);
        if (!ok) return m;
        bytes32 seed = _seed(c);
        bytes memory html = bytes.concat(
            bytes(SHELL_HEAD),
            abi.encodePacked(
                "{v:1,tokenId:",
                Strings.toString(c.id),
                ",seed:",
                seed == 0 ? bytes("null") : _quote(Strings.toHexString(uint256(seed), 32)),
                "};</script><script>"
            ),
            bytes(safe),
            bytes(SHELL_TAIL)
        );
        m.text = bytes.concat("data:text/html;base64,", bytes(Base64.encode(html)));
        m.mode = Mode.Data;
    }

    /// @dev The preferred locator of a file: its URL, or none for a file without one (the
    ///      satellite answers kind NONE) and for the implicit on-chain locator, which has no URL.
    ///      A failed read reverts: no media is better than media that depends on a gas cap.
    function _locator(Ctx memory c, bytes32 id) private view returns (Media memory m) {
        (Locator memory l,) = abi.decode(
            _read(
                c.records,
                abi.encodeCall(IWorkRecords.preferredLocator, (c.workId, id)),
                SMALL_GAS,
                LOCATOR_RETURN
            ),
            (Locator, uint256)
        );
        if (l.kind != LocatorKind.NONE && l.kind != LocatorKind.ONCHAIN && bytes(l.uri).length != 0)
        {
            return Media(Mode.Locator, 0, 0, _str(l.uri));
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

    /// @dev What a work whose record cannot be shown gets: its name from the collection and
    ///      serial, and the traits Stream itself knows. The artist is the lead artist's ID, since
    ///      the names are in the record. `record_status` says why: `not_open`, `incomplete` or
    ///      `invalid`.
    function _coreOnly(Ctx memory c, bytes[] memory t, RecordState state)
        private
        view
        returns (string memory)
    {
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
                '","description":"The work record is not available.","record_status":"',
                state == RecordState.NotOpen
                    ? bytes("not_open")
                    : state == RecordState.Incomplete ? bytes("incomplete") : bytes("invalid"),
                '","attributes":[',
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
            _word(
                c.records,
                IWorkRecords.licenseOf.selector,
                c.workId,
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
        bytes memory url = _licenseUrl(c, lic);
        if (url.length != 0) out = bytes.concat(out, ',"license_url":"', url, '"');
        if (lic.textFileId != 0) {
            out = bytes.concat(
                out,
                ',"license_text_file":"',
                bytes(Strings.toHexString(uint256(lic.textFileId), 32)),
                '"'
            );
        }
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

    /// @dev The license's URL. For an SPDX identifier (only `[A-Za-z0-9.+-]`, not a `LicenseRef-`
    ///      expression in any case) it is the SPDX page, in the identifier's own case (spdx.org
    ///      URLs are case sensitive). For any other license it is a locator of the license text
    ///      file, if the work lists that file among its media (locators exist only for media
    ///      files); `license_text_file` always names the file.
    function _licenseUrl(Ctx memory c, License memory lic) private view returns (bytes memory) {
        bytes memory id = bytes(lic.spdxId);
        bool spdx = id.length != 0;
        for (uint256 i; spdx && i < id.length; ++i) {
            uint8 b = uint8(id[i]);
            spdx = b < 128 && (SPDX_CHARS >> b) & 1 == 1;
        }
        // `LicenseRef-` in any case: within the charset above, OR-ing 0x20 into a byte lowers a
        // letter and leaves digits, `.`, `+` and `-` as they are.
        bool ref;
        assembly ("memory-safe") {
            ref := and(
                iszero(lt(mload(id), 11)),
                eq(
                    shr(168, or(mload(add(id, 0x20)), shl(168, 0x2020202020202020202020))),
                    0x6c6963656e73657265662d
                )
            )
        }
        if (spdx && !ref) return abi.encodePacked("https://spdx.org/licenses/", id, ".html");
        for (uint256 i; lic.textFileId != 0 && i < c.media.length; ++i) {
            if (c.media[i].fileId == lic.textFileId) return _locator(c, lic.textFileId).text;
        }
        return "";
    }

    /// @dev The seed of a seeded work, zero for none. Once the record is open the satellite has
    ///      it; before, only a VRF seed can be read, from the entropy module by item hash (an
    ///      ARTIST seed is stored when the record opens).
    function _seed(Ctx memory c) private view returns (bytes32 seed) {
        if (c.core.seedPolicy == SeedPolicy.NONE) return 0;
        if (c.open) {
            (, seed) = abi.decode(
                _word(c.records, IWorkRecords.seedOf.selector, c.workId, SMALL_GAS, 64),
                (SeedPolicy, bytes32)
            );
        } else if (c.core.seedPolicy == SeedPolicy.VRF) {
            address entropy = abi.decode(
                _read(c.stream, abi.encodeCall(IStream.entropyModule, ()), SMALL_GAS, 32), (address)
            );
            seed = abi.decode(
                _word(
                    entropy, IEntropyModule.seedOf.selector, uint256(c.core.itemHash), SMALL_GAS, 32
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

    /// @dev A read whose only argument is one word: `selector(arg)`.
    function _word(
        address target,
        bytes4 selector,
        uint256 arg,
        uint256 gasLimit,
        uint256 maxReturn
    ) private view returns (bytes memory) {
        return _read(target, abi.encodeWithSelector(selector, arg), gasLimit, maxReturn);
    }

    function _fileInfo(bytes32 id) private view returns (IContentStore.FileInfo memory) {
        return abi.decode(
            _word(
                address(contentStore), IContentStore.fileInfo.selector, uint256(id), SMALL_GAS, 512
            ),
            (IContentStore.FileInfo)
        );
    }

    function _complete(bytes32 id) private view returns (bool) {
        return abi.decode(
            _word(
                address(contentStore),
                IContentStore.isComplete.selector,
                uint256(id),
                COMPLETE_GAS,
                32
            ),
            (bool)
        );
    }

    /// @dev A string made safe for a JSON string inside a non-base64 data URI. The strings here
    ///      come from reads capped at a few KiB, so their `%` and `#` need no further cap.
    function _str(string memory s) private pure returns (bytes memory) {
        if (!Utf8.isValid(bytes(s))) revert RendererInvalidUtf8();
        (, string memory out) = DataUri.escape(JsonEscape.escape(s), type(uint256).max);
        return bytes(out);
    }

    function _attested(bytes32 id) private view returns (bool) {
        return abi.decode(
            _word(
                address(contentStore),
                IContentStore.isBase64Attested.selector,
                uint256(id),
                SMALL_GAS,
                32
            ),
            (bool)
        );
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

    /// @dev Whether a MIME type is `image/*`. The store's MIME types are lowercase, so this is
    ///      one comparison of the first six bytes.
    function _isImage(string memory mime) private pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(gt(mload(mime), 5), eq(shr(208, mload(add(mime, 0x20))), 0x696d6167652f))
        }
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
