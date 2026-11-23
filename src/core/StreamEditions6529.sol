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
/// @dev Its minters are the edition sale contracts the network adds, each active after the
///      network's waiting period (`moduleDelay`) and removed at once; its one module slot is
///      TERMS (royalties). The network, through the AccessManager, is the admin (`setOwner`,
///      `setContractURI`, the module and minter functions) and alone may `rebind` and
///      `setRebindDelay`.
contract StreamEditions6529 is EditionsBase, Modules {
    /// @notice The ERC-1155 collection name.
    string public constant name = "6529 Stream Editions";
    /// @notice The ERC-1155 collection symbol.
    string public constant symbol = "6529STREAMEDITIONS";

    /// @param authority_ The AccessManager.
    /// @param stream_ 6529 Stream.
    /// @param owner_ The first marketplace owner.
    /// @param terms_ The genesis TERMS module.
    /// @param minters_ The genesis minters (edition sale contracts), active at once: genesis
    ///        minters are deployed at predicted addresses, so they are named here rather than
    ///        added later with the wait.
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
