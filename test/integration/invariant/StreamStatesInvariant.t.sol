// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { MintFacts, Minter, Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IModules } from "src/interfaces/core/IModules.sol";
import { MockSale } from "../../mocks/core/CoreMocks.sol";
import { IntegrationBase } from "../IntegrationBase.sol";

/// @notice 6529 Stream's work lifecycle and minter lifecycle on the plain core: nothing moves a
///         work or a minter outside the tables below.
///
///         On the plain-core stack (`DeployCore` with the committed genesis), random sequences
///         of calls mint works through the English auction (admitted by the package registry)
///         and a second minter the network adds, bid, settle with both outcomes, report again
///         (refused), burn, transfer works out of and back into custody and between holders,
///         remove and add both minters (and try changes that change nothing), change the
///         network's module and rescue delays, warp time and rescue works. After every call the
///         suite reads each work's state from what Stream stores and checks:
///         1. every observed (before, after) pair of work states is a row of the work table (or
///            no change): NEVER_MINTED to IN_SALE; IN_SALE to OUT_OF_CUSTODY, CANCELLED, SOLD,
///            UNSOLD or RESCUED; OUT_OF_CUSTODY back to IN_SALE; the rest are final;
///         2. a recorded outcome never changes;
///         3. every observed minter transition is a row of the minter table: never added to
///            pending or active; pending to active or removed; active to removed; removed to
///            pending or active; and a change that would change nothing is refused;
///         4. an added minter is active from the time it was given (the module delay in force
///            when it was added), whatever the module delay becomes;
///         5. every report, burn and rescue goes through exactly when the seam allows it: a
///            minter (active or removed) holding the token with no outcome reports once or
///            burns; the network rescues only a token a removed minter holds unsold, once the
///            rescue delay as it stands has passed since the removal.
contract StreamStatesInvariantTest is IntegrationBase {
    /// @dev The work states of the table.
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

    /// @dev The minter states (`IModules.minterOf`).
    enum A {
        NEVER_ADDED,
        PENDING,
        ACTIVE,
        REMOVED
    }

    uint256 internal constant ITEMS = 24;
    uint256 internal constant ACTIONS = 12;
    /// @dev Replayed sequences in `test_EveryTransitionIsReached`.
    uint256 internal constant RUNS = 24;
    uint256 internal constant DEPTH = 96;

    MockSale internal adapter;
    address internal artist;
    address internal collector = makeAddr("statesCollector");
    address internal other = makeAddr("statesOther");
    address internal bidder = makeAddr("statesBidder");
    address internal neverAdded = makeAddr("statesNeverAdded");
    bytes32 internal root;
    uint256 internal nextItem;
    uint256 internal englishMinted;

    mapping(uint256 tokenId => address) internal minterOfToken;
    mapping(uint256 tokenId => uint256) internal englishSale;
    mapping(uint256 tokenId => S) internal seen;
    mapping(uint256 tokenId => Outcome) internal outcomeSeen;
    mapping(address minter => A) internal minterSeen;
    /// @dev The activation time each pending minter was given when it was added.
    mapping(address minter => uint256) internal givenActiveFrom;
    mapping(bytes32 transition => uint256) internal hits;
    uint256 internal violations;
    string internal firstViolation;

    function setUp() public override {
        super.setUp();
        artist = _actor("statesArtist");
        adapter = new MockSale();
        // The English auction's items: odd items are sold there, through the package registry.
        Work[] memory works = new Work[](ITEMS / 2);
        for (uint256 i; i < works.length; ++i) {
            works[i] = _work(artist, collectionId);
        }
        root = _publish(works);
        _keep(root, works);
        // The network adds the second minter; it is active once the module delay has passed.
        _asNetwork(address(stream), abi.encodeCall(stream.addMinter, (address(adapter))));
        givenActiveFrom[address(adapter)] = block.timestamp + stream.moduleDelay();
        vm.warp(block.timestamp + stream.moduleDelay());
        minterSeen[address(auction)] = A.ACTIVE;
        minterSeen[address(adapter)] = A.ACTIVE;
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
        s[10] = this.setDelay.selector;
        s[11] = this.warp.selector;
    }

    // ------------------------------------------------------------------------- actions

    /// @notice Mints the next item: through the second minter (even items) or the English
    ///         auction (odd). Goes through exactly while that minter is active.
    function mint(uint256) external {
        if (nextItem < ITEMS) {
            uint256 index = nextItem;
            uint256 tokenId = stream.totalMinted() + 1;
            bool ok;
            if (index % 2 == 0) {
                try adapter.mint(address(stream), _facts(index)) {
                    ok = true;
                } catch { }
                if (ok != stream.isMinter(address(adapter))) {
                    _violation("a mint by the second minter");
                }
                if (ok) minterOfToken[tokenId] = address(adapter);
            } else {
                bool active = stream.isMinter(address(auction));
                bytes memory data = _mintData(root, _package(root), englishMinted);
                try auction.start(address(stream), data) returns (uint256 saleId) {
                    ok = true;
                    englishSale[tokenId] = saleId;
                    minterOfToken[tokenId] = address(auction);
                    ++englishMinted;
                } catch { }
                if (ok != active) _violation("a start through the English auction");
            }
            if (ok) ++nextItem;
            else ++hits["mint refused"];
        }
        _observe();
    }

    /// @notice An ETH bid at the minimum on an English-auction work.
    function bid(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id != 0 && minterOfToken[id] == address(auction)) {
            uint256 saleId = englishSale[id];
            uint256 amount = auction.minimumBid(saleId);
            vm.prank(bidder);
            try auction.bid{ value: amount }(saleId, address(0)) {
                ++hits["bid"];
            } catch { }
        }
        _observe();
    }

    /// @notice Settles a work: the English auction at its end, or the second minter with either
    ///         outcome (again on a work that already has one, or one it does not hold: refused).
    function settle(uint256 seed, uint8 outcomeSeed) external {
        uint256 id = _pick(seed);
        if (id != 0 && minterOfToken[id] == address(auction)) {
            IEnglishAuction.Auction memory a = auction.auction(englishSale[id]);
            if (block.timestamp < a.endTime) vm.warp(a.endTime);
            try auction.settle(englishSale[id]) { } catch { }
        } else if (id != 0) {
            bool sold = outcomeSeed % 2 == 0;
            bool allowed = _seamAllows(address(adapter), id);
            bool ok;
            try adapter.record(address(stream), id, sold, sold ? collector : address(0), 1) {
                ok = true;
            } catch { }
            if (ok != allowed) _violation("a report the seam does not allow, or a refused one");
            if (ok) {
                if (stream.workOf(id).outcome != (sold ? Outcome.SOLD : Outcome.UNSOLD)) {
                    _violation("a report recorded another outcome");
                }
            } else {
                ++hits["report refused"];
            }
        }
        _observe();
    }

    /// @notice The second minter burns a work (the English auction burns only after a dispute).
    function burn(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id != 0) {
            bool allowed = _seamAllows(address(adapter), id);
            bool ok;
            try adapter.burn(address(stream), id) {
                ok = true;
            } catch { }
            if (ok != allowed) _violation("a burn the seam does not allow, or a refused one");
        }
        _observe();
    }

    /// @notice The second minter hands a work it holds to the collector, settled or not.
    function transferOut(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id != 0 && _holder(id) == address(adapter)) {
            adapter.send(address(stream), id, collector);
        }
        _observe();
    }

    /// @notice The collector gives an unsettled work back to the minter that minted it.
    function transferBack(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id != 0 && _holder(id) == collector && stream.workOf(id).outcome == Outcome.NONE) {
            vm.prank(collector);
            stream.transferFrom(collector, minterOfToken[id], id);
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
                && stream.workOf(id).outcome != Outcome.NONE
        ) {
            address to = holder == other ? collector : other;
            vm.prank(holder);
            stream.transferFrom(holder, to, id);
        }
        _observe();
    }

    /// @notice The network removes a minter (at once) or adds it (it waits the module delay).
    function toggleAdmission(uint256 seed) external {
        address which = seed % 2 == 0 ? address(adapter) : address(auction);
        if (_added(which)) {
            _asNetwork(address(stream), abi.encodeCall(stream.removeMinter, (which)));
        } else {
            _asNetwork(address(stream), abi.encodeCall(stream.addMinter, (which)));
            givenActiveFrom[which] = block.timestamp + stream.moduleDelay();
        }
        _observe();
    }

    /// @notice The network tries a change that would change nothing: adding a minter already
    ///         added, or removing one that is not; Stream refuses it with the exact error.
    function unchangedAdmission(uint256 seed) external {
        address which =
            seed % 3 == 0 ? address(adapter) : seed % 3 == 1 ? address(auction) : neverAdded;
        bytes memory call;
        bytes memory expected;
        if (_added(which)) {
            call = abi.encodeCall(stream.addMinter, (which));
            expected = abi.encodeWithSelector(IModules.MinterAlreadyAdded.selector, which);
        } else {
            call = abi.encodeCall(stream.removeMinter, (which));
            expected = abi.encodeWithSelector(IModules.NotMinter.selector, which);
        }
        vm.prank(network);
        (bool ok, bytes memory reason) = address(stream).call(call);
        if (ok) _violation("a minter change that changes nothing went through");
        else if (keccak256(reason) != keccak256(expected)) _violation("a no-op refused oddly");
        else ++hits["no-op refused"];
        _observe();
    }

    /// @notice The network rescues a work to the museum: it goes through exactly when the token
    ///         is live, unsold and held by a minter removed at least `rescueDelay` (as it stands
    ///         now) ago, and then lands in the rescued state.
    function rescue(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id != 0) {
            address holder = _holder(id);
            uint256 removedAt = holder == address(0) ? 0 : stream.minterOf(holder).removedAt;
            bool allowed = holder != address(0) && stream.workOf(id).outcome == Outcome.NONE
                && removedAt != 0 && block.timestamp >= removedAt + stream.rescueDelay();
            vm.prank(network);
            (bool ok,) = address(stream).call(abi.encodeCall(stream.rescue, (id, museum)));
            if (ok != allowed) _violation("a rescue the rules refuse, or a refused due rescue");
            if (ok) {
                if (stream.workOf(id).outcome != Outcome.RESCUED) {
                    _violation("a rescue did not record RESCUED");
                }
                if (_holder(id) != museum) _violation("a rescue did not reach the museum");
            } else {
                ++hits["rescue refused"];
            }
        }
        _observe();
    }

    /// @notice The network changes the module delay or the rescue delay, at once (zero allowed).
    function setDelay(uint256 seed) external {
        uint48[4] memory values = [uint48(0), 1 days, 14 days, 30 days];
        uint48 value = values[(seed >> 1) % 4];
        if (seed % 2 == 0) {
            _asNetwork(address(stream), abi.encodeCall(stream.setModuleDelay, (value)));
        } else {
            _asNetwork(address(stream), abi.encodeCall(stream.setRescueDelay, (value)));
        }
        _observe();
    }

    function warp(uint256 seed) external {
        vm.warp(block.timestamp + 1 hours + seed % 20 days);
        _observe();
    }

    // -------------------------------------------------------------------- observation

    /// @dev The second minter's facts for item `index`: its own content, the artist, the genesis
    ///      collection, no royalty.
    function _facts(uint256 index) internal view returns (MintFacts memory f) {
        f.itemHash = keccak256(abi.encode("states item", index));
        f.contentHash = keccak256(abi.encode("states content", index));
        f.artistId = uint160(artist);
        f.collectionId = collectionId;
    }

    /// @dev Whether the seam lets `minter` report or burn `id` now: it holds the token, it is or
    ///      was an active minter, and no outcome is recorded.
    function _seamAllows(address minter, uint256 id) internal view returns (bool) {
        Minter memory m = stream.minterOf(minter);
        bool wasActive = m.removedAt != 0 || (m.activeFrom != 0 && block.timestamp >= m.activeFrom);
        return _holder(id) == minter && wasActive && stream.workOf(id).outcome == Outcome.NONE;
    }

    /// @dev Added and not removed (active, or pending activation).
    function _added(address which) internal view returns (bool) {
        Minter memory m = stream.minterOf(which);
        return m.activeFrom != 0 && m.removedAt == 0;
    }

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

    /// @dev The work state of `id` per the table, from what Stream stores.
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
        bool custody = holder == address(adapter) || holder == address(auction);
        return (custody ? S.IN_SALE : S.OUT_OF_CUSTODY, outcome);
    }

    /// @dev The work table's rows, and no change.
    function _allowed(S a, S b) internal pure returns (bool) {
        if (b == S.OUTCOME_WITHOUT_TOKEN) return false;
        if (a == b) return true;
        if (a == S.NEVER_MINTED) return b == S.IN_SALE;
        if (a == S.IN_SALE) {
            return b == S.OUT_OF_CUSTODY || b == S.CANCELLED || b == S.SOLD || b == S.UNSOLD
                || b == S.RESCUED;
        }
        if (a == S.OUT_OF_CUSTODY) return b == S.IN_SALE;
        return false; // cancelled and every outcome are final
    }

    /// @dev The minter table's rows, and no change.
    function _allowedMinter(A a, A b) internal pure returns (bool) {
        if (a == b) return true;
        if (a == A.NEVER_ADDED) return b == A.PENDING || b == A.ACTIVE;
        if (a == A.PENDING) return b == A.ACTIVE || b == A.REMOVED;
        if (a == A.ACTIVE) return b == A.REMOVED;
        return b == A.PENDING || b == A.ACTIVE;
    }

    function _minterState(address which) internal view returns (A) {
        Minter memory m = stream.minterOf(which);
        if (m.activeFrom == 0) return A.NEVER_ADDED;
        if (m.removedAt != 0) return A.REMOVED;
        return block.timestamp < m.activeFrom ? A.PENDING : A.ACTIVE;
    }

    /// @dev Reads every work and both minters, checks each change against the tables and
    ///      records the new states.
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
            A now_ = _minterState(minters[i]);
            A before = minterSeen[minters[i]];
            if (!_allowedMinter(before, now_)) _violation("minter transition outside the table");
            if (before != now_) ++hits[keccak256(bytes(_minterKey(before, now_)))];
            uint256 given = givenActiveFrom[minters[i]];
            if (_added(minters[i]) && given != 0 && stream.minterOf(minters[i]).activeFrom != given)
            {
                _violation("an added minter's activation time is not the one it was given");
            }
            minterSeen[minters[i]] = now_;
        }
        if (_minterState(neverAdded) != A.NEVER_ADDED) _violation("a minter nobody added");
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

    function _minterKey(A a, A b) internal pure returns (string memory) {
        string[4] memory names = ["NEVER_ADDED", "PENDING", "ACTIVE", "REMOVED"];
        return string.concat("minter ", names[uint8(a)], ">", names[uint8(b)]);
    }

    // ------------------------------------------------------------------------ the checks

    /// @notice Every work and minter transition observed in the campaign is in the tables, no
    ///         recorded outcome changed, no pending minter's time moved, and every report, burn,
    ///         mint and rescue went through exactly when the rules allow it.
    function invariant_streamStatesFollowTheTables() public view {
        assertEq(violations, 0, firstViolation);
    }

    /// @notice The campaign is not vacuous: random sequences of its shape, replayed from fixed
    ///         seeds, reach every transition of both tables and the refusals, with no violation.
    function test_EveryTransitionIsReached() public {
        string[12] memory transitions = [
            "NEVER_MINTED>IN_SALE",
            "IN_SALE>OUT_OF_CUSTODY",
            "IN_SALE>CANCELLED",
            "IN_SALE>SOLD",
            "IN_SALE>UNSOLD",
            "IN_SALE>RESCUED",
            "OUT_OF_CUSTODY>IN_SALE",
            "minter ACTIVE>REMOVED",
            "minter REMOVED>PENDING",
            "minter REMOVED>ACTIVE",
            "minter PENDING>ACTIVE",
            "minter PENDING>REMOVED"
        ];
        uint256[12] memory totals;
        uint256[5] memory more;
        for (uint256 run; run < RUNS; ++run) {
            uint256 snapshot = vm.snapshotState();
            for (uint256 depth; depth < DEPTH; ++depth) {
                _step(uint256(keccak256(abi.encode(run, depth))));
            }
            assertEq(violations, 0, firstViolation);
            for (uint256 i; i < transitions.length; ++i) {
                totals[i] += hits[keccak256(bytes(transitions[i]))];
            }
            more[0] += hits["rescue refused"];
            more[1] += hits["mint refused"];
            more[2] += hits["bid"];
            more[3] += hits["no-op refused"];
            more[4] += hits["report refused"];
            vm.revertToStateAndDelete(snapshot);
        }
        for (uint256 i; i < transitions.length; ++i) {
            console2.log(transitions[i], totals[i]);
            assertGt(totals[i], 0, transitions[i]);
        }
        console2.log("rescues refused", more[0]);
        console2.log("mints refused", more[1]);
        console2.log("bids accepted", more[2]);
        console2.log("no-op minter changes refused", more[3]);
        console2.log("reports refused", more[4]);
        assertGt(more[0], 0, "rescue refused");
        assertGt(more[1], 0, "mint refused");
        assertGt(more[2], 0, "bid accepted");
        assertGt(more[3], 0, "no-op refused");
        assertGt(more[4], 0, "report refused");
    }

    /// @dev One random action, weighted toward the ones that move works.
    function _step(uint256 r) internal {
        uint256 pick = r % 22;
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
        else if (pick < 20) this.setDelay(seed);
        else this.warp(seed);
    }
}
