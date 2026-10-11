// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { ConsolidationAdapter } from "src/identity/ConsolidationAdapter.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "src/interfaces/types/IdentityTypes.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";

/// @notice The accounts the handler drives. `keys` are the artist key, an established
///         consolidated wallet, a fresh key and a thief; `payouts` are payout candidates.
struct IdentityActors {
    ArtistRegistry registry;
    ConsolidationAdapter adapter;
    DelegationManagementMock delegation;
    uint256 artistId;
    address guardian;
    address governor;
    address packageRegistry;
    uint256[4] keys;
    address[3] payouts;
}

/// @notice Drives one artist identity through every path: signed STANDARD changes by the
///         authority, a consolidated wallet and a thief; network overrides; cancellations by
///         every kind of caller; guardian vetoes and redirect attempts; replays of used payloads;
///         heartbeats; nonce revocations; consolidation revocations and renewals; and time.
///         It keeps ghost copies of the identity, changed only when its own `executeChange`
///         succeeds, and counts every outcome the rules forbid in {violations}.
contract ArtistRegistryHandler is Test {
    bytes32 internal constant PROFILE = keccak256("profile/punk6529");

    ArtistRegistry internal immutable registry;
    ConsolidationAdapter internal immutable adapter;
    DelegationManagementMock internal immutable delegation;
    uint256 internal immutable artistId;
    address internal immutable guardian;
    address internal immutable governor;
    address internal immutable packageRegistry;
    uint256[4] internal keys;
    address[3] internal payouts;

    address public ghostPayout;
    address public ghostAuthority;
    bytes32 public ghostCancellers;
    uint256 public violations;
    uint256 public executed;
    uint256 public stagedCount;
    bool internal walletConsolidated = true;

    struct Used {
        ArtistIdentity next;
        address signer;
        uint64 deadline;
        bytes signature;
        bytes acceptance;
    }

    Used internal lastUsed;

    struct Accepted {
        ChangeKind kind;
        ArtistIdentity next;
        bytes32 evidence;
        uint64 deadline;
        bytes acceptance;
    }

    Accepted internal lastAcceptance;

    constructor(IdentityActors memory a) {
        registry = a.registry;
        adapter = a.adapter;
        delegation = a.delegation;
        artistId = a.artistId;
        guardian = a.guardian;
        governor = a.governor;
        packageRegistry = a.packageRegistry;
        keys = a.keys;
        payouts = a.payouts;
        ghostPayout = registry.payoutAddress(artistId);
        ghostAuthority = registry.authorityOf(artistId);
    }

    // ----------------------------------------------------------------- actions

    function stageStandard(uint256 signerSeed, uint256 authoritySeed, uint256 payoutSeed) external {
        uint256 signerKey = keys[signerSeed % 4];
        uint256 nextKey = keys[authoritySeed % 4];
        ArtistIdentity memory next =
            ArtistIdentity(vm.addr(nextKey), payouts[payoutSeed % 3], PROFILE, bytes32(payoutSeed));
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 digest =
            registry.changeDigest(artistId, next, registry.changeNonce(artistId), deadline);
        Used memory u = Used(next, vm.addr(signerKey), deadline, _sign(signerKey, digest), "");
        u.acceptance = _sign(nextKey, digest);
        try registry.stageChange(artistId, next, u.signer, deadline, u.signature, u.acceptance) {
            if (u.signer != ghostAuthority && !adapter.isEstablished(ghostAuthority, u.signer)) {
                ++violations;
            }
            lastUsed = u;
            _onStaged();
        } catch { }
    }

    /// @dev A used payload must never stage again (nonces, not signature bytes).
    function replayLast() external {
        Used memory u = lastUsed;
        if (u.signer == address(0)) return;
        try registry.stageChange(
            artistId, u.next, u.signer, u.deadline, u.signature, u.acceptance
        ) {
            ++violations;
        } catch { }
    }

    /// @dev Overrides carry the new authority's acceptance (two-sided).
    function stageOverride(uint256 kindSeed, uint256 authoritySeed, uint256 payoutSeed) external {
        ChangeKind kind = ChangeKind(2 + kindSeed % 3);
        uint256 nextKey = keys[authoritySeed % 4];
        ArtistIdentity memory next =
            ArtistIdentity(vm.addr(nextKey), payouts[payoutSeed % 3], PROFILE, bytes32(0));
        bytes32 evidence = keccak256(abi.encode(kindSeed));
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes memory acceptance =
            _sign(nextKey, registry.overrideDigest(artistId, kind, next, evidence, deadline));
        (, uint64 lastActivity) = registry.artist(artistId);
        vm.prank(governor);
        try registry.stageOverride(artistId, kind, next, evidence, deadline, acceptance) {
            if (kind != ChangeKind.CONTESTED && block.timestamp < lastActivity + 365 days) {
                ++violations;
            }
            if (next.authority != ghostAuthority) {
                lastAcceptance = Accepted(kind, next, evidence, deadline, acceptance);
            }
            _onStaged();
        } catch { }
    }

    /// @dev A used override acceptance must never stage again. (Once its override executed, the
    ///      same call is a payout-only override that needs no acceptance and may stage.)
    function replayAcceptance() external {
        Accepted memory u = lastAcceptance;
        if (u.next.authority == address(0)) return;
        bool needsAcceptance = u.next.authority != registry.authorityOf(artistId);
        vm.prank(governor);
        try registry.stageOverride(artistId, u.kind, u.next, u.evidence, u.deadline, u.acceptance) {
            if (needsAcceptance) ++violations;
            _onStaged();
        } catch { }
    }

    function cancel(uint256 callerSeed) external {
        address caller = _caller(callerSeed);
        PendingChange memory p = registry.pendingChange(artistId);
        vm.prank(caller);
        try registry.cancelChange(artistId) {
            bool allowed = p.kind == ChangeKind.STANDARD && caller == p.previousAuthority;
            for (uint256 i; i < p.cancellers.length; ++i) {
                allowed = allowed || p.cancellers[i] == caller;
            }
            if (!allowed) ++violations;
        } catch { }
    }

    function veto() external {
        vm.prank(guardian);
        try registry.vetoChange(artistId) { } catch { }
    }

    /// @dev The guardian is veto-only: every write path must refuse it.
    function guardianRedirect(uint256 payoutSeed) external {
        ArtistIdentity memory next =
            ArtistIdentity(guardian, payouts[payoutSeed % 3], PROFILE, bytes32(0));
        vm.prank(guardian);
        try registry.stageOverride(artistId, ChangeKind.CONTESTED, next, keccak256("e")) {
            ++violations;
        } catch { }
        try registry.stageChange(artistId, next, guardian, type(uint64).max, "", "") {
            ++violations;
        } catch { }
    }

    function execute() external {
        PendingChange memory p = registry.pendingChange(artistId);
        try registry.executeChange(artistId) {
            uint64 delay = p.kind == ChangeKind.STANDARD ? 7 days : 180 days;
            if (p.executableAt != p.stagedAt + delay || block.timestamp < p.stagedAt + delay) {
                ++violations;
            }
            ghostPayout = p.next.payout;
            ghostAuthority = p.next.authority;
            ++executed;
        } catch { }
    }

    function heartbeat(uint256 callerSeed) external {
        address caller = callerSeed % 5 == 4 ? packageRegistry : _caller(callerSeed);
        vm.prank(caller);
        try registry.heartbeat(artistId) { } catch { }
    }

    function revokeNonce(uint256 callerSeed) external {
        vm.prank(_caller(callerSeed));
        try registry.revokeNonce(artistId) { } catch { }
    }

    /// @dev Revokes or renews the consolidation of the original artist key and its wallet, as a
    ///      thief holding the artist key (or the artist) could.
    function toggleWalletConsolidation() external {
        address artist = vm.addr(keys[0]);
        address wallet = vm.addr(keys[1]);
        address all = delegation.ALL_COLLECTIONS();
        if (walletConsolidated) {
            vm.prank(artist);
            delegation.revokeDelegationAddress(all, wallet, 999);
        } else {
            vm.prank(artist);
            delegation.registerDelegationAddress(all, wallet, type(uint64).max, 999, true, 0);
            vm.prank(wallet);
            delegation.registerDelegationAddress(all, artist, type(uint64).max, 999, true, 0);
        }
        walletConsolidated = !walletConsolidated;
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 hours, 200 days));
    }

    // ----------------------------------------------------------------- helpers

    function _onStaged() private {
        ghostCancellers = keccak256(abi.encode(registry.pendingChange(artistId).cancellers));
        ++stagedCount;
    }

    function _caller(uint256 seed) private view returns (address) {
        uint256 i = seed % 5;
        return i == 4 ? guardian : vm.addr(keys[i]);
    }

    function _sign(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
