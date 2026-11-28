// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";

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

