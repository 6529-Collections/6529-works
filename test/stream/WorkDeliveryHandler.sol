// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Test } from "forge-std/Test.sol";
import { Roles } from "src/governance/Roles.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkDelivery, IWorkLocators } from "src/interfaces/IWorkDelivery.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { Locator, LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { WorkDelivery } from "src/stream/WorkDelivery.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";

/// @notice A replacement delivery contract that answers `preferredLocator` in one of six ways:
///         a revert, a bare word, an ONCHAIN claim, a URI with a space, a well-formed IPFS
///         location, or kind NONE with a URI. Only the well-formed answer may be served.
contract ScriptedDelivery {
    address public immutable records;
    address public immutable predecessor;
    uint8 public immutable mode;
    string public constant GOOD_URI =
        "ipfs://bafkreigh2akiscaildcqabsyg3dfr6chu3fgpregiymsck7e7aqa4s52zy";

    constructor(address records_, address predecessor_, uint8 mode_) {
        (records, predecessor, mode) = (records_, predecessor_, mode_);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IWorkDelivery).interfaceId || id == 0x01ffc9a7;
    }

    function preferredLocator(uint256, bytes32)
        external
        view
        returns (IWorkDelivery.Location memory, uint256)
    {
        if (mode == 0) revert("refused");
        if (mode == 1) {
            assembly ("memory-safe") {
                mstore(0, 0xbad)
                return(0, 0x20)
            }
        }
        if (mode == 2) return (IWorkDelivery.Location(uint8(LocatorKind.ONCHAIN), ""), NONE);
        if (mode == 3) return (IWorkDelivery.Location(uint8(LocatorKind.IPFS), "ipfs://a b"), 0);
        if (mode == 4) return (IWorkDelivery.Location(uint8(LocatorKind.IPFS), GOOD_URI), 7);
        return (IWorkDelivery.Location(uint8(LocatorKind.NONE), "ipfs://x"), NONE);
    }

    uint256 internal constant NONE = type(uint256).max;
}

