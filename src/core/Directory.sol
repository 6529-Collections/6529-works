// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistPayoutResolver } from "../economics/interfaces/IArtistPayoutResolver.sol";
import { Slots } from "../interfaces/core/CoreTypes.sol";
import { IAccounts } from "../interfaces/core/IAccounts.sol";
import { IDirectory } from "../interfaces/core/IDirectory.sol";
import { IModuleSlots } from "../interfaces/core/IModules.sol";
import { ModuleSlots } from "./Modules.sol";

/// @title Directory
/// @notice The one permanent address for the network's shared modules (ADR 0010): ACCOUNTS,
///         FEDERATION, FEDERATED_TERMS and FEDERATED_RECORDS, each installed after the network's
///         waiting period (`moduleDelay`, a setting) and removed at once. The split ledger is
///         deployed with this contract as its payout resolver; every federated token is deployed
///         with it as its gate. It also holds `unclaimedPeriod`, the network's setting that the
///         split ledger and the escrow read.
/// @dev Genesis modules are constructor arguments, active at once and unchecked (predicted
///      addresses). `payoutAddress` is a plain call: a missing, reverting or gas-exhausted
///      ACCOUNTS module makes it revert, never answer a default, and the ledger then leaves the
///      money where it is. No gas number, no `try`/`catch`.
contract Directory is ModuleSlots, IDirectory, IArtistPayoutResolver, IERC165 {
    /// @inheritdoc IDirectory
    uint48 public unclaimedPeriod = 180 days;

    /// @param authority_ The AccessManager.
    /// @param accounts_ The genesis ACCOUNTS module.
    /// @param federation_ The genesis FEDERATION module.
    /// @param federatedTerms_ The genesis TERMS module of federated tokens.
    /// @param federatedRecords_ The genesis RECORDS module of federated tokens.
    constructor(
        address authority_,
        address accounts_,
        address federation_,
        address federatedTerms_,
        address federatedRecords_
    ) AccessManaged(authority_) {
        _setModule(Slots.ACCOUNTS, accounts_);
        _setModule(Slots.FEDERATION, federation_);
        _setModule(Slots.FEDERATED_TERMS, federatedTerms_);
        _setModule(Slots.FEDERATED_RECORDS, federatedRecords_);
        emit UnclaimedPeriodSet(0, unclaimedPeriod);
    }

    /// @inheritdoc IDirectory
    function setUnclaimedPeriod(uint48 next) external restricted {
        emit UnclaimedPeriodSet(unclaimedPeriod, next);
        unclaimedPeriod = next;
    }

    /// @inheritdoc IDirectory
    function payoutAddress(uint256 artistId)
        external
        view
        override(IDirectory, IArtistPayoutResolver)
        returns (address)
    {
        return IAccounts(moduleOf(Slots.ACCOUNTS)).payoutAddress(artistId);
    }

    /// @inheritdoc IERC165
    /// @dev ERC-165, `IArtistPayoutResolver`, `IDirectory` and `IModuleSlots`.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IArtistPayoutResolver).interfaceId
            || interfaceId == type(IModuleSlots).interfaceId
            || interfaceId == type(IDirectory).interfaceId;
    }
}
