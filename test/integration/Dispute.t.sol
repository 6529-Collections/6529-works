// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStatementLog, Statement } from "src/interfaces/IStatementLog.sol";
import {
    EditionFormat,
    EditionTerms,
    ItemKind,
    SeedPolicy
} from "src/interfaces/types/PackageTypes.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { HASH_SHA256, HashRef } from "src/interfaces/types/HashRef.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH, PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Flow 5 (integration brief, lane B): a dispute on the real contracts. A copier's
///         package reaches auction; a guardian pauses it; PLATFORM appends the
///         `DISPUTE_OUTCOME` statement, which the renderer shows; PARAMETER_SETTER's governed
///         `cancel` runs after its 48-hour delay, refunding the bid and burning the token; the
///         governed `releaseContent` reserves the content for the rightful artist the outcome
///         names; and only that artist's item with the same content then consumes. A rejected
///         dispute resumes the auction, and a dispute after a sale only adds a statement.
contract DisputeFlowTest is IntegrationBase {
    address internal rightful;
    address internal copier;
    address internal bidder = makeAddr("disputeBidder");
    bytes32 internal copierRoot;
    bytes32 internal rightfulRoot;
    bytes32 internal contentHash;

    function setUp() public override {
        super.setUp();
        rightful = _actor("rightfulArtist");
        copier = _actor("copier");
        Work memory original = _work(rightful, collectionId);
        Work memory copy = _work(copier, collectionId);
        // The copier claims the rightful artist's media: same content hash and media list.
        copy.media = original.media;
        copy.item.contentHash = original.item.contentHash;
        copy.item.mediaHash = original.item.mediaHash;
        contentHash = original.item.contentHash;
        Work[] memory copies = new Work[](2);
        copies[0] = copy;
        copies[1] = _work(copier, collectionId); // the copier's other work, sold normally
        copierRoot = _publish(copies);
        _keep(copierRoot, copies);
        rightfulRoot = _publish(_one(original));
        _keep(rightfulRoot, _one(original));
    }

    function _pauseCopy() internal returns (uint256 saleId, uint256 tokenId) {
        (saleId, tokenId) = _start(copierRoot, _package(copierRoot), 0);
        _ethBid(saleId, bidder, 1 ether);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("disputes wave: copied media"));
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.PAUSED));
    }

    function test_UpheldDisputeCancelsBurnsReleasesAndTheRightfulArtistMints() public {
        (uint256 saleId, uint256 tokenId) = _pauseCopy();

        // No bids while paused.
        vm.deal(bidder, 2 ether);
        vm.prank(bidder);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.PAUSED
            )
        );
        auction.bid{ value: 2 ether }(saleId, address(0), _payment(2 ether));

        // The TDH vote upholds the dispute: PLATFORM records the outcome; metadata shows it.
        bytes32 outcome = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://dispute-outcome-upheld"
        );
        assertEq(statements.latestDisputeOutcome(address(stream), tokenId), outcome);
        assertTrue(
            _contains(
                stream.tokenURI(tokenId),
                string.concat(
                    '{"trait_type":"Dispute statement","value":"',
                    Strings.toHexString(uint256(outcome), 32),
                    '"}'
                )
            ),
            "the renderer shows the dispute statement"
        );

        // A cancel citing anything but the recorded outcome fails.
        bytes memory wrong = abi.encodeCall(auction.cancel, (saleId, keccak256("not the outcome")));
        vm.warp(block.timestamp + 1 days);
        _schedule(hotAdmin, address(auction), wrong);
        vm.warp(block.timestamp + 2 days);
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.OutcomeNotRecorded.selector, saleId, keccak256("not the outcome")
            )
        );
        manager.execute(address(auction), wrong);

        // The governed cancel (PARAMETER_SETTER, 48 hours), scheduled by day 5 of the pause.
        _govern(hotAdmin, address(auction), abi.encodeCall(auction.cancel, (saleId, outcome)));
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        assertEq(auction.claimable(bidder, CURRENCY_ETH), 1 ether, "the bid is refunded");
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId)
        );
        stream.ownerOf(tokenId);
        assertEq(stream.totalSupply(), stream.totalMinted() - 1, "a gap: the ID is never reused");
        uint256 before = bidder.balance;
        vm.prank(bidder);
        auction.claim(CURRENCY_ETH, bidder);
        assertEq(bidder.balance - before, 1 ether);

        // The governed release names the rightful artist; the copier's item is tombstoned.
        bytes32 copierItem = WorksHashing.itemHash(_package(copierRoot)[0].item);
        _release(tokenId);
        assertEq(registry.consumedItemOf(contentHash), bytes32(0));
        assertEq(registry.releasedTo(contentHash), artists.artistIdOf(rightful));
        assertTrue(registry.isReleased(copierItem));

        // The rightful artist's item with the same content now consumes.
        (, uint256 rightfulToken) = _start(rightfulRoot, _package(rightfulRoot), 0);
        assertEq(stream.ownerOf(rightfulToken), address(auction));
        assertEq(
            registry.consumedItemOf(contentHash),
            WorksHashing.itemHash(_package(rightfulRoot)[0].item)
        );
        assertEq(rightfulToken, tokenId + 1);

        // The copier's item can never be consumed again, through any root.
        bytes memory again = _mintData(copierRoot, _package(copierRoot), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ContentUsed.selector,
                PRODUCT_STREAM,
                contentHash,
                WorksHashing.itemHash(_package(rightfulRoot)[0].item)
            )
        );
        auction.start(address(stream), again);
    }

    /// @dev The cancel must execute while the pause is live (ADR 0003): one scheduled on day 6
    ///      executes after the 7-day allowance, when the auction has resumed and run out.
    function test_CancelIsRefusedOnceThePauseHasLapsed() public {
        (uint256 saleId, uint256 tokenId) = _pauseCopy();
        bytes32 outcome = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://late-outcome"
        );
        vm.warp(block.timestamp + 6 days);
        bytes memory late = abi.encodeCall(auction.cancel, (saleId, outcome));
        _schedule(hotAdmin, address(auction), late);
        vm.warp(block.timestamp + 2 days);
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ENDED
            )
        );
        manager.execute(address(auction), late);
    }

    /// @dev A rejected dispute (or none within 7 days): the high bidder may withdraw while
    ///      paused, and the auction resumes with its remaining time.
    function test_RejectedDisputeResumesTheAuction() public {
        (uint256 saleId, uint256 tokenId) = _pauseCopy();
        IEnglishAuction.Auction memory paused = auction.auction(saleId);
        uint256 remaining = paused.endTime - paused.pausedAt;
        vm.prank(bidder);
        auction.withdrawBid(saleId);
        assertEq(auction.claimable(bidder, CURRENCY_ETH), 1 ether);

        _govern(hotAdmin, address(auction), abi.encodeCall(auction.resume, (saleId)));
        IEnglishAuction.Auction memory resumed = auction.auction(saleId);
        assertEq(uint8(resumed.state), uint8(IEnglishAuction.AuctionState.ACTIVE));
        // LIFECYCLE-1: the bid was withdrawn, so at least the full duration.
        uint256 left = remaining > AUCTION_DURATION ? remaining : AUCTION_DURATION;
        assertEq(resumed.endTime, block.timestamp + left, "the remaining time, or the duration");
        assertEq(auction.minimumBid(saleId), 1 ether, "the withdrawn bid is the reserve");
        _ethBid(saleId, makeAddr("lateBidder"), 2 ether);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), makeAddr("lateBidder"));
    }

    /// @dev After a sale a dispute only produces a statement: nothing is confiscated.
    function test_DisputeAfterASaleIsAStatementOnly() public {
        uint256 tokenId = _sell(copierRoot, _package(copierRoot), 1, bidder, 1 ether);
        bytes32 outcome = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://after-sale-outcome"
        );
        assertEq(stream.ownerOf(tokenId), bidder, "nothing is confiscated");
        assertTrue(_contains(stream.tokenURI(tokenId), Strings.toHexString(uint256(outcome), 32)));
        (, uint256 royalty) = stream.royaltyInfo(tokenId, 1 ether);
        assertEq(royalty, 0.06529 ether, "royalties unchanged");
    }

    /// @dev The emergency pause (PAUSER, held by the guardians) blocks new starts only; bids on
    ///      live auctions continue. Unpausing is UNPAUSER's, in the 48-hour class.
    function test_EmergencyPauseBlocksStartsNotBids() public {
        (uint256 saleId,) = _start(copierRoot, _package(copierRoot), 1);
        vm.prank(guardian3);
        auction.pause();
        bytes memory data = _mintData(copierRoot, _package(copierRoot), 0);
        vm.expectRevert(ISaleAdapter.SalePaused.selector);
        auction.start(address(stream), data);
        _ethBid(saleId, bidder, 1 ether);
        _govern(hotAdmin, address(auction), abi.encodeCall(auction.unpause, ()));
        auction.start(address(stream), data);
    }

    /// @dev The upheld path up to the burn of the copier's work.
    function _upheldBurn() internal returns (uint256 tokenId) {
        uint256 saleId;
        (saleId, tokenId) = _pauseCopy();
        bytes32 outcome = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://dispute-upheld"
        );
        _govern(hotAdmin, address(auction), abi.encodeCall(auction.cancel, (saleId, outcome)));
    }

    /// @dev PARAMETER_SETTER's governed release (48 hours, like the cancel) to the rightful artist.
    function _release(uint256 tokenId) internal {
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(
                stream.releaseContent, (tokenId, contentHash, artists.artistIdOf(rightful))
            )
        );
    }

    /// @dev SIGS-1 / LIFECYCLE-2: the copier holds a second approved copy of the content (same
    ///      media, another record). Once the upheld dispute burns the first, the release reserves
    ///      the content for the rightful artist the outcome names, so the copy cannot take it in
    ///      the same block, while the rightful artist's item consumes.
    function test_ReleasedContentIsReservedForTheNamedArtist() public {
        Work memory sibling = _work(copier, collectionId);
        Work memory original = _package(rightfulRoot)[0];
        sibling.media = original.media;
        sibling.item.contentHash = contentHash;
        sibling.item.mediaHash = original.item.mediaHash;
        bytes32 siblingRoot = _publish(_one(sibling));
        uint256 tokenId = _upheldBurn();
        _release(tokenId);

        uint256 rightfulId = artists.artistIdOf(rightful);
        bytes memory copy = _mintData(siblingRoot, _one(sibling), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ContentReserved.selector, contentHash, rightfulId
            )
        );
        auction.start(address(stream), copy);

        (, uint256 rightfulToken) = _start(rightfulRoot, _package(rightfulRoot), 0);
        assertEq(stream.artistOf(rightfulToken), rightfulId);
        assertEq(
            registry.consumedItemOf(contentHash),
            WorksHashing.itemHash(original.item),
            "the rightful artist's item holds the content"
        );
    }

    /// @dev The release is a governed action, not first come: nobody else may call it, it must
    ///      name an artist, and it happens once per burned token.
    function test_ReleaseIsGovernedNamesAnArtistAndHappensOnce() public {
        uint256 tokenId = _upheldBurn();
        uint256 rightfulId = artists.artistIdOf(rightful);
        address[2] memory strangers = [copier, makeAddr("anyone")];
        for (uint256 i; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManaged.AccessManagedUnauthorized.selector, strangers[i]
                )
            );
            stream.releaseContent(tokenId, contentHash, rightfulId);
        }
        (, uint32 delay) =
            manager.canCall(hotAdmin, address(stream), stream.releaseContent.selector);
        assertEq(delay, 48 hours, "the upheld-dispute class");

        // A release must name a registered artist: zero, or an ID nobody registered (here one
        // derived from an address the rightful artist never uses), is refused.
        uint256[2] memory unregistered =
            [uint256(0), uint160(makeAddr("an address the artist never registers"))];
        for (uint256 i; i < unregistered.length; ++i) {
            bytes memory unnamed =
                abi.encodeCall(stream.releaseContent, (tokenId, contentHash, unregistered[i]));
            _schedule(hotAdmin, address(stream), unnamed);
            vm.warp(block.timestamp + 48 hours);
            vm.prank(hotAdmin);
            vm.expectRevert(
                abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, unregistered[i])
            );
            manager.execute(address(stream), unnamed);
        }

        bytes memory named =
            abi.encodeCall(stream.releaseContent, (tokenId, contentHash, rightfulId));
        _schedule(hotAdmin, address(stream), named);
        vm.warp(block.timestamp + 48 hours);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IPackageRegistry.ContentReleased(
            contentHash, WorksHashing.itemHash(_package(copierRoot)[0].item), rightfulId
        );
        vm.prank(hotAdmin);
        manager.execute(address(stream), named);

        bytes memory again = abi.encodeCall(
            stream.releaseContent, (tokenId, contentHash, artists.artistIdOf(copier))
        );
        _schedule(hotAdmin, address(stream), again);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ClaimNotAllowed.selector, PRODUCT_STREAM, contentHash
            )
        );
        manager.execute(address(stream), again);
        assertEq(registry.releasedTo(contentHash), rightfulId, "the first release stands");
    }

    /// @dev DEPS-1 with SIGS-1: a VRF work keeps its one seed through an upheld dispute. The
    ///      rightful artist's VRF item cannot request while the content is consumed; after the
    ///      release it joins the content's delivered draw, with no new request, and starts.
    function test_TheRightfulVrfItemReadsTheContentsSeed() public {
        Work memory original = _work(rightful, collectionId);
        original.item.seedPolicy = SeedPolicy.VRF;
        Work memory copy = _work(copier, collectionId);
        copy.media = original.media;
        copy.item.contentHash = original.item.contentHash;
        copy.item.mediaHash = original.item.mediaHash;
        copy.item.seedPolicy = SeedPolicy.VRF;
        bytes32 copyRoot = _publish(_one(copy));
        bytes32 originalRoot = _publish(_one(original));
        bytes32[] memory none = new bytes32[](0);
        coordinator.fulfill(entropy.requestSeed(copy.item, copyRoot, none), 77);

        (uint256 saleId, uint256 tokenId) = _start(copyRoot, _one(copy), 0);
        bytes32 originalItem = WorksHashing.itemHash(original.item);
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.NotRequestable.selector, originalItem)
        );
        entropy.requestSeed(original.item, originalRoot, none);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("disputes wave: copied media"));
        bytes32 outcome = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://vrf-dispute-upheld"
        );
        _govern(hotAdmin, address(auction), abi.encodeCall(auction.cancel, (saleId, outcome)));
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(
                stream.releaseContent,
                (tokenId, original.item.contentHash, artists.artistIdOf(rightful))
            )
        );

        uint256 nextId = coordinator.nextId();
        assertEq(entropy.requestSeed(original.item, originalRoot, none), 0, "joined");
        assertEq(coordinator.nextId(), nextId, "no second draw");
        assertEq(entropy.seedOf(originalItem), bytes32(uint256(77)));
        (, uint256 rightfulToken) = _start(originalRoot, _one(original), 0);
        assertEq(uint8(stream.work(rightfulToken).seedPolicy), uint8(SeedPolicy.VRF));
    }

    /// @dev A guardian vetoes a mistaken release during its delay.
    function test_AGuardianCancelsAPendingRelease() public {
        uint256 tokenId = _upheldBurn();
        bytes memory wrong = abi.encodeCall(
            stream.releaseContent, (tokenId, contentHash, artists.artistIdOf(copier))
        );
        _schedule(hotAdmin, address(stream), wrong);
        vm.prank(guardian1);
        manager.cancel(hotAdmin, address(stream), wrong);
        vm.warp(block.timestamp + 48 hours);
        bytes32 operation = manager.hashOperation(hotAdmin, address(stream), wrong);
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, operation)
        );
        manager.execute(address(stream), wrong);
        assertEq(registry.releasedTo(contentHash), 0);
    }

    /// @dev A PLATFORM dispute outcome on `(token, id)`, as `_platformStatement` builds it.
    function _outcome(address token, uint256 id) internal pure returns (Statement memory) {
        return Statement(
            token,
            id,
            StatementKinds.DISPUTE_OUTCOME,
            keccak256("6529-works/dispute-outcome/1"),
            HashRef(HASH_SHA256, keccak256("outcome")),
            "ar://outcome",
            bytes32(0),
            bytes32(0)
        );
    }

    function _shows(string memory metadata, bytes32 entry) internal pure returns (bool) {
        return _contains(
            metadata,
            string.concat(
                '{"trait_type":"Dispute statement","value":"',
                Strings.toHexString(uint256(entry), 32),
                '"}'
            )
        );
    }

    /// @dev LIFECYCLE-4: an outcome can name only a token that exists (not one not yet minted,
    ///      nor a burned one), and an edition's outcome goes on its master.
    function test_ADisputeOutcomeNamesAnExistingToken() public {
        uint256 nextId = stream.totalMinted() + 1;
        vm.prank(platform);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStatementLog.UnknownDisputeSubject.selector, address(stream), nextId
            )
        );
        statements.appendPlatform(_outcome(address(stream), nextId));

        uint256 burned = _upheldBurn();
        vm.prank(platform);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStatementLog.UnknownDisputeSubject.selector, address(stream), burned
            )
        );
        statements.appendPlatform(_outcome(address(stream), burned));

        vm.prank(platform);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStatementLog.UnknownDisputeSubject.selector, address(editions), burned + 1
            )
        );
        statements.appendPlatform(_outcome(address(editions), burned + 1));
    }

    /// @dev LIFECYCLE-4 (a) and (b), inverted: an outcome recorded about an item before its
    ///      mint (subject `(address(0), itemHash)`) is shown on the work minted from it and on
    ///      that work's edition, until an outcome about the token itself takes precedence.
    function test_APreMintOutcomeShowsOnTheWorkAndItsEdition() public {
        Work memory w = _work(rightful, collectionId);
        w.item.kind = ItemKind.EDITION_MASTER;
        w.item.edition = EditionTerms(
            EditionFormat.FIXED, 10, 0, 0.01 ether, CURRENCY_ETH, SaleKind.FIXED_PRICE, ""
        );
        bytes32 masterRoot = _publish(_one(w));
        bytes32 preMint = _platformStatement(
            address(0),
            uint256(WorksHashing.itemHash(w.item)),
            StatementKinds.DISPUTE_OUTCOME,
            "ar://pre-mint-outcome"
        );
        uint256 tokenId = _sell(masterRoot, _one(w), 0, bidder, 1 ether);
        assertEq(statements.latestDisputeOutcome(address(stream), tokenId), preMint);
        (bytes32 own,) = statements.disputeOutcomeOf(address(stream), tokenId);
        assertEq(own, bytes32(0), "no outcome about the token itself");
        assertTrue(_shows(stream.tokenURI(tokenId), preMint), "(a) on the work");
        editions.createEdition(tokenId, w.item, masterRoot, _proofOf(_one(w), 0));
        assertTrue(_shows(editions.uri(tokenId), preMint), "(b) on its edition");

        // An outcome about the token is the work's current status from then on.
        bytes32 later = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://token-outcome"
        );
        assertEq(statements.latestDisputeOutcome(address(stream), tokenId), later);
        (own,) = statements.disputeOutcomeOf(address(stream), tokenId);
        assertEq(own, later);
        assertTrue(_shows(stream.tokenURI(tokenId), later));
        assertTrue(_shows(editions.uri(tokenId), later));
        assertFalse(_shows(stream.tokenURI(tokenId), preMint));
    }

    function _payment(uint256 amount) internal view returns (Payment memory) {
        return Payment(PaymentMethod.DIRECT, bidder, amount, 0, 0, "");
    }
}
