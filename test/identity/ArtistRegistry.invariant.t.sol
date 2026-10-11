// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import {
    ArtistIdentity,
    ChangeKind,
    PendingChange,
    Standing
} from "src/interfaces/types/IdentityTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { ArtistRegistryHandler, IdentityActors } from "./ArtistRegistryHandler.sol";
import { IdentityFixture } from "./IdentityFixture.sol";
import { SplitFactoryWalletsMock } from "../mocks/identity/IdentityWorksMocks.sol";

/// @notice Stateful invariants for the artist registry (ADR 0001 section 11). The handler stages,
///         overrides, cancels, vetoes, replays, executes, refreshes standing and moves time and
///         consolidations, asserting every call's predicted outcome (a wrong prediction reverts the
///         handler, which `fail_on_revert` reports). Run with the foundry.toml campaign (256 runs x
///         depth 128).
contract ArtistRegistryInvariantTest is IdentityFixture {
    ArtistRegistryHandler internal handler;

    function setUp() public override {
        super.setUp();
        SplitFactoryWalletsMock factory = new SplitFactoryWalletsMock();
        vm.prank(admin);
        registry.bindSplitFactory(address(factory));
        handler = new ArtistRegistryHandler(
            IdentityActors({
                registry: registry,
                adapter: adapter,
                delegation: delegation,
                factory: factory,
                artistId: artistId,
                guardian: guardian,
                governor: governor,
                keys: [artistKey, walletKey, newKey, thiefKey],
                payouts: [artist, payout, makeAddr("estatePayout")]
            })
        );
        targetContract(address(handler));
    }

    /// @dev The payout and the authority change only through executed changes: they always equal
    ///      the ghosts, which only a successful `executeChange` updates. The payout resolves to
    ///      zero exactly while a pending change would move it.
    function invariant_PayoutChangesOnlyThroughExecutedChanges() public view {
        (ArtistIdentity memory identity,) = registry.artist(artistId);
        assertEq(identity.payout, handler.ghostPayout());
        assertEq(registry.authorityOf(artistId), handler.ghostAuthority());
        PendingChange memory p = registry.pendingChange(artistId);
        bool frozen = p.kind != ChangeKind.NONE && p.next.payout != identity.payout;
        assertEq(registry.payoutAddress(artistId), frozen ? address(0) : handler.ghostPayout());
    }

    /// @dev Dormancy counts only the artist's own activity and executions (never overrides,
    ///      vetoes or refreshes), and the nonce moves only with stagings and revocations.
    function invariant_ActivityAndNonceMatchTheModel() public view {
        (, uint64 lastActivity) = registry.artist(artistId);
        assertEq(lastActivity, handler.ghostLastActivity());
        assertEq(registry.changeNonce(artistId), handler.ghostNonce());
    }

    /// @dev A pending change is well formed, and its captured cancellers never change.
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

    /// @dev The authority resolves to the artist, and the standing snapshot stays bounded and
    ///      free of duplicates.
    function invariant_AuthorityAndStandingAreConsistent() public view {
        assertEq(registry.artistIdOf(registry.authorityOf(artistId)), artistId);
        Standing[] memory s = registry.standingOf(artistId);
        assertLe(s.length, Limits.MAX_CANCELLERS);
        for (uint256 i; i < s.length; ++i) {
            for (uint256 j = i + 1; j < s.length; ++j) {
                assertTrue(s[i].wallet != s[j].wallet);
            }
        }
    }
}
