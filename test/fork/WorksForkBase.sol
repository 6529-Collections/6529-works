// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { DeployGuards } from "script/DeployGuards.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { MockVrfCoordinator } from "../mocks/entropy/EntropyMocks.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { MockPermit2, PermitToken } from "../mocks/sales/SaleMocks.sol";
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

/// @notice The whole v1 system deployed on a fork of a live chain, against the chain's real
///         dependencies instead of the integration mocks: the 6529 delegation contract (read
///         through the real `ConsolidationAdapter`), the canonical Permit2 and, where a test
///         provides one, the Chainlink VRF v2.5 coordinator. Nothing is broadcast: the fork is a
///         local copy, so a test may write to it (register delegations, create a subscription).
/// @dev Opt-in. A concrete test names the environment variable holding its RPC URL
///      (`FORK_MAINNET_RPC` or `FORK_SEPOLIA_RPC`); without it every test is skipped and
///      `setUp` deploys nothing. `<VAR>_BLOCK` pins the fork block (default: eight blocks behind
///      the head), which lets Foundry cache the RPC reads between runs. See `test/fork/README.md`.
abstract contract WorksForkBase is IntegrationBase {
    uint256 internal constant MAINNET = 1;
    uint256 internal constant SEPOLIA = 11_155_111;

    bool internal forked;

    /// @dev The environment variable naming this test's RPC URL.
    function _rpcVar() internal pure virtual returns (string memory);

    /// @dev The chain the fork must be of.
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public virtual override {
        string memory rpc = vm.envOr(_rpcVar(), string(""));
        if (bytes(rpc).length == 0) return;
        Forks.select(vm, rpc, vm.envOr(string.concat(_rpcVar(), "_BLOCK"), uint256(0)));
        require(block.chainid == _chainId(), "the RPC serves another chain");
        forked = true;
        super.setUp();
    }

    /// @dev Skips the test unless its fork is configured.
    modifier onFork() {
        if (!forked) vm.skip(true, string.concat(_rpcVar(), " is not set"));
        _;
    }

    /// @dev The 6529 delegation contract on this chain.
    function _delegationAddress() internal view returns (address) {
        return block.chainid == SEPOLIA
            ? DeployGuards.SEPOLIA_DELEGATION
            : DeployGuards.CANONICAL_DELEGATION;
    }

    /// @dev The real delegation contract and Permit2 (never etched over); the VRF coordinator is
    ///      the entropy lane's mock unless a test provides the real one (`_realCoordinator`).
    function _deployExternals() internal virtual override {
        address d = _delegationAddress();
        require(d.code.length != 0, "no delegation contract on this chain");
        require(PERMIT2.code.length != 0, "no Permit2 on this chain");
        delegation = DelegationManagementMock(d);
        permit2 = MockPermit2(PERMIT2);
        address real = _realCoordinator();
        coordinator = real == address(0) ? new MockVrfCoordinator() : MockVrfCoordinator(real);
        usd = new PermitToken();
    }

    /// @dev The chain's VRF coordinator, or zero to use the mock.
    function _realCoordinator() internal virtual returns (address) {
        return address(0);
    }

    /// @dev The deploy parameters, pinned to the canonical Permit2.
    function _params() internal view virtual override returns (DeployV1.Params memory p) {
        p = super._params();
        p.permit2 = DeployV1.CANONICAL_PERMIT2;
    }
}
