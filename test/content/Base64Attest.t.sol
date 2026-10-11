// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { ContentBase } from "./ContentBase.sol";
import { Base64Validator } from "src/content/Base64Validator.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";

/// @dev Shared text builders for the base64 tests.
abstract contract Base64Base is ContentBase {
    IContentStore.Encoding internal constant B64 = IContentStore.Encoding.Base64;
    IContentStore.Encoding internal constant GZB64 = IContentStore.Encoding.GzipBase64;
    /// @dev EIP-7825 (Fusaka): no transaction may use more gas than this.
    uint256 internal constant TX_GAS_CAP = 16_777_216;
    bytes internal constant ALPHABET =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    /// @dev The scalar definition of the alphabet, written differently from the validator.
    function _inAlphabet(uint8 b) internal pure returns (bool) {
        return (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39)
            || b == 0x2b || b == 0x2f;
    }

    /// @dev Pseudo-random base64 text of `length` bytes, then `pad` bytes of `=` at the end.
    function _text(uint256 length, uint256 pad, uint256 seed)
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(length);
        bytes memory alphabet = ALPHABET; // a constant is copied to memory on every use
        uint256 word;
        for (uint256 i; i < length - pad; ++i) {
            // One hash per 32 bytes: memory is never freed, so a hash per byte would grow it.
            if (i % 32 == 0) word = uint256(keccak256(abi.encode(seed, i / 32)));
            out[i] = alphabet[(word >> ((i % 32) * 8)) & 63];
        }
        for (uint256 i = length - pad; i < length; ++i) {
            out[i] = "=";
        }
    }

    /// @dev Fast text for large fixtures: the alphabet repeated, rotated by `seed` (so seeds 0 to
    ///      63 give distinct chunks).
    function _rotating(uint256 length, uint256 seed) internal pure returns (bytes memory out) {
        out = new bytes(length);
        bytes memory alphabet = ALPHABET;
        for (uint256 i; i < length; ++i) {
            out[i] = alphabet[(i + seed) & 63];
        }
    }

    function _attest(bytes32 fileId) internal returns (bool) {
        return store.attestBase64(fileId);
    }

    /// @dev Transaction gas of one `attestBase64` call: execution + 21,000 + calldata.
    function _attestTxGas(bytes32 fileId) internal returns (uint256 txGas) {
        bytes memory callData = abi.encodeCall(store.attestBase64, (fileId));
        txGas = 21_000 + _calldataGas(callData) + _gasOf(callData);
    }
}

