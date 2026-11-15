// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IWorkDelivery } from "./IWorkDelivery.sol";
import { IFederatedToken } from "./IFederatedToken.sol";
import { MediaFile } from "./types/ContentTypes.sol";
import { PackageItem } from "./types/PackageTypes.sol";
import { PrimaryOutcome } from "./types/SaleTypes.sol";

/// @title IFederatedStream
/// @notice Federated Stream: the artist's own ERC-721 of 1/1s, a full copy of a network template
///         (ADR 0008; spec `docs/spec/federation.md`, rules FED-1 to FED-30).
/// @dev A work is a `PackageItem` with its media list, hashed exactly as a curated item
///      (`WorksHashing.itemHash`), approved on chain by the artist (`approveItem`, which also
///      sets its royalty rate), and minted only into the custody of an admitted sale adapter
///      that starts its sale. The record the shared renderer reads (`work`, `collection`,
///      `workRecords`, `isOpen`, `record`, `mediaOf`, `preferredLocator`, `licenseOf`, `seedOf`)
///      is held here, so `workRecords()` is this contract. Token IDs and work IDs differ: an
///      unsold work returns to this contract's own custody and a restart burns its token and
///      mints the next ID for the same work, because a sale adapter keys a sale by token and ID.
interface IFederatedStream is IFederatedToken {
    /// @notice Deployment arguments; every one is written to storage (no immutables).
    /// @param name The ERC-721 name.
    /// @param symbol The ERC-721 symbol.
    /// @param artistRegistry The canonical artist registry.
    /// @param splitLedger The canonical split ledger.
    /// @param contentStore The content store media files are registered in.
    /// @param artistId The artist (its first authority's address as a number).
    /// @param feeShare The network's share of primary sales and royalties, out of 100,000.
    /// @param feeRecipient The network's fee recipient (the governed fee vault).
    /// @param renderer The default renderer, which `finalize` pins (ERC-165 `IRenderer`).
    /// @param rendererCodeHash Its code hash.
    /// @param owner The marketplace owner.
    struct Config {
        string name;
        string symbol;
        address artistRegistry;
        address splitLedger;
        address contentStore;
        uint256 artistId;
        uint32 feeShare;
        address feeRecipient;
        address renderer;
        bytes32 rendererCodeHash;
        address owner;
    }

    /// @notice What an adapter passes to `mint` (opaque to it): `abi.encode(FederatedMint)`.
    /// @param item The approved item (`WorksHashing.itemHash` names it).
    /// @param media Its media list, primary first, committed by `item.mediaHash` (ignored by a
    ///        restart).
    struct FederatedMint {
        PackageItem item;
        MediaFile[] media;
    }

    /// @notice The artist approved an item for one mint (or one restart), or withdrew it.
    /// @param itemHash `WorksHashing.itemHash` of the item.
    /// @param royaltyRate The royalty rate a new work of it gets, out of 100,000.
    /// @param approved Whether a mint of it may now proceed.
    event ItemApproval(bytes32 indexed itemHash, uint32 royaltyRate, bool approved);
    /// @notice A work's record was created at its first mint: everything rendering and payment
    ///         read, so a logs-only reader rebuilds it.
    /// @param workId The work.
    /// @param itemHash Its item hash.
    /// @param seller The seller vault of the item's payees.
    /// @param royaltyRate Its royalty rate.
    /// @param feeBearing Whether its royalties route through the network's split (minted
    ///        before the exit).
    /// @param item The approved item.
    /// @param media The item's media list.
    event WorkOpened(
        uint256 indexed workId,
        bytes32 indexed itemHash,
        address seller,
        uint32 royaltyRate,
        bool feeBearing,
        PackageItem item,
        MediaFile[] media
    );
    /// @notice A token of a work was minted into an adapter's custody for a sale.
    /// @param tokenId The token.
    /// @param workId Its work.
    /// @param adapter The minting adapter, the only one that settles or burns it.
    /// @param feeShare The network share the token's sale terms carry (zero after the exit).
    event TokenMinted(
        uint256 indexed tokenId, uint256 indexed workId, address indexed adapter, uint32 feeShare
    );
    /// @notice The minting adapter settled a token's primary sale (`IMintTarget.settlePrimary`).
    /// @param tokenId The token.
    /// @param outcome SOLD, UNBID or FROZEN_OUT.
    /// @param buyer The buyer, zero unless SOLD.
    /// @param currency The sale's currency.
    /// @param price The price, zero unless SOLD.
    event PrimarySaleSettled(
        uint256 indexed tokenId,
        PrimaryOutcome outcome,
        address buyer,
        address currency,
        uint256 price
    );
    /// @notice A token whose sale closed without settling (a refused settlement) came back from
    ///         its adapter into this contract's custody.
    /// @param tokenId The token.
    event WorkReturned(uint256 indexed tokenId);
    /// @notice The artist pointed a work at a new record file.
    event RecordChanged(uint256 indexed workId, bytes32 recordFileId);
    /// @notice The artist finalized a work, pinning a renderer.
    event Finalized(uint256 indexed workId, address renderer, bytes32 codeHash);
    /// @notice The artist lowered a work's royalty rate.
    event RoyaltyRateChanged(uint256 indexed workId, uint32 previous, uint32 next);
    /// @notice The artist set (or cleared, kind zero) a media file's locator.
    event LocatorSet(uint256 indexed workId, uint256 index, uint8 kind, string uri);
    /// @notice Every media file of a work is complete in the content store.
    event OnChainComplete(uint256 indexed workId);
    /// @notice The artist set the default renderer.
    event DefaultRendererSet(address renderer, bytes32 codeHash);
    /// @notice The artist linked the pair's editions contract.
    event EditionsLinked(address editions);

