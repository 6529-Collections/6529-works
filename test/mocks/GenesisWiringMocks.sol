// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice A peer that answers ERC-165, like the contracts a genesis bind checks.
contract Erc165PeerMock is IERC165 {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice A target with `restricted` one-shot binds, shaped like `IStream.bindWorkRecords`:
///         each slot binds once, to a peer that passes an ERC-165 check.
contract WiringTargetMock is AccessManaged {
    mapping(uint256 slot => address peer) public bound;

    event Bound(uint256 indexed slot, address peer);

    error AlreadyBound(uint256 slot);
    error NotErc165(address peer);
    error Refused();

    constructor(address manager) AccessManaged(manager) { }

    function bind(uint256 slot, address peer) external restricted {
        if (bound[slot] != address(0)) revert AlreadyBound(slot);
        if (!IERC165(peer).supportsInterface(type(IERC165).interfaceId)) revert NotErc165(peer);
        bound[slot] = peer;
        emit Bound(slot, peer);
    }

    /// Always reverts, to prove a failing wiring call aborts the whole configuration.
    function refuse() external restricted {
        revert Refused();
    }

    /// Reverts with no data, to prove the configurator names the failing wiring call.
    function silent() external restricted {
        assembly ("memory-safe") {
            revert(0, 0)
        }
    }
}

/// @notice Stands in for a v1 contract at a genesis placeholder address. It answers every
///         call, checks the AccessManager exactly as `restricted` does, and accepts each
///         distinct call once, like a one-shot bind. The authority is an immutable, so the
///         runtime code can be etched at any address and still point at the manager.
contract GenesisTargetMock is AccessManaged {
    address private immutable _manager;
    mapping(bytes32 call => bool done) public called;

    error AlreadyCalled(bytes4 selector);

    constructor(address manager) AccessManaged(manager) {
        _manager = manager;
    }

    function authority() public view override returns (address) {
        return _manager;
    }

    fallback() external {
        _checkCanCall(_msgSender(), _msgData());
        bytes32 key = keccak256(msg.data);
        if (called[key]) revert AlreadyCalled(bytes4(msg.data));
        called[key] = true;
    }
}
