// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRoleResolver } from "src/records/IArtistRoleResolver.sol";

/// @notice Mocks for the records lane: an artist resolver and minimal token ownership sources.

/// @dev An artist resolver whose answers tests set per subject, or for every subject.
contract ArtistResolverMock is IArtistRoleResolver {
    mapping(bytes32 => mapping(address => bool)) internal artists;
    mapping(address => bool) internal anywhere;

    function grant(address token, uint256 id, address account) external {
        artists[keccak256(abi.encode(token, id))][account] = true;
    }

    function grantEverywhere(address account) external {
        anywhere[account] = true;
    }

    function isArtist(address token, uint256 id, address account) external view returns (bool) {
        return anywhere[account] || artists[keccak256(abi.encode(token, id))][account];
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IArtistRoleResolver).interfaceId;
    }
}

/// @dev A contract with ERC-165 for the wrong interface only.
contract WrongInterfaceMock {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev ERC-721 `ownerOf` that reverts for unknown tokens, like OpenZeppelin's.
contract ERC721OwnerMock {
    mapping(uint256 => address) internal owners;

    function setOwner(uint256 id, address who) external {
        owners[id] = who;
    }

    function ownerOf(uint256 id) external view returns (address) {
        require(owners[id] != address(0), "nonexistent token");
        return owners[id];
    }
}

/// @dev ERC-1155 `balanceOf`.
contract ERC1155BalanceMock {
    mapping(uint256 => mapping(address => uint256)) internal balances;

    function setBalance(uint256 id, address who, uint256 amount) external {
        balances[id][who] = amount;
    }

    function balanceOf(address who, uint256 id) external view returns (uint256) {
        return balances[id][who];
    }
}
