// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { DeployCore } from "script/DeployCore.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { IFederatedMembership } from "src/interfaces/IFederatedMembership.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { WorkRules } from "src/records/WorkRules.sol";
import { WorkDelivery } from "src/stream/WorkDelivery.sol";
import { FederatedIntegrationBase } from "../integration/FederatedIntegrationBase.sol";

/// @notice Every restricted function of every deployed contract is in the genesis role map, and
///         the map names no function that does not exist. Replaces the deploy script's former
///         `checkNothingDropped` guard, on the real deployed stack (with the entropy module).
/// @dev The restricted functions are derived from the deployed code, not from a hand-written
///      list: every 3- and 4-byte constant the runtime code pushes is a candidate selector
///      (the dispatcher pushes every external selector), and each candidate is called by an
///      account with no role, with zeroed arguments, in a state snapshot that is rolled back.
///      A call that answers `AccessManagedUnauthorized(caller)` reached a restricted function.
///      The federated tokens' network functions are found the same way (`NotNetwork(caller)`);
///      they are authorized through the same selector on `Directory`.
///      Functions whose access check depends on their arguments (a check that zeroed arguments
///      never reach) are named in `_conditional`.
contract RoleMapCompleteTest is FederatedIntegrationBase {
    /// @dev Gas for one probe call: enough to reach any access check.
    uint256 internal constant PROBE_GAS = 3_000_000;
    /// @dev Zeroed argument words sent with each probe (dynamic offsets of zero decode as empty).
    uint256 internal constant PROBE_WORDS = 24;

    address internal prober = makeAddr("roleMapProber");

    function _withVrf() internal pure override returns (bool) {
        return true;
    }

    // ------------------------------------------------------------------ tests

    function test_RoleMap_EveryGovernedContractIsATarget() public view {
        GovernanceConfig.Config memory cfg = _genesisConfig();
        string[] memory names = DeployCore.order(params);
        uint256 governed;
        for (uint256 i; i < names.length; ++i) {
            address a = DeployCore.addressOf(deployment, names[i]);
            if (_authorityOf(a) != address(manager)) continue;
            ++governed;
            assertTrue(_isTarget(cfg, a), string.concat(names[i], " is governed but not mapped"));
        }
        assertEq(governed, cfg.targets.length, "every target is a governed deployed contract");
        assertEq(_authorityOf(address(entropy)), address(manager), "the entropy module is deployed");
    }

    function test_RoleMap_EveryRestrictedFunctionIsMapped() public {
        this.check_EveryRestrictedFunctionIsMapped();
    }

    function test_RoleMap_NothingIsMappedThatDoesNotExist() public {
        GovernanceConfig.Config memory cfg = _genesisConfig();
        bytes4[] memory viaDirectory = _federatedNetworkSelectors();
        uint256 checked;
        uint256 missing;
        for (uint256 i; i < cfg.targets.length; ++i) {
            address target = cfg.targets[i].target;
            bytes4[] memory found = _restrictedSelectors(target);
            GovernanceConfig.FunctionRole[] memory fns = cfg.targets[i].functions;
            for (uint256 j; j < fns.length; ++j) {
                bytes4 sel = fns[j].selector;
                bool exists = _has(found, sel) || _conditional(target, sel)
                    || (target == address(directory) && _has(viaDirectory, sel));
                if (!exists) {
                    emit log_named_string(_nameOf(target), _hex(sel));
                    ++missing;
                }
                ++checked;
            }
        }
        assertEq(missing, 0, "mapped selectors that are not restricted functions");
        assertGt(checked, 100, "the whole map was read");
    }

    function test_RoleMap_EveryFederatedNetworkFunctionIsTheDirectorysAtOnce() public {
        bytes4[] memory sels = _federatedNetworkSelectors();
        bytes4[5] memory expected = [
            IStream.rescue.selector,
            IStream.setRescueDelay.selector,
            IModuleSlots.setModuleDelay.selector,
            IEditions.rebind.selector,
            IEditions.setRebindDelay.selector
        ];
        assertEq(sels.length, expected.length, "exactly the five network functions");
        for (uint256 i; i < expected.length; ++i) {
            assertTrue(_has(sels, expected[i]), _hex(expected[i]));
        }
        for (uint256 i; i < sels.length; ++i) {
            assertEq(manager.getTargetFunctionRole(address(directory), sels[i]), Roles.NETWORK);
            (bool immediate,) = manager.canCall(network, address(directory), sels[i]);
            assertTrue(immediate, "a federated token admits only an immediate role");
        }
    }

    /// @notice The guard fails when a restricted function falls out of the map: the network
    ///         remaps one back to ADMIN (the unmapped default) and the check no longer passes.
    function test_RoleMap_AnUnmappedRestrictedFunctionFailsTheCheck() public {
        bytes4[] memory one = new bytes4[](1);
        one[0] = IModuleSlots.setModuleDelay.selector;
        _govern(
            network,
            address(manager),
            abi.encodeCall(
                IAccessManager.setTargetFunctionRole, (address(stream), one, Roles.ADMIN)
            )
        );
        (bool ok, bytes memory ret) =
            address(this).call(abi.encodeCall(this.check_EveryRestrictedFunctionIsMapped, ()));
        assertFalse(ok, "the guard catches the unmapped function");
        assertTrue(
            _contains(
                string(ret), string.concat("Stream restricts an unmapped selector: ", _hex(one[0]))
            ),
            "for that reason"
        );
    }

    /// @notice Every function the probe finds restricted on a governed target maps to a role
    ///         other than ADMIN, except the one-shot genesis bind.
    function check_EveryRestrictedFunctionIsMapped() external {
        GovernanceConfig.Config memory cfg = _genesisConfig();
        uint256 found;
        for (uint256 i; i < cfg.targets.length; ++i) {
            address target = cfg.targets[i].target;
            bytes4[] memory sels = _restrictedSelectors(target);
            for (uint256 j; j < sels.length; ++j) {
                // AccessManaged's own `setAuthority` answers only the manager
                // (`updateAuthority`); it is not a role-mapped function.
                if (sels[j] == IAccessManaged.setAuthority.selector) continue;
                if (_intentionallyAdmin(target, sels[j])) continue;
                uint64 role = manager.getTargetFunctionRole(target, sels[j]);
                assertTrue(
                    role != Roles.ADMIN,
                    string.concat(
                        _nameOf(target), " restricts an unmapped selector: ", _hex(sels[j])
                    )
                );
                ++found;
            }
            assertGt(sels.length, 0, string.concat(_nameOf(target), ": no restricted function"));
        }
        assertGt(found, 100, "the probe reached the map");
    }

    // ------------------------------------------------------------------ exceptions

    /// @dev Restricted functions left at ADMIN on purpose: `bindStream` binds once, at genesis
    ///      (`GovernanceConfig.isGenesisSelector`).
    function _intentionallyAdmin(address target, bytes4 sel) internal view returns (bool) {
        return target == address(registry) && sel == IPackageRegistry.bindStream.selector;
    }

    /// @dev Mapped functions whose access check zeroed arguments never reach: `addLocator`
    ///      reads the work's media first and asks for the platform's role only when the caller
    ///      is not the artist of an unfinalized work; `renounce` asks for the network's role
    ///      only when a royalty or license power is newly renounced; `setFileStore` asks for the
    ///      storage operator's role only when the caller is not a wallet of the work's artist.
    function _conditional(address target, bytes4 sel) internal view returns (bool) {
        return (target == address(delivery) && sel == WorkDelivery.addLocator.selector)
            || (target == address(rules) && sel == WorkRules.renounce.selector)
            || (target == address(rules) && sel == WorkRules.setFileStore.selector);
    }

    // ------------------------------------------------------------------ probing

    /// @dev The selectors of `target` that answer `AccessManagedUnauthorized(prober)`.
    function _restrictedSelectors(address target) internal returns (bytes4[] memory) {
        return _probe(
            target,
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, prober)
        );
    }

    /// @dev The network functions of a federated pair (`NotNetwork(prober)`), deployed and
    ///      listed through the genesis templates.
    function _federatedNetworkSelectors() internal returns (bytes4[] memory all) {
        (FederatedStream fStream, FederatedEditions fEditions) = _listPair(_actor("roleMapArtist"));
        bytes memory reason =
            abi.encodeWithSelector(IFederatedMembership.NotNetwork.selector, prober);
        bytes4[] memory a = _probe(address(fStream), reason);
        bytes4[] memory b = _probe(address(fEditions), reason);
        all = new bytes4[](a.length + b.length);
        uint256 n;
        for (uint256 i; i < a.length; ++i) {
            all[n++] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            if (!_has(a, b[i])) all[n++] = b[i];
        }
        assembly ("memory-safe") {
            mstore(all, n)
        }
    }

    /// @dev Calls every candidate selector of `target` as `prober` and keeps those that revert
    ///      with exactly `reason`. Every call is rolled back.
    function _probe(address target, bytes memory reason) internal returns (bytes4[] memory hits) {
        bytes4[] memory candidates = _candidates(target.code);
        hits = new bytes4[](candidates.length);
        uint256 n;
        bytes memory args = new bytes(32 * PROBE_WORDS);
        for (uint256 i; i < candidates.length; ++i) {
            uint256 snap = vm.snapshotState();
            vm.prank(prober);
            (bool ok, bytes memory ret) =
                target.call{ gas: PROBE_GAS }(abi.encodePacked(candidates[i], args));
            vm.revertToState(snap);
            if (!ok && keccak256(ret) == keccak256(reason)) hits[n++] = candidates[i];
        }
        assembly ("memory-safe") {
            mstore(hits, n)
        }
    }

    /// @dev Every distinct 3- and 4-byte immediate the code pushes, walking the opcodes.
    function _candidates(bytes memory code) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](code.length / 4 + 1);
        uint256 n;
        uint256 i;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                uint256 size = op - 0x5f;
                if ((size == 3 || size == 4) && i + size < code.length) {
                    uint32 v;
                    for (uint256 k = 1; k <= size; ++k) {
                        v = (v << 8) | uint8(code[i + k]);
                    }
                    bytes4 sel = bytes4(v);
                    bool seen;
                    for (uint256 k; k < n && !seen; ++k) {
                        seen = out[k] == sel;
                    }
                    if (!seen) out[n++] = sel;
                }
                i += size + 1;
            } else {
                ++i;
            }
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    // ------------------------------------------------------------------ helpers

    function _authorityOf(address a) internal view returns (address) {
        (bool ok, bytes memory ret) = a.staticcall(abi.encodeCall(IAccessManaged.authority, ()));
        return ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
    }

    function _isTarget(GovernanceConfig.Config memory cfg, address a) internal pure returns (bool) {
        for (uint256 i; i < cfg.targets.length; ++i) {
            if (cfg.targets[i].target == a) return true;
        }
        return false;
    }

    function _has(bytes4[] memory list, bytes4 sel) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == sel) return true;
        }
        return false;
    }

    function _nameOf(address a) internal view returns (string memory) {
        string[] memory names = DeployCore.order(params);
        for (uint256 i; i < names.length; ++i) {
            if (DeployCore.addressOf(deployment, names[i]) == a) return names[i];
        }
        return vm.toString(a);
    }

    function _hex(bytes4 sel) internal pure returns (string memory) {
        return vm.toString(abi.encodePacked(sel));
    }
}
