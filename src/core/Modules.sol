// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Minter, PendingModule } from "../interfaces/core/CoreTypes.sol";
import { IModuleSlots, IModules } from "../interfaces/core/IModules.sol";

/// @title ModuleSlots
/// @notice The seam between a permanent contract and its replaceable modules (ADR 0010): named
///         slots. The admin (the network) announces a module; anyone installs it once its
///         waiting period has passed; the admin removes one at once.
/// @dev The wait before an announced module or an added minter becomes active is `moduleDelay`,
///      a setting of the network: 7 days at deployment, changed at once by `setModuleDelay`,
///      zero allowed. It is not a fixed promise. A change applies to modules announced and
///      minters added after it; one already announced keeps the time it was given. The only
///      writes to a slot are the constructor of the inheriting contract (`_setModule`, for the
///      genesis modules), `activateModule` once the announced time has come, and
///      `removeModule`, which only empties a slot.
abstract contract ModuleSlots is AccessManaged, IModuleSlots {
    /// @inheritdoc IModuleSlots
    uint48 public moduleDelay = 7 days;

    mapping(bytes32 slot => address) private _modules;
    mapping(bytes32 slot => PendingModule) private _pending;

    /// @inheritdoc IModuleSlots
    function moduleOf(bytes32 slot) public view returns (address) {
        return _modules[slot];
    }

    /// @inheritdoc IModuleSlots
    function pendingModule(bytes32 slot) external view returns (PendingModule memory) {
        return _pending[slot];
    }

    /// @inheritdoc IModuleSlots
    function setModuleDelay(uint48 next) external {
        _checkModuleAdmin();
        emit ModuleDelaySet(moduleDelay, next);
        moduleDelay = next;
    }

    /// @inheritdoc IModuleSlots
    function proposeModule(bytes32 slot, address module) external {
        _checkModuleAdmin();
        if (module.code.length == 0) revert InvalidModule(module);
        uint48 readyAt = uint48(block.timestamp) + moduleDelay;
        _pending[slot] = PendingModule(module, readyAt);
        emit ModuleProposed(slot, module, readyAt);
    }

    /// @inheritdoc IModuleSlots
    function activateModule(bytes32 slot) external {
        PendingModule memory p = _pending[slot];
        if (p.readyAt == 0 || block.timestamp < p.readyAt) revert ModuleNotReady(slot);
        delete _pending[slot];
        _setModule(slot, p.module);
    }

    /// @inheritdoc IModuleSlots
    function removeModule(bytes32 slot) external {
        _checkModuleAdmin();
        delete _pending[slot];
        _setModule(slot, address(0));
    }

    /// @dev Who may announce and remove: by default whoever the AccessManager lets call the
    ///      function. A federated token overrides it with its artist's account.
    function _checkModuleAdmin() internal virtual {
        _checkCanCall(msg.sender, msg.data);
    }

    /// @dev Writes a slot. Called from constructors (genesis modules), `activateModule` and
    ///      `removeModule` only.
    function _setModule(bytes32 slot, address module) internal {
        emit ModuleSet(slot, _modules[slot], module);
        _modules[slot] = module;
    }

    /// @dev Reverts unless the caller is the module installed in `slot`.
    function _onlyModule(bytes32 slot) internal view {
        if (msg.sender != _modules[slot] || msg.sender == address(0)) {
            revert NotModule(slot, msg.sender);
        }
    }
}

/// @title Modules
/// @notice `ModuleSlots` plus the set of minters (sale contracts) of a token contract. A minter
///         is added with the same wait (`moduleDelay`, the network's setting) and removed at once.
/// @dev A removed minter keeps its record (`removedAt`), so it can still finish the sales it
///      started and the rescue and rebind waits can be counted from its removal.
abstract contract Modules is ModuleSlots, IModules {
    mapping(address minter => Minter) private _minters;

    /// @inheritdoc IModules
    function minterOf(address minter) external view returns (Minter memory) {
        return _minters[minter];
    }

    /// @inheritdoc IModules
    function isMinter(address account) public view returns (bool) {
        Minter memory m = _minters[account];
        return m.activeFrom != 0 && block.timestamp >= m.activeFrom && m.removedAt == 0;
    }

    /// @inheritdoc IModules
    function addMinter(address minter) external {
        _checkModuleAdmin();
        if (minter.code.length == 0) revert InvalidModule(minter);
        Minter memory m = _minters[minter];
        if (m.activeFrom != 0 && m.removedAt == 0) revert MinterAlreadyAdded(minter);
        _addMinter(minter, uint48(block.timestamp) + moduleDelay);
    }

    /// @inheritdoc IModules
    function removeMinter(address minter) external {
        _checkModuleAdmin();
        Minter storage m = _minters[minter];
        if (m.activeFrom == 0 || m.removedAt != 0) revert NotMinter(minter);
        m.removedAt = uint48(block.timestamp);
        emit MinterRemoved(minter);
    }

    /// @dev True for a minter that is or was active: a removed minter still settles its sales.
    ///      A minter still waiting to become active is not one.
    function _wasActiveMinter(address account) internal view returns (bool) {
        uint48 activeFrom = _minters[account].activeFrom;
        return activeFrom != 0 && block.timestamp >= activeFrom;
    }

    /// @dev When `account` was removed, or zero.
    function _removedAtOf(address account) internal view returns (uint256) {
        return _minters[account].removedAt;
    }

    /// @dev Records a minter. Called from constructors (genesis minters, active at once) and
    ///      `addMinter` only.
    function _addMinter(address minter, uint48 activeFrom) internal {
        _minters[minter] = Minter(activeFrom, 0);
        emit MinterAdded(minter, activeFrom);
    }
}
