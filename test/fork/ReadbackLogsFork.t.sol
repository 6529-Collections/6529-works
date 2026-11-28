// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { VerifyCore } from "script/VerifyCore.sol";
import { VerifyCoreScript } from "script/VerifyCore.s.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";

/// @notice The verification script with its environment set by the test; it reads logs from the
///         fork's endpoint, as a real run does.
contract LogsHarness is VerifyCoreScript {
    mapping(string name => string) internal _envs;

    function setEnv(string memory name, string memory value) external {
        _envs[name] = value;
    }

    function _env(string memory name) internal view override returns (string memory) {
        return _envs[name];
    }
}

/// @notice The read-back's log reads against a real endpoint: the logs of Sepolia r8's manager
///         and configurator over the blocks of its genesis are the same whatever
///         `LOG_BLOCK_RANGE` the run asks them in, so no log is lost or repeated where one
///         request ends and the next begins.
/// @dev Gated by `FORK_SEPOLIA_LOGS_RPC`: a Sepolia endpoint that still serves the logs of
///      r8's genesis (an archive endpoint). It is a variable of its own because a public
///      endpoint that has dropped old logs answers an empty list, not an error, and the suite's
///      other variable is usually set to such an endpoint. The fork is of a block just after
///      the genesis, whose state such an endpoint does not serve either.
contract ReadbackLogsForkTest is Test {
    string internal constant R8_RECORD = "deployments/11155111/core-1795440624.json";
    uint256 internal constant SEPOLIA = 11_155_111;

    LogsHarness internal script;
    address internal configurator;
    uint256 internal forkBlock;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_SEPOLIA_LOGS_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "FORK_SEPOLIA_LOGS_RPC is not set");
            return;
        }
        string memory record = vm.readFile(R8_RECORD);
        forkBlock = vm.parseJsonUint(record, ".forkBlock");
        configurator = vm.parseJsonAddress(record, ".GovernanceConfigurator");
        // Three blocks after the last block of the deployment: the whole genesis is in range.
        vm.createSelectFork(rpc, vm.parseJsonUint(record, ".endBlock") + 3);
        require(block.chainid == SEPOLIA, "the RPC serves another chain");
        script = new LogsHarness();
    }

    function test_ReadbackLogs_AreTheSameWhateverTheBlockRange() public {
        // The r8 record was written before the contract was renamed and keeps its old name.
        address manager =
            vm.parseJsonAddress(vm.readFile(R8_RECORD), ".contracts.WorksAccessManager.address");
        assertGt(block.number - forkBlock, 30, "several requests at the small ranges");
        string[4] memory ranges = ["5000", "13", "7", "2"];
        bytes32 managerLogs;
        bytes32 configuratorLogs;
        for (uint256 i; i < ranges.length; ++i) {
            script.setEnv("LOG_BLOCK_RANGE", ranges[i]);
            VerifyCore.Entry[] memory m = script.entriesSince(manager, forkBlock);
            VerifyCore.Entry[] memory c = script.entriesSince(configurator, forkBlock);
            assertEq(c.length, 1, "one GovernanceConfigured log");
            assertEq(
                c[0].topics[0], GovernanceConfigurator.GovernanceConfigured.selector, "its topic"
            );
            GovernanceConfig.Grant[] memory held = VerifyCore.holdersIn(m);
            assertEq(held.length, 8, "the eight genesis holders");
            if (i == 0) {
                (managerLogs, configuratorLogs) =
                (keccak256(abi.encode(m)), keccak256(abi.encode(c)));
                assertGt(m.length, held.length, "grants, mappings and labels");
                continue;
            }
            assertEq(keccak256(abi.encode(m)), managerLogs, ranges[i]);
            assertEq(keccak256(abi.encode(c)), configuratorLogs, ranges[i]);
        }
    }
}
