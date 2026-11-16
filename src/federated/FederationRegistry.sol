// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IFederatedStream } from "../interfaces/IFederatedStream.sol";
import { IFederatedToken } from "../interfaces/IFederatedToken.sol";
import { IFederationRegistry } from "../interfaces/IFederationRegistry.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { PRODUCT_FEDERATED, ProductEconomics } from "../interfaces/types/EconomicsTypes.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { SSTORE2 } from "../libraries/SSTORE2.sol";

/// @title FederationRegistry
/// @notice The replaceable, governed admission layer of 6529 Stream Federated (ADR 0008;
///         FED-41 to FED-52 in `docs/spec/federation.md`): the table of reviewed template code
///         hashes, the sale adapters admitted for new federated works, permissionless joining,
///         and delisting by vote.
/// @dev Holds no entry: an entry is composed on read from the permanent artist registry's
///      directory, the token's locked storage and the template table (`IFederationRegistry`),
///      so a replacement registry inherits every listing at once. It has no authority over any
///      deployed federated token, work or fund: it decides only which code may join, which
///      adapters may mint new works, and a listing's ACTIVE or DELISTED status. A template
///      version is a runtime code hash bound to the creation code that deploys it: a contract
///      joins only if it was created by the deterministic deployment proxy (`DEPLOYER`) from
///      exactly that creation code and the constructor arguments it presents, so its starting
///      storage is the constructor's and nothing else. Once replaced in the artist registry,
///      every read answers as the current registry does, so an adapter that still points here
///      never disagrees with the templates. Roles (genesis configuration): template approval,
///      revocation and adapter admission SUCCESSOR_SETTER (30 days); suspension GUARDIAN
///      (immediate, tightening only); resumption and delisting PARAMETER_SETTER (48 hours,
///      guardian-vetoable).
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
    /// @param creationHash The keccak256 of the creation code (constructor arguments excluded)
    ///        every copy must be deployed from.
    struct Template {
        uint32 version;
        Form form;
        TemplateStatus status;
        bytes32 creationHash;
    }

    /// @notice A template code hash's version, form or status changed.
    /// @param codeHash The template's runtime code hash.
    /// @param creationHash Its creation code's keccak256.
    /// @param version Its version.
    /// @param form Its form.
    /// @param status Its new status.
    event TemplateSet(
        bytes32 indexed codeHash,
        bytes32 creationHash,
        uint32 version,
        Form form,
        TemplateStatus status
    );
    /// @notice A sale adapter was admitted or removed for new federated works.
    /// @param adapter The adapter.
    /// @param admitted Whether it may mint new federated works.
    event AdapterSet(address indexed adapter, bool admitted);
    /// @notice Creation code was published: the data contracts (`SSTORE2`) that hold it, in
    ///         order, whose bytes hash to `creationHash`.
    /// @param creationHash The creation code's keccak256.
    /// @param pointers The data contracts.
    event CodePublished(bytes32 indexed creationHash, address[] pointers);

    /// @notice The transition is not allowed from the template's current status.
    error TemplateStatusInvalid(bytes32 codeHash, TemplateStatus current);

    /// @notice The deterministic deployment proxy (ownerless, keyless, permissionless: it
    ///         CREATE2-deploys `calldata[32:]` with salt `calldata[:32]`), from which every
    ///         federated copy is deployed.
    address public constant DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

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
    mapping(bytes32 creationHash => address[]) private _code;

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

    /// @notice Approves a template version: its runtime code hash, bound to the creation code
    ///         every copy must be deployed from. SUCCESSOR_SETTER (30 days). Once only per code
    ///         hash. Copies join once the creation code is published (`publishCode`).
    /// @param codeHash The runtime code hash of the reviewed template build.
    /// @param creationHash The keccak256 of that build's creation code.
    /// @param version Its version number.
    /// @param form ERC721 or ERC1155.
    function approveTemplate(bytes32 codeHash, bytes32 creationHash, uint32 version, Form form)
        external
        restricted
    {
        Template storage t = _templates[codeHash];
        if (
            t.status != TemplateStatus.NONE || form == Form.PAIR || codeHash == 0
                || creationHash == 0
        ) revert TemplateStatusInvalid(codeHash, t.status);
        (t.version, t.form, t.status, t.creationHash) =
        (version, form, TemplateStatus.APPROVED, creationHash);
        emit TemplateSet(codeHash, creationHash, version, form, TemplateStatus.APPROVED);
    }

    /// @notice Records the data contracts (`SSTORE2` pointers) that hold a creation code, in
    ///         order, under the keccak256 of their bytes. Permissionless: the bytes are read and
    ///         hashed here, so a record is always true; the first one for a hash stays.
    /// @param pointers The data contracts.
    /// @return creationHash The keccak256 of the bytes they hold.
    function publishCode(address[] calldata pointers) external returns (bytes32 creationHash) {
        creationHash = keccak256(_concat(pointers, msg.data[:0]));
        if (_code[creationHash].length == 0 && pointers.length != 0) {
            _code[creationHash] = pointers;
            emit CodePublished(creationHash, pointers);
        }
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
        emit TemplateSet(codeHash, t.creationHash, t.version, t.form, TemplateStatus.REVOKED);
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
    ///      registry records is read there too. Its provenance is recomputed: the CREATE2 address
    ///      of `DEPLOYER`, `j.salt` and the approved creation code followed by `j.config` must be
    ///      the caller. A 1/1 template must name the canonical content store; one with a partner
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
                || !_deployedFrom(token, t.creationHash, j.salt, j.config)
        ) revert NotListable(token);
        if (x.partner != address(0)) _checkPartner(token, t.form, x);
        address account = address(uint160(x.artistId));
        if (artistRegistry.artistIdOf(account) != x.artistId) {
            artistRegistry.registerFederated(
                account, j.profileId, j.profileDocHash, j.deadline, j.registration
            );
        }
        _list(token, t.form, x, j);
        emit Registered(token, x.artistId, token.codehash, j.salt, j.config);
    }

    // ------------------------------------------------------------------ reads

    /// @inheritdoc IFederationRegistry
    /// @dev A contract that left answers no entry: the English auction (`_lockTerms`) and the
    ///      federated edition auction's lens (`feeTerms`) refuse a new sale whose entry's code
    ///      hash is not the token's, so a left contract that admits a shared adapter as its own
    ///      minter still starts no sale there, at the network's fee or any other, while
    ///      `isActive` lets the sales it started before the exit finish.
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
    /// @dev LEFT is an exit from ACTIVE; a contract that left while delisted is LEFT_DELISTED in
    ///      the directory and is not served.
    function isActive(address token) external view returns (bool) {
        IFederationRegistry current = _current();
        if (_forwards(current)) return current.isActive(token);
        (, IArtistRegistry.FederationStatus status) = artistRegistry.federatedListing(token);
        TemplateStatus t = _templates[token.codehash].status;
        return (status == IArtistRegistry.FederationStatus.ACTIVE
                || status == IArtistRegistry.FederationStatus.LEFT)
            && (t == TemplateStatus.APPROVED || t == TemplateStatus.SUSPENDED);
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

    /// @notice A template code hash's version, form and status.
    /// @param codeHash The code hash.
    /// @return The template.
    function templateOf(bytes32 codeHash) external view returns (Template memory) {
        return _templates[codeHash];
    }

    /// @notice The data contracts holding a published creation code, in order.
    /// @param creationHash The creation code's keccak256.
    /// @return The pointers, empty if unpublished.
    function codeOf(bytes32 creationHash) external view returns (address[] memory) {
        return _code[creationHash];
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
            x.artistId,
            token,
            uint8(form),
            x.partner,
            x.feeShare,
            x.feeRecipient,
            j.deadline,
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

    /// @dev Whether `token` is the CREATE2 deployment of `DEPLOYER` with `salt` of the creation
    ///      code published for `creationHash` followed by `config`.
    function _deployedFrom(address token, bytes32 creationHash, bytes32 salt, bytes calldata config)
        private
        view
        returns (bool)
    {
        address[] memory pointers = _code[creationHash];
        if (pointers.length == 0) return false;
        bytes32 init = keccak256(_concat(pointers, config));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DEPLOYER, salt, init))))
        ) == token;
    }

    /// @dev The bytes behind `pointers`, in order, followed by `tail`.
    function _concat(address[] memory pointers, bytes calldata tail)
        private
        view
        returns (bytes memory out)
    {
        uint256 total;
        for (uint256 i; i < pointers.length; ++i) {
            total += SSTORE2.size(pointers[i]);
        }
        out = new bytes(total + tail.length);
        uint256 done;
        for (uint256 i; i < pointers.length; ++i) {
            done += SSTORE2.copyInto(pointers[i], out, done);
        }
        assembly ("memory-safe") {
            calldatacopy(add(add(out, 0x20), total), tail.offset, tail.length)
        }
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
        emit TemplateSet(codeHash, t.creationHash, t.version, t.form, to);
    }
}
