// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStream } from "src/interfaces/IStream.sol";

/// @notice Answers ERC-165 for one interface (plus ERC-165 itself), as a binding target.
contract InterfaceStub {
    bytes4 internal immutable _interfaceId;

    constructor(bytes4 interfaceId_) {
        _interfaceId = interfaceId_;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return interfaceId == _interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Stands in for the curation lane's package registry: the artist registry binds it and
///         tests call from its address.
contract PackageRegistryStub is InterfaceStub {
    constructor() InterfaceStub(type(IPackageRegistry).interfaceId) { }
}

/// @notice The two 6529 Stream reads the artist registry makes: `work(id).artistId` and
///         `editions()`. `work` reverts with `UnknownWork` for unminted or burned IDs, like Stream.
contract StreamWorksMock is InterfaceStub {
    address public editions;
    mapping(uint256 => uint256) internal _artistOf;

    constructor() InterfaceStub(type(IERC721).interfaceId) { }

    function setEditions(address editions_) external {
        editions = editions_;
    }

    function setWork(uint256 tokenId, uint256 artistId) external {
        _artistOf[tokenId] = artistId;
    }

    function work(uint256 tokenId) external view returns (IStream.WorkInfo memory info) {
        if (_artistOf[tokenId] == 0) revert IStream.UnknownWork(tokenId);
        info.artistId = _artistOf[tokenId];
    }
}

/// @notice The 6529 Editions read the artist registry makes: `masterOf(id)`, which reverts with
///         `UnknownEdition` for an unknown edition. `master` may be set to a foreign Stream.
contract EditionsMastersMock {
    mapping(uint256 => address) internal _masterStream;

    function setEdition(uint256 editionId, address masterStream) external {
        _masterStream[editionId] = masterStream;
    }

    function masterOf(uint256 editionId) external view returns (address, uint256, bytes32) {
        if (_masterStream[editionId] == address(0)) revert IEditions.UnknownEdition(editionId);
        return (_masterStream[editionId], editionId, keccak256("content"));
    }
}

/// @notice A governed consolidation source that misbehaves by returning too many wallets.
contract OversizedConsolidationSource is InterfaceStub {
    constructor() InterfaceStub(type(IConsolidationSource).interfaceId) { }

    function establishedWallets(address) external pure returns (address[] memory wallets) {
        wallets = new address[](17);
    }

    function isEstablished(address, address) external pure returns (bool) {
        return false;
    }
}
