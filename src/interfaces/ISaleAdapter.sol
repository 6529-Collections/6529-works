// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ISaleAdapter
/// @notice The surface every shared sale adapter has in common (ADR 0001 sections 5 and 16): the
///         start, settlement and claim events, the sale kind, the token contracts it serves, and
///         pull-based credits.
/// @dev Adapters mint only through `IMintTarget` and lock `LockedTerms` when a sale starts,
///      reading them back from the token where it stores them. Proceeds are pushed to the seller
///      split wallet (a predicted CREATE2 address that may not be deployed: adapters pay it by
///      plain transfer and never deploy it on a sale path) and to the fee recipient; a push that
///      fails is deposited in the revenue escrow instead. Refunds and overpayments are credited
///      here and claimed by the account. Every ERC-20 movement is checked by exact balance delta.
///      Federation readiness: a token is served when governance listed it, or when the
///      federation registry reports it active, in which case the network fee comes from its
///      registry entry, not from the token.
interface ISaleAdapter is IERC165 {
    /// @notice A sale started: an English auction started, or an edition sale opened.
    /// @param saleId The new sale's ID.
    /// @param token The token contract the sale mints from.
    /// @param tokenId The token ID: the minted token for an English auction, the edition ID for
    ///        an edition sale.
    /// @param saleKind The adapter's `SaleKind` label.
    /// @param currency The locked currency, zero for ETH.
    /// @param price The opening price: the opening bid for an English auction; each sale
    ///        method defines its own (the edition auction's is its base step price).
    /// @param startTime When the sale starts, in Unix seconds.
    /// @param endTime The end as configured, in Unix seconds: for an auction its first end
    ///        (bids may extend it); each sale method defines its own.
    event SaleStarted(
        uint256 indexed saleId,
        address indexed token,
        uint256 indexed tokenId,
        bytes32 saleKind,
        address currency,
        uint256 price,
        uint64 startTime,
        uint64 endTime
    );

    /// @notice A sale settled: an English auction ended, or an edition sale settled.
    /// @param saleId The sale's ID.
    /// @param token The token contract.
    /// @param tokenId The token ID (the edition ID for an edition sale).
    /// @param buyer The paying bidder or buyer; zero when no bid won an auction, and zero for an
    ///        edition auction, whose winners claim later (`IUniformEditionAuction.BidClaimed`).
    /// @param recipient Who receives the tokens: when no bid won an English auction, the 6529
    ///        Network Museum, or a federated work's artist (ADR 0005); zero for an edition
    ///        auction.
    /// @param quantity The number of tokens sold: 1 for an English auction, the copies sold
    ///        otherwise (an edition auction's count, possibly zero).
    /// @param currency The locked currency, zero for ETH.
    /// @param price The realized total price, equal to `sellerProceeds + fee`.
    /// @param seller The seller split wallet.
    /// @param sellerProceeds The seller's share of the price, `price - fee`.
    /// @param feeRecipient The network fee recipient, or zero when the terms name none.
    /// @param fee The network fee: `price` times the fee share out of 100,000, rounded down.
    event SaleSettled(
        uint256 indexed saleId,
        address indexed token,
        uint256 indexed tokenId,
        address buyer,
        address recipient,
        uint256 quantity,
        address currency,
        uint256 price,
        address seller,
        uint256 sellerProceeds,
        address feeRecipient,
        uint256 fee
    );

    /// @notice `amount` was credited to `account` and is claimable: an outbid refund, a
    ///         withdrawn bid, or an ETH overpayment; for the auction also the high bid refunded by
    ///         a dispute cancel or by a sale ending unsold (a currency freeze past its 30 days, or
    ///         a delisted federated contract), and an ERC-20 settlement payout that failed in its
    ///         own frame (MONEY-1), which `IEnglishAuction.claimFor` pays out.
    /// @param account The account credited: the bidder or buyer, or (MONEY-1) the seller or fee
    ///        wallet.
    /// @param currency The credit's currency, zero for ETH.
    /// @param saleId The sale the credit comes from.
    /// @param amount The amount credited, in the currency's base units.
    event Credited(
        address indexed account, address indexed currency, uint256 indexed saleId, uint256 amount
    );
    /// @notice `account` claimed `amount` of its credits to `to`.
    /// @param account The account whose credits were paid out.
    /// @param currency The currency claimed, zero for ETH.
    /// @param to The address the credits were sent to.
    /// @param amount The amount sent: all of the account's credits in `currency`, in base units.
    event Claimed(
        address indexed account, address indexed currency, address indexed to, uint256 amount
    );
    /// @notice Governance listed or unlisted a token contract.
    /// @param token The token contract.
    /// @param listed Whether the token is now listed.
    event TargetSet(address indexed token, bool listed);
    /// @notice The federation registry changed.
    /// @param previous The registry before the change, or zero.
    /// @param next The registry after the change, or zero when none is installed.
    event FederationRegistrySet(address previous, address next);
    /// @notice `account` paused the adapter.
    /// @param account The caller that paused it.
    event Paused(address account);
    /// @notice `account` unpaused the adapter.
    /// @param account The caller that unpaused it.
    event Unpaused(address account);

