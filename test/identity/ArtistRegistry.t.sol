// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { IAccounts } from "src/interfaces/IAccounts.sol";
import { IArtistRegistry, IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { IArtistRoleResolver } from "src/interfaces/IArtistRoleResolver.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "src/interfaces/types/IdentityTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { StreamMock } from "../mocks/stream/StreamMock.sol";
import {
    ConsolidationSourceMock,
    DisputeOutcomeLogMock,
    EditionsMastersMock,
    FederationRegistryStub,
    PackageRegistryStub,
    PullOnlyPayeeMock,
    SplitFactoryWalletsMock
} from "../mocks/identity/IdentityWorksMocks.sol";
import { BurningEditionsMock } from "../mocks/identity/PermanenceMocks.sol";
import { IdentityFixture } from "./IdentityFixture.sol";

/// @notice The artist registry: accounts (every consolidated wallet acts for the account), the
///         account's own changes, network replacements, freezes, payouts and the role answers.
/// @dev A consolidation source that says yes to every pair: different code from the pinned
///      adapter.
contract AlwaysConsolidated {
    function isConsolidated(address, address) external pure returns (bool) {
        return true;
    }
}

/// @dev Editions whose edition `editionId` is the master work `workId` of `stream`.
contract RemappedEditionsMock {
    address public immutable stream;
    uint256 public immutable editionId;
    uint256 public immutable workId;

    constructor(address stream_, uint256 editionId_, uint256 workId_) {
        (stream, editionId, workId) = (stream_, editionId_, workId_);
    }

    function masterOf(uint256 id) external view returns (address, uint256, bytes32) {
        require(id == editionId, "unknown");
        return (stream, workId, keccak256("content"));
    }
}

/// @dev A Stream whose `artistOf` burns all the gas it is given.
contract BurningArtistStream {
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC165).interfaceId || id == type(IStream).interfaceId;
    }

    function editions() external pure returns (address) {
        return address(0);
    }

    function artistOf(uint256) external view returns (uint256) {
        while (gasleft() > 0) { }
        return 0;
    }
}

