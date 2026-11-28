// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Collection, Facts, Media, Slots, Work } from "src/interfaces/core/CoreTypes.sol";
import { ILocators } from "src/interfaces/core/ILocators.sol";
import { Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";

/// @dev What a test states about a work in the token: the fields the renderer shows.
struct WorkCore {
    bytes32 itemHash;
    uint256 artistId;
    uint256 collectionId;
    uint64 serial;
    uint8 kind;
    uint8 seedPolicy;
    address seller;
    address royaltyReceiver;
    uint32 royaltyRate;
}

/// @dev What a test states about a collection.
struct CollectionInfo {
    string name;
    bytes32 metadataHash;
    uint64 minted;
}

/// @dev What a test states about a work's permanent record (`IWorkFacts.Facts`, without the
///      license and media, which have their own setters).
struct RecordInfo {
    bytes32 recordFileId;
    bytes32 mediaHash;
    bytes32 licenseKey;
    uint32 version;
    bool finalized;
    bool onChainComplete;
    address renderer;
}

/// @dev A token holding works, as the renderer reads it: `workOf`, `collectionOf`, `facts()` and
///      `moduleOf(RECORDS)`, answered from fixtures; `fail(selector, true)` makes one read revert.
///      A work with a zero item hash was never minted (`workOf` answers it empty, as Stream does).
contract RendererStreamMock {
    address public facts;
    mapping(bytes32 => address) internal modules;
    mapping(uint256 => Work) internal works;
    mapping(uint256 => Collection) internal collections;
    mapping(bytes4 => bool) internal failing;

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC165).interfaceId || id == type(IERC721).interfaceId;
    }

    function fail(bytes4 selector, bool on) external {
        failing[selector] = on;
    }

    function setFacts(address facts_) external {
        facts = facts_;
    }

    function setModule(bytes32 slot, address module) external {
        modules[slot] = module;
    }

    function setWork(uint256 id, WorkCore calldata core) external {
        Work storage w = works[id];
        w.itemHash = core.itemHash;
        w.artistId = uint160(core.artistId);
        // forge-lint: disable-next-line(unsafe-typecast)
        w.collectionId = uint32(core.collectionId);
        // forge-lint: disable-next-line(unsafe-typecast)
        w.serial = uint32(core.serial);
        w.kind = core.kind;
        w.seedPolicy = core.seedPolicy;
    }

    function setSeed(uint256 id, bytes32 seed) external {
        works[id].seed = seed;
    }

    function setCollection(uint256 id, CollectionInfo calldata c) external {
        // forge-lint: disable-next-line(unsafe-typecast)
        collections[id] = Collection(true, uint32(c.minted), c.metadataHash, c.name);
    }

    /// @dev Sets a collection's stored name to raw bytes (any, UTF-8 or not).
    function setCollectionName(uint256 id, bytes calldata name) external {
        collections[id].name = string(name);
    }

    function workOf(uint256 id) external view returns (Work memory) {
        _gate(msg.sig);
        return works[id];
    }

    function collectionOf(uint256 id) external view returns (Collection memory) {
        _gate(msg.sig);
        return collections[id];
    }

    function moduleOf(bytes32 slot) external view returns (address) {
        _gate(msg.sig);
        return modules[slot];
    }

    function _gate(bytes4 selector) internal view {
        require(!failing[selector], "mock failure");
    }
}

/// @dev The permanent record (`IWorkFacts.factsOf`), the RECORDS module (`IWorkRules.delivery`)
///      and the delivery contract (`ILocators.preferredLocator`) in one, keyed by work ID (one
///      token per test). `fail` and `burn` act per selector; `setRaw` makes `preferredLocator`
///      answer any bytes for a file.
contract RendererRecordsMock {
    mapping(uint256 => RecordInfo) internal infos;
    mapping(uint256 => bool) internal opened;
    mapping(uint256 => bytes) internal medias;
    mapping(uint256 => License) internal licenses;
    mapping(uint256 => mapping(bytes32 => Locator[])) internal locatorLists;
    mapping(uint256 => mapping(bytes32 => bool)) internal onchainPreferred;
    mapping(bytes32 => bytes) internal raws;
    mapping(bytes4 => bool) internal failing;
    mapping(bytes4 => uint256) internal burning;
    address public deliveryAddress = address(this);

    function fail(bytes4 selector, bool on) external {
        failing[selector] = on;
    }

    /// @dev Makes `selector` spend about `amount` gas more, as a costlier contract would.
    function burn(bytes4 selector, uint256 amount) external {
        burning[selector] = amount;
    }

    function setDelivery(address next) external {
        deliveryAddress = next;
    }

    function setRecord(uint256 id, RecordInfo calldata info) external {
        infos[id] = info;
    }

    function record(uint256 id) external view returns (RecordInfo memory) {
        return infos[id];
    }

    function setOpen(uint256 id, bool open) external {
        opened[id] = open;
    }

    function setMedia(uint256 id, MediaFile[] calldata media) external {
        medias[id] = abi.encode(media);
    }

    function setLicense(uint256 id, License calldata license) external {
        licenses[id] = license;
    }

    function addLocator(uint256 id, bytes32 fileId, Locator calldata locator) external {
        locatorLists[id][fileId].push(locator);
    }

    function preferOnchain(uint256 id, bytes32 fileId, bool on) external {
        onchainPreferred[id][fileId] = on;
    }

    function setRaw(bytes32 fileId, bytes calldata answer) external {
        raws[fileId] = answer;
    }

    /// @dev `IWorkFacts.factsOf`: an empty record until it is open, as `StreamWorkFacts6529`
    ///      answers.
    function factsOf(address, uint256 id) external view returns (Facts memory f) {
        _gate(msg.sig);
        if (!opened[id]) return f;
        RecordInfo storage info = infos[id];
        f.opened = true;
        f.recordFileId = info.recordFileId;
        f.onChainComplete = info.onChainComplete;
        f.finalized = info.finalized;
        f.renderer = info.renderer;
        f.licenseId = licenses[id].spdxId;
        f.licenseTextFileId = licenses[id].textFileId;
        if (medias[id].length != 0) {
            MediaFile[] memory m = abi.decode(medias[id], (MediaFile[]));
            f.media = new Media[](m.length);
            for (uint256 i; i < m.length; ++i) {
                f.media[i] = Media(m[i].fileId, m[i].role);
            }
        }
    }

    /// @dev `IWorkRules.delivery`.
    function delivery() external view returns (address) {
        _gate(msg.sig);
        return deliveryAddress;
    }

    /// @dev `ILocators.preferredLocator`, as `WorkDelivery` answers it: NONE for a file without
    ///      a locator, the first locator otherwise, ONCHAIN when preferred.
    function preferredLocator(address, uint256 id, bytes32 fileId)
        external
        view
        returns (ILocators.Location memory, uint256)
    {
        _gate(msg.sig);
        bytes memory raw = raws[fileId];
        if (raw.length != 0) {
            assembly ("memory-safe") {
                return(add(raw, 0x20), mload(raw))
            }
        }
        if (onchainPreferred[id][fileId]) {
            return (ILocators.Location(uint8(LocatorKind.ONCHAIN), ""), type(uint256).max);
        }
        Locator[] storage list = locatorLists[id][fileId];
        if (list.length == 0) {
            return (ILocators.Location(uint8(LocatorKind.NONE), ""), type(uint256).max);
        }
        return (ILocators.Location(uint8(list[0].kind), list[0].uri), 0);
    }

    function _gate(bytes4 selector) internal view {
        require(!failing[selector], "mock failure");
        uint256 amount = burning[selector];
        if (amount != 0) {
            uint256 stop = gasleft() - amount;
            while (gasleft() > stop) { }
        }
    }
}

