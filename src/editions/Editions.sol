// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IStream } from "../interfaces/IStream.sol";
import {
    PRODUCT_EDITIONS,
    SHARE_DENOMINATOR,
    WorkTerms
} from "../interfaces/types/EconomicsTypes.sol";
import {
    EditionFormat,
    EditionTerms,
    ItemKind,
    License,
    PackageItem
} from "../interfaces/types/PackageTypes.sol";
import { DutchParams, PrimaryTerms, SaleKind } from "../interfaces/types/SaleTypes.sol";
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";

/// @notice Whether a Stream master's primary sale has settled (ADR 0001 section 6; PR #10
///         review decision D14).
/// @dev A minimal local interface until the revised `IStream` names this read. It must be true
///      only once the master's auction has settled, so a master that is still in auction custody,
///      paused for a dispute, or burned after an upheld dispute never gets an edition.
interface IMasterSale {
    /// @notice Whether the primary sale of Stream token `tokenId` has settled.
    function primarySaleSettled(uint256 tokenId) external view returns (bool);
}

/// @title Editions
/// @notice 6529 Editions: the one shared ERC-1155 of editions, each anchored by a 6529 Stream
///         work of kind EDITION_MASTER (ADR 0001 section 6).
/// @dev The edition ID equals the master's Stream token ID. `createEdition` is permissionless:
///      it accepts only the exact package item the master was minted from (its item hash is the
///      one Stream recorded), only while the package is approved and the item consumed, and only
///      after the master's auction has settled, so a disputed or burned master never gets an
///      edition (a VRF master's seed is delivered before its auction starts). It locks the
///      edition's economics (seller, network fee, royalty), claims the master's content hash
///      under `PRODUCT_EDITIONS` (so editions never share media, while an edition reuses its own
///      master's hash, which Stream claimed under `PRODUCT_STREAM`), and writes both directions
///      of the link in one transaction, verifying Stream's side afterwards. Nothing ever changes
///      or removes a link.
///
///      Copies are minted only by MINTER adapters whose sale kind matches the package's, at
///      most `size` copies ever (burns do not free supply), and for OPEN editions only during
///      `window` seconds from the first mint. The currency has one owner, the sale adapter:
///      `primaryTerms` and `mint` return the package's stored currency, possibly
///      `CURRENCY_DEFAULT`, without resolving or re-validating it; the adapter resolves it once
///      when it opens a sale, locks it, and checks on each purchase that the locked asset is still
///      active (ADR 0001 section 5: each sale locks its currency when it starts). Royalties are
///      the terms locked at creation, read from this contract's storage with no external call.
///      The license and `uri` come from the master: `uri` is served by the master's renderer,
///      which reads the master's content-store bytes. ERC-4906 `MetadataUpdate` is emitted when an
///      edition is created and whenever the bound work-records contract reports that its master's
///      record, license or renderer changed; Stream may signal a default-renderer change, which
///      emits one `BatchMetadataUpdate` over every ID.
///
///      Wiring is immutable. Stream is checked at deployment (code, no EIP-7702 delegation,
///      ERC-165 for ERC-721, pinned code hash), and the package registry, economics resolver and
///      artist registry are taken from it, so Editions always talks to the same contracts as its
///      masters. The package registry must bind Editions as its Editions caller (`claimContent`)
///      and Stream must name it as `editions()` (`linkEdition`). Genesis wiring binds the
///      work-records satellite once (`bindWorkRecords`).
contract Editions is IEditions, ERC1155, AccessManaged {
    /// @dev `abi.encode(DutchParams)`: three static words.
    uint256 private constant DUTCH_PARAMS_LENGTH = 96;

    /// @dev An edition plus what it keeps beside the interface's `Edition` view.
    struct Record {
        Edition edition;
        uint256 artistId;
    }

    /// @inheritdoc IEditions
    address public immutable stream;
    /// @notice The package registry that approved the masters and claims edition content.
    IPackageRegistry public immutable packageRegistry;
    /// @notice The economics resolver whose `PRODUCT_EDITIONS` terms editions lock.
    IEconomicsResolver public immutable economics;
    /// @notice The artist registry that resolves each edition's creator.
    IArtistRegistry public immutable artistRegistry;

    string private _contractURI;
    address private _owner;
    mapping(uint256 editionId => Record) private _records;
    mapping(uint256 editionId => bytes32) private _contentHashes;

    /// @notice The work-records satellite allowed to report master metadata changes, bound once.
    address public workRecords;

    /// @notice An OPEN edition's window started with its first mint; minting ends at `end`.
    event EditionWindowOpened(uint256 indexed editionId, uint64 start, uint256 end);
    /// @notice ERC-4906: the metadata of edition `_tokenId` changed.
    event MetadataUpdate(uint256 _tokenId);
    /// @notice ERC-4906: the metadata of editions `_fromTokenId` to `_toTokenId` changed.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    /// @notice The contract URI changed from `previous` to `next` (beside ERC-7572's
    ///         `ContractURIUpdated`, which carries no values).
    event ContractURISet(string previous, string next);
    /// @notice The work-records satellite was bound, permanently, with its reviewed code hash.
    event WorkRecordsBound(address indexed workRecords, bytes32 codeHash);

    /// @notice A required address is zero.
    error ZeroAddress();
    /// @notice A dependency has no code, is an EIP-7702 delegated account, or lacks the expected
    ///         ERC-165 interface.
    error InvalidDependency(address dependency);
    /// @notice A dependency's code hash is not the reviewed one.
    error CodeHashMismatch(bytes32 expected, bytes32 actual);
    /// @notice The work-records satellite is already bound.
    error AlreadyBound();
    /// @notice The caller is not the bound work-records satellite.
    error NotWorkRecords(address caller);
    /// @notice The caller is not Stream.
    error NotStream(address caller);
    /// @notice The master's auction has not settled.
    error MasterNotSettled(uint256 workId);
    /// @notice The master's package is revoked or its item is not consumed.
    error MasterNotApproved(uint256 workId);
    /// @notice The item's edition terms are malformed (format, size, window, sale kind, params).
    error InvalidEditionTerms(uint256 workId);
    /// @notice Stream did not record the link back to this edition.
    error LinkFailed(uint256 workId);
    /// @notice A mint or preview carried data, or a mint or burn a zero amount.
    error InvalidMintRequest();
    /// @notice The calling adapter's sale kind is not the edition's.
    error SaleKindMismatch(bytes32 expected, bytes32 actual);

    /// @param authority_ The AccessManager that governs this contract.
    /// @param stream_ The 6529 Stream contract; the other wiring is read from it.
    /// @param streamCodeHash The reviewed code hash of `stream_`.
    /// @param owner_ The initial marketplace owner.
    constructor(address authority_, address stream_, bytes32 streamCodeHash, address owner_)
        ERC1155("")
        AccessManaged(authority_)
    {
        _checkInstall(stream_, streamCodeHash, type(IERC721).interfaceId);
        IStream s = IStream(stream_);
        (address registry, address resolver, address artists) =
            (s.packageRegistry(), s.economics(), s.artistRegistry());
        if (registry == address(0) || resolver == address(0) || artists == address(0)) {
            revert ZeroAddress();
        }
        stream = stream_;
        packageRegistry = IPackageRegistry(registry);
        economics = IEconomicsResolver(resolver);
        artistRegistry = IArtistRegistry(artists);
        _owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    // ----------------------------------------------------------------------- the link

    /// @inheritdoc IEditions
    function createEdition(uint256 workId, PackageItem calldata item)
        external
        returns (uint256 editionId)
    {
        Record storage r = _records[workId];
        if (r.edition.contentId != 0) revert EditionExists(workId);
        IStream.WorkInfo memory master = IStream(stream).work(workId);
        if (!IMasterSale(stream).primarySaleSettled(workId)) revert MasterNotSettled(workId);
        bytes32 itemHash = WorksHashing.itemHash(item);
        if (
            item.kind != ItemKind.EDITION_MASTER || master.kind != ItemKind.EDITION_MASTER
                || itemHash != master.itemHash || item.contentId != master.contentId
                || item.contentId == 0
        ) revert NotEditionMaster(workId);
        (IPackageRegistry.PackageStatus status,) = packageRegistry.packageOf(master.packageRoot);
        if (
            status != IPackageRegistry.PackageStatus.APPROVED
                || !packageRegistry.isConsumed(itemHash)
        ) {
            revert MasterNotApproved(workId);
        }

        EditionTerms memory terms = item.edition;
        _checkTerms(workId, terms);
        WorkTerms memory w = economics.newWorkTerms(PRODUCT_EDITIONS, item.payees);

        Edition storage e = r.edition;
        e.contentId = item.contentId;
        e.terms = terms;
        e.seller = w.seller;
        e.feeRecipient = w.feeRecipient;
        e.feeShare = w.feeShare;
        e.royaltyReceiver = w.royaltyReceiver;
        e.royaltyRate = w.royaltyRate;
        r.artistId = master.artistId;
        emit EditionCreated(workId, item.contentId, terms);
        emit MetadataUpdate(workId);

        // Protocol calls, after every effect above: a reentrant `createEdition` hits EditionExists.
        _contentHashes[workId] = packageRegistry.claimContent(PRODUCT_EDITIONS, item.contentId);
        IStream(stream).linkEdition(workId, workId);
        (address linked, uint256 linkedId) = IStream(stream).editionOf(workId);
        if (linked != address(this) || linkedId != workId) revert LinkFailed(workId);
        return workId;
    }

    /// @notice Binds the work-records satellite, once and permanently (PR #10 review decision
    ///         D6). Governed: genesis wiring. Checks code, EIP-7702 delegation and the reviewed
    ///         code hash.
    /// @param workRecords_ The work-records satellite of `stream`.
    /// @param codeHash The reviewed code hash of `workRecords_`.
    function bindWorkRecords(address workRecords_, bytes32 codeHash) external restricted {
        if (workRecords != address(0)) revert AlreadyBound();
        _checkInstall(workRecords_, codeHash, 0);
        workRecords = workRecords_;
        emit WorkRecordsBound(workRecords_, codeHash);
    }

    /// @notice Reports that master `workId`'s record, license or renderer changed. Only the bound
    ///         work-records satellite may call; emits ERC-4906 `MetadataUpdate` when the master
    ///         has an edition and does nothing otherwise, so a master without an edition never
    ///         blocks its own update.
    /// @param workId The master's Stream token ID, which is also its edition ID.
    function notifyMasterUpdated(uint256 workId) external {
        if (msg.sender != workRecords) revert NotWorkRecords(msg.sender);
        if (exists(workId)) emit MetadataUpdate(workId);
    }

    /// @notice Reports that Stream's default renderer changed, which can change every edition
    ///         whose master is not finalized. Only Stream may call; emits one ERC-4906
    ///         `BatchMetadataUpdate(0, type(uint256).max)` and changes no state.
    function notifyAllUpdated() external {
        if (msg.sender != stream) revert NotStream(msg.sender);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @inheritdoc IEditions
    function edition(uint256 editionId) external view returns (Edition memory) {
        return _edition(editionId);
    }

    /// @inheritdoc IEditions
    function masterOf(uint256 editionId)
        external
        view
        returns (address streamContract, uint256 workId, bytes32 contentId)
    {
        return (stream, editionId, _edition(editionId).contentId);
    }

    /// @notice The content hash (decoded SHA-256) the edition claimed: its master's. Reverts with
    ///         `UnknownEdition`.
    function contentHashOf(uint256 editionId) external view returns (bytes32) {
        _edition(editionId);
        return _contentHashes[editionId];
    }

    /// @inheritdoc IEditions
    function exists(uint256 editionId) public view returns (bool) {
        return _records[editionId].edition.contentId != 0;
    }

    // ----------------------------------------------------------------------- minting

    /// @inheritdoc IMintTarget
    /// @dev MINTER role. `data` must be empty. Effects precede the ERC-1155 acceptance call, so a
    ///      reentering receiver sees the updated supply.
    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        restricted
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        if (amount == 0 || data.length != 0) revert InvalidMintRequest();
        Edition storage e = _edition(id);
        bytes32 kind = ISaleAdapter(msg.sender).saleKind();
        if (kind != e.terms.saleKind) revert SaleKindMismatch(e.terms.saleKind, kind);
        uint256 cap = e.terms.size == 0 ? type(uint64).max : e.terms.size;
        if (amount > cap - e.minted) revert EditionUnavailable(id);
        if (e.terms.format == EditionFormat.OPEN) {
            uint64 start = e.windowStart;
            if (start == 0) {
                start = uint64(block.timestamp);
                e.windowStart = start;
                emit EditionWindowOpened(id, start, uint256(start) + e.terms.window);
            }
            // The window is a wall-clock bound by design; validator drift is immaterial.
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp >= uint256(start) + e.terms.window) revert EditionUnavailable(id);
        }
        // casting to 'uint64' is safe because amount <= cap - minted <= type(uint64).max - minted
        // forge-lint: disable-next-line(unsafe-typecast)
        e.minted += uint64(amount);
        terms = _primaryTerms(id, e);
        _mint(to, id, amount, "");
        return (id, terms);
    }

    /// @inheritdoc IMintTarget
    function primaryTerms(uint256 id, bytes calldata data)
        external
        view
        returns (PrimaryTerms memory)
    {
        if (data.length != 0) revert InvalidMintRequest();
        return _primaryTerms(id, _edition(id));
    }

    /// @inheritdoc IMintTarget
    /// @dev MINTER role. Burned copies still count toward the edition size.
    function burn(uint256 id, uint256 amount) external restricted {
        if (amount == 0) revert InvalidMintRequest();
        _edition(id);
        _burn(msg.sender, id, amount);
    }

    // ----------------------------------------------------------------- royalties, rendering

    /// @inheritdoc IERC2981
    /// @dev The terms locked at creation, out of 100,000. Reverts with `UnknownEdition`.
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        Edition storage e = _edition(tokenId);
        return (e.royaltyReceiver, Math.mulDiv(salePrice, e.royaltyRate, SHARE_DENOMINATOR));
    }

    /// @notice The edition's license: always its master's current license (ADR 0001 section 8).
    ///         Reverts with `UnknownEdition`.
    function licenseOf(uint256 editionId) external view returns (License memory) {
        _edition(editionId);
        return IStream(stream).licenseOf(editionId);
    }

    /// @notice The edition's metadata, built by its master's renderer from the master's record
    ///         and content-store bytes. Reverts with `UnknownEdition`.
    function uri(uint256 id) public view override returns (string memory) {
        _edition(id);
        return IRenderer(IStream(stream).rendererOf(id)).tokenURI(address(this), id);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, IERC165)
        returns (bool)
    {
        return interfaceId == type(IERC2981).interfaceId
            || interfaceId == type(IMintTarget).interfaceId
            || interfaceId == type(IEditions).interfaceId || super.supportsInterface(interfaceId);
    }

    // ----------------------------------------------------------------- marketplace metadata

    /// @inheritdoc IEditions
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @inheritdoc IEditions
    function setContractURI(string calldata uri_) external restricted {
        string memory previous = _contractURI;
        _contractURI = uri_;
        emit ContractURISet(previous, uri_);
        emit ContractURIUpdated();
    }

    /// @inheritdoc IEditions
    function owner() external view returns (address) {
        return _owner;
    }

    /// @inheritdoc IEditions
    function setOwner(address expected, address next) external restricted {
        address previous = _owner;
        if (previous != expected) revert ExpectedValueMismatch();
        _owner = next;
        emit OwnershipTransferred(previous, next);
    }

    // ----------------------------------------------------------------------- internals

    /// @dev ADR 0001 section 13.6 install checks. `interfaceId` zero skips the ERC-165 check.
    function _checkInstall(address target, bytes32 codeHash, bytes4 interfaceId) private view {
        if (
            target.code.length == 0 || DelegatedEOA.isDelegated(target)
                || (interfaceId != 0 && !ERC165Checker.supportsInterface(target, interfaceId))
        ) revert InvalidDependency(target);
        if (target.codehash != codeHash) revert CodeHashMismatch(codeHash, target.codehash);
    }

    function _edition(uint256 editionId) private view returns (Edition storage e) {
        e = _records[editionId].edition;
        if (e.contentId == 0) revert UnknownEdition(editionId);
    }

    /// @dev FIXED: a nonzero size and no window. OPEN: a nonzero window, size optional. Fixed
    ///      price carries no params; Dutch carries `DutchParams` resting at or below the price.
    function _checkTerms(uint256 workId, EditionTerms memory t) private pure {
        bool shape = t.format == EditionFormat.FIXED ? t.size != 0 && t.window == 0 : t.window != 0;
        if (t.saleKind == SaleKind.FIXED_PRICE) {
            shape = shape && t.params.length == 0;
        } else if (t.saleKind == SaleKind.DUTCH && t.params.length == DUTCH_PARAMS_LENGTH) {
            shape = shape && abi.decode(t.params, (DutchParams)).restingPrice <= t.price;
        } else {
            shape = false;
        }
        if (!shape) revert InvalidEditionTerms(workId);
    }

    function _primaryTerms(uint256 id, Edition storage e)
        private
        view
        returns (PrimaryTerms memory)
    {
        return PrimaryTerms({
            saleKind: e.terms.saleKind,
            currency: e.terms.currency,
            price: e.terms.price,
            params: e.terms.params,
            seller: e.seller,
            feeRecipient: e.feeRecipient,
            feeShare: e.feeShare,
            creator: artistRegistry.authorityOf(_records[id].artistId),
            revealPending: false
        });
    }
}
