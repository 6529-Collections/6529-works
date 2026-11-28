// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";
import { GenesisFreshBase } from "./GenesisFreshBase.sol";

interface IPausable {
    function pause() external;
    function unpause() external;
}

/// @notice The genesis configuration on the real deployed stack, installed by
///         `GovernanceConfigurator.configure` from `config/genesis.core.example.json`: it reads
///         back after the network accepts, the configurator and the deployer keep nothing, the
///         holders are the operational keys with no delay, each pauser stops the sale contracts
///         at once while only the network resumes them, and every mapped selector runs at its
///         class's delay.
contract GenesisConfigTest is IntegrationBase {
    address internal stranger = makeAddr("genesisStranger");

    function test_GenesisConfig_TheInstalledConfigurationReadsBack() public {
        configurator.verify(_genesisConfig());
        vm.warp(block.timestamp + 365 days);
        configurator.verify(_genesisConfig());
        assertEq(manager.network(), network);
        assertEq(manager.pendingNetwork(), address(0), "the network accepted");
        assertEq(manager.brake(), address(0), "no brake at launch");
    }

    function test_GenesisConfig_AChangedMapFailsTheReadback() public {
        GovernanceConfig.Config memory cfg = _genesisConfig();
        GovernanceConfig.FunctionRole memory fn = cfg.targets[0].functions[0];
        address target = cfg.targets[0].target;
        uint64 other = fn.role == Roles.NETWORK ? Roles.PARAMETER_SETTER : Roles.NETWORK;
        bytes4[] memory one = new bytes4[](1);
        one[0] = fn.selector;
        _asNetwork(
            address(manager),
            abi.encodeCall(IAccessManager.setTargetFunctionRole, (target, one, other))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceConfig.FunctionRoleMismatch.selector, target, fn.selector, other
            )
        );
        configurator.verify(cfg);
    }

    function test_GenesisConfig_TheConfiguratorAndTheDeployerKeepNothing() public {
        for (uint64 role; role < Roles.COUNT; ++role) {
            if (!Roles.isKnown(role)) continue;
            assertFalse(GovernanceConfig.hasRecord(manager, role, address(configurator)));
            assertFalse(GovernanceConfig.hasRecord(manager, role, deployer));
        }
        // Configure again: the deployer's configurator holds no ADMIN record any more.
        GovernanceConfig.Call[] memory none;
        GovernanceConfig.Config memory cfg = _genesisConfig();
        vm.prank(deployer);
        vm.expectRevert();
        configurator.configure(cfg, manifest.digest, none);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfigurator.NotDeployer.selector, stranger)
        );
        configurator.configure(cfg, manifest.digest, none);
    }

    function test_GenesisConfig_HoldersAreTheOperationalKeysWithNoDelay() public view {
        GovernanceConfig.Config memory cfg = _genesisConfig();
        assertEq(cfg.grants.length, 8);
        for (uint256 i; i < cfg.grants.length; ++i) {
            assertFalse(Roles.isNetworkRole(cfg.grants[i].role), "no grant of a network role");
            (bool member, uint32 delay) = manager.hasRole(cfg.grants[i].role, cfg.grants[i].account);
            assertTrue(member && delay == 0);
        }
        address[3] memory pausers = [pauser1, pauser2, pauser3];
        for (uint256 i; i < 3; ++i) {
            (bool member,) = manager.hasRole(Roles.PAUSER, pausers[i]);
            assertTrue(member, "pauser");
        }
        _holds(Roles.CURATION_SIGNER, signer1);
        _holds(Roles.CURATION_SIGNER, signer2);
        _holds(Roles.STORAGE_OPERATOR, storageOperator);
        _holds(Roles.PLATFORM, platform);
        _holds(Roles.CURATOR, curator);
        // The network holds every network role, each at its class's delay.
        uint64[5] memory networkRoles = [
            Roles.ADMIN,
            Roles.NETWORK,
            Roles.PARAMETER_SETTER,
            Roles.FUNDS_SETTER,
            Roles.SUCCESSOR_SETTER
        ];
        for (uint256 i; i < 5; ++i) {
            (bool member, uint32 delay) = manager.hasRole(networkRoles[i], network);
            assertTrue(member, vm.toString(networkRoles[i]));
            assertEq(delay, Roles.executionDelay(networkRoles[i]));
        }
    }

    function test_GenesisConfig_EachPauserStopsTheSalesAtOnceAndOnlyTheNetworkResumes() public {
        address[3] memory sales =
            [address(auction), address(editionAuction), deployment.independentEditionAuction];
        address[3] memory pausers = [pauser1, pauser2, pauser3];
        for (uint256 i; i < 3; ++i) {
            for (uint256 k; k < 3; ++k) {
                vm.prank(pausers[k]);
                IPausable(sales[i]).pause();
                vm.prank(pausers[k]);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IAccessManaged.AccessManagedUnauthorized.selector, pausers[k]
                    )
                );
                IPausable(sales[i]).unpause();
                vm.prank(network);
                IPausable(sales[i]).unpause();
            }
            vm.prank(stranger);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
            );
            IPausable(sales[i]).pause();
        }
        // A paused auction starts nothing.
        Work[] memory works = _one(_work(_actor("pausedArtist"), collectionId));
        bytes32 root = _publish(works);
        bytes memory request = _mintData(root, works, 0);
        vm.prank(pauser1);
        auction.pause();
        vm.expectRevert(IEnglishAuction.SalePaused.selector);
        auction.start(address(stream), request);
        vm.prank(network);
        auction.unpause();
        auction.start(address(stream), request);
    }

    function test_GenesisConfig_EveryMappedSelectorRunsAtItsClassDelay() public view {
        GovernanceConfig.Config memory cfg = _genesisConfig();
        uint256 checked;
        for (uint256 i; i < cfg.targets.length; ++i) {
            address target = cfg.targets[i].target;
            for (uint256 j; j < cfg.targets[i].functions.length; ++j) {
                GovernanceConfig.FunctionRole memory fn = cfg.targets[i].functions[j];
                assertEq(manager.getTargetFunctionRole(target, fn.selector), fn.role);
                (bool immediate, uint32 delay) = manager.canCall(network, target, fn.selector);
                if (Roles.isNetworkRole(fn.role)) {
                    assertEq(delay, Roles.executionDelay(fn.role), "network class delay");
                    assertEq(immediate, delay == 0);
                } else {
                    // The network holds no operational role; its keys act at once.
                    assertFalse(immediate || delay != 0, "the network is not an operational key");
                    address holder = _holderOf(cfg, fn.role);
                    (immediate, delay) = manager.canCall(holder, target, fn.selector);
                    assertTrue(immediate && delay == 0, "operational keys act at once");
                }
                (immediate, delay) = manager.canCall(stranger, target, fn.selector);
                assertFalse(immediate || delay != 0, "nobody else");
                ++checked;
            }
        }
        assertGt(checked, 100);
    }

    function _holds(uint64 role, address account) internal view {
        (bool member, uint32 delay) = manager.hasRole(role, account);
        assertTrue(member && delay == 0, Roles.label(role));
    }

    function _holderOf(GovernanceConfig.Config memory cfg, uint64 role)
        internal
        pure
        returns (address)
    {
        for (uint256 i; i < cfg.grants.length; ++i) {
            if (cfg.grants[i].role == role) return cfg.grants[i].account;
        }
        revert("no holder for an operational role in the map");
    }
}

