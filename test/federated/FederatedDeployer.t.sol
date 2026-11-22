// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { FederatedDeployer } from "src/federated/FederatedDeployer.sol";
import { IFederatedDeployer } from "src/interfaces/IFederatedDeployer.sol";

/// @notice The deployer's storage of a creation code in chunks and its reassembly at deploy, on
///         creation codes built for the purpose.
contract FederatedDeployerTest is Test {
    /// @dev Init code of exactly 49,152 bytes (the EIP-3860 maximum), so three chunks of at most
    ///      24,575: it writes one byte to memory, prepares `RETURN(0, 1)` and jumps to the last
    ///      two bytes, the third chunk, which hold `JUMPDEST RETURN`. It deploys the one-byte
    ///      runtime `0x01` only if every chunk lands at its own offset.
    function _threeChunkInitCode() internal pure returns (bytes memory code) {
        code = new bytes(49_152);
        bytes memory head = hex"6001600053600160006100005600";
        for (uint256 i; i < head.length; ++i) {
            code[i] = head[i];
        }
        // PUSH2 0xBFFE: the jump target, 49,150.
        (code[10], code[11]) = (0xbf, 0xfe);
        (code[49_150], code[49_151]) = (0x5b, 0xf3);
    }

    function test_Deploy_ACreationCodeOfThreeChunksIsReassembledInOrder() public {
        bytes memory code = _threeChunkInitCode();
        FederatedDeployer d = new FederatedDeployer(code);
        assertEq(d.creationHash(), keccak256(code));
        address token = d.deploy(bytes32(uint256(1)), "");
        assertEq(token.code, hex"01");
        assertTrue(d.deployed(token));
    }

    /// @dev A creation code of exactly one chunk is stored in one data contract, not two.
    function test_Constructor_AnExactChunkIsOnePointer() public {
        bytes memory code = new bytes(24_575);
        vm.recordLogs();
        new FederatedDeployer(code);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory stored = logs[logs.length - 1];
        assertEq(stored.topics[0], IFederatedDeployer.CreationCodeStored.selector);
        address[] memory pointers = abi.decode(stored.data, (address[]));
        assertEq(pointers.length, 1);
    }

    function test_Constructor_LogsTheStoredCode() public {
        bytes memory code = hex"600160005360016000f3";
        vm.expectEmit(true, false, false, false);
        emit IFederatedDeployer.CreationCodeStored(keccak256(code), new address[](0));
        new FederatedDeployer(code);
    }
}
