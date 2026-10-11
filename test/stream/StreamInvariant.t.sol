// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { IWorkRecords } from "src/stream/IWorkRecords.sol";
import { MockRenderer } from "../mocks/stream/StreamMocks.sol";
import { RecordsFixture } from "./RecordsFixture.sol";
import { StreamHandler } from "./StreamHandler.sol";

/// @notice Stateful invariants of 6529 Stream and its records satellite: supply accounting,
///         token-ID monotonicity and no reuse, royalty terms that move only with consent,
///         and finalized records that never change.
contract StreamInvariantTest is RecordsFixture {
    uint256 internal constant ITEMS = 40;

    StreamHandler internal handler;
    uint256 internal lastMinted;

    function setUp() public override {
        super.setUp();
        MockRenderer second = new MockRenderer("second");
        handler = new StreamHandler(
            stream,
            records,
            auction,
            artistKey,
            collaboratorKey,
            governor,
            platform,
            renderer,
            second
        );
        for (uint256 i; i < ITEMS; ++i) {
            handler.addItem(_recordsItem(i, i % 2 == 0));
        }
        for (uint256 i; i < 4; ++i) {
            handler.addSpareRecord(_record(1000 + i));
        }
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.burn.selector;
        selectors[2] = handler.deliver.selector;
        selectors[3] = handler.transfer.selector;
        selectors[4] = handler.register.selector;
        selectors[5] = handler.setRecord.selector;
        selectors[6] = handler.finalize.selector;
        selectors[7] = handler.attackFinalized.selector;
        selectors[8] = handler.changeRoyalty.selector;
        selectors[9] = handler.forceRoyalty.selector;
        selectors[10] = handler.swapRenderer.selector;
        selectors[11] = handler.addLocator.selector;
        selectors[12] = handler.warp.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// @dev Live supply is minted minus burned, and equals the sum of all balances.
    function invariant_supplyIsMintedMinusBurned() public view {
        assertEq(stream.totalMinted(), handler.ghostMinted());
        assertEq(stream.totalSupply(), handler.ghostMinted() - handler.ghostBurned());
        uint256 held = stream.balanceOf(address(auction));
        for (uint256 i; i < handler.actorCount(); ++i) {
            held += stream.balanceOf(handler.actors(i));
        }
        assertEq(held, stream.totalSupply());
    }

    /// @dev IDs are assigned in order, never skipped at mint, and burned IDs stay dead.
    function invariant_idsMonotonicAndNeverReused() public {
        uint256 minted = stream.totalMinted();
        assertGe(minted, lastMinted);
        lastMinted = minted;
        assertEq(handler.violations(), 0);
        for (uint256 id = 1; id <= minted; ++id) {
            assertTrue(stream.itemHashOf(id) != bytes32(0));
            if (handler.burned(id)) {
                vm.expectRevert(
                    abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id)
                );
                stream.ownerOf(id);
            }
        }
        assertEq(stream.itemHashOf(minted + 1), bytes32(0));
    }

    /// @dev The royalty receiver never changes after mint; the rate changes only through the
    ///      consented, governed path the handler tracks.
    function invariant_royaltyTermsLocked() public view {
        uint256 minted = stream.totalMinted();
        for (uint256 id = 1; id <= minted; ++id) {
            if (handler.burned(id)) continue;
            (address receiver, uint32 rate) = stream.royaltyOf(id);
            assertEq(receiver, handler.ghostReceiver(id));
            assertEq(rate, handler.ghostRate(id));
        }
    }

    /// @dev A finalized work keeps its record file and renderer pin.
    function invariant_finalizedRecordsImmutable() public view {
        uint256 minted = stream.totalMinted();
        for (uint256 id = 1; id <= minted; ++id) {
            if (handler.burned(id) || !handler.finalized(id)) continue;
            IWorkRecords.RecordState memory s = records.recordState(id);
            (bytes32 record, address pinned) = handler.finalSnapshot(id);
            assertTrue(s.finalized);
            assertEq(s.record, record);
            assertEq(s.renderer, pinned);
            assertEq(stream.rendererOf(id), pinned);
        }
    }
}
