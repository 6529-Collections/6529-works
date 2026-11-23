// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { RevenuePayment } from "src/economics/RevenuePayment.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEnglishAuctionRefusal } from "src/interfaces/IEnglishAuctionRefusal.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { PRODUCT_INDEPENDENT } from "src/interfaces/types/EconomicsTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { CallbackMintToken, OpenTermsPolicy } from "test/mocks/sales/EnglishAuctionRulesMocks.sol";
import { AuctionFixture } from "./AuctionFixture.sol";
import { BidderContract, MockMintPolicy } from "./AuctionMocks.sol";

/// @notice Rules of the English auction (docs/spec/stream-and-auctions.md) that the other suites
///         pin only in part: the policy call of every start, who claims a credit, the gas a
///         settler must forward, the clock of a resumed sale, the receiver callback, the museum
///         transfer, the mint policy's reach, the refusal delay and gas, and an Independent
///         Stream sale's fee. The last section pins two behaviours as built.
contract EnglishAuctionRulesTest is AuctionFixture {
    bytes32 internal constant REF = keccak256("dispute");
    uint256 internal constant DENOMINATOR = 100_000;

    // ------------------------------------------------------------------------------ start

    /// A start, with or without a bid, asks the token's mint policy once in the same call
    /// (AUC-3).
    function test_Start_AsksTheMintPolicyInTheSameCall() public {
        bytes memory first = abi.encode(uint256(1));
        vm.expectCall(
            address(policy), abi.encodeCall(IMintPolicy.authorize, (address(stream), first)), 1
        );
        auction.start(address(stream), first);
        bytes memory second = abi.encode(uint256(2));
        vm.expectCall(
            address(policy), abi.encodeCall(IMintPolicy.authorize, (address(stream), second)), 1
        );
        vm.prank(alice);
        auction.startWithBid{ value: 1 ether }(address(stream), second, address(0));
        assertEq(stream.totalMinted(), 2);
    }

    /// A policy revert reverts a start with a bid: nothing mints and the bid is not taken; the
    /// same request starts once the policy allows it (AUC-3).
    function test_StartWithBid_APolicyRevertMintsNothingAndTakesNoBid() public {
        bytes memory request = abi.encode(uint256(1));
        policy.setMode(MockMintPolicy.Mode.REVERT);
        uint256 before = alice.balance;
        vm.prank(alice);
        vm.expectRevert(bytes("policy says no"));
        auction.startWithBid{ value: 1 ether }(address(stream), request, address(0));
        assertEq(stream.totalMinted(), 0);
        assertEq(alice.balance, before);
        assertEq(address(auction).balance, 0);
        policy.setMode(MockMintPolicy.Mode.OK);
        vm.prank(alice);
        uint256 saleId =
            auction.startWithBid{ value: 1 ether }(address(stream), request, address(0));
        assertEq(stream.ownerOf(1), address(auction));
        assertEq(auction.auction(saleId).bidder, alice);
    }

    // ----------------------------------------------------------------------------- credits

    /// A credit is claimed by its own account only: another account, the new high bidder
    /// included, has nothing to claim, even when it names the credited account as the receiver
    /// (AUC-18).
    function test_Claim_OnlyTheCreditedAccountClaimsItsCredit() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        _bid(bob, saleId, 2 ether);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NothingToClaim.selector, carol));
        auction.claim(carol);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NothingToClaim.selector, bob));
        auction.claim(alice);
        assertEq(auction.claimable(alice), 1 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        assertEq(auction.claim(alice), 1 ether);
        assertEq(alice.balance, before + 1 ether);
        assertEq(auction.claimable(alice), 0);
    }

    // -------------------------------------------------------------------------- settlement

    /// A settler that forwards too little gas for the payouts or the delivery is refused with
    /// `PaymentInsufficientGas` or `DeliveryInsufficientGas` and changes nothing; a settlement
    /// that lands pays both wallets directly and delivers the work, never leaving a payout in
    /// the escrow or a pending delivery for lack of the settler's gas (AUC-22).
    function test_Settle_RefusesASettlerThatWithholdsThePayoutOrDeliveryGas() public {
        BidderContract winner = new BidderContract(IEnglishAuction(address(auction)));
        uint256 saleId = _start(1);
        winner.bid{ value: 1 ether }(saleId, address(0));
        _end(saleId);
        uint256 ceiling = auction.DELIVERY_GAS() + 2 * auction.PAYOUT_GAS() + 200_000;
        uint256[4] memory seen;
        for (uint256 limit = 40_000; limit <= ceiling; limit += 2_500) {
            uint256 snapshot = vm.snapshotState();
            ++seen[_settleWith(saleId, address(winner), limit)];
            vm.revertToStateAndDelete(snapshot);
        }
        assertGt(seen[0], 0, "enough gas settles");
        assertGt(seen[1], 0, "a payout shortfall is refused");
        assertGt(seen[2], 0, "a delivery shortfall is refused");
    }

    /// @dev Calls `settle` with exactly `limit` gas and checks the outcome. Returns 0 when the
    ///      sale settled (paid directly and delivered to `winner`), 1 for a refused payout
    ///      shortfall, 2 for a refused delivery shortfall and 3 for running out of gas; a call
    ///      that fails changes nothing.
    function _settleWith(uint256 saleId, address winner, uint256 limit)
        internal
        returns (uint256 kind)
    {
        (bool ok, bytes memory data) = address(auction).call{ gas: limit }(
            abi.encodeCall(IEnglishAuction.settle, (saleId))
        );
        if (ok) {
            assertEq(stream.ownerOf(1), winner, "delivered");
            assertEq(auction.pendingDelivery(saleId), address(0), "no pending delivery");
            assertEq(seller.balance, 0.9 ether, "the seller is paid directly");
            assertEq(feeRecipient.balance, 0.1 ether, "the network is paid directly");
            assertEq(address(escrow).balance, 0, "nothing went to the escrow");
            return 0;
        }
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.ENDED));
        assertEq(stream.ownerOf(1), address(auction));
        assertEq(address(auction).balance, 1 ether);
        if (
            keccak256(data)
                == keccak256(
                    abi.encodeWithSelector(
                        RevenuePayment.PaymentInsufficientGas.selector, auction.PAYOUT_GAS()
                    )
                )
        ) return 1;
        if (bytes4(data) == IEnglishAuction.DeliveryInsufficientGas.selector) {
            assertEq(data.length, 4);
            return 2;
        }
        assertEq(data.length, 0, "any other failure is running out of gas");
        return 3;
    }

    /// An unsold 6529 Stream work is moved to the museum with a plain transfer: a museum that
    /// refuses every safe transfer still receives it, its receiver callback never runs, and no
    /// pending delivery is left (AUC-33).
    function test_Settle_AnUnsoldStreamWorkIsMovedWithoutAskingTheMuseum() public {
        BidderContract vault = new BidderContract(IEnglishAuction(address(auction)));
        vault.set(false, true, false);
        // A callback would run this call and record that it ran.
        vault.setReentry(abi.encodeCall(IEnglishAuction.claimable, (alice)));
        economics.setMuseum(economics.museumRevision(), address(vault));
        uint256 saleId = _start(1);
        _end(saleId);
        vm.expectCall(
            address(vault), abi.encodeWithSelector(IERC721Receiver.onERC721Received.selector), 0
        );
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), address(vault));
        assertFalse(vault.reentered(), "the receiver callback never ran");
        assertEq(uint256(stream.workOf(1).outcome), uint256(Outcome.UNSOLD));
        assertEq(auction.pendingDelivery(saleId), address(0));
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        vault.claimDelivery(saleId, carol);
    }

    // ---------------------------------------------------------------------------- disputes

    /// A resumed sale runs for the time that remained at the pause, and at least the longer of
    /// the duration and the anti-snipe window in force at the resumption (AUC-27).
    function testFuzz_Resume_RunsAtLeastTheLongerOfTheDurationAndTheWindow(
        uint256 elapsed,
        uint256 held,
        uint256 duration,
        uint256 window
    ) public {
        uint256 saleId = _start(1);
        IEnglishAuction.AuctionConfig memory c = auction.config();
        vm.warp(block.timestamp + bound(elapsed, 0, c.duration - 1));
        auction.pause(saleId, REF);
        uint256 remaining = auction.auction(saleId).endTime - block.timestamp;
        // The network changes the settings while the sale is paused, within the compiled bounds
        // (a duration of 1 hour to 7 days, a window of 1 minute to 1 day and at most the
        // duration).
        IEnglishAuction.AuctionConfig memory next = c;
        next.duration = uint32(bound(duration, 1 hours, 7 days));
        next.extensionWindow =
            uint32(bound(window, 1 minutes, next.duration < 1 days ? next.duration : 1 days));
        auction.setConfig(c, next);
        vm.warp(block.timestamp + bound(held, 0, auction.MAX_PAUSE()));
        auction.resume(saleId);
        uint256 left = auction.auction(saleId).endTime - block.timestamp;
        assertGe(left, next.duration, "at least the duration");
        assertGe(left, next.extensionWindow, "at least the window");
        assertGe(left, remaining, "at least the time that remained");
        assertTrue(
            left == next.duration || left == next.extensionWindow || left == remaining,
            "and no longer than the longest of the three"
        );
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.ACTIVE));
    }

    // ---------------------------------------------------------------------------- receiver

    /// The receiver callback answers only a mint the auction itself made during a start: the
    /// same callback outside a start, or one stating another operator or a previous owner, is
    /// refused (AUC-29).
    function test_OnERC721Received_AcceptsOnlyItsOwnMintDuringAStart() public {
        CallbackMintToken token = new CallbackMintToken();
        uint256 saleId = auction.start(address(token), abi.encode(uint256(1)));
        assertEq(token.answer(), IERC721Receiver.onERC721Received.selector);
        assertEq(token.ownerOf(1), address(auction));
        assertEq(auction.auction(saleId).token, address(token));
        bytes memory refused =
            abi.encodeWithSelector(IEnglishAuction.InvalidTarget.selector, address(token));
        vm.expectRevert(refused);
        token.offer(address(auction), address(auction), address(0), 2);
        token.state(alice, address(0));
        vm.expectRevert(refused);
        auction.start(address(token), abi.encode(uint256(2)));
        token.state(address(auction), alice);
        vm.expectRevert(refused);
        auction.start(address(token), abi.encode(uint256(3)));
        assertEq(token.minted(), 1);
    }

    // ------------------------------------------------------------------------- mint policy

    /// The mint policy decides new mints only. An answer that names an existing token's content
    /// is refused, any other answer mints a new token, and neither changes the existing token;
    /// once a work is minted, its sale, transfers, royalty and metadata never call the policy:
    /// they all work with a policy whose every call fails (AUC-38).
    function test_MintPolicy_DecidesNewMintsOnlyAndIsNeverCalledForAnExistingToken() public {
        OpenTermsPolicy open = new OpenTermsPolicy(seller, feeRecipient, FEE_SHARE);
        auction.setStreamPolicy(address(policy), address(open));
        uint256 sold = _start(1);
        _bid(alice, sold, 1 ether);
        uint256 unsold = _start(2);
        bytes32 content = open.factsOf(1).contentHash;
        bytes32 first = keccak256(abi.encode(stream.workOf(1)));
        bytes32 second = keccak256(abi.encode(stream.workOf(2)));

        // The policy now states another royalty for the same content and for new content.
        open.setRoyalty(address(0xBAD), 50_000);
        vm.expectRevert(abi.encodeWithSelector(IStream.ContentAlreadyMinted.selector, content, 1));
        _start(1);
        _start(3);
        assertEq(stream.workOf(3).royaltyReceiver, address(0xBAD));
        assertEq(keccak256(abi.encode(stream.workOf(1))), first, "token 1 unchanged");
        assertEq(keccak256(abi.encode(stream.workOf(2))), second, "token 2 unchanged");
        assertEq(stream.ownerOf(1), address(auction));

        // From here every call of the policy fails.
        vm.etch(address(open), hex"60006000fd");
        _afterThePolicyFails(sold, unsold);
    }

    /// @dev With a policy that fails every call: no start, and the sale, transfer, royalty and
    ///      metadata of the works already minted go on.
    function _afterThePolicyFails(uint256 sold, uint256 unsold) internal {
        (bool ok, bytes memory data) = address(auction)
            .call(abi.encodeCall(IEnglishAuction.start, (address(stream), abi.encode(uint256(4)))));
        assertFalse(ok, "no start without the policy");
        assertEq(data.length, 0);
        _end(sold);
        auction.settle(sold);
        auction.settle(unsold);
        assertEq(stream.ownerOf(1), alice);
        assertEq(stream.ownerOf(2), museum);
        assertEq(seller.balance, 0.9 ether);
        vm.prank(alice);
        stream.transferFrom(alice, bob, 1);
        assertEq(stream.ownerOf(1), bob);
        (address receiver, uint256 amount) = stream.royaltyInfo(1, DENOMINATOR);
        assertEq(receiver, address(0xFEE));
        assertEq(amount, 6529);
        assertEq(stream.tokenURI(1), "data:,mock");
    }

    // ----------------------------------------------------------------------------- refusal

    /// The refusal exit opens exactly at the sale's end plus the auction's compiled
    /// `REFUSAL_DELAY` of 2 days, which no setting moves (AUC-45, AUC-46).
    function test_SettleOrRefund_OpensAtTheEndPlusTheCompiledRefusalDelay() public {
        assertEq(auction.REFUSAL_DELAY(), 2 days);
        uint256 saleId = _startInd(1);
        _bid(alice, saleId, 1 ether);
        uint256 opensAt = auction.auction(saleId).endTime + auction.REFUSAL_DELAY();
        assertEq(auction.refusableAt(saleId), opensAt);
        IEnglishAuction.AuctionConfig memory c = auction.config();
        auction.setConfig(
            c,
            IEnglishAuction.AuctionConfig(
                c.duration * 2, c.extensionWindow * 2, c.incrementShare * 2, c.refusalGas * 2
            )
        );
        assertEq(auction.refusableAt(saleId), opensAt);
        vm.warp(opensAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuctionRefusal.RefusalTooEarly.selector, saleId, opensAt)
        );
        auction.settleOrRefund(saleId);
        vm.warp(opensAt);
        auction.settleOrRefund(saleId);
        assertEq(ind.ownerOf(1), alice);
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.SETTLED));
    }

    /// The refusal gas only rises, at most doubles in one step, and stays between the bounds
    /// compiled in the auction, 3,000,000 and 15,000,000, at construction too (AUC-47).
    function test_SetConfig_RefusalGasIsRaiseOnlyAtMostDoubledWithinItsBounds() public {
        uint32 lowest = 3_000_000;
        uint32 highest = 15_000_000;
        IEnglishAuction.AuctionConfig memory c = auction.config();
        assertEq(c.refusalGas, lowest);
        vm.expectRevert(IEnglishAuction.InvalidConfig.selector);
        _deploy(lowest - 1);
        vm.expectRevert(IEnglishAuction.InvalidConfig.selector);
        _deploy(highest + 1);
        assertEq(_deploy(highest).config().refusalGas, highest);

        IEnglishAuction.AuctionConfig memory next = c;
        while (c.refusalGas < highest) {
            next.refusalGas = c.refusalGas - 1;
            vm.expectRevert(IEnglishAuction.InvalidConfig.selector);
            auction.setConfig(c, next);
            next.refusalGas = c.refusalGas * 2 + 1;
            vm.expectRevert(IEnglishAuction.InvalidConfig.selector);
            auction.setConfig(c, next);
            next.refusalGas = c.refusalGas * 2 > highest ? highest : c.refusalGas * 2;
            auction.setConfig(c, next);
            assertEq(auction.config().refusalGas, next.refusalGas);
            c.refusalGas = next.refusalGas;
        }
        next.refusalGas = highest + 1;
        vm.expectRevert(IEnglishAuction.InvalidConfig.selector);
        auction.setConfig(c, next);
        next.refusalGas = highest - 1;
        vm.expectRevert(IEnglishAuction.InvalidConfig.selector);
        auction.setConfig(c, next);
        // Keeping the value is allowed: the other parameters change without it.
        next.refusalGas = highest;
        next.duration = c.duration * 2;
        auction.setConfig(c, next);
        assertEq(auction.config().refusalGas, highest);
    }

    /// @dev A new auction on the fixture's stack with `refusalGas` as its refusal gas.
    function _deploy(uint32 refusalGas) internal returns (EnglishAuction) {
        return new EnglishAuction(
            address(manager),
            address(stream),
            IDirectory(address(directory)),
            IEconomicsResolver(address(economics)),
            IRevenueEscrow(address(escrow)),
            IStatementLog(address(statements)),
            address(policy),
            IEnglishAuction.AuctionConfig(DURATION, WINDOW, SHARE, refusalGas)
        );
    }

    // ------------------------------------------------------------------ Independent Stream

    /// An Independent Stream sale's fee share is the Independent Stream module's answer, kept in
    /// the sale from its start: a later change of the module's share or of the resolver's share
    /// does not reach a running sale, and the fee goes to the recipient the economics resolver
    /// names at settlement (AUC-48).
    function test_Independent_TheFeeShareIsTheModulesKeptFromTheStart() public {
        assertTrue(economics.economics(PRODUCT_INDEPENDENT).feeShare != IND_FEE_SHARE);
        uint256 saleId = _startInd(1);
        assertEq(independentStream.feeShareOf(address(ind)), IND_FEE_SHARE);
        assertEq(auction.auction(saleId).feeShare, IND_FEE_SHARE);
        _bid(alice, saleId, 1 ether);
        independentStream.setTerms(SaleKind.ENGLISH_AUCTION, "", indSeller, IND_FEE_SHARE / 5);
        address later = makeAddr("laterIndependentFeeRecipient");
        (uint64 revision,,) = economics.revisions(PRODUCT_INDEPENDENT);
        economics.setFeeTerms(PRODUCT_INDEPENDENT, revision, later, IND_FEE_SHARE * 4);
        assertEq(auction.auction(saleId).feeShare, IND_FEE_SHARE);
        _end(saleId);
        auction.settle(saleId);
        uint256 sellerPart = 1 ether * (DENOMINATOR - IND_FEE_SHARE) / DENOMINATOR;
        assertEq(indSeller.balance, sellerPart);
        assertEq(later.balance, 1 ether - sellerPart);
        assertEq(feeRecipient.balance, 0);
        assertEq(ind.ownerOf(1), alice);
    }

    // ---------------------------------------------------------------------------- as built

    /// As built, a start reads the seller, the fee share, the sale kind and the parameters of
    /// the policy's terms and nothing else: terms that name the escrow as fee recipient and no
    /// creator start a sale, and its fee goes to the recipient the economics resolver names.
    function test_Start_ReadsNeitherTheFeeRecipientNorTheCreatorOfTheTerms() public {
        OpenTermsPolicy open = new OpenTermsPolicy(seller, feeRecipient, FEE_SHARE);
        open.setParties(address(escrow), address(0));
        auction.setStreamPolicy(address(policy), address(open));
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), alice);
        assertEq(seller.balance, 0.9 ether);
        assertEq(feeRecipient.balance, 0.1 ether);
        assertEq(address(escrow).balance, 0);
    }

    /// As built, a running sale follows the increment share, the increment floor and the
    /// anti-snipe window in force when a bid is placed, not the ones in force at its start.
    function test_Bid_ARunningSaleFollowsTheSettingsInForceWhenTheBidIsPlaced() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        IEnglishAuction.AuctionConfig memory c = auction.config();
        IEnglishAuction.AuctionConfig memory next = c;
        next.incrementShare = c.incrementShare * 2;
        next.extensionWindow = c.extensionWindow * 2;
        auction.setConfig(c, next);
        assertEq(auction.minimumBid(saleId), 1 ether + 1 ether * next.incrementShare / DENOMINATOR);
        (,, uint64 revision) = allowlist.assetConfig(address(0));
        allowlist.setIncrementFloor(address(0), revision, 0.5 ether);
        assertEq(auction.minimumBid(saleId), 1.5 ether);
        uint256 end = auction.auction(saleId).endTime;
        // Inside the new window and outside the one in force at the start.
        vm.warp(end - next.extensionWindow + 1);
        _bid(bob, saleId, 1.5 ether);
        assertEq(auction.auction(saleId).endTime, block.timestamp + next.extensionWindow);
    }
}
