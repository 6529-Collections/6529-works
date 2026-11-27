// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import {
    Collection,
    Core,
    MintFacts,
    Outcome,
    Slots,
    Work
} from "../interfaces/core/CoreTypes.sol";
import { IModuleSlots, IModules } from "../interfaces/core/IModules.sol";
import { IStream } from "../interfaces/core/IStream.sol";
import { IWorkFacts } from "../interfaces/core/IWorkFacts.sol";

/// @title StreamBase
/// @notice The plain permanent ERC-721 of works (ADR 0010): who owns each token, the facts fixed
///         at mint, and how the first sale ended. Shared by 6529 Stream (`Stream6529`) and each
///         Independent Stream artist's token (`IndependentStream6529`), which differ only in the
///         hooks at the end: who the minters are, which artists the token takes, where the modules
///         are, and who the admin is.
/// @dev What a module or minter can do here, and nothing more:
///      - an active minter mints, stating the work's facts; the contract checks them;
///      - a minter (active or removed) that holds a token with no outcome recorded records the
///        outcome once, or burns the token;
///      - the TERMS module sets a live token's royalty receiver and rate, and locks the rate;
///      - the RENDERER module draws a work that is not finalized (`rendererOf`);
///      - `facts()`, the RECORDS module and the TERMS module emit ERC-4906 updates.
///      The network alone may `rescue` a token that a removed minter still holds unsold, once
///      `rescueDelay` (the network's setting) has passed since the removal. Transfers,
///      approvals and `ownerOf` are OpenZeppelin's, untouched, and call nothing outside this
///      contract; `mint`, `burn` and `rescue` move tokens without a receiver callback.
///      No assembly, no hand-packed words, no gas numbers, no `try`/`catch`.
abstract contract StreamBase is ERC721, IStream {
    /// @inheritdoc IStream
    uint48 public rescueDelay = 14 days;

    /// @inheritdoc IStream
    address public immutable facts;

    /// @inheritdoc IStream
    uint256 public totalMinted;
    /// @inheritdoc IStream
    uint256 public totalBurned;
    /// @inheritdoc IStream
    uint256 public collectionCount;
    /// @inheritdoc IStream
    address public owner;
    /// @inheritdoc IStream
    string public contractURI;
    /// @inheritdoc IStream
    mapping(bytes32 contentHash => uint256 tokenId) public tokenOfContent;
    mapping(uint256 tokenId => Work) private _works;
    mapping(uint256 collectionId => Collection) private _collections;

    /// @param name_ The ERC-721 name.
    /// @param symbol_ The ERC-721 symbol.
    /// @param facts_ The permanent record contract (`IWorkFacts`).
    /// @param owner_ The first marketplace owner.
    constructor(string memory name_, string memory symbol_, address facts_, address owner_)
        ERC721(name_, symbol_)
    {
        facts = facts_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        emit RescueDelaySet(0, rescueDelay);
    }

    // ------------------------------------------------------------------------------ minters

    /// @inheritdoc IStream
    /// @dev Writes five new storage slots (the owner, three work slots, the content's token),
    ///      six with a seed. Mints without a receiver callback: nothing outside this contract
    ///      runs during a mint except the `_isMinter` hook.
    function mint(address to, MintFacts calldata f) external returns (uint256 tokenId) {
        if (!_isMinter(msg.sender)) revert IModules.NotMinter(msg.sender);
        if (
            f.itemHash == 0 || f.contentHash == 0 || f.artistId == 0
                || f.artistId > type(uint160).max || f.royaltyRate > Core.DENOMINATOR
                || (f.royaltyReceiver == address(0) && f.royaltyRate != 0)
                || !_takesArtist(f.artistId)
        ) revert InvalidMint();
        uint256 existing = tokenOfContent[f.contentHash];
        if (existing != 0 && _ownerOf(existing) != address(0)) {
            revert ContentAlreadyMinted(f.contentHash, existing);
        }
        Collection storage c = _collections[f.collectionId];
        if (!c.exists) revert UnknownCollection(f.collectionId);

        tokenId = ++totalMinted;
        uint32 serial = ++c.minted;
        tokenOfContent[f.contentHash] = tokenId;
        Work storage w = _works[tokenId];
        w.itemHash = f.itemHash;
        // Checked above: at most 160 bits. An existing collection's ID fits 32 bits
        // (`_createCollection`).
        // forge-lint: disable-next-line(unsafe-typecast)
        w.artistId = uint160(f.artistId);
        // forge-lint: disable-next-line(unsafe-typecast)
        w.collectionId = uint32(f.collectionId);
        w.serial = serial;
        w.kind = f.kind;
        w.seedPolicy = f.seedPolicy;
        w.royaltyReceiver = f.royaltyReceiver;
        w.royaltyRate = f.royaltyRate;
        if (f.seed != 0) w.seed = f.seed;
        _mint(to, tokenId);
        emit WorkMinted(tokenId, f.collectionId, f.artistId, msg.sender, serial, f);
    }

    /// @inheritdoc IStream
    /// @dev For UNSOLD the log carries a zero buyer and a zero price whatever the minter states,
    ///      as the event promises. The price is not stored.
    function recordPrimarySale(uint256 tokenId, bool sold, address buyer, uint256 price) external {
        Work storage w = _inPrimarySale(tokenId);
        if (sold) {
            w.outcome = Outcome.SOLD;
            emit PrimarySale(tokenId, Outcome.SOLD, buyer, price);
        } else {
            w.outcome = Outcome.UNSOLD;
            emit PrimarySale(tokenId, Outcome.UNSOLD, address(0), 0);
        }
    }

    /// @inheritdoc IStream
    /// @dev The token's record (`workOf`) stays and its ID is never reused. `tokenOfContent`
    ///      keeps naming the burned token, and `mint` accepts the content again.
    function burn(uint256 tokenId) external {
        _inPrimarySale(tokenId);
        ++totalBurned;
        _burn(tokenId);
    }

    // ------------------------------------------------------------------------------ network

    /// @inheritdoc IStream
    /// @dev Rescuable exactly when the token is live, its holder is reported removed by the
    ///      hooks (`_minterRemovedAt` nonzero), no outcome is recorded, and `rescueDelay` as it
    ///      stands now has passed since that removal. A minter added again is no longer removed.
    ///      Records RESCUED, then moves the token without a receiver callback. Never to this
    ///      contract, where the token could never move again, nor to the zero address.
    function rescue(uint256 tokenId, address to) external {
        _checkNetwork();
        if (to == address(this) || to == address(0)) revert ERC721InvalidReceiver(to);
        address holder = _requireOwned(tokenId);
        Work storage w = _works[tokenId];
        uint256 removedAt = _minterRemovedAt(holder);
        if (
            w.outcome != Outcome.NONE || removedAt == 0 || block.timestamp < removedAt + rescueDelay
        ) revert NotRescuable(tokenId);
        w.outcome = Outcome.RESCUED;
        emit PrimarySale(tokenId, Outcome.RESCUED, address(0), 0);
        emit WorkRescued(tokenId, holder, to);
        _transfer(holder, to, tokenId);
    }

    /// @inheritdoc IStream
    function setRescueDelay(uint48 next) external {
        _checkNetwork();
        emit RescueDelaySet(rescueDelay, next);
        rescueDelay = next;
    }

    /// @inheritdoc IStream
    function createCollection(string calldata name_, bytes32 metadataHash)
        external
        returns (uint256 collectionId)
    {
        _checkAdmin();
        return _createCollection(name_, metadataHash);
    }

    /// @inheritdoc IStream
    function setOwner(address next) external {
        _checkAdmin();
        emit OwnershipTransferred(owner, next);
        owner = next;
    }

    /// @inheritdoc IStream
    function setContractURI(string calldata uri) external {
        _checkAdmin();
        contractURI = uri;
        emit ContractURISet(uri);
        emit ContractURIUpdated();
    }

    // -------------------------------------------------------------------------- terms module

    /// @inheritdoc IStream
    /// @dev Any other caller reverts with `IModuleSlots.NotModule`.
    function setRoyalty(uint256 tokenId, address receiver, uint24 rate) external {
        _onlyTerms();
        _requireOwned(tokenId);
        Work storage w = _works[tokenId];
        if (
            rate > Core.DENOMINATOR || (receiver == address(0) && rate != 0)
                || (w.royaltyRateLocked && rate != w.royaltyRate)
        ) {
            revert InvalidRoyalty();
        }
        w.royaltyReceiver = receiver;
        w.royaltyRate = rate;
        emit RoyaltySet(tokenId, receiver, rate);
    }

    /// @inheritdoc IStream
    /// @dev Any other caller reverts with `IModuleSlots.NotModule`. Locking again changes
    ///      nothing.
    function lockRoyaltyRate(uint256 tokenId) external {
        _onlyTerms();
        _requireOwned(tokenId);
        _works[tokenId].royaltyRateLocked = true;
        emit RoyaltyRateLocked(tokenId);
    }

    /// @inheritdoc IStream
    function emitMetadataUpdate(uint256 fromTokenId, uint256 toTokenId) external {
        if (
            msg.sender != facts && msg.sender != _moduleOf(Slots.RECORDS)
                && msg.sender != _moduleOf(Slots.TERMS)
        ) revert NotMetadataSource(msg.sender);
        if (fromTokenId == toTokenId) emit MetadataUpdate(fromTokenId);
        else emit BatchMetadataUpdate(fromTokenId, toTokenId);
    }

    // --------------------------------------------------------------------------------- views

    /// @inheritdoc IStream
    function workOf(uint256 tokenId) external view returns (Work memory) {
        return _works[tokenId];
    }

    /// @inheritdoc IStream
    function itemHashOf(uint256 tokenId) external view returns (bytes32) {
        _requireOwned(tokenId);
        return _works[tokenId].itemHash;
    }

    /// @inheritdoc IStream
    function collectionOf(uint256 collectionId) external view returns (Collection memory) {
        return _collections[collectionId];
    }

    /// @inheritdoc IStream
    function totalSupply() external view returns (uint256) {
        return totalMinted - totalBurned;
    }

    /// @inheritdoc IERC2981
    /// @dev This contract's storage only: no module is asked, so marketplaces always get an
    ///      answer. Exact for any price: `salePrice * rate / 100,000` rounded down, computed
    ///      without overflow. An unminted ID answers the zero address and zero; a burned token
    ///      answers its last values.
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        Work storage w = _works[tokenId];
        return (w.royaltyReceiver, Math.mulDiv(salePrice, w.royaltyRate, Core.DENOMINATOR));
    }

    /// @inheritdoc IStream
    /// @dev Answers for every work ever minted, a burned one included (its record stays), so the
    ///      editions of a burned master are still drawn. Zero when the work is not finalized and
    ///      no RENDERER module is installed; `tokenURI` then reverts.
    function rendererOf(uint256 tokenId) public view returns (address renderer) {
        if (_works[tokenId].itemHash == 0) revert ERC721NonexistentToken(tokenId);
        renderer = IWorkFacts(facts).rendererOf(address(this), tokenId);
        if (renderer == address(0)) renderer = _moduleOf(Slots.RENDERER);
    }

    /// @notice The token's metadata, built by `rendererOf(tokenId)`.
    /// @dev Reverts for a burned or unminted token, and if the renderer is missing, reverts, runs
    ///      out of gas, or (pinned) changed its code. Never falls back to another renderer.
    /// @param tokenId A live token.
    /// @return The metadata URI.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return IRenderer(rendererOf(tokenId)).tokenURI(address(this), tokenId);
    }

    /// @inheritdoc IERC165
    /// @dev ERC-165, ERC-721, ERC-721 metadata, ERC-2981, ERC-4906 (`0x49064906`) and `IStream`.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721, IERC165)
        returns (bool)
    {
        return interfaceId == type(IERC2981).interfaceId || interfaceId == bytes4(0x49064906)
            || interfaceId == type(IStream).interfaceId || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------------------ internal

    /// @dev Creates a collection (also used by an Independent Stream token's constructor). IDs run
    ///      from 1 and fit 32 bits, the width a work stores.
    function _createCollection(string memory name_, bytes32 metadataHash)
        internal
        returns (uint256 collectionId)
    {
        collectionId = SafeCast.toUint32(++collectionCount);
        Collection storage c = _collections[collectionId];
        c.exists = true;
        c.metadataHash = metadataHash;
        c.name = name_;
        emit CollectionCreated(collectionId, name_, metadataHash);
    }

    /// @dev A token the calling minter (active or removed) holds with no outcome recorded.
    function _inPrimarySale(uint256 tokenId) private view returns (Work storage w) {
        w = _works[tokenId];
        if (_ownerOf(tokenId) != msg.sender || !_wasMinter(msg.sender) || w.outcome != Outcome.NONE)
        {
            revert NotInPrimarySale(tokenId);
        }
    }

    /// @dev Reverts unless the caller is the TERMS module. The caller is never the zero address,
    ///      so an empty slot admits nobody.
    function _onlyTerms() private view {
        if (msg.sender != _moduleOf(Slots.TERMS)) {
            revert IModuleSlots.NotModule(Slots.TERMS, msg.sender);
        }
    }

    // --------------------------------------------------------------------- hooks (frozen)

    /// @dev The module installed in `slot` for this token, or zero.
    function _moduleOf(bytes32 slot) internal view virtual returns (address);

    /// @dev Whether `account` may mint now.
    function _isMinter(address account) internal view virtual returns (bool);

    /// @dev Whether `account` is or was an active minter.
    function _wasMinter(address account) internal view virtual returns (bool);

    /// @dev Whether this token takes works of `artistId`: every artist unless the concrete
    ///      token narrows it (an Independent Stream token takes its own artist only).
    function _takesArtist(uint256) internal view virtual returns (bool) {
        return true;
    }

    /// @dev When `account` was removed as a minter, or zero.
    function _minterRemovedAt(address account) internal view virtual returns (uint256);

    /// @dev Reverts unless the caller is the contract's admin (collections, owner, contract URI).
    function _checkAdmin() internal virtual;

    /// @dev Reverts unless the caller is the network (`rescue`, `setRescueDelay`).
    function _checkNetwork() internal virtual;
}
