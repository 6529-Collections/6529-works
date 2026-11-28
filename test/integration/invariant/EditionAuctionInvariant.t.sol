// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { EditionAuctionHandler } from "./EditionAuctionHandler.sol";

/// @notice Stateful invariants of 6529 Stream Editions' uniform-price edition auction on the
///         deployed stack (`DeployCore` with the committed genesis), each edition auction beside
///         its master's 1/1 English auction (D138-D141, ADR 0005).
///
///         The handler (`EditionAuctionHandler`, inherited) starts 1/1 auctions, opens their
///         edition auctions (which creates each edition), bids (sometimes in the soft-close
///         window), raises, bids on the 1/1 in its anti-snipe window, pauses a 1/1 for a dispute
///         and tries to take edition bids back (bids are firm, R21), cancels the 1/1 (voiding its
///         editions) or resumes it, has the network rescue the work of a 1/1 that is not settled
///         (to a safe, to the auction itself, or sent straight back: settling that 1/1 closes it
///         with refunds and voids its editions), settles the 1/1 (an unbid one goes to the
///         museum), spreads a
///         few books wider than one settle call scans, settles edition auctions with the
///         departure hint (and tries to settle them early, and to claim while they are
///         SETTLING), abandons them, and claims bids directly or by `claimBidFor`, on capped and
///         uncapped editions. After every call:
///
///         1. No unsold editions: copies minted equal the units claimed, never exceed the
///            clearing count `k`, and equal `k` once every bid is claimed; the edition is sealed
///            at `k` by the clearing (at zero when voided) and holds the creator's cap until then.
///         2. ETH conservation: the adapter's balance is what bidders paid in minus refunds,
///            revenue and credits paid out, and equals exactly what it owes.
///         3. Clearing optimality: the live result and the settled one equal a brute-force
///            per-unit reference, within the breadth margin and the cap.
///         4. FIFO at the cut step: the units won sum to `k`, filled in arrival order.
///         5. The view equals settlement.
///         6. Timing: the end is `max(1/1 end + 15 minutes, soft end)`, within the backstop.
///         7. No settlement before the end, or before the 1/1 settles or is cancelled.
///         8. A void auction refunds every bid in full and mints nothing.
///         9. No claim while SETTLING.
///         Every action also predicts its outcome; any disagreement fails the campaign.
contract EditionAuctionInvariantTest is EditionAuctionHandler {
    uint256 internal constant ACTIONS = 23;
    /// @dev Actions `test_EveryActionRuns` replays: every one but `abandon`, whose 21-day jumps
    ///      the campaign exercises (its outcome is predicted and checked on every call).
    uint256 internal constant STEP_ACTIONS = 22;
    /// @dev Replayed sequences in `test_EveryActionRuns`.
    uint256 internal constant RUNS = 128;

    function setUp() public override {
        super.setUp();
        targetContract(address(this));
        targetSelector(FuzzSelector(address(this), _selectors()));
    }

    function _selectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](ACTIONS);
        s[0] = this.startOneOfOne.selector;
        s[1] = this.bidOneOfOne.selector;
        s[2] = this.settleOneOfOne.selector;
        s[3] = this.disputePause.selector;
        s[4] = this.resolveDispute.selector;
        s[5] = this.open.selector;
        s[6] = this.bid.selector;
        s[7] = this.raise.selector;
        s[8] = this.withdraw.selector;
        s[9] = this.wideBook.selector;
        s[10] = this.settle.selector;
        s[11] = this.claim.selector;
        s[12] = this.withdrawCredit.selector;
        s[13] = this.warp.selector;
        s[14] = this.bid.selector;
        s[15] = this.bid.selector;
        s[16] = this.raise.selector;
        s[17] = this.claim.selector;
        s[18] = this.settle.selector;
        s[19] = this.settleOneOfOne.selector;
        s[20] = this.fifoHole.selector;
        s[21] = this.abandon.selector;
        s[22] = this.rescueOneOfOne.selector;
    }

    /// @notice Every invariant above. The state is asserted every fourth call and after the
    ///         last call of each run (every action still checks its own outcome at once); the
    ///         `deep` profile asserts it after every call.
    /// forge-config: default.invariant.check_interval = 4
    /// forge-config: deep.invariant.check_interval = 1
    function invariant_editionAuction() public view {
        _assertEditionAuction();
    }

    /// @notice The handler self-test: sequences of the campaign's shape replayed from fixed seeds
    ///         reach every action and the paths the invariants are about, with every invariant
    ///         holding along the way.
    function test_EveryActionRuns() public {
        // The campaign-shaped runs exceed the test gas limit; the metering is not what is tested.
        vm.pauseGasMetering();
        string[43] memory paths = [
            "startOneOfOne",
            "bidOneOfOne",
            "oneOfOneSnipe",
            "editionEndMoved",
            "settleOneOfOneSold",
            "museum",
            "disputePause",
            "cancel",
            "resume",
            "open",
            "openRefused",
            "bid",
            "inexactRefused",
            "softClose",
            "raise",
            "raiseRefused",
            "withdrawRefused",
            "settle",
            "settleEmpty",
            "settleChunked",
            "settlerHandoff",
            "sweepStranded",
            "completedAfterGrief",
            "settlersInterleave",
            "fifoHole",
            "wideBook",
            "scanChunked",
            "claimWhileSettlingRefused",
            "settleTooEarly",
            "settleWaits",
            "rationed",
            "holeSwept",
            "void",
            "voidRefund",
            "claim",
            "claimFor",
            "partFilled",
            "claimTwiceRefused",
            "withdrawCredit",
            "rescue",
            "rescueBackInCustody",
            "rescuedClose",
            "rescuedVoid"
        ];
        uint256[43] memory totals;
        for (uint256 run; run < RUNS; ++run) {
            uint256 snapshot = vm.snapshotState();
            for (uint256 depth; depth < 128; ++depth) {
                uint256 free;
                assembly ("memory-safe") {
                    free := mload(0x40)
                }
                _step(uint256(keccak256(abi.encode("edition auction", run, depth))));
                if (depth % 16 == 15) _assertEditionAuction();
                assembly ("memory-safe") {
                    mstore(0x40, free)
                }
            }
            _assertEditionAuction();
            for (uint256 i; i < paths.length; ++i) {
                totals[i] += hits[bytes32(bytes(paths[i]))];
            }
            vm.revertToStateAndDelete(snapshot);
        }
        for (uint256 i; i < paths.length; ++i) {
            console2.log(paths[i], totals[i]);
        }
        for (uint256 i; i < paths.length; ++i) {
            assertGt(totals[i], 0, paths[i]);
        }
    }

    /// @dev One handler call chosen and parameterised from `seed`, as the fuzzer would.
    function _step(uint256 seed) internal {
        uint256 which = seed % STEP_ACTIONS;
        (uint256 a, uint256 b, uint256 c) = (
            uint256(keccak256(abi.encode(seed, 1))),
            uint256(keccak256(abi.encode(seed, 2))),
            seed >> 32
        );
        if (which == 0) this.startOneOfOne(a);
        else if (which == 1) this.bidOneOfOne(a, b);
        else if (which == 2 || which == 19) this.settleOneOfOne(a);
        else if (which == 3) this.disputePause(a);
        else if (which == 4) this.resolveDispute(a, b);
        else if (which == 5) this.open(a, b);
        else if (which == 9) this.wideBook(a);
        else if (which == 6 || which == 14 || which == 15) this.bid(a, b, c);
        else if (which == 7 || which == 16) this.raise(a, b, c);
        else if (which == 8) this.withdraw(a, b);
        else if (which == 10 || which == 18) this.settle(a, b);
        else if (which == 11 || which == 17) this.claim(a, b, c);
        else if (which == 12) this.withdrawCredit(a);
        else if (which == 20) this.fifoHole(a);
        else if (which == 21) this.rescueOneOfOne(a, b);
        else this.warp(a);
    }
}
