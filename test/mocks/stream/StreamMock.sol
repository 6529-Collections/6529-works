// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IStreamViews } from "src/interfaces/IStreamViews.sol";

/// @notice The minimal 6529 Stream stand-in: the reads other contracts make of Stream, answered
///         from fixtures the test sets. The renderer reads `coreOf`, `extsload` (at Stream's own
///         storage slots, 17 and 18, which this mock mirrors), `workRecords` and
///         `entropyModuleOf`; the artist registry binds it (ERC-165 for `IStream`) and reads
///         `artistOf` and `editions`. `artistOf` reverts with `UnknownWork` for a token with no
///         artist ID, as Stream does for an unminted or burned token, and `fail(selector, true)`
///         makes one read revert.
/// @dev The other Stream stand-ins have a purpose this one does not: `EditionsStreamMock`
///      (test/mocks/editions) models masters, their settlement and the edition link, with
///      faults, for 6529 Stream Editions' unit tests; `LeanStream`
///      (test/mocks/sales/LeanStartStack.sol) is the lean start-path model the auction's gas tests
///      measure. Stream itself is tested
///      as the real contract (`StreamFixture`), and the whole system as the real, wired stack
///      (`IntegrationBase`).
contract StreamMock {
    address public workRecords;
    address public editions;
    address public entropyModule;
    mapping(uint256 => IStreamViews.WorkCore) internal cores;
    mapping(uint256 => IStreamViews.Collection) internal collections;
    mapping(bytes4 => bool) internal failing;
    /// @dev Padding so the two mappings below sit at Stream's slots 17 and 18, with Stream's
    ///      struct layouts, for `extsload`.
    uint256[11] private _gap;
    mapping(uint256 => CollectionLayout) internal _collectionSlots;
    mapping(uint256 => TokenLayout) internal _tokenSlots;

    /// @dev `Stream.CollectionData` and the first word of `Stream.TokenData`.
    struct CollectionLayout {
        bool exists;
        uint32 minted;
        bytes32 metadataHash;
        string name;
    }

    struct TokenLayout {
        address seller;
        uint32 serial;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC165).interfaceId || id == type(IERC721).interfaceId
            || id == type(IStream).interfaceId;
    }

    // ----- fixtures

    function fail(bytes4 selector, bool on) external {
        failing[selector] = on;
    }

    function setWorkRecords(address records) external {
        workRecords = records;
    }

    function setEditions(address editions_) external {
        editions = editions_;
    }

    function setEntropyModule(address module) external {
        entropyModule = module;
    }

    function setWork(uint256 id, IStreamViews.WorkCore calldata core) external {
        cores[id] = core;
        // forge-lint: disable-next-line(unsafe-typecast)
        _tokenSlots[id] = TokenLayout(core.seller, uint32(core.serial));
    }

    /// @dev A work known only by its lead artist ID (zero: unminted or burned).
    function setWork(uint256 id, uint256 artistId) external {
        cores[id].artistId = artistId;
    }

    function setCollection(uint256 id, IStreamViews.Collection calldata collection_) external {
        collections[id] = collection_;
        // forge-lint: disable-next-line(unsafe-typecast)
        _collectionSlots[id] = CollectionLayout(
            true, uint32(collection_.minted), collection_.metadataHash, collection_.name
        );
    }

    /// @dev Sets a collection's stored name to raw bytes (any, UTF-8 or not).
    function setCollectionName(uint256 id, bytes calldata name) external {
        _collectionSlots[id].name = string(name);
    }

    // ----- reads

    function work(uint256 id) external view returns (IStreamViews.WorkCore memory) {
        _gate(msg.sig);
        return cores[id];
    }

    function coreOf(uint256 id)
        external
        view
        returns (bytes32, uint256, uint256, uint8, uint8, uint32)
    {
        _gate(msg.sig);
        IStreamViews.WorkCore storage c = cores[id];
        if (c.artistId == 0) revert IStream.UnknownWork(id);
        return (c.itemHash, c.artistId, c.collectionId, c.kind, c.seedPolicy, c.royaltyRate);
    }

    function extsload(bytes32 slot, uint256 n) external view returns (bytes32[] memory words) {
        _gate(msg.sig);
        words = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 w;
            assembly ("memory-safe") {
                w := sload(add(slot, i))
            }
            words[i] = w;
        }
    }

    /// @dev One module for every work: the mock models no replacement.
    function entropyModuleOf(uint256) external view returns (address) {
        _gate(msg.sig);
        return entropyModule;
    }

    function collection(uint256 id) external view returns (IStreamViews.Collection memory) {
        _gate(msg.sig);
        return collections[id];
    }

    function artistOf(uint256 id) external view returns (uint256 artistId) {
        _gate(msg.sig);
        artistId = cores[id].artistId;
        if (artistId == 0) revert IStream.UnknownWork(id);
    }

    function _gate(bytes4 selector) internal view {
        require(!failing[selector], "mock failure");
    }
}
