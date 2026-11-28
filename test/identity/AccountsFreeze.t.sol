// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { ChangeKind } from "src/interfaces/types/IdentityTypes.sol";
import { AccountsFixture } from "./AccountsFixture.sol";

/// @notice How a freeze (14 days, the network at once) meets a network replacement (14 days'
///         notice, contestable during it): a freeze blocks a contest of a replacement, and a
///         freeze can be placed again.
contract AccountsFreezeTest is AccountsFixture {
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

    /// @dev A contest made in time does not bind the network to a vote: it withdraws the
    ///      contested replacement, freezes, and stages it again; the new notice runs under the
    ///      freeze and executes 14 days later.
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

        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.AccountIsFrozen.selector, artistId, registry.frozenUntil(artistId)
            )
        );
        registry.cancelChange(artistId);

        vm.warp(registry.pendingChange(artistId).executableAt);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), newRoot);
    }

    /// @dev A freeze can be placed again while one runs, by `unfreeze` then `freeze`: the
    ///      account is never unfrozen in between and the new freeze runs a full period from now.
    function test_AFreezeCanBePlacedAgainByUnfreezeThenFreeze() public {
        vm.prank(network);
        registry.freeze(artistId);
        uint48 first = registry.frozenUntil(artistId);
        vm.warp(block.timestamp + 13 days);
        vm.startPrank(network);
        registry.unfreeze(artistId);
        registry.freeze(artistId);
        vm.stopPrank();
        assertEq(registry.frozenUntil(artistId), first + 13 days, "a full period from now");
        assertFalse(registry.isWallet(artistId, artist), "never unfrozen in between");
        assertEq(registry.payoutAddress(artistId), address(0));
    }

    /// @dev Once a freeze ended, the network may freeze the account again at once.
    function test_AFreezeCanBePlacedAgainAfterItEnded() public {
        vm.prank(network);
        registry.freeze(artistId);
        uint48 first = registry.frozenUntil(artistId);
        vm.warp(first);
        assertTrue(registry.isWallet(artistId, wallet), "the freeze ended");
        vm.expectEmit(address(registry));
        emit IArtistRegistry.AccountFrozen(artistId, first + 14 days);
        vm.prank(network);
        registry.freeze(artistId);
        assertEq(registry.frozenUntil(artistId), first + 14 days);
        assertFalse(registry.isWallet(artistId, wallet));
    }

    /// @dev `freeze` is refused while a freeze runs, up to its last second.
    function testFuzz_Freeze_RefusedWhileOneRuns(uint256 elapsed) public {
        vm.prank(network);
        registry.freeze(artistId);
        uint48 until = registry.frozenUntil(artistId);
        elapsed = bound(elapsed, 0, 14 days - 1);
        vm.warp(block.timestamp + elapsed);
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.AccountIsFrozen.selector, artistId, until)
        );
        registry.freeze(artistId);
    }

    /// @dev A freeze blocks a contest: no wallet, root included, contests during it, however the
    ///      freeze and the notice overlap; the network can still withdraw its replacement.
    function testFuzz_Contest_RefusedWhileFrozen(uint256 stagedAfter, uint256 triedAfter) public {
        vm.prank(network);
        registry.freeze(artistId);
        uint48 until = registry.frozenUntil(artistId);
        stagedAfter = bound(stagedAfter, 0, 14 days - 1);
        vm.warp(block.timestamp + stagedAfter);
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        triedAfter = bound(triedAfter, block.timestamp, uint256(until) - 1);
        vm.warp(triedAfter);
        address[2] memory wallets = [artist, wallet];
        for (uint256 i; i < wallets.length; ++i) {
            vm.prank(wallets[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IArtistRegistry.AccountIsFrozen.selector, artistId, until)
            );
            registry.cancelChange(artistId);
        }
        assertEq(registry.pendingChange(artistId).contestedAt, 0);
        vm.prank(network);
        registry.cancelReplacement(artistId);
    }
}
