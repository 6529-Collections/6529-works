// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { IArtistRegistry, IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IFederationGate } from "src/interfaces/core/IFederationGate.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { InterfaceStub } from "../mocks/identity/IdentityWorksMocks.sol";
import { AccountsFixture } from "./AccountsFixture.sol";

/// @notice The accounts module's wiring: constructor arguments, the payout refusals that follow
///         from them, the refused wiring functions of the earlier registry, and the package
///         registry setter.
contract AccountsWiringTest is AccountsFixture {
    bytes32 internal constant VOTE = keccak256("vote");

    /// @dev A payout that could never pull its money is refused at staging: zero, this module,
    ///      every contract it is wired to, a deployed vault of the split factory, and any
    ///      contract declaring (ERC-165) the interface of a network contract.
    function test_PayoutValidation_RejectsWiredContractsAndSplitVaults() public {
        address splitVault = makeAddr("splitVault");
        factory.setWallet(splitVault, true);
        address[9] memory wired = [
            address(0),
            address(registry),
            address(directory),
            streamAddr,
            editionsAddr,
            address(factory),
            address(outcomes),
            packageRegistry,
            splitVault
        ];
        for (uint256 i; i < wired.length; ++i) {
            (bool ok, bytes memory data) =
                _relay(_changeCall(artistKey, _identity(artist, wired[i])));
            assertFalse(ok, vm.toString(i));
            assertEq(data, abi.encodeWithSelector(IArtistRegistry.InvalidIdentity.selector));
        }
    }

    /// @dev Any contract declaring a network contract's interface is refused as a payout; one
    ///      declaring another interface is an ordinary payout.
    function test_PayoutValidation_RejectsContractsDeclaringNetworkInterfaces() public {
        bytes4[9] memory ids = [
            type(IStream).interfaceId,
            type(IEditions).interfaceId,
            type(IModuleSlots).interfaceId,
            type(IDirectory).interfaceId,
            type(IWorkFacts).interfaceId,
            type(IMintPolicy).interfaceId,
            type(IFederationGate).interfaceId,
            type(IArtistRegistry).interfaceId,
            type(IRevenueEscrow).interfaceId
        ];
        for (uint256 i; i < ids.length; ++i) {
            address declaring = address(new InterfaceStub(ids[i]));
            (bool ok, bytes memory data) =
                _relay(_changeCall(artistKey, _identity(artist, declaring)));
            assertFalse(ok, vm.toString(i));
            assertEq(data, abi.encodeWithSelector(IArtistRegistry.InvalidIdentity.selector));
        }
        address plain = address(new InterfaceStub(0x12345678));
        _stage(artistKey, _identity(artist, plain));
        assertEq(registry.pendingChange(artistId).next.payout, plain);
    }

    /// @dev A split vault deployed after a change was staged is refused when it executes.
    function test_PayoutValidation_RecheckedForAVaultDeployedLater() public {
        _stage(artistKey, _identity(artist, payout));
        factory.setWallet(payout, true);
        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, address(registry), false);
        registry.executeChange(artistId);
        assertEq(registry.payoutAddress(artistId), artist);
    }

    /// @dev The four wiring functions of the earlier registry are refused for everyone.
    function test_Bind_AlwaysRefused() public {
        address[3] memory callers = [admin, network, stranger];
        for (uint256 i; i < callers.length; ++i) {
            bytes memory refused =
                abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, callers[i]);
            vm.startPrank(callers[i]);
            vm.expectRevert(refused);
            registry.bindPackageRegistry(stranger);
            vm.expectRevert(refused);
            registry.bindSplitFactory(stranger);
            vm.expectRevert(refused);
            registry.bindFederationRegistry(stranger);
            vm.expectRevert(refused);
            registry.bindStatementLog(stranger);
            vm.stopPrank();
        }
        assertEq(registry.packageRegistry(), packageRegistry, "nothing moved");
    }

    /// @dev The wiring is what the constructor was given; it logs the first source and package
    ///      registry.
    function test_Constructor_WiringAndLogs() public {
        assertEq(registry.directory(), address(directory));
        assertEq(registry.stream(), streamAddr);
        assertEq(registry.editions(), editionsAddr);
        assertEq(registry.splitFactory(), address(factory));
        assertEq(registry.statementLog(), address(outcomes));
        assertEq(registry.packageRegistry(), packageRegistry);
        assertEq(address(registry.consolidationSource()), address(adapter));
        assertEq(registry.consolidationSourceCodeHash(), address(adapter).codehash);
        vm.expectEmit();
        emit IArtistRegistry.ConsolidationSourceSet(
            address(0), address(adapter), address(adapter).codehash
        );
        vm.expectEmit();
        emit IArtistRegistry.PackageRegistrySet(address(0), packageRegistry);
        _deploy(address(0));
    }

    /// @dev The constructor checks the source against its pin, as the setter does.
    function test_Constructor_ChecksTheSourceAgainstItsPin() public {
        Accounts.Wiring memory w = Accounts.Wiring(
            address(directory),
            streamAddr,
            editionsAddr,
            address(factory),
            address(0),
            packageRegistry
        );
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(adapter))
        );
        new Accounts(address(manager), adapter, keccak256("other code"), w);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        new Accounts(address(manager), IConsolidationSource(stranger), bytes32(0), w);
    }

    /// @dev The network replaces the package registry, compare-and-set; the new one alone
    ///      registers accounts.
    function test_SetPackageRegistry_SwapsTheOnlyRegisterCaller() public {
        address next = address(new InterfaceStub(0x01020304));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        registry.setPackageRegistry(packageRegistry, next);
        vm.startPrank(network);
        vm.expectRevert(IArtistRegistry.ExpectedValueMismatch.selector);
        registry.setPackageRegistry(next, next);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        registry.setPackageRegistry(packageRegistry, stranger);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.PackageRegistrySet(packageRegistry, next);
        registry.setPackageRegistry(packageRegistry, next);
        vm.stopPrank();
        vm.prank(packageRegistry);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, packageRegistry)
        );
        registry.register(outsider, PROFILE, PROFILE_DOC);
        vm.prank(next);
        assertEq(registry.register(outsider, PROFILE, PROFILE_DOC), uint160(outsider));
    }

    /// @dev Without a statement log a contest records no prior outcome and no vote can resolve
    ///      it: it can only lapse.
    function test_NoStatementLog_AContestCanOnlyLapse() public {
        registry = _deploy(address(0));
        _configureRoles(address(registry));
        artistId = _register(artist);
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        assertEq(registry.pendingChange(artistId).priorOutcome, bytes32(0));
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.OutcomeNotRecorded.selector, artistId, VOTE)
        );
        registry.resolveContested(artistId, false, VOTE);
        vm.warp(block.timestamp + 90 days);
        registry.expireContest(artistId);
        assertEq(registry.authorityOf(artistId), artist);
    }
}
