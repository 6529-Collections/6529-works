// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Editions } from "src/editions/Editions.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import {
    PRODUCT_EDITIONS,
    PRODUCT_STREAM,
    Payee,
    ProductEconomics,
    WorkTerms
} from "src/interfaces/types/EconomicsTypes.sol";
import { ItemKind, License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";

/// @notice Mocks of other lanes' contracts for the 6529 Editions tests. Each implements only
///         the slice of its interface that Editions calls, with the same ABI, plus test knobs.

/// @dev A deterministic package for an item: a two-leaf tree of the item's leaf and a sibling
///      leaf derived from `salt`, so different salts give different roots for the same item.
library EditionsPackages {
    function packageOf(PackageItem memory item, uint256 salt)
        internal
        pure
        returns (bytes32 root, bytes32[] memory proof)
    {
        bytes32 itemHash = WorksHashing.itemHash(item);
        bytes32 leaf = WorksHashing.leaf(itemHash);
        bytes32 sibling = keccak256(abi.encode("sibling", itemHash, salt));
        proof = new bytes32[](1);
        proof[0] = sibling;
        root = leaf < sibling
            ? keccak256(abi.encode(leaf, sibling))
            : keccak256(abi.encode(sibling, leaf));
    }
}

/// @dev The package registry's content claims: Stream's consume records `contentHash -> itemHash`
///      under PRODUCT_STREAM; Editions may claim a hash under PRODUCT_EDITIONS only for the item
///      Stream consumed, once (`IPackageRegistry.claimContent`).
contract EditionsRegistryMock {
    mapping(bytes32 => IPackageRegistry.PackageStatus) internal _status;
    mapping(bytes32 => bytes32) public consumedItemOf;
    mapping(bytes32 => bytes32) public editionClaimOf;
    address public stream;
    address public editions;
    bool public skipStreamUniqueness;

    event ContentClaimed(bytes32 indexed contentHash, bytes32 indexed itemHash);

    function bindCallers(address stream_, address editions_) external {
        stream = stream_;
        editions = editions_;
    }

    function approve(bytes32 root) external {
        _status[root] = IPackageRegistry.PackageStatus.APPROVED;
    }

    function revoke(bytes32 root) external {
        _status[root] = IPackageRegistry.PackageStatus.REVOKED;
    }

    function packageOf(bytes32 root)
        external
        view
        returns (IPackageRegistry.PackageStatus, bytes32, address)
    {
        return (_status[root], keccak256(abi.encode("evidence", root)), address(0xC0FFEE));
    }

    function setSkipStreamUniqueness(bool skip) external {
        skipStreamUniqueness = skip;
    }

    /// @dev Makes the registry report another consumed item for `contentHash`.
    function setConsumedItem(bytes32 contentHash, bytes32 itemHash) external {
        consumedItemOf[contentHash] = itemHash;
    }

    function preclaim(bytes32 contentHash, bytes32 itemHash) external {
        editionClaimOf[contentHash] = itemHash;
    }

    /// @dev What Stream's mint does through `consume`, reduced to the uniqueness word.
    function consume(bytes32 itemHash, bytes32 contentHash) external {
        if (msg.sender != stream) revert IPackageRegistry.NotBoundCaller(msg.sender);
        bytes32 claimedBy = consumedItemOf[contentHash];
        if (claimedBy != 0 && !skipStreamUniqueness) {
            revert IPackageRegistry.ContentUsed(PRODUCT_STREAM, contentHash, claimedBy);
        }
        consumedItemOf[contentHash] = itemHash;
    }

    function claimContent(bytes32 contentHash, bytes32 itemHash) external {
        if (msg.sender != editions) revert IPackageRegistry.NotBoundCaller(msg.sender);
        if (consumedItemOf[contentHash] != itemHash) {
            revert IPackageRegistry.ClaimNotAllowed(PRODUCT_EDITIONS, contentHash);
        }
        bytes32 claimedBy = editionClaimOf[contentHash];
        if (claimedBy != 0) {
            revert IPackageRegistry.ContentUsed(PRODUCT_EDITIONS, contentHash, claimedBy);
        }
        editionClaimOf[contentHash] = itemHash;
        emit ContentClaimed(contentHash, itemHash);
    }
}

/// @dev The economics resolver: governed product economics; split wallets are deterministic
///      stand-ins for predicted CREATE2 addresses.
contract EditionsEconomicsMock {
    ProductEconomics public eco;

    constructor(address feeRecipient) {
        eco = ProductEconomics(feeRecipient, 25_000, 6_529);
    }

    function setEconomics(ProductEconomics calldata next) external {
        eco = next;
    }

    function newWorkTerms(bytes32 product, Payee[] calldata payees)
        external
        view
        returns (WorkTerms memory)
    {
        return WorkTerms({
            seller: predict(abi.encode("seller", product, payees)),
            feeRecipient: eco.feeRecipient,
            feeShare: eco.feeShare,
            royaltyReceiver: predict(abi.encode("royalty", product, payees, eco)),
            royaltyRate: eco.royaltyRate
        });
    }

    function predict(bytes memory salt) public pure returns (address) {
        return address(uint160(uint256(keccak256(salt))));
    }
}

/// @dev The artist registry: the authority is the artist ID's address until recovered.
contract EditionsArtistsMock {
    mapping(uint256 => address) internal _recovered;

    function recover(uint256 artistId, address next) external {
        _recovered[artistId] = next;
    }

    function authorityOf(uint256 artistId) external view returns (address a) {
        if (artistId == 0) revert IArtistRegistry.UnknownArtist(artistId);
        a = _recovered[artistId];
        if (a == address(0)) a = address(uint160(artistId));
    }
}

/// @dev A renderer that names itself, the token and the ID, so routing is observable.
contract EditionsRendererMock {
    string internal _label;

    constructor(string memory label) {
        _label = label;
    }

    function tokenURI(address token, uint256 id) external view returns (string memory) {
        return string.concat(_label, ":", Strings.toHexString(token), ":", Strings.toString(id));
    }
}

/// @dev The work-records satellite: opened records, each master's license (CC0 unless set;
///      `RecordNotOpen` until opened, decision E9), and its calls into Editions as the bound
///      satellite.
contract EditionsWorkRecordsMock {
    mapping(uint256 => License) internal _licenses;
    mapping(uint256 => bool) public isOpen;

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IERC165).interfaceId
                || interfaceId == type(IWorkRecords).interfaceId;
    }

    function openRecord(uint256 id) external {
        isOpen[id] = true;
    }

    function setLicense(uint256 id, License calldata next) external {
        _licenses[id] = next;
    }

    function licenseOf(uint256 id) external view returns (License memory l) {
        if (!isOpen[id]) revert IWorkRecords.RecordNotOpen(id);
        l = _licenses[id];
        if (bytes(l.spdxId).length == 0) l = License("CC0-1.0", keccak256("CC0 1.0 legal code"));
    }

    function notify(Editions editions, uint256 workId) external {
        editions.notifyMasterUpdated(workId);
    }

    function setRate(Editions editions, uint256 editionId, uint32 rate) external {
        editions.setRoyaltyRate(editionId, rate);
    }

    function notifyAll(Editions editions) external {
        editions.notifyAllUpdated();
    }
}

