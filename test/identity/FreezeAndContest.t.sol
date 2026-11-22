// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { ChangeKind } from "src/interfaces/types/IdentityTypes.sol";
import { IdentityFixture } from "./IdentityFixture.sol";

/// @notice How a freeze (14 days, the network at once) meets a network replacement (14 days'
///         notice, contestable during it) and the 90-day contested lapse.
contract FreezeAndContestTest is IdentityFixture {
    /// @dev A freeze and a replacement placed together cover the same 14 days to the second:
    ///      the account is frozen for the whole notice, so no wallet can contest, and at the
    ///      notice's end the freeze is over and anyone executes the replacement.
    function test_FreezeWithReplacement_LeavesNoMomentToContest() public {
        vm.prank(network);
        registry.freeze(artistId);
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        uint48 until = registry.frozenUntil(artistId);
        uint48 executableAt = registry.pendingChange(artistId).executableAt;
        assertEq(until, executableAt, "the freeze ends exactly when the notice does");

        vm.warp(executableAt - 1); // the last second of the notice: still frozen
        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.AccountIsFrozen.selector, artistId, until)
        );
        registry.cancelChange(artistId);

        vm.warp(executableAt); // the first unfrozen second: the notice is over
        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.ContestWindowClosed.selector, artistId, executableAt
            )
        );
        registry.cancelChange(artistId);
        vm.prank(stranger);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), newRoot, "replaced without a contest or a vote");
    }

    /// @dev A contest made in time does not bind the network to a vote: it withdraws the contested
    ///      replacement (no delay), freezes, and stages it again (here with a fresh acceptance);
    ///      the new notice runs under the freeze and executes 14 days later. The 90-day lapse is
    ///      reached only if the network leaves the contested replacement in place.
    function test_ContestedReplacement_IsRestagedUnderAFreezeAndExecutesWithoutAVote() public {
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        assertGt(registry.pendingChange(artistId).contestedAt, 0, "contested");

        vm.warp(block.timestamp + 1 hours);
        vm.startPrank(network);
        registry.cancelReplacement(artistId);
        registry.freeze(artistId);
        vm.stopPrank();
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.REPLACEMENT));
        assertEq(registry.pendingChange(artistId).contestedAt, 0, "the new notice is uncontested");

        vm.warp(registry.pendingChange(artistId).executableAt);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), newRoot);
    }

    /// @dev ID-8: a second `freeze` is refused while one runs, but `unfreeze` and `freeze` are
    ///      both the network's at once, so one batch renews a running freeze for a full 14 days
    ///      from now, with no moment in between when the account is unfrozen.
    function test_AFreezeIsRenewedWhileItRunsByUnfreezeThenFreeze() public {
        vm.prank(network);
        registry.freeze(artistId);
        uint48 first = registry.frozenUntil(artistId);
        vm.warp(block.timestamp + 13 days);
        vm.startPrank(network);
        registry.unfreeze(artistId);
        registry.freeze(artistId);
        vm.stopPrank();
        assertEq(registry.frozenUntil(artistId), first + 13 days, "renewed from now");
        assertFalse(registry.isWallet(artistId, artist), "never unfrozen in between");
    }
}
