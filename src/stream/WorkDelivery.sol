// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { Facts, Slots } from "../interfaces/core/CoreTypes.sol";
import { IAccounts } from "../interfaces/core/IAccounts.sol";
import { ILocators } from "../interfaces/core/ILocators.sol";
import { IModuleSlots } from "../interfaces/core/IModules.sol";
import { IStream } from "../interfaces/core/IStream.sol";
import { IWorkFacts } from "../interfaces/core/IWorkFacts.sol";
import { IDeliveryHost, IWorkDelivery } from "../interfaces/IWorkDelivery.sol";
import { Locator, LocatorKind } from "../interfaces/types/ContentTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";

/// @title WorkDelivery
/// @notice The first delivery contract of the RECORDS module `WorkRules`: where copies of a
///         work's media are served from, for every token the module serves. Append-only,
///         content-addressed locators per media file (the artist's before finalize, the
///         PLATFORM role's at any time), the storage operator's preferences among them and its
///         mark on a locator that died. Replaceable as a whole (`IWorkRules.setDelivery`); it
///         has no authority over any fact of a work.
/// @dev Reads what it needs on every call (open, finalized, on-chain complete and the media
///      from `IWorkFacts.factsOf`; the artist and collection from the token), so it never holds
///      a stale copy of a fact. Every change asks the RECORDS module to emit ERC-4906 through
///      the token. The renderer checks every answer it prints (`ILocators`).
contract WorkDelivery is AccessManaged, ERC165, IWorkDelivery {
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
    /// @inheritdoc IWorkDelivery
    address public immutable facts;
    /// @inheritdoc IWorkDelivery
    address public immutable directory;

    mapping(address token => LocatorKind) private _preferredKinds;
    mapping(address token => mapping(uint256 collectionId => LocatorKind)) private _collectionKinds;
    mapping(address token => mapping(uint256 tokenId => mapping(bytes32 fileId => Locator[])))
        private _locators;
    mapping(address token => mapping(uint256 tokenId => mapping(bytes32 fileId => uint256))) private
        _filePrefs;
    mapping(
        address token => mapping(uint256 tokenId => mapping(bytes32 fileId => LocatorCounts))
    ) private _locatorCounts;
    mapping(
        address token
            => mapping(uint256 tokenId => mapping(bytes32 fileId => mapping(bytes32 => bool)))
    ) private _locatorUris;

    /// @param authority_ The AccessManager governing this contract.
    /// @param records_ The RECORDS module this contract serves (`WorkRules`).
    /// @param facts_ The permanent record contract (`IWorkFacts`).
    /// @param directory_ The directory, through which the accounts module is found.
    constructor(address authority_, address records_, address facts_, address directory_)
        AccessManaged(authority_)
    {
        records = records_;
        facts = facts_;
        directory = directory_;
    }

    /// @inheritdoc IWorkDelivery
    /// @dev After finalize the call goes through the PLATFORM role only. A URI already
    ///      registered for the file is refused, compared as exact bytes; the set is shared, so
    ///      whichever side adds a URI first holds it.
    function addLocator(address token, uint256 tokenId, bytes32 fileId, Locator calldata locator)
        external
    {
        Facts memory f = _media(token, tokenId, fileId);
        bool byArtist = !f.finalized && _isArtist(token, tokenId);
        if (!byArtist) _checkCanCall(msg.sender, _msgData());
        _checkUri(locator);
        LocatorCounts storage counts = _locatorCounts[token][tokenId][fileId];
        mapping(bytes32 => bool) storage seen = _locatorUris[token][tokenId][fileId];
        bytes32 uriHash = keccak256(bytes(locator.uri));
        uint256 used = byArtist ? counts.artist : counts.platform;
        uint256 quota = LOCATOR_QUOTA;
        // After finalize the artist adds none, so the platform may use the artist's unused slots.
        if (f.finalized) (used, quota) = (used + counts.artist, Limits.MAX_LOCATORS_PER_FILE);
        if (used >= quota || seen[uriHash]) revert InvalidLocator();
        seen[uriHash] = true;
        Locator[] storage list = _locators[token][tokenId][fileId];
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
        emit LocatorAdded(token, tokenId, fileId, index, locator, msg.sender, byArtist);
        IDeliveryHost(records).refreshMetadata(token, tokenId);
    }

    /// @inheritdoc IWorkDelivery
    function locators(address token, uint256 tokenId, bytes32 fileId)
        external
        view
        returns (Locator[] memory)
    {
        return _locators[token][tokenId][fileId];
    }

    /// @inheritdoc IWorkDelivery
    function locatorCounts(address token, uint256 tokenId, bytes32 fileId)
        external
        view
        returns (uint256 artist, uint256 platform, uint256 byArtist)
    {
        LocatorCounts storage c = _locatorCounts[token][tokenId][fileId];
        return (c.artist, c.platform, c.byArtist);
    }

    /// @notice `ILocators.preferredLocator`: the preferred location of one media file of a work.
    /// @param token The token contract.
    /// @param tokenId A work with an open record.
    /// @param fileId One of the work's media files.
    /// @return location The location.
    /// @return index The locator's index, or `type(uint256).max` for none or the on-chain copy.
    /// @dev The most specific setting wins: the file's preferred index, then the collection's
    ///      preferred kind, then the token's preferred kind, then the first locator, then the
    ///      on-chain copy of an on-chain complete work, else no locator. Every choice is among
    ///      the live locators, whoever added them: a dead one is never served, and a file
    ///      preference naming one is passed over. ONCHAIN follows the flag `IWorkFacts` records.
    function preferredLocator(address token, uint256 tokenId, bytes32 fileId)
        external
        view
        returns (ILocators.Location memory location, uint256 index)
    {
        bool onChain = _media(token, tokenId, fileId).onChainComplete;
        Locator[] storage list = _locators[token][tokenId][fileId];
        // Bit `i` set for each live locator (at most 16).
        uint256 live =
            ((1 << list.length) - 1) & ~uint256(_locatorCounts[token][tokenId][fileId].dead);
        index = _filePrefs[token][tokenId][fileId];
        bool found = index != 0 && (live >> (index - 1)) & 1 != 0;
        if (found) index -= 1;
        if (!found) {
            uint256 collectionId = IStream(token).workOf(tokenId).collectionId;
            (found, index) =
                _firstOfKind(list, live, onChain, _collectionKinds[token][collectionId]);
        }
        if (!found) (found, index) = _firstOfKind(list, live, onChain, _preferredKinds[token]);
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
            location = ILocators.Location(uint8(l.kind), l.uri);
        }
    }

    /// @inheritdoc IWorkDelivery
    function setPreferredKind(address token, LocatorKind kind) external restricted {
        emit PreferredKindSet(token, _preferredKinds[token], kind);
        _preferredKinds[token] = kind;
        IDeliveryHost(records).refreshAllMetadata(token);
    }

    /// @inheritdoc IWorkDelivery
    function setCollectionPreferredKind(address token, uint256 collectionId, LocatorKind kind)
        external
        restricted
    {
        if (!IStream(token).collectionOf(collectionId).exists) {
            revert UnknownCollection(token, collectionId);
        }
        emit CollectionPreferredKindSet(
            token, collectionId, _collectionKinds[token][collectionId], kind
        );
        _collectionKinds[token][collectionId] = kind;
        IDeliveryHost(records).refreshAllMetadata(token);
    }

    /// @inheritdoc IWorkDelivery
    function setFilePreference(address token, uint256 tokenId, bytes32 fileId, uint256 index)
        external
        restricted
    {
        if (index == NONE) _media(token, tokenId, fileId);
        else _requireLive(token, tokenId, fileId, index);
        emit FilePreferenceSet(
            token, tokenId, fileId, filePreference(token, tokenId, fileId), index
        );
        _filePrefs[token][tokenId][fileId] = index == NONE ? 0 : index + 1;
        IDeliveryHost(records).refreshMetadata(token, tokenId);
    }

    /// @inheritdoc IWorkDelivery
    function markLocatorDead(address token, uint256 tokenId, bytes32 fileId, uint256 index)
        external
        restricted
    {
        LocatorCounts storage counts = _requireLive(token, tokenId, fileId, index);
        // Below 16: the file holds at most `Limits.MAX_LOCATORS_PER_FILE` locators.
        // forge-lint: disable-next-line(unsafe-typecast)
        counts.dead |= uint16(1 << index);
        emit LocatorDead(token, tokenId, fileId, index);
        IDeliveryHost(records).refreshMetadata(token, tokenId);
    }

    /// @inheritdoc IWorkDelivery
    function deadLocators(address token, uint256 tokenId, bytes32 fileId)
        external
        view
        returns (uint256)
    {
        return _locatorCounts[token][tokenId][fileId].dead;
    }

    /// @inheritdoc IWorkDelivery
    function preferredKind(address token) external view returns (LocatorKind) {
        return _preferredKinds[token];
    }

    /// @inheritdoc IWorkDelivery
    function collectionPreferredKind(address token, uint256 collectionId)
        external
        view
        returns (LocatorKind)
    {
        return _collectionKinds[token][collectionId];
    }

    /// @inheritdoc IWorkDelivery
    function filePreference(address token, uint256 tokenId, bytes32 fileId)
        public
        view
        returns (uint256)
    {
        uint256 stored = _filePrefs[token][tokenId][fileId];
        return stored == 0 ? NONE : stored - 1;
    }

    /// @notice ERC-165: `IWorkDelivery` (which `WorkRules.setDelivery` checks) and `ILocators`.
    /// @param interfaceId The interface ID to test.
    /// @return True for the `IWorkDelivery`, `ILocators` and `IERC165` interface IDs.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IWorkDelivery).interfaceId
            || interfaceId == type(ILocators).interfaceId || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------------------ internal

    /// @dev The work's facts, when its record is open and `fileId` is one of its media files.
    function _media(address token, uint256 tokenId, bytes32 fileId)
        private
        view
        returns (Facts memory f)
    {
        f = IWorkFacts(facts).factsOf(token, tokenId);
        if (!f.opened) revert RecordNotOpen(token, tokenId);
        for (uint256 i; i < f.media.length; ++i) {
            if (f.media[i].fileId == fileId) return f;
        }
        revert FileNotInWork(token, tokenId, fileId);
    }

    /// @dev Whether the caller is a wallet of the work's lead artist account now.
    function _isArtist(address token, uint256 tokenId) private view returns (bool) {
        address accounts = IModuleSlots(directory).moduleOf(Slots.ACCOUNTS);
        return IAccounts(accounts).isWallet(IStream(token).workOf(tokenId).artistId, msg.sender);
    }

    /// @dev Reverts with `InvalidLocator` unless locator `index` of one of the work's media
    ///      files exists and is not dead; returns the file's counts.
    function _requireLive(address token, uint256 tokenId, bytes32 fileId, uint256 index)
        private
        view
        returns (LocatorCounts storage counts)
    {
        _media(token, tokenId, fileId);
        counts = _locatorCounts[token][tokenId][fileId];
        if (index >= _locators[token][tokenId][fileId].length || (counts.dead >> index) & 1 != 0) {
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

    /// @dev The first live locator of `kind` (`live`, bit `i` for index `i`), or the on-chain
    ///      copy (`NONE`) when the work is on-chain complete. NONE as a kind never matches.
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
