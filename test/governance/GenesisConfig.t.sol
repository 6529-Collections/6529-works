// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Eip712CurationVerifier } from "src/curation/Eip712CurationVerifier.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { DependencyRegistry } from "src/content/DependencyRegistry.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { EconomicsResolver } from "src/economics/EconomicsResolver.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { Roles } from "src/governance/Roles.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import {
    Erc165PeerMock,
    GenesisTargetMock,
    WiringTargetMock
} from "../mocks/governance/GenesisWiringMocks.sol";

/// @notice Checks the committed genesis configuration, `config/genesis.example.json`, against
///         the compiled selectors, {Roles} and {GovernanceConfig}; installs it with its wiring
///         on a fresh manager and reads it back; and sizes the wiring bound against the
///         EIP-7825 transaction gas cap.
contract GenesisConfigTest is Test {
    string internal constant PATH = "config/genesis.example.json";
    bytes32 internal constant MANIFEST = keccak256("6529 Works genesis manifest, example");
    /// @dev EIP-7825 (Fusaka): no transaction may carry more than 2^24 gas.
    uint256 internal constant TX_GAS_CAP = 1 << 24;
    /// @dev `IEnglishAuction.pause(uint256,bytes32)`. It overloads `ISaleAdapter.pause()`, so
    ///      Solidity cannot name it by member access; tools/check_genesis.py checks it against
    ///      the compiled artifact.
    bytes4 internal constant DISPUTE_PAUSE = bytes4(keccak256("pause(uint256,bytes32)"));

    string internal json;
    GovernanceConfigurator internal configurator;
    WorksAccessManager internal manager;

    function setUp() public {
        json = vm.readFile(PATH);
        configurator = new GovernanceConfigurator(address(this));
        manager = configurator.worksManager();
    }

    // ------------------------------------------------------------------ JSON helpers

    function _at(string memory base, uint256 i) internal pure returns (string memory) {
        return string.concat(base, "[", vm.toString(i), "]");
    }

    function _count(string memory base) internal view returns (uint256 n) {
        while (vm.keyExistsJson(json, _at(base, n))) ++n;
    }

    function _str(string memory key) internal view returns (string memory) {
        return vm.parseJsonString(json, key);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _roleId(string memory name) internal pure returns (uint64) {
        if (_eq(name, "ADMIN")) return Roles.ADMIN;
        for (uint64 role = 1; role < Roles.COUNT; ++role) {
            if (_eq(name, Roles.label(role))) return role;
        }
        revert(string.concat("unknown role ", name));
    }

    function _classDelay(string memory class) internal pure returns (uint32) {
        if (_eq(class, "immediate")) return Roles.IMMEDIATE;
        if (_eq(class, "standard")) return Roles.STANDARD;
        if (_eq(class, "funds")) return Roles.FUNDS;
        if (_eq(class, "successor")) return Roles.SUCCESSOR;
        revert(string.concat("unknown class ", class));
    }

    function _selector(string memory key) internal view returns (bytes4) {
        bytes memory raw = vm.parseJsonBytes(json, key);
        assertEq(raw.length, 4, key);
        return bytes4(raw);
    }

    /// @dev The address of a contract or peer named in the JSON.
    function _addressOf(string memory name) internal view returns (address) {
        string[2] memory lists = [".contracts", ".peers"];
        for (uint256 l; l < 2; ++l) {
            for (uint256 i; i < _count(lists[l]); ++i) {
                string memory c = _at(lists[l], i);
                if (_eq(_str(string.concat(c, ".name")), name)) {
                    return vm.parseJsonAddress(json, string.concat(c, ".address"));
                }
            }
        }
        revert(string.concat("unknown contract ", name));
    }

    /// @dev Every selector a contract lists: mapped, genesis-only and deferred.
    function _listed(string memory c) internal view returns (bytes4[] memory all) {
        string[3] memory groups = [".functions", ".genesisOnly", ".deferred"];
        uint256 n;
        for (uint256 g; g < 3; ++g) {
            n += _count(string.concat(c, groups[g]));
        }
        all = new bytes4[](n);
        uint256 k;
        for (uint256 g; g < 3; ++g) {
            string memory base = string.concat(c, groups[g]);
            for (uint256 j; j < _count(base); ++j) {
                all[k++] = _selector(string.concat(_at(base, j), ".selector"));
            }
        }
    }

    // ------------------------------------------------------------------ compiled selectors

    function _s9(bytes4[9] memory xs) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](9);
        for (uint256 i; i < 9; ++i) {
            out[i] = xs[i];
        }
    }

    function _s(bytes4[7] memory xs, uint256 n) internal pure returns (bytes4[] memory out) {
        require(n <= xs.length, "_s: n exceeds the listed selectors");
        out = new bytes4[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = xs[i];
        }
    }

    /// @dev The compiled selectors each contract's entries must equal, as a set. A renamed or
    ///      re-typed function breaks compilation here before it can drift from the JSON.
    function _compiled(string memory name) internal pure returns (bytes4[] memory) {
        bytes4 z;
        if (_eq(name, "Stream")) {
            bytes4[] memory out = _s(
                [
                    IStream.createCollection.selector,
                    IStream.setContractURI.selector,
                    IStream.setOwner.selector,
                    IStream.setDefaultRenderer.selector,
                    IMintTarget.setAdmittedMinter.selector,
                    IStream.bindWorkRecords.selector,
                    IStream.bindEditions.selector
                ],
                7
            );
            bytes4[] memory all = new bytes4[](8);
            for (uint256 i; i < 7; ++i) {
                all[i] = out[i];
            }
            all[7] = IStream.releaseContent.selector;
            return all;
        }
        if (_eq(name, "WorkRecords")) {
            return _s(
                [
                    IWorkRecords.setPreferredKind.selector,
                    IWorkRecords.setCollectionPreferredKind.selector,
                    IWorkRecords.setFilePreference.selector,
                    IWorkRecords.addLocator.selector,
                    IWorkRecords.relicense.selector,
                    IWorkRecords.setRoyaltyRate.selector,
                    IWorkRecords.repinRenderer.selector
                ],
                7
            );
        }
        if (_eq(name, "Editions")) {
            return _s(
                [
                    IEditions.setContractURI.selector,
                    IEditions.setOwner.selector,
                    IMintTarget.setAdmittedMinter.selector,
                    IEditions.bindWorkRecords.selector,
                    z,
                    z,
                    z
                ],
                4
            );
        }
        if (_eq(name, "PackageRegistry")) {
            return _s(
                [
                    PackageRegistry.revokePackage.selector,
                    PackageRegistry.setVerifier.selector,
                    PackageRegistry.bindStream.selector,
                    PackageRegistry.bindEditions.selector,
                    z,
                    z,
                    z
                ],
                4
            );
        }
        if (_eq(name, "CurationVerifier")) {
            return _s(
                [
                    Eip712CurationVerifier.disableSigner.selector,
                    Eip712CurationVerifier.enableSigner.selector,
                    z,
                    z,
                    z,
                    z,
                    z
                ],
                2
            );
        }
        if (_eq(name, "ArtistRegistry")) {
            return _s9(
                [
                    IArtistRegistry.vetoChange.selector,
                    IArtistRegistry.stageOverride.selector,
                    IArtistRegistry.setConsolidationSource.selector,
                    IArtistRegistry.resolveContested.selector,
                    IArtistRegistry.bindPackageRegistry.selector,
                    IArtistRegistry.bindStream.selector,
                    IArtistRegistry.bindSplitFactory.selector,
                    IArtistRegistry.bindStatementLog.selector,
                    IArtistRegistry.bindFederationRegistry.selector
                ]
            );
        }
        if (_eq(name, "StatementLog")) {
            return _s(
                [
                    StatementLog.appendCurator.selector,
                    StatementLog.appendPlatform.selector,
                    StatementLog.appendGovernanceManifest.selector,
                    StatementLog.setArtistResolver.selector,
                    z,
                    z,
                    z
                ],
                4
            );
        }
        if (_eq(name, "EnglishAuction")) {
            bytes4[] memory out = _s(
                [
                    ISaleAdapter.pause.selector,
                    ISaleAdapter.unpause.selector,
                    IEnglishAuction.resume.selector,
                    IEnglishAuction.cancel.selector,
                    IEnglishAuction.setConfig.selector,
                    IEnglishAuction.setOpeningBid.selector,
                    ISaleAdapter.setTarget.selector
                ],
                7
            );
            bytes4[] memory all = new bytes4[](9);
            for (uint256 i; i < 7; ++i) {
                all[i] = out[i];
            }
            (all[7], all[8]) = (ISaleAdapter.setFederationRegistry.selector, DISPUTE_PAUSE);
            return all;
        }
        if (_eq(name, "UniformEditionAuction")) {
            return _s(
                [
                    ISaleAdapter.pause.selector,
                    ISaleAdapter.unpause.selector,
                    IUniformEditionAuction.setConfig.selector,
                    ISaleAdapter.setTarget.selector,
                    ISaleAdapter.setFederationRegistry.selector,
                    z,
                    z
                ],
                5
            );
        }
        if (_eq(name, "EconomicsResolver")) {
            return _s(
                [
                    EconomicsResolver.setFeeTerms.selector,
                    EconomicsResolver.setRoyaltyRate.selector,
                    EconomicsResolver.setDefaultLicense.selector,
                    EconomicsResolver.setMuseum.selector,
                    z,
                    z,
                    z
                ],
                4
            );
        }
        if (_eq(name, "AssetAllowlist")) {
            return _s(
                [
                    AssetAllowlist.admitAsset.selector,
                    AssetAllowlist.setDefaultCurrency.selector,
                    AssetAllowlist.setIncrementFloor.selector,
                    AssetAllowlist.deprecateAsset.selector,
                    z,
                    z,
                    z
                ],
                4
            );
        }
        if (_eq(name, "RevenueEscrow")) {
            return _s([RevenueEscrow.recover.selector, z, z, z, z, z, z], 1);
        }
        if (_eq(name, "DependencyRegistry")) {
            return _s(
                [
                    DependencyRegistry.register.selector,
                    DependencyRegistry.deprecate.selector,
                    z,
                    z,
                    z,
                    z,
                    z
                ],
                2
            );
        }
        if (_eq(name, "EntropyModule")) {
            return _s(
                [
                    VrfEntropyModule.setConfig.selector,
                    VrfEntropyModule.setCoordinator.selector,
                    VrfEntropyModule.lowerCallbackGasLimit.selector,
                    z,
                    z,
                    z,
                    z
                ],
                3
            );
        }
        revert(string.concat("no compiled selectors for ", name));
    }

    function _contains(bytes4[] memory xs, bytes4 x) internal pure returns (bool) {
        for (uint256 i; i < xs.length; ++i) {
            if (xs[i] == x) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ build from JSON

    function _config() internal view returns (GovernanceConfig.Config memory cfg) {
        uint256 holders = _count(".holders");
        cfg.grants = new GovernanceConfig.Grant[](holders);
        for (uint256 i; i < holders; ++i) {
            string memory h = _at(".holders", i);
            cfg.grants[i] = GovernanceConfig.Grant(
                _roleId(_str(string.concat(h, ".role"))),
                vm.parseJsonAddress(json, string.concat(h, ".account"))
            );
        }
        uint256 contracts = _count(".contracts");
        cfg.targets = new GovernanceConfig.Target[](contracts);
        for (uint256 i; i < contracts; ++i) {
            string memory c = _at(".contracts", i);
            string memory fnBase = string.concat(c, ".functions");
            uint256 n = _count(fnBase);
            GovernanceConfig.FunctionRole[] memory fns = new GovernanceConfig.FunctionRole[](n);
            for (uint256 j; j < n; ++j) {
                string memory f = _at(fnBase, j);
                fns[j] = GovernanceConfig.FunctionRole(
                    _selector(string.concat(f, ".selector")),
                    _roleId(_str(string.concat(f, ".role")))
                );
            }
            cfg.targets[i] = GovernanceConfig.Target(
                vm.parseJsonAddress(json, string.concat(c, ".address")), fns
            );
        }
    }

    function _wiring() internal view returns (GovernanceConfig.Call[] memory wiring) {
        uint256 n = _count(".wiring");
        wiring = new GovernanceConfig.Call[](n);
        for (uint256 i; i < n; ++i) {
            string memory w = _at(".wiring", i);
            wiring[i] = GovernanceConfig.Call(
                _addressOf(_str(string.concat(w, ".contract"))),
                vm.parseJsonBytes(json, string.concat(w, ".calldata"))
            );
        }
    }

    /// @dev Puts a `GenesisTargetMock` for this manager at every placeholder target address.
    function _etchTargets(GovernanceConfig.Config memory cfg) internal {
        GenesisTargetMock template = new GenesisTargetMock(address(manager));
        for (uint256 i; i < cfg.targets.length; ++i) {
            vm.etch(cfg.targets[i].target, address(template).code);
        }
    }

    // ------------------------------------------------------------------ the JSON itself

    function test_JsonMatchesTheCompiledSelectors() public view {
        uint256 total;
        for (uint256 i; i < _count(".contracts"); ++i) {
            string memory c = _at(".contracts", i);
            string memory name = _str(string.concat(c, ".name"));
            bytes4[] memory listed = _listed(c);
            bytes4[] memory compiled = _compiled(name);
            assertEq(listed.length, compiled.length, name);
            for (uint256 j; j < listed.length; ++j) {
                assertTrue(_contains(compiled, listed[j]), name);
                assertTrue(_contains(listed, compiled[j]), name);
            }
            total += listed.length;
        }
        assertEq(total, 66, "56 mapped, 9 genesis-only, 1 deferred");
    }

    function test_RoleTableMatchesRolesSol() public view {
        uint256 n = _count(".roles");
        assertEq(n, Roles.COUNT, "one entry per role");
        for (uint256 i; i < n; ++i) {
            string memory r = _at(".roles", i);
            string memory name = _str(string.concat(r, ".name"));
            uint64 id = _roleId(name);
            assertEq(vm.parseJsonUint(json, string.concat(r, ".id")), id, name);
            uint256 exec = vm.parseJsonUint(json, string.concat(r, ".executionDelay"));
            uint256 grant = vm.parseJsonUint(json, string.concat(r, ".grantDelay"));
            assertEq(exec, Roles.executionDelay(id), name);
            assertEq(grant, Roles.grantDelay(id), name);
            assertEq(exec, _classDelay(_str(string.concat(r, ".executionClass"))), name);
            assertEq(grant, _classDelay(_str(string.concat(r, ".grantClass"))), name);
            assertEq(
                vm.parseJsonBool(json, string.concat(r, ".suspendable")),
                Roles.isSuspendable(id),
                name
            );
        }
    }

    /// Regression: GOV-2 (docs/security/internal-review-2026-10.md)
    /// @dev The manager's own guardian function and view (GOV-2), beyond its OpenZeppelin base.
    function test_ManagerSectionMatchesWorksAccessManager() public view {
        assertEq(_count(".manager.functions"), 1, "suspend");
        assertEq(_str(".manager.functions[0].signature"), "suspend(uint64,address)");
        assertEq(_selector(".manager.functions[0].selector"), WorksAccessManager.suspend.selector);
        assertEq(_roleId(_str(".manager.functions[0].role")), Roles.GUARDIAN);
        assertEq(vm.parseJsonUint(json, ".manager.functions[0].delay"), Roles.IMMEDIATE);
        assertEq(_count(".manager.views"), 1, "isSuspended");
        assertEq(_selector(".manager.views[0].selector"), WorksAccessManager.isSuspended.selector);
    }

    function test_EveryEntryMatchesItsSignatureAndClassDelay() public view {
        for (uint256 i; i < _count(".contracts"); ++i) {
            string memory c = _at(".contracts", i);
            string[3] memory groups = [".functions", ".genesisOnly", ".deferred"];
            for (uint256 g; g < 3; ++g) {
                string memory base = string.concat(c, groups[g]);
                for (uint256 j; j < _count(base); ++j) {
                    string memory f = _at(base, j);
                    string memory sig = _str(string.concat(f, ".signature"));
                    assertEq(
                        _selector(string.concat(f, ".selector")), bytes4(keccak256(bytes(sig))), sig
                    );
                    if (g != 0) continue;
                    uint64 role = _roleId(_str(string.concat(f, ".role")));
                    uint256 delay = vm.parseJsonUint(json, string.concat(f, ".delay"));
                    assertEq(delay, Roles.executionDelay(role), sig);
                    assertEq(delay, _classDelay(_str(string.concat(f, ".class"))), sig);
                    assertTrue(role != Roles.ADMIN && role != Roles.CURATION_SIGNER, sig);
                }
            }
        }
    }

    function test_WiringIsGenesisOnlyAndComplete() public view {
        GovernanceConfig.Call[] memory wiring = _wiring();
        for (uint256 i; i < wiring.length; ++i) {
            string memory w = _at(".wiring", i);
            string memory sig = _str(string.concat(w, ".signature"));
            bytes4 sel = bytes4(wiring[i].data);
            assertEq(sel, bytes4(keccak256(bytes(sig))), sig);
            assertTrue(GovernanceConfig.isGenesisSelector(sel), sig);
            // When the call names its peer, the first argument is that placeholder address.
            if (_count(string.concat(w, ".args")) != 0) {
                bytes memory first = bytes(_str(string.concat(w, ".args[0]")));
                if (first.length >= 2 && first[0] == "0" && first[1] == "x") continue; // literal
                bytes memory data = wiring[i].data;
                address encoded;
                assembly ("memory-safe") {
                    encoded := mload(add(data, 36))
                }
                assertEq(encoded, _addressOf(string(first)), sig);
            }
        }
        // Every genesis-only bind is wired; nothing deferred is.
        for (uint256 i; i < _count(".contracts"); ++i) {
            string memory c = _at(".contracts", i);
            address location = vm.parseJsonAddress(json, string.concat(c, ".address"));
            string[2] memory groups = [".genesisOnly", ".deferred"];
            for (uint256 g; g < 2; ++g) {
                string memory base = string.concat(c, groups[g]);
                for (uint256 j; j < _count(base); ++j) {
                    bytes4 sel = _selector(string.concat(_at(base, j), ".selector"));
                    bool wired;
                    for (uint256 k; k < wiring.length; ++k) {
                        if (wiring[k].target == location && bytes4(wiring[k].data) == sel) {
                            wired = true;
                        }
                    }
                    assertEq(wired, g == 0, string.concat(c, groups[g]));
                }
            }
        }
    }

    function test_GuardiansHoldOnlyGuardianAndPauser() public view {
        GovernanceConfig.Grant[] memory grants = _config().grants;
        uint256 guardians;
        for (uint256 i; i < grants.length; ++i) {
            if (grants[i].role != Roles.GUARDIAN) continue;
            ++guardians;
            for (uint256 j; j < grants.length; ++j) {
                if (grants[j].account != grants[i].account) continue;
                assertTrue(
                    grants[j].role == Roles.GUARDIAN || grants[j].role == Roles.PAUSER,
                    "guardian holds another role"
                );
            }
        }
        assertGe(guardians, 3, "deploy default: three guardians");
    }

    // ------------------------------------------------------------------ install it

    function test_GenesisConfigurationInstallsWiresAndReadsBack() public {
        GovernanceConfig.Config memory cfg = _config();
        GovernanceConfig.Call[] memory wiring = _wiring();
        _etchTargets(cfg);
        configurator.configure(cfg, MANIFEST, wiring);

        for (uint256 i; i < wiring.length; ++i) {
            assertTrue(
                GenesisTargetMock(payable(wiring[i].target)).called(keccak256(wiring[i].data)),
                "wiring call not executed"
            );
        }
        for (uint64 role; role < Roles.COUNT; ++role) {
            assertFalse(GovernanceConfig.hasRecord(manager, role, address(configurator)));
        }
        vm.warp(block.timestamp + manager.minSetback());
        configurator.verify(cfg); // validation rules and every class delay, read back
    }

    /// @dev Sizes {GovernanceConfig.MAX_WIRING_CALLS}: the genesis configuration with the
    ///      maximum number of wiring calls, each an admitted-minter grant that ERC-165-checks a
    ///      fresh peer and writes a fresh slot, with every account cooled first so no access is
    ///      cheaper than in a real transaction, plus intrinsic and worst-case calldata gas.
    function test_MaximumWiringFitsTheTransactionGasCap() public {
        GovernanceConfig.Config memory genesis = _config();
        _etchTargets(genesis);
        GovernanceConfig.Call[] memory genesisWiring = _wiring();

        WiringTargetMock wired = new WiringTargetMock(address(manager));
        GovernanceConfig.Config memory cfg;
        cfg.grants = genesis.grants;
        cfg.targets = new GovernanceConfig.Target[](genesis.targets.length + 1);
        for (uint256 i; i < genesis.targets.length; ++i) {
            cfg.targets[i] = genesis.targets[i];
        }
        GovernanceConfig.FunctionRole[] memory fns = new GovernanceConfig.FunctionRole[](1);
        fns[0] = GovernanceConfig.FunctionRole(
            WiringTargetMock.setAdmittedMinter.selector, Roles.SUCCESSOR_SETTER
        );
        cfg.targets[genesis.targets.length] = GovernanceConfig.Target(address(wired), fns);

        uint256 max = GovernanceConfig.MAX_WIRING_CALLS;
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](max);
        for (uint256 i; i < max; ++i) {
            if (i < genesisWiring.length) {
                wiring[i] = genesisWiring[i];
                continue;
            }
            Erc165PeerMock peer = new Erc165PeerMock();
            vm.cool(address(peer));
            wiring[i] = GovernanceConfig.Call(
                address(wired),
                abi.encodeCall(WiringTargetMock.setAdmittedMinter, (address(peer), true))
            );
        }
        vm.cool(address(configurator));
        vm.cool(address(manager));
        vm.cool(address(wired));
        for (uint256 i; i < genesis.targets.length; ++i) {
            vm.cool(genesis.targets[i].target);
        }

        uint256 calldataBytes = 4 + abi.encode(cfg, MANIFEST, wiring).length;
        uint256 before = gasleft();
        configurator.configure(cfg, MANIFEST, wiring);
        uint256 execution = before - gasleft();
        // Intrinsic 21,000 plus 40 gas per calldata byte bounds both the standard calldata
        // price and the EIP-7623 floor.
        uint256 total = 21_000 + 40 * calldataBytes + execution;
        emit log_named_uint("genesis + max wiring: execution gas", execution);
        emit log_named_uint("genesis + max wiring: calldata bytes", calldataBytes);
        emit log_named_uint("genesis + max wiring: worst-case transaction gas", total);
        assertLt(total, TX_GAS_CAP * 60 / 100, "keep 40% headroom under the EIP-7825 cap");
    }
}
