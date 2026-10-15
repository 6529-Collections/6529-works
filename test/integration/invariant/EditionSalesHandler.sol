// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { CURRENCY_DEFAULT, CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionFormat,
    EditionTerms,
    ItemKind,
    PackageItem
} from "src/interfaces/types/PackageTypes.sol";
import { DutchParams, Payment, PaymentMethod, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { IntegrationBase } from "../IntegrationBase.sol";

/// @notice The handler of the Editions sales invariant suite: 6529 Editions, the fixed-price
///         adapter and the Dutch adapter on the real stack (`IntegrationBase`), with the asset
///         allowlist, the AccessManager and the records satellite that re-rates a master.
/// @dev Inherited by the invariant test, which targets itself (no handler contract size limit).
///      Every action is bounded and never reverts (`fail_on_revert`): it predicts the outcome
///      from the protocol's rules and an independent model of time and halts, runs the call
///      inside `try`, and records any disagreement in `violations`.
///
///      Seven edition masters by one artist, sold at auction in `setUp`: fixed size and open
///      window, fixed price and Dutch, ETH and an EIP-2612 ERC-20 (`usd`, admitted at genesis
///      through the 14-day FUNDS_SETTER path), and a free edition priced in the default
///      currency. Four buyers hold keys for EIP-2612 and Permit2 signatures; a relayer submits
///      Permit2 intents.
///
///      Every fixed-price sale of an edition uses the same three phases (only the times move),
///      so a phase index always has the same caps: phase 0 is a recipient-keyed allowlist
///      (leaf-priced when the artist approved the sale), phase 1 a payer-keyed allowlist, phase
///      2 public with a wallet cap.
abstract contract EditionSalesHandler is IntegrationBase {
    uint256 internal constant MASTERS = 7;
    uint256 internal constant BUYERS = 4;
    uint32 internal constant PUBLIC_CAP = 3;
    uint256 internal constant DENOMINATOR = 100_000;
    /// @dev A sale price whose royalty share rounds, for the royalty check.
    uint256 internal constant ODD_PRICE = 1_234_567_891;

    /// @dev One edition master and its edition terms.
    struct Master {
        uint256 tokenId;
        bytes item;
        bytes32 root;
        bytes32[] proof;
        bool created;
        address currency;
        address royaltyReceiver;
        bytes32 phase0Root;
        bytes32 phase1Root;
        /// @dev The edition's terms and economics, as created (they never change).
        EditionTerms terms;
        DutchParams dutch;
        uint32 feeShare;
        address seller;
        address feeRecipient;
    }

    /// @dev What the handler expects of one sale (fixed price or Dutch).
    struct SaleGhost {
        uint256 master;
        bool approved;
        bool closed;
        /// @dev The model's halt clock (adapter pauses plus currency deprecations) at open.
        uint256 haltedAtOpen;
        uint64 dutchStart;
        IFixedPriceSale.Phase[3] phases;
    }

    /// @dev A purchase's predicted price and the balances it moves.
    struct Charge {
        address currency;
        uint256 unit;
        uint256 total;
        uint256 fee;
        address seller;
        address feeRecipient;
        uint256 sellerBefore;
        uint256 feeBefore;
    }

    /// @dev A fixed-price purchase: the purchase, its proof, the payer's and the keyed buyer's
    ///      indexes, and the payment method's seed.
    struct FixedBuy {
        IFixedPriceSale.Purchase p;
        bytes32[] proof;
        uint256 payer;
        uint256 keyed;
        uint256 method;
    }

    address internal edArtist;
    address internal edCollector = makeAddr("editionsMasterCollector");
    address[BUYERS] internal buyers;
    /// @dev The buyers, as a dynamic array for `balanceOfBatch`.
    address[] internal holders;
    address internal relayer = makeAddr("editionsRelayer");
    Master[MASTERS] internal masters;
    /// @dev Phase 0 caps and leaf-price factors (percent of the package price), and phase 1 caps.
    uint256[BUYERS] internal cap0 = [uint256(2), 3, 1, 4];
    uint256[BUYERS] internal priceFactor0 = [uint256(50), 120, 0, 80];
    uint256[BUYERS] internal cap1 = [uint256(1), 2, 2, 1];

    mapping(uint256 saleId => SaleGhost) internal fixedSales;
    mapping(uint256 saleId => SaleGhost) internal dutchSales;
    uint256 internal fixedCount;
    uint256 internal dutchCount;

    /// @dev The model's halt clocks: closed pause seconds and the running pause's start per
    ///      adapter; closed deprecation seconds and the running deprecation's start per currency.
    mapping(address adapter => uint256) internal pausedTotal;
    mapping(address adapter => uint256) internal pausedSince;
    mapping(address currency => uint256) internal frozenTotal;
    mapping(address currency => uint256) internal frozenSince;

    mapping(uint256 editionId => uint256) internal ghostMinted;
    mapping(uint256 editionId => uint256) internal ghostWindowStart;
    /// @dev Paid in and paid out (sellers and the network) per currency, and Dutch ETH credits.
    mapping(address currency => uint256) internal ghostPaid;
    mapping(address currency => uint256) internal ghostReceived;
    uint256 internal ghostCredits;
    uint256 internal permit2Nonce;
    uint256 internal consentNonce;
    /// @dev Dutch credits already claimed (paid in, credited, then sent back).
    uint256 internal ghostClaimed;
    string[] internal violations;
    mapping(bytes32 path => uint256) public hits;

    function setUp() public virtual override {
        super.setUp();
        edArtist = _actor("editionsArtist");
        for (uint256 i; i < BUYERS; ++i) {
            buyers[i] = _actor(string.concat("editionsBuyer", vm.toString(i)));
            holders.push(buyers[i]);
            vm.prank(buyers[i]);
            usd.approve(PERMIT2, type(uint256).max);
        }
        _govern(
            hotAdmin,
            address(allowlist),
            abi.encodeCall(allowlist.admitAsset, (address(usd), 0, 1e16))
        );
        Work[] memory works = new Work[](MASTERS);
        EditionTerms[MASTERS] memory terms = _terms();
        for (uint256 i; i < MASTERS; ++i) {
            works[i] = _work(edArtist, collectionId);
            works[i].item.kind = ItemKind.EDITION_MASTER;
            works[i].item.edition = terms[i];
        }
        bytes32 root = _publish(works);
        for (uint256 i; i < MASTERS; ++i) {
            Master storage m = masters[i];
            (uint256 saleId, uint256 tokenId) = _start(root, works, i);
            _ethBid(saleId, edCollector, 1 ether);
            _settleAtEnd(saleId);
            records.openRecord(tokenId, works[i].item, works[i].media);
            m.tokenId = tokenId;
            m.item = abi.encode(works[i].item);
            m.root = root;
            m.proof = _proofOf(works, i);
            m.currency = terms[i].currency == CURRENCY_DEFAULT ? CURRENCY_ETH : terms[i].currency;
            m.terms = terms[i];
            if (terms[i].saleKind == SaleKind.DUTCH) {
                m.dutch = abi.decode(terms[i].params, (DutchParams));
            }
            (m.phase0Root, m.phase1Root) = _allowlists(tokenId, terms[i].price);
        }
        // Two editions exist at genesis; the rest come from `createEdition`.
        _createEdition(0);
        _createEdition(3);
    }

    /// @dev The seven edition terms: FIXED and OPEN, fixed price and Dutch (linear and
    ///      stepped), ETH and `usd`, and a free edition in the default currency.
    function _terms() internal view returns (EditionTerms[MASTERS] memory t) {
        address u = address(usd);
        bytes32 fp = SaleKind.FIXED_PRICE;
        bytes32 du = SaleKind.DUTCH;
        t[0] = EditionTerms(EditionFormat.FIXED, 24, 0, 0.05 ether, CURRENCY_ETH, fp, "");
        t[1] = EditionTerms(EditionFormat.FIXED, 20, 0, 10e18, u, fp, "");
        t[2] = EditionTerms(EditionFormat.OPEN, 30, 3 days, 0.02 ether, CURRENCY_ETH, fp, "");
        t[3] = EditionTerms(
            EditionFormat.FIXED,
            16,
            0,
            0.2 ether,
            CURRENCY_ETH,
            du,
            abi.encode(DutchParams(0.02 ether, 6 hours, 0))
        );
        t[4] = EditionTerms(
            EditionFormat.FIXED,
            12,
            0,
            40e18,
            u,
            du,
            abi.encode(DutchParams(4e18, 4 hours, 30 minutes))
        );
        t[5] = EditionTerms(
            EditionFormat.OPEN,
            40,
            2 days,
            0.1 ether,
            CURRENCY_ETH,
            du,
            abi.encode(DutchParams(0.01 ether, 1 days, 1 hours))
        );
        t[6] = EditionTerms(EditionFormat.FIXED, 10, 0, 0, CURRENCY_DEFAULT, fp, "");
    }

    /// @dev The phase 0 (recipient-keyed, leaf-priced) and phase 1 (payer-keyed) allowlist roots
    ///      of edition `id`.
    function _allowlists(uint256 id, uint256 price) internal view returns (bytes32, bytes32) {
        bytes32[] memory leaves0 = new bytes32[](BUYERS);
        bytes32[] memory leaves1 = new bytes32[](BUYERS);
        for (uint256 i; i < BUYERS; ++i) {
            leaves0[i] = fixedSale.allowlistLeaf(
                address(editions), id, 0, buyers[i], cap0[i], price * priceFactor0[i] / 100
            );
            leaves1[i] = fixedSale.allowlistLeaf(address(editions), id, 1, buyers[i], cap1[i], 0);
        }
        return (_root(leaves0), _root(leaves1));
    }

    // ------------------------------------------------------------------ actions

    /// @notice Anyone creates a settled master's edition from its approved item; a second
    ///         creation must be refused.
    function createEdition(uint256 seed) external {
        if (_createEdition(seed)) {
            ++hits["createEdition"];
            return;
        }
        Master storage again = masters[seed % MASTERS];
        try editions.createEdition(
            again.tokenId, abi.decode(again.item, (PackageItem)), again.root, again.proof
        ) {
            _violation("an edition was created twice");
        } catch {
            ++hits["editionExists"];
        }
    }

    /// @dev Creates the first edition not yet created, from `seed`; false when all exist.
    function _createEdition(uint256 seed) internal returns (bool) {
        for (uint256 k; k < MASTERS; ++k) {
            Master storage m = masters[(seed % MASTERS + k) % MASTERS];
            if (m.created) continue;
            editions.createEdition(m.tokenId, abi.decode(m.item, (PackageItem)), m.root, m.proof);
            m.created = true;
            IEditions.Edition memory e = editions.edition(m.tokenId);
            m.royaltyReceiver = e.royaltyReceiver;
            m.feeShare = e.feeShare;
            m.seller = e.seller;
            m.feeRecipient = e.feeRecipient;
            return true;
        }
        return false;
    }

    /// @notice Opens a fixed-price sale of an edition with no open sale: by the artist, by
    ///         PLATFORM with the artist's signed consent, or by PLATFORM alone (then only an
    ///         unpriced sale of a FIXED edition). Refusals are predicted: an OPEN edition for
    ///         PLATFORM alone, a paused adapter, a deprecated currency.
    function openFixedSale(uint256 seed, uint256 mode) external {
        (bool found, uint256 i) = _openable(seed, SaleKind.FIXED_PRICE, address(fixedSale));
        if (!found) return;
        uint256 id = masters[i].tokenId;
        uint256 how = mode % 3;
        IFixedPriceSale.Phase[] memory phases = _phases(i, how != 2, mode >> 8);
        IFixedPriceSale.ArtistConsent memory consent;
        if (how == 1) consent = _consent(i, phases, ++consentNonce);
        bool open = masters[i].terms.format == EditionFormat.OPEN;
        bool expected = !_halted(address(fixedSale), masters[i].currency) && (how != 2 || !open);
        vm.prank(how == 0 ? edArtist : platform);
        try fixedSale.openSale(address(editions), id, phases, consent) returns (uint256 saleId) {
            if (!expected) _violation("a fixed-price sale opened that the rules refuse");
            SaleGhost storage g = fixedSales[saleId];
            g.master = i;
            g.approved = how != 2;
            g.haltedAtOpen = _modelHalted(address(fixedSale), masters[i].currency);
            for (uint256 p; p < 3; ++p) {
                g.phases[p] = phases[p];
            }
            fixedCount = saleId;
            ++hits[how == 0 ? bytes32("openByArtist") : bytes32("openByPlatform")];
        } catch {
            if (expected) _violation("a valid fixed-price sale failed to open");
            ++hits["openRefused"];
        }
    }

    /// @notice Opens a Dutch sale, by the artist or by PLATFORM (a FIXED edition only),
    ///         starting now or up to two hours later.
    function openDutchSale(uint256 seed, uint256 mode) external {
        (bool found, uint256 i) = _openable(seed, SaleKind.DUTCH, address(dutchSale));
        if (!found) return;
        uint256 id = masters[i].tokenId;
        bool byArtist = mode % 2 == 0;
        uint64 startTime = uint64(block.timestamp + _bound(mode >> 8, 0, 2 hours));
        bool open = masters[i].terms.format == EditionFormat.OPEN;
        bool expected = !_halted(address(dutchSale), masters[i].currency) && (byArtist || !open);
        vm.prank(byArtist ? edArtist : platform);
        try dutchSale.openSale(address(editions), id, startTime) returns (uint256 saleId) {
            if (!expected) _violation("a Dutch sale opened that the rules refuse");
            SaleGhost storage g = dutchSales[saleId];
            g.master = i;
            g.approved = byArtist;
            g.haltedAtOpen = _modelHalted(address(dutchSale), masters[i].currency);
            g.dutchStart = startTime;
            dutchCount = saleId;
            ++hits[byArtist ? bytes32("openByArtist") : bytes32("openByPlatform")];
        } catch {
            if (expected) _violation("a valid Dutch sale failed to open");
            ++hits["openRefused"];
        }
    }

    /// @notice A buyer purchases from a fixed-price sale: an allowlist phase (with its proof) or
    ///         the public phase, for itself or another buyer, in ETH or `usd` (paid directly, by
    ///         EIP-2612 permit or by a relayed Permit2 intent). The outcome and the exact charge
    ///         are predicted from the phase, the caps, the supply, the halts and the schedule's
    ///         delay; a purchase while halted must be refused.
    function purchaseFixed(uint256 seed, uint256 buyerSeed, uint256 options) external {
        (bool found, uint256 saleId) = _openSale(seed, false);
        if (!found) return;
        FixedBuy memory b = _fixedBuy(saleId, buyerSeed, options);
        SaleGhost storage g = fixedSales[saleId];
        _payFixed(b, _fixedCharge(g, b.p), _fixedAdmits(g, b.p, b.keyed));
    }

    /// @dev A purchase in a phase open now (from `options % 3`; that one when none is open) by
    ///      buyer `buyerSeed`, for itself or (one time in four) for the next buyer, with the leaf
    ///      and proof it needs; the quantity probes the cap and supply boundaries (`_quantity`).
    function _fixedBuy(uint256 saleId, uint256 buyerSeed, uint256 options)
        internal
        view
        returns (FixedBuy memory b)
    {
        uint256 master = fixedSales[saleId].master;
        uint256 phase = _openPhase(fixedSales[saleId], options % 3);
        b.payer = buyerSeed % BUYERS;
        uint256 recipient = (options >> 8) % 4 == 0 ? (b.payer + 1) % BUYERS : b.payer;
        b.p = IFixedPriceSale.Purchase(saleId, phase, buyers[recipient], 0, 0, 0);
        b.keyed = phase == 1 ? b.payer : recipient;
        b.method = options >> 32;
        if (phase == 0) (b.p.leafCap, b.p.leafPrice, b.proof) = _leaf0(master, b.keyed);
        if (phase == 1) {
            b.p.leafCap = cap1[b.keyed];
            b.proof = _phase1Proof(masters[master].tokenId, b.keyed);
        }
        uint256 cap = phase == 2 ? PUBLIC_CAP : b.p.leafCap;
        uint256 bought =
            fixedSale.purchased(address(editions), masters[master].tokenId, phase, buyers[b.keyed]);
        b.p.quantity = _quantity(options >> 16, cap - bought, masters[master]);
    }

    /// @dev One to three copies, or a quantity on a boundary: exactly the wallet's room under
    ///      its cap, one past it, or one past the edition's remaining supply.
    function _quantity(uint256 seed, uint256 room, Master storage m)
        internal
        view
        returns (uint256)
    {
        uint256 supplyLeft = m.terms.size - ghostMinted[m.tokenId];
        uint256 mode = seed % 6;
        if (mode == 3 && room != 0) return room;
        if (mode == 4) return room + 1;
        if (mode == 5) return supplyLeft + 1;
        return _bound(seed >> 8, 1, 3);
    }

    /// @notice A buyer purchases from a Dutch sale at the current price of the curve, moved by
    ///         the schedule's delay: in ETH it overpays, and the excess is credited; in `usd` the
    ///         payment caps the price and exactly the charge is pulled.
    function purchaseDutch(uint256 seed, uint256 buyerSeed, uint256 options) external {
        (bool found, uint256 saleId) = _openSale(seed, true);
        if (!found) return;
        SaleGhost storage g = dutchSales[saleId];
        address buyer = buyers[buyerSeed % BUYERS];
        Master storage m = masters[dutchSales[saleId].master];
        // A Dutch sale has no wallet cap: the room is the edition's remaining supply.
        uint256 quantity = _quantity(options, m.terms.size - ghostMinted[m.tokenId], m);
        Charge memory c = _dutchCharge(g, quantity);
        bool expected = _dutchAdmits(g, quantity);
        _payDutch(saleId, buyer, quantity, c, expected, options >> 32);
    }

    /// @notice A guardian (PAUSER) pauses the fixed-price or the Dutch adapter (an emergency:
    ///         one call in four).
    function pauseAdapter(uint256 seed) external {
        address adapter = seed % 2 == 0 ? address(fixedSale) : address(dutchSale);
        if (_paused(adapter) || (seed >> 1) % 4 != 0) return;
        vm.prank(guardian1);
        ISaleAdapter(adapter).pause();
        pausedSince[adapter] = block.timestamp;
        ++hits["pause"];
    }

    /// @notice UNPAUSER's governed 48-hour unpause, counted from the pause (GOV-5).
    function unpauseAdapter(uint256 seed) external {
        address adapter = seed % 2 == 0 ? address(fixedSale) : address(dutchSale);
        if (!_paused(adapter)) return;
        _govern(hotAdmin, adapter, abi.encodeCall(ISaleAdapter.unpause, ()));
        pausedTotal[adapter] += block.timestamp - pausedSince[adapter];
        pausedSince[adapter] = 0;
        ++hits["unpause"];
    }

    /// @notice A guardian deprecates `usd` or ETH (an emergency: one call in four): every sale
    ///         in it halts.
    function deprecateCurrency(uint256 seed) external {
        address currency = seed % 2 == 0 ? address(usd) : CURRENCY_ETH;
        if (frozenSince[currency] != 0 || (seed >> 1) % 4 != 0) return;
        vm.prank(guardian2);
        allowlist.deprecateAsset(currency);
        frozenSince[currency] = block.timestamp;
        ++hits["deprecate"];
    }

    /// @notice FUNDS_SETTER's governed 14-day re-admission, no earlier than 14 days after the
    ///         deprecation.
    function readmitCurrency(uint256 seed) external {
        address currency = seed % 2 == 0 ? address(usd) : CURRENCY_ETH;
        if (frozenSince[currency] == 0) return;
        (, uint256 floor, uint64 revision) = allowlist.assetConfig(currency);
        _govern(
            hotAdmin,
            address(allowlist),
            abi.encodeCall(allowlist.admitAsset, (currency, revision, floor))
        );
        frozenTotal[currency] += block.timestamp - frozenSince[currency];
        frozenSince[currency] = 0;
        ++hits["readmit"];
    }

    /// @notice Closes an open sale as the artist, PLATFORM or an outsider. Predicted: the artist
    ///         always may; PLATFORM a sale opened without the artist's approval; anyone a
    ///         fixed-price sale whose phases (moved by the delay) have all ended.
    function closeSale(uint256 seed, uint256 who) external {
        bool dutch = who % 2 == 1;
        (bool found, uint256 saleId) = _openSale(seed, dutch);
        if (!found) return;
        SaleGhost storage g = dutch ? dutchSales[saleId] : fixedSales[saleId];
        uint256 role = (who >> 1) % 3;
        address caller = role == 0 ? edArtist : role == 1 ? platform : relayer;
        bool expected = role == 0 || (role == 1 && !g.approved) || (!dutch && _ended(g));
        vm.prank(caller);
        (bool ok,) = dutch
            ? address(dutchSale).call(abi.encodeCall(dutchSale.closeSale, (saleId)))
            : address(fixedSale).call(abi.encodeCall(fixedSale.closeSale, (saleId)));
        if (ok != expected) {
            _violation(ok ? "an unauthorised close" : "an authorised close failed");
        }
        if (!ok) {
            ++hits["closeRefused"];
            return;
        }
        g.closed = true;
        ++hits["closeSale"];
    }

    /// @notice Every party consents and FUNDS_SETTER (14 days) re-rates a master (one call in
    ///         four); its edition, if created, follows.
    function rerate(uint256 seed, uint256 rateSeed) external {
        if ((seed >> 8) % 4 != 0) return;
        Master storage m = masters[seed % MASTERS];
        uint32 rate = uint32(_bound(rateSeed, 0, 20_000));
        uint64 deadline = uint64(block.timestamp + 30 days);
        bytes32 state = records.workStateHash(m.tokenId);
        bytes32 digest = _typedDigest(
            address(records),
            keccak256(abi.encode(Typehashes.ROYALTY_RATE_CHANGE, m.tokenId, rate, state, deadline))
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(edArtist, digest);
        _govern(
            hotAdmin,
            address(records),
            abi.encodeCall(
                records.setRoyaltyRate,
                (m.tokenId, rate, abi.decode(m.item, (PackageItem)), state, deadline, sigs)
            )
        );
        ++hits["rerate"];
    }

    /// @notice A buyer claims its Dutch ETH credits (overpayments).
    function claim(uint256 seed) external {
        address buyer = buyers[seed % BUYERS];
        uint256 owed = dutchSale.claimable(buyer, CURRENCY_ETH);
        if (owed == 0) return;
        vm.prank(buyer);
        dutchSale.claim(CURRENCY_ETH, buyer);
        ghostCredits -= owed;
        ghostClaimed += owed;
        ++hits["claim"];
    }

    /// @notice Time passes: a minute to twelve hours.
    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + _bound(secondsSeed, 1 minutes, 12 hours));
        ++hits["warp"];
    }

    // ------------------------------------------------------------------ the model

    function _violation(string memory what) internal {
        violations.push(what);
    }

    function _paused(address adapter) internal view returns (bool) {
        return pausedSince[adapter] != 0;
    }

    /// @dev The model's halt clock for sales of `adapter` in `currency`: closed and running
    ///      pauses of the adapter plus closed and running deprecations of the currency. A
    ///      sale's delay is how much it grew since the sale opened (MARKET-1).
    function _modelHalted(address adapter, address currency) internal view returns (uint256 t) {
        t = pausedTotal[adapter] + frozenTotal[currency];
        if (pausedSince[adapter] != 0) t += block.timestamp - pausedSince[adapter];
        if (frozenSince[currency] != 0) t += block.timestamp - frozenSince[currency];
    }

    function _delay(SaleGhost storage g, address adapter) internal view returns (uint256) {
        return _modelHalted(adapter, masters[g.master].currency) - g.haltedAtOpen;
    }

    function _halted(address adapter, address currency) internal view returns (bool) {
        return _paused(adapter) || frozenSince[currency] != 0;
    }

    /// @dev The first master, from `seed`, with an edition of sale kind `kind` and no open sale.
    function _openable(uint256 seed, bytes32 kind, address adapter)
        internal
        view
        returns (bool, uint256)
    {
        for (uint256 k; k < MASTERS; ++k) {
            uint256 i = (seed % MASTERS + k) % MASTERS;
            Master storage m = masters[i];
            if (!m.created || m.terms.saleKind != kind) continue;
            (bool ok, bytes memory open) = adapter.staticcall(
                abi.encodeWithSignature("openSaleOf(address,uint256)", address(editions), m.tokenId)
            );
            if (ok && abi.decode(open, (uint256)) == 0) return (true, i);
        }
        return (false, 0);
    }

    /// @dev The first open (not closed) sale, from `seed`.
    function _openSale(uint256 seed, bool dutch) internal view returns (bool, uint256) {
        uint256 count = dutch ? dutchCount : fixedCount;
        for (uint256 k; k < count; ++k) {
            uint256 saleId = (seed % count + k) % count + 1;
            if (!(dutch ? dutchSales[saleId] : fixedSales[saleId]).closed) return (true, saleId);
        }
        return (false, 0);
    }

    /// @dev The three phases of edition `i`, starting within the next six hours.
    function _phases(uint256 i, bool approved, uint256 timeSeed)
        internal
        view
        returns (IFixedPriceSale.Phase[] memory phases)
    {
        uint64 t = uint64(block.timestamp + _bound(timeSeed, 0, 6 hours));
        phases = new IFixedPriceSale.Phase[](3);
        phases[0] = IFixedPriceSale.Phase(t, t + 1 days, masters[i].phase0Root, 0, false, approved);
        phases[1] =
            IFixedPriceSale.Phase(t + 6 hours, t + 2 days, masters[i].phase1Root, 0, true, false);
        phases[2] =
            IFixedPriceSale.Phase(t + 6 hours, t + 5 days, bytes32(0), PUBLIC_CAP, false, false);
    }

    /// @dev The first phase from `first` that is open now on the sale's delayed schedule, or
    ///      `first` when none is.
    function _openPhase(SaleGhost storage g, uint256 first) internal view returns (uint256) {
        uint256 delay = _delay(g, address(fixedSale));
        for (uint256 k; k < 3; ++k) {
            uint256 p = (first + k) % 3;
            IFixedPriceSale.Phase storage phase = g.phases[p];
            if (block.timestamp >= phase.start + delay && block.timestamp < phase.end + delay) {
                return p;
            }
        }
        return first;
    }

    /// @dev The artist's signed approval of `phases` at the edition's resolved terms.
    function _consent(uint256 i, IFixedPriceSale.Phase[] memory phases, uint256 nonce)
        internal
        view
        returns (IFixedPriceSale.ArtistConsent memory consent)
    {
        uint256 id = masters[i].tokenId;
        consent.nonce = nonce;
        consent.deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = fixedSale.phaseConfigurationDigest(
            address(editions),
            id,
            masters[i].currency,
            masters[i].terms.price,
            phases,
            nonce,
            consent.deadline
        );
        consent.signature = _sign(edArtist, digest);
    }

    function _leaf0(uint256 i, uint256 buyer)
        internal
        view
        returns (uint256 cap, uint256 price, bytes32[] memory proof)
    {
        uint256 id = masters[i].tokenId;
        uint256 packagePrice = masters[i].terms.price;
        bytes32[] memory leaves = new bytes32[](BUYERS);
        for (uint256 b; b < BUYERS; ++b) {
            leaves[b] = fixedSale.allowlistLeaf(
                address(editions), id, 0, buyers[b], cap0[b], packagePrice * priceFactor0[b] / 100
            );
        }
        return (cap0[buyer], packagePrice * priceFactor0[buyer] / 100, _proof(leaves, buyer));
    }

    /// @dev The predicted unit price and charge of a fixed-price purchase.
    function _fixedCharge(SaleGhost storage g, IFixedPriceSale.Purchase memory p)
        internal
        view
        returns (Charge memory c)
    {
        Master storage m = masters[g.master];
        c.currency = m.currency;
        c.unit = p.phase == 0 && g.approved ? p.leafPrice : m.terms.price;
        c.total = c.unit * p.quantity;
        c.fee = Math.mulDiv(c.total, m.feeShare, DENOMINATOR);
        c.seller = m.seller;
        c.feeRecipient = m.feeRecipient;
    }

    /// @dev Whether a fixed-price purchase must succeed: not halted, the phase open on the
    ///      delayed schedule, within the caps, the supply and an open edition's window.
    function _fixedAdmits(SaleGhost storage g, IFixedPriceSale.Purchase memory p, uint256 keyed)
        internal
        view
        returns (bool)
    {
        if (_halted(address(fixedSale), masters[g.master].currency)) return false;
        IFixedPriceSale.Phase storage phase = g.phases[p.phase];
        uint256 delay = _delay(g, address(fixedSale));
        if (block.timestamp < phase.start + delay || block.timestamp >= phase.end + delay) {
            return false;
        }
        Master storage m = masters[g.master];
        uint256 bought = fixedSale.purchased(address(editions), m.tokenId, p.phase, buyers[keyed]);
        uint256 cap = p.phase == 2 ? PUBLIC_CAP : p.leafCap;
        if (bought + p.quantity > cap) return false;
        return _mintable(m, p.quantity);
    }

    /// @dev The edition can mint `quantity` now: within its size, and an OPEN edition within its
    ///      window from the first mint.
    function _mintable(Master storage m, uint256 quantity) internal view returns (bool) {
        EditionTerms storage t = m.terms;
        if (t.size != 0 && ghostMinted[m.tokenId] + quantity > t.size) return false;
        uint256 start = ghostWindowStart[m.tokenId];
        return t.format == EditionFormat.FIXED || start == 0 || block.timestamp < start + t.window;
    }

    /// @dev The Dutch unit price at `t` (`DutchPricing.priceAt`, restated from the spec): the
    ///      start price until the start, the resting price from the end of the curve, and in
    ///      between the reduction rounded down (stepped when `step` is set).
    function _curve(
        uint256 start,
        uint256 resting,
        uint256 startTime,
        uint256 duration,
        uint256 step,
        uint256 t
    ) internal pure returns (uint256) {
        if (t <= startTime) return start;
        uint256 elapsed = t - startTime;
        if (elapsed >= duration) return resting;
        if (step != 0) elapsed = elapsed / step * step;
        return start - (start - resting) * elapsed / duration;
    }

    function _dutchCharge(SaleGhost storage g, uint256 quantity)
        internal
        view
        returns (Charge memory c)
    {
        Master storage m = masters[g.master];
        DutchParams storage d = m.dutch;
        c.currency = m.currency;
        c.unit = _curve(
            m.terms.price,
            d.restingPrice,
            g.dutchStart + _delay(g, address(dutchSale)),
            d.duration,
            d.stepSeconds,
            block.timestamp
        );
        c.total = c.unit * quantity;
        c.fee = Math.mulDiv(c.total, m.feeShare, DENOMINATOR);
        c.seller = m.seller;
        c.feeRecipient = m.feeRecipient;
    }

    function _dutchAdmits(SaleGhost storage g, uint256 quantity) internal view returns (bool) {
        if (_halted(address(dutchSale), masters[g.master].currency)) return false;
        if (block.timestamp < g.dutchStart + _delay(g, address(dutchSale))) return false;
        return _mintable(masters[g.master], quantity);
    }

    // ------------------------------------------------------------------ payments

    function _balance(address currency, address account) internal view returns (uint256) {
        return currency == CURRENCY_ETH ? account.balance : usd.balanceOf(account);
    }

    function _snapshot(Charge memory c) internal view {
        c.sellerBefore = _balance(c.currency, c.seller);
        c.feeBefore = _balance(c.currency, c.feeRecipient);
    }

    /// @dev After a purchase: the seller got exactly `total - fee` and the network `fee`.
    function _settled(Charge memory c, uint256 id, uint256 quantity) internal {
        uint256 seller = _balance(c.currency, c.seller) - c.sellerBefore;
        uint256 fee = _balance(c.currency, c.feeRecipient) - c.feeBefore;
        if (seller != c.total - c.fee || fee != c.fee) {
            _violation("a purchase was not charged the schedule price");
        }
        ghostPaid[c.currency] += c.total;
        ghostReceived[c.currency] += seller + fee;
        if (ghostWindowStart[id] == 0) ghostWindowStart[id] = block.timestamp;
        ghostMinted[id] += quantity;
    }

    function _payFixed(FixedBuy memory b, Charge memory c, bool expected) internal {
        uint256 id = masters[fixedSales[b.p.saleId].master].tokenId;
        address payer = buyers[b.payer];
        Payment memory pay = _fixedPayment(b.p, payer, c, b.method);
        address sender = pay.method == PaymentMethod.PERMIT2 ? relayer : payer;
        uint256 value = c.currency == CURRENCY_ETH ? c.total : 0;
        vm.deal(sender, sender.balance + value);
        _snapshot(c);
        vm.prank(sender);
        try fixedSale.purchase{ value: value }(b.p, b.proof, pay) {
            if (!expected) _violation("a fixed-price purchase the rules refuse succeeded");
            _settled(c, id, b.p.quantity);
            ++hits[
                pay.method == PaymentMethod.PERMIT2
                    ? bytes32("permit2")
                    : pay.method == PaymentMethod.PERMIT ? bytes32("permit") : bytes32("direct")
            ];
            ++hits[b.p.phase == 2 ? bytes32("buyPublic") : bytes32("buyAllowlist")];
        } catch {
            if (expected) _violation("a valid fixed-price purchase failed");
            ++hits[
                _halted(address(fixedSale), c.currency)
                    ? bytes32("haltedRefused")
                    : bytes32("purchaseRefused")
            ];
        }
    }

    function _phase1Proof(uint256 id, uint256 buyer) internal view returns (bytes32[] memory) {
        bytes32[] memory leaves = new bytes32[](BUYERS);
        for (uint256 b; b < BUYERS; ++b) {
            leaves[b] = fixedSale.allowlistLeaf(address(editions), id, 1, buyers[b], cap1[b], 0);
        }
        return _proof(leaves, buyer);
    }

    /// @dev ETH pays directly; `usd` directly (approved), by EIP-2612 permit, or by Permit2.
    function _fixedPayment(
        IFixedPriceSale.Purchase memory p,
        address payer,
        Charge memory c,
        uint256 method
    ) internal returns (Payment memory pay) {
        pay = Payment(PaymentMethod.DIRECT, payer, c.total, 0, 0, "");
        if (c.currency == CURRENCY_ETH) return pay;
        usd.mint(payer, c.total);
        uint256 m = method % 3;
        if (m == 0) {
            vm.prank(payer);
            usd.approve(address(fixedSale), c.total);
            return pay;
        }
        pay.deadline = block.timestamp + 1 hours;
        if (m == 1) {
            pay.method = PaymentMethod.PERMIT;
            pay.signature = _erc2612(payer, address(fixedSale), c.total, pay.deadline);
            return pay;
        }
        pay.method = PaymentMethod.PERMIT2;
        pay.nonce = ++permit2Nonce;
        bytes32 witness = keccak256(
            abi.encode(
                Typehashes.PURCHASE_WITNESS,
                p.saleId,
                p.phase,
                p.recipient,
                p.quantity,
                c.total,
                pay.deadline
            )
        );
        pay.signature = _permit2(
            payer, address(fixedSale), c.total, pay, witness, Typehashes.PURCHASE_WITNESS_TYPE
        );
    }

    function _payDutch(
        uint256 saleId,
        address buyer,
        uint256 quantity,
        Charge memory c,
        bool expected,
        uint256 method
    ) internal {
        uint256 maxUnit = c.unit + (method % 2 == 0 ? 0 : c.unit / 10);
        (Payment memory pay, address sender) =
            _dutchPayment(saleId, buyer, quantity, maxUnit, c.currency, method >> 1);
        uint256 value = c.currency == CURRENCY_ETH ? pay.amount : 0;
        vm.deal(sender, sender.balance + value);
        _snapshot(c);
        uint256 creditBefore = dutchSale.claimable(buyer, CURRENCY_ETH);
        vm.prank(sender);
        try dutchSale.purchase{ value: value }(saleId, address(0), quantity, maxUnit, pay) {
            if (!expected) _violation("a Dutch purchase the rules refuse succeeded");
            _settled(c, masters[dutchSales[saleId].master].tokenId, quantity);
            uint256 credited = dutchSale.claimable(buyer, CURRENCY_ETH) - creditBefore;
            if (credited != (value == 0 ? 0 : value - c.total)) {
                _violation("a Dutch overpayment was not credited exactly");
            }
            ghostCredits += credited;
            ghostPaid[c.currency] += credited;
            ++hits["buyDutch"];
            if (pay.method == PaymentMethod.PERMIT2) ++hits["permit2"];
        } catch {
            if (expected) _violation("a valid Dutch purchase failed");
            ++hits[
                _halted(address(dutchSale), c.currency)
                    ? bytes32("haltedRefused")
                    : bytes32("purchaseRefused")
            ];
        }
    }

    /// @dev At most `maxUnit` per copy: ETH directly (overpaying when `maxUnit` is above the
    ///      price); `usd` directly (approved) or by a relayed Permit2 intent.
    function _dutchPayment(
        uint256 saleId,
        address buyer,
        uint256 quantity,
        uint256 maxUnit,
        address currency,
        uint256 method
    ) internal returns (Payment memory pay, address sender) {
        uint256 amount = maxUnit * quantity;
        pay = Payment(PaymentMethod.DIRECT, buyer, amount, 0, 0, "");
        sender = buyer;
        if (currency == CURRENCY_ETH) return (pay, sender);
        usd.mint(buyer, amount);
        if (method % 2 == 0) {
            vm.prank(buyer);
            usd.approve(address(dutchSale), amount);
            return (pay, sender);
        }
        pay.method = PaymentMethod.PERMIT2;
        pay.deadline = block.timestamp + 1 hours;
        pay.nonce = ++permit2Nonce;
        bytes32 witness = keccak256(
            abi.encode(
                Typehashes.DUTCH_PURCHASE_WITNESS,
                saleId,
                address(0),
                quantity,
                maxUnit,
                pay.deadline
            )
        );
        pay.signature = _permit2(
            buyer, address(dutchSale), amount, pay, witness, Typehashes.DUTCH_PURCHASE_WITNESS_TYPE
        );
        sender = relayer;
    }

    function _erc2612(address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                owner,
                spender,
                value,
                usd.nonces(owner),
                deadline
            )
        );
        return
            _sign(
                owner, keccak256(abi.encodePacked("\x19\x01", usd.DOMAIN_SEPARATOR(), structHash))
            );
    }

    function _permit2(
        address owner,
        address spender,
        uint256 amount,
        Payment memory pay,
        bytes32 witness,
        string memory witnessType
    ) internal view returns (bytes memory) {
        bytes32 digest = permit2.witnessDigest(
            spender,
            ISignatureTransfer.PermitTransferFrom(
                ISignatureTransfer.TokenPermissions(address(usd), amount), pay.nonce, pay.deadline
            ),
            witness,
            witnessType
        );
        return _sign(owner, digest);
    }

    /// @dev Whether every phase of a fixed-price sale has ended on its delayed schedule.
    function _ended(SaleGhost storage g) internal view returns (bool) {
        uint256 delay = _delay(g, address(fixedSale));
        for (uint256 p; p < 3; ++p) {
            if (g.phases[p].end + delay > block.timestamp) return false;
        }
        return true;
    }

    // ------------------------------------------------------------------ the invariants

    /// @dev Every invariant of the suite; see `EditionSalesInvariantTest`.
    function _assertEditionSales() internal view {
        assertEq(violations.length, 0, violations.length == 0 ? "" : violations[0]);
        _assertEditions();
        _assertCaps();
        _assertFunds();
        _assertSchedules();
    }

    /// @dev Per edition: supply never exceeds the edition size and every copy minted is held by
    ///      a buyer; the edition and its master stay linked both ways; and the royalty follows
    ///      the master: the master's current rate, paid to the receiver locked at creation.
    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](BUYERS);
        for (uint256 b; b < BUYERS; ++b) {
            ids[b] = id;
        }
    }

    function _assertEditions() internal view {
        for (uint256 i; i < MASTERS; ++i) {
            Master storage m = masters[i];
            if (!m.created) continue;
            IEditions.Edition memory e = editions.edition(m.tokenId);
            assertLe(e.minted, e.terms.size, "supply within the edition size");
            assertEq(e.minted, ghostMinted[m.tokenId], "every copy minted by a purchase");
            uint256[] memory balances = editions.balanceOfBatch(holders, _ids(m.tokenId));
            uint256 held;
            for (uint256 b; b < BUYERS; ++b) {
                held += balances[b];
            }
            assertEq(held, e.minted, "every copy is held by its buyer");
            (address linked, uint256 editionId) = stream.editionOf(m.tokenId);
            assertTrue(linked == address(editions) && editionId == m.tokenId, "the master's link");
            (,,,,, uint32 masterRate) = stream.coreOf(m.tokenId);
            // An odd price: Editions' `mulDiv` must give exactly the master's share of it.
            (address receiver, uint256 amount) = editions.royaltyInfo(m.tokenId, ODD_PRICE);
            assertEq(e.royaltyRate, masterRate, "an edition's rate is its master's");
            assertEq(amount, ODD_PRICE * masterRate / DENOMINATOR, "the edition's royalty");
            assertEq(receiver, m.royaltyReceiver, "the edition's receiver never changes");
        }
    }

    /// @dev Each wallet stays within its cap in every capped phase, across all sales of an
    ///      edition.
    function _assertCaps() internal view {
        for (uint256 i; i < MASTERS; ++i) {
            uint256 id = masters[i].tokenId;
            // Only a purchase moves a count: an edition nobody bought from has none.
            if (masters[i].terms.saleKind != SaleKind.FIXED_PRICE || ghostMinted[id] == 0) {
                continue;
            }
            for (uint256 b; b < BUYERS; ++b) {
                address a = buyers[b];
                assertLe(fixedSale.purchased(address(editions), id, 0, a), cap0[b], "phase 0 cap");
                assertLe(fixedSale.purchased(address(editions), id, 1, a), cap1[b], "phase 1 cap");
                assertLe(fixedSale.purchased(address(editions), id, 2, a), PUBLIC_CAP, "public cap");
            }
        }
    }

    /// @dev Each adapter's ETH and `usd` balances cover what it owes (exactly: the fixed-price
    ///      adapter keeps nothing, the Dutch adapter keeps only ETH credits), and everything a
    ///      buyer paid reached the seller, the network or a credit.
    function _assertFunds() internal view {
        uint256 owed;
        for (uint256 b; b < BUYERS; ++b) {
            owed += dutchSale.claimable(buyers[b], CURRENCY_ETH);
            assertEq(dutchSale.claimable(buyers[b], address(usd)), 0, "no ERC-20 credit");
            assertEq(fixedSale.claimable(buyers[b], CURRENCY_ETH), 0, "fixed price credits no ETH");
        }
        assertEq(address(dutchSale).balance, owed, "the Dutch adapter holds exactly its credits");
        assertEq(owed, ghostCredits, "credits are the overpayments not yet claimed");
        assertEq(usd.balanceOf(address(dutchSale)), 0, "the Dutch adapter keeps no ERC-20");
        assertEq(address(fixedSale).balance, 0, "the fixed-price adapter keeps no ETH");
        assertEq(usd.balanceOf(address(fixedSale)), 0, "the fixed-price adapter keeps no ERC-20");
        assertEq(
            ghostPaid[CURRENCY_ETH],
            ghostReceived[CURRENCY_ETH] + ghostCredits + ghostClaimed,
            "ETH paid in = received + credited"
        );
        assertEq(ghostPaid[address(usd)], ghostReceived[address(usd)], "usd paid in = received");
    }

    /// @dev Every open sale's schedule delay is the model's halt time since it opened, and an open
    ///      Dutch sale's current price is the curve at that delay.
    function _assertSchedules() internal view {
        for (uint256 s = 1; s <= fixedCount; ++s) {
            SaleGhost storage g = fixedSales[s];
            if (g.closed) continue;
            assertEq(fixedSale.scheduleDelay(s), _delay(g, address(fixedSale)), "fixed delay");
        }
        for (uint256 s = 1; s <= dutchCount; ++s) {
            SaleGhost storage g = dutchSales[s];
            if (g.closed) continue;
            assertEq(dutchSale.scheduleDelay(s), _delay(g, address(dutchSale)), "Dutch delay");
            assertEq(dutchSale.currentPrice(s), _dutchCharge(g, 1).unit, "the curve's price");
        }
    }
}
