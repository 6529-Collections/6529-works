// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";

/// @notice Re-ported from the retired `GenesisConfig` suite: the committed genesis policy,
///         `config/genesis.core.example.json`, checked against {Roles}, the manager's own
///         functions and {GovernanceConfig}'s genesis allow-list. The compiled-selector and
///         role-matrix checks in both directions are `tools/check_genesis.py`; the install and
///         readback on the deployed stack are `GenesisPorted.t.sol` and `DeployCore.t.sol`.
contract GenesisConfigPortedTest is Test {
    string internal constant PATH = "config/genesis.core.example.json";

    string internal json;

    function setUp() public {
        json = vm.readFile(PATH);
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

    function _selector(string memory key) internal view returns (bytes4) {
        return bytes4(vm.parseJsonBytes(json, key));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _roleId(string memory name) internal pure returns (uint64) {
        for (uint64 id; id < Roles.COUNT; ++id) {
            if (id == Roles.ADMIN) {
                if (_eq(name, "ADMIN")) return id;
                continue;
            }
            if (Roles.isKnown(id) && _eq(name, Roles.label(id))) return id;
        }
        revert(string.concat("unknown role ", name));
    }

    function _classDelay(string memory class) internal pure returns (uint256) {
        if (_eq(class, "immediate")) return 0;
        if (_eq(class, "24h")) return 24 hours;
        if (_eq(class, "3d")) return 3 days;
        if (_eq(class, "7d")) return 7 days;
        revert(string.concat("unknown class ", class));
    }

    // ------------------------------------------------------------------ the role table

    /// @dev One entry per known role, each with its ID, delay, class, grant delay and whether
    ///      it is a network role exactly as {Roles} has them.
    function test_RoleTableMatchesRolesSol() public view {
        uint256 known;
        for (uint64 id; id < Roles.COUNT; ++id) {
            if (Roles.isKnown(id)) ++known;
        }
        uint256 n = _count(".roles");
        assertEq(n, known, "one entry per role");
        for (uint256 i; i < n; ++i) {
            string memory r = _at(".roles", i);
            string memory name = _str(string.concat(r, ".name"));
            uint64 id = _roleId(name);
            assertEq(vm.parseJsonUint(json, string.concat(r, ".id")), id, name);
            uint256 exec = vm.parseJsonUint(json, string.concat(r, ".executionDelay"));
            assertEq(exec, Roles.executionDelay(id), name);
            assertEq(exec, _classDelay(_str(string.concat(r, ".executionClass"))), name);
            assertEq(vm.parseJsonUint(json, string.concat(r, ".grantDelay")), 0, name);
            assertEq(
                vm.parseJsonBool(json, string.concat(r, ".network")), Roles.isNetworkRole(id), name
            );
        }
    }

    /// @dev The manager's own functions beyond its OpenZeppelin base, as the genesis file lists
    ///      them: the network's (7 days), the open ones and the views.
    function test_ManagerSectionMatchesWorksAccessManager() public view {
        bytes4[2] memory fns =
            [WorksAccessManager.transferNetwork.selector, WorksAccessManager.setBrake.selector];
        assertEq(_count(".manager.functions"), fns.length, "manager.functions");
        for (uint256 i; i < fns.length; ++i) {
            string memory f = _at(".manager.functions", i);
            string memory sig = _str(string.concat(f, ".signature"));
            assertEq(_selector(string.concat(f, ".selector")), fns[i], sig);
            assertEq(bytes4(keccak256(bytes(sig))), fns[i], sig);
            assertEq(_roleId(_str(string.concat(f, ".role"))), Roles.ADMIN);
            assertEq(vm.parseJsonUint(json, string.concat(f, ".delay")), 7 days);
        }
        bytes4[2] memory open =
            [WorksAccessManager.acceptNetwork.selector, WorksAccessManager.brakeOnce.selector];
        assertEq(_count(".manager.open"), open.length, "manager.open");
        for (uint256 i; i < open.length; ++i) {
            assertEq(_selector(string.concat(_at(".manager.open", i), ".selector")), open[i]);
        }
        bytes4[5] memory views = [
            bytes4(keccak256("network()")),
            bytes4(keccak256("pendingNetwork()")),
            bytes4(keccak256("brake()")),
            WorksAccessManager.notBefore.selector,
            WorksAccessManager.grantCount.selector
        ];
        assertEq(_count(".manager.views"), views.length, "manager.views");
        for (uint256 i; i < views.length; ++i) {
            string memory v = _at(".manager.views", i);
            assertEq(_selector(string.concat(v, ".selector")), views[i]);
            assertEq(bytes4(keccak256(bytes(_str(string.concat(v, ".signature"))))), views[i]);
        }
    }

    /// @dev Every listed selector is its signature's; every mapped function's delay is its
    ///      role's and its class's, and no function maps to ADMIN or CURATION_SIGNER; no
    ///      selector appears twice on one contract.
    function test_EveryEntryMatchesItsSignatureAndClassDelay() public view {
        uint256 mapped;
        for (uint256 i; i < _count(".contracts"); ++i) {
            string memory c = _at(".contracts", i);
            string[3] memory groups = [".functions", ".genesisOnly", ".deferred"];
            for (uint256 g; g < 3; ++g) {
                string memory base = string.concat(c, groups[g]);
                uint256 n = _count(base);
                for (uint256 j; j < n; ++j) {
                    string memory f = _at(base, j);
                    string memory sig = _str(string.concat(f, ".signature"));
                    bytes4 sel = _selector(string.concat(f, ".selector"));
                    assertEq(sel, bytes4(keccak256(bytes(sig))), sig);
                    for (uint256 k; k < j; ++k) {
                        assertTrue(
                            _selector(string.concat(_at(base, k), ".selector")) != sel,
                            string.concat("listed twice: ", sig)
                        );
                    }
                    if (g != 0) continue;
                    ++mapped;
                    uint64 role = _roleId(_str(string.concat(f, ".role")));
                    uint256 delay = vm.parseJsonUint(json, string.concat(f, ".delay"));
                    assertEq(delay, Roles.executionDelay(role), sig);
                    assertEq(delay, _classDelay(_str(string.concat(f, ".class"))), sig);
                    assertTrue(role != Roles.ADMIN && role != Roles.CURATION_SIGNER, sig);
                }
            }
        }
        assertGt(mapped, 0);
    }

    /// @dev Every wiring call names a genesis selector of the allow-list; every genesis-only
    ///      selector is wired on its own contract, and nothing deferred is.
    function test_WiringIsGenesisOnlyAndComplete() public view {
        uint256 wiring = _count(".wiring");
        assertGt(wiring, 0);
        for (uint256 i; i < wiring; ++i) {
            string memory sig = _str(string.concat(_at(".wiring", i), ".signature"));
            assertTrue(GovernanceConfig.isGenesisSelector(bytes4(keccak256(bytes(sig)))), sig);
        }
        assertLe(wiring, GovernanceConfig.MAX_WIRING_CALLS);
        for (uint256 i; i < _count(".contracts"); ++i) {
            string memory c = _at(".contracts", i);
            string memory name = _str(string.concat(c, ".name"));
            string[2] memory groups = [".genesisOnly", ".deferred"];
            for (uint256 g; g < 2; ++g) {
                string memory base = string.concat(c, groups[g]);
                for (uint256 j; j < _count(base); ++j) {
                    bytes4 sel = _selector(string.concat(_at(base, j), ".selector"));
                    bool wired;
                    for (uint256 k; k < wiring; ++k) {
                        string memory w = _at(".wiring", k);
                        if (
                            _eq(_str(string.concat(w, ".contract")), name)
                                && bytes4(keccak256(bytes(_str(string.concat(w, ".signature")))))
                                    == sel
                        ) wired = true;
                    }
                    assertEq(wired, g == 0, string.concat(name, groups[g]));
                }
            }
        }
    }

    /// @dev A wiring call's selector is never also mapped on the same contract to a class whose
    ///      holder could repeat it at once: genesis-only binds stay unmapped (ADMIN, 7 days).
    function test_GenesisOnlySelectorsAreNotMapped() public view {
        for (uint256 i; i < _count(".contracts"); ++i) {
            string memory c = _at(".contracts", i);
            string memory only = string.concat(c, ".genesisOnly");
            string memory fns = string.concat(c, ".functions");
            for (uint256 j; j < _count(only); ++j) {
                bytes4 sel = _selector(string.concat(_at(only, j), ".selector"));
                for (uint256 k; k < _count(fns); ++k) {
                    assertTrue(
                        _selector(string.concat(_at(fns, k), ".selector")) != sel,
                        _str(string.concat(_at(only, j), ".signature"))
                    );
                }
            }
        }
    }

    /// @dev The genesis holders are operational keys: none names a network role or ADMIN.
    function test_HoldersAreOperationalKeysOnly() public view {
        uint256 n = _count(".holders");
        assertGt(n, 0);
        for (uint256 i; i < n; ++i) {
            uint64 role = _roleId(_str(string.concat(_at(".holders", i), ".role")));
            assertFalse(Roles.isNetworkRole(role), "a holder names a network role");
            assertTrue(role != Roles.ADMIN);
        }
    }
}
