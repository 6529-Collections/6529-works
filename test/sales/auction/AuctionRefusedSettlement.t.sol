// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEnglishAuctionRefusal } from "src/interfaces/IEnglishAuctionRefusal.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
import {
    Payment,
    PaymentMethod,
    PrimarySettlement,
    PrimaryTerms,
    SaleKind
} from "src/interfaces/types/SaleTypes.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { HostileActor } from "../../mocks/sales/AuctionMocks.sol";
import { BurningToken, HostileMintTarget } from "../../mocks/sales/HostileMintTarget.sol";
import { MockFederationRegistry } from "../../mocks/sales/SaleMocks.sol";
import { AuctionBase } from "./AuctionBase.sol";

/// @dev Runs `settleOrRefund` from inside the escrow's guarded `flush`, which pays this contract.
contract EscrowReentrant {
    address internal immutable auction;
    uint256 internal saleId;
    bool public reverted;
    bytes public reason;

    constructor(address auction_) {
        auction = auction_;
    }

    function arm(uint256 saleId_) external {
        saleId = saleId_;
    }

    receive() external payable {
        (bool ok, bytes memory data) = auction.call{ gas: gasleft() - 50_000 }(
            abi.encodeCall(IEnglishAuctionRefusal.settleOrRefund, (saleId))
        );
        (reverted, reason) = (!ok, data);
    }
}

/// @dev A wallet or recipient with its own reentrancy guard: while it runs `act` (a third party
///      holding its guard), it refuses ETH and tokens, as a guarded split ledger or vault might.
contract GuardedParty {
    bool internal _entered;
    bool public lastOk;
    bytes public lastResult;

    function act(address target, bytes calldata data) external {
        _entered = true;
        (lastOk, lastResult) = target.call{ gas: 12_000_000 }(data);
        _entered = false;
    }

    receive() external payable {
        require(!_entered, "guarded");
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        require(!_entered, "guarded");
        return this.onERC721Received.selector;
    }
}

