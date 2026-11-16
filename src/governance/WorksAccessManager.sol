// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";
import { Roles } from "./Roles.sol";
import { SuccessionProbe } from "./SuccessionProbe.sol";

/// @title WorksAccessManager
/// @notice The OpenZeppelin 5.7.0 `AccessManager` that governs every 6529 Works contract, with
///         three cancellation rules (ADR 0001 §13.2, ADR 0002):
///         1. any `Roles.GUARDIAN` holder can cancel any scheduled operation;
///         2. nobody but its scheduler can cancel an operation that revokes one of the
///            canceller's own roles, so no guardian or admin can veto its own removal;
///         3. only a guardian, or its scheduler, can cancel a role revocation on this manager,
///            so no admin can veto another account's removal.
///         A guardian can suspend a holder of a zero-delay operational role at once (`suspend`,
///         ADR 0002 addendum). Four additions are for a long life (governance spec, GV-37 to
///         GV-46):
///         - bounded veto: once a guardian cancels a guardian's removal or a successor
///           registration, a re-proposal of the same action ({actionOf}) waits the escalated
///           delay, and only a majority of the guardian seats, never fewer than two guardians,
///           can stop it;
///         - dead-admin recovery: after `RECOVERY_SILENCE` with no admin activity anyone may open
///           a recovery that, `RECOVERY_DELAY` later, makes one account the only admin: approved
///           by a guardian majority, or, for the pre-registered recovery address, not objected
///           to by one. Any admin activity voids it;
///         - a two-step succession: `registerSuccessor` (slow lane) proposes a successor and
///           this manager keeps all its power until that successor proves it can act, by
///           re-pointing a probe contract to this manager and calling {acceptSuccession}
///           itself; only then does this manager's power end, and {migrate} re-points every
///           managed target to the successor, in pieces anyone may run;
///         - seat caps for `ADMIN` and `GUARDIAN`, and every holder of a role in {Roles} at
///           least its class delay (30 days for every admin).
///         Each number is a governed parameter within bounds compiled here ({parameterBounds}):
///         the lower bounds are the guarantee, the initial values only defaults.
/// @dev Stock cancellation is selector-scoped: the scheduler, an admin, or the guardian of the
///      target function's role. Rule 1 closes the gaps that leaves (the admin's operations on
///      this manager, a `setAuthority` scheduled directly on a target, unmapped selectors);
///      Rules 2 and 3 depend on arguments and on who scheduled. Every other cancellation keeps
///      the stock rules. The inherited OpenZeppelin `Multicall` self-delegatecall only batches
///      calls into this contract; it is the one sanctioned exemption to the no-delegatecall rule.
///      This manager's own selectors cannot be remapped and it cannot be closed, so the
///      functions added here always resolve to `ADMIN` with at least the admin's 30-day delay,
///      and {schedule} adds the longer delays on top.
contract WorksAccessManager is AccessManager {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice A governed number of this manager, bounded by {parameterBounds}.
    enum Parameter {
        SLOW_DELAY, // successor and recovery-address registration, parameter changes
        ESCALATED_DELAY, // a re-proposal after a guardian's cancellation (bounded veto)
        RECOVERY_SILENCE, // admin inactivity before a recovery may open
        RECOVERY_DELAY, // public delay between opening and completing a recovery
        ADMIN_SEATS, // most ADMIN records, active or pending
        GUARDIAN_SEATS // most GUARDIAN records, active or pending
    }

    /// @notice A re-proposal in the escalated lane. Only guardians whose seat serial is at most
    ///         `serial` (seated when it was scheduled) may vote; `seats` were counted then.
    struct Escalation {
        uint32 nonce;
        uint48 serial;
        uint16 seats;
        uint16 votes;
    }

    /// @notice A dead-admin recovery for one candidate; `serial` and `seats` as in {Escalation}.
    struct Recovery {
        uint48 openedAt;
        uint48 readyAt;
        uint48 serial;
        uint16 seats;
        uint16 votes;
        bool registered;
    }

    /// @dev Suspended holders of `Roles.isSuspendable` roles. Cleared by any grant or revocation
    ///      of the same role to the same account: an ADMIN grant or revocation (30 days,
    ///      guardian-vetoable), or the holder's own `renounceRole`, which revokes the role.
    mapping(uint64 roleId => mapping(address account => bool)) private _suspended;
    /// @dev ADMIN and GUARDIAN records (active or pending): seat caps, majorities, recovery.
    mapping(uint64 roleId => EnumerableSet.AddressSet) private _seats;
    /// @dev Each new GUARDIAN record gets the next serial, so seats order against snapshots.
    mapping(address guardian => uint48 serial) private _serialOf;
    uint32[6] private _params;
    /// @notice When an active ADMIN holder last scheduled, executed, consumed or cancelled an
    ///         operation, or called {heartbeat}.
    uint48 public lastAdminActivity;
    /// @notice The successor authority; nonzero once it accepted and this manager is handed over.
    address public successor;
    uint48 private _guardianSerial;
    /// @notice The pre-registered recovery address, or zero.
    address public recoveryAddress;
    /// @notice The proposed successor, until it accepts or a later registration replaces or
    ///         withdraws it; zero when none is proposed.
    address public pendingSuccessor;
    /// @notice The {SuccessionProbe} the pending successor must re-point to this manager before
    ///         it can accept; zero when none is proposed.
    address public successionProbe;
    /// @dev The constructor's admin (the one-shot configurator), which takes no admin seat.
    ///      Storage, not immutable, so the runtime code hash does not depend on it.
    address private _initialAdmin;
    address[] private _managed;
    mapping(address target => bool) private _isManaged;
    mapping(bytes32 action => bool) private _struck;
    mapping(bytes32 operationId => Escalation) private _escalations;
    mapping(address candidate => Recovery) private _recoveries;
    mapping(bytes32 ballot => mapping(address guardian => bool)) private _voted;

    /// @notice `guardian` suspended `account`'s `roleId`: it no longer acts for that role.
    /// @param roleId The suspended role.
    /// @param account The suspended holder.
    /// @param guardian The guardian that called {suspend}.
    event RoleSuspended(uint64 indexed roleId, address indexed account, address indexed guardian);
    /// @notice A grant or revocation of `roleId` to `account` cleared its suspension: an ADMIN
    ///         grant or revocation, or the holder's own `renounceRole`.
    /// @param roleId The role whose suspension was lifted.
    /// @param account The holder whose suspension was lifted.
    event RoleSuspensionLifted(uint64 indexed roleId, address indexed account);
    /// @notice A guardian cancelled an operation on a protected action that it did not
    ///         schedule, so the next proposal of `action` enters the escalated lane.
    /// @param action The action key ({actionOf}).
    /// @param operationId The cancelled operation.
    event ActionStruck(bytes32 indexed action, bytes32 indexed operationId);
    /// @notice `operationId` was scheduled in the escalated lane.
    /// @param operationId The operation.
    /// @param nonce Its nonce; its ballot is `keccak256(abi.encode(operationId, nonce))`.
    /// @param action Its action key.
    /// @param seats The guardian seats counted for its majority.
    event OperationEscalated(
        bytes32 indexed operationId, uint32 nonce, bytes32 indexed action, uint256 seats
    );
    /// @notice `guardian` voted on `ballot`: to stop an escalated operation, or on a recovery
    ///         (ballot `keccak256(abi.encode(candidate, openedAt))`).
    /// @param ballot The ballot.
    /// @param guardian The voter.
    /// @param votes The ballot's votes so far.
    /// @param seats The seats its majority is counted against.
    event GuardianVoted(
        bytes32 indexed ballot, address indexed guardian, uint256 votes, uint256 seats
    );
    /// @notice A governed parameter changed.
    /// @param which The parameter.
    /// @param previous Its old value.
    /// @param value Its new value.
    event ParameterSet(Parameter indexed which, uint32 previous, uint32 value);
    /// @notice The pre-registered recovery address changed.
    /// @param previous The old address, or zero.
    /// @param next The new address, or zero.
    event RecoveryAddressSet(address indexed previous, address indexed next);
    /// @notice A dead-admin recovery for `candidate` opened.
    /// @param candidate The account it would make the only admin.
    /// @param readyAt When it can complete.
    /// @param registered Whether `candidate` is the recovery address: guardian votes then object
    ///        instead of approve.
    /// @param seats The guardian seats counted for its majority.
    event RecoveryOpened(address indexed candidate, uint48 readyAt, bool registered, uint256 seats);
    /// @notice A recovery completed: every former admin was revoked and `candidate` is the admin.
    /// @param candidate The new admin.
    event RecoveryCompleted(address indexed candidate);
    /// @notice `next` was proposed as the successor (or, when zero, the proposal withdrawn).
    ///         This manager keeps all its power until `next` accepts.
    /// @param next The proposed successor, or zero.
    /// @param probe The {SuccessionProbe} governed by `next` that `next` must re-point to this
    ///        manager before {acceptSuccession}, or zero.
    event SuccessorProposed(address indexed next, address probe);
    /// @notice `next` accepted: this manager was handed over and has no power from now on.
    /// @param next The successor authority that {migrate} moves every managed target to.
    event SuccessorAccepted(address indexed next);
    /// @notice `target` joined the managed list that {migrate} hands over.
    /// @param target The target.
    event TargetManaged(address indexed target);

    /// @notice `roleId` is not a zero-delay operational role (`Roles.isSuspendable`).
    error RoleNotSuspendable(uint64 roleId);
    /// @notice `account` has no record for `roleId`, or is already suspended.
    error NotSuspendable(uint64 roleId, address account);
    /// @notice A grant of `roleId` carries an execution delay below the role's class delay
    ///         (`Roles.executionDelay`).
    error DelayBelowClass(uint64 roleId, uint32 executionDelay);
    /// @notice `roleId` already has its cap of `cap` records.
    error SeatCapReached(uint64 roleId, uint256 cap);
    /// @notice This manager's own selectors cannot be remapped and it cannot be closed.
    error ManagerSelfConfiguration();
    /// @notice The caller is not an active guardian seated when the ballot opened.
    error NotAVoter(address account);
    /// @notice The caller already voted on this ballot.
    error AlreadyVoted(address account);
    /// @notice A compare-and-set expected value is stale.
    error ExpectedValueMismatch(uint256 expected, uint256 actual);
    /// @notice `value` is outside `which`'s compiled bounds.
    error ParameterOutOfBounds(Parameter which, uint32 value);
    /// @notice `next` is this manager, has no code, or cannot answer `canCall`.
    error InvalidSuccessor(address next);
    /// @notice No successor has accepted.
    error NoSuccessor();
    /// @notice The caller is not the pending successor.
    error NotPendingSuccessor(address caller);
    /// @notice The pending successor has not re-pointed `probe` to this manager.
    error SuccessionUnproven(address probe);
    /// @notice This manager has been handed over to its successor.
    error HandedOver();
    /// @notice `candidate` is the zero address or this manager, or the vote is of the wrong
    ///         kind for its recovery.
    error InvalidCandidate(address candidate);
    /// @notice No admin has been inactive for `RECOVERY_SILENCE`; the last activity was at
    ///         `since`.
    error AdminsNotSilent(uint48 since);
    /// @notice No live recovery for `candidate` (never opened, completed, or voided by admin
    ///         activity since it opened); on open, one is live already.
    error RecoveryNotLive(address candidate);
    /// @notice The recovery for `candidate` can complete at `readyAt`.
    error RecoveryNotReady(address candidate, uint48 readyAt);
    /// @notice The guardian decision does not allow the recovery: an unregistered candidate
    ///         lacks a majority's approval, or a majority objected to the registered one.
    error RecoveryRefused(address candidate);

    /// @param initialAdmin The one-shot configurator, which renounces the admin role once done;
    ///        while it holds it, it takes no admin seat.
    constructor(address initialAdmin) AccessManager(initialAdmin) {
        _initialAdmin = initialAdmin;
        _params = [uint32(60 days), 120 days, 365 days, 180 days, 5, 7];
        lastAdminActivity = Time.timestamp();
    }

    // ------------------------------------------------------------------ suspension

    /// @notice Suspends `account`'s `roleId` at once: it fails `hasRole`, and so `canCall` and
    ///         every check built on them, until an ADMIN grant or revocation of that role to
    ///         that account executes (30 days, guardian-vetoable) or the holder renounces the
    ///         role (`renounceRole` revokes it, which lifts the suspension with the role).
    ///         Guardians only.
    /// @dev `roleId` must be `Roles.isSuspendable` and `account` must hold or await it.
    /// @param roleId The role to suspend: `Roles.PLATFORM`, `Roles.CURATOR` or
    ///        `Roles.STORAGE_OPERATOR`.
    /// @param account The holder, or pending grantee, of `roleId`; must not be suspended already.
    function suspend(uint64 roleId, address account) external {
        address sender = _msgSender();
        (bool isGuardian,) = hasRole(Roles.GUARDIAN, sender);
        if (!isGuardian) revert AccessManagerUnauthorizedAccount(sender, Roles.GUARDIAN);
        if (!Roles.isSuspendable(roleId)) revert RoleNotSuspendable(roleId);
        (uint48 since,,,) = getAccess(roleId, account);
        if (since == 0 || _suspended[roleId][account]) revert NotSuspendable(roleId, account);
        _suspended[roleId][account] = true;
        emit RoleSuspended(roleId, account, sender);
    }

    /// @notice Whether `account`'s `roleId` is suspended.
    /// @param roleId The role to check.
    /// @param account The account to check.
    /// @return True from {suspend} until a grant, revocation or renouncement of the role lifts it.
    function isSuspended(uint64 roleId, address account) external view returns (bool) {
        return _suspended[roleId][account];
    }

    // ------------------------------------------------------------------ slow lane

    /// @notice Sets a governed parameter within its compiled bounds. `ADMIN`, slow lane: it is
    ///         scheduled at least `SLOW_DELAY` ahead, and any guardian may cancel it.
    /// @param which The parameter.
    /// @param expected Its current value (compare-and-set).
    /// @param value The new value.
    function setParameter(Parameter which, uint32 expected, uint32 value) external onlyAuthorized {
        uint32 current = _params[uint8(which)];
        if (current != expected) revert ExpectedValueMismatch(expected, current);
        (uint32 min, uint32 max) = parameterBounds(which);
        if (value < min || value > max) revert ParameterOutOfBounds(which, value);
        _params[uint8(which)] = value;
        emit ParameterSet(which, current, value);
    }

    /// @notice Pre-registers the account a dead-admin recovery may install without a guardian
    ///         majority's approval, unless a majority objects. `ADMIN`, slow lane.
    /// @param expected The current recovery address (compare-and-set).
    /// @param next The new recovery address, or zero to clear it.
    function setRecoveryAddress(address expected, address next) external onlyAuthorized {
        address current = recoveryAddress;
        if (current != expected) revert ExpectedValueMismatch(uint160(expected), uint160(current));
        if (next == address(this)) revert InvalidCandidate(next);
        recoveryAddress = next;
        emit RecoveryAddressSet(current, next);
    }

    /// @notice Proposes `next` as the successor, replacing any earlier proposal, or withdraws
    ///         the proposal when `next` is zero. Nothing is handed over yet: this manager keeps
    ///         all its power until `next` accepts ({acceptSuccession}). Creates a
    ///         {SuccessionProbe} governed by `next`. `ADMIN`, slow lane, escalated after a
    ///         guardian's cancellation (bounded veto, keyed on `next`).
    /// @dev A nonzero `next` must have code and answer `canCall` with two words. What else it
    ///      must implement is in the governance spec ("What a successor must implement").
    /// @param next The proposed successor authority, or zero to withdraw.
    function registerSuccessor(address next) external onlyAuthorized {
        address probe;
        if (next != address(0)) {
            if (next == address(this) || next.code.length == 0) revert InvalidSuccessor(next);
            try IAccessManager(next).canCall(address(this), address(this), bytes4(0)) { }
            catch {
                revert InvalidSuccessor(next);
            }
            probe = address(new SuccessionProbe(next));
        }
        pendingSuccessor = next;
        successionProbe = probe;
        delete _struck[_successionKey(next)];
        emit SuccessorProposed(next, probe);
    }

    /// @notice Completes the handover: from now on this manager answers no `canCall` and no
    ///         `hasRole`, and {migrate} moves every managed target to the caller. Only the
    ///         pending successor itself, and only once it has re-pointed {successionProbe} to
    ///         this manager, which proves it can originate calls and get a stock
    ///         `setAuthority` accepted on a contract it governs. One way.
    function acceptSuccession() external {
        address next = pendingSuccessor;
        if (next == address(0) || _msgSender() != next) revert NotPendingSuccessor(_msgSender());
        address probe = successionProbe;
        if (IAccessManaged(probe).authority() != address(this)) revert SuccessionUnproven(probe);
        successor = next;
        delete pendingSuccessor;
        delete successionProbe;
        emit SuccessorAccepted(next);
    }

    /// @notice Moves every managed target with an index in `[from, to)` that still answers this
    ///         manager as its authority to the successor. Anyone, once a successor has accepted.
    ///         All or nothing: a failing target reverts the whole call, so a caller leaves a
    ///         failing index out of its range and nothing else waits on it.
    /// @dev Each call to a target forwards all available gas. `to` is clamped to the list length.
    /// @param from The first index.
    /// @param to One past the last index.
    function migrate(uint256 from, uint256 to) external {
        address next = successor;
        if (next == address(0)) revert NoSuccessor();
        uint256 count = _managed.length;
        if (to > count) to = count;
        for (uint256 i = from; i < to; ++i) {
            address target = _managed[i];
            if (target.code.length == 0 || IAccessManaged(target).authority() != address(this)) {
                continue;
            }
            IAccessManaged(target).setAuthority(next);
        }
    }

    // ------------------------------------------------------------------ dead-admin recovery

    /// @notice Proves an admin is alive: resets the inactivity clock, which voids every open
    ///         recovery. Any active `ADMIN` holder, at once.
    function heartbeat() external {
        address sender = _msgSender();
        (bool isAdmin,) = hasRole(Roles.ADMIN, sender);
        if (!isAdmin) revert AccessManagerUnauthorizedAccount(sender, Roles.ADMIN);
        lastAdminActivity = Time.timestamp();
    }

    /// @notice Opens a recovery that would make `candidate` the only admin. Anyone, once no
    ///         admin has acted for `RECOVERY_SILENCE`; it can complete `RECOVERY_DELAY` later.
    /// @param candidate The proposed admin: the recovery address (a guardian majority may
    ///        object) or any other account (a guardian majority must approve).
    function openRecovery(address candidate) external {
        if (successor != address(0)) revert HandedOver();
        if (candidate == address(0) || candidate == address(this)) {
            revert InvalidCandidate(candidate);
        }
        uint48 now_ = Time.timestamp();
        uint48 quietSince = lastAdminActivity;
        if (now_ < uint256(quietSince) + _params[uint8(Parameter.RECOVERY_SILENCE)]) {
            revert AdminsNotSilent(quietSince);
        }
        if (_recoveries[candidate].openedAt > quietSince) revert RecoveryNotLive(candidate);
        uint48 readyAt = now_ + _params[uint8(Parameter.RECOVERY_DELAY)];
        uint16 seats = uint16(_seats[Roles.GUARDIAN].length());
        bool registered = candidate == recoveryAddress;
        _recoveries[candidate] = Recovery(now_, readyAt, _guardianSerial, seats, 0, registered);
        emit RecoveryOpened(candidate, readyAt, registered, seats);
    }

    /// @notice Approves the live recovery of an unregistered `candidate`. Each guardian seated
    ///         when it opened, once.
    /// @param candidate The candidate.
    function approveRecovery(address candidate) external {
        _recoveryVote(candidate, false);
    }

    /// @notice Objects to the live recovery of the registered recovery address. Each guardian
    ///         seated when it opened, once.
    /// @param candidate The candidate.
    function objectToRecovery(address candidate) external {
        _recoveryVote(candidate, true);
    }

    /// @notice Completes a ready recovery: revokes every `ADMIN` record and grants `candidate`
    ///         `ADMIN` with the 30-day delay, active at once. Anyone. Refused while `candidate`
    ///         holds or awaits `GUARDIAN` or `PAUSER`: the veto stays separate from the action
    ///         (`InvalidCandidate`).
    /// @param candidate The candidate.
    function completeRecovery(address candidate) external {
        Recovery memory r = _liveRecovery(candidate);
        (uint48 guardianSince,,,) = getAccess(Roles.GUARDIAN, candidate);
        (uint48 pauserSince,,,) = getAccess(Roles.PAUSER, candidate);
        if (guardianSince != 0 || pauserSince != 0) revert InvalidCandidate(candidate);
        if (Time.timestamp() < r.readyAt) revert RecoveryNotReady(candidate, r.readyAt);
        if (_decided(r.votes, r.seats) == r.registered) revert RecoveryRefused(candidate);
        delete _recoveries[candidate];
        address[] memory admins = _seats[Roles.ADMIN].values();
        for (uint256 i = 0; i < admins.length; ++i) {
            _revokeRole(Roles.ADMIN, admins[i]);
        }
        _grantRole(Roles.ADMIN, candidate, 0, Roles.SUCCESSOR);
        lastAdminActivity = Time.timestamp();
        emit RecoveryCompleted(candidate);
    }

    // ------------------------------------------------------------------ views

    /// @notice The current value of a governed parameter.
    /// @param which The parameter.
    /// @return The value: a duration in seconds, or a seat count.
    function parameter(Parameter which) external view returns (uint32) {
        return _params[uint8(which)];
    }

    /// @notice A governed parameter's compiled bounds. The minimum is the guarantee no
    ///         governance action can go below; the maximum bounds the wait or the work.
    /// @param which The parameter.
    /// @return min The lowest allowed value.
    /// @return max The highest allowed value.
    function parameterBounds(Parameter which) public pure returns (uint32 min, uint32 max) {
        if (which == Parameter.SLOW_DELAY) return (30 days, 365 days);
        if (which == Parameter.ESCALATED_DELAY) return (60 days, 730 days);
        if (which == Parameter.RECOVERY_SILENCE) return (180 days, 1095 days);
        if (which == Parameter.RECOVERY_DELAY) return (90 days, 730 days);
        return (3, 16); // seat caps; 16 also bounds the recovery loop
    }

    /// @notice The ADMIN or GUARDIAN records, active or pending; empty for any other role.
    /// @param roleId The role.
    /// @return The accounts.
    function seatHolders(uint64 roleId) external view returns (address[] memory) {
        return _seats[roleId].values();
    }

    /// @notice Every target {migrate} hands over, in index order.
    /// @return The targets.
    function managedTargets() external view returns (address[] memory) {
        return _managed;
    }

    /// @notice The action key of a call, or zero when the bounded veto does not cover it. A
    ///         guardian's removal, `revokeRole(GUARDIAN or PAUSER, account)` on this manager,
    ///         keys on the account alone; `registerSuccessor(next)` on `next`. Arguments must be
    ///         clean words; trailing bytes and the scheduler do not change the key.
    /// @param target The call's target.
    /// @param data The call's data.
    /// @return The key.
    function actionOf(address target, bytes calldata data) public view returns (bytes32) {
        if (target != address(this) || data.length < 0x24) return 0;
        bytes4 selector = bytes4(data[:4]);
        uint256 a = uint256(bytes32(data[4:0x24]));
        if (selector == this.registerSuccessor.selector) {
            // Casting to uint160 is safe: the upper 96 bits were just checked to be zero.
            // forge-lint: disable-next-line(unsafe-typecast)
            return a >> 160 == 0 ? _successionKey(address(uint160(a))) : bytes32(0);
        }
        if (selector != this.revokeRole.selector || data.length < 0x44) return 0;
        uint256 b = uint256(bytes32(data[0x24:0x44]));
        if ((a != Roles.GUARDIAN && a != Roles.PAUSER) || b >> 160 != 0) return 0;
        // Casting to uint160 is safe: the upper 96 bits were just checked to be zero.
        // forge-lint: disable-next-line(unsafe-typecast)
        return _removalKey(address(uint160(b)));
    }

    /// @notice Whether the next proposal of `action` enters the escalated lane.
    /// @param action The action key.
    /// @return True from a guardian's cancellation until the action executes.
    function isStruck(bytes32 action) external view returns (bool) {
        return _struck[action];
    }

    /// @notice The escalated-lane record of `operationId`, live while `nonce` is the
    ///         operation's current nonce and the operation is scheduled.
    /// @param operationId The operation.
    /// @return The record.
    function getEscalation(bytes32 operationId) external view returns (Escalation memory) {
        return _escalations[operationId];
    }

    /// @notice The recovery record of `candidate`, live while `openedAt` is later than
    ///         {lastAdminActivity}.
    /// @param candidate The candidate.
    /// @return The record.
    function getRecovery(address candidate) external view returns (Recovery memory) {
        return _recoveries[candidate];
    }

    // ------------------------------------------------------------------ overrides

    /// @inheritdoc AccessManager
    /// @dev Answers `(false, 0)` once handed over.
    function canCall(address caller, address target, bytes4 selector)
        public
        view
        override
        returns (bool immediate, uint32 delay)
    {
        if (successor != address(0)) return (false, 0);
        return super.canCall(caller, target, selector);
    }

    /// @inheritdoc AccessManager
    /// @dev A suspended holder is not a member, and nobody is once handed over.
    function hasRole(uint64 roleId, address account)
        public
        view
        override
        returns (bool isMember, uint32 executionDelay)
    {
        if (successor != address(0)) return (false, 0);
        (isMember, executionDelay) = super.hasRole(roleId, account);
        if (isMember && Roles.isSuspendable(roleId) && _suspended[roleId][account]) {
            isMember = false;
        }
    }

    /// @inheritdoc AccessManager
    /// @dev Adds `SLOW_DELAY` to {setParameter}, {setRecoveryAddress} and {registerSuccessor},
    ///      and `ESCALATED_DELAY` to a struck action ({actionOf}), whose operation is then
    ///      recorded for a guardian majority. Counts as admin activity.
    function schedule(address target, bytes calldata data, uint48 when)
        public
        override
        returns (bytes32 operationId, uint32 nonce)
    {
        _touch(_msgSender());
        uint256 extra;
        if (target == address(this) && data.length >= 4) {
            bytes4 selector = bytes4(data[:4]);
            if (
                selector == this.setParameter.selector
                    || selector == this.setRecoveryAddress.selector
                    || selector == this.registerSuccessor.selector
            ) extra = _params[uint8(Parameter.SLOW_DELAY)];
        }
        bytes32 action = actionOf(target, data);
        bool escalate = action != 0 && _struck[action];
        if (escalate && _params[uint8(Parameter.ESCALATED_DELAY)] > extra) {
            extra = _params[uint8(Parameter.ESCALATED_DELAY)];
        }
        uint256 earliest = Time.timestamp() + extra;
        // Casting to uint48 is safe: a uint48 timestamp plus a uint32 delay fits until year 8.9M.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (extra != 0 && when < earliest) when = uint48(earliest);
        (operationId, nonce) = super.schedule(target, data, when);
        if (escalate) {
            uint16 seats = uint16(_seats[Roles.GUARDIAN].length());
            _escalations[operationId] = Escalation(nonce, _guardianSerial, seats, 0);
            emit OperationEscalated(operationId, nonce, action, seats);
        }
    }

    /// @inheritdoc AccessManager
    /// @dev On a live escalated operation, a call by anyone but its scheduler is a guardian's
    ///      vote, and cancels only once the votes decide ({_decided}). There Rule 2 gives way to
    ///      the majority: a guardian whose removal it is votes with its seat like every other
    ///      seated guardian, but never decides alone (a decision needs a majority of the seats
    ///      and two votes). Without that vote a compromised admin with one dishonest guardian
    ///      could remove honest guardians at three or four seats; with it, a colluding pair is
    ///      a majority only at three (governance spec, the escalated lane). A guardian's cancellation
    ///      of a protected action ({actionOf}) it did not schedule strikes the action. Counts
    ///      as admin activity.
    function cancel(address caller, address target, bytes calldata data)
        public
        override
        returns (uint32)
    {
        address sender = _msgSender();
        _touch(sender);
        bytes32 operationId = hashOperation(caller, target, data);
        Escalation storage e = _escalations[operationId];
        bool escalated = _isLive(operationId, e);
        if (escalated && sender != caller) {
            bytes32 ballot = keccak256(abi.encode(operationId, e.nonce));
            e.votes = _vote(ballot, e.serial, e.votes, e.seats);
            if (!_decided(e.votes, e.seats)) return e.nonce;
        }
        uint32 nonce = super.cancel(caller, target, data);
        (bool isGuardian,) = hasRole(Roles.GUARDIAN, sender);
        bytes32 action = actionOf(target, data);
        if (!escalated && sender != caller && isGuardian && action != 0) {
            _struck[action] = true;
            emit ActionStruck(action, operationId);
        }
        return nonce;
    }

    /// @inheritdoc AccessManager
    /// @dev Counts as admin activity of the sender before the call, immediate or scheduled
    ///      (only an active admin moves the clock; a failed call reverts the update with it).
    function execute(address target, bytes calldata data) public payable override returns (uint32) {
        _touch(_msgSender());
        return super.execute(target, data);
    }

    /// @inheritdoc AccessManager
    /// @dev Counts as admin activity of `caller`: a direct DELAYED `restricted` call on a managed
    ///      contract makes that contract call this, naming the scheduling admin, so it counts
    ///      like {execute} of the same operation. A direct IMMEDIATE call on a managed contract
    ///      never reaches this manager's state (it only asks `canCall`, a view), so it cannot
    ///      count.
    function consumeScheduledOp(address caller, bytes calldata data) public override {
        super.consumeScheduledOp(caller, data);
        _touch(caller);
    }

    /// @inheritdoc AccessManager
    /// @dev Counts as admin activity of the sender: a direct call of a delayed manager function
    ///      (an admin's always is: its class delay is at least 30 days) consumes its schedule here.
    ///      Here `_msgSender()` is the caller of a manager function; when a managed contract
    ///      consumes a schedule through {consumeScheduledOp}, the sender is that contract and
    ///      this touch is a no-op, the counting being done there for the scheduling admin. A
    ///      direct immediate `restricted` call on a managed contract never reaches the manager's
    ///      state (it only asks `canCall`, a view), so it cannot count; admins act through
    ///      {execute}, a direct delayed call, or {heartbeat}.
    function _consumeScheduledOp(bytes32 operationId) internal override returns (uint32) {
        _touch(_msgSender());
        return super._consumeScheduledOp(operationId);
    }

    /// @inheritdoc AccessManager
    /// @dev Enforces the class delays (every grant or re-grant of a role in {Roles} carries at
    ///      least `Roles.executionDelay`, whoever is the role's admin) and the seat caps,
    ///      numbers new guardian seats and lifts a suspension. Neither applies to the
    ///      constructor's admin, and that admin's seat does not count against the cap.
    function _grantRole(uint64 roleId, address account, uint32 grantDelay, uint32 executionDelay)
        internal
        override
        returns (bool newMember)
    {
        bool constructing = address(this).code.length == 0;
        if (!constructing && roleId < Roles.COUNT && executionDelay < Roles.executionDelay(roleId))
        {
            revert DelayBelowClass(roleId, executionDelay);
        }
        _lift(roleId, account);
        newMember = super._grantRole(roleId, account, grantDelay, executionDelay);
        if (newMember && (roleId == Roles.ADMIN || roleId == Roles.GUARDIAN)) {
            EnumerableSet.AddressSet storage seats = _seats[roleId];
            uint256 cap = _params[
                uint8(roleId == Roles.ADMIN ? Parameter.ADMIN_SEATS : Parameter.GUARDIAN_SEATS)
            ];
            if (!constructing) {
                uint256 used = seats.length();
                if (roleId == Roles.ADMIN && seats.contains(_initialAdmin)) --used;
                if (used >= cap) revert SeatCapReached(roleId, cap);
            }
            seats.add(account);
            if (roleId == Roles.GUARDIAN) _serialOf[account] = ++_guardianSerial;
        }
    }

    /// @inheritdoc AccessManager
    /// @dev Frees the seat and lifts a suspension; once an account holds neither `GUARDIAN` nor
    ///      `PAUSER`, its removal is no longer struck.
    function _revokeRole(uint64 roleId, address account) internal override returns (bool revoked) {
        _lift(roleId, account);
        revoked = super._revokeRole(roleId, account);
        if (!revoked) return revoked;
        if (roleId == Roles.ADMIN || roleId == Roles.GUARDIAN) _seats[roleId].remove(account);
        if (roleId == Roles.GUARDIAN || roleId == Roles.PAUSER) {
            uint64 other = roleId == Roles.GUARDIAN ? Roles.PAUSER : Roles.GUARDIAN;
            (uint48 since,,,) = getAccess(other, account);
            if (since == 0) delete _struck[_removalKey(account)];
        }
    }

    /// @inheritdoc AccessManager
    /// @dev Refused for this manager; any other target joins the managed list.
    function _setTargetFunctionRole(address target, bytes4 selector, uint64 roleId)
        internal
        override
    {
        if (target == address(this)) revert ManagerSelfConfiguration();
        _manage(target);
        super._setTargetFunctionRole(target, selector, roleId);
    }

    /// @inheritdoc AccessManager
    /// @dev Any target other than this manager joins the managed list.
    function _setTargetAdminDelay(address target, uint32 newDelay) internal override {
        _manage(target);
        super._setTargetAdminDelay(target, newDelay);
    }

    /// @inheritdoc AccessManager
    /// @dev Refused for this manager, whose added functions must stay reachable.
    function _setTargetClosed(address target, bool closed) internal override {
        if (target == address(this)) revert ManagerSelfConfiguration();
        super._setTargetClosed(target, closed);
    }

    /// @inheritdoc AccessManager
    /// @dev Rules 1 to 3 outside the escalated lane; a live escalated operation only by its
    ///      scheduler or once a guardian majority decided, a majority in which the guardian a
    ///      removal names has its vote ({cancel}).
    function _canCancel(address caller, address target, bytes calldata data)
        internal
        view
        override
        returns (bool)
    {
        address sender = _msgSender();
        if (caller == sender) return true;
        bytes32 operationId = hashOperation(caller, target, data);
        Escalation storage e = _escalations[operationId];
        if (_isLive(operationId, e)) return _decided(e.votes, e.seats);
        bool revocation = target == address(this) && data.length >= 4
            && bytes4(data[:4]) == this.revokeRole.selector;
        if (revocation && _revokesRoleOf(data, sender)) return false; // Rule 2
        (bool isGuardian,) = hasRole(Roles.GUARDIAN, sender);
        if (revocation) return isGuardian; // Rule 3
        return isGuardian || super._canCancel(caller, target, data); // Rule 1
    }

    // ------------------------------------------------------------------ private

    function _recoveryVote(address candidate, bool objection) private {
        Recovery memory r = _liveRecovery(candidate);
        if (r.registered != objection) revert InvalidCandidate(candidate);
        _recoveries[candidate].votes =
            _vote(keccak256(abi.encode(candidate, r.openedAt)), r.serial, r.votes, r.seats);
    }

    function _liveRecovery(address candidate) private view returns (Recovery memory r) {
        if (successor != address(0)) revert HandedOver();
        r = _recoveries[candidate];
        if (r.openedAt <= lastAdminActivity) revert RecoveryNotLive(candidate);
    }

    /// @dev Records the sender's vote on `ballot` and returns the new count. The sender must be
    ///      an active guardian whose seat serial is at most `serial`.
    function _vote(bytes32 ballot, uint48 serial, uint16 votes, uint16 seats)
        private
        returns (uint16)
    {
        address voter = _msgSender();
        (bool isGuardian,) = hasRole(Roles.GUARDIAN, voter);
        uint48 seat = _serialOf[voter];
        if (!isGuardian || seat == 0 || seat > serial) revert NotAVoter(voter);
        if (_voted[ballot][voter]) revert AlreadyVoted(voter);
        _voted[ballot][voter] = true;
        ++votes;
        emit GuardianVoted(ballot, voter, votes, seats);
        return votes;
    }

    /// @dev A guardian decision: a majority of the counted seats, and never fewer than two
    ///      guardians, so no single guardian decides alone.
    function _decided(uint16 votes, uint16 seats) private pure returns (bool) {
        return votes >= 2 && uint256(votes) * 2 > seats;
    }

    function _isLive(bytes32 operationId, Escalation storage e) private view returns (bool) {
        return e.nonce != 0 && e.nonce == getNonce(operationId) && getSchedule(operationId) != 0;
    }

    function _touch(address account) private {
        (bool isAdmin,) = hasRole(Roles.ADMIN, account);
        if (isAdmin) lastAdminActivity = Time.timestamp();
    }

    function _manage(address target) private {
        if (target == address(this) || _isManaged[target]) return;
        _isManaged[target] = true;
        _managed.push(target);
        emit TargetManaged(target);
    }

    function _lift(uint64 roleId, address account) private {
        if (!_suspended[roleId][account]) return;
        delete _suspended[roleId][account];
        emit RoleSuspensionLifted(roleId, account);
    }

    function _removalKey(address account) private pure returns (bytes32) {
        return keccak256(abi.encode(IAccessManager.revokeRole.selector, account));
    }

    function _successionKey(address next) private pure returns (bytes32) {
        return keccak256(abi.encode(WorksAccessManager.registerSuccessor.selector, next));
    }

    /// @dev True when `data`, a `revokeRole` call, names `account`. Never reverts: shorter
    ///      data, or an address word with dirty upper bits, cannot execute as `revokeRole`, so
    ///      it falls through to the other rules.
    function _revokesRoleOf(bytes calldata data, address account) private pure returns (bool) {
        if (data.length < 0x44) return false;
        return uint256(bytes32(data[0x24:0x44])) == uint256(uint160(account));
    }
}
