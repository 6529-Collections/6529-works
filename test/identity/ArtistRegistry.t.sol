// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { IAccounts } from "src/interfaces/IAccounts.sol";
import { IArtistRegistry, IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { IArtistRoleResolver } from "src/interfaces/IArtistRoleResolver.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "src/interfaces/types/IdentityTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
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
import { IdentityFixture } from "./IdentityFixture.sol";

/// @notice The artist registry: accounts (every consolidated wallet acts for the account), the
///         account's own changes, network replacements, freezes, payouts and the role answers.
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
        _stageReplacement(next, newKey);
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

    /// @dev C13: a contested replacement runs only if the network upholds it within 90 days.
    function test_Contest_LapsesAfterNinetyDays() public {
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.NotAuthorized.selector, artistId, outsider)
        );
        registry.cancelChange(artistId);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeContested(artistId, wallet);
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
    }

    function test_Contest_UpheldByAVoteRecordedAfterIt() public {
        DisputeOutcomeLogMock outcomes = _wireOutcomes();
        outcomes.setOutcome(address(registry), artistId, keccak256("earlier"));
        _stageReplacement(_identity(newRoot, newRoot), newKey);
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
        vm.prank(network);
        registry.resolveContested(artistId, true, VOTE);
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
