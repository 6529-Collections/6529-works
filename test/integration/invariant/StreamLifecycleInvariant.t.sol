// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { StreamLifecycleHandler } from "./StreamLifecycleHandler.sol";

/// @notice Stateful invariants of a work's whole lifecycle on the plain-core stack: 6529 Stream,
///         the package registry, `StreamWorkFacts6529` and `WorkRules`, the delivery contract, the
///         English auction and the accounts module, deployed and configured by `DeployCore`
///         with the committed genesis.
///
///         The handler (`StreamLifecycleHandler`, inherited) registers and accepts packages,
///         moves items to Stream and starts their auctions, bids, settles, pauses for disputes
///         and cancels or resumes them, releases a burned work's content, opens, amends,
///         finalizes and relicenses records, adds locators, swaps the RENDERER module,
///         transfers works, stages and ends replacements and freezes accounts while the
///         restrained keys keep trying to act, pauses and unpauses starts, claims and expires
///         credits while the network changes the unclaimed period, and lets a hostile contract
///         (reverting, burning its gas or re-entering) bid, receive works and claim, its refused
///         deliveries claimed by the winning bidder. The state is checked:
///
///         1. Ownership: every token has exactly one owner, a known holder, and is in the
///            auction's custody exactly while its sale is unsettled or its delivery pending (a
///            burned token has none).
///         2. IDs: token IDs are assigned once, in order, each to one item, and never reused;
///            supply is minted minus burned.
///         3. Facts fixed at mint never change; the outcome is NONE until the sale records it,
///            then SOLD or UNSOLD for good.
///         4. Content: a content hash is held by at most one live work. A burned work keeps it
///            until it is released; a released item is barred and only the release's
///            beneficiary may mint the content again.
///         5. Records: the media never change; the record file changes only by the artist's
///            `setRecord` and never after finalize; a finalized work keeps its pinned renderer;
///            a CC0 work stays CC0 with the deployment's pinned text; locators are append-only.
///         6. Renderers: the RENDERER module is the one governance activated, a pending module
///            keeps the time it was given whatever the module delay becomes, and a finalized
///            work is drawn by its pinned renderer whatever the module.
///         7. Restraint: a party has no active authority exactly while frozen or being
///            replaced, and nothing its keys try as the artist goes through.
///         8. The auction holds exactly the live high bids and the credits.
///         9. Aged credits: a credit is what was credited and not claimed or expired; it is due
///            one unclaimed period (as it stands) after its waiting money started to wait; an
///            expiry sends exactly that money and never money younger than the period.
///         10. An unbid work ends with the museum, at once whatever its artist's standing, and
///            the museum holds nothing else.
///         Every action also predicts its outcome; any disagreement fails the campaign.
contract StreamLifecycleInvariantTest is StreamLifecycleHandler {
    uint256 internal constant ACTIONS = 27;
    /// @dev Replayed sequences in `test_EveryActionRuns`.
    uint256 internal constant RUNS = 64;

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
        s[12] = this.relicense.selector;
        s[13] = this.stageRecovery.selector;
        s[14] = this.endRecovery.selector;
        s[15] = this.restrainedAct.selector;
        s[16] = this.transfer.selector;
        s[17] = this.warp.selector;
        s[18] = this.toggleStartPause.selector;
        s[19] = this.hostileBid.selector;
        s[20] = this.hostileClaim.selector;
        s[21] = this.claimDelivery.selector;
        s[22] = this.claimCredit.selector;
        s[23] = this.expireCredit.selector;
        s[24] = this.setUnclaimedPeriod.selector;
        s[25] = this.swapRenderer.selector;
        s[26] = this.freezeAccount.selector;
    }

    /// @notice Every invariant above (1 to 10). In CI the state is asserted every fourth call
    ///         and after the last call of each run (every action still checks its own outcome
    ///         at once); the `deep` profile asserts it after every call.
    /// forge-config: default.invariant.check_interval = 4
    /// forge-config: deep.invariant.check_interval = 1
    function invariant_streamLifecycle() public view {
        _assertLifecycle();
    }

    /// @notice The campaign is not vacuous: sequences of the campaign's shape (uniform random
    ///         actions, depth 128) replayed from fixed seeds reach every action and the paths
    ///         the invariants are about, with every invariant holding along the way.
    function test_EveryActionRuns() public {
        string[58] memory paths = [
            "register",
            "registerRefused",
            "accept",
            "start",
            "revokedMove",
            "bid",
            "settle",
            "museum",
            "restrainedMuseum",
            "disputePause",
            "pauseExhausted",
            "cancel",
            "resume",
            "withdraw",
            "openRecord",
            "setRecord",
            "finalizedRecordRefused",
            "finalize",
            "addLocator",
            "relicense",
            "stageRecovery",
            "veto",
            "recovered",
            "earlyExecuteRefused",
            "freeze",
            "unfreeze",
            "freezeRefused",
            "restrainedStart",
            "restrainedAct",
            "restrainedAccept",
            "restrainedRelicense",
            "transfer",
            "warp",
            "contentUsed",
            "locatorRefused",
            "cc0Held",
            "startPaused",
            "startUnpaused",
            "pausedStart",
            "pausedBid",
            "pausedSettle",
            "hostileBid",
            "hostileRecipient",
            "hostileReceived",
            "deliveryPending",
            "forwardedClaimRefused",
            "recipientRedirect",
            "deliveryClaimed",
            "hostileClaimKept",
            "hostileReentryRefused",
            "claim",
            "expired",
            "expireEarly",
            "expireNothing",
            "setPeriod",
            "rendererProposed",
            "rendererSwapped",
            "moduleNotReady"
        ];
        uint256[58] memory totals;
        // The deepest chain (a copy burned by an upheld dispute, its content released, a racing
        // copy refused, the rightful artist minting again) is rare in random sequences: it is
        // logged here and asserted step by step by `test_CopyDisputeReleaseAndRemint`.
        uint256[4] memory deep;
        for (uint256 run; run < RUNS; ++run) {
            uint256 snapshot = vm.snapshotState();
            for (uint256 depth; depth < 128; ++depth) {
                // Nothing a step allocates is used after it: reuse the memory, so the replay's
                // cost stays linear in its length.
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
            _assertLifecycle();
            for (uint256 i; i < paths.length; ++i) {
                totals[i] += hits[bytes32(bytes(paths[i]))];
            }
            deep[0] += hits["release"];
            deep[1] += hits["reserved"];
            deep[2] += hits["reconsume"];
            deep[3] += hits["frozenExecuteRefused"];
            vm.revertToStateAndDelete(snapshot);
        }
        for (uint256 i; i < paths.length; ++i) {
            console2.log(paths[i], totals[i]);
        }
        console2.log("release, reserved, reconsume, frozenExecuteRefused");
        console2.log(deep[0], deep[1], deep[2]);
        console2.log(deep[3]);
        for (uint256 i; i < paths.length; ++i) {
            assertGt(totals[i], 0, paths[i]);
        }
    }

    /// @notice The deepest path, driven step by step through the handler: a copy of another
    ///         artist's media is started and bid on, a pauser key pauses it, the dispute is
    ///         upheld (the work is burned and the bid credited back), its content is released to
    ///         the rightful artist, another artist's copy racing for it is refused, and the
    ///         rightful artist's own item then mints the content again. Every invariant holds
    ///         after each step.
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
        assertGt(auction.claimable(lcBidders[0]), 0, "the bid was credited back");
        _assertLifecycle();
        this.releaseContent(0, 0);
        assertEq(registry.releasedTo(address(stream), pool[4].contentHash), uint160(lcArtists[2]));
        assertTrue(registry.isBarred(pool[4].itemHash), "the burned item is barred");
        assertEq(hits["reserved"], 1, "artist 1's copy raced for the released content, refused");
        _assertLifecycle();
        this.start(0, 2);
        assertEq(pool[12].tokenId, 2, "the rightful artist's item minted the content again");
        assertEq(hits["reconsume"], 1);
        assertEq(registry.releasedTo(address(stream), pool[4].contentHash), 0, "release used up");
        _assertLifecycle();
    }

    /// @notice While artist 0 is being replaced, the key the replacement reserves, a stranger
    ///         to the record, records a finalize notice on the settled work; the replacement
    ///         executes 14 days later and a second one is staged; the restrained authority then
    ///         calls `finalize` once the notice is due. Not a wallet of the account, it finalizes
    ///         the record as it stands, as anyone may: a due finalize, not an artist's act. Every
    ///         invariant holds after each step.
    function test_DueFinalizeNoticeWhileRestrained() public {
        this.start(0, 2);
        uint256 id = uint160(lcArtists[0]);
        assertEq(stream.workOf(1).artistId, id, "artist 0's work");
        this.stageRecovery(0);
        assertEq(accounts.activeAuthorityOf(id), address(0), "restrained");
        this.settle(0);
        this.openRecord(0);
        assertTrue(stream.workOf(1).outcome != Outcome.NONE, "the sale has an outcome");
        _assertLifecycle();
        // The reserved key (which odd), power 2: a notice, not a finalize.
        this.restrainedAct(0, 5);
        uint256 notice = rules.finalizeNoticeAt(address(stream), 1);
        assertEq(notice, block.timestamp, "the stranger's call recorded a notice");
        assertFalse(facts.factsOf(address(stream), 1).finalized);
        _assertLifecycle();
        this.endRecovery(0, 1);
        assertEq(hits["recovered"], 1, "the replacement executed");
        this.stageRecovery(0);
        address authority = accounts.authorityOf(id);
        assertEq(accounts.activeAuthorityOf(id), address(0), "restrained again");
        assertFalse(accounts.isWallet(id, authority), "the authority is not a wallet");
        assertGe(block.timestamp, notice + FINALIZE_NOTICE, "the notice is due");
        // The authority (which even), power 2: the due finalize anyone may make.
        this.restrainedAct(0, 4);
        assertTrue(facts.factsOf(address(stream), 1).finalized, "the due notice finalized");
        assertEq(hits["dueFinalize"], 1);
        _assertLifecycle();
    }

    /// @notice The aged-credit rule under a changing period, step by step: a bidder outbid
    ///         twice holds two credits that started at different times; shortening the period
    ///         lets only the first (the waiting money) go to the network; the second then waits
    ///         a whole period from the expiry; a claim takes everything.
    function test_AgedCreditsExpireOnlyAgedMoney() public {
        this.start(0, 2);
        this.bid(0, 0, 0);
        this.bid(0, 1, 0);
        uint256 first = auction.claimable(lcBidders[0]);
        assertGt(first, 0, "bidder 0 was outbid");
        this.warp(12 hours);
        this.bid(0, 0, 0);
        this.bid(0, 1, 0);
        assertGt(auction.claimable(lcBidders[0]), first, "a second credit joined");
        this.setUnclaimedPeriod(2); // 1 day: neither credit has waited a day
        this.expireCredit(0);
        assertEq(hits["expireEarly"], 1, "refused: nothing has waited the period");
        this.warp(12 hours);
        this.setUnclaimedPeriod(0); // zero: the waiting money is due at once
        uint256 total = auction.claimable(lcBidders[0]);
        this.expireCredit(0);
        assertEq(hits["expired"], 1);
        assertEq(auction.claimable(lcBidders[0]), total - first, "only the first credit went");
        this.setUnclaimedPeriod(2);
        this.expireCredit(0);
        assertEq(hits["expireEarly"], 2, "the rest waits a new period from the expiry");
        this.claimCredit(0);
        assertEq(auction.claimable(lcBidders[0]), 0, "a claim takes everything");
        _assertLifecycle();
    }

    /// @dev One handler call chosen and parameterised from `seed`, as the fuzzer would.
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
        else if (which == 12) this.relicense(a, b);
        else if (which == 13) this.stageRecovery(a);
        else if (which == 14) this.endRecovery(a, b);
        else if (which == 15) this.restrainedAct(a, b);
        else if (which == 16) this.transfer(a, b);
        else if (which == 17) this.warp(a);
        else if (which == 18) this.toggleStartPause(a);
        else if (which == 19) this.hostileBid(a, b, seed >> 64);
        else if (which == 20) this.hostileClaim(b);
        else if (which == 21) this.claimDelivery(a);
        else if (which == 22) this.claimCredit(a);
        else if (which == 23) this.expireCredit(a);
        else if (which == 24) this.setUnclaimedPeriod(a);
        else if (which == 25) this.swapRenderer(a);
        else this.freezeAccount(a, b);
    }
}