/// @dev 6529 Stream core, reduced to masters, their primary-sale settlement and the Stream side
///      of the edition link. A master is minted into auction custody and is unsettled until
///      `settle`. `LinkMode` makes the Stream side misbehave: ignore the link, record another
///      ID, or reenter `createEdition` with a stored item.
contract EditionsStreamMock {
    enum LinkMode {
        NORMAL,
        IGNORE,
        WRONG_ID,
        REENTER
    }

    address public packageRegistry;
    address public economics;
    address public artistRegistry;
    address public workRecords;
    address public editions;
    address public defaultRenderer;
    uint256 public totalMinted;
    LinkMode public linkMode;
    bytes public reentryItem;
    bytes public reentryError;

    mapping(uint256 => IStream.WorkCore) internal _works;
    mapping(uint256 => address) internal _owners;
    mapping(uint256 => bool) internal _settled;
    mapping(uint256 => address) public pinnedRenderer;
    mapping(uint256 => uint256) internal _linked;

    event EditionLinked(uint256 indexed tokenId, address indexed editions, uint256 editionId);

    constructor(address registry, address resolver, address artists, address renderer) {
        packageRegistry = registry;
        economics = resolver;
        artistRegistry = artists;
        defaultRenderer = renderer;
    }

    // ----- knobs

    function bind(address workRecords_, address editions_) external {
        workRecords = workRecords_;
        editions = editions_;
    }

    function setLinkMode(LinkMode mode) external {
        linkMode = mode;
    }

    function setReentryItem(PackageItem calldata item) external {
        reentryItem = abi.encode(item);
    }

    function mintMaster(PackageItem calldata item, address to) external returns (uint256 id) {
        bytes32 itemHash = WorksHashing.itemHashCalldata(item);
        EditionsRegistryMock(packageRegistry).consume(itemHash, item.contentHash);
        id = ++totalMinted;
        IStream.WorkCore storage w = _works[id];
        w.itemHash = itemHash;
        w.artistId = uint256(uint160(item.parties[0].account));
        w.collectionId = item.collectionId;
        w.kind = item.kind;
        w.seedPolicy = item.seedPolicy;
        _owners[id] = to;
    }

    /// @dev The auction settled and delivered the master to `to` (or a later transfer).
    function settle(uint256 id, address to) external {
        _owners[id] = to;
        _settled[id] = true;
    }

    /// @dev An upheld dispute burns the master in custody.
    function burnMaster(uint256 id) external {
        delete _owners[id];
        delete _settled[id];
    }

    function pinRenderer(uint256 id, address renderer) external {
        pinnedRenderer[id] = renderer;
    }

    // ----- the IStream slice Editions reads

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC721).interfaceId;
    }

    function work(uint256 id) external view returns (IStream.WorkCore memory) {
        if (_owners[id] == address(0)) revert IStream.UnknownWork(id);
        return _works[id];
    }

    function primarySaleSettled(uint256 id) external view returns (bool) {
        return _settled[id] && _owners[id] != address(0);
    }

    function ownerOf(uint256 id) external view returns (address holder) {
        holder = _owners[id];
        if (holder == address(0)) revert IStream.UnknownWork(id);
    }

    function rendererOf(uint256 id) external view returns (address r) {
        r = pinnedRenderer[id];
        if (r == address(0)) r = defaultRenderer;
    }

    function editionOf(uint256 id) external view returns (address, uint256) {
        uint256 editionId = _linked[id];
        return editionId == 0 ? (address(0), 0) : (editions, editionId);
    }

    function linkEdition(uint256 tokenId, uint256 editionId) external {
        if (msg.sender != editions) revert IStream.NotBound(msg.sender);
        if (_works[tokenId].kind != ItemKind.EDITION_MASTER || _linked[tokenId] != 0) {
            revert IStream.EditionLinkInvalid(tokenId);
        }
        if (linkMode == LinkMode.IGNORE) return;
        if (linkMode == LinkMode.REENTER) {
            PackageItem memory item = abi.decode(reentryItem, (PackageItem));
            (bytes32 root, bytes32[] memory proof) = EditionsPackages.packageOf(item, 0);
            try Editions(editions).createEdition(tokenId, item, root, proof) {
                reentryError = "";
            } catch (bytes memory reason) {
                reentryError = reason;
            }
        }
        _linked[tokenId] = linkMode == LinkMode.WRONG_ID ? editionId + 1 : editionId;
        emit EditionLinked(tokenId, editions, editionId);
    }
}

