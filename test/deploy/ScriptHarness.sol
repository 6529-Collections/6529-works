// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Deploy } from "script/Deploy.s.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { ScriptIO } from "script/ScriptIO.sol";
import { Verify } from "script/Verify.s.sol";
import { MockVrfCoordinator } from "../mocks/EntropyMocks.sol";

/// @notice The scripts' outside inputs, set by the test instead of read from the process:
///         environment variables, files (falling back to the real ./config and ./deployments),
///         the RPC's chain ID and the pinned CC0 digest.
abstract contract ScriptInputs is ScriptIO {
    mapping(string name => string) internal _envs;
    mapping(string path => bytes) internal _files;
    mapping(string path => bool) internal _hasFile;
    uint256 internal _rpcChainId;
    bool internal _rpcSet;
    bytes32 internal _cc0Digest;
    bool internal _cc0Set;

    function setEnv(string memory name, string memory value) external {
        _envs[name] = value;
    }

    function setFile(string memory path, bytes memory content) external {
        _files[path] = content;
        _hasFile[path] = true;
    }

    function setRpcChainId(uint256 id) external {
        _rpcChainId = id;
        _rpcSet = true;
    }

    function setCc0Digest(bytes32 digest) external {
        _cc0Digest = digest;
        _cc0Set = true;
    }

    function rpcChainId() public view virtual override returns (uint256) {
        return _rpcSet ? _rpcChainId : block.chainid;
    }

    function cc0Digest() public view virtual override returns (bytes32) {
        return _cc0Set ? _cc0Digest : super.cc0Digest();
    }

    function _env(string memory name) internal view virtual override returns (string memory) {
        return _envs[name];
    }

    function _read(string memory path) internal view virtual override returns (string memory) {
        return _hasFile[path] ? string(_files[path]) : vm.readFile(path);
    }

    function _readBinary(string memory path) internal view virtual override returns (bytes memory) {
        return _hasFile[path] ? _files[path] : vm.readFileBinary(path);
    }
}

/// @notice `Deploy` with test-set inputs.
contract DeployHarness is Deploy, ScriptInputs {
    function rpcChainId() public view override(ScriptIO, ScriptInputs) returns (uint256) {
        return ScriptInputs.rpcChainId();
    }

    function cc0Digest() public view override(ScriptIO, ScriptInputs) returns (bytes32) {
        return ScriptInputs.cc0Digest();
    }

    function _env(string memory name)
        internal
        view
        override(ScriptIO, ScriptInputs)
        returns (string memory)
    {
        return ScriptInputs._env(name);
    }

    function _read(string memory path)
        internal
        view
        override(ScriptIO, ScriptInputs)
        returns (string memory)
    {
        return ScriptInputs._read(path);
    }

    function _readBinary(string memory path)
        internal
        view
        override(ScriptIO, ScriptInputs)
        returns (bytes memory)
    {
        return ScriptInputs._readBinary(path);
    }
}

/// @notice `Verify` with test-set inputs, and the logs a test recorded in place of
///         `eth_getLogs`.
contract VerifyHarness is Verify, ScriptInputs {
    struct StoredLog {
        address emitter;
        bytes32[] topics;
        bytes data;
    }

    StoredLog[] internal _stored;

    function checkCc0External(DeployV1.Deployment memory d, string memory record, bool local)
        external
        view
    {
        _checkCc0(d, record, local);
    }

    function checkSubscriptionExternal(
        DeployV1.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        bool mainnet
    ) external view {
        _checkSubscription(d, cfg, mainnet);
    }

    function checkManifestExternal(string memory record, bool local)
        external
        view
        returns (DeployV1.Manifest memory)
    {
        return _checkManifest(record, local);
    }

    function addLogs(Vm.Log[] memory logs) external {
        for (uint256 i; i < logs.length; ++i) {
            _add(logs[i].emitter, logs[i].topics, logs[i].data);
        }
    }

    function addLog(address emitter, bytes32[] memory topics, bytes memory data) external {
        _add(emitter, topics, data);
    }

    function clearLogs() external {
        delete _stored;
    }

    function _add(address emitter, bytes32[] memory topics, bytes memory data) internal {
        StoredLog storage log = _stored.push();
        log.emitter = emitter;
        log.data = data;
        for (uint256 i; i < topics.length; ++i) {
            log.topics.push(topics[i]);
        }
    }

    function _logs(uint256, address emitter, bytes32 topic)
        internal
        view
        override
        returns (Vm.EthGetLogs[] memory out)
    {
        uint256 n;
        for (uint256 i; i < _stored.length; ++i) {
            if (_matches(_stored[i], emitter, topic)) ++n;
        }
        out = new Vm.EthGetLogs[](n);
        uint256 k;
        for (uint256 i; i < _stored.length; ++i) {
            if (_matches(_stored[i], emitter, topic)) {
                out[k].emitter = emitter;
                out[k].topics = _stored[i].topics;
                out[k++].data = _stored[i].data;
            }
        }
    }

    function _matches(StoredLog storage log, address emitter, bytes32 topic)
        internal
        view
        returns (bool)
    {
        return log.emitter == emitter && log.topics.length != 0 && log.topics[0] == topic;
    }

    function rpcChainId() public view override(ScriptIO, ScriptInputs) returns (uint256) {
        return ScriptInputs.rpcChainId();
    }

    function cc0Digest() public view override(ScriptIO, ScriptInputs) returns (bytes32) {
        return ScriptInputs.cc0Digest();
    }

    function _env(string memory name)
        internal
        view
        override(ScriptIO, ScriptInputs)
        returns (string memory)
    {
        return ScriptInputs._env(name);
    }

    function _read(string memory path)
        internal
        view
        override(ScriptIO, ScriptInputs)
        returns (string memory)
    {
        return ScriptInputs._read(path);
    }

    function _readBinary(string memory path)
        internal
        view
        override(ScriptIO, ScriptInputs)
        returns (bytes memory)
    {
        return ScriptInputs._readBinary(path);
    }
}