/// @notice The genesis transaction itself: `configure` with the committed configuration and the
///         longest wiring (with the entropy module) fits the EIP-7825 transaction cap with 40%
///         headroom, and the result reads back once the network accepts.
contract GenesisTransactionTest is GenesisFreshBase {
    function test_GenesisConfig_ConfigureFitsTheTransactionCap() public {
        GovernanceConfig.Call[] memory calls = _wiring();
        assertEq(calls.length, 10, "the longest genesis wiring");
        (bool ok, uint256 total) = _sendAsDeployer(_configureData(calls));
        assertTrue(ok, "configure");
        console2.log("genesis configure, whole transaction", total);
        assertLt(total, TX_GAS_CAP * 60 / 100, "keep 40% headroom under the EIP-7825 cap");
        _accept();
        configurator.verify(_genesisConfig());
    }

    function test_GenesisConfig_NothingIsGovernedBeforeTheNetworkAccepts() public {
        (bool ok,) = _sendAsDeployer(_configureData(_wiring()));
        assertTrue(ok);
        assertEq(manager.network(), address(0), "proposed, not in charge");
        assertEq(manager.pendingNetwork(), network);
        vm.expectRevert();
        configurator.verify(_genesisConfig());
        _accept();
        configurator.verify(_genesisConfig());
    }
}
