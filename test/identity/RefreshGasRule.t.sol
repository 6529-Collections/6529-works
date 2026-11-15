// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { IArtistRegistry, IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { ArtistIdentity, ChangeKind, Standing } from "src/interfaces/types/IdentityTypes.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import {
    DisputeOutcomeLogMock,
    FailingConsolidationSource,
    FederationRegistryStub
} from "../mocks/identity/IdentityWorksMocks.sol";
import {
    BurningConsolidationSource,
    MalformedConsolidationSource,
    StipendConsolidationSource
} from "../mocks/identity/PermanenceMocks.sol";
import { IdentityFixture } from "./IdentityFixture.sol";

/// @notice Review C: no gas limit a submitter chooses turns a standing refresh into a skip (F1),
///         every change of a standing entry's `effectiveAt` is logged (F6), a malformed source
///         answer reverts rather than skips (F7, documented), and `ConsolidationSourceSet` carries
///         the pinned code hash (F15).
contract RefreshGasRuleTest is IdentityFixture {
    uint256 internal constant SWEEP_FROM = 30_000;
    uint256 internal constant SWEEP_TO = 900_000;
    uint256 internal constant SWEEP_STEP = 2_500;

    address internal unrecorded = makeAddr("unrecordedWallet");
    address internal newWallet = makeAddr("newAuthorityWallet");
    bytes32 internal constant VOTE = keccak256("vote");

    function setUp() public override {
        super.setUp();
        // A wallet established with the artist that no refresh has recorded, and one established
        // with the key a rotation installs: every refresh below has work to do.
        _consolidate(artist, unrecorded);
        _consolidate(newAuthority, newWallet);
        vm.warp(block.timestamp + 31 days);
    }

    // ----------------------------------------------------------------- F1: the gas sweep

    function test_GasRule_HeartbeatNeverSkipsForGas() public {
        _sweep(artist, abi.encodeCall(IArtistRegistry.heartbeat, (artistId)), artistId, unrecorded);
    }

    function test_GasRule_StageChangeNeverSkipsForGas() public {
        ArtistIdentity memory next = _identity(artist, payout);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory signature = _sign(artistKey, _digest(next, deadline));
        bytes memory data = abi.encodeCall(
            IArtistRegistry.stageChange, (artistId, next, artist, deadline, signature, "")
        );
        _sweep(stranger, data, artistId, unrecorded);
        // A source with a larger fixed stipend leaves a staging enough gas to finish after a
        // skip, so only the rethrow keeps that gas limit from skipping the refresh.
        address fresh = _installStipendSource();
        _sweepRange(stranger, data, artistId, fresh, 200_000, 3_000_000, 20_000);
    }

    function test_GasRule_StageOverrideNeverSkipsForGas() public {
        _sweep(governor, _overrideCall(), artistId, unrecorded);
        address fresh = _installStipendSource();
        _sweepRange(governor, _overrideCall(), artistId, fresh, 200_000, 3_000_000, 20_000);
    }

    /// @dev Installs a fixed-gas source needing 1,000,000 gas per read, which reports a fresh
    ///      wallet; returns that wallet.
    function _installStipendSource() internal returns (address fresh) {
        fresh = makeAddr("stipendWallet");
        StipendConsolidationSource source = new StipendConsolidationSource(fresh, 1_000_000);
        vm.prank(successorSetter);
        registry.setConsolidationSource(
            adapter, IConsolidationSource(address(source)), address(source).codehash
        );
    }

    function test_GasRule_ExecuteChangeNeverSkipsForGas() public {
        _stage(artistKey, _identity(newAuthority, newAuthority), newKey);
        vm.warp(block.timestamp + 7 days);
        _sweep(
            stranger, abi.encodeCall(IArtistRegistry.executeChange, (artistId)), artistId, newWallet
        );
    }

    function test_GasRule_UpholdingResolveContestedNeverSkipsForGas() public {
        DisputeOutcomeLogMock outcomes = new DisputeOutcomeLogMock(address(registry));
        vm.prank(admin);
        registry.bindStatementLog(address(outcomes));
        (bool ok,) = _call(governor, _overrideCall(), type(uint64).max);
        assertTrue(ok);
        vm.prank(wallet);
        registry.cancelChange(artistId); // the recorded wallet contests
        vm.warp(block.timestamp + 180 days);
        outcomes.setOutcome(address(registry), artistId, VOTE);
        _sweep(
            successorSetter,
            abi.encodeCall(IArtistRegistry.resolveContested, (artistId, true, VOTE)),
            artistId,
            newWallet
        );
    }

    function test_GasRule_RegisterNeverSkipsForGas() public {
        address account = makeAddr("newArtist");
        address accountWallet = makeAddr("newArtistWallet");
        _consolidate(account, accountWallet);
        vm.warp(block.timestamp + 31 days);
        _sweep(
            packageRegistry,
            abi.encodeCall(IArtistRegistry.register, (account, PROFILE, PROFILE_DOC)),
            uint160(account),
            accountWallet
        );
    }

    function test_GasRule_RegisterFederatedNeverSkipsForGas() public {
        address federation = address(new FederationRegistryStub());
        vm.prank(admin);
        registry.bindFederationRegistry(federation);
        uint256 key = 0xFED;
        address account = vm.addr(key);
        address accountWallet = makeAddr("federatedWallet");
        _consolidate(account, accountWallet);
        vm.warp(block.timestamp + 31 days);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory signature =
            _sign(key, registry.registrationDigest(account, PROFILE, PROFILE_DOC, deadline));
        _sweep(
            federation,
            abi.encodeCall(
                IArtistRegistry.registerFederated,
                (account, PROFILE, PROFILE_DOC, deadline, signature)
            ),
            uint160(account),
            accountWallet
        );
    }

    /// @dev The convention in `IConsolidationSource`: a source that reports its caller's gas as
    ///      too little (`BoundedCallInsufficientGas`, `BoundedCallShortfall`) makes every
    ///      refresh revert with that error, however much gas is left; any other revert is still
    ///      skipped by a best-effort refresh. Fails without the change: both are skipped.
    function test_GasRule_ASourceReportingAShortfallIsRethrownNotSkipped() public {
        FailingConsolidationSource failing = new FailingConsolidationSource();
        vm.prank(successorSetter);
        registry.setConsolidationSource(
            adapter, IConsolidationSource(address(failing)), address(failing).codehash
        );
        failing.set(true, false, false);
        bytes[2] memory reasons = [
            abi.encodeWithSelector(BoundedCall.BoundedCallInsufficientGas.selector, 200_000),
            abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, address(1))
        ];
        for (uint256 i; i < 2; ++i) {
            failing.setReason(reasons[i]);
            vm.expectRevert(reasons[i]);
            vm.prank(artist);
            registry.heartbeat(artistId);
            vm.expectRevert(reasons[i]);
            _register(makeAddr("anotherArtist"));
        }
        failing.setReason(abi.encodeWithSelector(FailingConsolidationSource.Broken.selector));
        vm.expectEmit(address(registry));
        emit IArtistRegistry.StandingRefreshSkipped(artistId);
        vm.prank(artist);
        registry.heartbeat(artistId);
    }

    /// @dev A source burning 2, 4 and 10 times what the adapter needs, behind the heartbeat (the
    ///      trigger no other gas test covers): read in full with enough gas, a revert below it,
    ///      never a skip.
    function test_GasRule_HeartbeatReadsARepricedSourceAt2x4x10x() public {
        BurningConsolidationSource source = new BurningConsolidationSource(unrecorded, 1);
        vm.prank(successorSetter);
        registry.setConsolidationSource(
            adapter, IConsolidationSource(address(source)), address(source).codehash
        );
        uint256[3] memory factors = [uint256(2), 4, 10];
        for (uint256 i; i < 3; ++i) {
            source.set(factors[i] * 200_000, 1, false);
            _sweepRange(
                artist,
                abi.encodeCall(IArtistRegistry.heartbeat, (artistId)),
                artistId,
                unrecorded,
                100_000,
                factors[i] * 200_000 * 3,
                factors[i] * 20_000
            );
        }
    }

    // ----------------------------------------------------------------- F6: effectiveAt events

    /// @dev A pending entry following a later live clock, and an established entry moving
    ///      earlier, each emit `StandingAdded` with the new time, so a logs-only mirror of
    ///      `standingOf` stays exact. Fails without the change: neither is logged.
    function test_Standing_EveryEffectiveAtChangeIsLogged() public {
        // A pending entry: recorded young, then revoked and re-registered later (no refresh
        // saw the gap), so its live clock moves later.
        address young = makeAddr("youngWallet");
        _consolidate(artist, young);
        registry.refreshStanding(artistId);
        uint48 first = _effectiveAt(young);
        vm.warp(block.timestamp + 5 days);
        _revoke(artist, young);
        _revoke(young, artist);
        _consolidate(artist, young);
        uint48 later = uint48(block.timestamp + 30 days);
        assertGt(later, first);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.StandingAdded(artistId, young, later);
        registry.refreshStanding(artistId);
        assertEq(_effectiveAt(young), later);

        // An established entry moving earlier: a source reports an earlier start.
        BurningConsolidationSource source = new BurningConsolidationSource(wallet, 7);
        vm.prank(successorSetter);
        registry.setConsolidationSource(
            adapter, IConsolidationSource(address(source)), address(source).codehash
        );
        vm.expectEmit(address(registry));
        emit IArtistRegistry.StandingAdded(artistId, wallet, 7);
        registry.refreshStanding(artistId);
        assertEq(_effectiveAt(wallet), 7);

        // Nothing changed: no event.
        vm.recordLogs();
        registry.refreshStanding(artistId);
        assertFalse(_logged(IArtistRegistry.StandingAdded.selector, wallet), "no change, no log");
    }

    // ----------------------------------------------------------------- F7: malformed answers

    /// @dev Documented (LIM-ID-17): a source answer that is not a canonical encoding reverts the
    ///      call even on a best-effort path, because decoding happens outside the `try`. A source
    ///      that burns all gas has the same effect under the gas rule, so validating the encoding
    ///      would not narrow what a hostile source can do; a reviewed source pinned by code hash
    ///      cannot start answering this way. The authority's own calls that read no source
    ///      (`revokeNonce`, the authority's cancel) still record activity.
    function test_MalformedSourceAnswer_RevertsEvenOnABestEffortPath() public {
        MalformedConsolidationSource bad = new MalformedConsolidationSource();
        vm.prank(successorSetter);
        registry.setConsolidationSource(
            adapter, IConsolidationSource(address(bad)), address(bad).codehash
        );
        vm.expectRevert();
        vm.prank(artist);
        registry.heartbeat(artistId);
        vm.expectRevert();
        _register(makeAddr("anotherArtist"));
        vm.prank(artist);
        registry.revokeNonce(artistId);
        (, uint64 last) = registry.artist(artistId);
        assertEq(last, block.timestamp, "activity still recorded");
    }

    // ----------------------------------------------------------------- F15: the source event

    /// @dev `ConsolidationSourceSet` carries the pinned code hash, at deployment and on every
    ///      swap, so `consolidationSourceCodeHash` can be rebuilt from logs. Fails without the
    ///      change: the event has no code hash.
    function test_ConsolidationSourceSet_CarriesTheCodeHash() public {
        bytes32 hash = address(adapter).codehash;
        vm.expectEmit();
        emit IArtistRegistry.ConsolidationSourceSet(address(0), address(adapter), hash);
        ArtistRegistry fresh = new ArtistRegistry(address(manager), adapter, hash);
        assertEq(fresh.consolidationSourceCodeHash(), hash);

        FailingConsolidationSource next = new FailingConsolidationSource();
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ConsolidationSourceSet(
            address(adapter), address(next), address(next).codehash
        );
        vm.prank(successorSetter);
        registry.setConsolidationSource(
            adapter, IConsolidationSource(address(next)), address(next).codehash
        );
    }

    // ----------------------------------------------------------------- helpers

    function _overrideCall() internal view returns (bytes memory) {
        ArtistIdentity memory next = _identity(newAuthority, newAuthority);
        bytes32 evidence = keccak256("evidence");
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes memory acceptance = _sign(
            newKey,
            registry.overrideDigest(artistId, ChangeKind.CONTESTED, next, evidence, deadline)
        );
        return abi.encodeCall(
            IArtistRegistry.stageOverride,
            (artistId, ChangeKind.CONTESTED, next, evidence, deadline, acceptance)
        );
    }

    function _sweep(address caller, bytes memory data, uint256 id, address expectRecorded)
        internal
    {
        _sweepRange(caller, data, id, expectRecorded, SWEEP_FROM, SWEEP_TO, SWEEP_STEP);
    }

    /// @dev Calls `data` from `caller` at every gas limit in the range: a call either reverts or
    ///      succeeds without `StandingRefreshSkipped`, and the calls that succeed record
    ///      `expectRecorded` for artist `id` (the refresh ran).
    function _sweepRange(
        address caller,
        bytes memory data,
        uint256 id,
        address expectRecorded,
        uint256 from,
        uint256 to,
        uint256 step
    ) internal {
        uint256 successes;
        for (uint256 g = from; g <= to; g += step) {
            uint256 snapshot = vm.snapshotState();
            vm.recordLogs();
            (bool ok,) = _call(caller, data, g);
            if (ok) {
                ++successes;
                Vm.Log[] memory logs = vm.getRecordedLogs();
                bool recorded;
                for (uint256 i; i < logs.length; ++i) {
                    if (logs[i].emitter != address(registry) || logs[i].topics.length == 0) {
                        continue;
                    }
                    bytes32 topic = logs[i].topics[0];
                    assertTrue(
                        topic != IArtistRegistry.StandingRefreshSkipped.selector,
                        "a gas limit turned the refresh into a skip"
                    );
                    if (
                        topic == IArtistRegistry.StandingAdded.selector
                            && logs[i].topics[1] == bytes32(id)
                            && logs[i].topics[2] == bytes32(uint256(uint160(expectRecorded)))
                    ) recorded = true;
                }
                assertTrue(recorded, "the refresh ran");
            }
            vm.revertToState(snapshot);
        }
        assertGt(successes, 0, "the sweep reaches success");
    }

    function _call(address caller, bytes memory data, uint256 g)
        internal
        returns (bool ok, bytes memory out)
    {
        vm.prank(caller);
        (ok, out) = address(registry).call{ gas: g }(data);
    }

    function _effectiveAt(address w) internal view returns (uint48) {
        Standing[] memory s = registry.standingOf(artistId);
        for (uint256 i; i < s.length; ++i) {
            if (s[i].wallet == w) return s[i].effectiveAt;
        }
        revert("not recorded");
    }

    function _logged(bytes32 topic, address w) internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].topics.length > 2 && logs[i].topics[0] == topic
                    && logs[i].topics[2] == bytes32(uint256(uint160(w)))
            ) return true;
        }
        return false;
    }
}
