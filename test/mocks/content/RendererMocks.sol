// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";

/// @dev A 6529 Stream Editions stand-in: ERC-1155 by ERC-165, with `masterOf` set by the test.
contract RendererEditionsMock {
    address public stream;
    mapping(uint256 => uint256) internal masters;
    mapping(uint256 => bytes32) internal hashes;

    constructor(address stream_) {
        stream = stream_;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0xd9b67a26;
    }

    function setMaster(uint256 editionId, uint256 workId, bytes32 contentHash) external {
        masters[editionId] = workId;
        hashes[editionId] = contentHash;
    }

    function masterOf(uint256 editionId) external view returns (address, uint256, bytes32) {
        require(hashes[editionId] != 0, "unknown edition");
        return (stream, masters[editionId], hashes[editionId]);
    }
}

/// @dev `latestDisputeOutcome` as the statement log answers it.
contract RendererDisputeLogMock {
    mapping(address => mapping(uint256 => bytes32)) internal outcomes;
    bool public broken;

    function set(address token, uint256 id, bytes32 entry) external {
        outcomes[token][id] = entry;
    }

    function setBroken(bool on) external {
        broken = on;
    }

    function latestDisputeOutcome(address token, uint256 id) external view returns (bytes32) {
        require(!broken, "log down");
        return outcomes[token][id];
    }
}

/// @dev `IEntropyModule.seedOf` by item hash.
contract RendererEntropyMock {
    mapping(bytes32 => bytes32) internal seeds;

    function set(bytes32 itemHash, bytes32 seed) external {
        seeds[itemHash] = seed;
    }

    function seedOf(bytes32 itemHash) external view returns (bytes32) {
        return seeds[itemHash];
    }
}
