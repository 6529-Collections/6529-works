// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { StateGrowth } from "../helpers/StateGrowth.sol";
import { EditionAuctionStack } from "./EditionAuctionStack.sol";

/// @notice The edition auction's gas report on the real, wired stack (ADR 0004; ADR 0005 section
///         5). Each `test_Gas_EditionAuction_*` measures one transaction from a steady state and
///         gates it: whole-transaction Prague gas (21,000, calldata and execution, with the
///         cold-account surcharge `_measureGrowth` adds) against its budget or regression ceiling,
///         and the exact number of new storage slots and new accounts it creates.
///         `forge test --match-contract EditionAuctionGasReport -vv` prints every row.
/// @dev Steady state: the network fee recipient exists and is interned, the master's seller
///      wallet exists (its 1/1 sold), and the edition exists. Budgets (ADR 0005 section 5): a bid
///      at most 110,000 and 2 new slots; a winner's claim as a new holder at most 100,000 and 1;
///      a settlement of at most 40 used steps 400,000 and 1; every step used, 1,000,000 and 1.
///      The other rows carry regression ceilings: the figure when set, plus about 2%, rounded up
///      to the thousand.
contract EditionAuctionGasReport is EditionAuctionStack {
    uint256 internal constant BID_BUDGET = 110_000;
    uint256 internal constant CLAIM_BUDGET = 100_000;
    uint256 internal constant SETTLE_BUDGET = 400_000;
    uint256 internal constant SETTLE_DENSE_BUDGET = 1_000_000;
    /// @dev The settlement's worst case, held to 350,000 execution gas (ADR 0004).
    uint256 internal constant SETTLE_EXECUTION_BUDGET = 350_000;
    /// @dev Regression ceilings (ADR 0004).
    uint256 internal constant OPEN_CEILING = 275_000;
    uint256 internal constant OPEN_FIRST_CEILING = 322_000;
    /// @dev Moved from 144,000 by owner decision 16: 6529 Stream Editions reads the package
    ///      registry from Stream (two reads) instead of an immutable.
    uint256 internal constant CREATE_BOUND_CEILING = 148_000;
    uint256 internal constant RAISE_CEILING = 56_000;
    uint256 internal constant RAISE_CAPPED_CEILING = 81_000;
    uint256 internal constant CLAIM_LOSER_CEILING = 49_000;
    uint256 internal constant CLAIM_FOR_CEILING = 67_000;
    uint256 internal constant WITHDRAW_CEILING = 90_000;
    uint256 internal constant SWEEP_SETTLE_CEILING = 153_000;

    address internal artist;
    address internal keeper = makeAddr("keeper");
    address internal collector = makeAddr("gasCollector");
    address[] internal probes;

    uint256 internal oneSaleId;
    uint256 internal tokenId;
    uint256 internal saleId;

    function setUp() public override {
        super.setUp();
        artist = _actor("gasMasterArtist");
        // Steady state: a first master opened (the fee recipient interned) and its 1/1 sold.
        (,, uint256 firstSale,,) = _startMaster(artist, 0);
        _ethBid(firstSale, collector, 1 ether);
        _settleAtEnd(firstSale);
    }

    // ------------------------------------------------------------------ rows

    function test_Gas_EditionAuction_OpenFirst() public {
        // A fresh adapter: the first open interns the fee recipient.
        _setUpFreshAdapter();
        (bytes32 r, Work memory w) = _masterPackage(0);
        (, uint256 id) = _start(r, _one(w), 0);
        bytes memory data =
            abi.encodeCall(editionAuction.open, (address(editions), id, abi.encode(w.item)));
        _rowGate(
            "open, first (fee recipient interned)",
            keeper,
            address(editionAuction),
            data,
            0,
            OPEN_FIRST_CEILING,
            8,
            0
        );
    }

    function test_Gas_EditionAuction_Open() public {
        (bytes32 r, Work memory w) = _masterPackage(0);
        (, uint256 id) = _start(r, _one(w), 0);
        bytes memory data =
            abi.encodeCall(editionAuction.open, (address(editions), id, abi.encode(w.item)));
        _rowGate("open, steady state", keeper, address(editionAuction), data, 0, OPEN_CEILING, 6, 0);
    }

    /// @dev `createEdition` of an edition its sale bound at open (`bindMinter`): the seller,
    ///      royalty and fee words were written then, so creation writes the rest. Compare the
    ///      unbound `createEdition` row of `GasReport` (6 new slots).
    function test_Gas_EditionAuction_CreateBoundEdition() public {
        _openMaster(0);
        _ethBid(oneSaleId, collector, 1 ether);
        Work memory w = _package(keccak256(abi.encode("kept", saleId)))[0];
        bytes32 r = _rootOf(_one(w));
        _settleAtEnd(oneSaleId);
        bytes memory data =
            abi.encodeCall(editions.createEdition, (tokenId, w.item, r, _proofOf(_one(w), 0)));
        _rowGate(
            "createEdition, bound at open",
            keeper,
            address(editions),
            data,
            0,
            CREATE_BOUND_CEILING,
            2,
            0
        );
    }

    function test_Gas_EditionAuction_BidNewWord() public {
        _openMaster(0);
        _editionBid(saleId, makeAddr("earlier"), 130, 5);
        address b = makeAddr("gasBidder");
        _rowGate(
            "bid, opens an 8-step word",
            b,
            address(editionAuction),
            _bidData(100, 1),
            _value(100, 1),
            BID_BUDGET,
            2,
            0
        );
    }

    function test_Gas_EditionAuction_Bid() public {
        _openMaster(0);
        _editionBid(saleId, makeAddr("earlier"), 130, 5);
        address b = makeAddr("gasBidder");
        _rowGate(
            "bid, its 8-step word exists",
            b,
            address(editionAuction),
            _bidData(131, 3),
            _value(131, 3),
            BID_BUDGET,
            1,
            0
        );
    }

    function test_Gas_EditionAuction_BidCapped() public {
        _openMaster(60);
        _editionBid(saleId, makeAddr("earlier"), 130, 5);
        address b = makeAddr("gasBidder");
        _rowGate(
            "bid, capped sale (queue position)",
            b,
            address(editionAuction),
            _bidData(130, 2),
            _value(130, 2),
            BID_BUDGET,
            1,
            0
        );
    }

    function test_Gas_EditionAuction_BidNearTheClose() public {
        _openMaster(0);
        _editionBid(saleId, makeAddr("earlier"), 130, 5);
        // In the soft-close window: the 1/1 is read live and the close extends.
        vm.warp(ea.endTimes(saleId).endTime - 1 minutes);
        address b = makeAddr("gasBidder");
        _rowGate(
            "bid, near the close (1/1 read, soft close)",
            b,
            address(editionAuction),
            _bidData(131, 1),
            _value(131, 1),
            BID_BUDGET,
            1,
            0
        );
    }

    function test_Gas_EditionAuction_Raise() public {
        _openMaster(0);
        address b = makeAddr("gasBidder");
        uint256 bidId = _editionBid(saleId, b, 130, 5);
        uint256 value = 5 * (ea.stepPrice(saleId, 132) - ea.stepPrice(saleId, 130));
        bytes memory data = abi.encodeCall(editionAuction.raise, (saleId, bidId, 132));
        _rowGate(
            "raise, same 8-step word", b, address(editionAuction), data, value, RAISE_CEILING, 0, 0
        );
    }

    function test_Gas_EditionAuction_RaiseCapped() public {
        _openMaster(60);
        address b = makeAddr("gasBidder");
        uint256 bidId = _editionBid(saleId, b, 130, 5);
        uint256 value = 5 * (ea.stepPrice(saleId, 132) - ea.stepPrice(saleId, 130));
        bytes memory data = abi.encodeCall(editionAuction.raise, (saleId, bidId, 132));
        _rowGate(
            "raise, capped (departure logged)",
            b,
            address(editionAuction),
            data,
            value,
            RAISE_CAPPED_CEILING,
            1,
            0
        );
    }

    function test_Gas_EditionAuction_WithdrawDuringDispute() public {
        _openMaster(60);
        address b = makeAddr("gasBidder");
        uint256 bidId = _editionBid(saleId, b, 130, 5);
        vm.prank(guardian1);
        auction.pause(oneSaleId, keccak256("dispute"));
        bytes memory data = abi.encodeCall(editionAuction.withdrawBid, (saleId, bidId, b));
        _rowGate(
            "withdrawBid, capped, 1/1 paused",
            b,
            address(editionAuction),
            data,
            0,
            WITHDRAW_CEILING,
            1,
            0
        );
    }

    function test_Gas_EditionAuction_SettleSparse() public {
        _openMaster(0);
        _traceTwo();
        _readyToSettle();
        bytes memory data = abi.encodeCall(editionAuction.settle, (saleId, new uint256[](0)));
        _rowGate(
            "settle, 5 used steps (trace 2)",
            keeper,
            address(editionAuction),
            data,
            0,
            SETTLE_BUDGET,
            1,
            0
        );
    }

    function test_Gas_EditionAuction_Settle40Steps() public {
        _openMaster(0);
        for (uint256 i; i < 40; ++i) {
            _editionBid(
                saleId, makeAddr(string.concat("s", vm.toString(i))), 100 + i * 5, 1 + i % 3
            );
        }
        _readyToSettle();
        bytes memory data = abi.encodeCall(editionAuction.settle, (saleId, new uint256[](0)));
        _rowGate(
            "settle, 40 used steps", keeper, address(editionAuction), data, 0, SETTLE_BUDGET, 1, 0
        );
    }

    /// @dev Every one of the 336 steps used, no cap: two calls (24 words, then 18 and the
    ///      clearing).
    function test_Gas_EditionAuction_SettleDense() public {
        _openMaster(0);
        for (uint256 step; step < 336; ++step) {
            _editionBid(saleId, makeAddr(string.concat("d", vm.toString(step))), step, 1 + step % 7);
        }
        _readyToSettle();
        _settleCalls("settle, all 336 steps used, call", _slots(1, 1), 0);
    }

    function test_Gas_EditionAuction_SettleWithSweep() public {
        _openMaster(60);
        _traceThree();
        _readyToSettle();
        uint256[] memory order = ea.settlementOrder(saleId);
        assertEq(order.length, 1);
        bytes memory data = abi.encodeCall(editionAuction.settle, (saleId, order));
        _rowGate(
            "settle, capped, sweep of 1 departure (trace 3)",
            keeper,
            address(editionAuction),
            data,
            0,
            SWEEP_SETTLE_CEILING,
            1,
            0
        );
    }

    function test_Gas_EditionAuction_ClaimWinnerFirstMint() public {
        _settledTraceTwo();
        address b = makeAddr("b2");
        bytes memory data = abi.encodeCall(editionAuction.claimBid, (saleId, 2, b));
        _rowGate(
            "claimBid, winner, the edition's first mint",
            b,
            address(editionAuction),
            data,
            0,
            CLAIM_BUDGET,
            1,
            0
        );
    }

    function test_Gas_EditionAuction_ClaimWinner() public {
        _settledTraceTwo();
        vm.prank(makeAddr("b1"));
        editionAuction.claimBid(saleId, 1, makeAddr("b1"));
        address b = makeAddr("b2");
        bytes memory data = abi.encodeCall(editionAuction.claimBid, (saleId, 2, b));
        _rowGate(
            "claimBid, winner and new holder, with refund",
            b,
            address(editionAuction),
            data,
            0,
            CLAIM_BUDGET,
            1,
            0
        );
    }

    function test_Gas_EditionAuction_ClaimLoser() public {
        _settledTraceTwo();
        address b = makeAddr("b5");
        bytes memory data = abi.encodeCall(editionAuction.claimBid, (saleId, 5, b));
        _rowGate(
            "claimBid, refund only", b, address(editionAuction), data, 0, CLAIM_LOSER_CEILING, 0, 0
        );
    }

    function test_Gas_EditionAuction_ClaimForLoser() public {
        _settledTraceTwo();
        bytes memory data = abi.encodeCall(editionAuction.claimBidFor, (saleId, 5));
        _rowGate(
            "claimBidFor, refund credited",
            keeper,
            address(editionAuction),
            data,
            0,
            CLAIM_FOR_CEILING,
            1,
            0
        );
    }

    // ------------------------------------------------------------------ worst cases

    /// @dev The settlement's worst case on the default ladder: every one of the 336 steps
    ///      occupied, the cap binding at the lowest step (so the scan reads every word and never
    ///      stops early), and 40 departures at that step, so the call that clears also sweeps
    ///      its longest legal chunk (16). Every call is gated on execution gas: at most 350,000.
    function test_Gas_EditionAuction_SettleWorstCase() public {
        _worstBook(336, 200_000_000, 40);
        // 42 words: the first call scans 24 (the scan word is new), the second scans 18,
        // clears (the result word is new; the scan word is deleted) and sweeps 16 (the keeper's
        // sweep progress is new); the third sweeps the remaining 24 and deletes it.
        _settleCalls("settle, worst case 336 steps, call", _slots(1, 2), 0);
    }

    /// @dev The same at the governed maximum of 512 steps (192 per decade from 0.1 ETH, the
    ///      highest power-of-ten base, so the top step is at least 10 ETH): 64 words, three
    ///      scanning calls.
    function test_Gas_EditionAuction_SettleWorstCase512() public {
        IUniformEditionAuction.AuctionConfig memory c = _editionConfig();
        (c.basePrice, c.stepsPerDecade, c.stepCount) = (1e17, 192, 512);
        _govern(
            hotAdmin,
            address(editionAuction),
            abi.encodeCall(editionAuction.setConfig, (_editionConfig(), c))
        );
        _worstBook(512, 100_000, 40);
        // 64 words: 24 (the scan word is new), 24, then 16 and the clearing (the result word
        // and the keeper's sweep progress).
        uint256[] memory slots = new uint256[](3);
        (slots[0], slots[1], slots[2]) = (1, 0, 2);
        _settleCalls("settle, worst case 512 steps, call", slots, 0);
    }

    /// @dev The longest legal sweep chunk: 300 departures at the cut step, so after the two
    ///      scanning calls (which sweep 16) the sweep calls take 96, 96, 92.
    function test_Gas_EditionAuction_SweepChunkWorstCase() public {
        _worstBook(336, 200_000_000, 300);
        assertEq(ea.settlementOrder(saleId).length, 300);
        _settleCalls("settle, 300 departures, call", _slots(1, 2), 0);
    }

    /// @dev The new slots each settle call creates, by call: the given first ones, then none.
    function _slots(uint256 first, uint256 second) internal pure returns (uint256[] memory s) {
        s = new uint256[](2);
        (s[0], s[1]) = (first, second);
    }

    /// @dev Settles `saleId` call by call, each with the lens's order, holding each call to
    ///      350,000 execution gas and its exact new slots (`slots[i]`, then none) and accounts.
    ///      Two passes from one snapshot, since nothing can be measured after a state-diff
    ///      recording: every call's gas first, then every call's growth, which also gives the
    ///      accounts each call reached cold (`_measureGrowth`'s surcharge).
    function _settleCalls(string memory label, uint256[] memory slots, uint256 accounts) internal {
        uint256 snapshot = vm.snapshotState();
        uint256[] memory execution = new uint256[](16);
        Warmth[] memory warmth = new Warmth[](16);
        uint256 calls;
        for (; calls < 16; ++calls) {
            warmth[calls] = _warmth();
            (, execution[calls]) = _measure(keeper, address(editionAuction), _settleData(), 0);
            if (_settled()) break;
        }
        require(calls < 16, "settlement does not advance");
        vm.revertToState(snapshot);
        for (uint256 i; i <= calls; ++i) {
            StateGrowth.Growth memory growth =
                _growth(keeper, address(editionAuction), _settleData(), 0);
            uint256 gas = execution[i] + COLD_ACCOUNT_SURCHARGE
                * _warmButCold(warmth[i], growth.coldAccounts);
            string memory row = string.concat(label, " ", vm.toString(i + 1));
            console2.log(row);
            console2.log("  execution gas", gas);
            console2.log("  new slots", growth.slots);
            console2.log("  new accounts", growth.accounts);
            assertLe(gas, SETTLE_EXECUTION_BUDGET, string.concat(row, ": execution gas"));
            assertEq(growth.slots, i < slots.length ? slots[i] : 0, string.concat(row, ": slots"));
            assertEq(growth.accounts, accounts, string.concat(row, ": accounts"));
        }
        assertTrue(_settled());
        assertEq(_claimTotal(), ea.settlement(saleId).count, "exactly k minted");
    }

    function _settleData() internal view returns (bytes memory) {
        return abi.encodeCall(editionAuction.settle, (saleId, _orderFor(saleId, keeper)));
    }

    function _settled() internal view returns (bool) {
        return ea.auction(saleId).status == IUniformEditionAuction.AuctionStatus.SETTLED;
    }

    /// @dev Claims every live bid of `saleId` for its bidder; returns the copies minted.
    function _claimTotal() internal returns (uint256 minted) {
        uint256 bids = ea.auction(saleId).bidCount;
        for (uint256 bidId = 1; bidId <= bids; ++bidId) {
            (uint256 won,) = editionAuction.claimBidFor(saleId, bidId);
            minted += won;
        }
    }

    /// @dev A master whose sale has one unit on every step from 1 to `steps - 1`, `base` units
    ///      at step 0 that make it the clearing step, and `departed` one-unit bids raised out of
    ///      step 0 (its departure log); capped one unit short of the demand at step 0, so step
    ///      0 is rationed. Ready to settle.
    function _worstBook(uint256 steps, uint256 base, uint256 departed) internal {
        _openMaster(uint32(base + steps - 1 + departed - 1));
        for (uint256 i; i < departed; ++i) {
            _editionBid(saleId, makeAddr("leaver"), 0, 1);
        }
        _editionBid(saleId, makeAddr("base"), 0, base);
        for (uint256 step = 1; step < steps; ++step) {
            _editionBid(saleId, makeAddr("ladder"), step, 1);
        }
        uint256 topUp = ea.stepPrice(saleId, 1) - ea.stepPrice(saleId, 0);
        for (uint256 i; i < departed; ++i) {
            vm.deal(makeAddr("leaver"), topUp);
            vm.prank(makeAddr("leaver"));
            editionAuction.raise{ value: topUp }(saleId, i + 1, 1);
        }
        IUniformEditionAuction.Clearing memory c = ea.clearing(saleId);
        assertEq(c.step, 0, "step 0 clears");
        assertTrue(c.rationed, "rationed at step 0");
        _readyToSettle();
    }

    /// @dev `_rowGate` on execution gas (the called frame's, with the cold-account surcharge),
    ///      which the settlement worst case is held to.
    function _rowExecution(
        string memory label,
        address from,
        address target,
        bytes memory data,
        uint256 budget,
        uint256 slots,
        uint256 accounts
    ) internal {
        (uint256 total, uint256 execution, StateGrowth.Growth memory growth) =
            _measureGrowth(from, target, data, 0);
        console2.log(label);
        console2.log("  execution gas", execution);
        console2.log("  Prague gas (whole transaction)", total);
        console2.log("  new slots", growth.slots);
        console2.log("  new accounts", growth.accounts);
        assertLe(execution, budget, string.concat(label, ": execution gas over its budget"));
        assertEq(growth.slots, slots, string.concat(label, ": new storage slots (ADR 0004)"));
        assertEq(growth.accounts, accounts, string.concat(label, ": new accounts (ADR 0004)"));
    }

    // ------------------------------------------------------------------ fixtures

    function _masterPackage(uint32 maxCount) internal returns (bytes32 r, Work memory w) {
        w = _masterWork(artist, maxCount);
        r = _publish(_one(w));
    }

    /// @dev Starts a master and opens its edition sale, keeping its work for `createEdition`.
    function _openMaster(uint32 maxCount) internal {
        Work memory w;
        (, w, oneSaleId, tokenId, saleId) = _startMaster(artist, maxCount);
        _keep(keccak256(abi.encode("kept", saleId)), _one(w));
    }

    function _traceTwo() internal {
        uint16[5] memory steps = [uint16(192), 158, 144, 130, 96];
        uint32[5] memory quantities = [uint32(1), 9, 20, 50, 200];
        for (uint256 i; i < 5; ++i) {
            _editionBid(
                saleId, makeAddr(string.concat("b", vm.toString(i + 1))), steps[i], quantities[i]
            );
        }
    }

    function _traceThree() internal {
        _editionBid(saleId, makeAddr("A"), 192, 1);
        _editionBid(saleId, makeAddr("B"), 158, 9);
        _editionBid(saleId, makeAddr("C"), 144, 5);
        _editionBid(saleId, makeAddr("B1"), 130, 20);
        uint256 b2 = _editionBid(saleId, makeAddr("B2"), 130, 15);
        _editionBid(saleId, makeAddr("B3"), 130, 10);
        _editionBid(saleId, makeAddr("B4"), 130, 20);
        uint256 topUp = 15 * (ea.stepPrice(saleId, 144) - ea.stepPrice(saleId, 130));
        vm.deal(makeAddr("B2"), topUp);
        vm.prank(makeAddr("B2"));
        editionAuction.raise{ value: topUp }(saleId, b2, 144);
    }

    /// @dev The 1/1 sold and settled, the edition created, the edition close reached.
    function _readyToSettle() internal {
        _ethBid(oneSaleId, collector, 1 ether);
        Work memory w = _package(keccak256(abi.encode("kept", saleId)))[0];
        bytes32 r = _rootOf(_one(w));
        _settleAtEnd(oneSaleId);
        editions.createEdition(tokenId, w.item, r, _proofOf(_one(w), 0));
        IUniformEditionAuction.EndTimes memory e = ea.endTimes(saleId);
        if (block.timestamp < e.endTime) vm.warp(e.endTime);
        probes.push(_editionSeller(w));
    }

    function _settledTraceTwo() internal {
        _openMaster(0);
        _traceTwo();
        _readyToSettle();
        editionAuction.settle(saleId, new uint256[](0));
    }

    function _setUpFreshAdapter() internal {
        editionAuction = new UniformEditionAuction(
            address(manager), address(escrow), address(editions), address(auction), _editionConfig()
        );
        ea = IUniformEditionAuction(address(editionAuction));
        _govern(
            hotAdmin,
            address(editions),
            abi.encodeCall(editions.setAdmittedMinter, (address(editionAuction), true))
        );
        _govern(
            hotAdmin,
            address(editionAuction),
            abi.encodeCall(editionAuction.setTarget, (address(editions), true))
        );
    }

    function _bidData(uint256 step, uint256 quantity) internal view returns (bytes memory) {
        return abi.encodeCall(editionAuction.bid, (saleId, step, quantity));
    }

    function _value(uint256 step, uint256 quantity) internal view returns (uint256) {
        return quantity * ea.stepPrice(saleId, step);
    }

    // ------------------------------------------------------------------ measuring

    function _probeSet() internal override returns (address[] memory accounts) {
        address[] memory base = super._probeSet();
        address[] memory extra = new address[](24 + probes.length);
        extra[0] = keeper;
        extra[1] = collector;
        extra[2] = makeAddr("gasBidder");
        extra[3] = makeAddr("b1");
        extra[4] = makeAddr("b2");
        extra[5] = makeAddr("b5");
        extra[6] = artist;
        extra[7] = guardian1;
        for (uint256 i; i < probes.length; ++i) {
            extra[8 + i] = probes[i];
        }
        uint256 n = 8 + probes.length;
        accounts = new address[](base.length + n);
        for (uint256 i; i < base.length; ++i) {
            accounts[i] = base[i];
        }
        for (uint256 i; i < n; ++i) {
            accounts[base.length + i] = extra[i];
        }
    }

    function _rowGate(
        string memory label,
        address from,
        address target,
        bytes memory data,
        uint256 value,
        uint256 ceiling,
        uint256 slots,
        uint256 accounts
    ) internal {
        (uint256 total,, StateGrowth.Growth memory growth) =
            _measureGrowth(from, target, data, value);
        console2.log(label);
        console2.log("  Prague gas", total);
        console2.log("  new slots", growth.slots);
        console2.log("  new accounts", growth.accounts);
        for (uint256 i; i < growth.newSlots.length; ++i) {
            console2.log("    slot of", vm.getLabel(growth.newSlots[i].account));
        }
        assertLe(total, ceiling, string.concat(label, ": Prague gas over its budget or ceiling"));
        assertEq(growth.slots, slots, string.concat(label, ": new storage slots (ADR 0004)"));
        assertEq(growth.accounts, accounts, string.concat(label, ": new accounts (ADR 0004)"));
    }
}

