// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { LockedTerms } from "src/interfaces/types/SaleTypes.sol";
import { BlockablePermitToken, HostileActor } from "../../../mocks/auction/AuctionMocks.sol";
import { AuctionBase } from "../AuctionBase.sol";
import { AuctionHandler } from "./AuctionHandler.sol";

/// @dev Deploys the handler for one currency. The network wallet refuses ETH, so ETH fee payouts
///      take the escrow route; the ERC-20 token blocks the seller wallet, so ERC-20 seller
///      payouts take it too.
abstract contract AuctionHandlerFixture is AuctionBase {
    AuctionHandler internal handler;
    BlockablePermitToken internal coin;

    function _currency() internal virtual returns (address);

    function setUp() public override {
        super.setUp();
        HostileActor refusing = new HostileActor();
        refusing.configure(HostileActor.Behaviour.REVERT, HostileActor.Behaviour.REVERT);
        network = address(refusing);
        address currency = _currency();
        stream.setTerms(_terms(currency));
        handler = new AuctionHandler(
            AuctionHandler.Setup(
                auction,
                stream,
                statements,
                escrow,
                allowlist,
                permit2,
                currency,
                address(this),
                guardian,
                unpauser,
                setter,
                platform,
                pauser
            )
        );
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = AuctionHandler.start.selector;
        selectors[1] = AuctionHandler.startWithBid.selector;
        selectors[2] = AuctionHandler.bid.selector;
        selectors[3] = AuctionHandler.warp.selector;
        selectors[4] = AuctionHandler.settle.selector;
        selectors[5] = AuctionHandler.pause.selector;
        selectors[6] = AuctionHandler.pauseAndWithdraw.selector;
        selectors[7] = AuctionHandler.resume.selector;
        selectors[8] = AuctionHandler.withdrawBid.selector;
        selectors[9] = AuctionHandler.cancel.selector;
        selectors[10] = AuctionHandler.claim.selector;
        selectors[11] = AuctionHandler.claimDelivery.selector;
        selectors[12] = AuctionHandler.toggleStartPause.selector;
        selectors[13] = AuctionHandler.govern.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function _balance(address account) internal view returns (uint256) {
        address currency = handler.currency();
        return currency == ETH ? account.balance : coin.balanceOf(account);
    }

    function _out() internal view returns (uint256) {
        address currency = handler.currency();
        return _balance(seller) + _balance(network) + escrow.owed(seller, currency)
            + escrow.owed(network, currency) + handler.ghostClaimed();
    }
}

/// @dev The auction's money and custody invariants, for one currency.
abstract contract AuctionInvariantBase is AuctionHandlerFixture {
    /// @dev Held funds equal the live high bids plus every credit: bids escrowed equal the
    ///      balance, and owed refunds equal the claimable balance.
    function invariant_HeldEqualsLiveBidsPlusCredits() public view {
        address currency = handler.currency();
        uint256 owed;
        for (uint256 i; i < handler.salesCount(); ++i) {
            IEnglishAuction.Auction memory a = auction.auction(handler.sales(i));
            if (
                a.state != IEnglishAuction.AuctionState.SETTLED
                    && a.state != IEnglishAuction.AuctionState.CANCELLED
            ) owed += a.bid;
        }
        for (uint256 i; i < handler.actorsCount(); ++i) {
            owed += auction.claimable(handler.actors(i), currency);
        }
        assertEq(_balance(address(auction)), owed);
    }

    /// @dev Every unit that entered as a bid is held, paid to the seller or network wallet,
    ///      escrowed for one of them, or claimed: nothing is created or lost.
    function invariant_ValueIsConserved() public view {
        assertEq(handler.ghostDeposited(), _balance(address(auction)) + _out());
    }

    /// @dev At most one settlement (one winner) or one cancellation per auction, never both,
    ///      and the token is in custody exactly while the sale is open or awaiting a claim.
    function invariant_OneOutcomeAndExactCustody() public view {
        for (uint256 i; i < handler.salesCount(); ++i) {
            uint256 saleId = handler.sales(i);
            IEnglishAuction.Auction memory a = auction.auction(saleId);
            uint256 outcomes = handler.ghostSettlements(saleId) + handler.ghostCancellations(saleId);
            assertLe(outcomes, 1);
            if (a.state == IEnglishAuction.AuctionState.CANCELLED) {
                assertFalse(stream.exists(a.tokenId), "burned");
                assertEq(a.bidder, address(0));
                continue;
            }
            bool held = stream.ownerOf(a.tokenId) == address(auction);
            if (a.state == IEnglishAuction.AuctionState.SETTLED) {
                assertEq(outcomes, 1);
                assertTrue(stream.primarySettled(a.tokenId), "marked at settlement");
                assertEq(held, auction.pendingDelivery(saleId) != address(0));
            } else {
                assertEq(outcomes, 0);
                assertFalse(stream.primarySettled(a.tokenId));
                assertTrue(held, "open sales keep the token");
            }
        }
    }

    /// @dev Each sale keeps what it locked whatever governance changed since: its currency, the
    ///      opening bid, increment share and window of its start, and the floor of its first bid
    ///      (kept after a withdrawal). A live sale names the recipient of its live high bid.
    function invariant_LockedTermsAndRecipients() public view {
        address currency = handler.currency();
        for (uint256 i; i < handler.salesCount(); ++i) {
            uint256 saleId = handler.sales(i);
            IEnglishAuction.Auction memory a = auction.auction(saleId);
            AuctionHandler.Locked memory l = handler.locked(saleId);
            LockedTerms memory lt = auction.lockedTerms(saleId);
            assertEq(a.currency, currency);
            assertEq(lt.currency, currency);
            assertEq(lt.token, address(stream));
            assertEq(lt.id, a.tokenId);
            assertEq(a.incrementFloor, l.incrementFloor, "floor locked by the first bid");
            if (
                a.state == IEnglishAuction.AuctionState.SETTLED
                    || a.state == IEnglishAuction.AuctionState.CANCELLED
            ) continue;
            assertEq(a.recipient, handler.ghostRecipient(saleId), "recipient of the high bid");
            uint256 minimum;
            if (a.bidder == address(0)) {
                minimum = l.openingBid == 0 ? 1 : l.openingBid;
            } else {
                uint256 step = (a.bid * l.incrementShare + 99_999) / 100_000;
                minimum = a.bid + (step > l.incrementFloor ? step : l.incrementFloor);
            }
            assertEq(auction.minimumBid(saleId), minimum, "minimum from the locked terms");
        }
    }

    /// @dev After every auction is driven to an end and every account claims, nothing is stuck:
    ///      the auction holds no funds and no token.
    function afterInvariant() public {
        vm.warp(block.timestamp + 30 days);
        for (uint256 i; i < handler.salesCount(); ++i) {
            handler.settle(i);
            handler.claimDelivery(i, false);
        }
        for (uint256 i; i < handler.actorsCount(); ++i) {
            handler.claim(i);
        }
        assertEq(_balance(address(auction)), 0, "no stuck funds");
        assertEq(stream.balanceOf(address(auction)), 0, "no stuck tokens");
        assertEq(handler.ghostDeposited(), _out());
    }
}

contract AuctionInvariantEth is AuctionInvariantBase {
    function _currency() internal pure override returns (address) {
        return ETH;
    }
}

contract AuctionInvariantErc20 is AuctionInvariantBase {
    function _currency() internal override returns (address) {
        coin = new BlockablePermitToken();
        coin.setBlocked(seller, true);
        allowlist.admitAsset(address(coin), 0, 1e15);
        return address(coin);
    }
}

/// @dev Replays handler sequences of the campaign's shape (256 runs of 128 calls) and checks
///      that every lifecycle path really executes, so the invariants are not vacuous
///      (review N6).
contract AuctionHandlerCoverage is AuctionHandlerFixture {
    function _currency() internal override returns (address) {
        coin = new BlockablePermitToken();
        coin.setBlocked(seller, true);
        allowlist.admitAsset(address(coin), 0, 1e15);
        return address(coin);
    }

    function test_EveryPathRuns() public {
        string[17] memory names = [
            "start",
            "startWithBid",
            "bid",
            "permit",
            "permit2",
            "settle",
            "pause",
            "resume",
            "withdraw",
            "cancel",
            "claim",
            "delivery",
            "startPause",
            "govern",
            "forAnother",
            "escrowed",
            "pending"
        ];
        uint256[17] memory totals;
        for (uint256 r; r < 64; ++r) {
            uint256 snap = vm.snapshotState();
            for (uint256 d; d < 128; ++d) {
                _step(uint256(keccak256(abi.encode(r, d))));
            }
            for (uint256 i; i < 15; ++i) {
                totals[i] += handler.hits(bytes32(bytes(names[i])));
            }
            if (escrow.owed(seller, address(coin)) != 0) ++totals[15];
            for (uint256 i; i < handler.salesCount(); ++i) {
                if (auction.pendingDelivery(handler.sales(i)) != address(0)) ++totals[16];
            }
            vm.revertToState(snap);
        }
        for (uint256 i; i < 17; ++i) {
            console2.log(names[i], totals[i]);
            assertGt(totals[i], 0, names[i]);
        }
    }

    function _step(uint256 seed) internal {
        uint256 which = seed % 14;
        (uint256 a, uint256 b, uint256 c) = (seed >> 8, seed >> 40, seed >> 72);
        if (which == 0) handler.start();
        else if (which == 1) handler.startWithBid(a, b);
        else if (which == 2) handler.bid(a, b, c, seed >> 120);
        else if (which == 3) handler.warp(a);
        else if (which == 4) handler.settle(a);
        else if (which == 5) handler.pause(a);
        else if (which == 6) handler.pauseAndWithdraw(a);
        else if (which == 7) handler.resume(a);
        else if (which == 8) handler.withdrawBid(a);
        else if (which == 9) handler.cancel(a);
        else if (which == 10) handler.claim(a);
        else if (which == 11) handler.claimDelivery(a, b % 2 == 0);
        else if (which == 12) handler.toggleStartPause();
        else handler.govern(a);
    }
}
