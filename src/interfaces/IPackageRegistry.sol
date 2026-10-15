// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ICurationVerifier } from "./ICurationVerifier.sol";
import { MoveAuthorization, PackageItem, PartyAcceptance } from "./types/PackageTypes.sol";

/// @title IPackageRegistry
/// @notice Approved packages, party consent, single-use items, per-product content uniqueness and
///         the artist's revocable "move to Stream" (ADR 0001 section 3).
/// @dev Lifecycle of a package root:
///      1. `registerPackage`: anyone submits the root, the evidence hash and the verifier's
///         attestation; the registry stores the approval and emits the evidence hash and the
///         signer. The CURATOR role appends the matching CURATION_EVIDENCE statement (subject
///         `(address(0), uint256(packageRoot))`). Approvals do not expire.
///      2. `acceptPackage`: each party's signed acceptance is stored as
///         `acceptedAs[root][account] = artistId`; a first acceptance creates the identity in
///         the artist registry, and only first acceptances count as artist activity.
///      3. `consume`: the bound 6529 Stream consumes one item when its sale starts, checking the
///         Merkle proof, every party's `acceptedAs` entry (no registry calls), that the payee list
///         is canonical, sums to 100,000 and pays only parties, and the lead artist's move
///         authorization.
///      Uniqueness is keyed on `PackageItem.contentHash`, the declared decoded SHA-256 of the
///      primary media, scoped per product: one storage word per product and content hash records
///      the item that claimed it, which also makes consumption single-use (`consumedItemOf`).
///      This on-chain check is defense in depth: the curation signer verifies every declared
///      SHA-256 against the decoded bytes before attesting, and the evidence hash covers that
///      check. Statements about an item before it is minted use the subject
///      `(address(0), uint256(itemHash))`. Contract callers are bound once at genesis.
interface IPackageRegistry is IERC165 {
    /// @notice Whether a package root is approved.
    enum PackageStatus {
        NONE,
        APPROVED,
        REVOKED
    }

    /// @notice A package root was approved by `verifier`, attested by `signer`.
    event PackageRegistered(
        bytes32 indexed packageRoot,
        bytes32 evidenceHash,
        address indexed verifier,
        address indexed signer
    );
    /// @notice The guardian revoked an approval; unconsumed items can no longer mint.
    event PackageRevoked(bytes32 indexed packageRoot, bytes32 reasonHash);
    /// @notice A party accepted a package root.
    event PackageAccepted(
        bytes32 indexed packageRoot, uint256 indexed artistId, address indexed account
    );
    /// @notice 6529 Stream consumed an item and claimed its content hash under `PRODUCT_STREAM`.
    event ItemConsumed(
        bytes32 indexed packageRoot,
        bytes32 indexed itemHash,
        uint256 indexed artistId,
        bytes32 contentHash
    );
    /// @notice 6529 Editions claimed a master's content hash under `PRODUCT_EDITIONS`.
    event ContentClaimed(bytes32 indexed contentHash, bytes32 indexed itemHash);
    /// @notice An upheld-dispute burn released a content hash to the artist `beneficiary`;
    ///         `itemHash` is tombstoned.
    event ContentReleased(
        bytes32 indexed contentHash, bytes32 indexed itemHash, uint256 indexed beneficiary
    );
    /// @notice An artist revoked an unused move nonce.
    event MoveRevoked(uint256 indexed artistId, uint256 indexed nonce);
    /// @notice The curation verifier changed; `codeHash` is the pinned code hash of `next`.
    event VerifierSet(address previous, address next, bytes32 codeHash);
    /// @notice A contract was bound under `name` (STREAM or EDITIONS), once.
    event Bound(bytes32 indexed name, address target);

    /// @notice The verifier rejected the attestation.
    error NotApproved(bytes32 packageRoot);
    /// @notice The package root is already registered.
    error PackageExists(bytes32 packageRoot);
    /// @notice The package root is not approved (unknown or revoked).
    error PackageNotApproved(bytes32 packageRoot);
    /// @notice The Merkle proof does not place the item in the package.
    error ItemNotInPackage(bytes32 packageRoot, bytes32 itemHash);
    /// @notice The content hash is already claimed in `product`, by `claimedBy`.
    error ContentUsed(bytes32 product, bytes32 contentHash, bytes32 claimedBy);
    /// @notice The claim is not allowed: an edition may only claim the content hash its master
    ///         item consumed on 6529 Stream.
    error ClaimNotAllowed(bytes32 product, bytes32 contentHash);
    /// @notice A released content hash is reserved for the item of artist `beneficiary`.
    error ContentReserved(bytes32 contentHash, uint256 beneficiary);
    /// @notice A listed party has not accepted the package root.
    error PartyNotAccepted(bytes32 packageRoot, address account);
    /// @notice The parties, payees, kind, seed or edition fields are inconsistent.
    error InvalidItem(bytes32 itemHash);
    /// @notice The caller is not the active authority of `artistId`.
    error NotAuthority(uint256 artistId, address caller);
    /// @notice The move nonce was used or revoked.
    error MoveNonceUsed(uint256 artistId, uint256 nonce);
    /// @notice The acceptance's profile fields do not match the artist record.
    error ProfileMismatch(uint256 artistId);
    /// @notice The caller is not the bound contract for this function.
    error UnboundCaller(address caller);
    /// @notice `name` is already bound.
    error AlreadyBound(bytes32 name);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();