    /// @notice Only the adapter that minted the token.
    error NotMintingAdapter(address caller);
    /// @notice The token's sale already settled.
    error SaleAlreadySettled(uint256 tokenId);
    /// @notice An outcome other than SOLD with a buyer, or UNBID or FROZEN_OUT without one.
    error InvalidSaleOutcome();
    /// @notice The work cannot restart: its token is not unsold in this contract's custody, or
    ///         its edition sale has begun.
    error WorkNotRestartable(uint256 workId);
    /// @notice The work is finalized.
    error WorkFinalized(uint256 workId);
    /// @notice A royalty rate above 100,000, or not lower than the current one.
    error InvalidRoyaltyRate(uint32 rate);
    /// @notice No live token or no such file, collection or index.
    error UnknownWork(uint256 tokenId);

    /// @notice The artist approves `itemHash` for one mint, with the royalty rate a new work of
    ///         it gets (no floor; at most 100,000), or re-approves a consumed item to restart its
    ///         unsold work.
    function approveItem(bytes32 itemHash, uint32 royaltyRate) external;
    /// @notice The artist withdraws an approval not yet used.
    function revokeItem(bytes32 itemHash) external;
    /// @notice Pulls a token whose sale closed without settling back into this contract's
    ///         custody, through its adapter's `claimDelivery` (this contract is the creator the
    ///         adapter recognises). Permissionless.
    function reclaim(uint256 tokenId) external;
    /// @notice The artist points a work at a new record file, until finalize.
    function setRecord(uint256 tokenId, bytes32 recordFileId) external;
    /// @notice The artist finalizes a work: the record is fixed and the default renderer is
    ///         pinned with its code hash.
    function finalize(uint256 tokenId) external;
    /// @notice The artist lowers a work's royalty rate.
    function setRoyaltyRate(uint256 tokenId, uint32 rate) external;
    /// @notice The artist sets media file `index`'s locator (kind zero clears it).
    function setLocator(uint256 tokenId, uint256 index, uint8 kind, string calldata uri) external;
    /// @notice Marks a work on-chain complete once every media file is complete in the content
    ///         store. Permissionless.
    function syncOnChain(uint256 tokenId) external;
    /// @notice The artist sets the default renderer (ERC-165 `IRenderer`, code hash pinned).
    function setDefaultRenderer(address renderer, bytes32 codeHash) external;
    /// @notice The artist links the pair's editions contract, once, before joining.
    function linkEditions(address editions) external;

    /// @notice The token's work, minting adapter and sale state (1 in sale, 2 sold, 3 unbid, 4
    ///         frozen out, 5 returned).
    function tokenInfo(uint256 tokenId)
        external
        view
        returns (uint256 workId, address adapter, uint8 state);
    /// @notice A work's live token, zero if burned.
    function liveTokenOf(uint256 workId) external view returns (uint256);
    /// @notice The token's primary-sale outcome: NONE until its adapter settles it.
    function primarySale(uint256 tokenId)
        external
        view
        returns (PrimaryOutcome outcome, address currency, uint256 price);
    /// @notice Whether the token's primary sale settled (sold, unbid or frozen out).
    function primarySaleSettled(uint256 tokenId) external view returns (bool);
    /// @notice The fields the edition auction and the editions template read.
    function coreOf(uint256 tokenId)
        external
        view
        returns (
            bytes32 itemHash,
            uint256 artistId,
            uint256 collectionId,
            uint8 kind,
            uint8 seedPolicy,
            uint32 royaltyRate
        );
    /// @notice The renderer that builds the token's metadata: its pin once finalized, else the
    ///         default renderer; either must still have its pinned code hash.
    function rendererOf(uint256 tokenId) external view returns (address);
    /// @notice The record satellite the renderer reads: this contract.
    function workRecords() external view returns (address);
    /// @notice A file's locator and its index in the work's media list.
    function preferredLocator(uint256 tokenId, bytes32 fileId)
        external
        view
        returns (IWorkDelivery.Location memory locator, uint256 index);
}
