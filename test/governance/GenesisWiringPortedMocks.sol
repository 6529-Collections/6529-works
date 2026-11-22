// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";

/// @notice A peer that answers ERC-165, like the contracts a genesis call names.
contract Erc165PeerPortedMock is IERC165 {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice A governed target exposing today's genesis selectors: the package registry's
///         one-shot `bindStream` and an edition auction's `setTarget` (each checking its peer's
///         ERC-165), a genesis selector that reverts with a reason (`setEntropyModule`), one
///         that reverts without data (`setOpeningBid`), and a 7-day setter wiring must not reach.
///         It declares `IPackageRegistry` and `ISaleAdapter`, not `IIndependentStreamRegistry`.
contract WiringTargetPortedMock is AccessManaged {
    address public stream;
    address public verifier;
    mapping(address token => bool listed) public isTarget;

    event Bound(bytes4 indexed selector, address peer);

    error AlreadyBound(bytes4 selector);
    error NotErc165(address peer);
    error Refused();

    constructor(address manager) AccessManaged(manager) { }

    function bindStream(address peer) external restricted {
        if (stream != address(0)) revert AlreadyBound(msg.sig);
        _checkErc165(peer);
        stream = peer;
        emit Bound(msg.sig, peer);
    }

    function setTarget(address token, bool listed) external restricted {
        _checkErc165(token);
        isTarget[token] = listed;
        emit Bound(msg.sig, token);
    }

    /// A genesis selector that always reverts with a reason.
    function setEntropyModule(address, address) external restricted {
        revert Refused();
    }

    /// A genesis selector (any target) that always reverts without data.
    function setOpeningBid(address, uint64, uint256) external restricted {
        assembly ("memory-safe") {
            revert(0, 0)
        }
    }

    /// Not a genesis selector: a 7-day verifier swap that wiring must refuse.
    function setVerifier(address next) external restricted {
        verifier = next;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IPackageRegistry).interfaceId
            || interfaceId == type(ISaleAdapter).interfaceId;
    }

    function _checkErc165(address peer) private view {
        if (!IERC165(peer).supportsInterface(type(IERC165).interfaceId)) revert NotErc165(peer);
    }
}

/// @notice Exposes the internal wiring validation, so a test can probe it with a configuration
///         the configurator would never accept (the manager as a target).
contract WiringValidationPortedHarness {
    function validateWiring(
        GovernanceConfig.Config memory cfg,
        GovernanceConfig.Call[] memory wiring
    ) external view {
        GovernanceConfig.validateWiring(cfg, wiring);
    }
}
