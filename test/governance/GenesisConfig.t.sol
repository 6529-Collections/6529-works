// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Roles } from "src/governance/Roles.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import {
    Erc165PeerMock,
    GenesisTargetMock,
    WiringTargetMock
} from "../mocks/GenesisWiringMocks.sol";

/// @notice Checks the committed genesis configuration, `config/genesis.example.json`, against
///         {Roles} and {GovernanceConfig}, installs it with its wiring on a fresh manager, reads
///         it back, and sizes the wiring bound against the EIP-7825 transaction gas cap.
contract GenesisConfigTest is Test {
    string internal constant PATH = "config/genesis.example.json";
    bytes32 internal constant MANIFEST = keccak256("6529 Works genesis manifest, example");
    /// @dev EIP-7825 (Fusaka): no transaction may carry more than 2^24 gas.
    uint256 internal constant TX_GAS_CAP = 1 << 24;

    string internal json;
    GovernanceConfigurator internal configurator;
    WorksAccessManager internal manager;

    function setUp() public {
        json = vm.readFile(PATH);
        configurator = new GovernanceConfigurator();
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
        for (uint256 i; i < _count(".contracts"); ++i) {
            string memory c = _at(".contracts", i);
            if (_eq(_str(string.concat(c, ".name")), name)) {
                return vm.parseJsonAddress(json, string.concat(c, ".address"));
            }
        }
        for (uint256 i; i < _count(".peers"); ++i) {
            string memory p = _at(".peers", i);
            if (_eq(_str(string.concat(p, ".name")), name)) {
                return vm.parseJsonAddress(json, string.concat(p, ".address"));
            }
        }
        revert(string.concat("unknown contract ", name));
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
        }
    }

    function test_EverySelectorMatchesItsSignatureAndClassDelay() public view {
        uint256 total;
        for (uint256 i; i < _count(".contracts"); ++i) {
            string memory c = _at(".contracts", i);
            string memory fnBase = string.concat(c, ".functions");
            for (uint256 j; j < _count(fnBase); ++j) {
                string memory f = _at(fnBase, j);
                string memory sig = _str(string.concat(f, ".signature"));
                assertEq(
                    _selector(string.concat(f, ".selector")), bytes4(keccak256(bytes(sig))), sig
                );
                uint64 role = _roleId(_str(string.concat(f, ".role")));
                uint256 delay = vm.parseJsonUint(json, string.concat(f, ".delay"));
                assertEq(delay, Roles.executionDelay(role), sig);
                assertEq(delay, _classDelay(_str(string.concat(f, ".class"))), sig);
                assertTrue(role != Roles.ADMIN && role != Roles.CURATION_SIGNER, sig);
                ++total;
            }
            // Genesis-only binds stay unmapped (ADMIN) and are wired once at genesis.
            string memory gBase = string.concat(c, ".genesisOnly");
            for (uint256 j; j < _count(gBase); ++j) {
                string memory g = _at(gBase, j);
                string memory sig = _str(string.concat(g, ".signature"));
                bytes4 sel = _selector(string.concat(g, ".selector"));
                assertEq(sel, bytes4(keccak256(bytes(sig))), sig);
                for (uint256 k; k < _count(fnBase); ++k) {
                    assertTrue(_selector(string.concat(_at(fnBase, k), ".selector")) != sel, sig);
                }
            }
        }
        assertGt(total, 0);
    }

    function test_WiringCalldataMatchesItsSignatureAndArguments() public view {
        for (uint256 i; i < _count(".wiring"); ++i) {
            string memory w = _at(".wiring", i);
            string memory sig = _str(string.concat(w, ".signature"));
            bytes memory data = vm.parseJsonBytes(json, string.concat(w, ".calldata"));
            assertEq(bytes4(data), bytes4(keccak256(bytes(sig))), sig);
            _addressOf(_str(string.concat(w, ".contract"))); // the target exists
            // The first argument names a contract or peer; it must be that placeholder.
            string memory peer = _str(string.concat(w, ".args[0]"));
            address encoded;
            assembly ("memory-safe") {
                encoded := mload(add(data, 36))
            }
            assertEq(encoded, _addressOf(peer), sig);
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
    ///      maximum number of wiring calls, each an ERC-165-checking bind to a cold peer that
    ///      writes a fresh slot, plus intrinsic and worst-case calldata gas, stays well under
    ///      the EIP-7825 cap.
    function test_MaximumWiringFitsTheTransactionGasCap() public {
        GovernanceConfig.Config memory genesis = _config();
        _etchTargets(genesis);
        GovernanceConfig.Call[] memory genesisWiring = _wiring();

        // One more target carries the extra binds.
        WiringTargetMock wired = new WiringTargetMock(address(manager));
        GovernanceConfig.Config memory cfg;
        cfg.grants = genesis.grants;
        cfg.targets = new GovernanceConfig.Target[](genesis.targets.length + 1);
        for (uint256 i; i < genesis.targets.length; ++i) {
            cfg.targets[i] = genesis.targets[i];
        }
        GovernanceConfig.FunctionRole[] memory fns = new GovernanceConfig.FunctionRole[](1);
        fns[0] =
            GovernanceConfig.FunctionRole(WiringTargetMock.bind.selector, Roles.SUCCESSOR_SETTER);
        cfg.targets[genesis.targets.length] = GovernanceConfig.Target(address(wired), fns);

        uint256 max = GovernanceConfig.MAX_WIRING_CALLS;
        GovernanceConfig.Call[] memory wiring = new GovernanceConfig.Call[](max);
        for (uint256 i; i < max; ++i) {
            wiring[i] = i < genesisWiring.length
                ? genesisWiring[i]
                : GovernanceConfig.Call(
                    address(wired),
                    abi.encodeCall(WiringTargetMock.bind, (i, address(new Erc165PeerMock())))
                );
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
