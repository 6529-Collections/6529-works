// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_STREAM,
    Payee,
    ProductEconomics,
    WorkTerms
} from "src/interfaces/types/EconomicsTypes.sol";
import { ItemKind, License, PackageItem, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";

/// @notice Mocks of other lanes' contracts for the 6529 Editions tests. Each implements only
///         the slice of its interface that Editions calls, with the same ABI, plus test knobs.

/// @dev The package registry: approvals, consumption and per-product content uniqueness keyed
///      on a simulated content store's decoded SHA-256 (`setContent`).
contract EditionsRegistryMock {
    error NotSystem(address caller);

    mapping(bytes32 => IPackageRegistry.PackageStatus) public status;
    mapping(bytes32 => bool) public isConsumed;
    mapping(bytes32 => bytes32) public sha256Of;
    mapping(bytes32 => mapping(bytes32 => bool)) public isContentUsed;
    address public system;
    address public stream;
    bool public skipStreamUniqueness;

    event ContentClaimed(bytes32 indexed product, bytes32 indexed contentHash, bytes32 contentId);

    function setSystem(address s) external {
        system = s;
    }

    function setStream(address s) external {
        stream = s;
    }

    function setContent(bytes32 contentId, bytes32 sha) external {
        sha256Of[contentId] = sha;
    }

    function approve(bytes32 root) external {
        status[root] = IPackageRegistry.PackageStatus.APPROVED;
    }

    function revoke(bytes32 root) external {
        status[root] = IPackageRegistry.PackageStatus.REVOKED;
    }

    function setConsumed(bytes32 itemHash, bool consumed) external {
        isConsumed[itemHash] = consumed;
    }

    function preclaim(bytes32 product, bytes32 sha) external {
        isContentUsed[product][sha] = true;
    }

    function setSkipStreamUniqueness(bool skip) external {
        skipStreamUniqueness = skip;
    }

    function packageOf(bytes32 root)
        external
        view
        returns (IPackageRegistry.PackageStatus, bytes32)
    {
        return (status[root], keccak256(abi.encode("evidence", root)));
    }

    /// @dev What Stream's mint does through `consume`, reduced to the bookkeeping.
    function consume(bytes32 root, bytes32 itemHash, bytes32 contentId) external {
        if (msg.sender != stream) revert NotSystem(msg.sender);
        if (status[root] != IPackageRegistry.PackageStatus.APPROVED) {
            revert IPackageRegistry.PackageNotApproved(root);
        }
        if (isConsumed[itemHash]) revert IPackageRegistry.ItemConsumedAlready(itemHash);
        isConsumed[itemHash] = true;
        if (!skipStreamUniqueness) _claim(PRODUCT_STREAM, contentId);
    }

    function claimContent(bytes32 product, bytes32 contentId) external returns (bytes32) {
        if (msg.sender != system) revert NotSystem(msg.sender);
        return _claim(product, contentId);
    }

    function _claim(bytes32 product, bytes32 contentId) internal returns (bytes32 sha) {
        sha = sha256Of[contentId];
        if (sha == 0) revert IContentStore.ContentFileUnknown(contentId);
        if (isContentUsed[product][sha]) revert IPackageRegistry.ContentUsed(product, sha);
        isContentUsed[product][sha] = true;
        emit ContentClaimed(product, sha, contentId);
    }
}

/// @dev The economics resolver: governed product economics, an allowlist and a default
///      currency; split wallets are deterministic stand-ins for predicted CREATE2 addresses.
contract EditionsEconomicsMock {
    ProductEconomics public eco;
    address public defaultCurrency;
    mapping(address => bool) public allowed;

    constructor(address feeRecipient) {
        eco = ProductEconomics(feeRecipient, 25_000, 6_529);
        allowed[CURRENCY_ETH] = true;
    }

    function setEconomics(ProductEconomics calldata next) external {
        eco = next;
    }

    function setAllowed(address currency, bool ok) external {
        allowed[currency] = ok;
    }

    function setDefaultCurrency(address currency) external {
        defaultCurrency = currency;
    }

    function resolveCurrency(bytes32, address requested) external view returns (address c) {
        c = requested == CURRENCY_DEFAULT ? defaultCurrency : requested;
        if (!allowed[c]) revert IEconomicsResolver.CurrencyNotAllowed(c);
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

/// @dev 6529 Stream, reduced to masters and the Stream side of the edition link. `LinkMode`
///      makes the Stream side misbehave: ignore the link, record another ID, or reenter
///      `createEdition` with a stored item.
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
    address public editions;
    address public defaultRenderer;
    uint256 public totalMinted;
    LinkMode public linkMode;
    bytes public reentryItem;
    bytes public reentryError;

    mapping(uint256 => IStream.WorkInfo) internal _works;
    mapping(uint256 => address) internal _owners;
    mapping(uint256 => License) internal _licenses;
    mapping(uint256 => bool) public seedPending;
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

    function setEditions(address e) external {
        editions = e;
    }

    function setLinkMode(LinkMode mode) external {
        linkMode = mode;
    }

    function setReentryItem(PackageItem calldata item) external {
        reentryItem = abi.encode(item);
    }

    function mintMaster(bytes32 root, PackageItem calldata item, address to)
        external
        returns (uint256 id)
    {
        bytes32 itemHash = WorksHashing.itemHash(item);
        EditionsRegistryMock(packageRegistry).consume(root, itemHash, item.contentId);
        id = ++totalMinted;
        IStream.WorkInfo storage w = _works[id];
        w.packageRoot = root;
        w.itemHash = itemHash;
        w.contentId = item.contentId;
        w.metadataHash = item.metadataHash;
        w.collectionId = item.collectionId;
        w.artistId = uint256(uint160(item.parties[0].account));
        w.kind = item.kind;
        w.seedPolicy = item.seedPolicy;
        _owners[id] = to;
        _licenses[id] = item.license;
        seedPending[id] = item.seedPolicy == SeedPolicy.VRF;
    }

    function burnMaster(uint256 id) external {
        delete _owners[id];
    }

    function deliverSeed(uint256 id) external {
        seedPending[id] = false;
    }

    function setLicense(uint256 id, License calldata next) external {
        _licenses[id] = next;
    }

    function pinRenderer(uint256 id, address renderer) external {
        pinnedRenderer[id] = renderer;
    }

    function corruptContentId(uint256 id, bytes32 contentId) external {
        _works[id].contentId = contentId;
    }

    // ----- the IStream slice Editions reads

    function work(uint256 id) external view returns (IStream.WorkInfo memory) {
        if (_owners[id] == address(0)) revert IStream.UnknownWork(id);
        return _works[id];
    }

    function ownerOf(uint256 id) external view returns (address holder) {
        holder = _owners[id];
        if (holder == address(0)) revert IStream.UnknownWork(id);
    }

    function seedOf(uint256 id) external view returns (SeedPolicy, bytes32, bool) {
        return (_works[id].seedPolicy, bytes32(0), !seedPending[id]);
    }

    function licenseOf(uint256 id) external view returns (License memory) {
        return _licenses[id];
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
        if (msg.sender != editions) revert IStream.NotEditions(msg.sender);
        if (_works[tokenId].kind != ItemKind.EDITION_MASTER || _linked[tokenId] != 0) {
            revert IStream.EditionLinkInvalid(tokenId);
        }
        if (linkMode == LinkMode.IGNORE) return;
        if (linkMode == LinkMode.REENTER) {
            PackageItem memory item = abi.decode(reentryItem, (PackageItem));
            try IEditions(editions).createEdition(tokenId, item) {
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
                (ok, reason) = address(editions)
                    .call(
                        abi.encodeCall(
                            IEditions.createEdition, (id, abi.decode(_item, (PackageItem)))
                        )
                    );
            }
            reentrySucceeded = ok;
            if (!ok) reentryError = reason;
        }
        return this.onERC1155Received.selector;
    }
}