/// @notice A Safe as the guards see one: code, `getThreshold()` and `getOwners()`. Its three
///         owners derive from its own address, so every etched copy has its own signers.
contract MockSafe {
    function getThreshold() external pure returns (uint256) {
        return 2;
    }

    function getOwners() external view returns (address[] memory owners) {
        owners = new address[](3);
        for (uint256 i; i < owners.length; ++i) {
            owners[i] = address(uint160(uint256(keccak256(abi.encode(address(this), i)))));
        }
    }
}

/// @notice A contract that answers `getThreshold()` with zero.
contract MockZeroThresholdSafe {
    function getThreshold() external pure returns (uint256) {
        return 0;
    }
}

/// @notice A Safe whose owners include one fixed signer, `SHARED`, wherever it is etched.
contract MockSharedSignerSafe {
    address public constant SHARED = address(0x5157);

    function getThreshold() external pure returns (uint256) {
        return 2;
    }

    function getOwners() external view returns (address[] memory owners) {
        owners = new address[](2);
        owners[0] = address(uint160(uint256(keccak256(abi.encode(address(this))))));
        owners[1] = SHARED;
    }
}

/// @notice A 1-of-1 Safe of one fixed key, wherever it is etched.
contract MockOneKeySafe {
    address public constant KEY = address(0xBAD0);

    function getThreshold() external pure returns (uint256) {
        return 1;
    }

    function getOwners() external pure returns (address[] memory owners) {
        owners = new address[](1);
        owners[0] = KEY;
    }
}

/// @notice A 2-of-2 Safe of the same two fixed keys, wherever it is etched.
contract MockTwoKeySafe {
    address public constant KEY_A = address(0xBAD1);
    address public constant KEY_B = address(0xBAD2);

    function getThreshold() external pure returns (uint256) {
        return 2;
    }

    function getOwners() external pure returns (address[] memory owners) {
        owners = new address[](2);
        owners[0] = KEY_A;
        owners[1] = KEY_B;
    }
}

/// @notice A 2-of-2 Safe whose owners are another Safe, `INNER`, and a key of its own.
contract MockNestedOwnerSafe {
    address public constant INNER = address(0x1EE7);

    function getThreshold() external pure returns (uint256) {
        return 2;
    }

    function getOwners() external view returns (address[] memory owners) {
        owners = new address[](2);
        owners[0] = INNER;
        owners[1] = address(uint160(uint256(keccak256(abi.encode(address(this))))));
    }
}

/// @notice A VRF v2.5 coordinator stand-in that also answers `getSubscription`, as the real one
///         does: (balance, native balance, request count, owner, consumers).
contract MockVrfSubscriptions is MockVrfCoordinator {
    address public subscriptionOwner;
    address[] internal _consumers;

    function setSubscription(address owner, address[] calldata consumers) external {
        subscriptionOwner = owner;
        _consumers = consumers;
    }

    function getSubscription(uint256)
        external
        view
        returns (uint96, uint96, uint64, address, address[] memory)
    {
        return (0, 0, 0, subscriptionOwner, _consumers);
    }
}

/// @notice A threshold but no `getOwners()`.
contract MockSafeWithoutOwners {
    function getThreshold() external pure returns (uint256) {
        return 2;
    }
}
