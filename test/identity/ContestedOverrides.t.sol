// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "src/interfaces/types/IdentityTypes.sol";
import {
    DisputeOutcomeLogMock,
    HostileResolverMock,
    PullOnlyPayeeMock,
    SplitFactoryWalletsMock
} from "../mocks/identity/IdentityWorksMocks.sol";
import { IdentityFixture } from "./IdentityFixture.sol";
import { Dependency } from "src/libraries/Dependency.sol";

/// @notice Contested overrides (ADR 0003 owner decision 1): a captured wallet's cancel during
///         the notice turns a 180-day override into a contest that a TDH vote, recorded after
///         the contest, resolves through the governed `resolveContested`; the guardian may veto
///         it and it lapses after a year.
contract ContestedOverridesTest is IdentityFixture {
    DisputeOutcomeLogMock internal outcomes;
    address internal thiefWallet = makeAddr("thiefWallet");
    bytes32 internal constant VOTE = keccak256("tdh vote outcome");
    bytes32 internal constant EARLIER_VOTE = keccak256("an earlier vote");

    function setUp() public override {
        super.setUp();
        outcomes = new DisputeOutcomeLogMock(address(registry));
        vm.prank(admin);
        registry.bindStatementLog(address(outcomes));
    }

    /// @dev A thief who held the key for 30 days consolidated a wallet of their own, recorded by
    ///      a refresh; the network's recovery override captures it, and its cancel contests the
    ///      override instead of killing it.
    function _contestedByTheThief() internal returns (PendingChange memory p) {
        _consolidate(artist, thiefWallet);
        vm.warp(block.timestamp + 31 days);
        registry.refreshStanding(artistId);
        p = _stageAndContest();
    }

    function _stageAndContest() internal returns (PendingChange memory) {
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, newAuthority), newKey);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeContested(artistId, thiefWallet);
        vm.prank(thiefWallet);
        registry.cancelChange(artistId);
        return registry.pendingChange(artistId);
    }

    function _resolve(bool uphold, bytes32 ref) internal {
        vm.prank(successorSetter);
        registry.resolveContested(artistId, uphold, ref);
    }

    function test_Contest_ThiefWalletContestsAndThePayoutStaysFrozen() public {
        PullOnlyPayeeMock payee = new PullOnlyPayeeMock{ value: 1 ether }(registry, artistId);
        PendingChange memory p = _contestedByTheThief();
        assertEq(uint8(p.kind), uint8(ChangeKind.CONTESTED));
        assertEq(p.contestedAt, block.timestamp);
        assertEq(p.priorOutcome, bytes32(0), "no outcome recorded yet");
        assertEq(registry.payoutAddress(artistId), address(0), "frozen during the dispute");
        vm.expectRevert(
            abi.encodeWithSelector(PullOnlyPayeeMock.NotPayoutAddress.selector, artist, address(0))
        );
        vm.prank(artist); // the thief, holding the payout key
        payee.release();

        vm.prank(wallet); // a further cancel does nothing
        registry.cancelChange(artistId);
        assertEq(keccak256(abi.encode(registry.pendingChange(artistId))), keccak256(abi.encode(p)));

        vm.warp(p.executableAt + 1 days);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.OverrideContested.selector, artistId)
        );
        registry.executeChange(artistId);
    }

    function test_Contest_VoteUpholdsAndTheArtistRecovers() public {
        PullOnlyPayeeMock payee = new PullOnlyPayeeMock{ value: 1 ether }(registry, artistId);
        PendingChange memory p = _contestedByTheThief();
        outcomes.setOutcome(address(registry), artistId, VOTE);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.ChangeNotDue.selector, artistId, p.executableAt)
        );
        _resolve(true, VOTE);

        vm.warp(p.executableAt);
        assertEq(registry.activeAuthorityOf(artistId), address(0), "restrained while contested");
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ContestResolved(artistId, true, true, VOTE);
        _resolve(true, VOTE);
        assertEq(registry.authorityOf(artistId), newAuthority);
        assertEq(registry.activeAuthorityOf(artistId), newAuthority);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        (, uint64 last) = registry.artist(artistId);
        assertEq(last, block.timestamp, "the installed identity's clock restarts");
        vm.prank(newAuthority);
        payee.release();
        assertEq(newAuthority.balance, 1 ether);
    }

    function test_Contest_VoteVoidsAndThePayoutUnfreezes() public {
        _contestedByTheThief();
        outcomes.setOutcome(address(registry), artistId, VOTE);
        (, uint64 before) = registry.artist(artistId);
        vm.warp(block.timestamp + 10 days);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, successorSetter, true);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ContestResolved(artistId, false, false, VOTE);
        _resolve(false, VOTE);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        assertEq(registry.payoutAddress(artistId), artist);
        assertEq(registry.activeAuthorityOf(artistId), artist, "a void lifts the restraint");
        assertEq(registry.reservedFor(newAuthority), 0, "a void releases the reservation");
        (, uint64 last) = registry.artist(artistId);
        assertEq(last, before, "a governed void is not artist activity");
    }

    function test_Contest_GuardianVetoVoids() public {
        _contestedByTheThief();
        vm.prank(guardian);
        registry.vetoChange(artistId);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        assertEq(registry.payoutAddress(artistId), artist);
    }

    function test_Contest_LapsesAfterAYear() public {
        PendingChange memory p = _contestedByTheThief();
        uint64 expiresAt = p.contestedAt + 365 days;
        vm.warp(expiresAt - 1);
        assertEq(registry.payoutAddress(artistId), address(0));
        assertEq(registry.activeAuthorityOf(artistId), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.ContestNotExpired.selector, artistId, expiresAt)
        );
        registry.expireContest(artistId);

        vm.warp(expiresAt);
        assertEq(registry.payoutAddress(artistId), artist, "a lapsed contest no longer freezes");
        assertEq(registry.activeAuthorityOf(artistId), artist, "nor restrains");
        outcomes.setOutcome(address(registry), artistId, VOTE);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NotContested.selector, artistId));
        _resolve(false, VOTE);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.OverrideContested.selector, artistId)
        );
        registry.executeChange(artistId);
        _armRevert(abi.encodeWithSelector(IArtistRegistry.ChangePending.selector, artistId));
        _stage(artistKey, _identity(artist, payout), 0);

        (, uint64 before) = registry.artist(artistId);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ContestExpired(artistId);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, address(registry), false);
        assertEq(registry.reservedFor(newAuthority), artistId, "reserved until it ends");
        vm.prank(stranger);
        registry.expireContest(artistId);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        assertEq(registry.reservedFor(newAuthority), 0, "a lapse releases the reservation");
        (, uint64 last) = registry.artist(artistId);
        assertEq(last, before, "expiry is not artist activity");
        _stage(artistKey, _identity(artist, payout), 0);
    }

    // ----------------------------------------------------------------- M1: the vote is fresh

    /// @dev Review PoC, now reverting: a vote recorded for an earlier contest cannot resolve a
    ///      later, unrelated one.
    function test_M1_StaleOutcomeFromAnEarlierContestIsRejected() public {
        _contestedByTheThief();
        outcomes.setOutcome(address(registry), artistId, EARLIER_VOTE);
        _resolve(false, EARLIER_VOTE);

        vm.warp(block.timestamp + 400 days);
        PendingChange memory p = _stageAndContest(); // no new vote recorded
        assertEq(p.priorOutcome, EARLIER_VOTE);
        vm.warp(p.executableAt);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.OutcomePredatesContest.selector, artistId, EARLIER_VOTE
            )
        );
        _resolve(true, EARLIER_VOTE);
        assertEq(registry.authorityOf(artistId), artist, "not upheld on a stale vote");

        outcomes.setOutcome(address(registry), artistId, VOTE); // the vote on this contest
        _resolve(true, VOTE);
        assertEq(registry.authorityOf(artistId), newAuthority);
    }

    /// @dev Review PoC, now reverting: an outcome recorded before the contest existed does not
    ///      count.
    function test_M1_OutcomeRecordedBeforeTheContestIsRejected() public {
        outcomes.setOutcome(address(registry), artistId, EARLIER_VOTE);
        vm.warp(block.timestamp + 10 days);
        PendingChange memory p = _contestedByTheThief();
        vm.warp(p.executableAt);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.OutcomePredatesContest.selector, artistId, EARLIER_VOTE
            )
        );
        _resolve(true, EARLIER_VOTE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.OutcomePredatesContest.selector, artistId, EARLIER_VOTE
            )
        );
        _resolve(false, EARLIER_VOTE);
    }

    // ----------------------------------------------------------------- L3: contests in the notice

    /// @dev Review PoC, now reverting: a captured wallet cannot contest once the notice ended, so
    ///      it cannot front-run a due execution.
    function test_L3_LateContestIsRefusedAndExecutionProceeds() public {
        _consolidate(artist, thiefWallet);
        vm.warp(block.timestamp + 31 days);
        registry.refreshStanding(artistId);
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, newAuthority), newKey);
        PendingChange memory p = registry.pendingChange(artistId);
        vm.warp(p.executableAt);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.ContestWindowClosed.selector, artistId, p.executableAt
            )
        );
        vm.prank(thiefWallet);
        registry.cancelChange(artistId);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), newAuthority);
    }

    /// @dev Every contest falls inside the notice, so the uphold window, from the notice's end
    ///      to the lapse, is always at least 185 days: no deadlock.
    function testFuzz_L3_UpholdWindowAlwaysOpen(uint256 contestDelay) public {
        _consolidate(artist, thiefWallet);
        vm.warp(block.timestamp + 31 days);
        registry.refreshStanding(artistId);
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, newAuthority), newKey);
        PendingChange memory s = registry.pendingChange(artistId);
        contestDelay = bound(contestDelay, 0, 180 days - 1);
        vm.warp(block.timestamp + contestDelay);
        vm.prank(thiefWallet);
        registry.cancelChange(artistId);
        PendingChange memory p = registry.pendingChange(artistId);
        uint256 lapseAt = uint256(p.contestedAt) + 365 days;
        assertEq(p.executableAt, s.executableAt);
        assertGe(lapseAt - p.executableAt, 185 days);
        outcomes.setOutcome(address(registry), artistId, VOTE);
        vm.warp(lapseAt - 1);
        _resolve(true, VOTE);
        assertEq(registry.authorityOf(artistId), newAuthority);
    }

    // ----------------------------------------------------------------- resolution errors

    function test_Resolve_RevertsForAMismatchedOrZeroOutcome() public {
        PendingChange memory p = _contestedByTheThief();
        vm.warp(p.executableAt);
        outcomes.setOutcome(address(registry), artistId, VOTE);
        bytes32 wrong = keccak256("another vote");
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.OutcomeNotRecorded.selector, artistId, wrong)
        );
        _resolve(true, wrong);
        outcomes.setOutcome(address(registry), artistId, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.OutcomeNotRecorded.selector, artistId, bytes32(0)
            )
        );
        _resolve(true, bytes32(0));
        // An outcome recorded for another subject does not count.
        outcomes.setOutcome(address(stranger), artistId, VOTE);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.OutcomeNotRecorded.selector, artistId, VOTE)
        );
        _resolve(true, VOTE);
    }

    function test_Resolve_RevertsWithoutABoundStatementLog() public {
        ArtistIdentity memory next = _identity(newAuthority, newAuthority);
        IdentityFixture.setUp(); // a fresh registry with no statement log bound
        _consolidate(artist, thiefWallet);
        vm.warp(block.timestamp + 31 days);
        registry.refreshStanding(artistId);
        _stageOverride(ChangeKind.CONTESTED, next, newKey);
        vm.prank(thiefWallet);
        registry.cancelChange(artistId);
        assertEq(registry.statementLog(), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.OutcomeNotRecorded.selector, artistId, VOTE)
        );
        _resolve(false, VOTE);
    }

    function test_Resolve_RevertsForAWrongCaller() public {
        _contestedByTheThief();
        outcomes.setOutcome(address(registry), artistId, VOTE);
        address[3] memory callers = [guardian, governor, thiefWallet];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManaged.AccessManagedUnauthorized.selector, callers[i]
                )
            );
            vm.prank(callers[i]);
            registry.resolveContested(artistId, true, VOTE);
        }
    }

    function test_Resolve_RevertsWithoutAContest() public {
        outcomes.setOutcome(address(registry), artistId, VOTE);
        bytes memory notContested =
            abi.encodeWithSelector(IArtistRegistry.NotContested.selector, artistId);
        vm.expectRevert(notContested);
        _resolve(true, VOTE); // nothing pending
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, newAuthority), newKey);
        vm.expectRevert(notContested);
        _resolve(true, VOTE); // an uncontested override
        vm.prank(guardian);
        registry.vetoChange(artistId);
        _stage(artistKey, _identity(artist, payout), 0);
        vm.prank(wallet);
        registry.cancelChange(artistId); // a STANDARD change still dies on cancel
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        vm.expectRevert(notContested);
        _resolve(true, VOTE);
        vm.expectRevert(notContested);
        registry.expireContest(artistId);
    }

    /// @dev Upholding re-checks the change as execution does: a payout that became a split
    ///      wallet clears the override, and the event says nothing executed.
    function test_Resolve_UpholdRechecksAtExecution() public {
        SplitFactoryWalletsMock factory = new SplitFactoryWalletsMock();
        vm.prank(admin);
        registry.bindSplitFactory(address(factory));
        PendingChange memory p = _contestedByTheThief();
        factory.setWallet(newAuthority, true);
        outcomes.setOutcome(address(registry), artistId, VOTE);
        vm.warp(p.executableAt);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, address(registry), false);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ContestResolved(artistId, true, false, VOTE);
        _resolve(true, VOTE);
        assertEq(registry.authorityOf(artistId), artist);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
    }

    function test_Contest_IsActivityOnlyForTheCapturedWallet() public {
        _consolidate(artist, thiefWallet);
        vm.warp(block.timestamp + 31 days);
        registry.refreshStanding(artistId);
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, newAuthority), newKey);
        vm.warp(block.timestamp + 1 days);
        vm.prank(thiefWallet);
        registry.cancelChange(artistId);
        (, uint64 contestedAt) = registry.artist(artistId);
        assertEq(contestedAt, block.timestamp, "the captured wallet's contest counts");
        vm.warp(block.timestamp + 1 days);
        vm.prank(wallet); // a no-op cancel records nothing
        registry.cancelChange(artistId);
        (, uint64 last) = registry.artist(artistId);
        assertEq(last, contestedAt);
    }

    function test_BindStatementLog_OneShotAndChecksTheResolver() public {
        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.AlreadyBound.selector, bytes32("STATEMENT_LOG"))
        );
        registry.bindStatementLog(address(outcomes));
        vm.stopPrank();
        assertEq(registry.statementLog(), address(outcomes));

        IdentityFixture.setUp();
        DisputeOutcomeLogMock foreign = new DisputeOutcomeLogMock(stranger);
        DisputeOutcomeLogMock mine = new DisputeOutcomeLogMock(address(registry));
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        registry.bindStatementLog(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.InvalidBinding.selector, address(foreign))
        );
        registry.bindStatementLog(address(foreign));
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.InvalidBinding.selector, address(adapter))
        );
        registry.bindStatementLog(address(adapter)); // no artistResolver()
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, governor)
        );
        vm.prank(governor);
        registry.bindStatementLog(address(mine));
        vm.expectEmit(address(registry));
        emit IArtistRegistry.Bound("STATEMENT_LOG", address(mine));
        vm.prank(admin);
        registry.bindStatementLog(address(mine));
    }

    /// The resolver read is bounded: a log that needs more than 50,000 gas or returns more than
    /// one word is refused, even when it names this registry.
    function test_BindStatementLog_ResolverReadIsBounded() public {
        IdentityFixture.setUp();
        HostileResolverMock fair = new HostileResolverMock(address(registry), 0, 32);
        HostileResolverMock hungry = new HostileResolverMock(address(registry), 60_000, 32);
        HostileResolverMock wide = new HostileResolverMock(address(registry), 0, 64);
        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.InvalidBinding.selector, address(hungry))
        );
        registry.bindStatementLog(address(hungry));
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.InvalidBinding.selector, address(wide))
        );
        registry.bindStatementLog(address(wide));
        registry.bindStatementLog(address(fair));
        vm.stopPrank();
        assertEq(registry.statementLog(), address(fair));
    }
}
