// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISaleAdapter } from "./ISaleAdapter.sol";
import { LockedTerms, Payment } from "./types/SaleTypes.sol";

/// @title IFixedPriceSale
/// @notice The shared fixed-price adapter, with allowlist phases and permit payments
///         (ADR 0001 sections 5 and 6). 6529 Editions sells copies through it.
/// @dev Price, currency and supply come from the token (`IMintTarget`), never from the sale
///      configuration; the sale only schedules phases. At most one sale per `(token, id)` is open
///      at a time (`openSaleOf`).
///
///      Allowlists: a phase with a nonzero `root` admits a wallet by OpenZeppelin `MerkleProof`
///      (sorted pairs) of the leaf `keccak256(bytes.concat(keccak256(abi.encode(
///      ALLOWLIST_LEAF_DOMAIN, block.chainid, address(this), token, id, phase, account, cap,
///      price))))`, with `ALLOWLIST_LEAF_DOMAIN = keccak256("6529WORKS_ALLOWLIST_LEAF_V1")`.
///      `account` is the wallet that actually receives the tokens, or the payer when the phase
///      is `payerKeyed` (this binds the leaf to the recipient and fixes PR #744's High finding).
///      `cap` is the per-wallet limit of the phase and `price` the per-wallet unit price, used
///      only when the phase is `leafPriced`. A phase with a zero `root` is public, limited per
///      recipient by `walletCap` (zero means no limit). Purchases name their phase.
///
///      Artist consent (MARKET-6): a leaf-priced phase (prices below or above the package price),
///      or a sale of an OPEN edition (its one-time window starts at the first mint), opens only
///      if the artist approved the phases, by opening the sale as the `creator` or by the
///      creator's `Typehashes.PHASE_CONFIGURATION` signature, which binds the resolved currency,
///      the package unit price and every phase as a typed `Phase[]` (single-use revocable nonce).
///      Alone, PLATFORM opens unpriced phases of a FIXED edition only. Purchase counts are kept
///      per edition `(token, id, phase, account)`, not per sale, so reopening a sale cannot reset
///      a cap. Only capped phases count (an allowlist, or a nonzero `walletCap`): an uncapped
///      public phase records nothing, so a per-wallet cap counts only the purchases made in
///      capped phases.
///      `saleKind()` is `SaleKind.FIXED_PRICE`; PERMIT2 purchases use
///      `Typehashes.PURCHASE_WITNESS`, and `payment.amount` is the exact total.
interface IFixedPriceSale is ISaleAdapter {
    /// @notice One phase of a sale.
    struct Phase {
        uint64 start;
        uint64 end;
        bytes32 root;
        uint32 walletCap;
        bool payerKeyed;
        bool leafPriced;
    }

    /// @notice The creator's signed approval of a phase configuration; empty `signature` when
    ///         the creator opens the sale itself or no approval is needed.
    /// @dev An authority the artist rotated away from is never the creator again, so its unused
    ///      consents stay void; a new authority that is an ERC-1271 or EIP-7702 wallet accepting
    ///      the old key's signatures revives them (the artist's own configuration).
    struct ArtistConsent {
        uint256 nonce;
        uint64 deadline;
        bytes signature;
    }

    /// @notice One purchase.
    /// @param recipient Who receives the tokens (the payer when zero).
    /// @param leafCap The `cap` of the caller's allowlist leaf (ignored in public phases).
    /// @param leafPrice The `price` of the caller's leaf (ignored unless `leafPriced`).
    struct Purchase {
        uint256 saleId;
        uint256 phase;
        address recipient;
        uint256 quantity;
        uint256 leafCap;
        uint256 leafPrice;
    }

    /// @notice A sale's phases were set when it opened, with or without the artist's approval.
    event PhasesSet(uint256 indexed saleId, Phase[] phases, bool artistApproved);
    /// @notice A sale was closed before its supply or phases ran out.
    event SaleClosed(uint256 indexed saleId);
    /// @notice A creator revoked an unused phase-configuration nonce.
    event ConsentNonceRevoked(address indexed creator, uint256 indexed nonce);

    /// @notice The phase is unknown or not open now, or the sale is closed.
    error PhaseNotOpen(uint256 saleId, uint256 phase);
    /// @notice The allowlist proof does not verify.
    error NotAllowlisted(uint256 saleId, uint256 phase, address account);
    /// @notice The purchase exceeds the wallet's cap in this phase.
    error WalletCapExceeded(uint256 saleId, uint256 phase, address account);
    /// @notice The consent is expired, its nonce is used, or the signature is not the creator's.
    error InvalidArtistConsent();

    /// @notice Opens a sale of token `id` with 1 to `Limits.MAX_PHASES` phases. Callable by the
    ///         creator or the PLATFORM role; a PLATFORM opener may pass the creator's `consent`,
    ///         which must verify and consumes its nonce. Without it, PLATFORM may open only
    ///         unpriced phases (the package price) of a listed edition of FIXED size.
    function openSale(
        address token,
        uint256 id,
        Phase[] calldata phases,
        ArtistConsent calldata consent
    ) external returns (uint256 saleId);
    /// @notice Closes a sale. Callable by the creator at any time; by the PLATFORM role for a
    ///         sale it opened without the artist's approval, or for any sale while the creator
    ///         resolves to zero (a pending recovery override, MARKET-6); and by anyone once all
    ///         of its phases have ended.
    function closeSale(uint256 saleId) external;
    /// @notice Buys `p.quantity` copies at the phase's unit price.
    function purchase(Purchase calldata p, bytes32[] calldata proof, Payment calldata payment)
        external
        payable;
    /// @notice Revokes one of the caller's unused phase-configuration nonces.
    function revokeConsentNonce(uint256 nonce) external;

    /// @notice A sale's locked terms, whether the artist approved its phases, and whether it is
    ///         closed.
    function sale(uint256 saleId)
        external
        view
        returns (LockedTerms memory terms, bool artistApproved, bool closed);
    /// @notice The open sale of `(token, id)`, or zero.
    function openSaleOf(address token, uint256 id) external view returns (uint256 saleId);
    /// @notice Seconds the sale's phase windows have moved since it opened: the adapter's pauses
    ///         and its currency's deprecations since then, running ones included (MARKET-1).
    ///         Overlapping halts count twice. Reverts for an unknown sale.
    function scheduleDelay(uint256 saleId) external view returns (uint256);
    /// @notice A sale's phases.
    function phases(uint256 saleId) external view returns (Phase[] memory);
    /// @notice Copies `account` bought of token `id` in phase `phase` (counted against its cap),
    ///         in capped phases only: an uncapped public phase adds nothing.
    function purchased(address token, uint256 id, uint256 phase, address account)
        external
        view
        returns (uint256);
    /// @notice Whether a creator's phase-configuration nonce is used or revoked.
    function isConsentNonceUsed(address creator, uint256 nonce) external view returns (bool);
    /// @notice The allowlist leaf for the given values, as defined above.
    function allowlistLeaf(
        address token,
        uint256 id,
        uint256 phase,
        address account,
        uint256 cap,
        uint256 price
    ) external view returns (bytes32);
}
