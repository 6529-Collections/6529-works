// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { GovernedTargetMock } from "../mocks/governance/GovernanceMocks.sol";
import { RefusingTargetMock } from "../mocks/governance/SuccessionMocks.sol";
import { PermanenceFixture } from "./PermanenceFixture.sol";

// =====================================================================================
// 1. No sequence of calls by fewer than a guardian majority stops the escalated lane.
// =====================================================================================

/// @notice Guardians (five seats), admins and an outsider call `cancel` on one escalated
///         removal in any order, guardians leave mid-flight, time passes (never past ready).
///         A model counts the distinct accepted votes.
contract EscalationHandler is Test {
    WorksAccessManager internal immutable manager;
    address internal immutable scheduler;
    address[] internal callers; // five guardians, two admins, an outsider
    bytes internal data;

    uint256 public votes; // accepted votes on the live nonce
    uint16 public seats;
    bool public stoppedWithoutMajority;
    bool public majorityIgnored;
    uint256 public stops;
    mapping(uint32 nonce => mapping(address => bool)) internal voted;

    constructor(
        WorksAccessManager manager_,
        address scheduler_,
        address[] memory callers_,
        bytes memory data_
    ) {
        manager = manager_;
        scheduler = scheduler_;
        callers = callers_;
        data = data_;
        seats = manager.getEscalation(_id()).seats;
    }

    function _id() internal view returns (bytes32) {
        return manager.hashOperation(scheduler, address(manager), data);
    }

    function _decided() internal view returns (bool) {
        return votes >= 2 && votes * 2 > seats;
    }

    function cancelAs(uint256 who) external {
        address caller = callers[who % callers.length];
        bytes32 id = _id();
        uint32 nonce = manager.getNonce(id);
        vm.prank(caller);
        try manager.cancel(scheduler, address(manager), data) {
            if (!voted[nonce][caller]) {
                voted[nonce][caller] = true;
                ++votes;
            }
            if (manager.getSchedule(id) == 0) {
                if (!_decided()) stoppedWithoutMajority = true;
                ++stops;
                _reschedule();
            } else if (_decided()) {
                majorityIgnored = true;
            }
        } catch { }
    }

    /// @dev One call in eight makes a guardian leave, so majorities stay reachable.
    function leave(uint256 who) external {
        if (who % 8 != 0) return;
        address g = callers[(who / 8) % 5];
        (bool member,) = manager.hasRole(Roles.GUARDIAN, g);
        if (!member) return;
        vm.prank(g);
        manager.renounceRole(Roles.GUARDIAN, g);
    }

    function warp(uint256 dt) external {
        uint256 ready = manager.getSchedule(_id());
        if (ready <= block.timestamp + 1) return;
        vm.warp(block.timestamp + bound(dt, 1, ready - block.timestamp - 1));
    }

    function _reschedule() internal {
        vm.prank(scheduler);
        manager.schedule(address(manager), data, 0);
        votes = 0;
        seats = manager.getEscalation(_id()).seats;
    }
}

contract EscalationInvariantTest is StdInvariant, PermanenceFixture {
    EscalationHandler internal handler;
    bytes internal removeA;

    function setUp() public {
        _deployGovernance();
        _addGuardian(makeAddr("guardianD"));
        _addGuardian(makeAddr("guardianE"));
        removeA = _revoke(Roles.GUARDIAN, guardianA);
        _strike(adminSafe, removeA, guardianB);
        _schedule(adminSafe, address(manager), removeA);
        address[] memory callers = new address[](8);
        (callers[0], callers[1], callers[2]) = (guardianA, guardianB, guardianC);
        (callers[3], callers[4]) = (makeAddr("guardianD"), makeAddr("guardianE"));
        (callers[5], callers[6], callers[7]) = (coldAdmin, adminSafe, outsider);
        // adminSafe is the scheduler: its cancel withdraws, which the model must not count as
        // a stop, so it is left out of the callers.
        callers[6] = attacker;
        handler = new EscalationHandler(manager, adminSafe, callers, removeA);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = EscalationHandler.cancelAs.selector;
        selectors[1] = EscalationHandler.leave.selector;
        selectors[2] = EscalationHandler.warp.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// The escalated operation is stopped exactly when a majority of its counted seats (and at
    /// least two guardians) has voted: never by fewer, and never left standing after.
    function invariant_OnlyAGuardianMajorityStopsTheEscalatedLane() public view {
        assertFalse(handler.stoppedWithoutMajority(), "stopped by fewer than a majority");
        assertFalse(handler.majorityIgnored(), "a majority did not stop it");
        assertTrue(_scheduled(adminSafe, removeA), "live");
    }
}

// =====================================================================================
// 2. A recovery never completes while an admin acts.
// =====================================================================================

contract RecoveryHandler is Test {
    WorksAccessManager internal immutable manager;
    address[] internal guardians;
    address[] internal candidates;

    uint256 public lastAdminAction;
    bool public completedDespiteAdmin;
    bool public completedTooEarly;
    uint256 public completions;

    constructor(
        WorksAccessManager manager_,
        address[] memory guardians_,
        address[] memory candidates_
    ) {
        manager = manager_;
        guardians = guardians_;
        candidates = candidates_;
        lastAdminAction = manager.lastAdminActivity();
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 200 days));
    }

    /// @dev One call in eight is a heartbeat, so long silences occur.
    function heartbeat(uint256 who) external {
        if (who % 8 != 0) return;
        who /= 8;
        address[] memory admins = manager.seatHolders(Roles.ADMIN);
        address admin = admins[who % admins.length];
        (bool active,) = manager.hasRole(Roles.ADMIN, admin);
        if (!active) return;
        vm.prank(admin);
        manager.heartbeat();
        lastAdminAction = block.timestamp;
    }

    function open(uint256 which) external {
        try manager.openRecovery(candidates[which % candidates.length]) { } catch { }
    }

    function approve(uint256 who, uint256 which) external {
        vm.prank(guardians[who % guardians.length]);
        try manager.approveRecovery(candidates[which % candidates.length]) { } catch { }
    }

    function complete(uint256 which) external {
        address candidate = candidates[which % candidates.length];
        WorksAccessManager.Recovery memory r = manager.getRecovery(candidate);
        uint256 quietBefore = lastAdminAction;
        try manager.completeRecovery(candidate) {
            if (lastAdminAction >= r.openedAt) completedDespiteAdmin = true;
            if (block.timestamp < quietBefore + 365 days + 180 days) completedTooEarly = true;
            lastAdminAction = block.timestamp;
            ++completions;
        } catch { }
    }
}

