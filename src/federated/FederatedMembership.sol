// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IFederatedMembership } from "../interfaces/IFederatedMembership.sol";
import { Slots } from "../interfaces/core/CoreTypes.sol";
import { IAccounts } from "../interfaces/core/IAccounts.sol";
import { IFederationGate } from "../interfaces/core/IFederationGate.sol";
import { IModuleSlots } from "../interfaces/core/IModules.sol";

/// @title FederatedMembership
/// @notice What both federated token contracts share: the artist, the permanent directory, and
///         the answers the token bases' hooks need from them (ADR 0010: the same plain token
///         with a different gate).
/// @dev Inherited source, never deployed alone. Every answer is a plain call to the directory or
///      to a module it names; a failing call reverts the whole call, so no default is ever read
///      from a failure. The one exception is a missing module: an empty FEDERATION slot answers
///      "may not mint" and "never removed", so a missing gate stops minting only.
abstract contract FederatedMembership is IFederatedMembership {
    /// @inheritdoc IFederatedMembership
    address public immutable directory;
    /// @inheritdoc IFederatedMembership
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

    /// @dev A shared module of federated tokens: TERMS is the directory's `FEDERATED_TERMS`,
    ///      RECORDS its `FEDERATED_RECORDS`; any other slot is zero here.
    function _sharedModule(bytes32 slot) internal view returns (address) {
        if (slot == Slots.TERMS) return _directoryModule(Slots.FEDERATED_TERMS);
        if (slot == Slots.RECORDS) return _directoryModule(Slots.FEDERATED_RECORDS);
        return address(0);
    }

    /// @dev Whether the federation module lets `account` mint for this token now; false while
    ///      the FEDERATION slot is empty.
    function _gateCanMint(address account) internal view returns (bool) {
        address gate = _directoryModule(Slots.FEDERATION);
        return gate != address(0) && IFederationGate(gate).canMint(address(this), account);
    }

    /// @dev When the federation module removed `account` as a sale contract; zero while the
    ///      FEDERATION slot is empty.
    function _gateRemovedAt(address account) internal view returns (uint256) {
        address gate = _directoryModule(Slots.FEDERATION);
        return gate == address(0) ? 0 : IFederationGate(gate).minterRemovedAt(account);
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
    ///      `setModuleDelay`) on the directory target once, for every federated token. A role
    ///      with an execution delay cannot be used here: such a call is refused.
    function _requireNetwork() internal view {
        address manager = IAccessManaged(directory).authority();
        (bool immediate,) = IAccessManager(manager).canCall(msg.sender, directory, msg.sig);
        if (!immediate) revert NotNetwork(msg.sender);
    }
}
