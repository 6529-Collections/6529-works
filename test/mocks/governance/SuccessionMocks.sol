// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// @notice A governed target whose `setAuthority` always refuses, so a migration piece that
///         includes it reverts and callers leave its index out.
contract RefusingTargetMock is AccessManaged {
    error Refused();

    constructor(address authority_) AccessManaged(authority_) { }

    function setAuthority(address) public pure override {
        revert Refused();
    }
}

/// @notice A governed target whose `setAuthority` first burns `units` x 10,000 gas, standing
///         for a target whose authority change got more expensive under a repricing.
contract BurningTargetMock is AccessManaged {
    uint256 public immutable units;
    uint256 private _sink;

    constructor(address authority_, uint256 units_) AccessManaged(authority_) {
        units = units_;
    }

    function setAuthority(address next) public override {
        uint256 stop = gasleft() - units * 10_000;
        while (gasleft() > stop) {
            _sink = _sink + 1;
        }
        super.setAuthority(next);
    }
}

/// @notice An authority that cannot answer `canCall`; it must never become a successor.
contract RevertingAuthorityMock {
    function canCall(address, address, bytes4) external pure returns (bool, uint32) {
        revert("no answer");
    }
}

/// @notice An authority that answers `canCall` (always yes) but can originate no call at all:
///         a governor whose `execute` is missing or broken. It may be proposed as a successor,
///         but it can never accept, so the manager keeps its power.
contract CanCallOnlyAuthorityMock {
    function canCall(address, address, bytes4) external pure returns (bool, uint32) {
        return (true, 0);
    }
}

/// @notice An authority with one hard-wired call, `accept`, and no general call path: it can
///         reach the manager but cannot re-point a contract it governs, so it never accepts.
contract AcceptOnlyAuthorityMock {
    function canCall(address, address, bytes4) external pure returns (bool, uint32) {
        return (true, 0);
    }

    function accept(address manager) external {
        (bool ok, bytes memory reason) = manager.call(abi.encodeWithSignature("acceptSuccession()"));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }
}

/// @notice A deliberately non-OpenZeppelin authority implementing only what a 6529 Works
///         permanent contract needs from its authority (governance spec, "What a successor must
///         implement"): `canCall` with a delay, `consumeScheduledOp` for delayed calls, an
///         arbitrary-call `execute` with a self-execution guard (so it can move targets on
///         again), and `hasRole`/`getAccess` for the curation verifier's signer reads. Its own
///         rules are a flat permission table run by one governor account; cancellation by the
///         scheduler, the governor or an emergency account stands in for a guardian veto.
contract MinimalAuthority {
    struct Permission {
        bool allowed;
        uint32 delay;
    }

    address public immutable governor;
    mapping(
        address target => mapping(bytes4 selector => mapping(address caller => Permission))
    ) public permissions;
    mapping(bytes32 operationId => uint48 readyAt) public readyAt;
    mapping(address account => bool) public emergency;
    mapping(uint64 role => mapping(address account => uint48 since)) public memberSince;
    bytes32 private _executing;

    event Permitted(address indexed caller, address indexed target, bytes4 selector, uint32 delay);
    event Scheduled(bytes32 indexed operationId, uint48 readyAt);
    event Cancelled(bytes32 indexed operationId);
    event Consumed(bytes32 indexed operationId);

    error NotGovernor();
    error NotPermitted(address caller, address target, bytes4 selector);
    error NotScheduled(bytes32 operationId);
    error NotReady(bytes32 operationId);
    error NotConsuming(address target);
    error CallFailed(bytes reason);

    constructor(address governor_) {
        governor = governor_;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    // ------------------------------------------------------------------ configuration

    function permit(address caller, address target, bytes4 selector, uint32 delay)
        external
        onlyGovernor
    {
        permissions[target][selector][caller] = Permission(true, delay);
        emit Permitted(caller, target, selector, delay);
    }

    function setEmergency(address account, bool on) external onlyGovernor {
        emergency[account] = on;
    }

    function setMember(uint64 role, address account, bool member) external onlyGovernor {
        memberSince[role][account] = member ? uint48(block.timestamp) : 0;
    }

    // ------------------------------------------------------------------ IAuthority

    function canCall(address caller, address target, bytes4 selector)
        external
        view
        returns (bool immediate, uint32 delay)
    {
        if (caller == address(this)) {
            return (_executing == keccak256(abi.encode(target, selector)), 0);
        }
        Permission memory p = permissions[target][selector][caller];
        if (!p.allowed) return (false, 0);
        return (p.delay == 0, p.delay);
    }

    function consumeScheduledOp(address caller, bytes calldata data) external {
        if (
            IAccessManaged(msg.sender).isConsumingScheduledOp()
                != IAccessManaged.isConsumingScheduledOp.selector
        ) revert NotConsuming(msg.sender);
        bytes32 id = keccak256(abi.encode(caller, msg.sender, data));
        uint48 ready = readyAt[id];
        if (ready == 0) revert NotScheduled(id);
        if (ready > block.timestamp) revert NotReady(id);
        delete readyAt[id];
        emit Consumed(id);
    }

    // ------------------------------------------------------------------ its own lane

    function schedule(address target, bytes calldata data) external returns (bytes32 id) {
        Permission memory p = permissions[target][bytes4(data)][msg.sender];
        if (!p.allowed || p.delay == 0) revert NotPermitted(msg.sender, target, bytes4(data));
        id = keccak256(abi.encode(msg.sender, target, data));
        uint48 ready = uint48(block.timestamp) + p.delay;
        readyAt[id] = ready;
        emit Scheduled(id, ready);
    }

    function cancel(address caller, address target, bytes calldata data) external {
        if (msg.sender != caller && msg.sender != governor && !emergency[msg.sender]) {
            revert NotPermitted(msg.sender, target, bytes4(data));
        }
        bytes32 id = keccak256(abi.encode(caller, target, data));
        if (readyAt[id] == 0) revert NotScheduled(id);
        delete readyAt[id];
        emit Cancelled(id);
    }

    /// @notice Any call as this authority, `setAuthority` on a target included.
    function execute(address target, bytes calldata data)
        external
        onlyGovernor
        returns (bytes memory result)
    {
        bytes32 previous = _executing;
        _executing = keccak256(abi.encode(target, bytes4(data)));
        bool ok;
        (ok, result) = target.call(data);
        _executing = previous;
        if (!ok) revert CallFailed(result);
    }

    // ------------------------------------------------------------------ signer reads

    function hasRole(uint64 role, address account) external view returns (bool, uint32) {
        return (memberSince[role][account] != 0, 0);
    }

    function getAccess(uint64 role, address account)
        external
        view
        returns (uint48 since, uint32, uint32, uint48)
    {
        return (memberSince[role][account], 0, 0, 0);
    }
}

/// @notice A governance seat that is a contract account, not a key: it acts for whoever
///         presents a preimage of its key hash, standing for any signature scheme (a passkey, a
///         post-quantum scheme, a multisig of those). The key can rotate without the seat's
///         address, and so its roles, changing.
contract ContractSeat {
    bytes32 public keyHash;

    error WrongKey();

    constructor(bytes32 keyHash_) {
        keyHash = keyHash_;
    }

    function exec(bytes32 key, address to, bytes calldata data)
        external
        returns (bytes memory result)
    {
        if (keccak256(abi.encode(key)) != keyHash) revert WrongKey();
        bool ok;
        (ok, result) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function rotate(bytes32 key, bytes32 nextHash) external {
        if (keccak256(abi.encode(key)) != keyHash) revert WrongKey();
        keyHash = nextHash;
    }
}
