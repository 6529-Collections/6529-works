// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { DeployV1 } from "./DeployV1.sol";

/// @title ScriptIO
/// @notice What the deploy and verify scripts read from outside the EVM: environment
///         variables, files under ./config and ./deployments, the RPC's chain ID and the pinned
///         CC0 digest. Each read is one virtual function, so the tests run the scripts with
///         their own inputs instead of the process environment.
abstract contract ScriptIO is Script {
    /// @notice The RPC endpoint reports a different chain than the script runs on.
    error ChainIdMismatch(uint256 evm, uint256 rpc);

    /// @notice Reverts unless the RPC endpoint's `eth_chainId` is `block.chainid`.
    function checkChain() public {
        uint256 rpc = rpcChainId();
        if (rpc != block.chainid) revert ChainIdMismatch(block.chainid, rpc);
    }

    /// @notice `eth_chainId` from the RPC endpoint.
    function rpcChainId() public virtual returns (uint256 id) {
        bytes memory quantity = vm.rpc("eth_chainId", "[]");
        for (uint256 i; i < quantity.length; ++i) {
            id = (id << 8) | uint8(quantity[i]);
        }
    }

    /// @notice The canonical CC0 legal code digest that off-anvil runs require.
    function cc0Digest() public view virtual returns (bytes32) {
        return DeployV1.CC0_LEGALCODE_SHA256;
    }

    /// @dev An environment variable; unset and empty are the same.
    function _env(string memory name) internal view virtual returns (string memory) {
        return vm.envOr(name, string(""));
    }

    function _envString(string memory name, string memory byDefault)
        internal
        view
        returns (string memory value)
    {
        value = _env(name);
        if (bytes(value).length == 0) value = byDefault;
    }

    function _envAddress(string memory name, address byDefault) internal view returns (address) {
        string memory value = _env(name);
        return bytes(value).length == 0 ? byDefault : vm.parseAddress(value);
    }

    function _envUint(string memory name, uint256 byDefault) internal view returns (uint256) {
        string memory value = _env(name);
        return bytes(value).length == 0 ? byDefault : vm.parseUint(value);
    }

    function _envBytes32(string memory name, bytes32 byDefault) internal view returns (bytes32) {
        string memory value = _env(name);
        return bytes(value).length == 0 ? byDefault : vm.parseBytes32(value);
    }

    function _read(string memory path) internal view virtual returns (string memory) {
        return vm.readFile(path);
    }

    function _readBinary(string memory path) internal view virtual returns (bytes memory) {
        return vm.readFileBinary(path);
    }
}
