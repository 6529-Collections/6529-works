// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionFormat,
    EditionTerms,
    ItemKind,
    Party,
    PartyRole,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { Payment, PaymentMethod, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StateGrowth } from "../helpers/StateGrowth.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice The integration gas report: the budgets of ADR 0001, ADR 0003 and ADR 0004, measured
///         on the real, wired contracts. `forge test --match-test test_Gas_Table -vv` prints one
///         table (operation, Prague gas, new slots, new accounts); each other `test_Gas_*` gates
///         one row.
/// @dev Two measures per row (ADR 0004):
///      - **Prague gas.** Foundry 1.7.1 has no Glamsterdam EVM, so every figure is the gas the
///        transaction uses at Prague costs: 21,000 intrinsic, the calldata (EIP-2028, or the
///        EIP-7623 floor when higher) and the execution measured with every contract's storage
///        cooled first. The execution is the called frame's own gas (`vm.lastCallGas`), which is
///        what a transaction to the target executes: the test's cold call into the target and its
///        value transfer are paid by the caller's frame and are not counted. Refunds are not
///        deducted. The 350K start budget and the other ceilings are Prague figures.
///
///        `vm.cool` cools storage but not accounts, so every account the call reaches besides
///        its target is priced as warm, about 2,500 gas under a real transaction. The
///        steady-state start reaches seven, which is why a Prague replay of the Sepolia start
///        (293,243) is about 17,500 above this report.
///      - **State growth.** Glamsterdam prices each new storage slot and each new account far
///        above Prague (on Sepolia, about 111K per slot and about 205K for ETH sent to a fresh
///        account). Every row caps the new slots and new accounts its transaction creates,
///        counted by `StateGrowth` from the state diff. The steady-state start caps (6 slots,
///        7 with a bid) are ADR 0004's; the others are the counts measured when ADR 0004 set
///        them, as a regression gate. Lower a cap when a change saves a slot.
///
///      Steady state (ADR 0003): Stream, the collection, the auction's custody balance, the
///      artist's move-nonce word and the auction's shared sale terms (with and without the
///      increment floor a first bid locks) have all been written before. Items are single-artist works
///      (the artist is the sole, artist-resolved payee) in an eight-item package (proof depth 3).
contract IntegrationGasReport is IntegrationBase {
    uint256 internal constant ITEMS = 8;
    /// @dev Prague execution gas, whole transaction (ADR 0004 keeps the ceilings at Prague).
    uint256 internal constant SETTLE_BUDGET = 400_000;
    /// @dev Tracked, not gated by an ADR: the first work of a new collection writes its serial
    ///      word from zero; ADR 0003 measures it separately. Prague execution gas.
    uint256 internal constant FIRST_IN_COLLECTION_CEILING = 400_000;
    /// @dev ADR 0004: the new storage slots a steady-state start may write, without and with a
    ///      bid (the token record, the owner, the consumed-content record and the sale; the bid).
    uint256 internal constant START_SLOTS = 6;
    uint256 internal constant START_WITH_BID_SLOTS = 7;
    /// @dev The edition master's terms, as on the Sepolia rehearsal (flows.md, section 3).
    uint64 internal constant EDITION_SIZE = 10;
    uint256 internal constant EDITION_PRICE = 0.0001 ether;
    /// @dev A 6529 consolidation: use case 999 over all collections.
    address internal constant ALL_COLLECTIONS = 0x8888888888888888888888888888888888888888;
    uint256 internal constant CONSOLIDATION = 999;

    /// @dev One measured transaction.
    struct Row {
        string label;
        uint256 total;
        uint256 execution;
        StateGrowth.Growth growth;
    }

    /// @dev What `_row` measures. A row's own test takes both; `test_Gas_Table` takes every
    ///      row's gas before any state-diff recording (see `_measureGrowth`), then the growth.
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
        // On a real deployment the network fee recipient is a Safe, an account that exists (the
        // deploy refuses holders without code). Here it is a placeholder address, so it is
        // funded once, and no row counts it as a new account.
        vm.deal(networkFee, 1);
    }

    // ------------------------------------------------------------------ measuring

    function _row(
        string memory label,
        address from,
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (Row memory r) {
        r.label = label;
        if (pass == Pass.BOTH) {
            (r.total, r.execution, r.growth) = _measureGrowth(from, target, data, value);
        } else if (pass == Pass.GAS) {
            (r.total, r.execution) = _measure(from, target, data, value);
        } else {
            r.growth = _growth(from, target, data, value);
        }
    }

    /// @dev Caps `r`'s state growth (ADR 0004). Over a cap, the new slots and accounts are
    ///      logged first, so the failure names them.
    function _capGrowth(Row memory r, uint256 slots, uint256 accounts) internal view {
        if (r.growth.slots > slots || r.growth.accounts > accounts) _logGrowth(r);
        assertLe(r.growth.slots, slots, string.concat(r.label, ": new storage slots (ADR 0004)"));
        assertLe(r.growth.accounts, accounts, string.concat(r.label, ": new accounts (ADR 0004)"));
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
        if (account == address(fixedSale)) return "FixedPriceSale";
        if (account == address(artists)) return "ArtistRegistry";
        if (account == address(escrow)) return "RevenueEscrow";
        if (account == address(economics)) return "EconomicsResolver";
        if (account == address(splitFactory)) return "SplitFactory";
        if (account == address(statements)) return "StatementLog";
        return vm.getLabel(account);
    }

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

    // ------------------------------------------------------------------ the auction start

    function _rowStart() internal returns (Row memory r) {
        _steadyState();
        r = _row("start, steady state", starter, address(auction), _startData(2), 0);
        assertLe(r.total, START_BUDGET, "ADR 0004: start <= 350K Prague execution gas");
        _capGrowth(r, START_SLOTS, 0);
    }

    function _rowStartWithBid() internal returns (Row memory r) {
        _steadyState();
        bytes memory data = _startWithBidData(root, _package(root), 2);
        r = _row("startWithBid, steady state", bidder, address(auction), data, 1 ether);
        assertLe(r.total, START_BUDGET, "ADR 0004: startWithBid <= 350K Prague execution gas");
        _capGrowth(r, START_WITH_BID_SLOTS, 0);
    }

    /// @dev A two-party work: the lead artist and a collaborator who is paid as a fixed payee.
    function _twoPartyPackage() internal returns (bytes32 twoRoot, Work[] memory works) {
        address collaborator = _actor("gasCollaborator");
        works = new Work[](ITEMS);
        for (uint256 i; i < ITEMS; ++i) {
            works[i] = _work(artistA, collectionId);
            works[i].item.parties = new Party[](2);
            works[i].item.parties[0] = Party(artistA, PartyRole.ARTIST);
            works[i].item.parties[1] = Party(collaborator, PartyRole.COLLABORATOR);
            works[i].item.payees = new ISplitWallet.Payee[](2);
            works[i].item.payees[0] = ISplitWallet.Payee(0, collaborator, 20_000);
            works[i].item.payees[1] = ISplitWallet.Payee(uint160(artistA), address(0), 80_000);
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
        assertLe(r.total, START_BUDGET, "ADR 0004: a two-party start <= 350K Prague execution gas");
        _capGrowth(r, START_SLOTS, 0);
    }

    /// @dev The smallest collaboration (the artist plus one collaborator, paid as a fixed payee)
    ///      is held to the same steady-state budget (formerly finding G-2, resolved by #34).
    function _rowStartWithBidTwoParty() internal returns (Row memory r) {
        _steadyState();
        (bytes32 twoRoot, Work[] memory works) = _twoPartyPackage();
        _start(twoRoot, works, 0);
        bytes memory data = _startWithBidData(twoRoot, works, 1);
        r = _row(
            "startWithBid, steady state, two-party work", bidder, address(auction), data, 1 ether
        );
        assertLe(
            r.total, START_BUDGET, "ADR 0004: a two-party startWithBid <= 350K Prague execution gas"
        );
        _capGrowth(r, START_WITH_BID_SLOTS, 0);
    }

    function _rowStartNewCollection() internal returns (Row memory r) {
        _steadyState();
        r = _row(
            "start, first work in a new collection", starter, address(auction), _startData(6), 0
        );
        assertLe(
            r.total,
            FIRST_IN_COLLECTION_CEILING,
            "first start in a new collection <= 400K Prague execution gas"
        );
        _capGrowth(r, 6, 0);
    }

    /// @dev Tracked, not gas-gated: the first start on a new deployment (empty custody, the
    ///      first fee terms and sale terms).
    function _rowStartFirstEver() internal returns (Row memory r) {
        r = _row("start, first work ever (one-time)", starter, address(auction), _startData(0), 0);
        _capGrowth(r, 13, 0);
    }

    /// @dev Tracked, not gas-gated: the first bid placed under a set of sale terms nobody has
    ///      bid under yet (after genesis, a new currency, or an auction config or opening-bid
    ///      change). Live sales exist, but none has a bid.
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
        _capGrowth(r, 10, 0);
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
        _capGrowth(r, 1, 0);
    }

    /// @dev The first sale to pay a payee configuration: its seller wallet's predicted address
    ///      is still empty, so the payout creates the account (once per configuration).
    function _rowSettleFirstPayout() internal returns (Row memory r) {
        _steadyState();
        (uint256 saleId,) = _start(root, _package(root), 2);
        _ethBid(saleId, bidder, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        bytes memory data = abi.encodeCall(auction.settle, (saleId));
        r = _row("settle, first payout to the seller wallet", starter, address(auction), data, 0);
        assertLe(r.total, SETTLE_BUDGET, "settle <= 400K Prague execution gas");
        assertEq(stream.ownerOf(auction.auction(saleId).tokenId), bidder);
        _capGrowth(r, 1, 1);
    }

    /// @dev A settlement once the seller wallet exists: the artist has been paid before.
    function _rowSettle() internal returns (Row memory r) {
        uint256 earlier = _steadyState();
        (uint256 saleId,) = _start(root, _package(root), 2);
        _ethBid(saleId, bidder, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(earlier); // the same artist's earlier sale pays its seller wallet first
        bytes memory data = abi.encodeCall(auction.settle, (saleId));
        r = _row("settle, with a bid", starter, address(auction), data, 0);
        assertLe(r.total, SETTLE_BUDGET, "settle <= 400K Prague execution gas");
        assertEq(stream.ownerOf(auction.auction(saleId).tokenId), bidder);
        _capGrowth(r, 1, 0);
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
        _capGrowth(r, 1, 0);
    }

    // ------------------------------------------------------------------ 6529 Editions

    /// @dev An eight-item package whose item 0 is an edition master (a fixed edition of 10 at
    ///      0.0001 ETH, sold at a fixed price), as on the Sepolia rehearsal. The master is
    ///      started at steady state, bid on and settled.
    function _settledMaster()
        internal
        returns (uint256 workId, bytes32 masterRoot, Work[] memory works)
    {
        _steadyState();
        works = new Work[](ITEMS);
        for (uint256 i; i < ITEMS; ++i) {
            works[i] = _work(artistA, collectionId);
        }
        works[0].item.kind = ItemKind.EDITION_MASTER;
        works[0].item.edition = EditionTerms(
            EditionFormat.FIXED,
            EDITION_SIZE,
            0,
            EDITION_PRICE,
            CURRENCY_ETH,
            SaleKind.FIXED_PRICE,
            ""
        );
        masterRoot = _publish(works);
        uint256 saleId;
        (saleId, workId) = _start(masterRoot, works, 0);
        _ethBid(saleId, makeAddr("masterCollector"), 1 ether);
        _settleAtEnd(saleId);
    }

    function _createEditionData(uint256 workId, bytes32 masterRoot, Work[] memory works)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            editions.createEdition, (workId, works[0].item, masterRoot, _proofOf(works, 0))
        );
    }

    /// @dev Tracked, not gas-gated (no ADR sets an Editions budget).
    function _rowCreateEdition() internal returns (Row memory r) {
        (uint256 workId, bytes32 masterRoot, Work[] memory works) = _settledMaster();
        bytes memory data = _createEditionData(workId, masterRoot, works);
        r = _row("createEdition", starter, address(editions), data, 0);
        _capGrowth(r, 9, 0);
    }

    function _openSaleData(uint256 editionId) internal view returns (bytes memory) {
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](1);
        phases[0] = IFixedPriceSale.Phase(
            uint64(block.timestamp), uint64(block.timestamp + 1 days), bytes32(0), 0, false, false
        );
        return abi.encodeCall(
            fixedSale.openSale,
            (address(editions), editionId, phases, IFixedPriceSale.ArtistConsent(0, 0, ""))
        );
    }

    /// @dev The edition after `createEdition`, ready for the PLATFORM's `openSale`.
    function _createdEdition() internal returns (uint256 editionId) {
        (uint256 workId, bytes32 masterRoot, Work[] memory works) = _settledMaster();
        editions.createEdition(workId, works[0].item, masterRoot, _proofOf(works, 0));
        editionId = workId;
    }

    /// @dev The PLATFORM opens one public phase at the package price, without the artist's
    ///      consent. Tracked, not gas-gated.
    function _rowOpenSale() internal returns (Row memory r) {
        uint256 editionId = _createdEdition();
        r = _row(
            "openSale (PLATFORM, one public phase)",
            platform,
            address(fixedSale),
            _openSaleData(editionId),
            0
        );
        _capGrowth(r, 8, 0);
    }

    function _purchaseData(uint256 saleId, address buyer, uint256 quantity)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            fixedSale.purchase,
            (
                IFixedPriceSale.Purchase(saleId, 0, buyer, quantity, 0, 0),
                new bytes32[](0),
                Payment(PaymentMethod.DIRECT, buyer, EDITION_PRICE * quantity, 0, 0, "")
            )
        );
    }

    function _openEditionSale() internal returns (uint256 saleId) {
        uint256 editionId = _createdEdition();
        vm.prank(platform);
        (bool ok, bytes memory ret) = address(fixedSale).call(_openSaleData(editionId));
        _bubble(ok, ret);
        saleId = abi.decode(ret, (uint256));
    }

    /// @dev The edition's first copy, to a new holder: the mint path's one-time records.
    function _rowPurchaseFirst() internal returns (Row memory r) {
        uint256 saleId = _openEditionSale();
        address buyer = makeAddr("firstCopyBuyer");
        r = _row(
            "purchase, first copy (new holder)",
            buyer,
            address(fixedSale),
            _purchaseData(saleId, buyer, 1),
            EDITION_PRICE
        );
        _capGrowth(r, 3, 0);
    }

    function _rowPurchaseLater() internal returns (Row memory r) {
        uint256 saleId = _openEditionSale();
        address first = makeAddr("firstCopyBuyer");
        vm.deal(first, EDITION_PRICE);
        vm.prank(first);
        (bool ok, bytes memory ret) =
            address(fixedSale).call{ value: EDITION_PRICE }(_purchaseData(saleId, first, 1));
        _bubble(ok, ret);
        address buyer = makeAddr("laterCopyBuyer");
        r = _row(
            "purchase, a later copy (new holder)",
            buyer,
            address(fixedSale),
            _purchaseData(saleId, buyer, 1),
            EDITION_PRICE
        );
        _capGrowth(r, 2, 0);
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
    ///      artist pays for (ADR 0003). Tracked, not gas-gated.
    function _rowRefreshFirst() internal returns (Row memory r) {
        _consolidate(artistA, makeAddr("gasWallet1"));
        r = _row(
            "refreshStanding, records a first wallet", artistA, address(artists), _refreshData(), 0
        );
        _capGrowth(r, 2, 0);
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
        _capGrowth(r, 1, 0);
    }

    // ------------------------------------------------------------------ views

    /// @dev `royaltyInfo` derives the receiver through the split factory (ADR 0003): one cold
    ///      external view call. Marketplaces call it with their own gas limits.
    function _rowRoyaltyInfo() internal returns (Row memory r) {
        _steadyState();
        bytes memory data = abi.encodeCall(stream.royaltyInfo, (1, 1 ether));
        r = _row("royaltyInfo (cold)", starter, address(stream), data, 0);
        r.total = 21_000 + r.execution; // a view: the call itself, without its calldata
        assertLt(r.execution, 50_000);
        _capGrowth(r, 0, 0);
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

    function test_Gas_Start_FirstWorkInANewCollection() public {
        _rowStartNewCollection();
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

    function test_Gas_Consume() public {
        _rowConsume();
    }

    function test_Gas_CreateEdition() public {
        _rowCreateEdition();
    }

    function test_Gas_OpenSale() public {
        _rowOpenSale();
    }

    function test_Gas_Purchase_FirstCopy() public {
        _rowPurchaseFirst();
    }

    function test_Gas_Purchase_LaterCopy() public {
        _rowPurchaseLater();
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

    function test_Gas_TokenURIBySize() public {
        _tokenUriMatrix(artistA, starter);
    }

    // ------------------------------------------------------------------ the table

    /// @dev Every row, each from a fresh copy of the set-up state, printed as one table. The
    ///      gates are the rows' own tests: here each row runs twice, for its gas and then for its
    ///      state growth, since no gas can be measured after a recording.
    function test_Gas_Table() public {
        function() internal returns (Row memory)[18] memory rows = [
            _rowStart,
            _rowStartWithBid,
            _rowStartTwoParty,
            _rowStartWithBidTwoParty,
            _rowStartNewCollection,
            _rowStartFirstEver,
            _rowStartWithBidNewTerms,
            _rowBid,
            _rowSettleFirstPayout,
            _rowSettle,
            _rowConsume,
            _rowCreateEdition,
            _rowOpenSale,
            _rowPurchaseFirst,
            _rowPurchaseLater,
            _rowRefreshFirst,
            _rowRefreshFurther,
            _rowRoyaltyInfo
        ];
        Row[18] memory measured;
        for (uint256 i; i < rows.length; ++i) {
            measured[i] = _runRow(rows[i], Pass.GAS);
        }
        console2.log(_line("Operation", "Prague gas", "New slots", "New accounts"));
        console2.log(_line("---", "---:", "---:", "---:"));
        for (uint256 i; i < rows.length; ++i) {
            StateGrowth.Growth memory growth = _runRow(rows[i], Pass.GROWTH).growth;
            console2.log(
                _line(
                    measured[i].label,
                    _thousands(measured[i].total),
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
