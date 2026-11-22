// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DeployCore } from "script/DeployCore.sol";
import { VerifyCore } from "script/VerifyCore.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { CoreDeployFixture } from "./CoreDeployFixture.sol";

/// @notice The plain-core deploy library: predicted addresses, the permanent contracts' wiring,
///         the genesis modules and minters as constructor arguments, the launch values of the
///         four settings, and the readback that catches a difference.
contract DeployCoreTest is CoreDeployFixture {
    function _networkAccount() internal override returns (address) {
        return makeAddr("network");
    }

    function verifyExternal(DeployCore.Deployment memory x) external view {
        VerifyCore.verifyPermanent(p, x);
    }

    function test_EveryPermanentContractIsAtItsPredictedAddress() public view {
        DeployCore.Deployment memory q = DeployCore.predict(p, address(this));
        string[] memory list = DeployCore.order(p);
        for (uint256 i; i < DeployCore.PERMANENT_COUNT; ++i) {
            address a = DeployCore.addressOf(d, list[i]);
            assertEq(a, DeployCore.addressOf(q, list[i]), list[i]);
            assertGt(a.code.length, 0, list[i]);
        }
        assertEq(address(d.manager), address(d.configurator.worksManager()));
        assertEq(DeployCore.PERMANENT_COUNT, 11);
        assertEq(list[DeployCore.PERMANENT_COUNT - 1], "StreamEditions6529");
    }

    function test_AddressesDependOnlyOnTheNamespaceAndTheName() public view {
        DeployCore.Params memory other = _params();
        other.marketOwner = address(0xBEEF);
        other.feeRecipient = address(0xCAFE);
        DeployCore.Deployment memory a = DeployCore.predict(other, address(this));
        assertEq(address(a.stream), address(d.stream));
        assertEq(a.renderer, d.renderer);
        other.namespace = keccak256("another system");
        DeployCore.Deployment memory b = DeployCore.predict(other, address(this));
        assertTrue(address(b.stream) != address(d.stream));
        assertTrue(b.workRules != d.workRules);
    }

    function test_GenesisModulesAndMintersAreConstructorArguments() public view {
        assertEq(d.stream.moduleOf(Slots.RENDERER), d.renderer);
        assertEq(d.stream.moduleOf(Slots.TERMS), d.streamTerms);
        assertEq(d.stream.moduleOf(Slots.RECORDS), d.workRules);
        assertTrue(d.stream.isMinter(d.englishAuction));
        assertEq(d.editions.moduleOf(Slots.TERMS), d.streamTerms);
        assertTrue(d.editions.isMinter(d.editionAuction));
        assertEq(d.directory.moduleOf(Slots.ACCOUNTS), d.accounts);
        assertEq(d.directory.moduleOf(Slots.INDEPENDENT_STREAM), d.independentStreamRegistry);
        assertEq(d.directory.moduleOf(Slots.INDEPENDENT_TERMS), d.streamTerms);
        assertEq(d.directory.moduleOf(Slots.INDEPENDENT_RECORDS), d.workRules);
        assertEq(address(d.splitLedger.resolver()), address(d.directory));
    }

    function test_TheSettingsStartAtTheirLaunchValues() public view {
        assertEq(d.stream.moduleDelay(), DeployCore.LAUNCH_MODULE_DELAY);
        assertEq(d.editions.moduleDelay(), DeployCore.LAUNCH_MODULE_DELAY);
        assertEq(d.directory.moduleDelay(), DeployCore.LAUNCH_MODULE_DELAY);
        assertEq(d.stream.rescueDelay(), DeployCore.LAUNCH_RESCUE_DELAY);
        assertEq(d.editions.rebindDelay(), DeployCore.LAUNCH_REBIND_DELAY);
        assertEq(d.directory.unclaimedPeriod(), DeployCore.LAUNCH_UNCLAIMED_PERIOD);
    }

    function test_TheGenesisReadsBack() public view {
        this.verifyExternal(d);
        d.configurator.verify(_config());
    }

    function test_AWrongModuleFailsTheReadback() public {
        DeployCore.Deployment memory x = d;
        x.renderer = address(0xBAD);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyCore.Mismatch.selector, "Stream6529.RENDERER", address(d.stream)
            )
        );
        this.verifyExternal(x);
    }

    function test_AChangedSettingFailsTheGenesisReadback() public {
        _asNetwork(address(d.stream), abi.encodeCall(d.stream.setRescueDelay, (1 days)));
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyCore.Mismatch.selector, "Stream6529.rescueDelay", address(0)
            )
        );
        this.verifyExternal(d);
    }

    function test_AnAnnouncedModuleFailsTheGenesisReadback() public {
        _asNetwork(
            address(d.directory),
            abi.encodeCall(d.directory.proposeModule, (Slots.ACCOUNTS, address(d.contentStore)))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyCore.Mismatch.selector,
                "StreamDirectory6529.ACCOUNTS announced at genesis",
                address(d.directory)
            )
        );
        this.verifyExternal(d);
    }

    function test_TheGovernedTargetsAreThePermanentContractsAndTheMoneyContracts() public view {
        GovernanceConfig.Config memory cfg = _config();
        assertEq(cfg.network, network);
        // Stream, Editions, Directory, the escrow and the two vaults exist at the base; the
        // modules join at integration.
        assertEq(cfg.targets.length, 6);
    }

    function verifyAllExternal(
        DeployCore.Params memory q,
        DeployCore.Deployment memory x,
        GovernanceConfig.Config memory cfg
    ) external view {
        VerifyCore.verify(q, x, cfg, true);
    }

    /// @dev The whole stack, modules included: deployed with the real constructors, the
    ///      committed genesis policy installed with its wiring, the network accepted, and every
    ///      contract read back.
    function test_TheWholeStackDeploysInstallsAndReadsBack() public {
        DeployCore.Params memory q = _params();
        q.namespace = keccak256("whole stack");
        q.delegation = address(new DelegationManagementMock());
        q.auctionConfig = DeployCore.auctionConfig();
        q.editionAuctionConfig = DeployCore.editionAuctionConfig();
        DeployCore.Deployment memory all = DeployCore.deploy(q, address(this));
        string memory json = vm.readFile(GENESIS);
        DeployCore.Manifest memory manifest =
            DeployCore.Manifest(keccak256("whole stack manifest"), "ar://whole-stack");
        GovernanceConfig.Config memory cfg = DeployCore.config(all, json);
        cfg.network = network;
        GovernanceConfig.Call[] memory calls = DeployCore.wiring(all, json, manifest);
        assertEq(calls.length, 8, "every wiring call but the two entropy ones applies");
        vm.prank(deployer);
        DeployCore.install(all, cfg, manifest, calls);
        vm.prank(network);
        all.manager.acceptNetwork();
        this.verifyAllExternal(q, all, cfg);
        assertEq(IPackageRegistryStream(all.packageRegistry).stream(), address(all.stream));
        assertTrue(all.stream.isMinter(all.englishAuction), "the English auction mints Stream");
        assertTrue(all.editions.isMinter(all.editionAuction), "the edition auction mints Editions");
    }
}

/// @dev The package registry's bound Stream.
interface IPackageRegistryStream {
    function stream() external view returns (address);
}
