// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Locator, LocatorKind } from "src/interfaces/types/ContentTypes.sol";

/// @notice Well-formed locator URIs for tests, derived from a seed: `ar://` and a 43-character
///         base64url transaction ID, and `ipfs://` and a CIDv1 of the fixed profile (base32,
///         sha2-256, raw leaves `bafkrei...` or a dag-pb root `bafybei...`), as
///         `WorkRecords.addLocator` accepts them. The digest is `keccak256(seed)`: the tests need
///         distinct, canonical addresses, not the hash of any real file.
library ContentAddresses {
    bytes internal constant B64URL =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    bytes internal constant B32 = "abcdefghijklmnopqrstuvwxyz234567";

    function arweave(string memory seed) internal pure returns (string memory) {
        return string.concat("ar://", string(txid(keccak256(bytes(seed)))));
    }

    function ipfs(string memory seed) internal pure returns (string memory) {
        return string.concat("ipfs://", string(cid(0x55, keccak256(bytes(seed)))));
    }

    /// @dev A dag-pb root CID (`bafybei...`), what the fixed profile gives a multi-block file.
    function ipfsRoot(string memory seed) internal pure returns (string memory) {
        return string.concat("ipfs://", string(cid(0x70, keccak256(bytes(seed)))));
    }

    function ar(string memory seed) internal pure returns (Locator memory) {
        return Locator(LocatorKind.ARWEAVE, arweave(seed));
    }

    function ipfsLocator(string memory seed) internal pure returns (Locator memory) {
        return Locator(LocatorKind.IPFS, ipfs(seed));
    }

    /// @dev The unpadded base64url text of 32 bytes: 43 characters.
    function txid(bytes32 digest) internal pure returns (bytes memory out) {
        out = new bytes(43);
        uint256 v = uint256(digest);
        // 256 bits read 6 at a time from the top; the last character carries 4 bits and two
        // zero bits.
        for (uint256 i; i < 42; ++i) {
            out[i] = B64URL[(v >> (250 - 6 * i)) & 63];
        }
        out[42] = B64URL[(v & 15) << 2];
    }

    /// @dev `b` and the unpadded lowercase base32 text of `0x01 || codec || 0x12 0x20 || digest`.
    function cid(uint8 codec, bytes32 digest) internal pure returns (bytes memory out) {
        bytes memory raw = abi.encodePacked(uint8(0x01), codec, uint8(0x12), uint8(0x20), digest);
        out = new bytes(59);
        out[0] = "b";
        uint256 buffer;
        uint256 bits;
        uint256 n = 1;
        for (uint256 i; i < raw.length; ++i) {
            buffer = (buffer << 8) | uint8(raw[i]);
            bits += 8;
            while (bits >= 5) {
                bits -= 5;
                out[n++] = B32[(buffer >> bits) & 31];
            }
        }
        out[n] = B32[(buffer << (5 - bits)) & 31];
    }
}
