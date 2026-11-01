// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice Replays the golden vectors (`test/fixtures/edition-auction/clearing.json`, made by
///         `tools/edition_auction_ref.py`, ADR 0005) through the real adapter and its lens: every
///         case on the default ladder, with its configuration, cap and events (bids, raises and
///         dispute withdrawals). Before the close it checks the live clearing, the step totals,
///         the departure logs, the settlement order, every bid's outcome, and the case's quotes
///         and lowest winning steps; then it settles with the lens's order and claims every bid,
///         checking each claim against the expected outcome, exactly `count` copies, the payout
///         and ETH conservation. Cases 0-2 price the owner's figures off the ladder (`prices`), so
///         only the model and the library's own tests replay them.
contract UniformEditionAuctionVectorsTest is EditionAuctionBase {
    string internal constant PATH = "test/fixtures/edition-auction/clearing.json";

    /// @dev Reads a number, or reports a JSON null (the model's "not applicable").
    function readUint(string memory json, string memory key) external pure returns (uint256) {
        return vm.parseJsonUint(json, key);
    }

    function test_Vectors_OffLadderCasesAreSkipped() public view {
        string memory json = vm.readFile(PATH);
        for (uint256 k; k < 3; ++k) {
            assertTrue(vm.keyExistsJson(json, string.concat(_case(k), ".prices")));
        }
        assertFalse(vm.keyExistsJson(json, string.concat(_case(3), ".prices")));
        assertFalse(vm.keyExistsJson(json, string.concat(_case(17), ".name")), "17 cases");
    }

    function test_Vector_03_Trace2DefaultLadder() public {
        _replay(3);
    }

    function test_Vector_04_Trace2BreadthTilt() public {
        _replay(4);
    }

    function test_Vector_05_Trace2NoTilt() public {
        _replay(5);
    }

    function test_Vector_06_Trace2Margin50() public {
        _replay(6);
    }

    function test_Vector_07_Trace3Cap60FifoHole() public {
        _replay(7);
    }

    function test_Vector_08_ZeroBids() public {
        _replay(8);
    }

    function test_Vector_09_OneBid() public {
        _replay(9);
    }

    function test_Vector_10_OneStepUncapped() public {
        _replay(10);
    }

    function test_Vector_11_OneStepCapped() public {
        _replay(11);
    }

    function test_Vector_12_Cap1() public {
        _replay(12);
    }

    function test_Vector_13_LadderEnds() public {
        _replay(13);
    }

    function test_Vector_14_FifoHoles() public {
        _replay(14);
    }

    function test_Vector_15_DenseBook() public {
        _replay(15);
    }

    function test_Vector_16_DenseBookCapped() public {
        _replay(16);
    }

    // ------------------------------------------------------------------ the replay

    function _replay(uint256 k) internal {
        string memory json = vm.readFile(PATH);
        string memory c = _case(k);
        assertFalse(vm.keyExistsJson(json, string.concat(c, ".prices")), "an off-ladder case");
        _setConfig(_config(json, c));
        uint256 saleId = _open(uint32(vm.parseJsonUint(json, string.concat(c, ".cap"))));
        _events(json, saleId, c);
        string memory e = string.concat(c, ".expected");
        _checkClearing(json, saleId, string.concat(e, ".clearing"), ua.clearing(saleId));
        _checkStepTotals(json, saleId, e);
        _checkDepartures(json, saleId, e);
        assertEq(
            ua.settlementOrder(saleId),
            vm.parseJsonUintArray(json, string.concat(e, ".settlementOrder")),
            "settlement order"
        );
        _checkOutcomes(json, saleId, e);
        if (vm.keyExistsJson(json, string.concat(c, ".quotes"))) _checkQuotes(json, saleId, c);
        if (vm.keyExistsJson(json, string.concat(c, ".lowestWinningStep"))) {
            _checkLowest(json, saleId, c);
        }
        _settleAndClaim(json, saleId, e);
    }

    function _events(string memory json, uint256 saleId, string memory c) internal {
        for (uint256 i;; ++i) {
            string memory ev = string.concat(c, ".events[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, ev)) break;
            bytes32 op = keccak256(bytes(vm.parseJsonString(json, string.concat(ev, ".op"))));
            if (op == keccak256("bid")) {
                _bid(
                    saleId,
                    makeAddr(vm.parseJsonString(json, string.concat(ev, ".bidder"))),
                    vm.parseJsonUint(json, string.concat(ev, ".step")),
                    vm.parseJsonUint(json, string.concat(ev, ".quantity"))
                );
            } else if (op == keccak256("raise")) {
                _raise(
                    saleId,
                    vm.parseJsonUint(json, string.concat(ev, ".bidId")),
                    vm.parseJsonUint(json, string.concat(ev, ".toStep"))
                );
            } else {
                assertEq(op, keccak256("withdraw"), "unknown event");
                _withdrawDuringPause(saleId, vm.parseJsonUint(json, string.concat(ev, ".bidId")));
            }
        }
    }

    function _checkClearing(
        string memory json,
        uint256 saleId,
        string memory p,
        IUniformEditionAuction.Clearing memory got
    ) internal view {
        string memory label = string.concat("clearing ", vm.toString(saleId % 1000));
        uint256 count = vm.parseJsonUint(json, string.concat(p, ".count"));
        assertEq(got.count, count, string.concat(label, ": count"));
        if (count != 0) {
            assertEq(got.step, vm.parseJsonUint(json, string.concat(p, ".step")), "step");
        }
        assertEq(got.price, vm.parseJsonUint(json, string.concat(p, ".price")), "price");
        assertEq(got.revenue, vm.parseJsonUint(json, string.concat(p, ".revenue")), "revenue");
        assertEq(
            got.networkFee, vm.parseJsonUint(json, string.concat(p, ".networkFee")), "network fee"
        );
        assertEq(got.bestRevenue, vm.parseJsonUint(json, string.concat(p, ".bestRevenue")), "R*");
        bool rationed = vm.parseJsonBool(json, string.concat(p, ".rationed"));
        assertEq(got.rationed, rationed, "rationed");
        assertEq(got.cutUnits, vm.parseJsonUint(json, string.concat(p, ".cutUnits")), "cutUnits");
        assertEq(
            got.unitsAtStep, vm.parseJsonUint(json, string.concat(p, ".unitsAtStep")), "at step"
        );
        if (rationed) {
            // The model gives no cutoff for a quote's hypothetical clearing.
            try this.readUint(json, string.concat(p, ".cutoff")) returns (uint256 cutoff) {
                assertEq(got.cutoff, cutoff, "cutoff");
            } catch { }
        } else {
            assertEq(got.cutoff, 0, "no cutoff unless rationed");
        }
    }

    function _checkStepTotals(string memory json, uint256 saleId, string memory e) internal view {
        string memory p = string.concat(e, ".stepTotals");
        string[] memory steps = vm.parseJsonKeys(json, p);
        (uint256 low, uint256[] memory units) = ua.stepTotals(saleId);
        uint256 nonzero;
        for (uint256 i; i < units.length; ++i) {
            if (units[i] != 0) ++nonzero;
        }
        assertEq(nonzero, steps.length, "used steps");
        for (uint256 i; i < steps.length; ++i) {
            uint256 step = vm.parseUint(steps[i]);
            assertEq(
                units[step - low],
                vm.parseJsonUint(json, string.concat(p, "['", steps[i], "']")),
                "step total"
            );
        }
    }

    function _checkDepartures(string memory json, uint256 saleId, string memory e) internal view {
        string memory p = string.concat(e, ".departures");
        string[] memory steps = vm.parseJsonKeys(json, p);
        for (uint256 i; i < steps.length; ++i) {
            IUniformEditionAuction.Departure[] memory got =
                ua.departures(saleId, vm.parseUint(steps[i]));
            for (uint256 j;; ++j) {
                string memory entry = string.concat(p, "['", steps[i], "'][", vm.toString(j), "]");
                if (!vm.keyExistsJson(json, entry)) {
                    assertEq(got.length, j, "departure count");
                    break;
                }
                uint256[] memory pair = vm.parseJsonUintArray(json, entry);
                assertEq(got[j].position, pair[0], "departure position");
                assertEq(got[j].quantity, pair[1], "departure quantity");
            }
        }
    }

    function _checkOutcomes(string memory json, uint256 saleId, string memory e) internal {
        for (uint256 i;; ++i) {
            string memory b = string.concat(e, ".bids[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, b)) break;
            uint256 bidId = vm.parseJsonUint(json, string.concat(b, ".bidId"));
            if (!vm.parseJsonBool(json, string.concat(b, ".active"))) {
                assertFalse(_live(saleId, bidId), "inactive bid");
                continue;
            }
            IUniformEditionAuction.Bid memory got = ua.bidOf(saleId, bidId);
            assertEq(got.bidder, makeAddr(vm.parseJsonString(json, string.concat(b, ".bidder"))));
            assertEq(got.step, vm.parseJsonUint(json, string.concat(b, ".step")), "bid step");
            assertEq(got.quantity, vm.parseJsonUint(json, string.concat(b, ".quantity")), "qty");
            assertEq(
                got.position, vm.parseJsonUint(json, string.concat(b, ".position")), "position"
            );
            IUniformEditionAuction.BidOutcome memory o = ua.bidOutcome(saleId, bidId);
            assertEq(o.escrow, vm.parseJsonUint(json, string.concat(b, ".escrow")), "escrow");
            assertEq(o.unitsWon, vm.parseJsonUint(json, string.concat(b, ".unitsWon")), "won");
            assertEq(o.refund, vm.parseJsonUint(json, string.concat(b, ".refund")), "refund");
            assertEq(o.unitsAhead, vm.parseJsonUint(json, string.concat(b, ".unitsAhead")), "ahead");
            assertFalse(o.isFinal);
        }
    }

    function _checkQuotes(string memory json, uint256 saleId, string memory c) internal view {
        for (uint256 i;; ++i) {
            string memory q = string.concat(c, ".quotes[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, q)) break;
            IUniformEditionAuction.Quote memory got = ua.quote(
                saleId,
                vm.parseJsonUint(json, string.concat(q, ".step")),
                vm.parseJsonUint(json, string.concat(q, ".quantity"))
            );
            assertEq(got.unitsWon, vm.parseJsonUint(json, string.concat(q, ".unitsWon")), "q won");
            assertEq(got.escrow, vm.parseJsonUint(json, string.concat(q, ".escrow")), "q escrow");
            assertEq(
                got.unitsPushedOut,
                vm.parseJsonUint(json, string.concat(q, ".unitsPushedOut")),
                "q pushed out"
            );
            assertEq(
                got.unitsPulledIn,
                vm.parseJsonUint(json, string.concat(q, ".unitsPulledIn")),
                "q pulled in"
            );
            _checkClearing(json, saleId, string.concat(q, ".result"), got.result);
        }
    }

    function _checkLowest(string memory json, uint256 saleId, string memory c) internal view {
        for (uint256 i;; ++i) {
            string memory l = string.concat(c, ".lowestWinningStep[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, l)) break;
            (bool found, uint256 step) =
                ua.lowestWinningStep(saleId, vm.parseJsonUint(json, string.concat(l, ".quantity")));
            assertTrue(found, "a winning step exists");
            assertEq(step, vm.parseJsonUint(json, string.concat(l, ".step")), "lowest step");
        }
    }

    /// @dev Settles with the lens's order, then claims every live bid, each against its expected
    ///      outcome.
    function _settleAndClaim(string memory json, uint256 saleId, string memory e) internal {
        IUniformEditionAuction.Clearing memory live = ua.clearing(saleId);
        _settle(saleId);
        IUniformEditionAuction.Settlement memory s = ua.settlement(saleId);
        assertEq(s.count, live.count, "settled count = live count");
        assertEq(s.step, live.step, "settled step");
        assertEq(s.price, live.price, "settled price");
        if (live.rationed) assertEq(s.cutoff, live.cutoff, "settled cutoff = live cutoff");
        assertEq(s.departuresSwept, s.departures, "sweep complete");
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
        );
        assertEq(paidOut, live.revenue, "revenue paid at settlement");
        assertEq(networkFee.balance, live.networkFee, "network fee");
        assertEq(seller.balance, live.revenue - live.networkFee, "seller proceeds");
        uint256 minted = _claimExpected(json, saleId, e);
        assertEq(minted, live.count, "exactly k copies");
        assertEq(editions.minted(ID), live.count, "exactly k minted");
        _assertConserved();
        assertEq(address(auction).balance, 0, "nothing left");
    }

    /// @dev Claims every active bid of case `e`, each checked against its expected outcome.
    function _claimExpected(string memory json, uint256 saleId, string memory e)
        internal
        returns (uint256 minted)
    {
        for (uint256 i;; ++i) {
            string memory b = string.concat(e, ".bids[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, b)) break;
            if (!vm.parseJsonBool(json, string.concat(b, ".active"))) continue;
            uint256 bidId = vm.parseJsonUint(json, string.concat(b, ".bidId"));
            IUniformEditionAuction.BidOutcome memory o = ua.bidOutcome(saleId, bidId);
            assertTrue(o.isFinal);
            address bidder = ua.bidOf(saleId, bidId).bidder;
            vm.prank(bidder);
            (uint256 won, uint256 refund) = auction.claimBid(saleId, bidId, bidder);
            assertEq(won, vm.parseJsonUint(json, string.concat(b, ".unitsWon")), "claim won");
            assertEq(refund, vm.parseJsonUint(json, string.concat(b, ".refund")), "claim refund");
            assertEq(won, o.unitsWon, "outcome = claim");
            minted += won;
            refundsOut += refund;
        }
    }

    function _config(string memory json, string memory c)
        internal
        view
        returns (IUniformEditionAuction.AuctionConfig memory t)
    {
        string memory p = string.concat(c, ".config");
        t.basePrice = uint96(vm.parseJsonUint(json, string.concat(p, ".basePrice")));
        t.stepsPerDecade = uint16(vm.parseJsonUint(json, string.concat(p, ".stepsPerDecade")));
        t.stepCount = uint16(vm.parseJsonUint(json, string.concat(p, ".stepCount")));
        t.marginShare = uint32(vm.parseJsonUint(json, string.concat(p, ".marginShare")));
        t.closeOffset = uint32(vm.parseJsonUint(json, string.concat(p, ".closeOffset")));
        t.softWindow = uint32(vm.parseJsonUint(json, string.concat(p, ".softWindow")));
        t.maxExtension = uint32(vm.parseJsonUint(json, string.concat(p, ".maxExtension")));
    }

    function _case(uint256 k) internal pure returns (string memory) {
        return string.concat(".cases[", vm.toString(k), "]");
    }
}
