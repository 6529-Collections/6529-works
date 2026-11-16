// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ISplitFactory } from "../economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "../economics/interfaces/ISplitWallet.sol";
import { Splits } from "../economics/Splits.sol";
import { EditionRules } from "../editions/EditionRules.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IFederatedEditions } from "../interfaces/IFederatedEditions.sol";
import { IFederatedStream } from "../interfaces/IFederatedStream.sol";
import { IFederatedToken } from "../interfaces/IFederatedToken.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH, WorkTerms } from "../interfaces/types/EconomicsTypes.sol";
import { EditionTerms, PackageItem } from "../interfaces/types/PackageTypes.sol";
import {
    PrimaryOutcome,
    PrimarySettlement,
    PrimaryTerms,
    SaleKind
} from "../interfaces/types/SaleTypes.sol";
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { FederatedMembership } from "./FederatedMembership.sol";

/// @title FederatedEditions
/// @notice Federated Stream Editions template: the ERC-1155 half of an artist's linked pair
///         (ADR 0008; FED-31 to FED-40 in `docs/spec/federation.md`).
/// @dev Deployed as a full copy per artist after its partner `FederatedStream`, which the
///      artist then links back (`linkEditions`). An edition is anchored by an EDITION_MASTER work
///      of the partner and has its token ID; it is bound to the adapter whose sale opens it,
///      sealed by that adapter at its sale's count, and created by anyone once the master's sale
///      settled. Its payees are the master's (same seller vault), its network share the locked
///      one, its royalty rate the master's current one. No immutables; no network authority.
contract FederatedEditions is ERC1155, FederatedMembership, IFederatedEditions {
    /// @dev `ItemKind.EDITION_MASTER`.
    uint8 private constant EDITION_MASTER = 1;
    /// @dev The maximum of an edition without a creator cap until its seal: a safety bound
    ///      (`minted` and `limit` are 40-bit), not a policy number, as in 6529 Stream Editions.
    uint40 private constant UNCAPPED = type(uint40).max;

    /// @dev An edition. Slot 0: the content hash (nonzero once created). Slot 1: the seller
    ///      vault, the current maximum, the count minted and the seal. Slot 2: the bound adapter,
    ///      the creator's cap and whether the network's share applies (locked while listed).
    struct Record {
        bytes32 contentHash;
        address seller;
        uint40 limit;
        uint40 minted;
        bool supplySealed;
        address minter;
        uint32 maxCount;
        bool fee;
    }

    string private _name;
    string private _symbol;
    mapping(uint256 editionId => Record) private _records;

    /// @param c The deployment arguments (`IFederatedEditions.Config`).
    constructor(Config memory c)
        ERC1155("")
        FederatedMembership(
            c.artistRegistry,
            c.splitLedger,
            c.artistId,
            c.feeShare,
            c.feeRecipient,
            c.partner,
            c.owner
        )
    {
        Dependency.check(c.partner);
        (_name, _symbol) = (c.name, c.symbol);
    }

    // ------------------------------------------------------------------ editions

    /// @inheritdoc IFederatedEditions
    function createEdition(uint256 editionId, PackageItem calldata item) external {
        Record storage r = _records[editionId];
        if (r.contentHash != 0) revert EditionExists(editionId);
        _checkMaster(editionId, item, true);
        if (r.seller == address(0)) _lock(r, editionId, item);
        uint32 maxCount = item.edition.maxCount;
        (r.contentHash, r.maxCount) = (item.contentHash, maxCount);
        // A sale that sold nothing may have sealed the edition at zero before it existed.
        if (!r.supplySealed) r.limit = maxCount == 0 ? UNCAPPED : maxCount;
        emit EditionCreated(editionId, item.contentHash, item.edition);
        emit MetadataUpdate(editionId);
    }

    /// @inheritdoc IFederatedEditions
    function bindMinter(uint256 editionId, PackageItem calldata item)
        public
        virtual
        returns (WorkTerms memory)
    {
        _onlyMinter();
        Record storage r = _records[editionId];
        address bound = r.minter;
        if (bound == address(0)) {
            if (r.contentHash == 0) {
                _checkMaster(editionId, item, false);
                if (ISaleAdapter(msg.sender).saleKind() != item.edition.saleKind) {
                    revert NotEditionMaster(editionId);
                }
            }
            r.minter = msg.sender;
            if (r.seller == address(0)) _lock(r, editionId, item);
            emit EditionMinterBound(editionId, msg.sender);
        } else if (bound != msg.sender) {
            revert MinterMismatch(editionId, bound);
        }
        return _terms(r, editionId);
    }

    /// @inheritdoc IMintTarget
    /// @dev The bound adapter mints copies to the buyer with `data` exactly
    ///      `abi.encode(CURRENCY_ETH, unitPrice)`, within the edition's maximum; a bound adapter
    ///      no longer admitted mints only once it sealed the edition, so its winners always
    ///      claim. Effects and the log precede the ERC-1155 acceptance call.
    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (uint256, PrimaryTerms memory terms)
    {
        Record storage r = _edition(id);
        if (msg.sender != r.minter) revert MinterMismatch(id, r.minter);
        if (!r.supplySealed) _onlyMinter();
        if (amount == 0 || data.length != 64) revert InvalidMintRequest();
        (address currency, uint256 unitPrice) = abi.decode(data, (address, uint256));
        if (currency != CURRENCY_ETH) revert CurrencyMismatch(CURRENCY_ETH, currency);
        if (amount > r.limit - r.minted) revert EditionUnavailable(id);
        // Safe: amount <= limit - minted, and limit < 2^40.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.minted += uint40(amount);
        terms.saleKind = SaleKind.UNIFORM_AUCTION;
        emit EditionPrimaryMint(id, to, amount, currency, unitPrice);
        _mint(to, id, amount, "");
        return (id, terms);
    }

    /// @inheritdoc IFederatedEditions
    function sealSupply(uint256 editionId, uint256 count) external {
        Record storage r = _records[editionId];
        if (msg.sender != r.minter || msg.sender == address(0)) {
            revert MinterMismatch(editionId, r.minter);
        }
        if (r.supplySealed) revert EditionSealed(editionId);
        if (count < r.minted || count > r.limit) revert InvalidSealCount(editionId, count);
        // Safe: count <= limit < 2^40.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.limit = uint40(count);
        r.supplySealed = true;
        emit EditionSupplySealed(editionId, count);
    }

    /// @inheritdoc IMintTarget
    /// @dev The locked terms; the creator is the partner, which holds an unsold master.
    function primaryTerms(uint256 id, bytes calldata)
        external
        view
        returns (PrimaryTerms memory p)
    {
        Record storage r = _edition(id);
        WorkTerms memory w = _terms(r, id);
        (p.saleKind, p.seller, p.feeRecipient, p.feeShare, p.creator) =
        (SaleKind.UNIFORM_AUCTION, w.seller, w.feeRecipient, w.feeShare, _partner);
    }

    /// @inheritdoc IMintTarget
    /// @dev Every copy is sold at mint: nothing to settle per token.
    function settlePrimary(uint256, PrimaryOutcome, address, address, uint256)
        external
        pure
        returns (PrimarySettlement memory nothing)
    {
        return nothing;
    }

    /// @inheritdoc IMintTarget
    /// @dev The bound adapter, from its own balance.
    function burn(uint256 id, uint256 amount) external {
        Record storage r = _edition(id);
        if (msg.sender != r.minter) revert MinterMismatch(id, r.minter);
        if (amount == 0) revert InvalidMintRequest();
        _burn(msg.sender, id, amount);
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc IFederatedEditions
    function stream() external view returns (address) {
        return _partner;
    }

    /// @inheritdoc IFederatedEditions
    function exists(uint256 editionId) public view returns (bool) {
        return _records[editionId].contentHash != 0;
    }

    /// @inheritdoc IFederatedEditions
    function isBound(uint256 editionId) external view returns (bool) {
        Record storage r = _records[editionId];
        return r.minter != address(0) || r.contentHash != 0;
    }

    /// @inheritdoc IFederatedEditions
    function edition(uint256 editionId) external view returns (IEditions.Edition memory e) {
        Record storage r = _edition(editionId);
        WorkTerms memory w = _terms(r, editionId);
        e.contentHash = r.contentHash;
        e.terms = EditionTerms(r.maxCount, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        (e.minted, e.minter, e.seller, e.feeRecipient, e.feeShare) =
        (r.minted, r.minter, w.seller, w.feeRecipient, w.feeShare);
        (e.royaltyReceiver, e.royaltyRate, e.maxSupply, e.supplySealed) =
        (w.royaltyReceiver, w.royaltyRate, r.limit, r.supplySealed);
    }

    /// @inheritdoc IFederatedEditions
    function masterOf(uint256 editionId) external view returns (address, uint256, bytes32) {
        return (_partner, editionId, _edition(editionId).contentHash);
    }

    /// @inheritdoc IFederatedEditions
    function previewTerms(ISplitWallet.Payee[] calldata payees)
        external
        view
        returns (WorkTerms memory w)
    {
        w.seller = ISplitFactory(_splitLedger).walletFor(payees, bytes32(0));
        (w.feeRecipient, w.feeShare) = _feeTerms();
        w.royaltyReceiver = w.feeShare == 0 ? w.seller : _royaltyVault(w.seller);
    }

    /// @notice ERC-2981 royalty information.
    /// @param tokenId The edition.
    /// @param salePrice The sale price.
    /// @return receiver The royalty receiver.
    /// @return amount The royalty.
    /// @dev The receiver locked with the edition; the master's current rate.
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 amount)
    {
        WorkTerms memory w = _terms(_edition(tokenId), tokenId);
        return (w.royaltyReceiver, Splits.entitlement(salePrice, w.royaltyRate));
    }

    /// @notice The edition's metadata, built by its master's renderer.
    /// @param id The edition ID.
    /// @return The metadata URI.
    function uri(uint256 id) public view override returns (string memory) {
        _edition(id);
        return IRenderer(IFederatedStream(_partner).rendererOf(id)).tokenURI(address(this), id);
    }

    /// @inheritdoc IFederatedEditions
    function name() external view returns (string memory) {
        return _name;
    }

    /// @inheritdoc IFederatedEditions
    function symbol() external view returns (string memory) {
        return _symbol;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IERC2981).interfaceId
            || interfaceId == type(IMintTarget).interfaceId
            || interfaceId == type(IFederatedToken).interfaceId
            || interfaceId == type(IFederatedEditions).interfaceId
            || interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------ internal

    /// @dev After the exit, the artist's own minters mint only once the partner is out of the
    ///      federation too (unlisted, LEFT or LEFT_DELISTED), so no edition of a master sold at
    ///      the network's fee sells without it while the partner is listed.
    function _ownMinters() internal view override returns (bool) {
        (, IArtistRegistry.FederationStatus status) =
            IArtistRegistry(_artistRegistry).federatedListing(_partner);
        return status != IArtistRegistry.FederationStatus.ACTIVE
            && status != IArtistRegistry.FederationStatus.DELISTED;
    }

    /// @dev Reverts unless `item` is the partner's EDITION_MASTER item for `editionId`, with ETH
    ///      edition terms, and (when `settled`) the master's primary sale settled.
    function _checkMaster(uint256 editionId, PackageItem calldata item, bool settled) private view {
        IFederatedStream master = IFederatedStream(_partner);
        (bytes32 itemHash,,, uint8 kind,,) = master.coreOf(editionId);
        if (
            kind != EDITION_MASTER || WorksHashing.itemHashCalldata(item) != itemHash
                || item.edition.currency != CURRENCY_ETH || !EditionRules.isValid(item.edition)
                || (settled && !master.primarySaleSettled(editionId))
        ) revert NotEditionMaster(editionId);
    }

    /// @dev Locks an edition's payees (the master's seller vault) and whether the network's share
    ///      applies (the contract still listed), deploying the vaults it pays.
    function _lock(Record storage r, uint256 editionId, PackageItem calldata item) private {
        address seller = _vault(item.payees);
        (address feeRecipient, uint32 feeShare) = _feeTerms();
        address royalty = seller;
        if (feeShare != 0) royalty = _vault(Splits.royaltyPayees(seller, feeRecipient, feeShare));
        (r.seller, r.fee) = (seller, feeShare != 0);
        emit EditionTermsLocked(editionId, seller, royalty, feeRecipient, feeShare);
    }

    /// @dev An edition's locked terms, with the master's current royalty rate.
    function _terms(Record storage r, uint256 editionId) private view returns (WorkTerms memory w) {
        w.seller = r.seller;
        if (r.fee) {
            (w.feeRecipient, w.feeShare) = (_feeRecipient, _feeShare);
            w.royaltyReceiver = _royaltyVault(w.seller);
        } else {
            w.royaltyReceiver = w.seller;
        }
        (,,,,, w.royaltyRate) = IFederatedStream(_partner).coreOf(editionId);
    }

    function _edition(uint256 editionId) private view returns (Record storage r) {
        r = _records[editionId];
        if (r.contentHash == 0) revert UnknownEdition(editionId);
    }
}
