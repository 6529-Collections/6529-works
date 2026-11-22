// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ISplitFactory } from "../economics/interfaces/ISplitFactory.sol";
import { Splits } from "../economics/Splits.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IContentStore } from "../interfaces/IContentStore.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEntropyModule } from "../interfaces/IEntropyModule.sol";
import { IFederatedDeployer } from "../interfaces/IFederatedDeployer.sol";
import { IFederatedMembership } from "../interfaces/IFederatedMembership.sol";
import { IFederatedStream } from "../interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "../interfaces/IFederationRegistry.sol";
import { Core, MintFacts, MintTerms, Slots } from "../interfaces/core/CoreTypes.sol";
import { IAccounts } from "../interfaces/core/IAccounts.sol";
import { IEditions } from "../interfaces/core/IEditions.sol";
import { IFederationGate } from "../interfaces/core/IFederationGate.sol";
import { IMintPolicy } from "../interfaces/core/IMintPolicy.sol";
import { IModuleSlots } from "../interfaces/core/IModules.sol";
import { IStream } from "../interfaces/core/IStream.sol";
import { IWorkFacts } from "../interfaces/core/IWorkFacts.sol";
import { MediaFile } from "../interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH, PRODUCT_FEDERATED } from "../interfaces/types/EconomicsTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { PackageItem, Party } from "../interfaces/types/PackageTypes.sol";
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";
import { SpdxId } from "../stream/SpdxId.sol";

