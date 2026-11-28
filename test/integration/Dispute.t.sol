// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { SaleFlowBase } from "./SaleFlowBase.sol";

/// @notice A dispute on the deployed stack. A copier's package, claiming the rightful artist's
///         media, reaches auction; a pauser key pauses the sale with a dispute reference; the high
///         bidder may withdraw while it is paused; PLATFORM records the outcome statement, which
///         the renderer shows; the network cancels the sale citing that statement (the bid is
///         credited back, the token burned, its ID never reused); the network releases the
///         content to the rightful artist, whose item then mints while every other copy is
///         refused. A rejected dispute resumes the sale with its clock extended; a pause that runs
///         its 3 days lapses by itself; a dispute after a sale only adds a statement.
contract DisputeTest is SaleFlowBase {
    address internal rightful;
    address internal copier;
    address internal bidder = makeAddr("disputeBidder");
    bytes32 internal copierRoot;
    bytes32 internal rightfulRoot;
    bytes32 internal contentHash;
    bytes32 internal constant DISPUTE_REF = keccak256("disputes wave: copied media");

    function setUp() public override {
        super.setUp();
        rightful = _actor("rightfulArtist");
        copier = _actor("copier");
        Work memory original = _work(rightful, collectionId);
        Work[] memory copies = new Work[](2);
        copies[0] = _copyOf(original);
        copies[1] = _work(copier, collectionId); // the copier's other work, sold normally
        contentHash = original.item.contentHash;
        copierRoot = _publish(copies);
        _keep(copierRoot, copies);
        rightfulRoot = _publish(_one(original));
        _keep(rightfulRoot, _one(original));
    }

    /// @dev A work by the copier with `original`'s media (same content and media hash) and its
    ///      own record.
    function _copyOf(Work memory original) internal returns (Work memory copy) {
        copy = _work(copier, collectionId);
        copy.media = original.media;
        copy.item.contentHash = original.item.contentHash;
        copy.item.mediaHash = original.item.mediaHash;
    }

    function _pause(uint256 saleId) internal {
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionPaused(saleId, DISPUTE_REF);
        _govern(
            pauser1,
            address(auction),
            abi.encodeWithSignature("pause(uint256,bytes32)", saleId, DISPUTE_REF)
        );
    }

    /// @dev Starts the copy, takes a 1 ETH bid and pauses the sale two hours in.
    function _pauseCopy() internal returns (uint256 saleId, uint256 tokenId) {
        (saleId, tokenId) = _start(copierRoot, _package(copierRoot), 0);
        _ethBid(saleId, bidder, 1 ether);
        vm.warp(block.timestamp + 2 hours);
        _pause(saleId);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.PAUSED));
    }

    function _outcome(uint256 tokenId, string memory uri) internal returns (bytes32) {
        return _platformStatement(address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, uri);
    }

    function _cancel(uint256 saleId, bytes32 outcome) internal {
        _asNetwork(address(auction), abi.encodeCall(auction.cancel, (saleId, outcome)));
    }

    /// @dev The network's release (PARAMETER_SETTER, 24 hours) of the burned token's content.
    function _release(uint256 tokenId, uint256 beneficiary) internal {
        _asNetwork(
            address(registry),
            abi.encodeCall(
                registry.releaseContent, (address(stream), tokenId, contentHash, beneficiary)
            )
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

    /// @dev The upheld path up to the burn of the copier's work.
    function _upheldBurn() internal returns (uint256 tokenId) {
        uint256 saleId;
        (saleId, tokenId) = _pauseCopy();
        _cancel(saleId, _outcome(tokenId, "ar://dispute-upheld"));
    }

    // ------------------------------------------------------------------ upheld

    function test_Dispute_UpheldCancelBurnsReleasesAndTheRightfulArtistMints() public {
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
        auction.bid{ value: 2 ether }(saleId, address(0));

        // PLATFORM records the outcome; the renderer shows it.
        bytes32 outcome = _outcome(tokenId, "ar://dispute-outcome-upheld");
        assertEq(statements.latestDisputeOutcome(address(stream), tokenId), outcome);
        assertTrue(_shows(stream.tokenURI(tokenId), outcome), "the renderer shows the statement");

        // A cancel citing anything but the recorded outcome fails.
        bytes32 wrong = keccak256("not the outcome");
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.OutcomeNotRecorded.selector, saleId, wrong)
        );
        auction.cancel(saleId, wrong);

        vm.expectEmit(address(auction));
        emit IEnglishAuction.Credited(bidder, address(0), saleId, 1 ether);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionCancelled(saleId, outcome);
        _cancel(saleId, outcome);
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        assertEq(auction.claimable(bidder), 1 ether, "the bid is credited back");
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId)
        );
        stream.ownerOf(tokenId);
        assertEq(stream.totalSupply(), stream.totalMinted() - 1, "a gap: the ID is never reused");
        assertEq(
            stream.workOf(tokenId).itemHash, WorksHashing.itemHash(_package(copierRoot)[0].item)
        );

        // Before the release the content is not free, for anyone.
        bytes memory early = _mintData(rightfulRoot, _package(rightfulRoot), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, contentHash, tokenId)
        );
        auction.start(address(stream), early);

        // The network releases the content to the rightful artist; the copier's item is barred.
        uint256 rightfulId = accounts.artistIdOf(rightful);
        bytes memory release = abi.encodeCall(
            registry.releaseContent, (address(stream), tokenId, contentHash, rightfulId)
        );
        vm.prank(network);
        manager.schedule(address(registry), release, 0);
        vm.warp(block.timestamp + 24 hours);
        vm.expectEmit(address(registry));
        emit IMintPolicy.ContentReleased(address(stream), tokenId, contentHash, rightfulId);
        vm.prank(network);
        manager.execute(address(registry), release);
        assertEq(registry.releasedTo(address(stream), contentHash), rightfulId);
        assertEq(registry.consumedItemOf(contentHash), bytes32(0));
        bytes32 copierItem = WorksHashing.itemHash(_package(copierRoot)[0].item);
        assertTrue(registry.isBarred(copierItem));

        // The rightful artist's item mints, as a new token.
        (, uint256 rightfulToken) = _start(rightfulRoot, _package(rightfulRoot), 0);
        assertEq(rightfulToken, tokenId + 1);
        assertEq(stream.workOf(rightfulToken).artistId, rightfulId);
        assertEq(registry.releasedTo(address(stream), contentHash), 0, "the release is used up");
        assertEq(
            registry.consumedItemOf(contentHash),
            WorksHashing.itemHash(_package(rightfulRoot)[0].item)
        );

        // The copier's item never mints again, through any root.
        bytes memory again = _mintData(copierRoot, _package(copierRoot), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, contentHash, rightfulToken)
        );
        auction.start(address(stream), again);

        vm.prank(bidder);
        auction.claim(bidder);
        assertEq(bidder.balance, 3 ether, "the refund pulled");
    }

    /// @dev After the release, another copy of the content (the copier's second package) is
    ///      reserved out, and the burned item itself is barred.
    function test_Dispute_ReleasedContentIsReservedForTheNamedArtist() public {
        Work memory sibling = _copyOf(_package(rightfulRoot)[0]);
        bytes32 siblingRoot = _publish(_one(sibling));
        uint256 tokenId = _upheldBurn();
        uint256 rightfulId = accounts.artistIdOf(rightful);
        _release(tokenId, rightfulId);

        bytes memory copy = _mintData(siblingRoot, _one(sibling), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.ContentReserved.selector, contentHash, rightfulId)
        );
        auction.start(address(stream), copy);
        bytes memory burned = _mintData(copierRoot, _package(copierRoot), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, contentHash, tokenId)
        );
        auction.start(address(stream), burned);

        (, uint256 rightfulToken) = _start(rightfulRoot, _package(rightfulRoot), 0);
        assertEq(stream.workOf(rightfulToken).artistId, rightfulId);
    }

    /// @dev The release is the network's, names a registered artist and a burned token.
    function test_Dispute_ReleaseIsGovernedAndNamesARegisteredArtistAndABurnedToken() public {
        (uint256 saleId, uint256 tokenId) = _pauseCopy();
        uint256 rightfulId = accounts.artistIdOf(rightful);

        // A live token's content cannot be released.
        bytes memory live = abi.encodeCall(
            registry.releaseContent, (address(stream), tokenId, contentHash, rightfulId)
        );
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, contentHash, tokenId)
        );
        this.asNetworkExternal(address(registry), live);

        _cancel(saleId, _outcome(tokenId, "ar://upheld"));
        vm.prank(copier);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, copier)
        );
        registry.releaseContent(address(stream), tokenId, contentHash, rightfulId);
        (, uint32 delay) =
            manager.canCall(network, address(registry), registry.releaseContent.selector);
        assertEq(delay, 24 hours, "the PARAMETER_SETTER class");

        uint256 nobody = uint160(makeAddr("never registered"));
        bytes memory unnamed = abi.encodeCall(
            registry.releaseContent, (address(stream), tokenId, contentHash, nobody)
        );
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, nobody));
        this.asNetworkExternal(address(registry), unnamed);
        assertEq(registry.releasedTo(address(stream), contentHash), 0);
    }

    /// @dev External, so `vm.expectRevert` sees a governed call's revert at this depth.
    function asNetworkExternal(address target, bytes calldata data) external {
        _asNetwork(target, data);
    }

    /// @dev The cancel cites an outcome recorded after the pause: one recorded before cannot
    ///      cancel the sale.
    function test_Dispute_CancelNeedsAnOutcomeRecordedAfterThePause() public {
        (uint256 saleId, uint256 tokenId) = _start(copierRoot, _package(copierRoot), 0);
        bytes32 early = _outcome(tokenId, "ar://before-the-pause");
        _pause(saleId);
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.OutcomeNotRecorded.selector, saleId, early)
        );
        auction.cancel(saleId, early);
        _cancel(saleId, _outcome(tokenId, "ar://after-the-pause"));
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
    }

    // ------------------------------------------------------------------ rejected or lapsed

    /// @dev A rejected dispute: the high bidder withdraws while paused, and the network resumes
    ///      the sale with its clock extended to at least the full duration.
    function test_Dispute_WithdrawWhilePausedThenResumeAfterARejectedDispute() public {
        (uint256 saleId, uint256 tokenId) = _pauseCopy();
        IEnglishAuction.Auction memory paused = auction.auction(saleId);
        uint256 remaining = paused.endTime - paused.pausedAt;
        assertEq(remaining, AUCTION_DURATION - 2 hours);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NotHighBidder.selector, stranger));
        auction.withdrawBid(saleId);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.BidWithdrawn(saleId, bidder, 1 ether);
        vm.prank(bidder);
        auction.withdrawBid(saleId);
        assertEq(auction.claimable(bidder), 1 ether);

        vm.warp(block.timestamp + 1 days);
        _asNetwork(address(auction), abi.encodeCall(auction.resume, (saleId)));
        IEnglishAuction.Auction memory resumed = auction.auction(saleId);
        assertEq(uint8(resumed.state), uint8(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(resumed.endTime, block.timestamp + AUCTION_DURATION, "extended to the duration");
        assertGt(resumed.endTime, paused.endTime + 1 days, "longer than the pause alone");
        assertEq(auction.minimumBid(saleId), 1 ether, "the withdrawn bid is the reserve");

        // One pause per sale.
        vm.prank(pauser1);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.PauseExhausted.selector, saleId));
        auction.pause(saleId, DISPUTE_REF);

        address late = makeAddr("lateBidder");
        _ethBid(saleId, late, 1 ether);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), late);
    }

    /// @dev With no call within 3 days the pause lapses: the sale runs again with its clock
    ///      extended, and the network can no longer cancel it.
    function test_Dispute_APauseLapsesAfterThreeDays() public {
        (uint256 saleId, uint256 tokenId) = _pauseCopy();
        uint256 pausedAt = block.timestamp;
        bytes32 outcome = _outcome(tokenId, "ar://late-outcome");
        vm.warp(pausedAt + 3 days);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.PAUSED));
        vm.warp(pausedAt + 3 days + 1);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.ACTIVE), "lapsed");
        assertEq(a.endTime, pausedAt + 3 days + AUCTION_DURATION, "extended");
        assertEq(a.pausedAt, 0);

        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ACTIVE
            )
        );
        auction.cancel(saleId, outcome);
        _ethBid(saleId, makeAddr("next"), 2 ether);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), makeAddr("next"));
        assertEq(auction.claimable(bidder), 1 ether, "the outbid bid credited");
    }

    // ------------------------------------------------------------------ statements

    /// @dev After a sale a dispute only produces a statement: nothing is confiscated, and the
    ///      renderer shows the statement.
    function test_Dispute_AfterASaleIsAStatementOnly() public {
        uint256 tokenId = _sell(copierRoot, _package(copierRoot), 1, bidder, 1 ether);
        bytes32 outcome = _outcome(tokenId, "ar://after-sale-outcome");
        assertEq(stream.ownerOf(tokenId), bidder, "nothing is confiscated");
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.SOLD));
        assertTrue(_shows(stream.tokenURI(tokenId), outcome));
        (, uint256 royalty) = stream.royaltyInfo(tokenId, 1 ether);
        assertEq(royalty, 0.06529 ether, "royalties unchanged");
    }

    /// @dev An outcome names a token that exists: not one not yet minted, nor a burned one.
    function test_Dispute_AnOutcomeNamesAnExistingToken() public {
        uint256 burned = _upheldBurn();
        uint256 nextId = stream.totalMinted() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IStatementLog.UnknownDisputeSubject.selector, address(stream), nextId
            )
        );
        this.outcomeExternal(nextId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStatementLog.UnknownDisputeSubject.selector, address(stream), burned
            )
        );
        this.outcomeExternal(burned);
    }

    function outcomeExternal(uint256 tokenId) external {
        _outcome(tokenId, "ar://outcome");
    }
}
