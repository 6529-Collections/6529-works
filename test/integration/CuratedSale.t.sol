// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEnglishAuctionRefusal } from "src/interfaces/IEnglishAuctionRefusal.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { Facts, Outcome, Work as StoredWork } from "src/interfaces/core/CoreTypes.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { SaleStarter } from "src/sales/SaleStarter.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { ContractWallet, SaleFlowBase } from "./SaleFlowBase.sol";

/// @notice A curated 6529 Stream 1/1 on the deployed stack, from content to collector: the
///         primary file stored in the content store, the package attested by a curation signer
///         and registered, every party's acceptance, the lead artist's move signature, the start
///         (directly, through `SaleStarter`, or with a first bid), bids, outbid credits, the
///         anti-snipe extension, settlement (the buyer owns the work, the seller vault and the fee
///         vault are paid their exact parts, Stream logs the sale), the seller vault's release to
///         the artist and the collaborator, `royaltyInfo` against the terms the resolver derives,
///         a pending delivery for a winner that cannot take the token, and single use.
contract CuratedSaleTest is SaleFlowBase {
    address internal artist;
    address internal collaborator;
    address internal bidder1 = makeAddr("bidder1");
    address internal bidder2 = makeAddr("bidder2");
    bytes32 internal root;
    /// @dev The stored primary file of item 0.
    bytes32 internal storedFile;

    function setUp() public override {
        super.setUp();
        artist = _actor("artist");
        collaborator = _actor("collaborator");
        bytes memory media = _bytes(30_000, 1);
        Work[] memory works = new Work[](3);
        works[0] = _storedWork(
            artist, media, IContentStore.Encoding.Identity, sha256(media), "Stored work"
        );
        storedFile = works[0].media[0].fileId;
        works[0] = _collab(works[0], collaborator, 20_000);
        works[1] = _collab(_work(artist, collectionId), collaborator, 20_000);
        works[2] = _collab(_work(artist, collectionId), collaborator, 20_000);
        root = _publish(works);
        _keep(root, works);
    }

    // ------------------------------------------------------------------ the package

    function test_CuratedSale_ContentStoredPackageApprovedAndAccepted() public view {
        assertTrue(store.isComplete(storedFile), "the primary file is stored whole");
        assertEq(store.sha256Of(storedFile), _package(root)[0].item.contentHash);
        (IPackageRegistry.PackageStatus status, bytes32 evidence, address signer) =
            registry.packageOf(root);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.APPROVED));
        assertEq(evidence, _evidence(root));
        assertEq(signer, signer1, "the attesting curation signer");
        assertEq(registry.acceptedAs(root, artist), uint160(artist), "first acceptance: the ID");
        assertEq(registry.acceptedAs(root, collaborator), uint160(collaborator));
        assertEq(accounts.artistIdOf(artist), uint160(artist));
    }

    // ------------------------------------------------------------------ start, bid, settle

    function test_CuratedSale_StartBidAntiSnipeSettleAndRelease() public {
        Work[] memory works = _package(root);
        WorkTerms memory t = _terms(works[0]);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);
        assertEq(stream.ownerOf(tokenId), address(auction), "minted into the auction's custody");
        assertEq(stream.itemHashOf(tokenId), WorksHashing.itemHash(works[0].item));
        assertEq(stream.tokenOfContent(works[0].item.contentHash), tokenId);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.endTime, block.timestamp + AUCTION_DURATION, "the 24-hour clock");
        assertEq(a.seller, t.seller, "the seller vault the resolver names");
        assertEq(a.feeShare, t.feeShare);

        _bidsAndAntiSnipe(saleId, a.endTime);

        uint256 price = 2 ether;
        uint256 fee = _fee(price, t.feeShare);
        vm.warp(auction.auction(saleId).endTime);
        vm.expectEmit(address(stream));
        emit IStream.PrimarySale(tokenId, Outcome.SOLD, bidder1, price);
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), bidder1, "the buyer owns the work");
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.SOLD));
        assertEq(t.seller.balance, price - fee, "the seller vault's exact part");
        assertEq(networkFee.balance, fee, "the fee vault's exact part");
        assertGt(fee, 0, "the network takes a share at genesis");
        assertEq(address(auction).balance, 2.35 ether, "only bidder2's credit stays");

        _claimRefund(bidder2, 2.35 ether);
        _releaseSellerVault(works[0], t, price - fee);
        _checkRoyalty(tokenId, t);
    }

    /// @dev The opening bid, the increment, an outbid credit and the anti-snipe extension.
    function _bidsAndAntiSnipe(uint256 saleId, uint64 endTime) internal {
        vm.deal(bidder1, 10 ether);
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, OPENING_BID, 0));
        auction.bid(saleId, address(0));
        _ethBid(saleId, bidder1, 1 ether);
        assertEq(auction.minimumBid(saleId), 1.05 ether, "5% increment");
        vm.deal(bidder2, 10 ether);
        vm.prank(bidder2);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, 1.05 ether, 1.04 ether)
        );
        auction.bid{ value: 1.04 ether }(saleId, address(0));
        _ethBid(saleId, bidder2, 1.05 ether);
        assertEq(auction.claimable(bidder1), 1 ether, "the outbid bidder is credited");

        // A bid outside the last 15 minutes leaves the end alone.
        vm.warp(endTime - EXTENSION_WINDOW - 1);
        _ethBid(saleId, bidder1, 1.2 ether);
        assertEq(auction.auction(saleId).endTime, endTime, "no extension");
        // A bid in the last 15 minutes moves the end to 15 minutes after it.
        vm.warp(endTime - 5 minutes);
        _ethBid(saleId, bidder2, 1.3 ether);
        _ethBid(saleId, bidder1, 2 ether);
        assertEq(auction.auction(saleId).endTime, block.timestamp + EXTENSION_WINDOW);
        assertEq(auction.claimable(bidder1), 2.2 ether, "both outbid bids credited");
        assertEq(auction.claimable(bidder2), 2.35 ether);
        _claimRefund(bidder1, 2.2 ether);

        // At the first end the auction still runs.
        vm.warp(endTime);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ACTIVE
            )
        );
        auction.settle(saleId);
    }

    function _claimRefund(address bidder, uint256 expected) internal {
        uint256 before = bidder.balance;
        vm.prank(bidder);
        assertEq(auction.claim(bidder), expected);
        assertEq(bidder.balance - before, expected, "refund pulled");
        assertEq(auction.claimable(bidder), 0);
    }

    /// @dev Anyone deploys the seller vault at the address the sale paid; each artist-resolved
    ///      payee pulls its share, and nobody else can move it.
    function _releaseSellerVault(Work memory w, WorkTerms memory t, uint256 proceeds) internal {
        ISplitWallet.Payee[] memory payees = w.item.payees;
        assertEq(ledger.createWallet(payees, bytes32(0)), t.seller, "predicted = deployed");
        uint256 artistIndex = _indexOf(payees, artist);
        uint256 collabIndex = _indexOf(payees, collaborator);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, stranger, artist)
        );
        ledger.release(payees, bytes32(0), address(0), artistIndex);

        vm.prank(artist);
        ledger.release(payees, bytes32(0), address(0), artistIndex);
        assertEq(artist.balance, proceeds * 80_000 / DENOMINATOR, "80% to the artist");
        vm.prank(collaborator);
        ledger.release(payees, bytes32(0), address(0), collabIndex);
        assertEq(collaborator.balance, proceeds * 20_000 / DENOMINATOR, "20% to the collaborator");
        assertLe(t.seller.balance, 1, "at most rounding dust stays");
    }

    /// @dev ERC-2981 answers the receiver and rate the resolver derived at the start.
    function _checkRoyalty(uint256 tokenId, WorkTerms memory t) internal view {
        StoredWork memory sw = stream.workOf(tokenId);
        assertEq(sw.royaltyReceiver, t.royaltyReceiver);
        assertEq(sw.royaltyRate, t.royaltyRate);
        assertTrue(t.royaltyReceiver != t.seller, "a royalty vault while the network takes a share");
        assertEq(
            t.royaltyReceiver, ledger.walletFor(_royaltyPayees(t), bytes32(0)), "the royalty vault"
        );
        (address receiver, uint256 amount) = stream.royaltyInfo(tokenId, 10 ether);
        assertEq(receiver, t.royaltyReceiver);
        assertEq(amount, 10 ether * uint256(t.royaltyRate) / DENOMINATOR);
        assertGt(amount, 0);
    }

    /// @dev `SaleStarter`: the auction starts, the seller and royalty vaults are deployed and the
    ///      record is opened in one transaction.
    function test_CuratedSale_StartThroughSaleStarterDeploysVaultsAndOpensTheRecord() public {
        Work[] memory works = _package(root);
        WorkTerms memory t = _terms(works[0]);
        assertFalse(ledger.isWallet(t.seller));
        (uint256 saleId, uint256 tokenId) = _startAndOpen(root, works, 0);
        assertEq(stream.ownerOf(tokenId), address(auction));
        assertTrue(ledger.isWallet(t.seller), "the seller vault is deployed");
        assertTrue(ledger.isWallet(t.royaltyReceiver), "the royalty vault is deployed");
        Facts memory f = facts.factsOf(address(stream), tokenId);
        assertTrue(f.opened, "the record is open");
        assertEq(f.media.length, 1);
        assertEq(f.media[0].fileId, storedFile);
        assertEq(f.recordFileId, works[0].item.recordFileId);

        _ethBid(saleId, bidder1, 1 ether);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), bidder1);
        uint256 fee = _fee(1 ether, t.feeShare);
        assertEq(t.seller.balance, 1 ether - fee, "paid to the deployed vault");
        vm.prank(artist);
        ledger.release(
            works[0].item.payees, bytes32(0), address(0), _indexOf(works[0].item.payees, artist)
        );
        assertEq(artist.balance, (1 ether - fee) * 80_000 / DENOMINATOR);
    }

    /// @dev `SaleStarter` is all or nothing: when the factory returns a seller vault other than
    ///      the one the work's terms name, the whole start reverts and no work is minted.
    function test_CuratedSale_SaleStarterRefusesASellerVaultTheTermsDoNotName() public {
        Work[] memory works = _package(root);
        address factory = economics.splitFactory();
        address wrong = makeAddr("another vault");
        vm.mockCall(
            factory,
            abi.encodeCall(ISplitFactory.createWallet, (works[0].item.payees, bytes32(0))),
            abi.encode(wrong)
        );
        uint256 minted = stream.totalMinted();
        bytes memory request = _mintData(root, works, 0);
        vm.expectRevert(abi.encodeWithSelector(SaleStarter.VaultMismatch.selector, wrong));
        starter.start(auction, address(stream), request, works[0].media);
        assertEq(stream.totalMinted(), minted, "nothing minted");

        // With the factory answering for itself the same request starts.
        vm.clearMockedCalls();
        starter.start(auction, address(stream), request, works[0].media);
        assertEq(stream.totalMinted(), minted + 1);
    }

    /// @dev The same for the royalty vault: the factory's vault for the seller vault and the fee
    ///      recipient must be the receiver the minted work records.
    function test_CuratedSale_SaleStarterRefusesARoyaltyVaultTheWorkDoesNotRecord() public {
        Work[] memory works = _package(root);
        WorkTerms memory t = _terms(works[0]);
        assertTrue(t.royaltyReceiver != t.seller, "a royalty vault of its own");
        address factory = economics.splitFactory();
        address wrong = makeAddr("another vault");
        vm.mockCall(
            factory,
            abi.encodeCall(ISplitFactory.createWallet, (_royaltyPayees(t), bytes32(0))),
            abi.encode(wrong)
        );
        uint256 minted = stream.totalMinted();
        bytes memory request = _mintData(root, works, 0);
        vm.expectRevert(abi.encodeWithSelector(SaleStarter.VaultMismatch.selector, wrong));
        starter.start(auction, address(stream), request, works[0].media);
        assertEq(stream.totalMinted(), minted, "nothing minted");
        assertFalse(ledger.isWallet(t.seller), "no vault deployed");
    }

    function test_CuratedSale_StartWithBidRecordsTheFirstBid() public {
        Work[] memory works = _package(root);
        bytes memory data = _mintData(root, works, 1);
        address recipient = makeAddr("recipient");
        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, OPENING_BID, 0.01 ether)
        );
        auction.startWithBid{ value: 0.01 ether }(address(stream), data, recipient);
        vm.prank(bidder1);
        uint256 saleId = auction.startWithBid{ value: 0.5 ether }(address(stream), data, recipient);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.bidder, bidder1);
        assertEq(a.recipient, recipient, "the bid's recipient");
        assertEq(a.bid, 0.5 ether);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(a.tokenId), recipient, "delivered to the named recipient");
    }

    // ------------------------------------------------------------------ delivery

    /// @dev Settlement never waits on the winner taking the token: a winner that cannot receive
    ///      it leaves a pending delivery, and names where it goes later.
    function test_CuratedSale_WinnerThatRefusesTheTokenGetsAPendingDelivery() public {
        ContractWallet winner = new ContractWallet();
        (uint256 saleId, uint256 tokenId) = _start(root, _package(root), 2);
        _walletBid(winner, saleId, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.DeliveryPending(saleId, address(winner));
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), address(auction), "still in custody");
        assertEq(auction.pendingDelivery(saleId), address(winner));
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.SOLD), "settled all the same");

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        auction.claimDelivery(saleId, makeAddr("stranger"));
        address vault = makeAddr("winnerVault");
        winner.exec(address(auction), 0, abi.encodeCall(auction.claimDelivery, (saleId, vault)));
        assertEq(stream.ownerOf(tokenId), vault);
        assertEq(auction.pendingDelivery(saleId), address(0));
    }

    /// @dev A 6529 Stream sale is never closed as refused: settlement is the only exit.
    function test_CuratedSale_AStreamSaleCannotBeRefused() public {
        (uint256 saleId,) = _start(root, _package(root), 2);
        _ethBid(saleId, bidder1, 1 ether);
        vm.warp(auction.auction(saleId).endTime + 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuctionRefusal.SaleNotRefusable.selector, saleId)
        );
        auction.settleOrRefund(saleId);
    }

    // ------------------------------------------------------------------ single use

    /// @dev An item starts once: neither a second start of it, through any root, nor of another
    ///      item with its content, after the sale settled.
    function test_CuratedSale_TheItemCanNeverStartAgain() public {
        Work[] memory works = _package(root);
        bytes32 contentHash = works[1].item.contentHash;
        (uint256 saleId, uint256 tokenId) = _start(root, works, 1);
        bytes memory again = _mintData(root, works, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, contentHash, tokenId)
        );
        auction.start(address(stream), again);

        _ethBid(saleId, bidder1, 1 ether);
        _settleAtEnd(saleId);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, contentHash, tokenId)
        );
        auction.start(address(stream), again);

        // The same item approved again in another package.
        Work[] memory relisted = _one(works[1]);
        bytes32 otherRoot = _publish(relisted);
        bytes memory viaOther = _mintData(otherRoot, relisted, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, contentHash, tokenId)
        );
        auction.start(address(stream), viaOther);
        assertEq(stream.totalMinted(), tokenId, "nothing more was minted");
        assertEq(registry.consumedItemOf(contentHash), WorksHashing.itemHash(works[1].item));
    }

    /// @dev The lead artist can revoke a move signature before anyone uses it.
    function test_CuratedSale_MoveSignatureIsRevocable() public {
        Work[] memory works = _package(root);
        uint256 artistId = uint160(artist);
        bytes memory data = _mintDataSignedBy(root, works, 0, artist, 5);
        vm.prank(artist);
        registry.revokeMove(artistId, 5);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.MoveNonceUsed.selector, artistId, 5)
        );
        auction.start(address(stream), data);
    }

    /// @dev The network revokes an approved root at once: its items stop starting.
    function test_CuratedSale_RevokedPackageStopsStarting() public {
        Work[] memory works = _package(root);
        bytes memory data = _mintData(root, works, 0);
        _asNetwork(
            address(registry), abi.encodeCall(registry.revokePackage, (root, keccak256("reason")))
        );
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        auction.start(address(stream), data);
    }
}
