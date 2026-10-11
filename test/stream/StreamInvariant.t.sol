// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { MockRenderer } from "../mocks/stream/StreamMocks.sol";
import { RecordsFixture } from "./RecordsFixture.sol";
import { StreamHandler } from "./StreamHandler.sol";

/// @notice Stateful invariants of 6529 Stream and its records satellite: supply accounting,
///         token-ID monotonicity and no reuse, per-collection serials, royalty terms that move
///         only with fresh consent, and finalized records that never change.
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
            MediaFile[] memory media = _single(i, i % 2 == 0);
            handler.addItem(_recordsItem(i, media), media);
        }
        for (uint256 i; i < 4; ++i) {
            handler.addSpareRecord(_record(1000 + i));
        }
        handler.addCollection(collectionId);
        vm.startPrank(platform);
        handler.addCollection(stream.createCollection("Second", keccak256("second")));
        handler.addCollection(stream.createCollection("Third", keccak256("third")));
        vm.stopPrank();
        address[] memory sellers = new address[](2);
        sellers[0] = seller;
        sellers[1] = makeAddr("secondSeller");
        handler.setEconomics(econ, ISplitFactory(address(splitFactory)), feeRecipient, sellers);
        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.burn.selector;
        selectors[2] = handler.deliver.selector;
        selectors[3] = handler.transfer.selector;
        selectors[4] = handler.openRecord.selector;
        selectors[5] = handler.setRecord.selector;
        selectors[6] = handler.finalize.selector;
        selectors[7] = handler.attackFinalized.selector;
        selectors[8] = handler.changeRoyalty.selector;
        selectors[9] = handler.forceRoyalty.selector;
        selectors[10] = handler.swapRenderer.selector;
        selectors[11] = handler.addLocator.selector;
        selectors[12] = handler.warp.selector;
        selectors[13] = handler.settle.selector;
        selectors[14] = handler.forgeSettle.selector;
        selectors[15] = handler.replayRoyalty.selector;
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
            if (handler.burned(id)) {
                vm.expectRevert(
                    abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id)
                );
                stream.ownerOf(id);
            }
        }
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, minted + 1));
        stream.work(minted + 1);
    }

    /// @dev The royalty receiver is the one the handler derived from the mint's fee terms
    ///      with the real split factory, and never changes; the rate changes only through the
    ///      consented, governed path the handler tracks (replayed consents never apply).
    function invariant_royaltyTermsLocked() public view {
        uint256 minted = stream.totalMinted();
        for (uint256 id = 1; id <= minted; ++id) {
            if (handler.burned(id)) continue;
            (address receiver, uint256 amount) = stream.royaltyInfo(id, 1 ether);
            assertEq(receiver, handler.ghostReceiver(id));
            assertEq(stream.work(id).royaltyReceiver, handler.ghostReceiver(id));
            assertEq(stream.work(id).royaltyRate, handler.ghostRate(id));
            assertEq(amount, uint256(handler.ghostRate(id)) * 1 ether / 100_000);
        }
        assertEq(handler.violations(), 0);
    }

    /// @dev Each collection numbers its works 1, 2, 3, ... in mint order, independently of
    ///      the global IDs, and its count never drops on a burn.
    function invariant_serialsPerCollection() public view {
        for (uint256 i; i < handler.collectionCount(); ++i) {
            uint256 c = handler.collections(i);
            assertEq(stream.collection(c).minted, handler.ghostCollectionMinted(c));
        }
        uint256 minted = stream.totalMinted();
        for (uint256 id = 1; id <= minted; ++id) {
            if (handler.burned(id)) continue;
            IStream.WorkCore memory w = stream.work(id);
            assertEq(w.collectionId, handler.ghostCollection(id));
            assertEq(w.serial, handler.ghostSerial(id));
        }
    }

    /// @dev Only the minting adapter's mark settles a primary sale; transfers never do.
    function invariant_primarySaleSettledOnlyByMintingAdapter() public view {
        uint256 minted = stream.totalMinted();
        for (uint256 id = 1; id <= minted; ++id) {
            bool expected = !handler.burned(id) && handler.settled(id);
            assertEq(stream.primarySaleSettled(id), expected);
        }
    }

    /// @dev A finalized work keeps its record file and renderer pin.
    function invariant_finalizedRecordsImmutable() public view {
        uint256 minted = stream.totalMinted();
        for (uint256 id = 1; id <= minted; ++id) {
            if (handler.burned(id) || !handler.finalized(id)) continue;
            IWorkRecords.RecordInfo memory info = records.record(id);
            (bytes32 recordFileId, address pinned) = handler.finalSnapshot(id);
            assertTrue(info.finalized);
            assertEq(info.recordFileId, recordFileId);
            assertEq(info.renderer, pinned);
            assertEq(stream.rendererOf(id), pinned);
        }
    }
}
