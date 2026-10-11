// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
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

/// @title Editions
/// @notice 6529 Editions: the one shared ERC-1155 of editions, each anchored by a 6529 Stream
///         work of kind EDITION_MASTER (ADR 0001 section 6).
/// @dev The edition ID equals the master's Stream token ID. `createEdition` is permissionless:
///      it accepts only the exact package item the master was minted from (its item hash is the
///      one Stream recorded), only while the package is approved and the item consumed, and only
///      once the master's seed is known. It locks the edition's economics and currency, claims
///      the master's content hash under `PRODUCT_EDITIONS` (so editions never share media, while
///      an edition reuses its own master's hash, which Stream claimed under `PRODUCT_STREAM`),
///      and writes both directions of the link in one transaction, verifying Stream's side
///      afterwards. Nothing ever changes or removes a link.
///
///      Copies are minted only by MINTER adapters whose sale kind matches the package's, at
///      most `size` copies ever (burns do not free supply), and for OPEN editions only during
///      `window` seconds from the first mint. Minting stops if the master is burned. Royalties
///      are the terms locked at creation, read from this contract's storage with no external
///      call. The license and `uri` come from the master: `uri` is served by the master's
///      renderer, which reads the master's content-store bytes.
///
///      Wiring is immutable and taken from Stream at deployment, so Editions always talks to the
///      same package registry, economics resolver and artist registry as its masters. Editions
///      needs the SYSTEM role on the package registry (`claimContent`) and must be Stream's
///      `editions()` (`linkEdition`).
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

    /// @notice An OPEN edition's window started with its first mint; minting ends at `end`.
    event EditionWindowOpened(uint256 indexed editionId, uint64 start, uint256 end);

    /// @notice A required address is zero.
    error ZeroAddress();
    /// @notice The master's package is revoked or its item is not consumed.
    error MasterNotApproved(uint256 workId);
    /// @notice The master's VRF seed is not delivered yet.
    error MasterSeedPending(uint256 workId);
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
    /// @param owner_ The initial marketplace owner.
    constructor(address authority_, address stream_, address owner_)
        ERC1155("")
        AccessManaged(authority_)
    {
        if (stream_ == address(0)) revert ZeroAddress();
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
        (,, bool seedAvailable) = IStream(stream).seedOf(workId);
        if (!seedAvailable) revert MasterSeedPending(workId);

        EditionTerms memory terms = item.edition;
        _checkTerms(workId, terms);
        terms.currency = economics.resolveCurrency(PRODUCT_EDITIONS, terms.currency);
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

        // Protocol calls, after every effect above: a reentrant `createEdition` hits EditionExists.
        _contentHashes[workId] = packageRegistry.claimContent(PRODUCT_EDITIONS, item.contentId);
        IStream(stream).linkEdition(workId, workId);
        (address linked, uint256 linkedId) = IStream(stream).editionOf(workId);
        if (linked != address(this) || linkedId != workId) revert LinkFailed(workId);
        return workId;
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
        if (amount > cap - e.minted || !_masterLive(id)) revert EditionUnavailable(id);
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
        _contractURI = uri_;
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

    /// @dev Whether the master still exists on Stream; any failure to read it counts as burned.
    function _masterLive(uint256 id) private view returns (bool) {
        try IERC721(stream).ownerOf(id) returns (address holder) {
            return holder != address(0);
        } catch {
            return false;
        }
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
