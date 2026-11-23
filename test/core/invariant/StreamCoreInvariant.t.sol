// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Outcome, Work } from "src/interfaces/core/CoreTypes.sol";
import { CoreFixture } from "../../mocks/core/CoreFixture.sol";
import { MockSale } from "../../mocks/core/CoreMocks.sol";
import { StreamCoreHandler } from "./StreamCoreHandler.sol";

/// @notice Stateful invariants of the permanent ERC-721 (`src/core/Stream6529.sol`), at the
///         repository's invariant settings (256 runs, depth 128, `fail_on_revert`).
contract StreamCoreInvariantTest is CoreFixture {
    StreamCoreHandler internal handler;

    function setUp() public override {
        super.setUp();
        MockSale[3] memory sales = [sale, new MockSale(), new MockSale()];
        stream.addMinter(address(sales[1]));
        stream.addMinter(address(sales[2]));
        skip(7 days);
        handler = new StreamCoreHandler(stream, terms, sales);
        // The handler acts as the network.
        manager.grantRole(manager.ADMIN_ROLE(), address(handler), 0);
        targetContract(address(handler));
    }

    /// One live token per content hash, and `tokenOfContent` names it.
    function invariant_OneLiveTokenPerContent() public view {
        for (uint256 c; c < 6; ++c) {
            uint256 live;
            uint256 liveId;
            for (uint256 id = 1; id <= stream.totalMinted(); ++id) {
                if (handler.contentIdx(id) == c && handler.holder(id) != address(0)) {
                    ++live;
                    liveId = id;
                }
            }
            assertLe(live, 1, "two live tokens share a content");
            if (live == 1) assertEq(stream.tokenOfContent(handler.contentHash(c)), liveId);
        }
    }

    /// An outcome leaves NONE once and never changes after.
    function invariant_OutcomeIsRecordedOnce() public view {
        for (uint256 id = 1; id <= stream.totalMinted(); ++id) {
            assertEq(uint8(stream.workOf(id).outcome), uint8(handler.outcome(id)), "outcome");
        }
    }

    /// Token IDs are the `totalMinted` sequence from 1, and supply is minted minus burned.
    function invariant_IdsAndSupply() public view {
        assertEq(stream.totalMinted(), handler.mints(), "minted");
        assertEq(stream.totalBurned(), handler.burns(), "burned");
        assertEq(stream.totalSupply(), stream.totalMinted() - stream.totalBurned(), "supply");
        for (uint256 id = 1; id <= stream.totalMinted(); ++id) {
            assertTrue(stream.workOf(id).itemHash != 0, "a gap in the sequence");
        }
        assertEq(stream.workOf(stream.totalMinted() + 1).itemHash, 0, "minted past the count");
    }

    /// Every live token is where the model put it: no call by a module or minter moved a
    /// token it did not hold; burned tokens have no owner. Balances add up to the supply.
    function invariant_OwnersMatchTheModel() public view {
        uint256 sum;
        for (uint256 id = 1; id <= stream.totalMinted(); ++id) {
            address h = handler.holder(id);
            if (h == address(0)) continue;
            assertEq(stream.ownerOf(id), h, "owner");
        }
        for (uint256 i; i < 3; ++i) {
            sum += stream.balanceOf(handler.collectors(i));
            sum += stream.balanceOf(address(handler.sales(i)));
        }
        sum += stream.balanceOf(handler.museum());
        assertEq(sum, stream.totalSupply(), "balances");
    }

    /// The facts fixed at mint never change.
    function invariant_FactsNeverChange() public view {
        for (uint256 id = 1; id <= stream.totalMinted(); ++id) {
            assertEq(handler.hashOf(stream.workOf(id)), handler.factsHash(id), "facts");
        }
    }

    /// A locked royalty rate never changes and stays locked.
    function invariant_LockedRateNeverChanges() public view {
        for (uint256 id = 1; id <= stream.totalMinted(); ++id) {
            if (!handler.rateLocked(id)) continue;
            Work memory w = stream.workOf(id);
            assertTrue(w.royaltyRateLocked, "unlocked");
            assertEq(w.royaltyRate, handler.lockedRate(id), "locked rate");
        }
    }

    /// No call the model refuses ever succeeded (records, burns, rescues, royalties, attacks on
    /// held tokens by minters and the TERMS module).
    function invariant_NoRefusedCallSucceeded() public view {
        assertFalse(handler.violation(), handler.violationNote());
    }

    /// A SOLD token is never in a burned state and never back in NONE.
    function invariant_SoldTokensStayLive() public view {
        for (uint256 id = 1; id <= stream.totalMinted(); ++id) {
            if (handler.outcome(id) == Outcome.SOLD) {
                assertTrue(handler.holder(id) != address(0), "a sold token burned");
            }
        }
    }

    /// Each action of the handler reaches the state it models, so a passing campaign is not a
    /// campaign of refused calls.
    function test_HandlerReachesEveryState() public {
        handler.mint(0, 0, 7, false); // token 1 in sale 0's custody
        handler.mint(1, 1, 8, false); // token 2 in sale 1's custody
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
        handler.removeMinter(0);
        handler.setRescueDelay(1 days);
        handler.rescue(4); // too early: refused
        handler.warp(1 days);
        handler.rescue(4);
        handler.addMinter(0);
        assertEq(handler.records(), 1);
        assertEq(handler.burns(), 1);
        assertEq(handler.rescues(), 1);
        assertEq(handler.locks(), 1);
        assertEq(stream.ownerOf(4), handler.museum());
        assertFalse(handler.violation(), handler.violationNote());
        invariant_OneLiveTokenPerContent();
        invariant_OutcomeIsRecordedOnce();
        invariant_IdsAndSupply();
        invariant_OwnersMatchTheModel();
        invariant_FactsNeverChange();
        invariant_LockedRateNeverChanges();
    }
}
