// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { ArtistIdentity, ChangeKind } from "src/interfaces/types/IdentityTypes.sol";
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
        ArtistRegistry.Standing[] memory s = registry.standingOf(artistId);
        assertEq(s.length, 1);
        assertEq(s[0].wallet, wallet);
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
        emit ArtistRegistry.StandingMissing(artistId, wallet);
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
        emit ArtistRegistry.StandingRemoved(artistId, wallet);
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
        emit ArtistRegistry.StandingAdded(artistId, wallet);
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
        ArtistRegistry.Standing[] memory s = registry.standingOf(artistId);
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

    /// @dev PoC-3, the residual risk (owner decision): once a hijack executes, the thief's own
    ///      prepared wallets gain standing for the new authority and can cancel each override.
    ///      The artist's genuine wallet keeps standing for the 30-day grace after the hijack.
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
        assertEq(registry.authorityOf(artistId), thief, "the override was killed");

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

        _revoke(newAuthority, artist);
        registry.refreshStanding(artistId);
        vm.warp(block.timestamp + 30 days);
        registry.refreshStanding(artistId);
        _stageOverride(ChangeKind.CONTESTED, _identity(thief, thief), thiefKey);
        _expectNotAuthorized(artist);
        vm.prank(artist);
        registry.cancelChange(artistId);
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
        vm.expectRevert(abi.encodeWithSelector(ArtistRegistry.FederatedListFull.selector, artistId));
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
