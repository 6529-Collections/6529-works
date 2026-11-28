// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice A bidder and recipient for the lifecycle suite that misbehaves when it is paid or
///         handed a work: it reverts, burns all the gas it was given, or re-enters a target once
///         (the call its handler armed) and then accepts. It records what its re-entry returned.
/// @dev `execute` lets anyone route a call through it, so the suite can model a third party
///      that tries to use a recipient's address.
contract LifecycleHostileActor {
    enum Behaviour {
        REVERT,
        BURN_GAS,
        REENTER
    }

    Behaviour public onEth;
    Behaviour public onToken;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentered;
    bool public reentryOk;
    bytes public reentryResult;

    function configure(Behaviour eth, Behaviour token) external {
        (onEth, onToken) = (eth, token);
    }

    /// @notice Arms one re-entry and clears what the last one recorded.
    function setReentry(address target, bytes calldata data) external {
        (reentryTarget, reentryData) = (target, data);
        (reentered, reentryOk) = (false, false);
        delete reentryResult;
    }

    /// @notice Calls `target` with `value` and `data`; a failure is passed on unchanged.
    function execute(address target, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory result)
    {
        bool ok;
        (ok, result) = target.call{ value: value }(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    receive() external payable {
        _misbehave(onEth);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        _misbehave(onToken);
        return this.onERC721Received.selector;
    }

    function _misbehave(Behaviour b) private {
        if (b == Behaviour.REVERT) revert("hostile: refused");
        if (b == Behaviour.BURN_GAS) {
            while (true) { }
        }
        if (reentered || reentryTarget == address(0)) return;
        reentered = true;
        (reentryOk, reentryResult) = reentryTarget.call(reentryData);
    }
}
