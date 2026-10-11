// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { Statement } from "src/interfaces/IStatementLog.sol";
import { HashRef, HASH_SHA256 } from "src/interfaces/types/HashRef.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { MockERC20 } from "../../../mocks/EconomicsMocks.sol";
import { HostileActor, MockMintTarget } from "../../../mocks/auction/AuctionMocks.sol";

/// @dev Drives one currency's auctions through every lifecycle path: starts, bids from honest
///      and hostile bidders, time, dispute pauses, withdrawals, upheld cancellations,
///      resumptions, settlements, credit claims and pending-delivery claims. Every action is
///      guarded so it never reverts (`fail_on_revert`), and ghost totals record what entered and
///      left the auction.
contract AuctionHandler is Test {
    uint256 internal constant MAX_SALES = 8;

    EnglishAuction public immutable auction;
    MockMintTarget public immutable stream;
    StatementLog public immutable statements;
    RevenueEscrow public immutable escrow;
    MockERC20 public immutable token;
    address public immutable currency;
    address public immutable guardian;
    address public immutable unpauser;
    address public immutable setter;
    address public immutable platform;
    address public immutable pauser;
    address public immutable sink = makeAddr("sink");

    address[] public actors;
    uint256[] public sales;
    HostileActor public hostile;

    uint256 public ghostDeposited;
    uint256 public ghostClaimed;
    mapping(uint256 saleId => uint256) public ghostSettlements;
    mapping(uint256 saleId => uint256) public ghostCancellations;
    /// @dev How often each path really ran, for coverage checks.
    mapping(bytes32 path => uint256) public hits;

    constructor(
        EnglishAuction auction_,
        MockMintTarget stream_,
        StatementLog statements_,
        RevenueEscrow escrow_,
        MockERC20 token_,
        address[5] memory roles
    ) {
        auction = auction_;
        stream = stream_;
        statements = statements_;
        escrow = escrow_;
        token = token_;
        currency = address(token_);
        (guardian, unpauser, setter, platform, pauser) =
        (roles[0], roles[1], roles[2], roles[3], roles[4]);
        hostile = new HostileActor();
        hostile.configure(HostileActor.Behaviour.REVERT, HostileActor.Behaviour.REVERT);
        actors.push(makeAddr("bidder0"));
        actors.push(makeAddr("bidder1"));
        actors.push(makeAddr("bidder2"));
        actors.push(address(hostile));
    }

    // ---------------------------------------------------------------------------- actions

    function start() external {
        if (sales.length >= MAX_SALES || auction.paused()) return;
        sales.push(auction.start(address(stream), ""));
    }

    function bid(uint256 saleSeed, uint256 actorSeed, uint256 amountSeed, bool forHostile)
        external
    {
        if (sales.length == 0) return;
        uint256 saleId = _sale(saleSeed);
        if (auction.auction(saleId).state != IEnglishAuction.AuctionState.ACTIVE) return;
        uint256 minimum = auction.minimumBid(saleId);
        uint256 amount = bound(amountSeed, minimum, minimum * 3 + 1 ether);
        address bidder = actors[actorSeed % actors.length];
        address recipient = forHostile ? address(hostile) : address(0);
        Payment memory p = Payment(PaymentMethod.DIRECT, bidder, amount, 0, 0, "");
        uint256 value = currency == address(0) ? amount : 0;
        if (value != 0) vm.deal(bidder, value);
        else token.mint(bidder, amount);
        if (bidder == address(hostile)) {
            if (value == 0) {
                hostile.execute(
                    currency, 0, abi.encodeCall(token.approve, (address(auction), amount))
                );
            }
            hostile.execute(
                address(auction), value, abi.encodeCall(auction.bid, (saleId, recipient, p))
            );
        } else {
            vm.startPrank(bidder);
            if (value == 0) token.approve(address(auction), amount);
            auction.bid{ value: value }(saleId, recipient, p);
            vm.stopPrank();
        }
        ghostDeposited += amount;
        ++hits["bid"];
    }

    /// @dev The emergency pause stops only new starts; live auctions must carry on.
    function toggleStartPause() external {
        if (auction.paused()) {
            vm.prank(unpauser);
            auction.unpause();
        } else {
            vm.prank(pauser);
            auction.pause();
        }
        ++hits["startPause"];
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 1 days));
    }

    function settle(uint256 saleSeed) external {
        if (sales.length == 0) return;
        uint256 saleId = _sale(saleSeed);
        if (auction.auction(saleId).state != IEnglishAuction.AuctionState.ENDED) return;
        auction.settle(saleId);
        ++ghostSettlements[saleId];
        ++hits["settle"];
    }

    function pause(uint256 saleSeed) external {
        if (sales.length == 0) return;
        uint256 saleId = _sale(saleSeed);
        if (auction.auction(saleId).state != IEnglishAuction.AuctionState.ACTIVE) return;
        if (_pauseUsed(saleId)) return;
        vm.prank(guardian);
        auction.pause(saleId, keccak256(abi.encode(saleId)));
        ++hits["pause"];
    }

    function resume(uint256 saleSeed) external {
        if (sales.length == 0) return;
        uint256 saleId = _sale(saleSeed);
        if (auction.auction(saleId).state != IEnglishAuction.AuctionState.PAUSED) return;
        vm.prank(unpauser);
        auction.resume(saleId);
        ++hits["resume"];
    }

    function withdrawBid(uint256 saleSeed) external {
        if (sales.length == 0) return;
        uint256 saleId = _sale(saleSeed);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        if (a.state != IEnglishAuction.AuctionState.PAUSED || a.bidder == address(0)) return;
        vm.prank(a.bidder);
        auction.withdrawBid(saleId);
        ++hits["withdraw"];
    }

    function cancel(uint256 saleSeed) external {
        if (sales.length == 0) return;
        uint256 saleId = _sale(saleSeed);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        if (a.state != IEnglishAuction.AuctionState.PAUSED) return;
        Statement memory s = Statement(
            a.token,
            a.tokenId,
            StatementKinds.DISPUTE_OUTCOME,
            keccak256("schema"),
            HashRef(HASH_SHA256, keccak256(abi.encode(saleId))),
            "ipfs://outcome",
            bytes32(0),
            bytes32(0)
        );
        vm.prank(platform);
        bytes32 outcome = statements.appendPlatform(s);
        vm.prank(setter);
        auction.cancel(saleId, outcome);
        ++ghostCancellations[saleId];
        ++hits["cancel"];
    }

    function claim(uint256 actorSeed) external {
        address account = actors[actorSeed % actors.length];
        uint256 amount = auction.claimable(account, currency);
        if (amount == 0) return;
        if (account == address(hostile)) {
            hostile.execute(address(auction), 0, abi.encodeCall(auction.claim, (currency, sink)));
        } else {
            vm.prank(account);
            auction.claim(currency, account);
        }
        ghostClaimed += amount;
        ++hits["claim"];
    }

    /// @dev The pending recipient claims, or the winning bidder does on its behalf.
    function claimDelivery(uint256 saleSeed, bool asWinner) external {
        if (sales.length == 0) return;
        uint256 saleId = _sale(saleSeed);
        address claimant = auction.pendingDelivery(saleId);
        if (claimant == address(0)) return;
        address winner = auction.auction(saleId).bidder;
        if (asWinner && winner != address(0)) claimant = winner;
        if (claimant == address(hostile)) {
            hostile.execute(
                address(auction), 0, abi.encodeCall(auction.claimDelivery, (saleId, sink))
            );
        } else {
            vm.prank(claimant);
            auction.claimDelivery(saleId, sink);
        }
        ++hits["delivery"];
    }

    // ------------------------------------------------------------------------------ reads

    function salesCount() external view returns (uint256) {
        return sales.length;
    }

    function actorsCount() external view returns (uint256) {
        return actors.length;
    }

    function _sale(uint256 seed) internal view returns (uint256) {
        return sales[seed % sales.length];
    }

    /// @dev Whether the handler already paused the sale (one pause per auction).
    mapping(uint256 saleId => bool) internal _paused;

    function _pauseUsed(uint256 saleId) internal returns (bool used) {
        used = _paused[saleId];
        _paused[saleId] = true;
    }
}
