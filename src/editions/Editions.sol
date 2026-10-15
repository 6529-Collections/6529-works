// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Splits } from "../economics/Splits.sol";
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
    CURRENCY_DEFAULT,
    PRODUCT_EDITIONS,
    WorkTerms
} from "../interfaces/types/EconomicsTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import {
    EditionFormat,
    EditionTerms,
    ItemKind,
    License,
    PackageItem
} from "../interfaces/types/PackageTypes.sol";
import { PrimaryTerms } from "../interfaces/types/SaleTypes.sol";
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { EditionRules } from "./EditionRules.sol";

/// @title Editions
/// @notice 6529 Editions: the one shared ERC-1155 of editions, each anchored by a 6529 Stream
///         work of kind EDITION_MASTER (ADR 0001 section 6).
/// @dev The edition ID equals the master's Stream token ID. `createEdition` is permissionless:
///      it accepts only the exact package item the master was minted from (its item hash is the
///      one Stream stored), proven by a Merkle proof to be an item of a package root the
///      registry registered. The root may have been revoked since: a revocation stops a
///      package's unconsumed items, and Stream already consumed exactly this item, so revoking a
///      root over another of its items never strands the edition of a master already sold
///      from it. The master's sale must also have settled
///      (`IStream.primarySaleSettled`, marked by the minting adapter at settle), so a disputed or
///      burned master never gets an edition. Creation locks the edition's economics (seller,
///      network fee, royalty), claims the master's content hash in the package registry (which
///      accepts only the item Stream consumed for that hash, and only once), and writes both
///      directions of the link in one transaction, verifying Stream's side afterwards. Nothing
///      ever changes or removes a link.
///
///      Copies are minted only by admitted adapters (`isAdmittedMinter`, written by a governed
///      setter in the 30-day class) whose sale kind matches the package's: at most `size` copies
///      ever (burns do not free supply), and for OPEN editions only during `window` seconds from
///      the first mint. A master with an edition is never burned (Stream refuses to burn a
///      settled token), so minting reads nothing from Stream. The sale adapter owns the currency:
///      `primaryTerms` and `mint` return the package's stored currency, possibly
///      `CURRENCY_DEFAULT` (allowed only with a zero price), and the adapter resolves and locks
///      it when it opens a sale (ADR 0001 section 5). Royalties are read from this contract's
///      storage with no external call. The receiver is the edition's split (from
///      `PRODUCT_EDITIONS` economics) and never changes; the rate starts at the master's current
///      rate, so a consented re-rate of the master before the edition exists carries over, and
///      the bound work-records satellite re-rates the edition with its master afterwards (every
///      party's consent plus a governed action). The license and `uri` come from the master.
///      ERC-4906 events follow the master: one per edition from the work-records satellite, and a
///      batch over every ID when Stream's default renderer or a global or collection preferred
///      location changes.
///
///      Wiring is immutable. Stream is checked at deployment (code, no EIP-7702 delegation,
///      ERC-165 for `IStream`, pinned code hash), and the package registry, economics resolver and
///      artist registry are taken from it. Stream and the package registry bind Editions, and
///      genesis binds Stream's work-records satellite here once, before any edition can be
///      created (an edition's license and record updates go through it).
contract Editions is IEditions, ERC1155, AccessManaged {
    /// @dev The binding name of the work-records satellite, as 6529 Stream names it.
    bytes32 private constant WORK_RECORDS = "WORK_RECORDS";
    /// @dev Minter status: never admitted, admitted, or admitted once and since removed.
    uint8 private constant MINTER_NONE = 0;
    uint8 private constant MINTER_ADMITTED = 1;
    uint8 private constant MINTER_REMOVED = 2;

    /// @dev What `createEdition` reads of its master from `IStream.coreOf`.
    struct Master {
        bytes32 itemHash;
        uint256 artistId;
        uint32 royaltyRate;
    }

    /// @dev An edition plus what it keeps beside the interface's `Edition` view.
    struct Record {
        Edition edition;
        uint256 artistId;
    }

    /// @inheritdoc IEditions
    address public immutable stream;
    /// @notice The package registry that approved the packages and claims edition content.
    IPackageRegistry public immutable packageRegistry;
    /// @notice The economics resolver whose `PRODUCT_EDITIONS` terms editions lock.
    IEconomicsResolver public immutable economics;
    /// @notice The artist registry that resolves each edition's creator.
    IArtistRegistry public immutable artistRegistry;

    /// @inheritdoc IEditions
    address public workRecords;
    string private _contractURI;
    address private _owner;
    mapping(address adapter => uint8) private _minterStatus;
    mapping(uint256 editionId => Record) private _records;

    /// @notice The contract URI changed from `previous` to `next` (beside ERC-7572's
    ///         `ContractURIUpdated`, which carries no values).
    event ContractURISet(string previous, string next);
    /// @notice An edition's royalty rate changed with its master's, by every party's agreement
    ///         plus a governed action, relayed by the work-records satellite.
    event RoyaltyRateChanged(uint256 indexed editionId, uint32 previous, uint32 next);

    /// @notice A required address is zero.
    error ZeroAddress();
    /// @notice Stream's code hash is not the reviewed one.
    error CodeHashMismatch(bytes32 expected, bytes32 actual);
    /// @notice The item's edition terms are malformed (format, size, window, sale kind, params).
    error InvalidEditionTerms(uint256 workId);
    /// @notice The edition terms price copies in `CURRENCY_DEFAULT`: a price is meaningless
    ///         without its currency, since a governed change of the default would reprice the
    ///         edition. `CURRENCY_DEFAULT` is allowed only with a zero price.
    error PricedDefaultCurrency(uint256 workId);
    /// @notice Stream did not record the link back to this edition.
    error LinkFailed(uint256 workId);
    /// @notice A mint carried data, or a mint or burn a zero amount.
    error InvalidMintRequest();
    /// @notice A royalty rate above 100,000.
    error InvalidRoyaltyRate(uint32 rate);
    /// @notice The work-records satellite is not bound yet, so no edition can be created.
    error WorkRecordsUnbound();

    /// @param authority_ The AccessManager that governs this contract.
    /// @param stream_ The 6529 Stream contract; the other wiring is read from it.
    /// @param streamCodeHash The reviewed code hash of `stream_`.
    /// @param owner_ The initial marketplace owner.
    constructor(address authority_, address stream_, bytes32 streamCodeHash, address owner_)
        ERC1155("")
        AccessManaged(authority_)
    {
        if (!_installable(stream_, type(IStream).interfaceId)) revert InvalidBinding(stream_);
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
    function createEdition(
        uint256 workId,
        PackageItem calldata item,
        bytes32 packageRoot,
        bytes32[] calldata proof
    ) external returns (uint256 editionId) {
        (bytes32 itemHash, Master memory master) = _admit(workId, item, packageRoot, proof);
        _checkTerms(workId, item.edition);
        EditionTerms memory terms = item.edition;
        WorkTerms memory w = economics.newWorkTerms(PRODUCT_EDITIONS, item.payees);

        Record storage r = _records[workId];
        Edition storage e = r.edition;
        e.contentHash = item.contentHash;
        e.terms = terms;
        e.seller = w.seller;
        e.feeRecipient = w.feeRecipient;
        e.feeShare = w.feeShare;
        e.royaltyReceiver = w.royaltyReceiver;
        // The master's current rate, not the product default: a consented re-rate of the master
        // before the edition exists carries over; later ones arrive through `setRoyaltyRate`.
        e.royaltyRate = master.royaltyRate;
        r.artistId = master.artistId;
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
    /// @dev The target must also be the satellite Stream bound.
    function bindWorkRecords(address target) external restricted {
        if (workRecords != address(0)) revert AlreadyBound(WORK_RECORDS);
        if (
            target != IStream(stream).workRecords()
                || !_installable(target, type(IWorkRecords).interfaceId)
        ) revert InvalidBinding(target);
        workRecords = target;
        emit Bound(WORK_RECORDS, target);
    }

    /// @inheritdoc IMintTarget
    /// @dev Emits only on a change: admitting an admitted adapter, or removing one that is not
    ///      admitted (never admitted, or already removed), is a silent no-op. Removal is unchecked;
    ///      an adapter once admitted can still burn its own copies.
    function setAdmittedMinter(address adapter, bool admitted) external restricted {
        uint8 status = _minterStatus[adapter];
        if (admitted == (status == MINTER_ADMITTED)) return;
        if (admitted && !_installable(adapter, type(ISaleAdapter).interfaceId)) {
            revert InvalidBinding(adapter);
        }
        _minterStatus[adapter] = admitted ? MINTER_ADMITTED : MINTER_REMOVED;
        emit AdmittedMinterSet(adapter, admitted);
    }

    /// @inheritdoc IMintTarget
    function isAdmittedMinter(address adapter) external view returns (bool) {
        return _minterStatus[adapter] == MINTER_ADMITTED;
    }

    /// @inheritdoc IEditions
    function notifyMasterUpdated(uint256 workId) external {
        if (msg.sender != workRecords) revert UnboundCaller(msg.sender);
        if (exists(workId)) emit MetadataUpdate(workId);
    }

    /// @inheritdoc IEditions
    /// @dev Emits `BatchMetadataUpdate(0, type(uint256).max)` and changes no state.
    function notifyAllUpdated() external {
        if (msg.sender != stream && msg.sender != workRecords) revert UnboundCaller(msg.sender);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @inheritdoc IEditions
    /// @dev The receiver never changes. A master without an edition, or an unchanged rate, is a
    ///      no-op without events, so the satellite can call this for every re-rated master.
    function setRoyaltyRate(uint256 editionId, uint32 rate) external {
        if (msg.sender != workRecords) revert UnboundCaller(msg.sender);
        if (rate > Splits.DENOMINATOR) revert InvalidRoyaltyRate(rate);
        if (!exists(editionId)) return;
        Edition storage e = _records[editionId].edition;
        if (e.royaltyRate == rate) return;
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
    function formatOf(uint256 editionId) external view returns (EditionFormat) {
        return _edition(editionId).terms.format;
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
    /// @dev `data` must be empty. Effects precede the ERC-1155 acceptance call, so a reentering
    ///      receiver sees the updated supply.
    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        if (_minterStatus[msg.sender] != MINTER_ADMITTED) {
            revert NotAdmittedMinter(msg.sender);
        }
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
    /// @dev The full edition terms; `data` is ignored and the currency is the package's,
    ///      unresolved.
    function primaryTerms(uint256 id, bytes calldata) external view returns (PrimaryTerms memory) {
        return _primaryTerms(id, _edition(id));
    }

    /// @inheritdoc IMintTarget
    /// @dev Any adapter ever admitted, including one since removed: copies can come from several
    ///      adapters, and a burn only takes from the caller's own balance. Burned copies still
    ///      count toward the edition size.
    function burn(uint256 id, uint256 amount) external {
        if (_minterStatus[msg.sender] == MINTER_NONE) revert NotAdmittedMinter(msg.sender);
        if (amount == 0) revert InvalidMintRequest();
        _edition(id);
        _burn(msg.sender, id, amount);
    }

    /// @inheritdoc IMintTarget
    /// @dev Every edition copy is sold at mint, so there is nothing to settle: a no-op that any
    ///      adapter ever admitted (the minting adapter included, even after removal) may call, so
    ///      a generic adapter never fails here; anyone else is refused with `NotAdmittedMinter`.
    function markPrimarySettled(uint256) external view {
        if (_minterStatus[msg.sender] == MINTER_NONE) revert NotAdmittedMinter(msg.sender);
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
        return (e.royaltyReceiver, Math.mulDiv(salePrice, e.royaltyRate, Splits.DENOMINATOR));
    }

    /// @inheritdoc IEditions
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

    /// @dev The checks of `createEdition`: the work-records satellite bound; no edition yet;
    ///      the master settled; an EDITION_MASTER item that is the master's stored one (its kind is
    ///      bound by the item hash); and the item proven (at most `Limits.MAX_PROOF_DEPTH` nodes)
    ///      in a package root the registry registered (an evidence hash), approved or revoked
    ///      since. The master is read through `IStream.coreOf`, which skips the royalty-receiver
    ///      derivation `work` performs.
    function _admit(
        uint256 workId,
        PackageItem calldata item,
        bytes32 packageRoot,
        bytes32[] calldata proof
    ) private view returns (bytes32 itemHash, Master memory master) {
        if (workRecords == address(0)) revert WorkRecordsUnbound();
        if (exists(workId)) revert EditionExists(workId);
        (master.itemHash, master.artistId,,,, master.royaltyRate) = IStream(stream).coreOf(workId);
        itemHash = WorksHashing.itemHashCalldata(item);
        if (
            !IStream(stream).primarySaleSettled(workId) || item.kind != ItemKind.EDITION_MASTER
                || itemHash != master.itemHash || item.contentHash == 0
                || proof.length > Limits.MAX_PROOF_DEPTH
                || !MerkleProof.verifyCalldata(proof, packageRoot, WorksHashing.leaf(itemHash))
        ) revert NotEditionMaster(workId);
        (, bytes32 evidenceHash,) = packageRegistry.packageOf(packageRoot);
        if (evidenceHash == 0) revert NotEditionMaster(workId);
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

    /// @dev The shared rule (`EditionRules.isValid`, also enforced by the package registry at
    ///      `consume`), with the priced-default case reported by its own error.
    function _checkTerms(uint256 workId, EditionTerms calldata t) private pure {
        if (t.currency == CURRENCY_DEFAULT && t.price != 0) revert PricedDefaultCurrency(workId);
        if (!EditionRules.isValid(t)) revert InvalidEditionTerms(workId);
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
            creator: artistRegistry.activeAuthorityOf(_records[id].artistId)
        });
    }
}
