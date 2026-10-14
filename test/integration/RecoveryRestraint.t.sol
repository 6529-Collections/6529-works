// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStatementLog, Role, Statement } from "src/interfaces/IStatementLog.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { Locator, LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH, PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import { HASH_SHA256, HashRef } from "src/interfaces/types/HashRef.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "src/interfaces/types/IdentityTypes.sol";
import { EditionFormat, EditionTerms, ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { Payment, PaymentMethod, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice IDENTITY-1 (owner decision A, 14 October 2026) on the real contracts: while a recovery
///         override that would move the authority is pending (staged or contested, until it
///         executes, is vetoed, voided or lapses), nobody acts as the artist. The key it recovers
///         from loses every creator power, and the reserved new key gains none until execution:
///         - sales: the creator's `openSale`, its consent and `closeSale` (FixedPriceSale);
///         - moves: an approved, unminted work cannot start;
///         - auctions: a no-bid `settle` waits (reverts, moving nothing) until the outcome;
///         - records: `setRecord`, `finalize` and the artist's `addLocator`;
///         - statements: ARTIST statements.
///         A STANDARD change and a payout-only override restrain nothing. Sales and auctions
///         already running keep running; the payout freeze holds their artist share.
contract RecoveryRestraintTest is IntegrationBase {
    address internal constant ALL = 0x8888888888888888888888888888888888888888;
    uint256 internal constant CONSOLIDATION = 999;
    /// @dev Arweave locators with 43-character transaction IDs.
    string internal constant THIEF_TX = "ar://tHiEf00000000000000000000000000000000000000";
    string internal constant REAL_TX = "ar://ReAL000000000000000000000000000000000000000";

    address internal artist; // its key is stolen: every `vm.prank(artist)` before recovery
    address internal newKey;
    address internal wallet;
    address internal thiefWallet;
    address internal collector = makeAddr("restraintCollector");
    uint256 internal artistId;
    bytes32 internal root;
    uint256 internal masterId;

    function setUp() public override {
        super.setUp();
        artist = _actor("restrainedArtist");
        newKey = _actor("recoveredKey");
        wallet = _actor("restrainedArtistWallet");
        thiefWallet = _actor("restraintThiefWallet");
        artistId = uint160(artist);
        _consolidate(artist, wallet);

        Work[] memory works = new Work[](3);
        works[0] = _work(artist, collectionId);
        works[0].item.kind = ItemKind.EDITION_MASTER;
        works[0].item.edition = EditionTerms(
            EditionFormat.FIXED, 50, 0, 0.1 ether, CURRENCY_ETH, SaleKind.FIXED_PRICE, ""
        );
        works[1] = _work(artist, collectionId); // approved, accepted, not yet minted
        works[2] = _work(artist, collectionId); // minted and sold, record not finalized
        root = _publish(works);
        _keep(root, works);
        masterId = _sell(root, works, 0, collector, 1 ether);
        editions.createEdition(masterId, works[0].item, root, _proofOf(works, 0));
    }

    function _consolidate(address a, address b) internal {
        vm.prank(a);
        delegation.registerDelegationAddress(ALL, b, type(uint64).max, CONSOLIDATION, true, 0);
        vm.prank(b);
        delegation.registerDelegationAddress(ALL, a, type(uint64).max, CONSOLIDATION, true, 0);
    }

    /// @dev Governance stages a CONTESTED override to `newKey` (PARAMETER_SETTER, 48 hours).
    function _stageRecovery() internal returns (PendingChange memory p) {
        ArtistIdentity memory next =
            ArtistIdentity(newKey, newKey, _profileId(artist), _profileDoc(artist));
        bytes32 evidence = keccak256("recovery evidence, public notice");
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes memory acceptance = _sign(
            newKey, artists.overrideDigest(artistId, ChangeKind.CONTESTED, next, evidence, deadline)
        );
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(
                artists.stageOverride,
                (artistId, ChangeKind.CONTESTED, next, evidence, deadline, acceptance)
            )
        );
        p = artists.pendingChange(artistId);
        assertEq(artists.activeAuthorityOf(artistId), address(0), "restrained");
        assertEq(artists.authorityOf(artistId), artist, "still identified");
    }

    function _statement(uint256 tokenId) internal view returns (Statement memory) {
        return Statement(
            address(stream),
            tokenId,
            StatementKinds.ARTIST_STATEMENT,
            keccak256("6529-works/artist-statement/1"),
            HashRef(HASH_SHA256, keccak256("a statement")),
            "ar://artist-statement",
            bytes32(0),
            bytes32(0)
        );
    }

    function _publicPhase() internal view returns (IFixedPriceSale.Phase[] memory pub) {
        pub = new IFixedPriceSale.Phase[](1);
        pub[0] = IFixedPriceSale.Phase(
            uint64(block.timestamp), uint64(block.timestamp + 365 days), bytes32(0), 0, false, false
        );
    }

    /// @dev One zero-price allowlist phase for `to`, 50 copies.
    function _freePhase(address to) internal view returns (IFixedPriceSale.Phase[] memory phases) {
        phases = new IFixedPriceSale.Phase[](1);
        phases[0] = IFixedPriceSale.Phase(
            uint64(block.timestamp),
            uint64(block.timestamp + 1 hours),
            fixedSale.allowlistLeaf(address(editions), masterId, 0, to, 50, 0),
            0,
            false,
            true
        );
    }

    /// @dev Moves to the auction's end, never back in time.
    function _toEnd(uint256 saleId) internal {
        uint256 end = auction.auction(saleId).endTime;
        if (block.timestamp < end) vm.warp(end);
    }

    function _notManager(address caller) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, caller);
    }

    // ------------------------------------------------------------------ the edition sale

    /// @dev IDENTITY-1 (a): the restrained key can neither close the platform's sale nor open
    ///      its own, and its signed consent does not approve a sale either. The platform's sale
    ///      at the package price keeps selling, its artist share frozen. After execution the new
    ///      key manages the sale.
    function test_RestrainedKeyCannotManageTheEditionSale() public {
        IFixedPriceSale.ArtistConsent memory none;
        vm.prank(platform);
        uint256 publicSale = fixedSale.openSale(address(editions), masterId, _publicPhase(), none);
        PendingChange memory p = _stageRecovery();
        vm.warp(block.timestamp + 10 days);

        vm.prank(artist);
        vm.expectRevert(_notManager(artist));
        fixedSale.closeSale(publicSale);
        vm.prank(newKey);
        vm.expectRevert(_notManager(newKey));
        fixedSale.closeSale(publicSale);
        IFixedPriceSale.Phase[] memory free = _freePhase(thiefWallet);
        vm.prank(artist);
        vm.expectRevert(_notManager(artist));
        fixedSale.openSale(address(editions), masterId, free, none);

        // The platform closes its sale and tries the restrained key's consent: refused.
        vm.prank(platform);
        fixedSale.closeSale(publicSale);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = fixedSale.phaseConfigurationDigest(
            address(editions), masterId, CURRENCY_ETH, 0.1 ether, free, 7, deadline
        );
        IFixedPriceSale.ArtistConsent memory consent =
            IFixedPriceSale.ArtistConsent(7, deadline, _sign(artist, digest));
        vm.prank(platform);
        vm.expectRevert(IFixedPriceSale.InvalidArtistConsent.selector);
        fixedSale.openSale(address(editions), masterId, free, consent);

        // The platform's own sale at the package price still sells.
        vm.prank(platform);
        uint256 again = fixedSale.openSale(address(editions), masterId, _publicPhase(), none);
        vm.deal(collector, 1 ether);
        vm.prank(collector);
        fixedSale.purchase{ value: 0.1 ether }(
            IFixedPriceSale.Purchase(again, 0, collector, 1, 0, 0),
            new bytes32[](0),
            Payment(PaymentMethod.DIRECT, collector, 0.1 ether, 0, 0, "")
        );
        assertEq(editions.balanceOf(collector, masterId), 1);
        assertEq(editions.balanceOf(thiefWallet, masterId), 0);

        vm.warp(p.executableAt);
        artists.executeChange(artistId);
        vm.prank(newKey);
        fixedSale.closeSale(again);
        vm.prank(newKey);
        fixedSale.openSale(address(editions), masterId, _publicPhase(), none);
    }

    // ------------------------------------------------------------------ moves and auctions

    /// @dev IDENTITY-1 (b): neither the restrained key nor the reserved new key can start an
    ///      approved, unminted work. After execution the new key's move starts it, and a no-bid
    ///      settlement delivers to the new key.
    function test_NobodyStartsAnUnmintedWorkDuringTheNotice() public {
        PendingChange memory p = _stageRecovery();
        Work[] memory works = _package(root);
        uint256 nonce = nextMoveNonce[artistId]++;
        bytes memory byOldKey = _mintDataSignedBy(root, works, 1, artist, nonce);
        bytes memory byNewKey = _mintDataSignedBy(root, works, 1, newKey, nonce);
        vm.expectRevert(IPackageRegistry.InvalidSignature.selector);
        auction.start(address(stream), byOldKey);
        vm.expectRevert(IPackageRegistry.InvalidSignature.selector);
        auction.start(address(stream), byNewKey);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.NotAuthority.selector, artistId, artist)
        );
        registry.revokeMove(artistId, nonce);

        vm.warp(p.executableAt);
        artists.executeChange(artistId);
        uint256 saleId =
            auction.start(address(stream), _mintDataSignedBy(root, works, 1, newKey, nonce));
        uint256 tokenId = stream.totalMinted();
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), newKey, "delivered to the recovered key");
    }

    /// @dev A no-bid auction that was already running when the override was staged: its settle
    ///      waits (reverts, moving nothing, the token stays in custody) while the artist is
    ///      restrained, and delivers to the new key once the override executes.
    function test_NoBidAuctionRunningAtStagingWaitsForTheOutcome() public {
        (uint256 saleId, uint256 tokenId) = _start(root, _package(root), 1);
        PendingChange memory p = _stageRecovery();
        _toEnd(saleId);
        vm.expectRevert(
            abi.encodeWithSelector(EnglishAuction.InvalidRecipient.selector, address(0))
        );
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), address(auction), "held in custody");

        vm.warp(p.executableAt);
        vm.expectRevert(
            abi.encodeWithSelector(EnglishAuction.InvalidRecipient.selector, address(0))
        );
        auction.settle(saleId);
        artists.executeChange(artistId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), newKey);
    }

    /// @dev The same waiting auction settles to the old authority once the guardian vetoes the
    ///      override: its powers return.
    function test_NoBidAuctionSettlesToTheOldAuthorityAfterAVeto() public {
        (uint256 saleId, uint256 tokenId) = _start(root, _package(root), 1);
        _stageRecovery();
        _toEnd(saleId);
        vm.expectRevert(
            abi.encodeWithSelector(EnglishAuction.InvalidRecipient.selector, address(0))
        );
        auction.settle(saleId);
        vm.prank(guardian2);
        artists.vetoChange(artistId);
        assertEq(artists.activeAuthorityOf(artistId), artist, "restored");
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), artist);
    }

    /// @dev An auction with a bid, running when the override is staged, settles as usual: the
    ///      bidder gets the work and the seller wallet the proceeds, whose artist share stays
    ///      frozen until the outcome and then follows the recovered payout.
    function test_AuctionWithABidRunningAtStagingSettlesNormally() public {
        Work[] memory works = _package(root);
        address seller = economics.newWorkTerms(PRODUCT_STREAM, works[1].item.payees).seller;
        (uint256 saleId, uint256 tokenId) = _start(root, works, 1);
        _ethBid(saleId, collector, 1 ether);
        PendingChange memory p = _stageRecovery();
        _toEnd(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), collector);
        splitFactory.createWallet(works[1].item.payees, bytes32(0));
        assertGt(seller.balance, 0);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayoutUnresolved.selector, artistId));
        ISplitWallet(seller).release(CURRENCY_ETH, 0);

        vm.warp(p.executableAt);
        artists.executeChange(artistId);
        uint256 before = newKey.balance;
        vm.prank(newKey);
        ISplitWallet(seller).release(CURRENCY_ETH, 0);
        assertGt(newKey.balance, before, "the recovered payout collects");
        assertEq(artist.balance, 0);
    }

    // ------------------------------------------------------------------ records and statements

    /// @dev IDENTITY-1 (c): the restrained key can neither add the artist's locators nor change
    ///      or finalize the record, nor append ARTIST statements. After execution the new key
    ///      does all of it.
    function test_RestrainedKeyCannotAmendTheRecord() public {
        Work[] memory works = _package(root);
        uint256 tokenId = _sell(root, works, 2, collector, 1 ether);
        records.openRecord(tokenId, works[2].item, works[2].media);
        PendingChange memory p = _stageRecovery();
        bytes32 fileId = works[2].media[0].fileId;
        bytes32 state = records.workStateHash(tokenId);

        vm.startPrank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, artist)
        );
        records.addLocator(tokenId, fileId, Locator(LocatorKind.ARWEAVE, THIEF_TX));
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.NotWorkArtist.selector, tokenId, artist)
        );
        records.finalize(tokenId, state);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.NotWorkArtist.selector, tokenId, artist)
        );
        records.setRecord(tokenId, bytes32(uint256(1)), state);
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.ARTIST, artist)
        );
        statements.append(Role.ARTIST, _statement(tokenId));
        vm.stopPrank();
        vm.prank(newKey);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.NotWorkArtist.selector, tokenId, newKey)
        );
        records.finalize(tokenId, state);

        vm.warp(p.executableAt);
        artists.executeChange(artistId);
        vm.startPrank(newKey);
        records.addLocator(tokenId, fileId, Locator(LocatorKind.ARWEAVE, REAL_TX));
        statements.append(Role.ARTIST, _statement(tokenId));
        bytes32 done = records.workStateHash(tokenId);
        records.finalize(tokenId, done);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.WorkIsFinalized.selector, tokenId));
        records.finalize(tokenId, done);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ what does not restrain

    /// @dev A STANDARD change restrains nothing: during its 7 days the authority still signs
    ///      moves and statements (the old key can cancel the change itself).
    function test_StandardChangeDoesNotRestrain() public {
        vm.warp(block.timestamp + 31 days);
        ArtistIdentity memory next =
            ArtistIdentity(newKey, newKey, _profileId(artist), _profileDoc(artist));
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest =
            artists.changeDigest(artistId, next, artists.changeNonce(artistId), deadline);
        artists.stageChange(
            artistId, next, wallet, deadline, _sign(wallet, digest), _sign(newKey, digest)
        );
        assertEq(artists.activeAuthorityOf(artistId), artist);
        (, uint256 tokenId) = _start(root, _package(root), 1);
        vm.prank(artist);
        statements.append(Role.ARTIST, _statement(tokenId));
    }

    /// @dev A payout-only override restrains nothing.
    function test_PayoutOnlyOverrideDoesNotRestrain() public {
        ArtistIdentity memory next = ArtistIdentity(
            artist, makeAddr("estatePayout"), _profileId(artist), _profileDoc(artist)
        );
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(
                artists.stageOverride,
                (artistId, ChangeKind.CONTESTED, next, keccak256("payout"), 0, "")
            )
        );
        assertEq(uint8(artists.pendingChange(artistId).kind), uint8(ChangeKind.CONTESTED));
        assertEq(artists.payoutAddress(artistId), address(0), "the payout is frozen");
        assertEq(artists.activeAuthorityOf(artistId), artist);
        _start(root, _package(root), 1);
    }

    // ------------------------------------------------------------------ powers return

    /// @dev A captured wallet contests the override and a recorded vote voids it: the old
    ///      authority's powers return at once.
    function test_PowersReturnWhenAVoteVoidsTheOverride() public {
        vm.warp(block.timestamp + 31 days);
        artists.refreshStanding(artistId);
        _stageRecovery();
        vm.prank(wallet);
        artists.cancelChange(artistId);
        assertGt(artists.pendingChange(artistId).contestedAt, 0, "contested");
        assertEq(artists.activeAuthorityOf(artistId), address(0), "still restrained");

        bytes32 vote = _platformStatement(
            address(artists), artistId, StatementKinds.DISPUTE_OUTCOME, "ar://identity-vote"
        );
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.resolveContested, (artistId, false, vote))
        );
        assertEq(artists.activeAuthorityOf(artistId), artist, "restored by the void");
        _start(root, _package(root), 1);
    }

    /// @dev A contest nobody resolves lapses after a year: the restraint lifts with the payout
    ///      freeze, before anyone calls `expireContest`.
    function test_PowersReturnWhenAContestLapses() public {
        vm.warp(block.timestamp + 31 days);
        artists.refreshStanding(artistId);
        _stageRecovery();
        vm.prank(wallet);
        artists.cancelChange(artistId);
        uint256 contestedAt = artists.pendingChange(artistId).contestedAt;
        vm.warp(contestedAt + 365 days - 1);
        assertEq(artists.activeAuthorityOf(artistId), address(0));
        vm.warp(contestedAt + 365 days);
        assertEq(artists.activeAuthorityOf(artistId), artist, "lapsed");
        assertEq(artists.payoutAddress(artistId), artist);
        Work[] memory works = _package(root);
        // A fresh signature: the move deadline is relative to now.
        auction.start(
            address(stream), _mintDataSignedBy(root, works, 1, artist, nextMoveNonce[artistId]++)
        );
    }
}
