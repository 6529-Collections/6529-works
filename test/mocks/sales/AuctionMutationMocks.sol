// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { MintFacts } from "src/interfaces/core/CoreTypes.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";

/// @notice An economics resolver stand-in for the auction's constructor checks: it names any
///         asset allowlist and declares `IEconomicsResolver` only when told to.
contract LooseEconomics {
    address public assetAllowlist;
    bool public declares;

    constructor(address assetAllowlist_, bool declares_) {
        (assetAllowlist, declares) = (assetAllowlist_, declares_);
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        if (!declares) return false;
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IEconomicsResolver).interfaceId;
    }
}

/// @notice A token that mints with a receiver callback: it asks the receiver's
///         `onERC721Received` as a safe mint does and refuses the mint on any other answer.
contract SafeMintingToken {
    mapping(uint256 => address) public ownerOf;

    function isMinter(address) external pure returns (bool) {
        return true;
    }

    function mint(address to, MintFacts calldata) external returns (uint256) {
        ownerOf[1] = to;
        bytes4 answer = IERC721Receiver(to).onERC721Received(msg.sender, address(0), 1, "");
        require(answer == IERC721Receiver.onERC721Received.selector, "receiver refused");
        return 1;
    }
}
