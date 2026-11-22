// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Slots } from "../interfaces/core/CoreTypes.sol";
import { IModules, IModuleSlots } from "../interfaces/core/IModules.sol";
import { EditionsBase } from "./EditionsBase.sol";
import { Modules } from "./Modules.sol";

/// @title Editions
/// @notice 6529 Stream Editions: the one shared ERC-1155 of editions (ADR 0010). `EditionsBase`
///         with its own minter list and TERMS slot (`Modules`); the admin is the network.
/// @dev lane 2 completes this.
contract Editions is EditionsBase, Modules {
    /// @notice The ERC-1155 collection name.
    string public constant name = "6529 Stream Editions";
    /// @notice The ERC-1155 collection symbol.
    string public constant symbol = "STREAMEDITIONS";

    /// @param authority_ The AccessManager.
    /// @param stream_ 6529 Stream.
    /// @param owner_ The first marketplace owner.
    /// @param terms_ The genesis TERMS module.
    /// @param minters_ The genesis minters (edition sale contracts), active at once.
    constructor(
        address authority_,
        address stream_,
        address owner_,
        address terms_,
        address[] memory minters_
    ) EditionsBase(stream_, owner_) AccessManaged(authority_) {
        _setModule(Slots.TERMS, terms_);
        for (uint256 i; i < minters_.length; ++i) {
            _addMinter(minters_[i], uint48(block.timestamp));
        }
    }

    /// @inheritdoc EditionsBase
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
