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
import { Splits } from "../economics/Splits.sol";
import { TokenTransfer } from "../economics/TokenTransfer.sol";
import { IAssetAllowlist } from "../economics/interfaces/IAssetAllowlist.sol";
import { IRevenueEscrow } from "../economics/interfaces/IRevenueEscrow.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IFederationRegistry } from "../interfaces/IFederationRegistry.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_EDITIONS,
    PRODUCT_FEDERATED
} from "../interfaces/types/EconomicsTypes.sol";
import {
    LockedTerms,
    Payment,
    PaymentMethod,
    PrimaryTerms
} from "../interfaces/types/SaleTypes.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { ISignatureTransfer } from "../interfaces/external/ISignatureTransfer.sol";

/// @title MintSaleBase
/// @notice What the fixed-price and Dutch adapters share (ADR 0001 sections 5, 6 and 16): the
///         token contracts they serve, terms locked when a sale opens, payment in ETH or an
///         allowlisted ERC-20 (direct, EIP-2612 permit, or a Permit2 signed payment intent),
///         minting per purchase through `IMintTarget`, proceeds pushed to the seller split
///         wallet and the network with the revenue-escrow fallback, pull-based credits, and an
///         emergency pause.
/// @dev A sale copies the token's `PrimaryTerms` when it opens, so a later change to a product
///      default only affects sales opened afterwards. The currency is resolved once, at open,
///      through `IEconomicsResolver.resolveCurrency` (6529 Editions for listed tokens, 6529
///      Stream Federated for registry tokens); `CURRENCY_DEFAULT` is accepted only with a zero
///      price, so a priced sale always names its currency. A purchase still requires its locked
///      currency to be active, so deprecating an asset halts running sales in it as an emergency
///      tightening; claims are never blocked. A token served through the federation registry
///      must run the code its entry records, pays the entry's network fee share to the
///      resolver's federated fee recipient, and stops selling when the registry delists it. The
///      token decides what may be minted (size, window, admitted minters). At most one sale per
///      `(token, id)` is open at a time. Every ERC-20 movement is checked by exact balance
///      delta, and every entry point that moves value is non-reentrant. While paused, sales
///      neither open nor sell; closing and claiming always work.
abstract contract MintSaleBase is ISaleAdapter, ERC165, AccessManaged, ReentrancyGuardTransient {
    /// @notice A sale's locked terms and state, packed so the flags share the first slot.
    /// @dev `approved` is the artist's approval of a fixed-price phase configuration;
    ///      `federated` marks a token served through the federation registry.
    struct Listing {
        address token;
        uint32 feeShare;
        bool approved;
        bool closed;
        bool federated;
        uint256 id;
        address currency;
        uint256 price;
        address seller;
        address feeRecipient;
    }

    /// @notice Gas forwarded with an ETH payout; a wallet that needs more is paid in escrow.
    uint256 public constant ETH_PAYOUT_GAS = 100_000;

    /// @notice Where a payout goes when the wallet or the token refuses it.
    IRevenueEscrow public immutable escrow;
    /// @notice The Permit2 contract that executes signed payment intents.
    ISignatureTransfer public immutable permit2;
    /// @notice The economics resolver: currency resolution and the federated fee recipient.
    IEconomicsResolver public immutable economicsResolver;
    /// @notice The resolver's asset allowlist, read on every purchase.
    IAssetAllowlist public immutable assets;

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
    /// @inheritdoc ISaleAdapter
    bool public paused;

    mapping(uint256 saleId => Listing) internal _listings;
    mapping(address token => mapping(uint256 id => uint256 saleId)) internal _openSales;

    /// @notice A required address is zero.
    error InvalidAddress();
    /// @notice The token's terms are unusable: no seller, no fee recipient for a non-zero fee
    ///         share, a fee share above the denominator, federated code that differs from its
    ///         registry entry, or a mint that returned another token ID.
    error InvalidSaleTerms(address token, uint256 id);
    /// @notice A priced sale must name its currency; `CURRENCY_DEFAULT` is for gifts only.
    error PricedDefaultCurrency(address token, uint256 id);
    /// @notice The resolver returned another currency than the one the token named.
    error CurrencyMismatch(address named, address resolved);
    /// @notice The locked currency is no longer active on the asset allowlist.
    error CurrencyNotActive(address currency);
    /// @notice A purchase must buy at least one copy.
    error InvalidQuantity();
    /// @notice The permit's deadline has passed.
    error PaymentExpired(uint256 deadline);
    /// @notice An ETH claim could not be delivered; the credit is kept.
    error ClaimFailed(address to);
    /// @notice A dependency has no code, is an EIP-7702 delegated account, or does not support
    ///         its interface through ERC-165.
    error InvalidDependency(address dependency);
    /// @notice The sale is already closed.
    error SaleAlreadyClosed(uint256 saleId);

    /// @dev Reverts while the adapter is paused.
    modifier whenNotPaused() {
        if (paused) revert SalePaused();
        _;
    }

    /// @param authority_ The AccessManager governing the setters, the pause and the PLATFORM
    ///        role.
    /// @param escrow_ The revenue escrow for refused payouts.
    /// @param permit2_ The Permit2 deployment.
    /// @param economicsResolver_ The economics resolver (ERC-165, not EIP-7702 delegated); its
    ///        asset allowlist is read once here.
    constructor(
        address authority_,
        IRevenueEscrow escrow_,
        ISignatureTransfer permit2_,
        IEconomicsResolver economicsResolver_
    ) AccessManaged(authority_) {
        if (address(escrow_) == address(0) || address(permit2_) == address(0)) {
            revert InvalidAddress();
        }
        if (!_fits(address(economicsResolver_), type(IEconomicsResolver).interfaceId)) {
            revert InvalidDependency(address(economicsResolver_));
        }
        // The economics lane's AssetAllowlist implements no ERC-165, so it is checked for code
        // and EIP-7702 delegation, and for IAssetAllowlist only if it does answer ERC-165. It
        // comes from the resolver, which passed the full check above.
        address allowlist = economicsResolver_.assetAllowlist();
        if (
            allowlist.code.length == 0 || DelegatedEOA.isDelegated(allowlist)
                || (ERC165Checker.supportsERC165(allowlist)
                    && !ERC165Checker.supportsInterface(
                        allowlist, type(IAssetAllowlist).interfaceId
                    ))
        ) revert InvalidDependency(allowlist);
        escrow = escrow_;
        permit2 = permit2_;
        economicsResolver = economicsResolver_;
        assets = IAssetAllowlist(allowlist);
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
        if (next != address(0) && !_fits(next, type(IFederationRegistry).interfaceId)) {
            revert InvalidDependency(next);
        }
        federationRegistry = next;
        federationRegistryCodeHash = next == address(0) ? bytes32(0) : next.codehash;
        emit FederationRegistrySet(expected, next);
    }

    /// @inheritdoc ISaleAdapter
    function pause() external restricted {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc ISaleAdapter
    function unpause() external restricted {
        paused = false;
        emit Unpaused(msg.sender);
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
        returns (PrimaryTerms memory t, bool federated)
    {
        federated = !isListed[token];
        if (federated && !_federated(token)) revert TargetNotAllowed(token);
        t = IMintTarget(token).primaryTerms(id, "");
        if (t.saleKind != kind) revert IMintTarget.SaleKindMismatch(kind, t.saleKind);
        if (t.currency == CURRENCY_DEFAULT && t.price != 0) {
            revert PricedDefaultCurrency(token, id);
        }
        bytes32 product = federated ? PRODUCT_FEDERATED : PRODUCT_EDITIONS;
        address resolved = economicsResolver.resolveCurrency(product, t.currency);
        if (t.currency != CURRENCY_DEFAULT && resolved != t.currency) {
            revert CurrencyMismatch(t.currency, resolved);
        }
        t.currency = resolved;
        if (federated) {
            IFederationRegistry.Entry memory e =
                IFederationRegistry(federationRegistry).entry(token);
            if (e.codeHash != token.codehash) revert InvalidSaleTerms(token, id);
            t.feeShare = e.feeShare;
            t.feeRecipient = economicsResolver.networkFeeRecipient(product);
        }
        if (
            t.seller == address(0) || (t.feeShare != 0 && t.feeRecipient == address(0))
                || t.feeShare > Splits.DENOMINATOR
        ) revert InvalidSaleTerms(token, id);
    }

    /// @dev Locks `t` under a new sale ID as the open sale of `(token, id)`; the caller has
    ///      checked that none is open.
    function _store(address token, uint256 id, PrimaryTerms memory t, bool approved, bool federated)
        internal
        returns (uint256 saleId)
    {
        saleId = nextSaleId++;
        _openSales[token][id] = saleId;
        _listings[saleId] = Listing(
            token,
            t.feeShare,
            approved,
            false,
            federated,
            id,
            t.currency,
            t.price,
            t.seller,
            t.feeRecipient
        );
    }

    /// @dev Whether the caller may run the current selector through the PLATFORM mapping now.
    function _isPlatform() internal view returns (bool) {
        (bool immediate, uint32 delay) =
            AuthorityUtils.canCallWithDelay(authority(), msg.sender, address(this), msg.sig);
        return immediate && delay == 0;
    }

    /// @dev Closes an open sale if `anyone` may, or the caller is PLATFORM or the token's
    ///      current creator.
    function _close(uint256 saleId, bool anyone) internal returns (bool authorized) {
        Listing storage l = _listing(saleId);
        if (l.closed) revert SaleAlreadyClosed(saleId);
        if (
            !anyone && !_isPlatform()
                && msg.sender != IMintTarget(l.token).primaryTerms(l.id, "").creator
        ) return false;
        l.closed = true;
        delete _openSales[l.token][l.id];
        return true;
    }

    /// @dev Takes `charge` of sale `saleId`'s currency from `pay.payer` and returns the ETH sent
    ///      above it. `value` is the payable entry point's `msg.value`. The locked currency must
    ///      be active and a federated token still listed. DIRECT and PERMIT need
    ///      `pay.payer == msg.sender`; PERMIT2 authenticates the payer by its signature over
    ///      `witness`, and both balance deltas are checked here because Permit2 does not.
    function _collect(
        uint256 saleId,
        Payment calldata pay,
        uint256 charge,
        bytes32 witness,
        string memory witnessType,
        uint256 value
    ) internal returns (uint256 excess) {
        Listing storage l = _listings[saleId];
        address currency = l.currency;
        if (!assets.isActive(currency)) revert CurrencyNotActive(currency);
        if (l.federated && !_federated(l.token)) revert TargetNotAllowed(l.token);
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
            _permit2(currency, pay, charge, witness, witnessType);
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
        Listing storage l = _listings[saleId];
        (uint256 minted,) = IMintTarget(l.token).mint(recipient, l.id, quantity, "");
        if (minted != l.id) revert InvalidSaleTerms(l.token, l.id);
        uint256 fee = Math.mulDiv(total, l.feeShare, Splits.DENOMINATOR);
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
        if (l.token == address(0)) revert UnknownSale(saleId);
    }

    /// @dev The locked terms of an existing sale.
    function _locked(Listing storage l) internal view returns (LockedTerms memory) {
        return LockedTerms(l.token, l.id, l.currency, l.price, l.seller, l.feeRecipient, l.feeShare);
    }

    /// @dev Whether `token` is active in the installed federation registry, with its code
    ///      unchanged since installation.
    function _federated(address token) internal view returns (bool) {
        address registry = federationRegistry;
        return registry != address(0) && registry.codehash == federationRegistryCodeHash
            && IFederationRegistry(registry).isActive(token);
    }

    /// @dev Pulls `charge` through a Permit2 witness transfer and checks both balance deltas.
    function _permit2(
        address currency,
        Payment calldata pay,
        uint256 charge,
        bytes32 witness,
        string memory witnessType
    ) private {
        uint256 ours = TokenTransfer.balanceOf(currency, address(this));
        uint256 theirs = TokenTransfer.balanceOf(currency, pay.payer);
        permit2.permitWitnessTransferFrom(
            ISignatureTransfer.PermitTransferFrom(
                ISignatureTransfer.TokenPermissions(currency, pay.amount), pay.nonce, pay.deadline
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
    }

    /// @dev Whether `dependency` has code, is not EIP-7702 delegated, and supports `interfaceId`.
    function _fits(address dependency, bytes4 interfaceId) private view returns (bool) {
        return dependency.code.length != 0 && !DelegatedEOA.isDelegated(dependency)
            && ERC165Checker.supportsInterface(dependency, interfaceId);
    }

    /// @dev A zero amount (no fee share, or a gift) pays nothing, so a zero-fee sale needs no
    ///      fee recipient.
    function _pay(address currency, address to, uint256 amount) private {
        if (amount != 0) {
            if (currency == CURRENCY_ETH) {
                RevenuePayment.payETH(escrow, to, amount, ETH_PAYOUT_GAS);
            } else {
                RevenuePayment.payERC20(escrow, to, currency, amount);
            }
        }
    }
}