contract ArtistRegistryTest is IdentityFixture {
    bytes32 internal constant VOTE = keccak256("vote");

    // ----------------------------------------------------------------- registration

    function test_Register_CreatesTheAccount() public view {
        (ArtistIdentity memory id, uint48 frozenUntil) = registry.artist(artistId);
        assertEq(artistId, uint256(uint160(artist)));
        assertEq(id.root, artist);
        assertEq(id.payout, artist);
        assertEq(id.profileId, PROFILE);
        assertEq(frozenUntil, 0);
        assertEq(registry.artistIdOf(artist), artistId);
        assertEq(registry.authorityOf(artistId), artist);
        assertEq(registry.activeAuthorityOf(artistId), artist);
    }

    function test_Register_Refusals() public {
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, artist));
        _register(artist);
        vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
        _register(address(0));
        // A root that may not be paid (here a protocol contract) is refused as well.
        vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
        _register(packageRegistry);
        vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
        _register(address(registry));
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, stranger));
        vm.prank(stranger);
        registry.register(stranger, PROFILE, PROFILE_DOC);
    }

    // ----------------------------------------------------------------- accounts

    /// @dev Every consolidated wallet acts for the account (fails on the single-authority
    ///      registry, which answered only for the authority).
    function test_IsWallet_RootAndEveryConsolidatedWallet() public {
        assertTrue(registry.isWallet(artistId, artist));
        assertTrue(registry.isWallet(artistId, wallet));
        assertFalse(registry.isWallet(artistId, wallet2));
        _consolidate(artist, wallet2);
        assertTrue(registry.isWallet(artistId, wallet2), "no minimum age");
        assertFalse(registry.isWallet(artistId, outsider));
        assertFalse(registry.isWallet(artistId, address(0)));
    }

    /// @dev A wallet that left the consolidation (either direction revoked, or expired) is
    ///      refused at once.
    function test_IsWallet_AWalletThatLeftIsRefused() public {
        _revoke(wallet, artist);
        assertFalse(registry.isWallet(artistId, wallet), "one direction gone");
        _delegate(wallet, artist, block.timestamp + 1 days);
        assertTrue(registry.isWallet(artistId, wallet));
        vm.warp(block.timestamp + 1 days);
        assertFalse(registry.isWallet(artistId, wallet), "expired");
    }

    /// @dev One-way and specific-collection consolidations do not count.
    function test_IsWallet_OnlyTwoWayAllCollections() public {
        _delegate(artist, wallet2, FAR);
        assertFalse(registry.isWallet(artistId, wallet2), "one way");
        vm.prank(wallet2);
        delegation.registerDelegationAddress(
            makeAddr("collection"), artist, FAR, CONSOLIDATION, true, 0
        );
        assertFalse(registry.isWallet(artistId, wallet2), "specific collection");
    }

    /// @dev An unregistered address is its own single-wallet account, so an unregistered
    ///      collaborator consents exactly as before.
    function test_IsWallet_UnregisteredAccountIsItsOwnWallet() public view {
        uint256 id = uint256(uint160(outsider));
        assertTrue(registry.isWallet(id, outsider));
        assertFalse(registry.isWallet(id, wallet));
        assertFalse(registry.isWallet(uint256(type(uint160).max) + 1, address(1)));
        assertFalse(registry.isWallet(0, address(0)), "the zero address is nobody's wallet");
    }

    /// @dev A consolidation source whose code no longer matches its pin answers "no" for every
    ///      wallet but the root, without being asked.
    function test_IsWallet_ASourceWhoseCodeChangedConsolidatesNobody() public {
        assertTrue(registry.isWallet(artistId, wallet));
        bytes32 pinned = address(adapter).codehash;
        bool below;
        bool above;
        for (uint256 i; !(below && above); ++i) {
            // The same answer behind code of another hash: a trailing byte that never runs.
            bytes memory code = abi.encodePacked(address(new AlwaysConsolidated()).code, uint8(i));
            vm.etch(address(adapter), code);
            bytes32 h = address(adapter).codehash;
            (below, above) = (below || h < pinned, above || h > pinned);
            assertFalse(registry.isWallet(artistId, wallet));
        }
        assertFalse(registry.isWallet(artistId, wallet));
        assertFalse(registry.isWallet(artistId, outsider));
        assertTrue(registry.isWallet(artistId, artist), "the root still is");
    }

    /// @dev A pending change reserves a new root for the account, and only a new one: a change
    ///      that keeps the root reserves nothing.
    function test_OwnChange_ReservesOnlyANewRoot() public {
        _stage(artistKey, _identity(artist, payout));
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.OWN));
        assertEq(registry.reservedFor(artist), 0);
    }

    /// @dev An account ID above 160 bits is never read as the address in its low bits: it names
    ///      no registered account, whoever's root those bits spell.
    function test_IsWallet_AnIdAbove160BitsNeverAliasesARoot() public view {
        uint256 alias_ = (uint256(1) << 160) | uint160(artist);
        assertTrue(registry.isWallet(artistId, artist));
        assertFalse(registry.isWallet(alias_, artist));
        assertFalse(registry.isWallet(alias_, wallet));
        assertEq(registry.frozenUntil(alias_), 0);
    }

    /// @dev The account may be named by any address that is or was its root.
    function test_IsWallet_ResolvesAPastRoot() public {
        _consolidate(wallet, wallet2);
        _stage(walletKey, _identity(wallet, artist));
        vm.warp(block.timestamp + 2 days);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), wallet);
        // The account is now read from `wallet`: wallet2 is consolidated with it.
        assertTrue(registry.isWallet(artistId, wallet2));
        assertTrue(registry.isWallet(uint160(artist), wallet2), "by the first root");
        assertTrue(registry.isWallet(uint160(wallet), wallet2), "by the current root");
        assertTrue(registry.isWallet(artistId, artist), "the old root is still consolidated");
    }

    function test_RequireSigned_AnyWalletOfTheAccount() public {
        bytes32 digest = keccak256("message");
        assertEq(registry.requireSigned(artistId, digest, _proof(artistKey, digest)), artist);
        assertEq(registry.requireSigned(artistId, digest, _proof(walletKey, digest)), wallet);
    }

    function test_RequireSigned_Refusals() public {
        bytes32 digest = keccak256("message");
        vm.expectRevert(
            abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, outsider)
        );
        registry.requireSigned(artistId, digest, _proof(outsiderKey, digest));
        // The right wallet named, another key's signature.
        bytes memory forged = abi.encodePacked(wallet, _sign(outsiderKey, digest));
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, wallet));
        registry.requireSigned(artistId, digest, forged);
        vm.expectRevert(
            abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, address(0))
        );
        registry.requireSigned(artistId, digest, hex"0102");
        _revoke(artist, wallet);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, wallet));
        registry.requireSigned(artistId, digest, _proof(walletKey, digest));
    }

    /// @dev A consent is good only for the contract that asks for it.
    function test_RequireConsent_BindsTheCaller() public {
        bytes32 what = keccak256("item");
        address subject = makeAddr("subject");
        bytes memory proof = _proof(walletKey, registry.consentDigest(subject, what));
        vm.prank(subject);
        assertEq(registry.requireConsent(artistId, what, proof), wallet);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, wallet));
        registry.requireConsent(artistId, what, proof);
    }

    /// @dev The root never reads the consolidation source: a source whose code changed (or that
    ///      fails) leaves the root acting and answers "no" for every other wallet.
    function test_Accounts_RootNeverDependsOnTheSource() public {
        vm.etch(address(adapter), hex"60006000fd");
        assertTrue(registry.isWallet(artistId, artist));
        assertFalse(registry.isWallet(artistId, wallet));
        bytes32 digest = keccak256("message");
        assertEq(registry.requireSigned(artistId, digest, _proof(artistKey, digest)), artist);
    }

    // ----------------------------------------------------------------- the account's own change

    /// @dev A second consolidated wallet stages a change (fails on the old registry: only the
    ///      authority, or a wallet of a dormant artist, could sign).
    function test_OwnChange_AnyWalletStagesAndAnyoneRelays() public {
        ArtistIdentity memory next = _identity(artist, payout);
        _stage(walletKey, next);
        PendingChange memory p = registry.pendingChange(artistId);
        assertEq(uint8(p.kind), uint8(ChangeKind.OWN));
        assertEq(p.executableAt, block.timestamp + 2 days);
        assertEq(p.next.payout, payout);
        assertEq(registry.changeNonce(artistId), 1);
        assertEq(registry.payoutAddress(artistId), address(0), "payout held while it moves");
        vm.warp(block.timestamp + 2 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.ChangeNotDue.selector, artistId, uint48(START + 2 days)
            )
        );
        registry.executeChange(artistId);
        vm.warp(block.timestamp + 1);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeExecuted(artistId, _identityNow(), next);
        registry.executeChange(artistId);
        assertEq(registry.payoutAddress(artistId), payout);
    }

    function test_OwnChange_MovesTheRootToAWalletOfTheAccount() public {
        _stage(artistKey, _identity(wallet, wallet));
        assertEq(registry.reservedFor(wallet), artistId);
        vm.warp(block.timestamp + 2 days);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), wallet);
        assertEq(registry.artistIdOf(wallet), artistId);
        assertEq(registry.artistIdOf(artist), artistId, "past roots keep resolving");
        assertEq(registry.reservedFor(wallet), 0);
    }

    function test_OwnChange_TheNewRootMustBeAWalletOfTheAccount() public {
        (bool ok, bytes memory data) = _relay(_changeCall(artistKey, _identity(newRoot, artist)));
        assertFalse(ok);
        assertEq(data, abi.encodeWithSelector(IArtistRegistry.InvalidIdentity.selector));
    }

    /// @dev If the new root leaves the consolidation before the change runs, it is cleared.
    function test_OwnChange_RecheckedAtExecution() public {
        _stage(artistKey, _identity(wallet, wallet));
        _revoke(wallet, artist);
        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, address(registry), false);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), artist);
    }

    function test_OwnChange_Refusals() public {
        (bool ok, bytes memory data) = _relay(_changeCall(outsiderKey, _identity(artist, payout)));
        assertFalse(ok, "an outsider");
        assertEq(
            data, abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, outsider)
        );
        _stage(artistKey, _identity(artist, payout));
        (ok, data) = _relay(_changeCall(walletKey, _identity(artist, artist)));
        assertEq(data, abi.encodeWithSelector(IArtistRegistry.ChangePending.selector, artistId));
    }

    /// @dev A change may not move the account onto a root another account holds: an own change
    ///      and a replacement are both refused with `AccountTaken`, before anything is staged.
    function test_OwnChange_RefusesARootAnotherAccountHolds() public {
        _register(outsider);
        (bool ok, bytes memory data) = _relay(_changeCall(artistKey, _identity(outsider, payout)));
        assertFalse(ok);
        assertEq(data, abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, outsider));
        bytes memory replacement = _replacementCall(_identity(outsider, outsider), outsiderKey);
        vm.prank(network);
        (ok, data) = address(registry).call(replacement);
        assertFalse(ok);
        assertEq(data, abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, outsider));
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
    }

    /// @dev Cancelling or contesting needs a pending change.
    function test_CancelChange_RefusesWithNothingPending() public {
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NoPendingChange.selector, artistId));
        registry.cancelChange(artistId);
    }

    function test_OwnChange_ANonceIsUsedOnce() public {
        bytes memory call = _changeCall(walletKey, _identity(artist, payout));
        (bool ok,) = _relay(call);
        assertTrue(ok);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        bytes memory data;
        (ok, data) = _relay(call);
        assertFalse(ok, "the nonce moved on");
    }

    function test_OwnChange_AnyWalletCancels() public {
        _stage(artistKey, _identity(artist, payout));
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.NotAuthorized.selector, artistId, outsider)
        );
        registry.cancelChange(artistId);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, wallet, false);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        assertEq(registry.payoutAddress(artistId), artist);
    }

    function test_RevokeNonce_AnyWallet() public {
        bytes memory call = _changeCall(artistKey, _identity(artist, payout));
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.NotAuthorized.selector, artistId, outsider)
        );
        registry.revokeNonce(artistId);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.NonceRevoked(artistId, 0);
        vm.prank(wallet);
        registry.revokeNonce(artistId);
        (bool ok,) = _relay(call);
        assertFalse(ok);
    }

    // ----------------------------------------------------------------- network replacement

    function test_Replacement_FourteenDaysThenExecutes() public {
        ArtistIdentity memory next = _identity(newRoot, newRoot);
        vm.recordLogs();
        _stageReplacement(next, newKey);
        assertEq(_logged(IArtistRegistry.ChangeCancelled.selector), 0, "nothing to cancel");
        assertEq(registry.reservedFor(newRoot), artistId);
        PendingChange memory p = registry.pendingChange(artistId);
        assertEq(uint8(p.kind), uint8(ChangeKind.REPLACEMENT));
        assertEq(p.executableAt, block.timestamp + 14 days);
        assertEq(p.evidenceHash, EVIDENCE);
        // Nobody acts for the account while it is replaced.
        assertEq(registry.activeAuthorityOf(artistId), address(0));
        assertFalse(registry.isWallet(artistId, artist));
        assertFalse(registry.isWallet(artistId, wallet));
        vm.warp(block.timestamp + 14 days);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), newRoot);
        assertEq(registry.activeAuthorityOf(artistId), newRoot);
        assertTrue(registry.isWallet(artistId, newRoot));
        assertFalse(registry.isWallet(artistId, wallet), "the old account's wallets are out");
    }

    function test_Replacement_Refusals() public {
        ArtistIdentity memory next = _identity(newRoot, newRoot);
        bytes memory call = _replacementCall(next, newKey);
        vm.prank(stranger);
        (bool ok, bytes memory data) = address(registry).call(call);
        assertFalse(ok);
        assertEq(
            data,
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        // The new root must accept.
        bytes memory wrong = _replacementCall(next, outsiderKey);
        vm.prank(network);
        (ok, data) = address(registry).call(wrong);
        assertEq(data, abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, newRoot));
        // No payout-only replacement: the root must change.
        bytes memory same = _replacementCall(_identity(artist, payout), artistKey);
        vm.prank(network);
        (ok, data) = address(registry).call(same);
        assertEq(data, abi.encodeWithSelector(IArtistRegistry.InvalidIdentity.selector));
        _stageReplacement(next, newKey);
        vm.prank(network);
        (ok, data) = address(registry).call(call);
        assertEq(data, abi.encodeWithSelector(IArtistRegistry.ChangePending.selector, artistId));
    }

    function test_Replacement_ReplacesAPendingOwnChange() public {
        _stage(artistKey, _identity(artist, payout));
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, network, true);
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.REPLACEMENT));
    }

    /// @dev C14: the network withdraws its own replacement at once (fails on the old registry,
    ///      where only a guardian veto or a contest removed an override).
    function test_CancelReplacement_ByTheNetwork() public {
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, artist)
        );
        vm.prank(artist);
        registry.cancelReplacement(artistId);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, network, true);
        vm.prank(network);
        registry.cancelReplacement(artistId);
        assertEq(registry.activeAuthorityOf(artistId), artist);
        assertEq(registry.reservedFor(newRoot), 0);
        assertTrue(registry.isWallet(artistId, wallet));
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NoPendingChange.selector, artistId));
        registry.cancelReplacement(artistId);
        // An own change is not a replacement.
        _stage(artistKey, _identity(artist, payout));
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NoPendingChange.selector, artistId));
        registry.cancelReplacement(artistId);
    }

    /// @dev Integrator ruling 17: the network cancels an account's own pending change at once;
    ///      nobody else can through this path, and it never removes a replacement (fails on
    ///      the lane-1 registry, where only staging a replacement removed an own change).
    function test_CancelOwnChange_ByTheNetwork() public {
        _stage(artistKey, _identity(artist, payout));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, artist)
        );
        vm.prank(artist);
        registry.cancelOwnChange(artistId);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, network, true);
        vm.prank(network);
        registry.cancelOwnChange(artistId);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NoPendingChange.selector, artistId));
        registry.cancelOwnChange(artistId);
        // A replacement is not an own change.
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NoPendingChange.selector, artistId));
        registry.cancelOwnChange(artistId);
        // The account stages a new own change afterwards.
        vm.prank(network);
        registry.cancelReplacement(artistId);
        _stage(artistKey, _identity(artist, payout));
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.OWN));
    }

    /// @dev C13: a contested replacement runs only if the network upholds it within 90 days.
    function test_Contest_LapsesAfterNinetyDays() public {
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.NotAuthorized.selector, artistId, outsider)
        );
        registry.cancelChange(artistId);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeContested(artistId, wallet, bytes32(0));
        vm.prank(wallet);
        registry.cancelChange(artistId);
        uint256 contested = block.timestamp;
        vm.warp(block.timestamp + 14 days);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.ReplacementContested.selector, artistId)
        );
        registry.executeChange(artistId);
        vm.warp(contested + 90 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.ContestNotExpired.selector, artistId, uint48(contested + 90 days)
            )
        );
        registry.expireContest(artistId);
        assertEq(registry.activeAuthorityOf(artistId), address(0));
        vm.warp(contested + 90 days);
        // A lapsed contest no longer holds the account.
        assertEq(registry.activeAuthorityOf(artistId), artist);
        assertTrue(registry.isWallet(artistId, wallet));
        registry.expireContest(artistId);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
    }

    function test_Contest_WindowClosesWithTheNotice() public {
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.warp(block.timestamp + 14 days);
        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.ContestWindowClosed.selector, artistId, uint48(START + 14 days)
            )
        );
        registry.cancelChange(artistId);
        vm.warp(block.timestamp + 1 days);
        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.ContestWindowClosed.selector, artistId, uint48(START + 14 days)
            )
        );
        registry.cancelChange(artistId);
    }

    /// @dev Only the network resolves a contest.
    function test_ResolveContested_IsRestricted() public {
        DisputeOutcomeLogMock outcomes = _wireOutcomes();
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        outcomes.setOutcome(address(registry), artistId, VOTE);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        registry.resolveContested(artistId, false, VOTE);
    }

    /// @dev Expiring a lapsed contest logs it.
    function test_ExpireContest_Logs() public {
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        vm.warp(block.timestamp + 90 days);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ContestExpired(artistId);
        registry.expireContest(artistId);
    }

    /// @dev A signed change or acceptance past its deadline is refused.
    function test_Deadlines_ExpiredChangeAndAcceptanceAreRefused() public {
        ArtistIdentity memory next = _identity(artist, payout);
        uint64 deadline = uint64(block.timestamp - 1);
        bytes32 digest =
            registry.changeDigest(artistId, next, registry.changeNonce(artistId), deadline);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(SignatureVerifier.SignatureExpired.selector, deadline)
        );
        registry.stageChange(artistId, next, deadline, _proof(artistKey, digest));
        ArtistIdentity memory replacement = _identity(newRoot, newRoot);
        bytes memory acceptance =
            _sign(newKey, registry.replacementDigest(artistId, replacement, EVIDENCE, deadline));
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(SignatureVerifier.SignatureExpired.selector, deadline)
        );
        registry.stageReplacement(artistId, replacement, EVIDENCE, deadline, acceptance);
    }

    /// @dev Staging logs the change and the consumed acceptance; executing applies every field
    ///      and ends the pending change.
    function test_Replacement_LogsAndAppliesTheWholeIdentity() public {
        ArtistIdentity memory next =
            ArtistIdentity(newRoot, newRoot, keccak256("new profile"), keccak256("new doc"));
        vm.recordLogs();
        _stageReplacement(next, newKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, IArtistRegistry.ChangeStaged.selector), 1);
        assertEq(_count(logs, IArtistRegistry.ReplacementAcceptanceConsumed.selector), 1);
        vm.warp(block.timestamp + 14 days);
        registry.executeChange(artistId);
        (ArtistIdentity memory id,) = registry.artist(artistId);
        assertEq(id.profileId, next.profileId);
        assertEq(id.profileDocHash, next.profileDocHash);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        assertEq(registry.pendingChange(artistId).executableAt, 0);
    }

    /// @dev A contest stays lapsed after its lapse time, not only at it.
    function test_Contest_StaysLapsedAfterNinetyDays() public {
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        vm.warp(block.timestamp + 91 days);
        assertEq(registry.activeAuthorityOf(artistId), artist);
        registry.expireContest(artistId);
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
    }

    /// @dev A vote recorded after the contest upholds it whatever its value relative to the
    ///      outcome the contest saw, and a due change may be upheld and executed later than its
    ///      exact due time.
    function test_Contest_UpheldLateByAVoteBelowThePriorOutcome() public {
        DisputeOutcomeLogMock outcomes = _wireOutcomes();
        bytes32 prior = bytes32(type(uint256).max);
        bytes32 vote = bytes32(uint256(1));
        outcomes.setOutcome(address(registry), artistId, prior);
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        outcomes.setOutcome(address(registry), artistId, vote);
        vm.warp(block.timestamp + 15 days);
        vm.prank(network);
        registry.resolveContested(artistId, true, vote);
        assertEq(registry.authorityOf(artistId), newRoot);
    }

    /// @dev Only the latest recorded outcome resolves a contest: references on either side of it
    ///      are refused.
    function test_ResolveContested_RefusesOutcomesEitherSideOfTheLatest() public {
        DisputeOutcomeLogMock outcomes = _wireOutcomes();
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        bytes32 latest = bytes32(uint256(1) << 128);
        outcomes.setOutcome(address(registry), artistId, latest);
        bytes32[2] memory others = [bytes32(uint256(1)), bytes32(type(uint256).max)];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(network);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IArtistRegistry.OutcomeNotRecorded.selector, artistId, others[i]
                )
            );
            registry.resolveContested(artistId, false, others[i]);
        }
        vm.prank(network);
        registry.resolveContested(artistId, false, latest);
    }

    /// @dev An own change executes any time after it is due.
    function test_OwnChange_ExecutesLaterThanDue() public {
        _stage(artistKey, _identity(artist, payout));
        vm.warp(block.timestamp + 30 days);
        registry.executeChange(artistId);
        assertEq(registry.payoutAddress(artistId), payout);
    }

    /// @dev A root another account's pending change reserves is taken too, whichever side of
    ///      this account's ID that account's ID falls.
    function test_OwnChange_RefusesRootsOthersReserveEitherSideOfThisOne() public {
        (uint256 belowKey, uint256 aboveKey) = (0, 0);
        for (uint256 k = 0x2000; belowKey == 0 || aboveKey == 0; ++k) {
            address a = vm.addr(k);
            if (a < artist && belowKey == 0) belowKey = k;
            if (a > artist && aboveKey == 0) aboveKey = k;
        }
        uint256[2] memory keys = [belowKey, aboveKey];
        for (uint256 i; i < keys.length; ++i) {
            address other = vm.addr(keys[i]);
            address wanted = vm.addr(0x3000 + i);
            uint256 otherId = _register(other);
            // Both accounts may move their root to `wanted`; the other one stages it first.
            _consolidate(other, wanted);
            _consolidate(artist, wanted);
            ArtistIdentity memory next = _identity(wanted, wanted);
            uint64 deadline = uint64(block.timestamp + 1 days);
            bytes32 digest =
                registry.changeDigest(otherId, next, registry.changeNonce(otherId), deadline);
            vm.prank(stranger);
            registry.stageChange(otherId, next, deadline, _proof(keys[i], digest));
            assertEq(registry.reservedFor(wanted), otherId);
            (bool ok, bytes memory data) = _relay(_changeCall(artistKey, next));
            assertFalse(ok);
            assertEq(data, abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, wanted));
        }
    }

    /// @dev A root held by another account is taken whichever side of this account's ID that
    ///      account's ID falls.
    function test_OwnChange_RefusesRootsOfAccountsEitherSideOfThisOne() public {
        (address below, address above) = (address(0), address(0));
        for (uint256 k = 0x1000; below == address(0) || above == address(0); ++k) {
            address a = vm.addr(k);
            if (a < artist && below == address(0)) below = a;
            if (a > artist && above == address(0)) above = a;
        }
        address[2] memory others = [below, above];
        for (uint256 i; i < others.length; ++i) {
            _register(others[i]);
            (bool ok, bytes memory data) =
                _relay(_changeCall(artistKey, _identity(others[i], payout)));
            assertFalse(ok);
            assertEq(data, abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, others[i]));
        }
    }

    /// @dev A second contest of a contested replacement is a no-op: no event, and the contest
    ///      keeps its original time and prior outcome.
    function test_Contest_ASecondContestChangesNothing() public {
        DisputeOutcomeLogMock outcomes = _wireOutcomes();
        outcomes.setOutcome(address(registry), artistId, keccak256("earlier"));
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        PendingChange memory first = registry.pendingChange(artistId);
        vm.warp(block.timestamp + 1 days);
        outcomes.setOutcome(address(registry), artistId, VOTE);
        vm.recordLogs();
        vm.prank(artist);
        registry.cancelChange(artistId);
        assertEq(vm.getRecordedLogs().length, 0, "no event");
        PendingChange memory second = registry.pendingChange(artistId);
        assertEq(second.contestedAt, first.contestedAt, "contest time unchanged");
        assertEq(second.priorOutcome, keccak256("earlier"), "prior outcome unchanged");
        assertEq(uint8(second.kind), uint8(ChangeKind.REPLACEMENT));
    }

    /// @dev The network resolves only a live contest, and only by the latest recorded outcome.
    function test_ResolveContested_Refusals() public {
        DisputeOutcomeLogMock outcomes = _wireOutcomes();
        vm.startPrank(network);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NotContested.selector, artistId));
        registry.resolveContested(artistId, true, VOTE);
        vm.stopPrank();
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NotContested.selector, artistId));
        registry.resolveContested(artistId, true, VOTE);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        uint256 contested = block.timestamp;
        vm.startPrank(network);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.OutcomeNotRecorded.selector, artistId, bytes32(0)
            )
        );
        registry.resolveContested(artistId, false, bytes32(0));
        outcomes.setOutcome(address(registry), artistId, VOTE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.OutcomeNotRecorded.selector, artistId, keccak256("other")
            )
        );
        registry.resolveContested(artistId, false, keccak256("other"));
        // A lapsed contest can no longer be resolved, only expired.
        vm.warp(contested + 90 days);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NotContested.selector, artistId));
        registry.resolveContested(artistId, false, VOTE);
        vm.stopPrank();
    }

    /// @dev Only a contested change can expire: an uncontested replacement, or none, is refused.
    function test_ExpireContest_RefusesWithoutAContest() public {
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NotContested.selector, artistId));
        registry.expireContest(artistId);
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.warp(block.timestamp + 90 days);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NotContested.selector, artistId));
        registry.expireContest(artistId);
    }

    function test_Contest_UpheldByAVoteRecordedAfterIt() public {
        DisputeOutcomeLogMock outcomes = _wireOutcomes();
        outcomes.setOutcome(address(registry), artistId, keccak256("earlier"));
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        // The contest logs the outcome it must be resolved after.
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeContested(artistId, wallet, keccak256("earlier"));
        vm.prank(wallet);
        registry.cancelChange(artistId);
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.OutcomePredatesContest.selector, artistId, keccak256("earlier")
            )
        );
        registry.resolveContested(artistId, true, keccak256("earlier"));
        outcomes.setOutcome(address(registry), artistId, VOTE);
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.ChangeNotDue.selector, artistId, uint48(START + 14 days)
            )
        );
        registry.resolveContested(artistId, true, VOTE);
        vm.warp(block.timestamp + 14 days);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ContestResolved(artistId, true, true, VOTE);
        vm.recordLogs();
        vm.prank(network);
        registry.resolveContested(artistId, true, VOTE);
        assertEq(_logged(IArtistRegistry.ChangeCancelled.selector), 0, "executed, not cancelled");
        assertEq(registry.authorityOf(artistId), newRoot);
    }

    function test_Contest_VoidedByAVote() public {
        DisputeOutcomeLogMock outcomes = _wireOutcomes();
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.prank(artist);
        registry.cancelChange(artistId);
        outcomes.setOutcome(address(registry), artistId, VOTE);
        vm.prank(network);
        registry.resolveContested(artistId, false, VOTE);
        assertEq(registry.authorityOf(artistId), artist);
        assertEq(registry.activeAuthorityOf(artistId), artist);
    }

    function test_Replacement_AcceptanceIsUsedOnce() public {
        ArtistIdentity memory next = _identity(newRoot, newRoot);
        bytes memory call = _replacementCall(next, newKey);
        vm.prank(network);
        (bool ok,) = address(registry).call(call);
        assertTrue(ok);
        vm.prank(network);
        registry.cancelReplacement(artistId);
        vm.prank(network);
        bytes memory data;
        (ok, data) = address(registry).call(call);
        assertFalse(ok);
        assertEq(bytes4(data), IArtistRegistry.AcceptanceUsed.selector);
    }

    // ----------------------------------------------------------------- freeze

    /// @dev C17: a frozen account cannot sign, its payout reads zero, and it thaws after 14
    ///      days (fails on the old registry, which had no freeze).
    function test_Freeze_StopsTheAccountForFourteenDays() public {
        bytes32 digest = keccak256("message");
        vm.expectEmit(address(registry));
        emit IArtistRegistry.AccountFrozen(artistId, uint48(START + 14 days));
        vm.prank(network);
        registry.freeze(artistId);
        assertEq(registry.frozenUntil(artistId), START + 14 days);
        assertEq(registry.frozenUntil(uint160(artist)), START + 14 days);
        assertFalse(registry.isWallet(artistId, artist));
        assertFalse(registry.isWallet(artistId, wallet));
        assertEq(registry.payoutAddress(artistId), address(0));
        assertEq(registry.activeAuthorityOf(artistId), address(0));
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, artist));
        registry.requireSigned(artistId, digest, _proof(artistKey, digest));
        (bool ok,) = _relay(_changeCall(walletKey, _identity(artist, payout)));
        assertFalse(ok, "no change while frozen");
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.AccountIsFrozen.selector, artistId, uint48(START + 14 days)
            )
        );
        registry.freeze(artistId);
        vm.warp(START + 14 days);
        assertTrue(registry.isWallet(artistId, wallet));
        assertEq(registry.payoutAddress(artistId), artist);
        assertEq(registry.requireSigned(artistId, digest, _proof(artistKey, digest)), artist);
        vm.prank(network);
        registry.freeze(artistId);
        assertEq(registry.frozenUntil(artistId), START + 28 days, "placed again after it ended");
    }

    function test_Freeze_HoldsPendingChangesAndPayouts() public {
        PullOnlyPayeeMock payee = new PullOnlyPayeeMock{ value: 1 ether }(registry, artistId);
        _stage(artistKey, _identity(artist, artist));
        vm.prank(network);
        registry.freeze(artistId);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.AccountIsFrozen.selector, artistId, uint48(START + 14 days)
            )
        );
        registry.executeChange(artistId);
        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.AccountIsFrozen.selector, artistId, uint48(START + 14 days)
            )
        );
        registry.cancelChange(artistId);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(PullOnlyPayeeMock.NotPayoutAddress.selector, artist, address(0))
        );
        payee.release();
        vm.expectEmit(address(registry));
        emit IArtistRegistry.AccountUnfrozen(artistId);
        vm.prank(network);
        registry.unfreeze(artistId);
        registry.executeChange(artistId);
        vm.prank(artist);
        payee.release();
    }

    /// @dev The one exception to "a freeze holds pending changes": the network's own
    ///      `resolveContested` upholds a contested replacement during a freeze, and the freeze
    ///      keeps running for the new identity (accepted ruling; the NatSpec and spec say so).
    function test_Freeze_AnUpheldContestedReplacementStillExecutes() public {
        DisputeOutcomeLogMock outcomes = _wireOutcomes();
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.prank(wallet);
        registry.cancelChange(artistId);
        vm.warp(block.timestamp + 14 days);
        vm.prank(network);
        registry.freeze(artistId);
        uint48 until = registry.frozenUntil(artistId);
        outcomes.setOutcome(address(registry), artistId, VOTE);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ContestResolved(artistId, true, true, VOTE);
        vm.prank(network);
        registry.resolveContested(artistId, true, VOTE);
        assertEq(registry.authorityOf(artistId), newRoot);
        assertEq(registry.frozenUntil(artistId), until, "the freeze keeps running");
        assertEq(registry.activeAuthorityOf(artistId), address(0));
        assertFalse(registry.isWallet(artistId, newRoot));
        assertEq(registry.payoutAddress(artistId), address(0));
    }

    function test_Freeze_NetworkOnlyAndKnownAccounts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, wallet)
        );
        vm.prank(wallet);
        registry.freeze(artistId);
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, 7));
        registry.freeze(7);
    }

    // ----------------------------------------------------------------- payouts

    function test_PayoutValidation_RejectsProtocolContractsAndSplitWallets() public {
        (StreamMock stream, EditionsMastersMock editions) = _wireStream();
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
            (bool ok, bytes memory data) = _relay(_changeCall(artistKey, _identity(artist, bad[i])));
            assertFalse(ok);
            assertEq(data, abi.encodeWithSelector(IArtistRegistry.InvalidIdentity.selector));
        }
    }

    function test_PayoutValidation_RecheckedAtExecution() public {
        SplitFactoryWalletsMock factory = _wireSplitFactory();
        _stage(artistKey, _identity(artist, payout));
        factory.setWallet(payout, true);
        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, address(registry), false);
        registry.executeChange(artistId);
        assertEq(registry.payoutAddress(artistId), artist);
    }

    // ----------------------------------------------------------------- roles and wiring

    /// @dev Any wallet of the lead's account speaks as the artist (fails on the old registry,
    ///      which answered only for the active authority).
    function test_IsArtist_AnyWalletOfTheLeadAccount() public {
        (StreamMock stream, EditionsMastersMock editions) = _wireStream();
        assertTrue(registry.isArtist(address(stream), 1, artist));
        assertTrue(registry.isArtist(address(stream), 1, wallet));
        assertTrue(registry.isArtist(address(editions), 1, wallet));
        assertFalse(registry.isArtist(address(stream), 1, outsider));
        assertFalse(registry.isArtist(address(stream), 2, artist), "unknown work");
        assertFalse(registry.isArtist(address(editions), 3, artist), "foreign master");
        assertFalse(registry.isArtist(address(0), 1, artist));
        vm.prank(network);
        registry.freeze(artistId);
        assertFalse(registry.isArtist(address(stream), 1, artist), "frozen");
    }

    /// @dev A token that is neither the Stream nor its Editions is never answered for, and an
    ///      edition the Editions contract does not know (its `masterOf` reverts) is "no".
    function test_IsArtist_AnyOtherTokenOrAnUnknownEditionIsNo() public {
        (StreamMock stream, EditionsMastersMock editions) = _wireStream();
        EditionsMastersMock other = new EditionsMastersMock();
        other.setEdition(1, address(stream));
        assertFalse(registry.isArtist(address(other), 1, artist), "not the bound Editions");
        assertFalse(registry.isArtist(address(editions), 2, artist), "unknown edition");
        assertTrue(registry.isArtist(address(editions), 1, artist));
    }

    /// @dev An edition whose master is not the bound Stream is "no", even when the work ID it
    ///      names is one of the artist's works.
    function test_IsArtist_AnEditionOfAnotherMasterIsNo() public {
        (StreamMock stream, EditionsMastersMock editions) = _wireStream();
        assertTrue(registry.isArtist(address(editions), 1, artist));
        editions.setEdition(1, stranger);
        assertFalse(registry.isArtist(address(editions), 1, artist));
        assertTrue(registry.isArtist(address(stream), 1, artist), "the work itself still answers");
    }

    /// @dev An edition is answered for through the work its master names, not through its own
    ///      ID.
    function test_IsArtist_AnEditionResolvesToTheWorkItsMasterNames() public {
        (StreamMock stream,) = _wireStream();
        RemappedEditionsMock remapped = new RemappedEditionsMock(address(stream), 5, 1);
        stream.setEditions(address(remapped));
        assertTrue(registry.isArtist(address(remapped), 5, artist), "edition 5 is work 1");
        stream.setWork(5, uint160(outsider));
        assertTrue(registry.isArtist(address(remapped), 5, artist), "not work 5's artist");
        assertFalse(registry.isArtist(address(remapped), 5, outsider));
    }

    /// @dev An edition the Editions contract does not know is "no", even when a work of the
    ///      artist has the same ID.
    function test_IsArtist_AnUnknownEditionWithTheIdOfAWorkIsNo() public {
        (StreamMock stream,) = _wireStream();
        EditionsMastersMock empty = new EditionsMastersMock();
        stream.setEditions(address(empty));
        assertTrue(registry.isArtist(address(stream), 1, artist));
        assertFalse(registry.isArtist(address(empty), 1, artist));
    }

    /// @dev Gas rule: a Stream `artistOf` that runs out of the gas forwarded to it reverts
    ///      `BoundedCallShortfall`, never reads as "not the artist".
    function test_IsArtist_AStreamShortfallReverts() public {
        BurningArtistStream burning = new BurningArtistStream();
        vm.prank(admin);
        registry.bindStream(address(burning));
        bytes memory call = abi.encodeCall(registry.isArtist, (address(burning), 1, artist));
        (bool ok, bytes memory data) = address(registry).staticcall{ gas: 1_000_000 }(call);
        assertFalse(ok);
        assertEq(
            data,
            abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, address(burning))
        );
    }

    /// @dev Before a Stream is bound every subject is "no", without calling anything.
    function test_IsArtist_NoStreamBoundIsNo() public {
        assertEq(registry.stream(), address(0));
        assertFalse(registry.isArtist(makeAddr("token"), 1, artist));
        assertFalse(registry.isArtist(address(0), 1, artist));
    }

    /// @dev Gas rule: an Editions `masterOf` that runs out of the gas forwarded to it reverts
    ///      `BoundedCallShortfall`, never reads as "not the artist".
    function test_IsArtist_AnEditionsShortfallReverts() public {
        (StreamMock stream,) = _wireStream();
        BurningEditionsMock burning = new BurningEditionsMock(address(stream));
        stream.setEditions(address(burning));
        assertTrue(registry.isArtist(address(burning), 1, artist), "answers when it fits");
        burning.setBurn(type(uint256).max);
        bytes memory call = abi.encodeCall(registry.isArtist, (address(burning), 1, artist));
        (bool ok, bytes memory data) = address(registry).staticcall{ gas: 1_000_000 }(call);
        assertFalse(ok);
        assertEq(
            data,
            abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, address(burning))
        );
    }

    function test_Bindings_AreOneShotAndChecked() public {
        StreamMock stream = new StreamMock();
        address federation = address(new FederationRegistryStub());
        address another = address(new PackageRegistryStub());
        vm.startPrank(admin);
        registry.bindStream(address(stream));
        registry.bindFederationRegistry(federation);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.AlreadyBound.selector, bytes32("STREAM"))
        );
        registry.bindStream(address(stream));
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.AlreadyBound.selector, bytes32("PACKAGE_REGISTRY")
            )
        );
        registry.bindPackageRegistry(another);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        registry.bindSplitFactory(stranger);
        vm.stopPrank();
        address factory = address(new SplitFactoryWalletsMock());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, network)
        );
        vm.prank(network);
        registry.bindSplitFactory(factory);
    }

    /// @dev The constructor checks the source against its pin, as the setter does.
    function test_Constructor_ChecksTheSourceAgainstItsPin() public {
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(adapter))
        );
        new ArtistRegistry(address(manager), adapter, keccak256("other code"));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        new ArtistRegistry(address(manager), IConsolidationSource(stranger), bytes32(0));
    }

    /// @dev Each one-shot binding checks its target before anything else, and logs it.
    function test_Bindings_CheckTheTargetFirstAndLog() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        registry.bindPackageRegistry(stranger);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        registry.bindStream(stranger);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        registry.bindFederationRegistry(stranger);
        StreamMock s = new StreamMock();
        vm.expectEmit(address(registry));
        emit IArtistRegistry.Bound("STREAM", address(s));
        registry.bindStream(address(s));
        vm.stopPrank();
    }

    function test_SetConsolidationSource_SwapsTheSourceWithItsPin() public {
        ConsolidationSourceMock mock = new ConsolidationSourceMock();
        IConsolidationSource next = IConsolidationSource(address(mock));
        mock.set(artist, outsider, true);
        vm.startPrank(network);
        vm.expectRevert(IArtistRegistry.ExpectedValueMismatch.selector);
        registry.setConsolidationSource(next, next, address(next).codehash);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(next))
        );
        registry.setConsolidationSource(adapter, next, keccak256("other code"));
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ConsolidationSourceSet(
            address(adapter), address(next), address(next).codehash
        );
        registry.setConsolidationSource(adapter, next, address(next).codehash);
        vm.stopPrank();
        assertTrue(registry.isWallet(artistId, outsider));
        assertFalse(registry.isWallet(artistId, wallet), "the old source is no longer read");
        // A source that reverts or answers anything but true is "no"; the root still acts.
        mock.setMode(ConsolidationSourceMock.Mode.REVERT);
        assertFalse(registry.isWallet(artistId, outsider));
        mock.setMode(ConsolidationSourceMock.Mode.MALFORMED);
        assertFalse(registry.isWallet(artistId, outsider));
        assertTrue(registry.isWallet(artistId, artist));
    }

    function test_SupportsInterface() public view {
        assertTrue(registry.supportsInterface(type(IERC165).interfaceId));
        assertTrue(registry.supportsInterface(type(IArtistRoleResolver).interfaceId));
        assertTrue(registry.supportsInterface(type(IArtistRegistry).interfaceId));
        assertTrue(registry.supportsInterface(type(IArtistPayoutResolver).interfaceId));
        assertTrue(registry.supportsInterface(type(IAccounts).interfaceId));
        assertFalse(registry.supportsInterface(0xffffffff));
        bytes4[5] memory ids = [
            type(IERC165).interfaceId,
            type(IArtistRoleResolver).interfaceId,
            type(IArtistRegistry).interfaceId,
            type(IArtistPayoutResolver).interfaceId,
            type(IAccounts).interfaceId
        ];
        for (uint256 i; i < ids.length; ++i) {
            assertFalse(registry.supportsInterface(bytes4(uint32(ids[i]) - 1)));
            assertFalse(registry.supportsInterface(bytes4(uint32(ids[i]) + 1)));
        }
    }

    function test_FixedValues() public view {
        assertEq(registry.OWN_CHANGE_DELAY(), 2 days);
        assertEq(registry.REPLACEMENT_NOTICE(), 14 days);
        assertEq(registry.CONTEST_LAPSE(), 90 days);
        assertEq(registry.FREEZE_PERIOD(), 14 days);
    }

    /// @dev The digests are standard EIP-712 over the registry's domain, as wallets compute them.
    function test_Golden_Digests() public view {
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
        ArtistIdentity memory next = _identity(newRoot, payout);
        bytes32 change = keccak256(
            abi.encode(
                keccak256(
                    "IdentityChange(uint256 artistId,address root,address payout,bytes32 profileId,bytes32 profileDocHash,uint256 nonce,uint64 deadline)"
                ),
                artistId,
                next.root,
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
        bytes32 consent = keccak256(
            abi.encode(keccak256("Consent(address subject,bytes32 what)"), stranger, keccak256("w"))
        );
        assertEq(
            registry.consentDigest(stranger, keccak256("w")),
            keccak256(abi.encodePacked(hex"1901", domain, consent))
        );
        assertEq(
            Typehashes.REPLACEMENT_ACCEPTANCE,
            keccak256(
                "ReplacementAcceptance(uint256 artistId,address root,address payout,bytes32 profileId,bytes32 profileDocHash,bytes32 evidenceHash,uint64 deadline)"
            )
        );
    }

    /// @dev The statement log binds only as an installable dependency: an address without code
    ///      and an EIP-7702 delegated account (here delegated to a log that names this registry)
    ///      are refused with `InvalidDependency` before anything is read. Fails without the
    ///      check: the codeless address reverts `InvalidBinding` instead, and the delegated
    ///      account binds.
    function test_BindStatementLog_RefusesAnAccountThatIsNotAnInstallableContract() public {
        address codeless = makeAddr("codelessLog");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, codeless));
        registry.bindStatementLog(codeless);
        DisputeOutcomeLogMock answering = new DisputeOutcomeLogMock(address(registry));
        address delegated = makeAddr("delegatedLog");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(answering)));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, delegated));
        registry.bindStatementLog(delegated);
        assertEq(registry.statementLog(), address(0), "nothing bound");
    }

    /// @dev A statement log whose `artistResolver()` names another registry is refused with
    ///      `InvalidBinding`, and nothing is bound.
    function test_BindStatementLog_RefusesALogNamingAnotherResolver() public {
        DisputeOutcomeLogMock foreign = new DisputeOutcomeLogMock(stranger);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.InvalidBinding.selector, address(foreign))
        );
        registry.bindStatementLog(address(foreign));
        address[2] memory resolvers = [address(1), address(type(uint160).max)];
        for (uint256 i; i < resolvers.length; ++i) {
            DisputeOutcomeLogMock other = new DisputeOutcomeLogMock(resolvers[i]);
            vm.prank(admin);
            vm.expectRevert(
                abi.encodeWithSelector(IArtistRegistry.InvalidBinding.selector, address(other))
            );
            registry.bindStatementLog(address(other));
        }
        assertEq(registry.statementLog(), address(0), "nothing bound");
    }

    // ----------------------------------------------------------------- helpers

    function _identityNow() internal view returns (ArtistIdentity memory id) {
        (id,) = registry.artist(artistId);
    }

    function _wireOutcomes() internal returns (DisputeOutcomeLogMock outcomes) {
        outcomes = new DisputeOutcomeLogMock(address(registry));
        vm.prank(admin);
        registry.bindStatementLog(address(outcomes));
    }

    function _wireSplitFactory() internal returns (SplitFactoryWalletsMock factory) {
        factory = new SplitFactoryWalletsMock();
        vm.prank(admin);
        registry.bindSplitFactory(address(factory));
    }

    /// @dev How many logs since `vm.recordLogs` have `topic` as their first topic.
    function _logged(bytes32 topic) internal returns (uint256) {
        return _count(vm.getRecordedLogs(), topic);
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) ++n;
        }
    }

    function _wireStream() internal returns (StreamMock stream, EditionsMastersMock editions) {
        stream = new StreamMock();
        editions = new EditionsMastersMock();
        stream.setEditions(address(editions));
        stream.setWork(1, artistId);
        editions.setEdition(1, address(stream));
        editions.setEdition(3, stranger);
        vm.prank(admin);
        registry.bindStream(address(stream));
    }
}
