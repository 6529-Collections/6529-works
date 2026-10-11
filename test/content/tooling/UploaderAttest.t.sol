// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { ContentBase } from "../ContentBase.sol";
import { UploaderGoldenData as Golden } from "./UploaderGoldenData.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";

/// @dev Shared helpers: build a base64 text from golden parts and stage it on the store.
abstract contract UploaderAttestBase is ContentBase {
    IContentStore.Encoding internal constant B64 = IContentStore.Encoding.Base64;
    IContentStore.Encoding internal constant GZB64 = IContentStore.Encoding.GzipBase64;

    function _build(Golden.Part[] memory parts) internal pure returns (bytes memory text) {
        uint256 total;
        for (uint256 i; i < parts.length; ++i) {
            total += parts[i].unit.length * parts[i].count;
        }
        text = new bytes(total);
        uint256 cursor;
        for (uint256 i; i < parts.length; ++i) {
            bytes memory unit = parts[i].unit;
            for (uint256 n; n < parts[i].count; ++n) {
                for (uint256 b; b < unit.length; ++b) {
                    text[cursor++] = unit[b];
                }
            }
        }
    }

    /// @dev Registers `text` as a `encoding` file and uploads every chunk.
    function _stage(bytes memory text, IContentStore.Encoding encoding)
        internal
        returns (bytes32 fileId)
    {
        (bytes[] memory chunks, bytes32[] memory hashes) = _split(text);
        fileId = store.registerManifest(hashes, text.length, encoding, "text/plain", DIGEST);
        _uploadAll(chunks);
    }
}

/// @dev Cross-language agreement on base64 attestation. The golden cases and bitmaps were
///      written by the Python tooling (`tools/content/golden_attest.py`), whose `attestBase64`
///      rule is checked here against the real `ContentStore`: the same texts must be attested, or
///      refused with the same error and chunk.
contract UploaderAttestTest is UploaderAttestBase {
    function setUp() public {
        store = new ContentStore();
    }

    function test_GoldenCases_StoreReachesThePythonVerdictForBothBase64Encodings() public {
        Golden.Base64Case[] memory cases = Golden.base64Cases();
        IContentStore.Encoding[2] memory encodings = [B64, GZB64];
        for (uint256 i; i < cases.length; ++i) {
            for (uint256 e; e < 2; ++e) {
                Golden.Base64Case memory c = cases[i];
                bytes memory text = _build(c.parts);
                bytes32 fileId = _stage(text, encodings[e]);
                if (c.expect == 0) {
                    assertTrue(store.attestBase64(fileId), c.name);
                    assertTrue(store.isBase64Attested(fileId), c.name);
                } else {
                    if (c.expect == 1) {
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                IContentStore.ContentBase64Invalid.selector, fileId, c.chunk
                            )
                        );
                    } else {
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                IContentStore.ContentBase64LengthInvalid.selector,
                                fileId,
                                text.length
                            )
                        );
                    }
                    store.attestBase64(fileId);
                    assertFalse(store.isBase64Attested(fileId), c.name);
                }
            }
        }
    }

    /// @dev Every byte value, first and last in an otherwise valid text, against the bitmaps the
    ///      Python rule produced: the alphabet at the start, the alphabet plus `=` at the end.
    function test_EveryByteValue_FirstAndLast() public {
        for (uint256 v; v < 256; ++v) {
            _assertVerdict(
                abi.encodePacked(bytes1(uint8(v)), "AAA"), Golden.BASE64_ACCEPTED_AS_FIRST, v
            );
            _assertVerdict(
                abi.encodePacked("AAA", bytes1(uint8(v))), Golden.BASE64_ACCEPTED_AS_LAST, v
            );
        }
    }

    function _assertVerdict(bytes memory text, uint256 bitmap, uint256 v) internal {
        bytes32 fileId = _stage(text, B64);
        (bool ok,) = address(store).call(abi.encodeCall(store.attestBase64, (fileId)));
        assertEq(ok, (bitmap >> v) & 1 == 1, "byte value verdict");
        assertEq(store.isBase64Attested(fileId), ok);
    }

    /// @dev The call the tooling emits is `attestBase64(fileId)` and nothing else: its calldata is
    ///      the selector and the ID, 36 bytes, byte-equal to what Solidity encodes.
    function test_AttestCalldataIsTheSelectorAndTheFileId() public view {
        bytes32 fileId = keccak256("any file");
        bytes memory expected = abi.encodeCall(store.attestBase64, (fileId));
        assertEq(expected.length, 36);
        assertEq(bytes4(expected), bytes4(0x0cecb241), "attestBase64(bytes32)");
        assertEq(bytes4(abi.encodeCall(store.isBase64Attested, (fileId))), bytes4(0x3435213b));
        assertEq(bytes4(abi.encodeCall(store.ATTEST_CHUNKS_PER_CALL, ())), bytes4(0xc3c78335));
        assertEq(store.ATTEST_CHUNKS_PER_CALL(), 48, "the tooling sizes its calls for 48");
    }
}

