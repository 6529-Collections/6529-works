// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IAccounts } from "../interfaces/IAccounts.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IFederatedDeployer } from "../interfaces/IFederatedDeployer.sol";
import { IFederatedStream } from "../interfaces/IFederatedStream.sol";
import { IFederatedToken } from "../interfaces/IFederatedToken.sol";
import { IFederationRegistry } from "../interfaces/IFederationRegistry.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IStream } from "../interfaces/IStream.sol";
import { PRODUCT_FEDERATED, ProductEconomics } from "../interfaces/types/EconomicsTypes.sol";
import { Dependency } from "../libraries/Dependency.sol";

/// @title FederationRegistry
/// @notice The replaceable, governed admission layer of 6529 Stream Federated (ADR 0008;
///         FED-41 to FED-52 in `docs/spec/federation.md`): the table of reviewed template code
///         hashes, the sale adapters admitted for new federated works, permissionless joining,
///         and delisting by the network.
/// @dev Holds no entry: an entry is composed on read from the permanent artist registry's
///      directory, the token's locked storage and the template table (`IFederationRegistry`),
///      so a replacement registry inherits every listing at once. It has no authority over any
///      deployed federated token, work or fund: it decides only which code may join, which
///      adapters may mint new works and open new sales, and a listing's ACTIVE or DELISTED
///      status. A template
///      version is a runtime code hash bound to its deployer (`FederatedDeployer`), the
///      ownerless contract that deploys that version's creation code: a contract joins only if
///      that deployer recorded it, so its starting storage is the constructor's and nothing
///      else. Once replaced in the artist registry,
///      every read answers as the current registry does, so an adapter that still points here
///      never disagrees with the templates. Every governed function is the network's; the
///      genesis role map sets each one's delay (template approval, suspension, resumption,
///      revocation and reinstatement, and delisting: 24 hours).
contract FederationRegistry is IFederationRegistry, AccessManaged {
    /// @notice A template code hash's status. The network can reinstate a REVOKED one.
    enum TemplateStatus {
        NONE,
        APPROVED,
        SUSPENDED,
        REVOKED
    }

    /// @notice A reviewed template version.
    /// @param version Its version number.
    /// @param form Its form (ERC721 or ERC1155).
    /// @param status Its status.
    /// @param deployer The ownerless deployer that alone creates copies of it
    ///        (`IFederatedDeployer`).
    struct Template {
        uint32 version;
        Form form;
        TemplateStatus status;
        address deployer;
    }

    /// @notice A template code hash's version, form or status changed.
    /// @param codeHash The template's runtime code hash.
    /// @param deployer Its deployer (`CreationCodeStored` there names the creation code).
    /// @param creationHash The keccak256 of the creation code the deployer deploys.
    /// @param version Its version.
    /// @param form Its form.
    /// @param status Its new status.
    event TemplateSet(
        bytes32 indexed codeHash,
        address deployer,
        bytes32 creationHash,
        uint32 version,
        Form form,
        TemplateStatus status
    );
    /// @notice A sale adapter was admitted or removed for new federated works.
    /// @param adapter The adapter.
    /// @param admitted Whether it may mint new federated works.
    event AdapterSet(address indexed adapter, bool admitted);

    /// @notice The transition is not allowed from the template's current status.
    error TemplateStatusInvalid(bytes32 codeHash, TemplateStatus current);
    /// @notice A batch longer than `MAX_BATCH`.
    error BatchTooLarge(uint256 length);

    /// @notice The most contracts one `setStatus` or `propagateRevocation` call takes: a safety
    ///         bound against unbounded work, not a policy number. The worst element (a cold
    ///         listed contract written to DELISTED) measures under 20,000 gas
    ///         (`FederationBatch.t.sol`), so 256 of them stay under 5.2M, a third of EIP-7825's
    ///         2^24 transaction cap, and a governed batch scheduled at the bound always executes;
    ///         a longer list is split into calls of the caller's size.
    uint256 public constant MAX_BATCH = 256;

    /// @notice The canonical artist registry, the permanent directory this registry writes.
    IArtistRegistry public immutable artistRegistry;
    /// @notice The economics resolver whose `PRODUCT_FEDERATED` share and recipient a contract
    ///         must lock to join.
    IEconomicsResolver public immutable economics;
    /// @notice The canonical split ledger every template must name.
    address public immutable splitLedger;
    /// @notice The canonical content store every 1/1 template must name.
    address public immutable contentStore;

    mapping(bytes32 codeHash => Template) private _templates;
    mapping(address adapter => bool) private _adapters;

    /// @param authority_ The AccessManager.
    /// @param artistRegistry_ The artist registry (ERC-165 `IArtistRegistry`).
    /// @param economics_ The economics resolver (ERC-165 `IEconomicsResolver`); its split factory
    ///        is the split ledger.
    /// @param contentStore_ The canonical content store.
    constructor(
        address authority_,
        address artistRegistry_,
        address economics_,
        address contentStore_
    ) AccessManaged(authority_) {
        Dependency.check(artistRegistry_, type(IArtistRegistry).interfaceId);
        Dependency.check(economics_, type(IEconomicsResolver).interfaceId);
        Dependency.check(contentStore_);
        artistRegistry = IArtistRegistry(artistRegistry_);
        economics = IEconomicsResolver(economics_);
        splitLedger = IEconomicsResolver(economics_).splitFactory();
        contentStore = contentStore_;
    }

    // ------------------------------------------------------------------ governance

    /// @notice Approves a template version: its runtime code hash, bound to the ownerless
    ///         deployer that alone creates its copies. The network. Once only per code hash. Review: the deployer's code hash is the reviewed `FederatedDeployer`
    ///         build and its creation code is the template's (`VerifyV1.checkTemplate`).
    /// @param codeHash The runtime code hash of the reviewed template build.
    /// @param deployer Its `FederatedDeployer` (code, not EIP-7702 delegated).
    /// @param version Its version number.
    /// @param form ERC721 or ERC1155.
    function approveTemplate(bytes32 codeHash, address deployer, uint32 version, Form form)
        external
        restricted
    {
        Template storage t = _templates[codeHash];
        if (t.status != TemplateStatus.NONE || form == Form.PAIR || codeHash == 0) {
            revert TemplateStatusInvalid(codeHash, t.status);
        }
        Dependency.check(deployer);
        (t.version, t.form, t.status, t.deployer) =
        (version, form, TemplateStatus.APPROVED, deployer);
        _emitTemplate(codeHash, t);
    }

    /// @notice Suspends an approved template version: no contract of it joins, mints a new work
    ///         or opens a new sale (each asks `canMint`); running sales finish. The network.
    /// @param codeHash The template code hash.
    function suspendTemplate(bytes32 codeHash) external restricted {
        _move(codeHash, TemplateStatus.APPROVED, TemplateStatus.SUSPENDED);
    }

    /// @notice Lifts a suspension. The network.
    /// @param codeHash The template code hash.
    function resumeTemplate(bytes32 codeHash) external restricted {
        _move(codeHash, TemplateStatus.SUSPENDED, TemplateStatus.APPROVED);
    }

    /// @notice Revokes a template version: its contracts are no longer served, and their running
    ///         sales end unsold with refunds. The network, which can reverse it
    ///         (`reinstateTemplate`).
    /// @param codeHash The template code hash.
    function revokeTemplate(bytes32 codeHash) external restricted {
        Template storage t = _templates[codeHash];
        TemplateStatus current = t.status;
        if (current != TemplateStatus.APPROVED && current != TemplateStatus.SUSPENDED) {
            revert TemplateStatusInvalid(codeHash, current);
        }
        t.status = TemplateStatus.REVOKED;
        _emitTemplate(codeHash, t);
    }

    /// @inheritdoc IFederationRegistry
    /// @dev REVOKED to APPROVED. Listings `propagateRevocation` wrote DELISTED stay so until the
    ///      network relists them (`setStatus`).
    function reinstateTemplate(bytes32 codeHash) external restricted {
        _move(codeHash, TemplateStatus.REVOKED, TemplateStatus.APPROVED);
    }

    /// @notice Admits or removes a sale adapter for new federated works (ERC-165 `ISaleAdapter`,
    ///         not EIP-7702 delegated). The network. Removal stops new works only:
    ///         an adapter settles and burns the tokens it minted whatever this says.
    /// @param adapter The sale adapter.
    /// @param admitted Whether it may mint new federated works.
    function setAdapter(address adapter, bool admitted) external restricted {
        if (admitted) Dependency.check(adapter, type(ISaleAdapter).interfaceId);
        _adapters[adapter] = admitted;
        emit AdapterSet(adapter, admitted);
    }

    /// @notice Sets listed contracts ACTIVE or DELISTED, in batches of the caller's size. The
    ///         network. An unlisted contract is skipped, never reverting the batch. A delisting
    ///         never touches tokens, ownership, records or funds; it stops new works and sales,
    ///         and running sales end unsold with refunds.
    /// @param tokens The federated contracts.
    /// @param status ACTIVE or DELISTED.
    /// @param voteRef A reference to the decision, recorded in the artist registry's event.
    function setStatus(address[] calldata tokens, Status status, bytes32 voteRef)
        external
        restricted
    {
        if (tokens.length > MAX_BATCH) revert BatchTooLarge(tokens.length);
        IArtistRegistry.FederationStatus next = IArtistRegistry.FederationStatus(uint8(status));
        for (uint256 i; i < tokens.length; ++i) {
            (, IArtistRegistry.FederationStatus current) =
                artistRegistry.federatedListing(tokens[i]);
            if (current != IArtistRegistry.FederationStatus.NONE) {
                artistRegistry.setFederatedStatus(tokens[i], next, voteRef);
            }
        }
    }

    /// @notice Records in the artist registry's directory that contracts of a revoked template
    ///         are delisted (reference: the code hash). Permissionless, in batches of the
    ///         caller's size; skips every contract that is not ACTIVE or not of a revoked
    ///         template.
    /// @param tokens The federated contracts.
    function propagateRevocation(address[] calldata tokens) external {
        if (tokens.length > MAX_BATCH) revert BatchTooLarge(tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            bytes32 codeHash = token.codehash;
            (, IArtistRegistry.FederationStatus status) = artistRegistry.federatedListing(token);
            if (
                _templates[codeHash].status == TemplateStatus.REVOKED
                    && status == IArtistRegistry.FederationStatus.ACTIVE
            ) {
                artistRegistry.setFederatedStatus(
                    token, IArtistRegistry.FederationStatus.DELISTED, codeHash
                );
            }
        }
    }

    // ------------------------------------------------------------------ joining

    /// @inheritdoc IFederationRegistry
    /// @dev The caller is the token: a genuine template whose code checked the artist's authority
    ///      before calling. Its terms are read from its own storage, and the code hash the artist
    ///      registry records is read there too. Its provenance: the version's approved deployer
    ///      recorded it. A 1/1 template must name the canonical content store; one with a partner
    ///      joins after it, so a listed 1/1 contract's editions are always a listed contract.
    function register(Join calldata j) external {
        address token = msg.sender;
        Template memory t = _templates[token.codehash];
        Terms memory x = _terms(token);
        ProductEconomics memory e = economics.economics(PRODUCT_FEDERATED);
        if (
            t.status != TemplateStatus.APPROVED || x.feeShare != e.feeShare
                || x.feeRecipient != e.feeRecipient
                || (t.form == Form.ERC1155
                        ? x.partner == address(0)
                        : IFederatedStream(token).contentStore() != contentStore)
                || !IFederatedDeployer(t.deployer).deployed(token)
        ) revert NotListable(token);
        if (x.partner != address(0)) _checkPartner(token, t.form, x);
        address account = address(uint160(x.artistId));
        if (artistRegistry.artistIdOf(account) != x.artistId) {
            artistRegistry.registerFederated(
                account, j.profileId, j.profileDocHash, j.deadline, j.registration
            );
        }
        _list(token, t.form, x, j);
        emit Registered(token, x.artistId, token.codehash, t.deployer);
    }

    // ------------------------------------------------------------------ reads

    /// @inheritdoc IFederationRegistry
    /// @dev The share is the smaller of the token's deployed share and the artist registry's
    ///      record (`IAccounts.federatedFeeShare`, which the network can only lower), as the
    ///      token itself computes it, so the adapters charge the share in force.
    function entry(address token) external view returns (Entry memory e) {
        IFederationRegistry current = _current();
        if (_forwards(current)) return current.entry(token);
        (uint256 artistId, IArtistRegistry.FederationStatus status) =
            artistRegistry.federatedListing(token);
        bytes32 codeHash = token.codehash;
        Template storage t = _templates[codeHash];
        if (
            (status != IArtistRegistry.FederationStatus.ACTIVE
                    && status != IArtistRegistry.FederationStatus.DELISTED)
                || t.status == TemplateStatus.NONE
        ) return e;
        (,,, uint32 feeShare,, address partner) = IFederatedToken(token).federationTerms();
        uint32 recorded = IAccounts(address(artistRegistry)).federatedFeeShare(token);
        if (recorded < feeShare) feeShare = recorded;
        e = Entry(
            t.form,
            partner,
            artistId,
            t.version,
            codeHash,
            feeShare,
            status == IArtistRegistry.FederationStatus.DELISTED ? Status.DELISTED : Status.ACTIVE
        );
    }

    /// @inheritdoc IFederationRegistry
    function isActive(address token) external view returns (bool) {
        IFederationRegistry current = _current();
        if (_forwards(current)) return current.isActive(token);
        TemplateStatus t = _templates[token.codehash].status;
        return
            _listedActive(token) && (t == TemplateStatus.APPROVED || t == TemplateStatus.SUSPENDED);
    }

    /// @inheritdoc IFederationRegistry
    /// @dev An editions contract mints only while its partner is listed ACTIVE too.
    function canMint(address token, address adapter) external view returns (bool) {
        IFederationRegistry current = _current();
        if (_forwards(current)) return current.canMint(token, adapter);
        Template storage t = _templates[token.codehash];
        if (!_adapters[adapter] || t.status != TemplateStatus.APPROVED || !_listedActive(token)) {
            return false;
        }
        if (t.form != Form.ERC1155) return true;
        (,,,,, address partner) = IFederatedToken(token).federationTerms();
        return _listedActive(partner);
    }

    /// @inheritdoc IFederationRegistry
    /// @dev 6529 Stream's governed entropy module (`IStream.entropyModule`): the same module
    ///      serves curated and federated works.
    function entropyModule() external view returns (address) {
        return IStream(artistRegistry.stream()).entropyModule();
    }

    /// @notice A template code hash's version, form and status.
    /// @param codeHash The code hash.
    /// @return The template.
    function templateOf(bytes32 codeHash) external view returns (Template memory) {
        return _templates[codeHash];
    }

    /// @notice Whether a sale adapter may mint new federated works.
    /// @param adapter The adapter.
    /// @return True while admitted.
    function isAdmittedAdapter(address adapter) external view returns (bool) {
        return _adapters[adapter];
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IFederationRegistry).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // ------------------------------------------------------------------ internal

    /// @dev A token's locked terms (`IFederatedToken.federationTerms`).
    struct Terms {
        address artistRegistry;
        address splitLedger;
        uint256 artistId;
        uint32 feeShare;
        address feeRecipient;
        address partner;
    }

    /// @dev A token's locked terms, required to name this deployment's artist registry and split
    ///      ledger (`NotListable`).
    function _terms(address token) private view returns (Terms memory x) {
        (x.artistRegistry, x.splitLedger, x.artistId, x.feeShare, x.feeRecipient, x.partner) =
            IFederatedToken(token).federationTerms();
        if (x.artistRegistry != address(artistRegistry) || x.splitLedger != splitLedger) {
            revert NotListable(token);
        }
    }

    /// @dev Lists `token` with its terms and the artist's consent.
    function _list(address token, Form form, Terms memory x, Join calldata j) private {
        artistRegistry.listFederatedContract(
            IArtistRegistry.FederatedListing(
                x.artistId, token, uint8(form), x.partner, x.feeShare, x.feeRecipient, j.deadline
            ),
            j.consent
        );
    }

    /// @dev Reverts unless `partner`, the other half of `token`'s pair, runs an approved template
    ///      of the other form under the same artist and terms and names `token` back; a 1/1
    ///      template's partner must already be listed ACTIVE under the same artist.
    function _checkPartner(address token, Form form, Terms memory x) private view {
        Template storage p = _templates[x.partner.codehash];
        Terms memory y = _terms(x.partner);
        (uint256 listedAs, IArtistRegistry.FederationStatus status) =
            artistRegistry.federatedListing(x.partner);
        if (
            p.status != TemplateStatus.APPROVED || p.form == form || y.artistId != x.artistId
                || y.feeShare != x.feeShare || y.feeRecipient != x.feeRecipient
                || y.partner != token
                || (form == Form.ERC721
                    && (listedAs != x.artistId
                        || status != IArtistRegistry.FederationStatus.ACTIVE))
        ) revert NotListable(token);
    }

    /// @dev Whether the directory lists `token` ACTIVE.
    function _listedActive(address token) private view returns (bool) {
        (, IArtistRegistry.FederationStatus status) = artistRegistry.federatedListing(token);
        return status == IArtistRegistry.FederationStatus.ACTIVE;
    }

    /// @dev The registry the artist registry names now (this one before the bind).
    function _current() private view returns (IFederationRegistry) {
        address current = artistRegistry.federationRegistry();
        return IFederationRegistry(current == address(0) ? address(this) : current);
    }

    /// @dev Whether a read is answered by `current` rather than here: once replaced, unless the
    ///      current registry itself asks (one that consults this one gets this one's own answer,
    ///      so forwarding never loops).
    function _forwards(IFederationRegistry current) private view returns (bool) {
        return address(current) != address(this) && msg.sender != address(current);
    }

    function _move(bytes32 codeHash, TemplateStatus from, TemplateStatus to) private {
        Template storage t = _templates[codeHash];
        if (t.status != from) revert TemplateStatusInvalid(codeHash, t.status);
        t.status = to;
        _emitTemplate(codeHash, t);
    }

    function _emitTemplate(bytes32 codeHash, Template storage t) private {
        address deployer = t.deployer;
        emit TemplateSet(
            codeHash,
            deployer,
            IFederatedDeployer(deployer).creationHash(),
            t.version,
            t.form,
            t.status
        );
    }
}
