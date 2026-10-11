// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { AuthorityUtils } from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { RevenuePayment } from "../economics/RevenuePayment.sol";
import { TokenTransfer } from "../economics/TokenTransfer.sol";
import { IAssetAllowlist } from "../economics/interfaces/IAssetAllowlist.sol";
import { IRevenueEscrow } from "../economics/interfaces/IRevenueEscrow.sol";
import { IFederationRegistry } from "../interfaces/IFederationRegistry.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_EDITIONS,
    PRODUCT_FEDERATED,
    SHARE_DENOMINATOR
} from "../interfaces/types/EconomicsTypes.sol";
import {
    LockedTerms,
    Payment,
    PaymentMethod,
    PrimaryTerms
} from "../interfaces/types/SaleTypes.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { ISignatureTransfer } from "./ISignatureTransfer.sol";

/// @title MintSaleBase
/// @notice What the fixed-price and Dutch adapters share (ADR 0001 sections 5, 6 and 16): the
///         token contracts they serve, terms locked when a sale opens, payment in ETH or an
///         allowlisted ERC-20 (direct, EIP-2612 permit, or a Permit2 signed payment intent),
///         minting per purchase through `IMintTarget`, proceeds pushed to the seller split
///         wallet and the network with the revenue-escrow fallback, and pull-based credits.
/// @dev A sale copies the token's `PrimaryTerms` into `LockedTerms` when it opens, so a later
///      change to a product default only affects sales opened afterwards. `CURRENCY_DEFAULT` is
///      resolved once, at open, through the asset allowlist (6529 Editions for listed tokens,
///      6529 Stream Federated for registry tokens). A purchase still requires its locked
///      currency to be active, so deprecating an asset halts running sales in it as an
///      emergency tightening; claims are never blocked. A token served through the federation
///      registry pays the network fee share of its registry entry, not its own. The token
///      decides what may be minted (size, window, admitted adapters). At most one sale per
///      `(token, id)` is open at a time. Every ERC-20 movement is checked by exact balance
///      delta, and every entry point that moves value is non-reentrant.
abstract contract MintSaleBase is ISaleAdapter, ERC165, AccessManaged, ReentrancyGuardTransient {
    /// @notice A sale: its locked terms, whether the artist approved its phases (fixed price
    ///         only), and whether it is closed.
    struct Listing {
        LockedTerms terms;
        bool approved;
        bool closed;
    }

    /// @notice Gas forwarded with an ETH payout; a wallet that needs more is paid in escrow.
    uint256 public constant ETH_PAYOUT_GAS = 100_000;

    /// @notice Where a payout goes when the wallet or the token refuses it.
    IRevenueEscrow public immutable escrow;
    /// @notice The governed currency allowlist.
    IAssetAllowlist public immutable assets;
    /// @notice The Permit2 contract that executes signed payment intents.
    ISignatureTransfer public immutable permit2;

    /// @notice The ID the next sale gets; sale IDs start at 1.
    uint256 public nextSaleId = 1;
    /// @notice Whether governance listed `token`.
    mapping(address token => bool) public isListed;
    /// @inheritdoc ISaleAdapter
    mapping(address account => mapping(address currency => uint256)) public claimable;
    /// @inheritdoc ISaleAdapter
    address public federationRegistry;
    /// @notice The code hash pinned when the federation registry was installed.
    bytes32 public federationRegistryCodeHash;

    mapping(uint256 saleId => Listing) internal _listings;
    mapping(address token => mapping(uint256 id => uint256 saleId)) internal _openSales;

    /// @notice A required address is zero.
    error InvalidAddress();
    /// @notice No sale has this ID.
    error UnknownSale(uint256 saleId);
    /// @notice The token's terms are unusable: no seller or fee recipient, a fee share above the
    ///         denominator, or a mint that returned another token ID.
    error InvalidSaleTerms(address token, uint256 id);
    /// @notice The currency is not active on the asset allowlist.
    error CurrencyNotActive(address currency);
    /// @notice A purchase must buy at least one copy.
    error InvalidQuantity();
    /// @notice The permit's deadline has passed.
    error PaymentExpired(uint256 deadline);
    /// @notice An ETH claim could not be delivered; the credit is kept.
    error ClaimFailed(address to);
    /// @notice The registry has no code, is an EIP-7702 delegated account, or does not support
    ///         `IFederationRegistry` through ERC-165.
    error InvalidRegistry(address registry);

    /// @param authority_ The AccessManager governing `setTarget`, `setFederationRegistry` and
    ///        the PLATFORM role.
    /// @param escrow_ The revenue escrow for refused payouts.
    /// @param assets_ The currency allowlist.
    /// @param permit2_ The Permit2 deployment.
    constructor(
        address authority_,
        IRevenueEscrow escrow_,
        IAssetAllowlist assets_,
        ISignatureTransfer permit2_
    ) AccessManaged(authority_) {
        if (
            address(escrow_) == address(0) || address(assets_) == address(0)
                || address(permit2_) == address(0)
        ) revert InvalidAddress();
        escrow = escrow_;
        assets = assets_;
        permit2 = permit2_;
    }

    /// @inheritdoc ISaleAdapter
    function setTarget(address token, bool listed) external restricted {
        if (token == address(0)) revert InvalidAddress();
        isListed[token] = listed;
        emit TargetSet(token, listed);
    }

    /// @inheritdoc ISaleAdapter
    /// @dev Installing checks ERC-165 support for `IFederationRegistry`, rejects EIP-7702
    ///      delegated accounts and pins the code hash; a registry whose code changes is ignored.
    function setFederationRegistry(address expected, address next) external restricted {
        if (federationRegistry != expected) revert ExpectedValueMismatch();
        if (
            next != address(0)
                && (next.code.length == 0
                    || DelegatedEOA.isDelegated(next)
                    || !ERC165Checker.supportsInterface(
                        next, type(IFederationRegistry).interfaceId
                    ))
        ) revert InvalidRegistry(next);
        federationRegistry = next;
        federationRegistryCodeHash = next == address(0) ? bytes32(0) : next.codehash;
        emit FederationRegistrySet(expected, next);
    }

    /// @inheritdoc ISaleAdapter
    function claim(address currency, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert InvalidAddress();
        amount = claimable[msg.sender][currency];
        if (amount == 0) revert NothingToClaim(msg.sender, currency);
        claimable[msg.sender][currency] = 0;
        emit Claimed(msg.sender, currency, to, amount);
        if (currency != CURRENCY_ETH) {
            TokenTransfer.transferExact(currency, to, amount);
        } else if (!TokenTransfer.sendETH(to, amount, gasleft())) {
            revert ClaimFailed(to);
        }
    }

    /// @inheritdoc ISaleAdapter
    function isTarget(address token) public view returns (bool) {
        return isListed[token] || _federated(token);
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(ISaleAdapter).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev The token's terms for a new sale of `kind`, resolved and checked to fail closed.
    function _terms(address token, uint256 id, bytes32 kind)
        internal
        view
        returns (LockedTerms memory locked, PrimaryTerms memory t)
    {
        bool listed = isListed[token];
        if (!listed && !_federated(token)) revert TargetNotAllowed(token);
        t = IMintTarget(token).primaryTerms(id, "");
        if (t.saleKind != kind) revert IMintTarget.SaleKindMismatch(kind, t.saleKind);
        if (!listed) t.feeShare = IFederationRegistry(federationRegistry).entry(token).feeShare;
        if (t.currency == CURRENCY_DEFAULT) {
            t.currency = assets.defaultCurrency(listed ? PRODUCT_EDITIONS : PRODUCT_FEDERATED);
        }
        if (!assets.isActive(t.currency)) revert CurrencyNotActive(t.currency);
        if (
            t.seller == address(0) || t.feeRecipient == address(0) || t.feeShare > SHARE_DENOMINATOR
        ) revert InvalidSaleTerms(token, id);
        locked = LockedTerms(token, id, t.currency, t.price, t.seller, t.feeRecipient, t.feeShare);
    }

    /// @dev Locks `locked` under a new sale ID as the open sale of its `(token, id)`; the caller
    ///      has checked that none is open.
    function _store(LockedTerms memory locked, bool approved) internal returns (uint256 saleId) {
        saleId = nextSaleId++;
        _openSales[locked.token][locked.id] = saleId;
        _listings[saleId] = Listing(locked, approved, false);
    }

    /// @dev Whether the caller may run the current selector through the PLATFORM mapping now.
    function _isPlatform() internal view returns (bool) {
        (bool immediate, uint32 delay) =
            AuthorityUtils.canCallWithDelay(authority(), msg.sender, address(this), msg.sig);
        return immediate && delay == 0;
    }

    /// @dev Closes a sale if the caller is PLATFORM or the token's current creator.
    function _close(uint256 saleId) internal returns (bool authorized) {
        Listing storage l = _listing(saleId);
        LockedTerms storage terms = l.terms;
        if (
            !_isPlatform()
                && msg.sender != IMintTarget(terms.token).primaryTerms(terms.id, "").creator
        ) return false;
        if (!l.closed) {
            l.closed = true;
            delete _openSales[terms.token][terms.id];
        }
        return true;
    }

    /// @dev Takes `charge` of the sale's currency from `pay.payer` and returns the ETH sent above
    ///      it. `value` is the payable entry point's `msg.value`. DIRECT and PERMIT need
    ///      `pay.payer == msg.sender`; PERMIT2 authenticates the payer by its signature over
    ///      `witness`, and both balance deltas are checked here because Permit2 does not.
    function _collect(
        address currency,
        Payment calldata pay,
        uint256 charge,
        bytes32 witness,
        string memory witnessType,
        uint256 value
    ) internal returns (uint256 excess) {
        if (!assets.isActive(currency)) revert CurrencyNotActive(currency);
        if (pay.amount < charge) revert InvalidPayment();
        if (currency == CURRENCY_ETH) {
            if (
                pay.method != PaymentMethod.DIRECT || pay.payer != msg.sender || value != pay.amount
            ) revert InvalidPayment();
            return pay.amount - charge;
        }
        if (value != 0) revert InvalidPayment();
        // forge-lint: disable-next-line(block-timestamp)
        if (pay.method != PaymentMethod.DIRECT && block.timestamp > pay.deadline) {
            revert PaymentExpired(pay.deadline);
        }
        if (pay.method == PaymentMethod.PERMIT2) {
            uint256 ours = TokenTransfer.balanceOf(currency, address(this));
            uint256 theirs = TokenTransfer.balanceOf(currency, pay.payer);
            permit2.permitWitnessTransferFrom(
                ISignatureTransfer.PermitTransferFrom(
                    ISignatureTransfer.TokenPermissions(currency, pay.amount),
                    pay.nonce,
                    pay.deadline
                ),
                ISignatureTransfer.SignatureTransferDetails(address(this), charge),
                pay.payer,
                witness,
                witnessType,
                pay.signature
            );
            if (
                TokenTransfer.balanceOf(currency, address(this)) != ours + charge
                    || TokenTransfer.balanceOf(currency, pay.payer) != theirs - charge
            ) revert TokenTransfer.TokenBalanceMismatch(currency);
            return 0;
        }
        if (pay.payer != msg.sender) revert InvalidPayment();
        if (pay.method == PaymentMethod.PERMIT) {
            (uint8 v, bytes32 r, bytes32 s) = ECDSA.parseCalldata(pay.signature);
            // A permit already submitted by someone else fails here; the pull below then
            // succeeds only on the allowance that permit (or the payer) granted.
            try IERC20Permit(currency)
                .permit(pay.payer, address(this), pay.amount, pay.deadline, v, r, s) { }
                catch { }
        }
        if (charge != 0) TokenTransfer.pullExact(currency, pay.payer, charge);
    }

    /// @dev Mints to `recipient`, pays the fee and the seller (escrow on refusal), and emits.
    function _settle(
        uint256 saleId,
        address buyer,
        address recipient,
        uint256 quantity,
        uint256 total
    ) internal {
        LockedTerms storage l = _listings[saleId].terms;
        (uint256 minted,) = IMintTarget(l.token).mint(recipient, l.id, quantity, "");
        if (minted != l.id) revert InvalidSaleTerms(l.token, l.id);
        uint256 fee = Math.mulDiv(total, l.feeShare, SHARE_DENOMINATOR);
        _pay(l.currency, l.feeRecipient, fee);
        _pay(l.currency, l.seller, total - fee);
        emit SaleSettled(
            saleId,
            l.token,
            l.id,
            buyer,
            recipient,
            quantity,
            l.currency,
            total,
            l.seller,
            total - fee,
            l.feeRecipient,
            fee
        );
    }

    /// @dev The listing of an existing sale.
    function _listing(uint256 saleId) internal view returns (Listing storage l) {
        l = _listings[saleId];
        if (l.terms.token == address(0)) revert UnknownSale(saleId);
    }

    /// @dev Whether `token` is active in the installed federation registry, with its code
    ///      unchanged since installation.
    function _federated(address token) internal view returns (bool) {
        address registry = federationRegistry;
        return registry != address(0) && registry.codehash == federationRegistryCodeHash
            && IFederationRegistry(registry).isActive(token);
    }

    function _pay(address currency, address to, uint256 amount) private {
        if (currency == CURRENCY_ETH) {
            RevenuePayment.payETH(escrow, to, amount, ETH_PAYOUT_GAS);
        } else {
            RevenuePayment.payERC20(escrow, to, currency, amount);
        }
    }
}
