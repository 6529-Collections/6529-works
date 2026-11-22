// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DeployCore } from "script/DeployCore.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { IModules } from "src/interfaces/core/IModules.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";
import { GenesisFreshBase } from "./GenesisFreshBase.sol";

/// @notice Exposes the library's wiring validation for the real deployment's targets.
contract WiringValidator {
    function validate(GovernanceConfig.Config memory cfg, GovernanceConfig.Call[] memory wiring)
        external
        view
    {
        GovernanceConfig.validateWiring(cfg, wiring);
    }
}

/// @notice The genesis wiring on the real deployed stack (with the entropy module): the genesis
///         selector list is exactly nine selectors, each admitted only on a target declaring its
///         interface; every wired call took effect in the configuring transaction; after genesis
///         each wired selector waits its class's delay, and the one-shot bind cannot run again.
contract GenesisWiringTest is IntegrationBase {
    WiringValidator internal validator;

    function setUp() public override {
        super.setUp();
        validator = new WiringValidator();
    }

    function _withVrf() internal pure override returns (bool) {
        return true;
    }

    // ------------------------------------------------------------------ the list

    function test_GenesisWiring_TheGenesisSelectorsAreExactlyTheEight() public view {
        bytes4[8] memory sels = _genesisSelectors();
        bytes4[8] memory ifaces = [
            type(IPackageRegistry).interfaceId,
            type(IPackageRegistry).interfaceId,
            type(IFederationRegistry).interfaceId,
            type(ISaleAdapter).interfaceId,
            type(IFederationRegistry).interfaceId,
            type(IFederationRegistry).interfaceId,
            GovernanceConfig.ANY_TARGET,
            GovernanceConfig.ANY_TARGET
        ];
        for (uint256 i; i < sels.length; ++i) {
            assertEq(GovernanceConfig.genesisInterface(sels[i]), ifaces[i]);
        }
        // No other selector of the role map, and no core module or minter function, is one.
        GovernanceConfig.Config memory cfg = _genesisConfig();
        uint256 others;
        for (uint256 i; i < cfg.targets.length; ++i) {
            for (uint256 j; j < cfg.targets[i].functions.length; ++j) {
                bytes4 sel = cfg.targets[i].functions[j].selector;
                if (_inList(sels, sel)) continue;
                assertFalse(
                    GovernanceConfig.isGenesisSelector(sel), vm.toString(abi.encodePacked(sel))
                );
                ++others;
            }
        }
        assertGt(others, 90);
        assertFalse(GovernanceConfig.isGenesisSelector(IModules.addMinter.selector));
        assertFalse(GovernanceConfig.isGenesisSelector(bytes4(0)));
        assertEq(GovernanceConfig.MAX_WIRING_CALLS, 64);
    }

    function test_GenesisWiring_TheWiringIsTheJsonsWithTheEntropyCallsWhenThereIsAModule()
        public
        view
    {
        GovernanceConfig.Call[] memory calls = DeployCore.wiring(deployment, genesisJson, manifest);
        assertEq(calls.length, 10);
        uint256 entropyCalls;
        for (uint256 i; i < calls.length; ++i) {
            bytes4 sel = bytes4(calls[i].data);
            assertTrue(GovernanceConfig.isGenesisSelector(sel));
            if (
                sel == IPackageRegistry.setEntropyModule.selector
                    || sel == FederationRegistry.setEntropyModule.selector
            ) ++entropyCalls;
        }
        assertEq(entropyCalls, 2);
        DeployCore.Deployment memory without = deployment;
        without.entropyModule = address(0);
        assertEq(DeployCore.wiring(without, genesisJson, manifest).length, 8, "left out");
    }

    function test_GenesisWiring_EveryWiredCallTookEffectAtGenesis() public view {
        assertEq(registry.stream(), address(stream), "bindStream");
        assertEq(registry.entropyModule(), address(entropy), "PackageRegistry.setEntropyModule");
        assertEq(
            federation.entropyModule(), address(entropy), "FederationRegistry.setEntropyModule"
        );
        assertTrue(
            IUniformEditionAuctionLens(address(editionAuction)).isTarget(address(editions)),
            "setTarget"
        );
        assertEq(allowlist.openingBid(CURRENCY_ETH), OPENING_BID, "setOpeningBid");
        address[2] memory adapters = [address(auction), deployment.federatedEditionAuction];
        for (uint256 i; i < 2; ++i) {
            IFederationRegistry.SaleContract memory s = federation.saleContractOf(adapters[i]);
            assertTrue(s.addedAt != 0 && s.removedAt == 0, "setAdapter");
        }
        _template(deployment.federatedStreamDeployer, IFederationRegistry.Form.ERC721);
        _template(deployment.federatedEditionsDeployer, IFederationRegistry.Form.ERC1155);
        (uint64 count,) = statements.chainOf(address(manager), 0);
        assertEq(count, 1, "the epoch-0 manifest is the manager's first statement");
    }

    function test_GenesisWiring_AfterGenesisEachWiredSelectorWaitsItsClass() public {
        GovernanceConfig.Call[] memory calls = DeployCore.wiring(deployment, genesisJson, manifest);
        for (uint256 i; i < calls.length; ++i) {
            bytes4 sel = bytes4(calls[i].data);
            uint64 role = manager.getTargetFunctionRole(calls[i].target, sel);
            (bool immediate, uint32 delay) = manager.canCall(network, calls[i].target, sel);
            assertFalse(immediate, "no wired selector is the network's at once");
            assertEq(delay, Roles.executionDelay(role));
            assertGe(delay, 1 days);
        }
        assertEq(
            manager.getTargetFunctionRole(address(registry), IPackageRegistry.bindStream.selector),
            Roles.ADMIN,
            "the one-shot bind stays at the 7-day default"
        );
        // And it binds once: even the network, after the wait, cannot bind again.
        bytes memory again = abi.encodeCall(IPackageRegistry.bindStream, (address(stream)));
        vm.prank(network);
        manager.schedule(address(registry), again, 0);
        vm.warp(block.timestamp + 7 days);
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.AlreadyBound.selector, bytes32("STREAM"))
        );
        manager.execute(address(registry), again);
    }

    // ------------------------------------------------------------------ validation

    function test_GenesisWiring_TheRealGenesisWiringValidates() public view {
        validator.validate(_genesisConfig(), DeployCore.wiring(deployment, genesisJson, manifest));
    }

    function test_GenesisWiring_AGenesisSelectorReachesOnlyATargetDeclaringItsInterface() public {
        _refused(address(registry), FederationRegistry.setAdapter.selector);
        _refused(address(registry), FederationRegistry.approveTemplate.selector);
        _refused(address(federation), IPackageRegistry.bindStream.selector);
        _refused(address(federation), ISaleAdapter.setTarget.selector);
        _refused(address(stream), ISaleAdapter.setTarget.selector);
        _refused(address(stream), IModules.addMinter.selector);
        _refused(address(editions), IModules.addMinter.selector);
        _refused(address(directory), IModules.addMinter.selector);
        // ANY_TARGET selectors pass validation on any configured target (only one contract
        // declares each; a call elsewhere fails when executed).
        validator.validate(
            _genesisConfig(),
            _call(address(stream), IStatementLog.appendGovernanceManifest.selector)
        );
    }

    function test_GenesisWiring_ACallOutsideTheConfiguredTargetsIsRefused() public {
        GovernanceConfig.Config memory cfg = _genesisConfig();
        bytes4 sel = IPackageRegistry.bindStream.selector;
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceConfig.InvalidWiringCall.selector, address(manager), sel
            )
        );
        validator.validate(cfg, _call(address(manager), sel));
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfig.InvalidWiringCall.selector, address(facts), sel)
        );
        validator.validate(cfg, _call(address(facts), sel));
        GovernanceConfig.Call[] memory tooMany = new GovernanceConfig.Call[](65);
        vm.expectRevert(abi.encodeWithSelector(GovernanceConfig.TooManyWiringCalls.selector, 65));
        validator.validate(cfg, tooMany);
    }

    // ------------------------------------------------------------------ helpers

    function _genesisSelectors() internal pure returns (bytes4[8] memory) {
        return [
            IPackageRegistry.bindStream.selector,
            IPackageRegistry.setEntropyModule.selector,
            FederationRegistry.setEntropyModule.selector,
            ISaleAdapter.setTarget.selector,
            FederationRegistry.setAdapter.selector,
            FederationRegistry.approveTemplate.selector,
            IAssetAllowlist.setOpeningBid.selector,
            IStatementLog.appendGovernanceManifest.selector
        ];
    }

    function _inList(bytes4[8] memory list, bytes4 sel) internal pure returns (bool) {
        for (uint256 i; i < 9; ++i) {
            if (list[i] == sel) return true;
        }
        return false;
    }

    function _template(address deployer_, IFederationRegistry.Form form) internal view {
        IFederationRegistry.Template memory t = federation.templateOf(deployer_);
        assertEq(t.version, 1, "approveTemplate");
        assertEq(uint8(t.form), uint8(form));
        assertEq(uint8(t.status), uint8(IFederationRegistry.TemplateStatus.APPROVED));
    }

    function _call(address target, bytes4 sel)
        internal
        pure
        returns (GovernanceConfig.Call[] memory calls)
    {
        calls = new GovernanceConfig.Call[](1);
        calls[0] = GovernanceConfig.Call(target, abi.encodePacked(sel, bytes32(0)));
    }

    function _refused(address target, bytes4 sel) internal {
        GovernanceConfig.Config memory cfg = _genesisConfig();
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfig.WiringSelectorNotAllowed.selector, target, sel)
        );
        validator.validate(cfg, _call(target, sel));
    }
}

