// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Multicall } from "@openzeppelin/contracts/utils/Multicall.sol";
import { Roles } from "src/governance/Roles.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStatementLog, Statement } from "src/interfaces/IStatementLog.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { HashRef, HASH_SHA256 } from "src/interfaces/types/HashRef.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { GovernanceFixture } from "../helpers/GovernanceFixture.sol";
import { GovernedTargetMock } from "../mocks/governance/GovernanceMocks.sol";
import {
    Erc165PeerMock,
    WiringTargetMock,
    WiringValidationHarness
} from "../mocks/governance/GenesisWiringMocks.sol";

/// @notice The genesis wiring phase: one-shot binds, admitted minters, sale targets and the
///         epoch-0 manifest, executed by the configurator as zero-delay ADMIN inside the
///         configuring transaction, and nothing else.
contract GenesisWiringTest is GovernanceFixture {
    WiringTargetMock internal wired;
    Erc165PeerMock internal peerA;
    Erc165PeerMock internal peerB;

    function setUp() public {
        _deployUnconfigured();
        wired = new WiringTargetMock(address(manager));
        peerA = new Erc165PeerMock();
        peerB = new Erc165PeerMock();
    }

    /// @dev The default config plus `wired`. Its binds stay unmapped (ADMIN), as in production;
    ///      admissions, targets and the verifier map to the 30-day class.
    function _wiredConfig() internal view returns (GovernanceConfig.Config memory cfg) {
        cfg = _config();
        GovernanceConfig.Target[] memory targets = new GovernanceConfig.Target[](2);
        targets[0] = cfg.targets[0];
        GovernanceConfig.FunctionRole[] memory fns = new GovernanceConfig.FunctionRole[](3);
        fns[0] = GovernanceConfig.FunctionRole(
            WiringTargetMock.setAdmittedMinter.selector, Roles.SUCCESSOR_SETTER
        );
        fns[1] = GovernanceConfig.FunctionRole(
            WiringTargetMock.setTarget.selector, Roles.SUCCESSOR_SETTER
        );
        fns[2] = GovernanceConfig.FunctionRole(
            WiringTargetMock.setVerifier.selector, Roles.SUCCESSOR_SETTER
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

    function _one(GovernanceConfig.Call memory c)
        internal
        pure
        returns (GovernanceConfig.Call[] memory wiring)
    {
        wiring = new GovernanceConfig.Call[](1);
        wiring[0] = c;
    }

    function _genesisCalls() internal view returns (GovernanceConfig.Call[] memory wiring) {
        wiring = new GovernanceConfig.Call[](4);
        wiring[0] = _call(
            address(wired), abi.encodeCall(WiringTargetMock.bindWorkRecords, (address(peerA)))
        );
        wiring[1] =
            _call(address(wired), abi.encodeCall(WiringTargetMock.bindEditions, (address(peerB))));
        wiring[2] = _call(
            address(wired),
            abi.encodeCall(WiringTargetMock.setAdmittedMinter, (address(peerA), true))
        );
        wiring[3] = _call(
            address(wired), abi.encodeCall(WiringTargetMock.setTarget, (address(peerB), true))
        );
    }

    function _expectWiringRevert(GovernanceConfig.Call[] memory wiring, bytes memory err) internal {
        GovernanceConfig.Config memory cfg = _wiredConfig();
        vm.expectRevert(err);
        configurator.configure(cfg, MANIFEST, wiring);
    }

    function _assertUntouched() internal view {
        assertEq(wired.workRecords(), address(0));
        assertEq(manager.getRoleGuardian(Roles.PAUSER), Roles.ADMIN, "no role setup");
        (bool stillAdmin,) = manager.hasRole(Roles.ADMIN, address(configurator));
        assertTrue(stillAdmin, "the configurator still holds ADMIN and can retry");
        (uint48 since,,,) = manager.getAccess(Roles.ADMIN, adminSafe);
        assertEq(since, 0, "no grants");
    }

    // ------------------------------------------------------------------ the allow-list

    function test_MaxWiringCallsIsPinned() public pure {
        assertEq(GovernanceConfig.MAX_WIRING_CALLS, 64);
    }

    function test_GenesisSelectorsAreExactlyTheAllowList() public pure {
        bytes4[11] memory allowed = [
            IStream.bindWorkRecords.selector,
            IStream.bindEditions.selector,
            IPackageRegistry.bindStream.selector,
            IArtistRegistry.bindPackageRegistry.selector,
            IArtistRegistry.bindSplitFactory.selector,
            IArtistRegistry.bindFederationRegistry.selector,
            IArtistRegistry.bindStatementLog.selector,
            IMintTarget.setAdmittedMinter.selector,
            ISaleAdapter.setTarget.selector,
            IAssetAllowlist.setDefaultCurrency.selector,
            IStatementLog.appendGovernanceManifest.selector
        ];
        for (uint256 i; i < allowed.length; ++i) {
            assertTrue(GovernanceConfig.isGenesisSelector(allowed[i]));
        }
        // The same selectors on the other contracts that declare them.
        assertEq(IPackageRegistry.bindEditions.selector, IStream.bindEditions.selector);
        assertEq(IArtistRegistry.bindStream.selector, IPackageRegistry.bindStream.selector);
        assertFalse(GovernanceConfig.isGenesisSelector(IPackageRegistry.setVerifier.selector));
        assertFalse(GovernanceConfig.isGenesisSelector(IStream.setDefaultRenderer.selector));
        assertFalse(GovernanceConfig.isGenesisSelector(bytes4(0)));
    }

    function testFuzz_OnlyGenesisSelectorsPassValidation(bytes4 selector) public {
        WiringValidationHarness harness = new WiringValidationHarness();
        GovernanceConfig.Config memory cfg = _wiredConfig();
        GovernanceConfig.Call[] memory wiring =
            _one(_call(address(wired), abi.encodePacked(selector, bytes32(0))));
        if (!GovernanceConfig.isGenesisSelector(selector)) {
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
        emit WiringTargetMock.Bound(WiringTargetMock.bindWorkRecords.selector, address(peerA));
        vm.expectEmit(address(configurator));
        emit GovernanceConfigurator.GovernanceConfigured(
            address(manager), keccak256(abi.encode(cfg)), MANIFEST, keccak256(abi.encode(wiring))
        );
        configurator.configure(cfg, MANIFEST, wiring);
        assertEq(wired.workRecords(), address(peerA));
        assertEq(wired.editions(), address(peerB));
        assertTrue(wired.isAdmittedMinter(address(peerA)));
        assertTrue(wired.isTarget(address(peerB)));

        _settle();
        configurator.verify(cfg);
    }

    function test_WiringRunsBeforeSelectorsAreMapped() public {
        // `setAdmittedMinter` maps to SUCCESSOR_SETTER, which the configurator never holds,
        // yet the wiring call succeeds: it runs while every selector resolves to zero-delay ADMIN.
        configurator.configure(_wiredConfig(), MANIFEST, _genesisCalls());
        assertEq(
            manager.getTargetFunctionRole(
                address(wired), WiringTargetMock.setAdmittedMinter.selector
            ),
            Roles.SUCCESSOR_SETTER
        );
        (uint48 since,,,) = manager.getAccess(Roles.SUCCESSOR_SETTER, address(configurator));
        assertEq(since, 0);

        // After genesis the same calls are 30-day, guardian-vetoable operations.
        bytes4[2] memory selectors = [
            WiringTargetMock.setAdmittedMinter.selector, WiringTargetMock.bindWorkRecords.selector
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool immediate, uint32 delay) =
                manager.canCall(adminSafe, address(wired), selectors[i]);
            assertFalse(immediate);
            assertEq(delay, 30 days);
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManaged.AccessManagedUnauthorized.selector, address(configurator)
            )
        );
        vm.prank(address(configurator));
        wired.setAdmittedMinter(address(peerB), true);
    }

    function test_ConfiguratorEndsWithNoRoleAfterWiring() public {
        configurator.configure(_wiredConfig(), MANIFEST, _genesisCalls());
        for (uint64 role; role < Roles.COUNT; ++role) {
            assertFalse(GovernanceConfig.hasRecord(manager, role, address(configurator)));
        }
    }

    function test_EmptyWiringIsAllowed() public {
        configurator.configure(_wiredConfig(), MANIFEST, _noWiring());
        assertEq(wired.workRecords(), address(0));
    }

    function test_EpochZeroManifestIsWrittenAtGenesis() public {
        // The real statement log: the manifest history starts with the genesis epoch.
        StatementLog log = new StatementLog(address(manager), address(0), bytes32(0));
        GovernanceConfig.Config memory cfg = _wiredConfig();
        GovernanceConfig.Target[] memory targets = new GovernanceConfig.Target[](3);
        (targets[0], targets[1]) = (cfg.targets[0], cfg.targets[1]);
        GovernanceConfig.FunctionRole[] memory fns = new GovernanceConfig.FunctionRole[](4);
        fns[0] = GovernanceConfig.FunctionRole(
            StatementLog.appendGovernanceManifest.selector, Roles.SUCCESSOR_SETTER
        );
        fns[1] = GovernanceConfig.FunctionRole(StatementLog.appendCurator.selector, Roles.CURATOR);
        fns[2] = GovernanceConfig.FunctionRole(StatementLog.appendPlatform.selector, Roles.PLATFORM);
        fns[3] = GovernanceConfig.FunctionRole(
            StatementLog.setArtistResolver.selector, Roles.SUCCESSOR_SETTER
        );
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
        GovernanceConfig.Call[] memory wiring = _one(
            _call(address(log), abi.encodeCall(StatementLog.appendGovernanceManifest, (manifest)))
        );
        configurator.configure(cfg, MANIFEST, wiring);

        (uint64 count, bytes32 head) = log.chainOf(address(manager), 0);
        assertEq(count, 1, "epoch-0 manifest recorded");
        assertTrue(head != bytes32(0));
        // Later epochs go through the 30-day class.
        (bool immediate, uint32 delay) =
            manager.canCall(adminSafe, address(log), StatementLog.appendGovernanceManifest.selector);
        assertFalse(immediate);
        assertEq(delay, 30 days);
    }

    // ------------------------------------------------------------------ failures abort all

    function test_RevertingWiringCallAbortsTheWholeConfiguration() public {
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](2);
        wiring[0] = _call(
            address(wired), abi.encodeCall(WiringTargetMock.bindWorkRecords, (address(peerA)))
        );
        wiring[1] = _call(
            address(wired), abi.encodeCall(WiringTargetMock.bindPackageRegistry, (address(peerB)))
        );
        _expectWiringRevert(wiring, abi.encodeWithSelector(WiringTargetMock.Refused.selector));
        _assertUntouched();
    }

    function test_SilentWiringRevertIsNamedByIndex() public {
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](2);
        wiring[0] = _call(
            address(wired), abi.encodeCall(WiringTargetMock.bindWorkRecords, (address(peerA)))
        );
        wiring[1] = _call(
            address(wired), abi.encodeCall(WiringTargetMock.bindSplitFactory, (address(peerB)))
        );
        _expectWiringRevert(
            wiring, abi.encodeWithSelector(GovernanceConfig.WiringCallFailed.selector, 1)
        );
        _assertUntouched();
    }

    function test_RepeatedOneShotBindAbortsTheWholeConfiguration() public {
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](2);
        wiring[0] = _call(
            address(wired), abi.encodeCall(WiringTargetMock.bindWorkRecords, (address(peerA)))
        );
        wiring[1] = _call(
            address(wired), abi.encodeCall(WiringTargetMock.bindWorkRecords, (address(peerB)))
        );
        _expectWiringRevert(
            wiring,
            abi.encodeWithSelector(
                WiringTargetMock.AlreadyBound.selector, WiringTargetMock.bindWorkRecords.selector
            )
        );
        _assertUntouched();
    }

    // ------------------------------------------------------------------ rejected wiring

    /// Regression for the PR #25 review: wiring once reached any target selector, so a 30-day
    /// verifier swap or recipient change could run at zero delay. Only genesis selectors pass.
    function test_RejectsZeroDelaySwapsThroughWiring() public {
        bytes[2] memory onTarget = [
            abi.encodeCall(GovernedTargetMock.setVerifier, (verifier0, attacker)),
            abi.encodeCall(GovernedTargetMock.setRecipient, (recipient0, attacker))
        ];
        for (uint256 i; i < onTarget.length; ++i) {
            _expectWiringRevert(
                _one(_call(address(target), onTarget[i])),
                abi.encodeWithSelector(
                    GovernanceConfig.WiringSelectorNotAllowed.selector,
                    address(target),
                    bytes4(onTarget[i])
                )
            );
        }
        _expectWiringRevert(
            _one(_call(address(wired), abi.encodeCall(WiringTargetMock.setVerifier, (attacker)))),
            abi.encodeWithSelector(
                GovernanceConfig.WiringSelectorNotAllowed.selector,
                address(wired),
                WiringTargetMock.setVerifier.selector
            )
        );
        assertEq(target.verifier(), verifier0);
    }

    /// Regression for the PR #25 review: the old deny-list missed the manager's `multicall`.
    /// Even if the manager were admitted as a target, the allow-list rejects it.
    function test_AllowListRejectsManagerCallsEvenIfTheManagerWereATarget() public {
        WiringValidationHarness harness = new WiringValidationHarness();
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
            harness.validateWiring(cfg, _one(_call(address(manager), calls[i])));
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
                _one(_call(address(manager), calls[i])),
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
                _one(_call(address(wired), abi.encodePacked(selectors[i], bytes32(0)))),
                abi.encodeWithSelector(
                    GovernanceConfig.WiringSelectorNotAllowed.selector, address(wired), selectors[i]
                )
            );
        }
    }

    function test_RejectsWiringOnAnUnconfiguredTarget() public {
        WiringTargetMock stranger = new WiringTargetMock(address(manager));
        bytes memory data = abi.encodeCall(WiringTargetMock.bindWorkRecords, (address(peerA)));
        _expectWiringRevert(
            _one(_call(address(stranger), data)),
            abi.encodeWithSelector(
                GovernanceConfig.InvalidWiringCall.selector, address(stranger), bytes4(data)
            )
        );
    }

    function test_RejectsWiringWithoutASelector() public {
        _expectWiringRevert(
            _one(_call(address(wired), hex"0102")),
            abi.encodeWithSelector(
                GovernanceConfig.InvalidWiringCall.selector, address(wired), bytes4(0)
            )
        );
    }

    function test_RejectsMoreThanTheWiringBound() public {
        uint256 count = GovernanceConfig.MAX_WIRING_CALLS + 1;
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](count);
        for (uint256 i; i < count; ++i) {
            wiring[i] = _call(
                address(wired), abi.encodeCall(WiringTargetMock.setTarget, (address(peerA), true))
            );
        }
        _expectWiringRevert(
            wiring, abi.encodeWithSelector(GovernanceConfig.TooManyWiringCalls.selector, count)
        );
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

    function test_StockManagerTargetCannotBeWired() public {
        // Wiring calls only reach targets validated as governed by the configurator's manager.
        AccessManager stock = new AccessManager(address(this));
        GovernedTargetMock foreign = new GovernedTargetMock(address(stock), recipient0, verifier0);
        bytes memory data = abi.encodeCall(WiringTargetMock.setTarget, (address(peerA), true));
        _expectWiringRevert(
            _one(_call(address(foreign), data)),
            abi.encodeWithSelector(
                GovernanceConfig.InvalidWiringCall.selector, address(foreign), bytes4(data)
            )
        );
    }
}
