// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { IIndependentStreamMembership } from "./IIndependentStreamMembership.sol";
import { IModuleSlots } from "./core/IModules.sol";
import { MediaFile } from "./types/ContentTypes.sol";
import { PackageItem } from "./types/PackageTypes.sol";

/// @title IIndependentStream
/// @notice An Independent Stream artist's own ERC-721 of 1/1s: the plain permanent token
///         (`IStream`) with a different gate (ADR 0010). Beyond `IStream` it answers the module
///         slots WorkFacts and the Independent Stream module read, whether an address may mint, and
///         the artist's renderer.
/// @dev Module slots. `moduleOf(TERMS)` and `moduleOf(RECORDS)` are the directory's
///      `INDEPENDENT_TERMS` and `INDEPENDENT_RECORDS` (shared by every Independent Stream token);
///      `moduleOf(RENDERER)` is this token's own slot, which any wallet of the artist's account
///      announces and removes (`proposeModule`, `removeModule`), installed by anyone once the
///      waiting period `moduleDelay` (the network's setting) has passed. No other slot exists.
interface IIndependentStream is IModuleSlots, IIndependentStreamMembership {
    /// @notice What a sale contract passes to the Independent Stream module's `authorize` for a new
    ///         work: `abi.encode(IndependentMint)`.
    /// @param item The approved item (`StreamHashing.itemHash` names it). Its first party is the
    ///        artist; any later party is a collaborator.
    /// @param media Its media list, primary first, committed by `item.mediaHash`.
    /// @param consents One per party after the first, in order: `abi.encodePacked(wallet,
    ///        signature)` of a wallet of that party's account over the accounts module's
    ///        `consentDigest(token, Core.independentConsent(itemHash, royaltyRate))`, so a consent
    ///        covers the item and its royalty rate for this token only.
    struct IndependentMint {
        PackageItem item;
        MediaFile[] media;
        bytes[] consents;
    }

    /// @notice The slot is not one this token holds itself (only RENDERER is).
    /// @param slot The slot.
    error NotLocalSlot(bytes32 slot);
    /// @notice An Independent Stream token has one collection, created at deployment.
    error OneCollection();

    /// @notice Whether `account` minted at least one token here. Such an account may record
    ///         the outcome of, or burn, a token it still holds with no outcome, whatever the
    ///         Independent Stream module answers later, so a missing or replaced module never
    ///         strands a running sale.
    /// @param account The account.
    /// @return True once it minted here.
    function hasMinted(address account) external view returns (bool);
}