/// @notice Drives the delivery contracts of three open works (two media files each) the way
///         the artist, the platform, the storage operator, governance and strangers would. The
///         changes go to the latest real delivery contract, which a hostile replacement leaves
///         behind: it then refuses every change (`NotDelivery` from the records satellite).
///         locators added (valid, duplicate, malformed, past the quota, after finalize),
///         locators marked dead, file, collection and global preferences, finalize, on-chain
///         sync, and replacement of the delivery contract by a new real one, by a scripted
///         hostile one, or with a stale compare-and-set value. Keeps an exact model of every
///         real delivery contract ever installed; each action predicts its outcome first and a
///         wrong prediction is counted in `violations`.
contract WorkDeliveryHandler is Test {
    uint256 internal constant NONE = type(uint256).max;
    uint256 internal constant MAX_DELIVERIES = 5;

    struct FileModel {
        uint8[] kinds;
        string[] uris;
        uint16 dead;
        uint16 byArtist;
        uint8 artistN;
        uint8 platformN;
        uint256 prefPlusOne;
    }

    WorkRecords internal immutable records;
    IStream internal immutable stream;
    address internal immutable admin;
    address internal immutable artist;
    address internal immutable platform;
    address internal immutable operator;
    address internal immutable governor;
    address internal constant STRANGER = address(0xBAD);

    uint256[] public tokens;
    mapping(uint256 token => bytes32[]) internal _files;
    mapping(uint256 token => uint256) public collectionOf;
    uint256 public collectionCount;

    address[] public deliveries;
    /// @dev Whether `deliveries[i]` is a real `WorkDelivery`; else its scripted mode.
    bool[] public isReal;
    uint8[] public scriptMode;
    /// @dev The delivery each one named as predecessor when it was installed.
    address[] public predecessorOf;
    uint256 public current;
    /// @dev The most recent real delivery, which the locator actions drive.
    uint256 public lastReal;

    mapping(uint256 d => mapping(uint256 token => mapping(bytes32 file => FileModel))) internal _m;
    mapping(uint256 d => uint8) public globalKind;
    mapping(uint256 d => mapping(uint256 collection => uint8)) public collectionKind;
    mapping(uint256 token => bool) public finalized;
    mapping(uint256 token => bool) public synced;

    uint256 internal _nonce;
    uint256 public violations;
    uint256 public added;
    uint256 public refusedAdds;
    uint256 public deaths;
    uint256 public filePrefs;
    uint256 public replacements;
    uint256 public staleSwaps;
    /// @dev Changes refused because the delivery contract driven had been replaced.
    uint256 public frozenRefusals;

    constructor(
        WorkRecords records_,
        address artist_,
        address platform_,
        address operator_,
        address governor_
    ) {
        records = records_;
        stream = IStream(records_.stream());
        admin = msg.sender;
        (artist, platform, operator, governor) = (artist_, platform_, operator_, governor_);
        deliveries.push(records_.delivery());
        isReal.push(true);
        scriptMode.push(0);
        predecessorOf.push(address(0));
    }

    function addWork(uint256 tokenId, bytes32[] calldata files, uint256 collectionId) external {
        tokens.push(tokenId);
        _files[tokenId] = files;
        collectionOf[tokenId] = collectionId;
    }

    function setCollectionCount(uint256 n) external {
        collectionCount = n;
    }

    function filesOf(uint256 tokenId) external view returns (bytes32[] memory) {
        return _files[tokenId];
    }

    function deliveryCount() external view returns (uint256) {
        return deliveries.length;
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    // ------------------------------------------------------------------------------- actions

    /// @dev The artist, the platform (twice as often) or a stranger adds a locator to the latest
    ///      real delivery: fresh (IPFS leaf, IPFS root or Arweave), a duplicate of one the file
    ///      holds, or malformed.
    function addLocator(uint256 tokenSeed, uint256 fileSeed, uint8 who, uint8 shape) external {
        (uint256 t, bytes32 f) = _pick(tokenSeed, fileSeed);
        FileModel storage m = _m[lastReal][t][f];
        address caller = who % 4 == 0 ? artist : who % 4 == 3 ? STRANGER : platform;
        Locator memory loc;
        bool duplicate;
        bool malformed;
        uint256 s = shape % 8;
        if (s == 5 && m.uris.length != 0) {
            uint256 i = uint256(keccak256(abi.encode(tokenSeed))) % m.uris.length;
            loc = Locator(LocatorKind(m.kinds[i]), m.uris[i]);
            duplicate = true;
        } else if (s == 6) {
            loc = Locator(LocatorKind.IPFS, "ipfs://not-a-cid");
            malformed = true;
        } else {
            string memory seed = vm.toString(++_nonce);
            loc = s == 7
                ? Locator(LocatorKind.IPFS, CA.ipfsRoot(seed))
                : s % 2 == 0 ? CA.ipfsLocator(seed) : CA.ar(seed);
        }
        bool byArtist = caller == artist && !finalized[t];
        bool expected;
        if (caller == STRANGER || (caller == artist && finalized[t])) {
            expected = false;
        } else if (byArtist) {
            expected = !malformed && !duplicate && m.artistN < 8;
        } else {
            uint256 used = finalized[t] ? uint256(m.platformN) + m.artistN : m.platformN;
            uint256 quota = finalized[t] ? 16 : 8;
            expected = !malformed && !duplicate && used < quota;
        }
        // A replaced delivery contract changes nothing: its refresh call is refused.
        expected = expected && lastReal == current;
        vm.prank(caller);
        try IWorkLocators(deliveries[lastReal]).addLocator(t, f, loc) {
            if (!expected) ++violations;
            uint256 index = m.kinds.length;
            m.kinds.push(uint8(loc.kind));
            m.uris.push(loc.uri);
            if (byArtist) {
                ++m.artistN;
                m.byArtist |= uint16(1 << index);
            } else {
                ++m.platformN;
            }
            ++added;
        } catch (bytes memory reason) {
            if (expected) ++violations;
            // A permitted caller is refused only for the URI, a duplicate or the quota.
            bool permitted = (caller == platform || byArtist) && lastReal == current;
            if (permitted && bytes4(reason) != IWorkLocators.InvalidLocator.selector) {
                ++violations;
            }
            ++refusedAdds;
        }
    }

    /// @dev The storage operator (or, one time in four, the platform, which may not) marks a
    ///      locator of the latest real delivery dead; an index past the end or already dead is
    ///      refused.
    function markDead(uint256 tokenSeed, uint256 fileSeed, uint256 index, uint8 who) external {
        (uint256 t, bytes32 f) = _pick(tokenSeed, fileSeed);
        FileModel storage m = _m[lastReal][t][f];
        index = index % (m.kinds.length + 1);
        address caller = who % 4 == 0 ? platform : operator;
        bool expected = caller == operator && index < m.kinds.length && (m.dead >> index) & 1 == 0
            && lastReal == current;
        vm.prank(caller);
        try IWorkLocators(deliveries[lastReal]).markLocatorDead(t, f, index) {
            if (!expected) ++violations;
            m.dead |= uint16(1 << index);
            ++deaths;
        } catch {
            if (expected) ++violations;
        }
    }

    /// @dev The storage operator sets a file's preferred index (a third of the time clears it);
    ///      a dead or missing index is refused.
    function setFilePreference(uint256 tokenSeed, uint256 fileSeed, uint256 index, uint8 mode)
        external
    {
        (uint256 t, bytes32 f) = _pick(tokenSeed, fileSeed);
        FileModel storage m = _m[lastReal][t][f];
        index = mode % 3 == 0 ? NONE : index % (m.kinds.length + 1);
        bool expected = (index == NONE || (index < m.kinds.length && (m.dead >> index) & 1 == 0))
            && lastReal == current;
        vm.prank(operator);
        try IWorkLocators(deliveries[lastReal]).setFilePreference(t, f, index) {
            if (!expected) ++violations;
            m.prefPlusOne = index == NONE ? 0 : index + 1;
            ++filePrefs;
        } catch {
            if (expected) ++violations;
        }
    }

    /// @dev The storage operator sets a collection's preferred kind; collection 0 and one past
    ///      the count are refused.
    function setCollectionKind(uint256 collectionSeed, uint8 kind) external {
        uint256 c = collectionSeed % (collectionCount + 2);
        kind = kind % 4;
        bool expected = c != 0 && c <= collectionCount && lastReal == current;
        vm.prank(operator);
        try IWorkLocators(deliveries[lastReal]).setCollectionPreferredKind(c, LocatorKind(kind)) {
            if (!expected) ++violations;
            collectionKind[lastReal][c] = kind;
        } catch {
            if (expected) ++violations;
        }
    }

    /// @dev The storage operator sets the global preferred kind.
    function setGlobalKind(uint8 kind) external {
        kind = kind % 4;
        vm.prank(operator);
        try IWorkLocators(deliveries[lastReal]).setPreferredKind(LocatorKind(kind)) {
            if (lastReal != current) ++violations;
            globalKind[lastReal] = kind;
        } catch (bytes memory reason) {
            if (lastReal == current || bytes4(reason) != IWorkRecords.NotDelivery.selector) {
                ++violations;
            }
            ++frozenRefusals;
        }
    }

    /// @dev The artist finalizes a work; a second finalize is refused.
    function finalize(uint256 tokenSeed) external {
        uint256 t = tokens[tokenSeed % tokens.length];
        bytes32 state = records.workStateHash(t);
        vm.prank(artist);
        try records.finalize(t, state) {
            if (finalized[t]) ++violations;
            finalized[t] = true;
        } catch {
            if (!finalized[t]) ++violations;
        }
    }

    /// @dev Anyone syncs a work's media from the content store, completing it on chain.
    function sync(uint256 tokenSeed) external {
        uint256 t = tokens[tokenSeed % tokens.length];
        records.syncOnChain(t, 0, type(uint256).max);
        synced[t] = true;
    }

    /// @dev Governance replaces the delivery contract: a new real one, a scripted hostile one,
    ///      or a call with a stale `expected` (an earlier delivery), which is refused; a stranger's
    ///      replacement is refused too.
    function replaceDelivery(uint8 mode, uint8 script) external {
        address cur = deliveries[current];
        if (mode % 4 == 3) {
            // A stale compare-and-set value, or a stranger.
            address stale = current == 0 ? address(0xdead) : deliveries[current - 1];
            WorkDelivery candidate = _real(cur);
            vm.prank(mode % 8 == 3 ? governor : STRANGER);
            try records.setDelivery(mode % 8 == 3 ? stale : cur, address(candidate)) {
                ++violations;
            } catch {
                ++staleSwaps;
            }
            return;
        }
        if (deliveries.length >= MAX_DELIVERIES) return;
        address next;
        bool real = mode % 4 != 2;
        if (real) next = address(_real(cur));
        else next = address(new ScriptedDelivery(address(records), cur, script % 6));
        vm.prank(governor);
        records.setDelivery(cur, next);
        deliveries.push(next);
        isReal.push(real);
        scriptMode.push(real ? 0 : script % 6);
        predecessorOf.push(cur);
        current = deliveries.length - 1;
        if (real) lastReal = current;
        ++replacements;
    }

    // ------------------------------------------------------------------------------ the model

    /// @notice The model's locators of a file in delivery `d`.
    function modelLocators(uint256 d, uint256 t, bytes32 f)
        external
        view
        returns (uint8[] memory kinds, string[] memory uris)
    {
        FileModel storage m = _m[d][t][f];
        return (m.kinds, m.uris);
    }

    /// @notice The model's counts and masks of a file in delivery `d`.
    function modelCounts(uint256 d, uint256 t, bytes32 f)
        external
        view
        returns (uint256 artistN, uint256 platformN, uint256 byArtist, uint256 dead, uint256 pref)
    {
        FileModel storage m = _m[d][t][f];
        pref = m.prefPlusOne == 0 ? NONE : m.prefPlusOne - 1;
        return (m.artistN, m.platformN, m.byArtist, m.dead, pref);
    }

    /// @notice WS-21's resolution order over the model of delivery `d`: the file's live preferred
    ///         index, the collection's kind, the global kind, the first live locator, the
    ///         implicit ONCHAIN copy of a synced work, else nothing.
    function expectedLocator(uint256 d, uint256 t, bytes32 f)
        public
        view
        returns (uint8 kind, string memory uri, uint256 index)
    {
        FileModel storage m = _m[d][t][f];
        uint256 live = ((1 << m.kinds.length) - 1) & ~uint256(m.dead);
        bool found;
        if (m.prefPlusOne != 0 && (live >> (m.prefPlusOne - 1)) & 1 != 0) {
            (found, index) = (true, m.prefPlusOne - 1);
        }
        if (!found) (found, index) = _firstOfKind(m, live, t, collectionKind[d][collectionOf[t]]);
        if (!found) (found, index) = _firstOfKind(m, live, t, globalKind[d]);
        if (!found && live != 0) {
            index = 0;
            while ((live >> index) & 1 == 0) {
                ++index;
            }
            found = true;
        }
        if (!found && synced[t]) (found, index) = (true, NONE);
        if (!found) return (0, "", NONE);
        if (index == NONE) return (uint8(LocatorKind.ONCHAIN), "", NONE);
        return (m.kinds[index], m.uris[index], index);
    }

    /// @notice What the records satellite must serve (WS-40): the current real delivery's
    ///         answer; under a scripted one only its well-formed answer, else the work's own
    ///         (ONCHAIN when synced, else nothing).
    function expectedServed(uint256 t, bytes32 f)
        external
        view
        returns (uint8 kind, string memory uri, uint256 index)
    {
        if (isReal[current]) return expectedLocator(current, t, f);
        if (scriptMode[current] == 4) {
            return (uint8(LocatorKind.IPFS), ScriptedDelivery(deliveries[current]).GOOD_URI(), 7);
        }
        return synced[t] ? (uint8(LocatorKind.ONCHAIN), "", NONE) : (0, "", NONE);
    }

    function _firstOfKind(FileModel storage m, uint256 live, uint256 t, uint8 kind)
        internal
        view
        returns (bool, uint256)
    {
        if (kind == uint8(LocatorKind.NONE)) return (false, 0);
        if (kind == uint8(LocatorKind.ONCHAIN)) return (synced[t], NONE);
        for (uint256 i; i < m.kinds.length; ++i) {
            if ((live >> i) & 1 != 0 && m.kinds[i] == kind) return (true, i);
        }
        return (false, 0);
    }

    function _pick(uint256 tokenSeed, uint256 fileSeed) internal view returns (uint256, bytes32) {
        uint256 t = tokens[tokenSeed % tokens.length];
        bytes32[] storage files = _files[t];
        return (t, files[fileSeed % files.length]);
    }

    /// @dev A new real delivery naming `predecessor`, with the first one's role mapping.
    function _real(address predecessor) internal returns (WorkDelivery next) {
        AccessManager manager = AccessManager(records.authority());
        next = new WorkDelivery(address(manager), address(records), address(stream), predecessor);
        bytes4[] memory platformSelectors = new bytes4[](1);
        platformSelectors[0] = IWorkLocators.addLocator.selector;
        bytes4[] memory operatorSelectors = new bytes4[](4);
        operatorSelectors[0] = IWorkLocators.markLocatorDead.selector;
        operatorSelectors[1] = IWorkLocators.setPreferredKind.selector;
        operatorSelectors[2] = IWorkLocators.setCollectionPreferredKind.selector;
        operatorSelectors[3] = IWorkLocators.setFilePreference.selector;
        vm.startPrank(admin);
        manager.setTargetFunctionRole(address(next), platformSelectors, Roles.PLATFORM);
        manager.setTargetFunctionRole(address(next), operatorSelectors, Roles.STORAGE_OPERATOR);
        vm.stopPrank();
    }
}
