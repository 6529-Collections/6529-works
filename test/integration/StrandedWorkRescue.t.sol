// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { console2 } from "forge-std/console2.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { PrimaryOutcome } from "src/interfaces/types/SaleTypes.sol";
import { HostileActor } from "../mocks/sales/AuctionMocks.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Owner decision 20 on the real genesis deployment: governance may move a work stranded
///         in a removed sale adapter's custody to the museum, and nothing else. A work is
///         stranded only while its primary sale never settled, its minting adapter still holds
///         it, and that adapter was removed at least 90 days earlier and not admitted again. The
///         rescue is SUCCESSOR_SETTER (30 days), goes to the economics resolver's museum only,
///         settles the work as UNBID, and leaves the stranded adapter nothing it can do with it.
contract StrandedWorkRescueTest is IntegrationBase {
    address internal artist;
    address internal collector = makeAddr("rescueCollector");
    bytes32 internal root;
    uint256 internal constant RESCUE_DELAY = 90 days;

    function setUp() public override {
        super.setUp();
        artist = _actor("rescueArtist");
        Work[] memory works = new Work[](4);
        for (uint256 i; i < works.length; ++i) {
            works[i] = _work(artist, collectionId);
        }
        root = _publish(works);
        _keep(root, works);
    }

    // ------------------------------------------------------------------------ helpers

    function _startItem(uint256 index) internal returns (uint256 saleId, uint256 tokenId) {
        (saleId, tokenId) = _start(root, _package(root), index);
    }

    /// @dev Governance removes or admits the English auction as a Stream minter (30 days);
    ///      returns when the change took effect.
    function _setAuctionAdmitted(bool admitted) internal returns (uint256 at) {
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.setAdmittedMinter, (address(auction), admitted))
        );
        at = block.timestamp;
    }

    /// @dev Schedules `call` on Stream as the hot admin now, waits out its delay and executes
    ///      it; a failed operation is cancelled, so the same call can be scheduled again.
    function _governed(bytes memory call) internal returns (bool ok, bytes memory reason) {
        (, uint32 delay) = manager.canCall(hotAdmin, address(stream), bytes4(call));
        assertEq(delay, 30 days, "the successor class");
        vm.prank(hotAdmin);
        manager.schedule(address(stream), call, 0);
        vm.warp(block.timestamp + delay);
        vm.prank(hotAdmin);
        try manager.execute(address(stream), call) {
            ok = true;
        } catch (bytes memory r) {
            reason = r;
            vm.prank(hotAdmin);
            manager.cancel(hotAdmin, address(stream), call);
        }
    }

    function _rescueCall(uint256 tokenId) internal view returns (bytes memory) {
        return abi.encodeCall(stream.rescueToMuseum, (tokenId));
    }

    /// @dev The rescue is refused with `WorkNotRescuable(tokenId)` and nothing moves.
    function _assertRefused(uint256 tokenId) internal {
        address holder = stream.ownerOf(tokenId);
        (PrimaryOutcome before,,) = stream.primarySale(tokenId);
        (bool ok, bytes memory reason) = _governed(_rescueCall(tokenId));
        assertFalse(ok, "refused");
        assertEq(reason, abi.encodeWithSelector(IStream.WorkNotRescuable.selector, tokenId));
        assertEq(stream.ownerOf(tokenId), holder, "not moved");
        (PrimaryOutcome after_,,) = stream.primarySale(tokenId);
        assertEq(uint8(after_), uint8(before), "outcome unchanged");
    }

    // -------------------------------------------------------------------------- tests

    /// @dev The happy path: 90 days after its removal, the auction's unsettled work moves to
    ///      the museum, recorded UNBID, with `Transfer` then `WorkRescued`. The old adapter can
    ///      then neither settle nor burn it, and the auction's own settlement reverts.
    function test_Rescue_MovesAStrandedWorkToTheMuseum() public {
        (uint256 saleId, uint256 tokenId) = _startItem(0);
        uint256 removedAt = _setAuctionAdmitted(false);
        vm.warp(removedAt + RESCUE_DELAY - 30 days);

        bytes memory call = _rescueCall(tokenId);
        vm.prank(hotAdmin);
        manager.schedule(address(stream), call, 0);
        vm.warp(block.timestamp + 30 days);
        vm.expectEmit(address(stream));
        emit IERC721.Transfer(address(auction), museum, tokenId);
        vm.expectEmit(address(stream));
        emit IStream.WorkRescued(tokenId, address(auction), museum);
        vm.prank(hotAdmin);
        uint256 gasBefore = gasleft();
        manager.execute(address(stream), call);
        console2.log("rescueToMuseum through the manager, execution gas", gasBefore - gasleft());

        assertEq(stream.ownerOf(tokenId), museum, "in the museum");
        (PrimaryOutcome outcome, address currency, uint256 price) = stream.primarySale(tokenId);
        assertEq(uint8(outcome), uint8(PrimaryOutcome.UNBID), "recorded UNBID");
        assertEq(currency, address(0));
        assertEq(price, 0);
        assertTrue(stream.primarySaleSettled(tokenId));

        // The stranded adapter can do nothing more with it.
        vm.startPrank(address(auction));
        vm.expectRevert(abi.encodeWithSelector(IStream.SaleAlreadySettled.selector, tokenId));
        stream.settlePrimary(tokenId, PrimaryOutcome.UNBID, address(0), address(0), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC721Errors.ERC721IncorrectOwner.selector, address(auction), tokenId, museum
            )
        );
        stream.burn(tokenId, 1);
        vm.stopPrank();
        vm.expectRevert();
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), museum, "still in the museum");
        // And a second rescue is refused: the work is settled now.
        _assertRefused(tokenId);
    }

    /// @dev The 90 days run from the removal: one second short is refused, the boundary passes.
    function test_Rescue_RefusesAnAdapterRemovedLessThan90DaysAgo() public {
        (, uint256 tokenId) = _startItem(0);
        uint256 removedAt = _setAuctionAdmitted(false);
        // Executed 30 days after the removal: refused.
        _assertRefused(tokenId);
        // Executed one second before the 90 days: refused.
        vm.warp(removedAt + RESCUE_DELAY - 30 days - 1);
        _assertRefused(tokenId);
        // Executed exactly 90 days after: moved.
        vm.warp(removedAt + RESCUE_DELAY - 30 days);
        (bool ok,) = _governed(_rescueCall(tokenId));
        assertTrue(ok, "at the boundary");
        assertEq(stream.ownerOf(tokenId), museum);
    }

    /// @dev An adapter governance never removed, or removed and admitted again, strands nothing:
    ///      however long its work waits, the rescue is refused.
    function test_Rescue_RefusesAnAdapterNeverRemovedOrAdmittedAgain() public {
        (, uint256 tokenId) = _startItem(0);
        vm.warp(block.timestamp + 365 days);
        _assertRefused(tokenId);

        (, uint256 second) = _startItem(1);
        _setAuctionAdmitted(false);
        _setAuctionAdmitted(true);
        vm.warp(block.timestamp + 365 days);
        _assertRefused(second);
    }

    /// @dev A settled work is never rescued, even 90 days after its adapter's removal: an unbid
    ///      work already in the museum, a sold work delivered to its collector, and a sold work
    ///      whose delivery is pending, which the removed adapter still holds.
    function test_Rescue_RefusesSettledAndSoldWorks() public {
        (uint256 unbidSale, uint256 unbid) = _startItem(0);
        _settleAtEnd(unbidSale);
        assertEq(stream.ownerOf(unbid), museum);

        (uint256 soldSale, uint256 sold) = _startItem(1);
        _ethBid(soldSale, collector, 1 ether);
        _settleAtEnd(soldSale);
        assertEq(stream.ownerOf(sold), collector);

        HostileActor refuser = new HostileActor();
        refuser.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.REVERT);
        (uint256 pendingSale, uint256 pending) = _startItem(2);
        vm.deal(address(refuser), 1 ether);
        _ethBid(pendingSale, address(refuser), 1 ether);
        _settleAtEnd(pendingSale);
        assertEq(stream.ownerOf(pending), address(auction), "delivery pending");
        (PrimaryOutcome outcome,,) = stream.primarySale(pending);
        assertEq(uint8(outcome), uint8(PrimaryOutcome.SOLD));

        uint256 removedAt = _setAuctionAdmitted(false);
        vm.warp(removedAt + RESCUE_DELAY);
        _assertRefused(unbid);
        _assertRefused(sold);
        _assertRefused(pending);
    }

    /// @dev A work its minting adapter no longer holds is never rescued: the collector's work
    ///      stays the collector's, whatever the adapter's state. A work the removed adapter
    ///      handed to someone else unsettled is not stranded either.
    function test_Rescue_RefusesAWorkNotHeldByItsAdapter() public {
        (uint256 saleId, uint256 sold) = _startItem(0);
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);

        (, uint256 handed) = _startItem(1);
        vm.prank(address(auction));
        stream.transferFrom(address(auction), collector, handed);
        (PrimaryOutcome outcome,,) = stream.primarySale(handed);
        assertEq(uint8(outcome), uint8(PrimaryOutcome.NONE), "never settled");

        uint256 removedAt = _setAuctionAdmitted(false);
        vm.warp(removedAt + RESCUE_DELAY);
        _assertRefused(sold);
        _assertRefused(handed);
        assertEq(stream.ownerOf(handed), collector, "still the collector's");
    }

    /// @dev The destination is the museum the economics resolver names when the rescue runs,
    ///      never the caller's: the call takes only the token ID, and calldata carrying another
    ///      address after it changes nothing.
    function test_Rescue_GoesToTheMuseumOnly() public {
        (, uint256 tokenId) = _startItem(0);
        uint256 removedAt = _setAuctionAdmitted(false);
        vm.warp(removedAt + RESCUE_DELAY);
        address elsewhere = makeAddr("elsewhere");
        bytes memory call = abi.encodePacked(_rescueCall(tokenId), abi.encode(elsewhere));
        (bool ok,) = _governed(call);
        assertTrue(ok);
        assertEq(stream.ownerOf(tokenId), economics.museum(), "the museum");
        assertEq(stream.balanceOf(elsewhere), 0, "never elsewhere");
        assertEq(IStream.rescueToMuseum.selector, bytes4(keccak256("rescueToMuseum(uint256)")));
    }

    /// @dev The rescue is governed: SUCCESSOR_SETTER in the 30-day class, and no one else.
    function test_Rescue_IsTheSuccessorClass() public {
        (, uint256 tokenId) = _startItem(0);
        (bool immediate, uint32 delay) =
            manager.canCall(hotAdmin, address(stream), IStream.rescueToMuseum.selector);
        assertFalse(immediate);
        assertEq(delay, 30 days);
        vm.prank(collector);
        vm.expectRevert();
        stream.rescueToMuseum(tokenId);
        vm.prank(guardian1);
        vm.expectRevert();
        stream.rescueToMuseum(tokenId);
    }
}
