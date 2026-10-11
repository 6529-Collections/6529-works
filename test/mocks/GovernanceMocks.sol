// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { BoundedParameter } from "src/governance/BoundedParameter.sol";

/// @notice Sample governed target showing the patterns every 6529 Works target follows:
///         `restricted` non-payable setters, one selector per delay class, separate pause and
///         unpause selectors, compare-and-set on recipient and verifier setters, a raise-only
///         gas parameter with an absolute ceiling, and old/new events on every setter.
contract GovernedTargetMock is AccessManaged {
    uint256 public constant GAS_CEILING = 2_000_000;

    bool public paused;
    uint256 public fee;
    address public recipient;
    address public verifier;
    uint256 public callbackGas;
    uint256 public vetoes;
    uint256 public keeps;
    uint256 public adminCalls;

    event PausedSet(bool paused);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event RecipientUpdated(address oldRecipient, address newRecipient);
    event VerifierUpdated(address oldVerifier, address newVerifier);
    event CallbackGasUpdated(uint256 oldGas, uint256 newGas);
    event Vetoed(bytes32 id);

    error StaleValue(address expected, address current);
    error PauseUnchanged(bool paused);

    constructor(address manager, address recipient_, address verifier_) AccessManaged(manager) {
        recipient = recipient_;
        verifier = verifier_;
        callbackGas = BoundedParameter.initial(100_000, GAS_CEILING);
    }

    /// Immediate class (PAUSER). Tightening only.
    function pause() external restricted {
        if (paused) revert PauseUnchanged(true);
        paused = true;
        emit PausedSet(true);
    }

    /// Standard class (UNPAUSER), so a guardian can cancel a hostile unpause.
    function unpause() external restricted {
        if (!paused) revert PauseUnchanged(false);
        paused = false;
        emit PausedSet(false);
    }

    /// Standard class (PARAMETER_SETTER).
    function setFee(uint256 newFee) external restricted {
        emit FeeUpdated(fee, newFee);
        fee = newFee;
    }

    /// Funds-and-recipients class (FUNDS_SETTER), compare-and-set.
    function setRecipient(address expected, address newRecipient) external restricted {
        if (recipient != expected) revert StaleValue(expected, recipient);
        emit RecipientUpdated(recipient, newRecipient);
        recipient = newRecipient;
    }

    /// Successor class (SUCCESSOR_SETTER), compare-and-set.
    function setVerifier(address expected, address newVerifier) external restricted {
        if (verifier != expected) revert StaleValue(expected, verifier);
        emit VerifierUpdated(verifier, newVerifier);
        verifier = newVerifier;
    }

    /// Standard class (PARAMETER_SETTER); direction and step enforced here.
    function raiseCallbackGas(uint256 newGas) external restricted {
        uint256 old = callbackGas;
        callbackGas = BoundedParameter.raise(old, newGas, GAS_CEILING);
        emit CallbackGasUpdated(old, newGas);
    }

    /// Immediate guardian veto (GUARDIAN), such as a dispute pause.
    function veto(bytes32 id) external restricted {
        ++vetoes;
        emit Vetoed(id);
    }

    /// Immediate upkeep (KEEPER).
    function keep() external restricted {
        ++keeps;
    }

    /// Deliberately unmapped: falls back to ADMIN and its 30-day execution delay.
    function adminOnly() external restricted {
        ++adminCalls;
    }
}

/// @notice A governed function that wrongly accepts value; the non-payable probe must flag it.
contract PayableGovernedMock is AccessManaged {
    constructor(address manager) AccessManaged(manager) { }

    function deposit(uint256 tag) external payable restricted {
        tag;
    }
}

/// @notice A contract with no `authority()`; the configurator must reject it as a target.
contract UnmanagedMock {
    function ping() external pure returns (uint256) {
        return 1;
    }
}
