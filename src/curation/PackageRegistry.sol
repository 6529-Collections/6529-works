// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { ICurationVerifier } from "../interfaces/ICurationVerifier.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { IStream } from "../interfaces/IStream.sol";
import { ISplitWallet } from "../economics/interfaces/ISplitWallet.sol";
import { Splits } from "../economics/Splits.sol";
import { PRODUCT_EDITIONS, PRODUCT_STREAM } from "../interfaces/types/EconomicsTypes.sol";
import { ArtistIdentity } from "../interfaces/types/IdentityTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import {
    EditionFormat,
    EditionTerms,
    ItemKind,
    MoveAuthorization,
    PackageItem,
    Party,
    PartyAcceptance,
    PartyRole,
    SeedPolicy
} from "../interfaces/types/PackageTypes.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { EditionRules } from "../editions/EditionRules.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";

/// @title PackageRegistry
/// @notice Approved package roots, party consent, single-use items, per-product content
///         uniqueness and the lead artist's revocable "move to Stream" (ADR 0001 section 3).
/// @dev Gas (the 300K auction start). `consume` writes one fresh slot, 6529 Stream's
///      `contentHash => itemHash`, which is both the consume-once record and the uniqueness
///      record. It reads consent from `acceptedAs[root][account]`, and its only external call is
///      the lead's current authority. Move nonces live in a per-artist bitmap of 255 nonces per
///      word whose top bit is a sentinel: the acceptance that creates an identity writes the
///      sentinel into word 0, so an artist's first 255 starts update a nonzero slot instead of
///      creating one. Tools should therefore use each artist's nonces sequentially from 0.
///
///      Replay protection never looks at signature bytes (a 65-byte signature and its 64-byte
///      ERC-2098 form both verify): a move spends a per-artist nonce, an item is single-use
///      through its content hash, and an acceptance is recorded once per (root, account).
///
///      Uniqueness keys on the item's declared `contentHash` (the decoded SHA-256 of its primary
///      media), never on a file ID. It is defense in depth: the curation signer verifies every
///      declared SHA-256 against the decoded bytes before attesting, and the evidence hash covers
///      that check. The one cross-product reuse, the linked pair, is enforced from the Editions
///      side: an edition may claim only the content hash its master item consumed on Stream.
///      When an upheld dispute burns a work during its auction, Stream calls `releaseContent`:
///      the content hash becomes available to its rightful artist, and the burned item is
///      tombstoned so it can never be consumed again, through any root.
///
///      Approvals are per root, not per item: revoking a root stops only that root, so an item
///      also listed in another approved root stays consumable there; the guardian revokes every
///      root that lists it. Disabling a curation signer stops only future registrations.
///
///      Callers: `consume` and `releaseContent` trust only the bound Stream, and `claimContent`
///      only the bound Editions. Each slot is bound once, independently, by the genesis
///      configurator (which holds ADMIN with no delay until it renounces ADMIN); no bound call
///      goes through the AccessManager.
contract PackageRegistry is IPackageRegistry, AccessManaged, EIP712 {
    /// @dev Move nonces per bitmap word; bit 255 of every written word is the sentinel.
    uint256 private constant NONCES_PER_WORD = 255;
    uint256 private constant SENTINEL = 1 << 255;
    /// @dev Binding names (`Bound`, `AlreadyBound`).
    bytes32 private constant STREAM = "STREAM";
    bytes32 private constant EDITIONS = "EDITIONS";
    /// @dev A Stream content slot whose item was burned and released: free for a new item.
    bytes32 private constant RELEASED = bytes32(uint256(1));

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

    mapping(bytes32 root => Package) private _packages;
    mapping(bytes32 root => mapping(address account => uint256 artistId)) private _acceptedAs;
    mapping(bytes32 contentHash => bytes32 itemHash) private _streamItems;
    mapping(bytes32 contentHash => bytes32 itemHash) private _editionItems;
    mapping(uint256 artistId => mapping(uint256 word => uint256 bits)) private _moveNonces;
    mapping(bytes32 itemHash => bool) private _released;

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
        _requireInstallable(
            artistRegistry_, artistRegistryCodeHash, type(IArtistRegistry).interfaceId
        );
        _artists = IArtistRegistry(artistRegistry_);
        _setVerifier(verifier_, verifierCodeHash);
    }

    /// @inheritdoc IPackageRegistry
    /// @dev Also the only caller of `releaseContent`. Governed (ADMIN by default): the genesis
    ///      configurator binds it before renouncing ADMIN.
    function bindStream(address target) external restricted {
        if (stream != address(0)) revert AlreadyBound(STREAM);
        _requireBindable(target, type(IStream).interfaceId);
        stream = target;
        emit Bound(STREAM, target);
    }

    /// @inheritdoc IPackageRegistry
    /// @dev Independent of Stream, so Editions can be bound whenever it deploys. Governed (ADMIN
    ///      by default): the genesis configurator binds it before renouncing ADMIN.
    function bindEditions(address target) external restricted {
        if (editions != address(0)) revert AlreadyBound(EDITIONS);
        _requireBindable(target, type(IEditions).interfaceId);
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
    ///      artist registry counts as its first activity), otherwise the current authority of its
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
        // A deadline is a wall-clock bound by design; validator timestamp drift is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > acceptance.deadline) revert InvalidSignature();
        address account = acceptance.account;
        artistId = _artists.artistIdOf(account);
        address signer = artistId == 0 ? account : _artists.authorityOf(artistId);
        if (!SignatureVerifier.isValid(
                signer, acceptanceDigest(packageRoot, acceptance), signature
            )) {
            revert InvalidSignature();
        }
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
            ) revert InvalidDependency(address(_artists));
        }
    }

    /// @inheritdoc IPackageRegistry
    /// @dev Checks, in order: the caller is the bound Stream; the root is approved; the proof
    ///      places the item; its content hash is unused on Stream; the seed and edition terms;
    ///      every party accepted the root and is a distinct artist; the payee list is canonical
    ///      and covered by the parties; the lead's current authority signed the move, unexpired,
    ///      on an unused nonce. A second consume of the same item, or of an item burned and
    ///      released, reverts with `ContentUsed` naming the item itself.
    function consume(
        bytes32 packageRoot,
        PackageItem calldata item,
        bytes32[] calldata proof,
        MoveAuthorization calldata move
    ) external returns (bytes32 itemHash, uint256 artistId) {
        if (msg.sender != stream) revert UnboundCaller(msg.sender);
        _requireApproved(packageRoot);
        itemHash = WorksHashing.itemHashCalldata(item);
        if (
            proof.length > Limits.MAX_PROOF_DEPTH
                || !MerkleProof.verifyCalldata(proof, packageRoot, WorksHashing.leaf(itemHash))
        ) revert ItemNotInPackage(packageRoot, itemHash);
        bytes32 contentHash = item.contentHash;
        bytes32 prior = _streamItems[contentHash];
        if (prior != 0) {
            if (prior != RELEASED) revert ContentUsed(PRODUCT_STREAM, contentHash, prior);
            // Only a released slot can hold a tombstoned item: fresh content skips this read. A
            // burned item reverts as if it still held the content, like a second consume.
            if (_released[itemHash]) revert ContentUsed(PRODUCT_STREAM, contentHash, itemHash);
        }
        _checkTerms(item, itemHash);
        artistId = _checkParties(packageRoot, item, itemHash);
        _useMove(packageRoot, itemHash, artistId, move);
        _streamItems[contentHash] = itemHash;
        emit ItemConsumed(packageRoot, itemHash, artistId, contentHash);
    }

    /// @inheritdoc IPackageRegistry
    /// @dev Reverts with `ClaimNotAllowed` unless 6529 Stream consumed `contentHash` for
    ///      `itemHash` (the linked pair), and with `ContentUsed` when an edition already claimed it.
    function claimContent(bytes32 contentHash, bytes32 itemHash) external {
        if (msg.sender != editions) revert UnboundCaller(msg.sender);
        if (uint256(itemHash) <= uint256(RELEASED) || _streamItems[contentHash] != itemHash) {
            revert ClaimNotAllowed(PRODUCT_EDITIONS, contentHash);
        }
        bytes32 prior = _editionItems[contentHash];
        if (prior != 0) revert ContentUsed(PRODUCT_EDITIONS, contentHash, prior);
        _editionItems[contentHash] = itemHash;
        emit ContentClaimed(contentHash, itemHash);
    }

    /// @inheritdoc IPackageRegistry
    /// @dev Reverts with `ClaimNotAllowed(PRODUCT_STREAM, contentHash)` unless `itemHash` holds
    ///      the slot. Editions are created only after a master's sale settles, so a burned work
    ///      never has an edition claim to release; the Editions slot is left untouched.
    function releaseContent(bytes32 contentHash, bytes32 itemHash) external {
        if (msg.sender != stream) revert UnboundCaller(msg.sender);
        // Zero (never consumed) and the release marker are not item hashes.
        if (uint256(itemHash) <= uint256(RELEASED) || _streamItems[contentHash] != itemHash) {
            revert ClaimNotAllowed(PRODUCT_STREAM, contentHash);
        }
        _streamItems[contentHash] = RELEASED;
        _released[itemHash] = true;
        emit ContentReleased(contentHash, itemHash);
    }

    /// @inheritdoc IPackageRegistry
    function revokeMove(uint256 artistId, uint256 nonce) external {
        if (_artists.authorityOf(artistId) != msg.sender) {
            revert NotAuthority(artistId, msg.sender);
        }
        _spendMoveNonce(artistId, nonce);
        emit MoveRevoked(artistId, nonce);
    }

    /// @inheritdoc IPackageRegistry
    /// @dev Governed: map to SUCCESSOR_SETTER (30 days). Reinstalling the current verifier is a
    ///      no-op and reverts with `InvalidDependency`.
    function setVerifier(ICurationVerifier expected, ICurationVerifier next, bytes32 nextCodeHash)
        external
        restricted
    {
        if (address(verifier) != address(expected)) revert ExpectedValueMismatch();
        if (address(next) == address(expected)) revert InvalidDependency(address(next));
        _setVerifier(next, nextCodeHash);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IPackageRegistry).interfaceId;
    }

    /// @inheritdoc IPackageRegistry
    function artistRegistry() external view returns (address) {
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
    function consumedItemOf(bytes32 contentHash) external view returns (bytes32 itemHash) {
        itemHash = _streamItems[contentHash];
        if (itemHash == RELEASED) itemHash = 0;
    }

    /// @notice Whether `itemHash` was burned and released, so it can never be consumed again.
    function isReleased(bytes32 itemHash) external view returns (bool) {
        return _released[itemHash];
    }

    /// @inheritdoc IPackageRegistry
    function editionClaimOf(bytes32 contentHash) external view returns (bytes32) {
        return _editionItems[contentHash];
    }

    /// @inheritdoc IPackageRegistry
    function isMoveNonceUsed(uint256 artistId, uint256 nonce) external view returns (bool) {
        return _moveNonces[artistId][nonce / NONCES_PER_WORD] & _bit(nonce) != 0;
    }

    /// @notice The EIP-712 digest the lead artist signs to move an item to Stream.
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

    function _requireApproved(bytes32 packageRoot) private view {
        if (_packages[packageRoot].status != PackageStatus.APPROVED) {
            revert PackageNotApproved(packageRoot);
        }
    }

    /// @dev Content, seed and edition fields: a nonzero content hash; an artist seed exactly
    ///      under `SeedPolicy.ARTIST`; an ORIGINAL with empty edition terms; an EDITION_MASTER
    ///      with edition terms `EditionRules.isValid` accepts, the same rule 6529 Editions applies
    ///      at `createEdition`, so a master that mints can always get its edition.
    function _checkTerms(PackageItem calldata item, bytes32 itemHash) private pure {
        EditionTerms calldata e = item.edition;
        bool fixedSize = e.format == EditionFormat.FIXED;
        bool bad =
            item.contentHash == 0 || (item.seedPolicy == SeedPolicy.ARTIST) == (item.seed == 0);
        if (item.kind == ItemKind.ORIGINAL) {
            bad = bad || !fixedSize || e.size != 0 || e.window != 0 || e.price != 0
                || e.currency != address(0) || e.saleKind != 0 || e.params.length != 0;
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
            n == 0 || n > Limits.MAX_PARTIES || parties[0].role != PartyRole.ARTIST
                || payees.length == 0 || payees.length > n
        ) revert InvalidItem(itemHash);
        mapping(address => uint256) storage accepted = _acceptedAs[packageRoot];
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
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
    ///      current authority.
    function _useMove(
        bytes32 packageRoot,
        bytes32 itemHash,
        uint256 artistId,
        MoveAuthorization calldata move
    ) private {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > move.deadline) revert InvalidSignature();
        _spendMoveNonce(artistId, move.nonce);
        bytes32 digest = moveDigest(packageRoot, itemHash, move.nonce, move.deadline);
        if (!SignatureVerifier.isValid(_artists.authorityOf(artistId), digest, move.signature)) {
            revert InvalidSignature();
        }
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
        _requireInstallable(address(next), codeHash, type(ICurationVerifier).interfaceId);
        emit VerifierSet(address(verifier), address(next), codeHash);
        verifier = next;
    }

    /// @dev Installs (decision D8): ERC-165 support, the pinned code hash, not delegated.
    function _requireInstallable(address target, bytes32 codeHash, bytes4 interfaceId)
        private
        view
    {
        if (!_supports(target, interfaceId) || target.codehash != codeHash) {
            revert InvalidDependency(target);
        }
    }

    /// @dev Bindings: ERC-165 support for the bound role, not delegated.
    function _requireBindable(address target, bytes4 interfaceId) private view {
        if (!_supports(target, interfaceId)) revert InvalidBinding(target);
    }

    /// @dev Code, not an EIP-7702 delegated account, and ERC-165 support for `interfaceId`.
    function _supports(address target, bytes4 interfaceId) private view returns (bool) {
        return target.code.length != 0 && !DelegatedEOA.isDelegated(target)
            && ERC165Checker.supportsInterface(target, interfaceId);
    }

    function _bit(uint256 nonce) private pure returns (uint256) {
        return uint256(1) << (nonce % NONCES_PER_WORD);
    }
}
