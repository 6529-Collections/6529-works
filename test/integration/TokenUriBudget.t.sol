// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { EditionTerms, ItemKind, License, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { StateGrowth } from "../helpers/StateGrowth.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice The `tokenURI` budget proof on the real stack (ADR 0004: at most 8M Prague gas): every
///         cap the protocol allows at once, measured cold through `Stream.tokenURI` (and
///         `Editions.uri`) with the real WorkRecords, content store, statement log and renderer.
///         - **The record**: the dearest rows of the renderer's record matrix
///           (`RendererGasBudgetTest`): 32 attributes at the member cap with white space before
///           each or after every token in all the room there is, 512 `%`, the rest of the 1,024
///           units as top-level members or an array of zeros, or the costliest UTF-8 fill. Each
///           attribute's name is 33 characters, the longest the renderer compares letter by
///           letter with its own names (`TRAIT`).
///         - **The media**: 256 KiB of attested `Base64` `text/html` as the primary (inlined),
///           a PREVIEW image at the WorkRecords cap (`Limits.MAX_PREVIEW_BYTES`), stored as
///           `Identity` or as attested `Base64` (inlined), and 32 media files in all
///           (`Limits.MAX_MEDIA_FILES`).
///         - **The rest**: a 64-byte `LicenseRef` license whose text is a media file served by
///           locator, 16 locators on it (the artist's 8 and the platform's 8, of the longest
///           kind, the served one last, so the scan runs to the end), the dearest collection
///           name `createCollection` accepts (`_dearestName`), an ARTIST seed and a dispute
///           statement. (A VRF seed instead adds one bounded read of the entropy module, a few
///           thousand gas.)
///         Each row builds its own work, so each test measures one.
contract TokenUriBudgetTest is IntegrationBase {
    uint256 internal constant MAX_ATTRIBUTES = 32;
    uint256 internal constant MAX_ESCAPES = 512;
    uint256 internal constant MAX_VALUES = 1_024;
    /// @dev The dearest trait name: 33 characters is the longest name the renderer lowers and
    ///      compares with its own (a longer one cannot be one of them without two spaces in a row).
    bytes internal constant TRAIT = "abcdefghijklmnopqrstuvwxyzabcdefg";
    bytes internal constant ATTR = '{"trait_type":"abcdefghijklmnopqrstuvwxyzabcdefg","value":1,'
        '"display_type":"number","max_value":9}';
    uint256 internal constant ATTR_UNITS = 9;
    /// @dev The largest PREVIEW image of each encoding `openRecord` accepts.
    uint256 internal constant PREVIEW_IDENTITY = Limits.MAX_PREVIEW_BYTES / 4;
    uint256 internal constant PREVIEW_BASE64 = Limits.MAX_PREVIEW_BYTES;

    // Where the attributes' white space goes, and what the leftover units are.
    uint256 internal constant NO_SPACE = 0;
    uint256 internal constant BEFORE = 1;
    uint256 internal constant INSIDE = 2;
    uint256 internal constant MEMBERS = 0;
    uint256 internal constant ZEROS = 1;

    address internal artist;
    address internal reader = makeAddr("budgetReader");
    uint256 internal salt;

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

    /// @dev `RendererGasBudgetTest._record`: `name`, a description of `MAX_ESCAPES` `%` and then
    ///      `fill` up to 12 KiB, the attributes, and the rest of the units as `shape`.
    function _record(bytes memory fill, uint256 shape, bytes memory attributes, uint256 units)
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
        if (where == NO_SPACE) return _record(hex"6161c3a9", shape, plain, ATTR_UNITS * n);
        uint256 free =
            Limits.MAX_RECORD_BYTES - _record("", shape, plain, ATTR_UNITS * n).length - 8;
        bytes memory attributes =
            where == BEFORE ? _spacedBefore(n, free / n) : _spacedInside(n, free / (17 * n));
        return _record(hex"6161c3a9", shape, attributes, ATTR_UNITS * n);
    }

    // ------------------------------------------------------------------ the work

    /// @dev The dearest collection name to render, of those `createCollection` accepts (it
    ///      refuses control characters, `<`, `"` and `\`, which JSON escaping makes six bytes):
    ///      U+2028 three bytes at a time, escaped to six (`\u2028`), and a `#` to fill the 256
    ///      bytes (the delta review's dearest). 256 `%` or `#` cost about 0.08M less, plain ASCII
    ///      about 0.2M less.
    function _dearestName() internal pure returns (string memory) {
        return string(bytes.concat(_fill(hex"e280a8", 255), "#"));
    }

    struct Built {
        uint256 tokenId;
        bytes32 licenseText;
        MediaFile[] media;
    }

    /// @dev A PREVIEW image at the cap: `Identity` of `MAX_PREVIEW_BYTES / 4` bytes, or attested
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
            FileRole.PRIMARY
        );
        _attestAll(b.media[0].fileId);
        (bytes32 preview, bytes32 previewSha) = _preview(base64Preview);
        b.media[1] = MediaFile(preview, previewSha, FileRole.PREVIEW);
        bytes memory terms = abi.encodePacked("The terms of the license, #", vm.toString(salt));
        b.licenseText = _storeText(terms, "text/plain");
        b.media[2] = MediaFile(b.licenseText, sha256(terms), FileRole.AUXILIARY);
        for (uint256 i = 3; i < b.media.length; ++i) {
            bytes memory aux =
                abi.encodePacked("auxiliary ", vm.toString(salt), "/", vm.toString(i));
            b.media[i] = MediaFile(_storeText(aux, "text/plain"), sha256(aux), FileRole.AUXILIARY);
        }
    }

    /// @dev The worst work: see the contract's notice. An edition master if `master`.
    function _build(bytes memory json, bool base64Preview, bool master)
        internal
        returns (Built memory b)
    {
        ++salt;
        vm.prank(platform);
        uint256 coll = stream.createCollection(_dearestName(), keccak256(abi.encode(salt)));
        bytes32 content;
        (b, content) = _mediaFiles(base64Preview);
        Work memory w;
        w.media = b.media;
        w.item = _item(artist, coll, content, b.media, _storeText(json, "application/json"));
        w.item.license =
            License(string.concat("LicenseRef-", string(_fill("x", 53))), b.licenseText);
        w.item.seedPolicy = SeedPolicy.ARTIST;
        w.item.seed = keccak256(abi.encode("seed", salt));
        if (master) {
            w.item.kind = ItemKind.EDITION_MASTER;
            w.item.edition = EditionTerms(20, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        }
        b.tokenId = _mintAndOpen(w, master);
        _addLocators(b);
        _platformStatement(address(stream), b.tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://d");
    }

    function _mintAndOpen(Work memory w, bool master) internal returns (uint256 tokenId) {
        Work[] memory works = _one(w);
        bytes32 root = _publish(works);
        uint256 saleId;
        (saleId, tokenId) = _start(root, works, 0);
        if (master) {
            _ethBid(saleId, makeAddr("budgetCollector"), 1 ether);
            _settleAtEnd(saleId);
            editions.createEdition(tokenId, w.item, root, _proofOf(works, 0));
        }
        records.openRecord(tokenId, w.item, w.media);
        records.syncOnChain(tokenId);
    }

    /// @dev 16 locators on the license text, of the longest kind (IPFS, 66 bytes) last and
    ///      ARWEAVE before it, and the global preference on IPFS: the scan runs to the end.
    function _addLocators(Built memory b) internal {
        for (uint256 i; i < 16; ++i) {
            string memory seed = string.concat(vm.toString(salt), "/", vm.toString(i));
            vm.prank(i < 8 ? artist : platform);
            records.addLocator(
                b.tokenId, b.licenseText, i == 15 ? CA.ipfsLocator(seed) : CA.ar(seed)
            );
        }
        vm.prank(storageOperator);
        records.setPreferredKind(LocatorKind.IPFS);
    }

    // ------------------------------------------------------------------ measuring

    /// @dev Cold Prague gas of `token`'s metadata view for `id`, as `_tokenUriMatrix` measures it.
    function _cold(address token, bytes memory call) internal returns (uint256 used) {
        (bool ok,) = token.call(call); // warm every account, so the surcharge applies to all
        assertTrue(ok, "metadata view");
        (, used) = _measure(reader, token, call, 0);
        StateGrowth.Growth memory growth = _growth(reader, token, call, 0);
        assertEq(growth.slots + growth.accounts, 0, "a view creates no state");
        used += COLD_ACCOUNT_SURCHARGE * growth.coldAccounts.length;
    }

    function _row(string memory label, bytes memory json, bool base64Preview) internal {
        Built memory b = _build(json, base64Preview, false);
        string memory uri = stream.tokenURI(b.tokenId);
        assertFalse(_contains(uri, "record_status"), "the record is accepted");
        assertTrue(_contains(uri, '"animation_url":"data:text/html;base64,'), "primary inline");
        assertTrue(_contains(uri, '"image":"data:image/png;base64,'), "preview inline");
        assertTrue(
            _contains(uri, string.concat('"license_url":"', CA.ipfs(_last(salt)), '"')),
            "the last locator is served"
        );
        uint256 used = _cold(address(stream), abi.encodeCall(stream.tokenURI, (b.tokenId)));
        console2.log(label, used);
        assertLt(used, TOKEN_URI_BUDGET, label);
    }

    function _last(uint256 s) internal view returns (string memory) {
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

    /// @dev An edition renders its master: `Editions.uri` adds the master link and one trait.
    function test_Budget_Edition_SpacedBefore_Zeros() public {
        Built memory b = _build(_worstRecord(BEFORE, ZEROS), false, true);
        string memory uri = editions.uri(b.tokenId);
        assertFalse(_contains(uri, "record_status"), "the record is accepted");
        assertTrue(_contains(uri, '"trait_type":"Edition of"'));
        uint256 used = _cold(address(editions), abi.encodeCall(editions.uri, (b.tokenId)));
        console2.log("edition, white space before each attribute, zeros:", used);
        assertLt(used, TOKEN_URI_BUDGET);
    }

    // ------------------------------------------------------------------ the read caps

    /// @dev The renderer's gas caps for the two satellite reads that grow with a work: the media
    ///      list (its own cap) and a preferred locator (the small-read cap). Not getters, to save
    ///      the renderer's bytecode: `RendererHostile.t.sol` checks the media cap's value.
    uint256 internal constant MEDIA_READ_CAP = 1_000_000;
    uint256 internal constant SMALL_READ_CAP = 300_000;

    /// @dev The least gas `call` on WorkRecords succeeds with, storage cold, plus EIP-2929's
    ///      2,500 for the one account it reaches that Foundry cannot cool (the store for
    ///      `mediaOf`, Stream for `preferredLocator`).
    function _least(bytes memory call) internal returns (uint256) {
        uint256 lo = 10_000;
        uint256 hi = 2_000_000;
        while (hi - lo > 100) {
            uint256 mid = (lo + hi) / 2;
            _coolAll();
            (bool ok,) = address(records).staticcall{ gas: mid }(call);
            if (ok) hi = mid;
            else lo = mid;
        }
        return hi + COLD_ACCOUNT_SURCHARGE;
    }

    /// @dev At every cap (32 files, 16 locators scanned to the last), each read needs a small
    ///      part of its cap from cold storage: room for a repricing of cold reads.
    function test_Reads_FarUnderTheirCaps() public {
        Built memory b = _build(_worstRecord(BEFORE, ZEROS), false, false);
        uint256 media = _least(abi.encodeCall(records.mediaOf, (b.tokenId)));
        uint256 locator =
            _least(abi.encodeCall(records.preferredLocator, (b.tokenId, b.licenseText)));
        console2.log("mediaOf, 32 files, cold:", media, "of", MEDIA_READ_CAP);
        console2.log("preferredLocator, 16 scanned, cold:", locator, "of", SMALL_READ_CAP);
        assertLt(media * 4, MEDIA_READ_CAP, "mediaOf: a quarter of its cap at most");
        assertLt(locator * 2, SMALL_READ_CAP, "preferredLocator: half of its cap at most");
    }

    // ------------------------------------------------------------------ the collection name

    /// @dev The names the review measured above the budget (a collection of 256 control bytes,
    ///      `"` or `<`, each escaped to up to six bytes in every work's metadata) are refused at
    ///      creation, as are a backslash and DEL anywhere; the dearest accepted name is the one
    ///      the rows use.
    function test_CollectionName_RefusesBytesThatEscapeLong() public {
        bytes[8] memory refused = [
            _fill(hex"01", 256),
            _fill('"', 256),
            _fill("<", 256),
            bytes("Genesis\\"),
            bytes("Genesis\x7f"),
            bytes("Gene\nsis"),
            bytes("A <b> collection"),
            hex"1f"
        ];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(platform);
            vm.expectRevert(IStream.InvalidCollectionName.selector);
            stream.createCollection(string(refused[i]), bytes32(0));
        }
        vm.startPrank(platform);
        stream.createCollection(_dearestName(), bytes32(0));
        stream.createCollection(string(_fill("%", 256)), bytes32(0));
        stream.createCollection("Genesis & Co. > 'all' #1", bytes32(0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ the preview cap

    /// @dev `openRecord` refuses an inlinable PREVIEW file (`Identity` or `Base64`) over the cap,
    ///      `Identity` counted four times, so the renderer never inlines a preview the budget
    ///      does not cover; a work whose media passes opens. A gzip preview is never inlined, so
    ///      it is not bounded.
    function test_PreviewCap_OpenRecordRefusesALargerPreview() public {
        uint256 cap = Limits.MAX_PREVIEW_BYTES;
        _expectPreview(_bytes(cap / 4 + 1, 1), IContentStore.Encoding.Identity, false);
        _expectPreview(_bytes(cap + 4, 2), IContentStore.Encoding.Base64, false);
        _expectPreview(_bytes(4 * cap, 3), IContentStore.Encoding.Gzip, true);
        _expectPreview(_bytes(4 * cap, 6), IContentStore.Encoding.GzipBase64, true);
        _expectPreview(_bytes(cap / 4, 4), IContentStore.Encoding.Identity, true);
        _expectPreview(_bytes(cap, 5), IContentStore.Encoding.Base64, true);
        // Not a PREVIEW: an auxiliary file of any size is unaffected.
        Work memory w = _work(artist, collectionId);
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = w.media[0];
        bytes memory big = _bytes(cap + 1, 6);
        media[1] = MediaFile(
            _registerOnly(big, IContentStore.Encoding.Identity, "image/png", sha256(big)),
            sha256(big),
            FileRole.AUXILIARY
        );
        _open(w, media, true);
    }

    function _expectPreview(bytes memory stored, IContentStore.Encoding encoding, bool fits)
        internal
    {
        Work memory w = _work(artist, collectionId);
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = w.media[0];
        bytes32 sha = sha256(stored);
        media[1] =
            MediaFile(_registerOnly(stored, encoding, "image/png", sha), sha, FileRole.PREVIEW);
        _open(w, media, fits);
    }

    function _open(Work memory w, MediaFile[] memory media, bool fits) internal {
        w.media = media;
        w.item = _item(artist, collectionId, media[0].sha256Hash, media, w.item.recordFileId);
        Work[] memory works = _one(w);
        (, uint256 tokenId) = _start(_publish(works), works, 0);
        if (!fits) {
            vm.expectRevert(
                abi.encodeWithSelector(IWorkRecords.InvalidRecordData.selector, tokenId)
            );
        }
        records.openRecord(tokenId, w.item, media);
        assertEq(records.isOpen(tokenId), fits);
    }
}
