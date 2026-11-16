// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IArtistRegistry, IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { ArtistIdentity, ChangeKind, Standing } from "src/interfaces/types/IdentityTypes.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import {
    FailingConsolidationSource,
    OversizedConsolidationSource
} from "../mocks/identity/IdentityWorksMocks.sol";
import {
    BurningConsolidationSource,
    BurningEditionsMock
} from "../mocks/identity/PermanenceMocks.sol";
import { StreamMock } from "../mocks/stream/StreamMock.sol";
import { IdentityFixture } from "./IdentityFixture.sol";

/// @notice Recovery never depends on the consolidation source answering (study G finding 7),
///         a gas shortfall is never read as an answer, source times are clamped instead of
///         truncated, and a payout-only override needs dormancy (studies D finding 5 and F
///         finding 2).
contract RecoveryRobustnessTest is IdentityFixture {
    // ----------------------------------------------------------------- recovery with a dead source

    /// @dev A LOST_KEY override stages and executes whatever the source does: reverts with or
    ///      without data, answers out of bounds, or had its code replaced.
    function test_LostKeyRecovery_SurvivesEveryKindOfDeadSource() public {
        for (uint256 kind; kind < 4; ++kind) {
            uint256 snapshot = vm.snapshotState();
            _breakSource(kind);
            vm.warp(block.timestamp + 365 days);
            vm.expectEmit(address(registry));
            emit IArtistRegistry.StandingRefreshSkipped(artistId);
            _stageOverride(ChangeKind.LOST_KEY, _identity(newAuthority, newAuthority), newKey);
            address[] memory cancellers = _cancellers();
            assertEq(cancellers.length, 1, "the recorded wallet keeps its standing");
            assertEq(cancellers[0], wallet);
            vm.warp(block.timestamp + 180 days);
            registry.executeChange(artistId);
            assertEq(registry.authorityOf(artistId), newAuthority, "recovered");
            vm.revertToState(snapshot);
        }
    }

    /// @dev A dead source cannot make a live artist dormant: the authority's heartbeat still
    ///      records activity, so a LOST_KEY override is refused.
    function test_DeadSource_AuthorityHeartbeatStillCounts() public {
        _breakSource(0);
        vm.warp(block.timestamp + 300 days);
        vm.prank(artist);
        registry.heartbeat(artistId);
        vm.warp(block.timestamp + 100 days);
        _armRevert(
            abi.encodeWithSelector(
                IArtistRegistry.NotDormant.selector, artistId, uint64(block.timestamp - 100 days)
            )
        );
        _stageOverride(ChangeKind.LOST_KEY, _identity(newAuthority, newAuthority), newKey);
    }

    // ----------------------------------------------------------------- gas

    /// @dev A source whose reads cost 2, 4 and 10 times the former 200,000-gas stipend is read
    ///      in full (all gas is forwarded): the staging records its consolidation instead of
    ///      skipping.
    function test_RepricedSource_IsReadInFullAt2x4x10x() public {
        address fresh = makeAddr("freshWallet");
        BurningConsolidationSource source = _install(fresh, uint64(block.timestamp));
        uint256[3] memory factors = [uint256(2), 4, 10];
        for (uint256 i; i < 3; ++i) {
            uint256 snapshot = vm.snapshotState();
            source.set(factors[i] * 200_000, uint64(block.timestamp), false);
            vm.recordLogs();
            _stage(artistKey, _identity(artist, payout), 0);
            assertFalse(_logged(IArtistRegistry.StandingRefreshSkipped.selector), "not skipped");
            assertEq(_cancellers()[_cancellers().length - 1], fresh, "read and captured");
            vm.revertToState(snapshot);
        }
    }

    /// @dev A call that cannot give the source what it needs reverts instead of skipping the
    ///      refresh (a shortfall is never read as a failing source), and the same call with
    ///      enough gas succeeds.
    function test_Shortfall_RevertsInsteadOfSkipping() public {
        BurningConsolidationSource source = _install(makeAddr("w"), uint64(block.timestamp));
        source.set(3_000_000, uint64(block.timestamp), false);
        vm.warp(block.timestamp + 365 days);
        ArtistIdentity memory next = _identity(artist, payout);
        bytes32 evidence = keccak256("evidence");
        vm.expectPartialRevert(BoundedCall.BoundedCallShortfall.selector);
        vm.prank(governor);
        registry.stageOverride{ gas: 1_500_000 }(
            artistId, ChangeKind.LOST_KEY, next, evidence, 0, ""
        );
        vm.prank(governor);
        registry.stageOverride(artistId, ChangeKind.LOST_KEY, next, evidence, 0, "");
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.LOST_KEY));
    }

    /// @dev `isArtist` never answers "not the artist" because the caller ran short of gas: an
    ///      Editions read that runs out reverts, and with enough gas the answer is true.
    function test_IsArtist_ShortfallRevertsInsteadOfAnsweringFalse() public {
        StreamMock stream = new StreamMock();
        BurningEditionsMock editions = new BurningEditionsMock(address(stream));
        stream.setEditions(address(editions));
        stream.setWork(1, artistId);
        vm.prank(admin);
        registry.bindStream(address(stream));
        editions.setBurn(2_000_000);
        vm.expectPartialRevert(BoundedCall.BoundedCallShortfall.selector);
        registry.isArtist{ gas: 1_000_000 }(address(editions), 1, artist);
        assertTrue(registry.isArtist(address(editions), 1, artist));
    }

    // ----------------------------------------------------------------- times

    /// @dev A source time beyond 48 bits is clamped, never truncated: truncation would turn a
    ///      far-future (pending) time into an early one and give the wallet standing at once.
    function test_SourceTimes_AreClampedNotTruncated() public {
        address fresh = makeAddr("freshWallet");
        uint64 far = uint64(type(uint48).max) + 5;
        _install(fresh, far);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.StandingAdded(artistId, fresh, type(uint48).max);
        registry.refreshStanding(artistId);
        Standing[] memory s = registry.standingOf(artistId);
        assertEq(s[s.length - 1].wallet, fresh);
        assertEq(s[s.length - 1].effectiveAt, type(uint48).max, "clamped");
        _stage(artistKey, _identity(artist, payout), 0);
        address[] memory cancellers = _cancellers();
        for (uint256 i; i < cancellers.length; ++i) {
            assertTrue(cancellers[i] != fresh, "a pending wallet has no standing");
        }
    }

    // ----------------------------------------------------------------- payout protection

    /// @dev Studies D finding 5 and F finding 2: a payout-only override (the authority stays)
    ///      needs dormancy whatever its kind, so a single governed role cannot freeze a live
    ///      artist's payout at once; the payout stays live.
    function test_PayoutOnlyOverride_NeedsDormancy() public {
        (, uint64 last) = registry.artist(artistId);
        vm.warp(last + 365 days - 1);
        _armRevert(abi.encodeWithSelector(IArtistRegistry.NotDormant.selector, artistId, last));
        _stageOverride(ChangeKind.CONTESTED, _identity(artist, thief), 0);
        assertEq(registry.payoutAddress(artistId), artist, "never frozen");
        vm.warp(last + 365 days);
        _stageOverride(ChangeKind.CONTESTED, _identity(artist, payout), 0);
        assertEq(registry.payoutAddress(artistId), address(0), "frozen for a dormant artist");
    }

    /// @dev Stolen-key recovery is unchanged: an override that moves the authority needs no
    ///      dormancy, and freezes and restrains from staging; a profile-only override neither
    ///      freezes nor needs dormancy.
    function test_PayoutOnlyOverride_RecoveryPathsUnchanged() public {
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, payout), newKey);
        assertEq(registry.payoutAddress(artistId), address(0));
        assertEq(registry.activeAuthorityOf(artistId), address(0));
        vm.prank(guardian);
        registry.vetoChange(artistId);
        _stageOverride(ChangeKind.CONTESTED, _identity(artist, artist), 0);
        assertEq(registry.payoutAddress(artistId), artist);
    }

    function testFuzz_PayoutOnlyOverride_RefusedForAnyLiveArtist(uint256 kindSeed, uint256 wait)
        public
    {
        ChangeKind kind = ChangeKind(2 + kindSeed % 3);
        (, uint64 last) = registry.artist(artistId);
        vm.warp(last + bound(wait, 0, 365 days - 1));
        _armRevert(abi.encodeWithSelector(IArtistRegistry.NotDormant.selector, artistId, last));
        _stageOverride(kind, _identity(artist, payout), 0);
    }

    // ----------------------------------------------------------------- helpers

    /// @dev 0: reverts with data; 1: reverts without data; 2: oversized answer; 3: code changed.
    function _breakSource(uint256 kind) internal {
        if (kind == 3) {
            vm.etch(address(adapter), address(new FailingConsolidationSource()).code);
            return;
        }
        IConsolidationSource broken;
        if (kind == 2) {
            broken = IConsolidationSource(address(new OversizedConsolidationSource()));
        } else {
            FailingConsolidationSource failing = new FailingConsolidationSource();
            failing.set(true, true, true);
            if (kind == 1) failing.setReason(hex"");
            broken = IConsolidationSource(address(failing));
        }
        vm.prank(successorSetter);
        registry.setConsolidationSource(adapter, broken, address(broken).codehash);
    }

    function _install(address w, uint64 time) internal returns (BurningConsolidationSource source) {
        source = new BurningConsolidationSource(w, time);
        vm.prank(successorSetter);
        registry.setConsolidationSource(
            adapter, IConsolidationSource(address(source)), address(source).codehash
        );
    }

    function _logged(bytes32 topic) internal returns (bool) {
        VmSafeLog[] memory logs = abi.decode(abi.encode(vm.getRecordedLogs()), (VmSafeLog[]));
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    struct VmSafeLog {
        bytes32[] topics;
        bytes data;
        address emitter;
    }
}
