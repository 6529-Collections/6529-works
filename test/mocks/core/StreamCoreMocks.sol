// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice A stand-in for `IWorkFacts.rendererOf` whose answer the test sets: a pinned renderer,
///         none, or a revert (as `StreamWorkFacts6529` reverts when a pinned renderer's code
///         changed).
contract MockPinnedFacts {
    mapping(address token => mapping(uint256 id => address)) public pinned;
    bool public fails;

    error PinnedCodeChanged();

    function pin(address token, uint256 id, address renderer) external {
        pinned[token][id] = renderer;
    }

    function setFails(bool fails_) external {
        fails = fails_;
    }

    function rendererOf(address token, uint256 id) external view returns (address) {
        if (fails) revert PinnedCodeChanged();
        return pinned[token][id];
    }
}

/// @notice A sale contract that delivers with `safeTransferFrom`, so the buyer's receiver hook
///         runs (and can try to re-enter).
contract SafeDeliverySale {
    function safeSend(address token, uint256 id, address to) external {
        IERC721(token).safeTransferFrom(address(this), to, id);
    }
}

/// @notice A contract that refuses every ERC-721 it is sent with a callback.
contract RefusingReceiver {
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("refused");
    }
}

/// @notice An accounts module that misbehaves on `payoutAddress`: it answers, reverts, burns all
///         its gas or returns nothing.
contract HostileAccounts {
    enum Mode {
        ANSWER,
        REVERT,
        BURN_GAS,
        EMPTY
    }

    Mode public mode;
    address public answer = address(0xBAD);

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function payoutAddress(uint256) external view returns (address) {
        if (mode == Mode.REVERT) revert("hostile");
        if (mode == Mode.BURN_GAS) {
            uint256 x;
            while (true) {
                ++x;
            }
        }
        if (mode == Mode.EMPTY) {
            // A function that returns no data where an address is expected.
            return _empty();
        }
        return answer;
    }

    function _empty() private pure returns (address) {
        // Low-level: stop with empty return data.
        assembly {
            return(0, 0)
        }
    }
}
