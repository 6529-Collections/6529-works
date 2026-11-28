// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { Minter, PendingModule } from "./CoreTypes.sol";

/// @title IModuleSlots
/// @notice Named slots for the replaceable modules of a permanent contract. The network adds a
///         module after a waiting period it sets (7 days at launch), and removes one at once.
interface IModuleSlots {
    /// @notice A module was announced for `slot`; anyone may install it from `readyAt`.
    /// @param slot The slot.
    /// @param module The announced module.
    /// @param readyAt When it may be installed.
    event ModuleProposed(bytes32 indexed slot, address module, uint48 readyAt);
    /// @notice The module of `slot` changed (`module` zero: removed).
    /// @param slot The slot.
    /// @param previous The module before.
    /// @param module The module now.
    event ModuleSet(bytes32 indexed slot, address previous, address module);
    /// @notice The announcement of `module` for `slot` was withdrawn; the installed module stays.
    /// @param slot The slot.
    /// @param module The module that was announced.
    event ModuleCancelled(bytes32 indexed slot, address module);

    /// @notice The wait for modules and minters added from now on was set: by the network, or
    ///         at deployment with its launch value (`previous` zero).
    /// @param previous The wait before.
    /// @param next The wait now.
    event ModuleDelaySet(uint48 previous, uint48 next);

    /// @notice No module is announced for the slot, or its wait has not passed.
    error ModuleNotReady(bytes32 slot);
    /// @notice The caller is not the module of the slot.
    error NotModule(bytes32 slot, address caller);
    /// @notice The announced module or minter is the zero address or has no code.
    error InvalidModule(address module);

    /// @notice The wait between announcing a module (or adding a minter) and its first use.
    ///         A setting of the network, 7 days at deployment; not a fixed promise.
    /// @return The wait, in seconds.
    function moduleDelay() external view returns (uint48);

    /// @notice Sets the wait, at once. The contract's admin only (the network). Zero is
    ///         allowed. A module already announced, or a minter already added, keeps the time
    ///         it was given. A wait that takes the current time plus the wait past 2^48 seconds
    ///         makes every announcement and addition revert until it is lowered.
    /// @param next The new wait, in seconds.
    function setModuleDelay(uint48 next) external;

    /// @notice The module installed in `slot`, or zero.
    /// @param slot The slot.
    /// @return The module.
    function moduleOf(bytes32 slot) external view returns (address);

    /// @notice The module announced for `slot` and not yet installed.
    /// @param slot The slot.
    /// @return The announcement (`readyAt` zero: none).
    function pendingModule(bytes32 slot) external view returns (PendingModule memory);

    /// @notice Announces `module` for `slot`. The contract's admin only (the network). Replaces
    ///         any earlier announcement for the slot and restarts the wait.
    /// @param slot The slot.
    /// @param module The module: nonzero, with code.
    function proposeModule(bytes32 slot, address module) external;

    /// @notice Withdraws the announcement for `slot`; the installed module stays. The admin only.
    ///         Reverts with `ModuleNotReady` if nothing is announced.
    /// @param slot The slot.
    function cancelModule(bytes32 slot) external;

    /// @notice Installs the module announced for `slot` once its wait has passed. Anyone.
    /// @param slot The slot.
    function activateModule(bytes32 slot) external;

    /// @notice Removes the module of `slot`, and any announcement for it, at once. The admin only.
    /// @param slot The slot.
    function removeModule(bytes32 slot) external;
}

/// @title IModules
/// @notice Module slots and the set of minters (sale contracts) of a token contract.
interface IModules is IModuleSlots {
    /// @notice A minter was added; it may mint from `activeFrom`.
    /// @param minter The minter.
    /// @param activeFrom When it may first mint.
    event MinterAdded(address indexed minter, uint48 activeFrom);
    /// @notice A minter was removed: it mints nothing new. It still finishes what it started.
    ///         Removed before it was ever active (before its first `activeFrom`), its record is
    ///         deleted instead: a cancelled addition, which never counts as a minter.
    /// @param minter The minter.
    event MinterRemoved(address indexed minter);

    /// @notice The caller is not an active minter.
    error NotMinter(address caller);
    /// @notice The minter is already added and not removed.
    error MinterAlreadyAdded(address minter);

    /// @notice A minter's standing.
    /// @param minter The minter.
    /// @return Its standing.
    function minterOf(address minter) external view returns (Minter memory);

    /// @notice Whether `account` may mint now: added, past its wait, and not removed.
    /// @param account The account.
    /// @return True if it may mint.
    function isMinter(address account) external view returns (bool);

    /// @notice Adds a minter, active after `moduleDelay`. The network only. A removed minter may
    ///         be added again, with a new wait.
    /// @param minter The minter: nonzero, with code.
    function addMinter(address minter) external;

    /// @notice Removes a minter at once. The network only. A minter that was never active loses
    ///         its record (a cancellation); one that was active keeps it, with `removedAt`, and
    ///         finishes the sales it started.
    /// @param minter An added minter that is not removed.
    function removeMinter(address minter) external;
}
