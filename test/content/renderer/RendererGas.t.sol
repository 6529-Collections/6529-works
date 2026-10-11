// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { RendererBase } from "./RendererBase.sol";
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
        bytes memory js = new bytes(renderer.SCRIPT_LIMIT());
        for (uint256 i; i < js.length; ++i) {
            js[i] = i % 64 == 63 ? bytes1("\n") : bytes1("a");
        }
        uint256 used = _compact(relay, _file(js, IDENTITY, "text/javascript"));
        emit log_named_uint("script page, SCRIPT_LIMIT bytes", used);
        assertLt(used, GAS_BUDGET);
    }

    /// @dev Scripts made only of what the neutralizer looks for: the slowest inputs.
    function test_ScriptPageOfNothingButTheDangerousStarts() public {
        bytes[4] memory unit = [bytes("<"), "</", "<!-", "</scrip"];
        for (uint256 u; u < unit.length; ++u) {
            bytes memory js = new bytes(renderer.SCRIPT_LIMIT());
            for (uint256 i; i < js.length; ++i) {
                js[i] = unit[u][i % unit[u].length];
            }
            uint256 used = _compact(relay, _file(js, IDENTITY, "text/javascript"));
            emit log_named_uint(string.concat("script page, repeating ", string(unit[u])), used);
            assertLt(used, GAS_BUDGET);
        }
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
///      so each test starts with cold storage and cold accounts, as an `eth_call` does. Records
///      are built to the limits the renderer enforces (`JsonScan.MAX_VALUES` values, `MAX_ESCAPES`
///      escapes, one chunk), and each is paired with the costliest media: a base64 text/html
///      primary at the full threshold and an identity preview at its limit. Run with `-vv`.
contract RendererGasAdversarialTest is RendererBase {
    uint256 internal constant GAS_BUDGET = 8_000_000;
    // Accepted records, each at one of the limits.
    uint256 internal constant W_VALUES = 11; // the most values, in an ignored array of zeros
    uint256 internal constant W_MEMBERS = 12; // the most values, as members of the top-level object
    uint256 internal constant W_ATTRS = 13; // the most attributes, and the rest of the values
    uint256 internal constant W_ESCAPES = 14; // the most `%` the record may hold, in text of 24 KiB
    uint256 internal constant W_SCRIPT = 15; // a script of `</scrip`, a `%` record, everything
    // Refused records: arrays of tiny values, members of nothing, `\u0000` escapes, more
    // attributes than allowed, and `%` past the cap.
    uint256 internal constant W_BOMB_ARRAY = 21;
    uint256 internal constant W_BOMB_ATTRS = 22;
    uint256 internal constant W_BOMB_EMPTY = 23;
    uint256 internal constant W_BOMB_MEMBERS = 24;
    uint256 internal constant W_BOMB_KEYS = 25;
    uint256 internal constant W_BOMB_NUL = 26;
    uint256 internal constant W_BOMB_PERCENT = 27;
    uint256 internal constant W_TOO_MANY_ATTRS = 28;

    TokenURIRelay internal relay;
    bytes32 internal html;
    bytes32 internal preview;
    bytes32 internal licenseText;

    function _fill(bytes memory unit, uint256 n) internal pure returns (bytes memory j) {
        j = new bytes(n);
        for (uint256 i; i < n; ++i) {
            j[i] = unit[i % unit.length];
        }
    }

    /// @dev `open`, then `unit` as many times as fit in a record (without its last comma), then
    ///      `close`.
    function _bomb(bytes memory open, bytes memory unit, bytes memory close)
        internal
        view
        returns (bytes memory j)
    {
        uint256 n = (renderer.MAX_RECORD_BYTES() - open.length - close.length) / unit.length;
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

    function setUp() public override {
        super.setUp();
        relay = new TokenURIRelay(renderer, address(stream));
        preview = _file(_data(renderer.PREVIEW_LIMIT() / 8, 70), IDENTITY, "image/png");
        html = _file(
            bytes(Base64.encode(_data(renderer.inlineThreshold() / 4 * 3, 71))), BASE64, "text/html"
        );
        bytes32 tiny = _file(hex"89504e47", IDENTITY, "image/png");
        licenseText = _file("The terms of the license.", IDENTITY, "text/plain");
        // A collection whose name is all `%`, which the renderer escapes.
        stream.setCollection(1, IStream.Collection(string(_fill("%", 256)), bytes32(0), 9));

        // A valid record with as many values as it may hold: the root object, `name`, and an
        // ignored array of 1,022 zeros.
        _members(
            W_VALUES,
            bytes.concat('{"name":"N","a":[', _fill("0,", 2 * (JsonScan.MAX_VALUES - 3)), "0]}"),
            html,
            preview
        );
        // The same, as 1,023 members of the top-level object, which the scanner also hashes.
        _members(
            W_MEMBERS,
            bytes.concat('{"name":"N"', _fill(',"a":0', 6 * (JsonScan.MAX_VALUES - 1)), "}"),
            html,
            preview
        );
        // The most attributes (each is an object and two values), and the rest of the values in an
        // ignored array: 1 + 1 + 3 * 128 + 1 + 637 = 1,024.
        uint256 attrs = renderer.MAX_ATTRIBUTES();
        _members(
            W_ATTRS,
            bytes.concat(
                '{"name":"N","a":[0',
                _fill(",0", 2 * (JsonScan.MAX_VALUES - 2 - 3 * attrs - 2)),
                '],"attributes":[',
                _fill('{"trait_type":"k","value":1},', 29 * (attrs - 1)),
                '{"trait_type":"k","value":1}]}'
            ),
            html,
            preview
        );
        // Text of 24 KiB with the most `%` the record may hold, which the renderer escapes.
        bytes memory open = '{"name":"N","description":"';
        _members(
            W_ESCAPES,
            bytes.concat(
                open,
                _fill("%", renderer.MAX_ESCAPES()),
                _fill("a", renderer.MAX_RECORD_BYTES() - open.length - 2 - renderer.MAX_ESCAPES()),
                '"}'
            ),
            html,
            preview
        );
        // The slowest script (every byte a candidate for the neutralizer), a record of `%`, a
        // collection with `%` in its name, a seed, a dispute and a license text.
        bytes32 js = _file(_fill("</scrip", renderer.SCRIPT_LIMIT()), IDENTITY, "text/javascript");
        _members(
            W_SCRIPT,
            bytes.concat(open, _fill("%", renderer.MAX_ESCAPES()), _fill("a", 1_000), '"}'),
            js,
            preview
        );

        // Records the renderer refuses: each must cost little.
        _members(W_BOMB_ARRAY, _bomb('{"name":"N","a":[', "0,", "]}"), tiny, 0);
        _members(W_BOMB_ATTRS, _bomb('{"name":"N","attributes":[', "0,", "]}"), tiny, 0);
        _members(W_BOMB_EMPTY, _bomb('{"name":"N","a":[', "[],", "]}"), tiny, 0);
        _members(W_BOMB_MEMBERS, _bomb('{"name":"N",', '"a":0,', "}"), tiny, 0);
        _members(W_BOMB_KEYS, _bomb('{"name":"N",', '"":0,', "}"), tiny, 0);
        _members(W_BOMB_NUL, _bomb('{"name":"N","a":"', "\\u0000,", '"}'), tiny, 0);
        _members(
            W_TOO_MANY_ATTRS,
            bytes.concat(
                '{"name":"N","attributes":[',
                _fill('{"trait_type":"k","value":1},', 29 * attrs),
                '{"trait_type":"k","value":1}]}'
            ),
            html,
            preview
        );
        _members(
            W_BOMB_PERCENT,
            bytes.concat(open, _fill("%", renderer.MAX_RECORD_BYTES() - open.length - 2), '"}'),
            html,
            preview
        );
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

    function _row(string memory label, uint256 id) internal returns (string memory j) {
        (uint256 used, bool ok) = _cold(id);
        emit log_named_uint(label, used);
        assertTrue(ok, label);
        assertLt(used, GAS_BUDGET, label);
        j = _decode(renderer.tokenURI(address(stream), id));
    }

    function test_Gas_ARecordWithTheMostValues() public {
        string memory j = _row("1,024 values + 256 KiB primary + preview", W_VALUES);
        assertEq(_str(j, ".name"), "N", "an accepted record");
        assertFalse(_has(j, ".record_status"));
    }

    function test_Gas_ARecordWithTheMostMembers() public {
        string memory j = _row("1,024 members + 256 KiB primary + preview", W_MEMBERS);
        assertEq(_str(j, ".name"), "N", "an accepted record");
        assertFalse(_has(j, ".record_status"));
    }

    function test_Gas_ARecordWithTheMostAttributes() public {
        string memory j = _row("128 attributes + 637 zeros + primary + preview", W_ATTRS);
        assertEq(_str(j, ".name"), "N", "an accepted record");
        // The renderer's own traits come first, then the record's 128.
        uint256 first = _attrIndex(j, "k");
        assertEq(_str(j, _at(first + 127, ".trait_type")), "k");
        assertFalse(_has(j, _at(first + 128, "")));
    }

    function test_Gas_ARecordWithTheMostEscapes() public {
        string memory j = _row("2,048 escapes + 24 KiB text + primary + preview", W_ESCAPES);
        assertEq(_str(j, ".name"), "N", "an accepted record");
    }

    function test_Gas_ScriptAndEverythingElse() public {
        string memory j = _row("script </scrip + % record + preview + traits", W_SCRIPT);
        assertEq(_str(j, ".name"), "N", "an accepted record");
    }

    function test_Gas_RefusedRecordsAreCheap() public {
        uint256[8] memory ids = [
            W_BOMB_ARRAY,
            W_BOMB_ATTRS,
            W_BOMB_EMPTY,
            W_BOMB_MEMBERS,
            W_BOMB_KEYS,
            W_BOMB_NUL,
            W_BOMB_PERCENT,
            W_TOO_MANY_ATTRS
        ];
        string[8] memory labels = [
            "refused: array of 0",
            "refused: attributes array of 0",
            "refused: array of []",
            "refused: members a:0",
            "refused: members \"\":0",
            "refused: \\u0000 escapes",
            "refused: 24 KiB of %",
            "refused: 129 attributes"
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
