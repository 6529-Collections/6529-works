// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAssetAllowlist } from "../economics/interfaces/IAssetAllowlist.sol";
import { IRevenueEscrow } from "../economics/interfaces/IRevenueEscrow.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IDutchSale } from "../interfaces/IDutchSale.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH } from "../interfaces/types/EconomicsTypes.sol";
import {
    DutchParams,
    LockedTerms,
    Payment,
    PrimaryTerms,
    SaleKind
} from "../interfaces/types/SaleTypes.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { DutchPricing } from "./DutchPricing.sol";
import { ISignatureTransfer } from "./ISignatureTransfer.sol";
import { MintSaleBase } from "./MintSaleBase.sol";

/// @title DutchSale
/// @notice The shared descending-price adapter (ADR 0001 sections 5 and 6) for 6529 Editions
///         and future federated contracts. The curve comes from the token's terms
///         (`DutchParams`); the sale only fixes when it starts.
/// @dev Clearing semantics: there is no clearing price. Each purchase pays the unit price of
///      the block it lands in (see `DutchPricing`), copies already sold are never repriced or
///      rebated when the price later falls, and after the curve ends the price rests at
///      `restingPrice` until the token's supply or window runs out or the sale is closed. A buyer
///      bounds the price with `maxUnitPrice`; `Payment.amount` is the most the payer will pay
///      (integrator decision D17): an ERC-20 payment pulls exactly the charge, and ETH above it is
///      credited to the payer and claimed (pull). Governance: map `openSale` and `closeSale` to
///      PLATFORM (the creator needs no role), `setTarget` and `setFederationRegistry` to
///      SUCCESSOR_SETTER.
contract DutchSale is IDutchSale, MintSaleBase {
    mapping(uint256 saleId => Schedule) private _schedules;

    /// @notice The start time is in the past, or the token's curve is invalid.
    error InvalidSchedule();

    /// @param authority_ The AccessManager.
    /// @param escrow_ The revenue escrow.
    /// @param assets_ The currency allowlist.
    /// @param permit2_ The Permit2 deployment.
    /// @param economicsResolver_ The economics resolver.
    constructor(
        address authority_,
        IRevenueEscrow escrow_,
        IAssetAllowlist assets_,
        ISignatureTransfer permit2_,
        IEconomicsResolver economicsResolver_
    ) MintSaleBase(authority_, escrow_, assets_, permit2_, economicsResolver_) { }

    /// @inheritdoc IDutchSale
    function openSale(address token, uint256 id, uint64 startTime)
        external
        returns (uint256 saleId)
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (startTime < block.timestamp) revert InvalidSchedule();
        (LockedTerms memory locked, PrimaryTerms memory t) = _terms(token, id, SaleKind.DUTCH);
        if (msg.sender != t.creator && !_isPlatform()) revert NotSaleManager(msg.sender);
        if (_openSales[token][id] != 0) revert SaleAlreadyOpen(token, id);
        DutchParams memory d = abi.decode(t.params, (DutchParams));
        if (!DutchPricing.isValid(t.price, d.restingPrice, d.duration, d.stepSeconds)) {
            revert InvalidSchedule();
        }
        saleId = _store(locked, false);
        _schedules[saleId] = Schedule(d.restingPrice, startTime, d.duration, d.stepSeconds);
        emit SaleStarted(saleId, token, id, SaleKind.DUTCH, locked.currency, t.price, startTime, 0);
    }

    /// @inheritdoc IDutchSale
    function closeSale(uint256 saleId) external {
        if (!_close(saleId)) revert NotSaleManager(msg.sender);
        emit SaleClosed(saleId);
    }

    /// @inheritdoc IDutchSale
    function purchase(
        uint256 saleId,
        address recipient,
        uint256 quantity,
        uint256 maxUnitPrice,
        Payment calldata payment
    ) external payable nonReentrant {
        Listing storage l = _listings[saleId];
        if (
            l.terms.token == address(0) || l.closed
                // forge-lint: disable-next-line(block-timestamp)
                || block.timestamp < _schedules[saleId].startTime
        ) revert SaleNotOpen(saleId);
        if (quantity == 0) revert InvalidQuantity();
        uint256 unit = _priceNow(saleId);
        if (unit > maxUnitPrice) revert PriceAboveLimit(unit, maxUnitPrice);
        uint256 total = unit * quantity;
        uint256 excess = _collect(
            l.terms.currency,
            payment,
            total,
            keccak256(
                abi.encode(
                    Typehashes.DUTCH_PURCHASE_WITNESS,
                    saleId,
                    recipient,
                    quantity,
                    maxUnitPrice,
                    payment.deadline
                )
            ),
            Typehashes.DUTCH_PURCHASE_WITNESS_TYPE,
            msg.value
        );
        if (excess != 0) {
            claimable[payment.payer][CURRENCY_ETH] += excess;
            emit Credited(payment.payer, CURRENCY_ETH, saleId, excess);
        }
        _settle(
            saleId,
            payment.payer,
            recipient == address(0) ? payment.payer : recipient,
            quantity,
            total
        );
    }

    /// @inheritdoc IDutchSale
    function currentPrice(uint256 saleId) external view returns (uint256) {
        _listing(saleId);
        return _priceNow(saleId);
    }

    /// @inheritdoc IDutchSale
    function sale(uint256 saleId)
        external
        view
        returns (LockedTerms memory terms, Schedule memory schedule, bool closed)
    {
        Listing storage l = _listing(saleId);
        return (l.terms, _schedules[saleId], l.closed);
    }

    /// @inheritdoc IDutchSale
    function openSaleOf(address token, uint256 id) external view returns (uint256) {
        return _openSales[token][id];
    }

    /// @inheritdoc ISaleAdapter
    function saleKind() external pure returns (bytes32) {
        return SaleKind.DUTCH;
    }

    /// @inheritdoc MintSaleBase
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(IERC165, MintSaleBase)
        returns (bool)
    {
        return interfaceId == type(IDutchSale).interfaceId || super.supportsInterface(interfaceId);
    }

    function _priceNow(uint256 saleId) private view returns (uint256) {
        Schedule storage s = _schedules[saleId];
        return DutchPricing.priceAt(
            _listings[saleId].terms.price,
            s.restingPrice,
            s.startTime,
            s.duration,
            s.stepSeconds,
            block.timestamp
        );
    }
}
