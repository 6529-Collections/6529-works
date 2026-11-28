// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { DeployCore } from "script/DeployCore.sol";
import { DeployGuards } from "script/DeployGuards.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @dev The subscription calls of the Chainlink VRF v2.5 coordinator (`SubscriptionAPI`).
interface IVrfSubscriptions {
    function createSubscription() external returns (uint256 subId);
    function fundSubscriptionWithNative(uint256 subId) external payable;
    function addConsumer(uint256 subId, address consumer) external;
    function getSubscription(uint256 subId)
        external
        view
        returns (
            uint96 balance,
            uint96 nativeBalance,
            uint64 reqCount,
            address owner,
            address[] memory consumers
        );
}

/// @notice Selects a fork of the chain at `rpc`: at `pinned` when nonzero, otherwise a few blocks
///         behind the head, which every node behind a load-balanced public endpoint already
///         serves (the head itself may not have reached the node that answers the next read).
library Forks {
    uint256 internal constant BEHIND_HEAD = 8;

    function select(Vm vm, string memory rpc, uint256 pinned) internal {
        if (pinned != 0) {
            vm.createSelectFork(rpc, pinned);
            return;
        }
        vm.createSelectFork(rpc);
        vm.rollFork(block.number - BEHIND_HEAD);
    }
}

/// @notice The whole plain-core stack, deployed by the integration base (`DeployCore.deploy`,
///         the committed genesis policy, `VerifyCore`), on a fork of a live chain and against
///         the chain's real 6529 delegation contract instead of the identity lane's mock.
///         Nothing is broadcast: the fork is a local copy, so a test may write to it.
/// @dev Opt-in. A concrete suite names the environment variable holding its RPC URL
///      (`FORK_MAINNET_RPC` or `FORK_SEPOLIA_RPC`); without it `setUp` deploys nothing and every
///      test is skipped. `<VAR>_BLOCK` pins the fork block (default: eight blocks behind the
///      head; public endpoints without archive state serve only recent blocks). A suite puts
///      the external accounts it needs in place before the deployment in `_beforeDeploy` (the
///      network Safe, a VRF subscription). See `test/fork/README.md`.
abstract contract CoreForkBase is IntegrationBase {
    uint256 internal constant MAINNET = 1;
    uint256 internal constant SEPOLIA = 11_155_111;

    /// @dev The environment variable naming this suite's RPC URL.
    function _rpcVar() internal pure virtual returns (string memory);

    /// @dev The chain the fork must be of.
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public virtual override {
        string memory rpc = vm.envOr(_rpcVar(), string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, string.concat(_rpcVar(), " is not set"));
            return;
        }
        Forks.select(vm, rpc, vm.envOr(string.concat(_rpcVar(), "_BLOCK"), uint256(0)));
        require(block.chainid == _chainId(), "the RPC serves another chain");
        require(_delegationAddress().code.length != 0, "no delegation contract on this chain");
        _beforeDeploy();
        super.setUp();
        // The base deployed the mock before reading `_params`; the system reads the real one.
        delegation = DelegationManagementMock(_delegationAddress());
    }

    /// @dev Runs on the fork before anything is deployed.
    function _beforeDeploy() internal virtual { }

    /// @dev The 6529 delegation contract on this chain.
    function _delegationAddress() internal view returns (address) {
        return block.chainid == SEPOLIA
            ? DeployGuards.SEPOLIA_DELEGATION
            : DeployGuards.CANONICAL_DELEGATION;
    }

    /// @dev The integration parameters with the chain's real delegation contract.
    function _params() internal view virtual override returns (DeployCore.Params memory p) {
        p = super._params();
        p.delegation = _delegationAddress();
    }
}
