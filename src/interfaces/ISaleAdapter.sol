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
    /// @notice A sale started (an auction opened, or a fixed-price or Dutch sale opened).
    /// @param price The opening price: the opening bid for an auction, the unit price for fixed
    ///        price, the starting price for Dutch.
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

    /// @notice A sale settled: an auction ended, or one purchase completed.
    /// @param buyer The paying bidder or buyer; zero when an auction drew no bids.
    /// @param recipient Who received the tokens (the artist when there were no bids).
    /// @param price The realized total price, equal to `sellerProceeds + fee`.
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

    /// @notice `amount` was credited to `account` (an outbid refund, a withdrawn bid, or an
    ///         overpayment) and is claimable.
    event Credited(
        address indexed account, address indexed currency, uint256 indexed saleId, uint256 amount
    );
    /// @notice `account` claimed `amount` of its credits to `to`.
    event Claimed(
        address indexed account, address indexed currency, address indexed to, uint256 amount
    );
    /// @notice Governance listed or unlisted a token contract.
    event TargetSet(address indexed token, bool listed);
    /// @notice The federation registry changed.
    event FederationRegistrySet(address previous, address next);
    /// @notice `account` paused the adapter.
    event Paused(address account);
    /// @notice `account` unpaused the adapter.
    event Unpaused(address account);

    /// @notice The token contract is neither listed nor active in the federation registry.
    error TargetNotAllowed(address token);
    /// @notice The caller has nothing to claim in this currency.
    error NothingToClaim(address account, address currency);
    /// @notice The payment does not match the method, the amount, `msg.value` or the payer.
    error InvalidPayment();
    /// @notice No sale has this ID.
    error UnknownSale(uint256 saleId);
    /// @notice The adapter is paused, so no sale may open, start or sell.
    error SalePaused();
    /// @notice A sale of this token is already open.
    error SaleAlreadyOpen(address token, uint256 id);
    /// @notice The caller is neither the token's creator nor the PLATFORM role.
    error NotSaleManager(address caller);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();

    /// @notice This adapter's `SaleKind` label.
    function saleKind() external view returns (bytes32);
    /// @notice Pauses the adapter: no new opens or purchases, and for the auction no new `start`.
    ///         Bids on live auctions, settlements, claims and closes continue. PAUSER role
    ///         (immediate).
    function pause() external;
    /// @notice Unpauses the adapter. UNPAUSER role.
    function unpause() external;
    /// @notice Whether the adapter is paused.
    function paused() external view returns (bool);
    /// @notice Whether `token` may be sold: listed by governance, or active in the federation
    ///         registry.
    function isTarget(address token) external view returns (bool);
    /// @notice Lists or unlists a token contract for new sales. SUCCESSOR_SETTER role. Running
    ///         sales finish.
    function setTarget(address token, bool listed) external;
    /// @notice The federation registry, or zero before v1.1.
    function federationRegistry() external view returns (address);
    /// @notice Sets the federation registry. SUCCESSOR_SETTER role, compare-and-set.
    function setFederationRegistry(address expected, address next) external;
    /// @notice What `account` may claim in `currency`.
    function claimable(address account, address currency) external view returns (uint256);
    /// @notice Sends all of the caller's credits in `currency` to `to`.
    function claim(address currency, address to) external returns (uint256 amount);
}
