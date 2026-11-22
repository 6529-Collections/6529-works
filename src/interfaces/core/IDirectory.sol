// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IModuleSlots } from "./IModules.sol";

/// @title IDirectory
/// @notice The one permanent address that answers where the network's shared modules are: the
///         accounts module (`ACCOUNTS`), the federation module (`FEDERATION`) and the TERMS and
///         RECORDS modules of every federated token (`FEDERATED_TERMS`, `FEDERATED_RECORDS`).
///         The split ledger asks it for artists' payout addresses; federated tokens ask it for
///         their gate. It also holds the one waiting period the money contracts share
///         (`unclaimedPeriod`), so the unowned split ledger needs no governance of its own. Slots change after the network's waiting period (`IModuleSlots`).
interface IDirectory is IModuleSlots {
    /// @notice The network changed the unclaimed period.
    /// @param previous The period before.
    /// @param next The period now.
    event UnclaimedPeriodSet(uint48 previous, uint48 next);

    /// @notice How long money must have waited unclaimed before it can go to the network: a
    ///         marked share in a split vault (`SplitLedger.forfeit`) and an aged escrow credit
    ///         (`RevenueEscrow.expire`). A setting of the network, 180 days at deployment; not a
    ///         fixed promise. The ledger and the escrow read it when the action is attempted,
    ///         so a change applies to marks and credits already running.
    /// @return The period, in seconds.
    function unclaimedPeriod() external view returns (uint48);

    /// @notice Sets `unclaimedPeriod`, at once. The network only. Zero is allowed.
    /// @param next The new period, in seconds.
    function setUnclaimedPeriod(uint48 next) external;

    /// @notice The payout address of an artist, as the ACCOUNTS module answers it now
    ///         (`IArtistPayoutResolver`, which the split ledger calls). Reverts if no ACCOUNTS
    ///         module is installed or it reverts: the ledger then leaves the money in the vault.
    /// @param artistId The artist.
    /// @return The payout address, or zero while the account is frozen or changing.
    function payoutAddress(uint256 artistId) external view returns (address);
}
