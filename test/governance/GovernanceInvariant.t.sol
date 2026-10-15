// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Multicall } from "@openzeppelin/contracts/utils/Multicall.sol";
import { Roles } from "src/governance/Roles.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { GovernanceFixture } from "../helpers/GovernanceFixture.sol";
import { GovernedTargetMock } from "../mocks/GovernanceMocks.sol";

/// @notice Admins schedule random hostile operations alongside benign guardian and admin
///         rotations that really execute. Vigilant guardians (a random one each time) cancel
///         every hostile operation before time moves on; wrapped revocations that can never
///         execute are left to mature. Guardians also suspend operational keys, and admins
///         lift the suspensions with 30-day grants. A model tracks who should hold which role.
///         With `fail_on_revert`, any cancel the guardians are not entitled to fails the
///         campaign.
contract GovernanceHandler is Test {
    struct Hostile {
        address caller;
        address to;
        bytes data;
        address victim; // the account whose role it revokes, or zero
        bool inert; // a wrapper that can never execute; left to mature
    }

    struct Benign {
        address caller;
        bytes first;
        bytes second; // empty for a single call
        uint8 kind; // 0 add guardian, 1 remove guardian, 2 add admin, 3 remove admin, 4 lift
        address subject;
    }

    GovernanceConfigurator internal immutable configurator;
    WorksAccessManager internal immutable manager;
    GovernedTargetMock internal immutable target;
    AccessManager internal immutable rogue;
    address internal immutable hot;
    address internal immutable attacker;
    bytes internal fixedGrants; // abi-encoded Grant[] of holders that never rotate
    bytes internal targets; // abi-encoded Target[]

    address[] public guardianPool;
    address[] public adminPool; // secondary admins; the hot admin never rotates
    mapping(address => bool) public granted; // model: membership
    mapping(address => uint256) public activeAt; // model: when membership becomes active
    mapping(address => bool) internal inFlight; // a benign operation for this account is pending
    mapping(bytes32 => bool) internal benignId;

    Hostile[] internal hostile;
    Benign[] internal benign;

    bool public hostileExecuted;
    bool public selfRescue;
    bool public benignFailed;
    bool public adminCancelledRevocation;
    bool public nonSuspendableSuspended;
    /// @dev The fixed holders of suspendable roles, and the model of which are suspended.
    GovernanceConfig.Grant[] internal keys;
    mapping(address => bool) public suspendedKey;
    uint256 public suspensions;
    uint256 public lifts;
    uint256 public revocationCancelAttempts;
    uint256 public benignExecuted;
    uint256 public hostileCancelled;
    uint256 public rescheduled;

    constructor(
        GovernanceConfigurator configurator_,
        GovernedTargetMock target_,
        bytes memory fixedGrants_,
        bytes memory targets_,
        address[] memory guardians,
        address[] memory admins,
        address hot_,
        address attacker_
    ) {
        configurator = configurator_;
        manager = configurator_.worksManager();
        target = target_;
        fixedGrants = fixedGrants_;
        targets = targets_;
        hot = hot_;
        attacker = attacker_;
        rogue = new AccessManager(attacker_);
        guardianPool = guardians;
        adminPool = admins;
        // The first three guardians and the first secondary admin are live at genesis.
        for (uint256 i; i < 3; ++i) {
            granted[guardians[i]] = true;
        }
        granted[admins[0]] = true;
        GovernanceConfig.Grant[] memory base = abi.decode(fixedGrants_, (GovernanceConfig.Grant[]));
        for (uint256 i; i < base.length; ++i) {
            if (Roles.isSuspendable(base[i].role)) keys.push(base[i]);
        }
    }

    function keyCount() external view returns (uint256) {
        return keys.length;
    }

    function keyAt(uint256 i) external view returns (uint64 role, address account) {
        return (keys[i].role, keys[i].account);
    }

    // ------------------------------------------------------------------ model views

    function _active(address account) internal view returns (bool) {
        return granted[account] && activeAt[account] <= block.timestamp;
    }

    function activeGuardians() public view returns (address[] memory list) {
        list = new address[](guardianPool.length);
        uint256 n;
        for (uint256 i; i < guardianPool.length; ++i) {
            if (_active(guardianPool[i])) list[n++] = guardianPool[i];
        }
        assembly ("memory-safe") {
            mstore(list, n)
        }
    }

    function _activeAdmins() internal view returns (address[] memory list) {
        list = new address[](adminPool.length + 1);
        list[0] = hot;
        uint256 n = 1;
        for (uint256 i; i < adminPool.length; ++i) {
            if (_active(adminPool[i])) list[n++] = adminPool[i];
        }
        assembly ("memory-safe") {
            mstore(list, n)
        }
    }

    function _pick(address[] memory list, uint256 seed) internal pure returns (address) {
        return list[seed % list.length];
    }

    function _id(address caller, address to, bytes memory data) internal view returns (bytes32) {
        return manager.hashOperation(caller, to, data);
    }

    /// @dev The configuration the model says is live: fixed holders that are not suspended,
    ///      plus active rotators.
    function modelConfig() public view returns (GovernanceConfig.Config memory cfg) {
        GovernanceConfig.Grant[] memory base = abi.decode(fixedGrants, (GovernanceConfig.Grant[]));
        address[] memory guardians = activeGuardians();
        address[] memory admins = _activeAdmins();
        cfg.grants =
            new GovernanceConfig.Grant[](base.length + 2 * guardians.length + admins.length - 1);
        uint256 n;
        for (uint256 i; i < base.length; ++i) {
            if (Roles.isSuspendable(base[i].role) && suspendedKey[base[i].account]) continue;
            cfg.grants[n++] = base[i];
        }
        for (uint256 i; i < guardians.length; ++i) {
            cfg.grants[n++] = GovernanceConfig.Grant(Roles.GUARDIAN, guardians[i]);
            cfg.grants[n++] = GovernanceConfig.Grant(Roles.PAUSER, guardians[i]);
        }
        for (uint256 i = 1; i < admins.length; ++i) {
            cfg.grants[n++] = GovernanceConfig.Grant(Roles.ADMIN, admins[i]);
        }
        GovernanceConfig.Grant[] memory grants = cfg.grants;
        assembly ("memory-safe") {
            mstore(grants, n)
        }
        cfg.targets = abi.decode(targets, (GovernanceConfig.Target[]));
    }

    // ------------------------------------------------------------------ hostile menu

    function _one(bytes4 selector) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = selector;
    }

    function _revoke(uint64 role, address account) internal pure returns (bytes memory) {
        return abi.encodeCall(IAccessManager.revokeRole, (role, account));
    }

    /// @return to The operation's target.
    /// @return data Its calldata.
    /// @return victim The account whose role it revokes, or zero.
    /// @return inert Whether it is a wrapper that can never execute.
    /// @return onTarget Whether it targets the sample target (scheduled by the hot admin).
    function _hostile(uint256 menu, uint256 arg)
        internal
        view
        returns (address to, bytes memory data, address victim, bool inert, bool onTarget)
    {
        address g = _pick(activeGuardians(), arg);
        uint64 role = uint64(arg % Roles.COUNT);
        uint64 nonAdmin = uint64(1 + arg % (Roles.COUNT - 1));
        to = address(manager);
        uint256 m = menu % 23;
        if (m == 0) {
            (data, victim) = (_revoke(Roles.GUARDIAN, g), g);
        } else if (m == 1) {
            (data, victim) = (_revoke(Roles.PAUSER, g), g);
        } else if (m == 2) {
            (data, victim) = (abi.encodePacked(_revoke(Roles.GUARDIAN, g), bytes32(arg)), g);
        } else if (m == 3) {
            victim = _pick(_activeAdmins(), arg);
            data = _revoke(Roles.ADMIN, victim);
        } else if (m == 4) {
            data = abi.encodeCall(IAccessManager.grantRole, (Roles.ADMIN, attacker, 0));
        } else if (m == 5) {
            data = abi.encodeCall(IAccessManager.grantRole, (role, attacker, 0));
        } else if (m == 6) {
            data = abi.encodeCall(IAccessManager.setGrantDelay, (role, 0));
        } else if (m == 7) {
            address t = arg % 2 == 0 ? address(target) : address(manager);
            data = abi.encodeCall(IAccessManager.setTargetAdminDelay, (t, 0));
        } else if (m == 8) {
            data = abi.encodeCall(
                IAccessManager.setTargetFunctionRole,
                (
                    address(target),
                    _one(GovernedTargetMock.setRecipient.selector),
                    Roles.PARAMETER_SETTER
                )
            );
        } else if (m == 9) {
            data = abi.encodeCall(IAccessManager.setRoleGuardian, (nonAdmin, Roles.ADMIN));
        } else if (m == 10) {
            data = abi.encodeCall(IAccessManager.setRoleAdmin, (nonAdmin, Roles.KEEPER));
        } else if (m == 11) {
            data = abi.encodeCall(IAccessManager.setTargetClosed, (address(target), true));
        } else if (m == 12) {
            data = abi.encodeCall(IAccessManager.updateAuthority, (address(target), address(rogue)));
        } else if (m == 13) {
            data = abi.encodeCall(IAccessManager.labelRole, (nonAdmin, "pwned"));
        } else if (m == 14) {
            data = abi.encodeCall(IAccessManager.grantRole, (Roles.ADMIN, hot, 0));
        } else if (m < 18) {
            inert = true;
            bytes memory inner = _revoke(Roles.GUARDIAN, g);
            if (m == 15) {
                bytes[] memory calls = new bytes[](1);
                calls[0] = inner;
                data = abi.encodeCall(Multicall.multicall, (calls));
            } else if (m == 16) {
                data = abi.encodeCall(IAccessManager.execute, (address(manager), inner));
            } else {
                data = abi.encodeCall(IAccessManager.renounceRole, (Roles.GUARDIAN, g));
            }
        } else {
            (to, onTarget) = (address(target), true);
            if (m == 18) {
                data =
                    abi.encodeCall(GovernedTargetMock.setRecipient, (target.recipient(), attacker));
            } else if (m == 19) {
                data = abi.encodeCall(GovernedTargetMock.setVerifier, (target.verifier(), attacker));
            } else if (m == 20) {
                data = abi.encodeCall(GovernedTargetMock.setFee, (arg));
            } else if (m == 21) {
                data = abi.encodeCall(GovernedTargetMock.adminOnly, ()); // unmapped: ADMIN
            } else {
                data = abi.encodeCall(IAccessManaged.setAuthority, (address(rogue)));
            }
        }
    }

    // ------------------------------------------------------------------ actions

    /// @notice An admin schedules a hostile operation. Scheduling itself must always work.
    function scheduleHostile(uint256 menu, uint256 arg, uint256 who) external {
        (address to, bytes memory data, address victim, bool inert, bool onTarget) =
            _hostile(menu, arg);
        address caller = onTarget ? hot : _pick(_activeAdmins(), who);
        bytes32 id = _id(caller, to, data);
        if (manager.getSchedule(id) != 0 || benignId[id]) return;
        vm.prank(caller);
        manager.schedule(to, data, 0);
        hostile.push(Hostile(caller, to, data, victim, inert));
    }

    /// @notice An admin schedules a benign rotation that the guardians let through.
    function scheduleBenign(uint256 kind, uint256 pick, uint256 who) external {
        address caller = _pick(_activeAdmins(), who);
        uint8 k = uint8(kind % 4);
        address subject = _benignSubject(k, pick);
        if (subject == address(0)) return;
        bytes memory first;
        bytes memory second;
        if (k == 0) {
            first = abi.encodeCall(IAccessManager.grantRole, (Roles.GUARDIAN, subject, 0));
            second = abi.encodeCall(IAccessManager.grantRole, (Roles.PAUSER, subject, 0));
        } else if (k == 1) {
            (first, second) = (_revoke(Roles.GUARDIAN, subject), _revoke(Roles.PAUSER, subject));
        } else if (k == 2) {
            first = abi.encodeCall(IAccessManager.grantRole, (Roles.ADMIN, subject, 30 days));
        } else {
            first = _revoke(Roles.ADMIN, subject);
        }
        bytes32 a = _id(caller, address(manager), first);
        bytes32 b = second.length == 0 ? bytes32(0) : _id(caller, address(manager), second);
        if (manager.getSchedule(a) != 0 || (b != 0 && manager.getSchedule(b) != 0)) return;
        vm.startPrank(caller);
        manager.schedule(address(manager), first, 0);
        if (b != 0) manager.schedule(address(manager), second, 0);
        vm.stopPrank();
        benignId[a] = true;
        if (b != 0) benignId[b] = true;
        inFlight[subject] = true;
        benign.push(Benign(caller, first, second, k, subject));
    }

    function _benignSubject(uint8 kind, uint256 pick) internal view returns (address) {
        address[] memory pool = kind < 2 ? guardianPool : adminPool;
        uint256 eligible;
        for (uint256 i; i < guardianPool.length; ++i) {
            address g = guardianPool[i];
            if (_active(g) && !inFlight[g]) ++eligible;
        }
        for (uint256 i; i < pool.length; ++i) {
            address a = pool[(pick % pool.length + i) % pool.length];
            if (inFlight[a]) continue;
            if (kind == 0 || kind == 2) {
                if (!granted[a]) return a;
            } else if (kind == 1) {
                // Keep at least two active guardians that are not themselves leaving.
                if (_active(a) && eligible >= 3) return a;
            } else if (granted[a]) {
                return a;
            }
        }
        return address(0);
    }

    /// @notice The scheduler executes a ready benign rotation in one multicall.
    function executeBenign(uint256 index) external {
        if (benign.length == 0) return;
        _executeBenign(index % benign.length);
    }

    /// @dev Executes benign operation `index` if ready, drops it once ready or expired, and
    ///      returns whether it was dropped.
    function _executeBenign(uint256 index) internal returns (bool) {
        Benign memory op = benign[index];
        uint48 ready = manager.getSchedule(_id(op.caller, address(manager), op.first));
        if (ready > block.timestamp) return false;
        if (ready != 0) {
            bytes[] memory calls = new bytes[](op.second.length == 0 ? 1 : 2);
            calls[0] = op.first;
            if (calls.length == 2) calls[1] = op.second;
            vm.prank(op.caller);
            try manager.multicall(calls) {
                ++benignExecuted;
                if (op.kind == 4) {
                    suspendedKey[op.subject] = false;
                    ++lifts;
                } else if (op.kind == 0 || op.kind == 2) {
                    (granted[op.subject], activeAt[op.subject]) = (true, block.timestamp + 30 days);
                } else {
                    granted[op.subject] = false;
                }
            } catch {
                // Only a scheduler that has since lost its admin role may fail here.
                if (_active(op.caller) || op.caller == hot) benignFailed = true;
            }
        }
        _dropBenign(index);
        return true;
    }

    /// @dev The honest admins execute every benign operation as soon as it is ready.
    function _executeReadyBenign() internal {
        for (uint256 i = benign.length; i > 0; --i) {
            _executeBenign(i - 1);
        }
    }

    /// @dev The earliest ready time of a pending benign operation in `(now, end]`, or zero.
    function _nextBenignReady(uint256 end) internal view returns (uint256 next) {
        for (uint256 i; i < benign.length; ++i) {
            Benign memory op = benign[i];
            uint256 ready = manager.getSchedule(_id(op.caller, address(manager), op.first));
            if (ready > block.timestamp && ready <= end && (next == 0 || ready < next)) {
                next = ready;
            }
        }
    }

    function _dropBenign(uint256 index) internal {
        Benign memory op = benign[index];
        delete benignId[_id(op.caller, address(manager), op.first)];
        if (op.second.length != 0) delete benignId[_id(op.caller, address(manager), op.second)];
        delete inFlight[op.subject];
        benign[index] = benign[benign.length - 1];
        benign.pop();
    }

    /// @notice A guardian suspends a fixed operational key at once, and tries a role that is
    ///         not suspendable, which must be refused.
    function guardianSuspends(uint256 pick, uint256 who, uint64 otherRole) external {
        address guardian = _pick(activeGuardians(), who);
        GovernanceConfig.Grant memory key = keys[pick % keys.length];
        if (!suspendedKey[key.account] && !inFlight[key.account]) {
            vm.prank(guardian);
            manager.suspend(key.role, key.account);
            suspendedKey[key.account] = true;
            ++suspensions;
        }
        otherRole = uint64(bound(otherRole, 0, Roles.COUNT - 1));
        if (Roles.isSuspendable(otherRole)) return;
        address victim = otherRole == Roles.ADMIN ? hot : _pick(activeGuardians(), pick);
        vm.prank(guardian);
        try manager.suspend(otherRole, victim) {
            nonSuspendableSuspended = true;
        } catch { }
    }

    /// @notice An admin schedules the lift of a suspended key (a 30-day grant to it), which
    ///         the guardians let through.
    function scheduleLift(uint256 pick, uint256 who) external {
        GovernanceConfig.Grant memory key = keys[pick % keys.length];
        if (!suspendedKey[key.account] || inFlight[key.account]) return;
        address caller = _pick(_activeAdmins(), who);
        bytes memory lift = abi.encodeCall(IAccessManager.grantRole, (key.role, key.account, 0));
        bytes32 id = _id(caller, address(manager), lift);
        if (manager.getSchedule(id) != 0) return;
        vm.prank(caller);
        manager.schedule(address(manager), lift, 0);
        benignId[id] = true;
        inFlight[key.account] = true;
        benign.push(Benign(caller, lift, "", 4, key.account));
    }

    /// @notice An admin tries to cancel a revocation another account scheduled (Rule 3).
    function adminCancelsOthersRevocation(uint256 index, uint256 who, bool fromBenign) external {
        address caller;
        address to = address(manager);
        bytes memory data;
        if (fromBenign) {
            if (benign.length == 0) return;
            Benign memory op = benign[index % benign.length];
            if (op.kind != 1 && op.kind != 3) return;
            (caller, data) = (op.caller, op.first);
        } else {
            (bool found, uint256 i) = _liveHostile(index);
            if (!found) return;
            Hostile memory op = hostile[i];
            if (op.victim == address(0) || op.to != address(manager)) return;
            (caller, to, data) = (op.caller, op.to, op.data);
        }
        if (bytes4(data) != IAccessManager.revokeRole.selector) return;
        if (manager.getSchedule(_id(caller, to, data)) == 0) return;
        address canceller = _pick(_activeAdmins(), who);
        if (canceller == caller) return;
        ++revocationCancelAttempts;
        vm.prank(canceller);
        try manager.cancel(caller, to, data) {
            adminCancelledRevocation = true;
        } catch { }
    }

    /// @notice The scheduler withdraws a hostile operation and schedules it again.
    function adminCancelAndReschedule(uint256 index) external {
        (bool found, uint256 i) = _liveHostile(index);
        if (!found) return;
        Hostile memory op = hostile[i];
        vm.prank(op.caller);
        manager.cancel(op.caller, op.to, op.data); // the scheduler path never fails
        if (op.caller == hot || _active(op.caller)) {
            vm.prank(op.caller);
            manager.schedule(op.to, op.data, 0);
            ++rescheduled;
        } else {
            _dropHostile(i);
        }
    }

    /// @notice A scheduler tries to execute a hostile or inert operation.
    function tryExecute(uint256 index) external {
        if (hostile.length == 0) return;
        Hostile memory op = hostile[index % hostile.length];
        vm.prank(op.caller);
        try manager.execute(op.to, op.data) {
            hostileExecuted = true;
        } catch { }
    }

    /// @notice The hot admin calls a hostile function directly, bypassing `execute`.
    function tryDirect(uint256 menu, uint256 arg) external {
        (address to, bytes memory data,, bool inert,) = _hostile(menu, arg);
        // A direct call would legitimately consume a ready schedule of the same call.
        if (inert || manager.getSchedule(_id(hot, to, data)) != 0) return;
        vm.prank(hot);
        (bool ok,) = to.call(data);
        if (ok) hostileExecuted = true;
    }

    /// @notice The account an operation revokes tries to cancel it.
    function trySelfRescue(uint256 index, bool fromBenign) external {
        address victim;
        address caller;
        address to = address(manager);
        bytes memory data;
        if (fromBenign) {
            if (benign.length == 0) return;
            Benign memory op = benign[index % benign.length];
            if (op.kind != 1 && op.kind != 3) return;
            (victim, caller, data) = (op.subject, op.caller, op.first);
        } else {
            (bool found, uint256 i) = _liveHostile(index);
            if (!found) return;
            Hostile memory op = hostile[i];
            (victim, caller, to, data) = (op.victim, op.caller, op.to, op.data);
        }
        if (victim == address(0) || victim == caller) return;
        if (manager.getSchedule(_id(caller, to, data)) == 0) return;
        vm.prank(victim);
        try manager.cancel(caller, to, data) {
            selfRescue = true;
        } catch { }
    }

    /// @notice Time passes, after a random guardian has cancelled every hostile operation.
    function warp(uint256 seconds_, uint256 who) external {
        address[] memory guardians = activeGuardians();
        uint256 base = who % guardians.length;
        for (uint256 i = hostile.length; i > 0; --i) {
            Hostile memory op = hostile[i - 1];
            if (op.inert) {
                if (manager.getSchedule(_id(op.caller, op.to, op.data)) == 0) _dropHostile(i - 1);
                continue;
            }
            address canceller = guardians[(base + i) % guardians.length];
            if (canceller == op.victim) canceller = guardians[(base + i + 1) % guardians.length];
            vm.prank(canceller);
            manager.cancel(op.caller, op.to, op.data);
            ++hostileCancelled;
            _dropHostile(i - 1);
        }
        // Time advances in steps that stop at every benign operation's ready time.
        uint256 end = block.timestamp + bound(seconds_, 1 hours, 40 days);
        for (uint256 next = _nextBenignReady(end); next != 0; next = _nextBenignReady(end)) {
            vm.warp(next);
            _executeReadyBenign();
        }
        vm.warp(end);
        _executeReadyBenign();
        configurator.verify(modelConfig());
    }

    function _liveHostile(uint256 index) internal view returns (bool, uint256) {
        for (uint256 n; n < hostile.length; ++n) {
            uint256 i = (index % hostile.length + n) % hostile.length;
            if (!hostile[i].inert) return (true, i);
        }
        return (false, 0);
    }

    function _dropHostile(uint256 index) internal {
        hostile[index] = hostile[hostile.length - 1];
        hostile.pop();
    }
}

