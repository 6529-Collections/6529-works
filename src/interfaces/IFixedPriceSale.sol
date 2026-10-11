// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISaleAdapter } from "./ISaleAdapter.sol";
import { Payment } from "./types/SaleTypes.sol";

/// @title IFixedPriceSale
/// @notice The shared fixed-price adapter, with allowlist phases and permit payments
///         (ADR 0001 sections 5 and 6). 6529 Editions sells copies through it.
/// @dev Price, currency and supply come from the token (`IMintTarget`), never from the sale
///      configuration; the sale only schedules phases. A phase with a nonzero `root` admits a
///      wallet by Merkle proof of the leaf
///      `keccak256(bytes.concat(keccak256(abi.encode(ALLOWLIST_LEAF_DOMAIN, block.chainid,
///      address(this), saleId, phaseIndex, account, cap, price))))`, where
///      `ALLOWLIST_LEAF_DOMAIN = keccak256("6529WORKS_ALLOWLIST_LEAF_V1")`, the tree uses
///      OpenZeppelin `MerkleProof` sorted pairs, and `account` is the wallet that actually
///      receives the tokens, or the payer when the phase is `payerKeyed` (this binds the leaf to
///      the recipient and fixes PR #744's High finding). `cap` is the per-wallet limit of the
///      phase and `price` the per-wallet unit price, used only when the phase is `leafPriced`.
///      A phase with a zero `root` is public, limited per recipient by `walletCap` (zero means
///      no limit). Phases may overlap in time; purchases name their phase.
///      `saleKind()` is `SaleKind.FIXED_PRICE`.
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

    /// @notice A sale's locked terms. `closed` is set by `closeSale`.
    struct FixedSale {
        address token;
        uint256 id;
        address currency;
        uint256 price;
        address seller;
        address feeRecipient;
        uint32 feeShare;
        address creator;
        bool closed;
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

    /// @notice A sale's phases were set when it opened.
    event PhasesSet(uint256 indexed saleId, Phase[] phases);
    /// @notice A sale was closed before its supply or phases ran out.
    event SaleClosed(uint256 indexed saleId);

    /// @notice The phase is unknown, not open now, or the sale is closed.
    error PhaseNotOpen(uint256 saleId, uint256 phase);
    /// @notice The allowlist proof does not verify.
    error NotAllowlisted(uint256 saleId, uint256 phase, address account);
    /// @notice The purchase exceeds the wallet's cap in this phase.
    error WalletCapExceeded(uint256 saleId, uint256 phase, address account);
    /// @notice The caller is neither the token's creator nor the PLATFORM role.
    error NotSaleManager(address caller);

    /// @notice Opens a sale of token `id` with 1 to `Limits.MAX_PHASES` phases. Callable by the
    ///         lead artist (the terms' `creator`) or the PLATFORM role.
    function openSale(address token, uint256 id, Phase[] calldata phases)
        external
        returns (uint256 saleId);

    /// @notice Closes a sale. Callable by the creator or the PLATFORM role.
    function closeSale(uint256 saleId) external;

    /// @notice Buys `p.quantity` copies; `payment.amount` must equal quantity times the unit
    ///         price.
    function purchase(Purchase calldata p, bytes32[] calldata proof, Payment calldata payment)
        external
        payable;

    /// @notice A sale's locked terms.
    function sale(uint256 saleId) external view returns (FixedSale memory);
    /// @notice A sale's phases.
    function phases(uint256 saleId) external view returns (Phase[] memory);
    /// @notice Copies `account` bought in a phase (counted against its cap).
    function purchased(uint256 saleId, uint256 phase, address account)
        external
        view
        returns (uint256);
    /// @notice The allowlist leaf for the given values, as defined above.
    function allowlistLeaf(
        uint256 saleId,
        uint256 phase,
        address account,
        uint256 cap,
        uint256 price
    ) external view returns (bytes32);
}
