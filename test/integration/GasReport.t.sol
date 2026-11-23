// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { EditionRules } from "src/editions/EditionRules.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IEnglishAuctionClock } from "src/interfaces/IEnglishAuctionClock.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
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
    SeedPolicy
} from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StateGrowth } from "../helpers/StateGrowth.sol";
import { GasBase } from "./GasBase.sol";

/// @notice The integration gas report on the deployed stack: every start, sale, edition, money
///         and view row, measured as a whole transaction in Prague gas, with the exact number of
///         new storage slots and new accounts it creates (ADR 0004, ADR 0010).
///         `forge test --match-test test_Gas_Table -vv` prints one table; each other `test_Gas_*`
///         gates one row (`-vv` on a start row also lists its new slots by contract).
/// @dev Gates:
///      - **Start rows** (an English-auction start of a 6529 Stream work, with or without a
///        bid): `START_BUDGET` (370,000 Prague gas) and, for the new slots, `START_MAX_SLOTS`
///        (8). A start with a bid of a VRF work also writes the seed (the ninth slot, in the
///        token), so those rows have their own ceiling: `VRF_START_BUDGET` (395,000) and
///        `VRF_START_MAX_SLOTS` (9) (`_vrfStartGates`). The ceilings are test budgets, not
///        chain code.
///      - **One-time rows** (the deployment's first start or first bid) and the other paths:
///        regression ceilings, the figure when set plus about 2%, rounded up to the thousand.
///        They are not budgets; a change that crosses one says why and moves it.
///      - **Settlement rows:** the 400,000 test ceiling. **royaltyInfo:** 50,000 execution gas.
///      Every row asserts its exact new slots and new accounts: a saved slot cannot be spent
///      again unnoticed. A change that lowers a count lowers it here.
///
///      Steady state: Stream, the collection, the auction's balance, the artist's move nonce and
///      a first bid (an earlier bidder's credit) all exist. Items are single-artist works (the
///      artist the sole, artist-resolved payee) in an eight-item package (proof depth 3). The
///      deployment includes the VRF entropy module (`_withVrf`), as on Sepolia.
contract IntegrationGasReport is GasBase {
    uint256 internal constant ITEMS = 8;
    /// @dev The rows of `test_Gas_Table`.
    uint256 internal constant ROWS = 39;
    /// @dev The settlement test ceiling (ADR 0004).
    uint256 internal constant SETTLE_CEILING = 400_000;
    /// @dev ADR 0004's budget for `royaltyInfo`, in execution gas.
    uint256 internal constant ROYALTY_INFO_EXECUTION = 50_000;
    /// @dev Regression ceilings, in Prague gas: each row's figure when it was set (22 November
    ///      2026, the plain-core stack), plus about 2%, rounded up to the thousand. Two were moved
    ///      on 23 November 2026, when `auctionClock` began to answer when a work was last offered
    ///      again (one more storage word read by the view, and by the edition settlement's first
    ///      call, which reads it): `AUCTION_CLOCK_VIEW_CEILING` (28,787 measured) and
    ///      `EDITION_SETTLE_CEILING` (180,815 measured).
    uint256 internal constant FIRST_START_CEILING = 357_000;
    uint256 internal constant FIRST_BID_CEILING = 353_000;
    uint256 internal constant STARTER_CEILING = 579_000;
    uint256 internal constant BID_CEILING = 76_000;
    uint256 internal constant AUTHORIZE_CEILING = 119_000;
    uint256 internal constant AUCTION_VIEW_CEILING = 34_000;
    uint256 internal constant MINIMUM_BID_VIEW_CEILING = 40_000;
    uint256 internal constant AUCTION_CLOCK_VIEW_CEILING = 30_000;
    uint256 internal constant EDITION_OPEN_CEILING = 260_000;
    uint256 internal constant EDITION_OPEN_WALLETS_CEILING = 402_000;
    uint256 internal constant EDITION_BID_NEW_WORD_CEILING = 89_000;
    uint256 internal constant EDITION_BID_CEILING = 71_000;
    uint256 internal constant EDITION_SETTLE_CEILING = 185_000;
    uint256 internal constant EDITION_CLAIM_WINNER_CEILING = 114_000;
    uint256 internal constant EDITION_CLAIM_REFUND_CEILING = 74_000;
    uint256 internal constant RERATE_CEILING = 231_000;
    uint256 internal constant CREATE_WALLET_CEILING = 98_000;
    uint256 internal constant RELEASE_FIRST_CEILING = 104_000;
    uint256 internal constant SIGNED_FIRST_CEILING = 150_000;
    uint256 internal constant SIGNED_LATER_CEILING = 98_000;
    /// @dev The edition master's creator cap.
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
    ///      `test_Gas_Table` takes every row's gas before any state-diff recording, then every
    ///      row's growth, and runs no gates.
    enum Pass {
        BOTH,
        GAS,
        GROWTH
    }

    Pass internal pass;
    address internal artistA;
    address internal artistB;
    address internal caller = makeAddr("gasCaller");
    address internal bidder = makeAddr("gasBidder");
    bytes32 internal root;
    /// @dev Artist A's seller vault (predicted; deployed by the rows that create it).
    address internal soloWallet;

    function _withVrf() internal pure override returns (bool) {
        return true;
    }

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
        soloWallet = economics.newWorkTerms(PRODUCT_STREAM, _soloPayees(artistA)).seller;
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

    /// @dev `r` creates exactly `slots` new slots and `accounts` new accounts. On a mismatch the
    ///      new slots and accounts are logged first, so the failure names them.
    function _growthIs(Row memory r, uint256 slots, uint256 accounts_) internal view {
        if (pass != Pass.BOTH) return;
        if (r.growth.slots != slots || r.growth.accounts != accounts_) _logGrowth(r);
        assertEq(r.growth.slots, slots, string.concat(r.label, ": new storage slots"));
        assertEq(r.growth.accounts, accounts_, string.concat(r.label, ": new accounts"));
    }

    /// @dev A start row: within the 370,000 start budget and the 8-slot maximum, its exact new
    ///      slots and no new account; its new slots are listed (`-vv`).
    function _startGates(Row memory r, uint256 slots) internal view {
        _gasAtMost(r, START_BUDGET, "370K start budget");
        _growthIs(r, slots, 0);
        if (pass != Pass.BOTH) return;
        _logGrowth(r);
        assertLe(r.growth.slots, START_MAX_SLOTS, string.concat(r.label, ": over 8 new slots"));
    }

    /// @dev A start with a bid of a VRF work: within the 395,000 ceiling and the 9-slot maximum
    ///      of those rows, its exact new slots and no new account.
    function _vrfStartGates(Row memory r, uint256 slots) internal view {
        _gasAtMost(r, VRF_START_BUDGET, "395K ceiling of a VRF start with a bid");
        _growthIs(r, slots, 0);
        if (pass != Pass.BOTH) return;
        _logGrowth(r);
        assertLe(r.growth.slots, VRF_START_MAX_SLOTS, string.concat(r.label, ": over 9 new slots"));
    }

    function _logGrowth(Row memory r) internal view {
        console2.log(r.label);
        console2.log("  Prague gas", r.total);
        for (uint256 i; i < r.growth.newSlots.length; ++i) {
            StateGrowth.Slot memory s = r.growth.newSlots[i];
            console2.log("  new slot", vm.getLabel(s.account), vm.toString(s.slot));
        }
        for (uint256 i; i < r.growth.newAccounts.length; ++i) {
            console2.log("  new account", vm.getLabel(r.growth.newAccounts[i]));
        }
    }

    /// @dev The accounts whose warmth `_measureGrowth` probes: the contracts, every actor of
    ///      this report and the split vaults its sales and editions reach.
    function _probeSet() internal override returns (address[] memory list) {
        address[] memory base = super._probeSet();
        address artistC = makeAddr("gasArtistC");
        address collaborator = makeAddr("gasCollaborator");
        address[10] memory vaults = [
            _seller(PRODUCT_STREAM, _soloPayees(artistA)),
            _royalty(PRODUCT_STREAM, _soloPayees(artistA)),
            _seller(PRODUCT_STREAM, _soloPayees(artistC)),
            _royalty(PRODUCT_STREAM, _soloPayees(artistC)),
            _seller(PRODUCT_STREAM, _duoPayees(artistA, collaborator)),
            _seller(PRODUCT_STREAM, _duoPayees(artistC, collaborator)),
            _seller(PRODUCT_EDITIONS, _soloPayees(artistA)),
            _royalty(PRODUCT_EDITIONS, _soloPayees(artistA)),
            _seller(PRODUCT_EDITIONS, _soloPayees(artistC)),
            _royalty(PRODUCT_EDITIONS, _soloPayees(artistC))
        ];
        address[21] memory actors = [
            artistA,
            artistB,
            artistC,
            collaborator,
            platform,
            caller,
            bidder,
            network,
            makeAddr("earlierBidder"),
            makeAddr("secondBidder"),
            makeAddr("masterCollector"),
            makeAddr("consolidatedWallet"),
            makeAddr("relayer"),
            makeAddr("b1"),
            makeAddr("b2"),
            makeAddr("b3"),
            makeAddr("b4"),
            makeAddr("b5"),
            makeAddr("editionEarlier"),
            address(editionLens),
            address(uint160(uint256(keccak256("unused probe"))))
        ];
        list = new address[](base.length + vaults.length + actors.length);
        uint256 n;
        for (uint256 i; i < base.length; ++i) {
            list[n++] = base[i];
        }
        for (uint256 i; i < vaults.length; ++i) {
            list[n++] = vaults[i];
        }
        for (uint256 i; i < actors.length; ++i) {
            list[n++] = actors[i];
        }
    }

    /// @dev The split vaults the release rows reach: their storage is cooled with the rest. The
    ///      address is computed once in `setUp`, so cooling calls nothing and warms no account.
    function _cooled() internal view override returns (address[] memory all) {
        address[] memory base = super._cooled();
        all = new address[](base.length + 1);
        for (uint256 i; i < base.length; ++i) {
            all[i] = base[i];
        }
        all[base.length] = soloWallet;
    }

    // ------------------------------------------------------------------ payees and vaults

    function _soloPayees(address lead) internal pure returns (ISplitWallet.Payee[] memory solo) {
        solo = new ISplitWallet.Payee[](1);
        solo[0] = ISplitWallet.Payee(uint160(lead), address(0), 100_000);
    }

    /// @dev The lead (artist-resolved, 80%) and a collaborator paid as a fixed payee (20%),
    ///      in canonical order (the fixed payee's artist ID is zero).
    function _duoPayees(address lead, address collaborator)
        internal
        pure
        returns (ISplitWallet.Payee[] memory duo)
    {
        duo = new ISplitWallet.Payee[](2);
        duo[0] = ISplitWallet.Payee(0, collaborator, 20_000);
        duo[1] = ISplitWallet.Payee(uint160(lead), address(0), 80_000);
    }

    function _seller(bytes32 product, ISplitWallet.Payee[] memory payees)
        internal
        view
        returns (address)
    {
        return economics.newWorkTerms(product, payees).seller;
    }

    function _royalty(bytes32 product, ISplitWallet.Payee[] memory payees)
        internal
        view
        returns (address)
    {
        return economics.newWorkTerms(product, payees).royaltyReceiver;
    }

    // ------------------------------------------------------------------ fixtures

    /// @dev Two live sales, one with a bid: every per-system record a start or a first bid
    ///      writes once (the auction's balance, an earlier bidder, the artist's nonce word)
    ///      already exists.
    function _steadyState() internal returns (uint256 firstSale) {
        Work[] memory works = _package(root);
        (firstSale,) = _start(root, works, 0);
        _start(root, works, 1);
        _ethBid(firstSale, makeAddr("earlierBidder"), 1 ether);
    }

    function _startData(bytes32 packageRoot, Work[] memory works, uint256 index)
        internal
        returns (bytes memory)
    {
        return abi.encodeCall(
            auction.start, (address(stream), _mintData(packageRoot, works, index))
        );
    }

    function _startWithBidData(bytes32 packageRoot, Work[] memory works, uint256 index)
        internal
        returns (bytes memory)
    {
        return abi.encodeCall(
            auction.startWithBid,
            (address(stream), _mintData(packageRoot, works, index), address(0))
        );
    }

    /// @dev Eight single-artist works by `lead` in the genesis collection, unpublished, so a row
    ///      can shape item 0 first.
    function _eightWorks(address lead) internal returns (Work[] memory works) {
        works = new Work[](ITEMS);
        for (uint256 i; i < ITEMS; ++i) {
            works[i] = _work(lead, collectionId);
        }
    }

    /// @dev Eight two-party works led by `lead`, with the collaborator paid as a fixed payee.
    function _twoPartyWorks(address lead) internal returns (Work[] memory works) {
        address collaborator = _actor("gasCollaborator");
        works = _eightWorks(lead);
        for (uint256 i; i < ITEMS; ++i) {
            works[i].item.parties = new Party[](2);
            works[i].item.parties[0] = Party(lead, uint8(PartyRole.ARTIST));
            works[i].item.parties[1] = Party(collaborator, uint8(PartyRole.COLLABORATOR));
            works[i].item.payees = _duoPayees(lead, collaborator);
        }
    }

    /// @dev Publishes `works` with item 0 VRF-seeded and its seed delivered before the start.
    function _publishVrf(Work[] memory works) internal returns (bytes32 vrfRoot) {
        works[0].item.seedPolicy = uint8(SeedPolicy.VRF);
        vrfRoot = _publish(works);
        uint256 requestId = entropy.requestSeed(works[0].item, vrfRoot, _proofOf(works, 0));
        coordinator.fulfill(requestId, uint256(keccak256("gas report randomness")));
    }

    /// @dev An edition master whose edition the uniform-price edition auction sells.
    function _asEditionMaster(Work memory w, uint32 cap) internal pure {
        w.item.kind = uint8(ItemKind.EDITION_MASTER);
        w.item.edition = EditionTerms(cap, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
    }

    /// @dev An edition master whose edition terms carry `EditionRules.MAX_PARAMS_BYTES` of
    ///      params, every byte nonzero: the most calldata and hashing a valid master adds to its
    ///      start (a fixed-price edition; the uniform auction takes no params).
    function _maxParamsMaster(Work memory w) internal pure {
        bytes memory p = new bytes(EditionRules.MAX_PARAMS_BYTES);
        for (uint256 i; i < p.length; ++i) {
            p[i] = bytes1(uint8(i % 251 + 1));
        }
        w.item.kind = uint8(ItemKind.EDITION_MASTER);
        w.item.edition = EditionTerms(10, CURRENCY_ETH, SaleKind.FIXED_PRICE, p);
    }

    // ------------------------------------------------------------------ the auction start

    function _rowStart() internal returns (Row memory r) {
        _steadyState();
        r = _row(
            "start, steady state", caller, address(auction), _startData(root, _package(root), 2), 0
        );
        _startGates(r, 7);
    }

    function _rowStartWithBid() internal returns (Row memory r) {
        _steadyState();
        bytes memory data = _startWithBidData(root, _package(root), 2);
        r = _row("startWithBid, steady state", bidder, address(auction), data, 1 ether);
        _startGates(r, 8);
    }

    /// @dev The move signed by a wallet consolidated with the lead's root on the 6529
    ///      delegation contract: the accounts module reads the consolidation source once.
    function _rowStartConsolidatedWallet() internal returns (Row memory r) {
        _steadyState();
        address wallet = _actor("consolidatedWallet");
        _consolidate(artistA, wallet);
        uint256 artistId = accounts.artistIdOf(artistA);
        bytes memory mintData =
            _mintDataSignedBy(root, _package(root), 2, wallet, nextMoveNonce[artistId]++);
        r = _row(
            "start, steady state, move signed by a consolidated wallet",
            caller,
            address(auction),
            abi.encodeCall(auction.start, (address(stream), mintData)),
            0
        );
        _startGates(r, 7);
    }

    function _rowStartTwoParty() internal returns (Row memory r) {
        _steadyState();
        Work[] memory works = _twoPartyWorks(artistA);
        bytes32 twoRoot = _publish(works);
        _start(twoRoot, works, 0);
        r = _row(
            "start, steady state, two-party work",
            caller,
            address(auction),
            _startData(twoRoot, works, 1),
            0
        );
        _startGates(r, 7);
    }

    function _rowStartWithBidTwoParty() internal returns (Row memory r) {
        _steadyState();
        Work[] memory works = _twoPartyWorks(artistA);
        bytes32 twoRoot = _publish(works);
        _start(twoRoot, works, 0);
        r = _row(
            "startWithBid, steady state, two-party work",
            bidder,
            address(auction),
            _startWithBidData(twoRoot, works, 1),
            1 ether
        );
        _startGates(r, 8);
    }

    function _rowStartVrf() internal returns (Row memory r) {
        _steadyState();
        Work[] memory works = _eightWorks(artistA);
        bytes32 vrfRoot = _publishVrf(works);
        r = _row(
            "start, steady state, VRF work",
            caller,
            address(auction),
            _startData(vrfRoot, works, 0),
            0
        );
        _startGates(r, 8);
    }

    function _rowStartWithBidVrf() internal returns (Row memory r) {
        _steadyState();
        Work[] memory works = _eightWorks(artistA);
        bytes32 vrfRoot = _publishVrf(works);
        r = _row(
            "startWithBid, steady state, VRF work",
            bidder,
            address(auction),
            _startWithBidData(vrfRoot, works, 0),
            1 ether
        );
        _vrfStartGates(r, 9);
    }

    function _rowStartMaster() internal returns (Row memory r) {
        _steadyState();
        Work[] memory works = _eightWorks(artistA);
        _asEditionMaster(works[0], EDITION_CAP);
        bytes32 masterRoot = _publish(works);
        r = _row(
            "start, steady state, edition master",
            caller,
            address(auction),
            _startData(masterRoot, works, 0),
            0
        );
        _startGates(r, 7);
    }

    function _rowStartMasterMaxParams() internal returns (Row memory r) {
        _steadyState();
        Work[] memory works = _eightWorks(artistA);
        _maxParamsMaster(works[0]);
        bytes32 masterRoot = _publish(works);
        r = _row(
            "start, edition master, params at the bound",
            caller,
            address(auction),
            _startData(masterRoot, works, 0),
            0
        );
        _startGates(r, 7);
    }

    function _rowStartNewCollection() internal returns (Row memory r) {
        _steadyState();
        r = _row(
            "start, first work in a new collection",
            caller,
            address(auction),
            _startData(root, _package(root), 6),
            0
        );
        _startGates(r, 7);
    }

    /// @dev Eight single-artist works by artist C, who has never started a work.
    function _artistCPackage() internal returns (bytes32 cRoot, Work[] memory works) {
        works = _eightWorks(_actor("gasArtistC"));
        cRoot = _publish(works);
    }

    function _rowStartArtistFirst() internal returns (Row memory r) {
        _steadyState();
        (bytes32 cRoot, Work[] memory works) = _artistCPackage();
        r = _row(
            "start, an artist's first work",
            caller,
            address(auction),
            _startData(cRoot, works, 0),
            0
        );
        _startGates(r, 7);
    }

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
        _startGates(r, 8);
    }

    function _rowStartWithBidArtistFirstTwoParty() internal returns (Row memory r) {
        _steadyState();
        Work[] memory works = _twoPartyWorks(_actor("gasArtistC"));
        bytes32 twoRoot = _publish(works);
        r = _row(
            "startWithBid, an artist's first work, two-party",
            bidder,
            address(auction),
            _startWithBidData(twoRoot, works, 0),
            1 ether
        );
        _startGates(r, 8);
    }

    function _rowStartWithBidArtistFirstTwoPartyVrf() internal returns (Row memory r) {
        _steadyState();
        Work[] memory works = _twoPartyWorks(_actor("gasArtistC"));
        bytes32 vrfRoot = _publishVrf(works);
        r = _row(
            "startWithBid, an artist's first work, two-party, VRF",
            bidder,
            address(auction),
            _startWithBidData(vrfRoot, works, 0),
            1 ether
        );
        _vrfStartGates(r, 9);
    }

    function _rowStartWithBidArtistFirstTwoPartyVrfMaxParams() internal returns (Row memory r) {
        _steadyState();
        Work[] memory works = _twoPartyWorks(_actor("gasArtistC"));
        _maxParamsMaster(works[0]);
        bytes32 vrfRoot = _publishVrf(works);
        r = _row(
            "startWithBid, an artist's first work, two-party, VRF, edition master, params at the bound",
            bidder,
            address(auction),
            _startWithBidData(vrfRoot, works, 0),
            1 ether
        );
        _vrfStartGates(r, 9);
    }

    /// @dev One-time: the first start on a new deployment.
    function _rowStartFirstEver() internal returns (Row memory r) {
        r = _row(
            "start, first work ever (one-time)",
            caller,
            address(auction),
            _startData(root, _package(root), 0),
            0
        );
        _gasAtMost(r, FIRST_START_CEILING, "regression ceiling");
        _growthIs(r, 9, 0);
    }

    /// @dev One-time: the first bid the auction ever takes (live sales exist, none has a bid).
    function _rowStartWithBidFirstBid() internal returns (Row memory r) {
        Work[] memory works = _package(root);
        _start(root, works, 0);
        _start(root, works, 1);
        r = _row(
            "startWithBid, the auction's first bid (one-time)",
            bidder,
            address(auction),
            _startWithBidData(root, works, 2),
            1 ether
        );
        _gasAtMost(r, FIRST_BID_CEILING, "regression ceiling");
        _growthIs(r, 8, 0);
    }

    /// @dev `SaleStarter.start` at steady state: the start, both vaults confirmed (the
    ///      artist's earlier sale created them) and the record opened in one transaction.
    function _rowSaleStarter() internal returns (Row memory r) {
        _steadyState();
        Work[] memory works = _package(root);
        starter.start(auction, address(stream), _mintData(root, works, 2), works[2].media);
        bytes memory data = abi.encodeCall(
            starter.start, (auction, address(stream), _mintData(root, works, 4), works[4].media)
        );
        r = _row(
            "SaleStarter.start, steady state (start, vaults, record)",
            caller,
            address(starter),
            data,
            0
        );
        _gasAtMost(r, STARTER_CEILING, "regression ceiling");
        _growthIs(r, 13, 0);
    }

    // ------------------------------------------------------------------ bids and settlement

    function _rowBid() internal returns (Row memory r) {
        _steadyState();
        (uint256 saleId,) = _start(root, _package(root), 2);
        _ethBid(saleId, bidder, 1 ether);
        address second = makeAddr("secondBidder");
        r = _row(
            "bid, outbids and credits the previous bidder",
            second,
            address(auction),
            abi.encodeCall(auction.bid, (saleId, address(0))),
            2 ether
        );
        _gasAtMost(r, BID_CEILING, "regression ceiling");
        _growthIs(r, 1, 0);
    }

    /// @dev The first sale to pay a payee configuration: its seller vault's address is still
    ///      empty, so the payout creates the account.
    function _rowSettleFirstPayout() internal returns (Row memory r) {
        _steadyState();
        (uint256 saleId,) = _start(root, _package(root), 2);
        _ethBid(saleId, bidder, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        r = _row(
            "settle, first payout to the seller vault",
            caller,
            address(auction),
            abi.encodeCall(auction.settle, (saleId)),
            0
        );
        _gasAtMost(r, SETTLE_CEILING, "400K test ceiling");
        if (pass == Pass.BOTH) assertEq(stream.ownerOf(auction.auction(saleId).tokenId), bidder);
        _growthIs(r, 1, 1);
    }

    /// @dev A settlement once the seller vault's account exists: the artist was paid before.
    function _rowSettle() internal returns (Row memory r) {
        uint256 earlier = _steadyState();
        (uint256 saleId,) = _start(root, _package(root), 2);
        _ethBid(saleId, bidder, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(earlier);
        r = _row(
            "settle, with a bid",
            caller,
            address(auction),
            abi.encodeCall(auction.settle, (saleId)),
            0
        );
        _gasAtMost(r, SETTLE_CEILING, "400K test ceiling");
        if (pass == Pass.BOTH) assertEq(stream.ownerOf(auction.auction(saleId).tokenId), bidder);
        _growthIs(r, 1, 0);
    }

    /// @dev A settlement with no bid: the work goes to the museum, nothing is paid. The museum
    ///      already holds an earlier unbid work, so its token balance exists.
    function _rowSettleNoBid() internal returns (Row memory r) {
        _steadyState();
        uint256 earlier = auction.saleIdOf(address(stream), stream.totalMinted()); // unbid
        (uint256 saleId,) = _start(root, _package(root), 2);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(earlier);
        assertEq(stream.balanceOf(museum), 1, "the museum holds the earlier unbid work");
        r = _row(
            "settle, no bid (to the museum)",
            caller,
            address(auction),
            abi.encodeCall(auction.settle, (saleId)),
            0
        );
        _gasAtMost(r, SETTLE_CEILING, "400K test ceiling");
        if (pass == Pass.BOTH) assertEq(stream.ownerOf(auction.auction(saleId).tokenId), museum);
        _growthIs(r, 0, 0);
    }

    // ------------------------------------------------------------------ views

    function _viewRow(string memory label, address target, bytes memory data)
        internal
        returns (Row memory r)
    {
        r = _row(label, caller, target, data, 0);
        r.isView = true;
        r.total = 21_000 + r.execution; // a view: the call itself, without its calldata
        _growthIs(r, 0, 0);
    }

    function _rowAuctionView() internal returns (Row memory r) {
        _steadyState();
        uint256 saleId = auction.saleIdOf(address(stream), 1);
        r = _viewRow("auction (view)", address(auction), abi.encodeCall(auction.auction, (saleId)));
        _gasAtMost(r, AUCTION_VIEW_CEILING, "regression ceiling");
    }

    function _rowMinimumBidView() internal returns (Row memory r) {
        _steadyState();
        uint256 saleId = auction.saleIdOf(address(stream), 1);
        r = _viewRow(
            "minimumBid (view)", address(auction), abi.encodeCall(auction.minimumBid, (saleId))
        );
        _gasAtMost(r, MINIMUM_BID_VIEW_CEILING, "regression ceiling");
    }

    /// @dev The integration view other contracts read on their hot paths (the edition auction's
    ///      open and soft close).
    function _rowAuctionClockView() internal returns (Row memory r) {
        _steadyState();
        uint256 saleId = auction.saleIdOf(address(stream), 1);
        r = _viewRow(
            "auctionClock (view)",
            address(auction),
            abi.encodeCall(IEnglishAuctionClock.auctionClock, (saleId))
        );
        _gasAtMost(r, AUCTION_CLOCK_VIEW_CEILING, "regression ceiling");
    }

    /// @dev `royaltyInfo` answers from Stream's own storage: marketplaces call it with their own
    ///      gas limits.
    function _rowRoyaltyInfo() internal returns (Row memory r) {
        _steadyState();
        r = _viewRow(
            "royaltyInfo (cold)", address(stream), abi.encodeCall(stream.royaltyInfo, (1, 1 ether))
        );
        if (pass == Pass.BOTH) {
            assertLe(r.execution, ROYALTY_INFO_EXECUTION, "royaltyInfo: 50,000 execution gas");
        }
    }

    /// @dev The mint policy's `authorize` alone, as the auction calls it at steady state.
    function _rowAuthorize() internal returns (Row memory r) {
        _steadyState();
        bytes memory request = _mintData(root, _package(root), 2);
        r = _row(
            "authorize (the mint policy's share of start, as a call)",
            address(auction),
            address(registry),
            abi.encodeCall(IMintPolicy.authorize, (address(stream), request)),
            0
        );
        _gasAtMost(r, AUTHORIZE_CEILING, "regression ceiling");
        _growthIs(r, 0, 0);
    }

    // ------------------------------------------------------------------ 6529 Stream Editions

    function _ea() internal view returns (IUniformEditionAuction) {
        return IUniformEditionAuction(address(editionAuction));
    }

    /// @dev A one-item package of an uncapped edition master by `lead`, published.
    function _masterPackage(address lead) internal returns (bytes32 r, Work[] memory works) {
        works = _one(_work(lead, collectionId));
        _asEditionMaster(works[0], 0);
        r = _publish(works);
    }

    function _openData(bytes32 r, Work[] memory works) internal pure returns (bytes memory) {
        return abi.encode(works[0].item, r, _proofOf(works, 0));
    }

    /// @dev A master by `lead` started; returns its 1/1 sale, token and the open call.
    function _startedMaster(address lead)
        internal
        returns (uint256 oneSale, uint256 tokenId, bytes32 r, Work[] memory works)
    {
        (r, works) = _masterPackage(lead);
        (oneSale, tokenId) = _start(r, works, 0);
    }

    /// @dev Artist A's first master opened: the seller and royalty vaults exist.
    function _editionSteadyState() internal {
        _steadyState();
        (, uint256 tokenId, bytes32 r, Work[] memory works) = _startedMaster(artistA);
        editionAuction.open(address(editions), tokenId, _openData(r, works));
    }

    /// @dev Artist A's master started and its edition opened at steady state.
    function _openMaster() internal returns (uint256 oneSale, uint256 saleId) {
        _editionSteadyState();
        uint256 tokenId;
        bytes32 r;
        Work[] memory works;
        (oneSale, tokenId, r, works) = _startedMaster(artistA);
        saleId = editionAuction.open(address(editions), tokenId, _openData(r, works));
    }

    function _editionBid(uint256 saleId, address who, uint256 step, uint256 quantity)
        internal
        returns (uint256 bidId)
    {
        uint256 value = quantity * _ea().stepPrice(saleId, step);
        vm.deal(who, who.balance + value);
        vm.prank(who);
        bidId = editionAuction.bid{ value: value }(saleId, step, quantity);
    }

    /// @dev Five bids on five steps (the edition sells at the lowest clearing step).
    function _traceTwo(uint256 saleId) internal {
        uint16[5] memory steps = [uint16(192), 158, 144, 130, 96];
        uint32[5] memory quantities = [uint32(1), 9, 20, 50, 200];
        for (uint256 i; i < 5; ++i) {
            _editionBid(
                saleId, makeAddr(string.concat("b", vm.toString(i + 1))), steps[i], quantities[i]
            );
        }
    }

    /// @dev The 1/1 sold and settled, the edition close reached.
    function _readyToSettle(uint256 oneSale, uint256 saleId) internal {
        _ethBid(oneSale, makeAddr("masterCollector"), 1 ether);
        _settleAtEnd(oneSale);
        IUniformEditionAuction.EndTimes memory e = _ea().endTimes(saleId);
        if (block.timestamp < e.endTime) vm.warp(e.endTime);
    }

    function _rowEditionOpen() internal returns (Row memory r) {
        _editionSteadyState();
        (, uint256 tokenId, bytes32 mr, Work[] memory works) = _startedMaster(artistA);
        r = _row(
            "edition open, steady state (creates the edition)",
            caller,
            address(editionAuction),
            abi.encodeCall(editionAuction.open, (address(editions), tokenId, _openData(mr, works))),
            0
        );
        _gasAtMost(r, EDITION_OPEN_CEILING, "regression ceiling");
        _growthIs(r, 5, 0);
    }

    /// @dev An artist's first edition sale: `open` deploys the seller's and the royalty
    ///      receiver's split vaults.
    function _rowEditionOpenDeploysWallets() internal returns (Row memory r) {
        _editionSteadyState();
        (, uint256 tokenId, bytes32 mr, Work[] memory works) = _startedMaster(_actor("gasArtistC"));
        r = _row(
            "edition open, an artist's first sale (deploys both vaults)",
            caller,
            address(editionAuction),
            abi.encodeCall(editionAuction.open, (address(editions), tokenId, _openData(mr, works))),
            0
        );
        _gasAtMost(r, EDITION_OPEN_WALLETS_CEILING, "regression ceiling");
        _growthIs(r, 7, 2);
    }

    function _rowEditionBidNewWord() internal returns (Row memory r) {
        (, uint256 saleId) = _openMaster();
        _editionBid(saleId, makeAddr("editionEarlier"), 130, 5);
        uint256 value = _ea().stepPrice(saleId, 100);
        r = _row(
            "edition bid, opens an 8-step word",
            bidder,
            address(editionAuction),
            abi.encodeCall(editionAuction.bid, (saleId, 100, 1)),
            value
        );
        _gasAtMost(r, EDITION_BID_NEW_WORD_CEILING, "regression ceiling");
        _growthIs(r, 2, 0);
    }

    function _rowEditionBid() internal returns (Row memory r) {
        (, uint256 saleId) = _openMaster();
        _editionBid(saleId, makeAddr("editionEarlier"), 130, 5);
        uint256 value = 3 * _ea().stepPrice(saleId, 131);
        r = _row(
            "edition bid, its 8-step word exists",
            bidder,
            address(editionAuction),
            abi.encodeCall(editionAuction.bid, (saleId, 131, 3)),
            value
        );
        _gasAtMost(r, EDITION_BID_CEILING, "regression ceiling");
        _growthIs(r, 1, 0);
    }

    function _rowEditionSettle() internal returns (Row memory r) {
        (uint256 oneSale, uint256 saleId) = _openMaster();
        _traceTwo(saleId);
        _readyToSettle(oneSale, saleId);
        r = _row(
            "edition settle, 5 used steps",
            caller,
            address(editionAuction),
            abi.encodeCall(editionAuction.settle, (saleId, new uint256[](0))),
            0
        );
        _gasAtMost(r, EDITION_SETTLE_CEILING, "regression ceiling");
        _growthIs(r, 1, 0);
    }

    function _settledTraceTwo() internal returns (uint256 saleId) {
        uint256 oneSale;
        (oneSale, saleId) = _openMaster();
        _traceTwo(saleId);
        _readyToSettle(oneSale, saleId);
        editionAuction.settle(saleId, new uint256[](0));
    }

    function _rowEditionClaimWinner() internal returns (Row memory r) {
        uint256 saleId = _settledTraceTwo();
        address b = makeAddr("b2");
        r = _row(
            "edition claimBid, winner, the edition's first mint",
            b,
            address(editionAuction),
            abi.encodeCall(editionAuction.claimBid, (saleId, 2, b)),
            0
        );
        _gasAtMost(r, EDITION_CLAIM_WINNER_CEILING, "regression ceiling");
        _growthIs(r, 1, 0);
    }

    function _rowEditionClaimRefund() internal returns (Row memory r) {
        uint256 saleId = _settledTraceTwo();
        address b = makeAddr("b5");
        r = _row(
            "edition claimBid, refund only",
            b,
            address(editionAuction),
            abi.encodeCall(editionAuction.claimBid, (saleId, 5, b)),
            0
        );
        _gasAtMost(r, EDITION_CLAIM_REFUND_CEILING, "regression ceiling");
        _growthIs(r, 0, 0);
    }

    // ------------------------------------------------------------------ re-rate

    /// @dev A work re-rated to 5% with the artist's consent, FUNDS_SETTER's governed action
    ///      executed through the manager: WorkRules bumps the work's version and the TERMS
    ///      module writes the rate to Stream.
    function _rowReRate() internal returns (Row memory r) {
        uint256 tokenId = auction.auction(_steadyState()).tokenId;
        Work[] memory works = _package(root);
        _open(tokenId, works[0]);
        uint24 rate = 5_000;
        uint64 deadline = uint64(block.timestamp + 30 days);
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                rules.domainSeparator(),
                keccak256(
                    abi.encode(
                        rules.ROYALTY_RATE_TYPEHASH(),
                        address(stream),
                        tokenId,
                        rate,
                        state,
                        deadline
                    )
                )
            )
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(artistA, _sign(artistA, digest));
        bytes memory call = abi.encodeCall(
            rules.setRoyaltyRate,
            (address(stream), tokenId, rate, works[0].item, state, deadline, sigs)
        );
        (, uint32 delay) = manager.canCall(network, address(rules), bytes4(call));
        vm.prank(network);
        manager.schedule(address(rules), call, 0);
        vm.warp(block.timestamp + delay);
        r = _row(
            "re-rate a work (governed execute)",
            network,
            address(manager),
            abi.encodeCall(manager.execute, (address(rules), call)),
            0
        );
        _gasAtMost(r, RERATE_CEILING, "regression ceiling");
        _growthIs(r, 1, 0);
        if (pass == Pass.BOTH) assertEq(stream.workOf(tokenId).royaltyRate, rate);
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

    // ------------------------------------------------------------------ split vaults

    /// @dev The first sale settled into the seller vault, the vault deployed, and the artist an
    ///      existing account (payees exist).
    function _fundedWallet() internal returns (address wallet) {
        uint256 first = _steadyState();
        _settleAtEnd(first);
        wallet = ledger.createWallet(_soloPayees(artistA), bytes32(0));
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
        claims[0] = IClaimRouter.SignedClaim(
            a, _sign(artistA, ledger.releaseDigest(a)), _soloPayees(artistA), bytes32(0)
        );
        return abi.encodeCall(IClaimRouter.claimSigned, (claims, false));
    }

    /// @dev A new payee configuration's seller vault, deployed once (permissionless).
    function _rowCreateWallet() internal returns (Row memory r) {
        r = _row(
            "createWallet, a seller vault (one artist payee)",
            caller,
            address(ledger),
            abi.encodeCall(ledger.createWallet, (_soloPayees(artistA), bytes32(0))),
            0
        );
        _gasAtMost(r, CREATE_WALLET_CEILING, "regression ceiling");
        _growthIs(r, 1, 1);
    }

    /// @dev The artist pulls its first ETH from the seller vault through the split ledger.
    function _rowReleaseFirst() internal returns (Row memory r) {
        _fundedWallet();
        r = _row(
            "release, the artist's first ETH release",
            artistA,
            address(ledger),
            abi.encodeCall(
                ISplitWallet.release, (_soloPayees(artistA), bytes32(0), CURRENCY_ETH, 0)
            ),
            0
        );
        _gasAtMost(r, RELEASE_FIRST_CEILING, "regression ceiling");
        _growthIs(r, 2, 0);
    }

    /// @dev A relayer submits the artist's first signed release through the claim router.
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

    /// @dev The artist's next signed release, with the next nonce, after more revenue arrived.
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

    // ------------------------------------------------------------------ tokenURI by size

    uint256[4] internal base64Sizes = [uint256(32_768), 65_536, 131_072, 262_144];
    uint256[2] internal identitySizes = [uint256(32_768), 65_536];

    /// @dev The `tokenURI` gas matrix: one work per row, sold, opened, attested and marked
    ///      on-chain complete, then `Stream6529.tokenURI` measured from a cold start through the
    ///      whole path (Stream, WorkFacts, the renderer, the content store, the statement log,
    ///      the accounts module). Rows: 32, 64, 128 and 256 KiB of base64-stored media, and 32
    ///      and 64 KiB of identity media. Each row fits 8M Prague gas (with the cold-account
    ///      surcharge), inlines exactly when the renderer's cost-weighted threshold allows it,
    ///      and creates no state.
    function _tokenUriMatrix(address lead, address reader) internal {
        Work[] memory works = new Work[](6);
        for (uint256 i; i < 4; ++i) {
            bytes memory media = _bytes(base64Sizes[i] / 4 * 3, i);
            works[i] = _storedWork(
                lead,
                bytes(Base64.encode(media)),
                IContentStore.Encoding.Base64,
                sha256(media),
                string.concat("Base64 ", vm.toString(base64Sizes[i]))
            );
        }
        for (uint256 i; i < 2; ++i) {
            bytes memory media = _bytes(identitySizes[i], 10 + i);
            works[4 + i] = _storedWork(
                lead,
                media,
                IContentStore.Encoding.Identity,
                sha256(media),
                string.concat("Identity ", vm.toString(identitySizes[i]))
            );
        }
        bytes32 matrixRoot = _publish(works);
        uint256[] memory ids = new uint256[](6);
        for (uint256 i; i < 6; ++i) {
            (, ids[i]) = _start(matrixRoot, works, i);
            _open(ids[i], works[i]);
            if (i < 4) _attestAll(works[i].media[0].fileId);
            facts.markOnChainComplete(address(stream), ids[i]);
        }
        // Every gas figure first: none can be measured after a state-diff recording. Each view
        // is called once before it is measured, so every account it reaches is warm and the
        // cold-account surcharge below applies to all of them.
        uint256[] memory used = new uint256[](6);
        for (uint256 i; i < 6; ++i) {
            bool inlined = _contains(stream.tokenURI(ids[i]), "data:image/png;base64,");
            // Base64 inlines up to the 256 KiB threshold; identity media counts eight times, so
            // 32 KiB inlines and 64 KiB falls back to its locator.
            assertEq(inlined, i != 5, string.concat(_matrixLabel(i), ": inline as expected"));
            (, used[i]) =
                _measure(reader, address(stream), abi.encodeCall(stream.tokenURI, (ids[i])), 0);
        }
        console2.log("Stream.tokenURI Prague gas, cold (stored bytes of the primary file)");
        for (uint256 i; i < 6; ++i) {
            StateGrowth.Growth memory growth =
                _growth(reader, address(stream), abi.encodeCall(stream.tokenURI, (ids[i])), 0);
            assertEq(growth.slots + growth.accounts, 0, "tokenURI creates no state");
            used[i] += COLD_ACCOUNT_SURCHARGE * growth.coldAccounts.length;
            console2.log(_matrixLabel(i), used[i]);
            assertLe(used[i], TOKEN_URI_BUDGET, _matrixLabel(i));
        }
    }

    function _matrixLabel(uint256 i) internal view returns (string memory) {
        return i < 4
            ? string.concat("  base64   ", vm.toString(base64Sizes[i]))
            : string.concat("  identity ", vm.toString(identitySizes[i - 4]));
    }

    // ------------------------------------------------------------------ the gates

    function test_Gas_Start_SteadyState() public {
        _rowStart();
    }

    function test_Gas_StartWithBid_SteadyState() public {
        _rowStartWithBid();
    }

    function test_Gas_Start_ConsolidatedWallet() public {
        _rowStartConsolidatedWallet();
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

    function test_Gas_StartWithBid_VrfWork() public {
        _rowStartWithBidVrf();
    }

    function test_Gas_Start_EditionMaster() public {
        _rowStartMaster();
    }

    function test_Gas_Start_EditionMaster_MaxParams() public {
        _rowStartMasterMaxParams();
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

    function test_Gas_StartWithBid_ArtistsFirstWork_TwoParty_Vrf() public {
        _rowStartWithBidArtistFirstTwoPartyVrf();
    }

    function test_Gas_StartWithBid_ArtistsFirstWork_TwoParty_Vrf_MaxParams() public {
        _rowStartWithBidArtistFirstTwoPartyVrfMaxParams();
    }

    function test_Gas_Start_FirstWorkEver() public {
        _rowStartFirstEver();
    }

    function test_Gas_StartWithBid_FirstBid() public {
        _rowStartWithBidFirstBid();
    }

    function test_Gas_SaleStarter_Start() public {
        _rowSaleStarter();
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

    function test_Gas_AuctionView() public {
        _rowAuctionView();
    }

    function test_Gas_MinimumBidView() public {
        _rowMinimumBidView();
    }

    function test_Gas_AuctionClockView() public {
        _rowAuctionClockView();
    }

    function test_Gas_RoyaltyInfo() public {
        _rowRoyaltyInfo();
    }

    function test_Gas_Authorize() public {
        _rowAuthorize();
    }

    function test_Gas_EditionOpen() public {
        _rowEditionOpen();
    }

    function test_Gas_EditionOpen_DeploysWallets() public {
        _rowEditionOpenDeploysWallets();
    }

    function test_Gas_EditionBid_NewWord() public {
        _rowEditionBidNewWord();
    }

    function test_Gas_EditionBid() public {
        _rowEditionBid();
    }

    function test_Gas_EditionSettle() public {
        _rowEditionSettle();
    }

    function test_Gas_EditionClaim_Winner() public {
        _rowEditionClaimWinner();
    }

    function test_Gas_EditionClaim_Refund() public {
        _rowEditionClaimRefund();
    }

    function test_Gas_ReRate() public {
        _rowReRate();
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
        _tokenUriMatrix(artistA, caller);
    }

    // ------------------------------------------------------------------ the table

    /// @dev Every row, each from a fresh copy of the set-up state, printed as one table with its
    ///      ceiling. The gates are the rows' own tests. Here each row runs twice: once for its
    ///      gas, every row before any recording, then once for its growth and cold accounts,
    ///      which add the cold-account surcharge.
    function test_Gas_Table() public {
        function() internal returns (Row memory)[ROWS] memory rows = _rows();
        uint256[ROWS] memory ceilings = _ceilings();
        Row[ROWS] memory measured;
        for (uint256 i; i < ROWS; ++i) {
            measured[i] = _runRow(rows[i], Pass.GAS);
        }
        console2.log(_line("Operation", "Prague gas", "Ceiling", "New slots", "New accounts"));
        console2.log(_line("---", "---:", "---:", "---:", "---:"));
        for (uint256 i; i < ROWS; ++i) {
            StateGrowth.Growth memory growth = _runRow(rows[i], Pass.GROWTH).growth;
            uint256 execution = measured[i].execution + COLD_ACCOUNT_SURCHARGE
                * _warmButCold(measured[i].warmth, growth.coldAccounts);
            uint256 total =
                measured[i].isView ? 21_000 + execution : _txGas(measured[i].data, execution);
            console2.log(
                _line(
                    measured[i].label,
                    _thousands(total),
                    _thousands(ceilings[i]),
                    vm.toString(growth.slots),
                    vm.toString(growth.accounts)
                )
            );
        }
    }

    function _rows() internal pure returns (function() internal returns (Row memory)[ROWS] memory) {
        return [
            _rowStart,
            _rowStartWithBid,
            _rowStartConsolidatedWallet,
            _rowStartTwoParty,
            _rowStartWithBidTwoParty,
            _rowStartVrf,
            _rowStartWithBidVrf,
            _rowStartMaster,
            _rowStartMasterMaxParams,
            _rowStartNewCollection,
            _rowStartArtistFirst,
            _rowStartWithBidArtistFirst,
            _rowStartWithBidArtistFirstTwoParty,
            _rowStartWithBidArtistFirstTwoPartyVrf,
            _rowStartWithBidArtistFirstTwoPartyVrfMaxParams,
            _rowStartFirstEver,
            _rowStartWithBidFirstBid,
            _rowSaleStarter,
            _rowBid,
            _rowSettleFirstPayout,
            _rowSettle,
            _rowSettleNoBid,
            _rowAuctionView,
            _rowMinimumBidView,
            _rowAuctionClockView,
            _rowRoyaltyInfo,
            _rowAuthorize,
            _rowEditionOpen,
            _rowEditionOpenDeploysWallets,
            _rowEditionBidNewWord,
            _rowEditionBid,
            _rowEditionSettle,
            _rowEditionClaimWinner,
            _rowEditionClaimRefund,
            _rowReRate,
            _rowCreateWallet,
            _rowReleaseFirst,
            _rowSignedFirst,
            _rowSignedLater
        ];
    }

    /// @dev Each row's ceiling, in the order of `_rows` (royaltyInfo: 21,000 plus its 50,000
    ///      execution budget).
    function _ceilings() internal pure returns (uint256[ROWS] memory c) {
        for (uint256 i; i < 15; ++i) {
            c[i] = START_BUDGET;
        }
        // The three starts with a bid of a VRF work.
        (c[6], c[13], c[14]) = (VRF_START_BUDGET, VRF_START_BUDGET, VRF_START_BUDGET);
        c[15] = FIRST_START_CEILING;
        c[16] = FIRST_BID_CEILING;
        c[17] = STARTER_CEILING;
        c[18] = BID_CEILING;
        (c[19], c[20], c[21]) = (SETTLE_CEILING, SETTLE_CEILING, SETTLE_CEILING);
        c[22] = AUCTION_VIEW_CEILING;
        c[23] = MINIMUM_BID_VIEW_CEILING;
        c[24] = AUCTION_CLOCK_VIEW_CEILING;
        c[25] = 21_000 + ROYALTY_INFO_EXECUTION;
        c[26] = AUTHORIZE_CEILING;
        c[27] = EDITION_OPEN_CEILING;
        c[28] = EDITION_OPEN_WALLETS_CEILING;
        c[29] = EDITION_BID_NEW_WORD_CEILING;
        c[30] = EDITION_BID_CEILING;
        c[31] = EDITION_SETTLE_CEILING;
        c[32] = EDITION_CLAIM_WINNER_CEILING;
        c[33] = EDITION_CLAIM_REFUND_CEILING;
        c[34] = RERATE_CEILING;
        c[35] = CREATE_WALLET_CEILING;
        c[36] = RELEASE_FIRST_CEILING;
        c[37] = SIGNED_FIRST_CEILING;
        c[38] = SIGNED_LATER_CEILING;
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

    function _line(
        string memory a,
        string memory b,
        string memory c,
        string memory d,
        string memory e
    ) internal pure returns (string memory) {
        return string.concat("| ", a, " | ", b, " | ", c, " | ", d, " | ", e, " |");
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