/// @dev An editions token: ERC-1155 by ERC-165, its master token in `stream()`.
contract RendererEditionsMock {
    address internal master;
    bool public broken;

    constructor(address stream_) {
        master = stream_;
    }

    function stream() external view returns (address) {
        require(!broken, "editions down");
        return master;
    }

    function setBroken(bool on) external {
        broken = on;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0xd9b67a26;
    }
}

/// @dev Wires a renderer test's token and records mock together.
library RendererWiring {
    function wire(RendererStreamMock stream, RendererRecordsMock records) internal {
        stream.setFacts(address(records));
        stream.setModule(Slots.RECORDS, address(records));
    }
}

/// @dev A delivery contract (and RECORDS module: `delivery()` answers itself) that misbehaves
///      in `preferredLocator`: it lies (an answer that is not a printable URI), answers a URI
///      over `Limits.MAX_URI_BYTES`, answers bytes that are not a canonical encoding, reverts,
///      burns `burn` gas before answering honestly, or burns everything.
contract HostileDelivery {
    enum Mode {
        HONEST,
        QUOTE,
        BACKSLASH,
        SPACE,
        CONTROL,
        HIGH_BYTE,
        OVERSIZED,
        MALFORMED,
        KIND_OVER_255,
        ONCHAIN_WITH_URI,
        REVERT,
        BURN_SOME,
        BURN_ALL
    }

    Mode public mode;
    uint256 public burn;
    string public uri = "ar://honest";

    function setMode(Mode next, uint256 burn_) external {
        (mode, burn) = (next, burn_);
    }

    function setUri(string calldata next) external {
        uri = next;
    }

    function delivery() external view returns (address) {
        return address(this);
    }

    function preferredLocator(address, uint256, bytes32)
        external
        view
        returns (ILocators.Location memory l, uint256 index)
    {
        Mode m = mode;
        l = ILocators.Location(uint8(LocatorKind.ARWEAVE), uri);
        if (m == Mode.QUOTE) l.uri = 'ar://a"b';
        if (m == Mode.BACKSLASH) l.uri = string(hex"61723a2f2f615c62");
        if (m == Mode.SPACE) l.uri = "ar://a b";
        if (m == Mode.CONTROL) l.uri = "ar://a\nb";
        if (m == Mode.HIGH_BYTE) l.uri = string(hex"61723a2f2fc3a9");
        if (m == Mode.OVERSIZED) {
            bytes memory b = new bytes(2_049);
            for (uint256 i; i < b.length; ++i) {
                b[i] = "a";
            }
            l.uri = string(b);
        }
        if (m == Mode.ONCHAIN_WITH_URI) l.kind = uint8(LocatorKind.ONCHAIN);
        if (m == Mode.REVERT) revert("hostile");
        if (m == Mode.MALFORMED) {
            assembly ("memory-safe") {
                mstore(0, 0x40)
                mstore(0x20, 0)
                mstore(0x40, 1)
                mstore(0x60, 0x20) // the inner offset is not 0x40
                return(0, 0x80)
            }
        }
        if (m == Mode.KIND_OVER_255) {
            bytes memory e = abi.encode(l, uint256(0));
            assembly ("memory-safe") {
                mstore(add(e, 0x60), 0x100)
                return(add(e, 0x20), mload(e))
            }
        }
        if (m == Mode.BURN_SOME || m == Mode.BURN_ALL) {
            uint256 start = gasleft();
            uint256 amount = m == Mode.BURN_ALL ? type(uint256).max : burn;
            while (start - gasleft() < amount) { }
        }
        index = 0;
    }
}
