// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Mocks for the integration lane (lane B).

/// @dev A wallet that can be told to refuse ETH, and that never implements
///      `onERC721Received`, so a `safeTransferFrom` to it always fails: a Safe-like recipient
///      whose fallback reverts, or a bidder contract that cannot take the NFT.
contract RefusingWallet {
    bool public refuse;

    function setRefuse(bool value) external {
        refuse = value;
    }

    /// @dev Forwards a call, so the wallet can bid and claim like a contract account.
    function exec(address target, uint256 value, bytes calldata data) external payable {
        (bool ok, bytes memory reason) = target.call{ value: value }(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    receive() external payable {
        require(!refuse, "refusing ETH");
    }
}
