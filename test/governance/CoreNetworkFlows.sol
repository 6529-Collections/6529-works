// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Outcome, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IModuleSlots, IModules } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { CoreDeployFixture } from "../deploy/CoreDeployFixture.sol";
import { MockRenderer, MockSale, MockTerms } from "../mocks/core/CoreMocks.sol";

/// @notice What the network does with the plain core's waiting periods, run against the
///         deployed stack with the genesis role map. Each wait is read from the contract (the
///         setting in force), never written here as a number. A concrete suite chooses the
///         network: a key (`CoreNetwork.t.sol`) or a real Safe on a fork (`SafeCoreNetwork`).
abstract contract CoreNetworkFlows is CoreDeployFixture {
    uint48 internal constant MAX_WAIT = 400 days;

    // ------------------------------------------------------------------ module and minter waits

    /// @notice An announced module is refused before the wait in force has passed, then anyone
    ///         installs it.
    function testFuzz_AModuleWaitsTheModuleDelayInForce(uint48 wait, uint48 early) public {
        wait = uint48(bound(wait, 1, MAX_WAIT));
        _asNetwork(address(d.stream), abi.encodeCall(IModuleSlots.setModuleDelay, (wait)));
        address next = address(new MockRenderer());
        _asNetwork(
            address(d.stream), abi.encodeCall(IModuleSlots.proposeModule, (Slots.RENDERER, next))
        );
        uint48 readyAt = d.stream.pendingModule(Slots.RENDERER).readyAt;
        assertEq(readyAt, block.timestamp + d.stream.moduleDelay());
        early = uint48(bound(early, 0, wait - 1));
        vm.warp(block.timestamp + early);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.RENDERER)
        );
        vm.prank(stranger);
        d.stream.activateModule(Slots.RENDERER);
        vm.warp(readyAt);
        vm.prank(stranger);
        d.stream.activateModule(Slots.RENDERER);
        assertEq(d.stream.moduleOf(Slots.RENDERER), next);
    }

    /// @notice A changed delay applies to later announcements; one already announced keeps the
    ///         time it was given.
    function testFuzz_AChangedModuleDelayLeavesAPendingAnnouncementAlone(uint48 next) public {
        next = uint48(bound(next, 0, MAX_WAIT));
        uint48 before = d.directory.moduleDelay();
        address accounts = address(new MockTerms());
        _asNetwork(
            address(d.directory),
            abi.encodeCall(IModuleSlots.proposeModule, (Slots.ACCOUNTS, accounts))
        );
        uint48 firstReady = d.directory.pendingModule(Slots.ACCOUNTS).readyAt;
        assertEq(firstReady, block.timestamp + before);

        vm.expectEmit(address(d.directory));
        emit IModuleSlots.ModuleDelaySet(before, next);
        _asNetwork(address(d.directory), abi.encodeCall(IModuleSlots.setModuleDelay, (next)));

        address independentStream = address(new MockTerms());
        _asNetwork(
            address(d.directory),
            abi.encodeCall(
                IModuleSlots.proposeModule, (Slots.INDEPENDENT_STREAM, independentStream)
            )
        );
        assertEq(
            d.directory.pendingModule(Slots.INDEPENDENT_STREAM).readyAt, block.timestamp + next
        );
        assertEq(d.directory.pendingModule(Slots.ACCOUNTS).readyAt, firstReady);
    }

    /// @notice Zero is allowed: an announcement is then installable in the same block.
    function test_AZeroModuleDelayInstallsAtOnce() public {
        _asNetwork(address(d.editions), abi.encodeCall(IModuleSlots.setModuleDelay, (0)));
        address terms = address(new MockTerms());
        _asNetwork(
            address(d.editions), abi.encodeCall(IModuleSlots.proposeModule, (Slots.TERMS, terms))
        );
        vm.prank(stranger);
        d.editions.activateModule(Slots.TERMS);
        assertEq(d.editions.moduleOf(Slots.TERMS), terms);
    }

    /// @notice An added minter waits the delay in force; a removal is immediate.
    function testFuzz_AMinterWaitsAndIsRemovedAtOnce(uint48 wait) public {
        wait = uint48(bound(wait, 1, MAX_WAIT));
        _asNetwork(address(d.stream), abi.encodeCall(IModuleSlots.setModuleDelay, (wait)));
        MockSale second = new MockSale();
        _asNetwork(address(d.stream), abi.encodeCall(IModules.addMinter, (address(second))));
        assertFalse(d.stream.isMinter(address(second)));
        vm.warp(block.timestamp + d.stream.moduleDelay());
        assertTrue(d.stream.isMinter(address(second)));

        _asNetwork(address(d.stream), abi.encodeCall(IModules.removeMinter, (address(sale))));
        assertFalse(d.stream.isMinter(address(sale)));
        vm.prank(platform);
        d.stream.createCollection("Genesis", bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(sale)));
        sale.mint(address(d.stream), _facts(1));
    }

    /// @notice A module is removed at once.
    function test_AModuleIsRemovedAtOnce() public {
        _asNetwork(address(d.stream), abi.encodeCall(IModuleSlots.removeModule, (Slots.TERMS)));
        assertEq(d.stream.moduleOf(Slots.TERMS), address(0));
    }

    // ------------------------------------------------------------------ rescue

    /// @notice A rescue is refused before the rescue period in force has passed since the
    ///         minter's removal; after a change, the new value decides.
    function testFuzz_ARescueWaitsTheRescueDelayInForce(uint48 next, uint48 early) public {
        uint256 tokenId = _mintInCustody(1);
        _asNetwork(address(d.stream), abi.encodeCall(IModules.removeMinter, (address(sale))));
        uint256 removedAt = block.timestamp;

        uint48 launch = d.stream.rescueDelay();
        vm.warp(removedAt + launch - 1);
        _expectNetworkRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, tokenId));
        _asNetwork(address(d.stream), abi.encodeCall(IStream.rescue, (tokenId, museum)));

        next = uint48(bound(next, 1, MAX_WAIT));
        vm.expectEmit(address(d.stream));
        emit IStream.RescueDelaySet(launch, next);
        _asNetwork(address(d.stream), abi.encodeCall(IStream.setRescueDelay, (next)));

        if (block.timestamp < removedAt + next) {
            early = uint48(bound(early, 0, removedAt + next - 1 - block.timestamp));
            vm.warp(block.timestamp + early);
            _expectNetworkRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, tokenId));
            _asNetwork(address(d.stream), abi.encodeCall(IStream.rescue, (tokenId, museum)));
            vm.warp(removedAt + d.stream.rescueDelay());
        }
        _asNetwork(address(d.stream), abi.encodeCall(IStream.rescue, (tokenId, museum)));
        assertEq(IERC721(address(d.stream)).ownerOf(tokenId), museum);
        assertEq(uint8(d.stream.workOf(tokenId).outcome), uint8(Outcome.RESCUED));
    }

    /// @notice Zero rescue period: a removed minter's unsold token can be rescued at once.
    function test_AZeroRescueDelayRescuesAtOnce() public {
        uint256 tokenId = _mintInCustody(1);
        _asNetwork(address(d.stream), abi.encodeCall(IStream.setRescueDelay, (0)));
        _asNetwork(address(d.stream), abi.encodeCall(IModules.removeMinter, (address(sale))));
        _asNetwork(address(d.stream), abi.encodeCall(IStream.rescue, (tokenId, museum)));
        assertEq(IERC721(address(d.stream)).ownerOf(tokenId), museum);
    }

    // ------------------------------------------------------------------ rebind

    /// @notice A rebind is refused before the rebind period in force has passed since the
    ///         minter's removal; after a change, the new value decides.
    function testFuzz_ARebindWaitsTheRebindDelayInForce(uint48 next) public {
        uint256 master = _mintInCustody(1);
        editionSale.createEdition(address(d.editions), master, 10, address(0xFEE), 1000);
        MockSale successor = new MockSale();
        _asNetwork(address(d.editions), abi.encodeCall(IModules.addMinter, (address(successor))));
        vm.warp(block.timestamp + d.editions.moduleDelay());
        _asNetwork(
            address(d.editions), abi.encodeCall(IModules.removeMinter, (address(editionSale)))
        );
        uint256 removedAt = block.timestamp;

        uint48 launch = d.editions.rebindDelay();
        vm.warp(removedAt + launch - 1);
        _expectNetworkRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, master));
        _asNetwork(
            address(d.editions), abi.encodeCall(IEditions.rebind, (master, address(successor)))
        );

        next = uint48(bound(next, 0, MAX_WAIT));
        vm.expectEmit(address(d.editions));
        emit IEditions.RebindDelaySet(launch, next);
        _asNetwork(address(d.editions), abi.encodeCall(IEditions.setRebindDelay, (next)));
        if (block.timestamp < removedAt + next) {
            _expectNetworkRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, master));
            _asNetwork(
                address(d.editions), abi.encodeCall(IEditions.rebind, (master, address(successor)))
            );
            vm.warp(removedAt + next);
        }
        _asNetwork(
            address(d.editions), abi.encodeCall(IEditions.rebind, (master, address(successor)))
        );
        assertEq(d.editions.editionOf(master).minter, address(successor));
    }

    // ------------------------------------------------------------------ unclaimed period

    /// @notice The unclaimed period is the network's setting in Directory, changed at once,
    ///         zero allowed. (The split ledger and the escrow read it when a forfeit or an expiry
    ///         is attempted; that read is tested with their code.)
    function testFuzz_TheUnclaimedPeriodIsTheNetworksSetting(uint48 next) public {
        uint48 before = d.directory.unclaimedPeriod();
        vm.expectEmit(address(d.directory));
        emit IDirectory.UnclaimedPeriodSet(before, next);
        _asNetwork(address(d.directory), abi.encodeCall(IDirectory.setUnclaimedPeriod, (next)));
        assertEq(d.directory.unclaimedPeriod(), next);
    }

    // ------------------------------------------------------------------ only the network

    /// @notice Nobody but the network changes a setting, announces or removes a module, adds or
    ///         removes a minter, rescues or rebinds.
    function test_NobodyButTheNetworkCallsTheGovernedFunctions() public {
        address[3] memory targets = [address(d.stream), address(d.editions), address(d.directory)];
        for (uint256 i; i < targets.length; ++i) {
            _refused(targets[i], abi.encodeCall(IModuleSlots.setModuleDelay, (0)));
            _refused(
                targets[i],
                abi.encodeCall(IModuleSlots.proposeModule, (Slots.TERMS, address(d.contentStore)))
            );
            _refused(targets[i], abi.encodeCall(IModuleSlots.removeModule, (Slots.TERMS)));
        }
        _refused(address(d.stream), abi.encodeCall(IModules.addMinter, (address(d.contentStore))));
        _refused(address(d.stream), abi.encodeCall(IModules.removeMinter, (address(sale))));
        _refused(address(d.stream), abi.encodeCall(IStream.setRescueDelay, (0)));
        _refused(address(d.stream), abi.encodeCall(IStream.rescue, (1, stranger)));
        _refused(address(d.editions), abi.encodeCall(IEditions.setRebindDelay, (0)));
        _refused(address(d.editions), abi.encodeCall(IEditions.rebind, (1, stranger)));
        _refused(address(d.directory), abi.encodeCall(IDirectory.setUnclaimedPeriod, (0)));
    }

    function _refused(address target, bytes memory data) internal {
        vm.prank(stranger);
        (bool ok, bytes memory reason) = target.call(data);
        assertFalse(ok);
        assertEq(bytes4(reason), IAccessManaged.AccessManagedUnauthorized.selector);
    }
}
