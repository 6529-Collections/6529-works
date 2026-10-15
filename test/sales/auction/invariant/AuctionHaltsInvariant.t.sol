// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { HostileActor } from "../../../mocks/sales/AuctionMocks.sol";
import { AuctionBase } from "../AuctionBase.sol";
import { AuctionHaltsHandler, SwitchToken } from "./AuctionHaltsHandler.sol";

abstract contract AuctionHaltsFixture is AuctionBase {
    AuctionHaltsHandler internal handler;
    SwitchToken internal coin;

    function _currency() internal virtual returns (address);

    function setUp() public override {
        super.setUp();
        HostileActor refusing = new HostileActor();
        refusing.configure(HostileActor.Behaviour.REVERT, HostileActor.Behaviour.REVERT);
        network = address(refusing);
        address currency = _currency();
        stream.setTerms(_terms(currency));
        handler = new AuctionHaltsHandler(
            AuctionHaltsHandler.Setup(
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
                pauser,
                seller,
                network
            )
        );
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](18);
        selectors[0] = AuctionHaltsHandler.start.selector;
        selectors[1] = AuctionHaltsHandler.startWithBid.selector;
        selectors[2] = AuctionHaltsHandler.bid.selector;
        selectors[3] = AuctionHaltsHandler.warp.selector;
        selectors[4] = AuctionHaltsHandler.settle.selector;
        selectors[5] = AuctionHaltsHandler.pause.selector;
        selectors[6] = AuctionHaltsHandler.pauseAndWithdraw.selector;
        selectors[7] = AuctionHaltsHandler.resume.selector;
        selectors[8] = AuctionHaltsHandler.withdrawBid.selector;
        selectors[9] = AuctionHaltsHandler.cancel.selector;
        selectors[10] = AuctionHaltsHandler.claim.selector;
        selectors[11] = AuctionHaltsHandler.claimDelivery.selector;
        selectors[12] = AuctionHaltsHandler.toggleStartPause.selector;
        selectors[13] = AuctionHaltsHandler.govern.selector;
        selectors[14] = AuctionHaltsHandler.toggleCurrency.selector;
        selectors[15] = AuctionHaltsHandler.toggleBroken.selector;
        selectors[16] = AuctionHaltsHandler.claimFor.selector;
        selectors[17] = AuctionHaltsHandler.bid.selector;
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

    function _credits() internal view returns (uint256 owed) {
        address currency = handler.currency();
        for (uint256 i; i < handler.actorsCount(); ++i) {
            owed += auction.claimable(handler.actors(i), currency);
        }
        owed += auction.claimable(seller, currency) + auction.claimable(network, currency);
    }

    function _liveBids() internal view returns (uint256 owed) {
        for (uint256 i; i < handler.salesCount(); ++i) {
            IEnglishAuction.Auction memory a = auction.auction(handler.sales(i));
            if (
                a.state != IEnglishAuction.AuctionState.SETTLED
                    && a.state != IEnglishAuction.AuctionState.CANCELLED && a.bidder != address(0)
            ) owed += a.bid;
        }
    }
}

abstract contract AuctionHaltsInvariantBase is AuctionHaltsFixture {
    /// @dev The auction's balance covers (equals) every live high bid and every credit,
    ///      payout credits (MONEY-1) included; a withdrawn bid's reserve is not counted twice.
    function invariant_BalanceCoversOwed() public view {
        uint256 owed = _liveBids() + _credits();
        assertGe(_balance(address(auction)), owed, "balance >= owed");
        assertEq(_balance(address(auction)), owed, "balance == owed");
    }

    function invariant_ValueIsConserved() public view {
        assertEq(handler.ghostDeposited(), _balance(address(auction)) + _out());
    }

    /// @dev Exactly one owner or custody per token: open sales hold it, a settled sale holds
    ///      it only while its delivery is pending, a cancelled sale burned it.
    function invariant_ExactCustody() public view {
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
                assertEq(held, auction.pendingDelivery(saleId) != address(0));
            } else {
                assertEq(outcomes, 0);
                assertTrue(held, "open sales keep the token");
            }
        }
    }

    /// @dev Settle is eventually possible: once the token works and the currency is back,
    ///      every sale settles (or was cancelled), and nothing is left in the auction.
    function afterInvariant() public {
        handler.drain();
        for (uint256 i; i < handler.salesCount(); ++i) {
            IEnglishAuction.Auction memory a = auction.auction(handler.sales(i));
            assertTrue(
                a.state == IEnglishAuction.AuctionState.SETTLED
                    || a.state == IEnglishAuction.AuctionState.CANCELLED,
                "every sale ends"
            );
        }
        assertEq(_balance(address(auction)), 0, "no stuck funds");
        assertEq(stream.balanceOf(address(auction)), 0, "no stuck tokens");
        assertEq(handler.ghostDeposited(), _out());
    }
}

contract AuctionHaltsInvariantEth is AuctionHaltsInvariantBase {
    function _currency() internal pure override returns (address) {
        return ETH;
    }
}

contract AuctionHaltsInvariantErc20 is AuctionHaltsInvariantBase {
    function _currency() internal override returns (address) {
        coin = new SwitchToken();
        coin.setBlocked(seller, true);
        allowlist.admitAsset(address(coin), 0, 1e15);
        return address(coin);
    }
}

/// @dev Checks that the new paths really run in campaign-shaped sequences.
contract AuctionHaltsCoverage is AuctionHaltsFixture {
    function _currency() internal override returns (address) {
        coin = new SwitchToken();
        coin.setBlocked(seller, true);
        allowlist.admitAsset(address(coin), 0, 1e15);
        return address(coin);
    }

    /// @dev Every halt path runs in campaign-shaped sequences. Half the runs then let a freeze
    ///      run 31 days before settling (the freeze exit); every run ends with `drain`, which
    ///      re-admits the currency (the reopenings) and settles everything.
    function test_HaltPathsRun() public {
        string[16] memory names = [
            "deprecate",
            "readmit",
            "readmitTooEarly",
            "reopen",
            "frozenSettleRefused",
            "freezeExit",
            "frozenWithdraw",
            "withdraw",
            "earlySettleRefused",
            "earlyCancelRefused",
            "payoutCredited",
            "claimFor",
            "broken",
            "settle",
            "cancel",
            "resume"
        ];
        uint256[16] memory totals;
        for (uint256 r; r < 64; ++r) {
            uint256 snap = vm.snapshotState();
            for (uint256 d; d < 128; ++d) {
                _step(uint256(keccak256(abi.encode(r, d))));
            }
            if (r % 2 == 0) {
                vm.warp(block.timestamp + 31 days);
                for (uint256 i; i < handler.salesCount(); ++i) {
                    handler.settle(i);
                }
            }
            handler.drain();
            for (uint256 i; i < 16; ++i) {
                totals[i] += handler.hits(bytes32(bytes(names[i])));
            }
            vm.revertToState(snap);
        }
        for (uint256 i; i < 16; ++i) {
            console2.log(names[i], totals[i]);
            assertGt(totals[i], 0, names[i]);
        }
    }

    function _step(uint256 seed) internal {
        uint256 which = seed % 18;
        (uint256 a, uint256 b, uint256 c) = (seed >> 8, seed >> 40, seed >> 72);
        if (which == 0) handler.start();
        else if (which == 1) handler.startWithBid(a, b);
        else if (which == 2 || which == 17) handler.bid(a, b, c, seed >> 120);
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
        else if (which == 13) handler.govern(a);
        else if (which == 14) handler.toggleCurrency(a);
        else if (which == 15) handler.toggleBroken();
        else handler.claimFor(a);
    }
}