/// @dev The word-at-a-time validator on its own: exhaustive over byte values and lane positions.
contract Base64ValidatorTest is Base64Base {
    function test_EveryByteValueInEveryLane() public pure {
        for (uint256 v; v < 256; ++v) {
            for (uint256 lane; lane < 32; ++lane) {
                bytes memory buf = _filled(32, "A");
                buf[lane] = bytes1(uint8(v));
                assertEq(
                    Base64Validator.isAlphabet(buf, 32), _inAlphabet(uint8(v)), "byte and lane"
                );
            }
        }
    }

    function test_EveryByteValueInEveryLaneOfASecondWord() public pure {
        for (uint256 v; v < 256; ++v) {
            for (uint256 lane = 32; lane < 64; ++lane) {
                bytes memory buf = _filled(64, "z");
                buf[lane] = bytes1(uint8(v));
                assertEq(Base64Validator.isAlphabet(buf, 64), _inAlphabet(uint8(v)));
            }
        }
    }

    /// @dev Carries and borrows move at most one lane, so every ordered pair of adjacent bytes,
    ///      at the start of a word and across a word boundary, covers every interaction.
    function test_EveryAdjacentPairOfBytes() public pure {
        // The buffers are reused (memory is never freed) and are whole words, so the validator
        // does not touch them.
        bytes memory inWord = _filled(32, "A");
        bytes memory acrossWords = _filled(64, "z");
        for (uint256 pair; pair < 65_536; ++pair) {
            bytes1 first = bytes1(uint8(pair >> 8));
            bytes1 second = bytes1(uint8(pair));
            bool expected = _inAlphabet(uint8(first)) && _inAlphabet(uint8(second));

            inWord[0] = first;
            inWord[1] = second;
            assertEq(Base64Validator.isAlphabet(inWord, 32), expected, "pair in a word");

            acrossWords[31] = first;
            acrossWords[32] = second;
            assertEq(Base64Validator.isAlphabet(acrossWords, 64), expected, "pair across words");
        }
    }

    function test_AlphabetAndNearMisses() public pure {
        // Every valid byte passes, every byte just outside each range fails.
        for (uint256 v; v < 256; ++v) {
            bytes memory buf = _filled(1, bytes1(uint8(v)));
            assertEq(Base64Validator.isAlphabet(buf, 1), _inAlphabet(uint8(v)));
        }
        assertTrue(Base64Validator.isAlphabet(ALPHABET, 64));
    }

    function test_OnlyTheCheckedPrefixCounts() public pure {
        // A bad byte at or after `length` is ignored, whatever the length mod 32; a bad byte
        // before it is not. 0xff and "=" are the two worst cases: invalid, and a lane carry.
        bytes1[2] memory bad = [bytes1(0xff), bytes1("=")];
        for (uint256 b; b < 2; ++b) {
            for (uint256 length; length <= 70; ++length) {
                for (uint256 position; position < 80; ++position) {
                    bytes memory buf = _filled(80, "A");
                    buf[position] = bad[b];
                    assertEq(Base64Validator.isAlphabet(buf, length), position >= length);
                }
            }
        }
    }

    function test_ZeroLengthIsValid() public pure {
        assertTrue(Base64Validator.isAlphabet(hex"ff", 0));
        assertTrue(Base64Validator.isAlphabet("", 0));
    }

    function test_BytesBeforeLengthAreLeftAlone() public pure {
        bytes memory buf = _text(50, 0, 1);
        bytes memory copy = _slice(buf, 0, 50);
        assertTrue(Base64Validator.isAlphabet(buf, 37));
        assertEq(_slice(buf, 0, 37), _slice(copy, 0, 37));
    }

    function testFuzz_ValidTextIsAccepted(uint256 length, uint256 seed) public pure {
        length = bound(length, 0, 4000);
        bytes memory text = _text(length, 0, seed);
        assertTrue(Base64Validator.isAlphabet(text, length));
    }

    function testFuzz_OneInjectedByteMatchesTheOracle(
        uint256 length,
        uint256 seed,
        uint256 position,
        uint8 value
    ) public pure {
        length = bound(length, 1, 4000);
        position = bound(position, 0, length - 1);
        bytes memory text = _text(length, 0, seed);
        text[position] = bytes1(value);
        assertEq(Base64Validator.isAlphabet(text, length), _inAlphabet(value));
    }

    function testFuzz_ArbitraryBytesMatchTheOracle(bytes memory raw, uint256 length) public pure {
        length = bound(length, 0, raw.length);
        bool expected = true;
        for (uint256 i; i < length; ++i) {
            if (!_inAlphabet(uint8(raw[i]))) expected = false;
        }
        assertEq(Base64Validator.isAlphabet(raw, length), expected);
    }

    function _filled(uint256 length, bytes1 value) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = value;
        }
    }
}

