// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { FileRole, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { EditionTerms, ItemKind, License, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { StateGrowth } from "../helpers/StateGrowth.sol";
import { GasBase } from "./GasBase.sol";

/// @notice The `tokenURI` budget proof on the deployed stack (ADR 0004: at most 8M Prague gas):
///         every cap the protocol allows at once, measured cold through `Stream6529.tokenURI` (and
///         `StreamEditions6529.uri`) with the real WorkFacts, content store, statement log,
///         accounts module, delivery module and renderer.
///         - **The record**: the dearest rows of the renderer's record matrix: 32 attributes at
///           the member cap with white space before each or after every token in all the room
///           there is, 512 `%`, the rest of the 1,024 units as top-level members or an array of
///           zeros, or the costliest UTF-8 fill. Each attribute's name is 33 characters, the
///           longest the renderer compares letter by letter with its own names (`TRAIT`).
///         - **The media**: 256 KiB of attested `Base64` `text/html` as the primary (inlined),
///           a PREVIEW image at the renderer's bound (`Limits.MAX_PREVIEW_BYTES`), stored as
///           `Identity` or as attested `Base64` (inlined), and 32 media files in all
///           (`Limits.MAX_MEDIA_FILES`).
///         - **The rest**: a 64-byte `LicenseRef` license whose text is a media file served by
///           locator, 16 locators on it (the platform's 8 and the artist's 8, of the longest
///           kind, the served one last, so the scan runs to the end), a dear collection name,
///           an ARTIST seed and a dispute statement.
///         Each row builds its own work, so each test measures one.
/// @dev Stream does not check a collection's name (the PLATFORM role chooses it); the renderer
///      shows a name of at most `Renderer.MAX_NAME_BYTES` (128) bytes of valid UTF-8 and reads
///      no longer one. The rows use the dearest name it shows (`_dearestName`). The name rows
///      measure the longest shown name, of bytes JSON escaping lengthens, and names far over
///      the bound (`test_Budget_LongestShownName_*`, `test_Budget_NameOverTheBound_*`).
contract TokenUriBudgetTest is GasBase {
    uint256 internal constant MAX_ATTRIBUTES = 32;
    uint256 internal constant MAX_ESCAPES = 512;
    uint256 internal constant MAX_VALUES = 1_024;
    /// @dev The dearest trait name: 33 characters is the longest name the renderer lowers and
    ///      compares with its own.
    bytes internal constant TRAIT = "abcdefghijklmnopqrstuvwxyzabcdefg";
    bytes internal constant ATTR = '{"trait_type":"abcdefghijklmnopqrstuvwxyzabcdefg","value":1,'
        '"display_type":"number","max_value":9}';
    uint256 internal constant ATTR_UNITS = 9;
    /// @dev The largest PREVIEW image of each encoding the renderer inlines (its preview bound is
    ///      `Limits.MAX_PREVIEW_BYTES` of weight, an `Identity` byte weighing eight).
    uint256 internal constant PREVIEW_IDENTITY = Limits.MAX_PREVIEW_BYTES / 8;
    uint256 internal constant PREVIEW_BASE64 = Limits.MAX_PREVIEW_BYTES;
    /// @dev The longest collection name the renderer shows (`Renderer.MAX_NAME_BYTES`).
    uint256 internal constant LONGEST_SHOWN_NAME = 128;

    /// @dev A work's metadata measured at or over the 8M budget (an open finding).
    error OverTokenUriBudget(uint256 used);

    // Where the attributes' white space goes, and what the leftover units are.
    uint256 internal constant NO_SPACE = 0;
    uint256 internal constant BEFORE = 1;
    uint256 internal constant INSIDE = 2;
    uint256 internal constant MEMBERS = 0;
    uint256 internal constant ZEROS = 1;

    address internal artist;
    address internal reader = makeAddr("budgetReader");
    uint256 internal salt;
    /// @dev When above 1, every chunk uploaded is stored as a link of this many parts, never
    ///      whole (`_writeChunks`).
    uint256 internal linkParts;
    /// @dev The collection name the next `_build` uses (`_dearestName` when empty).
    bytes internal nextName;
    /// @dev The token `_namedRow` built last.
    uint256 internal lastTokenId;

    function setUp() public override {
        super.setUp();
        artist = _actor("budgetArtist");
    }

    // ------------------------------------------------------------------ the record

    function _fill(bytes memory unit, uint256 n) internal pure returns (bytes memory j) {
        j = new bytes(n);
        for (uint256 i; i < n; ++i) {
            j[i] = unit[i % unit.length];
        }
    }

    function _rep(bytes memory unit, uint256 n) internal pure returns (bytes memory) {
        return _fill(unit, unit.length * n);
    }

    function _list(bytes memory item, uint256 n) internal pure returns (bytes memory all) {
        all = new bytes(n * (item.length + 1) - 1);
        uint256 p;
        for (uint256 k; k < n; ++k) {
            if (k != 0) all[p++] = ",";
            for (uint256 i; i < item.length; ++i) {
                all[p++] = item[i];
            }
        }
    }

    /// @dev `name`, a description of `MAX_ESCAPES` `%` and then `fill` up to 12 KiB, the
    ///      attributes, and the rest of the units as `shape`.
    function _json(bytes memory fill, uint256 shape, bytes memory attributes, uint256 units)
        internal
        pure
        returns (bytes memory)
    {
        uint256 rest = MAX_VALUES - 3 - 3 - 3 - units;
        bytes memory tail = shape == MEMBERS
            ? _rep(',"a":0', rest / 3)
            : bytes.concat(',"a":[0', _rep(",0", rest - 3 - 1), "]");
        tail = bytes.concat('","attributes":[', attributes, "]", tail, "}");
        bytes memory open = bytes.concat('{"name":"N","description":"', _fill("%", MAX_ESCAPES));
        if (fill.length == 0) return bytes.concat(open, tail);
        uint256 room = Limits.MAX_RECORD_BYTES - open.length - tail.length;
        return bytes.concat(open, _fill(fill, room / fill.length * fill.length), tail);
    }

    function _spacedBefore(uint256 n, uint256 sp) internal pure returns (bytes memory) {
        return _list(bytes.concat(_fill(" ", sp), ATTR), n);
    }

    function _spacedInside(uint256 n, uint256 sp) internal pure returns (bytes memory) {
        bytes memory s = _fill(" ", sp);
        bytes[17] memory tokens = [
            bytes("{"),
            '"trait_type"',
            ":",
            bytes.concat('"', TRAIT, '"'),
            ",",
            '"value"',
            ":",
            "1",
            ",",
            '"display_type"',
            ":",
            '"number"',
            ",",
            '"max_value"',
            ":",
            "9",
            "}"
        ];
        bytes memory one;
        for (uint256 i; i < tokens.length; ++i) {
            one = bytes.concat(one, tokens[i], s);
        }
        return _list(one, n);
    }

    /// @dev A record at every cap: white space in the attributes (`where`, all the room the plain
    ///      record leaves), the leftover units as `shape`, and the dearest fill (`aa` and a 2-byte
    ///      sequence, alternating) in what is left.
    function _worstRecord(uint256 where, uint256 shape) internal pure returns (bytes memory) {
        uint256 n = MAX_ATTRIBUTES;
        bytes memory plain = _list(ATTR, n);
        if (where == NO_SPACE) return _json(hex"6161c3a9", shape, plain, ATTR_UNITS * n);
        uint256 free = Limits.MAX_RECORD_BYTES - _json("", shape, plain, ATTR_UNITS * n).length - 8;
        bytes memory attributes =
            where == BEFORE ? _spacedBefore(n, free / n) : _spacedInside(n, free / (17 * n));
        return _json(hex"6161c3a9", shape, attributes, ATTR_UNITS * n);
    }

    // ------------------------------------------------------------------ linked chunks

    /// @dev Stores each chunk whole, or, with `linkParts` above 1, as a link of `linkParts`
    ///      parts (fewer only for a chunk shorter than that many bytes).
    function _writeChunks(bytes memory stored) internal override returns (bytes32[] memory hashes) {
        if (linkParts < 2) return super._writeChunks(stored);
        uint256 size = store.CHUNK_SIZE();
        hashes = new bytes32[]((stored.length + size - 1) / size);
        for (uint256 i; i < hashes.length; ++i) {
            bytes memory chunk = _slice(stored, i * size, size);
            hashes[i] = keccak256(chunk);
            if (store.chunkPointer(hashes[i]) != address(0)) continue;
            uint256 step = (chunk.length + linkParts - 1) / linkParts;
            bytes32[] memory parts = new bytes32[]((chunk.length + step - 1) / step);
            for (uint256 j; j < parts.length; ++j) {
                (parts[j],) = store.writeChunk(_slice(chunk, j * step, step));
            }
            if (parts.length > 1) assertEq(store.linkChunk(parts), hashes[i], "linked");
        }
    }

    // ------------------------------------------------------------------ the work

    /// @dev The dearest collection name the renderer shows: U+2028 three bytes at a time,
    ///      escaped to six (a JSON `u2028` escape), and `#x` to fill the 128 bytes.
    function _dearestName() internal pure returns (string memory) {
        return string(bytes.concat(_fill(hex"e280a8", LONGEST_SHOWN_NAME - 2), "#x"));
    }

    struct Built {
        uint256 tokenId;
        bytes32 licenseText;
        MediaFile[] media;
    }

    /// @dev A PREVIEW image at the bound: `Identity` of `MAX_PREVIEW_BYTES / 8` bytes, or attested
    ///      `Base64` text of `MAX_PREVIEW_BYTES` bytes.
    function _preview(bool base64) internal returns (bytes32 id, bytes32 sha) {
        bytes memory png = _bytes(base64 ? PREVIEW_BASE64 / 4 * 3 : PREVIEW_IDENTITY, 1000 + salt);
        sha = sha256(png);
        if (!base64) return (_upload(png, IContentStore.Encoding.Identity, "image/png", sha), sha);
        id = _upload(bytes(Base64.encode(png)), IContentStore.Encoding.Base64, "image/png", sha);
        _attestAll(id);
    }

    /// @dev The media: the primary, the preview, the license text and auxiliary files, 32 in all.
    function _mediaFiles(bool base64Preview) internal returns (Built memory b, bytes32 content) {
        bytes memory html = _bytes(262_144 / 4 * 3, salt);
        content = sha256(html);
        bytes memory text = bytes(Base64.encode(html));
        b.media = new MediaFile[](Limits.MAX_MEDIA_FILES);
        b.media[0] = MediaFile(
            _upload(text, IContentStore.Encoding.Base64, "text/html", content),
            content,
            uint8(FileRole.PRIMARY)
        );
        _attestAll(b.media[0].fileId);
        (bytes32 preview, bytes32 previewSha) = _preview(base64Preview);
        b.media[1] = MediaFile(preview, previewSha, uint8(FileRole.PREVIEW));
        bytes memory licenseTerms =
            abi.encodePacked("The terms of the license, #", vm.toString(salt));
        b.licenseText = _storeText(licenseTerms, "text/plain");
        b.media[2] = MediaFile(b.licenseText, sha256(licenseTerms), uint8(FileRole.AUXILIARY));
        for (uint256 i = 3; i < b.media.length; ++i) {
            bytes memory aux =
                abi.encodePacked("auxiliary ", vm.toString(salt), "/", vm.toString(i));
            b.media[i] =
                MediaFile(_storeText(aux, "text/plain"), sha256(aux), uint8(FileRole.AUXILIARY));
        }
    }

    /// @dev The worst work: see the contract's notice. An edition master if `master`.
    function _build(bytes memory json, bool base64Preview, bool master)
        internal
        returns (Built memory b)
    {
        ++salt;
        string memory name = nextName.length == 0 ? _dearestName() : string(nextName);
        vm.prank(platform);
        uint256 coll = stream.createCollection(name, keccak256(abi.encode(salt)));
        bytes32 content;
        (b, content) = _mediaFiles(base64Preview);
        Work memory w;
        w.media = b.media;
        w.item = _item(artist, coll, content, b.media, _storeText(json, "application/json"));
        w.item.license =
            License(string.concat("LicenseRef-", string(_fill("x", 53))), b.licenseText);
        w.item.seedPolicy = uint8(SeedPolicy.ARTIST);
        w.item.seed = keccak256(abi.encode("seed", salt));
        if (master) {
            w.item.kind = uint8(ItemKind.EDITION_MASTER);
            w.item.edition = EditionTerms(20, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        }
        b.tokenId = _mintAndOpen(w, master);
        _addLocators(b);
        _platformStatement(address(stream), b.tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://d");
    }

    /// @dev Starts the work (a master's edition opened while its 1/1 is live), opens its record
    ///      and marks it on-chain complete.
    function _mintAndOpen(Work memory w, bool master) internal returns (uint256 tokenId) {
        Work[] memory works = _one(w);
        bytes32 r = _publish(works);
        (, tokenId) = _start(r, works, 0);
        if (master) {
            editionAuction.open(
                address(editions), tokenId, abi.encode(w.item, r, _proofOf(works, 0))
            );
        }
        _open(tokenId, w);
        facts.markOnChainComplete(address(stream), tokenId);
    }

    /// @dev 16 locators on the license text, of the longest kind (IPFS, 66 bytes) last and
    ///      ARWEAVE before it, and the token's preference on IPFS: the scan runs to the end. The
    ///      platform's 8 come first and the artist's 8 last, so the served IPFS copy is the
    ///      artist's at index 15.
    function _addLocators(Built memory b) internal {
        for (uint256 i; i < 16; ++i) {
            string memory seed = string.concat(vm.toString(salt), "/", vm.toString(i));
            bytes memory call = abi.encodeCall(
                delivery.addLocator,
                (
                    address(stream),
                    b.tokenId,
                    b.licenseText,
                    i == 15 ? CA.ipfsLocator(seed) : CA.ar(seed)
                )
            );
            if (i < 8) {
                _govern(platform, address(delivery), call);
            } else {
                vm.prank(artist);
                (bool ok, bytes memory reason) = address(delivery).call(call);
                _bubble(ok, reason);
            }
        }
        _govern(
            storageOperator,
            address(delivery),
            abi.encodeCall(delivery.setPreferredKind, (address(stream), LocatorKind.IPFS))
        );
    }

    // ------------------------------------------------------------------ measuring

    /// @dev Cold Prague gas of a metadata view, as the integration report measures it.
    function _cold(address token, bytes memory call) internal returns (uint256 used) {
        (bool ok,) = token.call(call); // warm every account, so the surcharge applies to all
        assertTrue(ok, "metadata view");
        (, used) = _measure(reader, token, call, 0);
        StateGrowth.Growth memory growth = _growth(reader, token, call, 0);
        assertEq(growth.slots + growth.accounts, 0, "a view creates no state");
        used += COLD_ACCOUNT_SURCHARGE * growth.coldAccounts.length;
    }

    function _row(string memory label, bytes memory json, bool base64Preview)
        internal
        returns (uint256 used)
    {
        Built memory b = _build(json, base64Preview, false);
        string memory uri = stream.tokenURI(b.tokenId);
        assertFalse(_contains(uri, "record_status"), "the record is accepted");
        assertTrue(_contains(uri, '"animation_url":"data:text/html;base64,'), "primary inline");
        assertTrue(_contains(uri, '"image":"data:image/png;base64,'), "preview inline");
        assertTrue(
            _contains(uri, string.concat('"license_url":"', CA.ipfs(_last(salt)), '"')),
            "the last locator is served"
        );
        used = _cold(address(stream), abi.encodeCall(stream.tokenURI, (b.tokenId)));
        console2.log(label, used);
        assertLt(used, TOKEN_URI_BUDGET, label);
    }

    function _last(uint256 s) internal pure returns (string memory) {
        return string.concat(vm.toString(s), "/15");
    }

    // ------------------------------------------------------------------ the rows

    function test_Budget_SpacedBefore_Zeros() public {
        _row("white space before each attribute, zeros:", _worstRecord(BEFORE, ZEROS), false);
    }

    function test_Budget_SpacedBefore_Members() public {
        _row("white space before each attribute, members:", _worstRecord(BEFORE, MEMBERS), false);
    }

    function test_Budget_SpacedInside_Zeros() public {
        _row("white space after every token, zeros:", _worstRecord(INSIDE, ZEROS), false);
    }

    function test_Budget_SpacedInside_Members() public {
        _row("white space after every token, members:", _worstRecord(INSIDE, MEMBERS), false);
    }

    function test_Budget_DearestFill_Zeros() public {
        _row("aa and a 2-byte sequence, zeros:", _worstRecord(NO_SPACE, ZEROS), false);
    }

    /// @dev The preview at the cap as attested `Base64`: four times the bytes of the `Identity`
    ///      one, the same weight.
    function test_Budget_SpacedBefore_Zeros_Base64Preview() public {
        _row(
            "white space before each attribute, zeros, Base64 preview:",
            _worstRecord(BEFORE, ZEROS),
            true
        );
    }

    /// @dev The dearest row with every chunk the renderer reads linked from
    ///      `MAX_PARTS_PER_CHUNK` (3) parts, the most it reads from: each part costs one more
    ///      storage read and code copy, and the row still fits 8M.
    function test_Budget_LinkedAtTheBound_SpacedBefore_Zeros_Base64Preview() public {
        linkParts = 3;
        _row(
            "every chunk linked from 3 parts, white space before each attribute, zeros, Base64 preview:",
            _worstRecord(BEFORE, ZEROS),
            true
        );
    }

    /// @dev One part more than the bound in every chunk: the renderer neither reads the record
    ///      nor inlines a file, so the work renders its core facts.
    function test_Budget_PastTheBoundNothingIsRead() public {
        linkParts = 4;
        Built memory b = _build(_worstRecord(BEFORE, ZEROS), true, false);
        string memory uri = stream.tokenURI(b.tokenId);
        assertTrue(_contains(uri, '"record_status":"incomplete"'), "record not read");
        assertFalse(_contains(uri, ";base64,"), "nothing inlined");
        uint256 used = _cold(address(stream), abi.encodeCall(stream.tokenURI, (b.tokenId)));
        assertLt(used, TOKEN_URI_BUDGET);
    }

    /// @dev An edition renders its master: `StreamEditions6529.uri` adds the master link and one
    ///      trait.
    function test_Budget_Edition_SpacedBefore_Zeros() public {
        Built memory b = _build(_worstRecord(BEFORE, ZEROS), false, true);
        string memory uri = editions.uri(b.tokenId);
        assertFalse(_contains(uri, "record_status"), "the record is accepted");
        assertTrue(_contains(uri, '"trait_type":"Edition of"'));
        uint256 used = _cold(address(editions), abi.encodeCall(editions.uri, (b.tokenId)));
        console2.log("edition, white space before each attribute, zeros:", used);
        assertLt(used, TOKEN_URI_BUDGET);
    }

    // ------------------------------------------------------------------ the collection name

    /// @dev A work at every cap whose collection is named `name`: its cold `tokenURI` gas.
    function _namedRow(bytes memory name) internal returns (uint256) {
        nextName = name;
        Built memory b = _build(_worstRecord(BEFORE, ZEROS), false, false);
        lastTokenId = b.tokenId;
        assertFalse(_contains(stream.tokenURI(b.tokenId), "record_status"), "record accepted");
        return _cold(address(stream), abi.encodeCall(stream.tokenURI, (b.tokenId)));
    }

    /// @dev Whatever name the PLATFORM role gives a collection, a work in it renders within 8M.
    function _checkNamedWithinBudget(bytes memory name) internal {
        uint256 used = _namedRow(name);
        console2.log("tokenURI with a long collection name:", used);
        if (used >= TOKEN_URI_BUDGET) revert OverTokenUriBudget(used);
    }

    /// @dev The longest names the renderer shows, of the bytes JSON escaping lengthens most
    ///      (a control byte becomes six, a quote two, U+2028 six for three): each is shown, in
    ///      the work's name and in its Collection trait, inside the budget.
    function test_Budget_LongestShownName_ControlBytes() public {
        bytes memory name = _fill(hex"01", LONGEST_SHOWN_NAME);
        _checkNamedWithinBudget(name);
        assertTrue(_contains(stream.tokenURI(lastTokenId), "\\u0001\\u0001"), "name shown");
    }

    function test_Budget_LongestShownName_Quotes() public {
        _checkNamedWithinBudget(_fill('"', LONGEST_SHOWN_NAME));
        assertTrue(_contains(stream.tokenURI(lastTokenId), '\\"\\"\\"'), "name shown");
    }

    function test_Budget_LongestShownName_LineSeparators() public {
        _checkNamedWithinBudget(bytes(_dearestName()));
        assertTrue(_contains(stream.tokenURI(lastTokenId), "\\u2028\\u2028"), "name shown");
    }

    /// @dev A name over the bound is refused by its length alone, so what it holds costs
    ///      nothing: the work renders without a collection name, inside the budget. (Before the
    ///      bound, 4,096 control bytes took this work to 15.7M gas.)
    function _checkOverTheBound(bytes memory name) internal {
        uint256 used = _namedRow(name);
        console2.log("tokenURI with a collection name over the bound:", used);
        string memory uri = stream.tokenURI(lastTokenId);
        assertFalse(_contains(uri, "\\u0001\\u0001"), "the name is not shown");
        assertFalse(_contains(uri, '\\"\\"\\"'), "the name is not shown");
        assertLt(used, TOKEN_URI_BUDGET);
    }

    function test_Budget_NameOverTheBound_ControlBytes() public {
        _checkOverTheBound(_fill(hex"01", 4_096));
    }

    function test_Budget_NameOverTheBound_Quotes() public {
        _checkOverTheBound(_fill('"', 4_096));
    }

    function test_Budget_NameOverTheBound_NotUtf8() public {
        _checkOverTheBound(_fill(hex"ff", 4_096));
    }

    function test_Budget_NameOverTheBound_ByOneByte() public {
        _checkOverTheBound(_fill(hex"01", LONGEST_SHOWN_NAME + 1));
    }

    /// @dev A name longer than the renderer reads is no name: the work still renders, with its
    ///      record, inside the budget.
    function test_CollectionName_LongerThanTheRendererReadsIsNoName() public {
        nextName = _fill("n", LONGEST_SHOWN_NAME + 1);
        Built memory b = _build(_worstRecord(BEFORE, ZEROS), false, false);
        string memory uri = stream.tokenURI(b.tokenId);
        assertFalse(_contains(uri, "nnnn"), "the name is not shown");
        assertFalse(_contains(uri, "record_status"), "the record is accepted");
        uint256 used = _cold(address(stream), abi.encodeCall(stream.tokenURI, (b.tokenId)));
        assertLt(used, TOKEN_URI_BUDGET);
    }

    // ------------------------------------------------------------------ the preview

    /// @dev `StreamWorkFacts6529.open` holds no renderer budget: a PREVIEW of any size and encoding
    ///      opens, and the renderer decides what it inlines (its preview bound keeps `tokenURI`
    ///      within 8M).
    function test_PreviewCap_OpenAcceptsAnyPreview() public {
        uint256 cap = Limits.MAX_PREVIEW_BYTES;
        _expectPreview(_bytes(cap / 4 + 1, 1), IContentStore.Encoding.Identity);
        _expectPreview(_bytes(cap + 4, 2), IContentStore.Encoding.Base64);
        _expectPreview(_bytes(4 * cap, 3), IContentStore.Encoding.Gzip);
        _expectPreview(_bytes(4 * cap, 6), IContentStore.Encoding.GzipBase64);
        _expectPreview(_bytes(cap / 4, 4), IContentStore.Encoding.Identity);
        _expectPreview(_bytes(cap, 5), IContentStore.Encoding.Base64);
    }

    function _expectPreview(bytes memory stored, IContentStore.Encoding encoding) internal {
        Work memory w = _work(artist, collectionId);
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = w.media[0];
        bytes32 sha = sha256(stored);
        media[1] = MediaFile(
            _registerOnly(stored, encoding, "image/png", sha), sha, uint8(FileRole.PREVIEW)
        );
        w.media = media;
        w.item = _item(artist, collectionId, media[0].sha256Hash, media, w.item.recordFileId);
        Work[] memory works = _one(w);
        (, uint256 tokenId) = _start(_publish(works), works, 0);
        _open(tokenId, w);
        assertTrue(facts.factsOf(address(stream), tokenId).opened, "opened");
    }
}
