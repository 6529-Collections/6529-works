// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IMintTarget } from "./IMintTarget.sol";
import { EditionTerms, PackageItem } from "./types/PackageTypes.sol";

/// @title IEditions
/// @notice 6529 Editions: the one shared ERC-1155 for editions, each anchored by a 6529 Stream
///         work of kind EDITION_MASTER (ADR 0001 section 6).
/// @dev The edition ID equals the master's Stream token ID, so the link is one ID in both
///      contracts. The link is written once, from the approved package item, in both directions
///      in the same transaction, and never changes. An edition renders its master's content and
///      record and carries its master's license: `uri(id)` is served by the master's renderer
///      (`IStream.rendererOf(id)`), so finalizing the master fixes the edition's rendering too.
///      Copies are sold only through the shared fixed-price or Dutch adapters (MINTER role),
///      at the price, currency and size the package fixed. Minting stops if the master is
///      burned. There are no numbered editions.
interface IEditions is IERC1155, IERC2981, IMintTarget {
    /// @notice An edition's state.
    /// @param contentId The master's content ID (primary file); its decoded SHA-256 is unique in
    ///        Editions.
    /// @param terms The edition terms from the approved package item.
    /// @param minted Copies minted so far.
    /// @param windowStart When the first copy was minted (the OPEN window starts), or zero.
    /// @param seller The artist-portion split wallet, locked at creation.
    /// @param feeRecipient The network recipient, locked at creation.
    /// @param feeShare The network share of primary sales, out of 100,000, locked at creation.
    /// @param royaltyReceiver The royalty split wallet, locked at creation.
    /// @param royaltyRate The royalty rate, out of 100,000, locked at creation.
    struct Edition {
        bytes32 contentId;
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
    event EditionCreated(uint256 indexed editionId, bytes32 indexed contentId, EditionTerms terms);
    /// @notice ERC-7572: the contract-level metadata changed.
    event ContractURIUpdated();
    /// @notice The marketplace owner changed.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice The item does not match the master's committed item hash, or is not an
    ///         EDITION_MASTER item.
    error NotEditionMaster(uint256 workId);
    /// @notice The master already has its edition.
    error EditionExists(uint256 editionId);
    /// @notice No edition has this ID.
    error UnknownEdition(uint256 editionId);
    /// @notice The mint exceeds the edition size, falls outside the OPEN window, or the master
    ///         was burned.
    error EditionUnavailable(uint256 editionId);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();

    /// @notice The 6529 Stream contract whose masters anchor editions (immutable).
    function stream() external view returns (address);

    /// @notice Creates the edition of master `workId` from its approved package item, records
    ///         `(stream, workId, contentId)` and calls `IStream.linkEdition`. Permissionless: the
    ///         item is checked against the master's committed item hash. Claims the content hash
    ///         (the decoded SHA-256 of `contentId`) in the package registry for the Editions
    ///         product and locks economics from the resolver.
    /// @param workId The master's Stream token ID.
    /// @param item The master's package item.
    /// @return editionId The new edition ID (equal to `workId`).
    function createEdition(uint256 workId, PackageItem calldata item)
        external
        returns (uint256 editionId);

    /// @notice An edition's state. Reverts with `UnknownEdition`.
    function edition(uint256 editionId) external view returns (Edition memory);

    /// @notice The master an edition is anchored by: the Stream contract, the master token ID and
    ///         the content ID. Reverts with `UnknownEdition`.
    function masterOf(uint256 editionId)
        external
        view
        returns (address streamContract, uint256 workId, bytes32 contentId);

    /// @notice Whether an edition exists.
    function exists(uint256 editionId) external view returns (bool);

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
