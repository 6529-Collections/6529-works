// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DataUri } from "src/content/DataUri.sol";
import { HtmlScript } from "src/content/HtmlScript.sol";
import { JsonEscape } from "src/libraries/JsonEscape.sol";
import { Utf8 } from "src/libraries/Utf8.sol";
import { TextOracles } from "../helpers/TextOracles.sol";

/// @notice Halmos proofs for the text libraries against their naive byte-loop references
///         (docs/testing/README.md, "Symbolic").
/// @dev These libraries branch on every byte, so the number of paths grows with the input
///      length and most proofs are BOUNDED: every input of up to `MAX_*` bytes (all 2**(8n)
///      contents for each length n), not every input. The word-at-a-time fast paths of
///      `Utf8` and `JsonEscape` need at least 32 bytes and are not reached; the differential
///      fuzz tests in test/libraries and test/content/renderer cover them. The `DataUri` scan
///      is branch-free, so its proofs cover every content of a word (unbounded).
contract TextSymbolicTest is Test {
    /// @dev Longest inputs proved, per library. Chosen so the suite stays within the CI job.
    uint256 internal constant MAX_UTF8 = 4;
    uint256 internal constant MAX_ESCAPE = 4;
    uint256 internal constant MAX_SCRIPT = 10;
    uint256 internal constant MAX_HTML = 6;

    /// @dev The first `n` bytes of `w` as a fresh `bytes`.
    function _prefix(bytes32 w, uint256 n) internal pure returns (bytes memory b) {
        b = new bytes(n);
        assembly ("memory-safe") {
            mstore(add(b, 0x20), w)
            // Zero the bytes past `n` so the buffer is canonical.
            if lt(n, 32) { mstore(add(add(b, 0x20), n), 0) }
        }
    }

    function _slice(bytes memory b, uint256 from, uint256 to)
        internal
        pure
        returns (bytes memory s)
    {
        s = new bytes(to - from);
        for (uint256 i = from; i < to; ++i) {
            s[i - from] = b[i];
        }
    }

    // ---------------------------------------------------------------- UTF-8

    /// @notice `Utf8.isValid` agrees with the code-point decoding oracle on every input of up
    ///         to four bytes: every one-, two-, three- and four-byte sequence, well formed or
    ///         not, and every mix of shorter ones.
    function check_utf8_isValidMatchesTheOracle(bytes32 w) public pure {
        for (uint256 n; n <= MAX_UTF8; ++n) {
            bytes memory data = _prefix(w, n);
            assert(Utf8.isValid(data) == TextOracles.isValidUtf8(data));
        }
    }

    /// @notice Streaming: splitting any input of up to four bytes at any point and validating
    ///         the halves with the carried state gives the same verdict as validating the whole.
    function check_utf8_streamingAtEverySplitEqualsWhole(bytes32 w) public pure {
        for (uint256 n = 1; n <= MAX_UTF8; ++n) {
            bytes memory data = _prefix(w, n);
            bool whole = Utf8.isValid(data);
            for (uint256 k = 1; k < n; ++k) {
                (bool ok1, uint256 state) = Utf8.validate(0, _slice(data, 0, k));
                bool streamed;
                if (ok1) {
                    (bool ok2, uint256 next) = Utf8.validate(state, _slice(data, k, n));
                    streamed = ok2 && next == 0;
                }
                assert(streamed == whole);
            }
        }
    }

    /// @notice A state that `validate` returns is always one it accepts back: zero, or a
    ///         partial sequence with one to three continuations due in a sane range.
    function check_utf8_returnedStatesAreWellFormed(bytes32 w) public pure {
        for (uint256 n = 1; n <= MAX_UTF8; ++n) {
            (bool ok, uint256 state) = Utf8.validate(0, _prefix(w, n));
            if (!ok) {
                assert(state == 0);
                continue;
            }
            if (state == 0) continue;
            uint256 due = state & 0xff;
            uint256 lo = (state >> 8) & 0xff;
            uint256 hi = state >> 16;
            assert(due >= 1 && due <= 3 && lo >= 0x80 && hi <= 0xbf && lo <= hi);
            // Accepted back: an empty chunk keeps the state.
            (bool again, uint256 same) = Utf8.validate(state, "");
            assert(again && same == state);
        }
    }

    // ---------------------------------------------------------------- JSON escaping

    /// @notice `JsonEscape.escape` equals the byte-loop oracle on every input of up to four
    ///         bytes, and returns the input itself when nothing needs escaping.
    function check_jsonEscape_matchesTheOracle(bytes32 w) public pure {
        for (uint256 n; n <= MAX_ESCAPE; ++n) {
            bytes memory raw = _prefix(w, n);
            string memory out = JsonEscape.escape(string(raw));
            bytes memory expected = TextOracles.escape(raw);
            assert(keccak256(bytes(out)) == keccak256(expected));
            if (expected.length == n) {
                bool same;
                assembly ("memory-safe") {
                    same := eq(out, raw)
                }
                assert(same);
            }
        }
    }

    /// @notice `JsonEscape.scriptText` equals the oracle on every input of 8 to 10 bytes, the
    ///         lengths where a `</script` (any case) fits once or overlaps the ends.
    function check_jsonScriptText_matchesTheOracle(bytes32 w) public pure {
        for (uint256 n = 8; n <= MAX_SCRIPT; ++n) {
            bytes memory raw = _prefix(w, n);
            string memory out = JsonEscape.scriptText(string(raw));
            assert(keccak256(bytes(out)) == keccak256(TextOracles.scriptText(raw)));
        }
    }

    // ---------------------------------------------------------------- data: URI percent

    /// @dev Whether `DataUri.escape` with a cap of zero accepts the first `n` bytes of `w`, and
    ///      whether those bytes hold a `%` or a `#` (counted one byte at a time, branch-free).
    function _percentFree(bytes32 w, uint256 n) internal pure returns (bool accepted, bool clean) {
        bytes memory raw = _prefix(w, n);
        uint256 hits;
        for (uint256 i; i < n; ++i) {
            uint8 b = uint8(raw[i]);
            assembly ("memory-safe") {
                hits := add(hits, or(eq(b, 0x25), eq(b, 0x23)))
            }
        }
        string memory out;
        (accepted, out) = DataUri.escape(string(raw), 0);
        clean = hits == 0;
        bool same;
        assembly ("memory-safe") {
            same := eq(out, raw)
        }
        assert(same); // refused or clean: the input itself comes back
    }

    /// @notice `DataUri.escape` finds a `%` or a `#` wherever one is in a word: with a cap of
    ///         zero, a full 32-byte word is accepted exactly when it holds neither. Unbounded
    ///         over the 2**256 words; this is the word-at-a-time scan and its byte count.
    /// @dev The rewriting itself is not proved here: its output length comes from the hit count,
    ///      one symbolic value, and Halmos cannot place memory at a symbolic offset. The
    ///      differential fuzz tests in test/content/renderer/TextHelpers.t.sol cover it, and
    ///      longer texts.
    function check_dataUri_findsEveryHitInAWord(bytes32 w) public pure {
        (bool accepted, bool clean) = _percentFree(w, 32);
        assert(accepted == clean);
    }

    /// @notice The same for 31 bytes, where the scan must ignore the byte past the end.
    function check_dataUri_ignoresTheBytesPastTheEnd(bytes32 w) public pure {
        (bool accepted, bool clean) = _percentFree(w, 31);
        assert(accepted == clean);
    }

    // ---------------------------------------------------------------- <script> text

    /// @dev Naive reference for `HtmlScript.neutralize` with no cap.
    function _neutralize(bytes memory s) internal pure returns (bytes memory out) {
        out = new bytes(s.length * 2);
        uint256 j;
        for (uint256 i; i < s.length; ++i) {
            out[j++] = s[i];
            if (s[i] == "<") {
                bool comment =
                    i + 4 <= s.length && s[i + 1] == "!" && s[i + 2] == "-" && s[i + 3] == "-";
                if (comment || TextOracles.isEndTagAt(s, i)) out[j++] = "\\";
            }
        }
        assembly ("memory-safe") {
            mstore(out, j)
        }
    }

    /// @notice `HtmlScript.neutralize` equals the reference on every input of 4 to 6 bytes
    ///         (every placement of `<!--` among other bytes), and its `<` cap refuses exactly
    ///         the inputs with more `<` than the cap.
    function check_htmlScript_matchesTheReference(bytes32 w, uint256 maxLt) public pure {
        for (uint256 n = 4; n <= MAX_HTML; ++n) {
            bytes memory raw = _prefix(w, n);
            uint256 lts;
            for (uint256 i; i < n; ++i) {
                if (raw[i] == "<") ++lts;
            }
            (bool ok, string memory out) = HtmlScript.neutralize(string(raw), maxLt);
            assert(ok == (lts <= maxLt));
            if (ok) assert(keccak256(bytes(out)) == keccak256(_neutralize(raw)));
        }
    }

    /// @notice An end tag is caught in every case mix and with anything after it: every input
    ///         of 8 to 10 bytes that starts with `</` and holds no other `<`.
    function check_htmlScript_endTagInAnyCase(bytes32 w) public pure {
        for (uint256 n = 8; n <= MAX_SCRIPT; ++n) {
            bytes memory raw = _prefix(w, n);
            raw[0] = "<";
            raw[1] = "/";
            for (uint256 i = 2; i < n; ++i) {
                vm.assume(raw[i] != "<");
            }
            (bool ok, string memory out) = HtmlScript.neutralize(string(raw), 1);
            assert(ok);
            assert(keccak256(bytes(out)) == keccak256(_neutralize(raw)));
        }
    }
}
