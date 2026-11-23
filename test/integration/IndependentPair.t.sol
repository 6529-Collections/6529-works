// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Splits } from "src/economics/Splits.sol";
import { IndependentStreamEditions6529 } from "src/independent/IndependentStreamEditions6529.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { ITerms } from "src/interfaces/core/ITerms.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { IndependentIntegrationBase } from "./IndependentIntegrationBase.sol";

/// @notice An Independent Stream artist's pair end to end on the real deployed stack: deployed
///         through the genesis template deployers, listed with the artist's consent through the
///         Independent Stream module the directory names, an item approved with its collaborator's
///         consent to the royalty rate, minted through the Independent Stream module's `authorize`
///         by the English auction and sold; an unsold work stays in the auction's custody and
///         `restart` offers it again; delisting by contract and by account stops new mints; the
///         network's share is only ever lowered, for new works and, through the TERMS module, for
///         existing ones.
contract IndependentPairTest is IndependentIntegrationBase {
    address internal artist;
    address internal collab;
    address internal bidder;
    IndependentStream6529 internal fStream;
    IndependentStreamEditions6529 internal fEditions;

    function setUp() public override {
        super.setUp();
        artist = _actor("independentArtist");
        collab = _actor("independentCollaborator");
        bidder = makeAddr("independentBidder");
        (fStream, fEditions) = _listPair(artist);
    }

    // ------------------------------------------------------------------ listing

    function test_IndependentPair_ListedWithTheArtistsConsent() public view {
        uint256 artistId = uint256(uint160(artist));
        IIndependentStreamRegistry.Entry memory e = independentStream.entry(address(fStream));
        assertEq(uint8(e.form), uint8(IIndependentStreamRegistry.Form.ERC721));
        assertEq(e.partner, address(fEditions), "the editions name the 1/1 contract");
        assertEq(e.artistId, artistId);
        assertEq(e.feeShare, IND_SHARE, "the launch Independent Stream share, recorded at listing");
        assertEq(uint8(e.status), uint8(IIndependentStreamRegistry.Status.ACTIVE));
        assertEq(independentStream.entry(address(fEditions)).partner, address(fStream));
        assertEq(accounts.authorityOf(artistId), artist, "identity created at listing");
        assertTrue(fStream.isMinter(address(auction)), "the English auction mints the 1/1s");
        assertTrue(
            fEditions.isMinter(deployment.independentEditionAuction), "the edition auction mints"
        );
        assertEq(fStream.directory(), address(directory));
        assertEq(fStream.moduleOf(bytes32("TERMS")), address(terms), "shared TERMS module");
        assertEq(fStream.moduleOf(bytes32("RECORDS")), address(rules), "shared RECORDS module");
    }

    function test_IndependentPair_ListingRefusesAConsentByAnotherKey() public {
        address other = _actor("otherArtist");
        IndependentStream6529 token = _deployIndStream(other);
        IIndependentStreamRegistry.Join memory j =
            _joinOf(address(token), other, address(streamDeployer));
        // The consent is signed by a key that is not a wallet of the account.
        j.consent = abi.encodePacked(
            artist,
            _sign(
                artist,
                accounts.consentDigest(
                    address(independentStream),
                    independentStream.listingSubject(
                        address(token),
                        IIndependentStreamRegistry.Form.ERC721,
                        address(0),
                        IND_SHARE,
                        j.deadline
                    )
                )
            )
        );
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, artist));
        independentStream.register(address(token), j);
    }

    // ------------------------------------------------------------------ sale

    function test_IndependentPair_ACollaboratedWorkIsMintedAndSold() public {
        Work memory w = _withIndCollaborator(_fedWork(artist), collab, 30_000);
        _approveInd(address(fStream), artist, w, IND_RATE);
        bytes[] memory consents = new bytes[](1);
        consents[0] = _fedConsent(collab, address(fStream), w, IND_RATE);

        uint256 saleId = auction.start(address(fStream), _fedRequest(w, consents));
        uint256 tokenId = fStream.totalMinted();
        assertEq(fStream.ownerOf(tokenId), address(auction), "in the auction's custody");
        assertEq(fStream.itemHashOf(tokenId), _itemHash(w));
        assertEq(fStream.workOf(tokenId).artistId, uint256(uint160(artist)));
        assertEq(fStream.workOf(tokenId).royaltyRate, IND_RATE, "the approved rate");
        assertTrue(
            independentStream.itemOf(address(fStream), _itemHash(w)).used, "the item is consumed"
        );

        address seller = ledger.walletFor(w.item.payees, bytes32(0));
        address vault = ledger.walletFor(Splits.royaltyPayees(seller, networkFee, IND_SHARE), 0);
        assertEq(auction.auction(saleId).seller, seller);
        (address receiver, uint256 royalty) = fStream.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, vault, "royalties to the vault at the listing's share");
        assertTrue(vault.code.length != 0, "deployed at mint");
        assertEq(royalty, 0.05 ether);

        uint256 feeBefore = networkFee.balance;
        _ethBid(saleId, bidder, 1 ether);
        _settleAtEnd(saleId);
        assertEq(fStream.ownerOf(tokenId), bidder, "delivered");
        assertEq(uint8(fStream.workOf(tokenId).outcome), uint8(Outcome.SOLD));
        assertEq(seller.balance, 0.9 ether, "the seller vault takes the price less the share");
        assertEq(networkFee.balance - feeBefore, 0.1 ether, "the network's share");
    }

    function test_IndependentPair_TheCollaboratorsConsentMustCoverTheApprovedRate() public {
        Work memory w = _withIndCollaborator(_fedWork(artist), collab, 30_000);
        _approveInd(address(fStream), artist, w, IND_RATE);
        bytes[] memory consents = new bytes[](1);
        // Consent to a lower rate than the one the artist approved.
        consents[0] = _fedConsent(collab, address(fStream), w, IND_RATE - 1);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, collab));
        auction.start(address(fStream), _fedRequest(w, consents));

        // No consent at all.
        vm.expectRevert(IIndependentStreamRegistry.InvalidMintRequest.selector);
        auction.start(address(fStream), _fedRequest(w, new bytes[](0)));

        // The approved rate, consented: minted.
        consents[0] = _fedConsent(collab, address(fStream), w, IND_RATE);
        auction.start(address(fStream), _fedRequest(w, consents));
        assertEq(fStream.totalMinted(), 1);
    }

    function test_IndependentPair_AnItemNotApprovedMintsNothing() public {
        Work memory w = _fedWork(artist);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIndependentStreamRegistry.ItemNotApproved.selector, address(fStream), _itemHash(w)
            )
        );
        auction.start(address(fStream), _fedRequest(w, new bytes[](0)));
        // An approved item mints once.
        _approveInd(address(fStream), artist, w, IND_RATE);
        _fedStart(address(fStream), w);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIndependentStreamRegistry.ItemNotApproved.selector, address(fStream), _itemHash(w)
            )
        );
        auction.start(address(fStream), _fedRequest(w, new bytes[](0)));
    }

    function test_IndependentPair_AnUnsoldWorkStaysInCustodyAndRestarts() public {
        (, uint256 saleId, uint256 tokenId) = _fedApproveAndStart(address(fStream), artist);
        _settleAtEnd(saleId);
        assertEq(fStream.ownerOf(tokenId), address(auction), "stays with the auction, no museum");
        assertEq(uint8(fStream.workOf(tokenId).outcome), uint8(Outcome.NONE), "no outcome");
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));

        // Anyone offers it again, once the wait after the sale's end has passed.
        vm.warp(block.timestamp + auction.RESTART_DELAY());
        vm.prank(makeAddr("anyone"));
        auction.restart(saleId);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.ACTIVE));
        _ethBid(saleId, bidder, 1 ether);
        _settleAtEnd(saleId);
        assertEq(fStream.ownerOf(tokenId), bidder);
        assertEq(uint8(fStream.workOf(tokenId).outcome), uint8(Outcome.SOLD));

        // A sold work is not restarted.
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.SETTLED
            )
        );
        auction.restart(saleId);
    }

    // ------------------------------------------------------------------ delisting

    function test_IndependentPair_DelistingTheContractStopsNewMints() public {
        (, uint256 soldSale, uint256 sold) = _fedApproveAndStart(address(fStream), artist);
        _ethBid(soldSale, bidder, 1 ether);
        _settleAtEnd(soldSale);
        (, uint256 unsoldSale,) = _fedApproveAndStart(address(fStream), artist);
        _settleAtEnd(unsoldSale);
        (, uint256 running, uint256 runningToken) = _fedApproveAndStart(address(fStream), artist);
        _ethBid(running, bidder, 1 ether);
        Work memory next = _fedWork(artist);
        _approveInd(address(fStream), artist, next, IND_RATE);

        _asNetwork(
            address(independentStream),
            abi.encodeCall(
                independentStream.setStatus,
                (_asArray(address(fStream)), IIndependentStreamRegistry.Status.DELISTED, "vote")
            )
        );
        assertFalse(fStream.isMinter(address(auction)));
        assertFalse(fEditions.isMinter(deployment.independentEditionAuction), "editions follow");
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintPolicy.NotSaleContract.selector, address(fStream), address(auction)
            )
        );
        auction.start(address(fStream), _fedRequest(next, new bytes[](0)));
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.TargetNotAllowed.selector, address(fStream))
        );
        auction.restart(unsoldSale);
        // The sale that ran across the delisting (the decision waits its 24-hour role delay)
        // ends unsold: the standing bid is credited back and the work stays in custody.
        auction.settle(running);
        assertEq(fStream.ownerOf(runningToken), address(auction));
        assertEq(uint8(fStream.workOf(runningToken).outcome), uint8(Outcome.NONE));
        assertEq(auction.claimable(bidder), 1 ether, "the bid is credited back");

        // Nothing a collector holds is touched.
        address next_ = makeAddr("nextHolder");
        vm.prank(bidder);
        fStream.transferFrom(bidder, next_, sold);
        assertEq(fStream.ownerOf(sold), next_);

        // Listed again, it mints again.
        _asNetwork(
            address(independentStream),
            abi.encodeCall(
                independentStream.setStatus,
                (_asArray(address(fStream)), IIndependentStreamRegistry.Status.ACTIVE, "vote 2")
            )
        );
        _fedStart(address(fStream), next);
    }

    function test_IndependentPair_DelistingTheAccountStopsEveryContractOfIt() public {
        Work memory next = _fedWork(artist);
        _approveInd(address(fStream), artist, next, IND_RATE);
        uint256 artistId = uint256(uint160(artist));
        _asNetwork(
            address(independentStream),
            abi.encodeCall(independentStream.setAccountDelisted, (artistId, true, "vote"))
        );
        assertFalse(fStream.isMinter(address(auction)));
        assertFalse(fEditions.isMinter(deployment.independentEditionAuction));
        assertEq(
            uint8(independentStream.entry(address(fStream)).status),
            uint8(IIndependentStreamRegistry.Status.DELISTED)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintPolicy.NotSaleContract.selector, address(fStream), address(auction)
            )
        );
        auction.start(address(fStream), _fedRequest(next, new bytes[](0)));
        // The account lists no new contract.
        IndependentStream6529 another = _deployIndStream(artist);
        IIndependentStreamRegistry.Join memory j =
            _joinOf(address(another), artist, address(streamDeployer));
        vm.expectRevert(
            abi.encodeWithSelector(
                IIndependentStreamRegistry.NotListable.selector, address(another)
            )
        );
        independentStream.register(address(another), j);

        _asNetwork(
            address(independentStream),
            abi.encodeCall(independentStream.setAccountDelisted, (artistId, false, "vote 2"))
        );
        _fedStart(address(fStream), next);
    }

    // ------------------------------------------------------------------ the network's share

    function test_IndependentPair_TheShareIsOnlyLoweredForNewWorks() public {
        (Work memory before,, uint256 earlier) = _fedApproveAndStart(address(fStream), artist);
        _governExpectRevert(
            address(independentStream),
            abi.encodeCall(independentStream.lowerFeeShare, (address(fStream), IND_SHARE)),
            abi.encodeWithSelector(
                IIndependentStreamRegistry.FeeShareNotLowered.selector, address(fStream), IND_SHARE
            )
        );
        _asNetwork(
            address(independentStream),
            abi.encodeCall(independentStream.lowerFeeShare, (address(fStream), 2_500))
        );
        assertEq(independentStream.feeShareOf(address(fStream)), 2_500);
        _governExpectRevert(
            address(independentStream),
            abi.encodeCall(independentStream.lowerFeeShare, (address(fStream), 5_000)),
            abi.encodeWithSelector(
                IIndependentStreamRegistry.FeeShareNotLowered.selector, address(fStream), 2_500
            )
        );

        // A new work takes the lower share: royalty vault and settlement.
        (Work memory w, uint256 saleId, uint256 tokenId) =
            _fedApproveAndStart(address(fStream), artist);
        address seller = ledger.walletFor(w.item.payees, bytes32(0));
        (address receiver,) = fStream.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, ledger.walletFor(Splits.royaltyPayees(seller, networkFee, 2_500), 0));
        uint256 feeBefore = networkFee.balance;
        _ethBid(saleId, bidder, 1 ether);
        _settleAtEnd(saleId);
        assertEq(networkFee.balance - feeBefore, 0.025 ether, "the lowered share");

        // The work minted before keeps its receiver until TERMS moves it, never above the
        // Independent Stream module's share.
        address earlierSeller = ledger.walletFor(before.item.payees, bytes32(0));
        (receiver,) = fStream.royaltyInfo(earlier, 1 ether);
        assertEq(
            receiver,
            ledger.walletFor(Splits.royaltyPayees(earlierSeller, networkFee, IND_SHARE), 0)
        );
        _governExpectRevert(
            address(terms),
            abi.encodeCall(
                terms.lowerFeeShare,
                (address(fStream), earlier, earlierSeller, networkFee, IND_SHARE, 5_000)
            ),
            abi.encodeWithSelector(ITerms.InvalidFeeShare.selector)
        );
        _asNetwork(
            address(terms),
            abi.encodeCall(
                terms.lowerFeeShare,
                (address(fStream), earlier, earlierSeller, networkFee, IND_SHARE, 2_500)
            )
        );
        (receiver,) = fStream.royaltyInfo(earlier, 1 ether);
        assertEq(
            receiver, ledger.walletFor(Splits.royaltyPayees(earlierSeller, networkFee, 2_500), 0)
        );
        assertTrue(receiver.code.length != 0, "the new vault is deployed before it is named");
        assertEq(fStream.workOf(earlier).royaltyRate, IND_RATE, "the rate is unchanged");
    }
}
