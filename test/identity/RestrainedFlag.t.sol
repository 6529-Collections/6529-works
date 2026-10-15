// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ChangeKind, PendingChange } from "src/interfaces/types/IdentityTypes.sol";
import { IdentityFixture } from "./IdentityFixture.sol";

/// @notice The artist's `restrained` flag (the state-growth diet): kept beside the authority in
///         its storage word, it is set at every staging and cleared at every end of a change, so
///         `activeAuthorityOf` reads the pending change only while an override that moves the
///         authority is pending. The identity invariants check the same equivalence at random.
contract RestrainedFlagTest is IdentityFixture {
    /// @dev `ArtistRegistry._artists`'s storage slot (`forge inspect ArtistRegistry
    ///      storageLayout`), checked against `authorityOf` by `_flag` on every read.
    uint256 internal constant ARTISTS_SLOT = 3;

    function _word() internal view returns (bytes32 slot, uint256 word) {
        slot = keccak256(abi.encode(artistId, ARTISTS_SLOT));
        word = uint256(vm.load(address(registry), slot));
    }

    /// @dev The flag, after checking that the word holds the authority (the layout guard).
    function _flag() internal view returns (bool) {
        (, uint256 word) = _word();
        assertEq(address(uint160(word)), registry.authorityOf(artistId), "layout");
        return (word >> 160) & 0xff != 0;
    }

    /// @dev The reference: whether the pending change is an override that moves the authority.
    function _expected() internal view returns (bool) {
        PendingChange memory p = registry.pendingChange(artistId);
        return p.kind > ChangeKind.STANDARD && p.next.authority != registry.authorityOf(artistId);
    }

    function _check() internal view {
        assertEq(_flag(), _expected(), "flag");
        PendingChange memory p = registry.pendingChange(artistId);
        bool lapsed = p.contestedAt != 0 && block.timestamp >= uint256(p.contestedAt) + 365 days;
        address current = registry.authorityOf(artistId);
        assertEq(
            registry.activeAuthorityOf(artistId), _expected() && !lapsed ? address(0) : current
        );
    }

    /// @dev Without a pending override, the active authority is one storage read: the authority
    ///      word, never the pending change.
    function test_ActiveAuthorityReadsOnlyTheAuthorityWord() public {
        (bytes32 slot,) = _word();
        vm.record();
        assertEq(registry.activeAuthorityOf(artistId), artist);
        (bytes32[] memory reads,) = vm.accesses(address(registry));
        assertGt(reads.length, 0);
        for (uint256 i; i < reads.length; ++i) {
            assertEq(reads[i], slot, "only the authority word");
        }
    }

    function test_StandardChangeAndPayoutOnlyOverrideRestrainNothing() public {
        _check();
        _stage(artistKey, _identity(newAuthority, payout), newKey);
        assertFalse(_flag());
        _check();
        vm.prank(guardian);
        registry.vetoChange(artistId);
        _check();
        // A payout-only override keeps the authority.
        _stageOverride(ChangeKind.CONTESTED, _identity(artist, payout), 0);
        assertFalse(_flag());
        _check();
    }

    function test_SetByAnAuthorityMovingOverrideAndClearedByVeto() public {
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, payout), newKey);
        assertTrue(_flag());
        assertEq(registry.activeAuthorityOf(artistId), address(0));
        _check();
        vm.prank(guardian);
        registry.vetoChange(artistId);
        assertFalse(_flag());
        assertEq(registry.activeAuthorityOf(artistId), artist);
    }

    /// @dev An override that replaces a pending STANDARD change sets the flag; its execution
    ///      clears it and installs the new authority.
    function test_ReplacingOverrideSetsAndExecutionClears() public {
        _stage(artistKey, _identity(artist, payout), 0);
        _check();
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, payout), newKey);
        assertTrue(_flag());
        _check();
        vm.warp(block.timestamp + 180 days);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), newAuthority);
        assertFalse(_flag());
        assertEq(registry.activeAuthorityOf(artistId), newAuthority);
    }

    /// @dev A contest that nobody resolves lapses after a year: the flag is still set, but the
    ///      authority is active again; `expireContest` clears the flag.
    function test_LapsedContestIsActiveUntilExpired() public {
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, payout), newKey);
        vm.prank(wallet);
        registry.cancelChange(artistId); // the captured wallet contests
        _check();
        vm.warp(block.timestamp + 365 days);
        assertTrue(_flag());
        assertEq(registry.activeAuthorityOf(artistId), artist, "lapsed");
        _check();
        registry.expireContest(artistId);
        assertFalse(_flag());
        _check();
    }
}
