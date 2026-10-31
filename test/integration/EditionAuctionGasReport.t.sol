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
    /// @dev Regression ceilings (ADR 0004).
    uint256 internal constant OPEN_CEILING = 161_000;
    uint256 internal constant OPEN_FIRST_CEILING = 208_000;
    uint256 internal constant RAISE_CEILING = 56_000;
    uint256 internal constant RAISE_CAPPED_CEILING = 81_000;
    uint256 internal constant CLAIM_LOSER_CEILING = 49_000;
    uint256 internal constant CLAIM_FOR_CEILING = 67_000;
    uint256 internal constant WITHDRAW_CEILING = 97_000;
    uint256 internal constant SWEEP_SETTLE_CEILING = 159_000;

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
            4,
            0
        );
    }

    function test_Gas_EditionAuction_Open() public {
        (bytes32 r, Work memory w) = _masterPackage(0);
        (, uint256 id) = _start(r, _one(w), 0);
        bytes memory data =
            abi.encodeCall(editionAuction.open, (address(editions), id, abi.encode(w.item)));
        _rowGate("open, steady state", keeper, address(editionAuction), data, 0, OPEN_CEILING, 2, 0);
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

    function test_Gas_EditionAuction_SettleDense() public {
        _openMaster(0);
        for (uint256 step; step < 336; ++step) {
            _editionBid(saleId, makeAddr(string.concat("d", vm.toString(step))), step, 1 + step % 7);
        }
        _readyToSettle();
        bytes memory data = abi.encodeCall(editionAuction.settle, (saleId, new uint256[](0)));
        _rowGate(
            "settle, all 336 steps used (adversarial)",
            keeper,
            address(editionAuction),
            data,
            0,
            SETTLE_DENSE_BUDGET,
            1,
            0
        );
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

