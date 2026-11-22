// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Stream6529 } from "src/core/Stream6529.sol";
import { MintFacts, PendingModule, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IModules, IModuleSlots } from "src/interfaces/core/IModules.sol";
import { MockRenderer, MockSale, MockTerms } from "../mocks/core/CoreMocks.sol";
import { MockPinnedFacts } from "../mocks/core/StreamCoreMocks.sol";

/// @notice Halmos proofs on the module seam (`src/core/Modules.sol`), run through the real
///         `Stream6529` behind a real AccessManager whose admin is this test: a module or a minter
///         becomes active only once the delay in force when it was announced has passed, a later
///         change of the delay does not move it, and a removal takes effect in the same block.
///         Run with `FOUNDRY_PROFILE=symbolic halmos --contract ModulesSymbolicTest`.
/// @dev Bounds: any caller, any delay before and after the announcement (48 bits), any wait (48
///      bits) from a fixed start time; the RENDERER slot (every slot is the same code) and one
///      new minter.
contract ModulesSymbolicTest is Test {
    uint256 internal constant T0 = 1_800_000_000;
    bytes32 internal constant CONTENT = keccak256("content");

    AccessManager internal manager;
    Stream6529 internal stream;
    MockSale internal sale;
    MockSale internal next;
    address internal renderer;
    address internal nextRenderer;

    function setUp() public {
        vm.warp(T0);
        manager = new AccessManager(address(this));
        sale = new MockSale();
        next = new MockSale();
        renderer = address(new MockRenderer());
        nextRenderer = address(new MockRenderer());
        address[] memory minters = new address[](1);
        minters[0] = address(sale);
        stream = new Stream6529(
            address(manager),
            address(new MockPinnedFacts()),
            address(0xA),
            renderer,
            address(new MockTerms()),
            address(0),
            minters
        );
        stream.createCollection("Genesis", 0);
    }

    /// @notice Only the admin announces a module; the slot keeps its module until someone (anyone)
    ///         activates the announcement, which succeeds exactly when the delay in force at the
    ///         announcement has passed, whatever the delay was changed to since.
    /// @dev Bounds: any proposer and activator; any delay before (`d1`) and after (`d2`); any wait.
    function check_module_activeOnlyAfterTheDelayAtProposal(
        address proposer,
        address activator,
        uint48 d1,
        uint48 d2,
        uint48 wait
    ) public {
        stream.setModuleDelay(d1);
        vm.prank(proposer);
        (bool proposed,) = address(stream)
            .call(abi.encodeCall(IModuleSlots.proposeModule, (Slots.RENDERER, nextRenderer)));
        assert(proposed == (proposer == address(this) && T0 + d1 <= type(uint48).max));
        if (!proposed) return;
        stream.setModuleDelay(d2);
        vm.warp(T0 + wait);
        assert(stream.moduleOf(Slots.RENDERER) == renderer);
        vm.prank(activator);
        (bool ok,) =
            address(stream).call(abi.encodeCall(IModuleSlots.activateModule, (Slots.RENDERER)));
        assert(ok == (wait >= d1));
        assert(stream.moduleOf(Slots.RENDERER) == (ok ? nextRenderer : renderer));
    }

    /// @notice Only the admin adds a minter; it is a minter, and can mint, exactly once the delay
    ///         in force when it was added has passed, whatever the delay was changed to since.
    /// @dev Bounds: any caller of `addMinter`; any delay before (`d1`) and after (`d2`); any wait.
    function check_minter_activeOnlyAfterTheDelayWhenAdded(
        address adder,
        uint48 d1,
        uint48 d2,
        uint48 wait
    ) public {
        stream.setModuleDelay(d1);
        vm.prank(adder);
        (bool added,) = address(stream).call(abi.encodeCall(IModules.addMinter, (address(next))));
        assert(added == (adder == address(this) && T0 + d1 <= type(uint48).max));
        if (!added) return;
        stream.setModuleDelay(d2);
        vm.warp(T0 + wait);
        bool active = wait >= d1;
        assert(stream.isMinter(address(next)) == active);
        (bool minted,) =
            address(next).call(abi.encodeCall(MockSale.mint, (address(stream), _facts())));
        assert(minted == active);
    }

    /// @notice Only the admin removes; a removed module is gone in the same block, its pending
    ///         announcement with it, and nothing reinstates it later without a new announcement.
    /// @dev Bounds: any remover; any wait after the removal; a module announced before or not.
    function check_moduleRemoval_isImmediate(address remover, bool announced, uint48 wait) public {
        if (announced) {
            stream.setModuleDelay(0);
            stream.proposeModule(Slots.RENDERER, nextRenderer);
        }
        vm.prank(remover);
        (bool ok,) =
            address(stream).call(abi.encodeCall(IModuleSlots.removeModule, (Slots.RENDERER)));
        assert(ok == (remover == address(this)));
        if (!ok) return;
        assert(stream.moduleOf(Slots.RENDERER) == address(0));
        PendingModule memory p = stream.pendingModule(Slots.RENDERER);
        assert(p.module == address(0) && p.readyAt == 0);
        vm.warp(T0 + wait);
        (bool activated,) =
            address(stream).call(abi.encodeCall(IModuleSlots.activateModule, (Slots.RENDERER)));
        assert(!activated);
        assert(stream.moduleOf(Slots.RENDERER) == address(0));
    }

    /// @notice Only the admin removes a minter; an active or still waiting minter stops being one
    ///         in the same block and can no longer mint, at any later time.
    /// @dev Bounds: any remover; any wait after the removal; the genesis minter (active) or a
    ///      minter added with a 7-day delay and removed before it ends (waiting).
    function check_minterRemoval_isImmediate(address remover, bool waiting, uint48 wait) public {
        MockSale m = sale;
        if (waiting) {
            stream.addMinter(address(next));
            m = next;
        }
        vm.prank(remover);
        (bool ok,) = address(stream).call(abi.encodeCall(IModules.removeMinter, (address(m))));
        assert(ok == (remover == address(this)));
        if (!ok) return;
        assert(!stream.isMinter(address(m)));
        vm.warp(T0 + wait);
        assert(!stream.isMinter(address(m)));
        (bool minted,) = address(m).call(abi.encodeCall(MockSale.mint, (address(stream), _facts())));
        assert(!minted);
    }

    function _facts() internal pure returns (MintFacts memory f) {
        f.itemHash = keccak256("item");
        f.contentHash = CONTENT;
        f.artistId = 1;
        f.collectionId = 1;
    }
}
