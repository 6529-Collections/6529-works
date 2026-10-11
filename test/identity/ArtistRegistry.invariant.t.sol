// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ArtistIdentity, ChangeKind, PendingChange } from "src/interfaces/types/IdentityTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { ArtistRegistryHandler, IdentityActors } from "./ArtistRegistryHandler.sol";
import { IdentityFixture } from "./IdentityFixture.sol";

/// @notice Stateful invariants for the artist registry (ADR 0001 section 11). The handler stages,
///         overrides, cancels, vetoes, replays, executes and moves time and consolidations; run
///         with the foundry.toml campaign (256 runs x depth 128, `fail_on_revert`).
contract ArtistRegistryInvariantTest is IdentityFixture {
    ArtistRegistryHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ArtistRegistryHandler(
            IdentityActors({
                registry: registry,
                adapter: adapter,
                delegation: delegation,
                artistId: artistId,
                guardian: guardian,
                governor: governor,
                packageRegistry: packageRegistry,
                keys: [artistKey, walletKey, newKey, thiefKey],
                payouts: [artist, payout, makeAddr("estatePayout")]
            })
        );
        targetContract(address(handler));
    }

    /// @dev The payout address and the authority change only through executed changes: they
    ///      always equal the ghosts, which only a successful `executeChange` updates. The payout
    ///      resolves to zero exactly while an override, or a change that moves it, is pending.
    function invariant_PayoutChangesOnlyThroughExecutedChanges() public view {
        (ArtistIdentity memory identity,) = registry.artist(artistId);
        assertEq(identity.payout, handler.ghostPayout());
        assertEq(registry.authorityOf(artistId), handler.ghostAuthority());
        PendingChange memory p = registry.pendingChange(artistId);
        bool frozen = p.kind != ChangeKind.NONE
            && (p.kind != ChangeKind.STANDARD || p.next.payout != identity.payout);
        assertEq(registry.payoutAddress(artistId), frozen ? address(0) : handler.ghostPayout());
    }

    /// @dev Every executed change waited its full delay (7 days, or 180 for overrides); no
    ///      unauthorised stage, cancel or guardian redirect succeeded; no used payload replayed;
    ///      no ESTATE or LOST_KEY override was staged within a year of signed activity.
    function invariant_DelaysAndAuthorizationsHold() public view {
        assertEq(handler.violations(), 0);
    }

    /// @dev A pending change is well formed and its captured cancellers never change.
    function invariant_PendingChangeIsWellFormed() public view {
        PendingChange memory p = registry.pendingChange(artistId);
        if (p.kind == ChangeKind.NONE) return;
        uint64 delay = p.kind == ChangeKind.STANDARD ? 7 days : 180 days;
        assertEq(p.executableAt, p.stagedAt + delay);
        assertEq(p.previousAuthority, registry.authorityOf(artistId));
        assertEq(p.evidenceHash == bytes32(0), p.kind == ChangeKind.STANDARD);
        assertLe(p.cancellers.length, Limits.MAX_CANCELLERS);
        assertEq(keccak256(abi.encode(p.cancellers)), handler.ghostCancellers());
        assertTrue(p.next.authority != address(0) && p.next.payout != address(0));
    }

    /// @dev The current authority always resolves to the artist ID.
    function invariant_AuthorityResolvesToTheArtist() public view {
        assertEq(registry.artistIdOf(registry.authorityOf(artistId)), artistId);
    }
}
