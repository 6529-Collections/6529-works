// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IArtistRoleResolver } from "src/interfaces/IArtistRoleResolver.sol";

/// @title ArtistRegistryStandIn
/// @notice LOCAL DRY RUNS ONLY. Stands in for the identity lane's `ArtistRegistry` until it
///         merges, so the contracts that pin an artist registry at construction (package
///         registry, split factory, statement log) can be deployed and wired on `main`. It
///         answers ERC-165 for the same four interfaces as the real registry and implements
///         its one-shot genesis binds and their getters; it registers no artists and resolves
///         no payouts. `Deploy.s.sol` refuses to deploy it outside chain 31337.
contract ArtistRegistryStandIn is AccessManaged, IERC165, IArtistPayoutResolver {
    address public packageRegistry;
    address public stream;
    address public splitFactory;
    address public federationRegistry;

    error AlreadyBound(bytes4 selector);

    constructor(address authority) AccessManaged(authority) { }

    function bindPackageRegistry(address target) external restricted {
        packageRegistry = _bind(packageRegistry, target);
    }

    function bindStream(address target) external restricted {
        stream = _bind(stream, target);
    }

    function bindSplitFactory(address target) external restricted {
        splitFactory = _bind(splitFactory, target);
    }

    function bindFederationRegistry(address target) external restricted {
        federationRegistry = _bind(federationRegistry, target);
    }

    /// @notice No artists exist in the stand-in.
    function isArtist(address, uint256, address) external pure returns (bool) {
        return false;
    }

    /// @inheritdoc IArtistPayoutResolver
    function payoutAddress(uint256) external pure returns (address) {
        return address(0);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IArtistRoleResolver).interfaceId
            || interfaceId == type(IArtistPayoutResolver).interfaceId
            || interfaceId == type(IArtistRegistry).interfaceId;
    }

    function _bind(address current, address target) private pure returns (address) {
        if (current != address(0)) revert AlreadyBound(msg.sig);
        return target;
    }
}
