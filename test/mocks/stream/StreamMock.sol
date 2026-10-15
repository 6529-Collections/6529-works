// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IStream } from "src/interfaces/IStream.sol";

/// @notice The minimal 6529 Stream stand-in: the reads other contracts make of Stream, answered
///         from fixtures the test sets. The renderer reads `work`, `collection`, `workRecords`
///         and `entropyModule`; the artist registry binds it (ERC-165 for `IStream`) and reads
///         `artistOf` and `editions`. `artistOf` reverts with `UnknownWork` for a token with no
///         artist ID, as Stream does for an unminted or burned token, and `fail(selector, true)`
///         makes one read revert.
/// @dev The other Stream stand-ins have a purpose this one does not: `EditionsStreamMock`
///      (test/mocks/editions) models masters, their settlement and the edition link, with
///      faults, for 6529 Editions' unit tests; `LeanStream` (test/mocks/sales/LeanStartStack.sol)
///      is the lean start-path model the auction's gas tests measure. Stream itself is tested
///      as the real contract (`StreamFixture`), and the whole system as the real, wired stack
///      (`IntegrationBase`).
contract StreamMock {
    address public workRecords;
    address public editions;
    address public entropyModule;
    mapping(uint256 => IStream.WorkCore) internal cores;
    mapping(uint256 => IStream.Collection) internal collections;
    mapping(bytes4 => bool) internal failing;

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

    function setWork(uint256 id, IStream.WorkCore calldata core) external {
        cores[id] = core;
    }

    /// @dev A work known only by its lead artist ID (zero: unminted or burned).
    function setWork(uint256 id, uint256 artistId) external {
        cores[id].artistId = artistId;
    }

    function setCollection(uint256 id, IStream.Collection calldata collection_) external {
        collections[id] = collection_;
    }

    // ----- reads

    function work(uint256 id) external view returns (IStream.WorkCore memory) {
        _gate(msg.sig);
        return cores[id];
    }

    function collection(uint256 id) external view returns (IStream.Collection memory) {
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
