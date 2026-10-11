// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { ArtistIdentity, ChangeKind, Standing } from "src/interfaces/types/IdentityTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import {
    FederationRegistryStub,
    PullOnlyPayeeMock
} from "../mocks/identity/IdentityWorksMocks.sol";
import { IdentityFixture } from "./IdentityFixture.sol";

/// @notice Regression tests from the PR #16 review: the reviewer's proofs of concept, inverted
///         where the sticky standing snapshot (H1) or the narrower payout freeze (M1) changed the
///         outcome, plus dormancy accounting (M2), stale-change clearing (L3) and bounds.
contract ArtistRegistryReviewTest is IdentityFixture {
    // ----------------------------------------------------------------- H1: sticky standing

    function test_Standing_RecordedAtRegistration() public view {
        Standing[] memory s = registry.standingOf(artistId);
        assertEq(s.length, 1);
        assertEq(s[0].wallet, wallet);
        assertEq(s[0].effectiveAt, START + 30 days);
        assertEq(s[0].missingSince, 0);
    }

    /// @dev PoC-1 inverted: a thief holding the key revokes the artist's consolidation and stages
    ///      at once; the genuine wallet keeps standing, is captured, and stops the redirect.
    function test_PoC1_RevokeThenStageStillCapturesTheWallet() public {
        PullOnlyPayeeMock payee = new PullOnlyPayeeMock{ value: 1 ether }(registry, artistId);
        _revoke(artist, wallet);
        _stage(artistKey, _identity(thief, thief), thiefKey);
        assertEq(registry.standingOf(artistId)[0].missingSince, block.timestamp, "marked missing");
        assertEq(_cancellers().length, 1);
        assertEq(_cancellers()[0], wallet);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        vm.prank(artist);
        payee.release();
        assertEq(artist.balance, 1 ether, "the artist's payout, not the thief's");
    }

    /// @dev PoC-2 inverted: swap-and-pop moves a key holder's prepared tail wallet to the front of
    ///      the live list, but the genuine wallet keeps standing and is captured first.
    function test_PoC2_SwapAndPopCannotDisplaceStanding() public {
        address thiefWallet = makeAddr("thiefWallet");
        for (uint256 i; i < 40; ++i) {
            _delegate(artist, address(uint160(0x2000 + i)), FAR);
        }
        _consolidate(artist, thiefWallet);
        vm.warp(block.timestamp + 30 days);
        _revoke(artist, wallet);
        address[] memory live = adapter.establishedWallets(artist);
        assertEq(live.length, 1);
        assertEq(live[0], thiefWallet, "the live view reorders");
        _stage(artistKey, _identity(thief, thief), thiefKey);
        address[] memory c = _cancellers();
        assertEq(c.length, 2);
        assertEq(c[0], wallet, "standing first");
        assertEq(c[1], thiefWallet);
        vm.prank(wallet);
        registry.cancelChange(artistId);
    }

    /// @dev A wallet loses standing only after a refresh has recorded it missing (with an event)
    ///      and 30 more days have passed, also observed by a refresh.
    function test_Standing_LostOnlyAfterAPublicThirtyDayGrace() public {
        _revoke(artist, wallet);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.StandingMissing(artistId, wallet);
        vm.prank(stranger);
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId)[0].missingSince, block.timestamp);

        vm.warp(block.timestamp + 30 days - 1);
        _stage(artistKey, _identity(artist, payout), 0);
        assertEq(_cancellers()[0], wallet, "still captured on the last day");
        vm.prank(guardian);
        registry.vetoChange(artistId);

        vm.warp(block.timestamp + 1);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.StandingRemoved(artistId, wallet);
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId).length, 0);
        _stage(artistKey, _identity(artist, payout), 0);
        assertEq(_cancellers().length, 0);
    }

    /// @dev Staging refreshes first, so a wallet missing for 30 days is aged out, not captured.
    function test_Standing_StagingAgesOutAMissingWallet() public {
        _revoke(artist, wallet);
        registry.refreshStanding(artistId);
        vm.warp(block.timestamp + 30 days);
        vm.prank(governor);
        registry.stageOverride(
            artistId, ChangeKind.CONTESTED, _identity(artist, artist), keccak256("e"), 0, ""
        );
        assertEq(_cancellers().length, 0);
    }

    function test_Standing_RestoredWhenReEstablished() public {
        _revoke(artist, wallet);
        registry.refreshStanding(artistId);
        _delegate(artist, wallet, FAR);
        vm.warp(block.timestamp + 30 days);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.StandingAdded(artistId, wallet, uint64(START + 30 days));
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId)[0].missingSince, 0);
    }

    function test_Standing_RefreshAddsButIsNotActivity() public {
        _consolidate(artist, wallet2);
        vm.warp(block.timestamp + 30 days);
        (, uint64 before) = registry.artist(artistId);
        registry.refreshStanding(artistId);
        (, uint64 afterRefresh) = registry.artist(artistId);
        assertEq(afterRefresh, before, "a refresh is not activity");
        assertEq(registry.standingOf(artistId).length, 2);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, 7));
        registry.refreshStanding(7);
    }

    /// @dev An execution refreshes standing for the new authority: the old authority's wallets go
    ///      missing (keeping standing for the grace), the new authority's are added.
    function test_Standing_ExecutionRefreshesForTheNewAuthority() public {
        _consolidate(newAuthority, wallet2);
        vm.warp(block.timestamp + 30 days);
        _stage(artistKey, _identity(newAuthority, newAuthority), newKey);
        vm.warp(block.timestamp + 7 days);
        registry.executeChange(artistId);
        Standing[] memory s = registry.standingOf(artistId);
        assertEq(s.length, 2);
        assertEq(s[0].wallet, wallet);
        assertEq(s[0].missingSince, block.timestamp);
        assertEq(s[1].wallet, wallet2);
    }

    function test_Standing_BoundedToSixteen() public {
        for (uint256 i; i < 20; ++i) {
            _consolidate(artist, address(uint160(0x9000 + i)));
        }
        vm.warp(block.timestamp + 30 days);
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId).length, Limits.MAX_CANCELLERS);
        _stage(artistKey, _identity(artist, payout), 0);
        assertEq(_cancellers().length, Limits.MAX_CANCELLERS);
        assertEq(_cancellers()[0], wallet, "the oldest standing first");
    }

    /// @dev PoC-3, the residual exposure: once a hijack executes, the thief's own prepared
    ///      wallets gain standing for the new authority, so they are captured and can contest
    ///      each override (a TDH vote then decides; ADR 0003 owner decision 1). The artist's
    ///      genuine wallet keeps standing for the 30-day grace after the hijack.
    function test_PoC3_ResidualRiskThiefWalletsCancelOverridesAfterAHijack() public {
        address thiefWallet = makeAddr("thiefWallet");
        _consolidate(thief, thiefWallet);
        vm.warp(block.timestamp + 30 days);
        // The artist's wallet does not cancel (asleep); the hijack executes.
        _stage(artistKey, _identity(thief, thief), thiefKey);
        vm.warp(block.timestamp + 7 days);
        registry.executeChange(artistId);

        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, newAuthority), newKey);
        address[] memory c = _cancellers();
        assertEq(c.length, 2);
        assertEq(c[0], wallet, "the genuine wallet, within its grace");
        assertEq(c[1], thiefWallet);
        vm.prank(thiefWallet);
        registry.cancelChange(artistId);
        assertTrue(registry.pendingChange(artistId).contestedAt != 0, "contested, not killed");
        assertEq(registry.authorityOf(artistId), thief);
        vm.prank(guardian);
        registry.vetoChange(artistId);

        // After the grace, only the thief's wallet is captured.
        vm.warp(block.timestamp + 30 days);
        registry.refreshStanding(artistId);
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, newAuthority), newKey);
        assertEq(_cancellers().length, 1);
        assertEq(_cancellers()[0], thiefWallet);
    }

    /// @dev PoC-8 (documented): after a rotation A to N while A and N are consolidated, the old key
    ///      A is an established wallet of N and is captured as an override canceller. The artist
    ///      should revoke N to A; A then keeps standing for the 30-day grace.
    function test_PoC8_OldKeyConsolidatedWithTheNewAuthorityIsCaptured() public {
        _consolidate(artist, newAuthority);
        vm.warp(block.timestamp + 30 days);
        _stage(artistKey, _identity(newAuthority, newAuthority), newKey);
        vm.warp(block.timestamp + 7 days);
        registry.executeChange(artistId);
        _stageOverride(ChangeKind.CONTESTED, _identity(thief, thief), thiefKey);
        vm.prank(artist);
        registry.cancelChange(artistId);
        assertTrue(registry.pendingChange(artistId).contestedAt != 0, "the old key contests");
        vm.prank(guardian);
        registry.vetoChange(artistId);

        _revoke(newAuthority, artist);
        registry.refreshStanding(artistId);
        vm.warp(block.timestamp + 30 days);
        registry.refreshStanding(artistId);
        _stageOverride(ChangeKind.CONTESTED, _identity(thief, thief), thiefKey);
        _expectNotAuthorized(artist);
        vm.prank(artist);
        registry.cancelChange(artistId);
    }

    // ----------------------------------------------------------------- N1, N2: pending, direct

    /// @dev N1 inverted: a wallet consolidated after registration is recorded as pending by one
    ///      refresh (a keeper or the UI), has no standing before its 30 days, and once effective a
    ///      key holder who revokes it and stages still finds it captured.
    function test_N1_YoungWalletRecordedPendingIsCapturedAfterRevocation() public {
        address wallet3 = vm.addr(0xB4);
        _consolidate(artist, wallet3);
        uint64 effective = uint64(block.timestamp + 30 days);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.StandingAdded(artistId, wallet3, effective);
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId)[1].effectiveAt, effective);

        vm.warp(block.timestamp + 10 days);
        _stage(artistKey, _identity(artist, payout), 0);
        assertEq(_cancellers().length, 1, "pending: no standing yet");
        vm.prank(guardian);
        registry.vetoChange(artistId);

        vm.warp(effective + 1 days);
        _revoke(artist, wallet3);
        _stage(artistKey, _identity(thief, thief), thiefKey);
        address[] memory c = _cancellers();
        assertEq(c.length, 2);
        assertEq(c[1], wallet3);
        vm.prank(wallet3);
        registry.cancelChange(artistId);
    }

    /// @dev N2 inverted: a recorded wallet beyond the bounded scan is checked directly, so a
    ///      wallet that is still established is never marked missing or removed.
    function test_N2_StillEstablishedWalletBeyondTheScanKeepsStanding() public {
        address[16] memory j;
        for (uint256 i; i < 16; ++i) {
            j[i] = address(uint160(0xA000 + i));
            _delegate(artist, j[i], FAR);
        }
        _consolidate(artist, wallet2);
        vm.warp(block.timestamp + 30 days);
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId).length, 2);
        for (uint256 i; i < 16; ++i) {
            _delegate(j[i], artist, FAR);
        }
        vm.warp(block.timestamp + 30 days);
        vm.recordLogs();
        registry.refreshStanding(artistId);
        vm.warp(block.timestamp + 30 days);
        registry.refreshStanding(artistId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IArtistRegistry.StandingMissing.selector);
        }
        assertTrue(_hasStanding(wallet2), "kept while established");
    }

    /// @dev N2 direct check: after a rotation, a recorded wallet that is consolidated with the new
    ///      authority beyond the new authority's 32-entry scan is checked directly and keeps
    ///      standing instead of being marked missing.
    function test_N2_DirectCheckBeyondTheNewAuthoritysScan() public {
        for (uint256 i; i < 32; ++i) {
            _delegate(newAuthority, address(uint160(0xB000 + i)), FAR);
        }
        _consolidate(newAuthority, wallet);
        vm.warp(block.timestamp + 30 days);
        (address[] memory live,) = adapter.consolidations(newAuthority);
        assertEq(live.length, 0, "beyond the scan");
        _stage(artistKey, _identity(newAuthority, newAuthority), newKey);
        vm.warp(block.timestamp + 7 days);
        registry.executeChange(artistId);
        Standing[] memory s = registry.standingOf(artistId);
        assertEq(s.length, 1);
        assertEq(s[0].wallet, wallet);
        assertEq(s[0].missingSince, 0, "still consolidated with the new authority");
    }

    // ----------------------------------------------------------------- T1: snapshot mechanics

    /// @dev S09: a full snapshot keeps its missing entries for their grace and records nothing
    ///      new; slots free up only as missing entries age out.
    function test_Standing_FullSnapshotKeepsMissingEntriesAndSkipsNewOnes() public {
        for (uint256 i; i < 15; ++i) {
            _consolidate(artist, address(uint160(0x6000 + i)));
        }
        vm.warp(block.timestamp + 30 days);
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId).length, 16);
        for (uint256 i; i < 3; ++i) {
            _revoke(artist, address(uint160(0x6000 + i)));
        }
        registry.refreshStanding(artistId);
        for (uint256 i; i < 5; ++i) {
            _consolidate(artist, address(uint160(0x6100 + i)));
        }
        vm.warp(block.timestamp + 30 days - 1);
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId).length, 16, "bounded");
        assertTrue(_hasStanding(address(uint160(0x6000))), "missing entry kept");
        assertFalse(_hasStanding(address(uint160(0x6100))), "no eviction for new wallets");

        vm.warp(block.timestamp + 1);
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId).length, 16);
        assertFalse(_hasStanding(address(uint160(0x6000))), "aged out");
        assertTrue(_hasStanding(address(uint160(0x6100))), "recorded in a freed slot");
    }

    /// @dev S10: removing a non-last entry removes that wallet, not another.
    function test_Standing_RemovesExactlyTheMissingWallet() public {
        _consolidate(artist, wallet2);
        _consolidate(artist, newAuthority);
        vm.warp(block.timestamp + 30 days);
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId)[0].wallet, wallet);
        _revoke(artist, wallet);
        registry.refreshStanding(artistId);
        vm.warp(block.timestamp + 30 days);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.StandingRemoved(artistId, wallet);
        registry.refreshStanding(artistId);
        assertFalse(_hasStanding(wallet));
        assertTrue(_hasStanding(wallet2));
        assertTrue(_hasStanding(newAuthority));
        assertEq(registry.standingOf(artistId).length, 2);
    }

    /// @dev With one free slot, an established wallet takes it before a pending one, even one that
    ///      comes earlier in the delegate list.
    function test_Standing_EstablishedWalletsTakeFreeSlotsBeforePendingOnes() public {
        for (uint256 i; i < 14; ++i) {
            _consolidate(artist, address(uint160(0x6000 + i)));
        }
        vm.warp(block.timestamp + 30 days);
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId).length, 15);
        address pending = makeAddr("pending");
        address established = makeAddr("established");
        _delegate(artist, pending, FAR); // first in the list, one-sided for now
        _consolidate(artist, established);
        vm.warp(block.timestamp + 30 days);
        _delegate(pending, artist, FAR); // now consolidated, but young
        registry.refreshStanding(artistId);
        assertTrue(_hasStanding(established), "established first");
        assertFalse(_hasStanding(pending), "no slot left for the pending wallet");
    }

    /// @dev S18: a heartbeat refreshes standing.
    function test_Standing_HeartbeatRefreshes() public {
        _consolidate(artist, wallet2);
        vm.warp(block.timestamp + 30 days);
        vm.prank(artist);
        registry.heartbeat(artistId);
        assertTrue(_hasStanding(wallet2));
    }

    /// @dev After a rotation with a full snapshot, the previous authority's wallets keep standing
    ///      for the grace and the new authority's wallets are recorded only as those age out.
    function test_Standing_PostRotationFullSnapshot() public {
        for (uint256 i; i < 15; ++i) {
            _consolidate(artist, address(uint160(0x6000 + i)));
        }
        _consolidate(newAuthority, wallet2);
        vm.warp(block.timestamp + 30 days);
        _stage(artistKey, _identity(newAuthority, newAuthority), newKey);
        vm.warp(block.timestamp + 7 days);
        registry.executeChange(artistId);
        assertEq(registry.standingOf(artistId).length, 16);
        assertFalse(_hasStanding(wallet2), "full: not yet recorded");
        _stageOverride(ChangeKind.CONTESTED, _identity(thief, thief), thiefKey);
        assertEq(_cancellers().length, 16, "the previous wallets, within their grace");
        vm.prank(wallet);
        registry.cancelChange(artistId);

        vm.warp(block.timestamp + 30 days);
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId).length, 1);
        assertTrue(_hasStanding(wallet2));
    }

    // ----------------------------------------------------------------- M1: payout freeze

    /// @dev PoC-4 inverted: a no-op override does not freeze the payout.
    function test_PoC4_NoOpOverrideDoesNotFreeze() public {
        (ArtistIdentity memory current,) = registry.artist(artistId);
        vm.prank(governor);
        registry.stageOverride(artistId, ChangeKind.CONTESTED, current, keccak256("x"), 0, "");
        assertEq(registry.payoutAddress(artistId), artist);
    }

    /// @dev PoC-7 inverted: a recovery override that keeps a safe payout does not freeze it.
    function test_PoC7_RecoveryOverrideKeepsASafePayoutLive() public {
        _stage(artistKey, _identity(artist, payout), 0);
        vm.warp(block.timestamp + 7 days);
        registry.executeChange(artistId);
        PullOnlyPayeeMock payee = new PullOnlyPayeeMock{ value: 1 ether }(registry, artistId);
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, payout), newKey);
        vm.prank(payout);
        payee.release();
        assertEq(payout.balance, 1 ether);
    }

    /// @dev PoC-5 (observation): a heartbeat during a LOST_KEY notice does not stop it; only a
    ///      captured wallet or the guardian can (ADR: the old key cannot cancel an override).
    function test_PoC5_HeartbeatDuringALostKeyNoticeDoesNotStopIt() public {
        vm.warp(block.timestamp + 366 days);
        _stageOverride(ChangeKind.LOST_KEY, _identity(newAuthority, newAuthority), newKey);
        vm.prank(artist);
        registry.heartbeat(artistId);
        vm.warp(block.timestamp + 180 days);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), newAuthority);
    }

    // ----------------------------------------------------------------- M2: dormancy accounting

    function test_Activity_OverridesAndVetoesDoNotCount() public {
        (, uint64 last) = registry.artist(artistId);
        vm.warp(block.timestamp + 1 days);
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, newAuthority), newKey);
        vm.prank(guardian);
        registry.vetoChange(artistId);
        (, uint64 now_) = registry.artist(artistId);
        assertEq(now_, last);
    }

    function test_Activity_CancelsAndExecutionsCount() public {
        vm.warp(block.timestamp + 1 days);
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, newAuthority), newKey);
        vm.warp(block.timestamp + 1 days);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        _assertActivityNow();
        vm.prank(guardian);
        registry.vetoChange(artistId);

        vm.warp(block.timestamp + 1 days);
        vm.prank(governor);
        registry.stageOverride(
            artistId, ChangeKind.CONTESTED, _identity(artist, payout), keccak256("e"), 0, ""
        );
        vm.warp(block.timestamp + 180 days);
        registry.executeChange(artistId);
        _assertActivityNow();

        _stage(artistKey, _identity(artist, artist), 0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(artist);
        registry.cancelChange(artistId);
        _assertActivityNow();
    }

    // ----------------------------------------------------------------- bounds

    function test_FederatedList_BoundedToSixtyFour() public {
        address federation = address(new FederationRegistryStub());
        vm.prank(admin);
        registry.bindFederationRegistry(federation);
        vm.startPrank(federation);
        for (uint256 i; i < registry.MAX_FEDERATED(); ++i) {
            registry.listFederatedContract(artistId, address(uint160(0xF000 + i)));
        }
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.FederatedListFull.selector, artistId)
        );
        registry.listFederatedContract(artistId, stranger);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- gas (EIP-7825)

    /// @dev PoC-9: `stageChange` with 16 distinct cold non-established entries (one forward and four
    ///      expired reverse registrations each) and 16 distinct cold established wallets, all
    ///      added to the standing snapshot and captured. Execution plus intrinsic and calldata
    ///      gas fits far inside the 16,777,216 transaction cap.
    function test_PoC9_StageChangeAllColdWorstCase() public {
        _revoke(artist, wallet);
        for (uint256 i; i < 16; ++i) {
            address w = address(uint160(0x7000 + i));
            _delegate(artist, w, FAR);
            for (uint256 j; j < 4; ++j) {
                _delegate(w, artist, block.timestamp + 1);
            }
        }
        for (uint256 i; i < 16; ++i) {
            _consolidate(artist, address(uint160(0x8000 + i)));
        }
        vm.warp(block.timestamp + 30 days);
        ArtistIdentity memory next = _identity(newAuthority, payout);
        uint64 deadline = uint64(block.timestamp + 1);
        bytes32 digest = _digest(next, deadline);
        bytes memory sig = _sign(artistKey, digest);
        bytes memory acceptance = _sign(newKey, digest);
        vm.cool(address(delegation));
        vm.cool(address(registry));
        uint256 before = gasleft();
        registry.stageChange(artistId, next, artist, deadline, sig, acceptance);
        uint256 used = before - gasleft();
        assertEq(_cancellers().length, 16);
        uint256 total = used + 21_000 + 16
            * abi.encodeCall(
                ArtistRegistry.stageChange, (artistId, next, artist, deadline, sig, acceptance)
            )
            .length;
        emit log_named_uint("stageChange all-cold worst-case transaction gas", total);
        assertLt(total, 5_000_000);
    }

    // ----------------------------------------------------------------- worst-case gas (round 3)

    uint256 internal constant SCAN_KEY = 0xF100; // 32 scanned wallets
    uint256 internal constant RECORDED_KEY = 0xF200; // recorded wallets moved beyond the scan

    /// @dev The adversarial worst case: 32 scanned wallets and 16 directly checked recorded
    ///      wallets each cost 8 cold registration reads (3 expired and 1 live forward, 3 expired
    ///      and 1 live, or 4 expired, reverse), because the forward padding sits beyond the
    ///      32-entry scan window. At the measured call the 16 recorded wallets age out and 16
    ///      scanned wallets are recorded (and, for a staging, captured).
    function _setupWorstCase() private {
        for (uint256 i; i < 15; ++i) {
            _consolidate(artist, vm.addr(RECORDED_KEY + i));
        }
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId).length, 16);
        _revoke(artist, wallet);
        _revoke(wallet, artist);
        for (uint256 i; i < 15; ++i) {
            _revoke(artist, vm.addr(RECORDED_KEY + i));
            _revoke(vm.addr(RECORDED_KEY + i), artist);
        }
        uint256 soon = block.timestamp + 1;
        for (uint256 i; i < 32; ++i) {
            _delegate(artist, vm.addr(SCAN_KEY + i), soon);
        }
        for (uint256 i; i < 32; ++i) {
            address x = vm.addr(SCAN_KEY + i);
            _delegate(artist, x, soon);
            _delegate(artist, x, soon);
            _delegate(artist, x, FAR);
            _delegate(x, artist, soon);
            _delegate(x, artist, soon);
            _delegate(x, artist, soon);
            _delegate(x, artist, FAR);
        }
        for (uint256 i; i < 16; ++i) {
            address r = i == 15 ? wallet : vm.addr(RECORDED_KEY + i);
            _delegate(artist, r, soon);
            _delegate(artist, r, soon);
            _delegate(artist, r, soon);
            _delegate(artist, r, FAR);
            for (uint256 k; k < 4; ++k) {
                _delegate(r, artist, soon);
            }
        }
        vm.warp(block.timestamp + 2);
        registry.refreshStanding(artistId);
        vm.warp(block.timestamp + 30 days);
    }

    /// @dev About 7.44M gas: under half of the 16,777,216 EIP-7825 cap with calldata included.
    function test_WorstCase_StageChangeGas() public {
        _setupWorstCase();
        ArtistIdentity memory next = _identity(newAuthority, payout);
        uint64 deadline = uint64(block.timestamp + 1);
        bytes32 digest = _digest(next, deadline);
        bytes memory sig = _sign(SCAN_KEY, digest);
        bytes memory acceptance = _sign(newKey, digest);
        _coolAll();
        uint256 before = gasleft();
        registry.stageChange(artistId, next, vm.addr(SCAN_KEY), deadline, sig, acceptance);
        uint256 used = before - gasleft();
        emit log_named_uint("stageChange worst case (execution)", used);
        assertEq(_cancellers().length, 16);
        assertFalse(_hasStanding(wallet), "the recorded wallets aged out");
        assertLt(used + 21_000 + 16 * 900, 16_777_216 / 2);
    }

    /// @dev About 7.46M gas.
    function test_WorstCase_StageOverrideGas() public {
        _setupWorstCase();
        bytes32 evidence = keccak256("evidence");
        ArtistIdentity memory next = _identity(newAuthority, newAuthority);
        uint64 deadline = uint64(block.timestamp + 1);
        bytes memory acceptance = _sign(
            newKey,
            registry.overrideDigest(artistId, ChangeKind.CONTESTED, next, evidence, deadline)
        );
        _coolAll();
        vm.prank(governor);
        uint256 before = gasleft();
        registry.stageOverride(artistId, ChangeKind.CONTESTED, next, evidence, deadline, acceptance);
        uint256 used = before - gasleft();
        emit log_named_uint("stageOverride worst case (execution)", used);
        assertEq(_cancellers().length, 16);
        assertLt(used + 21_000 + 16 * 900, 16_777_216 / 2);
    }

    /// @dev About 6.82M gas.
    function test_WorstCase_RefreshStandingGas() public {
        _setupWorstCase();
        _coolAll();
        uint256 before = gasleft();
        registry.refreshStanding(artistId);
        uint256 used = before - gasleft();
        emit log_named_uint("refreshStanding worst case (execution)", used);
        assertEq(registry.standingOf(artistId).length, 16);
        assertLt(used + 21_000, 16_777_216 / 2);
    }

    /// @dev One direct check is bounded at 8 reads (4 per direction) of 50K gas each.
    function test_WorstCase_DirectCheckBoundedAtEightReads() public {
        _setupWorstCase();
        vm.cool(address(delegation));
        vm.cool(address(adapter));
        uint256 before = gasleft();
        adapter.effectiveAt(artist, wallet);
        uint256 used = before - gasleft();
        emit log_named_uint("one direct check (8 cold reads)", used);
        assertLt(used, 8 * 50_000);
    }

    // ----------------------------------------------------------------- effectiveAt (round 3)

    /// @dev T1: after a rotation, a recorded wallet whose pair with the new authority is older
    ///      has its effectiveAt lowered to that pair's, so it is captured at once.
    function test_Standing_RotationLowersEffectiveAtToTheOlderPair() public {
        uint256 old = block.timestamp;
        _consolidate(newAuthority, wallet2);
        vm.warp(old + 25 days);
        _consolidate(artist, wallet2);
        registry.refreshStanding(artistId);
        assertEq(_entry(wallet2).effectiveAt, old + 55 days, "young pair with the artist");
        vm.warp(old + 31 days);
        _stage(artistKey, _identity(newAuthority, newAuthority), newKey);
        vm.warp(block.timestamp + 7 days);
        registry.executeChange(artistId);
        assertEq(_entry(wallet2).effectiveAt, old + 30 days, "lowered to the older pair");
        _stageOverride(ChangeKind.CONTESTED, _identity(thief, thief), thiefKey);
        assertTrue(_inCancellers(wallet2), "captured before the young pair's 30 days");
    }

    /// @dev A recorded wallet's clock only moves earlier: a key holder's revoke and re-add cannot
    ///      push it later.
    function test_Standing_ReConsolidationCannotResetTheClock() public {
        uint256 first = block.timestamp;
        _consolidate(artist, wallet2);
        registry.refreshStanding(artistId);
        assertEq(_entry(wallet2).effectiveAt, first + 30 days);
        vm.warp(first + 10 days);
        _revoke(artist, wallet2);
        registry.refreshStanding(artistId);
        vm.warp(first + 20 days);
        _delegate(artist, wallet2, FAR);
        assertEq(adapter.effectiveAt(artist, wallet2), first + 50 days);
        registry.refreshStanding(artistId);
        assertEq(_entry(wallet2).effectiveAt, first + 30 days, "pinned");
        assertEq(_entry(wallet2).missingSince, 0);
    }

    /// @dev Expired back-dated and duplicate registrations do not make a wallet effective sooner
    ///      than its live registration plus 30 days.
    function test_Standing_NoFasterThanThirtyDaysFromTheLiveRegistration() public {
        address t = address(uint160(0xD100));
        _delegate(artist, t, block.timestamp + 1);
        _delegate(t, artist, block.timestamp + 1);
        vm.warp(block.timestamp + 20 days);
        uint256 live = block.timestamp;
        _consolidate(artist, t);
        _consolidate(artist, t);
        registry.refreshStanding(artistId);
        assertEq(_entry(t).effectiveAt, live + 30 days);
        vm.warp(live + 29 days);
        _stage(artistKey, _identity(thief, thief), thiefKey);
        assertFalse(_inCancellers(t), "pending: not captured at 29 days");
    }

    /// @dev A recorded wallet cannot be stripped in under 30 days by revoke and re-add cycles,
    ///      list stuffing or repeated refreshes.
    function test_Standing_CannotBeStrippedInUnderThirtyDays() public {
        uint256 t0 = block.timestamp;
        _revoke(artist, wallet);
        registry.refreshStanding(artistId);
        _delegate(artist, wallet, FAR);
        registry.refreshStanding(artistId);
        _revoke(artist, wallet);
        registry.refreshStanding(artistId);
        for (uint256 i; i < 40; ++i) {
            _delegate(artist, address(uint160(0xE000 + i)), FAR);
        }
        for (uint256 d = 1; d < 30; ++d) {
            vm.warp(t0 + d * 1 days);
            registry.refreshStanding(artistId);
        }
        vm.warp(t0 + 30 days - 1);
        _stage(artistKey, _identity(thief, thief), thiefKey);
        assertEq(_cancellers().length, 1);
        assertEq(_cancellers()[0], wallet, "still captured at 30 days minus one second");
    }

    /// @dev Residual risk (README): a key holder can fill the free slots with pending entries of
    ///      their own; a genuine wallet consolidated afterwards is not recorded while those slots
    ///      are held, and the key holder's entries become cancellers 30 days later.
    function test_ResidualRisk_KeyHolderFillsFreeSlots() public {
        for (uint256 i; i < 15; ++i) {
            _consolidate(artist, address(uint160(0xD000 + i)));
        }
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId).length, 16);
        _consolidate(artist, wallet2);
        vm.warp(block.timestamp + 31 days);
        registry.refreshStanding(artistId);
        assertFalse(_hasStanding(wallet2), "not recorded while the slots are held");
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, newAuthority), newKey);
        assertEq(_cancellers().length, 16);
    }

    function _entry(address w) private view returns (Standing memory) {
        Standing[] memory s = registry.standingOf(artistId);
        for (uint256 i; i < s.length; ++i) {
            if (s[i].wallet == w) return s[i];
        }
        revert("not recorded");
    }

    function _inCancellers(address w) private view returns (bool) {
        address[] memory c = _cancellers();
        for (uint256 i; i < c.length; ++i) {
            if (c[i] == w) return true;
        }
        return false;
    }

    function _coolAll() private {
        vm.cool(address(delegation));
        vm.cool(address(registry));
        vm.cool(address(adapter));
    }

    function _hasStanding(address w) internal view returns (bool) {
        Standing[] memory s = registry.standingOf(artistId);
        for (uint256 i; i < s.length; ++i) {
            if (s[i].wallet == w) return true;
        }
        return false;
    }

    function _assertActivityNow() internal view {
        (, uint64 last) = registry.artist(artistId);
        assertEq(last, block.timestamp);
    }

    function _expectNotAuthorized(address account) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.NotAuthorized.selector, artistId, account)
        );
    }
}
