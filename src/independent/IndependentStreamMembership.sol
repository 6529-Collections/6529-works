// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IIndependentStreamMembership } from "../interfaces/IIndependentStreamMembership.sol";
import { Slots } from "../interfaces/core/CoreTypes.sol";
import { IAccounts } from "../interfaces/core/IAccounts.sol";
import { IIndependentStreamGate } from "../interfaces/core/IIndependentStreamGate.sol";
import { IModuleSlots } from "../interfaces/core/IModules.sol";

/// @title IndependentStreamMembership
/// @notice What both Independent Stream token contracts share: the artist, the permanent directory,
///         and the answers the token bases' hooks need from them (ADR 0010: the same plain token
///         with a different gate).
/// @dev Inherited source, never deployed alone. Every answer is a plain call to the directory or
///      to a module it names; a failing call reverts the whole call, so no default is ever read
///      from a failure. The one exception is a missing module: an empty INDEPENDENT_STREAM slot
///      answers "may not mint", so nothing new is minted or created, and the editions contract
///      then reads every sale contract as removed, so nothing new is sealed either. Transfers,
///      and the minting of an edition sealed before, ask no module. The module is also what
///      knows which sale contracts it removed: while the slot is empty the ERC-721 reads a sale
///      contract as never removed, so `rescue` waits, and no edition is rebound. A module that
///      replaces another carries the removals over; the network replaces the module rather than
///      leave the slot empty (`docs/operations/replacing-modules.md`).
abstract contract IndependentStreamMembership is IIndependentStreamMembership {
    /// @inheritdoc IIndependentStreamMembership
    address public immutable directory;
    /// @inheritdoc IIndependentStreamMembership
    uint256 public immutable artistId;

    /// @param directory_ The permanent directory (nonzero).
    /// @param artistId_ The artist (nonzero, at most 160 bits).
    constructor(address directory_, uint256 artistId_) {
        if (directory_ == address(0) || artistId_ == 0 || artistId_ > type(uint160).max) {
            revert InvalidConfig();
        }
        directory = directory_;
        artistId = artistId_;
    }

    /// @dev The directory's module of `slot`, or zero.
    function _directoryModule(bytes32 slot) internal view returns (address) {
        return IModuleSlots(directory).moduleOf(slot);
    }

    /// @dev A shared module of Independent Stream tokens: TERMS is the directory's
    ///      `INDEPENDENT_TERMS`, RECORDS its `INDEPENDENT_RECORDS`; any other slot is zero here.
    function _sharedModule(bytes32 slot) internal view returns (address) {
        if (slot == Slots.TERMS) return _directoryModule(Slots.INDEPENDENT_TERMS);
        if (slot == Slots.RECORDS) return _directoryModule(Slots.INDEPENDENT_RECORDS);
        return address(0);
    }

    /// @dev Whether the Independent Stream module lets `account` mint for this token now; false
    ///      while the INDEPENDENT_STREAM slot is empty.
    function _gateCanMint(address account) internal view returns (bool) {
        address gate = _directoryModule(Slots.INDEPENDENT_STREAM);
        return gate != address(0) && IIndependentStreamGate(gate).canMint(address(this), account);
    }

    /// @dev When the Independent Stream module removed `account` as a sale contract; zero while the
    ///      INDEPENDENT_STREAM slot is empty.
    function _gateRemovedAt(address account) internal view returns (uint256) {
        address gate = _directoryModule(Slots.INDEPENDENT_STREAM);
        return gate == address(0) ? 0 : IIndependentStreamGate(gate).minterRemovedAt(account);
    }

    /// @dev Reverts unless the caller is a wallet of the artist's account now, as the accounts
    ///      module answers (`IAccounts.isWallet`): any wallet of the consolidated account, none
    ///      while it is frozen or being replaced. An empty ACCOUNTS slot refuses everyone.
    function _requireArtist() internal view {
        address accounts = _directoryModule(Slots.ACCOUNTS);
        if (accounts == address(0) || !IAccounts(accounts).isWallet(artistId, msg.sender)) {
            revert NotArtist(msg.sender);
        }
    }

    /// @dev Reverts unless the directory's AccessManager lets the caller call this same function
    ///      on the directory at once (`IAccessManager.canCall`, immediate). The network maps the
    ///      token functions it holds (`rescue`, `setRescueDelay`, `rebind`, `setRebindDelay`,
    ///      `setModuleDelay`) on the directory target once, for every Independent Stream token.
    ///      Only a direct call by a member of a role with no execution delay passes: a role with a
    ///      delay is refused, and so is a call relayed by the manager's `execute` (the manager is
    ///      then the caller). One selector on the directory target governs both
    ///      `StreamDirectory6529.setModuleDelay` and every Independent Stream token's
    ///      `setModuleDelay`.
    function _requireNetwork() internal view {
        address manager = IAccessManaged(directory).authority();
        (bool immediate,) = IAccessManager(manager).canCall(msg.sender, directory, msg.sig);
        if (!immediate) revert NotNetwork(msg.sender);
    }
}
