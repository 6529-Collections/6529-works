// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { MintFacts, Outcome, Slots, Work } from "src/interfaces/core/CoreTypes.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { HostileModule, MockSale } from "../mocks/core/CoreMocks.sol";
import { IndependentTokenFixture } from "./IndependentTokenFixture.sol";

/// @notice An Independent Stream gate or accounts module that lies, reverts or burns all its gas.
contract HostileGate {
    enum Mode {
        LIE,
        REVERT,
        BURN_GAS
    }

    Mode public mode;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function _act() internal view {
        if (mode == Mode.REVERT) revert("hostile");
        if (mode == Mode.BURN_GAS) {
            uint256 x;
            while (true) {
                ++x;
            }
        }
    }

    function canMint(address, address) external view returns (bool) {
        _act();
        return true;
    }

    function wasMinter(address) external view returns (bool) {
        _act();
        return true;
    }

    function minterRemovedAt(address) external view returns (uint256) {
        _act();
        return 1;
    }

    function feeShareOf(address) external view returns (uint32) {
        _act();
        return type(uint32).max;
    }

    function isWallet(uint256, address) external view returns (bool) {
        _act();
        return true;
    }
}

/// @notice Hostile modules in every seam position an Independent Stream token faces: the
///         Independent Stream gate, the accounts module, the shared TERMS and RECORDS modules, the
///         renderer, and a re-entering receiver. Pass condition: no token moves, no fact changes,
///         no balance changes; `ownerOf` and transfers keep working.
contract IndependentHostileTest is IndependentTokenFixture {
    HostileGate internal hostileGate;
    HostileModule internal hostile;
    uint256 internal sold;
    uint256 internal held;
    uint256 internal direct;
    bytes32 internal soldFacts;

    function setUp() public override {
        super.setUp();
        sold = _fsell(1, collector); // SOLD, a collector holds it
        held = _fmint(2); // in the sale's custody, no outcome
        direct = sale.mintTo(address(fs), stranger, _ffacts(3)); // no outcome, a collector holds it
        soldFacts = keccak256(abi.encode(fs.workOf(sold)));
        hostileGate = new HostileGate();
        hostile = new HostileModule();
    }

    function _install(bytes32 slot, address module) internal {
        directory.proposeModule(slot, module);
        vm.warp(block.timestamp + directory.moduleDelay());
        directory.activateModule(slot);
    }

    /// @dev Nothing a collector holds moved, no fact changed, balances are the same, and the
    ///      collector can still transfer.
    function _assertHeld() internal {
        assertEq(fs.ownerOf(sold), collector, "sold token moved");
        assertEq(fs.ownerOf(direct), stranger, "collector's unsold token moved");
        assertEq(fs.ownerOf(held), address(sale), "the sale's token moved");
        assertEq(keccak256(abi.encode(fs.workOf(sold))), soldFacts, "a fact changed");
        assertEq(uint8(fs.workOf(sold).outcome), uint8(Outcome.SOLD));
        assertEq(uint8(fs.workOf(direct).outcome), uint8(Outcome.NONE));
        assertEq(fs.balanceOf(collector), 1);
        assertEq(fs.balanceOf(stranger), 1);
        vm.prank(collector);
        fs.transferFrom(collector, address(0xBEEF), sold);
        assertEq(fs.ownerOf(sold), address(0xBEEF));
        vm.prank(address(0xBEEF));
        fs.transferFrom(address(0xBEEF), collector, sold);
    }

    // ---------------------------------------------------------------------- the gate

    /// A lying gate lets a junk contract mint junk, and nothing more.
    function test_LyingGate_MintsJunkButReachesNoHeldToken() public {
        _install(Slots.INDEPENDENT_STREAM, address(hostileGate));
        assertTrue(fs.isMinter(address(hostile)));
        MintFacts memory f = _ffacts(9);
        (bool minted,) =
            hostile.exec(address(fs), abi.encodeCall(IStream.mint, (address(hostile), f)));
        assertTrue(minted, "junk is minted: the gate decides who mints");
        assertTrue(fs.hasMinted(address(hostile)));

        assertEq(hostile.attack(address(fs), sold, collector), 0, "reached a sold token");
        assertEq(hostile.attack(address(fs), direct, stranger), 0, "reached a collector's token");
        assertEq(hostile.attack(address(fs), held, address(sale)), 0, "reached the sale's token");
        // The network cannot be led to rescue a collector's token either.
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, direct));
        fs.rescue(direct, address(this));
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, sold));
        fs.rescue(sold, address(this));
        _assertHeld();
    }

    function test_RevertingGate_StopsMintingOnly() public {
        _install(Slots.INDEPENDENT_STREAM, address(hostileGate));
        hostileGate.setMode(HostileGate.Mode.REVERT);
        vm.expectRevert("hostile");
        _fmint(4);
        // The sale still finishes what it started; nothing held moves.
        sale.record(address(fs), held, true, collector, 1 ether);
        assertEq(uint8(fs.workOf(held).outcome), uint8(Outcome.SOLD));
        _assertHeld();
    }

    function test_GasBurningGate_RevertsTheMintAndNothingElse() public {
        _install(Slots.INDEPENDENT_STREAM, address(hostileGate));
        hostileGate.setMode(HostileGate.Mode.BURN_GAS);
        (bool ok,) = address(sale).call{ gas: 2_000_000 }(
            abi.encodeCall(MockSale.mint, (address(fs), _ffacts(4)))
        );
        assertFalse(ok, "a gas shortfall never reads as an answer");
        assertEq(fs.totalMinted(), 3);
        sale.record(address(fs), held, false, address(0), 0);
        _assertHeld();
    }

    // ------------------------------------------------------------------ accounts module

    function test_HostileAccounts_TouchesNoToken() public {
        _install(Slots.ACCOUNTS, address(hostileGate));
        // A lying accounts module makes anyone the artist: the admin surface only.
        vm.prank(address(hostile));
        fs.setContractURI("ipfs://lie");
        assertEq(hostile.attack(address(fs), sold, collector), 0);
        hostileGate.setMode(HostileGate.Mode.REVERT);
        vm.prank(artistWallet);
        vm.expectRevert("hostile");
        fs.setOwner(stranger);
        _fmint(4);
        _assertHeld();
    }

    // ----------------------------------------------------------- TERMS and RECORDS modules

    function test_HostileTerms_ChangesRoyaltiesOnlyWithinTheSeam() public {
        terms.lockRoyaltyRate(address(fs), sold);
        _install(Slots.INDEPENDENT_TERMS, address(hostile));
        assertEq(fs.moduleOf(Slots.TERMS), address(hostile));
        assertEq(hostile.attack(address(fs), sold, collector), 0);
        (bool raised,) = hostile.exec(
            address(fs), abi.encodeCall(IStream.setRoyalty, (sold, address(hostile), 99_999))
        );
        assertFalse(raised, "a locked rate changed");
        (bool redirected,) = hostile.exec(
            address(fs), abi.encodeCall(IStream.setRoyalty, (sold, address(hostile), 6529))
        );
        assertTrue(redirected, "the receiver is the TERMS module's to set");
        Work memory w = fs.workOf(sold);
        assertEq(w.royaltyRate, 6529);
        assertTrue(w.royaltyRateLocked);
        assertEq(fs.ownerOf(sold), collector);
    }

    function test_HostileRecords_ReachesNoToken() public {
        _install(Slots.INDEPENDENT_RECORDS, address(hostile));
        assertEq(fs.moduleOf(Slots.RECORDS), address(hostile));
        assertEq(hostile.attack(address(fs), sold, collector), 0);
        assertEq(hostile.attack(address(fs), held, address(sale)), 0);
        _assertHeld();
    }

    // ------------------------------------------------------------------------ renderer

    function test_HostileRenderer_BreaksTokenURIOnly() public {
        fs.setModuleDelay(0);
        vm.startPrank(artistWallet);
        fs.proposeModule(Slots.RENDERER, address(hostile));
        vm.stopPrank();
        fs.activateModule(Slots.RENDERER);
        assertEq(fs.tokenURI(sold), "data:,a lie");
        hostile.setMode(HostileModule.Mode.REVERT);
        vm.expectRevert("hostile");
        fs.tokenURI(sold);
        hostile.setMode(HostileModule.Mode.BURN_GAS);
        (bool ok,) = address(fs).call{ gas: 1_000_000 }(abi.encodeCall(fs.tokenURI, (sold)));
        assertFalse(ok);
        _assertHeld();
    }

    // ------------------------------------------------------------- re-entering receiver

    function test_ReenteringReceiver_CannotBurnOrRecord() public {
        uint256 id = _fmint(4);
        sale.record(address(fs), id, true, address(hostile), 1 ether);
        hostile.arm(address(fs), id);
        vm.prank(address(sale));
        fs.safeTransferFrom(address(sale), address(hostile), id);
        assertEq(hostile.reentered(), 0);
        assertEq(fs.ownerOf(id), address(hostile));
        assertEq(uint8(fs.workOf(id).outcome), uint8(Outcome.SOLD));
    }

    // ------------------------------------------------------------------------ editions

    function test_LyingGate_EditionsMintJunkButNeverPastASealOrAnothersCopies() public {
        sale.createEdition(address(fe), sold, 3, address(0xFEE), 700);
        sale.mintEdition(address(fe), collector, sold, 2, 1 ether);
        sale.seal(address(fe), sold, 2);
        _install(Slots.INDEPENDENT_STREAM, address(hostileGate));
        // Junk: a new edition of a live master by the junk contract.
        (bool created,) = hostile.exec(
            address(fe), abi.encodeCall(IEditions.create, (held, 0, address(hostile), 0))
        );
        assertTrue(created);
        // Never another minter's edition, never past a seal, never a holder's copies.
        (bool a,) = hostile.exec(
            address(fe), abi.encodeCall(IEditions.mint, (address(hostile), sold, 1, 0))
        );
        (bool b,) = hostile.exec(address(fe), abi.encodeCall(IEditions.seal, (sold, 3)));
        (bool c,) = hostile.exec(
            address(fe),
            abi.encodeCall(IERC1155.safeTransferFrom, (collector, address(hostile), sold, 1, ""))
        );
        (bool d,) =
            hostile.exec(address(fe), abi.encodeCall(IEditions.rebind, (sold, address(hostile))));
        assertFalse(a || b || c || d);
        vm.expectRevert(abi.encodeWithSelector(IEditions.SupplyExceeded.selector, sold));
        sale.mintEdition(address(fe), collector, sold, 1, 1 ether);
        assertEq(fe.balanceOf(collector, sold), 2);
        assertEq(fe.editionOf(sold).maxSupply, 2);
        // The holder still transfers.
        vm.prank(collector);
        fe.safeTransferFrom(collector, stranger, sold, 1, "");
        assertEq(fe.balanceOf(stranger, sold), 1);
        assertEq(IERC721(address(fs)).ownerOf(sold), collector);
    }
}
