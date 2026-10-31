// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { UniformClearingReference as Ref } from "../helpers/UniformClearingReference.sol";
import { EditionAuctionStack } from "./EditionAuctionStack.sol";

/// @notice Differential fuzzing of the edition auction on the real stack against the slow,
///         obvious definition of D138 (`UniformClearingReference`, the Solidity twin of
///         `tools/edition_auction_ref.py`'s brute force): random books of bids and raises, on
///         capped and uncapped sales and under four breadth margins, then the contract's live
///         clearing, every bid's outcome and the settlement order against the reference, and
///         settlement and every claim against exact supply and ETH conservation.
/// @dev The golden vectors replay fixed books through the adapter
///      (`test/sales/edition/UniformEditionAuctionVectors.t.sol`); this explores books nobody
///      wrote down. Bids land on a narrow band of low steps, so steps collide, caps bind inside a
///      step and raises leave holes at the cut step.
contract EditionAuctionDifferentialTest is EditionAuctionStack {
    uint256 internal constant DENOMINATOR = 100_000;
    uint256 internal constant MAX_BIDS = 16;
    uint256 internal constant BAND = 10;

    uint32[5] internal CAPS = [uint32(0), 1, 3, 7, 20];
    uint32[4] internal MARGINS = [uint32(0), 10_000, 25_000, 50_000];

    address internal artist;
    address internal collector = makeAddr("differentialCollector");
    address[4] internal bidders;
    bytes32 internal root;

    /// @dev The fuzzed book, as the reference sees it (reset by every run's snapshot).
    uint256[] internal bidStep;
    uint256[] internal bidQty;
    uint256[] internal bidPos;
    mapping(uint256 step => uint256) internal live;
    mapping(uint256 step => uint256) internal entered;
    mapping(uint256 step => uint256[]) internal departedPos;
    uint256 internal lo = type(uint256).max;
    uint256 internal hi;

    function setUp() public override {
        super.setUp();
        artist = _actor("differentialArtist");
        for (uint256 i; i < 4; ++i) {
            bidders[i] = makeAddr(string.concat("differentialBidder", vm.toString(i)));
        }
        Work[] memory works = new Work[](CAPS.length);
        for (uint256 i; i < CAPS.length; ++i) {
            works[i] = _masterWork(artist, CAPS[i]);
        }
        root = _publish(works);
        _keep(root, works);
    }

    /// @notice A random book: the live clearing, every outcome and the settlement order equal the
    ///         per-unit reference's; settling and claiming every bid mints exactly the clearing
    ///         count and leaves the adapter empty.
    function testFuzz_Clearing_EqualsTheBruteForceReference(
        uint256 seed,
        uint8 capIndex,
        uint8 marginIndex
    ) public {
        uint32 cap = CAPS[capIndex % CAPS.length];
        uint256 margin = _setMargin(MARGINS[marginIndex % MARGINS.length]);
        (uint256 oneSaleId, uint256 workId, uint256 sale) = _startCapped(capIndex % CAPS.length);
        _fuzzBook(sale, seed, cap);

        (uint256 k, uint256 price, uint256 best) = _reference(sale, cap, margin);
        IUniformEditionAuction.Clearing memory c = ea.clearing(sale);
        assertEq(c.count, k, "count");
        assertEq(c.price, price, "price");
        assertEq(c.bestRevenue, best, "best revenue");
        if (cap != 0) assertLe(c.count, cap, "cap");
        _checkOutcomes(sale, k, price, cap);
        _checkOrder(sale, k, price, cap);

        // A sold 1/1, the edition when copies sold, then the edition sale and every claim.
        _ethBid(oneSaleId, collector, 1 ether);
        _settleAtEnd(oneSaleId);
        if (k != 0) {
            Work[] memory works = _package(root);
            uint256 index = capIndex % CAPS.length;
            editions.createEdition(workId, works[index].item, root, _proofOf(works, index));
        }
        _settleEditions(sale);
        assertEq(ea.settlement(sale).count, k, "settled count");
        _claimAll(sale, workId, k, seed);
    }

    // ------------------------------------------------------------------ the book

    function _setMargin(uint32 margin) internal returns (uint256) {
        IUniformEditionAuction.AuctionConfig memory current = ea.config();
        IUniformEditionAuction.AuctionConfig memory next = ea.config();
        next.marginShare = margin;
        if (margin != current.marginShare) {
            _govern(
                hotAdmin,
                address(editionAuction),
                abi.encodeCall(IUniformEditionAuction.setConfig, (current, next))
            );
        }
        return margin;
    }

    function _startCapped(uint256 index)
        internal
        returns (uint256 oneSaleId, uint256 workId, uint256 sale)
    {
        (oneSaleId, workId) = _start(root, _package(root), index);
        sale = editionAuction.open(address(editions), workId, abi.encode(_package(root)[index].item));
    }

    /// @dev Up to 16 bids of 1 to 5 units, mostly on a band of 10 low steps, one in eight a
    ///      raise of an earlier bid by 1 to 4 steps.
    function _fuzzBook(uint256 sale, uint256 seed, uint32 cap) internal {
        uint256 n = 1 + seed % MAX_BIDS;
        for (uint256 j; j < n; ++j) {
            uint256 r = uint256(keccak256(abi.encode(seed, j)));
            if (bidStep.length != 0 && r % 8 == 0) {
                _raise(sale, r >> 8, cap);
                continue;
            }
            uint256 step = (r >> 16) % 64 == 0 ? 40 + (r >> 24) % 4 : (r >> 24) % BAND;
            uint256 qty = 1 + (r >> 32) % 5;
            _editionBid(sale, bidders[j % 4], step, qty);
            bidStep.push(step);
            bidQty.push(qty);
            bidPos.push(cap == 0 ? 0 : entered[step]);
            entered[step] += qty;
            live[step] += qty;
            _widen(step);
        }
    }

    function _raise(uint256 sale, uint256 r, uint32 cap) internal {
        uint256 index = r % bidStep.length;
        uint256 from = bidStep[index];
        uint256 to = from + 1 + (r >> 8) % 4;
        uint256 cost = bidQty[index] * (ea.stepPrice(sale, to) - ea.stepPrice(sale, from));
        address bidder = ea.bidOf(sale, index + 1).bidder;
        vm.deal(bidder, bidder.balance + cost);
        vm.prank(bidder);
        editionAuction.raise{ value: cost }(sale, index + 1, to);
        live[from] -= bidQty[index];
        if (cap != 0) departedPos[from].push(bidPos[index]);
        bidStep[index] = to;
        bidPos[index] = cap == 0 ? 0 : entered[to];
        entered[to] += bidQty[index];
        live[to] += bidQty[index];
        _widen(to);
    }

    function _widen(uint256 step) internal {
        if (step < lo) lo = step;
        if (step > hi) hi = step;
    }

    // ------------------------------------------------------------------ the reference

    function _reference(uint256 sale, uint32 cap, uint256 margin)
        internal
        view
        returns (uint256 k, uint256 price, uint256 best)
    {
        uint256 n = hi - lo + 1;
        uint256[] memory units = new uint256[](n);
        uint256[] memory prices = new uint256[](n);
        for (uint256 s; s < n; ++s) {
            units[s] = live[lo + s];
            prices[s] = ea.stepPrice(sale, lo + s);
        }
        return Ref.clear(units, prices, cap, margin);
    }

    /// @dev Every bid wins all of its units above the clearing price, none below, and at the
    ///      clearing step the reference's fill in arrival order of what the step sells.
    function _checkOutcomes(uint256 sale, uint256 k, uint256 price, uint32 cap) internal view {
        uint256 step = k == 0 ? type(uint256).max : _stepAt(sale, price);
        uint256 above;
        for (uint256 s = step + 1; k != 0 && s <= hi; ++s) {
            above += live[s];
        }
        uint256[] memory filled;
        if (k != 0) filled = _fill(step, k - above, cap);
        uint256 cursor;
        for (uint256 j; j < bidStep.length; ++j) {
            uint256 won;
            if (k == 0 || bidStep[j] < step) won = 0;
            else if (bidStep[j] > step) won = bidQty[j];
            else won = filled[cursor++];
            IUniformEditionAuction.BidOutcome memory o = ea.bidOutcome(sale, j + 1);
            assertEq(o.unitsWon, won, "units won");
            assertEq(o.escrow, bidQty[j] * ea.stepPrice(sale, bidStep[j]), "escrow");
            assertEq(o.refund, o.escrow - won * price, "refund");
        }
    }

    /// @dev The units each bid at `step` wins, in the bids' order, filling `units` by position
    ///      (by bid order in an uncapped sale, whose clearing step is never split).
    function _fill(uint256 step, uint256 units, uint32 cap) internal view returns (uint256[] memory) {
        uint256 n;
        for (uint256 j; j < bidStep.length; ++j) {
            if (bidStep[j] == step) ++n;
        }
        uint256[] memory positions = new uint256[](n);
        uint256[] memory quantities = new uint256[](n);
        n = 0;
        for (uint256 j; j < bidStep.length; ++j) {
            if (bidStep[j] != step) continue;
            positions[n] = cap == 0 ? j : bidPos[j];
            quantities[n++] = bidQty[j];
        }
        return Ref.fillInArrivalOrder(positions, quantities, units);
    }

    /// @dev The settlement order is the clearing step's departures sorted by position, and only
    ///      when the cap binds inside it.
    function _checkOrder(uint256 sale, uint256 k, uint256 price, uint32 cap) internal view {
        uint256[] memory order = ea.settlementOrder(sale);
        if (cap == 0 || k == 0) {
            assertEq(order.length, 0, "no order without a rationed cap");
            return;
        }
        uint256 step = _stepAt(sale, price);
        uint256 atOrAbove;
        for (uint256 s = step; s <= hi; ++s) {
            atOrAbove += live[s];
        }
        uint256[] storage d = departedPos[step];
        if (atOrAbove <= k) {
            assertEq(order.length, 0, "no order unless rationed");
            return;
        }
        assertEq(order.length, d.length, "every departure of the cut step");
        for (uint256 n = 1; n < order.length; ++n) {
            assertLt(d[order[n - 1]], d[order[n]], "in position order");
        }
    }

    function _stepAt(uint256 sale, uint256 price) internal view returns (uint256) {
        for (uint256 s = lo; s <= hi; ++s) {
            if (ea.stepPrice(sale, s) == price) return s;
        }
        revert("no step at that price");
    }

    // ------------------------------------------------------------------ settlement and claims

    /// @dev Claims every bid (half pushed by `claimBidFor`, whose refunds the bidders then take):
    ///      exactly `k` copies exist afterwards and the adapter holds nothing.
    function _claimAll(uint256 sale, uint256 workId, uint256 k, uint256 seed) internal {
        uint256 minted;
        for (uint256 j; j < bidStep.length; ++j) {
            if ((seed >> j) & 1 == 0) {
                address bidder = ea.bidOf(sale, j + 1).bidder;
                vm.prank(bidder);
                (uint256 won,) = editionAuction.claimBid(sale, j + 1, bidder);
                minted += won;
            } else {
                (uint256 won,) = editionAuction.claimBidFor(sale, j + 1);
                minted += won;
            }
        }
        for (uint256 i; i < 4; ++i) {
            if (editionAuction.claimable(bidders[i], CURRENCY_ETH) == 0) continue;
            vm.prank(bidders[i]);
            editionAuction.claim(CURRENCY_ETH, bidders[i]);
        }
        assertEq(minted, k, "the claims minted k");
        if (k != 0) assertEq(editions.edition(workId).minted, k, "supply is k");
        assertEq(address(editionAuction).balance, 0, "nothing left in the adapter");
    }
}
