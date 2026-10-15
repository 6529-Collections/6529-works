// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { CURRENCY_ETH, PRODUCT_STREAM, WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { ItemKind, Party, PartyRole } from "src/interfaces/types/PackageTypes.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { Roles } from "src/governance/Roles.sol";
import { RefusingWallet } from "../mocks/integration/IntegrationMocks.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Flow 1 (integration brief, lane B): a curated sale on the real contracts. Package,
///         curation-signer attestation, registration, party acceptance, the artist's move
///         signature, `start` and `startWithBid`, bids with anti-snipe, `settle`, the split
///         wallet release (the artist pulls, fixed payees are pushed) and `royaltyInfo` against
///         the receiver the economics resolver derives.
contract CuratedSaleFlowTest is IntegrationBase {
    address internal artist;
    address internal collaborator;
    address internal bidder1 = makeAddr("bidder1");
    address internal bidder2 = makeAddr("bidder2");
    address internal keeper = makeAddr("keeper");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("artist");
        collaborator = _actor("collaborator");
        Work[] memory works = new Work[](3);
        for (uint256 i; i < 3; ++i) {
            works[i] = _collaboration(_work(artist, collectionId));
        }
        root = _publish(works);
        _keep(root, works);
    }

    /// @dev The lead artist with a collaborator paid as a fixed payee: 80/20 of the artist portion.
    function _collaboration(Work memory w) internal view returns (Work memory) {
        w.item.parties = new Party[](2);
        w.item.parties[0] = Party(artist, PartyRole.ARTIST);
        w.item.parties[1] = Party(collaborator, PartyRole.COLLABORATOR);
        w.item.payees = new ISplitWallet.Payee[](2);
        w.item.payees[0] = ISplitWallet.Payee(0, collaborator, 20_000);
        w.item.payees[1] = ISplitWallet.Payee(uint256(uint160(artist)), address(0), 80_000);
        return w;
    }

    function test_CuratedPackageIsApprovedAndAccepted() public view {
        (IPackageRegistry.PackageStatus status, bytes32 evidence, address signer) =
            registry.packageOf(root);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.APPROVED));
        assertEq(evidence, _evidence(root));
        assertEq(signer, signer1, "the attesting curation signer is recorded");
        assertEq(registry.acceptedAs(root, artist), uint160(artist), "first acceptance = identity");
        assertEq(registry.acceptedAs(root, collaborator), uint160(collaborator));
        assertEq(artists.authorityOf(uint160(artist)), artist);
        (uint64 count,) = statements.chainOf(address(0), uint256(root));
        assertEq(count, 1, "CURATION_EVIDENCE statement");
    }

    function test_StartBidAntiSnipeSettleAndRelease() public {
        Work[] memory works = _package(root);
        bytes memory data = _mintData(root, works, 0);
        bytes32 itemHash = WorksHashing.itemHash(works[0].item);
        vm.expectEmit(address(stream));
        emit IStream.WorkMinted(
            1,
            collectionId,
            itemHash,
            1,
            uint160(artist),
            ItemKind.ORIGINAL,
            root,
            works[0].item.contentHash,
            works[0].item.mediaHash,
            works[0].item.recordFileId
        );
        uint256 saleId = auction.start(address(stream), data);
        uint256 tokenId = 1;
        assertEq(stream.ownerOf(tokenId), address(auction), "minted into auction custody");
        assertEq(registry.consumedItemOf(works[0].item.contentHash), itemHash);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.endTime, block.timestamp + AUCTION_DURATION, "24-hour clock");
        assertEq(a.currency, CURRENCY_ETH);

        // A replayed start of the same item fails: single use.
        bytes memory replay = _mintDataSignedBy(root, works, 0, artist, 99);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ContentUsed.selector,
                PRODUCT_STREAM,
                works[0].item.contentHash,
                itemHash
            )
        );
        auction.start(address(stream), replay);

        // Bids: a zero bid cannot claim the work; increments are max(5%, 0.001 ETH).
        vm.deal(bidder1, 10 ether);
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, 1, 0));
        auction.bid(saleId, address(0), Payment(PaymentMethod.DIRECT, bidder1, 0, 0, 0, ""));
        _ethBid(saleId, bidder1, 1 ether);
        assertEq(auction.minimumBid(saleId), 1.05 ether);
        vm.deal(bidder2, 10 ether);
        vm.prank(bidder2);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, 1.05 ether, 1.04 ether)
        );
        auction.bid{ value: 1.04 ether }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, bidder2, 1.04 ether, 0, 0, "")
        );
        _ethBid(saleId, bidder2, 1.05 ether);
        assertEq(auction.claimable(bidder1, CURRENCY_ETH), 1 ether, "outbid bidder credited");

        // Anti-snipe: a bid in the last 15 minutes extends the end.
        vm.warp(a.endTime - 5 minutes);
        _ethBid(saleId, bidder1, 2 ether);
        assertEq(auction.auction(saleId).endTime, block.timestamp + EXTENSION_WINDOW);
        vm.warp(a.endTime);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ACTIVE
            )
        );
        auction.settle(saleId);

        WorkTerms memory terms = economics.newWorkTerms(PRODUCT_STREAM, works[0].item.payees);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), bidder1, "delivered to the winner");
        assertTrue(stream.primarySaleSettled(tokenId));
        assertEq(terms.seller.balance, 1.5 ether, "75% to the predicted seller wallet");
        assertEq(networkFee.balance, 0.5 ether, "25% to the network");
        assertEq(auction.claimable(bidder2, CURRENCY_ETH), 1.05 ether);
        uint256 before = bidder2.balance;
        vm.prank(bidder2);
        auction.claim(CURRENCY_ETH, bidder2);
        assertEq(bidder2.balance - before, 1.05 ether, "refund pulled");
        vm.prank(bidder1);
        auction.claim(CURRENCY_ETH, bidder1);

        _releaseSellerWallet(terms.seller, works[0].item.payees);
        _checkRoyalties(tokenId, works[0].item.payees, terms);
    }

    /// @dev The seller wallet is deployed by anyone after the sale; the collaborator (fixed) is
    ///      pushed by a keeper or the claim router, the artist (artist-resolved) pulls.
    function _releaseSellerWallet(address seller, ISplitWallet.Payee[] memory payees) internal {
        assertEq(splitFactory.createWallet(payees, bytes32(0)), seller, "predicted = deployed");
        ISplitWallet wallet = ISplitWallet(seller);
        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](1);
        claims[0] = IClaimRouter.Claim(seller, CURRENCY_ETH, 0);
        vm.prank(keeper);
        claimRouter.claim(claims, false);
        assertEq(collaborator.balance, 0.3 ether, "20% of the artist portion, pushed");

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, keeper, artist)
        );
        wallet.release(CURRENCY_ETH, 1);
        vm.prank(artist);
        wallet.release(CURRENCY_ETH, 1);
        assertEq(artist.balance, 1.2 ether, "80% of the artist portion, pulled");
    }

    /// @dev ERC-2981 names the receiver the economics resolver derives, at 6.529%; the royalty
    ///      wallet splits 25/75 between the network and the seller wallet.
    function _checkRoyalties(
        uint256 tokenId,
        ISplitWallet.Payee[] memory payees,
        WorkTerms memory terms
    ) internal {
        (address receiver, uint256 amount) = stream.royaltyInfo(tokenId, 10 ether);
        assertEq(receiver, terms.royaltyReceiver, "receiver = the resolver's derivation");
        assertEq(receiver, stream.work(tokenId).royaltyReceiver);
        assertEq(amount, 0.6529 ether, "6.529%");
        assertEq(terms.royaltyRate, 6_529);

        address marketplace = makeAddr("marketplace");
        vm.deal(marketplace, amount);
        vm.prank(marketplace);
        (bool ok,) = receiver.call{ value: amount }("");
        assertTrue(ok);
        ISplitWallet.Payee[] memory royaltyPayees =
            Splits.royaltyPayees(terms.seller, networkFee, terms.feeShare);
        assertEq(splitFactory.createWallet(royaltyPayees, bytes32(0)), receiver);
        uint256 feeBefore = networkFee.balance;
        uint256 sellerBefore = terms.seller.balance;
        for (uint256 i; i < 2; ++i) {
            vm.prank(keeper);
            ISplitWallet(receiver).release(CURRENCY_ETH, i);
        }
        assertEq(networkFee.balance - feeBefore, amount / 4, "25% of royalties to the network");
        assertEq(terms.seller.balance - sellerBefore, amount - amount / 4, "75% to the seller");
        payees; // the seller wallet's own payees are unchanged by royalties
    }

    function test_StartWithBidLocksTheFirstBid() public {
        Work[] memory works = _package(root);
        bytes memory data = _mintData(root, works, 1);
        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        uint256 saleId = auction.startWithBid{ value: 0.5 ether }(
            address(stream),
            data,
            address(0),
            Payment(PaymentMethod.DIRECT, bidder1, 0.5 ether, 0, 0, "")
        );
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.bidder, bidder1);
        assertEq(a.bid, 0.5 ether);
        assertEq(a.incrementFloor, ETH_INCREMENT_FLOOR, "floor locked at the first bid");
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(a.tokenId), bidder1);
    }

    function test_NoBidsDeliversToTheArtist() public {
        (uint256 saleId, uint256 tokenId) = _start(root, _package(root), 2);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), artist, "no bids: the artist's current authority");
        assertTrue(stream.primarySaleSettled(tokenId));
    }

    function test_MoveSignatureIsRevocable() public {
        Work[] memory works = _package(root);
        bytes memory data = _mintDataSignedBy(root, works, 0, artist, 5);
        vm.prank(artist);
        registry.revokeMove(uint160(artist), 5);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.MoveNonceUsed.selector, uint160(artist), 5)
        );
        auction.start(address(stream), data);
    }

    // ------------------------------------------------------------------ ERC-20, escrow, delivery

    /// @dev ADR 0001 section 5: an auction in an admitted ERC-20, opened with a first bid paid by
    ///      a relayed Permit2 transfer whose witness binds the start (`StartBid`).
    function test_Erc20AuctionStartedWithAPermit2Bid() public {
        _govern(
            hotAdmin,
            address(allowlist),
            abi.encodeCall(allowlist.admitAsset, (address(usd), 0, 1e16))
        );
        address payer = _actor("permit2Bidder");
        address relayer = makeAddr("relayer");
        Work memory w = _collaboration(_work(artist, collectionId));
        w.item.sale.currency = address(usd);
        Work[] memory works = _one(w);
        bytes32 usdRoot = _publish(works);
        bytes memory mintData = _mintData(usdRoot, works, 0);

        usd.mint(payer, 1_000e18);
        vm.prank(payer);
        usd.approve(PERMIT2, type(uint256).max);
        uint256 amount = 100e18;
        Payment memory pay = _permit2StartBid(mintData, payer, amount);
        vm.prank(relayer);
        uint256 saleId = auction.startWithBid(address(stream), mintData, payer, pay);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.currency, address(usd), "the currency is locked at start");
        assertEq(a.bidder, payer);
        assertEq(usd.balanceOf(address(auction)), amount);

        // An outbid in the same currency, paid directly.
        usd.mint(bidder2, 200e18);
        vm.startPrank(bidder2);
        usd.approve(address(auction), 200e18);
        auction.bid(saleId, address(0), Payment(PaymentMethod.DIRECT, bidder2, 200e18, 0, 0, ""));
        vm.stopPrank();
        assertEq(auction.claimable(payer, address(usd)), amount);

        _settleAtEnd(saleId);
        WorkTerms memory terms = economics.newWorkTerms(PRODUCT_STREAM, w.item.payees);
        assertEq(usd.balanceOf(terms.seller), 150e18);
        assertEq(usd.balanceOf(networkFee), 50e18);
        splitFactory.createWallet(w.item.payees, bytes32(0));
        vm.prank(artist);
        ISplitWallet(terms.seller).release(address(usd), 1);
        assertEq(usd.balanceOf(artist), 120e18, "the artist pulls ERC-20 too");
    }

    /// @dev A Permit2 payment whose witness binds the start: token, mint data, recipient, amount.
    function _permit2StartBid(bytes memory mintData, address payer, uint256 amount)
        internal
        view
        returns (Payment memory)
    {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 witness = keccak256(
            abi.encode(
                Typehashes.START_BID_WITNESS,
                address(stream),
                keccak256(mintData),
                payer,
                amount,
                deadline
            )
        );
        bytes32 digest = permit2.witnessDigest(
            address(auction),
            ISignatureTransfer.PermitTransferFrom(
                ISignatureTransfer.TokenPermissions(address(usd), amount), 0, deadline
            ),
            witness,
            Typehashes.START_BID_WITNESS_TYPE
        );
        return Payment(PaymentMethod.PERMIT2, payer, amount, deadline, 0, _sign(payer, digest));
    }

    /// @dev A network fee recipient that refuses ETH cannot block settlement: its share goes to
    ///      the escrow and is flushed later. The new fee terms apply to new works only.
    function test_RefusedFeeGoesToTheEscrow() public {
        RefusingWallet safe = new RefusingWallet();
        safe.setRefuse(true);
        // A sale running while the fee terms change keeps the terms its work locked at mint.
        (uint256 oldSale,) = _start(root, _package(root), 2);
        _ethBid(oldSale, bidder1, 1 ether);
        _govern(
            hotAdmin,
            address(economics),
            abi.encodeCall(economics.setFeeTerms, (PRODUCT_STREAM, 1, address(safe), 25_000))
        );
        auction.settle(oldSale);
        assertEq(networkFee.balance, 0.25 ether, "locked at mint");

        Work[] memory works = _one(_collaboration(_work(artist, collectionId)));
        bytes32 newRoot = _publish(works);
        uint256 tokenId = _sell(newRoot, works, 0, bidder2, 2 ether);
        assertEq(stream.ownerOf(tokenId), bidder2, "settled despite the refusal");
        assertEq(IRevenueEscrow(address(escrow)).owed(address(safe), CURRENCY_ETH), 0.5 ether);
        safe.setRefuse(false);
        vm.prank(keeper);
        IRevenueEscrow(address(escrow)).flush(address(safe), CURRENCY_ETH);
        assertEq(address(safe).balance, 0.5 ether, "flushed by anyone");
        (address receiver,) = stream.royaltyInfo(tokenId, 1 ether);
        assertEq(
            receiver, economics.newWorkTerms(PRODUCT_STREAM, works[0].item.payees).royaltyReceiver
        );
    }

    /// @dev Settlement never depends on the winner accepting the NFT (RC1's Medium finding): a
    ///      winner that cannot receive it gets a pending delivery and names a recipient later.
    function test_WinnerThatCannotReceiveGetsAPendingDelivery() public {
        RefusingWallet winner = new RefusingWallet();
        vm.deal(address(winner), 1 ether);
        (uint256 saleId, uint256 tokenId) = _start(root, _package(root), 2);
        winner.exec(
            address(auction),
            1 ether,
            abi.encodeCall(
                auction.bid,
                (
                    saleId,
                    address(0),
                    Payment(PaymentMethod.DIRECT, address(winner), 1 ether, 0, 0, "")
                )
            )
        );
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), address(auction), "still in custody");
        assertEq(auction.pendingDelivery(saleId), address(winner));
        assertTrue(stream.primarySaleSettled(tokenId), "settled all the same");
        address vault = makeAddr("winnerVault");
        winner.exec(address(auction), 0, abi.encodeCall(auction.claimDelivery, (saleId, vault)));
        assertEq(stream.ownerOf(tokenId), vault);
    }

    /// @dev The guardian's curation controls (ADR 0003): revoking an approved root stops its
    ///      starts at once; disabling a curation signer stops its new attestations, and the
    ///      second genesis signer keeps curation running.
    function test_GuardianRevokesAPackageAndDisablesASigner() public {
        Work[] memory works = _package(root);
        bytes memory data = _mintData(root, works, 0);
        vm.prank(guardian1);
        registry.revokePackage(root, keccak256("leaked attestation"));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        auction.start(address(stream), data);

        vm.prank(guardian2);
        verifier.disableSigner(signer1);
        Work[] memory fresh = _one(_work(artist, collectionId));
        bytes32 freshRoot = _rootOf(fresh);
        bytes32 evidence = _evidence(freshRoot);
        bytes memory bySigner1 = _attestation(signer1, freshRoot, evidence);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, freshRoot));
        registry.registerPackage(freshRoot, evidence, bySigner1);
        bytes memory bySigner2 = _attestation(signer2, freshRoot, evidence);
        registry.registerPackage(freshRoot, evidence, bySigner2);
        (,, address signer) = registry.packageOf(freshRoot);
        assertEq(signer, signer2);
    }

    /// @dev `signer`'s attestation of `packageRoot` at its current epoch.
    function _attestation(address signer, bytes32 packageRoot, bytes32 evidence)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest =
            verifier.approvalDigest(packageRoot, evidence, verifier.signerEpoch(signer));
        return abi.encode(signer, _sign(signer, digest));
    }

    /// @dev SIGS-2: re-enabling a disabled signer starts a new epoch. Approvals its key signed
    ///      before, or while it was disabled, never count again; the signer re-signs what it
    ///      still approves.
    function test_ReEnablingASignerDoesNotReviveOlderApprovals() public {
        address unvetted = _actor("unvetted");
        uint256 epoch = verifier.signerEpoch(signer1);
        vm.prank(guardian1);
        verifier.disableSigner(signer1);
        assertTrue(verifier.signerEpoch(signer1) != epoch, "disabling ends the epoch");
        Work[] memory unreviewed = _one(_work(unvetted, collectionId));
        bytes32 unreviewedRoot = _rootOf(unreviewed);
        bytes32 evidence = keccak256("unreviewed evidence");
        bytes memory signedWhileDisabled = _attestation(signer1, unreviewedRoot, evidence);

        _govern(hotAdmin, address(verifier), abi.encodeCall(verifier.enableSigner, (signer1)));
        assertTrue(verifier.isSignerActive(signer1));
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, unreviewedRoot)
        );
        registry.registerPackage(unreviewedRoot, evidence, signedWhileDisabled);

        // What the signer approves now registers.
        Work[] memory fresh = _one(_work(artist, collectionId));
        bytes32 freshRoot = _rootOf(fresh);
        registry.registerPackage(
            freshRoot, _evidence(freshRoot), _attestation(signer1, freshRoot, _evidence(freshRoot))
        );
        (IPackageRegistry.PackageStatus status,, address signer) = registry.packageOf(freshRoot);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.APPROVED));
        assertEq(signer, signer1);
    }

    /// @dev Review of SIGS-2: an approval signed while the signer is disabled, over the epoch the
    ///      re-enable would start if it were not salted from the re-enable's block, does not
    ///      register after the re-enable.
    function test_AnApprovalSignedWhileDisabledCannotNameTheReEnableEpoch() public {
        vm.prank(guardian1);
        verifier.disableSigner(signer1);
        Work[] memory works = _one(_work(_actor("unvetted"), collectionId));
        bytes32 packageRoot = _rootOf(works);
        bytes32 evidence = keccak256("unreviewed evidence");
        uint256 guess = verifier.signerEpoch(signer1) + 1; // the change count after an enable
        bytes memory early = abi.encode(
            signer1, _sign(signer1, verifier.approvalDigest(packageRoot, evidence, guess))
        );
        vm.prevrandao(keccak256("the re-enable block"));
        _govern(hotAdmin, address(verifier), abi.encodeCall(verifier.enableSigner, (signer1)));
        assertTrue(verifier.signerEpoch(signer1) != guess);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, packageRoot));
        registry.registerPackage(packageRoot, evidence, early);
    }

    /// @dev SIGS-2: revoking the CURATION_SIGNER role and granting it again to the same key is a
    ///      new grant, with a new epoch: approvals signed under the old grant stay dead.
    function test_RegrantingTheSignerRoleDoesNotReviveOlderApprovals() public {
        Work[] memory works = _one(_work(_actor("unregistered"), collectionId));
        bytes32 packageRoot = _rootOf(works);
        bytes32 evidence = _evidence(packageRoot);
        bytes memory oldGrant = _attestation(signer1, packageRoot, evidence);
        uint64 role = Roles.CURATION_SIGNER;
        _govern(hotAdmin, address(manager), abi.encodeCall(manager.revokeRole, (role, signer1)));
        _govern(hotAdmin, address(manager), abi.encodeCall(manager.grantRole, (role, signer1, 0)));
        vm.warp(block.timestamp + 31 days); // the role's grant delay
        assertTrue(verifier.isSignerActive(signer1));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, packageRoot));
        registry.registerPackage(packageRoot, evidence, oldGrant);
        registry.registerPackage(
            packageRoot, evidence, _attestation(signer1, packageRoot, evidence)
        );
        (IPackageRegistry.PackageStatus status,,) = registry.packageOf(packageRoot);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.APPROVED));
    }
}
