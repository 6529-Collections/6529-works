// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Slots } from "../interfaces/core/CoreTypes.sol";
import { IModules, IModuleSlots } from "../interfaces/core/IModules.sol";
import { Modules } from "./Modules.sol";
import { StreamBase } from "./StreamBase.sol";

/// @title Stream
/// @notice 6529 Stream: the one shared, network-curated ERC-721 of 1/1s (ADR 0010). `StreamBase`
///         with its own minter list and module slots (`Modules`); the admin is the network,
///         through the AccessManager.
/// @dev Genesis modules and minters are constructor arguments, active at once and unchecked
///      (the deployment predicts their CREATE2 addresses, so they may have no code yet). Every
///      later module or minter goes through `moduleDelay`, the network's setting in force when it
///      is announced or added. The network's functions here (`createCollection`, `setOwner`,
///      `setContractURI`, `rescue`, `setRescueDelay` and those of `Modules`) are whatever the
///      AccessManager lets call them.
contract Stream6529 is StreamBase, Modules {
    /// @param authority_ The AccessManager.
    /// @param facts_ The permanent record contract (`IWorkFacts`).
    /// @param owner_ The first marketplace owner.
    /// @param renderer_ The genesis RENDERER module.
    /// @param terms_ The genesis TERMS module.
    /// @param records_ The genesis RECORDS module.
    /// @param minters_ The genesis minters (sale contracts), active at once.
    constructor(
        address authority_,
        address facts_,
        address owner_,
        address renderer_,
        address terms_,
        address records_,
        address[] memory minters_
    ) StreamBase("6529 Stream", "6529STREAM", facts_, owner_) AccessManaged(authority_) {
        _setModule(Slots.RENDERER, renderer_);
        _setModule(Slots.TERMS, terms_);
        _setModule(Slots.RECORDS, records_);
        for (uint256 i; i < minters_.length; ++i) {
            _addMinter(minters_[i], uint48(block.timestamp));
        }
    }

    /// @inheritdoc StreamBase
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IModules).interfaceId
            || interfaceId == type(IModuleSlots).interfaceId || super.supportsInterface(interfaceId);
    }

    function _moduleOf(bytes32 slot) internal view override returns (address) {
        return moduleOf(slot);
    }

    function _isMinter(address account) internal view override returns (bool) {
        return isMinter(account);
    }

    function _wasMinter(address account) internal view override returns (bool) {
        return _wasActiveMinter(account);
    }

    function _minterRemovedAt(address account) internal view override returns (uint256) {
        return _removedAtOf(account);
    }

    function _checkAdmin() internal override {
        _checkCanCall(msg.sender, msg.data);
    }

    function _checkNetwork() internal override {
        _checkCanCall(msg.sender, msg.data);
    }
}
