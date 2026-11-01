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
    /// @param packageRoot The approved package root.
    /// @param evidenceHash The nonzero hash committing to the approval evidence.
    /// @param verifier The curation verifier that approved the root.
    /// @param signer The curation signer the verifier reported.
    event PackageRegistered(
        bytes32 indexed packageRoot,
        bytes32 evidenceHash,
        address indexed verifier,
        address indexed signer
    );
    /// @notice The guardian revoked an approval; unconsumed items can no longer mint.
    /// @param packageRoot The revoked package root, registered or not.
    /// @param reasonHash The hash of the reason, as the caller passed it.
    event PackageRevoked(bytes32 indexed packageRoot, bytes32 reasonHash);
    /// @notice A party accepted a package root.
    /// @param packageRoot The accepted package root.
    /// @param artistId The artist ID the party accepted as.
    /// @param account The party's account.
    event PackageAccepted(
        bytes32 indexed packageRoot, uint256 indexed artistId, address indexed account
    );
    /// @notice 6529 Stream consumed an item and claimed its content hash under `PRODUCT_STREAM`.
    /// @param packageRoot The package root the item was proved against.
    /// @param itemHash The consumed item's hash (`WorksHashing.itemHash`).
    /// @param artistId The lead artist's ID.
    /// @param contentHash The item's content hash.
    event ItemConsumed(
        bytes32 indexed packageRoot,
        bytes32 indexed itemHash,
        uint256 indexed artistId,
        bytes32 contentHash
    );
    /// @notice 6529 Stream Editions claimed a master's content hash under `PRODUCT_EDITIONS`.
    /// @param contentHash The master's content hash.
    /// @param itemHash The master item, which consumed `contentHash` on 6529 Stream.
    event ContentClaimed(bytes32 indexed contentHash, bytes32 indexed itemHash);
    /// @notice An upheld-dispute burn released a content hash to the artist `beneficiary`;
    ///         `itemHash` is tombstoned.
    /// @param contentHash The released content hash.
    /// @param itemHash The burned item that had consumed it.
    /// @param beneficiary The artist ID the content hash is now reserved for.
    event ContentReleased(
        bytes32 indexed contentHash, bytes32 indexed itemHash, uint256 indexed beneficiary
    );
    /// @notice An artist revoked an unused move nonce.
    /// @param artistId The artist whose nonce was revoked.
    /// @param nonce The revoked move nonce.
    event MoveRevoked(uint256 indexed artistId, uint256 indexed nonce);
    /// @notice The curation verifier changed; `codeHash` is the pinned code hash of `next`.
    /// @param previous The verifier before the change (zero at deployment).
    /// @param next The verifier after the change.
    /// @param codeHash The reviewed code hash `next` was pinned to.
    event VerifierSet(address previous, address next, bytes32 codeHash);
    /// @notice A contract was bound under `name` (STREAM or EDITIONS), once.
    /// @param name The binding's name as a `bytes32` string.
    /// @param target The contract bound.
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
    /// @param target The 6529 Stream contract.
    function bindStream(address target) external;
    /// @notice Binds 6529 Stream Editions, the only `claimContent` caller, once (ERC-165 for
    ///         `IEditions`, not an EIP-7702 delegated account). ADMIN role.
    /// @param target The 6529 Stream Editions contract.
    function bindEditions(address target) external;
    /// @notice Registers an approved package root. Permissionless; the verifier decides.
    /// @param packageRoot The package root: the Merkle root over its items'
    ///        `WorksHashing.leaf(itemHash)` values.
    /// @param evidenceHash The nonzero hash committing to the approval evidence.
    /// @param attestation The verifier's approval proof (for the v1 verifier,
    ///        `abi.encode(address signer, bytes signature)`).
    function registerPackage(bytes32 packageRoot, bytes32 evidenceHash, bytes calldata attestation)
        external;
    /// @notice Revokes an approval; items not yet consumed can no longer mint. Also pre-revokes
    ///         a root not yet registered (`NONE` to `REVOKED`), which can then never be
    ///         registered. GUARDIAN role (immediate: a tightening action, for a compromised
    ///         curation signer).
    /// @param packageRoot The package root to revoke; an already revoked root reverts with
    ///        `PackageNotApproved`.
    /// @param reasonHash The hash of the public reason, emitted unchecked.
    function revokePackage(bytes32 packageRoot, bytes32 reasonHash) external;
    /// @notice Records a party's acceptance of a package root. Permissionless relay of the
    ///         party's `Typehashes.PACKAGE_ACCEPTANCE` signature.
    /// @param packageRoot The approved package root to accept.
    /// @param acceptance The party's account, profile fields and signature deadline.
    /// @param signature The EIP-712 signature of the acceptance: by `acceptance.account` when it
    ///        has no artist ID yet, otherwise by its artist's active authority.
    /// @return artistId The party's artist ID (created if new).
    function acceptPackage(
        bytes32 packageRoot,
        PartyAcceptance calldata acceptance,
        bytes calldata signature
    ) external returns (uint256 artistId);
    /// @notice Consumes an item and claims its content hash under `PRODUCT_STREAM`. Bound 6529
    ///         Stream only.
    /// @param packageRoot The approved package root that lists the item.
    /// @param item The package item to consume.
    /// @param proof The Merkle proof of the item's leaf under `packageRoot`, at most
    ///        `Limits.MAX_PROOF_DEPTH` hashes.
    /// @param move The lead artist's signed move authorization.
    /// @return itemHash The item hash.
    /// @return artistId The lead artist's ID.
    /// @return authority The lead artist's active authority, which signed `move`: 6529 Stream
    ///         reports it as the work's creator, with no second read of the artist registry.
    function consume(
        bytes32 packageRoot,
        PackageItem calldata item,
        bytes32[] calldata proof,
        MoveAuthorization calldata move
    ) external returns (bytes32 itemHash, uint256 artistId, address authority);
    /// @notice Releases `contentHash` after an upheld-dispute burn to the artist `beneficiary`
    ///         the dispute outcome names: checks that `itemHash` consumed it, clears its
    ///         `PRODUCT_STREAM` claim, reserves it for items whose lead artist is `beneficiary`,
    ///         and tombstones `itemHash` so it can never be consumed again. Once per burned item;
    ///         `beneficiary` must be a registered artist (`IArtistRegistry.UnknownArtist`
    ///         otherwise). Bound 6529 Stream only, through the governed `IStream.releaseContent`.
    /// @param contentHash The content hash to release.
    /// @param itemHash The burned item that consumed `contentHash`.
    /// @param beneficiary The artist ID the content hash is reserved for.
    function releaseContent(bytes32 contentHash, bytes32 itemHash, uint256 beneficiary) external;
    /// @notice Claims a master's content hash under `PRODUCT_EDITIONS`; `consumedItemOf` must
    ///         already record `itemHash` for it. Bound 6529 Stream Editions only.
    /// @param contentHash The master's content hash.
    /// @param itemHash The master item.
    function claimContent(bytes32 contentHash, bytes32 itemHash) external;
    /// @notice Revokes one of the caller's unused move nonces. The caller must be the active
    ///         authority of `artistId` (`IArtistRegistry.activeAuthorityOf`).
    /// @param artistId The artist whose move nonce is revoked.
    /// @param nonce The move nonce; a used or revoked one reverts with `MoveNonceUsed`.
    function revokeMove(uint256 artistId, uint256 nonce) external;
    /// @notice Swaps the curation verifier: it must support `ICurationVerifier` (ERC-165), have
    ///         code hash `nextCodeHash`, not be an EIP-7702 delegated account, and never have
    ///         been installed before (a replaced verifier is retired for good).
    ///         SUCCESSOR_SETTER role, compare-and-set. Registered approvals are unaffected.
    /// @param expected The verifier the proposer saw; a stale value reverts with
    ///        `ExpectedValueMismatch`.
    /// @param next The new curation verifier.
    /// @param nextCodeHash The reviewed code hash `next` must have.
    function setVerifier(ICurationVerifier expected, ICurationVerifier next, bytes32 nextCodeHash)
        external;

    /// @notice The current curation verifier.
    /// @return The verifier `registerPackage` asks.
    function verifier() external view returns (ICurationVerifier);
    /// @notice The artist registry used for parties and the lead artist (immutable).
    /// @return The artist registry.
    function artistRegistry() external view returns (address);
    /// @notice The bound 6529 Stream.
    /// @return The 6529 Stream contract, or zero before it is bound.
    function stream() external view returns (address);
    /// @notice The bound 6529 Stream Editions.
    /// @return The 6529 Stream Editions contract, or zero before it is bound.
    function editions() external view returns (address);
    /// @notice A package root's status, evidence hash and attesting signer.
    /// @param packageRoot The package root.
    /// @return status NONE, APPROVED or REVOKED.
    /// @return evidenceHash The evidence hash it was registered with, or zero if never registered.
    /// @return signer The curation signer that attested it, or zero if never registered.
    function packageOf(bytes32 packageRoot)
        external
        view
        returns (PackageStatus status, bytes32 evidenceHash, address signer);
    /// @notice The artist ID `account` accepted `packageRoot` as, or zero if it has not.
    /// @param packageRoot The package root.
    /// @param account The party's account.
    /// @return The artist ID, or zero.
    function acceptedAs(bytes32 packageRoot, address account) external view returns (uint256);
    /// @notice The item that consumed `contentHash` on 6529 Stream, or zero. Tools derive an
    ///         item's content hash from the item itself.
    /// @param contentHash The content hash.
    /// @return itemHash The consuming item's hash, or zero (also after a release).
    function consumedItemOf(bytes32 contentHash) external view returns (bytes32 itemHash);
    /// @notice The artist a released content hash is reserved for, or zero if never released.
    ///         It binds only while the content is released: once its item consumes, the
    ///         content is used again.
    /// @param contentHash The content hash.
    /// @return artistId The beneficiary's artist ID, or zero.
    function releasedTo(bytes32 contentHash) external view returns (uint256 artistId);
    /// @notice The master item whose content hash 6529 Stream Editions claimed, or zero.
    /// @param contentHash The content hash.
    /// @return itemHash The master item's hash, or zero.
    function editionClaimOf(bytes32 contentHash) external view returns (bytes32 itemHash);
    /// @notice Whether an artist's move nonce is used or revoked.
    /// @param artistId The artist ID.
    /// @param nonce The move nonce.
    /// @return True if a move spent the nonce or the artist revoked it.
    function isMoveNonceUsed(uint256 artistId, uint256 nonce) external view returns (bool);
}
