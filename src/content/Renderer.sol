// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IContentStore } from "../interfaces/IContentStore.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import { IStatementLog } from "../interfaces/IStatementLog.sol";
import { Collection, Facts, Slots, Work } from "../interfaces/core/CoreTypes.sol";
import { IEditions } from "../interfaces/core/IEditions.sol";
import { ILocators } from "../interfaces/core/ILocators.sol";
import { IModuleSlots } from "../interfaces/core/IModules.sol";
import { IStream } from "../interfaces/core/IStream.sol";
import { IWorkFacts } from "../interfaces/core/IWorkFacts.sol";
import { IWorkRules } from "../interfaces/core/IWorkRules.sol";
import { FileRole, LocatorKind } from "../interfaces/types/ContentTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { License } from "../interfaces/types/PackageTypes.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { JsonEscape } from "../libraries/JsonEscape.sol";
import { SSTORE2 } from "../libraries/SSTORE2.sol";
import { Utf8 } from "../libraries/Utf8.sol";
import { DataUri } from "./DataUri.sol";
import { HtmlScript } from "./HtmlScript.sol";
import { JsonScan } from "./JsonScan.sol";

/// @title Renderer
/// @notice Builds the metadata of 6529 Stream works and the editions of 6529 Stream Editions
///         (ADR 0001 section 8 "`tokenURI` size"). Immutable and stateless: it only reads.
/// @dev `tokenURI(token, id)` reads the token it is asked about (a Stream token, or an editions
///      token, which it recognises by ERC-165 and follows to its master through
///      `IEditions.stream()`; an edition's ID is its master's token ID) only through plain
///      views: `IStream.workOf` and `collectionOf`, the work's permanent record in
///      `IWorkFacts.factsOf` (once), the shared content store, the preferred locators of the
///      token's RECORDS module's delivery contract, and optionally the statement log. A hostile
///      `token` can only change what its own call returns, so there is no list of tokens;
///      every read forwards all the gas it may (`BoundedCall.tryReadAll`, the gas rule of ADR
///      0007), with a return-size cap, and reverts if it fails (fail closed), except the
///      locator reads (below); a read that runs short reverts with `BoundedCallShortfall`, so a
///      caller retries with more gas. A finalized
///      work pins its renderer, possibly for good (its artist may renounce the repin), so no gas
///      figure is compiled here: a repricing can make `tokenURI` cost more, never fail.
///
///      The record. A work's descriptive record is a JSON file in the content store (stored as
///      `Identity`, at most `MAX_RECORD_BYTES`). The renderer reads it, checks it as UTF-8 and with
///      `JsonScan`, and copies the validated JSON text of `name`, `description`, `year`, `medium`,
///      `dimensions` and each of `artists` into the metadata (the `attributes` array goes in as it
///      is, after the renderer's own traits; other members are validated and ignored). Until the
///      work's record is open (`Facts.opened`) and its file is registered and complete, or
///      when it is not acceptable, the work gets core-only metadata from Stream with a
///      `record_status` field (`not_open`, `incomplete` or `invalid`) instead, and never a revert;
///      `fullTokenURI` reverts for such a work. A record is not acceptable if it is not `Identity`,
///      is over `MAX_RECORD_BYTES` (12 KiB), is not UTF-8 or JSON (no key with a backslash, no
///      `\u0000`, lone surrogate or bad hex digit in an escape, no number of more than 24 bytes or
///      with more than two exponent digits, at most `JsonScan.MAX_VALUES` units (values, keys and
///      escapes), eight levels), has no name or a wrong type, lists more than `MAX_ARTISTS` artists
///      or `MAX_ATTRIBUTES` attributes, holds more than `MAX_ESCAPES` `%` and `#`, gives a `year`
///      that is not an integer of at most six digits, or has an attribute that is not an object
///      whose members are only `trait_type`, `value`, `display_type` and `max_value`, each at most
///      once, with a string `trait_type` and a string or number `value`, or whose name is not
///      printable ASCII, has a backslash or is one the renderer writes itself in any case or
///      spacing. These bounds are chosen together, so that a record at every one of them at once
///      still costs under 8M gas, whatever its bytes (`RendererGas.t.sol`: a row for every class of
///      byte, and every cap at once; `TokenUriBudget.t.sol`: the budget proof on the real stack,
///      with the record's caps).
///
///      Output is `data:application/json;utf8,` followed by compact JSON, not base64, so the
///      media is not encoded twice. Every string from the Stream, a locator or the store is
///      checked as UTF-8 and escaped for JSON; the record, locators and strings alike are
///      percent-escaped for `%` and `#`, the only two bytes a non-base64 `data:` URI cannot
///      carry.
///
///      Media. The primary file is inlined when the work is on-chain complete, the file is
///      complete in the store with no chunk read from more than `MAX_PARTS_PER_CHUNK` stored
///      parts, its cost-weighted size is at most the threshold, and its stored
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
///      given by locator.
///
///      Locators. The renderer decides what it prints. It asks the token's RECORDS module for
///      its delivery contract (`IWorkRules.delivery`) and that contract for the file's
///      preferred locator (`ILocators.preferredLocator`), and prints the URI only if the answer
///      is the canonical encoding of a kind other than NONE and ONCHAIN with a URI of 1 to
///      `Limits.MAX_URI_BYTES` bytes, every byte printable ASCII other than space, `"` and `\`.
///      ONCHAIN carries no URI: an on-chain complete work is served from the content store, so
///      an ONCHAIN answer is never printed, for a work that `IWorkFacts` records as on-chain
///      complete or not. A missing module or delivery contract, a revert, or any other answer
///      is "no locator", so a broken delivery contract cannot break `tokenURI`; a read that
///      runs short of gas still reverts with `BoundedCallShortfall`.
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
    ///         file that is not (`Limits.MAX_PREVIEW_BYTES`: the 8M promise counts it; WorkFacts
    ///         holds no preview bound, so a larger preview is served by locator).
    uint256 internal constant PREVIEW_LIMIT = Limits.MAX_PREVIEW_BYTES;
    /// @notice The largest JavaScript primary, in stored bytes, that `tokenURI` wraps in the HTML
    ///         page (it has the 8M promise); `fullTokenURI` wraps a larger one, up to its size
    ///         limit.
    uint256 internal constant SCRIPT_LIMIT = 8_192;
    /// @notice The largest record file, in bytes: half a store chunk, so one chunk always holds
    ///         it.
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
    /// @notice The most stored parts any one chunk of a file may be read from: a linked chunk
    ///         costs one storage read and one code copy per part (about 8,000 gas), so a file
    ///         with a chunk over it is not inlined (a record with one is not shown) until that
    ///         chunk is written whole or linked from fewer parts, which anyone may do. A bound on
    ///         the work of a read, chosen with the others so that every cap at once stays within
    ///         the 8M budget (`TokenUriBudget.t.sol`), not a gas figure. Three parts of 8,192
    ///         bytes make a full 24,575-byte chunk, so a chunk can still be built from parts a
    ///         third of a chunk long.
    uint256 internal constant MAX_PARTS_PER_CHUNK = 3;

    /// @notice The content store the media and records are read from (immutable).
    IContentStore public immutable contentStore;
    /// @notice The statement log whose `latestDisputeOutcome` is shown, or zero for none.
    IStatementLog public immutable statementLog;
    /// @inheritdoc IRenderer
    uint256 public immutable inlineThreshold;

    /// @dev Return-size caps in bytes: a text, a locator, a `Work` (eleven words) and a `Facts`
    ///      (twelve head words, the license ID and the media list, with room to spare).
    uint256 private constant TEXT_RETURN = 4_096;
    uint256 private constant LOCATOR_RETURN = Limits.MAX_URI_BYTES + 256;
    uint256 private constant WORK_RETURN = 352;
    uint256 private constant FACTS_RETURN =
        448 + Limits.MAX_LICENSE_ID_BYTES + 64 * Limits.MAX_MEDIA_FILES;
    /// @dev The bytes a printed locator may hold, as a bit set over ASCII: printable ASCII but
    ///      space, `"` and `\`.
    uint256 private constant URI_BYTES = 0x7fffffffeffffffffffffffa00000000;

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

    /// @dev Everything one render reads, so helpers take one argument. `stream` is the token
    ///      that holds the work (the token itself, or an edition's master token); `collection`
    ///      is the collection's name, empty without one.
    struct Ctx {
        address token;
        uint256 id;
        bool edition;
        bool deps;
        address stream;
        uint256 workId;
        Work work;
        string collection;
        Facts facts;
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
    /// @param id The interface ID to test.
    /// @return True for the `IRenderer` and `IERC165` interface IDs.
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
        RecordState state = RecordState.NotOpen;
        bytes memory record = "";
        if (c.facts.opened) {
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

    /// @dev Finds the work behind `c.token`/`c.id` and loads it through plain views. An
    ///      ERC-1155 token is an editions token: the edition's ID is its master's token ID in
    ///      `IEditions.stream()`, which supplies the work. `workOf` (a work that was never minted
    ///      fails the read; a burned master keeps its record, so its editions still render),
    ///      the collection's name from `collectionOf` (a name that cannot be read within the text
    ///      cap, or is not UTF-8, is no name: the work still renders), and the permanent record
    ///      from `IWorkFacts.factsOf` on the token's `facts()`, in one read.
    function _load(Ctx memory c) private view {
        (bool ok, bytes memory ret) = BoundedCall.tryReadAll(
            c.token, abi.encodeCall(IERC165.supportsInterface, (type(IERC1155).interfaceId)), 32
        );
        c.stream = c.token;
        c.workId = c.id;
        if (ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1) {
            c.edition = true;
            c.stream =
                abi.decode(_read(c.token, abi.encodeCall(IEditions.stream, ()), 32), (address));
        }
        c.work = abi.decode(_word(c.stream, IStream.workOf.selector, c.workId, WORK_RETURN), (Work));
        if (c.work.itemHash == 0) revert RendererReadFailed(c.stream, IStream.workOf.selector);
        if (c.work.collectionId != 0) {
            (ok, ret) = BoundedCall.tryReadAll(
                c.stream,
                abi.encodeWithSelector(IStream.collectionOf.selector, c.work.collectionId),
                TEXT_RETURN + 192
            );
            if (ok) {
                string memory name = abi.decode(ret, (Collection)).name;
                if (Utf8.isValid(bytes(name))) c.collection = name;
            }
        }
        address facts =
            abi.decode(_read(c.stream, abi.encodeCall(IStream.facts, ()), 32), (address));
        c.facts = abi.decode(
            _read(facts, abi.encodeCall(IWorkFacts.factsOf, (c.stream, c.workId)), FACTS_RETURN),
            (Facts)
        );
    }

    /// @dev Checks the media of a work whose record is open (a primary file first) and loads
    ///      the primary file's store entry.
    function _loadRecord(Ctx memory c) private view {
        if (c.facts.media.length == 0 || c.facts.media[0].role != uint8(FileRole.PRIMARY)) {
            revert RendererRecordInvalid(c.token, c.id);
        }
        c.primary = _fileInfo(c.facts.media[0].fileId);
    }

    /// @dev The record JSON, percent-escaped, and whether it is ready: not if its file is not
    ///      complete yet (or has a chunk linked from more than `MAX_PARTS_PER_CHUNK`
    ///      parts), and never if it is not `Identity`, is over `MAX_RECORD_BYTES`, is not
    ///      UTF-8, or holds too many `%` and `#` to escape within the gas budget. A record file
    ///      the store does not answer for (an approved one whose manifest was never registered) is
    ///      not complete either: the store answered for the primary file in this same call, so the
    ///      failure is the unknown file, not a broken store.
    function _record(Ctx memory c) private view returns (RecordState, bytes memory j) {
        bytes32 id = c.facts.recordFileId;
        (bool known, bytes memory info) = BoundedCall.tryReadAll(
            address(contentStore), abi.encodeWithSelector(IContentStore.fileInfo.selector, id), 512
        );
        if (!known) return (RecordState.Incomplete, j);
        IContentStore.FileInfo memory fi = abi.decode(info, (IContentStore.FileInfo));
        if (fi.encoding != uint8(IContentStore.Encoding.Identity) || fi.length > MAX_RECORD_BYTES) {
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
    ///      The preview is read only when it is used, so an inlined image primary never asks
    ///      the delivery contract for anything.
    function _media(Ctx memory c) private view returns (Media[3] memory m) {
        Media memory p = _primary(c);
        if (p.mode == Mode.Locator) m[2] = p;
        bool image = _isImage(c.primary.mimeType);
        if (image && p.mode >= Mode.Data) {
            m[0] = p;
            return m;
        }
        Media memory v = _preview(c);
        if (image) m[0] = v.mode == Mode.None ? p : v;
        else (m[0], m[1]) = (v, p);
    }

    function _primary(Ctx memory c) private view returns (Media memory m) {
        bytes32 id = c.facts.media[0].fileId;
        if (c.facts.onChainComplete && _weight(c.primary) <= c.limit && _complete(id)) {
            m = _inline(c, id, c.primary, true);
            if (m.mode != Mode.None) return m;
        }
        if (c.strict) revert RendererNotInlineable(c.token, c.id);
        return _locator(c, id);
    }

    /// @dev The first PREVIEW image of the work: inline if small and complete, else by locator.
    function _preview(Ctx memory c) private view returns (Media memory m) {
        for (uint256 i = 1; i < c.facts.media.length; ++i) {
            if (c.facts.media[i].role != uint8(FileRole.PREVIEW)) continue;
            bytes32 id = c.facts.media[i].fileId;
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
        uint8 enc = fi.encoding;
        if (primary && _isScript(fi.mimeType)) {
            // `fullTokenURI` (strict) has no 8M promise: its limit is the size check before.
            return enc == uint8(IContentStore.Encoding.Identity)
                && (fi.length <= SCRIPT_LIMIT || c.strict) && !c.deps
                ? _shell(c, id, fi.length)
                : m;
        }
        if (enc == uint8(IContentStore.Encoding.Base64)) {
            // Concatenated as stored, so only text the store has checked as strict base64.
            if (!_attested(id)) return m;
            m.mode = Mode.Copy;
        } else if (enc == uint8(IContentStore.Encoding.Identity)) {
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
        bytes32 seed = c.work.seed;
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

    /// @dev The preferred locator of a file: its URL, or none. The delivery contract is the
    ///      token's RECORDS module's (`IWorkRules.delivery`), asked by token, work and file
    ///      (`ILocators.preferredLocator`). A missing module or contract, a refusal or an answer
    ///      that `_servable` rejects is no locator; running short of gas reverts.
    function _locator(Ctx memory c, bytes32 id) private view returns (Media memory m) {
        (bool ok, bytes memory ret) = BoundedCall.tryReadAll(
            c.stream, abi.encodeCall(IModuleSlots.moduleOf, (Slots.RECORDS)), 32
        );
        address target = _address(ok, ret);
        (ok, ret) = BoundedCall.tryReadAll(target, abi.encodeCall(IWorkRules.delivery, ()), 32);
        target = _address(ok, ret);
        (ok, ret) = BoundedCall.tryReadAll(
            target,
            abi.encodeCall(ILocators.preferredLocator, (c.stream, c.workId, id)),
            LOCATOR_RETURN
        );
        if (ok && _servable(ret)) {
            (ILocators.Location memory l,) = abi.decode(ret, (ILocators.Location, uint256));
            return Media(Mode.Locator, 0, 0, _str(l.uri));
        }
    }

    /// @dev A one-word answer that is an address (zero for anything else, which reads nothing).
    function _address(bool ok, bytes memory ret) private pure returns (address a) {
        if (ok && ret.length == 32 && uint256(bytes32(ret)) >> 160 == 0) {
            a = address(uint160(uint256(bytes32(ret))));
        }
    }

    /// @dev Whether `d` is the canonical encoding of `(Location, uint256)` with a URI the
    ///      renderer prints: any kind up to 255 but NONE and ONCHAIN (so a kind a later delivery
    ///      contract adds still reaches works that pinned this renderer), a URI of 1 to
    ///      `Limits.MAX_URI_BYTES` bytes, each in `URI_BYTES`. The padding is not checked: the URI
    ///      is taken by its length.
    function _servable(bytes memory d) private pure returns (bool ok) {
        if (d.length < 0xc0) return false;
        uint256 head;
        uint256 kind;
        uint256 inner;
        uint256 n;
        assembly ("memory-safe") {
            head := mload(add(d, 0x20))
            kind := mload(add(d, 0x60))
            inner := mload(add(d, 0x80))
            n := mload(add(d, 0xa0))
        }
        ok = head == 0x40 && inner == 0x40 && kind <= type(uint8).max
            && kind != uint8(LocatorKind.NONE) && kind != uint8(LocatorKind.ONCHAIN) && n != 0
            && n <= Limits.MAX_URI_BYTES && d.length == 0xa0 + ((n + 31) & ~uint256(31));
        for (uint256 i; ok && i < n; ++i) {
            ok = (URI_BYTES >> uint8(d[0xa0 + i])) & 1 == 1;
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
            bytes memory chunk = abi.decode(
                _read(
                    address(contentStore),
                    abi.encodeCall(IContentStore.readChunk, (id, i)),
                    SSTORE2.MAX_CHUNK_LENGTH + 96
                ),
                (bytes)
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
        if (c.work.collectionId != 0) {
            name = abi.encodePacked(_str(c.collection), " %23", Strings.toString(c.work.serial));
        }
        t[0] = _trait("Artist ID", _quote(Strings.toHexString(uint256(c.work.artistId))));
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
        if (c.work.collectionId != 0) {
            t[n++] = _trait("Collection", _quote(c.collection));
            t[n++] = _trait("Serial", bytes(Strings.toString(c.work.serial)));
        }
        if (c.edition) t[n++] = _trait("Edition of", bytes(Strings.toString(c.workId)));
        bytes32 seed = c.work.seed;
        if (seed != 0) t[n++] = _trait("Seed", _quote(Strings.toHexString(uint256(seed), 32)));
        if (address(statementLog) != address(0)) {
            bytes32 entry = abi.decode(
                _read(
                    address(statementLog),
                    abi.encodeCall(IStatementLog.latestDisputeOutcome, (c.stream, c.workId)),
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
        License memory lic = License(c.facts.licenseId, c.facts.licenseTextFileId);
        // The store's declared SHA-256 of the primary file: `IWorkFacts.open` admitted the file
        // only with the digest the item committed to.
        bytes memory out = abi.encodePacked(
            ',"content_type":',
            _quote(c.primary.mimeType),
            ',"content_hash":"',
            Strings.toHexString(uint256(c.primary.sha256Hash), 32),
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
        for (uint256 i; lic.textFileId != 0 && i < c.facts.media.length; ++i) {
            if (c.facts.media[i].fileId == lic.textFileId) return _locator(c, lic.textFileId).text;
        }
        return "";
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

    function _read(address target, bytes memory input, uint256 maxReturn)
        private
        view
        returns (bytes memory ret)
    {
        bool ok;
        (ok, ret) = BoundedCall.tryReadAll(target, input, maxReturn);
        // `input` is always an encoded call, so it holds a selector. An empty answer (an account
        // without code) is a failed read too.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (!ok || ret.length == 0) revert RendererReadFailed(target, bytes4(input));
    }

    /// @dev A read whose only argument is one word: `selector(arg)`.
    function _word(address target, bytes4 selector, uint256 arg, uint256 maxReturn)
        private
        view
        returns (bytes memory)
    {
        return _read(target, abi.encodeWithSelector(selector, arg), maxReturn);
    }

    function _fileInfo(bytes32 id) private view returns (IContentStore.FileInfo memory) {
        return abi.decode(
            _word(address(contentStore), IContentStore.fileInfo.selector, uint256(id), 512),
            (IContentStore.FileInfo)
        );
    }

    /// @dev Whether a file is complete in the store with no chunk read from more than
    ///      `MAX_PARTS_PER_CHUNK` stored parts (`IContentStore.maxParts`, zero when incomplete).
    function _complete(bytes32 id) private view returns (bool) {
        uint256 parts = abi.decode(
            _word(address(contentStore), IContentStore.maxParts.selector, uint256(id), 32),
            (uint256)
        );
        // From 1 to the bound: zero (incomplete) wraps to the largest word.
        unchecked {
            return parts - 1 < MAX_PARTS_PER_CHUNK;
        }
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
            _word(address(contentStore), IContentStore.isBase64Attested.selector, uint256(id), 32),
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
        return fi.encoding == uint8(IContentStore.Encoding.Identity) ? 8 * fi.length : fi.length;
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
