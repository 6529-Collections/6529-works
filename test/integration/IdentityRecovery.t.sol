// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IWorkRules } from "src/interfaces/core/IWorkRules.sol";
import { ArtistIdentity, PendingChange } from "src/interfaces/types/IdentityTypes.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { RecordFlowsBase } from "./RecordFlowsBase.sol";

/// @notice Consolidated accounts on the real stack, with the 6529 delegation contract as the
///         identity lane's mock: any wallet consolidated with the root acts as the artist (signs
///         a move, edits the record, consents to a relicense, stages a payout change and receives
///         the payout); the artist's own change (staged, cancelled, executed); the network's
///         replacement (blocking the account during its notice, then the new root and payout,
///         and the split-wallet release that follows); a contest that lapses; and a freeze that
///         blocks a contest of a replacement and can be placed again.
contract IdentityRecoveryTest is RecordFlowsBase {
    address internal lead;
    address internal wallet;
    address internal collector = makeAddr("identityCollector");
    address internal stranger = makeAddr("identityStranger");
    uint256 internal artistId;
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        lead = _actor("identityLead");
        wallet = _actor("identityWallet");
        Work[] memory works = new Work[](3);
        for (uint256 i; i < 3; ++i) {
            works[i] = _work(lead, collectionId);
        }
        works[2].item.license =
            License("CC-BY-4.0", _storeText(bytes("CC BY 4.0 (identity fixture)"), "text/plain"));
        root = _publish(works);
        _keep(root, works);
        artistId = accounts.artistIdOf(lead);
        assertEq(artistId, uint256(uint160(lead)));
    }

    function _changeProof(ArtistIdentity memory next, address signer)
        internal
        view
        returns (uint64 deadline, bytes memory proof)
    {
        deadline = uint64(block.timestamp + 7 days);
        bytes32 digest =
            accounts.changeDigest(artistId, next, accounts.changeNonce(artistId), deadline);
        proof = abi.encodePacked(signer, _sign(signer, digest));
    }

    function _setRecordAs(address who, uint256 tokenId, bytes32 recordFileId) internal {
        bytes32 state = _state(tokenId);
        vm.prank(who);
        rules.setRecord(address(stream), tokenId, recordFileId, state);
    }

    /// @dev Item `index` started through `SaleStarter` with a move signed by `signer`, sold.
    function _soldSignedBy(uint256 index, address signer, uint256 nonce)
        internal
        returns (uint256 tokenId)
    {
        Work[] memory works = _package(root);
        uint256 saleId = starter.start(
            auction,
            address(stream),
            _mintDataSignedBy(root, works, index, signer, nonce),
            works[index].media
        );
        tokenId = auction.auction(saleId).tokenId;
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
    }

    function _replacement(address newRoot) internal view returns (bytes memory call) {
        ArtistIdentity memory next = _identity(artistId, newRoot, newRoot);
        bytes32 evidence = keccak256(abi.encode("replacement evidence", newRoot));
        uint64 deadline = uint64(block.timestamp + 60 days);
        bytes memory acceptance =
            _sign(newRoot, accounts.replacementDigest(artistId, next, evidence, deadline));
        call = abi.encodeCall(
            accounts.stageReplacement, (artistId, next, evidence, deadline, acceptance)
        );
    }

    // ------------------------------------------------------------------ consolidated wallets

    function test_Identity_AConsolidatedWalletActsAsTheArtist() public {
        _consolidate(lead, wallet);
        assertTrue(accounts.isWallet(artistId, wallet));
        // The wallet signs the move that mints and sells the work.
        uint256 tokenId = _soldSignedBy(2, wallet, 0);
        assertEq(stream.workOf(tokenId).artistId, artistId);
        // It edits the record and consents to a relicense for the account.
        _setRecordAs(wallet, tokenId, _record("Edited by a second wallet"));
        Work memory w = _package(root)[2];
        License memory mit = License("MIT", _storeText(bytes("MIT (identity)"), "text/plain"));
        _govern(network, address(rules), _relicenseCall(tokenId, w, mit, _list(wallet)));
        assertEq(facts.factsOf(address(stream), tokenId).licenseId, "MIT");

        // It stages the account's payout to itself; while pending, the payout is held.
        ArtistIdentity memory next = _identity(artistId, lead, wallet);
        (uint64 deadline, bytes memory proof) = _changeProof(next, wallet);
        accounts.stageChange(artistId, next, deadline, proof);
        assertEq(accounts.payoutAddress(artistId), address(0), "held while a change moves it");
        vm.prank(lead);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayoutUnresolved.selector, artistId));
        ledger.release(w.item.payees, bytes32(0), address(0), 0);
        uint48 due = accounts.pendingChange(artistId).executableAt;
        assertEq(due, block.timestamp + 2 days);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.ChangeNotDue.selector, artistId, due)
        );
        accounts.executeChange(artistId);
        vm.warp(due);
        vm.prank(stranger);
        accounts.executeChange(artistId);
        assertEq(accounts.payoutAddress(artistId), wallet);

        // The wallet receives the payout; the root, no longer the payout, cannot pull it.
        address seller = auction.auction(auction.saleIdOf(address(stream), tokenId)).seller;
        uint256 part = seller.balance;
        assertGt(part, 0);
        vm.prank(lead);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, lead, wallet)
        );
        ledger.release(w.item.payees, bytes32(0), address(0), 0);
        vm.prank(wallet);
        assertEq(ledger.release(w.item.payees, bytes32(0), address(0), 0), part);
        assertEq(wallet.balance, part);

        // A wallet that leaves the consolidation no longer acts.
        vm.prank(wallet);
        delegation.revokeDelegationAddress(ALL_COLLECTIONS, lead, CONSOLIDATION);
        assertFalse(accounts.isWallet(artistId, wallet));
        bytes32 rec = _record("Refused");
        bytes32 state = _state(tokenId);
        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWorkRules.NotWorkArtist.selector, address(stream), tokenId, wallet
            )
        );
        rules.setRecord(address(stream), tokenId, rec, state);
    }

    // ------------------------------------------------------------------ the artist's own change

    function test_Identity_OwnChangeStagedCancelledThenExecuted() public {
        _consolidate(lead, wallet);
        ArtistIdentity memory next = _identity(artistId, wallet, wallet);
        (uint64 deadline, bytes memory proof) = _changeProof(next, lead);
        accounts.stageChange(artistId, next, deadline, proof);
        assertEq(accounts.reservedFor(wallet), artistId);
        (uint64 deadline2, bytes memory proof2) = _changeProof(next, lead);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.ChangePending.selector, artistId));
        accounts.stageChange(artistId, next, deadline2, proof2);

        // Any wallet of the account cancels it; the first signature is spent.
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.NotAuthorized.selector, artistId, stranger)
        );
        accounts.cancelChange(artistId);
        vm.prank(wallet);
        accounts.cancelChange(artistId);
        assertEq(uint8(accounts.pendingChange(artistId).kind), 0);
        assertEq(accounts.reservedFor(wallet), 0);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, lead));
        accounts.stageChange(artistId, next, deadline, proof);

        (deadline, proof) = _changeProof(next, wallet);
        accounts.stageChange(artistId, next, deadline, proof);
        vm.warp(block.timestamp + 2 days);
        accounts.executeChange(artistId);
        assertEq(accounts.authorityOf(artistId), wallet);
        assertEq(accounts.artistIdOf(wallet), artistId);
        assertEq(accounts.payoutAddress(artistId), wallet);
        // The new root signs the next move (`_mintData` signs with `authorityOf`).
        Work[] memory works = _package(root);
        (, uint256 tokenId) = _startAndOpen(root, works, 0);
        assertEq(stream.workOf(tokenId).artistId, artistId, "the same account");
    }

    // ------------------------------------------------------------------ the network's replacement

    /// @dev The network stages a replacement: during its 14-day notice nobody acts for the
    ///      account and its payout is held; then the new root acts, and the payout it names
    ///      releases the work's split-wallet share, which the old root no longer can.
    function test_Identity_NetworkReplacementThenPayoutAndSplitRelease() public {
        uint256 tokenId = _soldSignedBy(0, lead, 0);
        Work memory w = _package(root)[0];
        address newRoot = _actor("identityNewRoot");
        _govern(network, address(accounts), _replacement(newRoot));
        uint48 due = accounts.pendingChange(artistId).executableAt;
        assertEq(due, block.timestamp + 14 days);

        assertFalse(accounts.isWallet(artistId, lead), "blocked during the notice");
        assertEq(accounts.payoutAddress(artistId), address(0));
        bytes32 rec = _record("During the notice");
        bytes32 state = _state(tokenId);
        vm.prank(lead);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWorkRules.NotWorkArtist.selector, address(stream), tokenId, lead
            )
        );
        rules.setRecord(address(stream), tokenId, rec, state);
        vm.prank(lead);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayoutUnresolved.selector, artistId));
        ledger.release(w.item.payees, bytes32(0), address(0), 0);

        vm.warp(due - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.ChangeNotDue.selector, artistId, due)
        );
        accounts.executeChange(artistId);
        vm.warp(due);
        accounts.executeChange(artistId);
        assertEq(accounts.authorityOf(artistId), newRoot);
        assertEq(accounts.payoutAddress(artistId), newRoot);

        address seller = auction.auction(auction.saleIdOf(address(stream), tokenId)).seller;
        uint256 part = seller.balance;
        vm.prank(lead);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, lead, newRoot)
        );
        ledger.release(w.item.payees, bytes32(0), address(0), 0);
        vm.prank(newRoot);
        assertEq(ledger.release(w.item.payees, bytes32(0), address(0), 0), part);
        assertEq(newRoot.balance, part);
        _setRecordAs(newRoot, tokenId, _record("By the new root"));
        assertFalse(accounts.isWallet(artistId, lead));
    }

    /// @dev The root contests a replacement during its notice: it cannot execute, and lapses
    ///      after 90 days unless the network resolves it; then the root acts again.
    function test_Identity_AContestedReplacementLapses() public {
        address newRoot = _actor("identityContested");
        _govern(network, address(accounts), _replacement(newRoot));
        vm.prank(lead);
        accounts.cancelChange(artistId);
        PendingChange memory p = accounts.pendingChange(artistId);
        assertEq(p.contestedAt, block.timestamp);
        vm.warp(p.executableAt);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.ReplacementContested.selector, artistId)
        );
        accounts.executeChange(artistId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtistRegistry.ContestNotExpired.selector, artistId, p.contestedAt + 90 days
            )
        );
        accounts.expireContest(artistId);
        vm.warp(uint256(p.contestedAt) + 90 days);
        assertTrue(accounts.isWallet(artistId, lead), "a lapsed contest no longer blocks");
        vm.prank(stranger);
        accounts.expireContest(artistId);
        assertEq(accounts.authorityOf(artistId), lead);
        assertEq(accounts.payoutAddress(artistId), lead);
    }

    // ------------------------------------------------------------------ freezes

    /// @dev A freeze placed with a replacement blocks every contest; it cannot be placed twice
    ///      at once, but may be placed again once lifted or ended. Freezing until the notice ends
    ///      leaves no moment to contest; a freeze also holds the execution and the payout.
    function test_Identity_AFreezeBlocksAContestAndCanBePlacedAgain() public {
        address newRoot = _actor("identityFrozenReplacement");
        _govern(network, address(accounts), _replacement(newRoot));
        uint48 due = accounts.pendingChange(artistId).executableAt;
        bytes memory freeze = abi.encodeCall(accounts.freeze, (artistId));
        _asNetwork(address(accounts), freeze);
        uint48 until = uint48(block.timestamp + 14 days);
        assertEq(accounts.frozenUntil(artistId), until);
        assertEq(until, due, "the freeze covers the whole notice");

        vm.prank(lead);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.AccountIsFrozen.selector, artistId, until)
        );
        accounts.cancelChange(artistId);
        _governExpectRevert(
            network,
            address(accounts),
            freeze,
            abi.encodeWithSelector(IArtistRegistry.AccountIsFrozen.selector, artistId, until)
        );
        // Lifted, then placed again at once.
        _asNetwork(address(accounts), abi.encodeCall(accounts.unfreeze, (artistId)));
        assertEq(accounts.frozenUntil(artistId), 0);
        vm.warp(block.timestamp + 1 days);
        _asNetwork(address(accounts), freeze);
        until = uint48(block.timestamp + 14 days);
        assertEq(accounts.frozenUntil(artistId), until);
        assertEq(accounts.payoutAddress(artistId), address(0));

        // The notice ends while frozen: the contest window has closed.
        vm.warp(due);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.AccountIsFrozen.selector, artistId, until)
        );
        accounts.executeChange(artistId);
        vm.warp(until);
        vm.prank(lead);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.ContestWindowClosed.selector, artistId, due)
        );
        accounts.cancelChange(artistId);
        // The freeze ended: placed again at once.
        _asNetwork(address(accounts), freeze);
        assertEq(accounts.frozenUntil(artistId), until + 14 days);
        _asNetwork(address(accounts), abi.encodeCall(accounts.unfreeze, (artistId)));
        accounts.executeChange(artistId);
        assertEq(accounts.authorityOf(artistId), newRoot);
        assertEq(accounts.payoutAddress(artistId), newRoot);
    }
}
