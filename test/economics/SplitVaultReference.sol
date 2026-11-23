// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SplitVaultReference
/// @notice The split vault in plain Solidity: what the 66 bytes of `SplitVault` do, written out.
///         Test-only. It is never deployed by the ledger; `SplitVaultDifferential.t.sol` runs
///         every call shape against both and compares the outcome, the return data, the
///         balances and the logs.
/// @dev A call from anyone but the deployer succeeds with no calldata (so the vault accepts ETH)
///      and reverts with any. A call from the deployer is an instruction,
///      `abi.encodePacked(uint256(uint160(target)), value, data)`: the vault calls `target` with
///      `value` of its own wei and `data`, forwards all gas, returns the callee's return data
///      whole and unencoded, and reverts with no data if the call failed.
///      One difference, in gas only: a deployer's call shorter than 64 bytes fails with no data
///      in both, but the 66 bytes spend all the gas they were given on the way, where this
///      contract reverts at once. The ledger never sends one.
contract SplitVaultReference {
    /// @dev The deployer: the only account whose instructions the vault executes.
    address private immutable _LEDGER = msg.sender;

    // No `receive`: a call without calldata from the deployer is an instruction too.
    fallback(bytes calldata instruction) external payable returns (bytes memory) {
        if (msg.sender != _LEDGER) {
            if (instruction.length != 0) revert();
            return "";
        }
        address target = address(uint160(uint256(bytes32(instruction[:32]))));
        uint256 value = uint256(bytes32(instruction[32:64]));
        (bool ok, bytes memory answer) = target.call{ value: value }(instruction[64:]);
        if (!ok) revert();
        return answer;
    }
}
