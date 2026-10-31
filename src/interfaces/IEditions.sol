// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IMintTarget } from "./IMintTarget.sol";
import { EditionTerms, License, PackageItem } from "./types/PackageTypes.sol";

/// @title IEditions
/// @notice 6529 Stream Editions (named 6529 Editions before ADR 0005, D139): the one shared
///         ERC-1155 for editions, each anchored by a 6529 Stream work of kind EDITION_MASTER
///         (ADR 0001 section 6, as amended by ADR 0005).
/// @dev The edition ID equals the master's Stream token ID, so the link is one ID in both
///      contracts. An edition is created only after the master's sale has settled
///      (`IStream.primarySaleSettled`), so a burned or disputed master never gets one. The link is
///      written once, from the approved package item, in both directions in the same
///      transaction, and never changes. An edition renders its master's media and record and
///      carries its master's license: `uri(id)` is served by the master's renderer
///      (`IStream.rendererOf(id)`). Copies are minted only by an admitted sale adapter whose
///      `saleKind()` equals the edition's terms, within the creator's cap
///      (`EditionTerms.maxCount`): any adapter governance admits (`setAdmittedMinter`, 30-day
///      class), so a sale method is added by deploying and admitting an adapter, never by
///      redeploying this contract (ADR 0005, owner decision 14); in rc.2, the uniform-price
///      edition auction, whose clearing decides how many copies exist. The first adapter to mint
///      an edition is the only one that may mint it again (`MinterMismatch`), so a second
///      admitted adapter of the same kind can never add copies to a sale another one ran. A
///      master with an edition can never be burned (6529 Stream burns only before the primary
///      sale settles), so minting reads nothing from 6529 Stream. There are no numbered editions.
interface IEditions is IERC1155, IERC2981, IMintTarget {
    /// @notice An edition's state; economics are locked at creation.
    /// @param contentHash The master's content hash; unique in the Editions product.
    /// @param terms The edition terms from the approved package item.
    /// @param minted Copies minted so far.
    /// @param minter The adapter the edition is bound to: the first that minted it; zero before
    ///        the first mint.
    /// @param seller The artist-portion split wallet (a predicted address).
    /// @param feeRecipient The network fee recipient.
    /// @param feeShare The network share of primary sales and royalties, out of 100,000.
    /// @param royaltyReceiver The royalty split wallet (a predicted address).
    /// @param royaltyRate The ERC-2981 royalty rate, out of 100,000.
    struct Edition {
        bytes32 contentHash;
        EditionTerms terms;
        uint64 minted;
        address minter;
        address seller;
        address feeRecipient;
        uint32 feeShare;
        address royaltyReceiver;
        uint32 royaltyRate;
    }

    /// @notice An edition was created and linked to its master.
    /// @param editionId The new edition's ID, equal to its master's 6529 Stream token ID.
    /// @param contentHash The master's content hash.
    /// @param terms The edition terms from the approved package item.
    event EditionCreated(
        uint256 indexed editionId, bytes32 indexed contentHash, EditionTerms terms
    );
    /// @notice ERC-4906: an edition's metadata changed (its master's record, license, renderer
    ///         or preferred location).
    /// @param _tokenId The edition whose metadata changed.
    event MetadataUpdate(uint256 _tokenId);
    /// @notice ERC-4906: a range of editions' metadata changed.
    /// @param _fromTokenId The first ID of the range (this contract emits 0).
    /// @param _toTokenId The last ID of the range, inclusive (this contract emits
    ///        `type(uint256).max`).
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    /// @notice An edition was bound to the adapter that minted its first copies; only that
    ///         adapter may mint it from now on.
    /// @param editionId The edition.
    /// @param minter The adapter.
    event EditionMinterBound(uint256 indexed editionId, address indexed minter);
    /// @notice A contract was bound under `name` (WORK_RECORDS), once.
    /// @param name The binding name.
    /// @param target The bound contract.
    event Bound(bytes32 indexed name, address target);
    /// @notice ERC-7572: the contract-level metadata changed.
    event ContractURIUpdated();
    /// @notice The marketplace owner changed.
    /// @param previousOwner The owner before the change (zero at deployment).
    /// @param newOwner The owner after the change.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice The contract URI changed from `previous` to `next` (beside ERC-7572's
    ///         `ContractURIUpdated`, which carries no values).
    /// @param previous The value before the change.
    /// @param next The value after the change.
    event ContractURISet(string previous, string next);
    /// @notice An edition's royalty rate changed with its master's, by every party's agreement
    ///         plus a governed action, relayed by the work-records satellite.
    /// @param editionId The edition whose rate changed.
    /// @param previous The rate before the change, out of 100,000.
    /// @param next The rate after the change, out of 100,000.
    event RoyaltyRateChanged(uint256 indexed editionId, uint32 previous, uint32 next);