/// @dev The Python gas model for `attestBase64` is an upper bound. Each test runs from the state
///      after `setUp`, so every measured call is cold, as in a fresh transaction.
abstract contract UploaderAttestGasBase is UploaderAttestBase {
    bytes32 internal fileId;

    /// @dev A base64 file of `chunks` distinct chunks: text of 18,400 media bytes per chunk
    ///      (24,533 characters) stays inside its chunk. `calls` attest calls run in `setUp`.
    function _fixture(uint256 chunks, uint256 calls) internal {
        store = new ContentStore();
        bytes memory text = bytes(Base64.encode(_data(18_400 * chunks, 900 + chunks)));
        fileId = _stage(text, B64);
        for (uint256 i; i < calls; ++i) {
            store.attestBase64(fileId);
        }
    }

    function _model(uint256 chunksInCall) internal pure returns (uint256) {
        return Golden.GAS_ATTEST_BASE + Golden.GAS_ATTEST_PER_CHUNK * chunksInCall;
    }

    function _assertWithinModel(uint256 chunksInCall) internal {
        bytes memory callData = abi.encodeCall(store.attestBase64, (fileId));
        uint256 used = _gasOf(callData);
        assertLe(used, _model(chunksInCall), "attestBase64 gas above the Python model");
        assertLe(
            21_000 + _calldataGas(callData) + used, Golden.TX_GAS_CAP * 55 / 100, "no margin left"
        );
    }
}

contract UploaderAttestGasOneChunkTest is UploaderAttestGasBase {
    function setUp() public {
        _fixture(1, 0);
    }

    function test_OneChunk() public {
        _assertWithinModel(1);
    }
}

contract UploaderAttestGasElevenChunksTest is UploaderAttestGasBase {
    function setUp() public {
        _fixture(11, 0);
    }

    function test_ElevenChunks() public {
        _assertWithinModel(11);
    }
}

/// @dev The largest call: 48 distinct cold chunks. The model prices it at about 52 percent of the
///      transaction gas cap.
contract UploaderAttestGasFullCallTest is UploaderAttestGasBase {
    function setUp() public {
        _fixture(48, 0);
    }

    function test_FullCall() public {
        _assertWithinModel(48);
    }
}

/// @dev The worst call: the first call of a file with 49 chunks checks 48 chunks and, because it
///      reaches the end of the file, reads the last chunk cold to find the padding.
contract UploaderAttestGasWorstCallTest is UploaderAttestGasBase {
    function setUp() public {
        _fixture(49, 0);
    }

    function test_WorstCall() public {
        _assertWithinModel(48);
    }
}

/// @dev The second call of that file: one chunk to check, which is the last one.
contract UploaderAttestGasSecondCallTest is UploaderAttestGasBase {
    function setUp() public {
        _fixture(49, 1);
    }

    function test_SecondCall() public {
        assertFalse(store.isBase64Attested(fileId));
        _assertWithinModel(1);
    }
}
