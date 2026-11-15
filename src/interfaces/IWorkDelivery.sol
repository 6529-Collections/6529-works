// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Locator, LocatorKind } from "./types/ContentTypes.sol";

/// @title IWorkDelivery
/// @notice What the permanent `IWorkRecords` asks of a delivery contract, and what every
///         delivery contract owes its successors. A delivery contract decides where copies of a
///         work's media are served from (locators, kinds, preferences); it is replaceable under
///         the slow governance class (`IWorkRecords.setDelivery`) and has no authority over any
///         fact: media, hashes, records, licenses, rates, powers, pins or completeness.
/// @dev `IWorkRecords.preferredLocator` forwards to `preferredLocator` here with all the gas
///      the EIP-150 rule allows and checks the answer (fail-soft, see there), so pinned
///      renderers keep working across replacements.
///
///      Obligations of a successor (checked by review and the governance delay, not by code):
///      - it names the contract it replaces as `predecessor()` (`setDelivery` refuses
///        otherwise), so the chain of delivery contracts is on-chain and every predecessor's
///        state stays readable;
///      - it keeps serving every locator a predecessor registered for a work, reading the
///        predecessor's state (`IWorkLocators.locators`, `locatorCounts`, the preferences) for
///        files it holds nothing of its own for, or importing it, so no artist's locator is
///        lost; a successor that drops a predecessor's locators must say so in its governance
///        proposal;
///      - it never answers ONCHAIN for a work that is not on-chain complete, nor a URI that is
///        not a copy of the file asked for.
interface IWorkDelivery {
    /// @notice A locator as `IWorkRecords` passes it on: a kind label and a URI. The ABI is that
    ///         of `Locator` (kinds 0 to 3 are `LocatorKind`'s NONE, ARWEAVE, IPFS and ONCHAIN);
    ///         a future delivery contract may use other kind values, which are passed through.
    struct Location {
        uint8 kind;
        string uri;
    }

    /// @notice The records satellite this delivery contract serves.
    /// @return The `IWorkRecords` contract.
    function records() external view returns (address);
    /// @notice The delivery contract this one replaces, or zero for the first.
    /// @return The predecessor.
    function predecessor() external view returns (address);
    /// @notice The locator `tokenURI` serves for a media file of a work.
    /// @param tokenId A work with an open record.
    /// @param fileId One of the work's media files.
    /// @return locator The chosen locator: kind NONE and an empty URI for none, kind ONCHAIN
    ///         and an empty URI for the on-chain copy.
    /// @return index Its index in this contract's list for the file, or `type(uint256).max`
    ///         for none and for the on-chain copy.
    function preferredLocator(uint256 tokenId, bytes32 fileId)
        external
        view
        returns (Location memory locator, uint256 index);
}

/// @title IWorkLocators
/// @notice The first delivery contract of 6529 Stream (`WorkDelivery`): append-only locators
///         per media file, registered by the artist before finalize and by the PLATFORM role at
///         any time, and the storage operator's preferences among them. Replaceable as a whole.
/// @dev Every bit of state has a getter and every change an event naming who made it, so a
///      successor or an indexer can rebuild it without calls into history.
interface IWorkLocators is IWorkDelivery {
    /// @notice A locator was appended for one media file of a work.
    /// @param tokenId The work's token ID.
    /// @param fileId The media file the locator names a copy of.
    /// @param index The locator's index among the file's locators, from 0.
    /// @param locator The locator added.
    /// @param addedBy The account that added it.
    /// @param byArtist True when the work's artist added it (before finalize), false for the
    ///        PLATFORM role; only the artist's locators feed the kind and first-registered
    ///        fallbacks.
    event LocatorAdded(
        uint256 indexed tokenId,
        bytes32 indexed fileId,
        uint256 index,
        Locator locator,
        address addedBy,
        bool byArtist
    );
    /// @notice The global preferred locator kind was set (emitted even when it is unchanged).
    /// @param previous The kind before the call.
    /// @param next The kind after the call (NONE when cleared).
    event PreferredKindSet(LocatorKind previous, LocatorKind next);
    /// @notice A collection's preferred locator kind was set (emitted even when unchanged).
    /// @param collectionId The 6529 Stream collection ID.
    /// @param previous The kind before the call.
    /// @param next The kind after the call (NONE when cleared).
    event CollectionPreferredKindSet(
        uint256 indexed collectionId, LocatorKind previous, LocatorKind next
    );
    /// @notice A file's preferred locator index was set (emitted even when unchanged;
    ///         `type(uint256).max` means none).
    /// @param tokenId The work's token ID.
    /// @param fileId The media file.
    /// @param previous The index before the call.
    /// @param next The index after the call.
    event FilePreferenceSet(
        uint256 indexed tokenId, bytes32 indexed fileId, uint256 previous, uint256 next
    );

