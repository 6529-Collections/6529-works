// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { Locator, LocatorKind } from "./types/ContentTypes.sol";

/// @title IDeliveryHost
/// @notice What a delivery contract asks of the RECORDS module that serves it (`WorkRules`):
///         to emit ERC-4906 metadata updates through the token, which accepts them only from
///         its RECORDS module.
interface IDeliveryHost {
    /// @notice The caller is not the module's delivery contract.
    error NotDelivery(address caller);

    /// @notice Emits ERC-4906 for one work (and its edition, if any). The delivery contract
    ///         only.
    /// @param token The token contract.
    /// @param tokenId The token.
    function refreshMetadata(address token, uint256 tokenId) external;

    /// @notice Emits ERC-4906 for every token of `token` minted so far. The delivery contract
    ///         only.
    /// @param token The token contract.
    function refreshAllMetadata(address token) external;
}

/// @title IWorkDelivery
/// @notice A delivery contract (replaceable, `IWorkRules.delivery()`): where copies of a work's
///         media are served from (it also implements `ILocators`). Keyed by token contract, so one delivery contract serves every
///         token its RECORDS module serves. It has no authority over any fact of a work: media,
///         records, licenses, rates, pins and completeness live in `IWorkFacts`.
/// @dev The renderer reads `preferredLocator` (`ILocators`) and decides itself what it prints:
///      printable ASCII without `"` and `\`, at most `Limits.MAX_URI_BYTES`, ONCHAIN only for a
///      work `IWorkFacts` records as on-chain complete; anything else, a revert included, is
///      "no locator". This contract checks the grammar of each URI when it is added.
///
///      The first delivery contract keeps append-only, content-addressed locators per media
///      file (the artist's before finalize, the PLATFORM role's at any time), the storage
///      operator's preferences among them (per token, per collection, per file) and its mark on
///      a locator that died. Every bit of state has a getter and every change an event naming
///      who made it, so a successor or an indexer can rebuild it.
///
///      Obligations of a successor (checked by review and the network's waiting period, not by
///      code): it keeps serving every locator the contract it replaces registered, reading or
///      importing that contract's state (rebuildable from its events); it never answers ONCHAIN
///      for a work that is not on-chain complete, nor a URI that is not a copy of the file asked
///      for. This contract is the first: it reads no predecessor, so a successor of the same
///      code starts empty and the network must import the locators before installing it.
interface IWorkDelivery {
    /// @notice A served location, the same ABI as `ILocators.Location` (kinds 0 to 3 are
    ///         `LocatorKind`). Kept here for readers that name it through this interface.
    /// @param kind The locator kind.
    /// @param uri The URI; empty for kinds 0 and 3.
    struct Location {
        uint8 kind;
        string uri;
    }

    /// @notice A locator was appended for one media file of a work.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param fileId The media file the locator names a copy of.
    /// @param index The locator's index among the file's locators, from 0.
    /// @param locator The locator added.
    /// @param addedBy The account that added it.
    /// @param byArtist True when a wallet of the work's artist account added it (before
    ///        finalize), false for the PLATFORM role.
    event LocatorAdded(
        address indexed token,
        uint256 indexed tokenId,
        bytes32 indexed fileId,
        uint256 index,
        Locator locator,
        address addedBy,
        bool byArtist
    );
    /// @notice A token's preferred locator kind was set (emitted even when unchanged).
    /// @param token The token contract.
    /// @param previous The kind before the call.
    /// @param next The kind after the call (NONE when cleared).
    event PreferredKindSet(address indexed token, LocatorKind previous, LocatorKind next);
    /// @notice A collection's preferred locator kind was set (emitted even when unchanged).
    /// @param token The token contract.
    /// @param collectionId The collection.
    /// @param previous The kind before the call.
    /// @param next The kind after the call (NONE when cleared).
    event CollectionPreferredKindSet(
        address indexed token, uint256 indexed collectionId, LocatorKind previous, LocatorKind next
    );
    /// @notice A file's preferred locator index was set (`type(uint256).max` means none).
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param fileId The media file.
    /// @param previous The index before the call.
    /// @param next The index after the call.
    event FilePreferenceSet(
        address indexed token,
        uint256 indexed tokenId,
        bytes32 indexed fileId,
        uint256 previous,
        uint256 next
    );
    /// @notice The storage operator marked a locator dead: it is never served again.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param fileId The media file.
    /// @param index The locator's index among the file's locators.
    event LocatorDead(
        address indexed token, uint256 indexed tokenId, bytes32 indexed fileId, uint256 index
    );

