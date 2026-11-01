// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IEnglishAuctionClock } from "src/interfaces/IEnglishAuctionClock.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import {
    CURRENCY_ETH,
    PRODUCT_EDITIONS,
    PRODUCT_STREAM
} from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionTerms,
    ItemKind,
    Party,
    PartyRole,
    SeedPolicy,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { Payment, PaymentMethod, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { StateGrowth } from "../helpers/StateGrowth.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice The integration gas report: the budgets of ADR 0001, ADR 0003 and ADR 0004, measured
///         on the real, wired contracts. `forge test --match-test test_Gas_Table -vv` prints one
///         table (operation, Prague gas, new slots, new accounts); each other `test_Gas_*` gates
///         one row.
/// @dev Two measures per row (ADR 0004):
///      - **Prague gas.** Foundry 1.7.1 has no Glamsterdam EVM, so every figure is the gas the
///        transaction uses at Prague costs: 21,000 intrinsic, the calldata (EIP-2028, or the
///        EIP-7623 floor when higher) and the execution, before refunds. The execution is the
///        called frame's own gas (`vm.lastCallGas`) with every contract's storage cooled first,
///        plus 2,500 for each account a real transaction would reach cold but this test had
///        already touched: Foundry cannot cool accounts (`_measureGrowth`). The 350K start
///        budget, the 400K test ceilings and the regression ceilings are all Prague gas.
///      - **State growth.** Glamsterdam prices each new storage slot and each new account far
///        above Prague (on Sepolia, about 111K per slot and about 205K for ETH sent to a fresh
///        account). Every row asserts the exact number of new slots and new accounts its
///        transaction creates, counted by `StateGrowth`, so a saved slot cannot be spent again
///        unnoticed. The steady-state ETH start rows are also held to ADR 0004's maxima:
///        6 slots, 7 with a bid. A change that lowers a count lowers it here, in ADR 0004's table and
///        in AGENTS.md; raising one needs a reason, and raising a maximum needs an ADR.
///
///      Steady state (ADR 0003): Stream, the collection, the auction's custody balance, the
///      artist's move-nonce word and the auction's shared sale terms (with and without the
///      increment floor a first bid locks) have all been written before. Items are
///      single-artist works (the artist is the sole, artist-resolved payee) in an eight-item
///      package (proof depth 3).
contract IntegrationGasReport is IntegrationBase {
    uint256 internal constant ITEMS = 8;
    /// @dev ADR 0004 maxima for a steady-state start's new slots, without and with a bid: the
    ///      token's two words and its owner, the consumed-content record and the sale; the bid;
    ///      and Stream's shared terms word when the work is the first under its terms (an
    ///      artist's first start, QUALITY-6). Raising one needs an ADR.
    uint256 internal constant START_MAX_SLOTS = 6;
    uint256 internal constant START_WITH_BID_MAX_SLOTS = 7;
    /// @dev Test ceilings in Prague gas, kept by ADR 0004.
    uint256 internal constant SETTLE_CEILING = 400_000;
    /// @dev `createCollection` writes a new collection's counter word, so the first start in it
    ///      costs what any steady-state start costs; this ceiling only tracks it.
    uint256 internal constant FIRST_IN_COLLECTION_CEILING = 400_000;
    /// @dev Regression ceilings (ADR 0004), in Prague gas: each row's figure when it was set,
    ///      plus about 2%, rounded up to the thousand. They are not budgets. A change that
    ///      crosses one says why in its pull request and moves it.
    uint256 internal constant FIRST_START_CEILING = 449_000;
    uint256 internal constant NEW_TERMS_CEILING = 390_000;
    uint256 internal constant PERMIT2_START_CEILING = 365_000;
    uint256 internal constant BID_CEILING = 75_000;
    uint256 internal constant CONSUME_CEILING = 97_000;
    uint256 internal constant CREATE_EDITION_CEILING = 275_000;
    uint256 internal constant REFRESH_FIRST_CEILING = 131_000;
    uint256 internal constant RERATE_CEILING = 192_000;
    uint256 internal constant REFRESH_FURTHER_CEILING = 161_000;
    uint256 internal constant CREATE_WALLET_CEILING = 1_262_000;
    uint256 internal constant RELEASE_FIRST_CEILING = 96_000;
    uint256 internal constant SIGNED_FIRST_CEILING = 145_000;
    uint256 internal constant SIGNED_LATER_CEILING = 92_000;
    uint256 internal constant AUCTION_VIEW_CEILING = 41_000;
    uint256 internal constant AUCTION_CLOCK_VIEW_CEILING = 25_000;
    uint256 internal constant MINIMUM_BID_VIEW_CEILING = 39_000;
    /// @dev The edition master's creator cap (the Sepolia rehearsal's edition size).
    uint32 internal constant EDITION_CAP = 10;
    /// @dev A 6529 consolidation: use case 999 over all collections.
    address internal constant ALL_COLLECTIONS = 0x8888888888888888888888888888888888888888;
    uint256 internal constant CONSOLIDATION = 999;

    /// @dev One measured transaction.
    struct Row {
        string label;
        bytes data;
        bool isView;
        Warmth warmth;
        uint256 total;
        uint256 execution;
        StateGrowth.Growth growth;
    }

    /// @dev What `_row` measures. A row's own test takes both and runs its gates;
    ///      `test_Gas_Table` takes every row's gas before any state-diff recording (see
    ///      `_measureGrowth`), then every row's growth, and runs no gates.
    enum Pass {
        BOTH,
        GAS,
        GROWTH
    }

    Pass internal pass;
    address internal artistA;
    address internal artistB;
    address internal starter = makeAddr("starter");
    address internal bidder = makeAddr("gasBidder");
    bytes32 internal root;
    /// @dev Artist A's seller wallet (predicted; deployed by the split-wallet rows).
    address internal soloWallet;

    function setUp() public override {
        super.setUp();
        artistA = _actor("gasArtistA");
        artistB = _actor("gasArtistB");
        vm.prank(platform);
        uint256 second = stream.createCollection("Second", keccak256("second"));
        Work[] memory works = new Work[](ITEMS);
        for (uint256 i; i < ITEMS; ++i) {
            // Items 0-5 in the genesis collection, 6-7 in a second one that is still empty.
            works[i] = _work(i % 2 == 0 ? artistA : artistB, i < 6 ? collectionId : second);
        }
        root = _publish(works);
        _keep(root, works);
        // ADR 0004 assumes the network fee recipient already exists, and off anvil the deploy
        // refuses one that does not. Here it is a placeholder address, so it is funded once.
        vm.deal(networkFee, 1);
        soloWallet = economics.newWorkTerms(PRODUCT_STREAM, _soloPayees()).seller;
    }

    // ------------------------------------------------------------------ measuring and gates

    function _row(
        string memory label,
        address from,
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (Row memory r) {
        r.label = label;
        r.data = data;
        if (pass == Pass.BOTH) {
            (r.total, r.execution, r.growth) = _measureGrowth(from, target, data, value);
        } else if (pass == Pass.GAS) {
            // Without the cold-account surcharge, which needs the recording: the table adds it.
            r.warmth = _warmth();
            (r.total, r.execution) = _measure(from, target, data, value);
        } else {
            r.growth = _growth(from, target, data, value);
        }
    }

    /// @dev `r`'s Prague gas is at most `ceiling` (a budget, a test ceiling or a regression
    ///      ceiling, as `what` says).
    function _gasAtMost(Row memory r, uint256 ceiling, string memory what) internal view {
        if (pass != Pass.BOTH) return;
        assertLe(r.total, ceiling, string.concat(r.label, ": Prague gas over the ", what));
    }

    /// @dev `r` creates exactly `slots` new slots and `accounts` new accounts (ADR 0004). On a
    ///      mismatch the new slots and accounts are logged first, so the failure names them.
    function _growthIs(Row memory r, uint256 slots, uint256 accounts) internal view {
        if (pass != Pass.BOTH) return;
        if (r.growth.slots != slots || r.growth.accounts != accounts) _logGrowth(r);
        assertEq(r.growth.slots, slots, string.concat(r.label, ": new storage slots (ADR 0004)"));
        assertEq(r.growth.accounts, accounts, string.concat(r.label, ": new accounts (ADR 0004)"));
    }

    /// @dev The ADR 0004 policy maximum for a steady-state start's new slots.
    function _slotsAtMost(Row memory r, uint256 max) internal pure {
        assertLe(r.growth.slots, max, string.concat(r.label, ": over the ADR 0004 slot maximum"));
    }

    function _logGrowth(Row memory r) internal view {
        console2.log(r.label);
        for (uint256 i; i < r.growth.newSlots.length; ++i) {
            StateGrowth.Slot memory s = r.growth.newSlots[i];
            console2.log("  new slot", _name(s.account), vm.toString(s.slot));
        }
        for (uint256 i; i < r.growth.newAccounts.length; ++i) {
            console2.log("  new account", _name(r.growth.newAccounts[i]));
        }
    }

    function _name(address account) internal view returns (string memory) {
        if (account == address(stream)) return "Stream";
        if (account == address(records)) return "WorkRecords";
        if (account == address(registry)) return "PackageRegistry";
        if (account == address(auction)) return "EnglishAuction";
        if (account == address(editions)) return "Editions";
        if (account == address(artists)) return "ArtistRegistry";
        if (account == address(escrow)) return "RevenueEscrow";
        if (account == address(economics)) return "EconomicsResolver";
        if (account == address(splitFactory)) return "SplitFactory";
        if (account == address(statements)) return "StatementLog";
        if (account == address(entropy)) return "VrfEntropyModule";
        if (account == PERMIT2) return "Permit2";
        if (account == address(usd)) return "ERC-20";
        return vm.getLabel(account);
    }

    /// @dev The accounts whose warmth `_measureGrowth` probes: the contracts, the network fee
    ///      recipient, every actor of this report and the seller wallets its sales pay.
    function _probeSet() internal override returns (address[] memory accounts) {
        address[] memory base = super._probeSet();
        ISplitWallet.Payee[] memory solo = new ISplitWallet.Payee[](1);
        solo[0] = ISplitWallet.Payee(uint160(artistA), address(0), 100_000);
        ISplitWallet.Payee[] memory duo = new ISplitWallet.Payee[](2);
        duo[0] = ISplitWallet.Payee(0, makeAddr("gasCollaborator"), 20_000);
        duo[1] = ISplitWallet.Payee(uint160(artistA), address(0), 80_000);
        ISplitWallet.Payee[] memory soloC = new ISplitWallet.Payee[](1);
        soloC[0] = ISplitWallet.Payee(uint160(makeAddr("gasArtistC")), address(0), 100_000);
        ISplitWallet.Payee[] memory duoC = new ISplitWallet.Payee[](2);
        duoC[0] = ISplitWallet.Payee(0, makeAddr("gasCollaborator"), 20_000);
        duoC[1] = ISplitWallet.Payee(uint160(makeAddr("gasArtistC")), address(0), 80_000);
        address[23] memory extra = [
            artistA,
            artistB,
            makeAddr("gasArtistC"),
            economics.newWorkTerms(PRODUCT_STREAM, soloC).seller,
            economics.newWorkTerms(PRODUCT_STREAM, duoC).seller,
            platform,
            starter,
            bidder,
            address(coordinator),
            makeAddr("earlierBidder"),
            makeAddr("secondBidder"),
            makeAddr("masterCollector"),
            makeAddr("firstCopyBuyer"),
            makeAddr("laterCopyBuyer"),
            makeAddr("dutchBuyer"),
            makeAddr("gasWallet1"),
            makeAddr("gasWallet2"),
            makeAddr("gasCollaborator"),
            makeAddr("permit2Payer"),
            makeAddr("relayer"),
            economics.newWorkTerms(PRODUCT_STREAM, solo).seller,
            economics.newWorkTerms(PRODUCT_EDITIONS, solo).seller,
            economics.newWorkTerms(PRODUCT_STREAM, duo).seller
        ];
        accounts = new address[](base.length + extra.length);
        for (uint256 i; i < base.length; ++i) {
            accounts[i] = base[i];
        }
        for (uint256 i; i < extra.length; ++i) {
            accounts[base.length + i] = extra[i];
        }
    }

    // ------------------------------------------------------------------ fixtures

    /// @dev Two live sales, one with a bid: every per-system record a start or a first bid
    ///      writes once (the fee recipient, the sale terms with and without their increment
    ///      floor, the custody balance, the artist's nonce word) already exists.
    function _steadyState() internal returns (uint256 firstSale) {
        Work[] memory works = _package(root);
        (firstSale,) = _start(root, works, 0);
        _start(root, works, 1);
        _ethBid(firstSale, makeAddr("earlierBidder"), 1 ether);
    }

    function _startData(uint256 index) internal returns (bytes memory) {
        return
            abi.encodeCall(auction.start, (address(stream), _mintData(root, _package(root), index)));
    }

    function _startWithBidData(bytes32 packageRoot, Work[] memory works, uint256 index)
        internal
        returns (bytes memory)
    {
        return abi.encodeCall(
            auction.startWithBid,
            (
                address(stream),
                _mintData(packageRoot, works, index),
                address(0),
                Payment(PaymentMethod.DIRECT, bidder, 1 ether, 0, 0, "")
            )
        );
    }

    /// @dev Eight single-artist works by artist A in the genesis collection, unpublished, so a
    ///      row can shape item 0 first.
    function _eightWorks() internal returns (Work[] memory works) {
        works = new Work[](ITEMS);
        for (uint256 i; i < ITEMS; ++i) {
            works[i] = _work(artistA, collectionId);
        }
    }

    // ------------------------------------------------------------------ the auction start

    function _rowStart() internal returns (Row memory r) {
        _steadyState();
        r = _row("start, steady state", starter, address(auction), _startData(2), 0);
        _gasAtMost(r, START_BUDGET, "350K start budget (ADR 0004)");
        _growthIs(r, 5, 0);
        _slotsAtMost(r, START_MAX_SLOTS);
    }

    function _rowStartWithBid() internal returns (Row memory r) {
        _steadyState();
        bytes memory data = _startWithBidData(root, _package(root), 2);
        r = _row("startWithBid, steady state", bidder, address(auction), data, 1 ether);
        _gasAtMost(r, START_BUDGET, "350K start budget (ADR 0004)");
        _growthIs(r, 6, 0);
        _slotsAtMost(r, START_WITH_BID_MAX_SLOTS);
    }

    /// @dev A two-party work: the lead artist and a collaborator who is paid as a fixed payee.
    function _twoPartyPackage() internal returns (bytes32 twoRoot, Work[] memory works) {
        return _twoPartyPackageOf(artistA);
    }

    /// @dev Eight works led by `lead`, with the collaborator paid as a fixed payee.
    function _twoPartyPackageOf(address lead)
        internal
        returns (bytes32 twoRoot, Work[] memory works)
    {
        address collaborator = _actor("gasCollaborator");
        works = new Work[](ITEMS);
        for (uint256 i; i < ITEMS; ++i) {
            works[i] = _work(lead, collectionId);
            works[i].item.parties = new Party[](2);
            works[i].item.parties[0] = Party(lead, PartyRole.ARTIST);
            works[i].item.parties[1] = Party(collaborator, PartyRole.COLLABORATOR);
            works[i].item.payees = new ISplitWallet.Payee[](2);
            works[i].item.payees[0] = ISplitWallet.Payee(0, collaborator, 20_000);
            works[i].item.payees[1] = ISplitWallet.Payee(uint160(lead), address(0), 80_000);
        }
        twoRoot = _publish(works);
    }

    function _rowStartTwoParty() internal returns (Row memory r) {
        _steadyState();
        (bytes32 twoRoot, Work[] memory works) = _twoPartyPackage();
        _start(twoRoot, works, 0);
        bytes memory data =
            abi.encodeCall(auction.start, (address(stream), _mintData(twoRoot, works, 1)));
        r = _row("start, steady state, two-party work", starter, address(auction), data, 0);
        _gasAtMost(r, START_BUDGET, "350K start budget (ADR 0004)");
        _growthIs(r, 5, 0);
        _slotsAtMost(r, START_MAX_SLOTS);
    }

    /// @dev The smallest collaboration (the artist plus one collaborator, paid as a fixed payee)
    ///      is held to the same steady-state budget (formerly finding G-2, resolved by #34). It
    ///      is the closest row to the budget.
    function _rowStartWithBidTwoParty() internal returns (Row memory r) {
        _steadyState();
        (bytes32 twoRoot, Work[] memory works) = _twoPartyPackage();
        _start(twoRoot, works, 0);
        bytes memory data = _startWithBidData(twoRoot, works, 1);
        r = _row(
            "startWithBid, steady state, two-party work", bidder, address(auction), data, 1 ether
        );
        _gasAtMost(r, START_BUDGET, "350K start budget (ADR 0004)");
        _growthIs(r, 6, 0);
        _slotsAtMost(r, START_WITH_BID_MAX_SLOTS);
    }

    /// @dev A VRF-seeded work, its seed delivered before the start (ADR 0003).
    function _rowStartVrf() internal returns (Row memory r) {
        _steadyState();
        Work[] memory works = _eightWorks();
        works[0].item.seedPolicy = SeedPolicy.VRF;
        bytes32 vrfRoot = _publish(works);
        uint256 requestId = entropy.requestSeed(works[0].item, vrfRoot, _proofOf(works, 0));
        coordinator.fulfill(requestId, uint256(keccak256("gas report randomness")));
        bytes memory data =
            abi.encodeCall(auction.start, (address(stream), _mintData(vrfRoot, works, 0)));
        r = _row("start, steady state, VRF work", starter, address(auction), data, 0);
        _gasAtMost(r, START_BUDGET, "350K start budget (ADR 0004)");
        _growthIs(r, 5, 0);
        _slotsAtMost(r, START_MAX_SLOTS);
    }

    /// @dev An edition master whose edition the uniform-price edition auction sells, capped at
    ///      10 by its creator.
    function _masterWorks() internal returns (Work[] memory works) {
        works = _eightWorks();
        works[0].item.kind = ItemKind.EDITION_MASTER;
        works[0].item.edition =
            EditionTerms(EDITION_CAP, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
    }

    function _rowStartMaster() internal returns (Row memory r) {
        _steadyState();
        Work[] memory works = _masterWorks();
        bytes32 masterRoot = _publish(works);
        bytes memory data =
            abi.encodeCall(auction.start, (address(stream), _mintData(masterRoot, works, 0)));
        r = _row("start, steady state, edition master", starter, address(auction), data, 0);
        _gasAtMost(r, START_BUDGET, "350K start budget (ADR 0004)");
        _growthIs(r, 5, 0);
        _slotsAtMost(r, START_MAX_SLOTS);
    }

    /// @dev A Permit2 payment whose witness binds the start: token, mint data, payer, amount.
    function _permit2StartBid(bytes memory mintData, address payer, uint256 amount, uint256 nonce)
        internal
        view
        returns (Payment memory)
    {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 witness = keccak256(
            abi.encode(
                Typehashes.START_BID_WITNESS,
                address(stream),
                keccak256(mintData),
                payer,
                amount,
                deadline
            )
        );
        bytes32 digest = permit2.witnessDigest(
            address(auction),
            ISignatureTransfer.PermitTransferFrom(
                ISignatureTransfer.TokenPermissions(address(usd), amount), nonce, deadline
            ),
            witness,
            Typehashes.START_BID_WITNESS_TYPE
        );
        return Payment(PaymentMethod.PERMIT2, payer, amount, deadline, nonce, _sign(payer, digest));
    }

    /// @dev An ERC-20 auction opened with a first bid paid by a relayed Permit2 transfer, at
    ///      steady state for the currency and the payer: the token is admitted, its sale terms
    ///      (with and without the floor) exist, the auction holds a balance of it, and the payer
    ///      has used Permit2 before (its nonce word exists). The Permit2 is the sales lane's
    ///      faithful reproduction, not the canonical deployment. ADR 0004 (decision 6): the
    ///      350K budget and the slot maxima are for ETH, Stream's launch currency. An ERC-20
    ///      start by Permit2 is a supported, non-default path with a regression ceiling and
    ///      exact counts, not a budget; the Permit2 transfer path makes it cost more.
    function _rowStartWithPermit2Bid() internal returns (Row memory r) {
        _govern(
            hotAdmin,
            address(allowlist),
            abi.encodeCall(allowlist.admitAsset, (address(usd), 0, 1e16))
        );
        _steadyState();
        address payer = _actor("permit2Payer");
        usd.mint(payer, 1_000e18);
        vm.prank(payer);
        usd.approve(PERMIT2, type(uint256).max);
        Work[] memory works = _eightWorks();
        for (uint256 i; i < 2; ++i) {
            works[i].item.sale.currency = address(usd);
        }
        bytes32 usdRoot = _publish(works);
        // The first: the payer's first Permit2 transfer and the currency's first bid.
        bytes memory first = _mintData(usdRoot, works, 0);
        vm.prank(makeAddr("relayer"));
        auction.startWithBid(
            address(stream), first, payer, _permit2StartBid(first, payer, 100e18, 0)
        );
        bytes memory mintData = _mintData(usdRoot, works, 1);
        bytes memory data = abi.encodeCall(
            auction.startWithBid,
            (address(stream), mintData, payer, _permit2StartBid(mintData, payer, 100e18, 1))
        );
        r = _row(
            "startWithBid, steady state, ERC-20 by relayed Permit2",
            makeAddr("relayer"),
            address(auction),
            data,
            0
        );
        _gasAtMost(r, PERMIT2_START_CEILING, "regression ceiling");
        _growthIs(r, 6, 0);
    }

    function _rowStartNewCollection() internal returns (Row memory r) {
        _steadyState();
        r = _row(
            "start, first work in a new collection", starter, address(auction), _startData(6), 0
        );
        _gasAtMost(r, FIRST_IN_COLLECTION_CEILING, "400K test ceiling");
        _growthIs(r, 5, 0);
    }

    /// @dev Eight single-artist works by artist C, who has never started a work (the acceptance
    ///      pre-wrote the move-nonce word).
    function _artistCPackage() internal returns (bytes32 cRoot, Work[] memory works) {
        address artistC = _actor("gasArtistC");
        works = new Work[](ITEMS);
        for (uint256 i; i < ITEMS; ++i) {
            works[i] = _work(artistC, collectionId);
        }
        cRoot = _publish(works);
    }

    /// @dev An artist's first start, at steady state otherwise: Stream also writes the shared
    ///      terms word that the artist's later works reuse (QUALITY-6), so it writes as many slots
    ///      as every start did before. The terms' hashed position is free here; on a collision the
    ///      first start writes one slot more (`test/stream/StreamTermsGrind.t.sol`).
    function _rowStartArtistFirst() internal returns (Row memory r) {
        _steadyState();
        (bytes32 cRoot, Work[] memory works) = _artistCPackage();
        bytes memory data =
            abi.encodeCall(auction.start, (address(stream), _mintData(cRoot, works, 0)));
        r = _row("start, an artist's first work", starter, address(auction), data, 0);
        _gasAtMost(r, START_BUDGET, "350K start budget (ADR 0004)");
        _growthIs(r, 6, 0);
        _slotsAtMost(r, START_MAX_SLOTS);
    }

    /// @dev An artist's first start with a bid: the terms word and the bid.
    function _rowStartWithBidArtistFirst() internal returns (Row memory r) {
        _steadyState();
        (bytes32 cRoot, Work[] memory works) = _artistCPackage();
        r = _row(
            "startWithBid, an artist's first work",
            bidder,
            address(auction),
            _startWithBidData(cRoot, works, 0),
            1 ether
        );
        _gasAtMost(r, START_BUDGET, "350K start budget (ADR 0004)");
        _growthIs(r, 7, 0);
        _slotsAtMost(r, START_WITH_BID_MAX_SLOTS);
    }

    /// @dev An artist's first start is a two-party work with a bid: the binding row of the 350K
    ///      budget (ADR 0004).
    function _rowStartWithBidArtistFirstTwoParty() internal returns (Row memory r) {
        _steadyState();
        (bytes32 twoRoot, Work[] memory works) = _twoPartyPackageOf(_actor("gasArtistC"));
        r = _row(
            "startWithBid, an artist's first work, two-party",
            bidder,
            address(auction),
            _startWithBidData(twoRoot, works, 0),
            1 ether
        );
        _gasAtMost(r, START_BUDGET, "350K start budget (ADR 0004)");
        _growthIs(r, 7, 0);
        _slotsAtMost(r, START_WITH_BID_MAX_SLOTS);
    }

    /// @dev One-time: the first start on a new deployment (empty custody, the first fee terms
    ///      and sale terms).
    function _rowStartFirstEver() internal returns (Row memory r) {
        r = _row("start, first work ever (one-time)", starter, address(auction), _startData(0), 0);
        _gasAtMost(r, FIRST_START_CEILING, "regression ceiling");
        _growthIs(r, 13, 0);
    }

    /// @dev One-time: the first bid placed under a set of sale terms nobody has bid under yet
    ///      (after genesis, a new currency, or an auction config or opening-bid change). Live
    ///      sales exist, but none has a bid.
    function _rowStartWithBidNewTerms() internal returns (Row memory r) {
        Work[] memory works = _package(root);
        _start(root, works, 0);
        _start(root, works, 1);
        bytes memory data = _startWithBidData(root, works, 2);
        r = _row(
            "startWithBid, first bid under new terms (one-time)",
            bidder,
            address(auction),
            data,
            1 ether
        );
        _gasAtMost(r, NEW_TERMS_CEILING, "regression ceiling");
        _growthIs(r, 9, 0);
    }

    // ------------------------------------------------------------------ bids and settlement

    function _rowBid() internal returns (Row memory r) {
        _steadyState();
        (uint256 saleId,) = _start(root, _package(root), 2);
        _ethBid(saleId, bidder, 1 ether);
        address second = makeAddr("secondBidder");
        bytes memory data = abi.encodeCall(
            auction.bid,
            (saleId, address(0), Payment(PaymentMethod.DIRECT, second, 2 ether, 0, 0, ""))
        );
        r = _row(
            "bid, outbids and credits the previous bidder", second, address(auction), data, 2 ether
        );
        _gasAtMost(r, BID_CEILING, "regression ceiling");
        _growthIs(r, 1, 0);
    }

    /// @dev The first sale to pay a payee configuration: its seller wallet's predicted address
    ///      is still empty, so the payout creates the account (once per configuration). Stream
    ///      writes one new word, the sale's currency and price (owner decision 17).
    function _rowSettleFirstPayout() internal returns (Row memory r) {
        _steadyState();
        (uint256 saleId,) = _start(root, _package(root), 2);
        _ethBid(saleId, bidder, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        bytes memory data = abi.encodeCall(auction.settle, (saleId));
        r = _row("settle, first payout to the seller wallet", starter, address(auction), data, 0);
        _gasAtMost(r, SETTLE_CEILING, "400K test ceiling");
        assertEq(stream.ownerOf(auction.auction(saleId).tokenId), bidder);
        _growthIs(r, 2, 1);
    }

    /// @dev A settlement once the seller wallet exists: the artist has been paid before. Stream
    ///      writes one new word, the sale's currency and price (owner decision 17).
    function _rowSettle() internal returns (Row memory r) {
        uint256 earlier = _steadyState();
        (uint256 saleId,) = _start(root, _package(root), 2);
        _ethBid(saleId, bidder, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(earlier); // the same artist's earlier sale pays its seller wallet first
        bytes memory data = abi.encodeCall(auction.settle, (saleId));
        r = _row("settle, with a bid", starter, address(auction), data, 0);
        _gasAtMost(r, SETTLE_CEILING, "400K test ceiling");
        assertEq(stream.ownerOf(auction.auction(saleId).tokenId), bidder);
        _growthIs(r, 2, 0);
    }

    /// @dev A settlement with no bid (D140, ADR 0005): Stream moves the work to its economics
    ///      resolver's museum itself (owner decision 17) and nothing is paid. Steady state: the
    ///      museum already holds an earlier unbid work, so its token balance exists; the one new
    ///      slot is the sale's recipient, and Stream records UNBID in a word it rewrites.
    function _rowSettleNoBid() internal returns (Row memory r) {
        _steadyState();
        uint256 earlier = auction.saleIdOf(address(stream), stream.totalMinted()); // unbid
        (uint256 saleId,) = _start(root, _package(root), 2);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(earlier);
        assertEq(stream.balanceOf(museum), 1, "the museum holds the earlier unbid work");
        bytes memory data = abi.encodeCall(auction.settle, (saleId));
        r = _row("settle, no bid (to the museum)", starter, address(auction), data, 0);
        _gasAtMost(r, SETTLE_CEILING, "400K test ceiling");
        assertEq(stream.ownerOf(auction.auction(saleId).tokenId), museum);
        _growthIs(r, 1, 0);
    }

    /// @dev A cold view call to the English auction, answered by its lens through the
    ///      auction's fallback (the auction's own account is the transaction's target; the
    ///      lens is reached cold): `auction(saleId)` of a live sale with a bid, which the edition
    ///      auction's `open` also reads, and `minimumBid(saleId)`.
    function _rowAuctionView() internal returns (Row memory r) {
        _steadyState();
        uint256 saleId = auction.saleIdOf(address(stream), 1);
        r = _viewRow("auction (view, through the lens)", abi.encodeCall(auction.auction, (saleId)));
        _gasAtMost(r, AUCTION_VIEW_CEILING, "regression ceiling");
    }

    function _rowMinimumBidView() internal returns (Row memory r) {
        _steadyState();
        uint256 saleId = auction.saleIdOf(address(stream), 1);
        r = _viewRow(
            "minimumBid (view, through the lens)", abi.encodeCall(auction.minimumBid, (saleId))
        );
        _gasAtMost(r, MINIMUM_BID_VIEW_CEILING, "regression ceiling");
    }

    /// @dev The integration view other contracts read on their hot paths, answered by the
    ///      auction itself (no lens): one cold slot for a sale never paused.
    function _rowAuctionClockView() internal returns (Row memory r) {
        _steadyState();
        uint256 saleId = auction.saleIdOf(address(stream), 1);
        r = _viewRow(
            "auctionClock (view, in the auction)",
            abi.encodeCall(IEnglishAuctionClock.auctionClock, (saleId))
        );
        _gasAtMost(r, AUCTION_CLOCK_VIEW_CEILING, "regression ceiling");
    }

    function _viewRow(string memory label, bytes memory data) internal returns (Row memory r) {
        r = _row(label, starter, address(auction), data, 0);
        r.isView = true;
        r.total = 21_000 + r.execution; // a view: the call itself, without its calldata
        _growthIs(r, 0, 0);
    }

    /// @dev `IPackageRegistry.consume` alone, as Stream calls it at steady state.
    function _rowConsume() internal returns (Row memory r) {
        _steadyState();
        bytes memory request = _mintData(root, _package(root), 2);
        StreamMintRequest memory m = abi.decode(request, (StreamMintRequest));
        bytes memory data =
            abi.encodeCall(IPackageRegistry.consume, (m.packageRoot, m.item, m.proof, m.move));
        r = _row(
            "consume (the registry's share of start, as a call)",
            address(stream),
            address(registry),
            data,
            0
        );
        _gasAtMost(r, CONSUME_CEILING, "regression ceiling");
        _growthIs(r, 1, 0);
    }

    // ------------------------------------------------------------------ 6529 Stream Editions

    /// @dev The master package, published, with item 0 started at steady state, bid on and
    ///      settled.
    function _settledMaster()
        internal
        returns (uint256 workId, bytes32 masterRoot, Work[] memory works)
    {
        return _settledMasterOf(_masterWorks());
    }

    function _settledMasterOf(Work[] memory works)
        internal
        returns (uint256 workId, bytes32 masterRoot, Work[] memory)
    {
        _steadyState();
        masterRoot = _publish(works);
        uint256 saleId;
        (saleId, workId) = _start(masterRoot, works, 0);
        _ethBid(saleId, makeAddr("masterCollector"), 1 ether);
        _settleAtEnd(saleId);
        return (workId, masterRoot, works);
    }

    function _rowCreateEdition() internal returns (Row memory r) {
        (uint256 workId, bytes32 masterRoot, Work[] memory works) = _settledMaster();
        bytes memory data = abi.encodeCall(
            editions.createEdition, (workId, works[0].item, masterRoot, _proofOf(works, 0))
        );
        r = _row("createEdition", starter, address(editions), data, 0);
        _gasAtMost(r, CREATE_EDITION_CEILING, "regression ceiling");
        _growthIs(r, 6, 0);
    }

    // ------------------------------------------------------------------ re-rate

    /// @dev A work re-rated to 10% (every party's consent plus FUNDS_SETTER's governed action),
    ///      executed through the manager: Stream moves the token to the terms with its new rate,
    ///      which no work has yet, so it writes that terms word (QUALITY-6); before, it overwrote
    ///      the token's own word.
    function _rowReRate() internal returns (Row memory r) {
        uint256 tokenId = auction.auction(_steadyState()).tokenId;
        Work[] memory works = _package(root);
        records.openRecord(tokenId, works[0].item, works[0].media);
        uint32 rate = 10_000;
        uint64 deadline = uint64(block.timestamp + 30 days);
        bytes32 state = records.workStateHash(tokenId);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(
            artistA,
            _typedDigest(
                address(records),
                keccak256(
                    abi.encode(Typehashes.ROYALTY_RATE_CHANGE, tokenId, rate, state, deadline)
                )
            )
        );
        bytes memory call = abi.encodeCall(
            records.setRoyaltyRate, (tokenId, rate, works[0].item, state, deadline, sigs)
        );
        _schedule(hotAdmin, address(records), call);
        (, uint32 delay) = manager.canCall(hotAdmin, address(records), bytes4(call));
        vm.warp(block.timestamp + delay);
        r = _row(
            "re-rate a work (governed execute)",
            hotAdmin,
            address(manager),
            abi.encodeCall(manager.execute, (address(records), call)),
            0
        );
        _gasAtMost(r, RERATE_CEILING, "regression ceiling");
        _growthIs(r, 1, 0);
        if (pass == Pass.BOTH) assertEq(stream.work(tokenId).royaltyRate, rate);
    }

    // ------------------------------------------------------------------ identity

    /// @dev `a` and `b` consolidate each other on the 6529 delegation contract.
    function _consolidate(address a, address b) internal {
        vm.prank(a);
        delegation.registerDelegationAddress(
            ALL_COLLECTIONS, b, type(uint64).max, CONSOLIDATION, true, 0
        );
        vm.prank(b);
        delegation.registerDelegationAddress(
            ALL_COLLECTIONS, a, type(uint64).max, CONSOLIDATION, true, 0
        );
    }

    function _refreshData() internal view returns (bytes memory) {
        return abi.encodeCall(artists.refreshStanding, (artists.artistIdOf(artistA)));
    }

    /// @dev The artist's first consolidated wallet is recorded (as pending) by a refresh the
    ///      artist pays for (ADR 0003).
    function _rowRefreshFirst() internal returns (Row memory r) {
        _consolidate(artistA, makeAddr("gasWallet1"));
        r = _row(
            "refreshStanding, records a first wallet", artistA, address(artists), _refreshData(), 0
        );
        _gasAtMost(r, REFRESH_FIRST_CEILING, "regression ceiling");
        _growthIs(r, 2, 0);
    }

    /// @dev A further wallet joins a snapshot that already has one, as on Sepolia r2.
    function _rowRefreshFurther() internal returns (Row memory r) {
        _consolidate(artistA, makeAddr("gasWallet1"));
        artists.refreshStanding(artists.artistIdOf(artistA));
        _consolidate(artistA, makeAddr("gasWallet2"));
        r = _row(
            "refreshStanding, records a further wallet",
            artistA,
            address(artists),
            _refreshData(),
            0
        );
        _gasAtMost(r, REFRESH_FURTHER_CEILING, "regression ceiling");
        _growthIs(r, 1, 0);
    }

    // ------------------------------------------------------------------ split wallets

    /// @dev Artist A's single-payee list: the seller wallet of every work in this report.
    function _soloPayees() internal view returns (ISplitWallet.Payee[] memory solo) {
        solo = new ISplitWallet.Payee[](1);
        solo[0] = ISplitWallet.Payee(uint160(artistA), address(0), 100_000);
    }

    /// @dev The split wallets the release rows reach: their storage is cooled with the rest.
    ///      The address is computed once in `setUp`, so cooling calls nothing and warms no
    ///      account.
    function _cooled() internal view override returns (address[] memory all) {
        address[] memory base = super._cooled();
        all = new address[](base.length + 1);
        for (uint256 i; i < base.length; ++i) {
            all[i] = base[i];
        }
        all[base.length] = soloWallet;
    }

    /// @dev The first sale settled into the seller wallet (0.75 ETH), the wallet deployed, and
    ///      the artist an existing account (ADR 0004: payees exist).
    function _fundedWallet() internal returns (address wallet) {
        uint256 first = _steadyState();
        _settleAtEnd(first);
        wallet = splitFactory.createWallet(_soloPayees(), bytes32(0));
        vm.deal(artistA, artistA.balance + 1);
    }

    /// @dev The artist's signed release of everything due, nonce `nonce`, to its own account.
    function _signedClaimData(address wallet, uint256 nonce) internal view returns (bytes memory) {
        IReleaseVerifier.Authorization memory a = IReleaseVerifier.Authorization(
            wallet,
            CURRENCY_ETH,
            0,
            artistA,
            artistA,
            type(uint256).max,
            nonce,
            block.timestamp + 1 days
        );
        IClaimRouter.SignedClaim[] memory claims = new IClaimRouter.SignedClaim[](1);
        claims[0] = IClaimRouter.SignedClaim(a, _sign(artistA, releaseVerifier.releaseDigest(a)));
        return abi.encodeCall(IClaimRouter.claimSigned, (claims, false));
    }

    /// @dev A new payee configuration's seller wallet, deployed once (permissionless, off the
    ///      sale path): the payee list, its configuration hash and the code.
    function _rowCreateWallet() internal returns (Row memory r) {
        bytes memory data = abi.encodeCall(splitFactory.createWallet, (_soloPayees(), bytes32(0)));
        r = _row(
            "createWallet, a seller wallet (one artist payee)",
            starter,
            address(splitFactory),
            data,
            0
        );
        _gasAtMost(r, CREATE_WALLET_CEILING, "regression ceiling");
        _growthIs(r, 4, 1);
    }

    /// @dev The artist pulls its first ETH from the seller wallet: the payee's and the wallet's
    ///      release totals (ETH keeps no receipts high-water mark).
    function _rowReleaseFirst() internal returns (Row memory r) {
        address wallet = _fundedWallet();
        r = _row(
            "release, the artist's first ETH release",
            artistA,
            wallet,
            abi.encodeCall(ISplitWallet.release, (CURRENCY_ETH, 0)),
            0
        );
        _gasAtMost(r, RELEASE_FIRST_CEILING, "regression ceiling");
        _growthIs(r, 2, 0);
    }

    /// @dev A relayer submits the artist's first signed release through the claim router: the
    ///      first release's records and the verifier's nonce record.
    function _rowSignedFirst() internal returns (Row memory r) {
        address wallet = _fundedWallet();
        r = _row(
            "claimSigned, the artist's first signed release (relayed)",
            makeAddr("relayer"),
            address(claimRouter),
            _signedClaimData(wallet, 0),
            0
        );
        _gasAtMost(r, SIGNED_FIRST_CEILING, "regression ceiling");
        _growthIs(r, 3, 0);
    }

    /// @dev The artist's next signed release, with the next nonce, after more revenue arrived. The
    ///      nonce shares its bitmap word with the first, so nothing new is written.
    function _rowSignedLater() internal returns (Row memory r) {
        address wallet = _fundedWallet();
        vm.prank(makeAddr("relayer"));
        (bool ok, bytes memory ret) = address(claimRouter).call(_signedClaimData(wallet, 0));
        _bubble(ok, ret);
        vm.deal(wallet, wallet.balance + 1 ether);
        r = _row(
            "claimSigned, a later signed release (the next nonce)",
            makeAddr("relayer"),
            address(claimRouter),
            _signedClaimData(wallet, 1),
            0
        );
        _gasAtMost(r, SIGNED_LATER_CEILING, "regression ceiling");
        _growthIs(r, 0, 0);
    }

    // ------------------------------------------------------------------ views

    /// @dev `royaltyInfo` derives the receiver through the split factory (ADR 0003): one cold
    ///      external view call. Marketplaces call it with their own gas limits.
    function _rowRoyaltyInfo() internal returns (Row memory r) {
        _steadyState();
        bytes memory data = abi.encodeCall(stream.royaltyInfo, (1, 1 ether));
        r = _row("royaltyInfo (cold)", starter, address(stream), data, 0);
        r.isView = true;
        r.total = 21_000 + r.execution; // a view: the call itself, without its calldata
        if (pass == Pass.BOTH) assertLt(r.execution, 50_000, "royaltyInfo: one cheap view call");
        _growthIs(r, 0, 0);
    }

    // ------------------------------------------------------------------ the gates

    function test_Gas_Start_SteadyState() public {
        _rowStart();
    }

    function test_Gas_StartWithBid_SteadyState() public {
        _rowStartWithBid();
    }

    function test_Gas_Start_TwoPartyWork() public {
        _rowStartTwoParty();
    }

    function test_Gas_StartWithBid_TwoPartyWork() public {
        _rowStartWithBidTwoParty();
    }

    function test_Gas_Start_VrfWork() public {
        _rowStartVrf();
    }

    function test_Gas_Start_EditionMaster() public {
        _rowStartMaster();
    }

    function test_Gas_StartWithBid_Permit2Erc20() public {
        _rowStartWithPermit2Bid();
    }

    function test_Gas_Start_FirstWorkInANewCollection() public {
        _rowStartNewCollection();
    }

    function test_Gas_Start_ArtistsFirstWork() public {
        _rowStartArtistFirst();
    }

    function test_Gas_StartWithBid_ArtistsFirstWork() public {
        _rowStartWithBidArtistFirst();
    }

    function test_Gas_StartWithBid_ArtistsFirstWork_TwoParty() public {
        _rowStartWithBidArtistFirstTwoParty();
    }

    function test_Gas_Start_FirstWorkEver() public {
        _rowStartFirstEver();
    }

    function test_Gas_StartWithBid_FirstBidUnderNewTerms() public {
        _rowStartWithBidNewTerms();
    }

    function test_Gas_Bid() public {
        _rowBid();
    }

    function test_Gas_Settle_FirstPayout() public {
        _rowSettleFirstPayout();
    }

    function test_Gas_Settle() public {
        _rowSettle();
    }

    function test_Gas_Settle_NoBid() public {
        _rowSettleNoBid();
    }

    function test_Gas_Consume() public {
        _rowConsume();
    }

    function test_Gas_AuctionView() public {
        _rowAuctionView();
    }

    function test_Gas_AuctionClockView() public {
        _rowAuctionClockView();
    }

    function test_Gas_MinimumBidView() public {
        _rowMinimumBidView();
    }

    function test_Gas_CreateEdition() public {
        _rowCreateEdition();
    }

    function test_Gas_ReRate() public {
        _rowReRate();
    }

    function test_Gas_RefreshStanding_FirstWallet() public {
        _rowRefreshFirst();
    }

    function test_Gas_RefreshStanding_FurtherWallet() public {
        _rowRefreshFurther();
    }

    function test_Gas_RoyaltyInfo() public {
        _rowRoyaltyInfo();
    }

    function test_Gas_CreateWallet() public {
        _rowCreateWallet();
    }

    function test_Gas_Release_First() public {
        _rowReleaseFirst();
    }

    function test_Gas_ClaimSigned_First() public {
        _rowSignedFirst();
    }

    function test_Gas_ClaimSigned_Later() public {
        _rowSignedLater();
    }

    function test_Gas_TokenURIBySize() public {
        _tokenUriMatrix(artistA, starter);
    }

    // ------------------------------------------------------------------ the table

    /// @dev Every row, each from a fresh copy of the set-up state, printed as one table. The
    ///      gates are the rows' own tests. Here each row runs twice: once for its gas, every
    ///      row before any recording, then once for its growth and cold accounts, which add the
    ///      cold-account surcharge.
    function test_Gas_Table() public {
        function() internal returns (Row memory)[30] memory rows = [
            _rowStart,
            _rowStartWithBid,
            _rowStartTwoParty,
            _rowStartWithBidTwoParty,
            _rowStartVrf,
            _rowStartMaster,
            _rowStartWithPermit2Bid,
            _rowStartNewCollection,
            _rowStartArtistFirst,
            _rowStartWithBidArtistFirst,
            _rowStartWithBidArtistFirstTwoParty,
            _rowStartFirstEver,
            _rowStartWithBidNewTerms,
            _rowBid,
            _rowSettleFirstPayout,
            _rowSettle,
            _rowSettleNoBid,
            _rowAuctionView,
            _rowMinimumBidView,
            _rowAuctionClockView,
            _rowConsume,
            _rowCreateEdition,
            _rowReRate,
            _rowRefreshFirst,
            _rowRefreshFurther,
            _rowRoyaltyInfo,
            _rowCreateWallet,
            _rowReleaseFirst,
            _rowSignedFirst,
            _rowSignedLater
        ];
        Row[30] memory measured;
        for (uint256 i; i < rows.length; ++i) {
            measured[i] = _runRow(rows[i], Pass.GAS);
        }
        console2.log(_line("Operation", "Prague gas", "New slots", "New accounts"));
        console2.log(_line("---", "---:", "---:", "---:"));
        for (uint256 i; i < rows.length; ++i) {
            StateGrowth.Growth memory growth = _runRow(rows[i], Pass.GROWTH).growth;
            uint256 execution = measured[i].execution + COLD_ACCOUNT_SURCHARGE
                * _warmButCold(measured[i].warmth, growth.coldAccounts);
            uint256 total =
                measured[i].isView ? 21_000 + execution : _txGas(measured[i].data, execution);
            console2.log(
                _line(
                    measured[i].label,
                    _thousands(total),
                    vm.toString(growth.slots),
                    vm.toString(growth.accounts)
                )
            );
        }
    }

    /// @dev Runs `row` for `which` measure from the current state, then restores it.
    function _runRow(function() internal returns (Row memory) row, Pass which)
        internal
        returns (Row memory r)
    {
        uint256 snapshot = vm.snapshotState();
        pass = which;
        r = row();
        vm.revertToStateAndDelete(snapshot);
    }

    function _line(string memory a, string memory b, string memory c, string memory d)
        internal
        pure
        returns (string memory)
    {
        return string.concat("| ", a, " | ", b, " | ", c, " | ", d, " |");
    }

    /// @dev `n` with thousands separators.
    function _thousands(uint256 n) internal pure returns (string memory s) {
        while (n >= 1000) {
            uint256 group = n % 1000;
            string memory digits = vm.toString(group);
            if (group < 10) digits = string.concat("00", digits);
            else if (group < 100) digits = string.concat("0", digits);
            s = string.concat(",", digits, s);
            n /= 1000;
        }
        s = string.concat(vm.toString(n), s);
    }
}
