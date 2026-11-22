// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Multicall } from "@openzeppelin/contracts/utils/Multicall.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { Roles } from "src/governance/Roles.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStatementLog, Statement } from "src/interfaces/IStatementLog.sol";
import { HASH_SHA256, HashRef } from "src/interfaces/types/HashRef.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { GovernanceFixture } from "../helpers/GovernanceFixture.sol";
import { GovernedTargetMock } from "../mocks/governance/GovernanceMocks.sol";
import {
    Erc165PeerPortedMock,
    WiringTargetPortedMock,
    WiringValidationPortedHarness
} from "./GenesisWiringPortedMocks.sol";

/// @notice Re-ported from the retired `GenesisWiring` suite onto today's allow-list: the genesis
///         wiring (the package registry's Stream bind and entropy module, an edition auction's
///         sale target, the asset allowlist's first default currency and ETH opening bid, the
///         federation module's adapters, templates and entropy module, and the epoch-0 manifest)
///         runs as the zero-delay installer inside the configuring transaction, and nothing else
///         does.
contract GenesisWiringPortedTest is GovernanceFixture {
    WiringTargetPortedMock internal wired;
    Erc165PeerPortedMock internal peerA;
    Erc165PeerPortedMock internal peerB;

    function setUp() public {
        _deployUnconfigured();
        wired = new WiringTargetPortedMock(address(manager));
        peerA = new Erc165PeerPortedMock();
        peerB = new Erc165PeerPortedMock();
    }

    /// @dev The default config plus `wired`: `bindStream` stays unmapped (ADMIN), as in the
    ///      genesis file; `setTarget` and `setVerifier` map to the 7-day class.
    function _wiredConfig() internal view returns (GovernanceConfig.Config memory cfg) {
        cfg = _config();
        GovernanceConfig.Target[] memory targets = new GovernanceConfig.Target[](2);
        targets[0] = cfg.targets[0];
        GovernanceConfig.FunctionRole[] memory fns = new GovernanceConfig.FunctionRole[](2);
        fns[0] = GovernanceConfig.FunctionRole(
            WiringTargetPortedMock.setTarget.selector, Roles.SUCCESSOR_SETTER
        );
        fns[1] = GovernanceConfig.FunctionRole(
            WiringTargetPortedMock.setVerifier.selector, Roles.SUCCESSOR_SETTER
        );
        targets[1] = GovernanceConfig.Target(address(wired), fns);
        cfg.targets = targets;
    }

    function _call(address to, bytes memory data)
        internal
        pure
        returns (GovernanceConfig.Call memory)
    {
        return GovernanceConfig.Call(to, data);
    }

    function _oneCall(GovernanceConfig.Call memory c)
        internal
        pure
        returns (GovernanceConfig.Call[] memory wiring)
    {
        wiring = new GovernanceConfig.Call[](1);
        wiring[0] = c;
    }

    function _genesisCalls() internal view returns (GovernanceConfig.Call[] memory wiring) {
        wiring = new GovernanceConfig.Call[](2);
        wiring[0] = _call(
            address(wired), abi.encodeCall(WiringTargetPortedMock.bindStream, (address(peerA)))
        );
        wiring[1] = _call(
            address(wired), abi.encodeCall(WiringTargetPortedMock.setTarget, (address(peerB), true))
        );
    }

    function _expectWiringRevert(GovernanceConfig.Call[] memory wiring, bytes memory err) internal {
        GovernanceConfig.Config memory cfg = _wiredConfig();
        vm.expectRevert(err);
        configurator.configure(cfg, MANIFEST, wiring);
    }

    function _assertUntouched() internal view {
        assertEq(wired.stream(), address(0));
        assertEq(manager.getRoleGuardian(Roles.PAUSER), Roles.ADMIN, "no role setup");
        (bool stillAdmin,) = manager.hasRole(Roles.ADMIN, address(configurator));
        assertTrue(stillAdmin, "the configurator still holds ADMIN and can retry");
        (uint48 since,,,) = manager.getAccess(Roles.PAUSER, guardianA);
        assertEq(since, 0, "no grants");
    }

    // ------------------------------------------------------------------ the allow-list

    function test_MaxWiringCallsIsPinned() public pure {
        assertEq(GovernanceConfig.MAX_WIRING_CALLS, 64);
    }

    /// @dev Exactly nine selectors, each scoped to the interface it is admitted for.
    function test_GenesisSelectorsAreExactlyTheAllowList() public pure {
        bytes4[8] memory allowed = [
            IPackageRegistry.bindStream.selector,
            IPackageRegistry.setEntropyModule.selector,
            ISaleAdapter.setTarget.selector,
            IAssetAllowlist.setOpeningBid.selector,
            FederationRegistry.setAdapter.selector,
            FederationRegistry.approveTemplate.selector,
            FederationRegistry.setEntropyModule.selector,
            IStatementLog.appendGovernanceManifest.selector
        ];
        bytes4[8] memory scope = [
            type(IPackageRegistry).interfaceId,
            type(IPackageRegistry).interfaceId,
            type(ISaleAdapter).interfaceId,
            GovernanceConfig.ANY_TARGET,
            GovernanceConfig.ANY_TARGET,
            type(IFederationRegistry).interfaceId,
            type(IFederationRegistry).interfaceId,
            type(IFederationRegistry).interfaceId,
            GovernanceConfig.ANY_TARGET
        ];
        for (uint256 i; i < allowed.length; ++i) {
            assertTrue(GovernanceConfig.isGenesisSelector(allowed[i]));
            assertEq(GovernanceConfig.genesisInterface(allowed[i]), scope[i]);
        }
        // Later changes of the same contracts wait their class.
        assertFalse(GovernanceConfig.isGenesisSelector(IPackageRegistry.setVerifier.selector));
        assertFalse(GovernanceConfig.isGenesisSelector(FederationRegistry.revokeTemplate.selector));
        assertFalse(GovernanceConfig.isGenesisSelector(FederationRegistry.lowerFeeShare.selector));
        assertFalse(GovernanceConfig.isGenesisSelector(ISaleAdapter.unpause.selector));
        assertFalse(GovernanceConfig.isGenesisSelector(bytes4(0)));
        assertFalse(GovernanceConfig.isGenesisSelector(0xffffffff));
    }

    function testFuzz_OnlyGenesisSelectorsPassValidation(bytes4 selector) public {
        _expectValidation(selector);
    }

    /// @dev The federation module's genesis selectors reach only a target declaring
    ///      `IFederationRegistry`: the wiring mock does not, so all three are refused there;
    ///      the package registry's and the sale adapter's pass (explicit, so coverage does not
    ///      rest on the fuzzer).
    function test_FederationRegistrySelectorsNeedTheirInterface() public {
        assertFalse(
            IERC165(address(wired)).supportsInterface(type(IFederationRegistry).interfaceId)
        );
        _expectValidation(FederationRegistry.approveTemplate.selector);
        _expectValidation(FederationRegistry.setAdapter.selector);
        _expectValidation(FederationRegistry.setEntropyModule.selector);
        _expectValidation(IPackageRegistry.bindStream.selector);
        _expectValidation(ISaleAdapter.setTarget.selector);
        _expectValidation(IAssetAllowlist.setOpeningBid.selector);
    }

    /// @dev Validates one wiring call of `selector` on the wiring mock, expecting what
    ///      `genesisInterface` and the mock's declared interfaces allow.
    function _expectValidation(bytes4 selector) internal {
        WiringValidationPortedHarness harness = new WiringValidationPortedHarness();
        GovernanceConfig.Config memory cfg = _wiredConfig();
        GovernanceConfig.Call[] memory wiring =
            _oneCall(_call(address(wired), abi.encodePacked(selector, bytes32(0))));
        bytes4 iface = GovernanceConfig.genesisInterface(selector);
        bool allowed = iface != 0
            && (iface == GovernanceConfig.ANY_TARGET
                || IERC165(address(wired)).supportsInterface(iface));
        if (!allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    GovernanceConfig.WiringSelectorNotAllowed.selector, address(wired), selector
                )
            );
        }
        harness.validateWiring(cfg, wiring);
    }

    // ------------------------------------------------------------------ happy path

    function test_WiringExecutesGenesisCallsInTheConfiguringTransaction() public {
        GovernanceConfig.Config memory cfg = _wiredConfig();
        GovernanceConfig.Call[] memory wiring = _genesisCalls();
        vm.expectEmit(address(wired));
        emit WiringTargetPortedMock.Bound(
            WiringTargetPortedMock.bindStream.selector, address(peerA)
        );
        vm.expectEmit(address(configurator));
        emit GovernanceConfigurator.GovernanceConfigured(
            address(manager), keccak256(abi.encode(cfg)), MANIFEST, keccak256(abi.encode(wiring))
        );
        configurator.configure(cfg, MANIFEST, wiring);
        assertEq(wired.stream(), address(peerA));
        assertTrue(wired.isTarget(address(peerB)));
        _accept();
        configurator.verify(cfg);
    }

    /// @dev `setTarget` maps to SUCCESSOR_SETTER, which the configurator never holds, yet the
    ///      wiring call succeeds: it runs while every selector still resolves to ADMIN. After
    ///      genesis the same calls are the network's at 7 days, and the configurator holds nothing.
    function test_WiringRunsBeforeSelectorsAreMapped() public {
        configurator.configure(_wiredConfig(), MANIFEST, _genesisCalls());
        _accept();
        assertEq(
            manager.getTargetFunctionRole(
                address(wired), WiringTargetPortedMock.setTarget.selector
            ),
            Roles.SUCCESSOR_SETTER
        );
        (uint48 since,,,) = manager.getAccess(Roles.SUCCESSOR_SETTER, address(configurator));
        assertEq(since, 0);
        bytes4[2] memory selectors =
            [WiringTargetPortedMock.setTarget.selector, WiringTargetPortedMock.bindStream.selector];
        for (uint256 i; i < selectors.length; ++i) {
            (bool immediate, uint32 delay) =
                manager.canCall(adminSafe, address(wired), selectors[i]);
            assertFalse(immediate);
            assertEq(delay, 7 days);
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManaged.AccessManagedUnauthorized.selector, address(configurator)
            )
        );
        vm.prank(address(configurator));
        wired.setTarget(address(peerA), true);
    }

    function test_ConfiguratorEndsWithNoRoleAfterWiring() public {
        configurator.configure(_wiredConfig(), MANIFEST, _genesisCalls());
        for (uint64 role; role < Roles.COUNT; ++role) {
            assertFalse(GovernanceConfig.hasRecord(manager, role, address(configurator)));
        }
    }

    function test_EmptyWiringIsAllowed() public {
        configurator.configure(_wiredConfig(), MANIFEST, _noWiring());
        assertEq(wired.stream(), address(0));
    }

    /// @dev The real statement log: the manifest history starts with the genesis epoch; later
    ///      epochs go through the 7-day class.
    function test_EpochZeroManifestIsWrittenAtGenesis() public {
        StatementLog log = new StatementLog(address(manager), address(0), bytes32(0));
        GovernanceConfig.Config memory cfg = _wiredConfig();
        GovernanceConfig.Target[] memory targets = new GovernanceConfig.Target[](3);
        (targets[0], targets[1]) = (cfg.targets[0], cfg.targets[1]);
        GovernanceConfig.FunctionRole[] memory fns = new GovernanceConfig.FunctionRole[](3);
        fns[0] = GovernanceConfig.FunctionRole(
            StatementLog.appendGovernanceManifest.selector, Roles.SUCCESSOR_SETTER
        );
        fns[1] = GovernanceConfig.FunctionRole(StatementLog.appendCurator.selector, Roles.CURATOR);
        fns[2] = GovernanceConfig.FunctionRole(StatementLog.appendPlatform.selector, Roles.PLATFORM);
        targets[2] = GovernanceConfig.Target(address(log), fns);
        cfg.targets = targets;

        Statement memory manifest = Statement({
            token: address(manager),
            id: 0,
            kind: StatementKinds.GOVERNANCE_MANIFEST,
            schema: keccak256("6529-works/governance-manifest/1"),
            content: HashRef(HASH_SHA256, keccak256("signed epoch-0 manifest")),
            uri: "ar://epoch-0-manifest",
            fileId: bytes32(0),
            supersedes: bytes32(0)
        });
        GovernanceConfig.Call[] memory wiring = _oneCall(
            _call(address(log), abi.encodeCall(StatementLog.appendGovernanceManifest, (manifest)))
        );
        configurator.configure(cfg, MANIFEST, wiring);
        _accept();

        (uint64 count, bytes32 head) = log.chainOf(address(manager), 0);
        assertEq(count, 1, "epoch-0 manifest recorded");
        assertTrue(head != bytes32(0));
        (bool immediate, uint32 delay) =
            manager.canCall(adminSafe, address(log), StatementLog.appendGovernanceManifest.selector);
        assertFalse(immediate);
        assertEq(delay, 7 days);
    }

    // ------------------------------------------------------------------ failures abort all

    function test_RevertingWiringCallAbortsTheWholeConfiguration() public {
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](2);
        wiring[0] = _call(
            address(wired), abi.encodeCall(WiringTargetPortedMock.bindStream, (address(peerA)))
        );
        wiring[1] = _call(
            address(wired),
            abi.encodeCall(WiringTargetPortedMock.setEntropyModule, (address(0), address(peerB)))
        );
        _expectWiringRevert(wiring, abi.encodeWithSelector(WiringTargetPortedMock.Refused.selector));
        _assertUntouched();
    }

    function test_SilentWiringRevertIsNamedByIndex() public {
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](2);
        wiring[0] = _call(
            address(wired), abi.encodeCall(WiringTargetPortedMock.bindStream, (address(peerA)))
        );
        wiring[1] = _call(
            address(wired),
            abi.encodeCall(WiringTargetPortedMock.setOpeningBid, (address(0), 1, 1 ether))
        );
        _expectWiringRevert(
            wiring, abi.encodeWithSelector(GovernanceConfig.WiringCallFailed.selector, 1)
        );
        _assertUntouched();
    }

    function test_RepeatedOneShotBindAbortsTheWholeConfiguration() public {
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](2);
        wiring[0] = _call(
            address(wired), abi.encodeCall(WiringTargetPortedMock.bindStream, (address(peerA)))
        );
        wiring[1] = _call(
            address(wired), abi.encodeCall(WiringTargetPortedMock.bindStream, (address(peerB)))
        );
        _expectWiringRevert(
            wiring,
            abi.encodeWithSelector(
                WiringTargetPortedMock.AlreadyBound.selector,
                WiringTargetPortedMock.bindStream.selector
            )
        );
        _assertUntouched();
    }

    // ------------------------------------------------------------------ rejected wiring

    /// @dev Wiring reaches only genesis selectors, so no delayed swap (a verifier or a
    ///      recipient change) can run at zero delay through it.
    function test_RejectsZeroDelaySwapsThroughWiring() public {
        bytes[2] memory onTarget = [
            abi.encodeCall(GovernedTargetMock.setVerifier, (verifier0, attacker)),
            abi.encodeCall(GovernedTargetMock.setRecipient, (recipient0, attacker))
        ];
        for (uint256 i; i < onTarget.length; ++i) {
            _expectWiringRevert(
                _oneCall(_call(address(target), onTarget[i])),
                abi.encodeWithSelector(
                    GovernanceConfig.WiringSelectorNotAllowed.selector,
                    address(target),
                    bytes4(onTarget[i])
                )
            );
        }
        _expectWiringRevert(
            _oneCall(
                _call(
                    address(wired), abi.encodeCall(WiringTargetPortedMock.setVerifier, (attacker))
                )
            ),
            abi.encodeWithSelector(
                GovernanceConfig.WiringSelectorNotAllowed.selector,
                address(wired),
                WiringTargetPortedMock.setVerifier.selector
            )
        );
        assertEq(target.verifier(), verifier0);
    }

    /// @dev A scoped genesis selector reaches only a contract that declares the interface it is
    ///      admitted for: the sample target declares none, so each is refused there; the wiring
    ///      mock, which declares them, still receives its own.
    function test_GenesisSelectorsReachOnlyTheirTargets() public {
        bytes4[6] memory scoped = [
            ISaleAdapter.setTarget.selector,
            IPackageRegistry.bindStream.selector,
            IPackageRegistry.setEntropyModule.selector,
            FederationRegistry.setAdapter.selector,
            FederationRegistry.approveTemplate.selector,
            FederationRegistry.setEntropyModule.selector
        ];
        for (uint256 i; i < scoped.length; ++i) {
            _expectWiringRevert(
                _oneCall(
                    _call(address(target), abi.encodePacked(scoped[i], bytes32(0), bytes32(0)))
                ),
                abi.encodeWithSelector(
                        GovernanceConfig.WiringSelectorNotAllowed.selector,
                        address(target),
                        scoped[i]
                    )
            );
        }
        configurator.configure(_wiredConfig(), MANIFEST, _genesisCalls());
        assertTrue(wired.isTarget(address(peerB)));
    }

    /// @dev Even with the manager admitted as a target, the allow-list rejects its `multicall`
    ///      and its role functions.
    function test_AllowListRejectsManagerCallsEvenIfTheManagerWereATarget() public {
        WiringValidationPortedHarness harness = new WiringValidationPortedHarness();
        GovernanceConfig.Config memory cfg;
        cfg.targets = new GovernanceConfig.Target[](1);
        cfg.targets[0].target = address(manager);
        bytes[] memory inner = new bytes[](1);
        inner[0] = abi.encodeCall(IAccessManager.grantRole, (Roles.ADMIN, attacker, 0));
        bytes[2] memory calls = [abi.encodeCall(Multicall.multicall, (inner)), inner[0]];
        for (uint256 i; i < calls.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    GovernanceConfig.WiringSelectorNotAllowed.selector,
                    address(manager),
                    bytes4(calls[i])
                )
            );
            harness.validateWiring(cfg, _oneCall(_call(address(manager), calls[i])));
        }
    }

    function test_RejectsWiringOnTheManagersRoleAdminFunctions() public {
        bytes[2] memory calls = [
            abi.encodeCall(IAccessManager.grantRole, (Roles.ADMIN, attacker, 0)),
            abi.encodeCall(
                IAccessManager.setTargetFunctionRole,
                (address(target), _one(GovernedTargetMock.setRecipient.selector), Roles.KEEPER)
            )
        ];
        for (uint256 i; i < calls.length; ++i) {
            _expectWiringRevert(
                _oneCall(_call(address(manager), calls[i])),
                abi.encodeWithSelector(
                    GovernanceConfig.InvalidWiringCall.selector, address(manager), bytes4(calls[i])
                )
            );
        }
    }

    function test_RejectsAccessManagementSelectorsOnAnyTarget() public {
        bytes4[16] memory selectors = [
            IAccessManager.labelRole.selector,
            IAccessManager.grantRole.selector,
            IAccessManager.revokeRole.selector,
            IAccessManager.renounceRole.selector,
            IAccessManager.setRoleAdmin.selector,
            IAccessManager.setRoleGuardian.selector,
            IAccessManager.setGrantDelay.selector,
            IAccessManager.setTargetFunctionRole.selector,
            IAccessManager.setTargetAdminDelay.selector,
            IAccessManager.setTargetClosed.selector,
            IAccessManager.updateAuthority.selector,
            IAccessManager.schedule.selector,
            IAccessManager.execute.selector,
            IAccessManager.cancel.selector,
            Multicall.multicall.selector,
            IAccessManaged.setAuthority.selector
        ];
        for (uint256 i; i < selectors.length; ++i) {
            _expectWiringRevert(
                _oneCall(_call(address(wired), abi.encodePacked(selectors[i], bytes32(0)))),
                abi.encodeWithSelector(
                    GovernanceConfig.WiringSelectorNotAllowed.selector, address(wired), selectors[i]
                )
            );
        }
    }

    function test_RejectsWiringOnAnUnconfiguredTarget() public {
        WiringTargetPortedMock stranger = new WiringTargetPortedMock(address(manager));
        bytes memory data = abi.encodeCall(WiringTargetPortedMock.bindStream, (address(peerA)));
        _expectWiringRevert(
            _oneCall(_call(address(stranger), data)),
            abi.encodeWithSelector(
                GovernanceConfig.InvalidWiringCall.selector, address(stranger), bytes4(data)
            )
        );
    }

    function test_RejectsWiringWithoutASelector() public {
        _expectWiringRevert(
            _oneCall(_call(address(wired), hex"010203")),
            abi.encodeWithSelector(
                GovernanceConfig.InvalidWiringCall.selector, address(wired), bytes4(0)
            )
        );
    }

    /// @dev A wiring call of exactly four bytes carries its selector and is validated by it.
    function test_AFourByteWiringCallIsValidatedByItsSelector() public {
        WiringValidationPortedHarness harness = new WiringValidationPortedHarness();
        GovernanceConfig.Config memory cfg = _wiredConfig();
        bytes4 genesis = IPackageRegistry.bindStream.selector;
        harness.validateWiring(cfg, _oneCall(_call(address(wired), abi.encodePacked(genesis))));
        bytes4 other = IPackageRegistry.setVerifier.selector;
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceConfig.WiringSelectorNotAllowed.selector, address(wired), other
            )
        );
        harness.validateWiring(cfg, _oneCall(_call(address(wired), abi.encodePacked(other))));
    }

    /// @dev The bound is exact: 64 calls pass validation, 65 are refused by count.
    function test_RejectsMoreThanTheWiringBound() public {
        uint256 max = GovernanceConfig.MAX_WIRING_CALLS;
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](max + 1);
        for (uint256 i; i < wiring.length; ++i) {
            wiring[i] = _call(
                address(wired),
                abi.encodeCall(WiringTargetPortedMock.setTarget, (address(peerA), true))
            );
        }
        _expectWiringRevert(
            wiring, abi.encodeWithSelector(GovernanceConfig.TooManyWiringCalls.selector, max + 1)
        );
        GovernanceConfig.Call[] memory exact = new GovernanceConfig.Call[](max);
        for (uint256 i; i < max; ++i) {
            exact[i] = wiring[i];
        }
        new WiringValidationPortedHarness().validateWiring(_wiredConfig(), exact);
    }

    function test_OnlyTheDeployerCanWire() public {
        GovernanceConfig.Config memory cfg = _wiredConfig();
        GovernanceConfig.Call[] memory wiring = _genesisCalls();
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfigurator.NotDeployer.selector, attacker)
        );
        vm.prank(attacker);
        configurator.configure(cfg, MANIFEST, wiring);
    }

    /// @dev Wiring calls reach only targets validated as governed by the configurator's own
    ///      manager: one governed by a stock manager is refused.
    function test_StockManagerTargetCannotBeWired() public {
        AccessManager stock = new AccessManager(address(this));
        GovernedTargetMock foreign = new GovernedTargetMock(address(stock), recipient0, verifier0);
        bytes memory data = abi.encodeCall(WiringTargetPortedMock.setTarget, (address(peerA), true));
        _expectWiringRevert(
            _oneCall(_call(address(foreign), data)),
            abi.encodeWithSelector(
                GovernanceConfig.InvalidWiringCall.selector, address(foreign), bytes4(data)
            )
        );
    }
}
