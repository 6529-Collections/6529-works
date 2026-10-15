// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { StreamLifecycleHandler } from "./StreamLifecycleHandler.sol";

/// @notice Stateful invariants of a work's whole lifecycle on the real stack: 6529 Stream, the
///         package registry, the records satellite, the English auction and the artist registry,
///         deployed and configured by `DeployV1` with the committed genesis.
///
///         The handler (`StreamLifecycleHandler`, inherited) registers and accepts packages,
///         moves items to Stream and starts their auctions, bids, settles, pauses for disputes and
///         cancels or resumes them, releases a burned work's content, opens, amends, finalizes
///         and relicenses records, adds locators, transfers works, and stages and ends recovery
///         overrides while the restrained keys keep trying to act. After every call:
///
///         1. Ownership: every token has exactly one owner, a known holder, and is in the
///            auction's custody exactly while its sale is unsettled (a burned token has none).
///         2. IDs: token IDs are assigned once, in order, each to one item, and never reused;
///            supply is minted minus burned.
///         3. Content: a content hash is held by at most one live item. A burned work keeps it
///            until it is released; a released item is tombstoned and only the release's
///            beneficiary may consume the content again.
///         4. Finality: a finalized record never changes its content hashes (the media hash,
///            the media list and the record file); media never changes at all.
///         5. CC0: a CC0 work stays CC0, with the deployment's pinned CC0 text.
///         6. Locators are append-only: exactly the ones added, in order.
///         7. Restraint (IDENTITY-1): while a recovery override that moves the authority is
///            pending, the artist has no active authority, and nothing the old or the reserved
///            key tries as the artist goes through.
///         8. The auction holds exactly the live high bids and the bidders' credits.
///         Every action also predicts its outcome; any disagreement fails the campaign.
contract StreamLifecycleInvariantTest is StreamLifecycleHandler {
    uint256 internal constant ACTIONS = 18;
    /// @dev Replayed sequences in `test_EveryActionRuns`.
    uint256 internal constant RUNS = 32;

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
    }

    /// @notice Every invariant above (1 to 8). In CI the state is asserted every fourth call
    ///         and after the last call of each run (every action still checks its own outcome
    ///         at once); the `deep` profile asserts it after every call.
    /// forge-config: default.invariant.check_interval = 4
    /// forge-config: deep.invariant.check_interval = 1
    function invariant_streamLifecycle() public view {
        _assertLifecycle();
    }

    /// @notice The campaign is not vacuous: sequences of the campaign's shape (uniform random
    ///         actions, depth 128) replayed from fixed seeds reach every action and the paths
    ///         the invariants are about, with every invariant holding after each step.
    function test_EveryActionRuns() public {
        string[24] memory paths = [
            "register",
            "accept",
            "start",
            "bid",
            "settle",
            "disputePause",
            "cancel",
            "resume",
            "release",
            "openRecord",
            "setRecord",
            "finalize",
            "addLocator",
            "relicense",
            "stageRecovery",
            "veto",
            "recovered",
            "restrained",
            "transfer",
            "warp",
            "contentUsed",
            "locatorRefused",
            "cc0Held",
            "reconsume"
        ];
        uint256[24] memory totals;
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

    /// @notice The deepest path, driven step by step through the handler: a copy of another
    ///         artist's media is started and bid on, the guardian pauses it, the dispute is upheld
    ///         (the work is burned and the bid credited back), its content is released to the
    ///         rightful artist, and the rightful artist's own item then mints the content again.
    ///         Every invariant holds after each step.
    function test_CopyDisputeReleaseAndRemint() public {
        for (uint256 i; i < ARTISTS; ++i) {
            this.register(i);
        }
        for (uint256 i; i < 2 * ARTISTS; ++i) {
            this.accept(i / 2, i);
        }
        _assertLifecycle();
        // Pool item 4 is artist 0's copy of artist 2's first work (item 10).
        this.start(4, 2);
        assertEq(pool[4].tokenId, 1, "the copy minted first");
        this.bid(0, 0, 1 ether);
        this.disputePause(0);
        _assertLifecycle();
        this.resolveDispute(0, 0);
        assertTrue(tok[1].burned, "the upheld dispute burned the copy");
        _assertLifecycle();
        this.releaseContent(0, 0);
        assertEq(registry.releasedTo(pool[4].contentHash), uint160(lcArtists[2]));
        _assertLifecycle();
        this.start(0, 2);
        assertEq(pool[10].tokenId, 2, "the rightful artist's item minted the content again");
        assertEq(hits["reconsume"], 1);
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
        else this.warp(a);
    }
}
