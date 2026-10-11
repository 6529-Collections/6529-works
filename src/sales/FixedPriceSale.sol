// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IRevenueEscrow } from "../economics/interfaces/IRevenueEscrow.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IFixedPriceSale } from "../interfaces/IFixedPriceSale.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { LockedTerms, Payment, PrimaryTerms, SaleKind } from "../interfaces/types/SaleTypes.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";
import { ISignatureTransfer } from "../interfaces/external/ISignatureTransfer.sol";
import { MintSaleBase } from "./MintSaleBase.sol";

/// @title FixedPriceSale
/// @notice The shared fixed-price adapter with allowlist phases (ADR 0001 sections 5 and 6).
///         6529 Editions sells copies through it; a zero package price, or a zero leaf price the
///         artist approved, makes it a gift (no network fee either).
/// @dev Leaves bind `(chainid, adapter, token, id, phase, account, cap, price)` (see
///      {allowlistLeaf}), so a tree is built before the sale opens; tooling must emit at most one
///      leaf per account and phase. `account` is the wallet that receives the tokens, or the
///      payer in a payer-keyed phase, and the payer is always authenticated (`msg.sender`, or
///      the Permit2 signer): nobody can spend another wallet's leaf for themselves (PR #744's
///      High finding). Anyone may still pay for an allowlisted recipient; the tokens go to that
///      recipient and count against its cap. Caps, public phases included, count per
///      `(token, id, phase index, keyed wallet)` across sales, so reopening a token with the
///      same tree never resets them; a fresh drop uses new phase indices. A leaf price below the
///      package price needs the artist's approval: the creator opens the sale, or signs the
///      typed `Typehashes.PHASE_CONFIGURATION` (token, currency, package price, every phase),
///      with a single-use, revocable nonce. Anyone may close a sale whose phases have all
///      ended. Governance: map `openSale` and `closeSale` to PLATFORM (the creator needs no
///      role), `setTarget` and `setFederationRegistry` to SUCCESSOR_SETTER, `pause` to PAUSER
///      and `unpause` to UNPAUSER.
contract FixedPriceSale is IFixedPriceSale, MintSaleBase, EIP712 {
    /// @notice The EIP-712 struct hashed for {phaseConfigurationDigest} (phases as an array).
    struct Configuration {
        address token;
        uint256 id;
        address currency;
        uint256 packagePrice;
        bytes32 phasesHash;
        uint256 nonce;
        uint64 deadline;
    }

    /// @notice Domain label of allowlist leaves.
    bytes32 public constant ALLOWLIST_LEAF_DOMAIN = keccak256("6529WORKS_ALLOWLIST_LEAF_V1");

    mapping(uint256 saleId => Phase[]) private _phases;
    mapping(
        address token
            => mapping(uint256 id => mapping(uint256 phase => mapping(address account => uint256)))
    ) private _purchased;

    /// @inheritdoc IFixedPriceSale
    mapping(address creator => mapping(uint256 nonce => bool)) public isConsentNonceUsed;

    /// @notice The phases are empty, too many, or one is malformed (start not before end, or an
    ///         allowlist-only flag without a root).
    error InvalidPhases();
    /// @notice A zero-price sale prices its leaves without the artist's approval.
    error PricedLeavesNeedApproval(address token, uint256 id);

    /// @param authority_ The AccessManager.
    /// @param escrow_ The revenue escrow.
    /// @param permit2_ The Permit2 deployment.
    /// @param economicsResolver_ The economics resolver.
    constructor(
        address authority_,
        IRevenueEscrow escrow_,
        ISignatureTransfer permit2_,
        IEconomicsResolver economicsResolver_
    )
        MintSaleBase(authority_, escrow_, permit2_, economicsResolver_)
        EIP712(Typehashes.FIXED_PRICE_SALE_NAME, Typehashes.DOMAIN_VERSION)
    { }

    /// @inheritdoc IFixedPriceSale
    function openSale(
        address token,
        uint256 id,
        Phase[] calldata phases_,
        ArtistConsent calldata consent
    ) external whenNotPaused returns (uint256 saleId) {
        (PrimaryTerms memory t, bool federated) = _terms(token, id, SaleKind.FIXED_PRICE);
        bool approved = msg.sender == t.creator;
        if (!approved && !_isPlatform()) revert NotSaleManager(msg.sender);
        if (_openSales[token][id] != 0) revert SaleAlreadyOpen(token, id);
        (uint64 start, uint64 end, bool priced) = _checkPhases(phases_);
        if (consent.signature.length != 0) {
            _consume(token, id, t, phases_, consent);
            approved = true;
        }
        // In a zero-price sale every leaf price is a premium, so only the artist may price leaves.
        if (priced && t.price == 0 && !approved) revert PricedLeavesNeedApproval(token, id);
        saleId = _store(token, id, t, approved, federated);
        for (uint256 i; i < phases_.length; ++i) {
            _phases[saleId].push(phases_[i]);
        }
        emit SaleStarted(saleId, token, id, SaleKind.FIXED_PRICE, t.currency, t.price, start, end);
        emit PhasesSet(saleId, phases_, approved);
    }

    /// @inheritdoc IFixedPriceSale
    function revokeConsentNonce(uint256 nonce) external {
        if (isConsentNonceUsed[msg.sender][nonce]) revert InvalidArtistConsent();
        isConsentNonceUsed[msg.sender][nonce] = true;
        emit ConsentNonceRevoked(msg.sender, nonce);
    }

    /// @inheritdoc IFixedPriceSale
    /// @dev Anyone may close a sale whose phases have all ended, freeing its token.
    function closeSale(uint256 saleId) external {
        if (!_close(saleId, _ended(saleId))) revert NotSaleManager(msg.sender);
        emit SaleClosed(saleId);
    }

    /// @inheritdoc IFixedPriceSale
    function purchase(Purchase calldata p, bytes32[] calldata proof, Payment calldata payment)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        address recipient = p.recipient == address(0) ? payment.payer : p.recipient;
        uint256 total = _admit(p, proof, payment.payer, recipient) * p.quantity;
        if (payment.amount != total) revert InvalidPayment();
        _collect(
            p.saleId,
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
        return (_locked(l), l.approved, l.closed);
    }

    /// @inheritdoc IFixedPriceSale
    function openSaleOf(address token, uint256 id) external view returns (uint256) {
        return _openSales[token][id];
    }

    /// @inheritdoc IFixedPriceSale
    /// @dev Shared by every sale of `(token, id)` at that phase index.
    function purchased(address token, uint256 id, uint256 phase, address account)
        external
        view
        returns (uint256)
    {
        return _purchased[token][id][phase][account];
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

    /// @notice The EIP-712 digest a creator signs to approve `phases_` for token `id` sold in
    ///         `currency` at `packagePrice` (the sale's resolved currency and package price).
    function phaseConfigurationDigest(
        address token,
        uint256 id,
        address currency,
        uint256 packagePrice,
        Phase[] calldata phases_,
        uint256 nonce,
        uint64 deadline
    ) public view returns (bytes32) {
        Configuration memory c = Configuration(
            token, id, currency, packagePrice, _hashPhases(phases_), nonce, deadline
        );
        return _hashTypedDataV4(keccak256(abi.encode(Typehashes.PHASE_CONFIGURATION, c)));
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

    /// @dev Verifies and spends the creator's approval of `phases_` at the resolved terms.
    function _consume(
        address token,
        uint256 id,
        PrimaryTerms memory t,
        Phase[] calldata phases_,
        ArtistConsent calldata consent
    ) private {
        bytes32 digest = phaseConfigurationDigest(
            token, id, t.currency, t.price, phases_, consent.nonce, consent.deadline
        );
        if (
            // forge-lint: disable-next-line(block-timestamp)
            block.timestamp > consent.deadline || isConsentNonceUsed[t.creator][consent.nonce]
                || !SignatureVerifier.isValid(t.creator, digest, consent.signature)
        ) revert InvalidArtistConsent();
        isConsentNonceUsed[t.creator][consent.nonce] = true;
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
        unit = l.price;
        if (phase.root != 0) {
            _verifyLeaf(p, proof, phase.root, account, l);
            if (phase.leafPriced) {
                if (p.leafPrice < unit && !l.approved) revert PriceBelowPackage(p.leafPrice, unit);
                unit = p.leafPrice;
            }
        }
        address token = l.token;
        uint256 id = l.id;
        uint256 bought = _purchased[token][id][p.phase][account] + p.quantity;
        if (
            (phase.root != 0 && bought > p.leafCap)
                || (phase.walletCap != 0 && bought > phase.walletCap)
        ) revert WalletCapExceeded(p.saleId, p.phase, account);
        _purchased[token][id][p.phase][account] = bought;
    }

    function _verifyLeaf(
        Purchase calldata p,
        bytes32[] calldata proof,
        bytes32 root,
        address account,
        Listing storage l
    ) private view {
        bytes32 leaf = allowlistLeaf(l.token, l.id, p.phase, account, p.leafCap, p.leafPrice);
        if (proof.length > Limits.MAX_PROOF_DEPTH || !MerkleProof.verifyCalldata(proof, root, leaf))
        {
            revert NotAllowlisted(p.saleId, p.phase, account);
        }
    }

    /// @dev Whether every phase of the sale has ended (an unknown sale has none).
    function _ended(uint256 saleId) private view returns (bool) {
        Phase[] storage list = _phases[saleId];
        for (uint256 i; i < list.length; ++i) {
            // forge-lint: disable-next-line(block-timestamp)
            if (list[i].end > block.timestamp) return false;
        }
        return true;
    }

    function _hashPhases(Phase[] calldata phases_) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](phases_.length);
        for (uint256 i; i < phases_.length; ++i) {
            hashes[i] = keccak256(abi.encode(Typehashes.PHASE, phases_[i]));
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _checkPhases(Phase[] calldata phases_)
        private
        pure
        returns (uint64 start, uint64 end, bool priced)
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
            priced = priced || phase.leafPriced;
        }
    }
}
