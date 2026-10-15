// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DelegationManagementMock } from "./DelegationManagementMock.sol";

/// @notice Forwards the two getters the consolidation adapter reads to the faithful delegation
///         mock, and can misbehave first: burn extra gas (standing in for a gas schedule that
///         reprices cold reads), revert with data, or return oversized data. An index past the
///         end of an array reverts with no data, as the mock and the deployed contract do.
contract RepricedDelegationMock {
    enum Mode {
        FORWARD,
        REVERT_WITH_DATA,
        OVERSIZED
    }

    error Unavailable();

    DelegationManagementMock public immutable inner;
    uint256 public extraGas;
    Mode public mode;

    constructor(DelegationManagementMock inner_) {
        inner = inner_;
    }

    function setExtraGas(uint256 extra) external {
        extraGas = extra;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function delegatorHashes(bytes32 key, uint256 index) external view returns (address) {
        _misbehave();
        return inner.delegatorHashes(key, index);
    }

    function globalDelegationHashes(bytes32 key, uint256 index)
        external
        view
        returns (address, address, uint256, uint256, bool, uint256)
    {
        _misbehave();
        return inner.globalDelegationHashes(key, index);
    }

    function _misbehave() private view {
        uint256 target = gasleft() > extraGas ? gasleft() - extraGas : 0;
        while (gasleft() > target) { }
        Mode m = mode;
        if (m == Mode.REVERT_WITH_DATA) revert Unavailable();
        if (m == Mode.OVERSIZED) {
            assembly ("memory-safe") {
                return(0, 512)
            }
        }
    }
}
