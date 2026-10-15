// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { ConsolidationAdapter, IDelegationManagement } from "src/identity/ConsolidationAdapter.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { IArtistRegistry, IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { IArtistRoleResolver } from "src/interfaces/IArtistRoleResolver.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import {
    ArtistIdentity,
    ChangeKind,
    PendingChange,
    Standing
} from "src/interfaces/types/IdentityTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { ERC1271WalletMock } from "../mocks/AdversarialTargets.sol";
import {
    EditionsMastersMock,
    FailingConsolidationSource,
    FederationRegistryStub,
    OversizedConsolidationSource,
    PackageRegistryStub,
    PullOnlyPayeeMock,
    SplitFactoryWalletsMock,
    StreamWorksMock
} from "../mocks/identity/IdentityWorksMocks.sol";
import { RepricedDelegationMock } from "../mocks/identity/RepricedDelegationMock.sol";
import { IdentityFixture } from "./IdentityFixture.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { SignatureReverts } from "test/helpers/SignatureReverts.sol";

/// @notice Unit and attack-path tests for the artist registry (ADR 0001 section 11).
contract ArtistRegistryTest is IdentityFixture {
    // ----------------------------------------------------------------- registration

    function test_Register_CreatesIdentity() public view {
        assertEq(artistId, uint256(uint160(artist)));
        (ArtistIdentity memory identity, uint64 lastActivity) = registry.artist(artistId);
        assertEq(identity.authority, artist);
        assertEq(identity.payout, artist);
        assertEq(identity.profileId, PROFILE);
        assertEq(identity.profileDocHash, PROFILE_DOC);
        assertEq(lastActivity, block.timestamp);
        assertEq(registry.artistIdOf(artist), artistId);
        assertEq(registry.authorityOf(artistId), artist);
        assertEq(registry.payoutAddress(artistId), artist);
        assertEq(registry.changeNonce(artistId), 0);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
    }

    function test_Register_EmitsEvent() public {
        ArtistIdentity memory identity = ArtistIdentity(stranger, stranger, PROFILE, PROFILE_DOC);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ArtistRegistered(uint256(uint160(stranger)), identity);
        _register(stranger);
    }

    function test_Register_RevertsForTakenAccount() public {
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, artist));
        _register(artist);
    }

    function test_Register_RevertsForZeroAccount() public {
        vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
        _register(address(0));
    }

    function test_Register_RevertsForAnyoneButThePackageRegistry() public {
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, admin));
        vm.prank(admin);
        registry.register(stranger, PROFILE, PROFILE_DOC);
    }

    function testFuzz_Register_ArtistIdIsTheFirstAuthority(address account) public {
        vm.assume(account != address(0) && registry.artistIdOf(account) == 0);
        vm.assume(account != packageRegistry && account != address(registry));
        assertEq(_register(account), uint256(uint160(account)));
        assertEq(registry.authorityOf(uint256(uint160(account))), account);
    }

    function test_Register_PastAuthoritiesStayTaken() public {
        _stage(artistKey, _identity(newAuthority, payout), newKey);
        vm.warp(block.timestamp + 7 days);
        registry.executeChange(artistId);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, artist));
        _register(artist);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, newAuthority));
        _register(newAuthority);
    }

    // ----------------------------------------------------------------- staging

    function test_StageChange_ByAuthority() public {
        ArtistIdentity memory next = _identity(artist, payout);
        PendingChange memory expected = _expectedStandard(next);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ActivityRecorded(artistId, uint64(block.timestamp));
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeStaged(artistId, expected);
        _stage(artistKey, next, 0);

        PendingChange memory p = registry.pendingChange(artistId);
        assertEq(keccak256(abi.encode(p)), keccak256(abi.encode(expected)));
        assertEq(registry.changeNonce(artistId), 1);
        assertEq(registry.payoutAddress(artistId), address(0), "payout frozen while pending");
    }

    function test_StageChange_ByEstablishedWallet() public {
        _stage(walletKey, _identity(wallet, wallet), walletKey);
        PendingChange memory p = registry.pendingChange(artistId);
        assertEq(uint8(p.kind), uint8(ChangeKind.STANDARD));
        assertEq(p.next.authority, wallet);
        assertEq(p.previousAuthority, artist);
    }

    function test_StageChange_RevertsForFreshlyConsolidatedWallet() public {
        _consolidate(artist, wallet2);
        vm.warp(block.timestamp + 30 days - 1);
        _armRevert(_notAuthorized(wallet2));
        _stage(wallet2Key, _identity(artist, payout), 0);
    }

    function test_StageChange_RevertsForStranger() public {
        _armRevert(_notAuthorized(thief));
        _stage(thiefKey, _identity(artist, thief), 0);
    }

    function test_StageChange_RevertsForExpiredDeadline() public {
        ArtistIdentity memory next = _identity(artist, payout);
        uint64 deadline = uint64(block.timestamp - 1);
        bytes memory signature = _sign(artistKey, _digest(next, deadline));
        vm.expectRevert(SignatureReverts.expired(deadline));
        registry.stageChange(artistId, next, artist, deadline, signature, "");
    }

    function test_StageChange_AcceptsDeadlineNow() public {
        ArtistIdentity memory next = _identity(artist, payout);
        uint64 deadline = uint64(block.timestamp);
        registry.stageChange(
            artistId, next, artist, deadline, _sign(artistKey, _digest(next, deadline)), ""
        );
        assertEq(registry.changeNonce(artistId), 1);
    }

    function test_StageChange_RevertsForWrongSigner() public {
        ArtistIdentity memory next = _identity(artist, thief);
        uint64 deadline = uint64(block.timestamp + 1);
        bytes memory forged = _sign(thiefKey, _digest(next, deadline));
        vm.expectRevert(SignatureReverts.invalid(artist));
        registry.stageChange(artistId, next, artist, deadline, forged, "");
    }

    function test_StageChange_RevertsForTamperedPayload() public {
        uint64 deadline = uint64(block.timestamp + 1);
        bytes memory signature = _sign(artistKey, _digest(_identity(artist, payout), deadline));
        vm.expectRevert(SignatureReverts.invalid(artist));
        registry.stageChange(artistId, _identity(artist, thief), artist, deadline, signature, "");
    }

    function test_StageChange_AuthorityChangeNeedsTheNewKey() public {
        ArtistIdentity memory next = _identity(newAuthority, payout);
        uint64 deadline = uint64(block.timestamp + 1);
        bytes32 digest = _digest(next, deadline);
        bytes memory signature = _sign(artistKey, digest);
        vm.expectRevert(SignatureReverts.invalid(newAuthority));
        registry.stageChange(artistId, next, artist, deadline, signature, "");
        vm.expectRevert(SignatureReverts.invalid(newAuthority));
        registry.stageChange(artistId, next, artist, deadline, signature, _sign(thiefKey, digest));
        registry.stageChange(artistId, next, artist, deadline, signature, _sign(newKey, digest));
        assertEq(registry.pendingChange(artistId).next.authority, newAuthority);
    }

    function test_StageChange_ToAnERC1271Authority() public {
        ERC1271WalletMock safe = new ERC1271WalletMock(newAuthority);
        ArtistIdentity memory next = _identity(address(safe), address(safe));
        uint64 deadline = uint64(block.timestamp + 1);
        bytes32 digest = _digest(next, deadline);
        registry.stageChange(
            artistId, next, artist, deadline, _sign(artistKey, digest), _sign(newKey, digest)
        );
        vm.warp(block.timestamp + 7 days);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), address(safe));
    }

    function test_StageChange_RevertsWhenPending() public {
        _stage(artistKey, _identity(artist, payout), 0);
        _armRevert(abi.encodeWithSelector(IArtistRegistry.ChangePending.selector, artistId));
        _stage(artistKey, _identity(artist, wallet), 0);
    }

    function test_StageChange_RevertsForZeroAuthorityOrPayout() public {
        _armRevert(abi.encodeWithSelector(IArtistRegistry.InvalidIdentity.selector));
        _stage(artistKey, _identity(artist, address(0)), 0);
        _armRevert(abi.encodeWithSelector(IArtistRegistry.InvalidIdentity.selector));
        _stage(artistKey, _identity(address(0), payout), 0);
    }

    function test_StageChange_RevertsForAnotherArtistsAccount() public {
        _register(newAuthority);
        _armRevert(abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, newAuthority));
        _stage(artistKey, _identity(newAuthority, payout), newKey);
    }

    function test_StageChange_RevertsForUnknownArtist() public {
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, 7));
        registry.stageChange(7, _identity(artist, payout), artist, 1, "", "");
    }

    // ----------------------------------------------------------------- replay

    function test_Replay_ConsumedNonceRejected() public {
        ArtistIdentity memory next = _identity(artist, payout);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory signature = _sign(artistKey, _digest(next, deadline));
        registry.stageChange(artistId, next, artist, deadline, signature, "");
        vm.prank(artist);
        registry.cancelChange(artistId);
        vm.expectRevert(SignatureReverts.invalid(artist));
        registry.stageChange(artistId, next, artist, deadline, signature, "");
    }

    /// @dev Replay protection keys on the nonce, so the ERC-2098 form of a used signature fails.
    function test_Replay_CompactFormOfAUsedSignatureRejected() public {
        ArtistIdentity memory next = _identity(artist, payout);
        uint64 deadline = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(artistKey, _digest(next, deadline));
        registry.stageChange(artistId, next, artist, deadline, abi.encodePacked(r, s, v), "");
        vm.prank(artist);
        registry.cancelChange(artistId);
        bytes32 vs = bytes32(uint256(v - 27) << 255 | uint256(s));
        vm.expectRevert(SignatureReverts.invalid(artist));
        registry.stageChange(artistId, next, artist, deadline, abi.encodePacked(r, vs), "");
    }

    function test_Replay_OtherRegistryRejected() public {
        ArtistRegistry other =
            new ArtistRegistry(address(manager), adapter, address(adapter).codehash);
        _configureRoles(address(other));
        vm.prank(admin);
        other.bindPackageRegistry(packageRegistry);
        vm.prank(packageRegistry);
        other.register(artist, PROFILE, PROFILE_DOC);
        ArtistIdentity memory next = _identity(artist, payout);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory signature = _sign(artistKey, _digest(next, deadline));
        vm.expectRevert(SignatureReverts.invalid(artist));
        other.stageChange(artistId, next, artist, deadline, signature, "");
    }

    function test_RevokeNonce_VoidsAPresignedPayload() public {
        ArtistIdentity memory next = _identity(artist, payout);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory signature = _sign(artistKey, _digest(next, deadline));
        vm.expectEmit(address(registry));
        emit IArtistRegistry.NonceRevoked(artistId, 0);
        vm.prank(artist);
        registry.revokeNonce(artistId);
        assertEq(registry.changeNonce(artistId), 1);
        vm.expectRevert(SignatureReverts.invalid(artist));
        registry.stageChange(artistId, next, artist, deadline, signature, "");
    }

    function test_RevokeNonce_RevertsForAnyoneButTheAuthority() public {
        _expectNotAuthorized(stranger);
        vm.prank(stranger);
        registry.revokeNonce(artistId);
        _expectNotAuthorized(wallet);
        vm.prank(wallet);
        registry.revokeNonce(artistId);
    }

    // ----------------------------------------------------------------- execution

    function test_ExecuteChange_RevertsBeforeSevenDays() public {
        _stage(artistKey, _identity(artist, payout), 0);
        uint64 due = uint64(block.timestamp + 7 days);
        vm.warp(due - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.ChangeNotDue.selector, artistId, due)
        );
        registry.executeChange(artistId);
    }

    function test_ExecuteChange_AppliesAfterSevenDays() public {
        ArtistIdentity memory next = _identity(artist, payout);
        _stage(artistKey, next, 0);
        vm.warp(block.timestamp + 7 days);
        (ArtistIdentity memory previous,) = registry.artist(artistId);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeExecuted(artistId, previous, next);
        vm.prank(stranger);
        registry.executeChange(artistId);
        assertEq(registry.payoutAddress(artistId), payout);
        (ArtistIdentity memory current, uint64 lastActivity) = registry.artist(artistId);
        assertEq(keccak256(abi.encode(current)), keccak256(abi.encode(next)));
        assertEq(lastActivity, block.timestamp);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
    }

    function test_ExecuteChange_RotatesTheAuthority() public {
        _stage(artistKey, _identity(newAuthority, payout), newKey);
        vm.warp(block.timestamp + 7 days);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), newAuthority);
        assertEq(registry.artistIdOf(newAuthority), artistId);
        assertEq(registry.artistIdOf(artist), artistId, "old authorities keep resolving");
        _armRevert(_notAuthorized(artist));
        _stage(artistKey, _identity(artist, artist), artistKey);
        _stage(newKey, _identity(newAuthority, newAuthority), 0);
    }

    function test_ExecuteChange_RevertsWithoutPending() public {
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NoPendingChange.selector, artistId));
        registry.executeChange(artistId);
    }

    /// @dev IDENTITY-2 (formerly L3, where a registration meanwhile cleared the change): the
    ///      staging reserves the new authority, so neither a registration nor another artist's
    ///      change can take it while the change waits, and the change executes.
    function test_ExecuteChange_NewAuthorityCannotBeTakenMeanwhile() public {
        uint256 otherId = _register(stranger);
        _stage(artistKey, _identity(newAuthority, payout), newKey);
        assertEq(registry.reservedFor(newAuthority), artistId);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, newAuthority));
        _register(newAuthority);
        ArtistIdentity memory hijack = _identity(newAuthority, stranger);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = registry.changeDigest(otherId, hijack, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, newAuthority));
        registry.stageChange(otherId, hijack, stranger, deadline, "", _sign(newKey, digest));

        vm.warp(block.timestamp + 7 days);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeExecuted(
            artistId,
            ArtistIdentity(artist, artist, PROFILE, PROFILE_DOC),
            _identity(newAuthority, payout)
        );
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), newAuthority);
        assertEq(registry.artistIdOf(newAuthority), artistId);
        assertEq(registry.reservedFor(newAuthority), 0, "the reservation ends with the change");
    }

    /// @dev IDENTITY-2: only a change that moves the authority reserves anything, an override
    ///      replacing a STANDARD change moves the reservation, and every way a change ends
    ///      releases it.
    function test_Reservation_FollowsThePendingChange() public {
        _stage(artistKey, _identity(artist, payout), 0);
        assertEq(registry.reservedFor(artist), 0, "a change that keeps the authority");
        vm.prank(artist);
        registry.cancelChange(artistId);

        _stage(artistKey, _identity(newAuthority, payout), newKey);
        assertEq(registry.reservedFor(newAuthority), artistId);
        vm.prank(artist);
        registry.cancelChange(artistId);
        assertEq(registry.reservedFor(newAuthority), 0, "released by a cancel");

        _stage(artistKey, _identity(newAuthority, payout), newKey);
        vm.prank(guardian);
        registry.vetoChange(artistId);
        assertEq(registry.reservedFor(newAuthority), 0, "released by a veto");

        _stage(artistKey, _identity(newAuthority, payout), newKey);
        _stageOverride(ChangeKind.CONTESTED, _identity(thief, payout), thiefKey);
        assertEq(registry.reservedFor(newAuthority), 0, "released by the replaced change");
        assertEq(registry.reservedFor(thief), artistId, "reserved by the override");
        // An override to the same new authority as the change it replaces keeps it reserved.
        vm.prank(guardian);
        registry.vetoChange(artistId);
        _stage(artistKey, _identity(newAuthority, payout), newKey);
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, artist), newKey);
        assertEq(registry.reservedFor(newAuthority), artistId);
        assertEq(registry.reservedFor(thief), 0);
        _register(thief);
    }

    /// @dev IDENTITY-2: a change cleared at execution (its payout became a split wallet) releases
    ///      the reservation too.
    function test_Reservation_ReleasedWhenExecutionClears() public {
        SplitFactoryWalletsMock factory = _wireSplitFactory();
        _stage(artistKey, _identity(newAuthority, payout), newKey);
        factory.setWallet(payout, true);
        vm.warp(block.timestamp + 7 days);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), artist);
        assertEq(registry.reservedFor(newAuthority), 0);
        assertEq(_register(newAuthority), uint160(newAuthority));
    }

    function testFuzz_ExecuteChange_RespectsTheDelay(uint256 wait) public {
        wait = bound(wait, 0, 30 days);
        _stage(artistKey, _identity(artist, payout), 0);
        vm.warp(block.timestamp + wait);
        if (wait < 7 days) vm.expectRevert();
        registry.executeChange(artistId);
        assertEq(registry.payoutAddress(artistId), wait < 7 days ? address(0) : payout);
    }

    // ----------------------------------------------------------------- cancellation

    function test_Cancel_ByTheOldKey() public {
        _stage(walletKey, _identity(wallet, wallet), walletKey);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, artist, false);
        vm.prank(artist);
        registry.cancelChange(artistId);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
    }

    function test_Cancel_ByACapturedWallet() public {
        _stage(artistKey, _identity(artist, thief), 0);
        assertEq(_cancellers().length, 1);
        assertEq(_cancellers()[0], wallet);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, wallet, false);
        vm.prank(wallet);
        registry.cancelChange(artistId);
    }

    function test_Cancel_RevertsForStranger() public {
        _stage(artistKey, _identity(artist, payout), 0);
        _expectNotAuthorized(stranger);
        vm.prank(stranger);
        registry.cancelChange(artistId);
    }

    function test_Cancel_RevertsWithoutPending() public {
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NoPendingChange.selector, artistId));
        registry.cancelChange(artistId);
    }

    /// @dev Attack: a thief holding the artist key stages a redirect, then revokes the artist's
    ///      consolidation to strip the wallet's standing. The wallet was captured at staging.
    function test_Attack_ThiefRevokingConsolidationsAfterStagingCannotStripCancellers() public {
        _stage(artistKey, _identity(artist, thief), 0);
        _revoke(artist, wallet);
        assertFalse(adapter.isEstablished(artist, wallet));
        vm.prank(wallet);
        registry.cancelChange(artistId);
        assertEq(registry.payoutAddress(artistId), artist);
    }

    /// @dev Standing is fixed at staging: a wallet that becomes established later cannot cancel.
    function test_Cancel_WalletEstablishedAfterStagingCannotCancel() public {
        _consolidate(artist, wallet2);
        vm.warp(block.timestamp + 1 days);
        _stage(artistKey, _identity(artist, payout), 0);
        vm.warp(block.timestamp + 29 days);
        assertTrue(adapter.isEstablished(artist, wallet2));
        _expectNotAuthorized(wallet2);
        vm.prank(wallet2);
        registry.cancelChange(artistId);
    }

    // ----------------------------------------------------------------- guardian veto

    function test_Veto_ByGuardian() public {
        _stage(artistKey, _identity(artist, payout), 0);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, guardian, true);
        vm.prank(guardian);
        registry.vetoChange(artistId);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        assertEq(registry.payoutAddress(artistId), artist);
    }

    function test_Veto_RevertsForNonGuardian() public {
        _stage(artistKey, _identity(artist, payout), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, artist)
        );
        vm.prank(artist);
        registry.vetoChange(artistId);
    }

    function test_Veto_RevertsWithoutPending() public {
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NoPendingChange.selector, artistId));
        vm.prank(guardian);
        registry.vetoChange(artistId);
    }

    function test_Veto_StopsAnOverride() public {
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, payout), newKey);
        vm.prank(guardian);
        registry.vetoChange(artistId);
        vm.warp(block.timestamp + 180 days);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NoPendingChange.selector, artistId));
        registry.executeChange(artistId);
    }

    /// @dev Attack: the guardian is veto-only and has no path that writes an identity.
    function test_Attack_GuardianCannotRedirect() public {
        IConsolidationSource current = _source();
        vm.startPrank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian)
        );
        registry.stageOverride(
            artistId, ChangeKind.CONTESTED, _identity(guardian, guardian), keccak256("e"), 0, ""
        );
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, guardian));
        registry.register(guardian, PROFILE, PROFILE_DOC);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian)
        );
        registry.bindStream(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian)
        );
        registry.setConsolidationSource(
            current, IConsolidationSource(address(delegation)), address(delegation).codehash
        );
        vm.stopPrank();
        _expectNotAuthorized(guardian);
        registry.stageChange(artistId, _identity(guardian, guardian), guardian, 1, "", "");
        assertEq(registry.payoutAddress(artistId), artist);
        assertEq(registry.authorityOf(artistId), artist);
    }

    // ----------------------------------------------------------------- overrides

    function test_Override_ContestedWaits180Days() public {
        ArtistIdentity memory next = _identity(newAuthority, payout);
        PendingChange memory expected = PendingChange({
            kind: ChangeKind.CONTESTED,
            next: next,
            previousAuthority: artist,
            stagedAt: uint64(block.timestamp),
            executableAt: uint64(block.timestamp + 180 days),
            contestedAt: 0,
            priorOutcome: bytes32(0),
            evidenceHash: keccak256("evidence"),
            cancellers: _walletOnly()
        });
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeStaged(artistId, expected);
        _stageOverride(ChangeKind.CONTESTED, next, newKey);
        assertEq(registry.changeNonce(artistId), 1, "an override voids outstanding signatures");

        vm.warp(block.timestamp + 180 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.ChangeNotDue.selector, artistId, expected.executableAt
            )
        );
        registry.executeChange(artistId);
        vm.warp(block.timestamp + 1);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), newAuthority);
        assertEq(registry.payoutAddress(artistId), payout);
    }

    /// @dev Attack: a stolen old key tries to block the 180-day override.
    function test_Attack_OldKeyCannotCancelAnOverride() public {
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, payout), newKey);
        _expectNotAuthorized(artist);
        vm.prank(artist);
        registry.cancelChange(artistId);
        vm.prank(wallet);
        registry.cancelChange(artistId);
    }

    function test_Override_EstateRevertsBeforeOneYearOfDormancy() public {
        (, uint64 last) = registry.artist(artistId);
        vm.warp(last + 365 days - 1);
        _armRevert(abi.encodeWithSelector(IArtistRegistry.NotDormant.selector, artistId, last));
        _stageOverride(ChangeKind.ESTATE, _identity(newAuthority, payout), newKey);
        vm.warp(last + 365 days);
        _stageOverride(ChangeKind.ESTATE, _identity(newAuthority, payout), newKey);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.ESTATE));
    }

    function test_Override_LostKeyBlockedByRecentHeartbeat() public {
        vm.warp(block.timestamp + 300 days);
        vm.prank(wallet);
        registry.heartbeat(artistId);
        vm.warp(block.timestamp + 100 days);
        _armRevert(
            abi.encodeWithSelector(
                IArtistRegistry.NotDormant.selector, artistId, uint64(block.timestamp - 100 days)
            )
        );
        _stageOverride(ChangeKind.LOST_KEY, _identity(newAuthority, payout), newKey);
    }

    function test_Override_ReplacesAPendingStandardChange() public {
        _stage(artistKey, _identity(artist, thief), 0);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, governor, true);
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, payout), newKey);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.CONTESTED));
    }

    function test_Override_RevertsWhenAnOverrideIsPending() public {
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, payout), newKey);
        _armRevert(abi.encodeWithSelector(IArtistRegistry.ChangePending.selector, artistId));
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, artist), newKey);
        _armRevert(abi.encodeWithSelector(IArtistRegistry.ChangePending.selector, artistId));
        _stage(artistKey, _identity(artist, payout), 0);
    }

    function test_Override_RevertsForInvalidKindOrEvidence() public {
        ArtistIdentity memory next = _identity(artist, payout);
        vm.startPrank(governor);
        vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
        registry.stageOverride(artistId, ChangeKind.NONE, next, keccak256("e"), 0, "");
        vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
        registry.stageOverride(artistId, ChangeKind.STANDARD, next, keccak256("e"), 0, "");
        vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
        registry.stageOverride(artistId, ChangeKind.CONTESTED, next, bytes32(0), 0, "");
        vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
        registry.stageOverride(
            artistId, ChangeKind.CONTESTED, _identity(address(0), payout), keccak256("e"), 0, ""
        );
        vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
        registry.stageOverride(
            artistId, ChangeKind.CONTESTED, _identity(artist, address(0)), keccak256("e"), 0, ""
        );
        vm.stopPrank();
    }

    function test_Override_RevertsForNonSetter() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        vm.prank(stranger);
        registry.stageOverride(
            artistId, ChangeKind.CONTESTED, _identity(stranger, stranger), keccak256("e"), 0, ""
        );
    }

    /// @dev With the production 48-hour PARAMETER_SETTER delay, the override goes through the
    ///      AccessManager's schedule.
    function test_Override_ThroughTheScheduledDelay() public {
        address delayed = makeAddr("delayedSetter");
        vm.prank(admin);
        manager.grantRole(PARAMETER_SETTER, delayed, 48 hours);
        bytes memory call = abi.encodeCall(
            ArtistRegistry.stageOverride,
            (artistId, ChangeKind.CONTESTED, _identity(artist, payout), keccak256("e"), 0, "")
        );
        vm.prank(delayed);
        manager.schedule(address(registry), call, 0);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(delayed);
        manager.execute(address(registry), call);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.CONTESTED));
    }

    function test_Override_PayoutOnlyNeedsNoAcceptance() public {
        vm.warp(block.timestamp + 365 days);
        _stageOverride(ChangeKind.ESTATE, _identity(artist, payout), 0);
        vm.warp(block.timestamp + 180 days);
        registry.executeChange(artistId);
        assertEq(registry.payoutAddress(artistId), payout);
        assertEq(registry.authorityOf(artistId), artist);
    }

    /// @dev D18: an override that changes the authority is two-sided.
    function test_Override_AuthorityChangeNeedsTheNewAuthority() public {
        vm.warp(block.timestamp + 365 days); // dormant, so an ESTATE override is otherwise valid
        ArtistIdentity memory next = _identity(newAuthority, payout);
        bytes32 evidence = keccak256("evidence");
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest =
            registry.overrideDigest(artistId, ChangeKind.CONTESTED, next, evidence, deadline);
        vm.startPrank(governor);
        vm.expectRevert(SignatureReverts.invalid(newAuthority));
        registry.stageOverride(artistId, ChangeKind.CONTESTED, next, evidence, deadline, "");
        vm.expectRevert(SignatureReverts.invalid(newAuthority));
        registry.stageOverride(
            artistId, ChangeKind.CONTESTED, next, evidence, deadline, _sign(thiefKey, digest)
        );
        vm.expectRevert(SignatureReverts.invalid(newAuthority));
        registry.stageOverride(
            artistId, ChangeKind.ESTATE, next, evidence, deadline, _sign(newKey, digest)
        );
        vm.warp(deadline + 1);
        vm.expectRevert(SignatureReverts.expired(deadline));
        registry.stageOverride(
            artistId, ChangeKind.CONTESTED, next, evidence, deadline, _sign(newKey, digest)
        );
        vm.stopPrank();
    }

    /// @dev E11 (reverted to nonce-free): the acceptance is consumed once by digest, so the same
    ///      acceptance cannot stage twice, after a veto or after a cancel.
    function test_Override_AcceptanceIsSingleUseByDigest() public {
        ArtistIdentity memory next = _identity(newAuthority, payout);
        bytes32 evidence = keccak256("evidence");
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes32 digest =
            registry.overrideDigest(artistId, ChangeKind.CONTESTED, next, evidence, deadline);
        bytes memory acceptance = _sign(newKey, digest);
        vm.prank(governor);
        registry.stageOverride(artistId, ChangeKind.CONTESTED, next, evidence, deadline, acceptance);
        vm.prank(guardian);
        registry.vetoChange(artistId);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.AcceptanceUsed.selector, digest));
        vm.prank(governor);
        registry.stageOverride(artistId, ChangeKind.CONTESTED, next, evidence, deadline, acceptance);
    }

    function test_Override_SameAcceptanceCannotBeConsumedTwice() public {
        ArtistIdentity memory next = _identity(newAuthority, payout);
        bytes32 evidence = keccak256("evidence");
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes memory acceptance = _sign(
            newKey,
            registry.overrideDigest(artistId, ChangeKind.CONTESTED, next, evidence, deadline)
        );
        vm.prank(governor);
        registry.stageOverride(artistId, ChangeKind.CONTESTED, next, evidence, deadline, acceptance);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        // The same digest, even in its ERC-2098 compact form, is consumed.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            newKey,
            registry.overrideDigest(artistId, ChangeKind.CONTESTED, next, evidence, deadline)
        );
        bytes32 vs = bytes32(uint256(v - 27) << 255 | uint256(s));
        bytes memory used = abi.encodeWithSelector(
            IArtistRegistry.AcceptanceUsed.selector,
            registry.overrideDigest(artistId, ChangeKind.CONTESTED, next, evidence, deadline)
        );
        vm.startPrank(governor);
        vm.expectRevert(used);
        registry.stageOverride(artistId, ChangeKind.CONTESTED, next, evidence, deadline, acceptance);
        vm.expectRevert(used);
        registry.stageOverride(
            artistId, ChangeKind.CONTESTED, next, evidence, deadline, abi.encodePacked(r, vs)
        );
        vm.stopPrank();
    }

    /// @dev E11 inverted: burning the nonce (as a key holder could between scheduling and
    ///      execution) does not void a scheduled override's acceptance.
    function test_Override_AcceptanceSurvivesANonceBurn() public {
        ArtistIdentity memory next = _identity(newAuthority, payout);
        bytes32 evidence = keccak256("evidence");
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes memory acceptance = _sign(
            newKey,
            registry.overrideDigest(artistId, ChangeKind.CONTESTED, next, evidence, deadline)
        );
        vm.prank(artist); // the key holder, between scheduling and execution
        registry.revokeNonce(artistId);
        vm.prank(artist);
        registry.revokeNonce(artistId);
        vm.prank(governor);
        registry.stageOverride(artistId, ChangeKind.CONTESTED, next, evidence, deadline, acceptance);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.CONTESTED));
    }

    function test_Override_RevertsIfTheNewAuthorityBelongsToAnotherArtist() public {
        _register(newAuthority);
        _armRevert(abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, newAuthority));
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, payout), newKey);
    }

    /// @dev SIGS-3: an authority the artist rotated away from never becomes its authority again
    ///      (A, then B, then A is refused), by a STANDARD change or an override, so the signatures
    ///      A left unused (moves, sale consents, acceptances, which check the current authority)
    ///      stay dead. The current authority may still stage changes that keep it.
    function test_StageChange_RevertsForAPreviousAuthority() public {
        _stage(artistKey, _identity(newAuthority, payout), newKey);
        vm.warp(block.timestamp + 7 days);
        registry.executeChange(artistId);
        assertEq(registry.artistIdOf(artist), artistId, "still resolves to the artist");

        bytes memory taken = abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, artist);
        _armRevert(taken);
        _stage(newKey, _identity(artist, payout), artistKey);
        _armRevert(taken);
        _stageOverride(ChangeKind.CONTESTED, _identity(artist, artist), artistKey);

        _stage(newKey, _identity(newAuthority, artist), 0);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.STANDARD));
    }

    // ----------------------------------------------------------------- heartbeat

    function test_Heartbeat_ByAuthorityAndWallet() public {
        address[2] memory callers = [artist, wallet];
        for (uint256 i; i < callers.length; ++i) {
            vm.warp(block.timestamp + 1 days);
            vm.expectEmit(address(registry));
            emit IArtistRegistry.ActivityRecorded(artistId, uint64(block.timestamp));
            vm.prank(callers[i]);
            registry.heartbeat(artistId);
            (, uint64 last) = registry.artist(artistId);
            assertEq(last, block.timestamp);
        }
    }

    function test_Heartbeat_RevertsForStrangerPackageRegistryAndFreshWallet() public {
        _expectNotAuthorized(stranger);
        vm.prank(stranger);
        registry.heartbeat(artistId);
        _expectNotAuthorized(packageRegistry);
        vm.prank(packageRegistry);
        registry.heartbeat(artistId);
        _consolidate(artist, wallet2);
        _expectNotAuthorized(wallet2);
        vm.prank(wallet2);
        registry.heartbeat(artistId);
    }

    function test_Heartbeat_RevertsForUnknownArtist() public {
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, 9));
        vm.prank(artist);
        registry.heartbeat(9);
    }

    // ----------------------------------------------------------------- governed wiring

    function test_SetConsolidationSource() public {
        IConsolidationSource next =
            new ConsolidationAdapter(IDelegationManagement(address(delegation)));
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ConsolidationSourceSet(address(adapter), address(next));
        vm.prank(successorSetter);
        registry.setConsolidationSource(adapter, next, address(next).codehash);
        assertEq(address(registry.consolidationSource()), address(next));
        assertEq(registry.consolidationSourceCodeHash(), address(next).codehash);
    }

    /// @dev DEPS-6: the consolidation source's install-time code-hash pin holds at every use. A
    ///      source whose code no longer matches the pin (simulated with `vm.etch`) is never
    ///      trusted: staging, heartbeats and refreshes revert with `DependencyCodeChanged`, while an
    ///      execution and a registration go ahead and skip their refresh without reading it
    ///      (review L-1), so nobody's standing changes. The original code works again.
    function test_ConsolidationSource_CodeHashRecheckedAtUse() public {
        _stage(artistKey, _identity(newAuthority, newAuthority), newKey);
        vm.warp(block.timestamp + 7 days);
        assertEq(registry.consolidationSourceCodeHash(), address(adapter).codehash, "pinned");
        bytes memory original = address(adapter).code;
        // The replacement answers "not consolidated" for everyone.
        vm.etch(address(adapter), address(new FailingConsolidationSource()).code);
        bytes memory changed =
            abi.encodeWithSelector(Dependency.DependencyCodeChanged.selector, address(adapter));

        vm.expectRevert(changed);
        registry.refreshStanding(artistId);
        vm.expectRevert(changed);
        vm.prank(wallet);
        registry.heartbeat(artistId);

        vm.expectEmit(address(registry));
        emit IArtistRegistry.StandingRefreshSkipped(artistId);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), newAuthority, "the recovery executes");
        assertEq(registry.standingOf(artistId)[0].missingSince, 0, "nothing read from it");
        vm.expectEmit(address(registry));
        emit IArtistRegistry.StandingRefreshSkipped(uint160(stranger));
        _register(stranger);
        _armRevert(changed);
        _stage(newKey, _identity(newAuthority, payout), 0);

        vm.etch(address(adapter), original);
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId)[0].missingSince, block.timestamp, "caught up");
        _stage(newKey, _identity(newAuthority, payout), 0);
    }

    function test_SetConsolidationSource_RevertsForStaleExpected() public {
        vm.expectRevert(IArtistRegistry.ExpectedValueMismatch.selector);
        vm.prank(successorSetter);
        registry.setConsolidationSource(
            IConsolidationSource(stranger), adapter, address(adapter).codehash
        );
    }

    function test_SetConsolidationSource_RevertsForBadSourceOrCodeHash() public {
        vm.startPrank(successorSetter);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        registry.setConsolidationSource(adapter, IConsolidationSource(stranger), bytes32(0));
        address delegated = makeAddr("delegated7702");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(adapter)));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, delegated));
        registry.setConsolidationSource(
            adapter, IConsolidationSource(delegated), delegated.codehash
        );
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(delegation))
        );
        registry.setConsolidationSource(
            adapter, IConsolidationSource(address(delegation)), address(delegation).codehash
        );
        // A source whose code differs from the reviewed hash.
        IConsolidationSource other =
            new ConsolidationAdapter(IDelegationManagement(address(delegation)));
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(other))
        );
        registry.setConsolidationSource(adapter, other, keccak256("reviewed elsewhere"));
        vm.stopPrank();
    }

    function test_Constructor_RevertsForCodelessSource() public {
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        new ArtistRegistry(address(manager), IConsolidationSource(stranger), bytes32(0));
    }

    function test_SetConsolidationSource_RevertsForNonSetter() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, artist)
        );
        vm.prank(artist);
        registry.setConsolidationSource(adapter, adapter, address(adapter).codehash);
    }

    function test_Stage_RevertsWhenTheSourceReturnsTooManyWallets() public {
        OversizedConsolidationSource bad = new OversizedConsolidationSource();
        vm.prank(successorSetter);
        registry.setConsolidationSource(
            adapter, IConsolidationSource(address(bad)), address(bad).codehash
        );
        _armRevert(abi.encodeWithSelector(IArtistRegistry.InvalidSource.selector, address(bad)));
        _stage(artistKey, _identity(artist, payout), 0);
    }

    /// @dev IDENTITY-4: a repriced read within the stipend's headroom changes nothing, and a read
    ///      that exhausts it makes staging, heartbeats and refreshes revert instead of reading
    ///      "not consolidated", while a registration goes ahead and skips its refresh (review
    ///      L3). The recorded wallet is never marked missing, and its standing is intact once
    ///      reads work again.
    function test_SourceReadFailure_FailsClosed() public {
        RepricedDelegationMock repriced = new RepricedDelegationMock(delegation);
        ConsolidationAdapter source =
            new ConsolidationAdapter(IDelegationManagement(address(repriced)));
        vm.prank(successorSetter);
        registry.setConsolidationSource(adapter, source, address(source).codehash);

        // Cold reads repriced by 35K, beyond the former 50K stipend: nothing changes.
        repriced.setExtraGas(35_000);
        vm.cool(address(delegation));
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId)[0].missingSince, 0, "not marked missing");
        vm.prank(wallet);
        registry.heartbeat(artistId);

        // Reads that exhaust their gas: every call that reads the source reverts.
        repriced.setExtraGas(type(uint256).max);
        bytes memory err = abi.encodeWithSelector(
            IConsolidationSource.DelegationReadFailed.selector, address(repriced)
        );
        vm.expectRevert(err);
        registry.refreshStanding(artistId);
        vm.expectRevert(err);
        vm.prank(wallet);
        registry.heartbeat(artistId);
        _armRevert(err);
        _stage(artistKey, _identity(artist, payout), 0);
        uint256 strangerId = uint160(stranger);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.StandingRefreshSkipped(strangerId);
        assertEq(_register(stranger), strangerId, "registration goes ahead");
        assertEq(registry.standingOf(strangerId).length, 0);

        repriced.setExtraGas(0);
        registry.refreshStanding(artistId);
        Standing[] memory s = registry.standingOf(artistId);
        assertEq(s.length, 1);
        assertEq(s[0].wallet, wallet);
        assertEq(s[0].missingSince, 0, "standing intact");
        vm.prank(wallet);
        registry.heartbeat(artistId);
    }

    /// @dev Review L3: an execution during a source outage applies the change and skips its
    ///      standing refresh, so a due recovery is never blocked and nobody loses standing; a
    ///      later `refreshStanding` catches up once the source reads again.
    function test_SourceReadFailure_ExecutionSkipsTheRefresh() public {
        RepricedDelegationMock repriced = new RepricedDelegationMock(delegation);
        ConsolidationAdapter source =
            new ConsolidationAdapter(IDelegationManagement(address(repriced)));
        vm.prank(successorSetter);
        registry.setConsolidationSource(adapter, source, address(source).codehash);
        _stage(artistKey, _identity(newAuthority, newAuthority), newKey);
        vm.warp(block.timestamp + 7 days);

        repriced.setExtraGas(type(uint256).max);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.StandingRefreshSkipped(artistId);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), newAuthority, "applied");
        Standing[] memory s = registry.standingOf(artistId);
        assertEq(s.length, 1);
        assertEq(s[0].missingSince, 0, "nobody's standing changed");

        repriced.setExtraGas(0);
        registry.refreshStanding(artistId);
        assertEq(registry.standingOf(artistId)[0].missingSince, block.timestamp, "caught up");
    }

    /// @dev Review L3: only the source's `DelegationReadFailed` is skipped, in the scan and in a
    ///      recorded wallet's direct check; any other failure still reverts a registration or an
    ///      execution, and the fail-closed calls revert on both.
    function test_SourceReadFailure_OnlyTheOutageErrorIsSkipped() public {
        FailingConsolidationSource failing = new FailingConsolidationSource();
        _stage(artistKey, _identity(newAuthority, newAuthority), newKey);
        vm.warp(block.timestamp + 7 days);
        vm.prank(successorSetter);
        registry.setConsolidationSource(
            adapter, IConsolidationSource(address(failing)), address(failing).codehash
        );
        bytes memory outage = abi.encodeWithSelector(
            IConsolidationSource.DelegationReadFailed.selector, address(failing)
        );

        failing.set(true, false, true);
        vm.expectRevert(FailingConsolidationSource.Broken.selector);
        _register(stranger);
        failing.set(false, true, true);
        vm.expectRevert(FailingConsolidationSource.Broken.selector);
        registry.executeChange(artistId);

        // The outage, in the recorded wallet's direct check: execution goes ahead.
        failing.set(false, true, false);
        vm.expectRevert(outage);
        registry.refreshStanding(artistId);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.StandingRefreshSkipped(artistId);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), newAuthority);
        assertEq(registry.standingOf(artistId)[0].missingSince, 0);

        // The outage, in the scan: registration goes ahead; a refresh still reverts.
        failing.set(true, false, false);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.StandingRefreshSkipped(uint160(stranger));
        _register(stranger);
        vm.expectRevert(outage);
        registry.refreshStanding(uint160(stranger));
    }

    function test_Bindings_AreOneShot() public {
        StreamWorksMock stream = new StreamWorksMock();
        address federation = _federationStub();
        vm.startPrank(admin);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.Bound("STREAM", address(stream));
        registry.bindStream(address(stream));
        vm.expectEmit(address(registry));
        emit IArtistRegistry.Bound("FEDERATION_REGISTRY", federation);
        registry.bindFederationRegistry(federation);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.AlreadyBound.selector, bytes32("STREAM"))
        );
        registry.bindStream(address(stream));
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.AlreadyBound.selector, bytes32("FEDERATION_REGISTRY")
            )
        );
        registry.bindFederationRegistry(federation);
        address another = address(new PackageRegistryStub());
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.AlreadyBound.selector, bytes32("PACKAGE_REGISTRY")
            )
        );
        registry.bindPackageRegistry(another);
        vm.stopPrank();
        assertEq(registry.stream(), address(stream));
        assertEq(registry.federationRegistry(), federation);
        assertEq(registry.packageRegistry(), packageRegistry);
    }

    function test_Bindings_RejectInvalidTargets() public {
        ArtistRegistry fresh =
            new ArtistRegistry(address(manager), adapter, address(adapter).codehash);
        address delegated = makeAddr("delegated7702");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", packageRegistry));
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        fresh.bindPackageRegistry(stranger);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, delegated));
        fresh.bindPackageRegistry(delegated);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(adapter))
        );
        fresh.bindPackageRegistry(address(adapter));
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, packageRegistry)
        );
        fresh.bindStream(packageRegistry);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        fresh.bindFederationRegistry(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, packageRegistry)
        );
        fresh.bindFederationRegistry(packageRegistry);
        vm.stopPrank();
    }

    function test_Bindings_RevertForNonAdmin() public {
        address stream = address(new StreamWorksMock());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, governor)
        );
        vm.prank(governor);
        registry.bindStream(stream);
    }

    // ----------------------------------------------------------------- federated listing

    function test_ListFederatedContract_OnlyByTheFederationRegistry() public {
        address federation = _federationStub();
        address token = makeAddr("federatedToken");
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, federation));
        vm.prank(federation);
        registry.listFederatedContract(artistId, token);

        vm.prank(admin);
        registry.bindFederationRegistry(federation);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.FederatedContractListed(artistId, token);
        vm.prank(federation);
        registry.listFederatedContract(artistId, token);
        assertEq(registry.federatedContracts(artistId).length, 1);
        assertEq(registry.federatedContracts(artistId)[0], token);

        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, stranger));
        vm.prank(stranger);
        registry.listFederatedContract(artistId, token);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, 5));
        vm.prank(federation);
        registry.listFederatedContract(5, token);
    }

    // ----------------------------------------------------------------- artist role resolution

    function test_IsArtist_FalseBeforeTheStreamIsSet() public view {
        assertFalse(registry.isArtist(address(1), 1, artist));
    }

    function test_IsArtist_StreamWorksAndEditions() public {
        (StreamWorksMock stream, EditionsMastersMock editions) = _wireStream();
        assertTrue(registry.isArtist(address(stream), 1, artist));
        assertTrue(registry.isArtist(address(editions), 1, artist));
        assertFalse(registry.isArtist(address(stream), 1, wallet), "wallets are not the artist");
        assertFalse(registry.isArtist(address(stream), 2, artist), "unknown work");
        assertFalse(registry.isArtist(address(editions), 2, artist), "unknown edition");
        assertFalse(registry.isArtist(address(editions), 3, artist), "foreign master");
        assertFalse(registry.isArtist(stranger, 1, artist), "other token");
        assertFalse(registry.isArtist(address(0), 1, artist), "token zero");
        assertFalse(registry.isArtist(address(stream), 1, address(0)), "account zero");

        _stage(artistKey, _identity(newAuthority, payout), newKey);
        vm.warp(block.timestamp + 7 days);
        registry.executeChange(artistId);
        assertTrue(registry.isArtist(address(stream), 1, newAuthority));
        assertFalse(registry.isArtist(address(stream), 1, artist));
    }

    // ----------------------------------------------------------------- active authority

    /// @dev IDENTITY-1 (owner decision A): from its staging until it executes, an override that
    ///      would move the authority leaves the artist without an active authority, so nobody
    ///      acts as the artist (`isArtist` is false for both keys); `authorityOf` keeps
    ///      identifying it. After execution the new authority is active.
    function test_ActiveAuthority_RestrainedUntilTheOverrideExecutes() public {
        (StreamWorksMock stream,) = _wireStream();
        assertEq(registry.activeAuthorityOf(artistId), artist);
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, newAuthority), newKey);
        assertEq(registry.activeAuthorityOf(artistId), address(0), "restrained");
        assertEq(registry.authorityOf(artistId), artist, "still identified");
        assertFalse(registry.isArtist(address(stream), 1, artist));
        assertFalse(registry.isArtist(address(stream), 1, newAuthority));

        vm.warp(block.timestamp + 180 days);
        assertEq(registry.activeAuthorityOf(artistId), address(0), "until it executes");
        registry.executeChange(artistId);
        assertEq(registry.activeAuthorityOf(artistId), newAuthority);
        assertTrue(registry.isArtist(address(stream), 1, newAuthority));
    }

    /// @dev A STANDARD change, even one moving the authority, and an override that keeps the
    ///      authority restrain nothing; a veto lifts the restraint at once.
    function test_ActiveAuthority_OnlyAnAuthorityMovingOverrideRestrains() public {
        _stage(artistKey, _identity(newAuthority, payout), newKey);
        assertEq(registry.activeAuthorityOf(artistId), artist, "a STANDARD change");
        vm.prank(artist);
        registry.cancelChange(artistId);
        _stageOverride(ChangeKind.CONTESTED, _identity(artist, payout), 0);
        assertEq(registry.payoutAddress(artistId), address(0), "the payout is frozen");
        assertEq(registry.activeAuthorityOf(artistId), artist, "a payout-only override");
        vm.prank(guardian);
        registry.vetoChange(artistId);

        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, newAuthority), newKey);
        assertEq(registry.activeAuthorityOf(artistId), address(0));
        vm.prank(guardian);
        registry.vetoChange(artistId);
        assertEq(registry.activeAuthorityOf(artistId), artist, "restored by the veto");
    }

    function test_ActiveAuthority_RevertsForAnUnknownArtist() public {
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, 7));
        registry.activeAuthorityOf(7);
    }

    /// @dev The statement log accepts the registry as its artist resolver (ERC-165 at install).
    function test_IsArtist_InstallsAsTheStatementLogResolver() public {
        StatementLog log =
            new StatementLog(address(manager), address(registry), address(registry).codehash);
        assertEq(log.artistResolver(), address(registry));
    }

    function test_SupportsInterface() public view {
        assertTrue(registry.supportsInterface(type(IERC165).interfaceId));
        assertTrue(registry.supportsInterface(type(IArtistRoleResolver).interfaceId));
        assertTrue(registry.supportsInterface(type(IArtistRegistry).interfaceId));
        assertTrue(registry.supportsInterface(type(IArtistPayoutResolver).interfaceId));
        assertFalse(registry.supportsInterface(0xffffffff));
    }

    function test_Views_ForUnknownArtists() public {
        assertEq(registry.payoutAddress(5), address(0));
        assertEq(registry.changeNonce(5), 0);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, 5));
        registry.authorityOf(5);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, 5));
        registry.artist(5);
    }

    // ----------------------------------------------------------------- payout freeze

    /// @dev A pending payout change freezes `payoutAddress`; the outcome unfreezes it.
    function test_PayoutFreeze_WhileAPayoutChangeIsPending() public {
        _stage(artistKey, _identity(artist, payout), 0);
        assertEq(registry.payoutAddress(artistId), address(0));
        vm.prank(wallet);
        registry.cancelChange(artistId);
        assertEq(registry.payoutAddress(artistId), artist, "restored by a cancel");

        _stage(artistKey, _identity(artist, payout), 0);
        vm.prank(guardian);
        registry.vetoChange(artistId);
        assertEq(registry.payoutAddress(artistId), artist, "restored by a veto");

        _stage(artistKey, _identity(artist, payout), 0);
        vm.warp(block.timestamp + 7 days);
        assertEq(registry.payoutAddress(artistId), address(0), "frozen until executed");
        registry.executeChange(artistId);
        assertEq(registry.payoutAddress(artistId), payout, "the new payout");
    }

    /// @dev A STANDARD change that keeps the payout (an authority or profile change) does not
    ///      freeze it.
    function test_PayoutFreeze_NotForChangesThatKeepThePayout() public {
        _stage(artistKey, _identity(newAuthority, artist), newKey);
        assertEq(registry.payoutAddress(artistId), artist);
    }

    /// @dev M1: an override freezes the payout only when it moves it.
    function test_PayoutFreeze_OnlyForAnOverrideThatMovesThePayout() public {
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, payout), newKey);
        assertEq(registry.payoutAddress(artistId), address(0));
        vm.prank(wallet);
        registry.cancelChange(artistId);
        assertEq(registry.payoutAddress(artistId), address(0), "still frozen while contested");
        vm.prank(guardian);
        registry.vetoChange(artistId);
        assertEq(registry.payoutAddress(artistId), artist);
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, artist), newKey);
        assertEq(registry.payoutAddress(artistId), artist, "an override keeping it");
    }

    /// @dev The economics re-review case: a thief holding the stolen key (the current authority
    ///      and payout) cannot pull accrued balances while the network's 180-day recovery override
    ///      is pending, and cannot cancel it; the recovered payout pulls after execution.
    function test_Attack_ThiefCannotPullDuringARecoveryOverride() public {
        PullOnlyPayeeMock payee = new PullOnlyPayeeMock{ value: 1 ether }(registry, artistId);
        _stageOverride(ChangeKind.CONTESTED, _identity(newAuthority, newAuthority), newKey);

        vm.expectRevert(
            abi.encodeWithSelector(PullOnlyPayeeMock.NotPayoutAddress.selector, artist, address(0))
        );
        vm.prank(artist); // the thief, with the stolen key
        payee.release();
        _expectNotAuthorized(artist);
        vm.prank(artist);
        registry.cancelChange(artistId);

        vm.warp(block.timestamp + 180 days);
        registry.executeChange(artistId);
        vm.prank(newAuthority);
        payee.release();
        assertEq(newAuthority.balance, 1 ether);
        assertEq(artist.balance, 0);
    }

    // ----------------------------------------------------------------- payout validation

    /// @dev Pull-only artist payees: a protocol contract or a split wallet as the payout would
    ///      strand or stall funds, and is rejected at staging.
    function test_PayoutValidation_RejectsProtocolContractsAndSplitWallets() public {
        (StreamWorksMock stream, EditionsMastersMock editions) = _wireStream();
        SplitFactoryWalletsMock factory = _wireSplitFactory();
        address splitWallet = makeAddr("splitWallet");
        factory.setWallet(splitWallet, true);
        address[6] memory bad = [
            packageRegistry,
            address(stream),
            address(editions),
            address(registry),
            splitWallet,
            address(0)
        ];
        for (uint256 i; i < bad.length; ++i) {
            _armRevert(abi.encodeWithSelector(IArtistRegistry.InvalidIdentity.selector));
            _stage(artistKey, _identity(artist, bad[i]), 0);
            _armRevert(abi.encodeWithSelector(IArtistRegistry.InvalidIdentity.selector));
            _stageOverride(ChangeKind.CONTESTED, _identity(artist, bad[i]), 0);
        }
        _stage(artistKey, _identity(artist, payout), 0);
    }

    function test_PayoutValidation_RegistrationRejectsASplitWallet() public {
        SplitFactoryWalletsMock factory = _wireSplitFactory();
        address splitWallet = makeAddr("splitWallet");
        factory.setWallet(splitWallet, true);
        vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
        _register(splitWallet);
    }

    /// @dev A split wallet deployed at the payout's address while the change waits is caught at
    ///      execution, and the change is cleared (L3) rather than applied.
    function test_PayoutValidation_RecheckedAtExecution() public {
        SplitFactoryWalletsMock factory = _wireSplitFactory();
        _stage(artistKey, _identity(artist, payout), 0);
        factory.setWallet(payout, true);
        vm.warp(block.timestamp + 7 days);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, address(registry), false);
        registry.executeChange(artistId);
        assertEq(registry.payoutAddress(artistId), artist);
    }

    function test_BindSplitFactory_OneShotAndRequiresCode() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        registry.bindSplitFactory(stranger);
        SplitFactoryWalletsMock factory = new SplitFactoryWalletsMock();
        vm.expectEmit(address(registry));
        emit IArtistRegistry.Bound("SPLIT_FACTORY", address(factory));
        registry.bindSplitFactory(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.AlreadyBound.selector, bytes32("SPLIT_FACTORY"))
        );
        registry.bindSplitFactory(address(factory));
        vm.stopPrank();
        assertEq(registry.splitFactory(), address(factory));
    }

    // ----------------------------------------------------------------- residual risk

    // ----------------------------------------------------------------- golden values

    /// @dev Computed with `cast keccak` and `cast sig`, the way off-chain tools compute them.
    function test_Golden_TypehashesAndSelectors() public view {
        assertEq(
            Typehashes.IDENTITY_CHANGE,
            0xa474bd174aa5ecb19efe75995251c1fb8289b62bca04bc6c19e869f254e190f0
        );
        assertEq(
            Typehashes.OVERRIDE_ACCEPTANCE,
            0xe94c9e2e1a4e3c2652a414f70c177a61fc880d94ede3aaaf03a976666431f9a3
        );
        assertEq(type(IArtistPayoutResolver).interfaceId, bytes4(0x9b2c1793));
        (, string memory name, string memory version,,,,) = registry.eip712Domain();
        assertEq(name, "6529 Works Artist Registry");
        assertEq(version, "1");
    }

    /// @dev The digests are standard EIP-712 over the registry's domain, as wallets compute them.
    function test_Golden_DigestsAreStandardEip712() public view {
        ArtistIdentity memory next = _identity(newAuthority, payout);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("6529 Works Artist Registry"),
                keccak256("1"),
                block.chainid,
                address(registry)
            )
        );
        bytes32 change = keccak256(
            abi.encode(
                Typehashes.IDENTITY_CHANGE,
                artistId,
                next.authority,
                next.payout,
                next.profileId,
                next.profileDocHash,
                uint256(3),
                uint64(9)
            )
        );
        assertEq(
            registry.changeDigest(artistId, next, 3, 9),
            keccak256(abi.encodePacked(hex"1901", domain, change))
        );
        bytes32 acceptance = keccak256(
            abi.encode(
                Typehashes.OVERRIDE_ACCEPTANCE,
                artistId,
                uint8(ChangeKind.ESTATE),
                next.authority,
                next.payout,
                next.profileId,
                next.profileDocHash,
                keccak256("e"),
                uint64(9)
            )
        );
        assertEq(
            registry.overrideDigest(artistId, ChangeKind.ESTATE, next, keccak256("e"), 9),
            keccak256(abi.encodePacked(hex"1901", domain, acceptance))
        );
    }

    // ----------------------------------------------------------------- helpers

    function _federationStub() internal returns (address) {
        return address(new FederationRegistryStub());
    }

    function _expectNotAuthorized(address account) internal {
        vm.expectRevert(_notAuthorized(account));
    }

    function _notAuthorized(address account) internal view returns (bytes memory) {
        return abi.encodeWithSelector(IArtistRegistry.NotAuthorized.selector, artistId, account);
    }

    function _walletOnly() internal view returns (address[] memory list) {
        list = new address[](1);
        list[0] = wallet;
    }

    function _expectedStandard(ArtistIdentity memory next)
        internal
        view
        returns (PendingChange memory)
    {
        return PendingChange({
            kind: ChangeKind.STANDARD,
            next: next,
            previousAuthority: artist,
            stagedAt: uint64(block.timestamp),
            executableAt: uint64(block.timestamp + 7 days),
            contestedAt: 0,
            priorOutcome: bytes32(0),
            evidenceHash: bytes32(0),
            cancellers: _walletOnly()
        });
    }

    function _wireSplitFactory() internal returns (SplitFactoryWalletsMock factory) {
        factory = new SplitFactoryWalletsMock();
        vm.prank(admin);
        registry.bindSplitFactory(address(factory));
    }

    function _wireStream() internal returns (StreamWorksMock stream, EditionsMastersMock editions) {
        stream = new StreamWorksMock();
        editions = new EditionsMastersMock();
        stream.setEditions(address(editions));
        stream.setWork(1, artistId);
        editions.setEdition(1, address(stream));
        editions.setEdition(3, stranger);
        vm.prank(admin);
        registry.bindStream(address(stream));
    }
}