/// @dev A shared sale adapter reduced to its `IMintTarget` calls. It can hold copies (for
///      `burn`), and buys on behalf of whoever calls it, like a real adapter's purchase.
contract EditionsAdapterMock is ERC1155Holder {
    bytes32 public saleKind;
    PrimaryTerms internal _last;

    constructor(bytes32 kind) {
        saleKind = kind;
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(ISaleAdapter).interfaceId || super.supportsInterface(interfaceId);
    }

    function buy(IMintTarget target, uint256 id, address to, uint256 amount)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        (tokenId, terms) = target.mint(to, id, amount, "");
        _last = terms;
    }

    function buyWithData(IMintTarget target, uint256 id, address to, bytes calldata data) external {
        target.mint(to, id, 1, data);
    }

    function burnHeld(IMintTarget target, uint256 id, uint256 amount) external {
        target.burn(id, amount);
    }

    function lastTerms() external view returns (PrimaryTerms memory) {
        return _last;
    }
}

/// @dev Rejects every copy by reverting.
contract RevertingReceiver1155 {
    error Refused();

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert Refused();
    }
}

/// @dev Accepts by returning the wrong magic value.
contract WrongSelectorReceiver1155 {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return 0xdeadbeef;
    }
}

/// @dev Has code but no receiver hook.
contract NoHookReceiver1155 {
    uint256 public unused;
}

/// @dev Burns all gas it is given in the receiver hook.
contract GasBurnerReceiver1155 {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        assembly {
            for { } 1 { } { }
        }
        return 0;
    }
}

/// @dev On its first receipt, reenters once: through the adapter (a second purchase), directly
///      into `mint` (not a MINTER), or into `createEdition`. Records the reentry's revert data and
///      accepts the original copy.
contract ReentrantReceiver1155 is ERC1155Holder {
    enum Mode {
        ADAPTER,
        DIRECT,
        CREATE
    }

    EditionsAdapterMock public immutable adapter;
    IEditions public immutable editions;
    Mode public mode;
    bool internal _entered;
    bool public reentrySucceeded;
    bytes public reentryError;
    bytes internal _item;

    constructor(EditionsAdapterMock adapter_, IEditions editions_) {
        adapter = adapter_;
        editions = editions_;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setItem(PackageItem calldata item) external {
        _item = abi.encode(item);
    }

    function onERC1155Received(address, address, uint256 id, uint256, bytes memory)
        public
        override
        returns (bytes4)
    {
        if (!_entered) {
            _entered = true;
            bool ok;
            bytes memory reason;
            if (mode == Mode.ADAPTER) {
                (ok, reason) = address(adapter)
                    .call(abi.encodeCall(adapter.buy, (editions, id, address(this), 1)));
            } else if (mode == Mode.DIRECT) {
                (ok, reason) = address(editions)
                    .call(abi.encodeCall(IMintTarget.mint, (address(this), id, 1, "")));
            } else {
                PackageItem memory item = abi.decode(_item, (PackageItem));
                (bytes32 root, bytes32[] memory proof) = EditionsPackages.packageOf(item, 0);
                try Editions(address(editions)).createEdition(id, item, root, proof) {
                    ok = true;
                } catch (bytes memory r) {
                    reason = r;
                }
            }
            reentrySucceeded = ok;
            if (!ok) reentryError = reason;
        }
        return this.onERC1155Received.selector;
    }
}
