// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { LooseEconomics, SafeMintingToken } from "test/mocks/sales/AuctionMutationMocks.sol";
import { AuctionFixture } from "./AuctionFixture.sol";
import { MockMintPolicy } from "./AuctionMocks.sol";

/// @notice Behaviour the mutation campaign found unpinned: refunds of a bid with a named
///         recipient, the delivery gas check, restart's reset, exact refusals and boundaries.
contract EnglishAuctionMutationTest is AuctionFixture {
    bytes32 internal constant REF = keccak256("dispute");
    bytes32 internal constant OUTCOME = keccak256("outcome");

    // ----------------------------------------------------------------------------- refunds

    /// @notice Withdrawing a bid placed for someone else credits the bidder and clears the
    ///         recipient.
    function test_WithdrawBid_ABidForARecipientIsCreditedAndTheRecipientCleared() public {
        uint256 saleId = _start(1);
        vm.prank(alice);
        auction.bid{ value: 1 ether }(saleId, carol);
        auction.pause(saleId, REF);
        vm.prank(alice);
        auction.withdrawBid(saleId);
        assertEq(auction.claimable(alice), 1 ether);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.bidder, address(0));
        assertEq(a.recipient, address(0), "no bidder, no recipient");
    }

    /// @notice A delisted token's sale refunds a bid placed for someone else.
    function test_Settle_ADelistedSaleRefundsABidForARecipient() public {
        uint256 saleId = _startInd(1);
        vm.prank(alice);
        auction.bid{ value: 1 ether }(saleId, carol);
        independentStream.setMinter(address(ind), address(auction), false);
        _end(saleId);
        auction.settle(saleId);
        assertEq(auction.claimable(alice), 1 ether);
        assertEq(auction.claimable(carol), 0);
        assertEq(auction.auction(saleId).recipient, address(0));
        assertEq(ind.ownerOf(1), address(auction));
    }

    // -------------------------------------------------------------------------- settlement

    /// @notice A settlement that cannot give the delivery its full gas reverts; it never
    ///         delivers with less and never leaves a pending delivery for want of gas.
    function test_Settle_AGasShortfallRevertsInsteadOfDeliveringWithLess() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        bool refused;
        bool settled;
        for (uint256 gasLimit = 100_000; gasLimit <= 1_500_000; gasLimit += 20_000) {
            bytes memory data;
            (settled, data) = address(auction).call{ gas: gasLimit }(
                abi.encodeCall(IEnglishAuction.settle, (saleId))
            );
            if (settled) break;
            if (
                data.length == 4 && bytes4(data) == IEnglishAuction.DeliveryInsufficientGas.selector
            ) refused = true;
        }
        assertTrue(refused, "a shortfall is refused by name");
        assertTrue(settled);
        assertEq(stream.ownerOf(1), alice);
        assertEq(auction.pendingDelivery(saleId), address(0));
    }

    /// @notice With a zero network share nobody is named as the fee recipient.
    function test_Settle_AZeroFeeNamesNoFeeRecipient() public {
        policy.setTerms(SaleKind.ENGLISH_AUCTION, "", seller, 0);
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.SaleSettled(
            saleId,
            address(stream),
            1,
            alice,
            alice,
            1,
            address(0),
            1 ether,
            seller,
            1 ether,
            address(0),
            0
        );
        auction.settle(saleId);
        assertEq(seller.balance, 1 ether);
        assertEq(feeRecipient.balance, 0);
    }

    /// @notice A fee with no recipient to take it stops the settlement by the auction's own
    ///         error.
    function test_Settle_AFeeWithNoRecipientIsRefused() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        (uint64 feeRevision,,) = economics.revisions(PRODUCT_STREAM);
        economics.setFeeTerms(PRODUCT_STREAM, feeRevision, address(0), 0);
        _end(saleId);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.InvalidRecipient.selector, address(0))
        );
        auction.settle(saleId);
        assertEq(address(auction).balance, 1 ether);
    }

    // ----------------------------------------------------------------------------- restart

    /// @notice A restart forgets the last sale's bid: the old amount is no reserve.
    function test_Restart_ForgetsTheRefundedBid() public {
        uint256 saleId = _startInd(1);
        _bid(alice, saleId, 1 ether);
        independentStream.setMinter(address(ind), address(auction), false);
        _end(saleId);
        auction.settle(saleId);
        assertEq(auction.auction(saleId).bid, 1 ether, "the refunded amount stays until restart");
        independentStream.setMinter(address(ind), address(auction), true);
        auction.restart(saleId);
        assertEq(auction.auction(saleId).bid, 0);
        assertLt(auction.minimumBid(saleId), 1 ether);
        _bid(bob, saleId, 0.5 ether);
        assertEq(auction.auction(saleId).bidder, bob);
    }

    /// @notice A restart refuses a network share above the whole.
    function test_Restart_RefusesAShareAboveTheWhole() public {
        uint256 saleId = _startInd(1);
        _end(saleId);
        auction.settle(saleId);
        independentStream.setTerms(SaleKind.ENGLISH_AUCTION, "", indSeller, 100_001);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.InvalidSaleTerms.selector, address(ind), 1)
        );
        auction.restart(saleId);
        independentStream.setTerms(SaleKind.ENGLISH_AUCTION, "", indSeller, 100_000);
        auction.restart(saleId);
        assertEq(auction.auction(saleId).feeShare, 100_000);
    }

    /// @notice A cancelled sale does not restart, and says so by its state.
    function test_Restart_RefusesACancelledSale() public {
        uint256 saleId = _startInd(1);
        auction.pause(saleId, REF);
        statements.setOutcome(address(ind), 1, OUTCOME, 0);
        auction.cancel(saleId, OUTCOME);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.CANCELLED
            )
        );
        auction.restart(saleId);
    }

    // ------------------------------------------------------------------------------- start

    /// @notice Only the English auction sale kind starts, whichever side of it another kind is.
    function test_Start_RefusesEveryOtherSaleKind() public {
        bytes32[3] memory kinds = [
            bytes32(0),
            bytes32(uint256(SaleKind.ENGLISH_AUCTION) - 1),
            bytes32(uint256(SaleKind.ENGLISH_AUCTION) + 1)
        ];
        for (uint256 i; i < kinds.length; ++i) {
            policy.setTerms(kinds[i], "", seller, 0);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IEnglishAuction.InvalidSaleTerms.selector, address(stream), 0
                )
            );
            _start(1);
        }
        assertEq(stream.totalMinted(), 0);
    }

    /// @notice A policy cannot re-enter the auction from a start that carries a bid.
    function test_StartWithBid_APolicyCannotReenter() public {
        uint256 ended = _start(1);
        _end(ended);
        policy.setMode(MockMintPolicy.Mode.REENTER);
        policy.setReentry(abi.encodeCall(IEnglishAuction.settle, (ended)));
        vm.prank(alice);
        uint256 saleId =
            auction.startWithBid{ value: 1 ether }(address(stream), abi.encode(2), address(0));
        assertFalse(policy.reentered());
        assertEq(uint256(_state(ended)), uint256(IEnglishAuction.AuctionState.ENDED));
        assertEq(stream.ownerOf(1), address(auction));
        assertEq(auction.auction(saleId).bidder, alice);
    }

    /// @notice A token that mints with a receiver callback is accepted during a start.
    function test_OnERC721Received_AcceptsAMintIntoCustodyDuringAStart() public {
        SafeMintingToken t = new SafeMintingToken();
        uint256 saleId = auction.start(address(t), abi.encode(1));
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(t.ownerOf(1), address(auction));
    }

    // ---------------------------------------------------------------------------- disputes

    /// @notice A resumed sale keeps the time it had left when that is longer than the duration
    ///         in force now.
    function test_Resume_KeepsTheRemainingTimeWhenLongerThanTheDuration() public {
        uint256 saleId = _start(1);
        IEnglishAuction.AuctionConfig memory c = auction.config();
        auction.setConfig(c, IEnglishAuction.AuctionConfig(1 hours, WINDOW, SHARE, REFUSAL_GAS));
        vm.warp(block.timestamp + 1 hours);
        auction.pause(saleId, REF);
        vm.warp(block.timestamp + 2 hours);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionResumed(saleId, uint64(block.timestamp + 23 hours));
        auction.resume(saleId);
        assertEq(auction.auction(saleId).endTime, block.timestamp + 23 hours);
    }

    // -------------------------------------------------------------------------- governance

    /// @notice `setConfig` compares every parameter: one stale value, on either side of the
    ///         value in force, refuses the change.
    function test_SetConfig_EachParameterIsComparedExactly() public {
        IEnglishAuction.AuctionConfig memory next =
            IEnglishAuction.AuctionConfig(2 days, 1 hours, 10_000, 6_000_000);
        for (uint256 field; field < 4; ++field) {
            for (uint256 up; up < 2; ++up) {
                IEnglishAuction.AuctionConfig memory expected = auction.config();
                if (field == 0) expected.duration = up == 1 ? DURATION + 1 : DURATION - 1;
                if (field == 1) expected.extensionWindow = up == 1 ? WINDOW + 1 : WINDOW - 1;
                if (field == 2) expected.incrementShare = up == 1 ? SHARE + 1 : SHARE - 1;
                if (field == 3) {
                    expected.refusalGas = up == 1 ? REFUSAL_GAS + 1 : REFUSAL_GAS - 1;
                }
                vm.expectRevert(IEnglishAuction.ExpectedValueMismatch.selector);
                auction.setConfig(expected, next);
            }
        }
        assertEq(auction.config().duration, DURATION);
    }

    /// @notice The constructor refuses an economics resolver that does not declare the
    ///         interface, an asset allowlist without code and a statement log without code.
    function test_Constructor_ChecksTheResolverTheAllowlistAndTheStatementLog() public {
        LooseEconomics undeclared = new LooseEconomics(address(allowlist), false);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(undeclared))
        );
        _deploy(address(undeclared), address(statements));
        LooseEconomics noAllowlist = new LooseEconomics(alice, true);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, alice));
        _deploy(address(noAllowlist), address(statements));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, bob));
        _deploy(address(economics), bob);
        // The same stand-in, declaring the interface and naming a real allowlist, is accepted.
        LooseEconomics good = new LooseEconomics(address(allowlist), true);
        EnglishAuction deployed = _deploy(address(good), address(statements));
        assertEq(address(deployed.allowlist()), address(allowlist));
    }

    function _deploy(address economics_, address statementLog_) internal returns (EnglishAuction) {
        return new EnglishAuction(
            address(manager),
            address(stream),
            IDirectory(address(directory)),
            IEconomicsResolver(economics_),
            IRevenueEscrow(address(escrow)),
            IStatementLog(statementLog_),
            address(policy),
            IEnglishAuction.AuctionConfig(DURATION, WINDOW, SHARE, REFUSAL_GAS)
        );
    }
}