/// @dev `attestBase64` on the store: valid files, every kind of invalid byte, encodings,
///      incomplete files, idempotence and the per-call chunk limit.
contract Base64AttestTest is Base64Base {
    function setUp() public {
        store = new ContentStore();
    }

    // ---------------------------------------------------------------- valid files

    function test_Attest_SingleChunk() public {
        bytes memory file = _text(1000, 0, 1);
        bytes32 fileId = _publish(file, B64, "image/png");
        assertFalse(store.isBase64Attested(fileId));

        vm.expectEmit(true, false, false, true, address(store));
        emit IContentStore.Base64Attested(fileId);
        assertTrue(_attest(fileId));

        assertTrue(store.isBase64Attested(fileId));
        assertEq(store.fileInfo(fileId).length, 1000, "the file itself is untouched");
        assertEq(store.read(fileId, 0, 1000), file);
    }

    function test_Attest_GzipBase64IsAttestedToo() public {
        bytes32 fileId = _publish(_text(64, 0, 2), GZB64, "text/javascript");
        assertTrue(_attest(fileId));
        assertTrue(store.isBase64Attested(fileId));
    }

    function test_Attest_MultiChunk() public {
        // 24,575 + 24,575 + 2 = 49,152 bytes, a multiple of 4.
        bytes memory file = _text(2 * CHUNK + 2, 0, 3);
        bytes32 fileId = _publish(file, B64, "image/png");
        assertTrue(_attest(fileId));
        assertTrue(store.isBase64Attested(fileId));
    }

    function test_Attest_PaddingInASingleChunk() public {
        for (uint256 pad; pad <= 2; ++pad) {
            bytes32 fileId = _publish(_text(12, pad, 10 + pad), B64, "image/png");
            assertTrue(_attest(fileId), "pad");
        }
        // The smallest files: one group.
        assertTrue(_attest(_publish("AAAA", B64, "image/png")));
        assertTrue(_attest(_publish("AAA=", B64, "image/png")));
        assertTrue(_attest(_publish("AA==", B64, "image/png")));
        assertTrue(_attest(_publish("+/+/", B64, "image/png")));
    }

    function test_Attest_PaddingAcrossTheChunkBoundary() public {
        // 24,575 + 1 = 24,576 bytes: the last chunk is one byte, so "==" spans two chunks.
        for (uint256 pad; pad <= 2; ++pad) {
            bytes memory file = _text(CHUNK + 1, pad, 20 + pad);
            assertEq(file.length % 4, 0);
            bytes32 fileId = _publish(file, B64, "image/png");
            assertTrue(_attest(fileId), "valid padding across chunks");
        }
        // The same shape with 2 bytes in the last chunk (3 chunks: 2 * 24,575 + 2).
        for (uint256 pad; pad <= 2; ++pad) {
            bytes32 fileId = _publish(_text(2 * CHUNK + 2, pad, 30 + pad), B64, "image/png");
            assertTrue(_attest(fileId));
        }
    }

    function testFuzz_Attest_ValidFiles(uint256 groups, uint256 pad, uint256 seed, bool gzip)
        public
    {
        // Up to three chunks and a bit, every length a multiple of 4, every padding.
        uint256 total = 4 * bound(groups, 1, (3 * CHUNK + 40) / 4);
        pad = bound(pad, 0, 2);
        bytes32 fileId = _publish(_text(total, pad, seed), gzip ? GZB64 : B64, "image/png");
        assertTrue(_attest(fileId));
        assertTrue(store.isBase64Attested(fileId));
    }

    function testFuzz_Attest_AnyoneMayCall(address caller) public {
        bytes32 fileId = _publish(_text(100, 0, 5), B64, "image/png");
        vm.prank(caller);
        assertTrue(store.attestBase64(fileId));
    }

    // ---------------------------------------------------------------- invalid bytes

    function test_Attest_RejectsEveryInvalidByteClass() public {
        // Quote, backslash, percent, hash, markup, controls, DEL, high bytes, URL-safe
        // characters, "=" in the middle, and the neighbours of every range boundary.
        bytes memory bad = hex"225c25233c3e26277b7d2c3a2d5f20000a0d091f7f80ff3d2e5b60407e2a3b7c";
        uint256[8] memory positions = [uint256(0), 1, 31, 32, 63, 500, 997, 998];
        for (uint256 b; b < bad.length; ++b) {
            for (uint256 p; p < positions.length; ++p) {
                bytes memory file = _text(1000, 0, 40);
                file[positions[p]] = bad[b];
                bytes32 fileId = _publish(file, B64, "image/png");
                vm.expectRevert(
                    abi.encodeWithSelector(IContentStore.ContentBase64Invalid.selector, fileId, 0)
                );
                _attest(fileId);
                assertFalse(store.isBase64Attested(fileId));
            }
        }
    }

    function test_Attest_RejectsEqualsWhereverItIsNotTheLastOneOrTwoBytes() public {
        // Valid: "=" and "==" as the file's last bytes. Invalid: everywhere else.
        string[5] memory good = ["AAA=", "AA==", "QUJD", "AAAAAAA=", "AAAAAA=="];
        for (uint256 i; i < good.length; ++i) {
            assertTrue(_attest(_publish(bytes(good[i]), B64, "image/png")), good[i]);
        }
        string[12] memory bad = [
            "AA=A",
            "A=AA",
            "=AAA",
            "A===",
            "====",
            "AAA==",
            "AAAA=AAA",
            "AAAA==AA",
            "AAAA=A==",
            "=AAAAAAA",
            "AAAAAA=A",
            "AAAAA==="
        ];
        for (uint256 i; i < bad.length; ++i) {
            bytes memory file = bytes(bad[i]);
            if (file.length % 4 != 0) continue; // "AAA==" is covered by the length test
            bytes32 fileId = _publish(file, B64, "image/png");
            vm.expectRevert(
                abi.encodeWithSelector(IContentStore.ContentBase64Invalid.selector, fileId, 0)
            );
            _attest(fileId);
        }
    }

    function test_Attest_PaddingBeforeTheEndIsRejectedAcrossChunks() public {
        // A "=" at the end of chunk 0 is padding only if the file ends right after it.
        bytes memory file = _text(CHUNK + 1, 0, 50);
        file[CHUNK - 1] = "=";
        bytes32 fileId = _publish(file, B64, "image/png");
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentBase64Invalid.selector, fileId, 0)
        );
        _attest(fileId);

        // Three padding bytes are one too many.
        file = _text(CHUNK + 1, 2, 51);
        file[CHUNK - 2] = "=";
        fileId = _publish(file, B64, "image/png");
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentBase64Invalid.selector, fileId, 0)
        );
        _attest(fileId);
    }

    function test_Attest_PaddingDoesNotHideABadByteBeforeIt() public {
        // The bad byte sits right before the padding, or one further in: a quote, an "=" and a
        // byte with the high bit set.
        bytes1[3] memory bad = [bytes1(0x22), bytes1("="), bytes1(0xff)];
        for (uint256 b; b < 3; ++b) {
            for (uint256 pad = 1; pad <= 2; ++pad) {
                for (uint256 back = 1; back <= 2; ++back) {
                    // "=" one byte before a single "=" makes a valid "==" instead.
                    if (bad[b] == "=" && pad == 1 && back == 1) continue;
                    bytes memory file = _text(100, pad, 300 + b);
                    file[100 - pad - back] = bad[b];
                    bytes32 fileId = _publish(file, B64, "image/png");
                    vm.expectRevert(
                        abi.encodeWithSelector(
                            IContentStore.ContentBase64Invalid.selector, fileId, 0
                        )
                    );
                    _attest(fileId);
                }
            }
        }
    }

    function test_Attest_PaddingDoesNotHideABadByteAcrossTheChunkBoundary() public {
        // Two chunks, the last one byte long: the padding straddles the boundary, and the bad
        // byte is the last byte of chunk 0 (before a single "=") or the one before it.
        bytes1[2] memory bad = [bytes1(0x22), bytes1(0xff)];
        for (uint256 b; b < 2; ++b) {
            bytes memory file = _text(CHUNK + 1, 1, 400 + b);
            file[CHUNK - 1] = bad[b];
            bytes32 fileId = _publish(file, B64, "image/png");
            vm.expectRevert(
                abi.encodeWithSelector(IContentStore.ContentBase64Invalid.selector, fileId, 0)
            );
            _attest(fileId);

            // "==" across the boundary: the byte before both "=" is bad.
            file = _text(CHUNK + 1, 2, 410 + b);
            file[CHUNK - 2] = bad[b];
            fileId = _publish(file, B64, "image/png");
            vm.expectRevert(
                abi.encodeWithSelector(IContentStore.ContentBase64Invalid.selector, fileId, 0)
            );
            _attest(fileId);
        }
    }

    function test_Attest_RevertsOnTheFirstBadChunk() public {
        uint256 total = 2 * CHUNK + 2; // chunks 0, 1 and 2
        // Bad bytes in chunks 1 and 2: the first bad chunk is 1.
        bytes memory file = _text(total, 0, 60);
        file[CHUNK + 10] = '"';
        file[2 * CHUNK] = "\\";
        bytes32 fileId = _publish(file, B64, "image/png");
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentBase64Invalid.selector, fileId, 1)
        );
        _attest(fileId);

        // Only the last chunk is bad.
        file = _text(total, 0, 61);
        file[total - 1] = "%";
        fileId = _publish(file, B64, "image/png");
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentBase64Invalid.selector, fileId, 2)
        );
        _attest(fileId);

        // Either side of a chunk boundary.
        file = _text(total, 0, 62);
        file[CHUNK - 1] = "#";
        fileId = _publish(file, B64, "image/png");
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentBase64Invalid.selector, fileId, 0)
        );
        _attest(fileId);

        file = _text(total, 0, 63);
        file[CHUNK] = "#";
        fileId = _publish(file, B64, "image/png");
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentBase64Invalid.selector, fileId, 1)
        );
        _attest(fileId);
    }

    function testFuzz_Attest_OneInjectedByteMatchesTheOracle(
        uint256 position,
        uint8 value,
        uint256 seed
    ) public {
        uint256 total = CHUNK + 5 + 3; // two chunks, a multiple of 4: 24,583
        bytes memory file = _text(total - total % 4, 0, seed);
        position = bound(position, 0, file.length - 1);
        file[position] = bytes1(value);
        bytes32 fileId = _publish(file, B64, "image/png");
        // "=" is accepted only as the last byte (a one-byte pad).
        bool valid = _inAlphabet(value) || (value == 0x3d && position == file.length - 1);
        if (!valid) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IContentStore.ContentBase64Invalid.selector, fileId, position / CHUNK
                )
            );
        }
        assertEq(_attest(fileId), valid);
    }

    // ---------------------------------------------------------------- files that cannot qualify

    function test_Attest_RequiresBase64Encoding() public {
        IContentStore.Encoding[2] memory wrong =
            [IContentStore.Encoding.Identity, IContentStore.Encoding.Gzip];
        for (uint256 i; i < 2; ++i) {
            bytes32 fileId = _publish(_text(100, 0, 70), wrong[i], "image/png");
            vm.expectRevert(
                abi.encodeWithSelector(IContentStore.ContentNotBase64.selector, fileId, wrong[i])
            );
            _attest(fileId);
            assertFalse(store.isBase64Attested(fileId));
        }
    }

    function test_Attest_LengthMustBeAMultipleOfFour() public {
        uint256[7] memory lengths = [uint256(1), 2, 3, 5, 6, 7, 1001];
        for (uint256 i; i < lengths.length; ++i) {
            bytes32 fileId = _publish(_text(lengths[i], 0, 80), B64, "image/png");
            vm.expectRevert(
                abi.encodeWithSelector(
                    IContentStore.ContentBase64LengthInvalid.selector, fileId, lengths[i]
                )
            );
            _attest(fileId);
        }
        // A "=" does not make a short text long enough.
        bytes32 padded = _publish("AAA==", B64, "image/png");
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentBase64LengthInvalid.selector, padded, 5)
        );
        _attest(padded);
    }

    function test_Attest_UnknownFileReverts() public {
        bytes32 id = keccak256("nothing");
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, id));
        _attest(id);
        assertFalse(store.isBase64Attested(id), "the view never reverts");
    }

    function test_Attest_IncompleteFileRevertsAndCanBeFinishedByAnyone() public {
        bytes memory file = _text(2 * CHUNK + 2, 0, 90);
        (bytes32 fileId, bytes[] memory chunks, bytes32[] memory hashes) =
            _declare(file, B64, "image/png");

        // Nothing uploaded: the last chunk is the first thing read.
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentChunkMissing.selector, fileId, 2, hashes[2])
        );
        _attest(fileId);

        // The last chunk exists but chunk 0 does not.
        store.writeChunk(chunks[2]);
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentChunkMissing.selector, fileId, 0, hashes[0])
        );
        _attest(fileId);

        // A middle chunk is still missing.
        store.writeChunk(chunks[0]);
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentChunkMissing.selector, fileId, 1, hashes[1])
        );
        _attest(fileId);
        assertFalse(store.isBase64Attested(fileId));

        vm.prank(makeAddr("collector"));
        store.writeChunk(chunks[1]);
        assertTrue(_attest(fileId));
    }

    function test_Attest_ChunkOfTheWrongLengthReverts() public {
        // A manifest whose chunk lengths break the layout rule never completes, so it cannot
        // be attested either: here the one-byte last chunk was uploaded as eight bytes.
        bytes memory shortChunk = _text(100, 0, 91);
        bytes memory tail = _text(8, 0, 92);
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256(shortChunk);
        hashes[1] = keccak256(tail);
        bytes32 fileId = store.registerManifest(hashes, CHUNK + 1, B64, "image/png", DIGEST);
        store.writeChunk(shortChunk);
        store.writeChunk(tail);
        vm.expectRevert(
            abi.encodeWithSelector(
                IContentStore.ContentChunkLengthMismatch.selector, fileId, 1, 1, 8
            )
        );
        _attest(fileId);
        assertFalse(store.isBase64Attested(fileId));
    }

    // ---------------------------------------------------------------- one-time

    function test_Attest_IsOneTimeAndIdempotent() public {
        bytes32 fileId = _publish(_text(2 * CHUNK + 2, 0, 100), B64, "image/png");
        assertTrue(_attest(fileId));

        vm.recordLogs();
        assertTrue(_attest(fileId), "a second call is a no-op that still returns true");
        assertEq(vm.getRecordedLogs().length, 0, "no second event");
        assertTrue(store.isBase64Attested(fileId));
        // It does no work: no chunk is read again.
        assertLt(_gasOf(abi.encodeCall(store.attestBase64, (fileId))), 30_000);
    }

    function test_Attest_AttestationFollowsTheFileIdNotTheBytes() public {
        // The same bytes under another MIME type are another file and are attested separately.
        bytes memory file = _text(400, 0, 101);
        bytes32 first = _publish(file, B64, "image/png");
        bytes32 second = _publish(file, B64, "image/jpeg");
        assertTrue(_attest(first));
        assertTrue(store.isBase64Attested(first));
        assertFalse(store.isBase64Attested(second));
    }

    // ---------------------------------------------------------------- the per-call limit

    function test_Constants_ArePinned() public view {
        assertEq(store.ATTEST_CHUNKS_PER_CALL(), 48);
    }

    /// @dev `2n + 2` chunks listing one valid chunk `2n + 1` times, then a short last chunk
    ///      (`n` is the per-call limit): only two chunks are uploaded, and the file takes three
    ///      calls.
    function test_Attest_LargeFileTakesSeveralCalls() public {
        uint256 n = store.ATTEST_CHUNKS_PER_CALL();
        (bytes32 fileId, uint256 total) = _repeatedFile(2 * n + 1);
        assertEq(store.fileInfo(fileId).chunkCount, 2 * n + 2);
        assertEq(total % 4, 0);

        vm.expectEmit(true, false, false, true, address(store));
        emit IContentStore.Base64Progress(fileId, n);
        assertFalse(_attest(fileId));
        assertFalse(store.isBase64Attested(fileId), "not attested until every chunk is checked");

        vm.expectEmit(true, false, false, true, address(store));
        emit IContentStore.Base64Progress(fileId, 2 * n);
        assertFalse(_attest(fileId));
        assertFalse(store.isBase64Attested(fileId));

        vm.expectEmit(true, false, false, true, address(store));
        emit IContentStore.Base64Attested(fileId);
        assertTrue(_attest(fileId));
        assertTrue(store.isBase64Attested(fileId));
    }

    function test_Attest_AFileOfExactlyOneCallIsOneCall() public {
        uint256 n = store.ATTEST_CHUNKS_PER_CALL();
        (bytes32 fileId,) = _repeatedFile(n - 1); // n chunks in all
        assertEq(store.fileInfo(fileId).chunkCount, n);
        assertTrue(_attest(fileId));
    }

    function test_Attest_ABadChunkInALaterCallRevertsAndLeavesProgress() public {
        uint256 n = store.ATTEST_CHUNKS_PER_CALL();
        uint256 bad = n + 36; // in the second call
        bytes memory valid = _text(CHUNK, 0, 110);
        bytes memory poisoned = _text(CHUNK, 0, 111);
        poisoned[7] = 0x22; // a double quote
        bytes32[] memory hashes = new bytes32[](2 * n + 2);
        for (uint256 i; i < 2 * n + 1; ++i) {
            hashes[i] = keccak256(valid);
        }
        hashes[bad] = keccak256(poisoned);
        bytes memory last = _text(_lastLength(2 * n + 1), 0, 112);
        hashes[2 * n + 1] = keccak256(last);
        uint256 total = (2 * n + 1) * CHUNK + last.length;
        bytes32 fileId = store.registerManifest(hashes, total, B64, "image/png", DIGEST);
        store.writeChunk(valid);
        store.writeChunk(poisoned);
        store.writeChunk(last);

        assertFalse(_attest(fileId)); // the first n chunks
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentBase64Invalid.selector, fileId, bad)
        );
        _attest(fileId); // chunks n to 2n - 1 reach the bad one
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentBase64Invalid.selector, fileId, bad)
        );
        _attest(fileId); // and it keeps failing: the progress did not move
        assertFalse(store.isBase64Attested(fileId));
    }

    /// @dev The largest file the store accepts takes 11 calls, and every call fits the EIP-7825
    ///      gas cap. One chunk is listed 512 times, which makes the chunk reads warm after the
    ///      first; the cold, all-distinct worst case is `Base64WorstCaseGasTest`.
    function test_Attest_AtMaxChunksEveryCallFitsTheTransactionGasCap() public {
        uint256 max = store.MAX_CHUNKS();
        uint256 n = store.ATTEST_CHUNKS_PER_CALL();
        bytes memory chunk = _text(CHUNK, 0, 120);
        bytes32[] memory hashes = new bytes32[](max);
        for (uint256 i; i < max; ++i) {
            hashes[i] = keccak256(chunk);
        }
        bytes32 fileId = store.registerManifest(hashes, max * CHUNK, B64, "video/mp4", DIGEST);
        store.writeChunk(chunk);

        uint256 expectedCalls = (max + n - 1) / n;
        uint256 calls;
        uint256 worst;
        while (!store.isBase64Attested(fileId)) {
            uint256 txGas = _attestTxGas(fileId);
            if (txGas > worst) worst = txGas;
            assertLe(txGas, TX_GAS_CAP, "each call fits the cap");
            ++calls;
            assertLe(calls, expectedCalls, "no more calls than chunks / limit");
        }
        assertEq(calls, expectedCalls);
        console2.log("attestBase64 at MAX_CHUNKS: calls", calls);
        console2.log("attestBase64 at MAX_CHUNKS: worst call, transaction gas", worst);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev The length (1 to 4) of a last chunk that makes `copies` full chunks plus it a multiple
    ///      of 4 bytes.
    function _lastLength(uint256 copies) internal pure returns (uint256 length) {
        length = 4 - (copies * CHUNK) % 4;
    }

    /// @dev A manifest of `copies` identical full chunks of valid text, then a short last chunk
    ///      ending in one `=`: the whole file is valid base64.
    function _repeatedFile(uint256 copies) internal returns (bytes32 fileId, uint256 total) {
        bytes memory chunk = _text(CHUNK, 0, 130);
        bytes memory last = _text(_lastLength(copies), 1, 131);
        bytes32[] memory hashes = new bytes32[](copies + 1);
        for (uint256 i; i < copies; ++i) {
            hashes[i] = keccak256(chunk);
        }
        hashes[copies] = keccak256(last);
        total = copies * CHUNK + last.length;
        fileId = store.registerManifest(hashes, total, B64, "image/png", DIGEST);
        store.writeChunk(chunk);
        store.writeChunk(last);
    }
}

