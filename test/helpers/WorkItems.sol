// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { IWorkDelivery } from "src/interfaces/IWorkDelivery.sol";
import { Locator, LocatorKind } from "src/interfaces/types/ContentTypes.sol";

/// @notice `IWorkRecords.preferredLocator` as a `Locator`, for kinds `LocatorKind` names.
function preferredOf(IWorkRecords records, uint256 tokenId, bytes32 fileId)
    view
    returns (Locator memory, uint256)
{
    (IWorkDelivery.Location memory l, uint256 index) = records.preferredLocator(tokenId, fileId);
    return (Locator(LocatorKind(l.kind), l.uri), index);
}
