// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { AuctionFixture } from "../AuctionFixture.sol";
import { MockStatementLog } from "../AuctionMocks.sol";

/// @notice Drives the auction through starts, bids, warps, settlements, claims, expiries,
///         dispute pauses, withdrawals, cancels and restarts, and keeps a model of every
///         credit's money with the time each part arrived.
contract AuctionHandler is CommonBase, StdCheats, StdUtils {
    EnglishAuction public immutable auction;
    IDirectory public immutable directory;
    MockStatementLog public immutable statements;
    address public immutable stream;
    address public immutable ind;
    address public immutable network;

    address[3] public actors;
    uint256[] public sales;
    uint256 public starts;

    struct Piece {
        uint256 amount;
        uint256 at;
    }

    mapping(address => Piece[]) internal _pieces;
    /// @notice Set if an expiry ever took money younger than the period in force.
    bool public tookYoungMoney;
    uint256 public expiries;

    constructor(
        EnglishAuction auction_,
        IDirectory directory_,
        MockStatementLog statements_,
        address stream_,
        address ind_
    ) {
        (auction, directory, statements, stream, ind) =
        (auction_, directory_, statements_, stream_, ind_);
        network = msg.sender;
        actors = [address(0xA1), address(0xA2), address(0xA3)];
        for (uint256 i; i < 3; ++i) {
            vm.deal(actors[i], 1e24);
        }
    }

    function salesCount() external view returns (uint256) {
        return sales.length;
    }

    function accounts() external view returns (address[] memory a) {
        a = new address[](3);
        (a[0], a[1], a[2]) = (actors[0], actors[1], actors[2]);
    }

    function saleIds() external view returns (uint256[] memory) {
        return sales;
    }

    // -------------------------------------------------------------------------- actions

    function start(bool independent, uint256 actorSeed, uint256 amount, bool withBid) external {
        address token = independent ? ind : stream;
        bytes memory request = abi.encode(++starts);
        address actor = actors[actorSeed % 3];
        uint256 before = _snapshot();
        if (withBid) {
            amount = bound(amount, 1, 10 ether);
            vm.prank(actor);
            try auction.startWithBid{ value: amount }(token, request, address(0)) returns (
                uint256 saleId
            ) {
                sales.push(saleId);
            } catch { }
        } else {
            vm.prank(actor);
            try auction.start(token, request) returns (uint256 saleId) {
                sales.push(saleId);
            } catch { }
        }
        _recordCredits(before);
    }

    function bid(uint256 actorSeed, uint256 saleSeed, uint256 extra) external {
        if (sales.length == 0) return;
        uint256 saleId = sales[saleSeed % sales.length];
        address actor = actors[actorSeed % 3];
        uint256 amount;
        try auction.minimumBid(saleId) returns (uint256 m) {
            amount = m + bound(extra, 0, 1 ether);
        } catch {
            return;
        }
        if (amount > type(uint96).max) return;
        uint256 before = _snapshot();
        vm.prank(actor);
        try auction.bid{ value: amount }(saleId, address(0)) { } catch { }
        _recordCredits(before);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 60 days));
    }

    function settle(uint256 saleSeed) external {
        if (sales.length == 0) return;
        uint256 before = _snapshot();
        try auction.settle(sales[saleSeed % sales.length]) { } catch { }
        _recordCredits(before);
    }

    function settleOrRefund(uint256 saleSeed) external {
        if (sales.length == 0) return;
        uint256 before = _snapshot();
        try auction.settleOrRefund(sales[saleSeed % sales.length]) { } catch { }
        _recordCredits(before);
    }

    function restart(uint256 saleSeed) external {
        if (sales.length == 0) return;
        try auction.restart(sales[saleSeed % sales.length]) { } catch { }
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % 3];
        vm.prank(actor);
        try auction.claim(actor) {
            delete _pieces[actor];
        } catch { }
    }

    function expire(uint256 actorSeed) external {
        address actor = actors[actorSeed % 3];
        try auction.expireCredit(actor) returns (uint256 taken) {
            ++expiries;
            uint256 period = directory.unclaimedPeriod();
            uint256 aged;
            Piece[] storage p = _pieces[actor];
            for (uint256 i; i < p.length; ++i) {
                if (p[i].at + period <= block.timestamp) aged += p[i].amount;
            }
            if (taken > aged) tookYoungMoney = true;
            _takeOldest(actor, taken);
        } catch { }
    }

    function disputePause(uint256 saleSeed) external {
        if (sales.length == 0) return;
        vm.prank(network);
        try auction.pause(sales[saleSeed % sales.length], bytes32("d")) { } catch { }
    }

    function withdraw(uint256 saleSeed) external {
        if (sales.length == 0) return;
        uint256 saleId = sales[saleSeed % sales.length];
        address bidder;
        try auction.auction(saleId) returns (IEnglishAuction.Auction memory a) {
            bidder = a.bidder;
        } catch {
            return;
        }
        if (bidder == address(0)) return;
        uint256 before = _snapshot();
        vm.prank(bidder);
        try auction.withdrawBid(saleId) { } catch { }
        _recordCredits(before);
    }

    function cancel(uint256 saleSeed) external {
        if (sales.length == 0) return;
        uint256 saleId = sales[saleSeed % sales.length];
        IEnglishAuction.Auction memory a;
        try auction.auction(saleId) returns (IEnglishAuction.Auction memory got) {
            a = got;
        } catch {
            return;
        }
        statements.setOutcome(a.token, a.tokenId, keccak256(abi.encode(saleId)), 1);
        uint256 before = _snapshot();
        vm.prank(network);
        try auction.cancel(saleId, keccak256(abi.encode(saleId))) { } catch { }
        _recordCredits(before);
    }

    function setPeriod(uint256 period) external {
        vm.prank(network);
        directory.setUnclaimedPeriod(uint48(bound(period, 0, 200 days)));
    }

    // ---------------------------------------------------------------------------- model

    /// @dev The sum of claimables before an action, packed per actor into one call's memory.
    uint256[3] internal _before;

    function _snapshot() internal returns (uint256) {
        for (uint256 i; i < 3; ++i) {
            _before[i] = auction.claimable(actors[i]);
        }
        return 0;
    }

    /// @dev Money credited by the last action arrives now.
    function _recordCredits(uint256) internal {
        for (uint256 i; i < 3; ++i) {
            uint256 nowHeld = auction.claimable(actors[i]);
            if (nowHeld > _before[i]) {
                _pieces[actors[i]].push(Piece(nowHeld - _before[i], block.timestamp));
            }
        }
    }

    /// @dev The aged part is the oldest money: remove `amount` from the oldest pieces.
    function _takeOldest(address actor, uint256 amount) internal {
        Piece[] storage p = _pieces[actor];
        uint256 i;
        while (amount != 0 && i < p.length) {
            uint256 take = p[i].amount < amount ? p[i].amount : amount;
            p[i].amount -= take;
            amount -= take;
            ++i;
        }
    }
}

/// @notice Invariants of the auction's money: its ETH balance is exactly the standing bids of
///         unsettled sales plus the credits; an expiry never takes money younger than the
///         period in force.
contract AuctionInvariantTest is AuctionFixture {
    AuctionHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new AuctionHandler(
            auction, IDirectory(address(directory)), statements, address(stream), address(ind)
        );
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_BalanceIsStandingBidsPlusCredits() public view {
        assertEq(address(auction).balance, _owed(handler.saleIds(), handler.accounts()));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_NeverTakesMoneyYoungerThanThePeriod() public view {
        assertFalse(handler.tookYoungMoney());
    }
}
