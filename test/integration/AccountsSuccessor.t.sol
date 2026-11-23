// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IAccounts } from "src/interfaces/core/IAccounts.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IWorkRules } from "src/interfaces/core/IWorkRules.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { ReadThroughAccounts } from "test/mocks/identity/ReadThroughAccounts.sol";
import { RecordFlowsBase } from "./RecordFlowsBase.sol";

/// @notice Replacing the accounts module without losing an account, on the real deployed stack.
///         An artist registers and sells a work, the artist's account is moved to another
///         address by a network replacement (so its payout address is no longer the address its
///         ID was made from), and the network installs a successor accounts module through the
///         directory (announced, waited out, activated). The successor
///         ([`ReadThroughAccounts`](../mocks/identity/ReadThroughAccounts.sol), a test double)
///         reads through the genesis `Accounts` for every account it has not changed itself.
///         After the replacement the moved account is served under its old ID: payout address,
///         wallet check and freeze; money owed before and after the replacement is released to
///         the moved payout address; moves, consents and record edits signed by the moved root
///         verify. A change made in the old module during the wait is carried; an account the
///         successor changes is answered by the successor alone; a new artist registers in it.
/// @dev This is the test `docs/operations/replacing-modules.md` asks for before a successor
///      accounts module is announced; a real successor needs its own version of it.
contract AccountsSuccessorTest is RecordFlowsBase {
    address internal lead;
    address internal newRoot;
    address internal collector = makeAddr("successorCollector");
    uint256 internal artistId;
    bytes32 internal root;
    ISplitWallet.Payee[] internal payees;

    function setUp() public override {
        super.setUp();
        lead = _actor("successorLead");
        newRoot = _actor("successorNewRoot");
        Work[] memory works = new Work[](3);
        for (uint256 i; i < 3; ++i) {
            works[i] = _work(lead, collectionId);
        }
        works[1].item.license =
            License("CC-BY-4.0", _storeText(bytes("CC BY 4.0 (successor fixture)"), "text/plain"));
        root = _publish(works);
        _keep(root, works);
        artistId = accounts.artistIdOf(lead);
        assertEq(artistId, uint256(uint160(lead)));
        payees.push(works[0].item.payees[0]);
    }

    // ------------------------------------------------------------------ the moved account

    function test_AccountsSuccessor_AMovedAccountIsServedUnderItsOldId() public {
        // Money owed before the replacement, then the account moves in the genesis module.
        (, address vault) = _sold(root, 0, lead, 0);
        uint256 owedBefore = vault.balance;
        assertGt(owedBefore, 0);
        _moveAccount();
        assertEq(accounts.payoutAddress(artistId), newRoot);
        assertTrue(newRoot != address(uint160(artistId)), "the payout is not the ID's address");

        ReadThroughAccounts next = _installSuccessor();
        assertFalse(next.answersItself(artistId), "read through, not copied");

        // The same ID: payout address, wallets and freeze state.
        assertEq(directory.payoutAddress(artistId), newRoot);
        assertEq(next.artistIdOf(newRoot), artistId);
        assertEq(next.artistIdOf(lead), artistId, "the first address still names the account");
        assertEq(next.authorityOf(artistId), newRoot);
        assertEq(next.activeAuthorityOf(artistId), newRoot);
        assertTrue(next.isWallet(artistId, newRoot));
        assertFalse(next.isWallet(artistId, lead));
        assertEq(next.frozenUntil(artistId), 0);

        // Money owed before the replacement reaches the moved payout address; the ledger asks
        // the successor.
        vm.prank(lead);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, lead, newRoot)
        );
        ledger.release(payees, bytes32(0), address(0), 0);
        vm.expectCall(address(next), abi.encodeCall(IAccounts.payoutAddress, (artistId)));
        vm.prank(newRoot);
        assertEq(ledger.release(payees, bytes32(0), address(0), 0), owedBefore);
        assertEq(newRoot.balance, owedBefore);
        assertEq(vault.balance, 0);

        // A move signed by the moved root verifies: a work is minted and sold after the
        // replacement, for the same account, and its money reaches the same address.
        (uint256 tokenId, address vaultAfter) = _sold(root, 1, newRoot, 1);
        assertEq(stream.workOf(tokenId).artistId, artistId);
        uint256 owedAfter = vaultAfter.balance;
        assertGt(owedAfter, 0);
        vm.prank(newRoot);
        assertEq(ledger.release(payees, bytes32(0), address(0), 0), owedAfter);
        assertEq(newRoot.balance, owedBefore + owedAfter);

        // The moved root edits the record and consents to a relicense; the first address
        // cannot.
        _setRecordAs(newRoot, tokenId, _record("By the moved root, after the replacement"));
        _expectNotArtist(lead, tokenId);
        Work memory w = _package(root)[1];
        License memory mit = License("MIT", _storeText(bytes("MIT (successor)"), "text/plain"));
        _govern(network, address(rules), _relicenseCall(tokenId, w, mit, _list(newRoot)));
        assertEq(facts.factsOf(address(stream), tokenId).licenseId, "MIT");
    }

    function test_AccountsSuccessor_AFreezeInTheOldModuleIsServedAndLifted() public {
        (uint256 tokenId, address vault) = _sold(root, 0, lead, 0);
        uint256 owed = vault.balance;
        _moveAccount();
        ReadThroughAccounts next = _installSuccessor();

        // The network freezes the account where it is recorded; the stack sees it at once.
        _asNetwork(address(accounts), abi.encodeCall(accounts.freeze, (artistId)));
        uint48 until = accounts.frozenUntil(artistId);
        assertGt(until, block.timestamp);
        assertEq(next.frozenUntil(artistId), until);
        assertFalse(next.isWallet(artistId, newRoot));
        assertEq(next.activeAuthorityOf(artistId), address(0));
        assertEq(directory.payoutAddress(artistId), address(0), "held while frozen");
        vm.prank(newRoot);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayoutUnresolved.selector, artistId));
        ledger.release(payees, bytes32(0), address(0), 0);
        _expectNotArtist(newRoot, tokenId);
        assertEq(vault.balance, owed, "held, not lost");

        _asNetwork(address(accounts), abi.encodeCall(accounts.unfreeze, (artistId)));
        assertEq(next.frozenUntil(artistId), 0);
        _setRecordAs(newRoot, tokenId, _record("After the freeze"));
        vm.prank(newRoot);
        assertEq(ledger.release(payees, bytes32(0), address(0), 0), owed);
        assertEq(newRoot.balance, owed);
    }

    // ------------------------------------------------------------------ during the wait

    /// @dev The old module keeps changing while the successor waits: a replacement staged after
    ///      the announcement is pending at activation (nobody acts, the payout is held) and,
    ///      once executed in the old module, is what the stack serves. A copy taken at the
    ///      announcement would have missed it.
    function test_AccountsSuccessor_AChangeInTheOldModuleDuringTheWaitIsCarried() public {
        (uint256 tokenId, address vault) = _sold(root, 0, lead, 0);
        uint256 owed = vault.balance;
        ReadThroughAccounts next = _newSuccessor();
        _asNetwork(
            address(directory),
            abi.encodeCall(IModuleSlots.proposeModule, (Slots.ACCOUNTS, address(next)))
        );
        uint256 announced = block.timestamp;
        _wait(1 days);
        _govern(network, address(accounts), _replacement());
        uint48 due = accounts.pendingChange(artistId).executableAt;
        vm.warp(announced + directory.moduleDelay());
        assertLt(block.timestamp, due, "the replacement is still pending");
        directory.activateModule(Slots.ACCOUNTS);
        assertEq(directory.moduleOf(Slots.ACCOUNTS), address(next));

        assertFalse(next.isWallet(artistId, lead), "blocked during the notice");
        assertEq(directory.payoutAddress(artistId), address(0));
        vm.prank(lead);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayoutUnresolved.selector, artistId));
        ledger.release(payees, bytes32(0), address(0), 0);
        _expectNotArtist(lead, tokenId);

        vm.warp(due);
        accounts.executeChange(artistId);
        assertEq(directory.payoutAddress(artistId), newRoot);
        assertTrue(next.isWallet(artistId, newRoot));
        vm.prank(newRoot);
        assertEq(ledger.release(payees, bytes32(0), address(0), 0), owed);
        assertEq(newRoot.balance, owed);
        _setRecordAs(newRoot, tokenId, _record("By the root named during the wait"));
    }

    // ------------------------------------------------------------------ the successor's own records

    /// @dev Once the successor changes an account, the old module is not what the permanent
    ///      contracts ask: it still names the moved root, and the stack follows the successor.
    function test_AccountsSuccessor_AnAccountChangedInTheSuccessorIsAnsweredThere() public {
        (uint256 tokenId, address vault) = _sold(root, 0, lead, 0);
        uint256 owed = vault.balance;
        _moveAccount();
        ReadThroughAccounts next = _installSuccessor();
        address third = _actor("successorThirdRoot");
        address thirdPayout = makeAddr("successorThirdPayout");
        vm.prank(network);
        next.setAccount(artistId, third, thirdPayout, 0);
        assertTrue(next.answersItself(artistId));
        assertEq(accounts.payoutAddress(artistId), newRoot, "the old module is unchanged");
        assertTrue(accounts.isWallet(artistId, newRoot));

        assertEq(directory.payoutAddress(artistId), thirdPayout);
        vm.prank(newRoot);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, newRoot, thirdPayout)
        );
        ledger.release(payees, bytes32(0), address(0), 0);
        vm.prank(thirdPayout);
        assertEq(ledger.release(payees, bytes32(0), address(0), 0), owed);
        assertEq(thirdPayout.balance, owed);
        _expectNotArtist(newRoot, tokenId);
        _setRecordAs(third, tokenId, _record("By the root the successor names"));

        // The root the successor names signs the next move, for the same account.
        (uint256 next1, address vault1) = _sold(root, 2, third, 2);
        assertEq(stream.workOf(next1).artistId, artistId);
        uint256 owed1 = vault1.balance;
        vm.prank(thirdPayout);
        assertEq(ledger.release(payees, bytes32(0), address(0), 0), owed1);
        assertEq(thirdPayout.balance, owed + owed1);

        // A freeze the successor records holds the payout, whatever the old module says.
        vm.prank(network);
        next.setAccount(artistId, third, thirdPayout, uint48(block.timestamp + 1 days));
        assertEq(directory.payoutAddress(artistId), address(0));
        assertEq(accounts.frozenUntil(artistId), 0);
        _expectNotArtist(third, tokenId);
    }

    /// @dev An artist who registers after the replacement is recorded by the successor (the
    ///      package registry is its `register` caller), with the ID the genesis rule gives, and
    ///      is paid.
    function test_AccountsSuccessor_ANewArtistRegistersInTheSuccessor() public {
        _moveAccount();
        ReadThroughAccounts next = _installSuccessor();
        address newcomer = _actor("successorNewcomer");
        Work[] memory works = new Work[](1);
        works[0] = _work(newcomer, collectionId);
        bytes32 newRootHash = _publish(works);
        _keep(newRootHash, works);
        uint256 id = uint256(uint160(newcomer));
        assertEq(next.artistIdOf(newcomer), id);
        assertTrue(next.answersItself(id));
        assertEq(accounts.artistIdOf(newcomer), 0, "the old module was not written");

        (uint256 tokenId, address vault) = _sold(newRootHash, 0, newcomer, 0);
        assertEq(stream.workOf(tokenId).artistId, id);
        uint256 owed = vault.balance;
        assertGt(owed, 0);
        vm.prank(newcomer);
        assertEq(ledger.release(works[0].item.payees, bytes32(0), address(0), 0), owed);
        assertEq(newcomer.balance, owed);
        // The moved account is still served beside it.
        assertEq(directory.payoutAddress(artistId), newRoot);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Item `index` of `packageRoot` started through `SaleStarter` with a move signed by
    ///      `signer`, sold to the collector for 1 ETH; returns the token and its seller vault.
    function _sold(bytes32 packageRoot, uint256 index, address signer, uint256 nonce)
        internal
        returns (uint256 tokenId, address vault)
    {
        Work[] memory works = _package(packageRoot);
        uint256 saleId = starter.start(
            auction,
            address(stream),
            _mintDataSignedBy(packageRoot, works, index, signer, nonce),
            works[index].media
        );
        tokenId = auction.auction(saleId).tokenId;
        vault = auction.auction(saleId).seller;
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
    }

    /// @dev The network's replacement of the account's root and payout by `newRoot`, accepted
    ///      by `newRoot`.
    function _replacement() internal view returns (bytes memory call) {
        ArtistIdentity memory next = _identity(artistId, newRoot, newRoot);
        bytes32 evidence = keccak256(abi.encode("replacement evidence", newRoot));
        uint64 deadline = uint64(block.timestamp + 60 days);
        bytes memory acceptance =
            _sign(newRoot, accounts.replacementDigest(artistId, next, evidence, deadline));
        call = abi.encodeCall(
            accounts.stageReplacement, (artistId, next, evidence, deadline, acceptance)
        );
    }

    /// @dev Moves the account to `newRoot` in the genesis module: staged, waited out, executed.
    function _moveAccount() internal {
        _govern(network, address(accounts), _replacement());
        vm.warp(accounts.pendingChange(artistId).executableAt);
        accounts.executeChange(artistId);
        assertEq(accounts.authorityOf(artistId), newRoot);
    }

    function _newSuccessor() internal returns (ReadThroughAccounts) {
        return
            new ReadThroughAccounts(IArtistRegistry(address(accounts)), network, address(registry));
    }

    /// @dev The successor installed as the directory requires: announced by the network, waited
    ///      out, activated by anyone.
    function _installSuccessor() internal returns (ReadThroughAccounts next) {
        next = _newSuccessor();
        _asNetwork(
            address(directory),
            abi.encodeCall(IModuleSlots.proposeModule, (Slots.ACCOUNTS, address(next)))
        );
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.ACCOUNTS)
        );
        directory.activateModule(Slots.ACCOUNTS);
        assertEq(directory.moduleOf(Slots.ACCOUNTS), address(accounts), "not before the wait");
        _wait(directory.moduleDelay());
        vm.prank(collector);
        directory.activateModule(Slots.ACCOUNTS);
        assertEq(directory.moduleOf(Slots.ACCOUNTS), address(next));
    }

    function _setRecordAs(address who, uint256 tokenId, bytes32 recordFileId) internal {
        bytes32 state = _state(tokenId);
        vm.prank(who);
        rules.setRecord(address(stream), tokenId, recordFileId, state);
    }

    /// @dev `who` is refused as the work's artist.
    function _expectNotArtist(address who, uint256 tokenId) internal {
        bytes32 recordFileId = _record("Refused");
        bytes32 state = _state(tokenId);
        vm.prank(who);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRules.NotWorkArtist.selector, address(stream), tokenId, who)
        );
        rules.setRecord(address(stream), tokenId, recordFileId, state);
    }
}
