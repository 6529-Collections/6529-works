// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";

/// @dev The part of 6529 Stream core the renderer reads, with fixtures set by the test.
///      `fail(selector, true)` makes one read revert.
contract MockStream {
    address public workRecords;
    mapping(uint256 => IStream.WorkCore) internal cores;
    address public entropyModule;
    mapping(uint256 => IStream.Collection) internal collections;
    mapping(bytes4 => bool) internal failing;

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x80ac58cd;
    }

    function fail(bytes4 selector, bool on) external {
        failing[selector] = on;
    }

    function setWorkRecords(address records) external {
        workRecords = records;
    }

    function setWork(uint256 id, IStream.WorkCore calldata core) external {
        cores[id] = core;
    }

    function setEntropyModule(address module) external {
        entropyModule = module;
    }

    function setCollection(uint256 id, IStream.Collection calldata collection_) external {
        collections[id] = collection_;
    }

    function work(uint256 id) external view returns (IStream.WorkCore memory) {
        _gate(msg.sig);
        return cores[id];
    }

    function collection(uint256 id) external view returns (IStream.Collection memory) {
        _gate(msg.sig);
        return collections[id];
    }

    function _gate(bytes4 selector) internal view {
        require(!failing[selector], "mock failure");
    }
}

/// @dev The part of the work-records satellite the renderer reads. The media list is kept as an
///      ABI blob because memory arrays of structs cannot always be copied to storage.
contract MockWorkRecords {
    mapping(uint256 => IWorkRecords.RecordInfo) internal infos;
    mapping(uint256 => bool) internal opened;
    mapping(uint256 => SeedPolicy) internal seedPolicies;
    mapping(uint256 => bytes32) internal seeds;
    mapping(uint256 => bytes) internal medias;
    mapping(uint256 => License) internal licenses;
    mapping(uint256 => mapping(bytes32 => Locator[])) internal locatorLists;
    mapping(uint256 => mapping(bytes32 => bool)) internal onchainPreferred;
    mapping(bytes4 => bool) internal failing;

    function fail(bytes4 selector, bool on) external {
        failing[selector] = on;
    }

    function setRecord(uint256 id, IWorkRecords.RecordInfo calldata info) external {
        infos[id] = info;
    }

    function setOpen(uint256 id, bool open) external {
        opened[id] = open;
    }

    function setSeed(uint256 id, SeedPolicy policy, bytes32 seed) external {
        (seedPolicies[id], seeds[id]) = (policy, seed);
    }

    function setMedia(uint256 id, MediaFile[] calldata media) external {
        medias[id] = abi.encode(media);
    }

    function setLicense(uint256 id, License calldata license) external {
        licenses[id] = license;
    }

    function addLocator(uint256 id, bytes32 fileId, Locator calldata locator) external {
        locatorLists[id][fileId].push(locator);
    }

    function preferOnchain(uint256 id, bytes32 fileId, bool on) external {
        onchainPreferred[id][fileId] = on;
    }

    error RecordNotOpen(uint256 tokenId);

    function isOpen(uint256 id) external view returns (bool) {
        _gate(msg.sig);
        return opened[id];
    }

    function record(uint256 id) external view returns (IWorkRecords.RecordInfo memory) {
        _gate(msg.sig);
        _open(id);
        return infos[id];
    }

    function mediaOf(uint256 id) external view returns (MediaFile[] memory) {
        _gate(msg.sig);
        _open(id);
        if (medias[id].length == 0) return new MediaFile[](0);
        return abi.decode(medias[id], (MediaFile[]));
    }

    function licenseOf(uint256 id) external view returns (License memory) {
        _gate(msg.sig);
        _open(id);
        return licenses[id];
    }

    function seedOf(uint256 id) external view returns (SeedPolicy, bytes32) {
        _gate(msg.sig);
        _open(id);
        return (seedPolicies[id], seeds[id]);
    }

    function locators(uint256 id, bytes32 fileId) external view returns (Locator[] memory) {
        _gate(msg.sig);
        _open(id);
        return locatorLists[id][fileId];
    }

    function preferredLocator(uint256 id, bytes32 fileId)
        external
        view
        returns (Locator memory, uint256)
    {
        _gate(msg.sig);
        _open(id);
        if (onchainPreferred[id][fileId]) {
            return (Locator(LocatorKind.ONCHAIN, ""), type(uint256).max);
        }
        Locator[] storage list = locatorLists[id][fileId];
        require(list.length != 0, "no locator");
        return (list[0], 0);
    }

    /// @dev Every view reverts until the record is open (decision E9).
    function _open(uint256 id) internal view {
        if (!opened[id]) revert RecordNotOpen(id);
    }

    function _gate(bytes4 selector) internal view {
        require(!failing[selector], "mock failure");
    }
}

/// @dev A 6529 Editions stand-in: ERC-1155 by ERC-165, with `masterOf` set by the test.
contract MockEditions {
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
contract MockDisputeLog {
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
contract MockEntropy {
    mapping(bytes32 => bytes32) internal seeds;

    function set(bytes32 itemHash, bytes32 seed) external {
        seeds[itemHash] = seed;
    }

    function seedOf(bytes32 itemHash) external view returns (bytes32) {
        return seeds[itemHash];
    }
}
