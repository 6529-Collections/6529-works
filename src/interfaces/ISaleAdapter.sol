// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISaleAdapter
/// @notice The surface every shared sale adapter has in common (ADR 0001 section 5): the
///         start, settlement and claim events, the sale kind, the admitted token contracts, and
///         pull-based credits.
/// @dev Adapters mint only through `IMintTarget` and lock the returned `PrimaryTerms` when a sale
///      starts. Proceeds are pushed to the seller split wallet and the network fee recipient;
///      a push that fails is credited to the revenue escrow instead, so no recipient can block
///      a sale. Refunds and overpayments are credited here and claimed by the account (pull).
///      Every ERC-20 movement is checked by exact balance delta. A sale ID is unique within one
///      adapter.
interface ISaleAdapter {
    /// @notice A sale started (an auction opened, or a fixed-price or Dutch sale opened).
    /// @param price The opening price: the opening bid for an auction, the unit price for fixed
    ///        price, the starting price for Dutch.
    /// @param startTime When bids or purchases open; zero while an auction awaits its VRF seed.
    /// @param endTime When the sale ends; zero if it has no fixed end or awaits its seed.
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
    /// @param recipient Who received the tokens (the lead artist when there were no bids).
    /// @param quantity The number of tokens sold.
    /// @param currency The locked currency.
    /// @param price The realized total price, equal to `sellerProceeds + fee`.
    /// @param seller The artist-portion split wallet.
    /// @param sellerProceeds The amount paid (or escrowed) to `seller`.
    /// @param feeRecipient The network recipient.
    /// @param fee The amount paid (or escrowed) to `feeRecipient`.
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

    /// @notice A token contract was admitted to or removed from this adapter.
    event TargetSet(address indexed token, bool allowed);

    /// @notice The token contract is not admitted.
    error TargetNotAllowed(address token);
    /// @notice The terms name another sale kind than this adapter's.
    error SaleKindMismatch(bytes32 expected, bytes32 actual);
    /// @notice The caller has nothing to claim in this currency.
    error NothingToClaim(address account, address currency);
    /// @notice The payment does not match the method, the amount, `msg.value` or the payer.
    error InvalidPayment();

    /// @notice This adapter's `SaleKind` label.
    function saleKind() external view returns (bytes32);

    /// @notice Whether `token` may be sold through this adapter.
    function isTarget(address token) external view returns (bool);

    /// @notice Admits or removes a token contract for new sales. SUCCESSOR_SETTER role.
    ///         Running sales finish.
    function setTarget(address token, bool allowed) external;

    /// @notice What `account` may claim in `currency`.
    function claimable(address account, address currency) external view returns (uint256);

    /// @notice Sends all of the caller's credits in `currency` to `to`.
    /// @return amount The amount sent.
    function claim(address currency, address to) external returns (uint256 amount);
}
