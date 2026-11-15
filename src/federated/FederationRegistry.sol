// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IFederatedToken } from "../interfaces/IFederatedToken.sol";
import { IFederationRegistry } from "../interfaces/IFederationRegistry.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { PRODUCT_FEDERATED, ProductEconomics } from "../interfaces/types/EconomicsTypes.sol";
import { Dependency } from "../libraries/Dependency.sol";

/// @title FederationRegistry
/// @notice The replaceable, governed admission layer of 6529 Stream Federated (ADR 0008;
///         FED-41 to FED-52 in `docs/spec/federation.md`): the table of reviewed template code
///         hashes, the sale adapters admitted for new federated works, permissionless joining,
///         and delisting by vote.
/// @dev Holds no entry: an entry is composed on read from the permanent artist registry's
///      directory, the token's locked storage and the template table (`IFederationRegistry`),
///      so a replacement registry inherits every listing at once. It has no authority over any
///      deployed federated token, work or fund: it decides only which code may join, which
///      adapters may mint new works, and a listing's ACTIVE or DELISTED status. Roles (genesis
///      configuration): template approval, revocation and adapter admission SUCCESSOR_SETTER (30
///      days); suspension GUARDIAN (immediate, tightening only); resumption and delisting
///      PARAMETER_SETTER (48 hours, guardian-vetoable).
contract FederationRegistry is IFederationRegistry, AccessManaged {
    /// @notice A template code hash's status. REVOKED is terminal.
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
    struct Template {
        uint32 version;
        Form form;
        TemplateStatus status;
    }

    /// @notice A template code hash's version, form or status changed.
    event TemplateSet(bytes32 indexed codeHash, uint32 version, Form form, TemplateStatus status);
    /// @notice A sale adapter was admitted or removed for new federated works.
    event AdapterSet(address indexed adapter, bool admitted);

    /// @notice The transition is not allowed from the template's current status.
    error TemplateStatusInvalid(bytes32 codeHash, TemplateStatus current);

    /// @notice The canonical artist registry, the permanent directory this registry writes.
    IArtistRegistry public immutable artistRegistry;
    /// @notice The economics resolver whose `PRODUCT_FEDERATED` share and recipient a contract
    ///         must lock to join.
    IEconomicsResolver public immutable economics;
    /// @notice The canonical split ledger every template must name.
    address public immutable splitLedger;

    mapping(bytes32 codeHash => Template) private _templates;
    mapping(address adapter => bool) private _adapters;

    /// @param authority_ The AccessManager.
    /// @param artistRegistry_ The artist registry (ERC-165 `IArtistRegistry`).
    /// @param economics_ The economics resolver (ERC-165 `IEconomicsResolver`); its split factory
    ///        is the split ledger.
    constructor(address authority_, address artistRegistry_, address economics_)
        AccessManaged(authority_)
    {
        Dependency.check(artistRegistry_, type(IArtistRegistry).interfaceId);
        Dependency.check(economics_, type(IEconomicsResolver).interfaceId);
        artistRegistry = IArtistRegistry(artistRegistry_);
        economics = IEconomicsResolver(economics_);
        splitLedger = IEconomicsResolver(economics_).splitFactory();
    }

    // ------------------------------------------------------------------ governance

    /// @notice Approves a template version's runtime code hash. SUCCESSOR_SETTER (30 days).
    ///         Once only per code hash.
    /// @param codeHash The runtime code hash of the reviewed template build.
    /// @param version Its version number.
    /// @param form ERC721 or ERC1155.
    function approveTemplate(bytes32 codeHash, uint32 version, Form form) external restricted {
        Template storage t = _templates[codeHash];
        if (t.status != TemplateStatus.NONE || form == Form.PAIR || codeHash == 0) {
            revert TemplateStatusInvalid(codeHash, t.status);
        }
        (t.version, t.form, t.status) = (version, form, TemplateStatus.APPROVED);
        emit TemplateSet(codeHash, version, form, TemplateStatus.APPROVED);
    }

    /// @notice Suspends an approved template version: no contract of it joins or mints a new work;
    ///         running sales finish. GUARDIAN (immediate).
    /// @param codeHash The template code hash.
    function suspendTemplate(bytes32 codeHash) external restricted {
        _move(codeHash, TemplateStatus.APPROVED, TemplateStatus.SUSPENDED);
    }

    /// @notice Lifts a suspension. PARAMETER_SETTER (48 hours).
    /// @param codeHash The template code hash.
    function resumeTemplate(bytes32 codeHash) external restricted {
        _move(codeHash, TemplateStatus.SUSPENDED, TemplateStatus.APPROVED);
    }

    /// @notice Revokes a template version for good: its contracts are no longer served, and
    ///         their running sales end unsold with refunds. SUCCESSOR_SETTER (30 days).
    /// @param codeHash The template code hash.
    function revokeTemplate(bytes32 codeHash) external restricted {
        Template storage t = _templates[codeHash];
        TemplateStatus current = t.status;
        if (current != TemplateStatus.APPROVED && current != TemplateStatus.SUSPENDED) {
            revert TemplateStatusInvalid(codeHash, current);
        }
        t.status = TemplateStatus.REVOKED;
        emit TemplateSet(codeHash, t.version, t.form, TemplateStatus.REVOKED);
    }

    /// @notice Admits or removes a sale adapter for new federated works (ERC-165 `ISaleAdapter`,
    ///         not EIP-7702 delegated). SUCCESSOR_SETTER (30 days). Removal stops new works only:
    ///         an adapter settles and burns the tokens it minted whatever this says.
    /// @param adapter The sale adapter.
    /// @param admitted Whether it may mint new federated works.
    function setAdapter(address adapter, bool admitted) external restricted {
        if (admitted) Dependency.check(adapter, type(ISaleAdapter).interfaceId);
        _adapters[adapter] = admitted;
        emit AdapterSet(adapter, admitted);
    }

    /// @notice Sets listed contracts ACTIVE or DELISTED after a vote, in batches of the caller's
    ///         size (the artist registry refuses an unlisted or LEFT contract and any other
    ///         status). PARAMETER_SETTER (48 hours). A delisting never touches tokens, ownership,
    ///         records or funds; it stops new sales, and running sales end unsold with refunds.
    /// @param tokens The federated contracts.
    /// @param status ACTIVE or DELISTED.
    /// @param voteRef A reference to the vote, recorded in the artist registry's event.
    function setStatus(address[] calldata tokens, Status status, bytes32 voteRef)
        external
        restricted
    {
        for (uint256 i; i < tokens.length; ++i) {
            artistRegistry.setFederatedStatus(
                tokens[i], IArtistRegistry.FederationStatus(uint8(status)), voteRef
            );
        }
    }

    /// @notice Records in the artist registry's directory that contracts of a revoked template
    ///         are delisted (reference: the code hash). Permissionless, in batches of the
    ///         caller's size; skips every contract that is not ACTIVE or not of a revoked
    ///         template.
    /// @param tokens The federated contracts.
    function propagateRevocation(address[] calldata tokens) external {
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
    ///      registry records is read there too.
    function register(
        bytes32 profileId,
        bytes32 profileDocHash,
        uint64 deadline,
        bytes calldata signature
    ) external {
        address token = msg.sender;
        Template memory t = _templates[token.codehash];
        (,, uint256 artistId, uint32 feeShare, address feeRecipient, address partner) =
            _terms(token);
        ProductEconomics memory e = economics.economics(PRODUCT_FEDERATED);
        if (
            t.status != TemplateStatus.APPROVED || feeShare != e.feeShare
                || feeRecipient != e.feeRecipient
                || (t.form == Form.ERC1155 && partner == address(0))
        ) revert NotListable(token);
        if (partner != address(0)) {
            Template memory p = _templates[partner.codehash];
            (,, uint256 pArtist, uint32 pShare, address pRecipient, address pPartner) =
                _terms(partner);
            if (
                p.status != TemplateStatus.APPROVED || p.form == t.form || pArtist != artistId
                    || pShare != feeShare || pRecipient != feeRecipient || pPartner != token
            ) revert NotListable(token);
        }
        address account = address(uint160(artistId));
        if (artistRegistry.artistIdOf(account) != artistId) {
            artistRegistry.registerFederated(
                account, profileId, profileDocHash, deadline, signature
            );
        }
        artistRegistry.listFederatedContract(
            artistId, token, uint8(t.form), partner, feeShare, feeRecipient
        );
        emit Registered(token, artistId, token.codehash);
    }

    // ------------------------------------------------------------------ reads

    /// @inheritdoc IFederationRegistry
    function entry(address token) external view returns (Entry memory e) {
        (uint256 artistId, IArtistRegistry.FederationStatus status) =
            artistRegistry.federatedListing(token);
        bytes32 codeHash = token.codehash;
        Template memory t = _templates[codeHash];
        if (status == IArtistRegistry.FederationStatus.NONE || t.status == TemplateStatus.NONE) {
            return e;
        }
        (,,, uint32 feeShare,, address partner) = IFederatedToken(token).federationTerms();
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
        (, IArtistRegistry.FederationStatus status) = artistRegistry.federatedListing(token);
        TemplateStatus t = _templates[token.codehash].status;
        return (status == IArtistRegistry.FederationStatus.ACTIVE
                || status == IArtistRegistry.FederationStatus.LEFT)
            && (t == TemplateStatus.APPROVED || t == TemplateStatus.SUSPENDED);
    }

    /// @inheritdoc IFederationRegistry
    function canMint(address token, address adapter) external view returns (bool) {
        if (!_adapters[adapter] || _templates[token.codehash].status != TemplateStatus.APPROVED) {
            return false;
        }
        (, IArtistRegistry.FederationStatus status) = artistRegistry.federatedListing(token);
        return status == IArtistRegistry.FederationStatus.ACTIVE;
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

    /// @dev A token's locked terms, required to name this deployment's artist registry and split
    ///      ledger (`NotListable`).
    function _terms(address token)
        private
        view
        returns (address, address, uint256, uint32, address, address)
    {
        (
            address ar,
            address ledger,
            uint256 artistId,
            uint32 feeShare,
            address feeRecipient,
            address partner
        ) = IFederatedToken(token).federationTerms();
        if (ar != address(artistRegistry) || ledger != splitLedger) revert NotListable(token);
        return (ar, ledger, artistId, feeShare, feeRecipient, partner);
    }

    function _move(bytes32 codeHash, TemplateStatus from, TemplateStatus to) private {
        Template storage t = _templates[codeHash];
        if (t.status != from) revert TemplateStatusInvalid(codeHash, t.status);
        t.status = to;
        emit TemplateSet(codeHash, t.version, t.form, to);
    }
}
