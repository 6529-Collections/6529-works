// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { IAssetAllowlist } from "../economics/interfaces/IAssetAllowlist.sol";
import { IRevenueEscrow } from "../economics/interfaces/IRevenueEscrow.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IFixedPriceSale } from "../interfaces/IFixedPriceSale.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { LockedTerms, Payment, PrimaryTerms, SaleKind } from "../interfaces/types/SaleTypes.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";
import { ISignatureTransfer } from "./ISignatureTransfer.sol";
import { MintSaleBase } from "./MintSaleBase.sol";

/// @title FixedPriceSale
/// @notice The shared fixed-price adapter with allowlist phases (ADR 0001 sections 5 and 6).
///         6529 Editions sells copies through it; a zero package price, or a zero leaf price the
///         artist approved, makes it a gift.
/// @dev Leaves bind `(chainid, adapter, token, id, phase, account, cap, price)` (see
///      {allowlistLeaf}), so a tree is built before the sale opens. `account` is the wallet that
///      receives the tokens, or the payer in a payer-keyed phase, and the payer is always
///      authenticated (`msg.sender`, or the Permit2 signer): nobody can spend another wallet's
///      leaf for themselves (PR #744's High finding). Anyone may still pay for an allowlisted
///      recipient; the tokens go to that recipient and count against its cap. Caps count per
///      `(token, id, phase, account)`, across sales, so reopening a token with the same tree
///      never resets them; a fresh drop uses new phase indices. A leaf price below the package
///      price needs the artist's
///      approval: the creator opens the sale, or signs the `PhaseConfiguration` with a
///      single-use, revocable nonce. Governance: map `openSale` and `closeSale` to PLATFORM (the
///      creator needs no role), `setTarget` and `setFederationRegistry` to SUCCESSOR_SETTER.
contract FixedPriceSale is IFixedPriceSale, MintSaleBase, EIP712 {
    /// @notice Domain label of allowlist leaves.
    bytes32 public constant ALLOWLIST_LEAF_DOMAIN = keccak256("6529WORKS_ALLOWLIST_LEAF_V1");
    /// @notice The longest accepted Merkle proof (trees of up to 2**32 leaves).
    uint256 public constant MAX_PROOF_DEPTH = 32;

    mapping(uint256 saleId => Phase[]) private _phases;

    /// @notice Copies each keyed wallet bought, per token, ID and phase index, across sales.
    mapping(
        address token
            => mapping(uint256 id => mapping(uint256 phase => mapping(address account => uint256)))
    ) public purchasedOf;

    /// @inheritdoc IFixedPriceSale
    mapping(address creator => mapping(uint256 nonce => bool)) public isConsentNonceUsed;

    /// @notice The phases are empty, too many, or one is malformed (start not before end, or an
    ///         allowlist-only flag without a root).
    error InvalidPhases();

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
    )
        MintSaleBase(authority_, escrow_, assets_, permit2_, economicsResolver_)
        EIP712(Typehashes.FIXED_PRICE_SALE_NAME, Typehashes.DOMAIN_VERSION)
    { }

    /// @inheritdoc IFixedPriceSale
    function openSale(
        address token,
        uint256 id,
        Phase[] calldata phases_,
        ArtistConsent calldata consent
    ) external returns (uint256 saleId) {
        (LockedTerms memory locked, PrimaryTerms memory t) = _terms(token, id, SaleKind.FIXED_PRICE);
        bool approved = msg.sender == t.creator;
        if (!approved && !_isPlatform()) revert NotSaleManager(msg.sender);
        if (_openSales[token][id] != 0) revert SaleAlreadyOpen(token, id);
        (uint64 start, uint64 end) = _checkPhases(phases_);
        if (consent.signature.length != 0) {
            _consume(
                t.creator,
                phaseConfigurationDigest(token, id, phases_, consent.nonce, consent.deadline),
                consent
            );
            approved = true;
        }
        saleId = _store(locked, approved);
        for (uint256 i; i < phases_.length; ++i) {
            _phases[saleId].push(phases_[i]);
        }
        emit SaleStarted(
            saleId, token, id, SaleKind.FIXED_PRICE, locked.currency, locked.price, start, end
        );
        emit PhasesSet(saleId, phases_, approved);
    }

    /// @inheritdoc IFixedPriceSale
    function revokeConsentNonce(uint256 nonce) external {
        if (isConsentNonceUsed[msg.sender][nonce]) revert InvalidArtistConsent();
        isConsentNonceUsed[msg.sender][nonce] = true;
        emit ConsentNonceRevoked(msg.sender, nonce);
    }

    /// @inheritdoc IFixedPriceSale
    function closeSale(uint256 saleId) external {
        if (!_close(saleId)) revert NotSaleManager(msg.sender);
        emit SaleClosed(saleId);
    }

    /// @inheritdoc IFixedPriceSale
    function purchase(Purchase calldata p, bytes32[] calldata proof, Payment calldata payment)
        external
        payable
        nonReentrant
    {
        address recipient = p.recipient == address(0) ? payment.payer : p.recipient;
        uint256 total = _admit(p, proof, payment.payer, recipient) * p.quantity;
        if (payment.amount != total) revert InvalidPayment();
        _collect(
            _listings[p.saleId].terms.currency,
            payment,
            total,
            keccak256(
                abi.encode(
                    Typehashes.PURCHASE_WITNESS,
                    p.saleId,
                    p.phase,
                    p.recipient,
                    p.quantity,
                    total,
                    payment.deadline
                )
            ),
            Typehashes.PURCHASE_WITNESS_TYPE,
            msg.value
        );
        _settle(p.saleId, payment.payer, recipient, p.quantity, total);
    }

    /// @inheritdoc IFixedPriceSale
    function sale(uint256 saleId)
        external
        view
        returns (LockedTerms memory terms, bool artistApproved, bool closed)
    {
        Listing storage l = _listing(saleId);
        return (l.terms, l.approved, l.closed);
    }

    /// @inheritdoc IFixedPriceSale
    function openSaleOf(address token, uint256 id) external view returns (uint256) {
        return _openSales[token][id];
    }

    /// @inheritdoc IFixedPriceSale
    /// @dev The count of the sale's `(token, id)` at that phase index, shared by every sale of
    ///      the token.
    function purchased(uint256 saleId, uint256 phase, address account)
        external
        view
        returns (uint256)
    {
        LockedTerms storage terms = _listing(saleId).terms;
        return purchasedOf[terms.token][terms.id][phase][account];
    }

    /// @inheritdoc IFixedPriceSale
    function phases(uint256 saleId) external view returns (Phase[] memory) {
        _listing(saleId);
        return _phases[saleId];
    }

    /// @inheritdoc ISaleAdapter
    function saleKind() external pure returns (bytes32) {
        return SaleKind.FIXED_PRICE;
    }

    /// @inheritdoc IFixedPriceSale
    function allowlistLeaf(
        address token,
        uint256 id,
        uint256 phase,
        address account,
        uint256 cap,
        uint256 price
    ) public view returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        ALLOWLIST_LEAF_DOMAIN,
                        block.chainid,
                        address(this),
                        token,
                        id,
                        phase,
                        account,
                        cap,
                        price
                    )
                )
            )
        );
    }

    /// @notice The EIP-712 digest a creator signs to approve `phases_` for token `id`
    ///         (`Typehashes.PHASE_CONFIGURATION` in this contract's domain).
    function phaseConfigurationDigest(
        address token,
        uint256 id,
        Phase[] calldata phases_,
        uint256 nonce,
        uint64 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    Typehashes.PHASE_CONFIGURATION,
                    token,
                    id,
                    keccak256(abi.encode(phases_)),
                    nonce,
                    deadline
                )
            )
        );
    }

    /// @inheritdoc MintSaleBase
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(IERC165, MintSaleBase)
        returns (bool)
    {
        return interfaceId == type(IFixedPriceSale).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @dev Verifies and spends the creator's approval.
    function _consume(address creator, bytes32 digest, ArtistConsent calldata consent) private {
        if (
            // forge-lint: disable-next-line(block-timestamp)
            block.timestamp > consent.deadline || isConsentNonceUsed[creator][consent.nonce]
                || !SignatureVerifier.isValid(creator, digest, consent.signature)
        ) revert InvalidArtistConsent();
        isConsentNonceUsed[creator][consent.nonce] = true;
    }

    /// @dev Checks the phase is open, the leaf, the price and the caps; counts the purchase;
    ///      returns the unit price.
    function _admit(Purchase calldata p, bytes32[] calldata proof, address payer, address recipient)
        private
        returns (uint256 unit)
    {
        Phase[] storage list = _phases[p.saleId];
        Listing storage l = _listings[p.saleId];
        if (p.phase >= list.length || l.closed) revert PhaseNotOpen(p.saleId, p.phase);
        Phase memory phase = list[p.phase];
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < phase.start || block.timestamp >= phase.end) {
            revert PhaseNotOpen(p.saleId, p.phase);
        }
        if (p.quantity == 0) revert InvalidQuantity();
        address account = phase.payerKeyed ? payer : recipient;
        unit = l.terms.price;
        if (phase.root != 0) {
            _verifyLeaf(p, proof, phase.root, account, l.terms);
            if (phase.leafPriced) {
                if (p.leafPrice < unit && !l.approved) revert PriceBelowPackage(p.leafPrice, unit);
                unit = p.leafPrice;
            }
        }
        address token = l.terms.token;
        uint256 id = l.terms.id;
        uint256 bought = purchasedOf[token][id][p.phase][account] + p.quantity;
        if (
            (phase.root != 0 && bought > p.leafCap)
                || (phase.walletCap != 0 && bought > phase.walletCap)
        ) revert WalletCapExceeded(p.saleId, p.phase, account);
        purchasedOf[token][id][p.phase][account] = bought;
    }

    function _verifyLeaf(
        Purchase calldata p,
        bytes32[] calldata proof,
        bytes32 root,
        address account,
        LockedTerms storage terms
    ) private view {
        bytes32 leaf = allowlistLeaf(
            terms.token, terms.id, p.phase, account, p.leafCap, p.leafPrice
        );
        if (proof.length > MAX_PROOF_DEPTH || !MerkleProof.verifyCalldata(proof, root, leaf)) {
            revert NotAllowlisted(p.saleId, p.phase, account);
        }
    }

    function _checkPhases(Phase[] calldata phases_)
        private
        pure
        returns (uint64 start, uint64 end)
    {
        if (phases_.length == 0 || phases_.length > Limits.MAX_PHASES) revert InvalidPhases();
        start = type(uint64).max;
        for (uint256 i; i < phases_.length; ++i) {
            Phase calldata phase = phases_[i];
            if (
                phase.start >= phase.end
                    || (phase.root == 0 && (phase.payerKeyed || phase.leafPriced))
            ) revert InvalidPhases();
            if (phase.start < start) start = phase.start;
            if (phase.end > end) end = phase.end;
        }
    }
}
