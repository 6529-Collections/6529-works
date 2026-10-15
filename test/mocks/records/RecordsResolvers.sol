// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRoleResolver } from "src/interfaces/IArtistRoleResolver.sol";

/// @notice Adversarial artist resolvers for the records lane.

/// @dev A resolver that vouches for whoever deployed it, for every subject.
contract EvilResolverMock is IArtistRoleResolver {
    address internal immutable boss;

    constructor() {
        boss = msg.sender;
    }

    function isArtist(address, uint256, address account) external view returns (bool) {
        return account == boss;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IArtistRoleResolver).interfaceId;
    }
}

/// @dev A resolver with fixed code whose answers come from a backend its keeper can swap, so a
///      code-hash pin does not pin its behaviour.
contract ForwardingResolverMock is IArtistRoleResolver {
    address public backend;
    address internal immutable keeper;

    constructor(address backend_) {
        backend = backend_;
        keeper = msg.sender;
    }

    function setBackend(address next) external {
        require(msg.sender == keeper, "keeper only");
        backend = next;
    }

    function isArtist(address token, uint256 id, address account) external view returns (bool) {
        return IArtistRoleResolver(backend).isArtist(token, id, account);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IArtistRoleResolver).interfaceId;
    }
}
