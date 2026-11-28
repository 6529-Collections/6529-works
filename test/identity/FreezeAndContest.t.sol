// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Accounts } from "src/identity/Accounts.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { ArtistIdentity, ChangeKind } from "src/interfaces/types/IdentityTypes.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice PR 118's freeze-and-contest cases on the deployed stack, under the genesis policy:
///         `freeze`, `unfreeze` and `cancelReplacement` are the network's at once, but
///         `stageReplacement` is PARAMETER_SETTER (24 hours, scheduled through the manager).
///         A freeze (14 days) and a replacement notice (14 days) cover the same seconds only
///         when the freeze is placed in the block that executes the scheduled replacement; a
///         freeze placed when the replacement is scheduled ends 24 hours before the notice and
///         leaves its last day open to a contest. The unit cases are `AccountsFreeze.t.sol`.
contract FreezeAndContestTest is IntegrationBase {
    address internal constant ALL = 0x8888888888888888888888888888888888888888;
    uint256 internal constant CONSOLIDATION = 999;
    bytes32 internal constant EVIDENCE = keccak256("replacement evidence");

    address internal lead;
    address internal wallet;
    address internal newRoot;
    uint256 internal artistId;

    function setUp() public virtual override {
        super.setUp();
        lead = _actor("freezeLead");
        wallet = _actor("freezeWallet");
        newRoot = _actor("freezeNewRoot");
        _publish(_one(_work(lead, collectionId))); // the lead's acceptance registers the account
        artistId = accounts.artistIdOf(lead);
        assertGt(artistId, 0, "registered");
        _consolidate(lead, wallet);
        assertTrue(accounts.isWallet(artistId, wallet));
    }

    function _consolidate(address a, address b) internal {
        vm.prank(a);
        delegation.registerDelegationAddress(ALL, b, type(uint64).max, CONSOLIDATION, true, 0);
        vm.prank(b);
        delegation.registerDelegationAddress(ALL, a, type(uint64).max, CONSOLIDATION, true, 0);
    }

    /// @dev The replacement to `newRoot`, accepted by it, its acceptance valid for 3 days (it
    ///      must outlast the 24-hour schedule). `salt` changes the deadline, so a restage signs
    ///      a fresh acceptance.
    function _replacement(uint256 salt) internal view returns (bytes memory) {
        ArtistIdentity memory next =
            ArtistIdentity(newRoot, newRoot, _profileId(newRoot), _profileDoc(newRoot));
        uint64 deadline = uint64(block.timestamp + 3 days + salt);
        bytes memory acceptance =
            _sign(newRoot, accounts.replacementDigest(artistId, next, EVIDENCE, deadline));
        return abi.encodeCall(
            Accounts.stageReplacement, (artistId, next, EVIDENCE, deadline, acceptance)
        );
    }

    /// @dev Schedules `data` on the accounts module as the network; returns when it is due.
    function _schedule(bytes memory data) internal returns (uint256 due) {
        (bool immediate, uint32 delay) = manager.canCall(network, address(accounts), bytes4(data));
        assertFalse(immediate);
        assertEq(delay, 24 hours, "stageReplacement is PARAMETER_SETTER");
        vm.prank(network);
        manager.schedule(address(accounts), data, 0);
        due = block.timestamp + delay;
    }

    function _execute(bytes memory data) internal {
        vm.prank(network);
        manager.execute(address(accounts), data);
    }

    function _freeze() internal {
        _asNetwork(address(accounts), abi.encodeCall(Accounts.freeze, (artistId)));
    }

    function _expectFrozen(address who) internal {
        vm.prank(who);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.AccountIsFrozen.selector, artistId, accounts.frozenUntil(artistId)
            )
        );
        accounts.cancelChange(artistId);
    }

    /// @dev The network schedules the replacement, then in the block that executes it freezes
    ///      first: the freeze ends exactly when the notice does, no wallet can contest at any
    ///      second of it, and at its end anyone executes the replacement.
    function test_FreezeInTheExecutingBlock_LeavesNoMomentToContest() public {
        bytes memory data = _replacement(0);
        vm.warp(_schedule(data));
        _freeze();
        _execute(data);
        uint48 until = accounts.frozenUntil(artistId);
        uint48 executableAt = accounts.pendingChange(artistId).executableAt;
        assertEq(until, executableAt, "the freeze ends exactly when the notice does");

        vm.warp(executableAt - 1);
        _expectFrozen(wallet);
        _expectFrozen(lead);

        vm.warp(executableAt);
        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.ContestWindowClosed.selector, artistId, executableAt
            )
        );
        accounts.cancelChange(artistId);
        vm.prank(makeAddr("anyone"));
        accounts.executeChange(artistId);
        assertEq(accounts.authorityOf(artistId), newRoot, "replaced without a contest or a vote");
        assertEq(accounts.artistIdOf(newRoot), artistId);
    }

    /// @dev A freeze placed when the replacement is scheduled ends 24 hours before the notice:
    ///      a wallet contests in that last day and the replacement can no longer execute on its
    ///      own. (Operational: the network freezes in the executing block, as above.)
    function test_FreezeWhenScheduling_LeavesTheNoticesLastDayToContest() public {
        bytes memory data = _replacement(0);
        _freeze();
        uint48 until = accounts.frozenUntil(artistId);
        vm.warp(_schedule(data));
        _execute(data);
        uint48 executableAt = accounts.pendingChange(artistId).executableAt;
        assertEq(executableAt - until, 24 hours, "the freeze ends a day early");

        vm.warp(until - 1);
        _expectFrozen(wallet);
        vm.warp(until);
        vm.expectEmit(address(accounts));
        emit IArtistRegistry.ChangeContested(artistId, wallet, bytes32(0));
        vm.prank(wallet);
        accounts.cancelChange(artistId);

        vm.warp(executableAt);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.ReplacementContested.selector, artistId)
        );
        accounts.executeChange(artistId);
        assertEq(accounts.authorityOf(artistId), lead);
    }

    /// @dev A contest made in time does not bind the network to a vote: it withdraws the
    ///      contested replacement and freezes at once, schedules it again with a fresh
    ///      acceptance, and in the executing block renews the freeze (`unfreeze` then `freeze`,
    ///      never unfrozen in between) so it covers the whole new notice, which then executes.
    function test_ContestedReplacement_IsRestagedUnderARenewedFreezeAndExecutes() public {
        bytes memory first = _replacement(0);
        vm.warp(_schedule(first));
        _execute(first);
        vm.prank(wallet);
        accounts.cancelChange(artistId);
        assertGt(accounts.pendingChange(artistId).contestedAt, 0, "contested");

        vm.warp(block.timestamp + 1 hours);
        _asNetwork(address(accounts), abi.encodeCall(Accounts.cancelReplacement, (artistId)));
        _freeze();
        assertEq(uint8(accounts.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        assertFalse(accounts.isWallet(artistId, wallet), "frozen");

        bytes memory again = _replacement(1);
        vm.warp(_schedule(again));
        assertFalse(accounts.isWallet(artistId, wallet), "still frozen while the restage waits");
        vm.startPrank(network);
        accounts.unfreeze(artistId);
        accounts.freeze(artistId);
        manager.execute(address(accounts), again);
        vm.stopPrank();
        uint48 executableAt = accounts.pendingChange(artistId).executableAt;
        assertEq(accounts.frozenUntil(artistId), executableAt, "renewed to cover the notice");
        assertEq(accounts.pendingChange(artistId).contestedAt, 0, "the new notice is uncontested");

        vm.warp(executableAt - 1);
        _expectFrozen(wallet);
        vm.warp(executableAt);
        accounts.executeChange(artistId);
        assertEq(accounts.authorityOf(artistId), newRoot);
    }

    /// @dev A contested replacement the network leaves in place lapses after 90 days: anyone
    ///      clears it and the account's wallets act again.
    function test_ContestedReplacement_LapsesAfterNinetyDays() public {
        bytes memory data = _replacement(0);
        vm.warp(_schedule(data));
        _execute(data);
        assertFalse(accounts.isWallet(artistId, wallet), "a pending replacement blocks wallets");
        vm.prank(wallet);
        accounts.cancelChange(artistId);
        uint48 contestedAt = accounts.pendingChange(artistId).contestedAt;

        vm.warp(uint256(contestedAt) + accounts.CONTEST_LAPSE() - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.ContestNotExpired.selector,
                artistId,
                contestedAt + accounts.CONTEST_LAPSE()
            )
        );
        accounts.expireContest(artistId);
        vm.warp(uint256(contestedAt) + accounts.CONTEST_LAPSE());
        assertTrue(accounts.isWallet(artistId, wallet), "a lapsed contest no longer blocks");
        vm.expectEmit(address(accounts));
        emit IArtistRegistry.ContestExpired(artistId);
        vm.prank(makeAddr("anyone"));
        accounts.expireContest(artistId);
        assertEq(uint8(accounts.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        assertEq(accounts.authorityOf(artistId), lead);
        assertEq(accounts.reservedFor(newRoot), 0, "the new root is free again");
    }
}
