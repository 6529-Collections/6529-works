// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Edition, MintFacts, Outcome, Slots, Work } from "src/interfaces/core/CoreTypes.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IModules } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { CoreFixture } from "../mocks/core/CoreFixture.sol";
import { HostileModule, MockSale } from "../mocks/core/CoreMocks.sol";

/// @notice Base smoke tests of the seam and of the network's waiting-period settings. Lanes 1 and 2
///         take these over and extend them (unit, fuzz, invariants, the full hostile matrix).
contract CoreSeamTest is CoreFixture {
    function test_Mint_StoresFactsAndCountsSerial() public {
        uint256 id = _mint(1);
        assertEq(id, 1);
        assertEq(stream.ownerOf(id), address(sale));
        Work memory w = stream.workOf(id);
        assertEq(w.itemHash, _facts(1).itemHash);
        assertEq(w.artistId, ARTIST);
        assertEq(w.serial, 1);
        assertEq(uint8(w.outcome), uint8(Outcome.NONE));
        assertEq(stream.tokenOfContent(_facts(1).contentHash), id);
        (address receiver, uint256 amount) = stream.royaltyInfo(id, 100_000);
        assertEq(receiver, address(0xFEE));
        assertEq(amount, 6529);
        assertEq(stream.tokenURI(id), "data:,mock");
    }

    function test_Mint_OnlyAMinterAndOneLiveTokenPerContent() public {
        MintFacts memory f = _facts(1);
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(this)));
        stream.mint(address(this), f);
        uint256 id = _mint(1);
        vm.expectRevert(
            abi.encodeWithSelector(IStream.ContentAlreadyMinted.selector, f.contentHash, id)
        );
        sale.mint(address(stream), f);
        // Burned in custody, the content mints again.
        sale.burn(address(stream), id);
        assertEq(_mint(1), 2);
    }

    function test_Sold_TheMinterCanDoNothingMore() public {
        uint256 id = _sell(1, collector);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotInPrimarySale.selector, id));
        sale.burn(address(stream), id);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotInPrimarySale.selector, id));
        sale.record(address(stream), id, false, address(0), 0);
    }

    /// @dev A hostile contract installed as TERMS, RECORDS and RENDERER, and added as a minter,
    ///      cannot move, burn, re-record, rescue or get approved for a collector's token.
    function test_Hostile_NoSeamPositionReachesACollectorsToken() public {
        uint256 id = _sell(1, collector);
        HostileModule hostile = new HostileModule();
        stream.proposeModule(Slots.TERMS, address(hostile));
        stream.proposeModule(Slots.RECORDS, address(hostile));
        stream.proposeModule(Slots.RENDERER, address(hostile));
        stream.addMinter(address(hostile));
        skip(7 days);
        stream.activateModule(Slots.TERMS);
        stream.activateModule(Slots.RECORDS);
        stream.activateModule(Slots.RENDERER);
        assertEq(hostile.attack(address(stream), id, collector), 0);
        assertEq(stream.ownerOf(id), collector);
        assertEq(uint8(stream.workOf(id).outcome), uint8(Outcome.SOLD));
        // A renderer that reverts or burns its gas fails only tokenURI.
        hostile.setMode(HostileModule.Mode.REVERT);
        vm.expectRevert();
        stream.tokenURI(id);
        vm.prank(collector);
        stream.transferFrom(collector, address(0xB0B), id);
        assertEq(stream.ownerOf(id), address(0xB0B));
    }

    // ---------------------------------------------------------------- rescue: 14 days

    function test_RescueDelay_FourteenDaysAtDeploymentOnlyTheNetworkSetsIt() public {
        assertEq(stream.rescueDelay(), 14 days);
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, collector)
        );
        stream.setRescueDelay(0);
        vm.expectEmit(address(stream));
        emit IStream.RescueDelaySet(14 days, 3 days);
        stream.setRescueDelay(3 days);
        assertEq(stream.rescueDelay(), 3 days);
    }

    /// @dev The period in force when the rescue is attempted decides, zero included.
    function testFuzz_Rescue_RefusedBeforeThePeriodInForce(uint48 delay, uint256 wait) public {
        delay = uint48(bound(delay, 1, 365 days));
        wait = bound(wait, 0, delay - 1);
        uint256 id = _mint(1);
        stream.removeMinter(address(sale));
        stream.setRescueDelay(delay);
        skip(wait);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
        stream.rescue(id, marketOwner);
        stream.setRescueDelay(0);
        stream.rescue(id, marketOwner);
        assertEq(stream.ownerOf(id), marketOwner);
    }

    function testFuzz_Rescue_RefusedBeforeTheLaunchPeriod(uint256 wait) public {
        wait = bound(wait, 0, 14 days - 1);
        uint256 id = _mint(1);
        // Not while the minter is still a minter.
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
        stream.rescue(id, marketOwner);
        stream.removeMinter(address(sale));
        skip(wait);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, id));
        stream.rescue(id, marketOwner);
    }

    function test_Rescue_AfterFourteenDaysOnlyTheNetworkOnlyUnsold() public {
        uint256 held = _mint(1);
        uint256 sold = _sell(2, collector);
        stream.removeMinter(address(sale));
        skip(14 days);
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, collector)
        );
        stream.rescue(held, collector);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, sold));
        stream.rescue(sold, marketOwner);
        stream.rescue(held, marketOwner);
        assertEq(stream.ownerOf(held), marketOwner);
        assertEq(uint8(stream.workOf(held).outcome), uint8(Outcome.RESCUED));
    }

    // ---------------------------------------------------------------- editions

    function test_Edition_CreateMintSealAndTheSealNeverGrows() public {
        uint256 id = _sell(1, collector);
        sale.createEdition(address(editions), id, 10, address(0xFEE), 6529);
        sale.mintEdition(address(editions), collector, id, 3, 0.1 ether);
        vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidSeal.selector, id));
        sale.seal(address(editions), id, 2);
        sale.seal(address(editions), id, 4);
        vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidSeal.selector, id));
        sale.seal(address(editions), id, 10);
        sale.mintEdition(address(editions), collector, id, 1, 0.1 ether);
        vm.expectRevert(abi.encodeWithSelector(IEditions.SupplyExceeded.selector, id));
        sale.mintEdition(address(editions), collector, id, 1, 0.1 ether);
        Edition memory e = editions.editionOf(id);
        assertEq(e.maxSupply, 4);
        assertEq(e.minted, 4);
        assertEq(editions.balanceOf(collector, id), 4);
        assertEq(editions.uri(id), "data:,mock");
    }

    function test_RebindDelay_FourteenDaysAtDeploymentOnlyTheNetworkSetsIt() public {
        assertEq(editions.rebindDelay(), 14 days);
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, collector)
        );
        editions.setRebindDelay(0);
        vm.expectEmit(address(editions));
        emit IEditions.RebindDelaySet(14 days, 1 days);
        editions.setRebindDelay(1 days);
        assertEq(editions.rebindDelay(), 1 days);
    }

    function test_UnclaimedPeriod_OneEightyDaysAtDeploymentOnlyTheNetworkSetsIt() public {
        assertEq(directory.unclaimedPeriod(), 180 days);
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, collector)
        );
        directory.setUnclaimedPeriod(0);
        vm.expectEmit(address(directory));
        emit IDirectory.UnclaimedPeriodSet(180 days, 30 days);
        directory.setUnclaimedPeriod(30 days);
        assertEq(directory.unclaimedPeriod(), 30 days);
    }

    function testFuzz_Rebind_RefusedBeforeTheLaunchPeriod(uint256 wait) public {
        wait = bound(wait, 0, 14 days - 1);
        uint256 id = _sell(1, collector);
        sale.createEdition(address(editions), id, 10, address(0xFEE), 6529);
        MockSale next = new MockSale();
        editions.addMinter(address(next));
        skip(7 days);
        editions.removeMinter(address(sale));
        skip(wait);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, id));
        editions.rebind(id, address(next));
    }

    function test_Rebind_AfterFourteenDaysOnlyUnsealed() public {
        uint256 stuck = _sell(1, collector);
        uint256 live = _sell(2, collector);
        uint256 done = _sell(3, collector);
        sale.createEdition(address(editions), stuck, 10, address(0xFEE), 6529);
        sale.createEdition(address(editions), live, 10, address(0xFEE), 6529);
        sale.createEdition(address(editions), done, 10, address(0xFEE), 6529);
        sale.mintEdition(address(editions), collector, live, 1, 1);
        sale.seal(address(editions), done, 4);
        MockSale next = new MockSale();
        editions.addMinter(address(next));
        skip(7 days);
        editions.removeMinter(address(sale));
        skip(14 days);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, done));
        editions.rebind(done, address(next));
        editions.rebind(stuck, address(next));
        assertEq(editions.editionOf(stuck).minter, address(next));
        // The removed minter no longer seals: an open edition with copies waits for the rebind
        // too, and keeps its copies through it.
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, live, address(sale))
        );
        sale.seal(address(editions), live, 1);
        editions.rebind(live, address(next));
        assertEq(editions.editionOf(live).minter, address(next));
        assertEq(editions.editionOf(live).minted, 1);
    }
}
