// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Splits } from "../economics/Splits.sol";
import { IContentStore } from "../interfaces/IContentStore.sol";
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
import { IFederatedEditions } from "../interfaces/IFederatedEditions.sol";
import { IFederatedStream } from "../interfaces/IFederatedStream.sol";
import { IFederatedToken } from "../interfaces/IFederatedToken.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import { IStreamViews } from "../interfaces/IStreamViews.sol";
import { IWorkDelivery } from "../interfaces/IWorkDelivery.sol";
import { IWorkRecords } from "../interfaces/IWorkRecords.sol";
import { MediaFile } from "../interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH } from "../interfaces/types/EconomicsTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { License, PackageItem } from "../interfaces/types/PackageTypes.sol";
import { PrimaryOutcome, PrimarySettlement, PrimaryTerms } from "../interfaces/types/SaleTypes.sol";
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { FederatedMembership } from "./FederatedMembership.sol";

/// @title FederatedStream
/// @notice Federated Stream template: an artist's own ERC-721 of 1/1s, uncurated, listed in the
///         network's directory and sold through the network's shared adapters at the network's
///         locked 10% (ADR 0008; FED-10 to FED-30 in `docs/spec/federation.md`).
/// @dev Deployed as a full copy per artist, never behind a proxy or a clone. A work is minted
///      only into the custody of the adapter that starts its sale; unsold, the token returns to
///      this contract's own custody and the work can be offered again, so a work leaves this
///      contract only through a sale. Settlement makes no external call and reads no identity
///      state (the nine template guarantees of `stream-and-auctions.md`). The record the shared
///      renderer reads is held here; this contract is its own `workRecords()`.
contract FederatedStream is ERC721, FederatedMembership, IFederatedStream {
    /// @dev Token states.
    uint8 private constant IN_SALE = 1;
    uint8 private constant SOLD = 2;
    uint8 private constant UNBID = 3;
    uint8 private constant FROZEN_OUT = 4;
    uint8 private constant RETURNED = 5;
    /// @dev Work flags.
    uint8 private constant FINALIZED = 1;
    uint8 private constant ONCHAIN = 2;
    uint8 private constant FEE_BEARING = 4;
    /// @dev Item kinds and seed policies this template mints (`ItemKind`, `SeedPolicy`).
    uint8 private constant EDITION_MASTER = 1;
    uint8 private constant SEED_ARTIST = 1;
    /// @dev `_items` word: bit 0 approved, bits 8 to 31 the royalty rate, from bit 32 the work.
    uint256 private constant APPROVED = 1;
    /// @dev The one collection: this contract, named by the token name.
    uint256 private constant COLLECTION = 1;

    /// @dev A work. Slot 0 packs the seller vault, rate, kind, seed policy, flags, live token and
    ///      record version. `files` holds the media count (top byte) and each file's role (byte
    ///      `i`); `media` the file IDs (their SHA-256 is the content store's, checked at mint).
    struct Work {
        address seller;
        uint24 royaltyRate;
        uint8 kind;
        uint8 seedPolicy;
        uint8 flags;
        uint32 token;
        uint16 version;
        bytes32 itemHash;
        bytes32 recordFileId;
        uint256 files;
        bytes32 seed;
        address renderer;
        bytes32 rendererCodeHash;
        License license;
        bytes32[32] media;
    }

    /// @dev A token: its minting adapter, work, sale state and whether its sale terms carry the
    ///      network's fee (minted before the exit).
    struct Token {
        address adapter;
        uint32 workId;
        uint8 state;
        bool fee;
    }

    address private _contentStore;
    address private _defaultRenderer;
    bytes32 private _defaultRendererCodeHash;
    uint32 private _workCount;
    uint32 private _tokenCount;
    mapping(bytes32 itemHash => uint256) private _items;
    mapping(uint256 workId => Work) private _works;
    mapping(uint256 tokenId => Token) private _tokens;
    /// @dev A sold token's currency (low 160 bits) and price (high 96, saturated).
    mapping(uint256 tokenId => uint256) private _sales;
    mapping(uint256 workId => mapping(uint256 index => IWorkDelivery.Location)) private _locators;

    /// @param c The deployment arguments (`IFederatedStream.Config`).
    constructor(Config memory c)
        ERC721(c.name, c.symbol)
        FederatedMembership(
            c.artistRegistry,
            c.splitLedger,
            c.artistId,
            c.feeShare,
            c.feeRecipient,
            address(0),
            c.owner
        )
    {
        Dependency.check(c.contentStore);
        _contentStore = c.contentStore;
        _setRenderer(c.renderer, c.rendererCodeHash);
    }

    // ------------------------------------------------------------------ items and minting

    /// @inheritdoc IFederatedStream
    function approveItem(bytes32 itemHash, uint32 royaltyRate) external {
        _onlyArtist();
        if (royaltyRate > Splits.DENOMINATOR) revert InvalidRoyaltyRate(royaltyRate);
        _items[itemHash] = (_items[itemHash] >> 32) << 32 | uint256(royaltyRate) << 8 | APPROVED;
        emit ItemApproval(itemHash, royaltyRate, true);
    }

    /// @inheritdoc IFederatedStream
    function revokeItem(bytes32 itemHash) external {
        _onlyArtist();
        _items[itemHash] = (_items[itemHash] >> 32) << 32;
        emit ItemApproval(itemHash, 0, false);
    }

    /// @inheritdoc IMintTarget
    /// @dev An admitted adapter mints into its own custody (`to == msg.sender`, `id` 0, `amount`
    ///      1) with `data` `abi.encode(FederatedMint(item, media))` of an approved item, sold in
    ///      ETH. The first mint of an item creates its work (`WorkOpened`): every file must be
    ///      registered in the content store with the declared SHA-256, and the seller vault of
    ///      the item's payees (and, while listed, the royalty vault) is deployed now, so no sale
    ///      ever pays an undeployed vault. A later approved mint of the same item restarts its
    ///      unsold work: the token in this contract's custody is burned and the next ID minted.
    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        _onlyMinter();
        if (to != msg.sender || id != 0 || amount != 1) revert InvalidMintRequest();
        FederatedMint memory m = abi.decode(data, (FederatedMint));
        PackageItem memory item = m.item;
        bytes32 itemHash = WorksHashing.itemHash(item);
        uint256 approval = _items[itemHash];
        if (approval & APPROVED == 0 || item.sale.currency != CURRENCY_ETH) {
            revert InvalidMintRequest();
        }
        uint256 workId = approval >> 32;
        if (workId == 0) {
            // Safe: the rate was bounded by `approveItem`.
            // forge-lint: disable-next-line(unsafe-typecast)
            workId = _open(item, m.media, itemHash, uint24(approval >> 8));
        } else {
            _restart(workId);
        }
        _items[itemHash] = workId << 32;
        Work storage w = _works[workId];
        tokenId = ++_tokenCount;
        // Safe: token IDs and work IDs are 32-bit counters.
        // forge-lint: disable-next-line(unsafe-typecast)
        w.token = uint32(tokenId);
        (address feeRecipient, uint32 feeShare) = _feeTerms();
        // forge-lint: disable-next-line(unsafe-typecast)
        _tokens[tokenId] = Token(msg.sender, uint32(workId), IN_SALE, feeShare != 0);
        _mint(to, tokenId);
        emit TokenMinted(tokenId, workId, msg.sender, feeShare);
        terms = PrimaryTerms(
            item.sale.saleKind,
            CURRENCY_ETH,
            0,
            item.sale.params,
            w.seller,
            feeRecipient,
            feeShare,
            address(this)
        );
    }

    /// @inheritdoc IMintTarget
    /// @dev The minting adapter only, once, while it holds the token: SOLD records the sale;
    ///      UNBID and FROZEN_OUT move the token into this contract's own custody, with no
    ///      receiver call, and return this contract as `holder`. No external call, no identity
    ///      read: the terms returned were fixed at mint.
    function settlePrimary(
        uint256 tokenId,
        PrimaryOutcome outcome,
        address buyer,
        address currency,
        uint256 price
    ) public virtual returns (PrimarySettlement memory s) {
        Token storage t = _tokens[tokenId];
        if (t.adapter != msg.sender) revert NotMintingAdapter(msg.sender);
        if (t.state != IN_SALE) revert SaleAlreadySettled(tokenId);
        if (outcome == PrimaryOutcome.SOLD) {
            if (buyer == address(0)) revert InvalidSaleOutcome();
            t.state = SOLD;
            _sales[tokenId] =
                uint160(currency) | (price < type(uint96).max ? price : type(uint96).max) << 160;
        } else {
            if (
                (outcome != PrimaryOutcome.UNBID && outcome != PrimaryOutcome.FROZEN_OUT)
                    || buyer != address(0) || price != 0
            ) revert InvalidSaleOutcome();
            t.state = outcome == PrimaryOutcome.UNBID ? UNBID : FROZEN_OUT;
            address from = _update(address(this), tokenId, address(0));
            if (from != msg.sender) revert ERC721IncorrectOwner(msg.sender, tokenId, from);
            s.holder = address(this);
        }
        emit PrimarySaleSettled(tokenId, outcome, buyer, currency, price);
        s.seller = _works[t.workId].seller;
        if (t.fee) (s.feeRecipient, s.feeShare) = (_feeRecipient, _feeShare);
    }

    /// @inheritdoc IMintTarget
    /// @dev For a minted token: the seller, the fee terms its sale carries and this contract as
    ///      creator (an unsold token comes back here, never to a person). The sale kind is not
    ///      recorded (zero). Storage reads only.
    function primaryTerms(uint256 id, bytes calldata)
        external
        view
        returns (PrimaryTerms memory p)
    {
        Token storage t = _tokens[id];
        if (t.adapter == address(0)) revert UnknownWork(id);
        p.seller = _works[t.workId].seller;
        if (t.fee) (p.feeRecipient, p.feeShare) = (_feeRecipient, _feeShare);
        p.creator = address(this);
    }

    /// @inheritdoc IMintTarget
    /// @dev The minting adapter only, from its own custody, before the sale settles: an upheld
    ///      dispute's cancel. The work keeps its record and has no live token afterwards.
    function burn(uint256 id, uint256 amount) external {
        Token storage t = _tokens[id];
        if (amount != 1) revert InvalidMintRequest();
        if (t.adapter != msg.sender) revert NotMintingAdapter(msg.sender);
        if (t.state != IN_SALE) revert SaleAlreadySettled(id);
        address holder = _ownerOf(id);
        if (holder != msg.sender) revert ERC721IncorrectOwner(msg.sender, id, holder);
        _works[t.workId].token = 0;
        _burn(id);
    }

    /// @inheritdoc IFederatedStream
    function reclaim(uint256 tokenId) external {
        Token storage t = _tokens[tokenId];
        address adapter = t.adapter;
        if (t.state != IN_SALE || _ownerOf(tokenId) != adapter) {
            revert WorkNotRestartable(t.workId);
        }
        IEnglishAuction(adapter)
            .claimDelivery(IEnglishAuction(adapter).saleIdOf(address(this), tokenId), address(this));
        if (t.state != RETURNED) revert WorkNotRestartable(t.workId);
    }

    /// @notice Accepts only this contract's own token, back from its minting adapter while its
    ///         sale is unsettled (`reclaim`); it is then unsold (`WorkReturned`).
    /// @param from The previous holder: the token's minting adapter.
    /// @param tokenId The token.
    /// @return The ERC-721 acceptance selector.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        returns (bytes4)
    {
        Token storage t = _tokens[tokenId];
        if (msg.sender != address(this) || t.state != IN_SALE || from != t.adapter) {
            revert ERC721InvalidReceiver(address(this));
        }
        t.state = RETURNED;
        emit WorkReturned(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ the artist's record

    /// @inheritdoc IFederatedStream
    function setRecord(uint256 tokenId, bytes32 recordFileId) external {
        (uint256 workId, Work storage w) = _editable(tokenId);
        w.recordFileId = recordFileId;
        ++w.version;
        emit RecordChanged(workId, recordFileId);
        emit MetadataUpdate(tokenId);
    }

    /// @inheritdoc IFederatedStream
    function finalize(uint256 tokenId) external {
        (uint256 workId, Work storage w) = _editable(tokenId);
        (address renderer, bytes32 codeHash) = (_defaultRenderer, _defaultRendererCodeHash);
        Dependency.checkUnchanged(renderer, codeHash);
        (w.renderer, w.rendererCodeHash) = (renderer, codeHash);
        w.flags |= FINALIZED;
        ++w.version;
        emit Finalized(workId, renderer, codeHash);
        emit MetadataUpdate(tokenId);
    }

    /// @inheritdoc IFederatedStream
    function setRoyaltyRate(uint256 tokenId, uint32 rate) external {
        _onlyArtist();
        (uint256 workId, Work storage w) = _work(tokenId);
        uint32 previous = w.royaltyRate;
        if (rate >= previous) revert InvalidRoyaltyRate(rate);
        // Safe: below the previous 24-bit rate.
        // forge-lint: disable-next-line(unsafe-typecast)
        w.royaltyRate = uint24(rate);
        ++w.version;
        emit RoyaltyRateChanged(workId, previous, rate);
        emit MetadataUpdate(tokenId);
    }

    /// @inheritdoc IFederatedStream
    function setLocator(uint256 tokenId, uint256 index, uint8 kind, string calldata uri) external {
        _onlyArtist();
        (uint256 workId, Work storage w) = _work(tokenId);
        if (index >= w.files >> 248) revert UnknownWork(tokenId);
        _locators[workId][index] = IWorkDelivery.Location(kind, uri);
        emit LocatorSet(workId, index, kind, uri);
        emit MetadataUpdate(tokenId);
    }

    /// @inheritdoc IFederatedStream
    function syncOnChain(uint256 tokenId) external {
        (uint256 workId, Work storage w) = _work(tokenId);
        uint256 count = w.files >> 248;
        for (uint256 i; i < count; ++i) {
            if (!IContentStore(_contentStore).isComplete(w.media[i])) revert UnknownWork(tokenId);
        }
        if (w.flags & ONCHAIN == 0) {
            w.flags |= ONCHAIN;
            emit OnChainComplete(workId);
            emit MetadataUpdate(tokenId);
        }
    }

    /// @inheritdoc IFederatedStream
    function setDefaultRenderer(address renderer, bytes32 codeHash) external {
        _onlyArtist();
        _setRenderer(renderer, codeHash);
        uint256 minted = _tokenCount;
        if (minted != 0) emit BatchMetadataUpdate(1, minted);
    }

    /// @inheritdoc IFederatedStream
    function linkEditions(address editions) external {
        _onlyArtist();
        if (_partner != address(0) || _settled() || editions.code.length == 0) {
            revert FederationStateInvalid();
        }
        _partner = editions;
        emit EditionsLinked(editions);
    }

    // ------------------------------------------------------------------ sale views

    /// @inheritdoc IFederatedStream
    function tokenInfo(uint256 tokenId) external view returns (uint256, address, uint8) {
        Token storage t = _tokens[tokenId];
        return (t.workId, t.adapter, t.state);
    }

    /// @inheritdoc IFederatedStream
    function liveTokenOf(uint256 workId) external view returns (uint256) {
        return _works[workId].token;
    }

    /// @inheritdoc IFederatedStream
    function primarySale(uint256 tokenId)
        external
        view
        returns (PrimaryOutcome outcome, address currency, uint256 price)
    {
        uint8 state = _tokens[tokenId].state;
        if (state == SOLD) {
            uint256 sale = _sales[tokenId];
            return (PrimaryOutcome.SOLD, address(uint160(sale)), sale >> 160);
        }
        if (state == UNBID) outcome = PrimaryOutcome.UNBID;
        if (state == FROZEN_OUT) outcome = PrimaryOutcome.FROZEN_OUT;
    }

    /// @inheritdoc IFederatedStream
    function primarySaleSettled(uint256 tokenId) external view returns (bool) {
        uint8 state = _tokens[tokenId].state;
        return state >= SOLD && state <= FROZEN_OUT;
    }

    /// @notice ERC-2981 royalty information.
    /// @param tokenId A live token.
    /// @param salePrice The sale price.
    /// @return receiver The royalty receiver.
    /// @return amount The royalty.
    /// @dev Works minted while listed pay their royalties to the 90/10 vault of the seller and
    ///      the locked fee recipient (`Splits.royaltyPayees`), deployed at mint; later works to
    ///      the seller vault. Exact `floor(price * rate / 100,000)` for any price.
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 amount)
    {
        (, Work storage w) = _work(tokenId);
        receiver = _receiver(w);
        amount = Splits.entitlement(salePrice, w.royaltyRate);
    }

    // ------------------------------------------------------------------ renderer surface

    /// @notice What the renderer reads of a work (`IStreamViews.work`): the item hash, the
    ///         artist, the one collection, the work ID as its serial, kind, seed policy, seller,
    ///         royalty receiver and rate.
    /// @param tokenId A live token.
    /// @return c The work's core.
    function work(uint256 tokenId) external view returns (IStreamViews.WorkCore memory c) {
        (uint256 workId, Work storage w) = _work(tokenId);
        c = IStreamViews.WorkCore(
            w.itemHash,
            _artistId,
            COLLECTION,
            // Safe: a 32-bit work ID.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint64(workId),
            w.kind,
            w.seedPolicy,
            w.seller,
            _receiver(w),
            w.royaltyRate
        );
    }

    /// @inheritdoc IFederatedStream
    function coreOf(uint256 tokenId)
        external
        view
        returns (bytes32, uint256, uint256, uint8, uint8, uint32)
    {
        (, Work storage w) = _work(tokenId);
        return (w.itemHash, _artistId, COLLECTION, w.kind, w.seedPolicy, w.royaltyRate);
    }

    /// @notice The one collection (`IStreamViews.collection`): this contract, by its name.
    /// @param collectionId 1.
    /// @return The name, no metadata hash, and the works created.
    function collection(uint256 collectionId)
        external
        view
        returns (IStreamViews.Collection memory)
    {
        if (collectionId != COLLECTION) {
            revert UnknownWork(collectionId);
        }
        return IStreamViews.Collection(name(), 0, _workCount);
    }

    /// @inheritdoc IFederatedStream
    function workRecords() external view returns (address) {
        return address(this);
    }

    /// @notice Whether a live token's record is open (`IWorkRecords.isOpen`): always, from mint.
    /// @param tokenId A token.
    /// @return True for a live token.
    function isOpen(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /// @notice A work's record state (`IWorkRecords.record`).
    /// @param tokenId A live token.
    /// @return r The record file, media commitment, license key, version, flags and pin.
    function record(uint256 tokenId) external view returns (IWorkRecords.RecordInfo memory r) {
        (, Work storage w) = _work(tokenId);
        uint8 flags = w.flags;
        r = IWorkRecords.RecordInfo(
            w.recordFileId,
            WorksHashing.mediaHash(_mediaOf(w)),
            WorksHashing.licenseKey(w.license.spdxId),
            w.version,
            flags & FINALIZED != 0,
            flags & ONCHAIN != 0,
            w.renderer
        );
    }

    /// @notice A work's media list (`IWorkRecords.mediaOf`), primary first.
    /// @param tokenId A live token.
    /// @return The files, with the SHA-256 the content store declares (checked at mint).
    function mediaOf(uint256 tokenId) external view returns (MediaFile[] memory) {
        (, Work storage w) = _work(tokenId);
        return _mediaOf(w);
    }

    /// @notice A work's license (`IWorkRecords.licenseOf`), fixed by its item.
    /// @param tokenId A live token.
    /// @return The license.
    function licenseOf(uint256 tokenId) external view returns (License memory) {
        (, Work storage w) = _work(tokenId);
        return w.license;
    }

    /// @notice A work's seed policy and seed (`IWorkRecords.seedOf`): none or the artist's.
    /// @param tokenId A live token.
    /// @return The policy.
    /// @return The seed, zero under NONE.
    function seedOf(uint256 tokenId) external view returns (uint8, bytes32) {
        (, Work storage w) = _work(tokenId);
        return (w.seedPolicy, w.seed);
    }

    /// @inheritdoc IFederatedStream
    function preferredLocator(uint256 tokenId, bytes32 fileId)
        external
        view
        returns (IWorkDelivery.Location memory, uint256 index)
    {
        (uint256 workId, Work storage w) = _work(tokenId);
        uint256 count = w.files >> 248;
        for (; index < count; ++index) {
            if (w.media[index] == fileId) return (_locators[workId][index], index);
        }
        revert UnknownWork(tokenId);
    }

    /// @inheritdoc IFederatedStream
    function rendererOf(uint256 tokenId) public view returns (address renderer) {
        (, Work storage w) = _work(tokenId);
        bytes32 codeHash;
        (renderer, codeHash) = w.flags & FINALIZED != 0
            ? (w.renderer, w.rendererCodeHash)
            : (_defaultRenderer, _defaultRendererCodeHash);
        Dependency.checkUnchanged(renderer, codeHash);
    }

    /// @notice The token's metadata, built by `rendererOf(tokenId)`.
    /// @param tokenId A live token.
    /// @return The metadata URI.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return IRenderer(rendererOf(tokenId)).tokenURI(address(this), tokenId);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IERC2981).interfaceId
            || interfaceId == type(IMintTarget).interfaceId
            || interfaceId == type(IFederatedToken).interfaceId
            || interfaceId == type(IFederatedStream).interfaceId
            || interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------ internal

    /// @dev Creates the work of a newly minted item: checks the media against the item and the
    ///      content store, deploys the payout vaults and writes the record.
    function _open(
        PackageItem memory item,
        MediaFile[] memory media,
        bytes32 itemHash,
        uint24 royaltyRate
    ) private returns (uint256 workId) {
        uint256 count = media.length;
        if (
            count == 0 || count > Limits.MAX_MEDIA_FILES || item.contentHash == 0
                || media[0].sha256Hash != item.contentHash
                || WorksHashing.mediaHash(media) != item.mediaHash || item.kind > EDITION_MASTER
                || item.seedPolicy > SEED_ARTIST
                || (item.kind == EDITION_MASTER && _partner == address(0))
        ) revert InvalidMintRequest();
        workId = ++_workCount;
        Work storage w = _works[workId];
        uint256 files = count << 248;
        for (uint256 i; i < count; ++i) {
            MediaFile memory f = media[i];
            // Reverts for a file the store does not know.
            if (
                IContentStore(_contentStore).sha256Of(f.fileId) != f.sha256Hash || f.role > 15
                    || (f.role == 0) != (i == 0)
            ) revert InvalidMintRequest();
            w.media[i] = f.fileId;
            files |= uint256(f.role) << (8 * i);
        }
        w.files = files;
        (w.itemHash, w.recordFileId, w.license) = (itemHash, item.recordFileId, item.license);
        if (item.seedPolicy == SEED_ARTIST) w.seed = item.seed;
        bool fee = _openTerms(w, item, royaltyRate);
        emit WorkOpened(workId, itemHash, w.seller, royaltyRate, fee, item, media);
    }

    /// @dev Writes a new work's first word: the seller vault of the item's payees (deployed now),
    ///      and, while listed, the deployed royalty vault's flag; returns whether it bears fees.
    function _openTerms(Work storage w, PackageItem memory item, uint24 royaltyRate)
        private
        returns (bool fee)
    {
        address seller = _vault(item.payees);
        (address feeRecipient, uint32 feeShare) = _feeTerms();
        fee = feeShare != 0;
        if (fee) _vault(Splits.royaltyPayees(seller, feeRecipient, feeShare));
        w.seller = seller;
        w.royaltyRate = royaltyRate;
        (w.kind, w.seedPolicy, w.flags) = (item.kind, item.seedPolicy, fee ? FEE_BEARING : 0);
    }

    /// @dev Burns a work's unsold token held in this contract's custody so its next one can be
    ///      minted; an edition master only while no edition sale has bound its token.
    function _restart(uint256 workId) private {
        Work storage w = _works[workId];
        uint256 old = w.token;
        if (
            old == 0 || _ownerOf(old) != address(this) || _tokens[old].state < UNBID
                || (w.kind == EDITION_MASTER && IFederatedEditions(_partner).isBound(old))
        ) revert WorkNotRestartable(workId);
        _burn(old);
    }

    /// @dev The work of a live token.
    function _work(uint256 tokenId) private view returns (uint256 workId, Work storage w) {
        if (_ownerOf(tokenId) == address(0)) revert UnknownWork(tokenId);
        workId = _tokens[tokenId].workId;
        w = _works[workId];
    }

    /// @dev The artist's work of a live token, not finalized.
    function _editable(uint256 tokenId) private view returns (uint256 workId, Work storage w) {
        _onlyArtist();
        (workId, w) = _work(tokenId);
        if (w.flags & FINALIZED != 0) revert WorkFinalized(workId);
    }

    /// @dev The royalty receiver of a work.
    function _receiver(Work storage w) private view returns (address) {
        return w.flags & FEE_BEARING != 0 ? _royaltyVault(w.seller) : w.seller;
    }

    /// @dev A work's media list, with each file's SHA-256 from the content store.
    function _mediaOf(Work storage w) private view returns (MediaFile[] memory media) {
        uint256 files = w.files;
        media = new MediaFile[](files >> 248);
        for (uint256 i; i < media.length; ++i) {
            bytes32 fileId = w.media[i];
            media[i] = MediaFile(
                fileId, IContentStore(_contentStore).sha256Of(fileId), uint8(files >> (8 * i))
            );
        }
    }

    /// @dev Installs the default renderer: ERC-165 `IRenderer` and the pinned code hash.
    function _setRenderer(address renderer, bytes32 codeHash) private {
        Dependency.checkPinned(renderer, type(IRenderer).interfaceId, codeHash);
        (_defaultRenderer, _defaultRendererCodeHash) = (renderer, codeHash);
        emit DefaultRendererSet(renderer, codeHash);
    }
}
