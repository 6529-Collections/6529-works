// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IndependentStreamDeployer } from "src/independent/IndependentStreamDeployer.sol";
import { IIndependentStreamDeployer } from "src/interfaces/IIndependentStreamDeployer.sol";

/// @notice The deployer's storage of a creation code in chunks, its reassembly at deploy and the
///         failures of a deploy, on creation codes built for the purpose.
contract IndependentStreamDeployerTest is Test {
    /// @dev Init code that returns the one-byte runtime `0x01`.
    bytes internal constant TINY = hex"600160005360016000f3";
    /// @dev Init code that reverts with the one byte `0xaa`.
    bytes internal constant REFUSING = hex"60aa60005360016000fd";

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

    // ------------------------------------------------------------------ constructor

    function test_Constructor_RefusesAnEmptyCreationCode() public {
        vm.expectRevert(IIndependentStreamDeployer.EmptyCreationCode.selector);
        new IndependentStreamDeployer("");
    }

    function test_Constructor_LogsTheStoredCode() public {
        vm.expectEmit(true, false, false, false);
        emit IIndependentStreamDeployer.CreationCodeStored(keccak256(TINY), new address[](0));
        IndependentStreamDeployer d = new IndependentStreamDeployer(TINY);
        assertEq(d.creationHash(), keccak256(TINY));
    }

    /// @dev A creation code of exactly one chunk is stored in one data contract, not two.
    function test_Constructor_AnExactChunkIsOnePointer() public {
        bytes memory code = new bytes(24_575);
        vm.recordLogs();
        IndependentStreamDeployer d = new IndependentStreamDeployer(code);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory stored = logs[logs.length - 1];
        assertEq(stored.topics[0], IIndependentStreamDeployer.CreationCodeStored.selector);
        address[] memory pointers = abi.decode(stored.data, (address[]));
        assertEq(pointers.length, 1);
        assertEq(d.codeOf().length, 1, "codeOf");
    }

    // ------------------------------------------------------------------ codeOf

    /// @dev `codeOf` names the data contracts in order, and they hold the creation code: the
    ///      first chunk is full, the last holds the rest, and the logged list is the same one.
    function test_CodeOf_NamesTheDataContractsThatHoldTheCreationCode() public {
        bytes memory code = _threeChunkInitCode();
        vm.recordLogs();
        IndependentStreamDeployer d = new IndependentStreamDeployer(code);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address[] memory logged = abi.decode(logs[logs.length - 1].data, (address[]));
        address[] memory pointers = d.codeOf();
        assertEq(pointers.length, 3);
        assertEq(pointers, logged, "the logged pointers");
        uint256 held;
        for (uint256 i; i < pointers.length; ++i) {
            assertGt(pointers[i].code.length, 0, "a data contract");
            // A data contract holds its chunk after one leading byte.
            held += pointers[i].code.length - 1;
        }
        assertEq(held, code.length, "every byte is stored once");
        assertEq(pointers[0].code.length - 1, 24_575, "a full first chunk");
        assertEq(pointers[2].code.length - 1, 2, "the rest");
    }

    // ------------------------------------------------------------------ deploy

    function test_Deploy_ACreationCodeOfThreeChunksIsReassembledInOrder() public {
        bytes memory code = _threeChunkInitCode();
        IndependentStreamDeployer d = new IndependentStreamDeployer(code);
        assertEq(d.creationHash(), keccak256(code));
        address token = d.deploy(bytes32(uint256(1)), "");
        // CREATE2 from the deployer, salted by the caller and its salt (`abi.encode`).
        bytes32 key = keccak256(abi.encode(address(this), bytes32(uint256(1))));
        assertEq(token, vm.computeCreate2Address(key, keccak256(code), address(d)));
        assertEq(token.code, hex"01");
        assertTrue(d.deployed(token));
    }

    /// @dev The configuration is appended to the creation code as the constructor's arguments
    ///      and logged; the address follows the caller and its salt, so two callers using one
    ///      salt get two contracts.
    function test_Deploy_AppendsTheConfigAndLogsTheDeployment() public {
        IndependentStreamDeployer d = new IndependentStreamDeployer(TINY);
        bytes memory config = abi.encode(uint256(6529));
        bytes32 salt = keccak256("salt");
        bytes32 key = keccak256(abi.encode(address(this), salt));
        address expected =
            vm.computeCreate2Address(key, keccak256(bytes.concat(TINY, config)), address(d));
        assertFalse(d.deployed(expected), "not before");
        vm.expectEmit(address(d));
        emit IIndependentStreamDeployer.Deployed(expected, address(this), salt, config);
        address token = d.deploy(salt, config);
        assertEq(token, expected);
        assertEq(token.code, hex"01");
        assertTrue(d.deployed(token));

        address other = makeAddr("other caller");
        vm.prank(other);
        address second = d.deploy(salt, config);
        assertTrue(second != token, "salted by the caller");
        assertTrue(d.deployed(second));
    }

    /// @dev A constructor that refuses fails the deploy with the constructor's own revert data,
    ///      and nothing is recorded.
    function test_Deploy_RevertsWithTheConstructorsError() public {
        IndependentStreamDeployer d = new IndependentStreamDeployer(REFUSING);
        bytes32 salt = bytes32(uint256(7));
        vm.recordLogs();
        (bool ok, bytes memory data) = address(d).call(abi.encodeCall(d.deploy, (salt, "")));
        assertFalse(ok, "the deploy fails");
        assertEq(data, hex"aa", "the constructor's revert data");
        assertEq(vm.getRecordedLogs().length, 0, "nothing logged");
        bytes32 key = keccak256(abi.encode(address(this), salt));
        address refused = vm.computeCreate2Address(key, keccak256(REFUSING), address(d));
        assertFalse(d.deployed(refused));
        assertEq(refused.code.length, 0);
    }

    /// @dev The same caller, salt and configuration name an address that is already taken: the
    ///      second deploy reverts with empty data and the first contract stays as it is.
    function test_Deploy_RevertsEmptyWhenTheAddressIsTaken() public {
        IndependentStreamDeployer d = new IndependentStreamDeployer(TINY);
        bytes32 salt = bytes32(uint256(9));
        address token = d.deploy(salt, "");
        (bool ok, bytes memory data) = address(d).call(abi.encodeCall(d.deploy, (salt, "")));
        assertFalse(ok, "the second deploy fails");
        assertEq(data.length, 0, "empty revert data");
        assertEq(token.code, hex"01");
        assertTrue(d.deployed(token));
        // Another salt still deploys.
        assertTrue(d.deploy(bytes32(uint256(10)), "") != token);
    }
}
