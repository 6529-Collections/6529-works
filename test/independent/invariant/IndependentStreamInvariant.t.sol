// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Outcome, Work } from "src/interfaces/core/CoreTypes.sol";
import { MockSale } from "../../mocks/core/CoreMocks.sol";
import { IndependentTokenFixture } from "../IndependentTokenFixture.sol";
import { IndependentStreamHandler } from "./IndependentStreamHandler.sol";

/// @notice The permanent ERC-721's invariants run on a `IndependentStream6529` (the same plain
///         token with a different gate), at the repository's invariant settings (256 runs, depth
///         128, `fail_on_revert`). The Independent Stream gate is the handler's to drive, including
///         a lying one.
contract IndependentStreamInvariantTest is IndependentTokenFixture {
    IndependentStreamHandler internal handler;

    function setUp() public override {
        super.setUp();
        MockSale[3] memory sales = [sale, new MockSale(), new MockSale()];
        gate.setMinter(address(fs), address(sales[1]), true);
        gate.setMinter(address(fs), address(sales[2]), true);
        handler = new IndependentStreamHandler(fs, terms, gate, sales);
        // The handler acts as the network (the directory's AccessManager admin).
        manager.grantRole(manager.ADMIN_ROLE(), address(handler), 0);
        targetContract(address(handler));
    }

    /// One live token per content hash, and `tokenOfContent` names it.
    function invariant_OneLiveTokenPerContent() public view {
        for (uint256 c; c < 6; ++c) {
            uint256 live;
            uint256 liveId;
            for (uint256 id = 1; id <= fs.totalMinted(); ++id) {
                if (handler.contentIdx(id) == c && handler.holder(id) != address(0)) {
                    ++live;
                    liveId = id;
                }
            }
            assertLe(live, 1, "two live tokens share a content");
            if (live == 1) assertEq(fs.tokenOfContent(handler.contentHash(c)), liveId);
        }
    }

    /// An outcome leaves NONE once and never changes after.
    function invariant_OutcomeIsRecordedOnce() public view {
        for (uint256 id = 1; id <= fs.totalMinted(); ++id) {
            assertEq(uint8(fs.workOf(id).outcome), uint8(handler.outcome(id)), "outcome");
        }
    }

    /// Token IDs are the `totalMinted` sequence from 1; supply is minted minus burned.
    function invariant_IdsAndSupply() public view {
        assertEq(fs.totalMinted(), handler.mints(), "minted");
        assertEq(fs.totalBurned(), handler.burns(), "burned");
        assertEq(fs.totalSupply(), fs.totalMinted() - fs.totalBurned(), "supply");
        for (uint256 id = 1; id <= fs.totalMinted(); ++id) {
            assertTrue(fs.workOf(id).itemHash != 0, "a gap in the sequence");
        }
        assertEq(fs.workOf(fs.totalMinted() + 1).itemHash, 0, "minted past the count");
    }

    /// Every live token is where the model put it; balances add up to the supply.
    function invariant_OwnersMatchTheModel() public view {
        uint256 sum;
        for (uint256 id = 1; id <= fs.totalMinted(); ++id) {
            address h = handler.holder(id);
            if (h == address(0)) continue;
            assertEq(fs.ownerOf(id), h, "owner");
        }
        for (uint256 i; i < 3; ++i) {
            sum += fs.balanceOf(handler.collectors(i));
            sum += fs.balanceOf(address(handler.sales(i)));
        }
        sum += fs.balanceOf(handler.museum());
        assertEq(sum, fs.totalSupply(), "balances");
    }

    /// The facts fixed at mint never change.
    function invariant_FactsNeverChange() public view {
        for (uint256 id = 1; id <= fs.totalMinted(); ++id) {
            assertEq(handler.hashOf(fs.workOf(id)), handler.factsHash(id), "facts");
        }
    }

    /// A locked royalty rate never changes and stays locked.
    function invariant_LockedRateNeverChanges() public view {
        for (uint256 id = 1; id <= fs.totalMinted(); ++id) {
            if (!handler.rateLocked(id)) continue;
            Work memory w = fs.workOf(id);
            assertTrue(w.royaltyRateLocked, "unlocked");
            assertEq(w.royaltyRate, handler.lockedRate(id), "locked rate");
        }
    }

    /// No call the model refuses ever succeeded, whatever the gate says.
    function invariant_NoRefusedCallSucceeded() public view {
        assertFalse(handler.violation(), handler.violationNote());
    }

    /// A SOLD token is never burned.
    function invariant_SoldTokensStayLive() public view {
        for (uint256 id = 1; id <= fs.totalMinted(); ++id) {
            if (handler.outcome(id) == Outcome.SOLD) {
                assertTrue(handler.holder(id) != address(0), "a sold token burned");
            }
        }
    }

    /// `hasMinted` is exactly the set of sale contracts that minted.
    function invariant_HasMintedMatchesTheModel() public view {
        for (uint256 i; i < 3; ++i) {
            address s = address(handler.sales(i));
            assertEq(fs.hasMinted(s), handler.minted(s), "hasMinted");
            assertFalse(fs.hasMinted(handler.collectors(i)), "a collector minted");
        }
    }

    /// Each action of the handler reaches the state it models.
    function test_HandlerReachesEveryState() public {
        handler.mint(0, 0, 7, false);
        handler.mint(1, 1, 8, false);
        handler.mint(2, 0, 9, false); // content 0 again: refused
        handler.mint(2, 2, 10, true); // token 3 straight to a collector
        assertEq(handler.mints(), 3);
        handler.record(1, true, collector, 1 ether);
        handler.deliver(1, 0);
        handler.collectorTransfer(1, 1);
        handler.attack(1);
        handler.setRoyalty(1, address(0xFEE), 500);
        handler.lockRate(1);
        handler.setRoyalty(1, address(0xFEE), 600); // refused: locked
        handler.burn(2);
        handler.mint(0, 1, 11, false); // token 4: content 1 again after the burn
        handler.gateLies(1);
        handler.rescue(3); // a collector's token: refused although the gate lies
        handler.removeMinter(0);
        handler.record(4, false, address(0), 0); // a removed sale still records
        handler.mint(0, 3, 12, false); // refused: removed
        handler.mint(1, 3, 13, false); // token 5
        handler.removeMinter(1);
        handler.setRescueDelay(1 days);
        handler.rescue(5); // too early: refused
        handler.warp(1 days);
        handler.rescue(5);
        handler.addMinter(0);
        assertEq(handler.records(), 2);
        assertEq(handler.burns(), 1);
        assertEq(handler.rescues(), 1);
        assertEq(handler.locks(), 1);
        assertEq(fs.ownerOf(5), handler.museum());
        assertFalse(handler.violation(), handler.violationNote());
        invariant_OneLiveTokenPerContent();
        invariant_OutcomeIsRecordedOnce();
        invariant_IdsAndSupply();
        invariant_OwnersMatchTheModel();
        invariant_FactsNeverChange();
        invariant_LockedRateNeverChanges();
        invariant_HasMintedMatchesTheModel();
    }
}
