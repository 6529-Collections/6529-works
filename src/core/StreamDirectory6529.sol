// SPDX-License-Identifier: Apache-2.0
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
///         INDEPENDENT_STREAM, INDEPENDENT_TERMS and INDEPENDENT_RECORDS, each installed after the
///         network's waiting period (`moduleDelay`, a setting) and removed at once. The split
///         ledger is deployed with this contract as its payout resolver; every Independent Stream
///         token is deployed with it as its gate. It also holds `unclaimedPeriod`, the network's
///         setting that the split ledger and the escrow read.
/// @dev Genesis modules are constructor arguments, active at once and unchecked (predicted
///      addresses). `payoutAddress` is a plain call: a missing, reverting or gas-exhausted
///      ACCOUNTS module makes it revert, never answer a default, and the ledger then leaves the
///      money where it is. No gas number, no `try`/`catch`.
contract StreamDirectory6529 is ModuleSlots, IDirectory, IArtistPayoutResolver, IERC165 {
    /// @inheritdoc IDirectory
    uint48 public unclaimedPeriod = 180 days;

    /// @param authority_ The AccessManager.
    /// @param accounts_ The genesis ACCOUNTS module.
    /// @param independentStream_ The genesis INDEPENDENT_STREAM module.
    /// @param independentTerms_ The genesis TERMS module of Independent Stream tokens.
    /// @param independentRecords_ The genesis RECORDS module of Independent Stream tokens.
    constructor(
        address authority_,
        address accounts_,
        address independentStream_,
        address independentTerms_,
        address independentRecords_
    ) AccessManaged(authority_) {
        _setModule(Slots.ACCOUNTS, accounts_);
        _setModule(Slots.INDEPENDENT_STREAM, independentStream_);
        _setModule(Slots.INDEPENDENT_TERMS, independentTerms_);
        _setModule(Slots.INDEPENDENT_RECORDS, independentRecords_);
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
