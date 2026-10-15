// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";

/// @notice A peer that answers ERC-165, like the contracts a genesis bind checks.
contract Erc165PeerMock is IERC165 {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice A target exposing genesis selectors as `restricted` one-shot binds, admitted
///         minters and sale targets (each peer must pass an ERC-165 check), two genesis binds
///         that always revert, and a 30-day-class setter that wiring must not reach.
contract WiringTargetMock is AccessManaged {
    address public workRecords;
    address public editions;
    address public verifier;
    mapping(address minter => bool admitted) public isAdmittedMinter;
    mapping(address token => bool listed) public isTarget;

    event Bound(bytes4 indexed selector, address peer);

    error AlreadyBound(bytes4 selector);
    error NotErc165(address peer);
    error Refused();

    constructor(address manager) AccessManaged(manager) { }

    function bindWorkRecords(address peer) external restricted {
        workRecords = _bind(workRecords, peer);
    }

    function bindEditions(address peer) external restricted {
        editions = _bind(editions, peer);
    }

    function setAdmittedMinter(address minter, bool admitted) external restricted {
        _checkErc165(minter);
        isAdmittedMinter[minter] = admitted;
        emit Bound(msg.sig, minter);
    }

    function setTarget(address token, bool listed) external restricted {
        _checkErc165(token);
        isTarget[token] = listed;
        emit Bound(msg.sig, token);
    }

    /// A genesis selector that always reverts with a reason.
    function bindPackageRegistry(address) external restricted {
        revert Refused();
    }

    /// A genesis selector that always reverts without data.
    function bindSplitFactory(address) external restricted {
        assembly ("memory-safe") {
            revert(0, 0)
        }
    }

    /// Not a genesis selector: a 30-day verifier swap that wiring must refuse.
    function setVerifier(address next) external restricted {
        verifier = next;
    }

    function _bind(address current, address peer) private returns (address) {
        if (current != address(0)) revert AlreadyBound(msg.sig);
        _checkErc165(peer);
        emit Bound(msg.sig, peer);
        return peer;
    }

    function _checkErc165(address peer) private view {
        if (!IERC165(peer).supportsInterface(type(IERC165).interfaceId)) revert NotErc165(peer);
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

/// @notice Exposes the internal wiring validation, so tests can probe it with a configuration
///         the configurator itself would never accept (for example the manager as a target).
contract WiringValidationHarness {
    function validateWiring(
        GovernanceConfig.Config memory cfg,
        GovernanceConfig.Call[] memory wiring
    ) external pure {
        GovernanceConfig.validateWiring(cfg, wiring);
    }
}
