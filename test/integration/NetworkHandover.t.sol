// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { VerifyCore } from "script/VerifyCore.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { StreamAccessManager } from "src/governance/StreamAccessManager.sol";
import { Statement } from "src/interfaces/IStatementLog.sol";
import { HASH_SHA256, HashRef } from "src/interfaces/types/HashRef.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice What a network handover moves and what it leaves (governance spec, GV-4), on the
///         whole stack as `DeployCore` deploys and configures it. `acceptNetwork` moves the
///         network address, and with it the five network roles. It does not touch the
///         operational roles (they are ordinary grants, to the former network itself or to
///         anyone) or the brake: those stay until the new network revokes or replaces them,
///         and the manager's logs name every one of them.
contract NetworkHandoverTest is IntegrationBase {
    address internal next = makeAddr("next network");

    /// @dev Records every log from the deployment on, as the readback reads them from a chain.
    function setUp() public override {
        vm.recordLogs();
        super.setUp();
    }

    /// @dev The former network granted itself PLATFORM while it was the network. After the
    ///      handover it holds none of the network roles and still acts as PLATFORM (it records
    ///      a dispute outcome and creates a collection) until the new network revokes the grant,
    ///      which takes one call with no delay; from then on it is refused.
    function test_Handover_AnOperationalRoleOfTheFormerNetworkLastsUntilTheNewNetworkRevokesIt()
        public
    {
        vm.prank(network);
        manager.grantRole(Roles.PLATFORM, network, 0);

        _handOver();

        uint64[5] memory networkRoles = [
            Roles.ADMIN,
            Roles.NETWORK,
            Roles.PARAMETER_SETTER,
            Roles.FUNDS_SETTER,
            Roles.SUCCESSOR_SETTER
        ];
        for (uint256 i; i < networkRoles.length; ++i) {
            (bool former,) = manager.hasRole(networkRoles[i], network);
            (bool current,) = manager.hasRole(networkRoles[i], next);
            assertFalse(former, "the former network holds no network role");
            assertTrue(current, "the new network holds every network role");
        }
        (bool member, uint32 delay) = manager.hasRole(Roles.PLATFORM, network);
        assertTrue(member, "the handover does not revoke an operational role");
        assertEq(delay, 0);

        vm.prank(network);
        bytes32 entry = statements.appendPlatform(_outcome("ar://outcome-after-the-handover"));
        assertEq(statements.latestDisputeOutcome(address(accounts), 7), entry);
        vm.prank(network);
        stream.createCollection("After the handover", keccak256("after the handover"));

        vm.prank(next);
        manager.revokeRole(Roles.PLATFORM, network);
        (member,) = manager.hasRole(Roles.PLATFORM, network);
        assertFalse(member, "revoked at once");
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, network)
        );
        statements.appendPlatform(_outcome("ar://refused"));
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, network)
        );
        stream.createCollection("Refused", keccak256("refused"));
    }

    /// @dev Keys the former network granted to other accounts are untouched by the handover
    ///      as well: each acts until the new network revokes it.
    function test_Handover_KeysTheFormerNetworkGrantedToOthersStayUntilRevoked() public {
        address laterPauser = makeAddr("later pauser");
        vm.prank(network);
        manager.grantRole(Roles.PAUSER, laterPauser, 0);

        _handOver();

        (bool member,) = manager.hasRole(Roles.PAUSER, laterPauser);
        assertTrue(member);
        (member,) = manager.hasRole(Roles.PAUSER, pauser1);
        assertTrue(member, "a genesis key stays too");
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector, network, Roles.NETWORK
            )
        );
        manager.revokeRole(Roles.PAUSER, laterPauser);
        vm.prank(next);
        manager.revokeRole(Roles.PAUSER, laterPauser);
        (member,) = manager.hasRole(Roles.PAUSER, laterPauser);
        assertFalse(member);
    }

    /// @dev A brake set before the handover is the brake after it. It can still delay one of
    ///      the new network's scheduled operations once, its own removal included, which then
    ///      runs 7 days after its ready time and not before.
    function test_Handover_TheBrakeStaysUntilTheNewNetworkReplacesIt() public {
        _sevenDay(network, abi.encodeCall(StreamAccessManager.setBrake, (network)));
        assertEq(manager.brake(), network);

        _handOver();
        assertEq(manager.brake(), network, "the handover does not change the brake");

        bytes memory removal = abi.encodeCall(StreamAccessManager.setBrake, (address(0)));
        vm.prank(next);
        (bytes32 operationId,) = manager.schedule(address(manager), removal, 0);
        vm.prank(network);
        manager.brakeOnce(operationId);

        vm.warp(block.timestamp + 7 days);
        uint48 notBefore = manager.notBefore(operationId);
        vm.prank(next);
        vm.expectRevert(
            abi.encodeWithSelector(
                StreamAccessManager.BrakeNotElapsed.selector, operationId, notBefore
            )
        );
        manager.execute(address(manager), removal);

        vm.warp(notBefore);
        vm.prank(next);
        manager.execute(address(manager), removal);
        assertEq(manager.brake(), address(0));
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(StreamAccessManager.NotBrake.selector, network));
        manager.brakeOnce(operationId);
    }

    /// @dev The list a handover works from: the manager's logs since the deployment name every
    ///      member of every role, the genesis keys and the two granted since, and the list is
    ///      the genesis keys again once the new network has revoked those two.
    function test_Handover_TheLogsNameEveryKeyTheNewNetworkMustReview() public {
        address laterPauser = makeAddr("later pauser");
        vm.startPrank(network);
        manager.grantRole(Roles.PLATFORM, network, 0);
        manager.grantRole(Roles.PAUSER, laterPauser, 0);
        vm.stopPrank();
        _handOver();

        GovernanceConfig.Config memory cfg = _genesisConfig();
        Vm.Log[] memory first = vm.getRecordedLogs();
        VerifyCore.Entry[] memory logs = VerifyCore.entries(first, address(manager));
        GovernanceConfig.Grant[] memory held = VerifyCore.holdersIn(logs);
        assertEq(held.length, cfg.grants.length + 2);
        for (uint256 i; i < cfg.grants.length; ++i) {
            assertEq(held[i].role, cfg.grants[i].role);
            assertEq(held[i].account, cfg.grants[i].account);
        }
        assertEq(held[cfg.grants.length].role, Roles.PLATFORM);
        assertEq(held[cfg.grants.length].account, network);
        assertEq(held[cfg.grants.length + 1].role, Roles.PAUSER);
        assertEq(held[cfg.grants.length + 1].account, laterPauser);
        VerifyCore.Difference[] memory differences = VerifyCore.governanceDifferences(cfg, logs);
        assertEq(differences.length, 2);
        assertEq(differences[0].what, "holder not in the configuration");
        assertEq(differences[0].account, network);
        assertEq(differences[1].account, laterPauser);

        vm.startPrank(next);
        manager.revokeRole(Roles.PLATFORM, network);
        manager.revokeRole(Roles.PAUSER, laterPauser);
        vm.stopPrank();
        VerifyCore.Entry[] memory later = VerifyCore.entries(vm.getRecordedLogs(), address(manager));
        VerifyCore.Entry[] memory all = new VerifyCore.Entry[](logs.length + later.length);
        for (uint256 i; i < logs.length; ++i) {
            all[i] = logs[i];
        }
        for (uint256 i; i < later.length; ++i) {
            all[logs.length + i] = later[i];
        }
        assertEq(VerifyCore.holdersIn(all).length, cfg.grants.length);
        assertEq(VerifyCore.governanceDifferences(cfg, all).length, 0);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev The network names `next` (a 7-day action) and `next` accepts.
    function _handOver() internal {
        _sevenDay(network, abi.encodeCall(StreamAccessManager.transferNetwork, (next)));
        vm.prank(next);
        manager.acceptNetwork();
        assertEq(manager.network(), next);
    }

    /// @dev `who` (the network) runs a 7-day action on the manager: schedule, wait, execute.
    function _sevenDay(address who, bytes memory data) internal {
        vm.prank(who);
        manager.schedule(address(manager), data, 0);
        vm.warp(block.timestamp + 7 days);
        vm.prank(who);
        manager.execute(address(manager), data);
    }

    function _outcome(string memory uri) internal view returns (Statement memory) {
        return Statement(
            address(accounts),
            7,
            StatementKinds.DISPUTE_OUTCOME,
            keccak256("6529-stream/dispute-outcome/1"),
            HashRef(HASH_SHA256, keccak256(bytes(uri))),
            uri,
            bytes32(0),
            bytes32(0)
        );
    }
}
