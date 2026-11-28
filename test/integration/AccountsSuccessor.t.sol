// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DeployCore } from "script/DeployCore.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { IArtistRegistry, IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IAccounts } from "src/interfaces/core/IAccounts.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IWorkRules } from "src/interfaces/core/IWorkRules.sol";
import { ArtistIdentity, ChangeKind } from "src/interfaces/types/IdentityTypes.sol";
import { License, PartyAcceptance } from "src/interfaces/types/PackageTypes.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { RecordFlowsBase } from "./RecordFlowsBase.sol";

/// @notice The fixture of the accounts-replacement tests: an artist with three approved works,
///         the address its account is moved to, and the helpers that sell a work, move the
///         account, deploy a second `Accounts` naming the module it replaces and install it.
abstract contract AccountsSuccessorBase is RecordFlowsBase {
    address internal lead;
    address internal newRoot;
    address internal collector = makeAddr("successorCollector");
    uint256 internal artistId;
    bytes32 internal root;
    ISplitWallet.Payee[] internal payees;

    function setUp() public virtual override {
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

    /// @dev The network replaces the account's root by `nextRoot` (payout `nextPayout`) in
    ///      `module`, accepted by `nextRoot` in that module's domain; waited out and executed.
    function _replaceIn(Accounts module, address nextRoot, address nextPayout) internal {
        (ArtistIdentity memory next,) = module.artist(artistId);
        (next.root, next.payout) = (nextRoot, nextPayout);
        bytes32 evidence = keccak256(abi.encode("replacement evidence", nextRoot));
        uint64 deadline = uint64(block.timestamp + 60 days);
        bytes memory acceptance =
            _sign(nextRoot, module.replacementDigest(artistId, next, evidence, deadline));
        _govern(
            network,
            address(module),
            abi.encodeCall(
                module.stageReplacement, (artistId, next, evidence, deadline, acceptance)
            )
        );
        vm.warp(module.pendingChange(artistId).executableAt);
        module.executeChange(artistId);
        assertEq(module.authorityOf(artistId), nextRoot);
    }

    /// @dev A second `Accounts` with the genesis constructor arguments, naming `replaced` as
    ///      the module it replaces, its restricted functions mapped to the roles the role map
    ///      gives the replaced instance (the checklist's step 2).
    function _newSuccessor(Accounts replaced) internal returns (Accounts next) {
        next = new Accounts(
            address(manager),
            IConsolidationSource(address(consolidation)),
            address(consolidation).codehash,
            Accounts.Wiring(
                address(directory),
                address(stream),
                address(editions),
                address(ledger),
                address(statements),
                address(registry),
                address(replaced)
            ),
            DeployCore.notPayouts(deployment)
        );
        bytes4[8] memory selectors = [
            Accounts.freeze.selector,
            Accounts.unfreeze.selector,
            Accounts.cancelReplacement.selector,
            Accounts.cancelOwnChange.selector,
            Accounts.stageReplacement.selector,
            Accounts.resolveContested.selector,
            Accounts.setConsolidationSource.selector,
            Accounts.setPackageRegistry.selector
        ];
        // One call per role, as the network would batch them.
        for (uint256 i; i < selectors.length; ++i) {
            uint64 role = manager.getTargetFunctionRole(address(replaced), selectors[i]);
            if (manager.getTargetFunctionRole(address(next), selectors[i]) == role) continue;
            uint256 count;
            for (uint256 j = i; j < selectors.length; ++j) {
                if (manager.getTargetFunctionRole(address(replaced), selectors[j]) == role) {
                    ++count;
                }
            }
            bytes4[] memory group = new bytes4[](count);
            for (uint256 j = selectors.length; j > i; --j) {
                if (manager.getTargetFunctionRole(address(replaced), selectors[j - 1]) == role) {
                    group[--count] = selectors[j - 1];
                }
            }
            _asNetwork(
                address(manager),
                abi.encodeCall(manager.setTargetFunctionRole, (address(next), group, role))
            );
        }
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(
                manager.getTargetFunctionRole(address(next), selectors[i]),
                manager.getTargetFunctionRole(address(replaced), selectors[i])
            );
        }
    }

    /// @dev `next` installed as the directory requires: announced by the network, waited out,
    ///      activated by anyone.
    function _activate(address current, Accounts next) internal {
        _asNetwork(
            address(directory),
            abi.encodeCall(IModuleSlots.proposeModule, (Slots.ACCOUNTS, address(next)))
        );
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.ACCOUNTS)
        );
        directory.activateModule(Slots.ACCOUNTS);
        assertEq(directory.moduleOf(Slots.ACCOUNTS), current, "not before the wait");
        _wait(directory.moduleDelay());
        vm.prank(collector);
        directory.activateModule(Slots.ACCOUNTS);
        assertEq(directory.moduleOf(Slots.ACCOUNTS), address(next));
    }

    function _installSuccessor() internal returns (Accounts next) {
        next = _newSuccessor(accounts);
        _activate(address(accounts), next);
    }

    /// @dev Announces `next`, stages the replacement of the account in the old module a day
    ///      later, and activates `next` while that replacement is still pending; returns when
    ///      the replacement is due.
    function _activateDuringAReplacement(Accounts next) internal returns (uint48 due) {
        _asNetwork(
            address(directory),
            abi.encodeCall(IModuleSlots.proposeModule, (Slots.ACCOUNTS, address(next)))
        );
        uint256 announced = block.timestamp;
        _wait(1 days);
        _govern(network, address(accounts), _replacement());
        due = accounts.pendingChange(artistId).executableAt;
        vm.warp(announced + directory.moduleDelay());
        assertLt(block.timestamp, due, "the replacement is still pending");
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

/// @notice Replacing the accounts module without losing an account or handing one back, on the
///         real deployed stack. An artist registers and sells a work, the artist's account is
///         moved to another address by a network replacement (so the address its ID was made
///         from no longer acts for it), and the network installs a second `Accounts` through the
///         directory (announced, waited out, activated), deployed naming the genesis module as
///         `previous`. After the replacement the moved account is served under its old ID:
///         payout address, wallet check and freeze; money owed before and after is released to
///         the moved payout address; moves, consents and record edits signed by the moved root
///         verify; and the address the ID was made from has no power and cannot register again.
///         A change made in the old module during the wait is carried; the first change made in
///         the new module copies the account there, and the new module alone answers for it
///         from then on; a new artist registers in the new module; a third module serves the
///         accounts of both modules before it.
/// @dev This is the test `docs/operations/replacing-modules.md` asks for before a successor
///      accounts module is announced.
contract AccountsSuccessorTest is AccountsSuccessorBase {
    // ------------------------------------------------------------------ the moved account

    function test_AccountsSuccessor_AMovedAccountIsServedUnderItsOldId() public {
        // Money owed before the replacement, then the account moves in the genesis module.
        (, address vault) = _sold(root, 0, lead, 0);
        uint256 owedBefore = vault.balance;
        assertGt(owedBefore, 0);
        _moveAccount();
        assertEq(accounts.payoutAddress(artistId), newRoot);
        assertTrue(newRoot != address(uint160(artistId)), "the payout is not the ID's address");

        Accounts next = _installSuccessor();
        assertEq(next.previous(), address(accounts));

        // The same ID: payout address, wallets and freeze state.
        assertEq(directory.payoutAddress(artistId), newRoot);
        assertEq(next.artistIdOf(newRoot), artistId);
        assertEq(next.artistIdOf(lead), artistId, "the first address still names the account");
        assertEq(next.authorityOf(artistId), newRoot);
        assertEq(next.activeAuthorityOf(artistId), newRoot);
        assertTrue(next.isWallet(artistId, newRoot));
        assertFalse(next.isWallet(artistId, lead));
        assertFalse(next.isWallet(uint256(uint160(lead)), lead), "nor by its own address");
        assertTrue(next.isWallet(uint256(uint160(newRoot)), newRoot), "named by its root");
        assertEq(next.frozenUntil(artistId), 0);
        (ArtistIdentity memory identity, uint48 frozenUntil) = next.artist(artistId);
        (ArtistIdentity memory before,) = accounts.artist(artistId);
        assertEq(keccak256(abi.encode(identity)), keccak256(abi.encode(before)));
        assertEq(frozenUntil, 0);
        assertEq(uint8(next.pendingChange(artistId).kind), uint8(ChangeKind.NONE));

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
        accounts = next; // consents are signed in the domain of the module in force
        _govern(network, address(rules), _relicenseCall(tokenId, w, mit, _list(newRoot)));
        assertEq(facts.factsOf(address(stream), tokenId).licenseId, "MIT");
    }

    /// @dev The address the ID was made from lost the account before the replacement and has
    ///      no power after it: it cannot edit the record, and it finalizes it no sooner than a
    ///      stranger could. The moved root edits and finalizes at once.
    function test_AccountsSuccessor_TheFirstAddressOfAMovedAccountCannotEditOrFinalize() public {
        (uint256 tokenId,) = _sold(root, 0, lead, 0);
        _moveAccount();
        _expectNotArtist(lead, tokenId);

        Accounts next = _installSuccessor();
        assertFalse(next.isWallet(artistId, lead));
        assertTrue(next.isWallet(artistId, newRoot));
        assertEq(next.authorityOf(artistId), newRoot);

        _expectNotArtist(lead, tokenId);
        // Its `finalize` is anybody's: it records the public notice and finalizes nothing.
        bytes32 state = _state(tokenId);
        vm.prank(lead);
        rules.finalize(address(stream), tokenId, state);
        assertEq(rules.finalizeNoticeAt(address(stream), tokenId), block.timestamp);
        assertFalse(facts.factsOf(address(stream), tokenId).finalized);

        bytes32 file = _record("Written by the moved root");
        _setRecordAs(newRoot, tokenId, file);
        assertEq(facts.factsOf(address(stream), tokenId).recordFileId, file);
        state = _state(tokenId);
        vm.prank(newRoot);
        rules.finalize(address(stream), tokenId, state);
        assertTrue(facts.factsOf(address(stream), tokenId).finalized);
    }

    /// @dev Nor can it take the account back by accepting a package: its signature is not the
    ///      account's, `register` refuses an address the replaced module knows, and the money
    ///      the vault owes is paid to the moved payout address only.
    function test_AccountsSuccessor_TheFirstAddressOfAMovedAccountCannotRegisterOrBePaid() public {
        (, address vault) = _sold(root, 0, lead, 0);
        uint256 owed = vault.balance;
        assertGt(owed, 0);
        _moveAccount();
        Accounts next = _installSuccessor();
        assertEq(directory.payoutAddress(artistId), newRoot, "the payout is not held or reset");

        // A package of somebody else, approved; the first address signs an acceptance.
        Work[] memory works = _one(_work(_actor("successorOther"), collectionId));
        bytes32 otherRoot = _rootOf(works);
        _approve(otherRoot);
        PartyAcceptance memory acceptance = PartyAcceptance(
            lead, _profileId(lead), _profileDoc(lead), uint64(block.timestamp + 1 days)
        );
        bytes memory proof =
            abi.encodePacked(lead, _sign(lead, registry.acceptanceDigest(otherRoot, acceptance)));
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, lead));
        registry.acceptPackage(otherRoot, acceptance, proof);
        vm.prank(address(registry));
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, lead));
        next.register(lead, _profileId(lead), _profileDoc(lead));
        vm.prank(address(registry));
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, newRoot));
        next.register(newRoot, _profileId(newRoot), _profileDoc(newRoot));

        assertEq(next.authorityOf(artistId), newRoot);
        assertEq(directory.payoutAddress(artistId), newRoot);
        vm.prank(lead);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, lead, newRoot)
        );
        ledger.release(payees, bytes32(0), address(0), 0);
        vm.prank(newRoot);
        assertEq(ledger.release(payees, bytes32(0), address(0), 0), owed);
        assertEq(newRoot.balance, owed);
        assertEq(lead.balance, 0);

        // The moved root accepts the package for the account, under the old ID.
        proof = abi.encodePacked(
            newRoot, _sign(newRoot, registry.acceptanceDigest(otherRoot, acceptance))
        );
        assertEq(registry.acceptPackage(otherRoot, acceptance, proof), artistId);
        assertEq(registry.acceptedAs(otherRoot, lead), artistId);
    }

    /// @dev A wallet consolidated with the moved root acts for the inherited account: the
    ///      successor asks its own consolidation source about the root the old module names.
    function test_AccountsSuccessor_AConsolidatedWalletOfAnInheritedAccountActs() public {
        (uint256 tokenId,) = _sold(root, 0, lead, 0);
        _moveAccount();
        Accounts next = _installSuccessor();
        address second = _actor("successorSecondWallet");
        assertFalse(next.isWallet(artistId, second));
        _consolidate(newRoot, second);
        vm.expectCall(
            address(consolidation),
            abi.encodeCall(IConsolidationSource.isConsolidated, (newRoot, second))
        );
        assertTrue(next.isWallet(artistId, second));
        _setRecordAs(second, tokenId, _record("By a consolidated wallet"));
    }

    /// @dev While the new module waits, only the module in force writes: a wallet's call to
    ///      the new module is refused, and the freeze the network places in the module in
    ///      force is what the new module serves once it is activated. From then on the old
    ///      module writes nothing, and the network lifts the freeze in the new one.
    function test_AccountsSuccessor_AFreezePlacedDuringTheWaitIsServedAndLiftedInTheNewModule()
        public
    {
        (uint256 tokenId, address vault) = _sold(root, 0, lead, 0);
        uint256 owed = vault.balance;
        _moveAccount();
        Accounts next = _newSuccessor(accounts);
        _asNetwork(
            address(directory),
            abi.encodeCall(IModuleSlots.proposeModule, (Slots.ACCOUNTS, address(next)))
        );

        vm.prank(newRoot);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.NotModule.selector, Slots.ACCOUNTS, next)
        );
        next.revokeNonce(artistId);
        _asNetwork(address(accounts), abi.encodeCall(accounts.freeze, (artistId)));
        uint48 until = accounts.frozenUntil(artistId);
        _wait(directory.moduleDelay());
        directory.activateModule(Slots.ACCOUNTS);
        assertEq(directory.moduleOf(Slots.ACCOUNTS), address(next));
        assertGt(until, block.timestamp, "the freeze has not run out");

        assertEq(next.frozenUntil(artistId), until);
        assertFalse(next.isWallet(artistId, newRoot));
        assertEq(next.activeAuthorityOf(artistId), address(0));
        assertEq(directory.payoutAddress(artistId), address(0), "held while frozen");
        vm.prank(newRoot);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayoutUnresolved.selector, artistId));
        ledger.release(payees, bytes32(0), address(0), 0);
        _expectNotArtist(newRoot, tokenId);
        assertEq(vault.balance, owed, "held, not lost");

        // The replaced module changes no more.
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.NotModule.selector, Slots.ACCOUNTS, accounts)
        );
        accounts.unfreeze(artistId);
        _asNetwork(address(next), abi.encodeCall(next.unfreeze, (artistId)));
        assertEq(next.frozenUntil(artistId), 0);
        _setRecordAs(newRoot, tokenId, _record("After the freeze"));
        vm.prank(newRoot);
        assertEq(ledger.release(payees, bytes32(0), address(0), 0), owed);
        assertEq(newRoot.balance, owed);
    }

    /// @dev The network freezes an inherited account in the new module: the record is copied
    ///      there with the freeze, and lifting it there restores the account.
    function test_AccountsSuccessor_AFreezeInTheNewModuleCopiesTheAccountAndHolds() public {
        (uint256 tokenId, address vault) = _sold(root, 0, lead, 0);
        uint256 owed = vault.balance;
        _moveAccount();
        Accounts next = _installSuccessor();
        (ArtistIdentity memory identity,) = accounts.artist(artistId);

        vm.expectEmit(address(next));
        emit Accounts.AccountInherited(artistId, address(accounts), identity, 0);
        vm.prank(network);
        next.freeze(artistId);
        assertGt(next.frozenUntil(artistId), block.timestamp);
        assertEq(accounts.frozenUntil(artistId), 0, "the old module is not written");
        assertFalse(next.isWallet(artistId, newRoot));
        assertEq(directory.payoutAddress(artistId), address(0));
        _expectNotArtist(newRoot, tokenId);
        _expectNotArtist(lead, tokenId);

        // The old module changes no more: the record the new one copied cannot go stale.
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.NotModule.selector, Slots.ACCOUNTS, accounts)
        );
        accounts.unfreeze(artistId);
        assertFalse(next.isWallet(artistId, newRoot), "still frozen where it is recorded");

        _asNetwork(address(next), abi.encodeCall(next.unfreeze, (artistId)));
        assertTrue(next.isWallet(artistId, newRoot));
        assertFalse(next.isWallet(artistId, lead));
        vm.prank(newRoot);
        assertEq(ledger.release(payees, bytes32(0), address(0), 0), owed);
    }

    // ------------------------------------------------------------------ during the wait

    /// @dev The old module keeps changing while the successor waits: a replacement staged after
    ///      the announcement is pending at activation (nobody acts, the payout is held) and,
    ///      once executed in the new module, is what the stack serves.
    function test_AccountsSuccessor_AChangeInTheOldModuleDuringTheWaitIsCarried() public {
        (uint256 tokenId, address vault) = _sold(root, 0, lead, 0);
        uint256 owed = vault.balance;
        Accounts next = _newSuccessor(accounts);
        uint48 due = _activateDuringAReplacement(next);

        assertFalse(next.isWallet(artistId, lead), "blocked during the notice");
        assertEq(directory.payoutAddress(artistId), address(0));
        assertEq(uint8(next.pendingChange(artistId).kind), uint8(ChangeKind.REPLACEMENT));
        vm.prank(lead);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayoutUnresolved.selector, artistId));
        ledger.release(payees, bytes32(0), address(0), 0);
        _expectNotArtist(lead, tokenId);

        // It no longer runs in the old module, which writes nothing once replaced; anyone
        // runs it in the new one.
        vm.warp(due);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.NotModule.selector, Slots.ACCOUNTS, accounts)
        );
        accounts.executeChange(artistId);
        next.executeChange(artistId);
        assertEq(directory.payoutAddress(artistId), newRoot);
        assertTrue(next.isWallet(artistId, newRoot));
        assertFalse(next.isWallet(artistId, lead));
        vm.prank(newRoot);
        assertEq(ledger.release(payees, bytes32(0), address(0), 0), owed);
        assertEq(newRoot.balance, owed);
        _setRecordAs(newRoot, tokenId, _record("By the root named during the wait"));
    }

    /// @dev The same pending replacement executed in the new module: the account is copied
    ///      there with its pending change, which then runs there.
    function test_AccountsSuccessor_APendingReplacementIsCopiedAndExecutedInTheNewModule() public {
        (uint256 tokenId, address vault) = _sold(root, 0, lead, 0);
        uint256 owed = vault.balance;
        Accounts next = _newSuccessor(accounts);
        uint48 due = _activateDuringAReplacement(next);

        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.ChangeNotDue.selector, artistId, due)
        );
        next.executeChange(artistId);
        vm.warp(due);
        (ArtistIdentity memory before,) = accounts.artist(artistId);
        vm.expectEmit(address(next));
        emit Accounts.AccountInherited(artistId, address(accounts), before, 0);
        vm.prank(collector);
        next.executeChange(artistId);

        assertEq(next.authorityOf(artistId), newRoot);
        assertEq(next.artistIdOf(newRoot), artistId);
        assertEq(uint8(next.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        assertEq(accounts.authorityOf(artistId), lead, "the old module is not written");
        assertEq(directory.payoutAddress(artistId), newRoot);
        assertFalse(next.isWallet(artistId, lead));
        _expectNotArtist(lead, tokenId);
        vm.prank(newRoot);
        assertEq(ledger.release(payees, bytes32(0), address(0), 0), owed);
        _setRecordAs(newRoot, tokenId, _record("By the root the new module installed"));
    }

    // ------------------------------------------------------------------ the successor's own records

    /// @dev Once the successor changes an account, the old module is not what the permanent
    ///      contracts ask: it still names the moved root, and the stack follows the successor.
    function test_AccountsSuccessor_AnAccountChangedInTheSuccessorIsAnsweredThere() public {
        (uint256 tokenId, address vault) = _sold(root, 0, lead, 0);
        uint256 owed = vault.balance;
        _moveAccount();
        Accounts next = _installSuccessor();
        address third = _actor("successorThirdRoot");
        address thirdPayout = makeAddr("successorThirdPayout");

        // The network replaces the root again, in the new module.
        _replaceIn(next, third, thirdPayout);
        assertEq(accounts.payoutAddress(artistId), newRoot, "the old module is unchanged");
        assertTrue(accounts.isWallet(artistId, newRoot));
        assertEq(next.authorityOf(artistId), third);
        assertEq(next.artistIdOf(third), artistId);
        assertEq(next.artistIdOf(newRoot), artistId, "a former root still names the account");
        assertEq(next.artistIdOf(lead), artistId);

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
        _expectNotArtist(lead, tokenId);
        _setRecordAs(third, tokenId, _record("By the root the successor names"));

        // The root the successor names signs the next move, for the same account.
        (uint256 next1, address vault1) = _sold(root, 2, third, 2);
        assertEq(stream.workOf(next1).artistId, artistId);
        uint256 owed1 = vault1.balance;
        vm.prank(thirdPayout);
        assertEq(ledger.release(payees, bytes32(0), address(0), 0), owed1);
        assertEq(thirdPayout.balance, owed + owed1);

        // A freeze the successor records holds the payout, whatever the old module says.
        _asNetwork(address(next), abi.encodeCall(next.freeze, (artistId)));
        assertEq(directory.payoutAddress(artistId), address(0));
        assertEq(accounts.frozenUntil(artistId), 0);
        _expectNotArtist(third, tokenId);
    }

    /// @dev The moved root changes its payout address in the new module, signed in the new
    ///      module's domain at its nonce there (zero): the account is copied at staging.
    function test_AccountsSuccessor_AnInheritedAccountChangesItsPayoutInTheNewModule() public {
        (, address vault) = _sold(root, 0, lead, 0);
        uint256 owed = vault.balance;
        _moveAccount();
        Accounts next = _installSuccessor();
        address payout = makeAddr("successorNewPayout");
        ArtistIdentity memory id = _identity(artistId, newRoot, payout);
        uint64 deadline = uint64(block.timestamp + 1 days);
        assertEq(next.changeNonce(artistId), 0);
        bytes memory proof =
            abi.encodePacked(newRoot, _sign(newRoot, next.changeDigest(artistId, id, 0, deadline)));

        // The first address cannot stage it.
        bytes memory forged =
            abi.encodePacked(lead, _sign(lead, next.changeDigest(artistId, id, 0, deadline)));
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, lead));
        next.stageChange(artistId, id, deadline, forged);

        next.stageChange(artistId, id, deadline, proof);
        assertEq(next.changeNonce(artistId), 1);
        assertEq(directory.payoutAddress(artistId), address(0), "held while the payout moves");
        vm.warp(block.timestamp + next.OWN_CHANGE_DELAY());
        next.executeChange(artistId);
        assertEq(directory.payoutAddress(artistId), payout);
        assertEq(accounts.payoutAddress(artistId), newRoot, "the old module is not written");
        vm.prank(payout);
        assertEq(ledger.release(payees, bytes32(0), address(0), 0), owed);
        assertEq(payout.balance, owed);
    }

    /// @dev An artist who registers after the replacement is recorded by the successor (the
    ///      package registry is its `register` caller), with the ID the genesis rule gives, and
    ///      is paid.
    function test_AccountsSuccessor_ANewArtistRegistersInTheSuccessor() public {
        _moveAccount();
        Accounts next = _installSuccessor();
        address newcomer = _actor("successorNewcomer");
        uint256 id = uint256(uint160(newcomer));
        assertTrue(next.isWallet(id, newcomer), "an unregistered address is its own account");
        assertFalse(next.isWallet(id, lead));
        Work[] memory works = new Work[](1);
        works[0] = _work(newcomer, collectionId);
        bytes32 newRootHash = _publish(works);
        _keep(newRootHash, works);
        assertEq(next.artistIdOf(newcomer), id);
        assertEq(next.authorityOf(id), newcomer);
        assertEq(accounts.artistIdOf(newcomer), 0, "the old module was not written");

        accounts = next;
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

    // ------------------------------------------------------------------ a third module

    /// @dev Two replacements in a row. The third module names the second as `previous`, the
    ///      second names the first. It serves an account recorded only in the first, one the
    ///      second copied and changed, and one created in the second; no former root acts.
    function test_AccountsSuccessor_AThirdModuleServesTheAccountsOfBothBeforeIt() public {
        (uint256 tokenId, address vault) = _sold(root, 0, lead, 0);
        uint256 owed = vault.balance;
        address quiet = _actor("successorQuietArtist");
        _publish(_one(_work(quiet, collectionId)));
        uint256 quietId = uint256(uint160(quiet));
        _moveAccount();

        Accounts second = _installSuccessor();
        address third = _actor("successorThirdRoot");
        address thirdPayout = makeAddr("successorThirdPayout");
        _replaceIn(second, third, thirdPayout);
        address newcomer = _actor("successorNewcomer");
        _publish(_one(_work(newcomer, collectionId)));
        uint256 newcomerId = uint256(uint160(newcomer));
        assertEq(second.authorityOf(newcomerId), newcomer);

        Accounts last = _newSuccessor(second);
        _activate(address(second), last);
        assertEq(last.previous(), address(second));

        // Recorded only in the first module.
        assertEq(last.authorityOf(quietId), quiet);
        assertTrue(last.isWallet(quietId, quiet));
        assertEq(directory.payoutAddress(quietId), quiet);
        // Copied and changed in the second.
        assertEq(last.authorityOf(artistId), third);
        assertTrue(last.isWallet(artistId, third));
        assertFalse(last.isWallet(artistId, newRoot));
        assertFalse(last.isWallet(artistId, lead));
        assertEq(last.artistIdOf(lead), artistId);
        assertEq(last.artistIdOf(newRoot), artistId);
        assertEq(directory.payoutAddress(artistId), thirdPayout);
        // Created in the second.
        assertEq(last.authorityOf(newcomerId), newcomer);
        assertTrue(last.isWallet(newcomerId, newcomer));

        _expectNotArtist(lead, tokenId);
        _expectNotArtist(newRoot, tokenId);
        _setRecordAs(third, tokenId, _record("Under the third module"));
        vm.prank(thirdPayout);
        assertEq(ledger.release(payees, bytes32(0), address(0), 0), owed);
        for (uint256 i; i < 3; ++i) {
            address formerOrTaken = i == 0 ? lead : i == 1 ? newRoot : quiet;
            vm.prank(address(registry));
            vm.expectRevert(
                abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, formerOrTaken)
            );
            last.register(formerOrTaken, bytes32(0), bytes32(0));
        }

        // A freeze placed in the third module copies the account from the first, through the
        // second.
        _asNetwork(address(last), abi.encodeCall(last.freeze, (quietId)));
        assertFalse(last.isWallet(quietId, quiet));
        assertEq(second.frozenUntil(quietId), 0);
        assertEq(accounts.frozenUntil(quietId), 0);
    }
}
