// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { IArtistRegistry, IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IAccounts } from "src/interfaces/core/IAccounts.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "src/interfaces/types/IdentityTypes.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { Burner, GasRuleAssertions } from "../helpers/GasRule.sol";
import { ConsolidationSourceMock, InterfaceStub } from "../mocks/identity/IdentityStreamMocks.sol";
import { PredecessorMock } from "../mocks/identity/PredecessorMock.sol";
import { AccountsFixture } from "./AccountsFixture.sol";

/// @dev A payout contract that refuses every call until flipped, then burns all the gas it
///      is given.
contract GasBurningPayout {
    bool public hostile;

    function flip() external {
        hostile = true;
    }

    fallback() external {
        if (hostile) {
            while (true) { }
        }
        revert();
    }
}

/// @notice An accounts module that replaces another (`previous`). For an account it has not
///         recorded it answers from the replaced module's record; it never registers an address
///         that module knows; the first change it makes to such an account copies the record,
///         pending change included, and from then on it alone answers; a replaced module that
///         stops answering stops only the accounts it still holds; one that runs short of gas
///         makes the call revert.
/// @dev `first` is the fixture's module (no predecessor) with one registered artist, whose
///      root `artist` is consolidated with `wallet`. `next` replaces it through `replaced`, a
///      stand-in that forwards every read to `first` until a test makes it misbehave.
contract AccountsSuccessorModuleTest is AccountsFixture, GasRuleAssertions {
    Accounts internal first;
    Accounts internal next;
    PredecessorMock internal replaced;
    uint256 internal outsiderId;

    function setUp() public override {
        super.setUp();
        first = registry;
        replaced = new PredecessorMock(address(first));
        next = _successor(address(replaced));
        outsiderId = uint256(uint160(outsider));
    }

    function _successor(address previous) internal returns (Accounts module) {
        module = new Accounts(
            address(manager),
            adapter,
            address(adapter).codehash,
            Accounts.Wiring(
                address(directory),
                streamAddr,
                editionsAddr,
                address(factory),
                address(outcomes),
                packageRegistry,
                previous
            ),
            new address[](0)
        );
        bytes4[] memory s = new bytes4[](8);
        s[0] = Accounts.stageReplacement.selector;
        s[1] = Accounts.cancelReplacement.selector;
        s[2] = Accounts.resolveContested.selector;
        s[3] = Accounts.freeze.selector;
        s[4] = Accounts.unfreeze.selector;
        s[5] = Accounts.setConsolidationSource.selector;
        s[6] = Accounts.setPackageRegistry.selector;
        s[7] = Accounts.cancelOwnChange.selector;
        vm.prank(admin);
        manager.setTargetFunctionRole(address(module), s, NETWORK);
    }

    /// @dev Points the fixture's helpers at `module` (they sign in its domain).
    function _use(Accounts module) internal {
        registry = module;
    }

    /// @dev Puts `module` in the directory's ACCOUNTS slot, as an activation does: from now on
    ///      it is the only module that writes. Also points the fixture's helpers at it.
    function _force(Accounts module) internal {
        directory.setModule(Slots.ACCOUNTS, address(module));
        registry = module;
    }

    function _notInForce(Accounts module) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IModuleSlots.NotModule.selector, Slots.ACCOUNTS, module);
    }

    /// @dev Moves the account to `newRoot` in the first module: staged, waited out, executed.
    function _moveInFirst() internal {
        _use(first);
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.warp(block.timestamp + 14 days);
        first.executeChange(artistId);
        assertEq(first.authorityOf(artistId), newRoot);
    }

    // ------------------------------------------------------------------ wiring

    function test_Successor_TheFirstModuleReplacesNone() public {
        assertEq(first.previous(), address(0));
        assertEq(next.previous(), address(replaced));
        uint256 unknown = uint256(uint160(stranger));
        assertTrue(first.isWallet(unknown, stranger), "its own single-wallet account");
        assertFalse(first.isWallet(unknown, artist));
        assertFalse(first.isWallet(uint256(1) << 160, stranger));
        assertEq(first.artistIdOf(stranger), 0);
        assertEq(first.reservedFor(stranger), 0);
        assertEq(first.payoutAddress(unknown), address(0));
        assertEq(first.frozenUntil(unknown), 0);
        assertEq(uint8(first.pendingChange(unknown).kind), uint8(ChangeKind.NONE));
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, unknown));
        first.authorityOf(unknown);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, unknown));
        first.activeAuthorityOf(unknown);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, unknown));
        first.artist(unknown);
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, unknown));
        first.freeze(unknown);
        // An ID wider than an address names no account, whatever its low bits are.
        vm.prank(network);
        first.freeze(artistId);
        assertGt(first.frozenUntil(artistId), block.timestamp);
        assertEq(first.frozenUntil(uint256(1) << 160 | artistId), 0);
    }

    function test_Successor_ThePredecessorMustBeAnAccountsModule() public {
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        _successor(stranger);
        address other = address(new InterfaceStub(0x12345678));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, other));
        _successor(other);
    }

    // ------------------------------------------------------------------ reading through

    function test_Successor_AnswersAnAccountItHasNotRecordedFromThePredecessor() public view {
        (ArtistIdentity memory mine, uint48 frozen) = next.artist(artistId);
        (ArtistIdentity memory theirs,) = first.artist(artistId);
        assertEq(keccak256(abi.encode(mine)), keccak256(abi.encode(theirs)));
        assertEq(frozen, 0);
        assertEq(next.authorityOf(artistId), artist);
        assertEq(next.activeAuthorityOf(artistId), artist);
        assertEq(next.payoutAddress(artistId), artist);
        assertEq(next.artistIdOf(artist), artistId);
        assertEq(next.frozenUntil(artistId), 0);
        assertEq(next.frozenUntil(uint256(uint160(artist))), 0);
        assertEq(uint8(next.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        assertEq(next.changeNonce(artistId), 0);

        assertTrue(next.isWallet(artistId, artist));
        assertTrue(next.isWallet(artistId, wallet), "consolidated, by this module's source");
        assertFalse(next.isWallet(artistId, stranger));
        assertFalse(next.isWallet(artistId, address(0)));
        bytes32 digest = keccak256("message");
        assertEq(next.requireSigned(artistId, digest, _proof(walletKey, digest)), wallet);
    }

    function test_Successor_AnInheritedAccountUsesThisModulesConsolidationSource() public {
        assertTrue(next.isWallet(artistId, wallet));
        _revoke(wallet, artist);
        assertFalse(next.isWallet(artistId, wallet));
        assertTrue(next.isWallet(artistId, artist));
    }

    /// @dev With a source of its own that disagrees with the replaced module's, this module's
    ///      source decides who is consolidated with an inherited account's root.
    function test_Successor_ADifferentSourceHereDecidesTheWalletsOfAnInheritedAccount() public {
        ConsolidationSourceMock other = new ConsolidationSourceMock();
        other.set(artist, outsider, true);
        vm.prank(network);
        next.setConsolidationSource(
            adapter, IConsolidationSource(address(other)), address(other).codehash
        );
        assertTrue(first.isWallet(artistId, wallet), "by the replaced module's source");
        assertFalse(first.isWallet(artistId, outsider));
        assertFalse(next.isWallet(artistId, wallet), "not by this module's");
        assertTrue(next.isWallet(artistId, outsider));
        assertTrue(next.isWallet(artistId, artist), "the root needs no source");
        bytes32 digest = keccak256("message");
        assertEq(next.requireSigned(artistId, digest, _proof(outsiderKey, digest)), outsider);
    }

    function test_Successor_AMovedAccountsFirstAddressHasNoWallet() public {
        _moveInFirst();
        assertEq(next.authorityOf(artistId), newRoot);
        assertEq(next.payoutAddress(artistId), newRoot);
        assertTrue(next.isWallet(artistId, newRoot));
        assertFalse(next.isWallet(artistId, artist), "the address the ID is made from");
        assertFalse(next.isWallet(uint256(uint160(artist)), artist));
        assertFalse(next.isWallet(artistId, wallet), "consolidated with the former root only");
        assertTrue(next.isWallet(uint256(uint160(newRoot)), newRoot), "named by its root");
        assertEq(next.artistIdOf(artist), artistId);
        assertEq(next.artistIdOf(newRoot), artistId);
        assertEq(next.frozenUntil(uint256(uint160(newRoot))), 0);
        bytes32 digest = keccak256("message");
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, artist));
        next.requireSigned(artistId, digest, _proof(artistKey, digest));
        assertEq(next.requireSigned(artistId, digest, _proof(newKey, digest)), newRoot);
    }

    function test_Successor_AFreezeOrAPendingReplacementInThePredecessorStopsTheAccount() public {
        vm.prank(network);
        first.freeze(artistId);
        uint48 until = first.frozenUntil(artistId);
        assertEq(next.frozenUntil(artistId), until);
        assertEq(next.frozenUntil(uint256(uint160(artist))), until);
        assertFalse(next.isWallet(artistId, artist));
        assertFalse(next.isWallet(artistId, wallet));
        assertEq(next.activeAuthorityOf(artistId), address(0));
        assertEq(next.authorityOf(artistId), artist);
        assertEq(next.payoutAddress(artistId), address(0));
        (, uint48 frozen) = next.artist(artistId);
        assertEq(frozen, until);

        vm.prank(network);
        first.unfreeze(artistId);
        assertTrue(next.isWallet(artistId, artist));
        assertEq(next.payoutAddress(artistId), artist);

        _use(first);
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        assertFalse(next.isWallet(artistId, artist), "nobody acts during the notice");
        assertEq(next.activeAuthorityOf(artistId), address(0));
        assertEq(next.payoutAddress(artistId), address(0), "held while the payout would move");
        PendingChange memory p = next.pendingChange(artistId);
        assertEq(keccak256(abi.encode(p)), keccak256(abi.encode(first.pendingChange(artistId))));
        assertEq(uint8(p.kind), uint8(ChangeKind.REPLACEMENT));
        assertEq(next.reservedFor(newRoot), artistId);
    }

    // ------------------------------------------------------------------ new accounts

    function test_Successor_AnAddressNobodyKnowsIsItsOwnAccountAndRegistersHere() public {
        assertTrue(next.isWallet(outsiderId, outsider));
        assertFalse(next.isWallet(outsiderId, artist));
        assertFalse(next.isWallet(uint256(1) << 160 | outsiderId, outsider));
        bytes32 digest = keccak256("first acceptance");
        assertEq(next.requireSigned(outsiderId, digest, _proof(outsiderKey, digest)), outsider);

        _force(next);
        vm.expectEmit(address(next));
        emit IArtistRegistry.ArtistRegistered(
            outsiderId, ArtistIdentity(outsider, outsider, PROFILE, PROFILE_DOC)
        );
        vm.prank(packageRegistry);
        assertEq(next.register(outsider, PROFILE, PROFILE_DOC), outsiderId);
        assertEq(next.authorityOf(outsiderId), outsider);
        assertEq(next.payoutAddress(outsiderId), outsider);
        assertEq(next.artistIdOf(outsider), outsiderId);
        assertEq(first.artistIdOf(outsider), 0, "the replaced module is not written");
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, outsiderId));
        first.authorityOf(outsiderId);
    }

    /// @dev The root, a former root, and an address a pending change reserves in the replaced
    ///      module are all refused: none of them can be given a second account.
    function test_Successor_NeverRegistersAnAddressThePredecessorKnows() public {
        _moveInFirst();
        _use(first);
        bytes memory second = _replacementCall(_identity(outsider, outsider), outsiderKey);
        vm.prank(network);
        (bool ok,) = address(first).call(second);
        assertTrue(ok, "a second replacement staged in the first module");
        assertEq(first.reservedFor(outsider), artistId);

        address[3] memory taken = [artist, newRoot, outsider];
        for (uint256 i; i < taken.length; ++i) {
            _force(next);
            vm.prank(packageRegistry);
            vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, taken[i]));
            next.register(taken[i], PROFILE, PROFILE_DOC);
        }
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, outsiderId));
        next.authorityOf(outsiderId);
    }

    /// @dev A root named in this module must be free in the replaced one too.
    function test_Successor_ANewRootMustBeFreeInThePredecessorToo() public {
        _force(next);
        vm.prank(packageRegistry);
        next.register(outsider, PROFILE, PROFILE_DOC);
        _use(next);
        uint256 inherited = artistId;
        artistId = outsiderId;
        // `artist` is the root of an account the replaced module holds.
        bytes memory call = _replacementCall(_identity(artist, artist), artistKey);
        vm.prank(network);
        (bool ok, bytes memory data) = address(next).call(call);
        assertFalse(ok);
        assertEq(data, abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, artist));
        // A free address is accepted.
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        assertEq(next.reservedFor(newRoot), outsiderId);
        artistId = inherited;
    }

    // ------------------------------------------------------------------ the first change copies

    function test_Successor_AFreezeHereCopiesTheAccountAndThisModuleAnswersAlone() public {
        (ArtistIdentity memory identity,) = first.artist(artistId);
        _force(next);
        vm.expectEmit(address(next));
        emit Accounts.AccountInherited(artistId, address(replaced), identity, 0);
        vm.prank(network);
        next.freeze(artistId);
        uint48 until = uint48(block.timestamp + 14 days);
        assertEq(next.frozenUntil(artistId), until);
        assertEq(first.frozenUntil(artistId), 0, "the replaced module is not written");
        assertFalse(next.isWallet(artistId, artist));
        assertEq(next.payoutAddress(artistId), address(0));

        vm.prank(network);
        next.unfreeze(artistId);
        assertTrue(next.isWallet(artistId, artist));
        assertTrue(next.isWallet(artistId, wallet));
        assertEq(next.payoutAddress(artistId), artist);

        // The replaced module's silence does not reach it: the root and the ID's address are
        // mapped here.
        replaced.setMode(PredecessorMock.Mode.SILENT);
        assertEq(next.artistIdOf(artist), artistId);
        assertTrue(next.isWallet(uint256(uint160(artist)), artist));
        assertEq(next.frozenUntil(artistId), 0);
    }

    function test_Successor_AnOwnChangeHereIsSignedInThisModulesDomain() public {
        ArtistIdentity memory change = _identity(artist, payout);
        _use(first);
        bytes memory signedForFirst = _changeCall(walletKey, change);
        _force(next);
        vm.prank(stranger);
        (bool ok, bytes memory data) = address(next).call(signedForFirst);
        assertFalse(ok, "a signature for the replaced module");
        assertEq(data, abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, wallet));
        (ok,) = address(next).call(_changeCallFor(next, stranger, outsiderKey, change));
        assertFalse(ok, "a signature of a stranger");

        _use(next);
        _stage(walletKey, change);
        assertEq(next.changeNonce(artistId), 1);
        assertEq(first.changeNonce(artistId), 0);
        assertEq(uint8(next.pendingChange(artistId).kind), uint8(ChangeKind.OWN));
        assertEq(uint8(first.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        vm.warp(block.timestamp + 2 days);
        next.executeChange(artistId);
        assertEq(next.payoutAddress(artistId), payout);
        assertEq(first.payoutAddress(artistId), artist);
    }

    function _changeCallFor(
        Accounts module,
        address,
        uint256 signerKey,
        ArtistIdentity memory change
    ) internal view returns (bytes memory) {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest =
            module.changeDigest(artistId, change, module.changeNonce(artistId), deadline);
        return abi.encodeCall(
            Accounts.stageChange, (artistId, change, deadline, _proof(signerKey, digest))
        );
    }

    /// @dev An own change pending in the replaced module is copied with its reservation when
    ///      a wallet cancels it here. It can no longer run in the replaced module, which
    ///      writes nothing once it is replaced.
    function test_Successor_APendingOwnChangeIsCopiedAndCancelledHere() public {
        _use(first);
        _stage(artistKey, _identity(wallet, payout));
        PendingChange memory pending = first.pendingChange(artistId);
        assertEq(next.reservedFor(wallet), artistId);

        _force(next);
        vm.expectEmit(address(next));
        emit IArtistRegistry.ChangeStaged(artistId, pending);
        vm.expectEmit(address(next));
        emit IArtistRegistry.ChangeCancelled(artistId, wallet, false);
        vm.prank(wallet);
        next.cancelChange(artistId);
        assertEq(uint8(next.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        assertEq(next.authorityOf(artistId), artist);

        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(_notInForce(first));
        first.executeChange(artistId);
        assertEq(first.authorityOf(artistId), artist);
        assertEq(next.payoutAddress(artistId), artist);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NoPendingChange.selector, artistId));
        next.executeChange(artistId);
    }

    /// @dev A pending replacement is copied and executed here by anyone once due, with the
    ///      reservation it carried; the new root is then mapped here.
    function test_Successor_APendingReplacementIsCopiedAndExecutedHere() public {
        _use(first);
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        uint48 due = first.pendingChange(artistId).executableAt;
        _force(next);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.ChangeNotDue.selector, artistId, due)
        );
        next.executeChange(artistId);
        assertEq(next.changeNonce(artistId), 0, "nothing was copied by the refused call");

        vm.warp(due);
        next.executeChange(artistId);
        assertEq(next.authorityOf(artistId), newRoot);
        assertEq(next.payoutAddress(artistId), newRoot);
        assertTrue(next.isWallet(artistId, newRoot));
        assertFalse(next.isWallet(artistId, artist));
        assertEq(first.authorityOf(artistId), artist, "the replaced module is not written");
        replaced.setMode(PredecessorMock.Mode.SILENT);
        assertEq(next.artistIdOf(newRoot), artistId);
        assertEq(next.artistIdOf(artist), artistId);
    }

    /// @dev The network withdraws, in this module, a replacement staged in the replaced one;
    ///      the account acts again at once.
    function test_Successor_APendingReplacementIsCopiedAndWithdrawnHere() public {
        _use(first);
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        assertFalse(next.isWallet(artistId, artist));
        _force(next);
        vm.prank(network);
        next.cancelReplacement(artistId);
        assertTrue(next.isWallet(artistId, artist));
        assertEq(uint8(next.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        assertEq(uint8(first.pendingChange(artistId).kind), uint8(ChangeKind.REPLACEMENT));
    }

    /// @dev A contest made in the replaced module is copied with the replacement. It is
    ///      resolved here only by an outcome recorded for this module after the copy: one
    ///      recorded before it is refused, whatever the replaced module had recorded.
    function test_Successor_AContestedReplacementNeedsAnOutcomeRecordedAfterTheCopy() public {
        _use(first);
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        vm.prank(artist);
        first.cancelChange(artistId);
        assertGt(first.pendingChange(artistId).contestedAt, 0);
        bytes32 early = keccak256("recorded before the copy");
        outcomes.setOutcome(address(next), artistId, early);
        vm.warp(block.timestamp + 14 days);

        _force(next);
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.OutcomePredatesContest.selector, artistId, early)
        );
        next.resolveContested(artistId, true, early);

        // Anyone's call copies the account; the contest stands.
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.ReplacementContested.selector, artistId)
        );
        next.executeChange(artistId);
        vm.prank(network);
        next.freeze(artistId);
        vm.prank(network);
        next.unfreeze(artistId);
        assertEq(next.pendingChange(artistId).priorOutcome, early);
        assertEq(
            next.pendingChange(artistId).contestedAt, first.pendingChange(artistId).contestedAt
        );
        assertFalse(next.isWallet(artistId, artist));

        bytes32 vote = keccak256("recorded after the copy");
        outcomes.setOutcome(address(next), artistId, vote);
        vm.prank(network);
        next.resolveContested(artistId, true, vote);
        assertEq(next.authorityOf(artistId), newRoot);
        assertTrue(next.isWallet(artistId, newRoot));
    }

    function test_Successor_ARefusedCallCopiesNothing() public {
        vm.prank(network);
        first.freeze(artistId);
        _force(next);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NoPendingChange.selector, artistId));
        next.executeChange(artistId);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NoPendingChange.selector, artistId));
        next.cancelChange(artistId);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.NotContested.selector, artistId));
        next.expireContest(artistId);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.NotAuthorized.selector, artistId, stranger)
        );
        next.revokeNonce(artistId);
        // Still read through: the freeze placed in the replaced module is served.
        assertFalse(next.isWallet(artistId, artist));
        assertEq(next.frozenUntil(artistId), first.frozenUntil(artistId));

        // An account nobody knows is not created by a change.
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, outsiderId));
        next.freeze(outsiderId);
        uint256 wide = uint256(1) << 160 | artistId;
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, wide));
        next.freeze(wide);
    }

    function test_Successor_AWalletRevokesItsNonceHere() public {
        _force(next);
        vm.expectEmit(address(next));
        emit IArtistRegistry.NonceRevoked(artistId, 0);
        vm.prank(wallet);
        next.revokeNonce(artistId);
        assertEq(next.changeNonce(artistId), 1);
        assertEq(next.authorityOf(artistId), artist);
    }

    // ------------------------------------------------------------------ a predecessor that fails

    /// @dev The replaced module stops answering (reverts, answers nothing, answers the wrong
    ///      size). The accounts it still holds have nobody acting and their payout held; they
    ///      cannot be copied or registered again; nothing is registered, because whether an
    ///      address is known cannot be told. An account recorded here is unaffected.
    function test_Successor_APredecessorThatStopsAnsweringStopsOnlyItsOwnAccounts() public {
        _force(next);
        vm.prank(packageRegistry);
        next.register(outsider, PROFILE, PROFILE_DOC);
        bytes32 digest = keccak256("message");
        bytes memory invalid =
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(replaced));
        bytes memory unknown =
            abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, artistId);

        for (uint8 m = 1; m <= uint8(PredecessorMock.Mode.OVERSIZED); ++m) {
            replaced.setMode(PredecessorMock.Mode(m));

            // Held by the replaced module: closed.
            assertFalse(next.isWallet(artistId, artist));
            assertFalse(next.isWallet(uint256(uint160(artist)), artist));
            assertEq(next.payoutAddress(artistId), address(0));
            vm.expectRevert(unknown);
            next.authorityOf(artistId);
            vm.expectRevert(unknown);
            next.activeAuthorityOf(artistId);
            vm.expectRevert(unknown);
            next.artist(artistId);
            vm.expectRevert(invalid);
            next.artistIdOf(artist);
            vm.expectRevert(invalid);
            next.reservedFor(artist);
            vm.expectRevert(invalid);
            next.frozenUntil(uint256(uint160(artist)));
            vm.expectRevert(invalid);
            next.pendingChange(artistId);
            vm.expectRevert(
                abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, artist)
            );
            next.requireSigned(artistId, digest, _proof(artistKey, digest));
            vm.prank(network);
            vm.expectRevert(unknown);
            next.freeze(artistId);
            vm.prank(packageRegistry);
            vm.expectRevert(invalid);
            next.register(artist, PROFILE, PROFILE_DOC);

            // An address nobody recorded here: not known to be free, so not its own account
            // and not registered.
            assertFalse(next.isWallet(uint256(uint160(stranger)), stranger));
            vm.prank(packageRegistry);
            vm.expectRevert(invalid);
            next.register(stranger, PROFILE, PROFILE_DOC);

            // Recorded here: unaffected.
            assertTrue(next.isWallet(outsiderId, outsider));
            assertEq(next.artistIdOf(outsider), outsiderId);
            assertEq(next.authorityOf(outsiderId), outsider);
            assertEq(next.activeAuthorityOf(outsiderId), outsider);
            assertEq(next.payoutAddress(outsiderId), outsider);
            assertEq(next.frozenUntil(outsiderId), 0);
            assertEq(next.requireSigned(outsiderId, digest, _proof(outsiderKey, digest)), outsider);
        }

        // Its freeze, and a change of its payout, need nothing from the replaced module.
        vm.startPrank(network);
        next.freeze(outsiderId);
        next.unfreeze(outsiderId);
        vm.stopPrank();
        _use(next);
        artistId = outsiderId;
        _stage(outsiderKey, ArtistIdentity(outsider, payout, PROFILE, PROFILE_DOC));
        vm.warp(block.timestamp + 2 days);
        next.executeChange(outsiderId);
        assertEq(next.payoutAddress(outsiderId), payout);
        // Naming a new root does: the address must be known to be free.
        bytes memory call = _replacementCall(_identity(newRoot, newRoot), newKey);
        vm.prank(network);
        (bool ok, bytes memory data) = address(next).call(call);
        assertFalse(ok);
        assertEq(data, invalid);
    }

    /// @dev A replaced module that names an address as a root of an account recorded here
    ///      gives that address nothing: it is only refused an account of its own.
    function test_Successor_AClaimByThePredecessorGivesNoPowerOverAnAccountRecordedHere() public {
        _force(next);
        vm.prank(packageRegistry);
        next.register(outsider, PROFILE, PROFILE_DOC);
        replaced.claim(stranger, outsiderId);
        assertEq(next.artistIdOf(stranger), outsiderId);
        assertFalse(next.isWallet(outsiderId, stranger));
        assertFalse(next.isWallet(uint256(uint160(stranger)), stranger));
        assertTrue(next.isWallet(uint256(uint160(stranger)), outsider), "the account it names");
        assertTrue(next.isWallet(outsiderId, outsider));
        vm.prank(packageRegistry);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, stranger));
        next.register(stranger, PROFILE, PROFILE_DOC);
        // A claimed ID nobody holds answers for nobody.
        replaced.claim(newRoot, type(uint256).max);
        assertFalse(next.isWallet(uint256(uint160(newRoot)), newRoot));
    }

    /// @dev What this module recorded comes before what the replaced module hands over: a
    ///      record naming, as an inherited account's root, the root of an account recorded
    ///      here does not move that address to the inherited account.
    function test_Successor_ACopyNeverRemapsAnAddressRecordedHere() public {
        _force(next);
        vm.prank(packageRegistry);
        next.register(outsider, PROFILE, PROFILE_DOC);
        replaced.setRecord(artistId, ArtistIdentity(outsider, payout, PROFILE, PROFILE_DOC));
        vm.prank(network);
        next.freeze(artistId);

        assertEq(next.authorityOf(artistId), outsider, "the record as handed over");
        assertEq(next.artistIdOf(outsider), outsiderId, "still names its own account");
        assertEq(next.artistIdOf(artist), artistId, "the ID's address names the account");
        assertGt(next.frozenUntil(artistId), block.timestamp);
        assertEq(next.frozenUntil(outsiderId), 0);
        assertEq(next.frozenUntil(uint256(uint160(outsider))), 0, "its own account, not frozen");
        assertTrue(next.isWallet(uint256(uint160(outsider)), outsider));
        assertEq(next.payoutAddress(outsiderId), outsider);
    }

    /// @dev A pending change handed over whose new root a change pending here reserves is
    ///      left behind: the account is copied without it, so a freeze is never held up. With
    ///      a free root the change is copied and reserves it.
    function test_Successor_ACopyLeavesBehindAChangeWhoseRootIsReservedHere() public {
        _force(next);
        vm.prank(packageRegistry);
        next.register(outsider, PROFILE, PROFILE_DOC);
        uint256 inherited = artistId;
        artistId = outsiderId;
        _stageReplacement(_identity(newRoot, newRoot), newKey);
        artistId = inherited;
        assertEq(next.reservedFor(newRoot), outsiderId);

        PendingChange memory p;
        p.kind = ChangeKind.REPLACEMENT;
        p.executableAt = uint48(block.timestamp + 14 days);
        p.next = ArtistIdentity(newRoot, newRoot, PROFILE, PROFILE_DOC);
        p.evidenceHash = EVIDENCE;
        replaced.setPending(inherited, p);
        uint256 snapshot = vm.snapshotState();
        vm.prank(network);
        next.freeze(inherited);
        assertGt(next.frozenUntil(inherited), block.timestamp, "the freeze was placed");
        assertEq(next.reservedFor(newRoot), outsiderId, "the reservation made here stands");
        assertEq(uint8(next.pendingChange(inherited).kind), uint8(ChangeKind.NONE));
        vm.prank(network);
        next.unfreeze(inherited);
        assertTrue(next.isWallet(inherited, artist), "no replacement is pending here");
        vm.revertToState(snapshot);

        p.next.root = wallet2;
        replaced.setPending(inherited, p);
        vm.prank(network);
        next.freeze(inherited);
        assertEq(next.reservedFor(wallet2), inherited);
        assertEq(next.reservedFor(newRoot), outsiderId);
        assertEq(uint8(next.pendingChange(inherited).kind), uint8(ChangeKind.REPLACEMENT));
        // A change that keeps the root reserves nothing.
        assertEq(next.reservedFor(artist), 0);
    }

    /// @dev A payout address the replaced module holds and this module refuses by address is
    ///      not paid: read through, the payout is none; copied, the account has none until it
    ///      names another.
    function test_Successor_APayoutThisModuleRefusesIsNotCarried() public {
        address refused = address(directory);
        assertFalse(next.isPayoutAllowed(refused));
        replaced.setRecord(artistId, ArtistIdentity(artist, refused, PROFILE, PROFILE_DOC));
        assertEq(next.payoutAddress(artistId), address(0), "held, not paid to a refused address");
        (ArtistIdentity memory seen,) = next.artist(artistId);
        assertEq(seen.payout, refused, "the replaced module's record as it is");

        _force(next);
        vm.expectEmit(address(next));
        emit Accounts.AccountInherited(
            artistId, address(replaced), ArtistIdentity(artist, address(0), PROFILE, PROFILE_DOC), 0
        );
        vm.prank(wallet);
        next.revokeNonce(artistId);
        (seen,) = next.artist(artistId);
        assertEq(seen.payout, address(0));
        assertEq(next.payoutAddress(artistId), address(0));
        assertTrue(next.isWallet(artistId, artist), "the account acts");

        _stage(walletKey, ArtistIdentity(artist, payout, PROFILE, PROFILE_DOC));
        vm.warp(block.timestamp + 2 days);
        next.executeChange(artistId);
        assertEq(next.payoutAddress(artistId), payout);
    }

    /// @dev An allowed payout address is carried as it is, read through and copied.
    function test_Successor_AnAllowedPayoutIsCarried() public {
        replaced.setRecord(artistId, ArtistIdentity(artist, payout, PROFILE, PROFILE_DOC));
        assertEq(next.payoutAddress(artistId), payout);
        _force(next);
        vm.prank(wallet);
        next.revokeNonce(artistId);
        assertEq(next.payoutAddress(artistId), payout);
        (ArtistIdentity memory seen,) = next.artist(artistId);
        assertEq(seen.payout, payout);
    }

    /// @dev A copy takes the whole identity, profile included, and maps both the root and the
    ///      address the ID is made from, so neither is looked up in the replaced module again.
    function test_Successor_ACopyTakesTheWholeIdentityAndMapsRootAndIdAddress() public {
        _moveInFirst();
        (ArtistIdentity memory before,) = first.artist(artistId);
        assertEq(before.root, newRoot);
        assertEq(before.profileDocHash, keccak256("profile document v2"));
        _force(next);
        uint256[] memory ids = new uint256[](1);
        ids[0] = artistId;
        next.copyAccounts(ids);

        replaced.setMode(PredecessorMock.Mode.SILENT);
        (ArtistIdentity memory copied, uint48 frozen) = next.artist(artistId);
        assertEq(keccak256(abi.encode(copied)), keccak256(abi.encode(before)));
        assertEq(copied.profileId, PROFILE);
        assertEq(frozen, 0);
        assertEq(next.artistIdOf(newRoot), artistId, "the root is mapped here");
        assertEq(next.artistIdOf(artist), artistId, "and the address the ID is made from");
        assertTrue(next.isWallet(uint256(uint160(newRoot)), newRoot));
        assertFalse(next.isWallet(uint256(uint160(artist)), artist));
    }

    /// @dev Each inherited account is copied on its own: copying one with nothing pending
    ///      leaves no pending change and no reservation behind, so the next copies too.
    function test_Successor_CopiesEachAccountOnItsOwn() public {
        uint256 second = _register(outsider);
        _force(next);
        vm.recordLogs();
        vm.startPrank(network);
        next.freeze(artistId);
        next.freeze(second);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 inherited;
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IArtistRegistry.ChangeStaged.selector, "nothing was pending"
            );
            if (logs[i].topics[0] == Accounts.AccountInherited.selector) ++inherited;
        }
        assertEq(inherited, 2);
        assertEq(next.authorityOf(artistId), artist);
        assertEq(next.authorityOf(second), outsider);
        assertEq(uint8(next.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        assertEq(next.reservedFor(address(0)), 0);
        vm.prank(network);
        next.unfreeze(second);
        assertTrue(next.isWallet(second, outsider));
    }

    /// @dev An own change pending in the replaced module is copied as an own change: the
    ///      account still acts while it waits, and a change that keeps the root reserves
    ///      nothing.
    function test_Successor_ACopiedOwnChangeLeavesTheAccountActing() public {
        _use(first);
        _stage(artistKey, _identity(artist, payout));
        // An outcome already recorded for this module is no part of a change nobody contested.
        outcomes.setOutcome(address(next), artistId, keccak256("an earlier outcome"));
        _force(next);
        vm.prank(wallet);
        next.revokeNonce(artistId);
        assertEq(uint8(next.pendingChange(artistId).kind), uint8(ChangeKind.OWN));
        assertEq(next.pendingChange(artistId).priorOutcome, bytes32(0), "copied as it was");
        assertTrue(next.isWallet(artistId, artist), "an own change does not stop the account");
        assertTrue(next.isWallet(artistId, wallet));
        assertEq(next.activeAuthorityOf(artistId), artist);
        assertEq(next.reservedFor(artist), 0, "the root is kept: nothing is reserved");
        assertEq(next.payoutAddress(artistId), address(0), "held while the payout would move");
        vm.warp(block.timestamp + 2 days);
        next.executeChange(artistId);
        assertEq(next.payoutAddress(artistId), payout);
    }

    /// @dev An ID wider than an address names no account and is never copied, whatever the
    ///      replaced module answers for it.
    function test_Successor_AnIdWiderThanAnAddressIsNeverCopied() public {
        uint256 wide = uint256(1) << 160 | artistId;
        replaced.setRecord(wide, ArtistIdentity(artist, payout, PROFILE, PROFILE_DOC));
        assertEq(next.authorityOf(wide), artist, "read through as the replaced module answers");
        assertFalse(next.isWallet(wide, artist), "but nobody acts for it");
        _force(next);
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, wide));
        next.freeze(wide);
        // The account the low bits name is untouched and still read through.
        assertEq(next.changeNonce(artistId), 0);
        assertTrue(next.isWallet(artistId, artist));
    }

    // ------------------------------------------------------------------ one module writes

    /// @dev A module announced and not yet in force changes nothing: every function that
    ///      creates or changes an account is refused, by a wallet of the account, by the
    ///      network and by anyone, so no record is copied before activation.
    function test_Successor_WritesNothingBeforeItIsInForce() public {
        bytes memory refused = _notInForce(next);
        vm.prank(wallet);
        vm.expectRevert(refused);
        next.revokeNonce(artistId);
        vm.startPrank(network);
        vm.expectRevert(refused);
        next.freeze(artistId);
        vm.expectRevert(refused);
        next.unfreeze(artistId);
        vm.expectRevert(refused);
        next.cancelReplacement(artistId);
        vm.expectRevert(refused);
        next.cancelOwnChange(artistId);
        vm.expectRevert(refused);
        next.resolveContested(artistId, true, keccak256("vote"));
        vm.stopPrank();
        vm.expectRevert(refused);
        next.executeChange(artistId);
        vm.expectRevert(refused);
        next.expireContest(artistId);
        vm.prank(artist);
        vm.expectRevert(refused);
        next.cancelChange(artistId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = artistId;
        vm.expectRevert(refused);
        next.copyAccounts(ids);
        vm.prank(packageRegistry);
        vm.expectRevert(refused);
        next.register(outsider, PROFILE, PROFILE_DOC);

        bytes memory change = _changeCallFor(next, stranger, walletKey, _identity(artist, payout));
        (bool ok, bytes memory data) = address(next).call(change);
        assertFalse(ok);
        assertEq(data, refused);
        _use(next);
        bytes memory replacement = _replacementCall(_identity(newRoot, newRoot), newKey);
        vm.prank(network);
        (ok, data) = address(next).call(replacement);
        assertFalse(ok);
        assertEq(data, refused);
        assertEq(next.changeNonce(artistId), 0);
    }

    /// @dev What happens in the module in force while its successor waits reaches the
    ///      successor, whatever a wallet of the account tried there first: the account is
    ///      frozen and its root replaced in the module in force, and the successor, once in
    ///      force, answers with the new root and the freeze.
    function test_Successor_AFreezeAndAReplacementDuringTheWaitReachIt() public {
        vm.prank(wallet);
        vm.expectRevert(_notInForce(next));
        next.revokeNonce(artistId);

        vm.prank(network);
        first.freeze(artistId);
        assertFalse(next.isWallet(artistId, artist), "the successor sees the freeze");
        assertFalse(next.isWallet(artistId, wallet));
        _moveInFirst();
        assertEq(first.authorityOf(artistId), newRoot);

        _force(next);
        assertEq(next.authorityOf(artistId), newRoot);
        assertEq(next.activeAuthorityOf(artistId), newRoot);
        assertTrue(next.isWallet(artistId, newRoot));
        assertFalse(next.isWallet(artistId, artist), "the old root lost the account");
        assertFalse(next.isWallet(artistId, wallet));
        assertEq(next.payoutAddress(artistId), newRoot);
        vm.prank(newRoot);
        next.revokeNonce(artistId);
        assertEq(next.authorityOf(artistId), newRoot, "copied as it stood at activation");
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.NotAuthorized.selector, artistId, artist)
        );
        next.revokeNonce(artistId);
    }

    /// @dev A module that has been replaced changes no more, so the record its successor
    ///      reads stands still: nothing staged, executed, frozen or registered there after
    ///      the replacement, by the network or by a wallet. Its reads still answer.
    function test_Successor_AReplacedModuleWritesNothing() public {
        _use(first);
        _stage(artistKey, _identity(wallet, payout));
        _force(next);
        bytes memory refused = _notInForce(first);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(refused);
        first.executeChange(artistId);
        vm.prank(wallet);
        vm.expectRevert(refused);
        first.cancelChange(artistId);
        vm.startPrank(network);
        vm.expectRevert(refused);
        first.freeze(artistId);
        vm.expectRevert(refused);
        first.cancelOwnChange(artistId);
        vm.stopPrank();
        vm.prank(packageRegistry);
        vm.expectRevert(refused);
        first.register(outsider, PROFILE, PROFILE_DOC);
        assertEq(first.authorityOf(artistId), artist);
        assertEq(uint8(first.pendingChange(artistId).kind), uint8(ChangeKind.OWN));

        // The change it left pending runs in the module in force.
        next.executeChange(artistId);
        assertEq(next.authorityOf(artistId), wallet);
        assertEq(next.payoutAddress(artistId), payout);
    }

    /// @dev The step the checklist forbids (LIM-ID-28), shown so its effect is on record: the
    ///      slot must only move forward. Going back to a replaced module drops what its
    ///      successor recorded, and the replaced module, named again, writes again, so a
    ///      successor activated once more answers a copied account from its earlier copy.
    function test_Successor_Hazard_AReplacedModuleNamedAgainAndItsSuccessorDisagree() public {
        _force(next);
        vm.prank(network);
        next.freeze(artistId);
        assertGt(next.frozenUntil(artistId), block.timestamp);

        // Back to the replaced module: the freeze its successor placed is unknown there.
        _force(first);
        assertEq(first.frozenUntil(artistId), 0, "what the successor recorded is dropped");
        assertTrue(first.isWallet(artistId, artist), "the frozen account acts again");

        // The successor lifts its freeze; the replaced module, named again, places one.
        _force(next);
        vm.prank(network);
        next.unfreeze(artistId);
        _force(first);
        vm.prank(network);
        first.freeze(artistId);
        assertGt(first.frozenUntil(artistId), block.timestamp);

        // The successor, activated again, answers from its own earlier copy.
        _force(next);
        assertEq(next.frozenUntil(artistId), 0, "the later freeze is not in the copy");
        assertTrue(next.isWallet(artistId, artist));
    }

    /// @dev Anyone copies a list of accounts into the module in force. The answers do not
    ///      change, an account already recorded or unknown is skipped, and a copied account
    ///      no longer reads the replaced module.
    function test_Successor_CopyAccountsCopiesAListForAnyone() public {
        uint256 second = _register(outsider);
        _force(next);
        uint256[] memory ids = new uint256[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (artistId, second, uint256(uint160(stranger)), artistId);
        vm.recordLogs();
        vm.prank(stranger);
        next.copyAccounts(ids);
        uint256 inherited;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == Accounts.AccountInherited.selector) ++inherited;
        }
        assertEq(inherited, 2, "each known account once");
        assertEq(next.authorityOf(artistId), artist);
        assertEq(next.authorityOf(second), outsider);
        assertTrue(next.isWallet(artistId, wallet));
        assertEq(next.payoutAddress(second), outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.UnknownArtist.selector, uint256(uint160(stranger))
            )
        );
        next.authorityOf(uint256(uint160(stranger)));

        replaced.setMode(PredecessorMock.Mode.SILENT);
        assertTrue(next.isWallet(artistId, artist));
        assertEq(next.payoutAddress(artistId), artist);
        assertEq(next.activeAuthorityOf(second), outsider);
    }

    /// @dev A payout contract the account chose is never called by a copy or by the read of
    ///      an inherited payout address, so it cannot stop either, whatever gas it burns: the
    ///      network freezes, lifts and replaces in the module in force, at an ordinary gas
    ///      limit.
    function test_Successor_APayoutContractCannotStopACopyOrAFreeze() public {
        GasBurningPayout burning = new GasBurningPayout();
        _use(first);
        _stage(artistKey, ArtistIdentity(artist, address(burning), PROFILE, PROFILE_DOC));
        vm.warp(block.timestamp + 2 days);
        first.executeChange(artistId);
        assertEq(first.payoutAddress(artistId), address(burning));
        burning.flip();

        _force(next);
        assertEq(next.payoutAddress{ gas: 200_000 }(artistId), address(burning));
        bytes memory replacement = _replacementCall(_identity(newRoot, newRoot), newKey);
        uint256 snapshot = vm.snapshotState();
        vm.prank(network);
        next.freeze{ gas: 500_000 }(artistId);
        assertFalse(next.isWallet(artistId, artist));
        vm.prank(network);
        next.unfreeze{ gas: 200_000 }(artistId);
        assertEq(next.payoutAddress{ gas: 200_000 }(artistId), address(burning));
        vm.revertToState(snapshot);

        vm.prank(network);
        (bool ok,) = address(next).call{ gas: 1_000_000 }(replacement);
        assertTrue(ok, "the replacement is staged");
        vm.warp(block.timestamp + 14 days);
        next.executeChange{ gas: 1_000_000 }(artistId);
        assertEq(next.authorityOf(artistId), newRoot);
        assertEq(next.payoutAddress(artistId), newRoot);
    }

    // ------------------------------------------------------------------ the gas rule

    /// @dev A read of the replaced module that runs short of gas reverts with
    ///      `BoundedCallShortfall`; it never reads as "nobody acts", "no payout" or "free".
    function test_GasRule_AReadOfThePredecessorNeverAnswersForGas() public {
        Burner slow = new Burner(address(first), 20_000);
        Accounts module = _successor(address(slow));
        // The root, so the only read is of the replaced module (no consolidation source).
        bytes memory data = abi.encodeCall(IAccounts.isWallet, (artistId, artist));
        Outcome memory o = _assertSameAtEveryMultiple(slow, stranger, address(module), data);
        assertTrue(abi.decode(o.data, (bool)));
        slow.burnerSetMultiple(4);
        _assertShortfallNeverAnswers(slow, stranger, address(module), data);

        data = abi.encodeCall(IAccounts.payoutAddress, (artistId));
        (o,) = _assertShortfallNeverAnswers(slow, stranger, address(module), data);
        assertEq(abi.decode(o.data, (address)), artist);

        directory.setModule(Slots.ACCOUNTS, address(module));
        data = abi.encodeCall(Accounts.register, (outsider, PROFILE, PROFILE_DOC));
        (o,) = _assertShortfallNeverAnswers(slow, packageRegistry, address(module), data);
        assertTrue(o.ok, "registered with ample gas");

        slow.burnerSetBase(30_000_000);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, address(slow))
        );
        module.isWallet{ gas: 2_000_000 }(artistId, artist);
    }

    /// @dev An account recorded here never reads the replaced module, whatever it costs.
    function test_GasRule_AnAccountRecordedHereNeverReadsThePredecessor() public {
        Burner slow = new Burner(address(first), 20_000);
        Accounts module = _successor(address(slow));
        directory.setModule(Slots.ACCOUNTS, address(module));
        vm.prank(packageRegistry);
        module.register(outsider, PROFILE, PROFILE_DOC);
        slow.burnerSetBase(30_000_000);
        bytes32 digest = keccak256("message");
        assertTrue(module.isWallet{ gas: 200_000 }(outsiderId, outsider));
        assertEq(module.payoutAddress{ gas: 200_000 }(outsiderId), outsider);
        assertEq(
            module.requireSigned{ gas: 200_000 }(outsiderId, digest, _proof(outsiderKey, digest)),
            outsider
        );
    }
}
