// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Vm } from "forge-std/Vm.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { IUniformEditionAuctionStorage } from "src/interfaces/IUniformEditionAuctionStorage.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { UniformEditionAuctionLens } from "src/sales/UniformEditionAuctionLens.sol";
import { RefundReentrant } from "../../mocks/sales/AuctionMutationMocks.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice Behaviour of `UniformEditionAuctionBase` that the mutation campaign found unpinned:
///         the re-entry guard on the entry points that pay nobody, the target check of
///         `closeEdition`, the adapter's own state guard in `abandon`, the 1/1 end stored at
///         settlement, a refundless pushed claim, and two construction and configuration bounds.
contract UniformEditionAuctionMutationTest is EditionAuctionBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    /// @dev The 1/1 end sale `saleId` stores (`SaleWord.oneOfOneEnd`, bits 64-95).
    function _storedOneOfOneEnd(uint256 saleId) internal view returns (uint256) {
        return uint32(lens.storageWord(IUniformEditionAuctionStorage.Space.SALE, saleId, 0) >> 64);
    }

    // ------------------------------------------------------------------ re-entry

    /// @dev `open`, `adopt`, `bid`, `raise` and `expireCredit` are each refused by the guard
    ///      when called from inside a claim's refund, even by a caller the network trusts with
    ///      `adopt`.
    function test_Reentry_OpenAdoptBidRaiseAndExpireCreditAreRefusedDuringARefund() public {
        uint256 saleId = _open(0);
        RefundReentrant hostile = new RefundReentrant(address(auction));
        manager.grantRole(manager.ADMIN_ROLE(), address(hostile), 0);
        // A losing bid: its claim only refunds, through the ETH receive.
        uint256 bidId = _bid(saleId, address(hostile), 10, 1);
        _bid(saleId, alice, 200, 1);
        english.set(
            address(stream),
            8,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
        bytes memory data = _openData(_item(8, 0));
        hostile.arm(abi.encodeCall(IUniformEditionAuction.open, (address(editions), 8, data)));
        hostile.arm(abi.encodeCall(IUniformEditionAuction.adopt, (address(editions), 8, data)));
        hostile.arm(abi.encodeCall(IUniformEditionAuction.bid, (saleId, 0, 1)));
        hostile.arm(abi.encodeCall(IUniformEditionAuction.raise, (saleId, bidId, 20)));
        hostile.arm(
            abi.encodeCall(IUniformEditionAuction.expireCredit, (address(hostile), CURRENCY_ETH))
        );
        _settle(saleId);
        uint256 refund = _price(saleId, 10);
        vm.prank(address(hostile));
        auction.claimBid(saleId, bidId, address(hostile));
        assertEq(hostile.attempts(), 5, "every call was tried");
        for (uint256 i; i < 5; ++i) {
            assertFalse(hostile.succeeded(i), vm.toString(i));
            assertEq(
                hostile.answers(i),
                ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
                vm.toString(i)
            );
        }
        assertEq(address(hostile).balance, refund, "refunded all the same");
    }

    // ------------------------------------------------------------------ closeEdition

    /// @dev `closeEdition` seals only on the token this adapter sells, and only while listed.
    function test_CloseEdition_RefusesAnotherTokenAndAnUnlistedOne() public {
        address other = makeAddr("otherEditions");
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, other));
        auction.closeEdition(other, ID);
        auction.setTarget(address(editions), false);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(editions))
        );
        auction.closeEdition(address(editions), ID);
    }

    // ------------------------------------------------------------------ abandon

    /// @dev The adapter's own state rule: a sale that has cleared and paid (SETTLING with its
    ///      scan done, then SETTLED) is never voided, even when the lens lets the call through
    ///      (its `checkAbandon` is answered here by a mock that refuses nothing).
    function test_Abandon_APaidSaleIsNeverVoidedWhateverTheLensAnswers() public {
        uint256 saleId = _open(2);
        uint256 raised = _bid(saleId, alice, 10, 1);
        _raise(saleId, raised, 20);
        _bid(saleId, bob, 10, 2);
        _bid(saleId, carol, 10, 2);
        _closeOneOfOne(saleId);
        // Cleared and paid at step 10, rationed; its one departure is not swept yet.
        uint256 sellerBefore = seller.balance;
        assertFalse(auction.settle(saleId, new uint256[](0)));
        assertGt(seller.balance, sellerBefore, "paid");
        vm.mockCall(
            lensAddress,
            abi.encodeWithSelector(IUniformEditionAuctionLens.checkAbandon.selector),
            ""
        );
        vm.warp(block.timestamp + 400 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.InvalidAuctionState.selector,
                saleId,
                IUniformEditionAuction.AuctionStatus.SETTLING
            )
        );
        auction.abandon(saleId);
        assertTrue(auction.settle(saleId, lens.settlementOrderFor(saleId, address(this))));
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.InvalidAuctionState.selector,
                saleId,
                IUniformEditionAuction.AuctionStatus.SETTLED
            )
        );
        auction.abandon(saleId);
        // A sale never opened is refused by its state too.
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.InvalidAuctionState.selector,
                uint256(12_345),
                IUniformEditionAuction.AuctionStatus.NONE
            )
        );
        auction.abandon(12_345);
        assertEq(_claimAll(saleId), 2, "the winners still claim their copies");
    }

    /// @dev A sale abandoned while its scan was in progress is VOID for good: the adapter's
    ///      state rule refuses a second abandonment whatever the lens answers.
    function test_Abandon_ASaleAbandonedMidScanIsNotAbandonedAgain() public {
        uint256 saleId = _wideBook();
        vm.mockCall(
            lensAddress,
            abi.encodeWithSelector(IUniformEditionAuctionLens.checkAbandon.selector),
            ""
        );
        vm.warp(block.timestamp + 400 days);
        auction.abandon(saleId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.InvalidAuctionState.selector,
                saleId,
                IUniformEditionAuction.AuctionStatus.VOID
            )
        );
        auction.abandon(saleId);
    }

    /// @dev A closed sale whose book spans more words than one settle call scans, after its
    ///      first settle call: SETTLING with the scan in progress.
    function _wideBook() internal returns (uint256 saleId) {
        saleId = _open(0);
        _bid(saleId, alice, 0, 1);
        _bid(saleId, bob, 300, 1);
        _closeOneOfOne(saleId);
        assertFalse(auction.settle(saleId, new uint256[](0)), "the scan is in progress");
    }

    // ------------------------------------------------------------------ settlement

    /// @dev A scan that takes two calls carries the demand it counted in the first call into the
    ///      second: the stored result is the whole book's, as the lens computes it in one pass.
    function test_Settle_AResumedScanKeepsTheDemandAlreadyCounted() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 335, 1); // the book spans more than 24 words
        // Enough copies at the lowest step that selling to both bidders there earns the most.
        uint256 low = 2 * _price(saleId, 335) / _price(saleId, 0);
        _bid(saleId, bob, 0, low);
        IUniformEditionAuction.Clearing memory c = ua.clearing(saleId);
        assertEq(c.count, low + 1, "both bids win at the lowest step");
        assertEq(c.step, 0);
        _closeOneOfOne(saleId);
        assertFalse(auction.settle(saleId, new uint256[](0)), "the first scan call");
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLING)
        );
        _settle(saleId);
        IUniformEditionAuction.Settlement memory s = ua.settlement(saleId);
        assertEq(s.count, low + 1, "the demand of the first call is kept");
        assertEq(s.step, 0);
        assertEq(s.price, _price(saleId, 0));
    }

    /// @dev A 1/1 end that moved after the last bid (placed far from the close, so the cached
    ///      end was not refreshed) is stored by the first settle call.
    function test_Settle_StoresTheOneOfOneEndItRead() public {
        uint256 saleId = _open(0);
        uint256 firstEnd = block.timestamp + 1 days;
        _bid(saleId, alice, 10, 1);
        english.set(
            address(stream), ID, IEnglishAuction.AuctionState.ACTIVE, uint64(firstEnd + 1 hours)
        );
        assertEq(_storedOneOfOneEnd(saleId), firstEnd, "the cached end");
        _settle(saleId);
        assertEq(_storedOneOfOneEnd(saleId), firstEnd + 1 hours, "the end settlement read");
    }

    /// @dev Only the first settle call reads the 1/1: a scan in progress finishes when the
    ///      English auction no longer answers.
    function test_Settle_OnceBegunNoLongerReadsTheOneOfOne() public {
        uint256 saleId = _wideBook();
        english.setRefuseClock(true);
        assertTrue(auction.settle(saleId, new uint256[](0)));
        assertEq(editions.editionOf(ID).maxSupply, 1, "cleared: sealed at the one copy sold");
    }

    /// @dev A sweep index must name a departure of the clearing step. An index far past its
    ///      log, chosen so that the entry read is the head word of the next step's log (step
    ///      11's, with a departure of its own), is refused like any other.
    function test_Settle_RefusesAnIndexThatReachesAnotherStepsDepartureLog() public {
        uint256 saleId = _open(3);
        uint256 first = _bid(saleId, alice, 10, 1);
        _raise(saleId, first, 20);
        uint256 second = _bid(saleId, alice, 11, 1);
        _raise(saleId, second, 20);
        _bid(saleId, bob, 10, 2);
        _bid(saleId, carol, 10, 2);
        _closeOneOfOne(saleId);
        // Cleared at step 10, rationed; its one departure waits to be swept.
        assertFalse(auction.settle(saleId, new uint256[](0)));
        uint256[] memory order = new uint256[](1);
        order[0] = 3 + ((uint256(1) << 32) - 1) * 4;
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.InvalidSettlementOrder.selector, 0)
        );
        auction.settle(saleId, order);
        assertTrue(auction.settle(saleId, lens.settlementOrderFor(saleId, address(this))));
        assertEq(_claimAll(saleId), 3);
        assertEq(editions.balanceOf(bob, ID), 1, "bob, first in line at the cut, wins one");
    }

    // ------------------------------------------------------------------ bidding

    /// @dev Bid IDs run to 2^32 - 1 inclusive (the count is set here in storage: the sale
    ///      word, bits 224-255).
    function test_Bid_TheLastBidIdIsAccepted() public {
        uint256 saleId = _open(0);
        bytes32 slot = keccak256(abi.encode(saleId, uint256(3)));
        uint256 word = uint256(vm.load(address(auction), slot));
        assertEq(word >> 224, 0, "the sale word: no bid yet");
        vm.store(address(auction), slot, bytes32(word | uint256(type(uint32).max - 1) << 224));
        assertEq(_bid(saleId, alice, 10, 1), type(uint32).max);
    }

    /// @dev A bid exactly a soft window before the end extends nothing: no soft end is stored.
    function test_Bid_ExactlyASoftWindowBeforeTheEndStoresNoSoftEnd() public {
        uint256 saleId = _open(0);
        uint256 closeAt = block.timestamp + 1 days + 15 minutes;
        vm.warp(closeAt - 5 minutes);
        _bid(saleId, alice, 10, 1);
        uint256 word = lens.storageWord(IUniformEditionAuctionStorage.Space.SALE, saleId, 0);
        assertEq(uint32(word >> 96), 0, "no soft end");
        assertEq(ua.endTimes(saleId).endTime, closeAt);
    }

    /// @dev The clock is 32 bits: a soft end at its last second, 2^32 - 1, is still stored.
    function test_Bid_ASoftEndAtTheLastClockSecondIsAccepted() public {
        uint256 last = type(uint32).max;
        vm.warp(last - 5 minutes - 1000);
        english.set(
            address(stream), ID, IEnglishAuction.AuctionState.ACTIVE, uint64(last - 5 minutes - 800)
        );
        uint256 saleId = _open(0);
        vm.warp(last - 5 minutes);
        _bid(saleId, alice, 10, 1);
        uint256 word = lens.storageWord(IUniformEditionAuctionStorage.Space.SALE, saleId, 0);
        assertEq(uint32(word >> 96), last, "the soft end");
    }

    // ------------------------------------------------------------------ claims

    /// @dev An aged credit may be expired at any time from its expiry, not only at it.
    function test_ExpireCredit_AnyTimeAfterTheExpiry() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 100, 1);
        uint256 bidId = _bid(saleId, bob, 0, 1);
        _settle(saleId);
        auction.claimBidFor(saleId, bidId);
        uint256 credit = ua.claimable(bob, CURRENCY_ETH);
        assertEq(credit, _price(saleId, 0));
        vm.warp(lens.creditExpiresAt(bob) + 1);
        uint256 feeBefore = networkFee.balance;
        assertEq(auction.expireCredit(bob, CURRENCY_ETH), credit);
        assertEq(networkFee.balance - feeBefore, credit, "sent to the network");
        assertEq(ua.claimable(bob, CURRENCY_ETH), 0);
    }

    /// @dev A pushed claim with no refund (a winner at the clearing price) credits nothing: no
    ///      `Credited` event and no credit word.
    function test_ClaimBidFor_WithoutARefundCreditsNothing() public {
        uint256 saleId = _open(0);
        uint256 bidId = _bid(saleId, alice, 10, 2);
        _settle(saleId);
        vm.recordLogs();
        vm.prank(bob);
        (uint256 won, uint256 refund) = auction.claimBidFor(saleId, bidId);
        assertEq(won, 2);
        assertEq(refund, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != ISaleAdapter.Credited.selector, "no Credited event");
        }
        assertEq(
            lens.storageWord(IUniformEditionAuctionStorage.Space.CREDIT, 0, uint160(alice)),
            0,
            "no credit word"
        );
        assertEq(editions.balanceOf(alice, ID), 2);
    }

    // ------------------------------------------------------------------ construction, config

    /// @dev The English auction must have code, also when the lens was deployed for the same
    ///      address.
    function test_Constructor_RejectsAnEnglishAuctionWithoutCode() public {
        address none = makeAddr("noEnglishAuction");
        address l = address(
            new UniformEditionAuctionLens(
                address(editions),
                address(stream),
                none,
                address(escrow),
                address(directory),
                address(economics),
                address(stream)
            )
        );
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, none));
        new UniformEditionAuction(
            address(manager),
            address(escrow),
            address(directory),
            address(editions),
            none,
            l,
            l.codehash,
            defaultConfig(),
            defaultLimits()
        );
    }

    /// @dev `setLimits` is compare-and-set in both directions (an expected value above the
    ///      current one is refused too), and setting the current payout gas again is allowed.
    function test_SetLimits_RefusesAHigherExpectedValueAndAcceptsTheCurrentGas() public {
        uint256 current = ua.limits().payoutGas;
        vm.expectRevert(ISaleAdapter.ExpectedValueMismatch.selector);
        auction.setLimits(current + 1, current + 2);
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.LimitsSet(current, current);
        auction.setLimits(current, current);
        assertEq(ua.limits().payoutGas, current);
    }

    /// @dev The interning counter is 24 bits: once it is full, `setConfig` is refused with
    ///      `InvalidConfig` (the counter is set here in storage: slot 1, bits 24-47).
    function test_SetConfig_RefusedOnceTheTermsCounterIsFull() public {
        uint256 settings = uint256(vm.load(address(auction), bytes32(uint256(1))));
        assertEq(uint24(settings >> 24), 1, "the settings word: one record so far");
        vm.store(address(auction), bytes32(uint256(1)), bytes32(settings | uint256(0xffffff) << 24));
        IUniformEditionAuction.AuctionConfig memory current = ua.config();
        IUniformEditionAuction.AuctionConfig memory next = defaultConfig();
        next.marginShare = 20_000;
        vm.expectRevert(IUniformEditionAuction.InvalidConfig.selector);
        auction.setConfig(current, next);
    }
}
