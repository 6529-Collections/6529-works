// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IArtistRegistry, IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "src/interfaces/types/IdentityTypes.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { FailingConsolidationSource } from "../mocks/identity/IdentityWorksMocks.sol";
import { EveryoneEstablishedSource } from "../mocks/identity/PermanenceMocks.sol";
import { IdentityFixture } from "./IdentityFixture.sol";

/// @notice Review C, F2: the artist registry is permanent and the consolidation source is not, so
///         the source decides nothing for a live artist. A wallet the source names may sign a
///         STANDARD change only for a dormant artist; that change waits the override delay,
///         records no activity, and the authority's own cancel ends it; heartbeats are the
///         authority's alone. Pinned here against a source that names every wallet.
contract ConsolidationTrustTest is IdentityFixture {
    EveryoneEstablishedSource internal hostile;
    uint256 internal constant NAMED_KEY = 0x5EED;
    address internal named;

    function setUp() public override {
        super.setUp();
        named = vm.addr(NAMED_KEY);
        address[] memory list = new address[](1);
        list[0] = named;
        hostile = new EveryoneEstablishedSource(list);
        vm.prank(successorSetter);
        registry.setConsolidationSource(
            adapter, IConsolidationSource(address(hostile)), address(hostile).codehash
        );
    }

    /// @dev A live artist (activity within the dormancy period): the named wallet can stage
    ///      nothing (`NotDormant`, before the source is read) and cannot heartbeat. Fails without
    ///      the change: it stages a change of authority and payout, and its heartbeat counts.
    function test_SourceCannotActForALiveArtist() public {
        vm.warp(block.timestamp + 364 days);
        (, uint64 last) = registry.artist(artistId);
        _armRevert(abi.encodeWithSelector(IArtistRegistry.NotDormant.selector, artistId, last));
        _stage(NAMED_KEY, _identity(named, named), NAMED_KEY);
        _armRevert(abi.encodeWithSelector(IArtistRegistry.NotDormant.selector, artistId, last));
        _stage(NAMED_KEY, _identity(artist, named), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.NotAuthorized.selector, artistId, named)
        );
        vm.prank(named);
        registry.heartbeat(artistId);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        assertEq(registry.payoutAddress(artistId), artist, "the payout never froze");
    }

    /// @dev The live check comes before any source read: a source that reverts on every read
    ///      still gives `NotDormant` for a live artist's wallet signer.
    function test_LiveCheckPrecedesTheSourceRead() public {
        FailingConsolidationSource failing = new FailingConsolidationSource();
        failing.set(true, true, true);
        vm.prank(successorSetter);
        registry.setConsolidationSource(
            IConsolidationSource(address(hostile)),
            IConsolidationSource(address(failing)),
            address(failing).codehash
        );
        (, uint64 last) = registry.artist(artistId);
        _armRevert(abi.encodeWithSelector(IArtistRegistry.NotDormant.selector, artistId, last));
        _stage(walletKey, _identity(artist, wallet), 0);
    }

    /// @dev For a dormant artist the wallet signer check reads the source and fails closed on a
    ///      source whose code no longer matches its pin (DEPS-6).
    function test_WalletSignerCheckFailsClosedOnAChangedSource() public {
        vm.warp(block.timestamp + 365 days);
        vm.etch(address(hostile), address(new FailingConsolidationSource()).code);
        _armRevert(
            abi.encodeWithSelector(Dependency.DependencyCodeChanged.selector, address(hostile))
        );
        _stage(NAMED_KEY, _identity(artist, named), 0);
    }

    /// @dev A dormant artist: the named wallet can stage, but the change waits the override
    ///      delay (180 days, not 7), records no activity, and the authority's own cancel ends it;
    ///      the cancel is activity, so the wallet cannot stage again for another dormancy period.
    function test_SourceGetsNoFasterPathThanAnOverride() public {
        vm.warp(block.timestamp + 365 days);
        (, uint64 before) = registry.artist(artistId);
        _stage(NAMED_KEY, _identity(named, named), NAMED_KEY);
        PendingChange memory p = registry.pendingChange(artistId);
        assertEq(uint8(p.kind), uint8(ChangeKind.STANDARD));
        assertEq(p.executableAt, block.timestamp + 180 days, "the override delay");
        (, uint64 last) = registry.artist(artistId);
        assertEq(last, before, "no activity recorded");
        assertEq(registry.payoutAddress(artistId), address(0), "frozen while it waits");
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.ChangeNotDue.selector, artistId, p.executableAt)
        );
        registry.executeChange(artistId);

        vm.prank(artist);
        registry.cancelChange(artistId);
        assertEq(registry.payoutAddress(artistId), artist);
        (, last) = registry.artist(artistId);
        _armRevert(abi.encodeWithSelector(IArtistRegistry.NotDormant.selector, artistId, last));
        _stage(NAMED_KEY, _identity(named, named), NAMED_KEY);
    }

    /// @dev Recovery is not blocked: a LOST_KEY override replaces the named wallet's pending
    ///      change, and the wallet can then stage nothing while the override waits.
    function test_AGovernedOverrideReplacesASourceStaging() public {
        vm.warp(block.timestamp + 365 days);
        _stage(NAMED_KEY, _identity(named, named), NAMED_KEY);
        _stageOverride(ChangeKind.LOST_KEY, _identity(newAuthority, newAuthority), newKey);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.LOST_KEY));
        _armRevert(abi.encodeWithSelector(IArtistRegistry.ChangePending.selector, artistId));
        _stage(NAMED_KEY, _identity(named, payout), 0);
        vm.warp(block.timestamp + 180 days);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), newAuthority);
    }

    /// @dev The residual, pinned: what the source does record is standing. A wallet it names is
    ///      captured as a canceller of the artist's own later changes, until a source swap and the
    ///      standing grace remove it.
    function test_Residual_ANamedWalletGainsStandingUntilSwappedAndAged() public {
        registry.refreshStanding(artistId);
        _stage(artistKey, _identity(artist, payout), 0);
        address[] memory cancellers = _cancellers();
        bool captured;
        for (uint256 i; i < cancellers.length; ++i) {
            captured = captured || cancellers[i] == named;
        }
        assertTrue(captured, "the named wallet is a canceller");
        vm.prank(named);
        registry.cancelChange(artistId);

        vm.prank(successorSetter);
        registry.setConsolidationSource(
            IConsolidationSource(address(hostile)), adapter, address(adapter).codehash
        );
        registry.refreshStanding(artistId); // marked missing
        vm.warp(block.timestamp + 30 days);
        registry.refreshStanding(artistId); // removed after the grace
        _stage(artistKey, _identity(artist, payout), 0);
        cancellers = _cancellers();
        for (uint256 i; i < cancellers.length; ++i) {
            assertTrue(cancellers[i] != named, "gone after the swap and the grace");
        }
    }
}
