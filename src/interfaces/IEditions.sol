// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IMintTarget } from "./IMintTarget.sol";
import { EditionTerms, License, PackageItem } from "./types/PackageTypes.sol";

/// @title IEditions
/// @notice 6529 Editions: the one shared ERC-1155 for editions, each anchored by a 6529 Stream
///         work of kind EDITION_MASTER (ADR 0001 section 6).
/// @dev The edition ID equals the master's Stream token ID, so the link is one ID in both
///      contracts. An edition is created only after the master's sale has settled
///      (`IStream.primarySaleSettled`), so a burned or disputed master never gets one. The link is
///      written once, from the approved package item, in both directions in the same
///      transaction, and never changes. An edition renders its master's media and record and
///      carries its master's license: `uri(id)` is served by the master's renderer
///      (`IStream.rendererOf(id)`). Copies are sold only through the admitted fixed-price or
///      Dutch adapters, at the price, currency and size the package fixed; minting stops if the
///      master is burned. There are no numbered editions.
interface IEditions is IERC1155, IERC2981, IMintTarget {
    /// @notice An edition's state; economics are locked at creation.
    /// @param contentHash The master's content hash; unique in the Editions product.
    /// @param terms The edition terms from the approved package item.
    /// @param minted Copies minted so far.
    /// @param windowStart When the first copy was minted (the OPEN window starts), or zero.
    /// @param seller The artist-portion split wallet (a predicted address).
    /// @param feeRecipient The network fee recipient.
    /// @param feeShare The network share of primary sales and royalties, out of 100,000.
    /// @param royaltyReceiver The royalty split wallet (a predicted address).
    /// @param royaltyRate The ERC-2981 royalty rate, out of 100,000.
    struct Edition {
        bytes32 contentHash;
        EditionTerms terms;
        uint64 minted;
        uint64 windowStart;
        address seller;
        address feeRecipient;
        uint32 feeShare;
        address royaltyReceiver;
        uint32 royaltyRate;
    }

    /// @notice An edition was created and linked to its master.
    event EditionCreated(
        uint256 indexed editionId, bytes32 indexed contentHash, EditionTerms terms
    );
    /// @notice ERC-4906: an edition's metadata changed (its master's record, license, renderer
    ///         or preferred location).
    event MetadataUpdate(uint256 _tokenId);
    /// @notice ERC-4906: a range of editions' metadata changed.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    /// @notice An OPEN edition's window began with its first mint and ends at `closesAt`.
    event EditionWindowOpened(uint256 indexed editionId, uint64 closesAt);
    /// @notice A contract was bound under `name` (WORK_RECORDS), once.
    event Bound(bytes32 indexed name, address target);
    /// @notice ERC-7572: the contract-level metadata changed.
    event ContractURIUpdated();
    /// @notice The marketplace owner changed.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice The item does not match the master's committed item hash or its package, the
    ///         package is no longer approved, the item is not an EDITION_MASTER item, or the
    ///         master's sale has not settled.
    error NotEditionMaster(uint256 workId);
    /// @notice The master already has its edition.
    error EditionExists(uint256 editionId);
    /// @notice No edition has this ID.
    error UnknownEdition(uint256 editionId);
    /// @notice The mint exceeds the edition size, falls outside the OPEN window, or the master
    ///         was burned.
    error EditionUnavailable(uint256 editionId);
    /// @notice The caller is not the bound contract this function serves.
    error UnboundCaller(address caller);
    /// @notice `name` is already bound.
    error AlreadyBound(bytes32 name);
    /// @notice The target lacks code or the expected ERC-165 support, or is an EIP-7702 delegated
    ///         account.
    error InvalidBinding(address target);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();

    /// @notice The 6529 Stream contract whose masters anchor editions (immutable).
    function stream() external view returns (address);

    /// @notice Creates the edition of master `workId` from its approved package item once the
    ///         master's sale has settled, records `(stream, workId, contentHash)` and calls
    ///         `IStream.linkEdition`. Permissionless: the item is checked against the master's
    ///         stored item hash, and `proof` places it in `packageRoot`, which must still be
    ///         approved (not revoked) in the package registry. Claims the content hash for the
    ///         Editions product and locks `PRODUCT_EDITIONS` economics from the resolver. Reverts
    ///         for edition terms with a non-zero price and `CURRENCY_DEFAULT`.
    /// @return editionId The new edition ID (equal to `workId`).
    function createEdition(
        uint256 workId,
        PackageItem calldata item,
        bytes32 packageRoot,
        bytes32[] calldata proof
    ) external returns (uint256 editionId);

    /// @notice Binds 6529 Stream's work-records satellite, once (ERC-165 for `IWorkRecords`, not
    ///         an EIP-7702 delegated account). ADMIN role.
    function bindWorkRecords(address target) external;
    /// @notice The bound work-records satellite.
    function workRecords() external view returns (address);
    /// @notice Re-emits ERC-4906 for master `workId`'s edition after the master's record, license
    ///         or renderer changed; a no-op when the master has no edition. Bound work-records
    ///         satellite only.
    function notifyMasterUpdated(uint256 workId) external;
    /// @notice Sets an edition's royalty rate after its master's changed by agreement. Bound
    ///         work-records satellite only.
    function setRoyaltyRate(uint256 editionId, uint32 rate) external;
    /// @notice Emits a batch ERC-4906 update for every edition, after a global or collection
    ///         preferred-location change or a new default renderer. Bound work-records satellite
    ///         or 6529 Stream only.
    function notifyAllUpdated() external;

    /// @notice An edition's state. Reverts with `UnknownEdition`.
    function edition(uint256 editionId) external view returns (Edition memory);
    /// @notice The master an edition is anchored by. Reverts with `UnknownEdition`.
    function masterOf(uint256 editionId)
        external
        view
        returns (address streamContract, uint256 workId, bytes32 contentHash);
    /// @notice Whether an edition exists.
    function exists(uint256 editionId) external view returns (bool);
    /// @notice An edition's content hash (its master's). Reverts with `UnknownEdition`.
    function contentHashOf(uint256 editionId) external view returns (bytes32);
    /// @notice An edition's license: its master's current license from the work-records
    ///         satellite. Reverts with `UnknownEdition`, or `IWorkRecords.RecordNotOpen` until the
    ///         master's record is open.
    function licenseOf(uint256 editionId) external view returns (License memory);

    /// @notice ERC-7572 contract-level metadata URI.
    function contractURI() external view returns (string memory);
    /// @notice Sets the contract URI. PARAMETER_SETTER role.
    function setContractURI(string calldata uri) external;
    /// @notice The marketplace owner (held by 6529); it has no on-chain powers.
    function owner() external view returns (address);
    /// @notice Sets the marketplace owner, which marketplaces let configure creator earnings.
    ///         FUNDS_SETTER role, compare-and-set.
    function setOwner(address expected, address next) external;
}
