// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IRenderer } from "src/interfaces/IRenderer.sol";

/// @title RendererStandIn
/// @notice LOCAL DRY RUNS ONLY. Stands in for the content lane's `Renderer` (#20) until it
///         merges, so 6529 Stream, which pins its default renderer and that renderer's code hash
///         at construction, can be deployed and wired on `main`. It answers ERC-165 for
///         `IRenderer` and returns empty metadata. `DeployV1` refuses to deploy it outside
///         chain 31337.
contract RendererStandIn is IRenderer {
    function tokenURI(address, uint256) external pure returns (string memory) {
        return "";
    }

    function fullTokenURI(address, uint256) external pure returns (string memory) {
        return "";
    }

    function inlineThreshold() external pure returns (uint256) {
        return 256 * 1024;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IRenderer).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
