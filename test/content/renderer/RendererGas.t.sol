// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { RendererBase } from "./RendererBase.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { Renderer } from "src/content/Renderer.sol";
import { IRenderer } from "src/interfaces/IRenderer.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { JsonScan } from "src/content/JsonScan.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";

/// @dev What 6529 Stream's `tokenURI` does with the renderer's answer: call it, copy the string
///      out of the return data, and return it again. The extra copies are part of the budget.
contract TokenURIRelay {
    IRenderer internal immutable renderer;
    address internal immutable token;

    constructor(IRenderer renderer_, address token_) {
        renderer = renderer_;
        token = token_;
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        return renderer.tokenURI(token, id);
    }

    function fullTokenURI(uint256 id) external view returns (string memory) {
        return renderer.fullTokenURI(token, id);
    }
}

/// @dev The `tokenURI` gas matrix (ADR 0001: at most 8M, measured). Run with
///      `forge test --match-contract RendererGas -vv` to print the table. Each figure is the gas
///      of one call through a relay that behaves like Stream's `tokenURI`, from a cold start
///      (the fixtures are built in `setUp`, a separate transaction), without the cost of copying
///      the result into the test. The fixtures are pseudo-random bytes. The content store is the
///      real one; the Stream and the log are mocks that answer from storage, so the figures
///      include the mocks' own reads (the real Stream reads the record from SSTORE2 instead).
contract RendererGasTest is RendererBase {
    uint256 internal constant GAS_BUDGET = 8_000_000;
    /// @dev Stored bytes of the files measured.
    uint256[4] internal sizes = [uint256(32_768), 65_536, 131_072, 262_144];
    /// @dev No renderer inlines an `Identity` file above 128 KiB (weight 8 against 1 MiB), so
    ///      only the first three sizes exist as identity files.
    bytes32[3] internal identityFiles;
    bytes32[4] internal base64Files;
    TokenURIRelay internal relay;
    /// @dev A renderer whose threshold is high enough to inline every identity file measured.
    TokenURIRelay internal wideRelay;

    function setUp() public override {
        super.setUp();
        relay = new TokenURIRelay(renderer, address(stream));
        wideRelay = new TokenURIRelay(
            new Renderer(store, IStatementLog(address(disputeLog)), 1_048_576), address(stream)
        );
        for (uint256 i; i < 4; ++i) {
            if (i < 3) identityFiles[i] = _file(_data(sizes[i], i), IDENTITY, "image/png");
            // The same stored size: base64 text, so the media itself is three quarters of it.
            base64Files[i] =
                _file(bytes(Base64.encode(_data(sizes[i] / 4 * 3, 10 + i))), BASE64, "image/png");
        }
    }

    function _gas(TokenURIRelay target, bytes memory callData)
        internal
        view
        returns (uint256 used)
    {
        address to = address(target);
        bool ok;
        assembly ("memory-safe") {
            let before := gas()
            ok := staticcall(gas(), to, add(callData, 0x20), mload(callData), 0, 0)
            used := sub(before, gas())
        }
        assertTrue(ok, "call failed");
    }

    function _compact(TokenURIRelay target, bytes32 file) internal returns (uint256) {
        _install(file);
        return _gas(target, abi.encodeCall(TokenURIRelay.tokenURI, (ID)));
    }

    /// @dev The measured table: the gas of `tokenURI` for a primary file of each size and storage.
    function test_Matrix() public {
        emit log("tokenURI gas (stored bytes of the primary file)");
        for (uint256 i; i < 4; ++i) {
            uint256 b64 = _compact(relay, base64Files[i]);
            emit log_named_uint(string.concat("base64   ", vm.toString(sizes[i])), b64);
            assertLt(b64, GAS_BUDGET, "base64 within 8M at every size, including the default");
            if (i == 3) continue;
            // The widest renderer inlines these; the default one only up to an eighth of 256 KiB.
            uint256 identity = _compact(wideRelay, identityFiles[i]);
            emit log_named_uint(string.concat("identity ", vm.toString(sizes[i])), identity);
            if (sizes[i] <= renderer.inlineThreshold() / 8) {
                assertLt(
                    identity, GAS_BUDGET, "identity within 8M up to an eighth of the threshold"
                );
            }
        }
    }

    /// @dev Why an `Identity` file counts eight times: past an eighth of the threshold it would
    ///      not fit 8M gas.
    function test_IdentityPastAnEighthOfTheThresholdDoesNotFit() public {
        uint256 used = _compact(wideRelay, identityFiles[2]); // 128 KiB
        assertGt(used, GAS_BUDGET, "if this fits, the weighting can be lowered");
    }

    function test_DefaultRendererServesTheLargestIdentityFileItInlines() public {
        // An eighth of the threshold: the file is inlined (it is long), and within budget.
        uint256 used = _compact(relay, identityFiles[0]);
        assertGt(used, 1_000_000, "inlined, not a locator");
        assertLt(used, GAS_BUDGET);
        // Above it: a locator, which is cheap.
        _install(identityFiles[1]);
        records.addLocator(ID, identityFiles[1], Locator(LocatorKind.IPFS, "ipfs://bafy"));
        assertLt(_gas(relay, abi.encodeCall(TokenURIRelay.tokenURI, (ID))), 500_000);
    }

    function test_ScriptPage() public {
        bytes memory js = new bytes(SCRIPT_LIMIT);
        for (uint256 i; i < js.length; ++i) {
            js[i] = i % 64 == 63 ? bytes1("\n") : bytes1("a");
        }
        uint256 used = _compact(relay, _file(js, IDENTITY, "text/javascript"));
        emit log_named_uint("script page, SCRIPT_LIMIT bytes", used);
        assertLt(used, GAS_BUDGET);
    }

    /// @dev Scripts made of what the neutralizer looks for, with the most `<` it takes
    ///      (`MAX_SCRIPT_LT`), then plain text to the script limit: the slowest inputs, wrapped.
    ///      The same with one more `<` is refused and served by locator, which is cheap.
    function test_ScriptPageOfNothingButTheDangerousStarts() public {
        bytes[5] memory unit =
            [bytes("<"), "</", "<!-", "</script", "<aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"];
        uint256 lt = MAX_SCRIPT_LT;
        for (uint256 u; u < unit.length; ++u) {
            bytes memory js = new bytes(SCRIPT_LIMIT);
            for (uint256 i; i < js.length; ++i) {
                js[i] = "a";
            }
            // `lt` of the unit (the last may be cut by the limit), in the first bytes.
            for (uint256 k; k < lt && k * unit[u].length < js.length; ++k) {
                for (uint256 i; i < unit[u].length && k * unit[u].length + i < js.length; ++i) {
                    js[k * unit[u].length + i] = unit[u][i];
                }
            }
            bytes32 file = _file(js, IDENTITY, "text/javascript");
            uint256 used = _compact(relay, file);
            emit log_named_uint(string.concat("script page, 1,024 x ", string(unit[u])), used);
            assertLt(used, GAS_BUDGET);
            assertTrue(_has(_out(), ".animation_url"));
            assertEq(_startsWith(_str(_out(), ".animation_url"), "data:text/html;base64,"), true);
        }
        // One more `<` and the page is not built.
        bytes memory dense = new bytes(SCRIPT_LIMIT);
        for (uint256 i; i < dense.length; ++i) {
            dense[i] = "<";
        }
        bytes32 denseFile = _file(dense, IDENTITY, "text/javascript");
        uint256 refused = _compact(relay, denseFile);
        emit log_named_uint("script of 16,384 <, refused", refused);
        assertLt(refused, 1_000_000);
        assertFalse(_has(_out(), ".animation_url"), "no locator: no media");
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(prefix);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function test_OverTheThresholdIsCheap() public {
        bytes32 file = _file(_data(THRESHOLD + 1, 99), IDENTITY, "image/png");
        _install(file);
        records.addLocator(ID, file, Locator(LocatorKind.IPFS, "ipfs://bafy"));
        uint256 used = _gas(relay, abi.encodeCall(TokenURIRelay.tokenURI, (ID)));
        emit log_named_uint("locator only", used);
        assertLt(used, 1_500_000);
    }

    /// @dev `fullTokenURI` is an off-chain view with no 8M promise; its cost is reported. Uploading
    ///      and attesting the file is most of a test's own gas, so each size is a test of its own.
    function _full(uint256 size, uint256 seed) internal {
        bytes memory media = _data(size / 4 * 3, seed);
        _install(_file(bytes(Base64.encode(media)), BASE64, "image/png"));
        uint256 used = _gas(relay, abi.encodeCall(TokenURIRelay.fullTokenURI, (ID)));
        emit log_named_uint(string.concat("fullTokenURI base64 ", vm.toString(size)), used);
    }

    function test_FullForm_256KiB() public {
        _full(262_144, 50);
    }

    function test_FullForm_512KiB() public {
        _full(524_288, 51);
    }

    function test_FullForm_1MiB() public {
        _full(1_048_576, 52);
    }
}

/// @dev Cold worst cases (ADR 0001: at most 8M for every record the renderer accepts, and cheap
///      for every record it refuses). The fixtures are built in `setUp`, a separate transaction,
///      so each test starts with cold storage and cold accounts, as an `eth_call` does, and each
///      measures one work (a second would find the record and the media warm). A record is built
///      to a limit the renderer enforces (the record size, `JsonScan.MAX_VALUES` values and
///      escapes, `MAX_ESCAPES`, `MAX_ATTRIBUTES`) or is full of one class of byte, and is
///      measured with each of the two costliest primaries: a base64 text/html file of 256 KiB
///      (attested) and a 16 KiB script of `</scrip`, with an identity preview at its limit, a
///      collection whose name is all `%`, a seed, a dispute and a `LicenseRef` license with a
///      text file and a locator. Run with `-vv`.
contract RendererGasAdversarialTest is RendererBase {
    uint256 internal constant GAS_BUDGET = 8_000_000;

    // Work IDs: a record class `k` is work `10 * k + 1` with the HTML primary and `10 * k + 2` with
    // the script.
    uint256 internal constant K_VALUES = 1; // the most values, in an ignored array of zeros
    uint256 internal constant K_MEMBERS = 2; // the most values, as members of the top object
    uint256 internal constant K_ATTRS = 3; // the most attributes, and the rest of the values
    uint256 internal constant K_PERCENT = 4; // a `%` every sixth byte of text filling the record
    uint256 internal constant K_BACKSLASH = 5; // text of `\\` escapes
    uint256 internal constant K_UNICODE = 6; // text of `é` escapes
    uint256 internal constant K_PAIRS = 7; // text of `😀` escape pairs
    uint256 internal constant K_UTF8_2 = 8; // 2-byte UTF-8 (Cyrillic prose)
    uint256 internal constant K_UTF8_3 = 9; // 3-byte UTF-8 (Japanese prose)
    uint256 internal constant K_UTF8_4 = 10; // 4-byte UTF-8 (emoji)
    uint256 internal constant K_SPACES = 11; // whitespace padding
    uint256 internal constant K_PRETTY = 12; // a pretty-printed array, one indented value a line
    uint256 internal constant K_NAMES = 13; // attributes with 132-byte ASCII names
    uint256 internal constant K_NAMES_PCT = 14; // the same, with 16 `%` in each
    uint256 internal constant K_NAMES_BS = 15; // names of `\\` escapes (refused: no backslash in a name)
    uint256 internal constant K_NAMES_UTF8 = 16; // attributes with names of 2-byte UTF-8
    // The dearest mix: names of 2-byte UTF-8 that also hold as many `%` as the cap allows.
    uint256 internal constant K_NAMES_MIX = 21;
    // The three escape classes again, with as many escapes as the budget takes (accepted).
    uint256 internal constant K_BACKSLASH_CAP = 17;
    uint256 internal constant K_UNICODE_CAP = 18;
    uint256 internal constant K_PAIRS_CAP = 19;
    // Refused records, each cheap: arrays of tiny values, members of nothing, `\u0000`,
    // more attributes than allowed, `%` past the cap, escapes past the cap.
    uint256 internal constant W_BOMB_ARRAY = 201;
    uint256 internal constant W_BOMB_ATTRS = 202;
    uint256 internal constant W_BOMB_EMPTY = 203;
    uint256 internal constant W_BOMB_MEMBERS = 204;
    uint256 internal constant W_BOMB_KEYS = 205;
    uint256 internal constant W_BOMB_NUL = 206;
    uint256 internal constant W_BOMB_PERCENT = 207;
    uint256 internal constant W_TOO_MANY_ATTRS = 208;
    uint256 internal constant W_BOMB_ESCAPES = 209;

    TokenURIRelay internal relay;
    bytes32 internal html;
    bytes32 internal script;
    bytes32 internal preview;
    bytes32 internal licenseText;
    uint256 internal limit;

    function _fill(bytes memory unit, uint256 n) internal pure returns (bytes memory j) {
        j = new bytes(n);
        for (uint256 i; i < n; ++i) {
            j[i] = unit[i % unit.length];
        }
    }

    /// @dev `open`, then `unit` as often as fits, then `close`: a record of at most `limit` bytes.
    function _padded(bytes memory open, bytes memory unit, bytes memory close)
        internal
        view
        returns (bytes memory)
    {
        uint256 n = (limit - open.length - close.length) / unit.length;
        return bytes.concat(open, _fill(unit, n * unit.length), close);
    }

    /// @dev `open`, `n` of `unit`, then plain text up to a full record, then `close`.
    function _capped(bytes memory open, bytes memory unit, uint256 n, bytes memory close)
        internal
        view
        returns (bytes memory)
    {
        uint256 used = open.length + n * unit.length + close.length;
        return bytes.concat(open, _fill(unit, n * unit.length), _fill("a", limit - used), close);
    }

    /// @dev `open`, then `unit` as many times as fit in a record (without its last comma), then
    ///      `close`.
    function _bomb(bytes memory open, bytes memory unit, bytes memory close)
        internal
        view
        returns (bytes memory j)
    {
        uint256 n = (limit - open.length - close.length) / unit.length;
        j = new bytes(open.length + n * unit.length - 1 + close.length);
        uint256 p;
        for (uint256 i; i < open.length; ++i) {
            j[p++] = open[i];
        }
        for (uint256 k; k < n; ++k) {
            for (uint256 i; i < unit.length; ++i) {
                if (k == n - 1 && i == unit.length - 1) break; // drop the last comma
                j[p++] = unit[i];
            }
        }
        for (uint256 i; i < close.length; ++i) {
            j[p++] = close[i];
        }
    }

    /// @dev Work `id` with record `json`, the media `primary` and `prev` (none if zero) and the
    ///      license text, a collection, a seed, a dispute and a license with its own locator.
    function _members(uint256 id, bytes memory json, bytes32 primary, bytes32 prev) internal {
        require(json.length <= limit, "record over the limit");
        MediaFile[] memory m = new MediaFile[](prev == 0 ? 2 : 3);
        m[0] = MediaFile(primary, _sha(primary), FileRole.PRIMARY);
        m[1] = MediaFile(licenseText, _sha(licenseText), FileRole.AUXILIARY);
        if (prev != 0) m[2] = MediaFile(prev, _sha(prev), FileRole.PREVIEW);
        _installRawAt(id, json, m);
        IStream.WorkCore memory core = _core();
        core.collectionId = 1;
        core.serial = 9;
        core.seedPolicy = SeedPolicy.ARTIST;
        stream.setWork(id, core);
        records.setSeed(id, SeedPolicy.ARTIST, bytes32(uint256(1)));
        disputeLog.set(address(stream), id, bytes32(uint256(1)));
        records.setLicense(id, License("LicenseRef-Studio-1", licenseText));
        records.addLocator(id, licenseText, Locator(LocatorKind.ARWEAVE, "ar://licence"));
    }

    /// @dev Record class `k` as work `10 * k + 1` (HTML primary) and `10 * k + 2` (script).
    function _both(uint256 k, bytes memory json) internal {
        _members(10 * k + 1, json, html, preview);
        _members(10 * k + 2, json, script, preview);
    }

    /// @dev `n` attributes of the same text, comma separated, in an array.
    function _attrList(bytes memory attr, uint256 n) internal pure returns (bytes memory all) {
        all = new bytes(n * (attr.length + 1) - 1);
        uint256 p;
        for (uint256 k; k < n; ++k) {
            if (k != 0) all[p++] = ",";
            for (uint256 i; i < attr.length; ++i) {
                all[p++] = attr[i];
            }
        }
    }

    /// @dev As many attributes with names of `unit` (the name `per` bytes long, `pct` of them `%`)
    ///      as fit in a record.
    function _names(bytes memory unit, uint256 pct, uint256 per)
        internal
        view
        returns (bytes memory)
    {
        bytes memory name = bytes.concat(_fill("%", pct), _fill(unit, per - pct));
        bytes memory attr = bytes.concat('{"trait_type":"', name, '","value":1}');
        bytes memory open = '{"name":"N","attributes":[';
        uint256 n = (limit - open.length - 2) / (attr.length + 1);
        if (n > MAX_ATTRIBUTES) n = MAX_ATTRIBUTES;
        return bytes.concat(open, _attrList(attr, n), "]}");
    }

    function setUp() public override {
        super.setUp();
        relay = new TokenURIRelay(renderer, address(stream));
        limit = Limits.MAX_RECORD_BYTES;
        preview = _file(_data(PREVIEW_LIMIT / 8, 70), IDENTITY, "image/png");
        html = _file(
            bytes(Base64.encode(_data(renderer.inlineThreshold() / 4 * 3, 71))), BASE64, "text/html"
        );
        assertTrue(_attested(html));
        // The costliest script the renderer wraps: 1,024 `</script` (the most `<` it takes), then plain
        // text to the script limit.
        uint256 lt = MAX_SCRIPT_LT;
        script = _file(
            bytes.concat(_fill("</script", 8 * lt), _fill("a", SCRIPT_LIMIT - 8 * lt)),
            IDENTITY,
            "text/javascript"
        );
        bytes32 tiny = _file(hex"89504e47", IDENTITY, "image/png");
        licenseText = _file("The terms of the license.", IDENTITY, "text/plain");
        // A collection whose name is all `%`, which the renderer escapes.
        stream.setCollection(1, IStream.Collection(string(_fill("%", 256)), bytes32(0), 9));
        bytes memory open = '{"name":"N","description":"';
        bytes memory close = '"}';

        // The most units (a value, a key, an escape: 1,024, a top-level key counting two): the
        // top-level object holds `name` (3 units), the array (`a`, 3 units) and 1,018 zeros, or
        // 340 members of 3 units each.
        _both(
            K_VALUES,
            bytes.concat(
                '{"name":"N","a":[0', _fill(",0", 2 * (JsonScan.MAX_VALUES - 3 - 3 - 1)), "]}"
            )
        );
        _both(
            K_MEMBERS,
            bytes.concat('{"name":"N"', _fill(',"a":0', 6 * ((JsonScan.MAX_VALUES - 3) / 3)), "}")
        );
        // The most attributes (each is an object, two keys and two values: 5 units), and the rest
        // of the units in an ignored array.
        uint256 attrs = MAX_ATTRIBUTES;
        _both(
            K_ATTRS,
            bytes.concat(
                '{"name":"N","a":[0',
                _fill(",0", 2 * (JsonScan.MAX_VALUES - 3 - 3 - (3 + 5 * attrs) - 1)),
                '],"attributes":[',
                _attrList('{"trait_type":"k","value":1}', attrs),
                "]}"
            )
        );
        // Text filling the record: the most `%` and `#` it may hold (a `%` every sixth byte), then
        // every other class of byte.
        _both(
            K_PERCENT,
            bytes.concat(
                open,
                _fill("aaaaa%", 6 * MAX_ESCAPES),
                _fill("a", limit - open.length - close.length - 6 * MAX_ESCAPES),
                close
            )
        );
        _both(K_BACKSLASH, _padded(open, hex"5c5c", close));
        // With the escapes the budget takes: `name` and `description` are 6 units, 1,018 more.
        _both(K_BACKSLASH_CAP, _capped(open, hex"5c5c", 1_018, close));
        _both(K_UNICODE_CAP, _capped(open, hex"5c7530306539", 1_018, close));
        _both(K_PAIRS_CAP, _capped(open, bytes("\\ud83d\\ude00"), 509, close));
        _both(K_UNICODE, _padded(open, hex"5c7530306539", close));
        _both(K_PAIRS, _padded(open, bytes("\\ud83d\\ude00"), close));
        _both(K_UTF8_2, _padded(open, hex"d09fd180d0b8d0b2d0b5d18220d0bcd0b8d18020", close));
        _both(K_UTF8_3, _padded(open, hex"e697a5e69cace8aa9ee381aee8aaace6988ee38082", close));
        _both(K_UTF8_4, _padded(open, hex"f09f9880", close));
        _both(K_SPACES, _padded('{"name":"N"', " ", "}"));
        _both(
            K_PRETTY,
            _padded(
                '{\n  "name": "N",\n  "a": [\n',
                "                    0,\n",
                "                    0\n  ]\n}"
            )
        );
        // Attributes with long names: plain, with `%`, of escapes, of 2-byte UTF-8.
        _both(K_NAMES, _names("a", 0, 132));
        _both(K_NAMES_PCT, _names("a", MAX_ESCAPES / MAX_ATTRIBUTES, 132));
        _both(K_NAMES_BS, _names(hex"5c5c", 0, 132));
        _both(K_NAMES_UTF8, _names(hex"c3a9", 0, 130));
        _both(K_NAMES_MIX, _names(hex"c3a9", MAX_ESCAPES / MAX_ATTRIBUTES, 130));

        // Records the renderer refuses: each must cost little.
        _members(W_BOMB_ARRAY, _bomb('{"name":"N","a":[', "0,", "]}"), tiny, 0);
        _members(W_BOMB_ATTRS, _bomb('{"name":"N","attributes":[', "0,", "]}"), tiny, 0);
        _members(W_BOMB_EMPTY, _bomb('{"name":"N","a":[', "[],", "]}"), tiny, 0);
        _members(W_BOMB_MEMBERS, _bomb('{"name":"N",', '"a":0,', "}"), tiny, 0);
        _members(W_BOMB_KEYS, _bomb('{"name":"N",', '"":0,', "}"), tiny, 0);
        _members(W_BOMB_NUL, _bomb('{"name":"N","a":"', "\\u0000,", '"}'), tiny, 0);
        _members(
            W_BOMB_PERCENT,
            bytes.concat(open, _fill("%", limit - open.length - 2), close),
            html,
            preview
        );
        _members(
            W_TOO_MANY_ATTRS,
            bytes.concat(
                '{"name":"N","attributes":[',
                _attrList('{"trait_type":"k","value":1}', attrs + 1),
                "]}"
            ),
            html,
            preview
        );
        _members(W_BOMB_ESCAPES, _padded(open, hex"5c6e", close), html, preview);
    }

    function _cold(uint256 id) internal view returns (uint256 used, bool ok) {
        bytes memory callData = abi.encodeCall(TokenURIRelay.tokenURI, (id));
        address to = address(relay);
        assembly ("memory-safe") {
            let before := gas()
            ok := staticcall(gas(), to, add(callData, 0x20), mload(callData), 0, 0)
            used := sub(before, gas())
        }
    }

    /// @dev The cold gas of work `id`, which must be accepted (no `record_status`) and cost less
    ///      than the budget.
    function _row(string memory label, uint256 id) internal returns (string memory j) {
        (uint256 used, bool ok) = _cold(id);
        emit log_named_uint(label, used);
        assertTrue(ok, label);
        assertLt(used, GAS_BUDGET, label);
        j = _decode(renderer.tokenURI(address(stream), id));
        assertFalse(_has(j, ".record_status"), "an accepted record");
        assertEq(_str(j, ".name"), "N");
    }

    // ---------------------------------------------------------------- one test per row and primary

    function test_Gas_Values_Html() public {
        _row("1,024 units, array of zeros + 256 KiB b64 + preview", 10 * K_VALUES + 1);
    }

    function test_Gas_Values_Script() public {
        _row("1,024 units, array of zeros + script + preview", 10 * K_VALUES + 2);
    }

    function test_Gas_Members_Html() public {
        _row("340 top-level members + 256 KiB b64 + preview", 10 * K_MEMBERS + 1);
    }

    function test_Gas_Members_Script() public {
        _row("340 top-level members + script + preview", 10 * K_MEMBERS + 2);
    }

    function test_Gas_Attributes_Html() public {
        string memory j =
            _row("64 attributes + 695 zeros + 256 KiB b64 + preview", 10 * K_ATTRS + 1);
        uint256 first = _attrIndex(j, "k");
        assertEq(_str(j, _at(first + MAX_ATTRIBUTES - 1, ".trait_type")), "k");
        assertFalse(_has(j, _at(first + MAX_ATTRIBUTES, "")));
    }

    function test_Gas_Attributes_Script() public {
        _row("64 attributes + 695 zeros + script + preview", 10 * K_ATTRS + 2);
    }

    function test_Gas_Percent_Html() public {
        _row("512 % in 12 KiB text + 256 KiB b64 + preview", 10 * K_PERCENT + 1);
    }

    function test_Gas_Percent_Script() public {
        _row("512 % in 12 KiB text + script + preview", 10 * K_PERCENT + 2);
    }

    /// @dev A row of a record the renderer refuses: it costs the scan up to the budget, no more.
    function _refusedRow(string memory label, uint256 id) internal {
        (uint256 used, bool ok) = _cold(id);
        emit log_named_uint(label, used);
        assertTrue(ok, label);
        assertLt(used, GAS_BUDGET, label);
        string memory j = _decode(renderer.tokenURI(address(stream), id));
        assertEq(_str(j, ".record_status"), "invalid", label);
    }

    function test_Gas_Backslashes_Html() public {
        _refusedRow(
            "12 KiB of \\\\ escapes (refused) + 256 KiB b64 + preview", 10 * K_BACKSLASH + 1
        );
    }

    function test_Gas_Backslashes_Script() public {
        _refusedRow("12 KiB of \\\\ escapes (refused) + script + preview", 10 * K_BACKSLASH + 2);
    }

    function test_Gas_BackslashesAtTheBudget_Html() public {
        _row("1,018 \\\\ escapes + 12 KiB text + 256 KiB b64 + preview", 10 * K_BACKSLASH_CAP + 1);
    }

    function test_Gas_BackslashesAtTheBudget_Script() public {
        _row("1,018 \\\\ escapes + 12 KiB text + script + preview", 10 * K_BACKSLASH_CAP + 2);
    }

    function test_Gas_UnicodeEscapes_Html() public {
        _refusedRow(
            "12 KiB of \\u00e9 escapes (refused) + 256 KiB b64 + preview", 10 * K_UNICODE + 1
        );
    }

    function test_Gas_UnicodeEscapes_Script() public {
        _refusedRow("12 KiB of \\u00e9 escapes (refused) + script + preview", 10 * K_UNICODE + 2);
    }

    function test_Gas_UnicodeEscapesAtTheBudget_Html() public {
        _row("1,018 \\u00e9 escapes + 12 KiB text + 256 KiB b64 + preview", 10 * K_UNICODE_CAP + 1);
    }

    function test_Gas_UnicodeEscapesAtTheBudget_Script() public {
        _row("1,018 \\u00e9 escapes + 12 KiB text + script + preview", 10 * K_UNICODE_CAP + 2);
    }

    function test_Gas_EscapePairs_Html() public {
        _refusedRow(
            "12 KiB of \\ud83d\\ude00 pairs (refused) + 256 KiB b64 + preview", 10 * K_PAIRS + 1
        );
    }

    function test_Gas_EscapePairs_Script() public {
        _refusedRow("12 KiB of \\ud83d\\ude00 pairs (refused) + script + preview", 10 * K_PAIRS + 2);
    }

    function test_Gas_EscapePairsAtTheBudget_Html() public {
        _row("509 \\ud83d\\ude00 pairs + 12 KiB text + 256 KiB b64 + preview", 10 * K_PAIRS_CAP + 1);
    }

    function test_Gas_EscapePairsAtTheBudget_Script() public {
        _row("509 \\ud83d\\ude00 pairs + 12 KiB text + script + preview", 10 * K_PAIRS_CAP + 2);
    }

    function test_Gas_Utf8Two_Html() public {
        _row("12 KiB 2-byte UTF-8 + 256 KiB b64 + preview", 10 * K_UTF8_2 + 1);
    }

    function test_Gas_Utf8Two_Script() public {
        _row("12 KiB 2-byte UTF-8 + script + preview", 10 * K_UTF8_2 + 2);
    }

    function test_Gas_Utf8Three_Html() public {
        _row("12 KiB 3-byte UTF-8 + 256 KiB b64 + preview", 10 * K_UTF8_3 + 1);
    }

    function test_Gas_Utf8Three_Script() public {
        _row("12 KiB 3-byte UTF-8 + script + preview", 10 * K_UTF8_3 + 2);
    }

    function test_Gas_Utf8Four_Html() public {
        _row("12 KiB 4-byte UTF-8 + 256 KiB b64 + preview", 10 * K_UTF8_4 + 1);
    }

    function test_Gas_Utf8Four_Script() public {
        _row("12 KiB 4-byte UTF-8 + script + preview", 10 * K_UTF8_4 + 2);
    }

    function test_Gas_Spaces_Html() public {
        _row("12 KiB of spaces + 256 KiB b64 + preview", 10 * K_SPACES + 1);
    }

    function test_Gas_Spaces_Script() public {
        _row("12 KiB of spaces + script + preview", 10 * K_SPACES + 2);
    }

    function test_Gas_PrettyPrinted_Html() public {
        _row("12 KiB pretty-printed values + 256 KiB b64 + preview", 10 * K_PRETTY + 1);
    }

    function test_Gas_PrettyPrinted_Script() public {
        _row("12 KiB pretty-printed values + script + preview", 10 * K_PRETTY + 2);
    }

    function test_Gas_LongNames_Html() public {
        _row("132-byte attribute names + 256 KiB b64 + preview", 10 * K_NAMES + 1);
    }

    function test_Gas_LongNames_Script() public {
        _row("132-byte attribute names + script + preview", 10 * K_NAMES + 2);
    }

    function test_Gas_LongNamesWithPercent_Html() public {
        _row("132-byte attribute names, 8 % each + 256 KiB b64 + preview", 10 * K_NAMES_PCT + 1);
    }

    function test_Gas_LongNamesWithPercent_Script() public {
        _row("132-byte attribute names, 8 % each + script + preview", 10 * K_NAMES_PCT + 2);
    }

    function test_Gas_LongNamesOfUtf8_Html() public {
        _row(
            "130-byte attribute names of 2-byte UTF-8 + 256 KiB b64 + preview",
            10 * K_NAMES_UTF8 + 1
        );
    }

    function test_Gas_LongNamesOfUtf8_Script() public {
        _row("130-byte attribute names of 2-byte UTF-8 + script + preview", 10 * K_NAMES_UTF8 + 2);
    }

    function test_Gas_LongNamesOfUtf8WithPercent_Html() public {
        _row(
            "130-byte names of 2-byte UTF-8, 8 % each + 256 KiB b64 + preview", 10 * K_NAMES_MIX + 1
        );
    }

    function test_Gas_LongNamesOfUtf8WithPercent_Script() public {
        _row("130-byte names of 2-byte UTF-8, 8 % each + script + preview", 10 * K_NAMES_MIX + 2);
    }

    // ---------------------------------------------------------------- refused records

    /// @dev Names with a backslash are refused, so they cost the scan and the first check only.
    function test_Gas_NamesOfEscapesAreRefusedCheaply() public {
        (uint256 used, bool ok) = _cold(10 * K_NAMES_BS + 1);
        emit log_named_uint("refused: attribute names of \\\\", used);
        assertTrue(ok);
        assertLt(used, GAS_BUDGET);
        string memory j = _decode(renderer.tokenURI(address(stream), 10 * K_NAMES_BS + 1));
        assertEq(_str(j, ".record_status"), "invalid");
    }

    function test_Gas_RefusedRecordsAreCheap() public {
        uint256[9] memory ids = [
            W_BOMB_ARRAY,
            W_BOMB_ATTRS,
            W_BOMB_EMPTY,
            W_BOMB_MEMBERS,
            W_BOMB_KEYS,
            W_BOMB_NUL,
            W_BOMB_PERCENT,
            W_TOO_MANY_ATTRS,
            W_BOMB_ESCAPES
        ];
        string[9] memory labels = [
            "refused: array of 0",
            "refused: attributes array of 0",
            "refused: array of []",
            "refused: members a:0",
            "refused: members \"\":0",
            "refused: \\u0000 escapes",
            "refused: 12 KiB of %",
            "refused: 65 attributes",
            "refused: 6,000 \\n escapes"
        ];
        for (uint256 i; i < labels.length; ++i) {
            (uint256 used, bool ok) = _cold(ids[i]);
            emit log_named_uint(labels[i], used);
            assertTrue(ok, labels[i]);
            // A refused record costs the scan up to its first fault: well under the budget.
            assertLt(used, 4_000_000, labels[i]);
            string memory j = _decode(renderer.tokenURI(address(stream), ids[i]));
            assertEq(_str(j, ".record_status"), "invalid", labels[i]);
        }
    }
}

/// @dev The budget proof (decision H2, round 3): every cap at once. Each class of byte and each
///      limit is bounded on its own, but a record can sit at all of them, and its cost is their
///      sum. The record here has the most attributes, the most `%`, the most units in members,
///      an array or a nested object, and its remaining bytes (up to 12 KiB) filled with the
///      costliest mix of UTF-8 (a short run of ASCII and a multi-byte sequence, alternating, so
///      the validator changes path at every step), against the primaries that cost the most: 256
///      KiB of attested `Base64`, the script of `</script` with the most `<`, and a script of
///      `a` and U+0800 (the costliest to validate). Each is cold, one work per test, and at most
///      8M. The media are the same as in `RendererGasAdversarialTest`.
contract RendererGasBudgetTest is RendererBase {
    uint256 internal constant GAS_BUDGET = 8_000_000;
    bytes internal constant ATTR = '{"trait_type":"k","value":1}';

    // Primaries.
    uint256 internal constant P_HTML = 1;
    uint256 internal constant P_SCRIPT_LT = 2;
    uint256 internal constant P_SCRIPT_U8 = 3;
    // Shapes of the units left over after the attributes.
    uint256 internal constant MEMBERS = 0; // top-level members, 3 units each
    uint256 internal constant ZEROS = 1; // an array of zeros, 1 unit each
    uint256 internal constant NESTED = 2; // members of a nested object, 2 units each

    TokenURIRelay internal relay;
    bytes32 internal html;
    bytes32 internal scriptLt;
    bytes32 internal scriptU8;
    bytes32 internal preview;
    bytes32 internal licenseText;
    uint256 internal limit;

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

    /// @dev Work `id` with `json` and `primary`, an identity preview, and the license text, a
    ///      collection of `%`, a seed, a dispute and a `LicenseRef` license with a locator.
    function _work(uint256 id, bytes memory json, bytes32 primary) internal {
        require(json.length <= limit, "record over the limit");
        MediaFile[] memory m = new MediaFile[](3);
        m[0] = MediaFile(primary, _sha(primary), FileRole.PRIMARY);
        m[1] = MediaFile(licenseText, _sha(licenseText), FileRole.AUXILIARY);
        m[2] = MediaFile(preview, _sha(preview), FileRole.PREVIEW);
        _installRawAt(id, json, m);
        IStream.WorkCore memory core = _core();
        core.collectionId = 1;
        core.serial = 9;
        core.seedPolicy = SeedPolicy.ARTIST;
        stream.setWork(id, core);
        records.setSeed(id, SeedPolicy.ARTIST, bytes32(uint256(1)));
        disputeLog.set(address(stream), id, bytes32(uint256(1)));
        records.setLicense(id, License("LicenseRef-Studio-1", licenseText));
        records.addLocator(id, licenseText, Locator(LocatorKind.ARWEAVE, "ar://licence"));
    }

    /// @dev A record at every cap: `name` (3 units), a description of `MAX_ESCAPES` `%` and then
    ///      `fill` up to the size limit (3 units), `MAX_ATTRIBUTES` attributes (2 + 1 + 5 each),
    ///      and the rest of the 1,024 units as `shape`.
    function _everyCap(bytes memory fill, uint256 shape) internal view returns (bytes memory) {
        uint256 rest = JsonScan.MAX_VALUES - 3 - 3 - 3 - 5 * MAX_ATTRIBUTES;
        bytes memory tail;
        if (shape == MEMBERS) {
            tail = _rep(',"a":0', rest / 3);
        } else if (shape == ZEROS) {
            tail = bytes.concat(',"a":[0', _rep(",0", rest - 3 - 1), "]");
        } else {
            tail = bytes.concat(',"a":{"b":0', _rep(',"b":0', (rest - 3) / 2 - 1), "}");
        }
        tail = bytes.concat('","attributes":[', _list(ATTR, MAX_ATTRIBUTES), "]", tail, "}");
        bytes memory open = bytes.concat('{"name":"N","description":"', _fill("%", MAX_ESCAPES));
        uint256 room = limit - open.length - tail.length;
        return bytes.concat(open, _fill(fill, room / fill.length * fill.length), tail);
    }

    function _primary(uint256 which) internal view returns (bytes32) {
        return which == P_HTML ? html : (which == P_SCRIPT_LT ? scriptLt : scriptU8);
    }

    /// @dev Work `100 * k + 10 * shape + primary`, k naming the fill.
    function _id(uint256 k, uint256 shape, uint256 primary) internal pure returns (uint256) {
        return 100 * k + 10 * shape + primary;
    }

    function _add(uint256 k, bytes memory fill, uint256 shape, uint256 primary) internal {
        _work(_id(k, shape, primary), _everyCap(fill, shape), _primary(primary));
    }

    // The fills: ASCII only; ASCII and a 3-byte sequence from E0 (the general path of the
    // validator before it was shortened); ASCII twice and a 2-byte one; ASCII and 4 bytes;
    // E0 alone; the 4-byte sequence alone; 2-byte alone.
    uint256 internal constant F_ASCII = 1;
    uint256 internal constant F_A_E0 = 2;
    uint256 internal constant F_AA_2B = 3;
    uint256 internal constant F_A_4B = 4;
    uint256 internal constant F_E0 = 5;
    uint256 internal constant F_4B = 6;
    uint256 internal constant F_2B = 7;
    uint256 internal constant F_ED = 8; // ED, the other lead with its own second-byte range

    function setUp() public override {
        super.setUp();
        relay = new TokenURIRelay(renderer, address(stream));
        limit = Limits.MAX_RECORD_BYTES;
        preview = _file(_data(PREVIEW_LIMIT / 8, 70), IDENTITY, "image/png");
        html = _file(
            bytes(Base64.encode(_data(renderer.inlineThreshold() / 4 * 3, 71))), BASE64, "text/html"
        );
        assertTrue(_attested(html));
        scriptLt = _file(
            bytes.concat(
                _fill("</script", 8 * MAX_SCRIPT_LT), _fill("a", SCRIPT_LIMIT - 8 * MAX_SCRIPT_LT)
            ),
            IDENTITY,
            "text/javascript"
        );
        scriptU8 = _file(_fill(hex"61e0a080", SCRIPT_LIMIT), IDENTITY, "text/javascript");
        licenseText = _file("The terms of the license.", IDENTITY, "text/plain");
        stream.setCollection(1, IStream.Collection(string(_fill("%", 256)), bytes32(0), 9));

        // Against 256 KiB of `Base64`: every fill, every shape.
        bytes[8] memory fills = [
            bytes("a"),
            hex"61e0a080",
            hex"6161c3a9",
            hex"61f09f9880",
            hex"e0a080",
            hex"f09f9880",
            hex"c3a9",
            hex"ed8080"
        ];
        for (uint256 f; f < fills.length; ++f) {
            _add(f + 1, fills[f], MEMBERS, P_HTML);
        }
        for (uint256 s = 1; s < 3; ++s) {
            _add(F_ASCII, "a", s, P_HTML);
            _add(F_A_E0, fills[1], s, P_HTML);
            _add(F_AA_2B, fills[2], s, P_HTML);
        }
        // Against the two scripts: the costliest fills in every shape.
        for (uint256 s; s < 3; ++s) {
            _add(F_A_E0, fills[1], s, P_SCRIPT_LT);
            _add(F_A_E0, fills[1], s, P_SCRIPT_U8);
            _add(F_AA_2B, fills[2], s, P_SCRIPT_U8);
            _add(F_A_4B, fills[3], s, P_SCRIPT_U8);
        }
    }

    function _cold(uint256 id) internal view returns (uint256 used, bool ok) {
        bytes memory callData = abi.encodeCall(TokenURIRelay.tokenURI, (id));
        address to = address(relay);
        assembly ("memory-safe") {
            let before := gas()
            ok := staticcall(gas(), to, add(callData, 0x20), mload(callData), 0, 0)
            used := sub(before, gas())
        }
    }

    /// @dev The cold gas of work `id`, which must be an accepted record, at most the budget.
    function _row(string memory label, uint256 id) internal {
        (uint256 used, bool ok) = _cold(id);
        emit log_named_uint(label, used);
        assertTrue(ok, label);
        assertLt(used, GAS_BUDGET, label);
        string memory j = _decode(renderer.tokenURI(address(stream), id));
        assertFalse(_has(j, ".record_status"), "an accepted record");
        assertEq(_str(j, ".name"), "N");
    }

    // ---------------------------------------------------------------- 256 KiB of `Base64`

    function test_Budget_Html_Members_Ascii() public {
        _row("every cap, members, ASCII, 256 KiB b64", _id(F_ASCII, MEMBERS, P_HTML));
    }

    function test_Budget_Html_Members_AsciiAndE0() public {
        _row("every cap, members, a+U+0800, 256 KiB b64", _id(F_A_E0, MEMBERS, P_HTML));
    }

    function test_Budget_Html_Members_TwoAsciiAndTwoByte() public {
        _row("every cap, members, aa+e, 256 KiB b64", _id(F_AA_2B, MEMBERS, P_HTML));
    }

    function test_Budget_Html_Members_AsciiAndFourByte() public {
        _row("every cap, members, a+4-byte, 256 KiB b64", _id(F_A_4B, MEMBERS, P_HTML));
    }

    function test_Budget_Html_Members_E0() public {
        _row("every cap, members, U+0800, 256 KiB b64", _id(F_E0, MEMBERS, P_HTML));
    }

    function test_Budget_Html_Members_FourByte() public {
        _row("every cap, members, 4-byte, 256 KiB b64", _id(F_4B, MEMBERS, P_HTML));
    }

    function test_Budget_Html_Members_TwoByte() public {
        _row("every cap, members, 2-byte, 256 KiB b64", _id(F_2B, MEMBERS, P_HTML));
    }

    function test_Budget_Html_Members_Ed() public {
        _row("every cap, members, U+D000 (ED), 256 KiB b64", _id(F_ED, MEMBERS, P_HTML));
    }

    function test_Budget_Html_Zeros_Ascii() public {
        _row("every cap, zeros, ASCII, 256 KiB b64", _id(F_ASCII, ZEROS, P_HTML));
    }

    function test_Budget_Html_Zeros_AsciiAndE0() public {
        _row("every cap, zeros, a+U+0800, 256 KiB b64", _id(F_A_E0, ZEROS, P_HTML));
    }

    function test_Budget_Html_Zeros_TwoAsciiAndTwoByte() public {
        _row("every cap, zeros, aa+e, 256 KiB b64", _id(F_AA_2B, ZEROS, P_HTML));
    }

    function test_Budget_Html_Nested_Ascii() public {
        _row("every cap, nested members, ASCII, 256 KiB b64", _id(F_ASCII, NESTED, P_HTML));
    }

    function test_Budget_Html_Nested_AsciiAndE0() public {
        _row("every cap, nested members, a+U+0800, 256 KiB b64", _id(F_A_E0, NESTED, P_HTML));
    }

    function test_Budget_Html_Nested_TwoAsciiAndTwoByte() public {
        _row("every cap, nested members, aa+e, 256 KiB b64", _id(F_AA_2B, NESTED, P_HTML));
    }

    // ---------------------------------------------------------------- the script of `</script`

    function test_Budget_ScriptLt_Members_AsciiAndE0() public {
        _row("every cap, members, a+U+0800, script of </script", _id(F_A_E0, MEMBERS, P_SCRIPT_LT));
    }

    function test_Budget_ScriptLt_Zeros_AsciiAndE0() public {
        _row("every cap, zeros, a+U+0800, script of </script", _id(F_A_E0, ZEROS, P_SCRIPT_LT));
    }

    function test_Budget_ScriptLt_Nested_AsciiAndE0() public {
        _row("every cap, nested, a+U+0800, script of </script", _id(F_A_E0, NESTED, P_SCRIPT_LT));
    }

    // ---------------------------------------------------------------- the script of a and U+0800

    function test_Budget_ScriptU8_Members_AsciiAndE0() public {
        _row("every cap, members, a+U+0800, script a+U+0800", _id(F_A_E0, MEMBERS, P_SCRIPT_U8));
    }

    function test_Budget_ScriptU8_Members_TwoAsciiAndTwoByte() public {
        _row("every cap, members, aa+e, script a+U+0800", _id(F_AA_2B, MEMBERS, P_SCRIPT_U8));
    }

    function test_Budget_ScriptU8_Members_AsciiAndFourByte() public {
        _row("every cap, members, a+4-byte, script a+U+0800", _id(F_A_4B, MEMBERS, P_SCRIPT_U8));
    }

    function test_Budget_ScriptU8_Zeros_AsciiAndE0() public {
        _row("every cap, zeros, a+U+0800, script a+U+0800", _id(F_A_E0, ZEROS, P_SCRIPT_U8));
    }

    function test_Budget_ScriptU8_Nested_AsciiAndE0() public {
        _row("every cap, nested, a+U+0800, script a+U+0800", _id(F_A_E0, NESTED, P_SCRIPT_U8));
    }

    // ---------------------------------------------------------------- the media alone

    /// @dev The script page alone, with the costliest script to validate: what the README says
    ///      the script costs.
    function test_Budget_TheScriptPageAlone() public {
        _work(999, '{"name":"N"}', scriptU8);
        (uint256 used, bool ok) = _cold(999);
        emit log_named_uint("minimal record, script a+U+0800", used);
        assertTrue(ok);
        assertLt(used, 3_500_000);
    }
}
