// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionTerms, ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice The edition auction on the real stack against the golden vectors of the reference
///         model (`tools/edition_auction_ref.py`, `test/fixtures/edition-auction/clearing.json`).
///         Each case replays its bids, raises and dispute withdrawals on a fresh sale with the
///         case's cap and margin, then compares the contract's live clearing, step totals,
///         departure log, settlement order and every bid's outcome with the model's. The same
///         vectors check the frontend, so the chain and every client agree on every figure.
/// @dev Cases that price steps off the ladder (`prices`) check the model alone and are skipped
///      here. A case's sale opens on a master whose package cap is the case's (`CAPS`); its
///      margin, when not the launch value, is set by the governed `setConfig` first. Each case
///      runs from the same snapshot.
contract EditionAuctionVectorsTest is IntegrationBase {
    string internal constant VECTORS = "test/fixtures/edition-auction/clearing.json";
    uint32[6] internal CAPS = [uint32(0), 1, 20, 30, 60, 100];

    bytes32 internal root;
    string internal json;
    uint256 internal checked;

    function setUp() public override {
        super.setUp();
        address artist = _actor("vectorArtist");
        Work[] memory works = new Work[](CAPS.length);
        for (uint256 i; i < CAPS.length; ++i) {
            works[i] = _work(artist, collectionId);
            works[i].item.kind = ItemKind.EDITION_MASTER;
            works[i].item.edition =
                EditionTerms(CAPS[i], CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        }
        root = _publish(works);
        _keep(root, works);
        json = vm.readFile(VECTORS);
    }

    /// @notice Every golden case the ladder can express, replayed on the real contracts.
    function test_GoldenVectors_TheContractAgreesWithTheReferenceModel() public {
        uint256 cases;
        for (uint256 i; vm.keyExistsJson(json, _case(i, "")); ++i) {
            ++cases;
            if (vm.keyExistsJson(json, _case(i, ".prices"))) continue;
            uint256 snapshot = vm.snapshotState();
            _replay(i);
            vm.revertToState(snapshot);
            ++checked;
        }
        assertGt(cases, 10, "the vectors were read");
        assertGt(checked, 10, "most cases run on the ladder");
    }

    // ------------------------------------------------------------------ replay

    function _replay(uint256 i) internal {
        string memory name = vm.parseJsonString(json, _case(i, ".name"));
        uint256 sale = _openSale(i);
        bool paused;
        for (uint256 j; vm.keyExistsJson(json, _event(i, j, "")); ++j) {
            string memory op = vm.parseJsonString(json, _event(i, j, ".op"));
            if (_eq(op, "bid")) {
                address bidder = makeAddr(vm.parseJsonString(json, _event(i, j, ".bidder")));
                uint256 step = vm.parseJsonUint(json, _event(i, j, ".step"));
                uint256 quantity = vm.parseJsonUint(json, _event(i, j, ".quantity"));
                uint256 cost = quantity * editionAuction.stepPrice(sale, step);
                vm.deal(bidder, cost);
                vm.prank(bidder);
                editionAuction.bid{ value: cost }(sale, step, quantity);
            } else if (_eq(op, "raise")) {
                uint256 bidId = vm.parseJsonUint(json, _event(i, j, ".bidId"));
                uint256 toStep = vm.parseJsonUint(json, _event(i, j, ".toStep"));
                IUniformEditionAuction.Bid memory b = editionAuction.bidOf(sale, bidId);
                uint256 cost = uint256(b.quantity)
                    * (editionAuction.stepPrice(sale, toStep) - editionAuction.stepPrice(sale, b.step));
                vm.deal(b.bidder, cost);
                vm.prank(b.bidder);
                editionAuction.raise{ value: cost }(sale, bidId, toStep);
            } else {
                assertTrue(_eq(op, "withdraw"), string.concat(name, ": unknown op"));
                if (!paused) {
                    // Withdrawals open only while the 1/1 is paused for a dispute.
                    vm.prank(guardian1);
                    auction.pause(
                        auction.saleIdOf(address(stream), editionAuction.auction(sale).id),
                        keccak256(bytes(name))
                    );
                    paused = true;
                }
                uint256 bidId = vm.parseJsonUint(json, _event(i, j, ".bidId"));
                address bidder = editionAuction.bidOf(sale, bidId).bidder;
                vm.prank(bidder);
                editionAuction.withdrawBid(sale, bidId, bidder);
            }
        }
        _checkClearing(i, sale, name);
        _checkBook(i, sale, name);
        _checkBids(i, sale, name);
    }

    /// @dev Starts the master whose cap is the case's, sets a non-launch margin, opens the sale.
    function _openSale(uint256 i) internal returns (uint256 sale) {
        uint256 cap = vm.parseJsonUint(json, _case(i, ".cap"));
        uint256 index = type(uint256).max;
        for (uint256 k; k < CAPS.length; ++k) {
            if (CAPS[k] == cap) index = k;
        }
        require(index != type(uint256).max, "no master with the case's cap");
        IUniformEditionAuction.AuctionConfig memory current = editionAuction.config();
        IUniformEditionAuction.AuctionConfig memory next = current;
        next.marginShare = uint32(vm.parseJsonUint(json, _case(i, ".config.marginShare")));
        assertEq(
            uint256(next.basePrice), vm.parseJsonUint(json, _case(i, ".config.basePrice")), "base"
        );
        assertEq(next.stepsPerDecade, vm.parseJsonUint(json, _case(i, ".config.stepsPerDecade")));
        assertEq(next.stepCount, vm.parseJsonUint(json, _case(i, ".config.stepCount")));
        if (next.marginShare != current.marginShare) {
            _govern(
                hotAdmin,
                address(editionAuction),
                abi.encodeCall(editionAuction.setConfig, (current, next))
            );
        }
        (, uint256 workId) = _start(root, _package(root), index);
        sale = editionAuction.open(address(editions), workId, abi.encode(_package(root)[index].item));
    }

    // ------------------------------------------------------------------ checks

    function _checkClearing(uint256 i, uint256 sale, string memory name) internal view {
        IUniformEditionAuction.Clearing memory c = editionAuction.clearing(sale);
        string memory at = string.concat(name, ": ");
        assertEq(c.count, _uint(i, ".expected.clearing.count"), string.concat(at, "count"));
        if (c.count == 0) return;
        assertEq(c.step, _uint(i, ".expected.clearing.step"), string.concat(at, "step"));
        assertEq(c.price, _uint(i, ".expected.clearing.price"), string.concat(at, "price"));
        assertEq(c.revenue, _uint(i, ".expected.clearing.revenue"), string.concat(at, "revenue"));
        assertEq(c.networkFee, _uint(i, ".expected.clearing.networkFee"), string.concat(at, "fee"));
        assertEq(c.bestRevenue, _uint(i, ".expected.clearing.bestRevenue"), string.concat(at, "R*"));
        bool rationed = vm.parseJsonBool(json, _case(i, ".expected.clearing.rationed"));
        assertEq(c.rationed, rationed, string.concat(at, "rationed"));
        assertEq(c.cutUnits, _uint(i, ".expected.clearing.cutUnits"), string.concat(at, "cut units"));
        assertEq(
            c.unitsAtStep, _uint(i, ".expected.clearing.unitsAtStep"), string.concat(at, "units at step")
        );
        if (rationed) {
            assertEq(c.cutoff, _uint(i, ".expected.clearing.cutoff"), string.concat(at, "cutoff"));
        }
    }

    /// @dev Step totals, each step's departure log, and the settlement order.
    function _checkBook(uint256 i, uint256 sale, string memory name) internal view {
        string memory at = string.concat(name, ": ");
        (uint256 low, uint256[] memory units) = editionAuction.stepTotals(sale);
        string[] memory steps = vm.parseJsonKeys(json, _case(i, ".expected.stepTotals"));
        uint256 live;
        for (uint256 k; k < units.length; ++k) {
            if (units[k] != 0) ++live;
        }
        assertEq(live, steps.length, string.concat(at, "used steps"));
        for (uint256 k; k < steps.length; ++k) {
            uint256 step = vm.parseUint(steps[k]);
            uint256 expected = _uint(i, string.concat(".expected.stepTotals.", steps[k]));
            assertGe(step, low, string.concat(at, "low step"));
            assertEq(units[step - low], expected, string.concat(at, "units at ", steps[k]));
        }
        string[] memory logged = vm.parseJsonKeys(json, _case(i, ".expected.departures"));
        for (uint256 k; k < logged.length; ++k) {
            IUniformEditionAuction.Departure[] memory d =
                editionAuction.departures(sale, vm.parseUint(logged[k]));
            // The model writes each departure as [position, quantity].
            string memory list = string.concat(".expected.departures.", logged[k]);
            for (uint256 n; n < d.length; ++n) {
                uint256[] memory pair = vm.parseJsonUintArray(
                    json, _case(i, string.concat(list, "[", vm.toString(n), "]"))
                );
                assertEq(d[n].position, pair[0], string.concat(at, "departure position"));
                assertEq(d[n].quantity, pair[1], string.concat(at, "departure quantity"));
            }
            assertFalse(
                vm.keyExistsJson(json, _case(i, string.concat(list, "[", vm.toString(d.length), "]"))),
                string.concat(at, "departures at ", logged[k])
            );
        }
        uint256[] memory order = editionAuction.settlementOrder(sale);
        uint256[] memory expectedOrder =
            vm.parseJsonUintArray(json, _case(i, ".expected.settlementOrder"));
        assertEq(order, expectedOrder, string.concat(at, "settlement order"));
    }

    /// @dev Every bid's outcome if the sale closed now; a withdrawn bid is gone.
    function _checkBids(uint256 i, uint256 sale, string memory name) internal view {
        for (uint256 k; vm.keyExistsJson(json, _bid(i, k, "")); ++k) {
            uint256 bidId = vm.parseJsonUint(json, _bid(i, k, ".bidId"));
            string memory at = string.concat(name, ": bid ", vm.toString(bidId), " ");
            if (!vm.parseJsonBool(json, _bid(i, k, ".active"))) {
                try editionAuction.bidOf(sale, bidId) {
                    revert(string.concat(at, "should be gone"));
                } catch { }
                continue;
            }
            IUniformEditionAuction.Bid memory b = editionAuction.bidOf(sale, bidId);
            assertEq(b.step, vm.parseJsonUint(json, _bid(i, k, ".step")), string.concat(at, "step"));
            assertEq(b.quantity, vm.parseJsonUint(json, _bid(i, k, ".quantity")), string.concat(at, "qty"));
            assertEq(b.position, vm.parseJsonUint(json, _bid(i, k, ".position")), string.concat(at, "pos"));
            IUniformEditionAuction.BidOutcome memory o = editionAuction.bidOutcome(sale, bidId);
            assertEq(o.escrow, vm.parseJsonUint(json, _bid(i, k, ".escrow")), string.concat(at, "escrow"));
            assertEq(o.unitsWon, vm.parseJsonUint(json, _bid(i, k, ".unitsWon")), string.concat(at, "won"));
            assertEq(o.refund, vm.parseJsonUint(json, _bid(i, k, ".refund")), string.concat(at, "refund"));
            assertEq(o.unitsAhead, vm.parseJsonUint(json, _bid(i, k, ".unitsAhead")), string.concat(at, "ahead"));
        }
    }

    // ------------------------------------------------------------------ JSON paths

    function _case(uint256 i, string memory path) internal pure returns (string memory) {
        return string.concat(".cases[", vm.toString(i), "]", path);
    }

    function _event(uint256 i, uint256 j, string memory path) internal pure returns (string memory) {
        return _case(i, string.concat(".events[", vm.toString(j), "]", path));
    }

    function _bid(uint256 i, uint256 k, string memory path) internal pure returns (string memory) {
        return _case(i, string.concat(".expected.bids[", vm.toString(k), "]", path));
    }

    function _uint(uint256 i, string memory path) internal view returns (uint256) {
        return vm.parseJsonUint(json, _case(i, path));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
