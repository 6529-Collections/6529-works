// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { MockERC20 } from "../../../mocks/EconomicsMocks.sol";
import { HostileActor } from "../../../mocks/auction/AuctionMocks.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { AuctionBase } from "../AuctionBase.sol";
import { AuctionHandler } from "./AuctionHandler.sol";

/// @dev The auction's money and custody invariants, for one currency. The network wallet refuses
///      ETH, so ETH fee payouts take the escrow route.
abstract contract AuctionInvariantBase is AuctionBase {
    AuctionHandler internal handler;
    MockERC20 internal coin;

    function _currency() internal virtual returns (address);

    function setUp() public override {
        super.setUp();
        HostileActor refusing = new HostileActor();
        refusing.configure(HostileActor.Behaviour.REVERT, HostileActor.Behaviour.REVERT);
        network = address(refusing);
        address currency = _currency();
        stream.setTerms(_terms(currency));
        handler = new AuctionHandler(
            auction,
            stream,
            statements,
            escrow,
            MockERC20(currency),
            [guardian, unpauser, setter, platform]
        );
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = AuctionHandler.start.selector;
        selectors[1] = AuctionHandler.bid.selector;
        selectors[2] = AuctionHandler.warp.selector;
        selectors[3] = AuctionHandler.settle.selector;
        selectors[4] = AuctionHandler.pause.selector;
        selectors[5] = AuctionHandler.resume.selector;
        selectors[6] = AuctionHandler.withdrawBid.selector;
        selectors[7] = AuctionHandler.cancel.selector;
        selectors[8] = AuctionHandler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function _balance(address account) internal view returns (uint256) {
        address currency = address(handler.token());
        return currency == ETH ? account.balance : MockERC20(currency).balanceOf(account);
    }

    /// @dev Held funds equal the live high bids plus every credit: bids escrowed equal the
    ///      balance, and owed refunds equal the claimable balance.
    function invariant_HeldEqualsLiveBidsPlusCredits() public view {
        address currency = address(handler.token());
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
        address currency = address(handler.token());
        uint256 out = _balance(seller) + _balance(network) + escrow.owed(seller, currency)
            + escrow.owed(network, currency) + handler.ghostClaimed();
        assertEq(handler.ghostDeposited(), _balance(address(auction)) + out);
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

    /// @dev After every auction is driven to an end and every account claims, nothing is stuck:
    ///      the auction holds no funds and no token.
    function afterInvariant() public {
        for (uint256 i; i < handler.salesCount(); ++i) {
            vm.warp(block.timestamp + 8 days);
            handler.settle(i);
            handler.claimDelivery(i);
        }
        for (uint256 i; i < handler.actorsCount(); ++i) {
            handler.claim(i);
        }
        assertEq(_balance(address(auction)), 0, "no stuck funds");
        assertEq(stream.balanceOf(address(auction)), 0, "no stuck tokens");
        assertEq(
            handler.ghostDeposited(),
            _balance(seller) + _balance(network) + escrow.owed(seller, address(handler.token()))
                + escrow.owed(network, address(handler.token())) + handler.ghostClaimed()
        );
    }
}

contract AuctionInvariantEth is AuctionInvariantBase {
    function _currency() internal pure override returns (address) {
        return ETH;
    }
}

contract AuctionInvariantErc20 is AuctionInvariantBase {
    function _currency() internal override returns (address) {
        coin = new MockERC20("Coin", "COIN");
        allowlist.admitAsset(address(coin), 0, 1e15);
        return address(coin);
    }
}
