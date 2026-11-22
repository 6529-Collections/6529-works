// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { StreamLifecycleHandlerPorted } from "./StreamLifecycleHandlerPorted.sol";

/// @notice Stateful invariants of a work's whole lifecycle on the deployed plain-core stack,
///         re-ported from the retired `StreamLifecycleInvariant`: 6529 Stream, the package
///         registry, `WorkFacts`, `WorkRules`, `WorkDelivery`, the English auction and
///         `Accounts`, deployed by `DeployCore` with the committed genesis.
///
///         The handler registers and accepts packages, starts auctions (with and without a
///         first bid), bids, settles, pauses for disputes and cancels or resumes them, releases
///         a burned copy's content, opens, amends and finalizes records, adds locators,
///         transfers works, stages and ends recoveries while the restrained keys keep trying to
///         act, pauses and unpauses starts, and lets a hostile contract (reverting, burning its
///         gas or re-entering) bid, receive works and claim. After every call:
///
///         1. Ownership: every live token has one known holder, is in the auction's custody
///            exactly while its sale is unsettled or its delivery pending, and has an outcome
///            exactly once settled; a burned token has none.
///         2. IDs: assigned once, in order, each to one item, never reused; supply is minted
///            minus burned.
///         3. Content: a content hash is held by at most one work; a burned work keeps it until
///            released; a released item is barred and only the beneficiary consumes it again.
///         4. Records: the media never change; a finalized record keeps its record file.
///         5. CC0: a CC0 work stays CC0, with the deployment's CC0 text.
///         6. Locators are append-only: exactly the ones added, in order.
///         7. Restraint: while a recovery is pending the artist has no active authority, and
///            nothing the old or the reserved key tries as the artist goes through.
///         8. The auction holds exactly the live high bids and the bidders' credits.
///         9. An unbid work ends with the museum (UNSOLD), even while its artist is restrained,
///            and the museum holds nothing else.
///         Every action also predicts its outcome; any disagreement fails the campaign.
contract StreamLifecycleInvariantPortedTest is StreamLifecycleHandlerPorted {
    uint256 internal constant ACTIONS = 21;
    /// @dev Replayed sequences in `test_EveryActionRuns`.
    uint256 internal constant RUNS = 32;
    uint256 internal constant DEPTH = 128;

    function setUp() public override {
        super.setUp();
        targetContract(address(this));
        targetSelector(FuzzSelector(address(this), _selectors()));
    }

    function _selectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](ACTIONS);
        s[0] = this.register.selector;
        s[1] = this.accept.selector;
        s[2] = this.start.selector;
        s[3] = this.bid.selector;
        s[4] = this.settle.selector;
        s[5] = this.disputePause.selector;
        s[6] = this.resolveDispute.selector;
        s[7] = this.releaseContent.selector;
        s[8] = this.openRecord.selector;
        s[9] = this.setRecord.selector;
        s[10] = this.finalize.selector;
        s[11] = this.addLocator.selector;
        s[12] = this.stageRecovery.selector;
        s[13] = this.endRecovery.selector;
        s[14] = this.restrainedAct.selector;
        s[15] = this.transfer.selector;
        s[16] = this.warp.selector;
        s[17] = this.toggleStartPause.selector;
        s[18] = this.hostileBid.selector;
        s[19] = this.hostileClaim.selector;
        s[20] = this.claimDelivery.selector;
    }

    /// @notice Every invariant above (1 to 9), asserted every fourth call in CI and after every
    ///         call in the deep profile (every action still checks its own outcome at once).
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.check_interval = 4
    /// forge-config: deep.invariant.check_interval = 1
    function invariant_streamLifecycle() public view {
        _assertLifecycle();
    }

    /// @notice The campaign is not vacuous: sequences of its shape replayed from fixed seeds
    ///         reach every action and the paths the invariants are about, with every invariant
    ///         holding along the way.
    function test_EveryActionRuns() public {
        string[33] memory paths = [
            "register",
            "registerRefused",
            "accept",
            "start",
            "revokedMove",
            "bid",
            "settle",
            "museum",
            "disputePause",
            "pauseExhausted",
            "cancel",
            "resume",
            "withdraw",
            "openRecord",
            "setRecord",
            "finalize",
            "addLocator",
            "locatorRefused",
            "stageRecovery",
            "veto",
            "recovered",
            "restrainedStart",
            "restrainedAct",
            "transfer",
            "warp",
            "contentUsed",
            "startPaused",
            "startUnpaused",
            "pausedStart",
            "hostileBid",
            "hostileRecipient",
            "deliveryPending",
            "deliveryClaimed"
        ];
        uint256[33] memory totals;
        uint256[6] memory rare;
        for (uint256 run; run < RUNS; ++run) {
            uint256 snapshot = vm.snapshotState();
            for (uint256 depth; depth < DEPTH; ++depth) {
                uint256 free;
                assembly ("memory-safe") {
                    free := mload(0x40)
                }
                _step(uint256(keccak256(abi.encode(run, depth))));
                if (depth % 16 == 15) _assertLifecycle();
                assembly ("memory-safe") {
                    mstore(0x40, free)
                }
            }
            for (uint256 i; i < paths.length; ++i) {
                totals[i] += hits[bytes32(bytes(paths[i]))];
            }
            rare[0] += hits["release"];
            rare[1] += hits["reserved"];
            rare[2] += hits["reconsume"];
            rare[3] += hits["hostileReceived"];
            rare[4] += hits["hostileClaimKept"] + hits["hostileReentryRefused"];
            rare[5] += hits["forwardedClaimRefused"];
            vm.revertToStateAndDelete(snapshot);
        }
        for (uint256 i; i < paths.length; ++i) {
            console2.log(paths[i], totals[i]);
        }
        console2.log("release, reserved, reconsume, hostileReceived, hostileClaim, forwarded");
        console2.log(rare[0], rare[1], rare[2]);
        console2.log(rare[3], rare[4], rare[5]);
        for (uint256 i; i < paths.length; ++i) {
            assertGt(totals[i], 0, paths[i]);
        }
    }

    /// @notice The deepest path, step by step through the handler: a copy of another artist's
    ///         media is started and bid on, a pauser pauses it, the dispute is upheld (the work
    ///         is burned and the bid credited back), its content is released to the rightful
    ///         artist, another artist's copy racing for it is refused, and the rightful artist's
    ///         own item then mints the content again. Every invariant holds after each step.
    function test_CopyDisputeReleaseAndRemint() public {
        for (uint256 i; i < ARTISTS; ++i) {
            this.register(i);
        }
        for (uint256 i; i < 2 * ARTISTS; ++i) {
            this.accept(i / 2, i);
        }
        _assertLifecycle();
        // Pool item 4 is artist 0's copy of artist 2's first work (item 12).
        this.start(4, 2);
        assertEq(pool[4].tokenId, 1, "the copy minted first");
        this.bid(0, 0, 1 ether);
        this.disputePause(0);
        _assertLifecycle();
        this.resolveDispute(0, 0);
        assertTrue(tok[1].burned, "the upheld dispute burned the copy");
        _assertLifecycle();
        this.releaseContent(0, 0);
        assertEq(
            registry.releasedTo(address(stream), pool[4].contentHash),
            accounts.artistIdOf(lcArtists[2])
        );
        assertEq(hits["reserved"], 1, "artist 1's copy raced for the released content, refused");
        _assertLifecycle();
        this.start(0, 2);
        assertEq(pool[12].tokenId, 2, "the rightful artist's item minted the content again");
        assertEq(hits["reconsume"], 1);
        _assertLifecycle();
    }

    /// @notice While artist 0 is restrained (a recovery pending), its reserved key, a stranger
    ///         to the record, records a finalize notice on the settled work; once the notice is
    ///         due the restrained authority's `finalize` finalizes the record as it stands, as
    ///         anyone's may: a due finalize, not an artist's act. Before the sale had an outcome
    ///         neither key could finalize or change the record.
    function test_DueFinalizeNoticeWhileRestrained() public {
        this.start(0, 2); // artist 0's first work, no first bid
        this.openRecord(0);
        this.stageRecovery(0);
        uint256 id = accounts.artistIdOf(lcArtists[0]);
        assertEq(accounts.activeAuthorityOf(id), address(0), "restrained");
        this.restrainedAct(0, 3); // the reserved key, a record change: refused
        this.restrainedAct(0, 5); // the reserved key, a finalize before an outcome: refused
        assertEq(rules.finalizeNoticeAt(address(stream), 1), 0);
        this.settle(0); // unbid: the museum's, while restrained
        assertEq(hits["restrainedMuseum"], 1);
        assertEq(uint8(stream.workOf(1).outcome), uint8(Outcome.UNSOLD));
        _assertLifecycle();

        this.restrainedAct(0, 5); // the reserved key: a notice, not a finalize
        uint256 notice = rules.finalizeNoticeAt(address(stream), 1);
        assertEq(notice, block.timestamp, "the stranger's call recorded a notice");
        assertFalse(facts.factsOf(address(stream), 1).finalized);
        _assertLifecycle();

        vm.warp(notice + FINALIZE_NOTICE);
        this.restrainedAct(0, 4); // the old authority: the due finalize anyone may make
        assertTrue(facts.factsOf(address(stream), 1).finalized, "the due notice finalized it");
        assertEq(hits["dueFinalize"], 1);
        assertGe(hits["restrainedAct"], 2);
        _assertLifecycle();
    }

    function _step(uint256 seed) internal {
        uint256 which = seed % ACTIONS;
        (uint256 a, uint256 b) = (uint256(keccak256(abi.encode(seed, 1))), seed >> 32);
        if (which == 0) this.register(a);
        else if (which == 1) this.accept(a, b);
        else if (which == 2) this.start(a, b);
        else if (which == 3) this.bid(a, b, seed >> 64);
        else if (which == 4) this.settle(a);
        else if (which == 5) this.disputePause(a);
        else if (which == 6) this.resolveDispute(a, b);
        else if (which == 7) this.releaseContent(a, b);
        else if (which == 8) this.openRecord(a);
        else if (which == 9) this.setRecord(a, b);
        else if (which == 10) this.finalize(a);
        else if (which == 11) this.addLocator(a, b);
        else if (which == 12) this.stageRecovery(a);
        else if (which == 13) this.endRecovery(a, b);
        else if (which == 14) this.restrainedAct(a, b);
        else if (which == 15) this.transfer(a, b);
        else if (which == 16) this.warp(a);
        else if (which == 17) this.toggleStartPause(a);
        else if (which == 18) this.hostileBid(a, b, seed >> 64);
        else if (which == 19) this.hostileClaim(b);
        else this.claimDelivery(a);
    }
}
