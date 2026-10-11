// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { ItemKind, License } from "../interfaces/types/PackageTypes.sol";

/// @title IStreamCore
/// @notice DRAFT, local to the stream lane: the core 6529 Stream token surface after the PR #10
///         review (integrator decision D1). It replaces this lane's use of `IStream` until the
///         interfaces lane publishes the reshaped `IStream`; the integrator reconciles the two.
/// @dev Token IDs are one chronological global sequence from 1, never reused; a burn leaves a
///      gap. Collections are groupings with per-collection serials from 1. Governed functions
///      are non-payable and restricted by AccessManager; each names the role it maps to.
interface IStreamCore is IERC4906, IERC2981, IMintTarget {
    /// @notice A collection: a named grouping of works, possibly by several artists.
    struct Collection {
        string name;
        bytes32 metadataHash;
        uint64 minted;
    }

    /// @notice What the core stores about a token. `artistId` is the lead artist; `itemHash`
    ///         the consumed package item, whose fields are in `WorkMinted` and the published
    ///         package.
    struct TokenInfo {
        bytes32 itemHash;
        uint256 artistId;
        uint256 collectionId;
        uint64 serial;
        ItemKind kind;
        bool editionLinked;
    }

    /// @notice A curated work was minted from an approved package item. The package root and
    ///         content hash are in the registry's `ItemConsumed` for the same `itemHash`, and the
    ///         full item in the published package (D26). `seller` is the payees' split wallet and
    ///         `royaltyReceiver` the royalty split wallet, both predicted addresses.
    event WorkMinted(
        uint256 indexed tokenId,
        uint256 indexed collectionId,
        bytes32 indexed itemHash,
        uint64 serial,
        uint256 artistId,
        ItemKind kind,
        bytes32 contentId,
        address seller,
        address royaltyReceiver,
        uint32 royaltyRate
    );
    /// @notice A work's royalty rate changed, by every party's consent plus a governed action.
    event RoyaltyChanged(
        uint256 indexed tokenId, address receiver, uint32 previousRate, uint32 nextRate
    );
    /// @notice A work's license changed, by every party's consent plus a governed action.
    event LicenseChanged(uint256 indexed tokenId, License previous, License next);
    /// @notice A collection was created.
    event CollectionCreated(uint256 indexed collectionId, string name, bytes32 metadataHash);
    /// @notice The renderer of works without a pin changed.
    event DefaultRendererSet(address previous, address next);
    /// @notice The records satellite was bound (once).
    event RecordsBound(address records);
    /// @notice The 6529 Editions contract was bound (once).
    event EditionsBound(address editions);
    /// @notice An edition master was linked to its 6529 Editions edition.
    event EditionLinked(uint256 indexed tokenId, address indexed editions, uint256 editionId);
    /// @notice The marketplace owner changed.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice ERC-7572: the contract-level metadata changed.
    event ContractURIUpdated();

    /// @notice No live token has this ID.
    error UnknownWork(uint256 tokenId);
    /// @notice No collection has this ID.
    error UnknownCollection(uint256 collectionId);
    /// @notice The mint request is malformed or the item breaks a Stream rule.
    error InvalidMintRequest();
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();
    /// @notice The caller is not the bound contract for this hook.
    error UnboundCaller(address caller);
    /// @notice The binding was already made.
    error AlreadyBound(address bound);
    /// @notice The work is not an edition master, or its edition is already linked.
    error EditionLinkInvalid(uint256 tokenId);
    /// @notice A dependency has no code or is an EIP-7702 delegated account.
    error InvalidDependency(address dependency);
    /// @notice The collection name is empty, too long or not UTF-8.
    error InvalidCollection();
    /// @notice The license identifier is empty or too long.
    error InvalidLicense();
    /// @notice The royalty rate exceeds 100,000.
    error InvalidRoyalty();
    /// @notice A CC0 dedication is irrevocable.
    error LicenseIrrevocable(uint256 tokenId);

    /// @notice The package registry `mint` consumes items from (immutable).
    function packageRegistry() external view returns (address);
    /// @notice The artist registry (immutable).
    function artistRegistry() external view returns (address);
    /// @notice The economics resolver whose `PRODUCT_STREAM` terms works lock (immutable).
    function economics() external view returns (address);
    /// @notice The bound records satellite, or zero before genesis wiring.
    function records() external view returns (address);
    /// @notice The bound 6529 Editions contract, or zero before genesis wiring.
    function editions() external view returns (address);
    /// @notice Binds the records satellite, once. Genesis wiring (ADMIN).
    function bindRecords(address records_) external;
    /// @notice Binds the 6529 Editions contract, once. Genesis wiring (ADMIN).
    function bindEditions(address editions_) external;

    /// @notice Creates a collection (sequential IDs from 1). PLATFORM role.
    function createCollection(string calldata name, bytes32 metadataHash)
        external
        returns (uint256 collectionId);
    /// @notice A collection. Reverts with `UnknownCollection`.
    function collection(uint256 collectionId) external view returns (Collection memory);
    /// @notice The number of collections.
    function collectionCount() external view returns (uint256);
    /// @notice Tokens ever minted, which is also the highest token ID.
    function totalMinted() external view returns (uint256);
    /// @notice Live tokens: minted minus burned.
    function totalSupply() external view returns (uint256);

    /// @notice What the core stores about a live token. Reverts with `UnknownWork`.
    function work(uint256 tokenId) external view returns (TokenInfo memory);
    /// @notice The consumed item's hash, also after a burn; zero if never minted.
    function itemHashOf(uint256 tokenId) external view returns (bytes32);
    /// @notice A live token's license.
    function licenseOf(uint256 tokenId) external view returns (License memory);
    /// @notice The canonical key of an SPDX identifier: keccak256 of its ASCII-lowercase form.
    function licenseKey(string memory spdxId) external pure returns (bytes32);
    /// @notice A live token's royalty receiver and rate (out of 100,000).
    function royaltyOf(uint256 tokenId) external view returns (address receiver, uint32 rate);

    /// @notice Records hook: replaces a work's license. Bound records satellite only.
    function setLicense(uint256 tokenId, License calldata next) external;
    /// @notice Records hook: replaces a work's royalty rate. Bound records satellite only.
    function setRoyaltyRate(uint256 tokenId, uint32 rate) external;
    /// @notice Records hook: emits ERC-4906 for one token (`from == to`) or a range.
    function refreshMetadata(uint256 fromTokenId, uint256 toTokenId) external;

    /// @notice The renderer of works without a pin.
    function defaultRenderer() external view returns (address);
    /// @notice Sets the default renderer. SUCCESSOR_SETTER role, compare-and-set.
    function setDefaultRenderer(address expected, address next) external;
    /// @notice The renderer serving a live work: its pin in the records satellite, else the
    ///         default.
    function rendererOf(uint256 tokenId) external view returns (address);

    /// @notice Records the edition of an EDITION_MASTER work, once. Bound Editions only.
    function linkEdition(uint256 tokenId, uint256 editionId) external;
    /// @notice The edition an EDITION_MASTER work anchors, or zeros.
    function editionOf(uint256 tokenId)
        external
        view
        returns (address editionsContract, uint256 editionId);

    /// @notice ERC-7572 contract-level metadata URI.
    function contractURI() external view returns (string memory);
    /// @notice Sets the contract URI. PARAMETER_SETTER role.
    function setContractURI(string calldata uri) external;
    /// @notice The marketplace owner; it has no on-chain powers.
    function owner() external view returns (address);
    /// @notice Sets the marketplace owner. FUNDS_SETTER role, compare-and-set.
    function setOwner(address expected, address next) external;
}
