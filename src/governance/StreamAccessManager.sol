// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";
import { Roles } from "./Roles.sol";

/// @title StreamAccessManager
/// @notice The OpenZeppelin 5 `AccessManager` that governs every 6529 Stream contract, with one
///         authority and one brake (governance spec, GV-1 to GV-9):
///         - The network: one address that holds every network role (`Roles.isNetworkRole`)
///           with that role's class delay: no delay, 24 hours, 3 days or 7 days. Nobody else
///           can be granted a network role. It hands over in two steps ({transferNetwork},
///           then {acceptNetwork} by the new address).
///         - The brake: one optional address that can make one scheduled operation wait
///           `Roles.BRAKE_DELAY` past its ready time ({brakeOnce}), once per operation.
///         Operational keys (pauser, curation signers, storage operator, platform, curator)
///         are ordinary OpenZeppelin roles the network grants and revokes.
/// @dev Everything else is stock OpenZeppelin: scheduling, execution, cancellation (the
///      scheduler, or the network as the admin and the default guardian of every role), and
///      `updateAuthority` to move a managed contract to another manager. The inherited
///      `Multicall` self-delegatecall only batches calls into this contract; it is the one
///      sanctioned exemption to the no-delegatecall rule. This manager's own selectors cannot
///      be remapped and it cannot be closed, so {transferNetwork} and {setBrake} always need
///      the network at the 7-day class.
contract StreamAccessManager is AccessManager {
    /// @notice The network: the one holder of every network role, or zero before the first
    ///         {acceptNetwork}.
    address public network;
    /// @notice The address {transferNetwork} named, until it accepts; zero when none.
    address public pendingNetwork;
    /// @notice The brake, or zero when there is none.
    address public brake;
    /// @dev Set by {brakeOnce}; cleared when the operation runs.
    mapping(bytes32 operationId => uint48) private _notBefore;
    /// @dev How many times each account became a member of each role.
    mapping(uint64 roleId => mapping(address account => uint32)) private _grants;

    /// @notice The network named `next` as its successor; it takes over on {acceptNetwork}.
    /// @param network The current network.
    /// @param next The proposed network, or zero to withdraw the proposal.
    event NetworkTransferStarted(address indexed network, address indexed next);
    /// @notice `next` accepted and is the network from now on; `previous` holds none of the
    ///         network roles. Operational roles it granted, to itself included, and a brake stay
    ///         until the new network revokes them.
    /// @param previous The former network, or zero at genesis.
    /// @param next The new network.
    event NetworkTransferred(address indexed previous, address indexed next);
    /// @notice The brake changed.
    /// @param previous The former brake, or zero.
    /// @param next The new brake, or zero for none.
    event BrakeSet(address indexed previous, address indexed next);
    /// @notice The brake delayed `operationId`: it cannot run before `notBefore`.
    /// @param operationId The scheduled operation.
    /// @param notBefore Its ready time plus `Roles.BRAKE_DELAY`.
    event OperationBraked(bytes32 indexed operationId, uint48 notBefore);

    /// @notice Network roles are held by the network address alone and cannot be granted.
    error NetworkRoleNotGrantable(uint64 roleId);
    /// @notice This manager's own selectors cannot be remapped and it cannot be closed.
    error ManagerSelfConfiguration();
    /// @notice The caller is not the pending network.
    error NotPendingNetwork(address caller);
    /// @notice The caller is not the brake.
    error NotBrake(address caller);
    /// @notice `operationId` is not scheduled (never, cancelled, executed or expired); an
    ///         action with no delay is never scheduled.
    error NotBrakeable(bytes32 operationId);
    /// @notice The brake already delayed `operationId`; the mark lasts until it runs.
    error AlreadyBraked(bytes32 operationId);
    /// @notice The brake delayed `operationId` until `notBefore`.
    error BrakeNotElapsed(bytes32 operationId, uint48 notBefore);

    /// @param initialAdmin The installer (`GovernanceConfigurator`). Until it renounces
    ///        `ADMIN`, it holds every network role with no delay, to install genesis in one
    ///        transaction; it names the network with {transferNetwork}.
    constructor(address initialAdmin) AccessManager(initialAdmin) { }

    // ------------------------------------------------------------------ network and brake

    /// @notice Names `next` as the next network, replacing any earlier proposal; zero
    ///         withdraws it. Nothing changes until `next` calls {acceptNetwork}. `ADMIN`: the
    ///         network at 7 days.
    /// @param next The proposed network, or zero.
    function transferNetwork(address next) external onlyAuthorized {
        pendingNetwork = next;
        emit NetworkTransferStarted(network, next);
    }

    /// @notice Makes the caller the network. Only the pending network itself, which proves it
    ///         can make a call. This moves the network address and the network roles: the
    ///         former network holds none of them from now on, and the operations it scheduled
    ///         under a network role can no longer run. It does not touch operational roles (a
    ///         PLATFORM or PAUSER grant, the former network's own included) or the brake: they
    ///         stay, and an operation scheduled under such a grant can still run, until the new
    ///         network revokes or replaces them.
    function acceptNetwork() external {
        address next = pendingNetwork;
        if (next == address(0) || _msgSender() != next) revert NotPendingNetwork(_msgSender());
        emit NetworkTransferred(network, next);
        network = next;
        delete pendingNetwork;
    }

    /// @notice Sets the brake, or removes it with zero. `ADMIN`: the network at 7 days.
    /// @param next The new brake, or zero.
    function setBrake(address next) external onlyAuthorized {
        emit BrakeSet(brake, next);
        brake = next;
    }

    /// @notice Makes the scheduled operation `operationId` wait until its ready time plus
    ///         `Roles.BRAKE_DELAY`. The brake only, once per operation: the mark stays until
    ///         the operation runs, so cancelling and scheduling it again does not clear it.
    /// @param operationId The scheduled operation (`hashOperation(caller, target, data)`).
    function brakeOnce(bytes32 operationId) external {
        if (_msgSender() != brake) revert NotBrake(_msgSender());
        if (_notBefore[operationId] != 0) revert AlreadyBraked(operationId);
        uint48 ready = getSchedule(operationId);
        if (ready == 0) revert NotBrakeable(operationId);
        uint48 until = ready + Roles.BRAKE_DELAY;
        _notBefore[operationId] = until;
        emit OperationBraked(operationId, until);
    }

    /// @notice When the brake let `operationId` run: zero when it was never braked or has run
    ///         since.
    /// @param operationId The operation.
    /// @return The earliest time it can run.
    function notBefore(bytes32 operationId) external view returns (uint48) {
        return _notBefore[operationId];
    }

    /// @notice How many times `account` became a member of `roleId`: every grant to a
    ///         non-member counts, so a revocation followed by a new grant always changes it,
    ///         even within one second (the grant's `since` alone may not).
    /// @param roleId The role.
    /// @param account The account.
    /// @return The number of grants that made `account` a member.
    function grantCount(uint64 roleId, address account) external view returns (uint32) {
        return _grants[roleId][account];
    }

    // ------------------------------------------------------------------ overrides

    /// @inheritdoc AccessManager
    /// @dev A network role answers for {network} alone, with the role's class delay; while the
    ///      installer holds its constructor `ADMIN` record, it also answers for the installer,
    ///      with no delay.
    function hasRole(uint64 roleId, address account)
        public
        view
        override
        returns (bool isMember, uint32 executionDelay)
    {
        if (!Roles.isNetworkRole(roleId)) return super.hasRole(roleId, account);
        if (account != address(0) && account == network) {
            return (true, Roles.executionDelay(roleId));
        }
        (isMember,) = super.hasRole(Roles.ADMIN, account);
        return (isMember, 0);
    }

    /// @inheritdoc AccessManager
    /// @dev One week after the ready time, as upstream, plus the brake's delay, so a braked
    ///      operation keeps a week in which it can run.
    function expiration() public pure override returns (uint32) {
        return 1 weeks + Roles.BRAKE_DELAY;
    }

    /// @inheritdoc AccessManager
    /// @dev Refuses a braked operation before its mark, and clears the mark when it runs.
    function _consumeScheduledOp(bytes32 operationId) internal override returns (uint32) {
        uint48 until = _notBefore[operationId];
        if (until != 0) {
            if (Time.timestamp() < until) revert BrakeNotElapsed(operationId, until);
            delete _notBefore[operationId];
        }
        return super._consumeScheduledOp(operationId);
    }

    /// @inheritdoc AccessManager
    /// @dev Refuses a network role, except the constructor's grant to the installer.
    function _grantRole(uint64 roleId, address account, uint32 grantDelay, uint32 executionDelay)
        internal
        override
        returns (bool)
    {
        if (Roles.isNetworkRole(roleId) && address(this).code.length != 0) {
            revert NetworkRoleNotGrantable(roleId);
        }
        bool newMember = super._grantRole(roleId, account, grantDelay, executionDelay);
        if (newMember) ++_grants[roleId][account];
        return newMember;
    }

    /// @inheritdoc AccessManager
    /// @dev Refused for this manager.
    function _setTargetFunctionRole(address target, bytes4 selector, uint64 roleId)
        internal
        override
    {
        if (target == address(this)) revert ManagerSelfConfiguration();
        super._setTargetFunctionRole(target, selector, roleId);
    }

    /// @inheritdoc AccessManager
    /// @dev Refused for this manager, whose added functions must stay reachable.
    function _setTargetClosed(address target, bool closed) internal override {
        if (target == address(this)) revert ManagerSelfConfiguration();
        super._setTargetClosed(target, closed);
    }
}
