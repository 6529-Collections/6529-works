// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IAccounts } from "../interfaces/IAccounts.sol";
import { IStream } from "../interfaces/IStream.sol";
import { IWorkDelivery, IWorkLocators } from "../interfaces/IWorkDelivery.sol";
import { IWorkRecords } from "../interfaces/IWorkRecords.sol";
import { Locator, LocatorKind } from "../interfaces/types/ContentTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";

/// @title WorkDelivery
/// @notice The first delivery contract of 6529 Stream: where copies of a work's media are
///         served from. Append-only, content-addressed locators per media file (the artist's
///         before finalize, the PLATFORM role's at any time), the storage operator's
///         preferences among them and its mark on a locator that died (ADR 0001 sections 8 and
///         10; C21, C33). Replaceable as a whole through
///         `IWorkRecords.setDelivery`; it has no authority over any fact of a work, and
///         `IWorkRecords.preferredLocator` checks every answer it gives.
/// @dev Reads what it needs from the records satellite (open, finalized, on-chain complete,
///      media membership) and from 6529 Stream (artist, collection) on every call, so it never
///      holds a stale copy of a fact. Every change asks the records satellite to refresh
///      metadata (ERC-4906 through 6529 Stream). Every bit of state has a getter, and
///      `LocatorAdded` names who added each locator, so a successor can carry it over.
contract WorkDelivery is AccessManaged, ERC165, IWorkLocators {
    uint256 private constant NONE = type(uint256).max;
    /// @dev Locators per file the artist may add, and separately the platform (16 in all).
    uint256 private constant LOCATOR_QUOTA = Limits.MAX_LOCATORS_PER_FILE / 2;
    /// @dev The characters of an Arweave transaction ID (base64url: `A-Z a-z 0-9 - _`) and of a
    ///      base32 CID (`a-z 2-7`), as bit sets over ASCII.
    uint256 private constant TXID_CHARS = 0x07fffffe87fffffe03ff200000000000;
    uint256 private constant CID_CHARS = 0x07fffffe0000000000fc000000000000;
    /// @dev The last characters of a canonical transaction ID and CID: the encoding's last
    ///      character carries two padding bits, which must be zero (`AEIMQUYcgkosw048`, and
    ///      `aeimquy4`).
    uint256 private constant TXID_LAST = 0x888888022222220111000000000000;
    uint256 private constant CID_LAST = 0x2222222000000000010000000000000;

    /// @dev How many of a file's locators the artist and the platform each added, which the
    ///      artist added (bit `i` of `byArtist` for the locator at index `i`) and which are dead
    ///      (bit `i` of `dead`).
    struct LocatorCounts {
        uint8 artist;
        uint8 platform;
        uint16 byArtist;
        uint16 dead;
    }

    /// @inheritdoc IWorkDelivery
    address public immutable records;
    /// @notice The 6529 Stream core (immutable).
    address public immutable stream;
    /// @inheritdoc IWorkDelivery
    address public immutable predecessor;

    /// @inheritdoc IWorkLocators
    LocatorKind public preferredKind;

    mapping(uint256 collectionId => LocatorKind) private _collectionKinds;
    mapping(uint256 tokenId => mapping(bytes32 fileId => Locator[])) private _locators;
    mapping(uint256 tokenId => mapping(bytes32 fileId => uint256 indexPlusOne)) private _filePrefs;
    mapping(uint256 tokenId => mapping(bytes32 fileId => LocatorCounts)) private _locatorCounts;
    mapping(uint256 tokenId => mapping(bytes32 fileId => mapping(bytes32 uriHash => bool))) private
        _locatorUris;

    /// @param authority_ The AccessManager governing this contract.
    /// @param records_ The records satellite this contract serves.
    /// @param stream_ The 6529 Stream core.
    /// @param predecessor_ The delivery contract this one replaces, or zero for the first.
    constructor(address authority_, address records_, address stream_, address predecessor_)
        AccessManaged(authority_)
    {
        records = records_;
        stream = stream_;
        predecessor = predecessor_;
    }

    /// @inheritdoc IWorkLocators
    /// @dev After finalize the call goes through the PLATFORM role only. A URI already
    ///      registered for the file is refused, compared as exact bytes; the set is shared, so
    ///      whichever side adds a URI first holds it.
    function addLocator(uint256 tokenId, bytes32 fileId, Locator calldata locator) external {
        bool finalized = IWorkRecords(records).record(tokenId).finalized;
        bool byArtist = !finalized && _isArtist(tokenId);
        if (!byArtist) _checkCanCall(msg.sender, _msgData());
        IWorkRecords(records).mediaIndex(tokenId, fileId);
        _checkUri(locator);
        LocatorCounts storage counts = _locatorCounts[tokenId][fileId];
        mapping(bytes32 => bool) storage seen = _locatorUris[tokenId][fileId];
        bytes32 uriHash = keccak256(bytes(locator.uri));
        uint256 used = byArtist ? counts.artist : counts.platform;
        uint256 quota = LOCATOR_QUOTA;
        // After finalize the artist adds none, so the platform may use the artist's unused slots.
        if (finalized) (used, quota) = (used + counts.artist, Limits.MAX_LOCATORS_PER_FILE);
        if (used >= quota || seen[uriHash]) revert InvalidLocator();
        seen[uriHash] = true;
        Locator[] storage list = _locators[tokenId][fileId];
        uint256 index = list.length;
        if (byArtist) {
            ++counts.artist;
            // Below 16: the file holds at most `Limits.MAX_LOCATORS_PER_FILE` locators.
            // forge-lint: disable-next-line(unsafe-typecast)
            counts.byArtist |= uint16(1 << index);
        } else {
            ++counts.platform;
        }
        list.push(locator);
        emit LocatorAdded(tokenId, fileId, index, locator, msg.sender, byArtist);
        IWorkRecords(records).refreshMetadata(tokenId);
    }

    /// @inheritdoc IWorkLocators
    function locators(uint256 tokenId, bytes32 fileId) external view returns (Locator[] memory) {
        if (!IWorkRecords(records).isOpen(tokenId)) revert IWorkRecords.RecordNotOpen(tokenId);
        return _locators[tokenId][fileId];
    }

    /// @inheritdoc IWorkLocators
    function locatorCounts(uint256 tokenId, bytes32 fileId)
        external
        view
        returns (uint256 artist, uint256 platform, uint256 byArtist)
    {
        LocatorCounts storage c = _locatorCounts[tokenId][fileId];
        return (c.artist, c.platform, c.byArtist);
    }

    /// @inheritdoc IWorkDelivery
    /// @dev The most specific setting wins: the file's preferred index, then the collection's
    ///      preferred kind, then the global preferred kind, then the first locator, then the
    ///      implicit ONCHAIN copy of an on-chain complete work, else the empty locator. Every
    ///      choice is among the live locators, whoever added them (C33): a dead one is never
    ///      served, and a file preference naming one is passed over. ONCHAIN matches on the
    ///      records satellite's stored flag, never a content-store scan.
    function preferredLocator(uint256 tokenId, bytes32 fileId)
        external
        view
        returns (Location memory location, uint256 index)
    {
        bool onChain = IWorkRecords(records).record(tokenId).onChainComplete;
        IWorkRecords(records).mediaIndex(tokenId, fileId);
        Locator[] storage list = _locators[tokenId][fileId];
        // Bit `i` set for each live locator (at most 16).
        uint256 live = ((1 << list.length) - 1) & ~uint256(_locatorCounts[tokenId][fileId].dead);
        index = _filePrefs[tokenId][fileId];
        bool found = index != 0 && (live >> (index - 1)) & 1 != 0;
        if (found) index -= 1;
        if (!found) {
            (,, uint256 collectionId,,,) = IStream(stream).coreOf(tokenId);
            (found, index) = _firstOfKind(list, live, onChain, _collectionKinds[collectionId]);
        }
        if (!found) (found, index) = _firstOfKind(list, live, onChain, preferredKind);
        if (!found && live != 0) {
            // The first live locator: the mask's lowest set bit.
            index = 0;
            while ((live >> index) & 1 == 0) {
                ++index;
            }
            found = true;
        }
        if (!found && onChain) (found, index) = (true, NONE);
        if (!found) return (location, NONE);
        if (index == NONE) {
            location.kind = uint8(LocatorKind.ONCHAIN);
        } else {
            Locator storage l = list[index];
            location = Location(uint8(l.kind), l.uri);
        }
    }

    /// @inheritdoc IWorkLocators
    function setPreferredKind(LocatorKind kind) external restricted {
        emit PreferredKindSet(preferredKind, kind);
        preferredKind = kind;
        IWorkRecords(records).refreshAllMetadata();
    }

    /// @inheritdoc IWorkLocators
    function setCollectionPreferredKind(uint256 collectionId, LocatorKind kind)
        external
        restricted
    {
        // Collection IDs run from 1 to the count and are never removed.
        if (collectionId == 0 || collectionId > IStream(stream).collectionCount()) {
            revert IStream.UnknownCollection(collectionId);
        }
        emit CollectionPreferredKindSet(collectionId, _collectionKinds[collectionId], kind);
        _collectionKinds[collectionId] = kind;
        IWorkRecords(records).refreshAllMetadata();
    }

    /// @inheritdoc IWorkLocators
    function setFilePreference(uint256 tokenId, bytes32 fileId, uint256 index) external restricted {
        if (index == NONE) IWorkRecords(records).mediaIndex(tokenId, fileId);
        else _requireLive(tokenId, fileId, index);
        emit FilePreferenceSet(tokenId, fileId, filePreference(tokenId, fileId), index);
        _filePrefs[tokenId][fileId] = index == NONE ? 0 : index + 1;
        IWorkRecords(records).refreshMetadata(tokenId);
    }

    /// @inheritdoc IWorkLocators
    function markLocatorDead(uint256 tokenId, bytes32 fileId, uint256 index) external restricted {
        LocatorCounts storage counts = _requireLive(tokenId, fileId, index);
        // Below 16: the file holds at most `Limits.MAX_LOCATORS_PER_FILE` locators.
        // forge-lint: disable-next-line(unsafe-typecast)
        counts.dead |= uint16(1 << index);
        emit LocatorDead(tokenId, fileId, index);
        IWorkRecords(records).refreshMetadata(tokenId);
    }

    /// @inheritdoc IWorkLocators
    function deadLocators(uint256 tokenId, bytes32 fileId) external view returns (uint256) {
        return _locatorCounts[tokenId][fileId].dead;
    }

    /// @inheritdoc IWorkLocators
    function collectionPreferredKind(uint256 collectionId) external view returns (LocatorKind) {
        return _collectionKinds[collectionId];
    }

    /// @inheritdoc IWorkLocators
    function filePreference(uint256 tokenId, bytes32 fileId) public view returns (uint256) {
        uint256 stored = _filePrefs[tokenId][fileId];
        return stored == 0 ? NONE : stored - 1;
    }

    /// @notice ERC-165: `IWorkDelivery`, which `IWorkRecords.setDelivery` checks, and
    ///         `IWorkLocators`.
    /// @param interfaceId The interface ID to test.
    /// @return True for the `IWorkDelivery`, `IWorkLocators` and `IERC165` interface IDs.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IWorkDelivery).interfaceId
            || interfaceId == type(IWorkLocators).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @dev Whether the caller is a wallet of the work's lead artist account now.
    function _isArtist(uint256 tokenId) private view returns (bool) {
        IStream core = IStream(stream);
        return IAccounts(core.artistRegistry()).isWallet(core.artistOf(tokenId), msg.sender);
    }

    /// @dev Reverts with `InvalidLocator` unless locator `index` of one of the work's media
    ///      files exists and is not dead; returns the file's counts.
    function _requireLive(uint256 tokenId, bytes32 fileId, uint256 index)
        private
        view
        returns (LocatorCounts storage counts)
    {
        IWorkRecords(records).mediaIndex(tokenId, fileId);
        counts = _locatorCounts[tokenId][fileId];
        if (index >= _locators[tokenId][fileId].length || (counts.dead >> index) & 1 != 0) {
            revert InvalidLocator();
        }
    }

    /// @dev A locator URI is a content address in its one canonical spelling, with nothing after
    ///      it (no path, query or fragment), so what it names cannot be repointed and a copy has
    ///      one URI:
    ///      - ARWEAVE: `ar://` and a 43-character base64url transaction ID (32 bytes) whose last
    ///        character's two padding bits are zero. The shape is checked, not that the ID
    ///        exists.
    ///      - IPFS: `ipfs://` and a base32 CIDv1 of the fixed profile: a raw leaf or a dag-pb
    ///        root with a 32-byte sha2-256 multihash (`bafkrei` or `bafybei`, then a character
    ///        in `a-h`), whose last character's two padding bits are zero; 66 bytes in all.
    function _checkUri(Locator calldata locator) private pure {
        bytes calldata uri = bytes(locator.uri);
        uint256 chars = 0;
        uint256 lasts = 0;
        uint256 start = 0;
        if (locator.kind == LocatorKind.ARWEAVE) {
            if (uri.length == 48 && bytes5(uri[:5]) == "ar://") {
                (chars, lasts, start) = (TXID_CHARS, TXID_LAST, 5);
            }
        } else if (locator.kind == LocatorKind.IPFS && uri.length == 66) {
            bytes14 head = bytes14(uri[:14]);
            if (
                (head == "ipfs://bafkrei" || head == "ipfs://bafybei") && uri[14] >= "a"
                    && uri[14] <= "h"
            ) (chars, lasts, start) = (CID_CHARS, CID_LAST, 15);
        }
        // The last character's set is inside the charset, so the loop stops before it.
        if (chars == 0 || (lasts >> uint8(uri[uri.length - 1])) & 1 == 0) revert InvalidLocator();
        for (uint256 i = start; i < uri.length - 1; ++i) {
            if ((chars >> uint8(uri[i])) & 1 == 0) revert InvalidLocator();
        }
    }

    /// @dev The first live locator of `kind` (`live`, bit `i` for index `i`), or the implicit
    ///      ONCHAIN one (`NONE`) when the work is on-chain complete. NONE as a kind never
    ///      matches.
    function _firstOfKind(Locator[] storage list, uint256 live, bool onChain, LocatorKind kind)
        private
        view
        returns (bool, uint256)
    {
        if (kind == LocatorKind.NONE) return (false, 0);
        if (kind == LocatorKind.ONCHAIN) return (onChain, NONE);
        for (uint256 i; live >> i != 0; ++i) {
            if ((live >> i) & 1 != 0 && list[i].kind == kind) return (true, i);
        }
        return (false, 0);
    }
}
