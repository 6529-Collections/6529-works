// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "../economics/interfaces/ISplitWallet.sol";
import { IEditions } from "./IEditions.sol";
import { IFederatedToken } from "./IFederatedToken.sol";
import { WorkTerms } from "./types/EconomicsTypes.sol";
import { EditionTerms, PackageItem } from "./types/PackageTypes.sol";

/// @title IFederatedEditions
/// @notice Federated Stream Editions: the ERC-1155 half of an artist's linked pair, each edition
///         anchored by an EDITION_MASTER work of its partner `IFederatedStream` (ADR 0008;
///         FED-31 to FED-40 in `docs/spec/federation.md`).
/// @dev The edition ID is the master's token ID, as in 6529 Stream Editions, and the functions an
///      edition sale adapter calls (`stream`, `bindMinter`, `exists`, `edition`, `sealSupply`,
///      `masterOf`, `mint`) have 6529 Stream Editions' signatures, so the edition auction's code
///      serves both. An edition is bound to the one adapter whose sale opens it, sealed by that
///      adapter at its sale's count, and paid at the locked network share. ETH only.
interface IFederatedEditions is IFederatedToken {
    /// @notice Deployment arguments; every one is written to storage (no immutables).
    struct Config {
        string name;
        string symbol;
        address artistRegistry;
        address splitLedger;
        uint256 artistId;
        uint32 feeShare;
        address feeRecipient;
        address partner;
        address owner;
    }

    /// @notice An edition was created from its settled master (`createEdition`).
    /// @param editionId The edition (the master's token ID).
    /// @param contentHash The master's content hash.
    /// @param terms The master item's edition terms.
    event EditionCreated(uint256 indexed editionId, bytes32 contentHash, EditionTerms terms);
    /// @notice An edition's payout terms were locked (at its binding or its creation).
    /// @param editionId The edition.
    /// @param seller The master's seller vault.
    /// @param royaltyReceiver The royalty receiver (the 90/10 vault while listed).
    /// @param feeRecipient The network fee recipient, zero after the exit.
    /// @param feeShare The network share, zero after the exit.
    event EditionTermsLocked(
        uint256 indexed editionId,
        address seller,
        address royaltyReceiver,
        address feeRecipient,
        uint32 feeShare
    );
    /// @notice Copies were minted by the bound adapter, at the price it reports.
    /// @param editionId The edition.
    /// @param to The buyer's recipient.
    /// @param amount Copies minted.
    /// @param currency The currency paid (ETH).
    /// @param unitPrice The price paid per copy.
    event EditionPrimaryMint(
        uint256 indexed editionId,
        address indexed to,
        uint256 amount,
        address currency,
        uint256 unitPrice
    );
    /// @notice The bound adapter sealed the edition's supply.
    /// @param editionId The edition.
    /// @param supply The sealed maximum.
    event EditionSupplySealed(uint256 indexed editionId, uint256 supply);
    /// @notice An edition was bound to the adapter whose sale opened it.
    /// @param editionId The edition.
    /// @param minter The bound adapter.
    event EditionMinterBound(uint256 indexed editionId, address indexed minter);

    /// @notice Not the partner's EDITION_MASTER work, or not its item, or not settled yet.
    /// @param workId The master's token ID.
    error NotEditionMaster(uint256 workId);
    /// @notice The edition exists already.
    /// @param editionId The edition.
    error EditionExists(uint256 editionId);
    /// @notice No such edition.
    /// @param editionId The edition.
    error UnknownEdition(uint256 editionId);
    /// @notice The mint would pass the edition's maximum.
    /// @param editionId The edition.
    error EditionUnavailable(uint256 editionId);
    /// @notice The edition's supply is sealed already.
    /// @param editionId The edition.
    error EditionSealed(uint256 editionId);
    /// @notice A seal below the minted count or above the maximum.
    /// @param editionId The edition.
    /// @param count The count asked for.
    error InvalidSealCount(uint256 editionId, uint256 count);
    /// @notice A currency other than the edition's (ETH).
    /// @param expected ETH.
    /// @param actual The currency reported.
    error CurrencyMismatch(address expected, address actual);
    /// @notice The edition is bound to another adapter.
    /// @param editionId The edition.
    /// @param minter Its bound adapter.
    error MinterMismatch(uint256 editionId, address minter);

    /// @notice Creates edition `editionId` from its master's item once the master's primary sale
    ///         settled. Permissionless.
    /// @param editionId The master's token ID.
    /// @param item The master's EDITION_MASTER item.
    function createEdition(uint256 editionId, PackageItem calldata item) external;
    /// @notice Binds the edition to the calling admitted adapter (or checks it is the bound one)
    ///         and returns the locked terms its sale pays; before the edition exists, `item` must
    ///         be the master's EDITION_MASTER item, its edition terms ETH and of the adapter's
    ///         sale kind.
    /// @param editionId The master's token ID.
    /// @param item The master's item (read only before the edition exists).
    /// @return The locked terms: seller, fee recipient and share, royalty receiver and rate.
    function bindMinter(uint256 editionId, PackageItem calldata item)
        external
        returns (WorkTerms memory);
    /// @notice Seals the edition's supply at `count`, once. The bound adapter only.
    /// @param editionId The edition.
    /// @param count The supply, at least the count minted and at most the maximum.
    function sealSupply(uint256 editionId, uint256 count) external;
    /// @notice The partner 1/1 contract (`IEditions.stream`'s signature).
    /// @return The partner.
    function stream() external view returns (address);
    /// @notice Whether the edition exists.
    /// @param editionId The edition.
    /// @return True once created.
    function exists(uint256 editionId) external view returns (bool);
    /// @notice Whether a sale bound the edition or it exists (the master then never restarts).
    /// @param editionId The edition.
    /// @return True once bound or created.
    function isBound(uint256 editionId) external view returns (bool);
    /// @notice The edition, in 6529 Stream Editions' shape.
    /// @param editionId An existing edition.
    /// @return The edition.
    function edition(uint256 editionId) external view returns (IEditions.Edition memory);
    /// @notice The master: the partner, the master's token ID and its content hash.
    /// @param editionId An existing edition.
    /// @return The partner.
    /// @return The master's token ID.
    /// @return The content hash.
    function masterOf(uint256 editionId) external view returns (address, uint256, bytes32);
    /// @notice The terms an edition of `payees` would lock now (for the sale adapter's preview).
    /// @param payees The master item's payees.
    /// @return The seller vault, fee terms and royalty receiver (rate zero).
    function previewTerms(ISplitWallet.Payee[] calldata payees)
        external
        view
        returns (WorkTerms memory);
    /// @notice The ERC-1155 collection name.
    /// @return The name.
    function name() external view returns (string memory);
    /// @notice The ERC-1155 collection symbol.
    /// @return The symbol.
    function symbol() external view returns (string memory);
}
