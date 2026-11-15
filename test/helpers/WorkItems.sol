// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { IWorkDelivery } from "src/interfaces/IWorkDelivery.sol";
import { Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";

/// @notice `IWorkRecords` reads items and media with their enum fields as `uint8`; the ABI is
///         the same, so a `PackageItem` or `MediaFile[]` converts by re-decoding its encoding.
function toWorkItem(PackageItem memory item) pure returns (IWorkRecords.WorkItem memory) {
    return abi.decode(abi.encode(item), (IWorkRecords.WorkItem));
}

/// @notice See `toWorkItem`.
function toWorkMedia(MediaFile[] memory media) pure returns (IWorkRecords.WorkMedia[] memory) {
    return abi.decode(abi.encode(media), (IWorkRecords.WorkMedia[]));
}

/// @notice The inverse of `toWorkMedia`, for media whose roles `MediaFile` can name.
function toMediaFiles(IWorkRecords.WorkMedia[] memory media) pure returns (MediaFile[] memory) {
    return abi.decode(abi.encode(media), (MediaFile[]));
}

/// @notice `IWorkRecords.preferredLocator` as a `Locator`, for kinds `LocatorKind` names.
function preferredOf(IWorkRecords records, uint256 tokenId, bytes32 fileId)
    view
    returns (Locator memory, uint256)
{
    (IWorkDelivery.Location memory l, uint256 index) = records.preferredLocator(tokenId, fileId);
    return (Locator(LocatorKind(l.kind), l.uri), index);
}