contract RecoveryInvariantTest is StdInvariant, PermanenceFixture {
    RecoveryHandler internal handler;

    function setUp() public {
        _deployGovernance();
        address[] memory g = new address[](3);
        (g[0], g[1], g[2]) = (guardianA, guardianB, guardianC);
        address[] memory c = new address[](2);
        (c[0], c[1]) = (makeAddr("candidate0"), makeAddr("candidate1"));
        handler = new RecoveryHandler(manager, g, c);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = RecoveryHandler.warp.selector;
        selectors[1] = RecoveryHandler.heartbeat.selector;
        selectors[2] = RecoveryHandler.open.selector;
        selectors[3] = RecoveryHandler.approve.selector;
        selectors[4] = RecoveryHandler.complete.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// No recovery completes once an admin acted after it opened, none completes before a
    /// whole silence plus the public delay, and the clock matches the model.
    function invariant_RecoveryNeverCompletesWhileAnAdminActs() public view {
        assertFalse(handler.completedDespiteAdmin(), "completed after an admin acted");
        assertFalse(handler.completedTooEarly(), "completed before silence plus delay");
        assertEq(manager.lastAdminActivity(), handler.lastAdminAction(), "clock");
    }
}

// =====================================================================================
// 3. `migrate` is all or nothing per piece.
// =====================================================================================

contract MigrateHandler is Test {
    WorksAccessManager internal immutable manager;
    address internal immutable next;
    bool public partialPiece;
    uint256 public pieces;

    constructor(WorksAccessManager manager_, address next_) {
        manager = manager_;
        next = next_;
    }

    function migrate(uint256 from, uint256 to) external {
        address[] memory targets = manager.managedTargets();
        from = bound(from, 0, targets.length + 1);
        to = bound(to, 0, targets.length + 2);
        try manager.migrate(from, to) {
            ++pieces;
            uint256 end = to < targets.length ? to : targets.length;
            for (uint256 i = from; i < end; ++i) {
                if (IAccessManaged(targets[i]).authority() == address(manager)) {
                    partialPiece = true;
                }
            }
        } catch { }
    }
}

contract MigrateInvariantTest is StdInvariant, PermanenceFixture {
    MigrateHandler internal handler;
    AccessManager internal next;
    RefusingTargetMock internal refusing;

    function setUp() public {
        _deployGovernance();
        next = new AccessManager(makeAddr("nextAdmin"));
        refusing = new RefusingTargetMock(address(manager));
        bytes32 id;
        address[] memory late = new address[](6);
        for (uint256 i; i < late.length; ++i) {
            late[i] = i == 3
                ? address(refusing)
                : address(new GovernedTargetMock(address(manager), recipient0, verifier0));
            id = _schedule(
                adminSafe,
                address(manager),
                abi.encodeCall(IAccessManager.setTargetAdminDelay, (late[i], 30 days))
            );
        }
        vm.warp(manager.getSchedule(id));
        vm.startPrank(adminSafe);
        for (uint256 i; i < late.length; ++i) {
            manager.execute(
                address(manager),
                abi.encodeCall(IAccessManager.setTargetAdminDelay, (late[i], 30 days))
            );
        }
        vm.stopPrank();
        _scheduleAndExecute(adminSafe, address(manager), _register(address(next)));
        _accept(next, makeAddr("nextAdmin"));
        handler = new MigrateHandler(manager, address(next));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MigrateHandler.migrate.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// Every successful piece moved every target in its range; a target is only ever under the
    /// old manager or the successor; the refusing target never moves.
    function invariant_MigrateIsAllOrNothingPerPiece() public view {
        assertFalse(handler.partialPiece(), "a piece left a target behind");
        address[] memory targets = manager.managedTargets();
        for (uint256 i; i < targets.length; ++i) {
            address a = IAccessManaged(targets[i]).authority();
            assertTrue(a == address(manager) || a == address(next), "an unexpected authority");
        }
        assertEq(refusing.authority(), address(manager));
    }
}

// =====================================================================================
// 4. Seat caps hold and the seat lists match the records.
// =====================================================================================

contract SeatHandler is Test {
    WorksAccessManager internal immutable manager;
    address internal immutable admin;
    address[] internal pool;

    bool public grantedOverCap;
    mapping(uint64 role => mapping(address => bool)) public held;
    mapping(uint64 role => uint256) public count;

    constructor(
        WorksAccessManager manager_,
        address admin_,
        address[] memory pool_,
        address[] memory guardians_,
        address[] memory admins_
    ) {
        manager = manager_;
        admin = admin_;
        pool = pool_;
        for (uint256 i; i < guardians_.length; ++i) {
            held[Roles.GUARDIAN][guardians_[i]] = true;
        }
        for (uint256 i; i < admins_.length; ++i) {
            held[Roles.ADMIN][admins_[i]] = true;
        }
        count[Roles.GUARDIAN] = guardians_.length;
        count[Roles.ADMIN] = admins_.length;
    }

    function _role(uint256 r) internal pure returns (uint64) {
        return r % 2 == 0 ? Roles.ADMIN : Roles.GUARDIAN;
    }

    function _run(bytes memory data) internal returns (bool ok) {
        vm.prank(admin);
        (bytes32 id,) = manager.schedule(address(manager), data, 0);
        vm.warp(manager.getSchedule(id));
        vm.prank(admin);
        try manager.execute(address(manager), data) {
            ok = true;
        } catch {
            vm.prank(admin);
            manager.cancel(admin, address(manager), data);
        }
    }

    function grant(uint256 r, uint256 who) external {
        uint64 role = _role(r);
        address account = pool[who % pool.length];
        uint32 delay = role == Roles.ADMIN ? 30 days : 0;
        uint256 cap = manager.parameter(
            role == Roles.ADMIN
                ? WorksAccessManager.Parameter.ADMIN_SEATS
                : WorksAccessManager.Parameter.GUARDIAN_SEATS
        );
        uint256 before = count[role];
        bool wasHeld = held[role][account];
        if (_run(abi.encodeCall(IAccessManager.grantRole, (role, account, delay))) && !wasHeld) {
            if (before >= cap) grantedOverCap = true;
            held[role][account] = true;
            ++count[role];
        }
    }

    function revoke(uint256 r, uint256 who) external {
        uint64 role = _role(r);
        address account = pool[who % pool.length];
        if (!held[role][account]) return;
        vm.prank(account);
        manager.renounceRole(role, account);
        held[role][account] = false;
        --count[role];
    }

    function setCap(uint256 r, uint256 value) external {
        WorksAccessManager.Parameter p = _role(r) == Roles.ADMIN
            ? WorksAccessManager.Parameter.ADMIN_SEATS
            : WorksAccessManager.Parameter.GUARDIAN_SEATS;
        uint32 v = uint32(bound(value, 3, 16));
        _run(abi.encodeCall(WorksAccessManager.setParameter, (p, manager.parameter(p), v)));
    }
}

contract SeatInvariantTest is StdInvariant, PermanenceFixture {
    SeatHandler internal handler;
    address[] internal pool;

    function setUp() public {
        _deployGovernance();
        for (uint256 i; i < 20; ++i) {
            pool.push(makeAddr(string.concat("seat", vm.toString(i))));
        }
        address[] memory g = new address[](3);
        (g[0], g[1], g[2]) = (guardianA, guardianB, guardianC);
        address[] memory a = new address[](1);
        a[0] = coldAdmin;
        // adminSafe runs every operation and never leaves; it is not in the pool.
        handler = new SeatHandler(manager, adminSafe, pool, g, a);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = SeatHandler.grant.selector;
        selectors[1] = SeatHandler.revoke.selector;
        selectors[2] = SeatHandler.setCap.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// No grant ever exceeds the cap in force; the seat lists hold exactly the records.
    function invariant_SeatCapsHold() public view {
        assertFalse(handler.grantedOverCap(), "granted over the cap");
        assertEq(manager.seatHolders(Roles.ADMIN).length, handler.count(Roles.ADMIN) + 1);
        assertEq(manager.seatHolders(Roles.GUARDIAN).length, handler.count(Roles.GUARDIAN));
        assertLe(manager.seatHolders(Roles.GUARDIAN).length, 16);
        address[] memory holders = manager.seatHolders(Roles.GUARDIAN);
        for (uint256 i; i < holders.length; ++i) {
            (uint48 since,,,) = manager.getAccess(Roles.GUARDIAN, holders[i]);
            assertGt(since, 0, "a seat without a record");
        }
    }
}