contract GovernanceInvariantTest is StdInvariant, GovernanceFixture {
    GovernanceHandler internal handler;
    address[] internal guardianPool;
    address[] internal adminPool;

    function setUp() public {
        _deployGovernance();
        address[5] memory guardians =
            [guardianA, guardianB, guardianC, makeAddr("guardianD"), makeAddr("guardianE")];
        address[3] memory admins = [coldAdmin, makeAddr("adminX"), makeAddr("adminY")];
        for (uint256 i; i < guardians.length; ++i) {
            guardianPool.push(guardians[i]);
        }
        for (uint256 i; i < admins.length; ++i) {
            adminPool.push(admins[i]);
        }

        // Holders that never rotate: everything except guardians and secondary admins.
        GovernanceConfig.Grant[] memory all = _grants();
        GovernanceConfig.Grant[] memory fixedGrants = new GovernanceConfig.Grant[](all.length);
        uint256 n;
        for (uint256 i; i < all.length; ++i) {
            uint64 role = all[i].role;
            if (role == Roles.GUARDIAN || (role == Roles.PAUSER && all[i].account != adminSafe)) {
                continue;
            }
            if (role == Roles.ADMIN && all[i].account != adminSafe) continue;
            fixedGrants[n++] = all[i];
        }
        assembly ("memory-safe") {
            mstore(fixedGrants, n)
        }

        handler = new GovernanceHandler(
            configurator,
            target,
            abi.encode(fixedGrants),
            abi.encode(_config().targets),
            guardianPool,
            adminPool,
            adminSafe,
            attacker
        );
        configurator.verify(handler.modelConfig());

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = GovernanceHandler.scheduleHostile.selector;
        selectors[1] = GovernanceHandler.scheduleBenign.selector;
        selectors[2] = GovernanceHandler.executeBenign.selector;
        selectors[3] = GovernanceHandler.adminCancelAndReschedule.selector;
        selectors[4] = GovernanceHandler.tryExecute.selector;
        selectors[5] = GovernanceHandler.tryDirect.selector;
        selectors[6] = GovernanceHandler.trySelfRescue.selector;
        selectors[7] = GovernanceHandler.warp.selector;
        selectors[8] = GovernanceHandler.guardianSuspends.selector;
        selectors[9] = GovernanceHandler.scheduleLift.selector;
        selectors[10] = GovernanceHandler.adminCancelsOthersRevocation.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// Hostile operations never change the target or grant the attacker a role; nothing
    /// executes early or through a wrapper; nobody cancels their own revocation; benign
    /// rotations always execute; on-chain membership matches the model; at least two
    /// guardians stay active. The full readback runs in the handler at every warp, since only
    /// a flagged or modelled execution can change state between warps.
    function invariant_GovernanceStaysContained() public view {
        assertEq(target.authority(), address(manager));
        assertEq(target.recipient(), recipient0);
        assertEq(target.verifier(), verifier0);
        assertEq(target.fee(), 0);
        assertEq(target.adminCalls(), 0);
        for (uint64 role; role < Roles.COUNT; ++role) {
            assertFalse(GovernanceConfig.hasRecord(manager, role, attacker), "attacker role");
        }
        assertFalse(handler.hostileExecuted(), "hostile execution");
        assertFalse(handler.selfRescue(), "cancelled its own revocation");
        assertFalse(handler.benignFailed(), "benign rotation failed");

        for (uint256 i; i < guardianPool.length; ++i) {
            address g = guardianPool[i];
            bool modelled = handler.granted(g);
            assertEq(GovernanceConfig.hasRecord(manager, Roles.GUARDIAN, g), modelled, "guardian");
            assertEq(GovernanceConfig.hasRecord(manager, Roles.PAUSER, g), modelled, "pauser");
        }
        for (uint256 i; i < adminPool.length; ++i) {
            address a = adminPool[i];
            assertEq(
                GovernanceConfig.hasRecord(manager, Roles.ADMIN, a), handler.granted(a), "admin"
            );
        }
        (bool hotAdmin,) = manager.hasRole(Roles.ADMIN, adminSafe);
        assertTrue(hotAdmin);
        assertGe(handler.activeGuardians().length, 2, "fewer than two guardians");
        assertFalse(handler.adminCancelledRevocation(), "an admin cancelled another's revocation");
    }

    /// Only suspendable roles are ever suspended, and a suspended holder never passes
    /// `hasRole` or `canCall`. The suspension state matches the model.
    function invariant_SuspensionsStayContained() public view {
        assertFalse(handler.nonSuspendableSuspended(), "a non-suspendable role was suspended");
        address[] memory accounts = new address[](guardianPool.length + adminPool.length + 3);
        uint256 n;
        for (uint256 i; i < guardianPool.length; ++i) {
            accounts[n++] = guardianPool[i];
        }
        for (uint256 i; i < adminPool.length; ++i) {
            accounts[n++] = adminPool[i];
        }
        (accounts[n++], accounts[n++], accounts[n++]) = (adminSafe, keeper, attacker);
        for (uint64 role; role < Roles.COUNT; ++role) {
            if (Roles.isSuspendable(role)) continue;
            for (uint256 i; i < accounts.length; ++i) {
                assertFalse(manager.isSuspended(role, accounts[i]), "non-suspendable suspended");
            }
        }
        for (uint256 i; i < handler.keyCount(); ++i) {
            (uint64 role, address key) = handler.keyAt(i);
            bool suspended = manager.isSuspended(role, key);
            assertEq(suspended, handler.suspendedKey(key), "suspension model");
            (bool member,) = manager.hasRole(role, key);
            assertEq(member, !suspended, "a suspended key is no member");
            if (role == Roles.CURATOR) {
                (bool immediate, uint32 delay) =
                    manager.canCall(key, address(target), GovernedTargetMock.curate.selector);
                assertEq(immediate, !suspended, "canCall");
                assertEq(delay, 0);
            }
        }
    }
}
