// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Roles } from "src/governance/Roles.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IModuleSlots, IModules } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { CoreDeployFixture } from "../deploy/CoreDeployFixture.sol";

/// @notice The genesis role map of the plain core (`config/genesis.core.example.json`), read
///         back from the installed manager: every function that changes a waiting period, a
///         module, a minter, or makes the one timed move (`rescue`, `rebind`) maps to NETWORK,
///         so the wait that applies is the contract's own setting and no role delay is stacked
///         on it; the rest keep today's classes.
contract CoreRoleMapTest is CoreDeployFixture {
    function _networkAccount() internal override returns (address) {
        return makeAddr("network");
    }

    function test_TheModuleMinterAndSettingFunctionsAreTheNetworksAtOnce() public view {
        bytes4[5] memory shared = [
            IModuleSlots.proposeModule.selector,
            IModuleSlots.removeModule.selector,
            IModuleSlots.setModuleDelay.selector,
            IModules.addMinter.selector,
            IModules.removeMinter.selector
        ];
        for (uint256 i; i < shared.length; ++i) {
            _role(address(d.stream), shared[i], Roles.NETWORK);
            _role(address(d.editions), shared[i], Roles.NETWORK);
            if (i < 3) _role(address(d.directory), shared[i], Roles.NETWORK);
        }
        _role(address(d.stream), IStream.setRescueDelay.selector, Roles.NETWORK);
        _role(address(d.stream), IStream.rescue.selector, Roles.NETWORK);
        _role(address(d.editions), IEditions.setRebindDelay.selector, Roles.NETWORK);
        _role(address(d.editions), IEditions.rebind.selector, Roles.NETWORK);
        _role(address(d.directory), IDirectory.setUnclaimedPeriod.selector, Roles.NETWORK);
        assertEq(Roles.executionDelay(Roles.NETWORK), 0);
    }

    function test_TheMarketplaceFunctionsKeepTheirClasses() public view {
        _role(address(d.stream), IStream.createCollection.selector, Roles.PLATFORM);
        _role(address(d.stream), IStream.setContractURI.selector, Roles.PARAMETER_SETTER);
        _role(address(d.stream), IStream.setOwner.selector, Roles.FUNDS_SETTER);
        _role(address(d.editions), IEditions.setContractURI.selector, Roles.PARAMETER_SETTER);
        _role(address(d.editions), IEditions.setOwner.selector, Roles.FUNDS_SETTER);
    }

    /// @notice The functions a module or a minter calls, and `activateModule`, are not governed:
    ///         they check their caller themselves (or anyone may call them).
    function test_TheSeamFunctionsAreNotMapped() public view {
        bytes4[6] memory open = [
            IStream.mint.selector,
            IStream.recordPrimarySale.selector,
            IStream.burn.selector,
            IStream.setRoyalty.selector,
            IStream.lockRoyaltyRate.selector,
            IModuleSlots.activateModule.selector
        ];
        for (uint256 i; i < open.length; ++i) {
            _role(address(d.stream), open[i], Roles.ADMIN);
        }
    }

    /// @notice Every governed selector of the three permanent contracts in the policy file has
    ///         the role the file gives it.
    function test_TheInstalledMapIsThePolicyFile() public view {
        string memory json = vm.readFile(GENESIS);
        string[3] memory names = ["Stream6529", "StreamEditions6529", "StreamDirectory6529"];
        address[3] memory at = [address(d.stream), address(d.editions), address(d.directory)];
        uint256 checked;
        for (uint256 c; c < 3; ++c) {
            string memory base = _contract(json, names[c]);
            for (uint256 j;; ++j) {
                string memory f = string.concat(base, ".functions[", vm.toString(j), "]");
                if (!vm.keyExistsJson(json, f)) break;
                bytes4 sel = bytes4(vm.parseJsonBytes(json, string.concat(f, ".selector")));
                string memory role = vm.parseJsonString(json, string.concat(f, ".role"));
                assertEq(Roles.label(d.manager.getTargetFunctionRole(at[c], sel)), role);
                ++checked;
            }
        }
        // Directory also carries the four network functions every Independent Stream token asks it
        // about (`rescue`, `setRescueDelay`, `rebind`, `setRebindDelay`).
        assertEq(checked, 11 + 10 + 9);
    }

    function _contract(string memory json, string memory name)
        internal
        view
        returns (string memory)
    {
        for (uint256 i;; ++i) {
            string memory c = string.concat(".contracts[", vm.toString(i), "]");
            if (
                keccak256(bytes(vm.parseJsonString(json, string.concat(c, ".name"))))
                    == keccak256(bytes(name))
            ) {
                return c;
            }
        }
    }

    function _role(address target, bytes4 selector, uint64 role) internal view {
        assertEq(d.manager.getTargetFunctionRole(target, selector), role);
    }
}
