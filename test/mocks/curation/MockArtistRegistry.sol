// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IArtistRoleResolver } from "src/interfaces/IArtistRoleResolver.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";

/// @dev The slice of `IArtistRegistry` the package registry calls, with the identity lane's
///      rules that matter to it: artist ID `uint256(uint160(first authority))`, every past
///      authority keeps mapping to its ID, `register` only from the bound package registry (and it
///      counts as the first activity), `authorityOf` and `artist` revert for unknown IDs.
///      `recover` stands in for an executed identity change.
contract MockArtistRegistry is IERC165 {
    error UnknownArtist(uint256 artistId);
    error AccountTaken(address account);
    error UnboundCaller(address caller);

    address public packageRegistry;
    mapping(address account => uint256) public artistIdOf;
    mapping(uint256 artistId => ArtistIdentity) internal _identity;
    mapping(uint256 artistId => uint64) public lastActivity;
    uint256 public registrations;

    function bindPackageRegistry(address target) external {
        packageRegistry = target;
    }

    function register(address authority, bytes32 profileId, bytes32 profileDocHash)
        external
        returns (uint256 artistId)
    {
        if (msg.sender != packageRegistry) revert UnboundCaller(msg.sender);
        if (artistIdOf[authority] != 0) revert AccountTaken(authority);
        artistId = uint256(uint160(authority));
        artistIdOf[authority] = artistId;
        _identity[artistId] = ArtistIdentity(authority, authority, profileId, profileDocHash);
        lastActivity[artistId] = uint64(block.timestamp);
        ++registrations;
    }

    /// @dev Test hook: an executed authority change.
    function recover(uint256 artistId, address next) external {
        _known(artistId);
        artistIdOf[next] = artistId;
        _identity[artistId].authority = next;
    }

    /// @dev Test hook: an executed profile change.
    function setProfile(uint256 artistId, bytes32 profileId, bytes32 profileDocHash) external {
        _known(artistId);
        _identity[artistId].profileId = profileId;
        _identity[artistId].profileDocHash = profileDocHash;
    }

    function authorityOf(uint256 artistId) external view returns (address) {
        _known(artistId);
        return _identity[artistId].authority;
    }

    /// @dev No recovery override is modelled: the active authority is the authority.
    function activeAuthorityOf(uint256 artistId) external view returns (address) {
        _known(artistId);
        return _identity[artistId].authority;
    }

    function artist(uint256 artistId)
        external
        view
        returns (ArtistIdentity memory identity, uint64 activity)
    {
        _known(artistId);
        return (_identity[artistId], lastActivity[artistId]);
    }

    function isArtist(address, uint256, address) external pure returns (bool) {
        return false;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IArtistRoleResolver).interfaceId
            || interfaceId == type(IArtistRegistry).interfaceId;
    }

    function _known(uint256 artistId) internal view {
        if (_identity[artistId].authority == address(0)) revert UnknownArtist(artistId);
    }
}
