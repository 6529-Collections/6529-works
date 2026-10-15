// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
import { ISignatureTransfer } from "../interfaces/external/ISignatureTransfer.sol";
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
///      credited to the payer and claimed (pull). `SaleStarted.endTime` is when the curve reaches
///      its resting price. A sale the creator opens is the artist's, which PLATFORM closes only
///      while the creator resolves to zero (MARKET-6). Governance: map `openSale` and `closeSale`
///      to PLATFORM (the creator needs no role), `setTarget` and `setFederationRegistry` to SUCCESSOR_SETTER, `pause` to
///      PAUSER and `unpause` to UNPAUSER.
contract DutchSale is IDutchSale, MintSaleBase {
    mapping(uint256 saleId => Schedule) private _schedules;

    /// @param authority_ The AccessManager.
    /// @param escrow_ The revenue escrow.
    /// @param permit2_ The Permit2 deployment.
    /// @param economicsResolver_ The economics resolver.
    constructor(
        address authority_,
        IRevenueEscrow escrow_,
        ISignatureTransfer permit2_,
        IEconomicsResolver economicsResolver_
    ) MintSaleBase(authority_, escrow_, permit2_, economicsResolver_) { }

    /// @inheritdoc IDutchSale
    function openSale(address token, uint256 id, uint64 startTime)
        external
        whenNotPaused
        returns (uint256 saleId)
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (startTime < block.timestamp) revert InvalidSchedule();
        (PrimaryTerms memory t, bool federated) = _terms(token, id, SaleKind.DUTCH);
        if (msg.sender != t.creator) {
            if (!_isPlatform()) revert NotSaleManager(msg.sender);
            // MARKET-6: PLATFORM never spends an OPEN edition's one-time window.
            _requirePlatformMayOpen(token, id, federated);
        }
        if (_openSales[token][id] != 0) revert SaleAlreadyOpen(token, id);
        DutchParams memory d = abi.decode(t.params, (DutchParams));
        if (!DutchPricing.isValid(t.price, d.restingPrice, d.duration, d.stepSeconds)) {
            revert InvalidSchedule();
        }
        // A sale the creator opens is the artist's: PLATFORM cannot close it (MARKET-6).
        saleId = _store(token, id, t, msg.sender == t.creator, federated, 0);
        _schedules[saleId] = Schedule(d.restingPrice, startTime, d.duration, d.stepSeconds);
        emit SaleStarted(
            saleId,
            token,
            id,
            SaleKind.DUTCH,
            t.currency,
            t.price,
            startTime,
            startTime + d.duration
        );
    }

    /// @inheritdoc IDutchSale
    function closeSale(uint256 saleId) external {
        if (!_close(saleId, false)) revert NotSaleManager(msg.sender);
        emit SaleClosed(saleId);
    }

    /// @inheritdoc IDutchSale
    function purchase(
        uint256 saleId,
        address recipient,
        uint256 quantity,
        uint256 maxUnitPrice,
        Payment calldata payment
    ) external payable whenNotPaused nonReentrant {
        Listing storage l = _listings[saleId];
        if (l.token == address(0) || l.closed) revert SaleNotOpen(saleId);
        uint256 delay = _purchaseDelay(l);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < _schedules[saleId].startTime + delay) revert SaleNotOpen(saleId);
        if (quantity == 0) revert InvalidQuantity();
        uint256 unit = _priceNow(saleId, delay);
        if (unit > maxUnitPrice) revert PriceAboveLimit(unit, maxUnitPrice);
        uint256 total = unit * quantity;
        uint256 excess = _collect(
            saleId,
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
    /// @dev The curve runs `scheduleDelay(saleId)` seconds later than configured (MARKET-1).
    function currentPrice(uint256 saleId) external view returns (uint256) {
        Listing storage l = _listing(saleId);
        return _priceNow(saleId, _halted(l.currency) - l.haltedAtOpen);
    }

    /// @inheritdoc IDutchSale
    function sale(uint256 saleId)
        external
        view
        returns (LockedTerms memory terms, Schedule memory schedule, bool closed)
    {
        Listing storage l = _listing(saleId);
        return (_locked(l), _schedules[saleId], l.closed);
    }

    /// @inheritdoc IDutchSale
    function openSaleOf(address token, uint256 id) external view returns (uint256) {
        return _openSales[token][id];
    }

    /// @inheritdoc IDutchSale
    function scheduleDelay(uint256 saleId) external view returns (uint256) {
        return _scheduleDelay(saleId);
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

    /// @dev The unit price now, on the curve moved `delay` seconds later.
    function _priceNow(uint256 saleId, uint256 delay) private view returns (uint256) {
        Schedule storage s = _schedules[saleId];
        return DutchPricing.priceAt(
            _listings[saleId].price,
            s.restingPrice,
            s.startTime + delay,
            s.duration,
            s.stepSeconds,
            block.timestamp
        );
    }
}
