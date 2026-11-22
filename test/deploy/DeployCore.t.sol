// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DeployCore } from "script/DeployCore.sol";
import { VerifyCore } from "script/VerifyCore.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
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

    function verifyAllExternal(DeployCore.Params memory q, DeployCore.Deployment memory x)
        external
        view
    {
        GovernanceConfig.Config memory none;
        VerifyCore.verify(q, x, none, false);
    }

    function probeArtifact(string memory artifact) external view returns (uint256) {
        return vm.getCode(artifact).length;
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
        assertEq(list[DeployCore.PERMANENT_COUNT - 1], "Editions");
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
        assertEq(d.directory.moduleOf(Slots.FEDERATION), d.federationRegistry);
        assertEq(d.directory.moduleOf(Slots.FEDERATED_TERMS), d.streamTerms);
        assertEq(d.directory.moduleOf(Slots.FEDERATED_RECORDS), d.workRules);
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
                VerifyCore.Mismatch.selector, "Stream.RENDERER", address(d.stream)
            )
        );
        this.verifyExternal(x);
    }

    function test_AChangedSettingFailsTheGenesisReadback() public {
        _asNetwork(address(d.stream), abi.encodeCall(d.stream.setRescueDelay, (1 days)));
        vm.expectRevert(
            abi.encodeWithSelector(VerifyCore.Mismatch.selector, "Stream.rescueDelay", address(0))
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
                "Directory.ACCOUNTS announced at genesis",
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

    /// @dev The whole stack, modules included. Runs once every lane's module exists (at
    ///      integration); skipped while one of them is missing from the build.
    function test_TheWholeStackDeploysAndReadsBack() public {
        string[6] memory pending = [
            "Accounts.sol:Accounts",
            "WorkRules.sol:WorkRules",
            "StreamTerms.sol:StreamTerms",
            "FederationRegistry.sol:FederationRegistry",
            "EnglishAuction.sol:EnglishAuction",
            "UniformEditionAuction.sol:UniformEditionAuction"
        ];
        for (uint256 i; i < pending.length; ++i) {
            try this.probeArtifact(pending[i]) { }
            catch {
                vm.skip(true, string.concat("integration pending: ", pending[i]));
            }
        }
        // INTEGRATION: the modules' constructor arguments follow the lanes' briefs; this test
        // turns green when `DeployCore._moduleCode` matches the finished constructors.
        DeployCore.Params memory q = _params();
        q.namespace = keccak256("whole stack");
        DeployCore.Deployment memory all = DeployCore.deploy(q, address(this));
        this.verifyAllExternal(q, all);
    }
}