    /// @notice Binds 6529 Stream, the only `consume` caller, once (ERC-165 for `IStream`, not an
    ///         EIP-7702 delegated account). ADMIN role.
    function bindStream(address target) external;
    /// @notice Binds 6529 Editions, the only `claimContent` caller, once (ERC-165 for
    ///         `IEditions`, not an EIP-7702 delegated account). ADMIN role.
    function bindEditions(address target) external;
    /// @notice Registers an approved package root. Permissionless; the verifier decides.
    function registerPackage(bytes32 packageRoot, bytes32 evidenceHash, bytes calldata attestation)
        external;
    /// @notice Revokes an approval; items not yet consumed can no longer mint. Also pre-revokes
    ///         a root not yet registered (`NONE` to `REVOKED`), which can then never be
    ///         registered. GUARDIAN role (immediate: a tightening action, for a compromised
    ///         curation signer).
    function revokePackage(bytes32 packageRoot, bytes32 reasonHash) external;
    /// @notice Records a party's acceptance of a package root. Permissionless relay of the
    ///         party's `Typehashes.PACKAGE_ACCEPTANCE` signature.
    /// @return artistId The party's artist ID (created if new).
    function acceptPackage(
        bytes32 packageRoot,
        PartyAcceptance calldata acceptance,
        bytes calldata signature
    ) external returns (uint256 artistId);
    /// @notice Consumes an item and claims its content hash under `PRODUCT_STREAM`. Bound 6529
    ///         Stream only.
    /// @return itemHash The item hash.
    /// @return artistId The lead artist's ID.
    function consume(
        bytes32 packageRoot,
        PackageItem calldata item,
        bytes32[] calldata proof,
        MoveAuthorization calldata move
    ) external returns (bytes32 itemHash, uint256 artistId);
    /// @notice Releases `contentHash` after an upheld-dispute burn to the artist `beneficiary`
    ///         the dispute outcome names: checks that `itemHash` consumed it, clears its
    ///         `PRODUCT_STREAM` claim, reserves it for items whose lead artist is `beneficiary`,
    ///         and tombstones `itemHash` so it can never be consumed again. Once per burned item;
    ///         `beneficiary` must be a registered artist (`IArtistRegistry.UnknownArtist`
    ///         otherwise). Bound 6529 Stream only, through the governed `IStream.releaseContent`.
    function releaseContent(bytes32 contentHash, bytes32 itemHash, uint256 beneficiary) external;
    /// @notice Claims a master's content hash under `PRODUCT_EDITIONS`; `consumedItemOf` must
    ///         already record `itemHash` for it. Bound 6529 Editions only.
    function claimContent(bytes32 contentHash, bytes32 itemHash) external;
    /// @notice Revokes one of the caller's unused move nonces. The caller must be the current
    ///         authority of `artistId`.
    function revokeMove(uint256 artistId, uint256 nonce) external;
    /// @notice Swaps the curation verifier: it must support `ICurationVerifier` (ERC-165), have
    ///         code hash `nextCodeHash`, not be an EIP-7702 delegated account, and never have
    ///         been installed before (a replaced verifier is retired for good).
    ///         SUCCESSOR_SETTER role, compare-and-set. Registered approvals are unaffected.
    function setVerifier(ICurationVerifier expected, ICurationVerifier next, bytes32 nextCodeHash)
        external;

    /// @notice The current curation verifier.
    function verifier() external view returns (ICurationVerifier);
    /// @notice The artist registry used for parties and the lead artist (immutable).
    function artistRegistry() external view returns (address);
    /// @notice The bound 6529 Stream.
    function stream() external view returns (address);
    /// @notice The bound 6529 Editions.
    function editions() external view returns (address);
    /// @notice A package root's status, evidence hash and attesting signer.
    function packageOf(bytes32 packageRoot)
        external
        view
        returns (PackageStatus status, bytes32 evidenceHash, address signer);
    /// @notice The artist ID `account` accepted `packageRoot` as, or zero if it has not.
    function acceptedAs(bytes32 packageRoot, address account) external view returns (uint256);
    /// @notice The item that consumed `contentHash` on 6529 Stream, or zero. Tools derive an
    ///         item's content hash from the item itself.
    function consumedItemOf(bytes32 contentHash) external view returns (bytes32 itemHash);
    /// @notice The artist a released content hash is reserved for, or zero if never released.
    ///         It binds only while the content is released: once its item consumes, the
    ///         content is used again.
    function releasedTo(bytes32 contentHash) external view returns (uint256 artistId);
    /// @notice The master item whose content hash 6529 Editions claimed, or zero.
    function editionClaimOf(bytes32 contentHash) external view returns (bytes32 itemHash);
    /// @notice Whether an artist's move nonce is used or revoked.
    function isMoveNonceUsed(uint256 artistId, uint256 nonce) external view returns (bool);
}
