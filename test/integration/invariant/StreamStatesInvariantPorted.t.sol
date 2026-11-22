// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { SaleTerms } from "src/interfaces/types/PackageTypes.sol";
import { IntegrationBase } from "../IntegrationBase.sol";
import { PortedSaleAdapter } from "../StreamSalePorted.t.sol";

/// @notice Owner decision 28 on the plain core, re-ported from `StreamStatesInvariant`: a work's
///         life and a minter's life follow fixed tables, and nothing moves a work or a minter
///         outside them.
///
///         On the deployed stack, random sequences mint works through the English auction and
///         a second minter (`PortedSaleAdapter`), bid, settle with either outcome, burn, hand
///         works out of custody and back and between holders, add and remove both minters (and
///         try calls that would change nothing), warp time and rescue works. After every call
///         each work's state is read from what Stream stores and checked:
///         1. every observed (before, after) pair of work states is a row of the table (or no
///            change). The plain core's table: NEVER_MINTED > IN_SALE; IN_SALE > OUT_OF_CUSTODY,
///            CANCELLED (burned), SOLD, UNSOLD, RESCUED; OUT_OF_CUSTODY > IN_SALE. Cancelled and
///            every outcome are final. (The retired Stream also allowed OUT_OF_CUSTODY > SOLD;
///            the plain core records an outcome only for a minter holding the token.)
///         2. a recorded outcome never changes;
///         3. every observed minter transition is a row of its table (NEVER > WAITING > ACTIVE >
///            REMOVED > WAITING, and WAITING > REMOVED), and a call that would change nothing is
///            refused.
contract StreamStatesInvariantPortedTest is IntegrationBase {
    enum S {
        NEVER_MINTED,
        IN_SALE,
        OUT_OF_CUSTODY,
        CANCELLED,
        SOLD,
        UNSOLD,
        RESCUED,
        /// @dev Not a state of the table: a recorded outcome on a token that no longer exists.
        OUTCOME_WITHOUT_TOKEN
    }

    enum M {
        NEVER_ADDED,
        WAITING,
        ACTIVE,
        REMOVED
    }

    bytes32 internal constant KIND = keccak256("STATES_TEST_1OF1");
    uint256 internal constant ITEMS = 24;
    uint256 internal constant ACTIONS = 11;
    /// @dev Replayed sequences in `test_EveryTransitionIsReached`.
    uint256 internal constant RUNS = 24;
    uint256 internal constant DEPTH = 96;

    PortedSaleAdapter internal adapter;
    address internal artist;
    address internal collector = makeAddr("statesCollector");
    address internal other = makeAddr("statesOther");
    address internal bidder = makeAddr("statesBidder");
    bytes32 internal root;
    uint256 internal nextItem;

    mapping(uint256 tokenId => address) internal minterOf;
    mapping(uint256 tokenId => uint256) internal englishSale;
    mapping(uint256 tokenId => S) internal seen;
    mapping(uint256 tokenId => Outcome) internal outcomeSeen;
    mapping(address minter => M) internal minterSeen;
    mapping(bytes32 transition => uint256) internal hits;
    uint256 internal violations;
    string internal firstViolation;

    function setUp() public override {
        super.setUp();
        artist = _actor("statesArtist");
        adapter = new PortedSaleAdapter(KIND, registry);
        Work[] memory works = new Work[](ITEMS);
        for (uint256 i; i < ITEMS; ++i) {
            works[i] = _work(artist, collectionId);
            // Even items sell through the second minter, odd ones through the English auction.
            if (i % 2 == 0) works[i].item.sale = SaleTerms(KIND, CURRENCY_ETH, "");
        }
        root = _publish(works);
        _keep(root, works);
        vm.prank(network);
        stream.addMinter(address(adapter));
        vm.warp(stream.minterOf(address(adapter)).activeFrom);
        minterSeen[address(auction)] = M.ACTIVE;
        minterSeen[address(adapter)] = M.ACTIVE;
        vm.deal(bidder, 1000 ether);
        targetContract(address(this));
        targetSelector(FuzzSelector(address(this), _selectors()));
    }

    function _selectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](ACTIONS);
        s[0] = this.mint.selector;
        s[1] = this.bid.selector;
        s[2] = this.settle.selector;
        s[3] = this.burn.selector;
        s[4] = this.transferOut.selector;
        s[5] = this.transferBack.selector;
        s[6] = this.transferSettled.selector;
        s[7] = this.toggleMinter.selector;
        s[8] = this.unchangedMinter.selector;
        s[9] = this.rescue.selector;
        s[10] = this.warp.selector;
    }

    // ------------------------------------------------------------------------- actions

    /// @notice Mints the next item: through the second minter (even items) or the English
    ///         auction (odd). Refused while its minter is not active.
    function mint(uint256) external {
        if (nextItem < ITEMS) {
            uint256 index = nextItem;
            bytes memory data = _mintData(root, _package(root), index);
            uint256 before = stream.totalMinted();
            if (index % 2 == 0) {
                try adapter.start(address(stream), data) {
                    minterOf[before + 1] = address(adapter);
                    ++nextItem;
                } catch {
                    ++hits["mint refused"];
                }
            } else {
                try auction.start(address(stream), data) returns (uint256 saleId) {
                    minterOf[before + 1] = address(auction);
                    englishSale[before + 1] = saleId;
                    ++nextItem;
                } catch {
                    ++hits["mint refused"];
                }
            }
        }
        _observe();
    }

    /// @notice An ETH bid at the minimum on an English-auction work.
    function bid(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id != 0 && minterOf[id] == address(auction)) {
            uint256 saleId = englishSale[id];
            try auction.minimumBid(saleId) returns (uint256 amount) {
                vm.prank(bidder);
                try auction.bid{ value: amount }(saleId, address(0)) {
                    ++hits["bid"];
                } catch { }
            } catch { }
        }
        _observe();
    }

    /// @notice Settles a work: the English auction at its end, or the second minter with
    ///         either outcome. An accepted report lands in its own row's state.
    function settle(uint256 seed, bool sold) external {
        uint256 id = _pick(seed);
        if (id != 0 && minterOf[id] == address(auction)) {
            uint256 saleId = englishSale[id];
            IEnglishAuction.Auction memory a = auction.auction(saleId);
            if (block.timestamp < a.endTime) vm.warp(a.endTime);
            try auction.settle(saleId) { } catch { }
        } else if (id != 0) {
            try adapter.settleWith(address(stream), id, sold, sold ? collector : address(0)) {
                (, Outcome recorded) = _state(id);
                if (recorded != (sold ? Outcome.SOLD : Outcome.UNSOLD)) {
                    _violation("a settlement recorded another outcome");
                }
            } catch {
                ++hits["report refused"];
            }
        }
        _observe();
    }

    /// @notice The second minter burns a work (the English auction burns only after a dispute).
    function burn(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id != 0) {
            try adapter.burn(address(stream), id) { } catch { }
        }
        _observe();
    }

    /// @notice The second minter hands a work it holds to the collector, settled or not.
    function transferOut(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id != 0) {
            try adapter.deliver(address(stream), id, collector) { } catch { }
        }
        _observe();
    }

    /// @notice The collector gives an unsettled work back to the minter that minted it.
    function transferBack(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id != 0 && _holder(id) == collector && stream.workOf(id).outcome == Outcome.NONE) {
            vm.prank(collector);
            try stream.transferFrom(collector, minterOf[id], id) { } catch { }
        }
        _observe();
    }

    /// @notice A settled work's holder passes it on.
    function transferSettled(uint256 seed) external {
        uint256 id = _pick(seed);
        address holder = id == 0 ? address(0) : _holder(id);
        if (
            holder != address(0) && holder != address(adapter) && holder != address(auction)
                && stream.workOf(id).outcome != Outcome.NONE
        ) {
            address to = holder == other ? collector : other;
            vm.prank(holder);
            try stream.transferFrom(holder, to, id) { } catch { }
        }
        _observe();
    }

    /// @notice The network removes or adds one of the two minters (immediate; an added minter
    ///         waits out the module delay): a transition.
    function toggleMinter(uint256 seed) external {
        address which = seed % 2 == 0 ? address(adapter) : address(auction);
        M state = _minterState(which);
        vm.prank(network);
        if (state == M.REMOVED) stream.addMinter(which);
        else stream.removeMinter(which);
        _observe();
    }

    /// @notice The network tries a minter call that would change nothing (adding an added or
    ///         waiting minter, removing a removed or never-added one); Stream refuses it.
    function unchangedMinter(uint256 seed) external {
        address which =
            seed % 3 == 0 ? address(adapter) : seed % 3 == 1 ? address(auction) : address(registry);
        M state = _minterState(which);
        bool add = state == M.WAITING || state == M.ACTIVE;
        vm.prank(network);
        (bool ok,) = address(stream)
            .call(
                add
                    ? abi.encodeCall(stream.addMinter, (which))
                    : abi.encodeCall(stream.removeMinter, (which))
            );
        if (ok) _violation("a minter call that changes nothing went through");
        else ++hits["no-op refused"];
        _observe();
    }

    /// @notice The network rescues a work to the museum; refused unless a removed minter holds
    ///         it unsold past the rescue delay. A rescue that goes through lands in RESCUED.
    function rescue(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id != 0) {
            vm.prank(network);
            try stream.rescue(id, museum) {
                (S rescued,) = _state(id);
                if (rescued != S.RESCUED) _violation("a rescue did not record RESCUED");
                if (_holder(id) != museum) _violation("a rescue did not reach the museum");
            } catch { }
        }
        _observe();
    }

    function warp(uint256 seed) external {
        vm.warp(block.timestamp + 1 hours + seed % 100 days);
        _observe();
    }

    // -------------------------------------------------------------------- observation

    function _pick(uint256 seed) internal view returns (uint256) {
        uint256 minted = stream.totalMinted();
        return minted == 0 ? 0 : 1 + seed % minted;
    }

    function _holder(uint256 id) internal view returns (address) {
        try stream.ownerOf(id) returns (address h) {
            return h;
        } catch {
            return address(0);
        }
    }

    /// @dev The work state of `id`, from what Stream stores.
    function _state(uint256 id) internal view returns (S, Outcome outcome) {
        if (id > stream.totalMinted()) return (S.NEVER_MINTED, Outcome.NONE);
        outcome = stream.workOf(id).outcome;
        address holder = _holder(id);
        if (outcome != Outcome.NONE && holder == address(0)) {
            return (S.OUTCOME_WITHOUT_TOKEN, outcome);
        }
        if (outcome == Outcome.SOLD) return (S.SOLD, outcome);
        if (outcome == Outcome.UNSOLD) return (S.UNSOLD, outcome);
        if (outcome == Outcome.RESCUED) return (S.RESCUED, outcome);
        if (holder == address(0)) return (S.CANCELLED, outcome);
        return (holder == minterOf[id] ? S.IN_SALE : S.OUT_OF_CUSTODY, outcome);
    }

    function _allowed(S a, S b) internal pure returns (bool) {
        if (b == S.OUTCOME_WITHOUT_TOKEN) return false;
        if (a == b) return true;
        if (a == S.NEVER_MINTED) return b == S.IN_SALE;
        if (a == S.IN_SALE) {
            return b == S.OUT_OF_CUSTODY || b == S.CANCELLED || b == S.SOLD || b == S.UNSOLD
                || b == S.RESCUED;
        }
        if (a == S.OUT_OF_CUSTODY) return b == S.IN_SALE;
        return false;
    }

    function _allowedMinter(M a, M b) internal pure returns (bool) {
        if (a == b) return true;
        if (a == M.NEVER_ADDED) return b == M.WAITING;
        if (a == M.WAITING) return b == M.ACTIVE || b == M.REMOVED;
        if (a == M.ACTIVE) return b == M.REMOVED;
        return b == M.WAITING;
    }

    function _minterState(address which) internal view returns (M) {
        (uint48 activeFrom, uint48 removedAt) =
            (stream.minterOf(which).activeFrom, stream.minterOf(which).removedAt);
        if (activeFrom == 0) return M.NEVER_ADDED;
        if (removedAt != 0) return M.REMOVED;
        return block.timestamp >= activeFrom ? M.ACTIVE : M.WAITING;
    }

    function _observe() internal {
        uint256 last = stream.totalMinted() + 1;
        for (uint256 id = 1; id <= last; ++id) {
            (S now_, Outcome outcome) = _state(id);
            S before = seen[id];
            if (!_allowed(before, now_)) {
                _violation(string.concat("work transition outside the table: ", _key(before, now_)));
            }
            Outcome recorded = outcomeSeen[id];
            if (recorded != Outcome.NONE && outcome != recorded) {
                _violation("a recorded outcome changed");
            }
            if (before != now_) {
                ++hits[keccak256(bytes(_key(before, now_)))];
                seen[id] = now_;
            }
            outcomeSeen[id] = outcome;
        }
        address[2] memory minters = [address(adapter), address(auction)];
        for (uint256 i; i < 2; ++i) {
            M now_ = _minterState(minters[i]);
            M before = minterSeen[minters[i]];
            if (!_allowedMinter(before, now_)) _violation("minter transition outside the table");
            if (before != now_) ++hits[keccak256(abi.encode("minter", before, now_))];
            minterSeen[minters[i]] = now_;
        }
    }

    function _violation(string memory what) internal {
        if (violations++ == 0) firstViolation = what;
    }

    function _key(S a, S b) internal pure returns (string memory) {
        return string.concat(_name(a), ">", _name(b));
    }

    function _name(S s) internal pure returns (string memory) {
        string[8] memory names = [
            "NEVER_MINTED",
            "IN_SALE",
            "OUT_OF_CUSTODY",
            "CANCELLED",
            "SOLD",
            "UNSOLD",
            "RESCUED",
            "OUTCOME_WITHOUT_TOKEN"
        ];
        return names[uint8(s)];
    }

    // ------------------------------------------------------------------------ the checks

    /// @notice Every work and minter transition observed in the campaign is in the tables, and
    ///         no recorded outcome changed.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_streamStatesFollowTheTables() public view {
        assertEq(violations, 0, firstViolation);
    }

    /// @notice The campaign is not vacuous: random sequences of its shape, replayed from fixed
    ///         seeds, reach every transition of both tables and the refusals, with no violation.
    function test_EveryTransitionIsReached() public {
        string[7] memory transitions = [
            "NEVER_MINTED>IN_SALE",
            "IN_SALE>OUT_OF_CUSTODY",
            "IN_SALE>CANCELLED",
            "IN_SALE>SOLD",
            "IN_SALE>UNSOLD",
            "IN_SALE>RESCUED",
            "OUT_OF_CUSTODY>IN_SALE"
        ];
        uint256[7] memory totals;
        uint256[4] memory minterTotals;
        uint256 refusedReports;
        uint256 refusedNoOps;
        uint256 acceptedBids;
        for (uint256 run; run < RUNS; ++run) {
            uint256 snapshot = vm.snapshotState();
            for (uint256 depth; depth < DEPTH; ++depth) {
                _step(uint256(keccak256(abi.encode(run, depth))));
            }
            assertEq(violations, 0, firstViolation);
            for (uint256 i; i < 7; ++i) {
                totals[i] += hits[keccak256(bytes(transitions[i]))];
            }
            minterTotals[0] += hits[keccak256(abi.encode("minter", M.ACTIVE, M.REMOVED))];
            minterTotals[1] += hits[keccak256(abi.encode("minter", M.REMOVED, M.WAITING))];
            minterTotals[2] += hits[keccak256(abi.encode("minter", M.WAITING, M.ACTIVE))];
            minterTotals[3] += hits[keccak256(abi.encode("minter", M.WAITING, M.REMOVED))];
            refusedReports += hits["report refused"];
            refusedNoOps += hits["no-op refused"];
            acceptedBids += hits["bid"];
            vm.revertToStateAndDelete(snapshot);
        }
        for (uint256 i; i < 7; ++i) {
            console2.log(transitions[i], totals[i]);
            assertGt(totals[i], 0, transitions[i]);
        }
        string[4] memory minterNames =
            ["ACTIVE>REMOVED", "REMOVED>WAITING", "WAITING>ACTIVE", "WAITING>REMOVED"];
        for (uint256 i; i < 4; ++i) {
            console2.log(minterNames[i], minterTotals[i]);
            assertGt(minterTotals[i], 0, minterNames[i]);
        }
        console2.log("reports refused", refusedReports);
        console2.log("no-op minter calls refused", refusedNoOps);
        console2.log("bids accepted", acceptedBids);
        assertGt(refusedReports, 0, "report refused");
        assertGt(refusedNoOps, 0, "no-op refused");
        assertGt(acceptedBids, 0, "bid accepted");
    }

    /// @notice A work handed out of custody unsettled can no longer be reported by its minter,
    ///         and a removed minter's holder cannot rescue it: only its return to the minter
    ///         makes it settleable again.
    function test_OutOfCustody_OnlyReturnsToTheMinter() public {
        this.mint(0); // item 0: the second minter
        adapter.deliver(address(stream), 1, collector);
        vm.expectRevert();
        adapter.settleWith(address(stream), 1, true, collector);
        vm.prank(network);
        stream.removeMinter(address(adapter));
        vm.warp(block.timestamp + stream.rescueDelay());
        vm.prank(network);
        vm.expectRevert();
        stream.rescue(1, museum);
        vm.prank(collector);
        stream.transferFrom(collector, address(adapter), 1);
        adapter.settleWith(address(stream), 1, true, collector);
        assertEq(uint8(stream.workOf(1).outcome), uint8(Outcome.SOLD));
        _observe();
        assertEq(violations, 0, firstViolation);
    }

    /// @dev One random action, weighted toward the ones that move works.
    function _step(uint256 r) internal {
        uint256 pick = r % 20;
        uint256 seed = r >> 8;
        if (pick < 4) this.mint(seed);
        else if (pick < 6) this.bid(seed);
        else if (pick < 10) this.settle(seed, (seed >> 16) % 2 == 0);
        else if (pick < 11) this.burn(seed);
        else if (pick < 13) this.transferOut(seed);
        else if (pick < 14) this.transferBack(seed);
        else if (pick < 15) this.transferSettled(seed);
        else if (pick < 16) this.toggleMinter(seed);
        else if (pick < 17) this.unchangedMinter(seed);
        else if (pick < 19) this.rescue(seed);
        else this.warp(seed);
    }
}
