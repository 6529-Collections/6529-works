// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionTerms, ItemKind, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { Roles } from "src/governance/Roles.sol";
import { UniformClearingReference as Ref } from "../../helpers/UniformClearingReference.sol";
import { EditionAuctionStack } from "../EditionAuctionStack.sol";

/// @notice The handler of the edition auction's invariant suite: 6529 Stream Editions and the
///         uniform-price edition auction on the real stack (`EditionAuctionStack`), each edition
///         auction beside its master's 1/1 English auction.
/// @dev Inherited by the invariant test, which targets itself (no handler contract size limit).
///      Every action is bounded and never reverts (`fail_on_revert`): it predicts its outcome
///      from the rules (D138-D141, ADR 0005) and the handler's ghost book, runs the call, and
///      records any disagreement in `violations`.
///
///      Six edition masters by one artist, in one approved package, with creator caps of 0
///      (none), 0, 4, 0, 6 and 2. Five edition bidders and two 1/1 collectors. Bids land on a
///      narrow band of low steps, so steps collide, caps bind inside a step and raises leave
///      holes at the cut step; one bid in sixteen lands far above the band.
abstract contract EditionAuctionHandler is EditionAuctionStack {
    uint256 internal constant MASTERS = 6;
    uint256 internal constant BIDDERS = 5;
    uint256 internal constant COLLECTORS = 2;
    /// @dev The band of steps most bids use, and the first of the far steps a few use.
    uint256 internal constant BAND = 8;
    uint256 internal constant FAR = 48;
    uint256 internal constant MAX_QTY = 4;
    /// @dev The step `fifoHole` builds its hole on: above every band and far step and raise.
    uint256 internal constant HOLE_STEP = 64;
    uint256 internal constant DENOMINATOR = 100_000;

    /// @dev One edition bid as the handler expects it.
    struct GhostBid {
        address bidder;
        uint256 step;
        uint256 qty;
        /// @dev Units entered at the step before this bid: its queue position (capped only).
        uint256 pos;
        bool withdrawn;
        bool claimed;
    }

    /// @dev A departure from a step's queue: a raise out of it or a withdrawal.
    struct Departure {
        uint256 pos;
        uint256 qty;
    }

    /// @dev What the handler expects of one master and its edition auction.
    struct Piece {
        uint32 cap;
        uint256 tokenId;
        /// @dev The 1/1's English auction sale ID, and the edition auction's.
        uint256 saleId;
        uint256 editionSaleId;
        bool started;
        bool opened;
        bool pauseUsed;
        bool cancelled;
        bool masterSettled;
        bool editionCreated;
        bool settled;
        bool voided;
        /// @dev The soft end the handler expects (zero until a bid lands in the soft window).
        uint256 softEnd;
        /// @dev The result settlement stored.
        uint256 k;
        uint256 clearStep;
        uint256 price;
        uint256 claimedWon;
        uint256 lo;
        uint256 hi;
    }

    address internal artist;
    address[BIDDERS] internal bidders;
    address[COLLECTORS] internal collectors;
    bytes32 internal root;
    Piece[MASTERS] internal pieces;
    uint32[MASTERS] internal caps = [uint32(0), 0, 4, 0, 6, 2];

    mapping(uint256 piece => GhostBid[]) internal book;
    mapping(uint256 piece => mapping(uint256 step => uint256)) internal liveUnits;
    mapping(uint256 piece => mapping(uint256 step => uint256)) internal enteredUnits;
    mapping(uint256 piece => mapping(uint256 step => Departure[])) internal departures;

    /// @dev ETH paid into the edition auction, and paid out of it (refunds, withdrawals,
    ///      revenue and credits).
    uint256 internal ghostIn;
    uint256 internal ghostOut;
    mapping(address account => uint256) internal ghostCredit;
    uint256 internal ghostCredits;

    string[] internal violations;
    mapping(bytes32 path => uint256) public hits;

    function setUp() public virtual override {
        super.setUp();
        artist = _actor("eaArtist");
        for (uint256 i; i < BIDDERS; ++i) {
            bidders[i] = makeAddr(string.concat("eaBidder", vm.toString(i)));
        }
        for (uint256 i; i < COLLECTORS; ++i) {
            collectors[i] = makeAddr(string.concat("eaCollector", vm.toString(i)));
        }
        Work[] memory works = new Work[](MASTERS);
        for (uint256 i; i < MASTERS; ++i) {
            works[i] = _work(artist, collectionId);
            works[i].item.kind = ItemKind.EDITION_MASTER;
            works[i].item.edition = _editionTerms(caps[i]);
        }
        root = _publish(works);
        _keep(root, works);
        for (uint256 i; i < MASTERS; ++i) {
            pieces[i].cap = caps[i];
            pieces[i].lo = type(uint256).max;
        }
        // Two pieces start at genesis; the others through `startOneOfOne`.
        _startPiece(0);
        _startPiece(1);
    }

    function _editionTerms(uint32 cap) internal pure returns (EditionTerms memory t) {
        t.maxCount = cap;
        t.currency = CURRENCY_ETH;
        t.saleKind = SaleKind.UNIFORM_AUCTION;
    }

    // ------------------------------------------------------------------ actions: the 1/1

    /// @notice Starts the next master's 1/1 auction.
    function startOneOfOne(uint256 seed) external {
        for (uint256 k; k < MASTERS; ++k) {
            uint256 i = (seed % MASTERS + k) % MASTERS;
            if (pieces[i].started) continue;
            _startPiece(i);
            ++hits["startOneOfOne"];
            return;
        }
    }

    /// @notice A collector bids on a live 1/1, half the time in its last anti-snipe window, so
    ///         the 1/1's end, and with it the edition auction's, moves later.
    function bidOneOfOne(uint256 seed, uint256 amountSeed) external {
        (bool found, uint256 i) = _pieceWith1of1(seed, IEnglishAuction.AuctionState.ACTIVE);
        if (!found) return;
        Piece storage p = pieces[i];
        uint256 end = _oneOfOneEnd(i);
        uint256 window = auction.config().extensionWindow;
        bool snipe = amountSeed % 2 == 0 && end > block.timestamp + 1;
        if (snipe) {
            uint256 room = end - block.timestamp - 1;
            vm.warp(end - _bound(amountSeed >> 8, 1, window < room ? window : room));
        }
        uint256 before = p.opened ? _endTime(i) : 0;
        uint256 minimum = auction.minimumBid(p.saleId);
        _ethBid(p.saleId, collectors[seed % COLLECTORS], _bound(amountSeed >> 16, minimum, minimum + 1 ether));
        if (snipe) {
            if (_oneOfOneEnd(i) != block.timestamp + window) {
                _violation("the 1/1 anti-snipe did not extend its end");
            }
            ++hits["oneOfOneSnipe"];
            uint256 after_ = p.opened ? _endTime(i) : 0;
            if (p.opened && after_ < before) _violation("the edition end moved earlier");
            if (p.opened && after_ > before) ++hits["editionEndMoved"];
        }
        ++hits["bidOneOfOne"];
    }

    /// @notice Settles an ended 1/1: a bid sells it, no bid sends it to the museum (D140).
    function settleOneOfOne(uint256 seed) external {
        (bool found, uint256 i) = _pieceWith1of1(seed, IEnglishAuction.AuctionState.ENDED);
        if (!found) return;
        Piece storage p = pieces[i];
        IEnglishAuction.Auction memory a = auction.auction(p.saleId);
        auction.settle(p.saleId);
        address holder = a.bidder != address(0) ? a.recipient : economics.museum();
        if (stream.ownerOf(p.tokenId) != holder) _violation("the 1/1 went to the wrong holder");
        p.masterSettled = true;
        ++hits[a.bidder != address(0) ? bytes32("settleOneOfOneSold") : bytes32("museum")];
    }

    /// @notice The guardian pauses a live 1/1 for a dispute (once per auction); the edition
    ///         auction's close becomes undetermined.
    function disputePause(uint256 seed) external {
        (bool found, uint256 i) = _pieceWith1of1(seed, IEnglishAuction.AuctionState.ACTIVE);
        if (!found || pieces[i].pauseUsed) return;
        vm.prank(guardian1);
        auction.pause(pieces[i].saleId, keccak256(abi.encode("edition auction dispute", i)));
        pieces[i].pauseUsed = true;
        ++hits["disputePause"];
    }

    /// @notice Decides a paused 1/1's dispute: upheld a third of the time (the governed cancel,
    ///         which voids the edition auction), otherwise rejected (the governed resume).
    function resolveDispute(uint256 seed, uint256 mode) external {
        (bool found, uint256 i) = _pieceWith1of1(seed, IEnglishAuction.AuctionState.PAUSED);
        if (!found) return;
        Piece storage p = pieces[i];
        IEnglishAuction.Auction memory a = auction.auction(p.saleId);
        if (block.timestamp + Roles.STANDARD > a.pausedAt + auction.MAX_PAUSE()) return;
        if (mode % 3 == 0) {
            bytes32 outcome = _platformStatement(
                address(stream), p.tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://ea-outcome"
            );
            _govern(hotAdmin, address(auction), abi.encodeCall(auction.cancel, (p.saleId, outcome)));
            p.cancelled = true;
            ++hits["cancel"];
            return;
        }
        _govern(hotAdmin, address(auction), abi.encodeCall(auction.resume, (p.saleId)));
        ++hits["resume"];
    }

    // ------------------------------------------------------------------ actions: editions

    /// @notice Anyone opens a started master's edition auction until the 1/1's end plus the
    ///         offset (an unopened one first); a late or second open is refused.
    function open(uint256 seed, uint256 callerSeed) external {
        for (uint256 k; k < 2 * MASTERS; ++k) {
            uint256 i = (seed % MASTERS + k) % MASTERS;
            Piece storage p = pieces[i];
            if (!p.started || p.cancelled || (k < MASTERS && p.opened && seed % 4 != 0)) continue;
            PackageItem memory item = _package(root)[i].item;
            bool expected = !p.opened && _openable(i);
            vm.prank(bidders[callerSeed % BIDDERS]);
            try ea.open(address(editions), p.tokenId, abi.encode(item)) returns (
                uint256 saleId
            ) {
                if (!expected) _violation("an edition auction opened late or twice");
                if (saleId != p.editionSaleId) _violation("the sale ID is not saleIdOf");
                p.opened = true;
                ++hits["open"];
            } catch {
                if (expected) _violation("a valid open failed");
                ++hits["openRefused"];
            }
            return;
        }
    }

    /// @notice A bidder bids a quantity at a step, paying exactly; a quarter of the time in the
    ///         auction's soft-close window, which extends the close. A payment one wei off is
    ///         refused.
    function bid(uint256 seed, uint256 stepSeed, uint256 qtySeed) external {
        (bool found, uint256 i) = _biddable(seed);
        if (!found) return;
        if (qtySeed % 4 == 0) _warpIntoSoftWindow(i, qtySeed >> 2);
        uint256 step = _stepFrom(stepSeed);
        uint256 qty = _bound(qtySeed >> 8, 1, MAX_QTY);
        _placeBid(i, bidders[seed % BIDDERS], step, qty);
    }

    /// @notice A bidder raises one of its live bids to a higher step, paying the difference;
    ///         in a capped auction it rejoins at the back of its new step, leaving a hole at
    ///         the old one. A stranger's raise is refused.
    function raise(uint256 seed, uint256 bidSeed, uint256 stepSeed) external {
        (bool found, uint256 i) = _biddable(seed);
        if (!found || book[i].length == 0) return;
        uint256 index = bidSeed % book[i].length;
        GhostBid storage b = book[i][index];
        if (b.withdrawn) return;
        uint256 next = b.step + 1 + stepSeed % 6;
        uint256 id = index + 1;
        vm.prank(collectors[0]);
        try ea.raise(pieces[i].editionSaleId, id, next) {
            _violation("a stranger raised another's bid");
        } catch {
            ++hits["raiseRefused"];
        }
        _raiseBid(i, index, next);
    }

    /// @notice On a capped sale (a cap `c` of at least 4) that is still taking bids, builds
    ///         holes at the cut step: bids of 1, 1, `c - 3` and 2 units on one step above every
    ///         other, the first two then raised two steps higher. The step is rationed (it sells
    ///         `c - 2` of its `c - 1` live units), the sweep closes both holes, the third bid wins
    ///         in full and the fourth, the marginal bid, 1 of its 2 (FIFO with holes, owner
    ///         decision 1). Without the sweep the third bid would win nothing.
    function fifoHole(uint256 seed) external {
        for (uint256 k; k < MASTERS; ++k) {
            uint256 i = (seed % MASTERS + k) % MASTERS;
            Piece storage p = pieces[i];
            if (p.cap < 4 || !p.opened || !_biddingOpen(i) || p.hi >= HOLE_STEP) continue;
            uint256 first = book[i].length;
            _placeBid(i, bidders[0], HOLE_STEP, 1);
            _placeBid(i, bidders[1], HOLE_STEP, 1);
            _placeBid(i, bidders[2], HOLE_STEP, p.cap - 3);
            _placeBid(i, bidders[3], HOLE_STEP, 2);
            if (book[i].length != first + 4) return;
            _raiseBid(i, first, HOLE_STEP + 2);
            _raiseBid(i, first + 1, HOLE_STEP + 2);
            ++hits["fifoHole"];
            return;
        }
    }

    /// @dev The bidder of bid `index` raises it to `next`, paying exactly the difference; in a
    ///      capped sale it leaves a departure at its old step and rejoins at the back of `next`.
    function _raiseBid(uint256 i, uint256 index, uint256 next) internal {
        GhostBid storage b = book[i][index];
        uint256 cost = b.qty * (_price(i, next) - _price(i, b.step));
        _softClose(i);
        vm.deal(b.bidder, b.bidder.balance + cost);
        vm.prank(b.bidder);
        try ea.raise{ value: cost }(pieces[i].editionSaleId, index + 1, next) {
            ghostIn += cost;
            _depart(i, b.step, b.pos, b.qty);
            b.step = next;
            b.pos = pieces[i].cap == 0 ? 0 : enteredUnits[i][next];
            enteredUnits[i][next] += b.qty;
            liveUnits[i][next] += b.qty;
            _widen(i, next);
            ++hits["raise"];
        } catch {
            _violation("a valid raise failed");
        }
    }

    /// @notice A bidder withdraws an edition bid in full, which only a dispute pause of the 1/1
    ///         allows (bids are firm otherwise).
    function withdraw(uint256 seed, uint256 bidSeed) external {
        for (uint256 k; k < MASTERS; ++k) {
            uint256 i = (seed % MASTERS + k) % MASTERS;
            Piece storage p = pieces[i];
            if (!p.opened || p.settled || p.voided || book[i].length == 0) continue;
            uint256 index = bidSeed % book[i].length;
            GhostBid storage b = book[i][index];
            if (b.withdrawn || b.claimed) continue;
            bool paused = _state1of1(i) == IEnglishAuction.AuctionState.PAUSED;
            uint256 escrow = b.qty * _price(i, b.step);
            uint256 before = b.bidder.balance;
            vm.prank(b.bidder);
            try ea.withdrawBid(p.editionSaleId, index + 1, b.bidder) {
                if (!paused) {
                    _violation("a bid was withdrawn outside a dispute pause");
                    return;
                }
                if (b.bidder.balance - before != escrow) _violation("a withdrawal was not exact");
                ghostOut += escrow;
                _depart(i, b.step, b.pos, b.qty);
                b.withdrawn = true;
                ++hits["withdraw"];
            } catch {
                if (paused) _violation("a withdrawal during a dispute pause failed");
                ++hits["withdrawRefused"];
            }
            return;
        }
    }

    /// @notice Anyone creates the edition of a settled master.
    function createEdition(uint256 seed) external {
        for (uint256 k; k < MASTERS; ++k) {
            uint256 i = (seed % MASTERS + k) % MASTERS;
            Piece storage p = pieces[i];
            if (!p.masterSettled || p.editionCreated) continue;
            editions.createEdition(p.tokenId, _package(root)[i].item, root, _proofOf(_package(root), i));
            p.editionCreated = true;
            ++hits["createEdition"];
            return;
        }
    }

    /// @notice Settles (or voids) an edition auction with the departure hint, in one call or
    ///         two chunks, and checks the result against the brute-force reference. A third of
    ///         the time it first tries one that may not settle yet: before the close, before
    ///         the 1/1 settles, or before its edition exists, all refused.
    function settle(uint256 seed, uint256 mode) external {
        for (uint256 k; k < MASTERS; ++k) {
            uint256 i = (seed % MASTERS + k) % MASTERS;
            Piece storage p = pieces[i];
            if (!p.opened || p.settled || p.voided) continue;
            if (p.cancelled) {
                _void(i);
                return;
            }
            bool closed = block.timestamp >= _endTime(i);
            bool final_ = _state1of1(i) == IEnglishAuction.AuctionState.SETTLED;
            (uint256 refK,,) = _reference(i);
            if (closed && final_ && (refK == 0 || p.editionCreated)) {
                _settle(i, mode);
                return;
            }
            if (mode % 3 != 0) continue;
            uint256[] memory order = _hint(i);
            try ea.settle(p.editionSaleId, order) {
                _violation("an edition auction settled early");
            } catch {
                ++hits[!closed ? bytes32("settleTooEarly") : bytes32("settleWaits")];
            }
            return;
        }
    }

    /// @notice The bidder claims a bid of a settled or void auction (to itself), or anyone
    ///         pushes it with `claimBidFor`; a second claim is refused.
    function claim(uint256 seed, uint256 bidSeed, uint256 mode) external {
        for (uint256 k; k < MASTERS; ++k) {
            uint256 i = (seed % MASTERS + k) % MASTERS;
            Piece storage p = pieces[i];
            if (!(p.settled || p.voided)) continue;
            for (uint256 j; j < book[i].length; ++j) {
                uint256 index = (bidSeed % book[i].length + j) % book[i].length;
                GhostBid storage b = book[i][index];
                if (b.withdrawn || b.claimed) continue;
                _claim(i, index, mode);
                return;
            }
        }
    }

    /// @notice A bidder with a credit (a `claimBidFor` refund) withdraws it.
    function withdrawCredit(uint256 seed) external {
        address account = bidders[seed % BIDDERS];
        uint256 credit = ghostCredit[account];
        if (credit == 0) return;
        uint256 before = account.balance;
        vm.prank(account);
        ea.claim(CURRENCY_ETH, account);
        if (account.balance - before != credit) _violation("a credit was not paid in full");
        ghostOut += credit;
        ghostCredits -= credit;
        ghostCredit[account] = 0;
        ++hits["withdrawCredit"];
    }

    /// @notice Time passes: half the time a short while, otherwise to just past the next clock
    ///         of a started piece (a 1/1's end or an edition close), so sales close within a run.
    function warp(uint256 secondsSeed) external {
        uint256 next = type(uint256).max;
        if (secondsSeed % 2 == 1) {
            for (uint256 i; i < MASTERS; ++i) {
                Piece storage p = pieces[i];
                if (!p.started || p.settled || p.voided) continue;
                uint256 end = _oneOfOneEnd(i);
                if (end > block.timestamp && end < next) next = end;
                if (!p.opened || _state1of1(i) == IEnglishAuction.AuctionState.PAUSED) continue;
                end = _endTime(i);
                if (end > block.timestamp && end < next) next = end;
            }
        }
        if (next == type(uint256).max) next = block.timestamp + _bound(secondsSeed >> 1, 1 minutes, 3 hours);
        else next += _bound(secondsSeed >> 1, 0, 10 minutes);
        vm.warp(next);
        ++hits["warp"];
    }

    // ------------------------------------------------------------------ internals: actions

    function _startPiece(uint256 i) internal {
        Piece storage p = pieces[i];
        (p.saleId, p.tokenId) = _start(root, _package(root), i);
        p.editionSaleId = ea.saleIdOf(address(editions), p.tokenId);
        p.started = true;
    }

    function _placeBid(uint256 i, address bidder, uint256 step, uint256 qty) internal {
        Piece storage p = pieces[i];
        uint256 cost = qty * _price(i, step);
        vm.deal(bidder, bidder.balance + cost + 1);
        vm.prank(bidder);
        try ea.bid{ value: cost + 1 }(p.editionSaleId, step, qty) {
            _violation("an inexact payment was accepted");
        } catch {
            ++hits["inexactRefused"];
        }
        _softClose(i);
        vm.prank(bidder);
        try ea.bid{ value: cost }(p.editionSaleId, step, qty) returns (uint256 id) {
            if (id != book[i].length + 1) _violation("bid IDs are not sequential");
            ghostIn += cost;
            uint256 pos = p.cap == 0 ? 0 : enteredUnits[i][step];
            book[i].push(GhostBid(bidder, step, qty, pos, false, false));
            enteredUnits[i][step] += qty;
            liveUnits[i][step] += qty;
            _widen(i, step);
            ++hits["bid"];
        } catch {
            _violation("a valid bid failed");
        }
    }

    /// @dev D141: a bid or raise within `softWindow` of the end sets the soft end to
    ///      `min(now + softWindow, backstop)`, the backstop being the 1/1's end plus the offset
    ///      plus `maxExtension`. While the 1/1 is paused bids are accepted at any time and move
    ///      nothing. Called just before a bid lands. A bid exactly `softWindow` before the end
    ///      would only set the soft end to the end itself; the adapter leaves it unset then, and
    ///      the end is the same either way.
    function _softClose(uint256 i) internal {
        if (_state1of1(i) == IEnglishAuction.AuctionState.PAUSED) return;
        IUniformEditionAuction.AuctionConfig memory t = _terms(i);
        if (block.timestamp + t.softWindow <= _endTime(i)) return;
        uint256 backstop = _closeAt(i) + t.maxExtension;
        uint256 next = block.timestamp + t.softWindow;
        pieces[i].softEnd = next < backstop ? next : backstop;
        ++hits["softClose"];
    }

    function _warpIntoSoftWindow(uint256 i, uint256 seed) internal {
        if (_state1of1(i) == IEnglishAuction.AuctionState.PAUSED) return;
        uint256 end = _endTime(i);
        uint256 into = _bound(seed, 1, _terms(i).softWindow);
        if (end > block.timestamp + into) vm.warp(end - into);
    }

    function _depart(uint256 i, uint256 step, uint256 pos, uint256 qty) internal {
        liveUnits[i][step] -= qty;
        if (pieces[i].cap != 0) departures[i][step].push(Departure(pos, qty));
    }

    function _widen(uint256 i, uint256 step) internal {
        Piece storage p = pieces[i];
        if (step < p.lo) p.lo = step;
        if (step > p.hi) p.hi = step;
    }

    function _settle(uint256 i, uint256 mode) internal {
        Piece storage p = pieces[i];
        IUniformEditionAuction.Clearing memory live = ea.clearing(p.editionSaleId);
        uint256 feeBefore = networkFee.balance;
        _sweep(i, mode);
        IUniformEditionAuction.Clearing memory c = ea.clearing(p.editionSaleId);
        if (c.count != live.count || c.step != live.step || c.price != live.price) {
            _violation("the live view differs from the settled result");
        }
        _checkAgainstReference(i, c.count, c.price);
        p.settled = true;
        p.k = c.count;
        p.clearStep = c.step;
        p.price = c.price;
        uint256 revenue = uint256(c.count) * c.price;
        uint256 fee = revenue * ea.auction(p.editionSaleId).feeShare / DENOMINATOR;
        if (networkFee.balance - feeBefore != fee) _violation("the network was not paid its share");
        ghostOut += revenue;
        if (c.count == 0) {
            ++hits["settleEmpty"];
            return;
        }
        ++hits["settle"];
        if (c.rationed) ++hits["rationed"];
        if (c.rationed && departures[i][c.step].length != 0) ++hits["holeSwept"];
    }

    /// @dev Settles with the departure order, which must equal `settlementOrder`. Half the time
    ///      the first call gets only the first half of the sweep; every later call continues
    ///      from the departures already swept, as a keeper would, until the sale settles.
    function _sweep(uint256 i, uint256 mode) internal {
        uint256 sale = pieces[i].editionSaleId;
        uint256[] memory order = _hint(i);
        if (keccak256(abi.encode(order)) != keccak256(abi.encode(ea.settlementOrder(sale)))) {
            _violation("settlementOrder differs from the departures sorted by position");
        }
        uint256 chunk = order.length > 1 && mode % 2 == 0 ? order.length / 2 : order.length;
        bool done = ea.settle(sale, _slice(order, 0, chunk));
        if (chunk < order.length) {
            if (done) _violation("half a sweep settled");
            ++hits["settleChunked"];
        }
        for (uint256 calls; !done && calls < 8; ++calls) {
            uint256 swept = ea.settlement(sale).departuresSwept;
            done = ea.settle(sale, _slice(order, swept, order.length));
        }
        if (!done) _violation("a complete sweep did not settle");
    }

    /// @dev The settled count and price equal the per-unit reference's, within the cap and the
    ///      breadth margin.
    function _checkAgainstReference(uint256 i, uint256 k, uint256 price) internal {
        (uint256 refK, uint256 refPrice, uint256 best) = _reference(i);
        if (k != refK) _violation("the count differs from the per-unit reference");
        if (k != 0 && price != refPrice) _violation("the price differs from the reference");
        if (pieces[i].cap != 0 && k > pieces[i].cap) _violation("the count exceeds the cap");
        if (k * price * DENOMINATOR < best * (DENOMINATOR - _terms(i).marginShare)) {
            _violation("revenue below the breadth threshold");
        }
    }

    /// @dev A cancelled 1/1 takes no more edition bids, and settling voids its edition auction.
    function _void(uint256 i) internal {
        Piece storage p = pieces[i];
        uint256 cost = _price(i, 0);
        vm.deal(bidders[0], bidders[0].balance + cost);
        vm.prank(bidders[0]);
        try ea.bid{ value: cost }(p.editionSaleId, 0, 1) {
            _violation("a cancelled 1/1's edition auction took a bid");
        } catch {
            ++hits["cancelledBidRefused"];
        }
        ea.settle(p.editionSaleId, new uint256[](0));
        if (
            ea.auction(p.editionSaleId).status
                != IUniformEditionAuction.AuctionStatus.VOID
        ) {
            _violation("a cancelled 1/1 did not void its edition auction");
        }
        p.voided = true;
        ++hits["void"];
    }

    function _claim(uint256 i, uint256 index, uint256 mode) internal {
        Piece storage p = pieces[i];
        GhostBid storage b = book[i][index];
        uint256 id = index + 1;
        uint256 won = p.voided ? 0 : _expectedWon(i, index);
        uint256 refund = b.qty * _price(i, b.step) - won * p.price;
        IUniformEditionAuction.BidOutcome memory o = ea.bidOutcome(p.editionSaleId, id);
        if (o.unitsWon != won || o.refund != refund || !o.isFinal) {
            _violation("bidOutcome differs from the claim");
        }
        uint256 copiesBefore = won == 0 ? 0 : editions.balanceOf(b.bidder, p.tokenId);
        if (mode % 3 == 0) {
            vm.prank(collectors[1]);
            ea.claimBidFor(p.editionSaleId, id);
            ghostCredit[b.bidder] += refund;
            ghostCredits += refund;
            ++hits["claimFor"];
        } else {
            uint256 ethBefore = b.bidder.balance;
            vm.prank(b.bidder);
            ea.claimBid(p.editionSaleId, id, b.bidder);
            if (b.bidder.balance - ethBefore != refund) _violation("a claim refund was not exact");
            ghostOut += refund;
            ++hits["claim"];
        }
        if (won != 0 && editions.balanceOf(b.bidder, p.tokenId) - copiesBefore != won) {
            _violation("a claim minted the wrong number of copies");
        }
        b.claimed = true;
        p.claimedWon += won;
        if (won != 0 && won < b.qty) ++hits["partFilled"];
        if (p.voided) ++hits["voidRefund"];
        vm.prank(b.bidder);
        try ea.claimBid(p.editionSaleId, id, b.bidder) {
            _violation("a bid was claimed twice");
        } catch {
            ++hits["claimTwiceRefused"];
        }
    }

    // ------------------------------------------------------------------ internals: the model

    /// @dev The per-unit reference clearing of piece `i`'s live book.
    function _reference(uint256 i) internal view returns (uint256 k, uint256 price, uint256 best) {
        Piece storage p = pieces[i];
        if (p.lo == type(uint256).max) return (0, 0, 0);
        uint256 n = p.hi - p.lo + 1;
        uint256[] memory units = new uint256[](n);
        uint256[] memory prices = new uint256[](n);
        for (uint256 s; s < n; ++s) {
            units[s] = liveUnits[i][p.lo + s];
            prices[s] = _price(i, p.lo + s);
        }
        return Ref.clear(units, prices, p.cap, _terms(i).marginShare);
    }

    function _slice(uint256[] memory list, uint256 from, uint256 to)
        internal
        pure
        returns (uint256[] memory out)
    {
        out = new uint256[](to - from);
        for (uint256 j = from; j < to; ++j) {
            out[j - from] = list[j];
        }
    }

    /// @dev The settler's hint: the indexes of the clearing step's departures, in position
    ///      order. Empty unless the reference clearing is rationed (the cap binds inside the
    ///      clearing step), the only case in which settlement sweeps departures.
    function _hint(uint256 i) internal view returns (uint256[] memory order) {
        Piece storage p = pieces[i];
        if (p.cap == 0) return order;
        (uint256 k, uint256 price,) = _reference(i);
        if (k == 0) return order;
        uint256 step = _stepAt(i, price);
        uint256 atOrAbove;
        for (uint256 s = step; s <= p.hi; ++s) {
            atOrAbove += liveUnits[i][s];
        }
        if (atOrAbove <= k) return order;
        Departure[] storage d = departures[i][step];
        order = new uint256[](d.length);
        bool[] memory used = new bool[](d.length);
        for (uint256 n; n < d.length; ++n) {
            uint256 next = type(uint256).max;
            for (uint256 j; j < d.length; ++j) {
                if (!used[j] && (next == type(uint256).max || d[j].pos < d[next].pos)) next = j;
            }
            used[next] = true;
            order[n] = next;
        }
    }

    /// @dev The units bid `index` wins once settled: all of a bid above the clearing step, none
    ///      below, and at the step the reference's fill, in arrival order, of what the step
    ///      sells.
    function _expectedWon(uint256 i, uint256 index) internal view returns (uint256) {
        Piece storage p = pieces[i];
        GhostBid storage b = book[i][index];
        if (p.k == 0 || b.withdrawn || b.step < p.clearStep) return 0;
        if (b.step > p.clearStep) return b.qty;
        uint256 above;
        for (uint256 s = p.clearStep + 1; s <= p.hi; ++s) {
            above += liveUnits[i][s];
        }
        (uint256[] memory positions, uint256[] memory quantities, uint256 me) = _cutQueue(i, index);
        return Ref.fillInArrivalOrder(positions, quantities, p.k - above)[me];
    }

    /// @dev The live bids at the clearing step: their positions (entry order for an uncapped
    ///      auction, whose step is never split) and quantities, and where bid `index` is.
    function _cutQueue(uint256 i, uint256 index)
        internal
        view
        returns (uint256[] memory positions, uint256[] memory quantities, uint256 me)
    {
        Piece storage p = pieces[i];
        GhostBid[] storage bids = book[i];
        uint256 n;
        for (uint256 j; j < bids.length; ++j) {
            if (!bids[j].withdrawn && bids[j].step == p.clearStep) ++n;
        }
        positions = new uint256[](n);
        quantities = new uint256[](n);
        n = 0;
        for (uint256 j; j < bids.length; ++j) {
            if (bids[j].withdrawn || bids[j].step != p.clearStep) continue;
            if (j == index) me = n;
            positions[n] = p.cap == 0 ? j : bids[j].pos;
            quantities[n++] = bids[j].qty;
        }
    }

    function _stepAt(uint256 i, uint256 price) internal view returns (uint256) {
        Piece storage p = pieces[i];
        for (uint256 s = p.lo; s <= p.hi; ++s) {
            if (_price(i, s) == price) return s;
        }
        revert("no step at that price");
    }

    /// @dev Mostly the band of low steps; one bid in sixteen far above it.
    function _stepFrom(uint256 seed) internal pure returns (uint256) {
        return seed % 16 == 0 ? FAR + (seed >> 4) % 4 : (seed >> 4) % BAND;
    }


    /// @dev The first piece, from `seed`, whose edition auction takes bids now.
    function _biddable(uint256 seed) internal view returns (bool, uint256) {
        for (uint256 k; k < MASTERS; ++k) {
            uint256 i = (seed % MASTERS + k) % MASTERS;
            if (pieces[i].opened && _biddingOpen(i)) return (true, i);
        }
        return (false, 0);
    }

    function _pieceWith1of1(uint256 seed, IEnglishAuction.AuctionState state)
        internal
        view
        returns (bool, uint256)
    {
        for (uint256 k; k < MASTERS; ++k) {
            uint256 i = (seed % MASTERS + k) % MASTERS;
            if (pieces[i].started && _state1of1(i) == state) return (true, i);
        }
        return (false, 0);
    }

    function _state1of1(uint256 i) internal view returns (IEnglishAuction.AuctionState) {
        return auction.auction(pieces[i].saleId).state;
    }

    function _oneOfOneEnd(uint256 i) internal view returns (uint256) {
        return auction.auction(pieces[i].saleId).endTime;
    }

    /// @dev The 1/1's end plus the locked offset: the earliest the edition auction can close.
    function _closeAt(uint256 i) internal view returns (uint256) {
        return _oneOfOneEnd(i) + _terms(i).closeOffset;
    }

    /// @dev The end the handler expects: `max(closeAt, softEnd)` (D140, D141).
    function _endTime(uint256 i) internal view returns (uint256) {
        uint256 closeAt = _closeAt(i);
        uint256 soft = pieces[i].softEnd;
        return soft > closeAt ? soft : closeAt;
    }

    /// @dev Bidding is open before the end, and at any time while the 1/1 is paused for a
    ///      dispute; never once the 1/1 is cancelled.
    function _biddingOpen(uint256 i) internal view returns (bool) {
        IEnglishAuction.AuctionState s = _state1of1(i);
        if (s == IEnglishAuction.AuctionState.CANCELLED) return false;
        return s == IEnglishAuction.AuctionState.PAUSED || block.timestamp < _endTime(i);
    }

    /// @dev An auction may open from the 1/1's start until the edition close, which before it
    ///      opens is the 1/1's end plus the current offset (at any time while the 1/1 is paused),
    ///      never once the 1/1 is cancelled.
    function _openable(uint256 i) internal view returns (bool) {
        IEnglishAuction.AuctionState s = _state1of1(i);
        if (s == IEnglishAuction.AuctionState.CANCELLED) return false;
        return s == IEnglishAuction.AuctionState.PAUSED
            || block.timestamp < _oneOfOneEnd(i) + ea.config().closeOffset;
    }

    function _terms(uint256 i) internal view returns (IUniformEditionAuction.AuctionConfig memory) {
        return ea.auction(pieces[i].editionSaleId).terms;
    }

    function _price(uint256 i, uint256 step) internal view returns (uint256) {
        return ea.stepPrice(pieces[i].editionSaleId, step);
    }

    function _violation(string memory what) internal {
        violations.push(what);
    }

    // ------------------------------------------------------------------ the invariants

    function _assertEditionAuction() internal view {
        for (uint256 v; v < violations.length; ++v) {
            revert(violations[v]);
        }
        _assertConservation();
        for (uint256 i; i < MASTERS; ++i) {
            if (!pieces[i].opened) continue;
            _assertTiming(i);
            _assertClearing(i);
            _assertSupply(i);
        }
    }

    /// @dev ETH conservation: the adapter's balance is what was paid in minus what was paid
    ///      out, and exactly what it owes: every unclaimed, unwithdrawn bid's escrow, less its
    ///      won units at the clearing price once settled, plus the credits.
    function _assertConservation() internal view {
        uint256 owed = ghostCredits;
        for (uint256 i; i < MASTERS; ++i) {
            Piece storage p = pieces[i];
            for (uint256 j; j < book[i].length; ++j) {
                GhostBid storage b = book[i][j];
                if (b.withdrawn || b.claimed) continue;
                uint256 escrow = b.qty * _price(i, b.step);
                owed += p.settled ? escrow - _expectedWon(i, j) * p.price : escrow;
            }
        }
        assertEq(address(editionAuction).balance, ghostIn - ghostOut, "ETH in minus ETH out");
        assertEq(address(editionAuction).balance, owed, "the balance is exactly what is owed");
    }

    /// @dev The clocks: the 1/1's end read live, `closeAt` its end plus the offset, the soft end
    ///      the handler expects, `endTime = max(closeAt, softEnd)` within the backstop, and
    ///      bidding and withdrawals open exactly when the rules say.
    function _assertTiming(uint256 i) internal view {
        Piece storage p = pieces[i];
        if (p.settled || p.voided) return;
        IUniformEditionAuction.EndTimes memory e = ea.endTimes(p.editionSaleId);
        IUniformEditionAuction.AuctionConfig memory t = _terms(i);
        IEnglishAuction.AuctionState s = _state1of1(i);
        assertEq(e.oneOfOneEnd, _oneOfOneEnd(i), "the 1/1's end is read live");
        assertEq(e.closeAt, _closeAt(i), "closeAt is the 1/1's end plus the offset");
        assertEq(e.softEnd, p.softEnd, "the soft end");
        assertEq(e.endTime, _endTime(i), "endTime is max(closeAt, softEnd)");
        assertEq(e.backstop, e.closeAt + t.maxExtension, "the backstop");
        assertGe(e.endTime, e.closeAt, "never before the 1/1's end plus the offset");
        assertLe(e.endTime, e.backstop, "the soft close stays within the backstop");
        assertEq(uint8(e.oneOfOneState), uint8(s), "the 1/1's state");
        assertEq(e.biddingOpen, _biddingOpen(i), "bidding open exactly when the rules say");
        assertEq(
            e.withdrawalsOpen,
            s == IEnglishAuction.AuctionState.PAUSED,
            "withdrawals open exactly while the 1/1 is paused"
        );
    }

    /// @dev Before settlement the live result equals the per-unit reference (so it is the
    ///      largest count within the breadth margin of the best revenue, and its best revenue is
    ///      R*), within the cap; after it, the stored result never changes.
    function _assertClearing(uint256 i) internal view {
        Piece storage p = pieces[i];
        if (p.voided) return;
        if (p.settled) {
            IUniformEditionAuction.Settlement memory r = ea.settlement(p.editionSaleId);
            assertEq(r.count, p.k, "the stored count never changes");
            assertEq(r.price, p.price, "the stored price never changes");
            assertEq(r.departuresSwept, r.departures, "the sweep is complete");
            return;
        }
        IUniformEditionAuction.Clearing memory c = ea.clearing(p.editionSaleId);
        (uint256 refK, uint256 refPrice, uint256 best) = _reference(i);
        assertEq(c.count, refK, "the live count equals the per-unit reference");
        assertEq(c.price, refK == 0 ? 0 : refPrice, "the live price equals the reference");
        assertEq(c.bestRevenue, best, "R* equals the reference's best revenue");
        if (p.cap != 0) assertLe(c.count, p.cap, "the cap");
    }

    /// @dev Never more copies than the clearing count; exactly that many once every bid is
    ///      claimed; the units won sum to `k`, filled at the cut step in arrival order.
    function _assertSupply(uint256 i) internal view {
        Piece storage p = pieces[i];
        uint256 minted = p.editionCreated ? editions.edition(p.tokenId).minted : 0;
        assertEq(minted, p.claimedWon, "copies minted equal the units claimed");
        if (!p.settled) {
            assertEq(minted, 0, "nothing mints before settlement");
            return;
        }
        assertLe(minted, p.k, "never more copies than k");
        uint256 total;
        uint256 unclaimed;
        for (uint256 j; j < book[i].length; ++j) {
            if (book[i][j].withdrawn) continue;
            total += _expectedWon(i, j);
            if (!book[i][j].claimed) ++unclaimed;
        }
        assertEq(total, p.k, "the units won sum to k");
        if (unclaimed == 0) assertEq(minted, p.k, "exactly k copies once every bid is claimed");
    }
}