    /// @notice The locator kind is NONE or ONCHAIN, the URI is not a content address of its kind
    ///         or is already registered for the file, or the caller's quota for the file is used
    ///         up; or an index names no locator, or a dead one.
    /// @dev A content address must be canonical to its last character: the last character of
    ///      an Arweave transaction ID (base64url) or of a CID (base32) carries two padding bits,
    ///      and a URI whose last character has either of them set is refused (an Arweave ID
    ///      must end in one of `AEIMQUYcgkosw048`, a CID in one of `aeimquy4`).
    error InvalidLocator();
    /// @notice The work has no open record in `IWorkFacts`.
    error RecordNotOpen(address token, uint256 tokenId);
    /// @notice The file is not one of the work's media files.
    error FileNotInWork(address token, uint256 tokenId, bytes32 fileId);
    /// @notice The collection does not exist in the token contract.
    error UnknownCollection(address token, uint256 collectionId);

    /// @notice The RECORDS module this delivery contract serves.
    /// @return The module (`IWorkRules`).
    function records() external view returns (address);

    /// @notice The permanent record contract read for each work's facts.
    /// @return The `IWorkFacts` contract.
    function facts() external view returns (address);

    /// @notice The directory, through which the accounts module is found.
    /// @return The `IDirectory` contract.
    function directory() external view returns (address);

    /// @notice Appends an ARWEAVE or IPFS locator for one of a work's media files. A wallet of
    ///         the lead artist's account until finalize; the PLATFORM role at any time. Before
    ///         finalize each side has half of `Limits.MAX_LOCATORS_PER_FILE`; after it only the
    ///         platform adds, up to the whole limit. A URI already registered for the file is
    ///         refused.
    /// @param token The token contract.
    /// @param tokenId A work with an open record.
    /// @param fileId One of the work's media files.
    /// @param locator The ARWEAVE or IPFS locator of a copy of that file.
    function addLocator(address token, uint256 tokenId, bytes32 fileId, Locator calldata locator)
        external;

    /// @notice A file's registered locators, in registration order.
    /// @param token The token contract.
    /// @param tokenId Any token.
    /// @param fileId Any file ID.
    /// @return The file's locators.
    function locators(address token, uint256 tokenId, bytes32 fileId)
        external
        view
        returns (Locator[] memory);

    /// @notice How many locators the artist and the platform added for a file, and which.
    /// @param token The token contract.
    /// @param tokenId Any token.
    /// @param fileId Any file ID.
    /// @return artist The artist's count.
    /// @return platform The platform's count.
    /// @return byArtist Bit `i` set when the artist added the locator at index `i`.
    function locatorCounts(address token, uint256 tokenId, bytes32 fileId)
        external
        view
        returns (uint256 artist, uint256 platform, uint256 byArtist);

    /// @notice Sets a token's preferred kind (NONE clears it). The STORAGE_OPERATOR role.
    /// @param token The token contract.
    /// @param kind The new preferred kind.
    function setPreferredKind(address token, LocatorKind kind) external;

    /// @notice Sets a collection's preferred kind (NONE clears it). The STORAGE_OPERATOR role.
    /// @param token The token contract.
    /// @param collectionId An existing collection of the token.
    /// @param kind The collection's new preferred kind.
    function setCollectionPreferredKind(address token, uint256 collectionId, LocatorKind kind)
        external;

    /// @notice Sets a file's preferred locator index (`type(uint256).max` clears it), which must
    ///         be registered and live. The STORAGE_OPERATOR role.
    /// @param token The token contract.
    /// @param tokenId A work with an open record.
    /// @param fileId One of the work's media files.
    /// @param index An index into the file's live locators, or `type(uint256).max`.
    function setFilePreference(address token, uint256 tokenId, bytes32 fileId, uint256 index)
        external;

    /// @notice Marks a file's locator dead, for good: it is never served again, whoever added
    ///         it, and its URI stays registered. The STORAGE_OPERATOR role.
    /// @param token The token contract.
    /// @param tokenId A work with an open record.
    /// @param fileId One of the work's media files.
    /// @param index An index into the file's live locators.
    function markLocatorDead(address token, uint256 tokenId, bytes32 fileId, uint256 index) external;

    /// @notice A file's dead locators.
    /// @param token The token contract.
    /// @param tokenId Any token.
    /// @param fileId Any file ID.
    /// @return Bit `i` set when the locator at index `i` is dead.
    function deadLocators(address token, uint256 tokenId, bytes32 fileId)
        external
        view
        returns (uint256);

    /// @notice A token's preferred kind.
    /// @param token The token contract.
    /// @return The kind, or NONE when unset.
    function preferredKind(address token) external view returns (LocatorKind);

    /// @notice A collection's preferred kind.
    /// @param token The token contract.
    /// @param collectionId Any collection.
    /// @return The kind, or NONE when unset.
    function collectionPreferredKind(address token, uint256 collectionId)
        external
        view
        returns (LocatorKind);

    /// @notice A file's preferred locator index, or `type(uint256).max`.
    /// @param token The token contract.
    /// @param tokenId Any token.
    /// @param fileId Any file ID.
    /// @return The index into the file's locators, or `type(uint256).max` when unset.
    function filePreference(address token, uint256 tokenId, bytes32 fileId)
        external
        view
        returns (uint256);
}