    /// @notice The token contract is neither listed nor active in the federation registry.
    error TargetNotAllowed(address token);
    /// @notice The caller has nothing to claim in this currency.
    error NothingToClaim(address account, address currency);
    /// @notice The payment does not match the method, the amount, `msg.value` or the payer.
    error InvalidPayment();
    /// @notice A PERMIT or PERMIT2 payment's deadline has passed.
    error PaymentExpired(uint256 deadline);
    /// @notice No sale has this ID.
    error UnknownSale(uint256 saleId);
    /// @notice The adapter is paused, so no sale may open, start or sell; also a repeated
    ///         `pause`.
    error SalePaused();
    /// @notice `unpause` was called while the adapter is not paused.
    error NotPaused();
    /// @notice An unpause (or an auction's `resume`) before `allowedAt`, which is 48 hours
    ///         (`Roles.STANDARD`) after the pause it would end.
    error UnpauseTooEarly(uint256 allowedAt);
    /// @notice The address cannot receive the token or the credit (for `claim`, zero).
    error InvalidRecipient(address recipient);
    /// @notice An ETH claim could not be delivered to `to`; the credit is kept.
    error ClaimFailed(address to);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();
    /// @notice The token returned unusable terms. Every adapter: no seller, the revenue escrow
    ///         as seller or fee recipient, no fee recipient for a nonzero fee share, a fee share
    ///         above the denominator, federated code that differs from its registry entry, or a
    ///         mint that returned another token ID. The auction also: a token ID of 2^32 or more,
    ///         no creator (a pending recovery override), a nonzero price or sale parameters, the
    ///         token not in its custody after the mint, or, for a federated token, an escrow or
    ///         zero network fee recipient for a nonzero registry fee. Other adapters add
    ///         their own cases.
    error InvalidSaleTerms(address token, uint256 id);

    /// @notice This adapter's `SaleKind` label: a token mints only for an admitted adapter whose
    ///         label equals its terms' kind. A new sale method claims a new label (ADR 0005,
    ///         owner decision 14).
    /// @return `SaleKind.ENGLISH_AUCTION`, `SaleKind.UNIFORM_AUCTION`, rc.1's
    ///         `SaleKind.FIXED_PRICE` or `SaleKind.DUTCH`, or a later adapter's own label.
    function saleKind() external view returns (bytes32);
    /// @notice Pauses the adapter: no new opens or purchases, and for the auction no new `start`.
    ///         Bids on live auctions, settlements, claims and closes continue. PAUSER role
    ///         (immediate).
    function pause() external;
    /// @notice Unpauses the adapter. UNPAUSER role. Refused until 48 hours (`Roles.STANDARD`)
    ///         after the pause, so the guardians always have the standard delay to cancel an
    ///         unpause, even one scheduled before the pause.
    function unpause() external;
    /// @notice Whether the adapter is paused.
    /// @return True from `pause` until `unpause`.
    function paused() external view returns (bool);
    /// @notice Whether `token` may be sold: listed by governance, or active in the federation
    ///         registry.
    /// @param token The token contract.
    /// @return True when listed, or active in an installed registry whose code is unchanged.
    function isTarget(address token) external view returns (bool);
    /// @notice Lists or unlists a token contract for new sales. SUCCESSOR_SETTER role. Running
    ///         sales finish. Listing checks the token like any dependency
    ///         (`Dependency.InvalidDependency`): code, not an EIP-7702 delegated account, and
    ///         ERC-165 support for the surface the adapter calls.
    /// @param token The token contract: ERC-721 for the English auction; each edition adapter
    ///        names the tokens it serves (the edition auction, 6529 Stream Editions only).
    /// @param listed True to list the token, false to unlist it.
    function setTarget(address token, bool listed) external;
    /// @notice The federation registry, or zero before v1.1.
    /// @return The registry's address, or zero.
    function federationRegistry() external view returns (address);
    /// @notice Sets the federation registry. SUCCESSOR_SETTER role, compare-and-set.
    /// @param expected The registry the caller expects is installed now; a stale value reverts.
    /// @param next The new registry, or zero to remove it; a nonzero one must support
    ///        `IFederationRegistry` through ERC-165.
    function setFederationRegistry(address expected, address next) external;
    /// @notice What `account` may claim in `currency`.
    /// @param account The credited account.
    /// @param currency The currency, zero for ETH.
    /// @return The account's credits in `currency`, in base units.
    function claimable(address account, address currency) external view returns (uint256);
    /// @notice Sends all of the caller's credits in `currency` to `to`.
    /// @param currency The currency to claim, zero for ETH.
    /// @param to The address that receives the credits; zero reverts.
    /// @return amount The amount sent, in the currency's base units.
    function claim(address currency, address to) external returns (uint256 amount);
}