/// @dev Gas for the sizes the renderer cares about. Fixtures are built in `setUp`, a separate
///      transaction, so every measured call starts cold.
contract Base64GasTest is Base64Base {
    bytes32 internal id256k;
    bytes32 internal id1m;

    function setUp() public {
        store = new ContentStore();
        id256k = _publish(_rotating(256 * 1024, 1), B64, "image/png");
        id1m = _publish(_rotating(1024 * 1024, 2), B64, "image/png");
    }

    function test_Gas_Attest256KiB() public {
        uint256 txGas = _attestTxGas(id256k);
        console2.log("gas attestBase64, 256 KiB (11 chunks), transaction", txGas);
        assertTrue(store.isBase64Attested(id256k));
        assertLt(txGas, 2_000_000);
    }

    function test_Gas_Attest1MiB() public {
        uint256 txGas = _attestTxGas(id1m);
        console2.log("gas attestBase64, 1 MiB (43 chunks), transaction", txGas);
        assertTrue(store.isBase64Attested(id1m));
        assertLt(txGas, 8_000_000);
    }
}

/// @dev The worst single call: `ATTEST_CHUNKS_PER_CALL` distinct chunks, every one cold.
contract Base64WorstCaseGasTest is Base64Base {
    bytes32 internal fileId;

    function setUp() public {
        store = new ContentStore();
        uint256 n = store.ATTEST_CHUNKS_PER_CALL();
        bytes32[] memory hashes = new bytes32[](n);
        bytes[] memory chunks = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            // Distinct chunks (rotation i), so each is a separate pointer and a cold read.
            chunks[i] = _rotating(CHUNK, i);
            hashes[i] = keccak256(chunks[i]);
        }
        // n * 24,575 bytes is a multiple of 4 when n is.
        assertEq((n * CHUNK) % 4, 0);
        fileId = store.registerManifest(hashes, n * CHUNK, B64, "video/mp4", DIGEST);
        _uploadAll(chunks);
    }

    function test_Gas_FullCallFitsTheTransactionGasCapWithMargin() public {
        uint256 txGas = _attestTxGas(fileId);
        console2.log("gas attestBase64, a full call of distinct cold chunks, transaction", txGas);
        assertTrue(store.isBase64Attested(fileId));
        assertLe(txGas, TX_GAS_CAP);
        assertLe(txGas, TX_GAS_CAP * 55 / 100, "keeps 45% of the cap as margin");
    }
}
