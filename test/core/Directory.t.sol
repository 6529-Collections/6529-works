// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Directory } from "src/core/Directory.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { CoreFixture } from "../mocks/core/CoreFixture.sol";
import { HostileModule } from "../mocks/core/CoreMocks.sol";
import { HostileAccounts } from "../mocks/core/StreamCoreMocks.sol";

/// @notice The permanent `Directory`: genesis wiring, `payoutAddress` forwarding (and never a
///         default), the network's `unclaimedPeriod` setting, ERC-165. `moduleDelay` through the
///         real Directory is in `StreamSettings.t.sol`.
contract DirectoryTest is CoreFixture {
    function _unauthorized(address caller) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller);
    }

    function test_Constructor_GenesisModulesAndLaunchSettings() public {
        assertEq(directory.moduleOf(Slots.ACCOUNTS), address(accounts));
        assertEq(directory.moduleOf(Slots.FEDERATION), address(gate));
        assertEq(directory.moduleOf(Slots.FEDERATED_TERMS), address(terms));
        assertEq(directory.moduleOf(Slots.FEDERATED_RECORDS), address(records));
        assertEq(directory.unclaimedPeriod(), 180 days);
        assertEq(directory.moduleDelay(), 7 days);
        assertEq(directory.authority(), address(manager));
        vm.recordLogs();
        new Directory(address(manager), address(1), address(2), address(3), address(4));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 sets;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IModuleSlots.ModuleSet.selector) ++sets;
        }
        assertEq(sets, 4);
    }

    function testFuzz_PayoutAddress_ForwardsToTheAccountsModule(uint256 artistId, address payout)
        public
    {
        accounts.setPayout(artistId, payout);
        assertEq(directory.payoutAddress(artistId), payout);
        assertEq(IArtistPayoutResolver(address(directory)).payoutAddress(artistId), payout);
    }

    /// @dev A missing ACCOUNTS module reverts: no default answer.
    function test_PayoutAddress_RevertsWithoutAModule() public {
        directory.removeModule(Slots.ACCOUNTS);
        vm.expectRevert();
        directory.payoutAddress(ARTIST);
    }

    function test_PayoutAddress_RevertsWhenTheModuleReverts() public {
        HostileAccounts hostile = _install();
        hostile.setMode(HostileAccounts.Mode.REVERT);
        vm.expectRevert("hostile");
        directory.payoutAddress(ARTIST);
    }

    /// @dev A module that burns its gas makes the call revert at any gas: there is no gas level
    ///      at which a default comes back.
    function testFuzz_PayoutAddress_RevertsWhenTheModuleBurnsItsGas(uint256 gas) public {
        gas = bound(gas, 30_000, 5_000_000);
        HostileAccounts hostile = _install();
        hostile.setMode(HostileAccounts.Mode.BURN_GAS);
        (bool ok,) = address(directory).call{ gas: gas }(
            abi.encodeCall(IDirectory.payoutAddress, (ARTIST))
        );
        assertFalse(ok);
    }

    function test_PayoutAddress_RevertsOnEmptyReturnData() public {
        HostileAccounts hostile = _install();
        hostile.setMode(HostileAccounts.Mode.EMPTY);
        vm.expectRevert();
        directory.payoutAddress(ARTIST);
        // A module with no such function (the generic hostile module) also reverts.
        HostileModule generic = new HostileModule();
        directory.proposeModule(Slots.ACCOUNTS, address(generic));
        skip(7 days);
        directory.activateModule(Slots.ACCOUNTS);
        vm.expectRevert();
        directory.payoutAddress(ARTIST);
    }

    /// @dev A lying module is answered as it lies (the accounts module is trusted for payouts,
    ///      owner decision 2); the directory adds nothing.
    function test_PayoutAddress_ALyingModuleIsForwarded() public {
        HostileAccounts hostile = _install();
        assertEq(directory.payoutAddress(ARTIST), address(0xBAD));
    }

    function _install() internal returns (HostileAccounts hostile) {
        hostile = new HostileAccounts();
        directory.proposeModule(Slots.ACCOUNTS, address(hostile));
        skip(7 days);
        directory.activateModule(Slots.ACCOUNTS);
    }

    // ---------------------------------------------------------------- unclaimedPeriod

    function testFuzz_SetUnclaimedPeriod_OnlyTheNetworkEventCarriesOldAndNew(
        address caller,
        uint48 first,
        uint48 second
    ) public {
        vm.assume(caller != address(this));
        vm.prank(caller);
        vm.expectRevert(_unauthorized(caller));
        directory.setUnclaimedPeriod(first);
        vm.expectEmit(address(directory));
        emit IDirectory.UnclaimedPeriodSet(180 days, first);
        directory.setUnclaimedPeriod(first);
        vm.expectEmit(address(directory));
        emit IDirectory.UnclaimedPeriodSet(first, second);
        directory.setUnclaimedPeriod(second);
        assertEq(directory.unclaimedPeriod(), second);
    }

    function test_SetUnclaimedPeriod_ZeroAndAtOnce() public {
        directory.setUnclaimedPeriod(0);
        assertEq(directory.unclaimedPeriod(), 0);
        // No delay on the change: the next read in the same block sees it.
        directory.setUnclaimedPeriod(1);
        assertEq(directory.unclaimedPeriod(), 1);
    }

    function testFuzz_ModuleFunctions_OnlyTheNetwork(address caller) public {
        vm.assume(caller != address(this));
        vm.startPrank(caller);
        vm.expectRevert(_unauthorized(caller));
        directory.setModuleDelay(0);
        vm.expectRevert(_unauthorized(caller));
        directory.proposeModule(Slots.ACCOUNTS, address(gate));
        vm.expectRevert(_unauthorized(caller));
        directory.removeModule(Slots.ACCOUNTS);
        vm.stopPrank();
    }

    function test_SupportsInterface() public view {
        assertTrue(directory.supportsInterface(type(IERC165).interfaceId));
        assertTrue(directory.supportsInterface(type(IArtistPayoutResolver).interfaceId));
        assertTrue(directory.supportsInterface(type(IDirectory).interfaceId));
        assertTrue(directory.supportsInterface(type(IModuleSlots).interfaceId));
        assertFalse(directory.supportsInterface(0xffffffff));
    }

    /// @dev Nothing in the directory accepts ETH.
    function test_NonPayable() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(directory).call{ value: 1 }(
            abi.encodeCall(IDirectory.setUnclaimedPeriod, (1))
        );
        assertFalse(ok);
        (ok,) = address(directory).call{ value: 1 }("");
        assertFalse(ok);
    }
}
