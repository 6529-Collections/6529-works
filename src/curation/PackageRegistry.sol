// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IEntropyModule } from "../interfaces/IEntropyModule.sol";
import { ICurationVerifier } from "../interfaces/ICurationVerifier.sol";
import { IMintPolicy } from "../interfaces/IMintPolicy.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { IStream } from "../interfaces/IStream.sol";
import { ISplitFactory } from "../economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "../economics/interfaces/ISplitWallet.sol";
import { Splits } from "../economics/Splits.sol";
import { PRODUCT_STREAM, ProductEconomics } from "../interfaces/types/EconomicsTypes.sol";
import { ArtistIdentity } from "../interfaces/types/IdentityTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import {
    EditionTerms,
    ItemKind,
    MoveAuthorization,
    PackageItem,
    Party,
    PartyAcceptance,
    PartyRole,
    SeedPolicy,
    StreamMintRequest
} from "../interfaces/types/PackageTypes.sol";
import { PrimaryTerms } from "../interfaces/types/SaleTypes.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { EditionRules } from "../editions/EditionRules.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";
import { SpdxId } from "../stream/SpdxId.sol";

/// @title PackageRegistry
/// @notice Approved package roots, party consent, single-use items, per-product content
///         uniqueness and the lead artist's revocable "move to Stream" (ADR 0001 section 3).
/// @dev Gas (the auction start's budget: 350K Prague gas, ADR 0004). A mint consumes an item
///      without an event of its own: Stream's permanent `WorkMinted` carries the package root,
///      item hash, lead artist and content hash. The consume writes one fresh slot, 6529 Stream's `contentHash => itemHash`, which is both the consume-once record and
///      the uniqueness record. It reads consent from `acceptedAs[root][account]`, and its only
///      external call is the lead's active authority. Move nonces live in a per-artist bitmap of
///      255 nonces per word whose top bit is a sentinel: the acceptance that creates an identity
///      writes the sentinel into word 0, so an artist's first 255 starts update a nonzero slot
///      instead of creating one. Tools should therefore use each artist's nonces sequentially from
///      0.
///
///      Replay protection never looks at signature bytes (a 65-byte signature and its 64-byte
///      ERC-2098 form both verify): a move spends a per-artist nonce, an item is single-use
///      through its content hash, and an acceptance is recorded once per (root, account).
///
///      Uniqueness keys on the item's declared `contentHash` (the decoded SHA-256 of its primary
///      media), never on a file ID. It is defense in depth: the curation signer verifies every
///      declared SHA-256 against the decoded bytes before attesting, and the evidence hash covers
///      that check. The one cross-product reuse, the linked pair, is decided by Editions from
///      Stream's permanent record (an edition is created only for the item Stream recorded as
///      consuming its content); this registry plays no part in it.
///      When an upheld dispute burns a work during its auction, the governed
///      `IStream.releaseContent` passes on the rightful artist the dispute outcome names: the
///      content hash is reserved for that artist, so only an item whose lead artist it is may
///      consume it, and the burned item is tombstoned so it can never be consumed again,
///      through any root. The reservation is checked only on a released slot, so a fresh
///      consume pays nothing for it.
///
///      Approvals are per root, not per item: revoking a root stops only that root, so an item
///      also listed in another approved root stays consumable there; the guardian revokes every
///      root that lists it. Disabling a curation signer stops only future registrations.
///
///      Callers: `authorize` trusts only the bound Stream; the Editions binding is kept for the
///      genesis wiring and is informational. Each slot is bound once, independently, by the genesis
///      configurator (which holds ADMIN with no delay until it renounces ADMIN); no bound call
///      goes through the AccessManager.
contract PackageRegistry is IPackageRegistry, IMintPolicy, AccessManaged, EIP712 {
    /// @dev Move nonces per bitmap word; bit 255 of every written word is the sentinel.
    uint256 private constant NONCES_PER_WORD = 255;
    uint256 private constant SENTINEL = 1 << 255;
    /// @dev Binding names (`Bound`, `AlreadyBound`).
    bytes32 private constant STREAM = "STREAM";
    bytes32 private constant EDITIONS = "EDITIONS";

    struct Package {
        PackageStatus status;
        address signer;
        bytes32 evidenceHash;
    }

    IArtistRegistry private immutable _artists;

    /// @inheritdoc IPackageRegistry
    ICurationVerifier public verifier;
    /// @inheritdoc IPackageRegistry
    address public stream;
    /// @inheritdoc IPackageRegistry
    address public editions;
    /// @dev The verifier's pinned code hash, checked again at every registration, not only at
    ///      install.
    bytes32 private _verifierCodeHash;

    mapping(bytes32 root => Package) private _packages;
    mapping(bytes32 root => mapping(address account => uint256 artistId)) private _acceptedAs;
    mapping(uint256 artistId => mapping(uint256 word => uint256 bits)) private _moveNonces;
    /// @dev Verifiers replaced by `setVerifier`: never installable again.
    mapping(address verifier => bool) private _retired;

    /// @param authority_ The AccessManager that governs this registry.
    /// @param verifier_ The initial curation verifier.
    /// @param verifierCodeHash The reviewed code hash `verifier_` must have.
    /// @param artistRegistry_ The artist registry (immutable), which must bind this registry as
    ///        its only `register` caller.
    /// @param artistRegistryCodeHash The reviewed code hash `artistRegistry_` must have.
    constructor(
        address authority_,
        ICurationVerifier verifier_,
        bytes32 verifierCodeHash,
        address artistRegistry_,
        bytes32 artistRegistryCodeHash
    )
        AccessManaged(authority_)
        EIP712(Typehashes.PACKAGE_REGISTRY_NAME, Typehashes.DOMAIN_VERSION)
    {
        Dependency.checkPinned(
            artistRegistry_, type(IArtistRegistry).interfaceId, artistRegistryCodeHash
        );
        _artists = IArtistRegistry(artistRegistry_);
        _setVerifier(verifier_, verifierCodeHash);
    }

    /// @inheritdoc IPackageRegistry
    /// @dev Also the only caller of `releaseContent`. Governed (ADMIN by default): the genesis
    ///      configurator binds it before renouncing ADMIN.
    function bindStream(address target) external restricted {
        if (stream != address(0)) revert AlreadyBound(STREAM);
        Dependency.check(target, type(IStream).interfaceId);
        stream = target;
        emit Bound(STREAM, target);
    }

    /// @inheritdoc IPackageRegistry
    /// @dev Independent of Stream, so Editions can be bound whenever it deploys. Governed (ADMIN
    ///      by default): the genesis configurator binds it before renouncing ADMIN.
    function bindEditions(address target) external restricted {
        if (editions != address(0)) revert AlreadyBound(EDITIONS);
        Dependency.check(target, type(IEditions).interfaceId);
        editions = target;
        emit Bound(EDITIONS, target);
    }

    /// @inheritdoc IPackageRegistry
    function registerPackage(bytes32 packageRoot, bytes32 evidenceHash, bytes calldata attestation)
        external
    {
        Package storage p = _packages[packageRoot];
        if (p.status != PackageStatus.NONE) revert PackageExists(packageRoot);
        ICurationVerifier v = verifier;
        Dependency.checkUnchanged(address(v), _verifierCodeHash);
        (bool approved, address signer) = v.isApproved(packageRoot, evidenceHash, attestation);
        if (!approved || evidenceHash == 0) revert NotApproved(packageRoot);
        p.status = PackageStatus.APPROVED;
        p.signer = signer;
        p.evidenceHash = evidenceHash;
        emit PackageRegistered(packageRoot, evidenceHash, address(v), signer);
    }

    /// @inheritdoc IPackageRegistry
    /// @dev Governed: map to GUARDIAN with no delay (a tightening action). Final. A root not yet
    ///      registered may be revoked in advance, and then can never be registered, so a leaked
    ///      attestation can be stopped before anyone submits it. Revocation is per root (see the
    ///      contract notes).
    function revokePackage(bytes32 packageRoot, bytes32 reasonHash) external restricted {
        Package storage p = _packages[packageRoot];
        if (p.status == PackageStatus.REVOKED) revert PackageNotApproved(packageRoot);
        p.status = PackageStatus.REVOKED;
        emit PackageRevoked(packageRoot, reasonHash);
    }

    /// @inheritdoc IPackageRegistry
    /// @dev The root must be approved. The signer is the account itself when it has no artist ID
    ///      yet (the acceptance then creates the identity, artist ID `uint160(account)`, which the
    ///      artist registry counts as its first activity), otherwise the active authority of its
    ///      artist ID, and the profile fields must match the record. A repeat is a no-op. Later
    ///      acceptances are not reported as activity. Because the first acceptance relayed sets
    ///      the identity's profile, an artist's pre-signed acceptances carrying different profile
    ///      fields succeed only in the order the relayer submits them; the others revert with
    ///      `ProfileMismatch` until the artist re-signs or changes the profile.
    function acceptPackage(
        bytes32 packageRoot,
        PartyAcceptance calldata acceptance,
        bytes calldata signature
    ) external returns (uint256 artistId) {
        _requireApproved(packageRoot);
        SignatureVerifier.checkDeadline(acceptance.deadline);
        address account = acceptance.account;
        artistId = _artists.artistIdOf(account);
        address signer = artistId == 0 ? account : _artists.activeAuthorityOf(artistId);
        SignatureVerifier.check(signer, acceptanceDigest(packageRoot, acceptance), signature);
        mapping(address => uint256) storage accepted = _acceptedAs[packageRoot];
        if (accepted[account] != 0) return accepted[account];
        if (artistId != 0) {
            (ArtistIdentity memory identity,) = _artists.artist(artistId);
            if (
                identity.profileId != acceptance.profileId
                    || identity.profileDocHash != acceptance.profileDocHash
            ) revert ProfileMismatch(artistId);
            accepted[account] = artistId;
            emit PackageAccepted(packageRoot, artistId, account);
        } else {
            artistId = uint256(uint160(account));
            accepted[account] = artistId;
            _moveNonces[artistId][0] |= SENTINEL;
            emit PackageAccepted(packageRoot, artistId, account);
            if (
                _artists.register(account, acceptance.profileId, acceptance.profileDocHash)
                    != artistId
            ) revert Dependency.InvalidDependency(address(_artists));
        }
    }

    /// @inheritdoc IMintPolicy
    /// @dev The v1 policy: `request` is `abi.encode(StreamMintRequest)`. Checks the Stream item
    ///      rules (`_checkItem`), consumes the item (`_consume`), checks a VRF item's delivered
    ///      seed at Stream's current entropy module, and quotes the terms from Stream's economics
    ///      resolver and split factory (`_quote`). The lead artist's active authority, which
    ///      signed the move, is the work's creator.
    function authorize(MintContext calldata context, bytes calldata request)
        external
        returns (MintRecord memory r)
    {
        if (msg.sender != stream) revert UnboundCaller(msg.sender);
        StreamMintRequest calldata req = _request(request);
        PackageItem calldata item = req.item;
        _checkItem(item, context.entropyModule);
        address creator;
        (r.itemHash, r.artistId, creator) = _consume(req.packageRoot, item, req.proof, req.move);
        if (
            item.seedPolicy == uint8(SeedPolicy.VRF)
                && !IEntropyModule(context.entropyModule).isDeliveredContent(item.contentHash)
        ) revert SeedNotDelivered(r.itemHash);
        (r.seller, r.feeRecipient, r.feeShare, r.royaltyRate) = _quote(item, context);
        r.creator = creator;
        r.saleKind = item.sale.saleKind;
        r.currency = item.sale.currency;
        r.params = item.sale.params;
        r.collectionId = item.collectionId;
        r.kind = uint8(item.kind);
        r.seedPolicy = uint8(item.seedPolicy);
        r.packageRoot = req.packageRoot;
        r.contentHash = item.contentHash;
        r.mediaHash = item.mediaHash;
        r.recordFileId = item.recordFileId;
    }

    /// @inheritdoc IMintPolicy
    /// @dev Resolves the lead artist through `artistIdOf`, so it reverts while the lead artist
    ///      has no identity. Does not check that the collection exists (Stream does, at mint).
    function preview(MintContext calldata context, bytes calldata request)
        external
        view
        returns (PrimaryTerms memory terms)
    {
        StreamMintRequest calldata req = _request(request);
        _checkItem(req.item, context.entropyModule);
        uint256 artistId = _artists.artistIdOf(req.item.parties[0].account);
        if (artistId == 0) revert InvalidLeadArtist();
        (terms.seller, terms.feeRecipient, terms.feeShare,) = _quote(req.item, context);
        terms.saleKind = req.item.sale.saleKind;
        terms.currency = req.item.sale.currency;
        terms.params = req.item.sale.params;
        terms.creator = _artists.activeAuthorityOf(artistId);
    }

    /// @dev Checks, in order: the caller is the bound Stream; the root is approved; the proof
    ///      places the item; its content hash is unused on Stream; the seed and edition terms;
    ///      every party accepted the root and is a distinct artist; the payee list is canonical
    ///      and covered by the parties; the lead's active authority signed the move, unexpired,
    ///      on an unused nonce. A second consume of the same item, or of an item burned and
    ///      released, reverts with `ContentUsed` naming the item itself. A released content hash
    ///      is consumed only by an item whose lead artist is the release's beneficiary
    ///      (`ContentReserved` otherwise).
    function _consume(
        bytes32 packageRoot,
        PackageItem calldata item,
        bytes32[] calldata proof,
        MoveAuthorization calldata move
    ) private returns (bytes32 itemHash, uint256 artistId, address authority) {
        _requireApproved(packageRoot);
        itemHash = WorksHashing.itemHashCalldata(item);
        if (
            proof.length > Limits.MAX_PROOF_DEPTH
                || !MerkleProof.verifyCalldata(proof, packageRoot, WorksHashing.leaf(itemHash))
        ) revert ItemNotInPackage(packageRoot, itemHash);
        _checkTerms(item, itemHash);
        artistId = _checkParties(packageRoot, item, itemHash);
        authority = _useMove(packageRoot, itemHash, artistId, move);
    }

    /// @inheritdoc IPackageRegistry
    function revokeMove(uint256 artistId, uint256 nonce) external {
        if (_artists.activeAuthorityOf(artistId) != msg.sender) {
            revert NotAuthority(artistId, msg.sender);
        }
        _spendMoveNonce(artistId, nonce);
        emit MoveRevoked(artistId, nonce);
    }

    /// @inheritdoc IPackageRegistry
    /// @dev Governed: map to SUCCESSOR_SETTER (30 days). The replaced verifier is retired: it,
    ///      the current verifier and every verifier retired before revert with
    ///      `Dependency.InvalidDependency`, so a swap back never restores a retired verifier's
    ///      approvals or signer states. One slot per swap. The pinned code hash is checked again
    ///      at every registration (`Dependency.DependencyCodeChanged`).
    function setVerifier(ICurationVerifier expected, ICurationVerifier next, bytes32 nextCodeHash)
        external
        restricted
    {
        if (address(verifier) != address(expected)) revert ExpectedValueMismatch();
        if (address(next) == address(expected) || _retired[address(next)]) {
            revert Dependency.InvalidDependency(address(next));
        }
        _retired[address(expected)] = true;
        _setVerifier(next, nextCodeHash);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IPackageRegistry).interfaceId
            || interfaceId == type(IMintPolicy).interfaceId;
    }

    /// @inheritdoc IPackageRegistry
    function artistRegistry()
        external
        view
        override(IMintPolicy, IPackageRegistry)
        returns (address)
    {
        return address(_artists);
    }

    /// @inheritdoc IPackageRegistry
    function packageOf(bytes32 packageRoot)
        external
        view
        returns (PackageStatus status, bytes32 evidenceHash, address signer)
    {
        Package storage p = _packages[packageRoot];
        return (p.status, p.evidenceHash, p.signer);
    }

    /// @inheritdoc IPackageRegistry
    function acceptedAs(bytes32 packageRoot, address account) external view returns (uint256) {
        return _acceptedAs[packageRoot][account];
    }

    /// @inheritdoc IPackageRegistry
    /// @dev Stream holds content uniqueness (AUC-44); this answers from it.
    function consumedItemOf(bytes32 contentHash) external view returns (bytes32 itemHash) {
        return IStream(stream).consumedItemOf(contentHash);
    }

    /// @notice Whether `itemHash` was burned and released, so it can never be consumed again.
    /// @param itemHash The item hash.
    /// @return True if `releaseContent` tombstoned the item.
    function isReleased(bytes32 itemHash) external view returns (bool) {
        return IStream(stream).isReleased(itemHash);
    }

    /// @inheritdoc IPackageRegistry
    /// @dev Answered from Stream (AUC-44).
    function releasedTo(bytes32 contentHash) external view returns (uint256 artistId) {
        return IStream(stream).releasedTo(contentHash);
    }

    /// @inheritdoc IPackageRegistry
    function isMoveNonceUsed(uint256 artistId, uint256 nonce) external view returns (bool) {
        return _moveNonces[artistId][nonce / NONCES_PER_WORD] & _bit(nonce) != 0;
    }

    /// @notice The EIP-712 digest the lead artist signs to move an item to Stream.
    /// @param packageRoot The package root the item is consumed through.
    /// @param itemHash The item's hash (`WorksHashing.itemHash`).
    /// @param nonce The lead artist's move nonce; any unused `uint256`.
    /// @param deadline The Unix time in seconds after which the signature is expired.
    /// @return The `Typehashes.MOVE_TO_STREAM` digest in this registry's EIP-712 domain.
    function moveDigest(bytes32 packageRoot, bytes32 itemHash, uint256 nonce, uint64 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(Typehashes.MOVE_TO_STREAM, packageRoot, itemHash, nonce, deadline))
        );
    }

    /// @notice The EIP-712 digest a party signs to accept a package root.
    /// @param packageRoot The package root to accept.
    /// @param acceptance The party's account, profile fields and signature deadline.
    /// @return The `Typehashes.PACKAGE_ACCEPTANCE` digest in this registry's EIP-712 domain.
    function acceptanceDigest(bytes32 packageRoot, PartyAcceptance calldata acceptance)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    Typehashes.PACKAGE_ACCEPTANCE,
                    packageRoot,
                    acceptance.account,
                    acceptance.profileId,
                    acceptance.profileDocHash,
                    acceptance.deadline
                )
            )
        );
    }

    /// @dev Views `data` as `abi.encode(StreamMintRequest)` in place. Member offsets are
    ///      bounds-checked by the compiler on access.
    function _request(bytes calldata data) private pure returns (StreamMintRequest calldata req) {
        if (data.length < 160 || uint256(bytes32(data[:32])) != 32) revert InvalidMintRequest();
        assembly ("memory-safe") {
            req := add(data.offset, 32)
        }
    }

    /// @dev Stream rules: a sale kind (whose adapter checks the sale's currency and params), a
    ///      lead party, a coherent seed policy (a VRF item needs Stream's entropy module), and a
    ///      license ID that follows the `SpdxId` rule `WorkRecords` applies at relicense.
    ///      `openRecord` stores the approved record file and license as they are; the media
    ///      commitments it checks are not visible here, so the curation signer's tooling must
    ///      simulate `openRecord` before attesting an item.
    function _checkItem(PackageItem calldata item, address entropy) private pure {
        if (item.sale.saleKind == 0) revert InvalidItemSale();
        if (item.parties.length == 0) revert InvalidLeadArtist();
        // Kinds, seed policies and roles are open `uint8`s in the package types; this policy
        // knows today's values and refuses any other for a new item (a successor may add some).
        uint8 policy = item.seedPolicy;
        if (
            policy > uint8(SeedPolicy.VRF)
                || (policy == uint8(SeedPolicy.ARTIST)) != (item.seed != 0)
                || (policy == uint8(SeedPolicy.VRF) && entropy == address(0))
        ) revert InvalidSeedPolicy();
        if (!SpdxId.isValidCalldata(item.license.spdxId)) revert InvalidLicenseId();
    }

    /// @dev The terms a work of `item` locks now: the seller wallet, the split factory's
    ///      salt-zero wallet for the item's payees (the factory validates the list), and the
    ///      product's economics (one view read). The fee terms must yield a valid royalty payee
    ///      list: a fee share below 100,000 with a fee recipient other than the seller, or no fee
    ///      at all. The adapter resolves `CURRENCY_DEFAULT`, checks the allowlist when it locks
    ///      the currency, and checks the params (the English auction refuses any).
    function _quote(PackageItem calldata item, MintContext calldata context)
        private
        view
        returns (address seller, address feeRecipient, uint32 feeShare, uint32 royaltyRate)
    {
        ProductEconomics memory e = IEconomicsResolver(context.economics).economics(PRODUCT_STREAM);
        seller = ISplitFactory(context.splitFactory).walletFor(item.payees, bytes32(0));
        if (
            e.royaltyRate > Splits.DENOMINATOR || e.feeShare >= Splits.DENOMINATOR
                || (e.feeShare != 0 && (e.feeRecipient == address(0) || e.feeRecipient == seller))
        ) revert InvalidWorkTerms();
        return (seller, e.feeRecipient, e.feeShare, e.royaltyRate);
    }

    function _requireApproved(bytes32 packageRoot) private view {
        if (_packages[packageRoot].status != PackageStatus.APPROVED) {
            revert PackageNotApproved(packageRoot);
        }
    }

    /// @dev Content, seed and edition fields: a nonzero content hash; an artist seed exactly
    ///      under `SeedPolicy.ARTIST`; an ORIGINAL with empty edition terms; an EDITION_MASTER
    ///      with edition terms `EditionRules.isValid` accepts, the same rule 6529 Stream Editions
    ///      applies at `createEdition`, so a master that mints can always get its edition (a
    ///      later revocation of its root does not stop that either).
    function _checkTerms(PackageItem calldata item, bytes32 itemHash) private pure {
        EditionTerms calldata e = item.edition;
        bool bad = item.contentHash == 0
            || (item.seedPolicy == uint8(SeedPolicy.ARTIST)) == (item.seed == 0)
            || item.kind > uint8(ItemKind.EDITION_MASTER);
        if (item.kind == uint8(ItemKind.ORIGINAL)) {
            bad = bad || e.maxCount != 0 || e.currency != address(0) || e.saleKind != 0
                || e.params.length != 0;
        } else {
            bad = bad || !EditionRules.isValid(e);
        }
        if (bad) revert InvalidItem(itemHash);
    }

    /// @dev Every party accepted the root and is a distinct artist; the lead is an ARTIST; the
    ///      payee list is canonical (strictly increasing `(artistId, account)`, exactly one of the
    ///      two set, nonzero shares summing to `Splits.DENOMINATOR`, no more payees than parties)
    ///      and every payee is a party by account or by artist ID. One party may be paid both as
    ///      a fixed and as an artist-resolved payee: the two are distinct canonical keys.
    /// @return leadId The lead artist's ID.
    function _checkParties(bytes32 packageRoot, PackageItem calldata item, bytes32 itemHash)
        private
        view
        returns (uint256 leadId)
    {
        Party[] calldata parties = item.parties;
        ISplitWallet.Payee[] calldata payees = item.payees;
        uint256 n = parties.length;
        if (
            n == 0 || n > Limits.MAX_PARTIES || parties[0].role != uint8(PartyRole.ARTIST)
                || payees.length == 0 || payees.length > n
        ) revert InvalidItem(itemHash);
        mapping(address => uint256) storage accepted = _acceptedAs[packageRoot];
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            if (parties[i].role > uint8(PartyRole.COLLABORATOR)) revert InvalidItem(itemHash);
            uint256 id = accepted[parties[i].account];
            if (id == 0) revert PartyNotAccepted(packageRoot, parties[i].account);
            for (uint256 j; j < i; ++j) {
                if (ids[j] == id) revert InvalidItem(itemHash);
            }
            ids[i] = id;
        }
        uint256 sum = 0;
        for (uint256 i; i < payees.length; ++i) {
            ISplitWallet.Payee calldata p = payees[i];
            bool ordered = i == 0 || p.artistId > payees[i - 1].artistId
                || (p.artistId == payees[i - 1].artistId && p.account > payees[i - 1].account);
            if (
                !ordered || (p.artistId == 0) == (p.account == address(0)) || p.share == 0
                    || !_isParty(parties, ids, p)
            ) revert InvalidItem(itemHash);
            sum += p.share;
        }
        if (sum != Splits.DENOMINATOR) revert InvalidItem(itemHash);
        return ids[0];
    }

    function _isParty(Party[] calldata parties, uint256[] memory ids, ISplitWallet.Payee calldata p)
        private
        pure
        returns (bool)
    {
        for (uint256 j; j < ids.length; ++j) {
            if (p.artistId == 0 ? parties[j].account == p.account : ids[j] == p.artistId) {
                return true;
            }
        }
        return false;
    }

    /// @dev Checks the deadline, spends the nonce and checks the signature of the lead artist's
    ///      active authority (`IArtistRegistry.activeAuthorityOf`).
    /// @dev Returns the active authority that signed the move.
    function _useMove(
        bytes32 packageRoot,
        bytes32 itemHash,
        uint256 artistId,
        MoveAuthorization calldata move
    ) private returns (address authority) {
        SignatureVerifier.checkDeadline(move.deadline);
        _spendMoveNonce(artistId, move.nonce);
        bytes32 digest = moveDigest(packageRoot, itemHash, move.nonce, move.deadline);
        authority = _artists.activeAuthorityOf(artistId);
        SignatureVerifier.check(authority, digest, move.signature);
    }

    function _spendMoveNonce(uint256 artistId, uint256 nonce) private {
        mapping(uint256 => uint256) storage words = _moveNonces[artistId];
        uint256 word = nonce / NONCES_PER_WORD;
        uint256 bits = words[word];
        uint256 bit = _bit(nonce);
        if (bits & bit != 0) revert MoveNonceUsed(artistId, nonce);
        words[word] = bits | bit | SENTINEL;
    }

    function _setVerifier(ICurationVerifier next, bytes32 codeHash) private {
        Dependency.checkPinned(address(next), type(ICurationVerifier).interfaceId, codeHash);
        emit VerifierSet(address(verifier), address(next), codeHash);
        verifier = next;
        _verifierCodeHash = codeHash;
    }

    function _bit(uint256 nonce) private pure returns (uint256) {
        return uint256(1) << (nonce % NONCES_PER_WORD);
    }
}