/// @title FederationRegistry
/// @notice The federation module (replaceable, governed; the permanent `Directory`'s FEDERATION
///         slot names it): the directory of federated contracts, template versions, the
///         federated sale contracts, delisting by contract and by account, each contract's
///         network fee share (recorded at listing, only lowered), the artist's item approvals,
///         and the mint policy of federated works (`IMintPolicy.authorize`), which checks the
///         item, the media, every collaborator's consent and the payees, and deploys the vaults.
/// @dev Every federated token asks the module the directory names now (`IFederationGate`). This
///      module has no power over a deployed token, a work or money: it decides which contracts
///      are listed, which sale contracts may mint new works and open new sales, and what a new
///      work is minted with. A replacement is deployed naming this one as `previous` and reads
///      through it for listings, account delistings, template versions and sale contracts it has
///      not recorded itself, so it inherits them without any artist signature. Every governed
///      function is the network's, at the role delays of the genesis role map.
contract FederationRegistry is IFederationRegistry, IFederationGate, IMintPolicy, AccessManaged {
    /// @notice Whether an account is delisted, as recorded here.
    /// @param recorded Whether this module recorded the account (else the predecessor answers).
    /// @param delisted Whether the account is delisted.
    struct Delisting {
        bool recorded;
        bool delisted;
    }

    /// @notice The most contracts one `setStatus` call takes: a bound on the work of one call.
    uint256 public constant MAX_BATCH = 256;
    /// @dev `ItemKind.EDITION_MASTER`.
    uint8 private constant EDITION_MASTER = 1;
    /// @dev `SeedPolicy.ARTIST` and `SeedPolicy.VRF`.
    uint8 private constant SEED_ARTIST = 1;
    uint8 private constant SEED_VRF = 2;
    /// @dev The most chunks of a license text: a bound on the work of one call.
    uint256 private constant MAX_LICENSE_TEXT_CHUNKS = 16;
    /// @dev The one collection of a federated token.
    uint256 private constant COLLECTION = 1;
    /// @dev The domain of a listing consent.
    bytes32 private constant LISTING_DOMAIN = keccak256("6529WORKS_FEDERATED_LISTING_V1");

    /// @notice The permanent directory (its ACCOUNTS slot names the accounts module).
    address public immutable directory;
    /// @notice The permanent record contract every federated 1/1 token must name.
    address public immutable facts;
    /// @notice The economics resolver: the federated share at listing and the fee recipient.
    IEconomicsResolver public immutable economics;
    /// @notice The split ledger that deploys every seller and royalty vault.
    address public immutable splitFactory;
    /// @notice The content store media files are registered in.
    address public immutable contentStore;
    /// @notice The module this one replaces (zero for the first): read for what is not recorded
    ///         here.
    address public immutable previous;
    /// @inheritdoc IFederationRegistry
    address public entropyModule;

    /// @inheritdoc IMintPolicy
    mapping(bytes32 itemHash => bool) public isBarred;

    mapping(address deployer => Template) private _templates;
    mapping(address token => Listing) private _listings;
    mapping(uint256 artistId => Delisting) private _delistings;
    mapping(address minter => SaleContract) private _saleContracts;
    mapping(address token => mapping(bytes32 itemHash => Item)) private _items;
    mapping(address token => mapping(bytes32 contentHash => Release)) private _releases;

    /// @param authority_ The AccessManager.
    /// @param directory_ The permanent directory.
    /// @param facts_ The permanent record contract.
    /// @param economics_ The economics resolver; its split factory is the split ledger.
    /// @param contentStore_ The content store.
    /// @param previous_ The federation module this one replaces, or zero.
    constructor(
        address authority_,
        address directory_,
        address facts_,
        address economics_,
        address contentStore_,
        address previous_
    ) AccessManaged(authority_) {
        directory = directory_;
        facts = facts_;
        economics = IEconomicsResolver(economics_);
        splitFactory = IEconomicsResolver(economics_).splitFactory();
        contentStore = contentStore_;
        previous = previous_;
        if (previous_ != address(0)) entropyModule = FederationRegistry(previous_).entropyModule();
    }

    // ------------------------------------------------------------------------ governance

    /// @notice Approves a template version: its ownerless deployer, which alone creates its
    ///         copies. The network. Once per deployer.
    /// @param deployer The version's `FederatedDeployer` (code).
    /// @param version Its version number.
    /// @param form ERC721 or ERC1155.
    function approveTemplate(address deployer, uint32 version, Form form) external restricted {
        Template memory t = templateOf(deployer);
        if (t.status != TemplateStatus.NONE || form == Form.PAIR || deployer.code.length == 0) {
            revert TemplateStatusInvalid(deployer, t.status);
        }
        _templates[deployer] = Template(version, form, TemplateStatus.APPROVED);
        _emitTemplate(deployer);
    }

    /// @notice Suspends a version: its contracts join, mint and open new sales no more; running
    ///         sales finish. The network.
    /// @param deployer The version's deployer.
    function suspendTemplate(address deployer) external restricted {
        _move(deployer, TemplateStatus.APPROVED, TemplateStatus.SUSPENDED);
    }

    /// @notice Lifts a suspension. The network.
    /// @param deployer The version's deployer.
    function resumeTemplate(address deployer) external restricted {
        _move(deployer, TemplateStatus.SUSPENDED, TemplateStatus.APPROVED);
    }

    /// @notice Revokes a version: its contracts are no longer served, and their running sales
    ///         end unsold with refunds. The network, which can reverse it (`reinstateTemplate`).
    /// @param deployer The version's deployer.
    function revokeTemplate(address deployer) external restricted {
        TemplateStatus current = templateOf(deployer).status;
        if (current != TemplateStatus.APPROVED && current != TemplateStatus.SUSPENDED) {
            revert TemplateStatusInvalid(deployer, current);
        }
        _ownTemplate(deployer).status = TemplateStatus.REVOKED;
        _emitTemplate(deployer);
    }

    /// @notice Reverses a revocation: REVOKED to APPROVED. The network. A revocation writes no
    ///         listing, so the version's contracts are served again as listed.
    /// @param deployer The version's deployer.
    function reinstateTemplate(address deployer) external restricted {
        _move(deployer, TemplateStatus.REVOKED, TemplateStatus.APPROVED);
    }

    /// @notice Adds (`admitted`) or removes a federated sale contract, at once. The network. A
    ///         removed one may be added again. Removal stops new works only: the sale contract
    ///         still finishes the sales it started, and from then the rescue and rebind waits of
    ///         the federated tokens count from the removal. The network's waiting period applies
    ///         to installing this module in the directory, not to each sale contract.
    /// @param adapter The sale contract (code, to add).
    /// @param admitted True to add, false to remove.
    function setAdapter(address adapter, bool admitted) external restricted {
        SaleContract memory s = saleContractOf(adapter);
        bool active = s.addedAt != 0 && s.removedAt == 0;
        if (admitted) {
            if (adapter.code.length == 0 || active) revert SaleContractInvalid(adapter);
            s = SaleContract(_now(), 0);
        } else {
            if (!active) revert SaleContractInvalid(adapter);
            s.removedAt = _now();
        }
        _saleContracts[adapter] = s;
        emit SaleContractSet(adapter, s.addedAt, s.removedAt);
    }

    /// @notice Sets listed contracts ACTIVE or DELISTED, in batches of the caller's size. The
    ///         network. An unlisted contract is skipped. A delisting never touches tokens,
    ///         ownership, records or funds; it stops new works and sales, and running sales end
    ///         unsold with refunds.
    /// @param tokens The federated contracts.
    /// @param status ACTIVE or DELISTED.
    /// @param ref A reference to the decision.
    function setStatus(address[] calldata tokens, Status status, bytes32 ref) external restricted {
        if (tokens.length > MAX_BATCH) revert BatchTooLarge(tokens.length);
        if (status == Status.NONE) revert NotListed(address(0));
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            if (listingOf(token).status == Status.NONE) continue;
            Listing storage l = _ownListing(token);
            emit StatusSet(token, l.status, status, ref);
            l.status = status;
        }
    }

    /// @notice Delists a whole account, or ends that. The network. While set, the account lists
    ///         no new contract and every contract it listed reads DELISTED. Federation only:
    ///         identity, payout and 6529 Stream works are untouched.
    /// @param artistId The account.
    /// @param delisted Whether it is delisted.
    /// @param ref A reference to the decision.
    function setAccountDelisted(uint256 artistId, bool delisted, bytes32 ref) external restricted {
        _delistings[artistId] = Delisting(true, delisted);
        emit AccountDelistedSet(artistId, delisted, ref);
    }

    /// @notice Lowers a listed contract's network share. The network. Lower only: nothing raises
    ///         it. The TERMS module moves the royalty receivers of existing works to the new share.
    /// @param token The contract.
    /// @param share The new share, below the current one.
    function lowerFeeShare(address token, uint32 share) external restricted {
        uint32 current = listingOf(token).feeShare;
        if (listingOf(token).status == Status.NONE) revert NotListed(token);
        if (share >= current) revert FeeShareNotLowered(token, current);
        _ownListing(token).feeShare = share;
        emit FeeShareLowered(token, current, share);
    }

    /// @notice Sets the entropy module of federated VRF works. The network.
    /// @param next The entropy module, or zero for none.
    function setEntropyModule(address next) external restricted {
        emit EntropyModuleSet(entropyModule, next);
        entropyModule = next;
    }

    /// @inheritdoc IMintPolicy
    /// @dev For a listed federated 1/1 contract: `tokenId` must be burned and named by
    ///      `tokenOfContent(contentHash)`, and `beneficiary` must be the contract's artist. The
    ///      burned item is barred for good.
    function releaseContent(
        address token,
        uint256 tokenId,
        bytes32 contentHash,
        uint256 beneficiary
    ) external restricted {
        Listing memory l = listingOf(token);
        if (
            l.form != Form.ERC721 || l.status == Status.NONE || tokenId == 0
                || IStream(token).tokenOfContent(contentHash) != tokenId || _isLive(token, tokenId)
                || beneficiary != l.artistId
        ) revert ReleaseRefused(token, tokenId);
        _releases[token][contentHash] = Release(tokenId, beneficiary);
        bytes32 itemHash = IStream(token).workOf(tokenId).itemHash;
        isBarred[itemHash] = true;
        emit ContentReleased(token, tokenId, contentHash, beneficiary);
        emit ItemBarred(itemHash);
    }

    // ------------------------------------------------------------------------- listing

    /// @inheritdoc IFederationRegistry
    function register(address token, Join calldata j) external {
        Template memory t = templateOf(j.deployer);
        if (
            listingOf(token).status != Status.NONE || t.status != TemplateStatus.APPROVED
                || !IFederatedDeployer(j.deployer).deployed(token)
                || IFederatedMembership(token).directory() != directory
        ) revert NotListable(token);
        uint256 artistId = IFederatedMembership(token).artistId();
        if (isAccountDelisted(artistId)) revert NotListable(token);
        address partner;
        if (t.form == Form.ERC721) {
            if (IStream(token).facts() != facts) revert NotListable(token);
        } else {
            partner = IEditions(token).stream();
            Listing memory p = listingOf(partner);
            if (
                !_listedActive(p) || p.form != Form.ERC721 || p.artistId != artistId
                    || p.partner != address(0)
            ) revert NotListable(token);
        }
        uint32 share = economics.economics(PRODUCT_FEDERATED).feeShare;
        _identify(artistId, j);
        SignatureVerifier.checkDeadline(j.deadline);
        _accounts()
            .requireConsent(
                artistId, listingSubject(token, t.form, partner, share, j.deadline), j.consent
            );
        // Checked: an artist ID is at most 160 bits (the token's constructor).
        // forge-lint: disable-next-line(unsafe-typecast)
        _listings[token] =
            Listing(uint160(artistId), Status.ACTIVE, t.form, share, j.deployer, partner);
        if (partner != address(0)) _ownListing(partner).partner = token;
        emit Registered(token, artistId, j.deployer, t.form, partner, share);
    }

    /// @inheritdoc IFederationRegistry
    function listingSubject(
        address token,
        Form form,
        address partner,
        uint32 feeShare,
        uint64 deadline
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(LISTING_DOMAIN, token, form, partner, feeShare, deadline));
    }

    // --------------------------------------------------------------------------- items

    /// @notice Approves an item for one mint into a listed federated 1/1 contract, with the
    ///         royalty rate its work gets. Any wallet of the contract's artist's account. An
    ///         approval may be changed until the item is minted.
    /// @param token The federated 1/1 contract.
    /// @param itemHash `WorksHashing.itemHash` of the item.
    /// @param royaltyRate The royalty rate, out of 100,000.
    function approveItem(address token, bytes32 itemHash, uint24 royaltyRate) external {
        _requireTokenArtist(token);
        if (royaltyRate > Core.DENOMINATOR) revert InvalidRoyaltyRate(royaltyRate);
        Item storage it = _items[token][itemHash];
        if (it.used || isBarred[itemHash]) revert ItemNotApproved(token, itemHash);
        (it.approved, it.royaltyRate) = (true, royaltyRate);
        emit ItemApproval(token, itemHash, royaltyRate, true);
    }

    /// @notice Withdraws an item's approval before it is minted. Any wallet of the contract's
    ///         artist's account.
    /// @param token The federated 1/1 contract.
    /// @param itemHash The item hash.
    function revokeItem(address token, bytes32 itemHash) external {
        _requireTokenArtist(token);
        Item storage it = _items[token][itemHash];
        if (it.used) revert ItemNotApproved(token, itemHash);
        (it.approved, it.royaltyRate) = (false, 0);
        emit ItemApproval(token, itemHash, 0, false);
    }

    /// @notice An item's approval for a contract.
    /// @param token The contract.
    /// @param itemHash The item hash.
    /// @return The approval.
    function itemOf(address token, bytes32 itemHash) external view returns (Item memory) {
        return _items[token][itemHash];
    }

    // ---------------------------------------------------------------------- mint policy

    /// @inheritdoc IMintPolicy
    /// @dev `request` is `abi.encode(IFederatedStream.FederatedMint)`. The caller must be a sale
    ///      contract that may mint into `token` now (`canMint`). The item must be approved for
    ///      `token`, not minted and not barred; it is consumed. Checks: ETH only; one to
    ///      `Limits.MAX_MEDIA_FILES` media files, each registered in the content store with the
    ///      stated SHA-256, the primary first and committed by the item; kind original or edition
    ///      master (a master needs the contract's editions listed ACTIVE); seed policy none,
    ///      artist or VRF (delivered); a license ID the renderer can show, its text a registered
    ///      SHA-256 file of at most 16 chunks, CC0 naming the deployment's CC0 text; the first
    ///      party is the contract's artist; every later party consents to the item and its
    ///      royalty rate for this contract (`Core.federatedConsent`); every artist-resolved
    ///      payee is a party with a payout address now; a burned work's content mints again only
    ///      once the network released it. The seller vault of the item's payees and the royalty
    ///      vault at the contract's share are deployed here, so no sale pays an undeployed vault.
    function authorize(address token, bytes calldata request)
        external
        returns (MintFacts memory f, MintTerms memory t)
    {
        if (!canMint(token, msg.sender)) revert NotSaleContract(token, msg.sender);
        IFederatedStream.FederatedMint memory m =
            abi.decode(request, (IFederatedStream.FederatedMint));
        bytes32 itemHash = WorksHashing.itemHash(m.item);
        Item storage it = _items[token][itemHash];
        if (!it.approved || it.used || isBarred[itemHash]) revert ItemNotApproved(token, itemHash);
        it.used = true;
        f = _facts(token, m, itemHash, it.royaltyRate);
        t = _terms(token, m.item);
        t.seller = ISplitFactory(splitFactory).createWallet(m.item.payees, bytes32(0));
        f.seller = t.seller;
        f.royaltyReceiver = t.feeShare == 0
            ? t.seller
            : ISplitFactory(splitFactory)
                .createWallet(
                    Splits.royaltyPayees(t.seller, t.feeRecipient, t.feeShare), bytes32(0)
                );
        emit ItemMinted(token, itemHash, msg.sender, t.seller, f.royaltyReceiver);
    }

    /// @inheritdoc IMintPolicy
    /// @dev The same checks as `authorize` except the caller's; nothing is consumed or deployed
    ///      (the vaults are predicted).
    function preview(address token, bytes calldata request)
        external
        view
        returns (MintFacts memory f, MintTerms memory t)
    {
        IFederatedStream.FederatedMint memory m =
            abi.decode(request, (IFederatedStream.FederatedMint));
        bytes32 itemHash = WorksHashing.itemHash(m.item);
        Item memory it = _items[token][itemHash];
        if (!it.approved || it.used || isBarred[itemHash]) revert ItemNotApproved(token, itemHash);
        f = _facts(token, m, itemHash, it.royaltyRate);
        t = _terms(token, m.item);
        t.seller = ISplitFactory(splitFactory).walletFor(m.item.payees, bytes32(0));
        f.seller = t.seller;
        f.royaltyReceiver = t.feeShare == 0
            ? t.seller
            : ISplitFactory(splitFactory)
                .walletFor(Splits.royaltyPayees(t.seller, t.feeRecipient, t.feeShare), bytes32(0));
    }

    /// @inheritdoc IMintPolicy
    /// @dev Zero unless the release names the token `tokenOfContent(contentHash)` names now.
    function releasedTo(address token, bytes32 contentHash) external view returns (uint256) {
        Release memory r = _releases[token][contentHash];
        if (r.tokenId == 0 || IStream(token).tokenOfContent(contentHash) != r.tokenId) return 0;
        return r.beneficiary;
    }

    // --------------------------------------------------------------------------- reads

    /// @inheritdoc IFederationRegistry
    function entry(address token) external view returns (Entry memory e) {
        Listing memory l = listingOf(token);
        if (l.status == Status.NONE) return e;
        e = Entry(
            l.form,
            l.partner,
            l.artistId,
            templateOf(l.deployer).version,
            token.codehash,
            l.feeShare,
            _listedActive(l) ? Status.ACTIVE : Status.DELISTED
        );
    }

    /// @inheritdoc IFederationRegistry
    function isActive(address token) external view returns (bool) {
        Listing memory l = listingOf(token);
        TemplateStatus t = templateOf(l.deployer).status;
        return _listedActive(l) && (t == TemplateStatus.APPROVED || t == TemplateStatus.SUSPENDED);
    }

    /// @inheritdoc IFederationGate
    function canMint(address token, address minter)
        public
        view
        override(IFederationGate, IFederationRegistry)
        returns (bool)
    {
        SaleContract memory s = saleContractOf(minter);
        if (s.addedAt == 0 || s.removedAt != 0) return false;
        Listing memory l = listingOf(token);
        if (!_mintable(l)) return false;
        return l.form != Form.ERC1155 || _mintable(listingOf(l.partner));
    }

    /// @inheritdoc IFederationGate
    function wasMinter(address minter) external view returns (bool) {
        return saleContractOf(minter).addedAt != 0;
    }

    /// @inheritdoc IFederationGate
    function minterRemovedAt(address minter) external view returns (uint256) {
        return saleContractOf(minter).removedAt;
    }

    /// @inheritdoc IFederationGate
    function feeShareOf(address token) external view returns (uint32) {
        return listingOf(token).feeShare;
    }

    /// @notice A template version, as recorded here or inherited.
    /// @param deployer The version's deployer.
    /// @return t The template (status NONE: unknown).
    function templateOf(address deployer) public view returns (Template memory t) {
        t = _templates[deployer];
        if (t.status == TemplateStatus.NONE && previous != address(0)) {
            t = FederationRegistry(previous).templateOf(deployer);
        }
    }

    /// @notice A contract's listing as stored here or inherited (its own status, before the
    ///         account flag).
    /// @param token The contract.
    /// @return l The listing (status NONE: not listed).
    function listingOf(address token) public view returns (Listing memory l) {
        l = _listings[token];
        if (l.status == Status.NONE && previous != address(0)) {
            l = FederationRegistry(previous).listingOf(token);
        }
    }

    /// @notice Whether an account is delisted, as recorded here or inherited.
    /// @param artistId The account.
    /// @return True if delisted.
    function isAccountDelisted(uint256 artistId) public view returns (bool) {
        Delisting memory d = _delistings[artistId];
        if (d.recorded) return d.delisted;
        return previous != address(0) && FederationRegistry(previous).isAccountDelisted(artistId);
    }

    /// @notice A federated sale contract's standing, as recorded here or inherited.
    /// @param minter The sale contract.
    /// @return s Its standing.
    function saleContractOf(address minter) public view returns (SaleContract memory s) {
        s = _saleContracts[minter];
        if (s.addedAt == 0 && previous != address(0)) {
            s = FederationRegistry(previous).saleContractOf(minter);
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IFederationRegistry).interfaceId
            || interfaceId == type(IFederationGate).interfaceId
            || interfaceId == type(IMintPolicy).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // ------------------------------------------------------------------------ internal

    /// @dev The facts of a new work, after every check but the caller's and the vaults.
    function _facts(
        address token,
        IFederatedStream.FederatedMint memory m,
        bytes32 itemHash,
        uint24 rate
    ) private view returns (MintFacts memory f) {
        Listing memory l = listingOf(token);
        PackageItem memory item = m.item;
        _checkItem(l, item, m.media);
        _checkParties(token, item, itemHash, rate, m.consents, l.artistId);
        _checkContent(token, item.contentHash, l.artistId);
        f.itemHash = itemHash;
        f.contentHash = item.contentHash;
        f.artistId = l.artistId;
        f.collectionId = COLLECTION;
        f.kind = item.kind;
        f.seedPolicy = item.seedPolicy;
        f.seed = _seed(token, item);
        f.royaltyRate = rate;
        f.mediaHash = item.mediaHash;
        f.recordFileId = item.recordFileId;
    }

    /// @dev The sale's terms, without the seller.
    function _terms(address token, PackageItem memory item)
        private
        view
        returns (MintTerms memory t)
    {
        t.saleKind = item.sale.saleKind;
        t.params = item.sale.params;
        t.feeRecipient = economics.economics(PRODUCT_FEDERATED).feeRecipient;
        t.feeShare = listingOf(token).feeShare;
        t.creator = token;
    }

    /// @dev The item's own rules: currency, media, kind, seed policy and license.
    function _checkItem(Listing memory l, PackageItem memory item, MediaFile[] memory media)
        private
        view
    {
        uint256 count = media.length;
        if (
            l.form != Form.ERC721 || item.sale.currency != CURRENCY_ETH || count == 0
                || count > Limits.MAX_MEDIA_FILES || item.contentHash == 0
                || media[0].sha256Hash != item.contentHash
                || WorksHashing.mediaHash(media) != item.mediaHash || item.kind > EDITION_MASTER
                || item.seedPolicy > SEED_VRF || !SpdxId.isValid(item.license.spdxId)
                || (item.kind == EDITION_MASTER
                    && (l.partner == address(0) || !_listedActive(listingOf(l.partner))))
        ) revert InvalidMintRequest();
        for (uint256 i; i < count; ++i) {
            // Reverts for a file the store does not know.
            if (
                IContentStore(contentStore).sha256Of(media[i].fileId) != media[i].sha256Hash
                    || (media[i].role == 0) != (i == 0)
            ) revert InvalidMintRequest();
        }
        IContentStore.FileInfo memory info =
            IContentStore(contentStore).fileInfo(item.license.textFileId);
        if (
            info.digestKind != 0 || info.chunkCount > MAX_LICENSE_TEXT_CHUNKS
                || (WorksHashing.licenseKey(item.license.spdxId) == WorksHashing.CC0_LICENSE_KEY
                    && item.license.textFileId != IWorkFacts(facts).cc0TextFileId())
        ) revert InvalidMintRequest();
    }

    /// @dev Reverts (`InvalidMintRequest`) unless the first party is the contract's artist (its
    ///      ID as an address), there are at most `Limits.MAX_PARTIES` parties and one consent per
    ///      later party, and at most `Splits.MAX_PAYEES` payees. Each later party's consent to
    ///      `Core.federatedConsent(itemHash, rate)` for `token` must be good
    ///      (`IAccounts.requireSigned` over `consentDigest(token, ...)` reverts otherwise):
    ///      signed by a wallet of that party's account, so consent is unanimous and counted by
    ///      account. Every artist-resolved payee must be a party with a payout address now.
    function _checkParties(
        address token,
        PackageItem memory item,
        bytes32 itemHash,
        uint24 rate,
        bytes[] memory consents,
        uint256 artistId
    ) private view {
        Party[] memory parties = item.parties;
        uint256 n = parties.length;
        if (
            n == 0 || n > Limits.MAX_PARTIES || uint160(parties[0].account) != artistId
                || consents.length != n - 1 || item.payees.length > Splits.MAX_PAYEES
        ) revert InvalidMintRequest();
        IAccounts accounts = _accounts();
        bytes32 digest = accounts.consentDigest(token, Core.federatedConsent(itemHash, rate));
        for (uint256 i = 1; i < n; ++i) {
            accounts.requireSigned(uint160(parties[i].account), digest, consents[i - 1]);
        }
        for (uint256 i; i < item.payees.length; ++i) {
            uint256 payee = item.payees[i].artistId;
            if (payee == 0) continue;
            uint256 j;
            while (j < n && uint160(parties[j].account) != payee) {
                ++j;
            }
            if (j == n || accounts.payoutAddress(payee) == address(0)) {
                revert InvalidMintRequest();
            }
        }
    }

    /// @dev A content whose token was burned mints again only once the network released it for
    ///      that burned token, to this contract's artist.
    function _checkContent(address token, bytes32 contentHash, uint256 artistId) private view {
        uint256 existing = IStream(token).tokenOfContent(contentHash);
        if (existing == 0) return;
        Release memory r = _releases[token][contentHash];
        if (_isLive(token, existing) || r.tokenId != existing) {
            revert ContentUsed(contentHash, existing);
        }
        if (r.beneficiary != artistId) revert ContentReserved(contentHash, r.beneficiary);
    }

    /// @dev The seed a new work is minted with: none, the artist's, or the VRF seed delivered
    ///      for this contract and content (`SeedNotDelivered` until then).
    function _seed(address token, PackageItem memory item) private view returns (bytes32 seed) {
        if (item.seedPolicy == SEED_ARTIST) return item.seed;
        if (item.seedPolicy != SEED_VRF) return bytes32(0);
        address module = entropyModule;
        bool delivered;
        if (module != address(0)) {
            (delivered, seed) = IEntropyModule(module).federatedSeedOf(token, item.contentHash);
        }
        if (!delivered) revert SeedNotDelivered(token, item.contentHash);
    }

    /// @dev Creates the artist's identity from its own signature if it has none.
    function _identify(uint256 artistId, Join calldata j) private {
        IArtistRegistry accounts = IArtistRegistry(address(_accounts()));
        address root = address(uint160(artistId));
        if (accounts.artistIdOf(root) != artistId) {
            accounts.registerFederated(
                root, j.profileId, j.profileDocHash, j.deadline, j.registration
            );
        }
    }

    /// @dev Reverts unless `token` is a listed 1/1 contract and the caller a wallet of its
    ///      artist's account.
    function _requireTokenArtist(address token) private view {
        Listing memory l = listingOf(token);
        if (
            l.status == Status.NONE || l.form != Form.ERC721
                || !_accounts().isWallet(l.artistId, msg.sender)
        ) revert NotArtist(token, msg.sender);
    }

    /// @dev Whether a listing is ACTIVE and its account not delisted.
    function _listedActive(Listing memory l) private view returns (bool) {
        return l.status == Status.ACTIVE && !isAccountDelisted(l.artistId);
    }

    /// @dev Whether a listing may take new works: listed active and its version approved.
    function _mintable(Listing memory l) private view returns (bool) {
        return _listedActive(l) && templateOf(l.deployer).status == TemplateStatus.APPROVED;
    }

    /// @dev Whether `tokenId` of `token` exists now (`ownerOf` answers).
    function _isLive(address token, uint256 tokenId) private view returns (bool live) {
        (live,) = token.staticcall(abi.encodeCall(IERC721.ownerOf, (tokenId)));
    }

    /// @dev The accounts module the directory names now.
    function _accounts() private view returns (IAccounts) {
        return IAccounts(IModuleSlots(directory).moduleOf(Slots.ACCOUNTS));
    }

    /// @dev The listing of `token`, copied here from the predecessor first if needed.
    function _ownListing(address token) private returns (Listing storage l) {
        l = _listings[token];
        if (l.status == Status.NONE) _listings[token] = listingOf(token);
    }

    /// @dev The template of `deployer`, copied here from the predecessor first if needed.
    function _ownTemplate(address deployer) private returns (Template storage t) {
        t = _templates[deployer];
        if (t.status == TemplateStatus.NONE) _templates[deployer] = templateOf(deployer);
    }

    function _move(address deployer, TemplateStatus from, TemplateStatus to) private {
        TemplateStatus current = templateOf(deployer).status;
        if (current != from) revert TemplateStatusInvalid(deployer, current);
        _ownTemplate(deployer).status = to;
        _emitTemplate(deployer);
    }

    function _emitTemplate(address deployer) private {
        Template storage t = _templates[deployer];
        emit TemplateSet(
            deployer, IFederatedDeployer(deployer).creationHash(), t.version, t.form, t.status
        );
    }

    /// @dev The block time as stored (48 bits last for millions of years).
    function _now() private view returns (uint48) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(block.timestamp);
    }
}
