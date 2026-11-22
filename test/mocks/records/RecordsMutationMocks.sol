// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IStream } from "src/interfaces/IStream.sol";

/// @dev A token that declares `IStream` by ERC-165 and whose `coreOf` reverts with the exact
///      bytes the test sets.
contract RawRevertStreamCore {
    bytes internal _reason;

    function setReason(bytes calldata reason) external {
        _reason = reason;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == type(IStream).interfaceId;
    }

    function coreOf(uint256)
        external
        view
        returns (bytes32, uint256, uint256, uint8, uint8, uint32)
    {
        bytes memory reason = _reason;
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}

/// @dev An authority whose `canCall` answers "immediate" for every call, with the execution delay
///      the test sets: an answer OpenZeppelin's AccessManager never gives, but a replacement
///      authority could.
contract ImmediateWithDelayAuthority {
    uint32 public delay;

    function setDelay(uint32 delay_) external {
        delay = delay_;
    }

    function canCall(address, address, bytes4) external view returns (bool, uint32) {
        return (true, delay);
    }
}
