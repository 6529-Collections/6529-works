// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { DeployGuards } from "script/DeployGuards.sol";
import { CoreNetworkFlows } from "../governance/CoreNetworkFlows.sol";
import { Forks } from "./StreamForkBase.sol";

/// @dev The parts of Safe v1.4.1 this suite calls.
interface ISafeV141 {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);

    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);

    function nonce() external view returns (uint256);
    function VERSION() external view returns (string memory);
}

interface ISafeV141ProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

/// @notice The plain core's waiting-period flows with the network as a real 2-of-3 Safe v1.4.1
///         on an Ethereum mainnet fork: the Safe accepts the network role by a Safe transaction,
///         proposes a module and anyone activates it once `moduleDelay()` (read from the
///         contract) has passed; it changes the setting and a later proposal follows the new
///         value while a pending one keeps its time; it removes a minter at once; it rescues
///         only once `rescueDelay()` has passed since the removal, and after `setRescueDelay` the
///         new value decides; the same for `rebindDelay()`; and it sets
///         `StreamDirectory6529.unclaimedPeriod()` at once. Every flow is `CoreNetworkFlows`.
/// @dev Opt-in like every fork suite: without `FORK_MAINNET_RPC` every test is skipped.
///      `FORK_MAINNET_RPC_BLOCK` pins the block. Each Safe transaction is signed by two owner
///      keys this test holds and executed by a relayer, so the Safe is `msg.sender`.
contract SafeCoreNetworkTest is CoreNetworkFlows {
    address internal constant SAFE_SINGLETON = DeployGuards.SAFE_141_L1;
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    uint256 internal constant THRESHOLD = 2;

    uint256[] internal ownerKeys;
    address internal relayer = makeAddr("relayer");
    /// @dev Set by `_expectNetworkRevert`: the next Safe transaction must revert.
    bool internal expectFailure;

    function setUp() public override {
        string memory rpc = vm.envOr("FORK_MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "FORK_MAINNET_RPC is not set");
            return;
        }
        Forks.select(vm, rpc, vm.envOr("FORK_MAINNET_RPC_BLOCK", uint256(0)));
        require(block.chainid == 1, "the RPC serves another chain");
        assertEq(SAFE_SINGLETON.codehash, DeployGuards.SAFE_141_L1_CODEHASH, "Safe singleton");
        assertEq(ISafeV141(SAFE_SINGLETON).VERSION(), "1.4.1");
        super.setUp();
    }

    function _networkAccount() internal override returns (address) {
        address[] memory owners = new address[](3);
        for (uint256 i; i < 3; ++i) {
            uint256 key;
            (owners[i], key) = makeAddrAndKey(string.concat("network owner ", vm.toString(i)));
            ownerKeys.push(key);
        }
        bytes memory init = abi.encodeCall(
            ISafeV141.setup,
            (
                owners,
                THRESHOLD,
                address(0),
                "",
                FALLBACK_HANDLER,
                address(0),
                0,
                payable(address(0))
            )
        );
        return ISafeV141ProxyFactory(SAFE_PROXY_FACTORY)
            .createProxyWithNonce(SAFE_SINGLETON, init, uint256(keccak256("core network")));
    }

    /// @dev One Safe transaction signed by the first two owners. A failed inner call reverts
    ///      the Safe transaction with "GS013" (no `safeTxGas`, no gas price).
    function _asNetwork(address target, bytes memory data) internal override {
        ISafeV141 safe = ISafeV141(network);
        bytes32 hash = safe.getTransactionHash(
            target, 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce()
        );
        bytes memory signatures = _signatures(hash);
        if (expectFailure) {
            expectFailure = false;
            vm.expectRevert(bytes("GS013"));
        }
        vm.prank(relayer);
        safe.execTransaction(
            target, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signatures
        );
    }

    /// @dev The Safe reverts with its own reason, not the target's.
    function _expectNetworkRevert(bytes memory) internal override {
        expectFailure = true;
    }

    /// @dev Signatures of the first `THRESHOLD` owners, ordered by owner address as Safe wants.
    function _signatures(bytes32 hash) internal view returns (bytes memory out) {
        uint256 a = ownerKeys[0];
        uint256 b = ownerKeys[1];
        if (vm.addr(a) > vm.addr(b)) (a, b) = (b, a);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(a, hash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(b, hash);
        out = abi.encodePacked(r1, s1, v1, r2, s2, v2);
    }
}
