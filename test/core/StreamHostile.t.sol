// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { MintFacts, Outcome, Slots, Work } from "src/interfaces/core/CoreTypes.sol";
import { IModuleSlots, IModules } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { CoreFixture } from "../mocks/core/CoreFixture.sol";
import { HostileModule, MockSale } from "../mocks/core/CoreMocks.sol";
import { SafeDeliverySale } from "../mocks/core/StreamCoreMocks.sol";

/// @notice The hostile-module matrix of the permanent ERC-721: `HostileModule` installed as
///         TERMS, RECORDS and RENDERER, added as a minter (active, pending, removed), and as an
///         ERC-721 receiver that re-enters. In every position it tries every state-changing call
///         of the contract against a collector's sold token. Pass: no token moves, no fact
///         changes, no balance changes, the locked rate holds; `ownerOf` and transfers work.
contract StreamHostileTest is CoreFixture {
    HostileModule internal hostile;
    uint256 internal victim;
    Work internal before;

    // Bits of `_everything`: the calls a position is allowed to succeed at.
    uint256 internal constant LOCK_RATE = 1 << 7;
    uint256 internal constant SAME_RATE = 1 << 8;
    uint256 internal constant MINT = 1 << 18;
    uint256 internal constant METADATA = 1 << 19;

    function setUp() public override {
        super.setUp();
        hostile = new HostileModule();
        victim = _sell(1, collector);
        terms.lockRoyaltyRate(address(stream), victim);
        before = stream.workOf(victim);
    }

    /// @dev Tries every state-changing call of the contract as the hostile module.
    /// @return succeeded A bit per call that did not revert.
    function _everything() internal returns (uint256 succeeded) {
        address h = address(hostile);
        MintFacts memory junk = _facts(900);
        bytes[21] memory calls = [
            abi.encodeCall(IERC721.transferFrom, (collector, h, victim)),
            abi.encodeWithSignature(
                "safeTransferFrom(address,address,uint256)", collector, h, victim
            ),
            abi.encodeCall(IStream.burn, (victim)),
            abi.encodeCall(IStream.recordPrimarySale, (victim, false, address(0), 0)),
            abi.encodeCall(IStream.rescue, (victim, h)),
            abi.encodeCall(IERC721.approve, (h, victim)),
            abi.encodeCall(IStream.setRoyalty, (victim, h, 100_000)),
            abi.encodeCall(IStream.lockRoyaltyRate, (victim)),
            abi.encodeCall(IStream.setRoyalty, (victim, h, before.royaltyRate)),
            abi.encodeCall(IStream.createCollection, ("hostile", 0)),
            abi.encodeCall(IStream.setOwner, (h)),
            abi.encodeCall(IStream.setContractURI, ("hostile")),
            abi.encodeCall(IStream.setRescueDelay, (0)),
            abi.encodeCall(IModuleSlots.setModuleDelay, (0)),
            abi.encodeCall(IModuleSlots.proposeModule, (Slots.TERMS, h)),
            abi.encodeCall(IModuleSlots.removeModule, (Slots.TERMS)),
            abi.encodeCall(IModules.addMinter, (h)),
            abi.encodeCall(IModules.removeMinter, (address(sale))),
            abi.encodeCall(IStream.mint, (h, junk)),
            abi.encodeCall(IStream.emitMetadataUpdate, (victim, victim)),
            abi.encodeCall(IModuleSlots.activateModule, (Slots.TERMS))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = hostile.exec(address(stream), calls[i]);
            if (ok) succeeded |= 1 << i;
        }
        assertEq(hostile.attack(address(stream), victim, collector), 0, "attack");
    }

    /// @dev The victim is untouched (the receiver may change only where TERMS may set it) and
    ///      the collector can still move it.
    function _assertHeld(bool receiverMayChange) internal {
        Work memory w = stream.workOf(victim);
        assertEq(stream.ownerOf(victim), collector, "owner");
        assertEq(stream.balanceOf(collector), 1, "balance");
        assertEq(stream.getApproved(victim), address(0), "approval");
        assertEq(w.itemHash, before.itemHash, "itemHash");
        assertEq(w.artistId, before.artistId, "artistId");
        assertEq(w.collectionId, before.collectionId, "collectionId");
        assertEq(w.serial, before.serial, "serial");
        assertEq(w.kind, before.kind, "kind");
        assertEq(w.seedPolicy, before.seedPolicy, "seedPolicy");
        assertEq(w.seed, before.seed, "seed");
        assertEq(uint8(w.outcome), uint8(Outcome.SOLD), "outcome");
        assertEq(w.royaltyRate, before.royaltyRate, "locked rate");
        assertTrue(w.royaltyRateLocked, "lock");
        if (!receiverMayChange) assertEq(w.royaltyReceiver, before.royaltyReceiver, "receiver");
        assertEq(stream.owner(), marketOwner, "market owner");
        assertEq(stream.moduleDelay(), 7 days, "module delay");
        assertEq(stream.rescueDelay(), 14 days, "rescue delay");
        assertTrue(stream.isMinter(address(sale)), "sale still a minter");
        vm.prank(collector);
        stream.transferFrom(collector, address(0xB0B), victim);
        assertEq(stream.ownerOf(victim), address(0xB0B));
        vm.prank(address(0xB0B));
        stream.transferFrom(address(0xB0B), collector, victim);
    }

    function _install(bytes32 slot) internal {
        stream.proposeModule(slot, address(hostile));
        skip(7 days);
        stream.activateModule(slot);
    }

    function test_Hostile_AsTerms() public {
        _install(Slots.TERMS);
        assertEq(_everything(), LOCK_RATE | SAME_RATE | METADATA);
        _assertHeld(true);
        assertEq(stream.workOf(victim).royaltyReceiver, address(hostile));
    }

    function test_Hostile_AsRecords() public {
        _install(Slots.RECORDS);
        assertEq(_everything(), METADATA);
        _assertHeld(false);
    }

    function test_Hostile_AsRenderer() public {
        _install(Slots.RENDERER);
        assertEq(_everything(), 0);
        _assertHeld(false);
        // It lies: the lie is shown (the network installed it), nothing else follows.
        assertEq(stream.tokenURI(victim), "data:,a lie");
        // It reverts or burns its gas: only `tokenURI` fails, at any gas.
        hostile.setMode(HostileModule.Mode.REVERT);
        vm.expectRevert("hostile");
        stream.tokenURI(victim);
        hostile.setMode(HostileModule.Mode.BURN_GAS);
        (bool ok,) = address(stream).call{ gas: 2_000_000 }(
            abi.encodeWithSignature("tokenURI(uint256)", victim)
        );
        assertFalse(ok);
        (address receiver, uint256 amount) = stream.royaltyInfo(victim, 100_000);
        assertEq(receiver, before.royaltyReceiver);
        assertEq(amount, before.royaltyRate);
        _assertHeld(false);
    }

    function test_Hostile_AsActiveMinter() public {
        stream.addMinter(address(hostile));
        skip(7 days);
        // It may mint junk (a new token in its custody); nothing else.
        assertEq(_everything(), MINT);
        _assertHeld(false);
        assertEq(stream.ownerOf(2), address(hostile));
        // Junk cannot take a live work's content.
        MintFacts memory f = _facts(901);
        f.contentHash = _facts(1).contentHash;
        (bool ok,) =
            hostile.exec(address(stream), abi.encodeCall(IStream.mint, (address(hostile), f)));
        assertFalse(ok);
    }

    function test_Hostile_AsPendingMinter() public {
        stream.addMinter(address(hostile));
        assertEq(_everything(), 0);
        _assertHeld(false);
    }

    function test_Hostile_AsRemovedMinter() public {
        stream.addMinter(address(hostile));
        skip(7 days);
        (, bytes memory ret) = hostile.exec(
            address(stream), abi.encodeCall(IStream.mint, (address(hostile), _facts(5)))
        );
        uint256 own = abi.decode(ret, (uint256));
        stream.removeMinter(address(hostile));
        assertEq(_everything(), 0);
        _assertHeld(false);
        // It still finishes what it holds, and only that.
        (bool ok,) = hostile.exec(
            address(stream), abi.encodeCall(IStream.recordPrimarySale, (own, false, address(0), 0))
        );
        assertTrue(ok);
    }

    /// @dev Every position at once.
    function test_Hostile_EverywhereAtOnce() public {
        stream.proposeModule(Slots.TERMS, address(hostile));
        stream.proposeModule(Slots.RECORDS, address(hostile));
        stream.proposeModule(Slots.RENDERER, address(hostile));
        stream.addMinter(address(hostile));
        skip(7 days);
        stream.activateModule(Slots.TERMS);
        stream.activateModule(Slots.RECORDS);
        stream.activateModule(Slots.RENDERER);
        assertEq(_everything(), LOCK_RATE | SAME_RATE | MINT | METADATA);
        _assertHeld(true);
    }

    /// @dev A buyer's receiver hook that re-enters `burn` and `recordPrimarySale` changes nothing.
    function test_Hostile_ReceiverReentersOnDelivery() public {
        SafeDeliverySale safeSale = new SafeDeliverySale();
        MockSale minter = new MockSale();
        stream.addMinter(address(minter));
        skip(7 days);
        uint256 id = minter.mintTo(address(stream), address(safeSale), _facts(2));
        // The safe-delivery sale is a minter too, so it can record.
        stream.addMinter(address(safeSale));
        skip(7 days);
        vm.prank(address(safeSale));
        stream.recordPrimarySale(id, true, address(hostile), 1 ether);
        hostile.arm(address(stream), id);
        safeSale.safeSend(address(stream), id, address(hostile));
        assertEq(hostile.reentered(), 0);
        assertEq(stream.ownerOf(id), address(hostile));
        assertEq(uint8(stream.workOf(id).outcome), uint8(Outcome.SOLD));
        assertEq(stream.totalBurned(), 0);
    }

    /// @dev `mint` and `rescue` use no receiver callback: an armed receiver never runs.
    function test_Hostile_ReceiverIsNeverCalledByMintOrRescue() public {
        hostile.arm(address(stream), 2);
        uint256 id = sale.mintTo(address(stream), address(hostile), _facts(2));
        assertEq(id, 2);
        uint256 held = _mint(3);
        stream.removeMinter(address(sale));
        skip(14 days);
        hostile.arm(address(stream), held);
        stream.rescue(held, address(hostile));
        assertEq(hostile.reentered(), 0);
        assertEq(stream.ownerOf(held), address(hostile));
    }

    /// @dev With the hostile module removed from every position, it can do nothing at all.
    function test_Hostile_RemovedFromEveryPosition() public {
        test_Hostile_EverywhereAtOnce();
        stream.removeModule(Slots.TERMS);
        stream.removeModule(Slots.RECORDS);
        stream.removeModule(Slots.RENDERER);
        stream.removeMinter(address(hostile));
        before = stream.workOf(victim);
        assertEq(_everything(), 0);
        _assertHeld(false);
    }
}