    /// @notice The item does not match the master's committed item hash, the proof does not
    ///         place it in `packageRoot`, the root was never registered (a revoked root is
    ///         accepted: SIGS-4), the item is not an EDITION_MASTER item, or the master's sale
    ///         has not settled.
    error NotEditionMaster(uint256 workId);
    /// @notice The master already has its edition.
    error EditionExists(uint256 editionId);
    /// @notice No edition has this ID.
    error UnknownEdition(uint256 editionId);
    /// @notice The mint would take the edition past its creator's cap (`EditionTerms.maxCount`).
    error EditionUnavailable(uint256 editionId);
    /// @notice The caller is not the bound contract this function serves.
    error UnboundCaller(address caller);
    /// @notice `name` is already bound.
    error AlreadyBound(bytes32 name);
    /// @notice The work-records satellite to bind is not the one 6529 Stream bound.
    error InvalidBinding(address target);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();
    /// @notice 6529 Stream returned a zero package registry, economics resolver or artist
    ///         registry at deployment.
    error ZeroAddress();
    /// @notice The item's edition terms are invalid (`EditionRules.isValid`): the uniform-price
    ///         edition auction other than in ETH with empty params, no sale kind or the 1/1's,
    ///         or params past `EditionRules.MAX_PARAMS_BYTES`.
    error InvalidEditionTerms(uint256 workId);
    /// @notice 6529 Stream did not record the link back to this edition.
    error LinkFailed(uint256 workId);
    /// @notice A royalty rate above 100,000.
    error InvalidRoyaltyRate(uint32 rate);
    /// @notice The work-records satellite is not bound yet, so no edition can be created.
    error WorkRecordsUnbound();
    /// @notice `minter` is admitted, but another adapter already minted this edition, and only
    ///         that one may mint it again (ADR 0005).
    error MinterMismatch(uint256 editionId, address minter);

    /// @notice The collection's name (D139): "6529 Stream Editions".
    /// @return The name, for wallets and marketplaces.
    function name() external view returns (string memory);
    /// @notice The collection's symbol: "STREAMEDITIONS" (ADR 0005, owner decision 13).
    /// @return The symbol, for wallets and marketplaces.
    function symbol() external view returns (string memory);

    /// @notice The 6529 Stream contract whose masters anchor editions (immutable).
    /// @return The 6529 Stream address.
    function stream() external view returns (address);

    /// @notice Creates the edition of master `workId` from its approved package item once the
    ///         master's sale has settled, records `(stream, workId, contentHash)` and calls
    ///         `IStream.linkEdition`. Permissionless: the item is checked against the master's
    ///         stored item hash, and `proof` places it in `packageRoot`, which the package
    ///         registry must have registered (it may have been revoked since: a revocation stops
    ///         unconsumed items, not the edition of a master already sold). Claims the content
    ///         hash for the Editions product and locks `PRODUCT_EDITIONS` economics from the
    ///         resolver.
    /// @param workId The master's 6529 Stream token ID, which becomes the edition ID.
    /// @param item The master's EDITION_MASTER package item, whose hash must be the item hash
    ///        6529 Stream stored for `workId`.
    /// @param packageRoot A package root the package registry registered (approved, or revoked
    ///        since).
    /// @param proof The Merkle proof of the item's leaf under `packageRoot`, at most
    ///        `Limits.MAX_PROOF_DEPTH` nodes.
    /// @return editionId The new edition ID (equal to `workId`).
    function createEdition(
        uint256 workId,
        PackageItem calldata item,
        bytes32 packageRoot,
        bytes32[] calldata proof
    ) external returns (uint256 editionId);

