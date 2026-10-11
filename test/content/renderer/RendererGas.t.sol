// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { RendererBase } from "./RendererBase.sol";
import { Renderer } from "src/content/Renderer.sol";
import { IRenderer } from "src/interfaces/IRenderer.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { Rec, Trait } from "./RendererBase.sol";
import { Locator, LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";

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

    /// @dev The most expensive `tokenURI` the renderer produces: a non-image primary at the full
    ///      threshold, an on-chain preview at its limit, a maximal record, a collection, a seed,
    ///      a dispute and a license with its own locator.
    function test_WorstCaseCombination() public {
        // A text/html primary stored as base64 at the full threshold, and the costliest preview:
        // an identity image at the preview limit.
        bytes32 html = _file(
            bytes(Base64.encode(_data(renderer.inlineThreshold() / 4 * 3, 71))), BASE64, "text/html"
        );
        bytes32 preview = _file(_data(renderer.PREVIEW_LIMIT() / 8, 70), IDENTITY, "image/png");
        Rec memory r = _rec();
        r.artists = new string[](16);
        for (uint256 i; i < 16; ++i) {
            r.artists[i] = _text(64);
        }
        r.attributes = new Trait[](64);
        for (uint256 i; i < 64; ++i) {
            r.attributes[i] = Trait(_text(24), _text(64));
        }
        r.description = "";
        r.description = _text(CHUNK - _json(r).length);
        _install(html, preview, r);
        IStream.WorkCore memory core = _core();
        core.collectionId = 1;
        core.serial = 9;
        core.seedPolicy = SeedPolicy.ARTIST;
        stream.setWork(ID, core);
        stream.setCollection(1, IStream.Collection("A collection", bytes32(0), 9));
        records.setSeed(ID, SeedPolicy.ARTIST, bytes32(uint256(1)));
        bytes32 text = _file("licence", IDENTITY, "text/plain");
        records.setLicense(ID, License("LicenseRef-Studio-1", text));
        records.addLocator(ID, text, Locator(LocatorKind.ARWEAVE, "ar://licence"));
        disputeLog.set(address(stream), ID, bytes32(uint256(1)));

        uint256 used = _gas(relay, abi.encodeCall(TokenURIRelay.tokenURI, (ID)));

        emit log_named_uint("worst case", used);
        assertLt(used, GAS_BUDGET);
    }

    function test_OverTheThresholdIsCheap() public {
        bytes32 file = _file(_data(THRESHOLD + 1, 99), IDENTITY, "image/png");
        _install(file);
        records.addLocator(ID, file, Locator(LocatorKind.IPFS, "ipfs://bafy"));
        uint256 used = _gas(relay, abi.encodeCall(TokenURIRelay.tokenURI, (ID)));
        emit log_named_uint("locator only", used);
        assertLt(used, 1_500_000);
    }

    /// @dev `fullTokenURI` is an off-chain view with no 8M promise; its cost is reported.
    function test_FullForm() public {
        uint256[3] memory full = [uint256(262_144), 524_288, 1_048_576];
        for (uint256 i; i < 3; ++i) {
            bytes memory media = _data(full[i] / 4 * 3, 50 + i);
            _install(_file(bytes(Base64.encode(media)), BASE64, "image/png"));
            uint256 used = _gas(relay, abi.encodeCall(TokenURIRelay.fullTokenURI, (ID)));
            emit log_named_uint(string.concat("fullTokenURI base64 ", vm.toString(full[i])), used);
        }
    }

    function _text(uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = bytes1(uint8(97 + (i % 26)));
        }
        return string(b);
    }
}
