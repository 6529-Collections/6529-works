// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { ChangeKind, PendingChange } from "src/interfaces/types/IdentityTypes.sol";
import { IdentityFixture } from "./IdentityFixture.sol";

/// @notice The artist registry's governed timers: compiled floors (the genesis values) and
///         ceilings, the uphold-window coupling, and locking at staging, so a later setting
///         never traps or releases a pending change.
contract RegistryTimersTest is IdentityFixture {
    IArtistRegistry.Timer internal constant CHANGE = IArtistRegistry.Timer.CHANGE_DELAY;
    IArtistRegistry.Timer internal constant NOTICE = IArtistRegistry.Timer.OVERRIDE_DELAY;
    IArtistRegistry.Timer internal constant DORMANCY = IArtistRegistry.Timer.DORMANCY;
    IArtistRegistry.Timer internal constant CONTEST = IArtistRegistry.Timer.CONTEST_TIMEOUT;
    IArtistRegistry.Timer internal constant GRACE = IArtistRegistry.Timer.STANDING_GRACE;

    /// @dev The floors and ceilings, by number: the floors are the genesis values.
    function test_Bounds_AreTheGuarantee() public view {
        uint48[5] memory floors = [uint48(7 days), 180 days, 365 days, 365 days, 30 days];
        uint48[5] memory ceilings = [uint48(30 days), 365 days, 1825 days, 730 days, 90 days];
        for (uint256 i; i < 5; ++i) {
            (uint48 floor, uint48 ceiling) = registry.timerBounds(IArtistRegistry.Timer(i));
            assertEq(floor, floors[i]);
            assertEq(ceiling, ceilings[i]);
            assertEq(registry.timer(IArtistRegistry.Timer(i)), floors[i], "genesis value");
        }
    }

    /// @dev Deployment announces every timer at its floor, so a logs-only reader knows them.
    function test_Constructor_EmitsEveryTimer() public {
        uint48[5] memory floors = [uint48(7 days), 180 days, 365 days, 365 days, 30 days];
        for (uint256 i; i < 5; ++i) {
            vm.expectEmit(true, true, true, true);
            emit IArtistRegistry.TimerSet(IArtistRegistry.Timer(i), floors[i]);
        }
        new ArtistRegistry(address(manager), adapter, address(adapter).codehash);
    }

    function test_SetTimer_WithinBounds() public {
        vm.expectEmit(address(registry));
        emit IArtistRegistry.TimerSet(CHANGE, 14 days);
        _set(CHANGE, 14 days);
        assertEq(registry.timer(CHANGE), 14 days);
        _set(CHANGE, 7 days);
        _set(DORMANCY, 1825 days);
        _set(GRACE, 90 days);
        _set(CONTEST, 730 days);
        _set(NOTICE, 365 days);
    }

    function test_SetTimer_RefusesValuesOutsideTheBounds() public {
        uint48[5] memory floors = [uint48(7 days), 180 days, 365 days, 365 days, 30 days];
        uint48[5] memory ceilings = [uint48(30 days), 365 days, 1825 days, 730 days, 90 days];
        for (uint256 i; i < 5; ++i) {
            IArtistRegistry.Timer which = IArtistRegistry.Timer(i);
            vm.expectRevert(IArtistRegistry.InvalidTimers.selector);
            _set(which, floors[i] - 1);
            vm.expectRevert(IArtistRegistry.InvalidTimers.selector);
            _set(which, ceilings[i] + 1);
        }
    }

    /// @dev The contest timeout always exceeds the override notice by the floors' 185 days, so
    ///      a contested override can be upheld after its notice: lengthen the timeout first.
    function test_SetTimer_KeepsTheUpholdWindow() public {
        vm.expectRevert(IArtistRegistry.InvalidTimers.selector);
        _set(NOTICE, 181 days);
        _set(CONTEST, 366 days);
        _set(NOTICE, 181 days);
        vm.expectRevert(IArtistRegistry.InvalidTimers.selector);
        _set(CONTEST, 365 days);
    }

    function testFuzz_SetTimer_NeverLeavesTheBounds(uint256 whichSeed, uint48 value) public {
        IArtistRegistry.Timer which = IArtistRegistry.Timer(whichSeed % 5);
        (uint48 floor, uint48 ceiling) = registry.timerBounds(which);
        uint48 notice = which == NOTICE ? value : registry.timer(NOTICE);
        uint48 contest = which == CONTEST ? value : registry.timer(CONTEST);
        bool ok =
            value >= floor && value <= ceiling && uint256(contest) >= uint256(notice) + 185 days;
        if (!ok) vm.expectRevert(IArtistRegistry.InvalidTimers.selector);
        _set(which, value);
        assertEq(registry.timer(which), ok ? value : floor);
    }

    function test_SetTimer_RevertsForNonSetter() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, governor)
        );
        vm.prank(governor);
        registry.setTimer(CHANGE, 8 days);
    }

    // ----------------------------------------------------------------- locking

    /// @dev Lengthening the change delay does not trap a change staged before it.
    function test_Lock_LengtheningNeverTrapsAPendingChange() public {
        _stage(artistKey, _identity(artist, payout), 0);
        _set(CHANGE, 30 days);
        vm.warp(block.timestamp + 7 days);
        registry.executeChange(artistId);
        assertEq(registry.payoutAddress(artistId), payout);
        // A change staged now takes the new delay.
        _stage(artistKey, _identity(artist, artist), 0);
        assertEq(registry.pendingChange(artistId).executableAt, block.timestamp + 30 days);
    }

    /// @dev Shortening a delay never releases a change staged under the longer one.
    function test_Lock_ShorteningNeverReleasesAPendingChange() public {
        _set(CONTEST, 550 days);
        _set(NOTICE, 365 days);
        ChangeKindStage memory s = _stageAuthorityOverride();
        _set(NOTICE, 180 days);
        vm.warp(s.stagedAt + 180 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.ChangeNotDue.selector, artistId, s.stagedAt + 365 days
            )
        );
        registry.executeChange(artistId);
        vm.warp(s.stagedAt + 365 days);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), newAuthority);
    }

    /// @dev A contest lapses by the timeout locked at staging, not by a later setting.
    function test_Lock_ContestLapseUsesTheLockedTimeout() public {
        ChangeKindStage memory s = _stageAuthorityOverride();
        assertEq(registry.pendingChange(artistId).contestTimeout, 365 days);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        uint256 contestedAt = block.timestamp;
        _set(CONTEST, 730 days);
        vm.warp(contestedAt + 365 days);
        assertEq(registry.activeAuthorityOf(artistId), artist, "lapsed at the locked year");
        registry.expireContest(artistId);
        assertEq(s.stagedAt, contestedAt);

        // And the other way: staged under 730 days, a shorter setting does not lapse it early.
        _stageAuthorityOverride();
        vm.prank(wallet);
        registry.cancelChange(artistId);
        contestedAt = block.timestamp;
        _set(CONTEST, 365 days);
        vm.warp(contestedAt + 365 days);
        assertEq(registry.activeAuthorityOf(artistId), address(0), "still restrained");
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.ContestNotExpired.selector, artistId, uint64(contestedAt + 730 days)
            )
        );
        registry.expireContest(artistId);
    }

    /// @dev Dormancy is read when an override is staged: a longer setting protects a silent
    ///      artist from then on.
    function test_Dormancy_LongerSettingAppliesToNewStagings() public {
        _set(DORMANCY, 730 days);
        (, uint64 last) = registry.artist(artistId);
        vm.warp(last + 365 days);
        _armRevert(abi.encodeWithSelector(IArtistRegistry.NotDormant.selector, artistId, last));
        _stageOverride(ChangeKind.LOST_KEY, _identity(newAuthority, payout), newKey);
        vm.warp(last + 730 days);
        _stageOverride(ChangeKind.LOST_KEY, _identity(newAuthority, payout), newKey);
    }

    /// @dev The standing grace in force when a refresh runs decides a missing wallet's removal.
    function test_Grace_LongerSettingKeepsAMissingWallet() public {
        _set(GRACE, 90 days);
        _revoke(artist, wallet);
        registry.refreshStanding(artistId);
        uint256 missing = block.timestamp;
        vm.warp(missing + 30 days);
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId).length, 1, "kept beyond 30 days");
        vm.warp(missing + 90 days);
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId).length, 0);
    }

    // ----------------------------------------------------------------- helpers

    struct ChangeKindStage {
        uint64 stagedAt;
    }

    function _stageAuthorityOverride() internal returns (ChangeKindStage memory s) {
        s.stagedAt = uint64(block.timestamp);
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, newAuthority), newKey);
        PendingChange memory p = registry.pendingChange(artistId);
        assertEq(p.stagedAt, s.stagedAt);
    }

    function _set(IArtistRegistry.Timer which, uint48 value) internal {
        vm.prank(successorSetter);
        registry.setTimer(which, value);
    }
}
