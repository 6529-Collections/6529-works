// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SplitVault } from "src/economics/SplitVault.sol";
import { MockERC20, NoReturnToken, ReturnsFalseToken } from "../mocks/economics/EconomicsMocks.sol";
import { SplitVaultReference } from "./SplitVaultReference.sol";

/// @dev Stands in for the ledger: deploys both vaults, so both obey it.
contract VaultCommander {
    function deployBytes(bytes32 salt) external returns (address vault, uint256 gasUsed) {
        bytes memory code = SplitVault.INIT_CODE;
        uint256 before = gasleft();
        assembly ("memory-safe") {
            vault := create2(0, add(code, 0x20), mload(code), salt)
        }
        gasUsed = before - gasleft();
    }

    function deployReference(bytes32 salt) external returns (address vault, uint256 gasUsed) {
        uint256 before = gasleft();
        vault = address(new SplitVaultReference{ salt: salt }());
        gasUsed = before - gasleft();
    }
}

/// @dev A callee whose behaviour its calldata chooses. It logs every call, then by the first
///      byte modulo 6: 0 (or no calldata) returns nothing; 1 returns its calldata; 2 reverts with
///      its calldata; 3 calls its caller back with the rest of the calldata and half the value
///      and returns the outcome; 4 sends the value back to its caller with no calldata and
///      returns the outcome; 5 returns 100,000 bytes.
contract ShapedCallee {
    event Called(address caller, uint256 value, bytes data);

    fallback(bytes calldata data) external payable returns (bytes memory) {
        emit Called(msg.sender, msg.value, data);
        uint256 mode = data.length == 0 ? 0 : uint8(data[0]) % 6;
        if (mode == 1) return data;
        if (mode == 2) {
            bytes memory reason = data;
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
        if (mode == 3) {
            (bool ok, bytes memory answer) = msg.sender.call{ value: msg.value / 2 }(data[1:]);
            return abi.encode(ok, answer);
        }
        if (mode == 4) {
            (bool ok, bytes memory answer) = msg.sender.call{ value: msg.value }("");
            return abi.encode(ok, answer);
        }
        if (mode == 5) return new bytes(100_000);
        return "";
    }
}

/// @dev Pays with Solidity's `transfer`: a 2,300-gas stipend.
contract StipendPayer {
    function pay(address payable to) external payable {
        to.transfer(msg.value);
    }
}

/// @notice The 66 bytes of `SplitVault` against the plain Solidity vault of
///         `SplitVaultReference.sol`: every call shape runs on both, from the same state and at
///         the same address, and must give the same success flag, return data, balances and logs.
/// @dev The vault's address is the bytes' own CREATE2 address; for the second run the state is
///      rolled back and the reference's runtime code (deployed by the same commander, so it
///      obeys the same account) is put at that address. Nothing but the vault's code differs
///      between the two runs.
contract SplitVaultDifferentialTest is Test {
    /// @dev The gas given to a call unless a test says otherwise.
    uint256 internal constant CALL_GAS = 2_000_000;
    uint256 internal constant VAULT_ETH = 10 ether;
    uint256 internal constant VAULT_TOKENS = 1000e18;

    VaultCommander internal commander;
    address internal vault;
    bytes internal referenceCode;
    ShapedCallee internal callee;
    MockERC20 internal token;
    NoReturnToken internal silentToken;
    ReturnsFalseToken internal falseToken;
    address internal stranger = makeAddr("stranger");
    address internal recipient = makeAddr("recipient");

    /// @dev What one call left behind.
    struct Outcome {
        bool ok;
        bytes answer;
        uint256[5] eth;
        uint256[6] tokens;
        bytes32 logs;
        uint256 logCount;
    }

    function setUp() public {
        commander = new VaultCommander();
        (vault,) = commander.deployBytes(bytes32(0));
        (address reference_,) = commander.deployReference(bytes32(0));
        referenceCode = reference_.code;
        callee = new ShapedCallee();
        token = new MockERC20("Token", "TKN");
        silentToken = new NoReturnToken();
        falseToken = new ReturnsFalseToken();
        vm.deal(vault, VAULT_ETH);
        token.mint(vault, VAULT_TOKENS);
        silentToken.mint(vault, VAULT_TOKENS);
        falseToken.mint(vault, VAULT_TOKENS);
    }

    // ------------------------------------------------------------------ the comparison

    function _run(address caller, uint256 value, bytes memory data, uint256 gasLimit)
        internal
        returns (Outcome memory o)
    {
        vm.deal(caller, value);
        vm.recordLogs();
        vm.prank(caller);
        (o.ok, o.answer) = vault.call{ value: value, gas: gasLimit }(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        o.logCount = logs.length;
        o.logs = keccak256(abi.encode(logs));
        o.eth = [
            vault.balance,
            caller.balance,
            address(callee).balance,
            recipient.balance,
            address(commander).balance
        ];
        o.tokens = [
            token.balanceOf(vault),
            token.balanceOf(recipient),
            silentToken.balanceOf(vault),
            silentToken.balanceOf(recipient),
            falseToken.balanceOf(vault),
            falseToken.balanceOf(recipient)
        ];
    }

    /// @dev Runs one call on the 66 bytes and on the reference and requires the same outcome.
    function _same(address caller, uint256 value, bytes memory data)
        internal
        returns (Outcome memory a)
    {
        return _same(caller, value, data, CALL_GAS);
    }

    function _same(address caller, uint256 value, bytes memory data, uint256 gasLimit)
        internal
        returns (Outcome memory a)
    {
        uint256 state = vm.snapshotState();
        a = _run(caller, value, data, gasLimit);
        vm.revertToState(state);
        vm.etch(vault, referenceCode);
        Outcome memory b = _run(caller, value, data, gasLimit);
        vm.revertToState(state);
        assertEq(a.ok, b.ok, "success");
        assertEq(a.answer, b.answer, "return data");
        assertEq(a.logCount, b.logCount, "log count");
        assertEq(a.logs, b.logs, "logs");
        for (uint256 i; i < a.eth.length; ++i) {
            assertEq(a.eth[i], b.eth[i], "ETH balance");
        }
        for (uint256 i; i < a.tokens.length; ++i) {
            assertEq(a.tokens[i], b.tokens[i], "token balance");
        }
    }

    function _instruction(address target, uint256 value, bytes memory data)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(uint256(uint160(target)), value, data);
    }

    function _ledger() internal view returns (address) {
        return address(commander);
    }

    // ------------------------------------------------------------------ the two vaults

    function test_BothVaultsObeyTheSameAccount() public view {
        assertEq(vault.code, abi.encodePacked(hex"73", address(commander), SplitVault.RUNTIME_TAIL));
        assertGt(referenceCode.length, 66);
    }

    /// @dev The numbers behind keeping the 66 bytes: the reference is several times the size,
    ///      and each wallet would pay for its code again (200 gas a byte) when it is created.
    ///      The gas of a payment, a token move and a receipt is logged for both.
    function test_TheReferenceCostsMoreToDeploy() public {
        (, uint256 bytesGas) = commander.deployBytes(bytes32(uint256(1)));
        (, uint256 referenceGas) = commander.deployReference(bytes32(uint256(1)));
        emit log_named_uint("runtime size, the 66 bytes", vault.code.length);
        emit log_named_uint("runtime size, the reference", referenceCode.length);
        emit log_named_uint("CREATE2 gas, the 66 bytes", bytesGas);
        emit log_named_uint("CREATE2 gas, the reference", referenceGas);
        assertGt(referenceGas, bytesGas + (referenceCode.length - 66) * 200);

        bytes memory pay = _instruction(recipient, 1 ether, "");
        bytes memory move =
            _instruction(address(token), 0, abi.encodeCall(IERC20.transfer, (recipient, 1e18)));
        // Three passes from the same state: the first only warms every account and slot.
        uint256[3][3] memory used;
        for (uint256 k; k < 3; ++k) {
            uint256 state = vm.snapshotState();
            if (k == 2) vm.etch(vault, referenceCode);
            used[0][k] = _gasOf(_ledger(), 0, pay);
            used[1][k] = _gasOf(_ledger(), 0, move);
            used[2][k] = _gasOf(stranger, 1 ether, "");
            vm.revertToState(state);
        }
        emit log_named_uint("pay ETH, the 66 bytes", used[0][1]);
        emit log_named_uint("pay ETH, the reference", used[0][2]);
        emit log_named_uint("move a token, the 66 bytes", used[1][1]);
        emit log_named_uint("move a token, the reference", used[1][2]);
        emit log_named_uint("receive ETH, the 66 bytes", used[2][1]);
        emit log_named_uint("receive ETH, the reference", used[2][2]);
    }

    /// @dev Gas of one call to the vault, its accounts funded first.
    function _gasOf(address caller, uint256 value, bytes memory data) internal returns (uint256) {
        vm.deal(caller, value + 1);
        vm.deal(recipient, 1);
        token.mint(recipient, 1);
        vm.prank(caller);
        uint256 before = gasleft();
        (bool ok,) = vault.call{ value: value }(data);
        uint256 used = before - gasleft();
        assertTrue(ok);
        return used;
    }

    // ------------------------------------------------------------------ anyone but the ledger

    function test_Stranger_PlainETHIsAccepted() public {
        Outcome memory o = _same(stranger, 1 ether, "");
        assertTrue(o.ok);
        assertEq(o.answer.length, 0);
        assertEq(o.eth[0], VAULT_ETH + 1 ether);
    }

    function test_Stranger_AnEmptyCallWithoutValueSucceeds() public {
        Outcome memory o = _same(stranger, 0, "");
        assertTrue(o.ok);
        assertEq(o.eth[0], VAULT_ETH);
    }

    /// @dev Solidity's `transfer` forwards 2,300 gas: both vaults accept it.
    function test_Stranger_PlainETHWithinTheStipendIsAccepted() public {
        StipendPayer payer = new StipendPayer();
        for (uint256 k; k < 2; ++k) {
            uint256 state = vm.snapshotState();
            if (k == 1) vm.etch(vault, referenceCode);
            payer.pay{ value: 1 ether }(payable(vault));
            assertEq(vault.balance, VAULT_ETH + 1 ether);
            vm.revertToState(state);
        }
    }

    function test_Stranger_AnyCalldataReverts() public {
        bytes[6] memory shapes = [
            bytes(hex"00"),
            abi.encodeWithSelector(IERC20.transfer.selector),
            abi.encodeCall(IERC20.transfer, (stranger, 1)),
            _instruction(stranger, 1 ether, ""),
            _instruction(address(token), 0, abi.encodeCall(IERC20.transfer, (stranger, 1e18))),
            abi.encodeWithSignature(
                "onERC721Received(address,address,uint256,bytes)", stranger, stranger, 1, ""
            )
        ];
        for (uint256 i; i < shapes.length; ++i) {
            for (uint256 value; value < 2; ++value) {
                Outcome memory o = _same(stranger, value * 1 ether, shapes[i]);
                assertFalse(o.ok);
                assertEq(o.answer.length, 0, "no revert data");
                assertEq(o.eth[0], VAULT_ETH);
                assertEq(o.tokens[0], VAULT_TOKENS);
            }
        }
    }

    // ------------------------------------------------------------------ the ledger

    function test_Ledger_PaysETH() public {
        Outcome memory o = _same(_ledger(), 0, _instruction(recipient, 1 ether, ""));
        assertTrue(o.ok);
        assertEq(o.answer.length, 0);
        assertEq(o.eth[0], VAULT_ETH - 1 ether);
        assertEq(o.eth[3], 1 ether);
    }

    function test_Ledger_ZeroValueToAnAccountWithoutCode() public {
        Outcome memory o = _same(_ledger(), 0, _instruction(recipient, 0, ""));
        assertTrue(o.ok);
        assertEq(o.eth[0], VAULT_ETH);
    }

    function test_Ledger_MoreThanTheBalanceFails() public {
        Outcome memory o = _same(_ledger(), 0, _instruction(recipient, VAULT_ETH + 1, ""));
        assertFalse(o.ok);
        assertEq(o.answer.length, 0);
        assertEq(o.eth[0], VAULT_ETH);
    }

    /// @dev Value the ledger sends with an instruction is the vault's to spend in it.
    function test_Ledger_ValueSentWithAnInstructionIsTheVaults() public {
        Outcome memory o =
            _same(_ledger(), 1 ether, _instruction(recipient, VAULT_ETH + 1 ether, ""));
        assertTrue(o.ok);
        assertEq(o.eth[0], 0);
        assertEq(o.eth[3], VAULT_ETH + 1 ether);
    }

    function test_Ledger_MovesATokenThatReturnsTrue() public {
        bytes memory move = abi.encodeCall(IERC20.transfer, (recipient, 5e18));
        Outcome memory o = _same(_ledger(), 0, _instruction(address(token), 0, move));
        assertTrue(o.ok);
        assertEq(o.answer, abi.encode(true));
        assertEq(o.tokens[0], VAULT_TOKENS - 5e18);
        assertEq(o.tokens[1], 5e18);
        assertEq(o.logCount, 1, "the token's Transfer");
    }

    function test_Ledger_MovesATokenThatReturnsNothing() public {
        bytes memory move = abi.encodeCall(IERC20.transfer, (recipient, 5e18));
        Outcome memory o = _same(_ledger(), 0, _instruction(address(silentToken), 0, move));
        assertTrue(o.ok);
        assertEq(o.answer.length, 0);
        assertEq(o.tokens[3], 5e18);
    }

    function test_Ledger_ATokenThatReturnsFalseIsPassedOn() public {
        bytes memory move = abi.encodeCall(IERC20.transfer, (recipient, 5e18));
        Outcome memory o = _same(_ledger(), 0, _instruction(address(falseToken), 0, move));
        assertTrue(o.ok);
        assertEq(o.answer, abi.encode(false));
        assertEq(o.tokens[4], VAULT_TOKENS);
    }

    function test_Ledger_ATokenThatRevertsFailsWithNoData() public {
        bytes memory move = abi.encodeCall(IERC20.transfer, (recipient, VAULT_TOKENS + 1));
        Outcome memory o = _same(_ledger(), 0, _instruction(address(token), 0, move));
        assertFalse(o.ok);
        assertEq(o.answer.length, 0, "the callee's reason is dropped");
        assertEq(o.tokens[0], VAULT_TOKENS);
    }

    /// @dev Every behaviour of the callee, with and without value.
    function test_Ledger_EveryCalleeBehaviour() public {
        for (uint256 mode; mode < 6; ++mode) {
            for (uint256 value; value < 2; ++value) {
                bytes memory data = abi.encodePacked(uint8(mode), "payload");
                Outcome memory o =
                    _same(_ledger(), 0, _instruction(address(callee), value * 1 ether, data));
                assertEq(o.ok, mode != 2);
                if (mode == 1) assertEq(o.answer, data, "return data comes back whole");
                if (mode == 2) assertEq(o.answer.length, 0);
                if (mode == 5) assertEq(o.answer.length, 100_000);
            }
        }
    }

    /// @dev A callee that calls the vault back is anyone else: with calldata it is refused, with
    ///      none its ETH is accepted, and the outer instruction completes either way.
    function test_Ledger_ACalleeThatReentersIsAStranger() public {
        bytes memory steal = _instruction(address(callee), 1 ether, "");
        Outcome memory o = _same(
            _ledger(), 0, _instruction(address(callee), 2 ether, abi.encodePacked(uint8(3), steal))
        );
        assertTrue(o.ok);
        assertEq(o.answer, abi.encode(false, bytes("")), "the inner call was refused");
        assertEq(o.eth[0], VAULT_ETH - 2 ether);

        o = _same(_ledger(), 0, _instruction(address(callee), 2 ether, abi.encodePacked(uint8(3))));
        assertEq(o.answer, abi.encode(true, bytes("")), "plain ETH back is accepted");
        assertEq(o.eth[0], VAULT_ETH - 1 ether);

        o = _same(_ledger(), 0, _instruction(address(callee), 2 ether, abi.encodePacked(uint8(4))));
        assertEq(o.eth[0], VAULT_ETH);
    }

    /// @dev The vault told to call itself is a stranger to itself.
    function test_Ledger_TheVaultAsItsOwnTarget() public {
        Outcome memory o = _same(_ledger(), 0, _instruction(vault, 1 ether, ""));
        assertTrue(o.ok);
        assertEq(o.eth[0], VAULT_ETH);
        o = _same(_ledger(), 0, _instruction(vault, 0, _instruction(recipient, 1 ether, "")));
        assertFalse(o.ok);
        assertEq(o.eth[0], VAULT_ETH);
    }

    /// @dev Only the low 160 bits of the first word name the target.
    function test_Ledger_HighBitsOfTheTargetWordAreIgnored() public {
        bytes memory data =
            abi.encodePacked(uint256(uint160(recipient)) | 0xff << 160, uint256(1 ether));
        Outcome memory o = _same(_ledger(), 0, data);
        assertTrue(o.ok);
        assertEq(o.eth[3], 1 ether);
    }

    /// @dev Fewer than the 64 bytes of a target and a value: both fail with no data and move
    ///      nothing. (The 66 bytes spend all the gas of the call doing so.)
    function test_Ledger_AnInstructionShorterThanSixtyFourBytesFails() public {
        uint256[4] memory lengths = [uint256(0), 1, 32, 63];
        for (uint256 i; i < lengths.length; ++i) {
            for (uint256 value; value < 2; ++value) {
                Outcome memory o = _same(_ledger(), value * 1 ether, new bytes(lengths[i]), 100_000);
                assertFalse(o.ok);
                assertEq(o.answer.length, 0);
                assertEq(o.eth[0], VAULT_ETH);
            }
        }
    }

    // ------------------------------------------------------------------ any call

    /// @dev Any caller, value and calldata.
    function testFuzz_AnyCall(bool fromLedger, uint64 value, bytes calldata data) public {
        _same(fromLedger ? _ledger() : stranger, value, data, 200_000);
    }

    /// @dev Any instruction from the ledger or from anyone else: any of the targets, any value
    ///      up to a little more than the vault holds, any calldata (which chooses the callee's
    ///      behaviour and what it sends back into the vault).
    function testFuzz_AnyInstruction(
        bool fromLedger,
        uint8 targetSeed,
        uint256 value,
        uint64 sent,
        bytes calldata data
    ) public {
        address[7] memory targets = [
            address(callee),
            address(token),
            address(silentToken),
            address(falseToken),
            recipient,
            vault,
            address(commander)
        ];
        value = bound(value, 0, VAULT_ETH + 2 ether);
        _same(
            fromLedger ? _ledger() : stranger,
            sent,
            _instruction(targets[targetSeed % targets.length], value, data)
        );
    }

    /// @dev Any token transfer the ledger orders, within the balance or beyond it.
    function testFuzz_AnyTokenTransfer(uint8 tokenSeed, address to, uint256 amount) public {
        address[3] memory tokens = [address(token), address(silentToken), address(falseToken)];
        amount = bound(amount, 0, VAULT_TOKENS * 2);
        _same(
            _ledger(),
            0,
            _instruction(tokens[tokenSeed % 3], 0, abi.encodeCall(IERC20.transfer, (to, amount)))
        );
    }
}
