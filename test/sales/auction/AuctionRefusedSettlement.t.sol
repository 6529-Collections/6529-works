// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEnglishAuctionRefusal } from "src/interfaces/IEnglishAuctionRefusal.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
import { PrimarySettlement } from "src/interfaces/types/SaleTypes.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { HostileActor } from "../../mocks/sales/AuctionMocks.sol";
import { HostileMintTarget } from "../../mocks/sales/HostileMintTarget.sol";
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

/// @notice LIM-SAL-16 solved (AUC-38 to AUC-41): a sale whose token will not let it settle
///         reaches a terminal state through `settleOrRefund`, without taking the bidder's funds,
///         without giving the work away unpaid, without redirecting the network fee, and without
///         touching any other sale; a token that settles is never affected.
contract AuctionRefusedSettlementTest is AuctionBase {
    /// @dev Every call into a token that may burn its gas is given this much, so a burner ends.
    uint256 internal constant KEEPER_GAS = 10_000_000;
    uint256 internal constant BID = 1 ether;

    HostileMintTarget internal hostile;
    MockFederationRegistry internal registry;

    function setUp() public override {
        super.setUp();
        hostile = _hostile(false);
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

    /// @dev Settling 6529 Stream through `settleOrRefund` gives exactly what `settle` gives: the
    ///      same events, balances and state, for a sale with a bid, with no bid, and in ERC-20.
    function test_ACooperatingTokenSettlesExactlyAsSettle() public {
        for (uint256 mode; mode < 3; ++mode) {
            uint256 saleId = mode == 2 ? _startUsd() : _start();
            if (mode == 0) _bidEth(saleId, alice, BID);
            if (mode == 2) _bidUsd(saleId, alice, 100e18);
            _end(saleId);
            _refusable(saleId);
            uint256 snapshot = vm.snapshotState();
            vm.recordLogs();
            auction.settle(saleId);
            Vm.Log[] memory viaSettle = vm.getRecordedLogs();
            bytes32 stateA = _fingerprint(saleId);
            vm.revertToState(snapshot);
            vm.recordLogs();
            auction.settleOrRefund(saleId);
            Vm.Log[] memory viaExit = vm.getRecordedLogs();
            assertEq(keccak256(abi.encode(viaExit)), keccak256(abi.encode(viaSettle)), "events");
            assertEq(_fingerprint(saleId), stateA, "state and balances");
        }
    }

    function _fingerprint(uint256 saleId) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                auction.auction(saleId),
                stream.ownerOf(_tokenIdOf(saleId)),
                seller.balance,
                network.balance,
                usd.balanceOf(seller),
                usd.balanceOf(network),
                auction.claimable(alice, ETH),
                address(auction).balance
            )
        );
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
        uint256 saleId = _start();
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
        assertEq(seller.balance, BID - BID * FEE / 100_000);
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
            HostileMintTarget.Rule(HostileMintTarget.Fault.REVERT, 0, 0, 0, 0, 0, alice)
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
        assertEq(network.balance, BID * FEE / 100_000, "the network is paid on the sale only");
    }

    /// @dev A token that cooperates only with a settler sending more gas than the refusal gas:
    ///      `settle` sells, while `settleOrRefund` refuses. Either way the bidder keeps its money
    ///      or gets the work, and the network is paid exactly on the sale.
    function test_ATokenSteeringByGasPicksOnlyBetweenSaleAndRefund() public {
        hostile.setRule(
            HostileMintTarget.Call.SETTLE,
            HostileMintTarget.Rule(
                HostileMintTarget.Fault.REVERT, 0, 0, 0, 5_000_000, 0, address(0)
            )
        );
        uint256 saleId = _endedSale(hostile, true);
        _refusable(saleId);
        uint256 snapshot = vm.snapshotState();
        auction.settle{ gas: 8_000_000 }(saleId);
        assertEq(hostile.holderOf(_tokenIdOf(saleId)), alice, "sold through settle");
        assertEq(network.balance, BID * FEE / 100_000, "fee paid");
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
                HostileMintTarget.Fault.REVERT, 0, allowed + 1, 0, 0, 0, address(0)
            )
        );
        vm.warp(allowed + 1);
        _settleOrRefund(saleId);
        assertEq(hostile.holderOf(_tokenIdOf(saleId)), alice, "it cooperated by then: sold");
        // Cooperates for one more settlement, then refuses every later one.
        uint32 skip = uint32(hostile.passed(HostileMintTarget.Call.SETTLE) + 1);
        hostile.setRule(
            HostileMintTarget.Call.SETTLE,
            HostileMintTarget.Rule(HostileMintTarget.Fault.BURN_GAS, 0, 0, 0, 0, skip, address(0))
        );
        uint256 sold = _endedSale(hostile, true);
        _refusable(sold);
        _settleOrRefund(sold);
        assertEq(hostile.holderOf(_tokenIdOf(sold)), alice, "the one more: sold");
        uint256 next = _endedSale(hostile, true);
        _refusable(next);
        uint256 paidBefore = seller.balance + network.balance;
        vm.expectEmit(address(auction));
        emit IEnglishAuctionRefusal.SettlementRefused(next);
        _settleOrRefund(next);
        assertEq(auction.claimable(alice, ETH), BID, "then refused: credited back");
        assertEq(seller.balance + network.balance, paidBefore, "nothing paid");
        assertEq(hostile.holderOf(_tokenIdOf(next)), address(auction), "in custody");
    }

    /// @dev A token re-entering from its own settlement cannot reach another sale: the auction's
    ///      guard refuses `settleOrRefund`, `settle` and `claim` there.
    function test_AReentrantTokenCannotTouchAnotherSale() public {
        uint256 victim = _start();
        _bidEth(victim, alice, BID);
        _end(victim);
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
        assertEq(stream.ownerOf(_tokenIdOf(victim)), alice, "the victim settles as usual");
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
        assertEq(escrow.owed(address(refusingSeller), ETH), BID - BID * FEE / 100_000);
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
        assertEq(seller.balance + network.balance, 0, "no one paid");
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

    /// @dev A federated sale locks its refusal delay at start; a listed token's sale reads the
    ///      current one.
    function test_TheRefusalDelayIsLockedForAFederatedSale() public {
        HostileMintTarget fed = _hostile(true);
        uint256 federatedSale = auction.start(address(fed), "");
        uint256 listedSale = auction.start(address(hostile), "");
        IEnglishAuction.AuctionConfig memory next = _config();
        next.refusalDelay = 20 days;
        vm.prank(setter);
        auction.setConfig(_config(), next);
        uint256 end = auction.auction(federatedSale).endTime;
        assertEq(auction.refusableAt(federatedSale), end + REFUSAL_DELAY, "locked");
        assertEq(auction.refusableAt(listedSale), end + 20 days, "current");
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
            [REFUSAL_GAS - 1, 2 * REFUSAL_GAS + 1, uint32(2_499_999), uint32(15_000_001)];
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

    /// @dev Any combination of failures, on any call, for a listed or federated token, with or
    ///      without a bid: `settleOrRefund` always ends the sale; the bid is either paid out in
    ///      full, with the network's fee, or credited back in full; the work is the buyer's only
    ///      when the sale was paid.
    function testFuzz_AnyFailureCombinationEndsTheSaleWithEverythingConserved(
        uint256 seed,
        bool federated,
        bool withBid
    ) public {
        HostileMintTarget h = federated ? _hostile(true) : hostile;
        // A REPORT names a seller the payout refuses (zero) or one that accepts.
        address chosen = address(uint160((seed >> 96) & 1 == 0 ? 0 : 0xBEEF));
        h.setReported(PrimarySettlement(chosen, network, FEE, address(0)));
        uint256 saleId = auction.start(address(h), "");
        if (withBid) _bidEth(saleId, alice, BID);
        _end(saleId);
        for (uint256 c; c < 5; ++c) {
            uint256 f = (seed >> (8 * c)) % 6;
            if (f == uint256(HostileMintTarget.Fault.REENTER)) f = 0;
            uint64 minGas = (seed >> (40 + c)) & 1 == 0 ? 0 : 3_000_000;
            h.setRule(
                HostileMintTarget.Call(c),
                HostileMintTarget.Rule(HostileMintTarget.Fault(f), 0, 0, minGas, 0, 0, address(0))
            );
        }
        _refusable(saleId);
        address fee = federated ? federatedNetwork : network;
        uint256 out = seller.balance + fee.balance + address(0xBEEF).balance
            + escrow.owed(seller, ETH) + escrow.owed(address(0xBEEF), ETH);
        _settleOrRefund(saleId);
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.SETTLED), "terminal");
        uint256 paid = seller.balance + fee.balance + address(0xBEEF).balance
            + escrow.owed(seller, ETH) + escrow.owed(address(0xBEEF), ETH) - out;
        uint256 credit = auction.claimable(alice, ETH);
        assertEq(paid + credit, withBid ? BID : 0, "paid out or credited back, in full");
        assertEq(address(auction).balance, credit, "the auction holds only the credit");
        bool sold = paid != 0;
        if (sold) {
            uint256 share = federated ? 10_000 : FEE;
            assertEq(fee.balance, BID * share / 100_000, "the network's fee on every sale");
            assertTrue(h.primarySettled(_tokenIdOf(saleId)), "reported to the token");
        } else {
            assertTrue(
                h.holderOf(_tokenIdOf(saleId)) != alice || !withBid, "no work for an unpaid bid"
            );
        }
    }
}
