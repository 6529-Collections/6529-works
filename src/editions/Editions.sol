// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IStream } from "../interfaces/IStream.sol";
import { IWorkRecords } from "../interfaces/IWorkRecords.sol";
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

/// @title Editions
/// @notice 6529 Editions: the one shared ERC-1155 of editions, each anchored by a 6529 Stream
///         work of kind EDITION_MASTER (ADR 0001 section 6).
/// @dev The edition ID equals the master's Stream token ID. `createEdition` is permissionless:
///      it accepts only the exact package item the master was minted from (its item hash is the
///      one Stream stored), proven by a Merkle proof to be an item of a package root the registry
///      still reports approved, so a guardian revocation blocks the edition at no cost to the
///      auction start (an item listed in two packages passes through whichever is still
///      approved: an accepted edge case), and only after the master's sale has settled
///      (`IStream.primarySaleSettled`, which the minting adapter marks at settle), so a disputed
///      or burned master never gets an edition. It
///      locks the edition's economics (seller, network fee, royalty), claims the master's
///      content hash in the package registry (which accepts only the item Stream consumed for
///      that hash, and only once), and writes both directions of the link in one transaction,
///      verifying Stream's side afterwards. Nothing ever changes or removes a link.
///
///      Copies are minted only by admitted adapters (`isAdmittedMinter`, written by a governed
///      setter in the 30-day class, decision E4) whose sale kind matches the package's, at most `size` copies ever (burns do not free supply), for OPEN editions only
///      during `window` seconds from the first mint, and never once the master is burned. The
///      currency has one owner, the sale adapter: `primaryTerms` and `mint` return the package's
///      stored currency, possibly `CURRENCY_DEFAULT`; the adapter resolves and locks it when it
///      opens a sale (ADR 0001 section 5). Royalties are read from this contract's storage with
///      no external call; payees never change, and only the bound work-records satellite may
///      change the rate: when a master's rate changes there (every party's consent and a governed
///      action, decision D19), it re-rates the linked edition through `setRoyaltyRate`. The
///      license and `uri` come from the master. ERC-4906 events follow the master: one per
///      edition from the work-records satellite, and a batch over every ID when Stream's default
///      renderer or a global or collection preferred location changes (decision E11).
///
///      Wiring is immutable. Stream is checked at deployment (code, no EIP-7702 delegation,
///      ERC-165 for ERC-721, pinned code hash), and the package registry, economics resolver and
///      artist registry are taken from it. The package registry and Stream must bind Editions as
///      their Editions caller, and genesis binds the work-records satellite here once, with
///      ERC-165 and EIP-7702 checks (decision E7).
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
    /// @notice The package registry that claims edition content.
    IPackageRegistry public immutable packageRegistry;
    /// @notice The economics resolver whose `PRODUCT_EDITIONS` terms editions lock.
    IEconomicsResolver public immutable economics;
    /// @notice The artist registry that resolves each edition's creator.
    IArtistRegistry public immutable artistRegistry;

    /// @inheritdoc IEditions
    address public workRecords;
    /// @notice Whether a sale adapter may mint and burn (decision E4).
    mapping(address adapter => bool) public isAdmittedMinter;
    string private _contractURI;
    address private _owner;
    mapping(uint256 editionId => Record) private _records;

    /// @notice The contract URI changed from `previous` to `next` (beside ERC-7572's
    ///         `ContractURIUpdated`, which carries no values).
    event ContractURISet(string previous, string next);
    /// @notice An edition's royalty rate changed, by every party's agreement plus a governed
    ///         action, relayed by the work-records satellite.
    event RoyaltyRateChanged(uint256 indexed editionId, uint32 previous, uint32 next);
    /// @notice A sale adapter was admitted to, or removed from, minting and burning.
    event MinterAdmissionSet(address indexed adapter, bool admitted);

    /// @notice A required address is zero.
    error ZeroAddress();
    /// @notice A dependency has no code, is an EIP-7702 delegated account, lacks the expected
    ///         ERC-165 interface, or is not the satellite Stream bound.
    error InvalidDependency(address dependency);
    /// @notice A dependency's code hash is not the reviewed one.
    error CodeHashMismatch(bytes32 expected, bytes32 actual);
    /// @notice The item's edition terms are malformed (format, size, window, sale kind, params).
    error InvalidEditionTerms(uint256 workId);
    /// @notice Stream did not record the link back to this edition.
    error LinkFailed(uint256 workId);
    /// @notice A mint carried data, or a mint or burn a zero amount.
    error InvalidMintRequest();
    /// @notice The caller is neither Stream nor the bound work-records satellite.
    error NotNotifier(address caller);
    /// @notice The caller is not an admitted sale adapter.
    error NotAdmittedMinter(address caller);
    /// @notice A royalty rate above 100,000.
    error InvalidRoyaltyRate(uint32 rate);
    /// @notice Creating an edition needs the package root and proof (the four-argument form).
    error PackageProofRequired(uint256 workId);

    /// @param authority_ The AccessManager that governs this contract.
    /// @param stream_ The 6529 Stream contract; the other wiring is read from it.
    /// @param streamCodeHash The reviewed code hash of `stream_`.
    /// @param owner_ The initial marketplace owner.
    constructor(address authority_, address stream_, bytes32 streamCodeHash, address owner_)
        ERC1155("")
        AccessManaged(authority_)
    {
        if (!_installable(stream_, type(IERC721).interfaceId)) revert InvalidDependency(stream_);
        if (stream_.codehash != streamCodeHash) {
            revert CodeHashMismatch(streamCodeHash, stream_.codehash);
        }
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
    /// @dev TODO(#10 follow-up): superseded by the four-argument form, which carries the package
    ///      root and proof (integrator decision); removed when `IEditions` adopts it.
    function createEdition(uint256 workId, PackageItem calldata) external pure returns (uint256) {
        revert PackageProofRequired(workId);
    }

    /// @notice Creates the edition of master `workId` from its approved package item once the
    ///         master's sale has settled. Permissionless. The item must hash to the master's
    ///         stored item hash, `proof` must place it in `packageRoot`, and the registry must
    ///         still report `packageRoot` approved, so a revoked package blocks the edition. Records
    ///         `(stream, workId, contentHash)`, claims the content hash for the Editions product,
    ///         locks `PRODUCT_EDITIONS` economics and calls `IStream.linkEdition`.
    /// @param workId The master's Stream token ID, which becomes the edition ID.
    /// @param item The master's package item.
    /// @param packageRoot A package root containing the item, still approved.
    /// @param proof The item's Merkle proof under `packageRoot` (`WorksHashing.leaf` convention).
    /// @return editionId The new edition ID (equal to `workId`).
    function createEdition(
        uint256 workId,
        PackageItem calldata item,
        bytes32 packageRoot,
        bytes32[] calldata proof
    ) external returns (uint256 editionId) {
        (bytes32 itemHash, uint256 artistId) = _admit(workId, item, packageRoot, proof);
        EditionTerms memory terms = item.edition;
        _checkTerms(workId, terms);
        WorkTerms memory w = economics.newWorkTerms(PRODUCT_EDITIONS, item.payees);

        Record storage r = _records[workId];
        Edition storage e = r.edition;
        e.contentHash = item.contentHash;
        e.terms = terms;
        e.seller = w.seller;
        e.feeRecipient = w.feeRecipient;
        e.feeShare = w.feeShare;
        e.royaltyReceiver = w.royaltyReceiver;
        e.royaltyRate = w.royaltyRate;
        r.artistId = artistId;
        emit EditionCreated(workId, item.contentHash, terms);
        emit MetadataUpdate(workId);

        // Protocol calls, after every effect above: a reentrant `createEdition` hits EditionExists.
        // The registry accepts only the item Stream consumed for this content hash, once.
        packageRegistry.claimContent(item.contentHash, itemHash);
        IStream(stream).linkEdition(workId, workId);
        (address linked, uint256 linkedId) = IStream(stream).editionOf(workId);
        if (linked != address(this) || linkedId != workId) revert LinkFailed(workId);
        return workId;
    }

    /// @inheritdoc IEditions
    /// @dev Requires the satellite Stream bound, supporting `IWorkRecords` by ERC-165 and not an
    ///      EIP-7702 delegated account (decision E7).
    function bindWorkRecords(address workRecords_) external restricted {
        if (workRecords != address(0)) revert AlreadyBound();
        if (
            workRecords_ != IStream(stream).workRecords()
                || !_installable(workRecords_, type(IWorkRecords).interfaceId)
        ) revert InvalidDependency(workRecords_);
        workRecords = workRecords_;
        emit WorkRecordsBound(workRecords_);
    }

    /// @notice Admits or removes a sale adapter for minting and burning (decision E4).
    ///         Governed, in the 30-day class. An admitted adapter must support `ISaleAdapter` by
    ///         ERC-165 and not be an EIP-7702 delegated account; removal is unchecked.
    /// @param adapter The sale adapter.
    /// @param admitted Whether it may mint and burn.
    function setAdmittedMinter(address adapter, bool admitted) external restricted {
        if (admitted && !_installable(adapter, type(ISaleAdapter).interfaceId)) {
            revert InvalidDependency(adapter);
        }
        isAdmittedMinter[adapter] = admitted;
        emit MinterAdmissionSet(adapter, admitted);
    }

    /// @inheritdoc IEditions
    function notifyMasterUpdated(uint256 workId) external {
        if (msg.sender != workRecords) revert NotWorkRecords(msg.sender);
        if (exists(workId)) emit MetadataUpdate(workId);
    }

    /// @notice Reports a change that can alter every edition's metadata: Stream's default renderer,
    ///         or a global or collection preferred location in the work-records satellite
    ///         (decision E11). Only Stream or the bound work-records satellite may call; emits one
    ///         ERC-4906 `BatchMetadataUpdate(0, type(uint256).max)` and changes no state.
    function notifyAllUpdated() external {
        if (msg.sender != stream && msg.sender != workRecords) revert NotNotifier(msg.sender);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Sets an edition's royalty rate; the receiver (payees) never changes. Only the
    ///         bound work-records satellite may call: it re-rates a master's linked edition
    ///         together with the master, after every party's consent and the governed action
    ///         (decision D19). A master without an edition is a no-op.
    /// @param editionId The edition, which is also its master's token ID.
    /// @param rate The new rate, out of 100,000.
    function setRoyaltyRate(uint256 editionId, uint32 rate) external {
        if (msg.sender != workRecords) revert NotWorkRecords(msg.sender);
        if (rate > SHARE_DENOMINATOR) revert InvalidRoyaltyRate(rate);
        if (!exists(editionId)) return;
        Edition storage e = _records[editionId].edition;
        emit RoyaltyRateChanged(editionId, e.royaltyRate, rate);
        emit MetadataUpdate(editionId);
        e.royaltyRate = rate;
    }

    /// @inheritdoc IEditions
    function edition(uint256 editionId) external view returns (Edition memory) {
        return _edition(editionId);
    }

    /// @inheritdoc IEditions
    function masterOf(uint256 editionId)
        external
        view
        returns (address streamContract, uint256 workId, bytes32 contentHash)
    {
        return (stream, editionId, _edition(editionId).contentHash);
    }

    /// @inheritdoc IEditions
    function contentHashOf(uint256 editionId) external view returns (bytes32) {
        return _edition(editionId).contentHash;
    }

    /// @inheritdoc IEditions
    function exists(uint256 editionId) public view returns (bool) {
        return _records[editionId].edition.contentHash != 0;
    }

    // ----------------------------------------------------------------------- minting

    /// @inheritdoc IMintTarget
    /// @dev Admitted adapters only. `data` must be empty. Effects precede the ERC-1155 acceptance
    ///      call, so a reentering receiver sees the updated supply.
    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        if (!isAdmittedMinter[msg.sender]) revert NotAdmittedMinter(msg.sender);
        if (amount == 0 || data.length != 0) revert InvalidMintRequest();
        Edition storage e = _edition(id);
        bytes32 kind = ISaleAdapter(msg.sender).saleKind();
        if (kind != e.terms.saleKind) revert SaleKindMismatch(e.terms.saleKind, kind);
        uint256 cap = e.terms.size == 0 ? type(uint64).max : e.terms.size;
        // `primarySaleSettled` is false for a burned master.
        if (amount > cap - e.minted || !IStream(stream).primarySaleSettled(id)) {
            revert EditionUnavailable(id);
        }
        if (e.terms.format == EditionFormat.OPEN) {
            uint64 start = e.windowStart;
            if (start == 0) {
                start = uint64(block.timestamp);
                e.windowStart = start;
                uint256 closesAt = Math.min(uint256(start) + e.terms.window, type(uint64).max);
                // casting to 'uint64' is safe because closesAt is capped at type(uint64).max
                // forge-lint: disable-next-line(unsafe-typecast)
                emit EditionWindowOpened(id, uint64(closesAt));
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
    /// @dev `data` is ignored. The currency is the package's, unresolved.
    function primaryTerms(uint256 id, bytes calldata) external view returns (PrimaryTerms memory) {
        return _primaryTerms(id, _edition(id));
    }

    /// @inheritdoc IMintTarget
    /// @dev Admitted adapters only. Burned copies still count toward the edition size.
    function burn(uint256 id, uint256 amount) external {
        if (!isAdmittedMinter[msg.sender]) revert NotAdmittedMinter(msg.sender);
        if (amount == 0) revert InvalidMintRequest();
        _edition(id);
        _burn(msg.sender, id, amount);
    }

    // ----------------------------------------------------------------- royalties, rendering

    /// @inheritdoc IERC2981
    /// @dev The receiver locked at creation and the current rate, out of 100,000. Reverts with
    ///      `UnknownEdition`.
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        Edition storage e = _edition(tokenId);
        return (e.royaltyReceiver, Math.mulDiv(salePrice, e.royaltyRate, SHARE_DENOMINATOR));
    }

    /// @inheritdoc IEditions
    /// @dev Reverts with the satellite's `RecordNotOpen` until the master's record is opened
    ///      (decision E9).
    function licenseOf(uint256 editionId) external view returns (License memory) {
        _edition(editionId);
        return IWorkRecords(workRecords).licenseOf(editionId);
    }

    /// @notice The edition's metadata, built by its master's renderer from the master's record
    ///         and content-store bytes. Reverts with `UnknownEdition`.
    function uri(uint256 id) public view override returns (string memory) {
        _edition(id);
        return IRenderer(IStream(stream).rendererOf(id)).tokenURI(address(this), id);
    }

    /// @inheritdoc IERC165
    /// @dev Also reports ERC-4906 (`0x49064906`), whose events this contract emits.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, IERC165)
        returns (bool)
    {
        return interfaceId == type(IERC2981).interfaceId
            || interfaceId == type(IMintTarget).interfaceId
            || interfaceId == type(IEditions).interfaceId || interfaceId == bytes4(0x49064906)
            || super.supportsInterface(interfaceId);
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

    /// @dev The checks of `createEdition`: no edition yet, the master settled and of kind
    ///      EDITION_MASTER, the item its stored one, and the item in a still-approved package.
    function _admit(
        uint256 workId,
        PackageItem calldata item,
        bytes32 packageRoot,
        bytes32[] calldata proof
    ) private view returns (bytes32 itemHash, uint256 artistId) {
        if (exists(workId)) revert EditionExists(workId);
        IStream.WorkCore memory master = IStream(stream).work(workId);
        itemHash = WorksHashing.itemHashCalldata(item);
        if (
            !IStream(stream).primarySaleSettled(workId) || item.kind != ItemKind.EDITION_MASTER
                || master.kind != ItemKind.EDITION_MASTER || itemHash != master.itemHash
                || item.contentHash == 0
        ) revert NotEditionMaster(workId);
        if (!MerkleProof.verifyCalldata(proof, packageRoot, WorksHashing.leaf(itemHash))) {
            revert IPackageRegistry.ItemNotInPackage(packageRoot, itemHash);
        }
        (IPackageRegistry.PackageStatus status,,) = packageRegistry.packageOf(packageRoot);
        if (status != IPackageRegistry.PackageStatus.APPROVED) {
            revert IPackageRegistry.PackageNotApproved(packageRoot);
        }
        return (itemHash, master.artistId);
    }

    /// @dev ADR 0001 section 13.6: code, no EIP-7702 delegation, and ERC-165 support.
    function _installable(address target, bytes4 interfaceId) private view returns (bool) {
        return target.code.length != 0 && !DelegatedEOA.isDelegated(target)
            && ERC165Checker.supportsInterface(target, interfaceId);
    }

    function _edition(uint256 editionId) private view returns (Edition storage e) {
        e = _records[editionId].edition;
        if (e.contentHash == 0) revert UnknownEdition(editionId);
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
            creator: artistRegistry.authorityOf(_records[id].artistId)
        });
    }
}
