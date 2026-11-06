// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { SaleTerms } from "src/interfaces/types/PackageTypes.sol";
import { Payment, PaymentMethod, PrimaryOutcome } from "src/interfaces/types/SaleTypes.sol";
import { MockSaleAdapter } from "../../mocks/stream/StreamMocks.sol";
import { IntegrationBase } from "../IntegrationBase.sol";

/// @notice Owner decision 28: 6529 Stream's work lifecycle and sale-method lifecycle are the
///         tables in `docs/spec/stream-and-auctions.md` ("A work's lifecycle", "A sale
///         method's lifecycle"), and nothing moves a work or an adapter outside them.
///
///         On the real stack (`DeployV1` with the committed genesis), random sequences of calls
///         mint works through the English auction and a second admitted sale adapter, bid,
///         settle with every outcome (and try the ones an adapter may not report), burn,
///         transfer works out of and back into custody and between holders, remove and admit
///         both adapters through governance (and try transitions that change nothing), warp
///         time and rescue works. After every call the suite reads each work's state from what
///         Stream stores and checks:
///         1. every observed (before, after) pair of work states is a row of the table (or no
///            change);
///         2. a recorded outcome never changes;
///         3. every observed adapter transition is a row of the sale-method table, and a call
///            that would change nothing is refused.
contract StreamStatesInvariantTest is IntegrationBase {
    /// @dev The work states of the spec's table.
    enum S {
        NEVER_MINTED,
        IN_SALE,
        OUT_OF_CUSTODY,
        CANCELLED,
        SOLD,
        UNBID,
        FROZEN_OUT,
        RESCUED,
        /// @dev Not a state of the table: a recorded outcome on a token that no longer exists.
        OUTCOME_WITHOUT_TOKEN
    }

    /// @dev The sale-method states (rescue eligibility is the removed state plus time).
    enum A {
        NEVER_ADMITTED,
        ADMITTED,
        REMOVED
    }

    bytes32 internal constant KIND = keccak256("STATES_TEST_1OF1");
    uint256 internal constant ITEMS = 24;
    uint256 internal constant ACTIONS = 11;
    /// @dev Replayed sequences in `test_EveryTransitionIsReached`.
    uint256 internal constant RUNS = 24;
    uint256 internal constant DEPTH = 96;

    MockSaleAdapter internal adapter;
    address internal artist;
    address internal collector = makeAddr("statesCollector");
    address internal other = makeAddr("statesOther");
    address internal bidder = makeAddr("statesBidder");
    bytes32 internal root;
    uint256 internal nextItem;

    mapping(uint256 tokenId => address) internal minterOf;
    mapping(uint256 tokenId => uint256) internal englishSale;
    mapping(uint256 tokenId => S) internal seen;
    mapping(uint256 tokenId => PrimaryOutcome) internal outcomeSeen;
    mapping(address adapter => A) internal adapterSeen;
    mapping(bytes32 transition => uint256) internal hits;
    uint256 internal violations;
    string internal firstViolation;

    function setUp() public override {
        super.setUp();
        artist = _actor("statesArtist");
        adapter = new MockSaleAdapter(KIND);
        Work[] memory works = new Work[](ITEMS);
        for (uint256 i; i < ITEMS; ++i) {
            works[i] = _work(artist, collectionId);
            // Even items sell through the second adapter, odd ones through the English auction.
            if (i % 2 == 0) works[i].item.sale = SaleTerms(KIND, CURRENCY_ETH, "");
        }
        root = _publish(works);
        _keep(root, works);
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.setAdmittedMinter, (address(adapter), true))
        );
        adapterSeen[address(auction)] = A.ADMITTED;
        adapterSeen[address(adapter)] = A.ADMITTED;
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
        s[7] = this.toggleAdmission.selector;
        s[8] = this.unchangedAdmission.selector;
        s[9] = this.rescue.selector;
        s[10] = this.warp.selector;
    }

    // ------------------------------------------------------------------------- actions

    /// @notice Mints the next item: through the second adapter (even items) or the English
    ///         auction (odd). Refused while its adapter is removed.
    function mint(uint256) external {
        if (nextItem < ITEMS) {
            uint256 index = nextItem;
            bytes memory data = _mintData(root, _package(root), index);
            uint256 before = stream.totalMinted();
            if (index % 2 == 0) {
                try adapter.start(stream, data) {
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
                try auction.bid{ value: amount }(
                    saleId, address(0), Payment(PaymentMethod.DIRECT, bidder, amount, 0, 0, "")
                ) {
                    ++hits["bid"];
                } catch { }
            } catch { }
        }
        _observe();
    }

    /// @notice Settles a work: the English auction at its end, or the second adapter with any
    ///         outcome, NONE and RESCUED included (which Stream refuses).
    function settle(uint256 seed, uint8 outcomeSeed) external {
        uint256 id = _pick(seed);
        if (id != 0 && minterOf[id] == address(auction)) {
            uint256 saleId = englishSale[id];
            try auction.auction(saleId) returns (IEnglishAuction.Auction memory a) {
                if (block.timestamp < a.endTime) vm.warp(a.endTime);
            } catch { }
            try auction.settle(saleId) { } catch { }
        } else if (id != 0) {
            PrimaryOutcome outcome = PrimaryOutcome(outcomeSeed % 5);
            bool sold = outcome == PrimaryOutcome.SOLD;
            try adapter.settleWith(
                stream, id, outcome, sold ? collector : address(0), CURRENCY_ETH, sold ? 1 : 0
            ) {
                if (outcome == PrimaryOutcome.NONE || outcome == PrimaryOutcome.RESCUED) {
                    _violation("an adapter reported NONE or RESCUED");
                }
            } catch {
                if (outcome == PrimaryOutcome.RESCUED) ++hits["RESCUED report refused"];
            }
        }
        _observe();
    }

    /// @notice The second adapter burns a work (the English auction burns only after a dispute).
    function burn(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id != 0) {
            try adapter.burn(stream, id, 1) { } catch { }
        }
        _observe();
    }

    /// @notice The second adapter hands a work it holds to the collector, settled or not.
    function transferOut(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id != 0) {
            try adapter.deliver(address(stream), id, collector) { } catch { }
        }
        _observe();
    }

    /// @notice The collector gives an unsettled work back to the adapter that minted it.
    function transferBack(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id != 0 && _holder(id) == collector && !stream.primarySaleSettled(id)) {
            vm.prank(collector);
            try stream.transferFrom(collector, minterOf[id], id) { } catch { }
        }
        _observe();
    }

    /// @notice A settled work's holder (the museum, the collector or another account) passes it
    ///         on.
    function transferSettled(uint256 seed) external {
        uint256 id = _pick(seed);
        address holder = id == 0 ? address(0) : _holder(id);
        if (
            holder != address(0) && holder != address(adapter) && holder != address(auction)
                && stream.primarySaleSettled(id)
        ) {
            address to = holder == other ? collector : other;
            vm.prank(holder);
            try stream.transferFrom(holder, to, id) { } catch { }
        }
        _observe();
    }

    /// @notice Governance removes or admits one of the two adapters (30 days): a transition.
    function toggleAdmission(uint256 seed) external {
        address which = seed % 2 == 0 ? address(adapter) : address(auction);
        bool admitted = stream.isAdmittedMinter(which);
        _govern(
            hotAdmin, address(stream), abi.encodeCall(stream.setAdmittedMinter, (which, !admitted))
        );
        _observe();
    }

    /// @notice Governance tries a transition that would change nothing; Stream refuses it.
    function unchangedAdmission(uint256 seed) external {
        address which = seed % 3 == 0
            ? address(adapter)
            : seed % 3 == 1 ? address(auction) : makeAddr("statesNeverAdmitted");
        bool admitted = stream.isAdmittedMinter(which);
        bool ok = _governTry(
            hotAdmin, address(stream), abi.encodeCall(stream.setAdmittedMinter, (which, admitted))
        );
        if (ok) _violation("a transition that changes nothing went through");
        else ++hits["no-op refused"];
        _observe();
    }

    /// @notice Governance rescues a work (30 days); refused unless it is stranded.
    function rescue(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id != 0) {
            _governTry(hotAdmin, address(stream), abi.encodeCall(stream.rescueToMuseum, (id)));
        }
        _observe();
    }

    function warp(uint256 seed) external {
        vm.warp(block.timestamp + 1 hours + seed % 100 days);
        _observe();
    }

    // -------------------------------------------------------------------- observation

    /// @dev A minted token ID from `seed`, or zero when none is minted.
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

    /// @dev The work state of `id` per the spec's table, from what Stream stores.
    function _state(uint256 id) internal view returns (S, PrimaryOutcome outcome) {
        if (id > stream.totalMinted()) return (S.NEVER_MINTED, PrimaryOutcome.NONE);
        (outcome,,) = stream.primarySale(id);
        address holder = _holder(id);
        // Every settled state has a holder; only a cancelled work has none.
        if (outcome != PrimaryOutcome.NONE && holder == address(0)) {
            return (S.OUTCOME_WITHOUT_TOKEN, outcome);
        }
        if (outcome == PrimaryOutcome.SOLD) return (S.SOLD, outcome);
        if (outcome == PrimaryOutcome.UNBID) return (S.UNBID, outcome);
        if (outcome == PrimaryOutcome.FROZEN_OUT) return (S.FROZEN_OUT, outcome);
        if (outcome == PrimaryOutcome.RESCUED) return (S.RESCUED, outcome);
        if (holder == address(0)) return (S.CANCELLED, outcome);
        return (holder == minterOf[id] ? S.IN_SALE : S.OUT_OF_CUSTODY, outcome);
    }

    /// @dev The table's rows, and no change.
    function _allowed(S a, S b) internal pure returns (bool) {
        if (b == S.OUTCOME_WITHOUT_TOKEN) return false;
        if (a == b) return true;
        if (a == S.NEVER_MINTED) return b == S.IN_SALE;
        if (a == S.IN_SALE) {
            return b == S.OUT_OF_CUSTODY || b == S.CANCELLED || b == S.SOLD || b == S.UNBID
                || b == S.FROZEN_OUT || b == S.RESCUED;
        }
        if (a == S.OUT_OF_CUSTODY) return b == S.IN_SALE || b == S.SOLD;
        return false; // cancelled and every outcome are final
    }

    function _allowedAdapter(A a, A b) internal pure returns (bool) {
        if (a == b) return true;
        if (a == A.NEVER_ADMITTED) return b == A.ADMITTED;
        if (a == A.ADMITTED) return b == A.REMOVED;
        return b == A.ADMITTED; // removed (and rescue-eligible) to admitted
    }

    function _adapterState(address which) internal view returns (A) {
        if (stream.isAdmittedMinter(which)) return A.ADMITTED;
        return adapterSeen[which] == A.NEVER_ADMITTED ? A.NEVER_ADMITTED : A.REMOVED;
    }

    /// @dev Reads every work and both adapters, checks each change against the tables and
    ///      records the new states.
    function _observe() internal {
        uint256 last = stream.totalMinted() + 1;
        for (uint256 id = 1; id <= last; ++id) {
            (S now_, PrimaryOutcome outcome) = _state(id);
            S before = seen[id];
            if (!_allowed(before, now_)) {
                _violation(string.concat("work transition outside the table: ", _key(before, now_)));
            }
            PrimaryOutcome recorded = outcomeSeen[id];
            if (recorded != PrimaryOutcome.NONE && outcome != recorded) {
                _violation("a recorded outcome changed");
            }
            if (before != now_) {
                ++hits[keccak256(bytes(_key(before, now_)))];
                seen[id] = now_;
            }
            outcomeSeen[id] = outcome;
        }
        address[2] memory adapters = [address(adapter), address(auction)];
        for (uint256 i; i < 2; ++i) {
            A now_ = _adapterState(adapters[i]);
            if (!_allowedAdapter(adapterSeen[adapters[i]], now_)) {
                _violation("adapter transition outside the table");
            }
            adapterSeen[adapters[i]] = now_;
        }
    }

    function _violation(string memory what) internal {
        if (violations++ == 0) firstViolation = what;
    }

    function _key(S a, S b) internal pure returns (string memory) {
        return string.concat(_name(a), ">", _name(b));
    }

    function _name(S s) internal pure returns (string memory) {
        string[9] memory names = [
            "NEVER_MINTED",
            "IN_SALE",
            "OUT_OF_CUSTODY",
            "CANCELLED",
            "SOLD",
            "UNBID",
            "FROZEN_OUT",
            "RESCUED",
            "OUTCOME_WITHOUT_TOKEN"
        ];
        return names[uint8(s)];
    }

    // ------------------------------------------------------------------------ the checks

    /// @notice Every work and adapter transition observed in the campaign is in the tables, and
    ///         no recorded outcome changed.
    function invariant_streamStatesFollowTheTables() public view {
        assertEq(violations, 0, firstViolation);
    }

    /// @notice The campaign is not vacuous: random sequences of its shape, replayed from fixed
    ///         seeds, reach every transition of the work table and the refusals, with no
    ///         violation.
    function test_EveryTransitionIsReached() public {
        string[9] memory transitions = [
            "NEVER_MINTED>IN_SALE",
            "IN_SALE>OUT_OF_CUSTODY",
            "IN_SALE>CANCELLED",
            "IN_SALE>SOLD",
            "IN_SALE>UNBID",
            "IN_SALE>FROZEN_OUT",
            "IN_SALE>RESCUED",
            "OUT_OF_CUSTODY>IN_SALE",
            "OUT_OF_CUSTODY>SOLD"
        ];
        uint256[9] memory totals;
        uint256 refusedRescued;
        uint256 refusedNoOps;
        for (uint256 run; run < RUNS; ++run) {
            uint256 snapshot = vm.snapshotState();
            for (uint256 depth; depth < DEPTH; ++depth) {
                _step(uint256(keccak256(abi.encode(run, depth))));
            }
            assertEq(violations, 0, firstViolation);
            for (uint256 i; i < transitions.length; ++i) {
                totals[i] += hits[keccak256(bytes(transitions[i]))];
            }
            refusedRescued += hits["RESCUED report refused"];
            refusedNoOps += hits["no-op refused"];
            vm.revertToStateAndDelete(snapshot);
        }
        for (uint256 i; i < transitions.length; ++i) {
            console2.log(transitions[i], totals[i]);
            assertGt(totals[i], 0, transitions[i]);
        }
        console2.log("RESCUED reports refused", refusedRescued);
        console2.log("no-op admissions refused", refusedNoOps);
        assertGt(refusedRescued, 0, "RESCUED report refused");
        assertGt(refusedNoOps, 0, "no-op admission refused");
    }

    /// @dev One random action, weighted toward the ones that move works.
    function _step(uint256 r) internal {
        uint256 pick = r % 20;
        uint256 seed = r >> 8;
        if (pick < 4) this.mint(seed);
        else if (pick < 6) this.bid(seed);
        else if (pick < 10) this.settle(seed, uint8(seed >> 16));
        else if (pick < 11) this.burn(seed);
        else if (pick < 13) this.transferOut(seed);
        else if (pick < 14) this.transferBack(seed);
        else if (pick < 15) this.transferSettled(seed);
        else if (pick < 16) this.toggleAdmission(seed);
        else if (pick < 17) this.unchangedAdmission(seed);
        else if (pick < 19) this.rescue(seed);
        else this.warp(seed);
    }
}