/// @notice LIM-SAL-16 solved (AUC-38 to AUC-41): a sale whose token will not let it settle
///         reaches a terminal state through `settleOrRefund`, without taking the bidder's funds,
///         without giving the work away unpaid, without redirecting the network fee, and without
///         touching any other sale; a token that settles is never affected. Federated sales
///         only: a listed token's sale, 6529 Stream's included, is never refused (AUC-38).
contract AuctionRefusedSettlementTest is AuctionBase {
    /// @dev Every call into a token that may burn its gas is given this much, so a burner ends.
    uint256 internal constant KEEPER_GAS = 10_000_000;
    uint256 internal constant BID = 1 ether;

    HostileMintTarget internal hostile;
    MockFederationRegistry internal registry;

    function setUp() public override {
        super.setUp();
        hostile = _hostile(true);
    }

    // ------------------------------------------------------------------ fixtures

    /// @dev A hostile token on `_terms(ETH)`: listed by governance, or federated (registered
    ///      ACTIVE with a 10% fee).
    function _hostile(bool federated) internal returns (HostileMintTarget h) {
        h = new HostileMintTarget();
        h.setAdmittedMinter(address(auction), true);
        h.setTerms(_terms(ETH));
        h.setLiar(makeAddr("liar"));
        if (!federated) {
            vm.prank(successor);
            auction.setTarget(address(h), true);
            return h;
        }
        if (address(registry) == address(0)) {
            registry = new MockFederationRegistry();
            vm.prank(successor);
            auction.setFederationRegistry(address(0), address(registry));
        }
        registry.register(
            address(h),
            IFederationRegistry.Entry(
                IFederationRegistry.Form.ERC721,
                address(0),
                uint160(artist),
                1,
                address(h).codehash,
                10_000,
                IFederationRegistry.Status.ACTIVE
            )
        );
    }

    /// @dev A sale of `h` with `BID` from alice, ended.
    function _endedSale(HostileMintTarget h, bool withBid) internal returns (uint256 saleId) {
        saleId = auction.start(address(h), "");
        if (withBid) _bidEth(saleId, alice, BID);
        _end(saleId);
    }

    function _refusable(uint256 saleId) internal {
        vm.warp(auction.refusableAt(saleId));
    }

    function _settleOrRefund(uint256 saleId) internal {
        auction.settleOrRefund{ gas: KEEPER_GAS }(saleId);
    }

    /// @dev The state a refused sale ends in: SETTLED, the bid credited back to alice, nothing
    ///      reported to the token or paid, the work in custody as a delivery its artist claims.
    function _assertRefused(HostileMintTarget h, uint256 saleId, bool withBid) internal {
        uint256 tokenId = _tokenIdOf(saleId);
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.SETTLED), "terminal");
        assertEq(auction.claimable(alice, ETH), withBid ? BID : 0, "the bid is credited back");
        assertEq(address(auction).balance, withBid ? BID : 0, "the auction holds only the credit");
        assertEq(seller.balance, 0, "the seller is not paid");
        assertEq(network.balance + federatedNetwork.balance, 0, "no fee without a sale");
        assertFalse(h.primarySettled(tokenId), "nothing reported to the token");
        assertEq(h.holderOf(tokenId), address(auction), "the work stays in custody");
        assertEq(auction.auction(saleId).bidder, address(0), "no winner");
        // The lens reports the delivery as pending for the artist the token names (the no-bid
        // path `claimDelivery` admits), never as none (automated review, 16 November 2026).
        assertEq(auction.pendingDelivery(saleId), artist, "pending for the artist");
        // The former bidder cannot take the work; the artist the token names can.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        auction.claimDelivery(saleId, alice);
    }

    function _artistClaims(HostileMintTarget h, uint256 saleId) internal {
        address to = makeAddr("artistVault");
        vm.prank(artist);
        auction.claimDelivery(saleId, to);
        assertEq(h.holderOf(_tokenIdOf(saleId)), to, "the artist took the work back");
    }

    // ------------------------------------------------- a token that settles: unchanged

    /// @dev Settling a cooperating federated token through `settleOrRefund` gives exactly what
    ///      `settle` gives: the same events, balances and state, with a bid, with no bid, in ERC-20.
    function test_ACooperatingTokenSettlesExactlyAsSettle() public {
        for (uint256 mode; mode < 3; ++mode) {
            HostileMintTarget coop = _hostile(true);
            if (mode == 2) coop.setTerms(_terms(address(usd)));
            uint256 saleId = auction.start(address(coop), "");
            if (mode == 0) _bidEth(saleId, alice, BID);
            if (mode == 2) _bidUsd(saleId, alice, 100e18);
            _end(saleId);
            _refusable(saleId);
            uint256 snapshot = vm.snapshotState();
            vm.recordLogs();
            auction.settle(saleId);
            Vm.Log[] memory viaSettle = vm.getRecordedLogs();
            bytes32 stateA = _fingerprint(coop, saleId);
            vm.revertToState(snapshot);
            vm.recordLogs();
            auction.settleOrRefund(saleId);
            Vm.Log[] memory viaExit = vm.getRecordedLogs();
            assertEq(keccak256(abi.encode(viaExit)), keccak256(abi.encode(viaSettle)), "events");
            assertEq(_fingerprint(coop, saleId), stateA, "state and balances");
        }
    }

    function _fingerprint(HostileMintTarget h, uint256 saleId) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                auction.auction(saleId),
                h.holderOf(_tokenIdOf(saleId)),
                seller.balance,
                federatedNetwork.balance,
                usd.balanceOf(seller),
                usd.balanceOf(federatedNetwork),
                auction.claimable(alice, ETH),
                address(auction).balance
            )
        );
    }

    /// @dev F1: a listed token's sale is never refused, 6529 Stream's (here its mock) included,
    ///      whatever its settlement does: it settles only through `settle`.
    function test_AListedTokensSaleIsNeverRefused() public {
        HostileMintTarget listed = _hostile(false);
        listed.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.REVERT);
        uint256 listedSale = _endedSale(listed, true);
        uint256 streamSale = _start();
        _bidEth(streamSale, bob, BID);
        _end(streamSale);
        vm.warp(block.timestamp + 365 days);
        uint256[2] memory sales_ = [listedSale, streamSale];
        for (uint256 i; i < 2; ++i) {
            bytes memory refused =
                abi.encodeWithSelector(IEnglishAuctionRefusal.SaleNotRefusable.selector, sales_[i]);
            vm.expectRevert(refused);
            _settleOrRefund(sales_[i]);
            vm.expectRevert(refused);
            auction.refusableAt(sales_[i]);
        }
        assertEq(auction.claimable(alice, ETH), 0, "nothing credited");
        auction.settle(streamSale);
        assertEq(stream.ownerOf(_tokenIdOf(streamSale)), bob, "6529 Stream settles as ever");
    }

    // ------------------------------------------------------------ preconditions

    function test_RefusedBeforeTheDelay() public {
        hostile.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.REVERT);
        uint256 saleId = _endedSale(hostile, true);
        uint256 allowedAt = auction.auction(saleId).endTime + REFUSAL_DELAY;
        assertEq(auction.refusableAt(saleId), allowedAt, "end plus the current delay");
        vm.warp(allowedAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuctionRefusal.RefusalTooEarly.selector, saleId, allowedAt
            )
        );
        _settleOrRefund(saleId);
        vm.warp(allowedAt);
        _settleOrRefund(saleId);
        _assertRefused(hostile, saleId, true);
    }

    function test_OnlyAnEndedSale() public {
        uint256 unknown = uint256(keccak256("no sale"));
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnknownSale.selector, unknown));
        _settleOrRefund(unknown);
        uint256 saleId = auction.start(address(hostile), "");
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ACTIVE
            )
        );
        _settleOrRefund(saleId);
        _end(saleId);
        _refusable(saleId);
        _settleOrRefund(saleId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.SETTLED
            )
        );
        _settleOrRefund(saleId);
    }

    /// @dev A currency freeze is the auction's own wait (MARKET-2, RFX-SAL-2): the exit does not
    ///      shorten it, and after the freeze exit it ends the sale as `settle` would.
    function test_AFrozenCurrencyWaitsForItsExit() public {
        hostile.setTerms(_terms(address(usd)));
        hostile.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.REVERT);
        uint256 saleId = auction.start(address(hostile), "");
        _bidUsd(saleId, alice, 100e18);
        _end(saleId);
        _refusable(saleId);
        allowlist.deprecateAsset(address(usd));
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, address(usd))
        );
        _settleOrRefund(saleId);
        vm.warp(block.timestamp + 60 days);
        _settleOrRefund(saleId);
        assertEq(auction.claimable(alice, address(usd)), 100e18, "credited back");
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.SETTLED));
    }

    /// @dev AUC-40: a caller that cannot forward the refusal gas in full is refused before
    ///      anything happens, so a shortfall can never be taken for a refusal.
    function test_TheCallerMustForwardTheRefusalGas() public {
        hostile.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.BURN_GAS);
        uint256 saleId = _endedSale(hostile, true);
        _refusable(saleId);
        vm.expectRevert(
            abi.encodeWithSelector(
                BoundedCall.BoundedCallInsufficientGas.selector, uint256(REFUSAL_GAS)
            )
        );
        auction.settleOrRefund{ gas: REFUSAL_GAS }(saleId);
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.ENDED), "unchanged");
        assertEq(auction.claimable(alice, ETH), 0, "nothing credited");
    }

    /// @dev Around the least gas that passes: a call either reverts with nothing changed (too
    ///      little for the attempt, or for the close after it) or gives the attempt its full gas
    ///      and closes the sale correctly. A shortfall never produces a success-shaped outcome.
    function test_AShortfallNeverClosesASale() public {
        hostile.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.BURN_GAS);
        uint256 saleId = _endedSale(hostile, true);
        _refusable(saleId);
        bool closed;
        for (uint256 limit = REFUSAL_GAS; limit < uint256(REFUSAL_GAS) + 200_000; limit += 5000) {
            uint256 snapshot = vm.snapshotState();
            (bool ok,) = address(auction).call{ gas: limit }(
                abi.encodeCall(IEnglishAuctionRefusal.settleOrRefund, (saleId))
            );
            if (ok) {
                _assertRefused(hostile, saleId, true);
                closed = true;
            } else {
                assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.ENDED));
                assertEq(auction.claimable(alice, ETH), 0, "nothing credited");
            }
            vm.revertToState(snapshot);
        }
        assertTrue(closed, "some limit in the range suffices");
    }

    /// @dev The attempt gets exactly the refusal gas, whatever the caller sends: a token sees
    ///      the same gas and the outcome cannot be chosen by the caller's gas limit.
    function test_TheAttemptGetsExactlyTheRefusalGas() public {
        hostile.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.BURN_GAS);
        uint256 saleId = _endedSale(hostile, true);
        _refusable(saleId);
        uint256 snapshot = vm.snapshotState();
        uint256 g0 = gasleft();
        auction.settleOrRefund{ gas: 6_000_000 }(saleId);
        uint256 small = g0 - gasleft();
        vm.revertToState(snapshot);
        g0 = gasleft();
        auction.settleOrRefund{ gas: 15_000_000 }(saleId);
        uint256 large = g0 - gasleft();
        assertEq(small, large, "the same gas whatever the limit");
        // The token burned all it was given (63/64 of the attempt); the attempt returned the rest.
        assertGt(small, uint256(REFUSAL_GAS) * 62 / 64, "the attempt's allowance was spent");
        assertLt(small, uint256(REFUSAL_GAS) + 200_000, "and nothing more");
    }

    // ----------------------------------------------- each failure, one at a time

    /// @dev Every way a token's settlement call can fail with a bid standing: `settle` reverts
    ///      for good, and `settleOrRefund` closes the sale as refused.
    function test_EachFailureWithABidClosesTheSaleAsRefused() public {
        HostileMintTarget.Fault[5] memory settleFaults = [
            HostileMintTarget.Fault.REVERT,
            HostileMintTarget.Fault.BURN_GAS,
            HostileMintTarget.Fault.MALFORMED,
            HostileMintTarget.Fault.REENTER,
            HostileMintTarget.Fault.REPORT
        ];
        // REENTER bubbles a refused re-entry; REPORT names a seller the payout refuses.
        hostile.setReentry(address(auction), abi.encodeCall(ISaleAdapter.claim, (ETH, alice)), true);
        for (uint256 i; i < 5; ++i) {
            _refusedOnce(HostileMintTarget.Call.SETTLE, settleFaults[i], true);
        }
        _refusedOnce(HostileMintTarget.Call.SALE_VIEW, HostileMintTarget.Fault.BURN_GAS, true);
        _refusedOnce(HostileMintTarget.Call.OWNER_OF, HostileMintTarget.Fault.REVERT, true);
        _refusedOnce(HostileMintTarget.Call.OWNER_OF, HostileMintTarget.Fault.BURN_GAS, true);
        _refusedOnce(HostileMintTarget.Call.OWNER_OF, HostileMintTarget.Fault.MALFORMED, true);
    }

    /// @dev With no bid there is nothing to credit; the artist takes the work back.
    function test_EachFailureWithNoBidClosesTheSaleAsRefused() public {
        _refusedOnce(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.REVERT, false);
        _refusedOnce(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.BURN_GAS, false);
        _refusedOnce(HostileMintTarget.Call.OWNER_OF, HostileMintTarget.Fault.REVERT, false);
        _refusedOnce(HostileMintTarget.Call.TERMS, HostileMintTarget.Fault.BURN_GAS, false);
        _refusedOnce(HostileMintTarget.Call.TERMS, HostileMintTarget.Fault.MALFORMED, false);
    }

    function _refusedOnce(HostileMintTarget.Call call, HostileMintTarget.Fault fault, bool bid)
        internal
    {
        uint256 snapshot = vm.snapshotState();
        hostile.setReported(PrimarySettlement(address(0), network, FEE, address(0)));
        uint256 saleId = _endedSale(hostile, bid);
        hostile.fail(call, fault);
        vm.expectRevert();
        auction.settle{ gas: KEEPER_GAS }(saleId);
        // `settle` alone never gets past the token, however long anyone waits.
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert();
        auction.settle{ gas: KEEPER_GAS }(saleId);
        vm.expectEmit(address(auction));
        emit IEnglishAuctionRefusal.SettlementRefused(saleId);
        _settleOrRefund(saleId);
        // The token behaves again, so the checks below can read it.
        hostile.clear(call);
        _assertRefused(hostile, saleId, bid);
        _artistClaims(hostile, saleId);
        vm.revertToState(snapshot);
    }

    /// @dev Failures the auction already absorbs are not refusals: a delivery the token blocks
    ///      leaves a pending delivery after a full sale, and an unreadable outcome view settles
    ///      as usual. `settleOrRefund` then settles exactly as `settle` does.
    function test_SoftFailuresStillSettle() public {
        hostile.fail(HostileMintTarget.Call.TRANSFER, HostileMintTarget.Fault.REVERT);
        uint256 saleId = _endedSale(hostile, true);
        _refusable(saleId);
        _settleOrRefund(saleId);
        assertTrue(hostile.primarySettled(_tokenIdOf(saleId)), "sold");
        assertEq(auction.pendingDelivery(saleId), alice, "pending for the winner");
        assertEq(seller.balance, BID - BID / 10, "the registry's 10% fee taken");
        hostile.clear(HostileMintTarget.Call.TRANSFER);
        hostile.fail(HostileMintTarget.Call.SALE_VIEW, HostileMintTarget.Fault.MALFORMED);
        saleId = _endedSale(hostile, true);
        _refusable(saleId);
        _settleOrRefund(saleId);
        assertEq(hostile.holderOf(_tokenIdOf(saleId)), alice, "delivered");
    }

    // ----------------------------------------------------- selective and hostile

    /// @dev A token that refuses one buyer refuses only that buyer's sale.
    function test_ATokenRefusingOneBuyerAffectsOnlyThatSale() public {
        hostile.setRule(
            HostileMintTarget.Call.SETTLE,
            HostileMintTarget.Rule(HostileMintTarget.Fault.REVERT, 0, 0, 0, 0, 0, alice, address(0))
        );
        uint256 refused = auction.start(address(hostile), "");
        uint256 sold = auction.start(address(hostile), "");
        _bidEth(refused, alice, BID);
        _bidEth(sold, bob, BID);
        _end(refused);
        _refusable(refused);
        _settleOrRefund(refused);
        _settleOrRefund(sold);
        assertEq(auction.claimable(alice, ETH), BID, "alice credited back");
        assertEq(hostile.holderOf(_tokenIdOf(sold)), bob, "bob's sale went through");
        assertEq(federatedNetwork.balance, BID / 10, "the network is paid on the sale only");
    }

    /// @dev A token that cooperates only with a settler sending more gas than the refusal gas:
    ///      `settle` sells, while `settleOrRefund` refuses. Either way the bidder keeps its money
    ///      or gets the work, and the network is paid exactly on the sale.
    function test_ATokenSteeringByGasPicksOnlyBetweenSaleAndRefund() public {
        hostile.setRule(
            HostileMintTarget.Call.SETTLE,
            HostileMintTarget.Rule(
                HostileMintTarget.Fault.REVERT, 0, 0, 0, 5_000_000, 0, address(0), address(0)
            )
        );
        uint256 saleId = _endedSale(hostile, true);
        _refusable(saleId);
        uint256 snapshot = vm.snapshotState();
        auction.settle{ gas: 8_000_000 }(saleId);
        assertEq(hostile.holderOf(_tokenIdOf(saleId)), alice, "sold through settle");
        assertEq(federatedNetwork.balance, BID / 10, "fee paid");
        vm.revertToState(snapshot);
        _settleOrRefund(saleId);
        _assertRefused(hostile, saleId, true);
    }

    /// @dev A token that refuses until a time and then cooperates, or the reverse: the first
    ///      `settleOrRefund` call after the delay decides, once, from what the token does then.
    function test_ATokenChangingBehaviourBetweenCalls() public {
        uint256 saleId = _endedSale(hostile, true);
        uint64 allowed = uint64(auction.refusableAt(saleId));
        hostile.setRule(
            HostileMintTarget.Call.SETTLE,
            HostileMintTarget.Rule(
                HostileMintTarget.Fault.REVERT, 0, allowed + 1, 0, 0, 0, address(0), address(0)
            )
        );
        vm.warp(allowed + 1);
        _settleOrRefund(saleId);
        assertEq(hostile.holderOf(_tokenIdOf(saleId)), alice, "it cooperated by then: sold");
        // Cooperates for one more settlement, then refuses every later one.
        uint32 skip = uint32(hostile.passed(HostileMintTarget.Call.SETTLE) + 1);
        hostile.setRule(
            HostileMintTarget.Call.SETTLE,
            HostileMintTarget.Rule(
                HostileMintTarget.Fault.BURN_GAS, 0, 0, 0, 0, skip, address(0), address(0)
            )
        );
        uint256 sold = _endedSale(hostile, true);
        _refusable(sold);
        _settleOrRefund(sold);
        assertEq(hostile.holderOf(_tokenIdOf(sold)), alice, "the one more: sold");
        uint256 next = _endedSale(hostile, true);
        _refusable(next);
        uint256 paidBefore = seller.balance + federatedNetwork.balance;
        vm.expectEmit(address(auction));
        emit IEnglishAuctionRefusal.SettlementRefused(next);
        _settleOrRefund(next);
        assertEq(auction.claimable(alice, ETH), BID, "then refused: credited back");
        assertEq(seller.balance + federatedNetwork.balance, paidBefore, "nothing paid");
        assertEq(hostile.holderOf(_tokenIdOf(next)), address(auction), "in custody");
    }

    /// @dev A token re-entering from its own settlement cannot reach another sale: the auction's
    ///      guard refuses `settleOrRefund`, `settle` and `claim` there.
    function test_AReentrantTokenCannotTouchAnotherSale() public {
        uint256 victim = _endedSale(_hostile(true), true);
        hostile.setReentry(
            address(auction), abi.encodeCall(IEnglishAuctionRefusal.settleOrRefund, (victim)), false
        );
        hostile.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.REENTER);
        uint256 own = _endedSale(hostile, true);
        _refusable(victim);
        _refusable(own);
        _settleOrRefund(own);
        assertFalse(hostile.reentryOk(), "re-entry refused");
        assertEq(
            bytes4(hostile.reentryResult()),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(uint8(_state(victim)), uint8(IEnglishAuction.AuctionState.ENDED), "untouched");
        assertEq(hostile.holderOf(_tokenIdOf(own)), alice, "its own sale settled");
        _settleOrRefund(victim);
        assertEq(uint8(_state(victim)), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(auction.auction(victim).bidder, alice, "the victim settles as usual: sold");
    }

    /// @dev A caller running inside the escrow (a flush to its own contract) holds the escrow's
    ///      guard, which would fail any attempt that escrows a refused payout: it is refused, so
    ///      no third party can turn another sale into a refusal.
    function test_ACallerInsideTheEscrowIsRefused() public {
        HostileActor refusingSeller = new HostileActor();
        refusingSeller.configure(HostileActor.Behaviour.REVERT, HostileActor.Behaviour.ACCEPT);
        PrimarySettlement memory p =
            PrimarySettlement(address(refusingSeller), network, FEE, address(0));
        hostile.setReported(p);
        hostile.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.REPORT);
        uint256 victim = _endedSale(hostile, true);
        _refusable(victim);
        EscrowReentrant attacker = new EscrowReentrant(address(auction));
        attacker.arm(victim);
        vm.deal(address(this), 1);
        escrow.depositETH{ value: 1 }(address(attacker));
        escrow.flush(address(attacker), ETH);
        assertTrue(attacker.reverted(), "refused inside the escrow");
        assertEq(
            bytes4(attacker.reason()),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(uint8(_state(victim)), uint8(IEnglishAuction.AuctionState.ENDED), "untouched");
        // Outside the escrow the victim settles: its refusing seller is escrowed, as ever.
        _settleOrRefund(victim);
        assertEq(hostile.holderOf(_tokenIdOf(victim)), alice, "sold");
        assertEq(escrow.owed(address(refusingSeller), ETH), BID - BID / 10);
    }

    /// @dev A bidder colluding with the token gets back exactly its bid and nothing else from
    ///      the auction; where the work goes after a refusal is the token's own ledger's choice
    ///      (the artist it names), and no one is paid.
    function test_ABidderColludingWithTheTokenGetsOnlyItsBidBack() public {
        hostile.setLiar(alice);
        hostile.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.REVERT);
        uint256 saleId = _endedSale(hostile, true);
        _refusable(saleId);
        _settleOrRefund(saleId);
        uint256 before = alice.balance;
        vm.prank(alice);
        auction.claim(ETH, alice);
        assertEq(alice.balance - before, BID, "exactly the bid");
        assertEq(address(auction).balance, 0, "nothing left behind or taken");
        assertEq(seller.balance + federatedNetwork.balance, 0, "no one paid");
    }

    // --------------------------------------------------------- the network's fee

    /// @dev A federated sale pays the network the registry's fee share to the federated
    ///      recipient, both locked when the sale opened: neither the token's answer nor a later
    ///      change of the resolver or the registry moves it (AUC-41).
    function test_TheFederatedFeeIsTheOneLockedAtStart() public {
        HostileMintTarget fed = _hostile(true);
        address tokenWallet = makeAddr("tokenChosenFeeWallet");
        fed.setReported(PrimarySettlement(seller, tokenWallet, 100_000, address(0)));
        fed.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.REPORT);
        uint256 saleId = auction.start(address(fed), "");
        _bidEth(saleId, alice, BID);
        resolver.set(PRODUCT_FEDERATED, makeAddr("laterRecipient"), 10_000);
        registry.setEntry(address(fed), 50_000, true);
        _end(saleId);
        auction.settle{ gas: KEEPER_GAS }(saleId);
        assertEq(federatedNetwork.balance, BID / 10, "10% to the recipient locked at start");
        assertEq(seller.balance, BID - BID / 10, "the rest to the seller the token names");
        assertEq(tokenWallet.balance, 0, "nothing to the token's own fee wallet");
    }

    /// @dev A seller wallet that refuses payment cannot block or divert the network's part: it
    ///      is escrowed for the seller, and the fee is paid in full.
    function test_ARefusingSellerWalletCannotTouchTheNetworksPart() public {
        HostileMintTarget fed = _hostile(true);
        HostileActor wallet = new HostileActor();
        wallet.configure(HostileActor.Behaviour.BURN_GAS, HostileActor.Behaviour.ACCEPT);
        fed.setReported(PrimarySettlement(address(wallet), address(0), 0, address(0)));
        fed.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.REPORT);
        uint256 saleId = _endedSale(fed, true);
        auction.settle{ gas: KEEPER_GAS }(saleId);
        assertEq(federatedNetwork.balance, BID / 10, "the network's part, in full");
        assertEq(escrow.owed(address(wallet), ETH), BID - BID / 10, "the seller's, escrowed");
        assertEq(fed.holderOf(_tokenIdOf(saleId)), alice, "the buyer has the work");
    }

    /// @dev A token naming a seller no payout can reach (zero, or the escrow) cannot sell: no
    ///      outcome gives the buyer the work and the seller the price without the network's
    ///      fee. The sale closes as refused and no one is paid.
    function test_ATokenNamingAnUnpayableSellerIsRefused() public {
        HostileMintTarget fed = _hostile(true);
        address[2] memory sellers = [address(0), address(escrow)];
        for (uint256 i; i < 2; ++i) {
            fed.setReported(PrimarySettlement(sellers[i], address(0), 0, address(0)));
            fed.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.REPORT);
            uint256 saleId = _endedSale(fed, true);
            vm.expectRevert();
            auction.settle{ gas: KEEPER_GAS }(saleId);
            _refusable(saleId);
            _settleOrRefund(saleId);
            assertEq(federatedNetwork.balance, 0, "no sale, no fee");
            assertEq(fed.holderOf(_tokenIdOf(saleId)), address(auction), "no work handed over");
            vm.prank(alice);
            auction.claim(ETH, alice);
        }
    }

    // ------------------------------------------------------------ federated paths

    /// @dev A delisted federated token whose settlement fails no longer holds the bid.
    function test_ADelistedFederatedTokenThatRefusesReleasesTheBid() public {
        HostileMintTarget fed = _hostile(true);
        fed.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.REVERT);
        uint256 saleId = _endedSale(fed, true);
        registry.setStatus(address(fed), IFederationRegistry.Status.DELISTED, bytes32(0));
        vm.expectRevert();
        auction.settle{ gas: KEEPER_GAS }(saleId);
        _refusable(saleId);
        _settleOrRefund(saleId);
        _assertRefused(fed, saleId, true);
    }

    /// @dev A federated token reporting an outcome before its sale settles closes it with
    ///      refunds (AUC-36) and leaves the work for its artist to claim.
    function test_AFederatedTokenReportingEarlyLeavesTheWorkToItsArtist() public {
        HostileMintTarget fed = _hostile(true);
        uint256 saleId = _endedSale(fed, true);
        fed.fail(HostileMintTarget.Call.SALE_VIEW, HostileMintTarget.Fault.REPORT);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.RescuedSaleClosed(saleId);
        auction.settle{ gas: KEEPER_GAS }(saleId);
        assertEq(auction.claimable(alice, ETH), BID, "credited back");
        _artistClaims(fed, saleId);
    }

    /// @dev A federated sale locks its refusal delay at start; a later change reaches only sales
    ///      started afterwards.
    function test_TheRefusalDelayIsLockedForAFederatedSale() public {
        uint256 before = auction.start(address(hostile), "");
        IEnglishAuction.AuctionConfig memory next = _config();
        next.refusalDelay = 20 days;
        vm.prank(setter);
        auction.setConfig(_config(), next);
        uint256 afterwards = auction.start(address(hostile), "");
        uint256 end = auction.auction(before).endTime;
        assertEq(auction.refusableAt(before), end + REFUSAL_DELAY, "locked");
        assertEq(auction.refusableAt(afterwards), end + 20 days, "the new delay");
    }

    // ------------------------------------------------------------ governed values

    function test_SetConfig_RefusalBoundsAndRaiseOnly() public {
        IEnglishAuction.AuctionConfig memory c = _config();
        uint32[2] memory badDelay = [uint32(1 days - 1), 30 days + 1];
        for (uint256 i; i < 2; ++i) {
            IEnglishAuction.AuctionConfig memory n = _config();
            n.refusalDelay = badDelay[i];
            vm.prank(setter);
            vm.expectRevert(IEnglishAuction.InvalidConfig.selector);
            auction.setConfig(c, n);
        }
        uint32[4] memory badGas =
            [REFUSAL_GAS - 1, 2 * REFUSAL_GAS + 1, uint32(2_999_999), uint32(15_000_001)];
        for (uint256 i; i < 4; ++i) {
            IEnglishAuction.AuctionConfig memory n = _config();
            n.refusalGas = badGas[i];
            vm.prank(setter);
            vm.expectRevert(IEnglishAuction.InvalidConfig.selector);
            auction.setConfig(c, n);
        }
        IEnglishAuction.AuctionConfig memory raised = _config();
        (raised.refusalDelay, raised.refusalGas) = (1 days, 2 * REFUSAL_GAS);
        vm.prank(setter);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.ConfigSet(c, raised);
        auction.setConfig(c, raised);
        assertEq(abi.encode(auction.config()), abi.encode(raised));
        // Compare-and-set covers the refusal fields too.
        vm.prank(setter);
        vm.expectRevert(ISaleAdapter.ExpectedValueMismatch.selector);
        auction.setConfig(c, raised);
        // The ceiling.
        IEnglishAuction.AuctionConfig memory top = _config();
        (top.refusalDelay, top.refusalGas) = (1 days, 15_000_000);
        vm.prank(setter);
        auction.setConfig(raised, top);
    }

    // ------------------------------------------------------------ fuzz

    /// @dev Any combination of failures, on any call of a federated token, with or without a bid,
    ///      in ETH, in an ERC-20 paid directly or through Permit2: `settleOrRefund` always ends the
    ///      sale; the bid is either paid out in full, with the network's fee, or credited back in
    ///      full; the work is the buyer's only when the sale was paid.
    function testFuzz_AnyFailureCombinationEndsTheSaleWithEverythingConserved(
        uint256 seed,
        uint8 payMode,
        bool withBid
    ) public {
        payMode %= 3;
        address currency = payMode == 0 ? ETH : address(usd);
        uint256 price = payMode == 0 ? BID : 100e18;
        HostileMintTarget h = _hostile(true);
        h.setTerms(_terms(currency));
        // A REPORT names a seller the payout refuses (zero) or one that accepts.
        address chosen = address(uint160((seed >> 96) & 1 == 0 ? 0 : 0xBEEF));
        h.setReported(PrimarySettlement(chosen, network, FEE, address(0)));
        uint256 saleId = auction.start(address(h), "");
        if (withBid) _fuzzBid(saleId, payMode, price);
        _end(saleId);
        for (uint256 c; c < 5; ++c) {
            uint256 f = (seed >> (8 * c)) % 6;
            if (f == uint256(HostileMintTarget.Fault.REENTER)) f = 0;
            uint64 minGas = (seed >> (40 + c)) & 1 == 0 ? 0 : 3_000_000;
            h.setRule(
                HostileMintTarget.Call(c),
                HostileMintTarget.Rule(
                    HostileMintTarget.Fault(f), 0, 0, minGas, 0, 0, address(0), address(0)
                )
            );
        }
        _refusable(saleId);
        uint256 out = _paidOut(currency);
        _settleOrRefund(saleId);
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.SETTLED), "terminal");
        uint256 paid = _paidOut(currency) - out;
        uint256 credit = auction.claimable(alice, currency);
        assertEq(paid + credit, withBid ? price : 0, "paid out or credited back, in full");
        assertEq(_held(currency), credit, "the auction holds only the credit");
        if (paid != 0) {
            assertEq(_balance(currency, federatedNetwork), price / 10, "the network's fee");
            assertTrue(h.primarySettled(_tokenIdOf(saleId)), "reported to the token");
        } else if (withBid) {
            assertTrue(h.holderOf(_tokenIdOf(saleId)) != alice, "no work for an unpaid bid");
        }
    }

    function _fuzzBid(uint256 saleId, uint8 payMode, uint256 price) internal {
        if (payMode == 0) return _bidEth(saleId, alice, price);
        if (payMode == 1) return _bidUsd(saleId, alice, price);
        usd.mint(alice, price);
        vm.prank(alice);
        usd.approve(address(permit2), type(uint256).max);
        Payment memory p = _permit2Payment(alicePk, saleId, alice, price, 1);
        vm.prank(relayer);
        auction.bid(saleId, alice, p);
    }

    function _balance(address currency, address account) internal view returns (uint256) {
        return currency == ETH ? account.balance : usd.balanceOf(account);
    }

    function _held(address currency) internal view returns (uint256) {
        return _balance(currency, address(auction));
    }

    function _paidOut(address currency) internal view returns (uint256) {
        return _balance(currency, seller) + _balance(currency, federatedNetwork)
            + _balance(currency, address(0xBEEF)) + escrow.owed(seller, currency)
            + escrow.owed(address(0xBEEF), currency) + auction.claimable(seller, currency)
            + auction.claimable(address(0xBEEF), currency);
    }

    // ------------------------------------------------------------ review additions

    /// @dev F3: the floor covers the auction's own worst case with a cooperating token: both
    ///      ERC-20 payout frames burn their whole allowance (credited instead) and the recipient
    ///      burns the delivery's 300,000. At the floor the settlement still completes as a sale.
    function test_TheFloorCoversTheAuctionsWorstCase() public {
        BurningToken coin = new BurningToken();
        allowlist.admitAsset(address(coin), 0, 1e18);
        HostileMintTarget h = _hostile(true);
        h.setTerms(_terms(address(coin)));
        HostileActor recipient = new HostileActor();
        recipient.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.BURN_GAS);
        uint256 saleId = auction.start(address(h), "");
        coin.mint(alice, 100e18);
        vm.startPrank(alice);
        coin.approve(address(auction), 100e18);
        auction.bid(
            saleId, address(recipient), Payment(PaymentMethod.DIRECT, alice, 100e18, 0, 0, "")
        );
        vm.stopPrank();
        _end(saleId);
        coin.setBurning(true);
        (bool ok,) = address(auction).call{ gas: 3_000_000 }(
            abi.encodeCall(IEnglishAuction.settle, (saleId))
        );
        assertTrue(ok, "the worst case fits the floor");
        assertTrue(h.primarySettled(_tokenIdOf(saleId)), "sold");
        assertEq(auction.claimable(seller, address(coin)), 90e18, "the seller's part credited");
        assertEq(auction.claimable(federatedNetwork, address(coin)), 10e18, "the network's too");
        assertEq(auction.pendingDelivery(saleId), address(recipient), "delivery pending");
    }

    /// @dev F4: the exit runs at the refusal gas ceiling inside a 2^24 transaction.
    function test_TheExitRunsAtTheCeiling() public {
        IEnglishAuction.AuctionConfig memory c = _config();
        IEnglishAuction.AuctionConfig memory n = _config();
        n.refusalGas = 8_000_000;
        vm.prank(setter);
        auction.setConfig(c, n);
        c = n;
        n = _config();
        n.refusalGas = 15_000_000;
        vm.prank(setter);
        auction.setConfig(c, n);
        hostile.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.BURN_GAS);
        uint256 saleId = _endedSale(hostile, true);
        _refusable(saleId);
        auction.settleOrRefund{ gas: 16_777_216 }(saleId);
        _assertRefused(hostile, saleId, true);
    }

    /// @dev A token steering by the keeper's identity (`tx.origin`) still only picks between a
    ///      full sale and a refund.
    function test_ATokenSteeringByOriginPicksOnlyBetweenSaleAndRefund() public {
        address keeper = makeAddr("keeper");
        hostile.setRule(
            HostileMintTarget.Call.SETTLE,
            HostileMintTarget.Rule(
                HostileMintTarget.Fault.REVERT, 0, 0, 0, 0, 0, address(0), keeper
            )
        );
        uint256 saleId = _endedSale(hostile, true);
        _refusable(saleId);
        uint256 snapshot = vm.snapshotState();
        vm.prank(keeper, keeper);
        _settleOrRefund(saleId);
        _assertRefused(hostile, saleId, true);
        vm.revertToState(snapshot);
        address other = makeAddr("otherKeeper");
        vm.prank(other, other);
        _settleOrRefund(saleId);
        assertEq(hostile.holderOf(_tokenIdOf(saleId)), alice, "sold for another keeper");
        assertEq(federatedNetwork.balance, BID / 10, "with the fee");
    }

    /// @dev With no bid and a token reporting no creator, the sale closes as refused and the work
    ///      waits in custody until the token names one: no funds are at stake.
    function test_AZeroCreatorLeavesTheWorkWaitingForItsArtist() public {
        hostile.setLiar(address(0));
        uint256 saleId = _endedSale(hostile, false);
        hostile.fail(HostileMintTarget.Call.TERMS, HostileMintTarget.Fault.REPORT);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.InvalidRecipient.selector, address(0)));
        auction.settle{ gas: KEEPER_GAS }(saleId);
        _refusable(saleId);
        _settleOrRefund(saleId);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        auction.claimDelivery(saleId, artist);
        hostile.clear(HostileMintTarget.Call.TERMS);
        _artistClaims(hostile, saleId);
    }

    /// @dev Review round 4: on the refused-close path the lens reads the creator with the shared
    ///      forward-all helper and copies at most 4 KiB. A refusal or an answer over the bound
    ///      reverts with `BoundedCallFailed`, a malformed one with `BoundedCallMalformedReturn`,
    ///      a burn with `BoundedCallShortfall`; an answer at the bound still names the artist.
    ///      The auction's own `claimDelivery` is unchanged. Fails without the change: the plain
    ///      call bubbles the token's revert, decodes a 32-byte answer with no reason, and copies
    ///      any answer whole.
    function test_PendingDeliveryReadsTheCreatorWithBoundedReturnData() public {
        uint256 saleId = _endedSale(hostile, true);
        hostile.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.REVERT);
        _refusable(saleId);
        _settleOrRefund(saleId);
        hostile.clear(HostileMintTarget.Call.SETTLE);
        assertEq(auction.pendingDelivery(saleId), artist);
        address token = address(hostile);
        hostile.fail(HostileMintTarget.Call.TERMS, HostileMintTarget.Fault.REVERT);
        vm.expectRevert(abi.encodeWithSelector(BoundedCall.BoundedCallFailed.selector, token));
        auction.pendingDelivery(saleId);
        hostile.fail(HostileMintTarget.Call.TERMS, HostileMintTarget.Fault.MALFORMED);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallMalformedReturn.selector, token)
        );
        auction.pendingDelivery(saleId);
        hostile.fail(HostileMintTarget.Call.TERMS, HostileMintTarget.Fault.BURN_GAS);
        vm.expectRevert(abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, token));
        auction.pendingDelivery{ gas: 1_000_000 }(saleId);
        hostile.clear(HostileMintTarget.Call.TERMS);
        // 3,776 bytes of params make a 4,096-byte answer, the bound; 32 more are refused.
        PrimaryTerms memory t = hostile.primaryTerms(0, "");
        t.params = new bytes(3_776);
        hostile.setTerms(t);
        assertEq(auction.pendingDelivery(saleId), artist, "at the bound");
        t.params = new bytes(3_777);
        hostile.setTerms(t);
        vm.expectRevert(abi.encodeWithSelector(BoundedCall.BoundedCallFailed.selector, token));
        auction.pendingDelivery(saleId);
        _artistClaims(hostile, saleId);
    }

    /// @dev A hand-built `PrimaryTerms` answer: head offset, eight struct words with `params` at
    ///      `paramsOffset` and the artist as creator, then the length word and `body`.
    function _rawTerms(uint256 paramsOffset, uint256 paramsLength, bytes memory body)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            uint256(0x20),
            bytes32(0),
            uint256(uint160(ETH)),
            uint256(0),
            paramsOffset,
            uint256(uint160(seller)),
            uint256(uint160(network)),
            uint256(FEE),
            uint256(uint160(artist)),
            paramsLength,
            body
        );
    }

    /// @dev A refused-close sale of `hostile` whose delivery is pending for the artist.
    function _refusedSale() internal returns (uint256 saleId) {
        saleId = _endedSale(hostile, true);
        hostile.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.REVERT);
        _refusable(saleId);
        _settleOrRefund(saleId);
        hostile.clear(HostileMintTarget.Call.SETTLE);
    }

    function _malformed() internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                BoundedCall.BoundedCallMalformedReturn.selector, address(hostile)
            );
    }

    /// @dev Review round 5: the creator helper checks the whole `PrimaryTerms` shape. A
    ///      well-formed hand-built answer names the artist, with and without `params` bytes.
    function test_PendingDeliveryAcceptsAWellFormedTermsAnswer() public {
        uint256 saleId = _refusedSale();
        hostile.setRawTerms(_rawTerms(0x100, 64, new bytes(64)));
        assertEq(auction.pendingDelivery(saleId), artist, "64 bytes of params");
        hostile.setRawTerms(_rawTerms(0x100, 0, ""));
        assertEq(auction.pendingDelivery(saleId), artist, "empty params");
    }

    /// @dev A `params` offset outside the answer, or one that would wrap under addition, is
    ///      refused with `BoundedCallMalformedReturn`. Fails without the `params` check: both
    ///      answers decode to the artist.
    function test_PendingDeliveryRejectsAParamsOffsetOutsideTheData() public {
        uint256 saleId = _refusedSale();
        hostile.setRawTerms(_rawTerms(0x1000, 0, ""));
        vm.expectRevert(_malformed());
        auction.pendingDelivery(saleId);
        hostile.setRawTerms(_rawTerms(type(uint256).max - 0x1f, 0, ""));
        vm.expectRevert(_malformed());
        auction.pendingDelivery(saleId);
    }

    /// @dev A `params` offset that points into the struct's own head (zero, or any word before
    ///      the head ends) is not a canonical encoding and is refused. Fails without the lower
    ///      bound: the head word it lands on reads as a small length and the creator is returned.
    function test_PendingDeliveryRejectsAParamsOffsetInsideTheHead() public {
        uint256 saleId = _refusedSale();
        hostile.setRawTerms(_rawTerms(0, 0, ""));
        vm.expectRevert(_malformed());
        auction.pendingDelivery(saleId);
        hostile.setRawTerms(_rawTerms(0xe0, 0, ""));
        vm.expectRevert(_malformed());
        auction.pendingDelivery(saleId);
    }

    /// @dev A `params` length that overruns the answer (one byte over, the maximum, and one that
    ///      would wrap under addition) is refused with `BoundedCallMalformedReturn`. Fails
    ///      without the `params` check: all three decode to the artist.
    function test_PendingDeliveryRejectsAParamsLengthThatOverrunsTheData() public {
        uint256 saleId = _refusedSale();
        hostile.setRawTerms(_rawTerms(0x100, 65, new bytes(64)));
        vm.expectRevert(_malformed());
        auction.pendingDelivery(saleId);
        hostile.setRawTerms(_rawTerms(0x100, type(uint256).max, new bytes(64)));
        vm.expectRevert(_malformed());
        auction.pendingDelivery(saleId);
        hostile.setRawTerms(_rawTerms(0x100, type(uint256).max - 0x3f, new bytes(64)));
        vm.expectRevert(_malformed());
        auction.pendingDelivery(saleId);
    }

    /// @dev A token whose `ownerOf` lies on the unbid path reports the work moved: the sale
    ///      settles unsold to the holder it names and the work stays in custody, out of anyone's
    ///      reach. Only the token's own work is affected; no funds are at stake.
    function test_ALyingOwnerOfOnTheUnbidPathOnlyStrandsItsOwnWork() public {
        uint256 saleId = _endedSale(hostile, false);
        hostile.fail(HostileMintTarget.Call.OWNER_OF, HostileMintTarget.Fault.REPORT);
        auction.settle{ gas: KEEPER_GAS }(saleId);
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(hostile.holderOf(_tokenIdOf(saleId)), address(auction), "never moved");
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        auction.claimDelivery(saleId, artist);
        assertEq(address(auction).balance, 0, "no funds involved");
    }

    /// @dev F5: a listed token cannot start a sale paying the auction itself; a federated token
    ///      that names the auction as seller at settlement is refused.
    function test_TheAuctionItselfIsNeverASeller() public {
        HostileMintTarget listed = _hostile(false);
        listed.setTerms(
            PrimaryTerms(
                SaleKind.ENGLISH_AUCTION, ETH, 0, "", address(auction), network, FEE, artist
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(listed), 1)
        );
        auction.start(address(listed), "");
        hostile.setReported(PrimarySettlement(address(auction), address(0), 0, address(0)));
        hostile.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.REPORT);
        uint256 saleId = _endedSale(hostile, true);
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, address(auction))
        );
        auction.settle{ gas: KEEPER_GAS }(saleId);
        _refusable(saleId);
        _settleOrRefund(saleId);
        _assertRefused(hostile, saleId, true);
    }

    /// @dev A third party holding a wallet's or a recipient's own guard while it calls
    ///      `settleOrRefund` does not turn a cooperating sale into a refusal: the refused payout is
    ///      escrowed and the refused delivery left pending, and the sale completes.
    function test_AThirdPartyHoldingAWalletOrRecipientGuardCannotForceARefusal() public {
        GuardedParty party = new GuardedParty();
        hostile.setReported(PrimarySettlement(address(party), address(0), 0, address(0)));
        hostile.fail(HostileMintTarget.Call.SETTLE, HostileMintTarget.Fault.REPORT);
        uint256 saleId = auction.start(address(hostile), "");
        _bidFor(saleId, alice, address(party), BID);
        _end(saleId);
        _refusable(saleId);
        party.act(address(auction), abi.encodeCall(IEnglishAuctionRefusal.settleOrRefund, (saleId)));
        assertTrue(party.lastOk(), "the call settled");
        assertTrue(hostile.primarySettled(_tokenIdOf(saleId)), "sold, not refused");
        assertEq(escrow.owed(address(party), ETH), BID - BID / 10, "the payout escrowed");
        assertEq(federatedNetwork.balance, BID / 10, "the fee paid");
        assertEq(auction.pendingDelivery(saleId), address(party), "the delivery pending");
    }
}
