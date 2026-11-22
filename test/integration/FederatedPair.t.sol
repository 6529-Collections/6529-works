// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Splits } from "src/economics/Splits.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { ITerms } from "src/interfaces/core/ITerms.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { FederatedIntegrationBase } from "./FederatedIntegrationBase.sol";

/// @notice A federated artist's pair end to end on the real deployed stack: deployed through the
///         genesis template deployers, listed with the artist's consent through the federation
///         module the directory names, an item approved with its collaborator's consent to the
///         royalty rate, minted through the federation module's `authorize` by the English
///         auction and sold; an unsold work stays in the auction's custody and `restart` offers it
///         again; delisting by contract and by account stops new mints; the network's share is
///         only ever lowered, for new works and, through the TERMS module, for existing ones.
contract FederatedPairTest is FederatedIntegrationBase {
    address internal artist;
    address internal collab;
    address internal bidder;
    FederatedStream internal fStream;
    FederatedEditions internal fEditions;

    function setUp() public override {
        super.setUp();
        artist = _actor("federatedArtist");
        collab = _actor("federatedCollaborator");
        bidder = makeAddr("federatedBidder");
        (fStream, fEditions) = _listPair(artist);
    }

    // ------------------------------------------------------------------ listing

    function test_FederatedPair_ListedWithTheArtistsConsent() public view {
        uint256 artistId = uint256(uint160(artist));
        IFederationRegistry.Entry memory e = federation.entry(address(fStream));
        assertEq(uint8(e.form), uint8(IFederationRegistry.Form.ERC721));
        assertEq(e.partner, address(fEditions), "the editions name the 1/1 contract");
        assertEq(e.artistId, artistId);
        assertEq(e.feeShare, FED_SHARE, "the launch federated share, recorded at listing");
        assertEq(uint8(e.status), uint8(IFederationRegistry.Status.ACTIVE));
        assertEq(federation.entry(address(fEditions)).partner, address(fStream));
        assertEq(accounts.authorityOf(artistId), artist, "identity created at listing");
        assertTrue(fStream.isMinter(address(auction)), "the English auction mints the 1/1s");
        assertTrue(
            fEditions.isMinter(deployment.federatedEditionAuction), "the edition auction mints"
        );
        assertEq(fStream.directory(), address(directory));
        assertEq(fStream.moduleOf(bytes32("TERMS")), address(terms), "shared TERMS module");
        assertEq(fStream.moduleOf(bytes32("RECORDS")), address(rules), "shared RECORDS module");
    }

    function test_FederatedPair_ListingRefusesAConsentByAnotherKey() public {
        address other = _actor("otherArtist");
        FederatedStream token = _deployFedStream(other);
        IFederationRegistry.Join memory j = _joinOf(address(token), other, address(streamDeployer));
        // The consent is signed by a key that is not a wallet of the account.
        j.consent = abi.encodePacked(
            artist,
            _sign(
                artist,
                accounts.consentDigest(
                    address(federation),
                    federation.listingSubject(
                        address(token),
                        IFederationRegistry.Form.ERC721,
                        address(0),
                        FED_SHARE,
                        j.deadline
                    )
                )
            )
        );
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, artist));
        federation.register(address(token), j);
    }

    // ------------------------------------------------------------------ sale

    function test_FederatedPair_ACollaboratedWorkIsMintedAndSold() public {
        Work memory w = _withFedCollaborator(_fedWork(artist), collab, 30_000);
        _approveFed(address(fStream), artist, w, FED_RATE);
        bytes[] memory consents = new bytes[](1);
        consents[0] = _fedConsent(collab, address(fStream), w, FED_RATE);

        uint256 saleId = auction.start(address(fStream), _fedRequest(w, consents));
        uint256 tokenId = fStream.totalMinted();
        assertEq(fStream.ownerOf(tokenId), address(auction), "in the auction's custody");
        assertEq(fStream.itemHashOf(tokenId), _itemHash(w));
        assertEq(fStream.workOf(tokenId).artistId, uint256(uint160(artist)));
        assertEq(fStream.workOf(tokenId).royaltyRate, FED_RATE, "the approved rate");
        assertTrue(federation.itemOf(address(fStream), _itemHash(w)).used, "the item is consumed");

        address seller = ledger.walletFor(w.item.payees, bytes32(0));
        address vault = ledger.walletFor(Splits.royaltyPayees(seller, networkFee, FED_SHARE), 0);
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

    function test_FederatedPair_TheCollaboratorsConsentMustCoverTheApprovedRate() public {
        Work memory w = _withFedCollaborator(_fedWork(artist), collab, 30_000);
        _approveFed(address(fStream), artist, w, FED_RATE);
        bytes[] memory consents = new bytes[](1);
        // Consent to a lower rate than the one the artist approved.
        consents[0] = _fedConsent(collab, address(fStream), w, FED_RATE - 1);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, collab));
        auction.start(address(fStream), _fedRequest(w, consents));

        // No consent at all.
        vm.expectRevert(IFederationRegistry.InvalidMintRequest.selector);
        auction.start(address(fStream), _fedRequest(w, new bytes[](0)));

        // The approved rate, consented: minted.
        consents[0] = _fedConsent(collab, address(fStream), w, FED_RATE);
        auction.start(address(fStream), _fedRequest(w, consents));
        assertEq(fStream.totalMinted(), 1);
    }

    function test_FederatedPair_AnItemNotApprovedMintsNothing() public {
        Work memory w = _fedWork(artist);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.ItemNotApproved.selector, address(fStream), _itemHash(w)
            )
        );
        auction.start(address(fStream), _fedRequest(w, new bytes[](0)));
        // An approved item mints once.
        _approveFed(address(fStream), artist, w, FED_RATE);
        _fedStart(address(fStream), w);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederationRegistry.ItemNotApproved.selector, address(fStream), _itemHash(w)
            )
        );
        auction.start(address(fStream), _fedRequest(w, new bytes[](0)));
    }

    function test_FederatedPair_AnUnsoldWorkStaysInCustodyAndRestarts() public {
        (, uint256 saleId, uint256 tokenId) = _fedApproveAndStart(address(fStream), artist);
        _settleAtEnd(saleId);
        assertEq(fStream.ownerOf(tokenId), address(auction), "stays with the auction, no museum");
        assertEq(uint8(fStream.workOf(tokenId).outcome), uint8(Outcome.NONE), "no outcome");
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));

        // Anyone offers it again.
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

    function test_FederatedPair_DelistingTheContractStopsNewMints() public {
        (, uint256 soldSale, uint256 sold) = _fedApproveAndStart(address(fStream), artist);
        _ethBid(soldSale, bidder, 1 ether);
        _settleAtEnd(soldSale);
        (, uint256 unsoldSale,) = _fedApproveAndStart(address(fStream), artist);
        _settleAtEnd(unsoldSale);
        (, uint256 running, uint256 runningToken) = _fedApproveAndStart(address(fStream), artist);
        _ethBid(running, bidder, 1 ether);
        Work memory next = _fedWork(artist);
        _approveFed(address(fStream), artist, next, FED_RATE);

        _asNetwork(
            address(federation),
            abi.encodeCall(
                federation.setStatus,
                (_asArray(address(fStream)), IFederationRegistry.Status.DELISTED, "vote")
            )
        );
        assertFalse(fStream.isMinter(address(auction)));
        assertFalse(fEditions.isMinter(deployment.federatedEditionAuction), "editions follow");
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
            address(federation),
            abi.encodeCall(
                federation.setStatus,
                (_asArray(address(fStream)), IFederationRegistry.Status.ACTIVE, "vote 2")
            )
        );
        _fedStart(address(fStream), next);
    }

    function test_FederatedPair_DelistingTheAccountStopsEveryContractOfIt() public {
        Work memory next = _fedWork(artist);
        _approveFed(address(fStream), artist, next, FED_RATE);
        uint256 artistId = uint256(uint160(artist));
        _asNetwork(
            address(federation),
            abi.encodeCall(federation.setAccountDelisted, (artistId, true, "vote"))
        );
        assertFalse(fStream.isMinter(address(auction)));
        assertFalse(fEditions.isMinter(deployment.federatedEditionAuction));
        assertEq(
            uint8(federation.entry(address(fStream)).status),
            uint8(IFederationRegistry.Status.DELISTED)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintPolicy.NotSaleContract.selector, address(fStream), address(auction)
            )
        );
        auction.start(address(fStream), _fedRequest(next, new bytes[](0)));
        // The account lists no new contract.
        FederatedStream another = _deployFedStream(artist);
        IFederationRegistry.Join memory j =
            _joinOf(address(another), artist, address(streamDeployer));
        vm.expectRevert(
            abi.encodeWithSelector(IFederationRegistry.NotListable.selector, address(another))
        );
        federation.register(address(another), j);

        _asNetwork(
            address(federation),
            abi.encodeCall(federation.setAccountDelisted, (artistId, false, "vote 2"))
        );
        _fedStart(address(fStream), next);
    }

    // ------------------------------------------------------------------ the network's share

    function test_FederatedPair_TheShareIsOnlyLoweredForNewWorks() public {
        (Work memory before,, uint256 earlier) = _fedApproveAndStart(address(fStream), artist);
        _governExpectRevert(
            address(federation),
            abi.encodeCall(federation.lowerFeeShare, (address(fStream), FED_SHARE)),
            abi.encodeWithSelector(
                IFederationRegistry.FeeShareNotLowered.selector, address(fStream), FED_SHARE
            )
        );
        _asNetwork(
            address(federation), abi.encodeCall(federation.lowerFeeShare, (address(fStream), 2_500))
        );
        assertEq(federation.feeShareOf(address(fStream)), 2_500);
        _governExpectRevert(
            address(federation),
            abi.encodeCall(federation.lowerFeeShare, (address(fStream), 5_000)),
            abi.encodeWithSelector(
                IFederationRegistry.FeeShareNotLowered.selector, address(fStream), 2_500
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
        // federation module's share.
        address earlierSeller = ledger.walletFor(before.item.payees, bytes32(0));
        (receiver,) = fStream.royaltyInfo(earlier, 1 ether);
        assertEq(
            receiver,
            ledger.walletFor(Splits.royaltyPayees(earlierSeller, networkFee, FED_SHARE), 0)
        );
        _governExpectRevert(
            address(terms),
            abi.encodeCall(
                terms.lowerFeeShare,
                (address(fStream), earlier, earlierSeller, networkFee, FED_SHARE, 5_000)
            ),
            abi.encodeWithSelector(ITerms.InvalidFeeShare.selector)
        );
        _asNetwork(
            address(terms),
            abi.encodeCall(
                terms.lowerFeeShare,
                (address(fStream), earlier, earlierSeller, networkFee, FED_SHARE, 2_500)
            )
        );
        (receiver,) = fStream.royaltyInfo(earlier, 1 ether);
        assertEq(
            receiver, ledger.walletFor(Splits.royaltyPayees(earlierSeller, networkFee, 2_500), 0)
        );
        assertTrue(receiver.code.length != 0, "the new vault is deployed before it is named");
        assertEq(fStream.workOf(earlier).royaltyRate, FED_RATE, "the rate is unchanged");
    }
}
