// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { EditionsBase } from "../core/EditionsBase.sol";
import { IIndependentStreamMembership } from "../interfaces/IIndependentStreamMembership.sol";
import { Slots } from "../interfaces/core/CoreTypes.sol";
import { IndependentStreamMembership } from "./IndependentStreamMembership.sol";

/// @title IndependentStreamEditions6529
/// @notice An Independent Stream artist's own ERC-1155 of editions, the partner of one
///         `IndependentStream6529`: the same plain permanent contract as 6529 Stream Editions
///         (`EditionsBase`) with a different gate (ADR 0010). Permanent once deployed: a full
///         contract, never behind a proxy or a clone.
/// @dev What differs from 6529 Stream Editions, all through the hooks of `EditionsBase`:
///      - Minters: whoever the Independent Stream module the directory names says may mint for this
///        contract (`IIndependentStreamGate.canMint`); an empty INDEPENDENT_STREAM slot stops
///        creating and minting unsealed editions. A sealed edition is minted by its own sale
///        contract whatever the module says, so removing a sale contract never strands its winners.
///      - Rebind: the network moves an edition with no copies and no seal to another sale
///        contract once `rebindDelay` (the network's setting) has passed since the Independent
///        Stream module removed its own.
///      - TERMS: the directory's shared `INDEPENDENT_TERMS`.
///      - Admin: any wallet of the artist's account (the collection page).
///      - Network: whoever the directory's AccessManager lets call the same function on the
///        directory at once (`rebind`, `setRebindDelay`): only a direct call by a member of a
///        role with no execution delay; a call through the manager's `execute`, or by a role
///        with a delay, is refused.
///      An edition's ID is its master's token ID in the partner `stream`, and `uri` is drawn by
///      the master's renderer.
contract IndependentStreamEditions6529 is EditionsBase, IndependentStreamMembership {
    /// @notice The ERC-1155 collection name.
    string public name;
    /// @notice The ERC-1155 collection symbol.
    string public symbol;

    /// @param name_ The collection name.
    /// @param symbol_ The collection symbol.
    /// @param stream_ The partner `IndependentStream6529` of masters, nonzero.
    /// @param directory_ The permanent directory, nonzero.
    /// @param artistId_ The artist, nonzero and at most 160 bits.
    /// @param owner_ The first marketplace owner.
    constructor(
        string memory name_,
        string memory symbol_,
        address stream_,
        address directory_,
        uint256 artistId_,
        address owner_
    ) EditionsBase(stream_, owner_) IndependentStreamMembership(directory_, artistId_) {
        if (stream_ == address(0)) revert InvalidConfig();
        name = name_;
        symbol = symbol_;
    }

    /// @notice The module of `slot` for this contract: TERMS is the directory's
    ///         `INDEPENDENT_TERMS`; every other slot is zero.
    /// @param slot The slot.
    /// @return The module.
    function moduleOf(bytes32 slot) public view returns (address) {
        return slot == Slots.TERMS ? _sharedModule(slot) : address(0);
    }

    /// @inheritdoc IIndependentStreamMembership
    function isMinter(address account) external view returns (bool) {
        return _gateCanMint(account);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IIndependentStreamMembership).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------------------- hooks

    function _moduleOf(bytes32 slot) internal view override returns (address) {
        return moduleOf(slot);
    }

    function _isMinter(address account) internal view override returns (bool) {
        return _gateCanMint(account);
    }

    function _minterRemovedAt(address account) internal view override returns (uint256) {
        return _gateRemovedAt(account);
    }

    function _checkAdmin() internal view override {
        _requireArtist();
    }

    function _checkNetwork() internal view override {
        _requireNetwork();
    }
}