    /// @notice The locator kind is NONE or ONCHAIN, the URI is not a content address of its kind
    ///         (see `Locator`) or is already registered for the file, or the caller's quota for
    ///         the file is used up.
    error InvalidLocator();

    /// @notice Appends an ARWEAVE or IPFS locator for one of a work's media files. Callable by
    ///         the artist until finalize, and by the PLATFORM role at any time. The URI must be a
    ///         content address with nothing after it (`Locator`). Before finalize each side has
    ///         half of `Limits.MAX_LOCATORS_PER_FILE` (8); after it only PLATFORM adds, up to the
    ///         whole 16. A URI already registered for the file is refused.
    /// @param tokenId A work with an open record.
    /// @param fileId One of the work's media files (`IWorkRecords.FileNotInWork` otherwise).
    /// @param locator The ARWEAVE or IPFS locator of a copy of that file.
    function addLocator(uint256 tokenId, bytes32 fileId, Locator calldata locator) external;
    /// @notice A file's registered locators, in registration order.
    /// @param tokenId A work with an open record.
    /// @param fileId Any file ID; one that is not in the work has none.
    /// @return The file's locators.
    function locators(uint256 tokenId, bytes32 fileId) external view returns (Locator[] memory);
    /// @notice How many locators the artist and the platform added for a file, and which.
    /// @param tokenId Any token ID.
    /// @param fileId Any file ID.
    /// @return artist The artist's count.
    /// @return platform The platform's count.
    /// @return byArtist Bit `i` set when the artist added the locator at index `i`.
    function locatorCounts(uint256 tokenId, bytes32 fileId)
        external
        view
        returns (uint256 artist, uint256 platform, uint256 byArtist);
    /// @notice Sets the global preferred kind (NONE clears it). STORAGE_OPERATOR role.
    /// @param kind The new global preferred kind.
    function setPreferredKind(LocatorKind kind) external;
    /// @notice Sets a collection's preferred kind (NONE clears it). STORAGE_OPERATOR role.
    /// @param collectionId An existing 6529 Stream collection (`IStreamCore.UnknownCollection`
    ///        otherwise).
    /// @param kind The collection's new preferred kind.
    function setCollectionPreferredKind(uint256 collectionId, LocatorKind kind) external;
    /// @notice Sets a file's preferred locator index (`type(uint256).max` clears it), which must
    ///         be registered. STORAGE_OPERATOR role.
    /// @param tokenId A work with an open record.
    /// @param fileId One of the work's media files.
    /// @param index An index into the file's locators (`InvalidLocator` otherwise), or
    ///        `type(uint256).max`.
    function setFilePreference(uint256 tokenId, bytes32 fileId, uint256 index) external;
    /// @notice The global preferred kind.
    /// @return The kind, or NONE when unset.
    function preferredKind() external view returns (LocatorKind);
    /// @notice A collection's preferred kind.
    /// @param collectionId Any collection ID.
    /// @return The kind, or NONE when unset.
    function collectionPreferredKind(uint256 collectionId) external view returns (LocatorKind);
    /// @notice A file's preferred locator index, or `type(uint256).max`.
    /// @param tokenId Any token ID.
    /// @param fileId Any file ID.
    /// @return The index into the file's locators, or `type(uint256).max` when unset.
    function filePreference(uint256 tokenId, bytes32 fileId) external view returns (uint256);
}
