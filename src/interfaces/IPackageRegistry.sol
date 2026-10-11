// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ICurationVerifier } from "./ICurationVerifier.sol";
import { MoveAuthorization, PackageItem, PartyAcceptance } from "./types/PackageTypes.sol";

/// @title IPackageRegistry
/// @notice Approved packages, party consent, single-use items, per-product content
///         uniqueness and the artist's revocable "move to Stream" (ADR 0001 section 3).
/// @dev Lifecycle of a package root:
///      1. `registerPackage`: anyone submits the root, the evidence hash and the verifier's
///         attestation; the registry stores the approval and emits the evidence hash. The
///         curation signer also appends the CURATION_EVIDENCE statement to the statement log
///         (subject `(address(0), uint256(packageRoot))`). Approvals do not expire.
///      2. `acceptPackage`: each listed party's signed acceptance is recorded by artist ID; a
///         first acceptance creates the artist identity in the artist registry.
///      3. `consume`: 6529 Stream consumes one item when its sale starts, after checking the
///         Merkle proof, that every party accepted the root, that the payee list is canonical
///         with shares summing to 100,000 and every payee is a party (by account or by artist
///         ID), and the lead artist's move authorization.
///      Item and leaf hashes are defined by `WorksHashing`. Content uniqueness is keyed on the
///      content hash: the decoded SHA-256 the content store declares for the primary file
///      (`IContentStore.sha256Of(contentId)`), which the registry reads itself so a
///      package can never declare a hash its file does not have. Uniqueness is scoped by product
///      ID: each consumed item claims its content hash under `PRODUCT_STREAM`, and each edition
///      under `PRODUCT_EDITIONS`, so each product rejects media it already used, whatever its
///      MIME type or encoding; an edition may reuse its master's content hash, because it
///      claims it in another product.
interface IPackageRegistry {
    /// @notice Whether a package root is approved.
    enum PackageStatus {
        NONE,
        APPROVED,
        REVOKED
    }

    /// @notice A package root was approved by `verifier` with `evidenceHash`.
    event PackageRegistered(
        bytes32 indexed packageRoot, bytes32 evidenceHash, address indexed verifier
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
        bytes32 contentId,
        bytes32 contentHash
    );
    /// @notice A content hash was claimed for `product` outside `consume` (an edition).
    event ContentClaimed(bytes32 indexed product, bytes32 indexed contentHash, bytes32 contentId);
    /// @notice An artist revoked an unused move nonce.
    event MoveRevoked(uint256 indexed artistId, uint256 indexed nonce);
    /// @notice The curation verifier changed.
    event VerifierSet(address previous, address next);

    /// @notice The verifier rejected the attestation.
    error NotApproved(bytes32 packageRoot);
    /// @notice The package root is already registered.
    error PackageExists(bytes32 packageRoot);
    /// @notice The package root is not approved (unknown or revoked).
    error PackageNotApproved(bytes32 packageRoot);
    /// @notice The Merkle proof does not place the item in the package.
    error ItemNotInPackage(bytes32 packageRoot, bytes32 itemHash);
    /// @notice The item was already consumed.
    error ItemConsumedAlready(bytes32 itemHash);
    /// @notice The content hash is already used in `product`.
    error ContentUsed(bytes32 product, bytes32 contentHash);
    /// @notice A listed party has not accepted the package root.
    error PartyNotAccepted(bytes32 packageRoot, address account);
    /// @notice The parties, payees, kind, seed or edition fields are inconsistent.
    error InvalidItem(bytes32 itemHash);
    /// @notice A signature is expired, malformed or from the wrong signer.
    error InvalidSignature();
    /// @notice The move nonce was used or revoked.
    error MoveNonceUsed(uint256 artistId, uint256 nonce);
    /// @notice The acceptance's profile fields do not match the artist record.
    error ProfileMismatch(uint256 artistId);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();

    /// @notice Registers an approved package root. Permissionless; the verifier decides.
    function registerPackage(bytes32 packageRoot, bytes32 evidenceHash, bytes calldata attestation)
        external;

    /// @notice Revokes an approval; items not yet consumed can no longer mint. GUARDIAN role
    ///         (immediate: a tightening action, for a compromised curation signer).
    function revokePackage(bytes32 packageRoot, bytes32 reasonHash) external;

    /// @notice Records a party's acceptance of a package root. Permissionless relay of the
    ///         party's EIP-712 `PackageAcceptance` signature.
    /// @return artistId The party's artist ID (created if new).
    function acceptPackage(
        bytes32 packageRoot,
        PartyAcceptance calldata acceptance,
        bytes calldata signature
    ) external returns (uint256 artistId);

    /// @notice Consumes an item and claims its content hash under `PRODUCT_STREAM`. Restricted
    ///         to protocol contracts (SYSTEM role, held by 6529 Stream).
    ///         The item's `contentId` must be registered in the content store.
    /// @return itemHash The item hash.
    /// @return artistId The lead artist's ID.
    /// @return contentHash The claimed content hash (decoded SHA-256 of `item.contentId`).
    function consume(
        bytes32 packageRoot,
        PackageItem calldata item,
        bytes32[] calldata proof,
        MoveAuthorization calldata move
    ) external returns (bytes32 itemHash, uint256 artistId, bytes32 contentHash);

    /// @notice Claims the content hash of file `contentId` for `product` outside `consume`.
    ///         Restricted to protocol contracts (SYSTEM role, held by 6529 Editions, which claims
    ///         under `PRODUCT_EDITIONS`).
    /// @return contentHash The claimed content hash.
    function claimContent(bytes32 product, bytes32 contentId) external returns (bytes32 contentHash);

    /// @notice Revokes one of the caller's unused move nonces. The caller must be the current
    ///         authority of `artistId`.
    function revokeMove(uint256 artistId, uint256 nonce) external;

    /// @notice Swaps the curation verifier. SUCCESSOR_SETTER role, compare-and-set.
    ///         Registered approvals are unaffected.
    function setVerifier(ICurationVerifier expected, ICurationVerifier next) external;

    /// @notice The current curation verifier.
    function verifier() external view returns (ICurationVerifier);
    /// @notice The artist registry used for parties and the lead artist (immutable).
    function artistRegistry() external view returns (address);
    /// @notice The content store that declares each content ID's content hash (immutable).
    function contentStore() external view returns (address);
    /// @notice A package root's status and evidence hash.
    function packageOf(bytes32 packageRoot)
        external
        view
        returns (PackageStatus status, bytes32 evidenceHash);
    /// @notice Whether artist `artistId` accepted `packageRoot`.
    function hasAccepted(bytes32 packageRoot, uint256 artistId) external view returns (bool);
    /// @notice Whether an item was consumed.
    function isConsumed(bytes32 itemHash) external view returns (bool);
    /// @notice Whether a content hash (decoded SHA-256) is used in `product`.
    function isContentUsed(bytes32 product, bytes32 contentHash) external view returns (bool);
    /// @notice Whether an artist's move nonce is used or revoked.
    function isMoveNonceUsed(uint256 artistId, uint256 nonce) external view returns (bool);
    /// @notice The EIP-712 digest of a move authorization.
    function moveDigest(bytes32 packageRoot, bytes32 itemHash, uint256 nonce, uint64 deadline)
        external
        view
        returns (bytes32);
    /// @notice The EIP-712 digest of a party acceptance.
    function acceptanceDigest(bytes32 packageRoot, PartyAcceptance calldata acceptance)
        external
        view
        returns (bytes32);
}