/// @notice The configuring transaction with a failing wiring call: the whole configuration is
///         undone and can be sent again correctly.
contract GenesisWiringAbortTest is GenesisFreshBase {
    function test_GenesisWiring_AFailingCallAbortsTheWholeConfiguration() public {
        GovernanceConfig.Call[] memory calls = _wiring();
        GovernanceConfig.Call[] memory twice = new GovernanceConfig.Call[](calls.length + 1);
        for (uint256 i; i < calls.length; ++i) {
            twice[i] = calls[i];
        }
        twice[calls.length] = calls[0]; // bindStream again
        assertEq(bytes4(calls[0].data), IPackageRegistry.bindStream.selector);
        GovernanceConfig.Config memory cfg = _genesisConfig();
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.AlreadyBound.selector, bytes32("STREAM"))
        );
        configurator.configure(cfg, manifest.digest, twice);

        // Nothing landed: no bind, no grant, the configurator still the installer.
        assertEq(IPackageRegistry(deployment.packageRegistry).stream(), address(0));
        (bool installer,) = manager.hasRole(Roles.ADMIN, address(configurator));
        assertTrue(installer);
        (bool pauser,) = manager.hasRole(Roles.PAUSER, pauser1);
        assertFalse(pauser);

        vm.prank(deployer);
        configurator.configure(cfg, manifest.digest, calls);
        _accept();
        configurator.verify(cfg);
        assertEq(IPackageRegistry(deployment.packageRegistry).stream(), address(deployment.stream));
    }

    function test_GenesisWiring_ANonGenesisCallIsRefusedBeforeAnythingRuns() public {
        GovernanceConfig.Call[] memory calls = _wiring();
        calls[calls.length - 1] = GovernanceConfig.Call(
            address(deployment.stream), abi.encodeCall(IModules.addMinter, (address(this)))
        );
        GovernanceConfig.Config memory cfg = _genesisConfig();
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceConfig.WiringSelectorNotAllowed.selector,
                address(deployment.stream),
                IModules.addMinter.selector
            )
        );
        configurator.configure(cfg, manifest.digest, calls);
    }
}
