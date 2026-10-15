// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { RendererBase } from "./RendererBase.sol";
import { HtmlScript } from "src/content/HtmlScript.sol";
import { JsonScan } from "src/content/JsonScan.sol";
import { Utf8 } from "src/libraries/Utf8.sol";

/// @notice Differential tests of the renderer's text checks against oracles outside Solidity:
///         `tools/content/oracles.py` generates the vectors from a fixed seed into
///         `test/fixtures/oracles/` (read here, since vectors compiled into Solidity would take
///         minutes to build), and its `--check` mode, run by the tooling tests, keeps them
///         current. See that module for what decides each verdict.
contract RendererOraclesTest is RendererBase {
    bytes internal png = hex"89504e470d0a1a0a0000000d49484452";

    function _fixture(string memory name)
        internal
        view
        returns (bytes[] memory input, string memory json)
    {
        json = vm.readFile(string.concat("test/fixtures/oracles/", name, ".json"));
        input = vm.parseJsonBytesArray(json, ".input");
    }

    /// @dev Whatever `JsonScan.object` accepts, CPython's strict `json` accepts as an object.
    function test_JsonScanAcceptsOnlyStrictJsonObjects() public view {
        (bytes[] memory docs, string memory json) = _fixture("json");
        bool[] memory ok = vm.parseJsonBoolArray(json, ".expected");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = keccak256("name");
        uint256 accepted;
        for (uint256 i; i < docs.length; ++i) {
            (bool scanned,) = JsonScan.object(docs[i], keys);
            if (!scanned) continue;
            ++accepted;
            assertTrue(ok[i], string(docs[i]));
        }
        assertGt(accepted, 100, "the vectors reach accepted documents");
    }

    /// @dev `Utf8.isValid` agrees with CPython's strict UTF-8 decoder.
    function test_Utf8AgreesWithAStrictDecoder() public view {
        (bytes[] memory strings, string memory json) = _fixture("utf8");
        bool[] memory ok = vm.parseJsonBoolArray(json, ".expected");
        for (uint256 i; i < strings.length; ++i) {
            assertEq(Utf8.isValid(strings[i]), ok[i], vm.toString(strings[i]));
        }
    }

    /// @dev `HtmlScript.neutralize` gives, byte for byte, the output the oracle checked closes
    ///      the page's `<script>` element at the renderer's own `</script>`.
    function test_NeutralizeMatchesTheTokenizerCheckedMirror() public view {
        (bytes[] memory scripts, string memory json) = _fixture("html");
        bytes[] memory safe = vm.parseJsonBytesArray(json, ".expected");
        for (uint256 i; i < scripts.length; ++i) {
            (bool ok, string memory out) = HtmlScript.neutralize(string(scripts[i]), 1_024);
            assertTrue(ok);
            assertEq(bytes(out), safe[i], vm.toString(scripts[i]));
        }
    }

    /// @dev A record with each attribute name is accepted exactly when the trait-name rule says
    ///      so (CONTENT-5: printable ASCII, no backslash, no two spaces in a row, and not one of
    ///      the renderer's own names in any case or spacing).
    function test_TraitNamesFollowTheRule() public {
        (bytes[] memory names, string memory json) = _fixture("traits");
        bool[] memory ok = vm.parseJsonBoolArray(json, ".expected");
        bytes32 primary = _file(png, IDENTITY, "image/png");
        for (uint256 i; i < names.length; ++i) {
            bytes memory record = bytes.concat(
                '{"attributes":[{"trait_type":"', names[i], '","value":"v"}],"name":"N"}'
            );
            _installRaw(record, _media(primary, 0));
            assertEq(!_has(_out(), ".record_status"), ok[i], string(names[i]));
        }
    }
}
