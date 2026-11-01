// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
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
import { CURRENCY_ETH, PRODUCT_EDITIONS, WorkTerms } from "../interfaces/types/EconomicsTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { EditionTerms, ItemKind, License, PackageItem } from "../interfaces/types/PackageTypes.sol";
import {
    PrimaryOutcome,
    PrimarySettlement,
    PrimaryTerms,
    SaleKind
} from "../interfaces/types/SaleTypes.sol";
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { EditionRules } from "./EditionRules.sol";

/// @title Editions
/// @notice 6529 Stream Editions: the one shared ERC-1155 of editions, each anchored by a 6529
///         Stream work of kind EDITION_MASTER (ADR 0001 section 6, as amended by ADR 0005).
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
///      setter in the 30-day class) whose sale kind (`ISaleAdapter.saleKind`) is the edition's
///      own, from its approved terms. Minting is generic (ADR 0005, owner decision 14): rc.2
///      sells editions by the uniform-price edition auction (`SaleKind.UNIFORM_AUCTION`), and a
///      later sale method (a fixed-price adapter, say) is a new adapter governance admits,
///      selling editions whose terms name its kind, with no redeployment of this contract. The
///      terms' currency and params are opaque here (`EditionRules`). The sale decides how
///      many copies exist, so the terms fix no size: this contract enforces only the creator's
///      optional cap (`maxCount`; burns do not free it) and binds each edition to one adapter:
///      the one whose sale opened it (`bindMinter`, which may precede the edition: the edition
///      auction opens with the master's 1/1, and the item proves the edition's kind), or else
///      the first admitted adapter that mints it. No other adapter, admitted then or later, can
///      open a sale of it or add copies to a count its sale settled. A bound adapter mints its
///      edition even after governance removes it, within the cap: its sale has already paid the
///      seller, so its winners must still claim. A master with an edition is never burned (Stream
///      refuses to burn a settled token), so minting reads nothing from Stream. The adapter owns
///      the currency and the params: `primaryTerms` returns them as approved, and `mint` returns
///      only the sale kind. Royalties are read from this contract's storage with no external
///      call. The receiver is the edition's split (from
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
    /// @inheritdoc IEditions
    string public constant name = "6529 Stream Editions";
    /// @inheritdoc IEditions
    string public constant symbol = "STREAMEDITIONS";

    /// @dev The binding name of the work-records satellite, as 6529 Stream names it.
    bytes32 private constant WORK_RECORDS = "WORK_RECORDS";
    /// @dev Minter status: never admitted, admitted, or admitted once and since removed.
    uint8 private constant MINTER_NONE = 0;
    uint8 private constant MINTER_ADMITTED = 1;
    uint8 private constant MINTER_REMOVED = 2;
    /// @dev The mint bound of an edition without a creator cap: `minted` is a `uint48`.
    uint256 private constant UNCAPPED = type(uint48).max;

    /// @dev What `createEdition` reads of its master from `IStream.coreOf`.
    struct Master {
        bytes32 itemHash;
        uint256 artistId;
        uint32 royaltyRate;
    }

    /// @dev An admitted adapter: its status and the ID an edition binds it by. The ID is given
    ///      at the first admission, from 1, and kept through a removal and a re-admission.
    struct Minter {
        uint8 status;
        uint16 id;
    }

    /// @dev An edition as stored (QUALITY-5), behind the interface's `Edition` view. An edition
    ///      of the uniform-price edition auction writes five words when its terms name a fee
    ///      recipient: the content hash and four packed words. The sale kind, currency and params
    ///      are written only when they differ from the auction's (`saleKind` zero stands for
    ///      `SaleKind.UNIFORM_AUCTION`, the currency zero is ETH, and the params are empty), so
    ///      another sale method costs its own words and the auction none. A mint writes only the
    ///      seller's word: the creator's cap, the count minted and the bound adapter's ID share
    ///      it, so the first mint writes no new slot. `bindMinter` may write that word before the
    ///      edition exists (only `minterId`); `createEdition` writes the other fields one by one
    ///      and keeps it. `minted` is a `uint48`: a capped edition
    ///      stops at its `uint32` cap, and an uncapped one at 2^48 - 1, far past any sale's count.
    struct Record {
        bytes32 contentHash;
        address seller;
        uint32 maxCount;
        uint48 minted;
        uint16 minterId;
        address royaltyReceiver;
        uint32 royaltyRate;
        uint160 artistId;
        uint32 feeShare;
        address feeRecipient;
        bytes32 saleKind;
        address currency;
        bytes params;
    }

    /// @inheritdoc IEditions
    address public immutable stream;

    /// @inheritdoc IEditions
    address public workRecords;
    string private _contractURI;
    address private _owner;
    uint16 private _minterCount;
    mapping(address adapter => Minter) private _minters;
    mapping(uint16 minterId => address) private _minterAddresses;
    mapping(uint256 editionId => Record) private _records;

    /// @param authority_ The AccessManager that governs this contract.
    /// @param stream_ The 6529 Stream contract; the other wiring is read from it.
    /// @param streamCodeHash The reviewed code hash of `stream_`.
    /// @param owner_ The initial marketplace owner.
    constructor(address authority_, address stream_, bytes32 streamCodeHash, address owner_)
        ERC1155("")
        AccessManaged(authority_)
    {
        Dependency.checkPinned(stream_, type(IStream).interfaceId, streamCodeHash);
        IStream s = IStream(stream_);
        if (
            s.packageRegistry() == address(0) || s.economics() == address(0)
                || s.artistRegistry() == address(0)
        ) revert ZeroAddress();
        stream = stream_;
        _owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    // ------------------------------------------------------------------- dependencies

    /// @notice The package registry that approved the packages and claims edition content:
    ///         6529 Stream's, read from it on every use, so a governed replacement there
    ///         (`IStream.setDependency`, owner decision 16) applies here at once.
    /// @return The package registry.
    function packageRegistry() public view returns (IPackageRegistry) {
        return IPackageRegistry(IStream(stream).packageRegistry());
    }

    /// @notice The economics resolver whose `PRODUCT_EDITIONS` terms new editions lock: 6529
    ///         Stream's, read from it on every use.
    /// @return The economics resolver.
    function economics() public view returns (IEconomicsResolver) {
        return IEconomicsResolver(IStream(stream).economics());
    }

    /// @notice The artist registry that resolves each edition's creator: 6529 Stream's, read
    ///         from it on every use.
    /// @return The artist registry.
    function artistRegistry() public view returns (IArtistRegistry) {
        return IArtistRegistry(IStream(stream).artistRegistry());
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
        EditionTerms calldata terms = item.edition;
        if (!EditionRules.isValid(terms)) revert InvalidEditionTerms(workId);

        Record storage r = _records[workId];
        // An edition a sale bound before it existed keeps the economics locked at the binding,
        // which that sale pays (`bindMinter`); the seller, a split wallet, is never zero.
        if (r.seller == address(0)) {
            _lockTerms(r, economics().newWorkTerms(PRODUCT_EDITIONS, item.payees));
        }
        r.contentHash = item.contentHash;
        r.maxCount = terms.maxCount;
        // The master's current rate, not the product default: a consented re-rate of the master
        // before the edition exists carries over; later ones arrive through `setRoyaltyRate`.
        r.royaltyRate = master.royaltyRate;
        // Stream mints only artist IDs below 2^160.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.artistId = uint160(master.artistId);
        // The uniform auction's kind, ETH and empty params are the zero record (`_terms`).
        if (terms.saleKind != SaleKind.UNIFORM_AUCTION) r.saleKind = terms.saleKind;
        if (terms.currency != CURRENCY_ETH) r.currency = terms.currency;
        if (terms.params.length != 0) r.params = terms.params;
        emit EditionCreated(workId, item.contentHash, terms);
        emit MetadataUpdate(workId);

        // Protocol calls, after every effect above: a reentrant `createEdition` hits EditionExists.
        // The registry accepts only the item Stream consumed for this content hash, once.
        packageRegistry().claimContent(item.contentHash, itemHash);
        IStream(stream).linkEdition(workId, workId);
        (address linked, uint256 linkedId) = IStream(stream).editionOf(workId);
        if (linked != address(this) || linkedId != workId) revert LinkFailed(workId);
        return workId;
    }

    /// @inheritdoc IEditions
    /// @dev The target must also be the satellite Stream bound.
    function bindWorkRecords(address target) external restricted {
        if (workRecords != address(0)) revert AlreadyBound(WORK_RECORDS);
        Dependency.check(target, type(IWorkRecords).interfaceId);
        if (target != IStream(stream).workRecords()) revert InvalidBinding(target);
        workRecords = target;
        emit Bound(WORK_RECORDS, target);
    }

    /// @inheritdoc IMintTarget
    /// @dev Emits only on a change: admitting an admitted adapter, or removing one that is not
    ///      admitted (never admitted, or already removed), is a silent no-op. Removal is unchecked;
    ///      an adapter once admitted can still burn its own copies. The first admission gives the
    ///      adapter its binding ID (a 16-bit counter: past 65,535 admissions it reverts).
    function setAdmittedMinter(address adapter, bool admitted) external restricted {
        Minter storage m = _minters[adapter];
        uint8 status = m.status;
        if (admitted == (status == MINTER_ADMITTED)) return;
        if (admitted) {
            Dependency.check(adapter, type(ISaleAdapter).interfaceId);
            if (status == MINTER_NONE) {
                uint16 id = ++_minterCount;
                m.id = id;
                _minterAddresses[id] = adapter;
            }
        }
        m.status = admitted ? MINTER_ADMITTED : MINTER_REMOVED;
        emit AdmittedMinterSet(adapter, admitted);
    }

    /// @inheritdoc IMintTarget
    function isAdmittedMinter(address adapter) external view returns (bool) {
        return _minters[adapter].status == MINTER_ADMITTED;
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
        Record storage r = _records[editionId];
        if (r.royaltyRate == rate) return;
        emit RoyaltyRateChanged(editionId, r.royaltyRate, rate);
        emit MetadataUpdate(editionId);
        r.royaltyRate = rate;
    }

    /// @inheritdoc IEditions
    function edition(uint256 editionId) external view returns (Edition memory e) {
        Record storage r = _edition(editionId);
        e.contentHash = r.contentHash;
        e.terms = _terms(r);
        e.minted = r.minted;
        e.minter = _minterAddresses[r.minterId];
        e.seller = r.seller;
        e.feeRecipient = r.feeRecipient;
        e.feeShare = r.feeShare;
        e.royaltyReceiver = r.royaltyReceiver;
        e.royaltyRate = r.royaltyRate;
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
        return _records[editionId].contentHash != 0;
    }

    // ----------------------------------------------------------------------- minting

    /// @inheritdoc IEditions
    /// @dev Reverts with `NotAdmittedMinter` unless the caller is admitted now (a removed
    ///      adapter opens no new sale), `NotEditionMaster` if the edition does not exist and
    ///      `item` is not the master's stored EDITION_MASTER item, and `SaleKindMismatch` if the
    ///      caller's kind is not the edition's. Binding an edition that does not exist yet also
    ///      locks its `PRODUCT_EDITIONS` economics (seller, network fee, royalty receiver) from
    ///      the resolver, in the transaction in which the binding sale locks its own, and
    ///      `createEdition` keeps them: the edition reports the split its sale paid.
    function bindMinter(uint256 editionId, PackageItem calldata item) external {
        Minter memory m = _minters[msg.sender];
        if (m.status != MINTER_ADMITTED) revert NotAdmittedMinter(msg.sender);
        Record storage r = _records[editionId];
        if (r.contentHash != 0) {
            _bind(r, editionId, m, _saleKind(r));
            return;
        }
        (bytes32 itemHash,,, ItemKind kind,,) = IStream(stream).coreOf(editionId);
        if (kind != ItemKind.EDITION_MASTER || WorksHashing.itemHashCalldata(item) != itemHash) {
            revert NotEditionMaster(editionId);
        }
        bool unbound = r.minterId == 0;
        _bind(r, editionId, m, item.edition.saleKind);
        if (unbound) _lockTerms(r, economics().newWorkTerms(PRODUCT_EDITIONS, item.payees));
    }

    /// @inheritdoc IMintTarget
    /// @dev `data` must be empty. The caller must report the edition's sale kind and be the
    ///      edition's bound adapter; an unbound edition is bound to its first minter, which must
    ///      be admitted (`EditionMinterBound`). A bound adapter mints even after its removal, so
    ///      the winners of a sale it settled always claim; the cap still bounds it. Any other
    ///      caller ever admitted is refused with `MinterMismatch`, and one never admitted with
    ///      `NotAdmittedMinter`. The count is the sale's to decide; this contract enforces
    ///      only the creator's cap. `terms` carries only the sale kind: an adapter locks the full
    ///      terms when its sale opens and never reads them from a mint, so a mint skips the
    ///      artist-registry call (QUALITY-2). Effects precede the ERC-1155 acceptance call, so a
    ///      reentering receiver sees the updated supply.
    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        Minter memory m = _minters[msg.sender];
        if (m.status == MINTER_NONE) revert NotAdmittedMinter(msg.sender);
        if (amount == 0 || data.length != 0) revert InvalidMintRequest();
        Record storage r = _edition(id);
        bytes32 kind = _bind(r, id, m, _saleKind(r));
        uint256 cap = r.maxCount == 0 ? UNCAPPED : r.maxCount;
        if (amount > cap - r.minted) revert EditionUnavailable(id);
        // casting to 'uint48' is safe because amount <= cap - minted <= type(uint48).max - minted
        // forge-lint: disable-next-line(unsafe-typecast)
        r.minted += uint48(amount);
        terms.saleKind = kind;
        _mint(to, id, amount, "");
        return (id, terms);
    }

    /// @inheritdoc IMintTarget
    /// @dev The edition's sale kind, currency and params as approved (the currency unresolved:
    ///      the adapter resolves and locks it), no price (`EditionTerms` has none: a priced sale
    ///      method carries its price in its params), and the locked economics; `data` is
    ///      ignored.
    function primaryTerms(uint256 id, bytes calldata) external view returns (PrimaryTerms memory) {
        return _primaryTerms(_edition(id));
    }

    /// @inheritdoc IMintTarget
    /// @dev Any adapter ever admitted, including one since removed: copies can come from several
    ///      adapters, and a burn only takes from the caller's own balance. Burned copies still
    ///      count toward the creator's cap.
    function burn(uint256 id, uint256 amount) external {
        if (_minters[msg.sender].status == MINTER_NONE) revert NotAdmittedMinter(msg.sender);
        if (amount == 0) revert InvalidMintRequest();
        _edition(id);
        _burn(msg.sender, id, amount);
    }

    /// @inheritdoc IMintTarget
    /// @dev Every edition copy is sold at mint, so there is nothing to settle: a no-op returning
    ///      nothing that any adapter ever admitted (the minting adapter included, even after
    ///      removal) may call, so a generic adapter never fails here; anyone else is refused with
    ///      `NotAdmittedMinter`.
    function settlePrimary(uint256, PrimaryOutcome, address, address, uint256)
        external
        view
        returns (PrimarySettlement memory nothing)
    {
        if (_minters[msg.sender].status == MINTER_NONE) revert NotAdmittedMinter(msg.sender);
        return nothing;
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
        Record storage r = _edition(tokenId);
        return (r.royaltyReceiver, Math.mulDiv(salePrice, r.royaltyRate, Splits.DENOMINATOR));
    }

    /// @inheritdoc IEditions
    function licenseOf(uint256 editionId) external view returns (License memory) {
        _edition(editionId);
        return IWorkRecords(workRecords).licenseOf(editionId);
    }

    /// @notice The edition's metadata, built by its master's renderer from the master's record
    ///         and content-store bytes. Reverts with `UnknownEdition`.
    /// @param id The edition ID.
    /// @return The renderer's compact metadata URI (`IRenderer.tokenURI`) for this contract and
    ///        `id`.
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
        (, bytes32 evidenceHash,) = packageRegistry().packageOf(packageRoot);
        if (evidenceHash == 0) revert NotEditionMaster(workId);
    }

    /// @dev Writes the economics an edition locks: its seller, network fee and royalty receiver
    ///      (the royalty rate is the master's, written by `createEdition`).
    function _lockTerms(Record storage r, WorkTerms memory w) private {
        r.seller = w.seller;
        r.royaltyReceiver = w.royaltyReceiver;
        r.feeShare = w.feeShare;
        r.feeRecipient = w.feeRecipient;
    }

    /// @dev Checks that the caller's sale kind is `expected`, then binds an unbound edition to
    ///      the caller, which must be admitted, or checks that the caller is its bound adapter.
    ///      Returns the caller's kind.
    function _bind(Record storage r, uint256 editionId, Minter memory m, bytes32 expected)
        private
        returns (bytes32 kind)
    {
        kind = ISaleAdapter(msg.sender).saleKind();
        if (kind != expected) revert SaleKindMismatch(expected, kind);
        uint16 bound = r.minterId;
        if (bound == 0) {
            if (m.status != MINTER_ADMITTED) revert NotAdmittedMinter(msg.sender);
            r.minterId = m.id;
            emit EditionMinterBound(editionId, msg.sender);
        } else if (bound != m.id) {
            revert MinterMismatch(editionId, _minterAddresses[bound]);
        }
    }

    function _edition(uint256 editionId) private view returns (Record storage r) {
        r = _records[editionId];
        if (r.contentHash == 0) revert UnknownEdition(editionId);
    }

    function _primaryTerms(Record storage r) private view returns (PrimaryTerms memory) {
        return PrimaryTerms({
            saleKind: _saleKind(r),
            currency: r.currency,
            price: 0,
            params: r.params,
            seller: r.seller,
            feeRecipient: r.feeRecipient,
            feeShare: r.feeShare,
            creator: artistRegistry().activeAuthorityOf(r.artistId)
        });
    }

    /// @dev The edition terms as approved, rebuilt from the record.
    function _terms(Record storage r) private view returns (EditionTerms memory t) {
        t.maxCount = r.maxCount;
        t.currency = r.currency;
        t.saleKind = _saleKind(r);
        t.params = r.params;
    }

    /// @dev The edition's sale kind: a stored zero is the uniform-price edition auction's.
    function _saleKind(Record storage r) private view returns (bytes32 kind) {
        kind = r.saleKind;
        if (kind == 0) kind = SaleKind.UNIFORM_AUCTION;
    }
}