    /// @notice Binds 6529 Stream's work-records satellite, once (ERC-165 for `IWorkRecords`, not
    ///         an EIP-7702 delegated account). ADMIN role.
    /// @param target The work-records satellite 6529 Stream bound (`IStream.workRecords()`).
    function bindWorkRecords(address target) external;
    /// @notice The bound work-records satellite.
    /// @return The satellite's address, or zero before it is bound.
    function workRecords() external view returns (address);
    /// @notice Re-emits ERC-4906 for master `workId`'s edition after anything the edition renders
    ///         from its master changed (record, license, renderer, locators, preferences, on-chain
    ///         sync or royalty rate); a no-op when the master has no edition. Bound work-records
    ///         satellite only.
    /// @param workId The master's 6529 Stream token ID (its edition's ID).
    function notifyMasterUpdated(uint256 workId) external;
    /// @notice Sets an edition's royalty rate after its master's changed by agreement. Bound
    ///         work-records satellite only.
    /// @param editionId The edition ID (its master's token ID); an ID without an edition is a
    ///        no-op.
    /// @param rate The new ERC-2981 rate, out of 100,000; a higher value reverts with
    ///        `InvalidRoyaltyRate`.
    function setRoyaltyRate(uint256 editionId, uint32 rate) external;
    /// @notice Emits a batch ERC-4906 update for every edition, after a global or collection
    ///         preferred-location change or a new default renderer. Bound work-records satellite
    ///         or 6529 Stream only.
    function notifyAllUpdated() external;

    /// @notice An edition's state. Reverts with `UnknownEdition`.
    /// @param editionId The edition ID.
    /// @return The edition's content hash, terms as approved, mint count, bound adapter, locked
    ///        economics and current royalty rate.
    function edition(uint256 editionId) external view returns (Edition memory);
    /// @notice The master an edition is anchored by. Reverts with `UnknownEdition`.
    /// @param editionId The edition ID.
    /// @return streamContract The 6529 Stream contract (`stream()`).
    /// @return workId The master's token ID, equal to `editionId`.
    /// @return contentHash The master's content hash.
    function masterOf(uint256 editionId)
        external
        view
        returns (address streamContract, uint256 workId, bytes32 contentHash);
    /// @notice Whether an edition exists.
    /// @param editionId The edition ID.
    /// @return True once `createEdition` created it.
    function exists(uint256 editionId) external view returns (bool);
    /// @notice An edition's content hash (its master's). Reverts with `UnknownEdition`.
    /// @param editionId The edition ID.
    /// @return The content hash stored when the edition was created.
    function contentHashOf(uint256 editionId) external view returns (bytes32);
    /// @notice An edition's license: its master's current license from the work-records
    ///         satellite. Reverts with `UnknownEdition`, or `IWorkRecords.RecordNotOpen` until the
    ///         master's record is open.
    /// @param editionId The edition ID.
    /// @return The license's SPDX identifier and license-text file ID.
    function licenseOf(uint256 editionId) external view returns (License memory);

    /// @notice ERC-7572 contract-level metadata URI.
    /// @return The URI; empty until set.
    function contractURI() external view returns (string memory);
    /// @notice Sets the contract URI. PARAMETER_SETTER role.
    /// @param uri The new contract-level metadata URI.
    function setContractURI(string calldata uri) external;
    /// @notice The marketplace owner (held by 6529); it has no on-chain powers.
    /// @return The current owner.
    function owner() external view returns (address);
    /// @notice Sets the marketplace owner, which marketplaces let configure creator earnings.
    ///         FUNDS_SETTER role, compare-and-set.
    /// @param expected The current owner; any other value reverts with `ExpectedValueMismatch`.
    /// @param next The new owner.
    function setOwner(address expected, address next) external;
}
