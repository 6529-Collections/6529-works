// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { Statement } from "src/interfaces/IStatementLog.sol";
import { HashRef, HASH_SHA256 } from "src/interfaces/types/HashRef.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import {
    BlockablePermitToken,
    HostileActor,
    MockMintTarget
} from "../../../mocks/sales/AuctionMocks.sol";
import { MockPermit2, PermitToken } from "../../../mocks/sales/SaleMocks.sol";

/// @dev A permit token that can also refuse transfers *from* an address (USDC-style block of
///      the auction itself), so every payout and claim out of the auction fails, even through
///      the escrow (MONEY-1).
contract SwitchToken is PermitToken {
    mapping(address => bool) public blocked;
    mapping(address => bool) public blockedFrom;

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function setBlockedFrom(address account, bool isBlocked) external {
        blockedFrom[account] = isBlocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blockedFrom[from] && !blocked[to], "blocked");
        super._update(from, to, value);
    }
}

/// @dev The auction's lifecycle through halts: dispute pauses (with the 48-hour floor on
///      `resume` and `cancel`), the start pause, currency deprecation and re-admission (MARKET-2,
///      with the 14-day re-admission floor and the 30-day freeze exit), withdrawals while paused
///      or frozen (LIFECYCLE-1), a token that blocks the auction (MONEY-1 credits) and
///      `claimFor`. Every action is guarded so it never reverts unexpectedly
///      (`fail_on_revert`). Adopted from the independent review of the sales fixes.
contract AuctionHaltsHandler is Test {
    uint256 internal constant MAX_SALES = 8;

    struct Setup {
        EnglishAuction auction;
        MockMintTarget stream;
        StatementLog statements;
        RevenueEscrow escrow;
        AssetAllowlist allowlist;
        MockPermit2 permit2;
        address currency;
        address admin;
        address guardian;
        address unpauser;
        address setter;
        address platform;
        address pauser;
        address seller;
        address network;
    }

    EnglishAuction public immutable auction;
    MockMintTarget public immutable stream;
    StatementLog public immutable statements;
    RevenueEscrow public immutable escrow;
    AssetAllowlist public immutable allowlist;
    MockPermit2 public immutable permit2;
    address public immutable currency;
    address public immutable admin;
    address public immutable guardian;
    address public immutable unpauser;
    address public immutable setter;
    address public immutable platform;
    address public immutable pauser;
    address public immutable seller;
    address public immutable network;
    address public immutable sink = makeAddr("sink");
    address public immutable relayer = makeAddr("handlerRelayer");

    address[] public actors;
    uint256[] internal _keys;
    uint256[] public sales;
    HostileActor public hostile;
    uint256 internal _permit2Nonce;

    uint256 public ghostDeposited;
    uint256 public ghostClaimed;
    mapping(uint256 saleId => uint256) public ghostSettlements;
    mapping(uint256 saleId => uint256) public ghostCancellations;
    mapping(uint256 saleId => bool) internal _paused;
    uint256 internal startPausedAt;
    bool public broken;
    mapping(bytes32 path => uint256) public hits;

    struct Locked {
        uint256 openingBid;
        uint256 incrementShare;
        uint256 extensionWindow;
        uint256 incrementFloor;
    }

    mapping(uint256 saleId => Locked) internal _locked;
    mapping(uint256 saleId => address) public ghostRecipient;

    constructor(Setup memory c) {
        (auction, stream, statements, escrow, allowlist, permit2) =
        (c.auction, c.stream, c.statements, c.escrow, c.allowlist, c.permit2);
        (currency, admin, guardian, unpauser, setter, platform, pauser) =
        (c.currency, c.admin, c.guardian, c.unpauser, c.setter, c.platform, c.pauser);
        (seller, network) = (c.seller, c.network);
        hostile = new HostileActor();
        hostile.configure(HostileActor.Behaviour.REVERT, HostileActor.Behaviour.REVERT);
        for (uint256 i = 1; i <= 3; ++i) {
            _keys.push(0xB1D0 + i);
            actors.push(vm.addr(0xB1D0 + i));
        }
        actors.push(address(hostile));
        if (currency != address(0)) {
            for (uint256 i; i < 3; ++i) {
                vm.prank(actors[i]);
                _token().approve(address(permit2), type(uint256).max);
            }
        }
    }

    function _active() internal view returns (bool) {
        return allowlist.isActive(currency);
    }

    // ---------------------------------------------------------------------------- actions

    function start() external {
        if (sales.length >= MAX_SALES || auction.paused() || !_active()) return;
        uint256 saleId = auction.start(address(stream), "");
        sales.push(saleId);
        _lockStart(saleId);
        ++hits["start"];
    }

    function startWithBid(uint256 actorSeed, uint256 amountSeed) external {
        if (sales.length >= MAX_SALES || auction.paused() || !_active()) return;
        address bidder = actors[actorSeed % actors.length];
        uint256 opening = auction.openingBid(currency);
        uint256 amount = bound(amountSeed, opening == 0 ? 1 : opening, opening + 3 ether);
        Payment memory p = _fund(bidder, amount);
        bytes memory call =
            abi.encodeCall(auction.startWithBid, (address(stream), "", address(0), p));
        uint256 value = currency == address(0) ? amount : 0;
        uint256 saleId;
        if (bidder == address(hostile)) {
            saleId = abi.decode(hostile.execute(address(auction), value, call), (uint256));
        } else {
            vm.prank(bidder);
            saleId = auction.startWithBid{ value: value }(address(stream), "", address(0), p);
        }
        sales.push(saleId);
        _lockStart(saleId);
        _recordBid(saleId, bidder);
        ghostDeposited += amount;
        ++hits["startWithBid"];
    }

    function bid(uint256 saleSeed, uint256 actorSeed, uint256 amountSeed, uint256 options)
        external
    {
        if (sales.length == 0 || !_active()) return;
        uint256 saleId = _sale(saleSeed);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        if (a.state != IEnglishAuction.AuctionState.ACTIVE) return;
        uint256 minimum = auction.minimumBid(saleId);
        uint256 amount = bound(amountSeed, minimum, minimum * 3 + 1 ether);
        address bidder = actors[actorSeed % actors.length];
        address recipient = _recipient(options);
        uint256 method =
            currency == address(0) || bidder == address(hostile) ? 0 : (options >> 2) % 3;
        if (method == 0) {
            Payment memory p = _fund(bidder, amount);
            uint256 value = currency == address(0) ? amount : 0;
            if (bidder == address(hostile)) {
                hostile.execute(
                    address(auction), value, abi.encodeCall(auction.bid, (saleId, recipient, p))
                );
            } else {
                vm.prank(bidder);
                auction.bid{ value: value }(saleId, recipient, p);
            }
        } else if (method == 1) {
            uint256 key = _keys[actorSeed % actors.length];
            _token().mint(bidder, amount);
            Payment memory p = _permit(key, amount);
            vm.prank(bidder);
            auction.bid(saleId, recipient, p);
        } else {
            uint256 key = _keys[actorSeed % actors.length];
            _token().mint(bidder, amount);
            Payment memory p =
                _permit2Payment(key, saleId, recipient == address(0) ? bidder : recipient, amount);
            vm.prank(relayer);
            auction.bid(saleId, recipient, p);
        }
        ++hits["bid"];
        ghostDeposited += amount;
        _recordBid(saleId, recipient == address(0) ? bidder : recipient);
        uint256 end = block.timestamp + _locked[saleId].extensionWindow;
        if (a.endTime > end) end = a.endTime;
        assertEq(auction.auction(saleId).endTime, end, "anti-snipe uses the locked window");
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 3 days));
    }

    /// @dev Settles an ended sale, checking every outcome: a freeze with a standing bid
    ///      reverts, a re-admission in the last window or after the end reopens, and otherwise
    ///      the token reaches the named recipient (or the artist with no bidder). A sale that
    ///      has not ended must refuse to settle.
    function settle(uint256 saleSeed) public {
        if (sales.length == 0) return;
        uint256 saleId = _sale(saleSeed);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        if (
            a.state == IEnglishAuction.AuctionState.ACTIVE
                || a.state == IEnglishAuction.AuctionState.PAUSED
        ) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IEnglishAuction.InvalidAuctionState.selector, saleId, a.state
                )
            );
            auction.settle(saleId);
            ++hits["earlySettleRefused"];
            return;
        }
        if (a.state != IEnglishAuction.AuctionState.ENDED) return;
        (IAssetAllowlist.Status status, uint256 since,) = allowlist.statusClock(currency);
        bool active = status == IAssetAllowlist.Status.Active;
        if (!active) {
            // Nothing settles while frozen, sold or unsold, until the 30-day exit.
            if (block.timestamp < since + 30 days) {
                vm.expectRevert(
                    abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, currency)
                );
                auction.settle(saleId);
                ++hits["frozenSettleRefused"];
                return;
            }
            _freezeExit(saleId, a);
            return;
        }
        if (since + _locked[saleId].extensionWindow > a.endTime) {
            auction.settle(saleId);
            IEnglishAuction.Auction memory r = auction.auction(saleId);
            uint256 duration = auction.config().duration;
            uint256 window = _locked[saleId].extensionWindow;
            assertEq(uint8(r.state), uint8(IEnglishAuction.AuctionState.ACTIVE), "reopened");
            assertEq(
                r.endTime,
                block.timestamp + (duration > window ? duration : window),
                "the governed duration, or the locked window if longer"
            );
            assertEq(r.bidder, a.bidder, "the standing bid is kept");
            ++hits["reopen"];
            return;
        }
        address expected = ghostRecipient[saleId];
        if (expected == address(0)) expected = stream.primaryTerms(a.tokenId, "").creator;
        uint256 sellerCredit = auction.claimable(seller, currency);
        auction.settle(saleId);
        address pending = auction.pendingDelivery(saleId);
        if (pending == address(0)) {
            assertEq(stream.ownerOf(a.tokenId), expected, "delivered to the named recipient");
        } else {
            assertEq(pending, expected, "pending for the named recipient");
        }
        if (auction.claimable(seller, currency) > sellerCredit) ++hits["payoutCredited"];
        ++ghostSettlements[saleId];
        ++hits["settle"];
    }

    function pause(uint256 saleSeed) external {
        _pauseSale(saleSeed);
    }

    function pauseAndWithdraw(uint256 saleSeed) external {
        uint256 saleId = _pauseSale(saleSeed);
        if (saleId != 0) _withdraw(saleId);
    }

    function resume(uint256 saleSeed) external {
        if (sales.length == 0) return;
        uint256 saleId = _sale(saleSeed);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        if (a.state != IEnglishAuction.AuctionState.PAUSED) return;
        uint256 allowedAt = uint256(a.pausedAt) + Roles.STANDARD;
        vm.prank(unpauser);
        if (block.timestamp < allowedAt) {
            vm.expectRevert(
                abi.encodeWithSelector(ISaleAdapter.UnpauseTooEarly.selector, allowedAt)
            );
            auction.resume(saleId);
            return;
        }
        auction.resume(saleId);
        ++hits["resume"];
    }

    function withdrawBid(uint256 saleSeed) external {
        if (sales.length == 0) return;
        _withdraw(_sale(saleSeed));
    }

    function cancel(uint256 saleSeed) external {
        if (sales.length == 0) return;
        uint256 saleId = _sale(saleSeed);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        if (a.state != IEnglishAuction.AuctionState.PAUSED) return;
        uint256 allowedAt = uint256(a.pausedAt) + Roles.STANDARD;
        if (block.timestamp < allowedAt) {
            vm.prank(setter);
            vm.expectRevert(
                abi.encodeWithSelector(ISaleAdapter.UnpauseTooEarly.selector, allowedAt)
            );
            auction.cancel(saleId, bytes32(0));
            ++hits["earlyCancelRefused"];
            return;
        }
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
        ghostRecipient[saleId] = address(0);
        ++ghostCancellations[saleId];
        ++hits["cancel"];
    }

    function claim(uint256 actorSeed) public {
        if (broken) return;
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

    /// @dev `claimFor` the seller or network wallet (credited payouts), or an honest actor.
    function claimFor(uint256 seed) public {
        if (broken) return;
        uint256 pick = seed % 5;
        address account = pick == 0 ? seller : pick == 1 ? network : actors[pick - 2];
        uint256 amount = auction.claimable(account, currency);
        if (amount == 0) return;
        if (currency == address(0)) {
            // ETH credits are claimed by their account only.
            vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.InvalidAsset.selector, currency));
            auction.claimFor(account, currency);
            ++hits["claimForEthRefused"];
            return;
        }
        if (currency != address(0) && account == seller) {
            // The token blocks the seller wallet, so `claimFor` cannot push to it; a seller
            // that can call claims elsewhere.
            vm.prank(seller);
            auction.claim(currency, sink);
            ghostClaimed += amount;
            ++hits["sellerClaim"];
            return;
        }
        auction.claimFor(account, currency);
        if (account != seller && account != network) ghostClaimed += amount;
        ++hits["claimFor"];
    }

    function claimDelivery(uint256 saleSeed, bool asWinner) public {
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

    function toggleStartPause() external {
        if (auction.paused()) {
            uint256 allowedAt = startPausedAt + Roles.STANDARD;
            vm.prank(unpauser);
            if (block.timestamp < allowedAt) {
                vm.expectRevert(
                    abi.encodeWithSelector(ISaleAdapter.UnpauseTooEarly.selector, allowedAt)
                );
                auction.unpause();
                return;
            }
            auction.unpause();
        } else {
            vm.prank(pauser);
            auction.pause();
            startPausedAt = block.timestamp;
        }
        ++hits["startPause"];
    }

    /// @dev The guardian deprecates the currency (immediate), or governance re-admits it.
    function toggleCurrency(uint256 seed) public {
        if (_active()) {
            vm.prank(admin);
            allowlist.deprecateAsset(currency);
            ++hits["deprecate"];
        } else {
            (,, uint64 revision) = allowlist.assetConfig(currency);
            (, uint256 since,) = allowlist.statusClock(currency);
            uint256 floor = currency == address(0) ? 1e15 : 1e15 + seed % 1e15;
            uint256 allowedAt = since + Roles.FUNDS;
            vm.prank(admin);
            if (block.timestamp < allowedAt) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IAssetAllowlist.ReadmissionTooEarly.selector, currency, allowedAt
                    )
                );
                allowlist.admitAsset(currency, revision, floor);
                ++hits["readmitTooEarly"];
                return;
            }
            allowlist.admitAsset(currency, revision, floor);
            ++hits["readmit"];
        }
    }

    /// @dev For ERC-20 only: the token blocks the auction itself, so every payout out of it
    ///      fails, escrow route included, and claims fail too.
    function toggleBroken() external {
        if (currency == address(0)) return;
        broken = !broken;
        SwitchToken(currency).setBlockedFrom(address(auction), broken);
        ++hits["broken"];
    }

    function govern(uint256 seed) external {
        if (!_active()) return;
        uint256 what = seed % 3;
        if (what == 0) {
            IEnglishAuction.AuctionConfig memory c = auction.config();
            uint32 duration = uint32(bound(seed >> 8, 1 hours, 2 days));
            IEnglishAuction.AuctionConfig memory next = IEnglishAuction.AuctionConfig(
                duration,
                uint32(bound(seed >> 40, 1 minutes, 1 hours)),
                uint32(bound(seed >> 72, 1_000, 100_000))
            );
            vm.prank(setter);
            auction.setConfig(c, next);
        } else if (what == 1) {
            uint256 ceiling = allowlist.incrementFloor(currency) * auction.OPENING_BID_FLOORS();
            uint256 next = bound(seed >> 8, 0, ceiling / 10);
            uint256 current = auction.openingBid(currency);
            vm.prank(setter);
            auction.setOpeningBid(currency, current, next);
        } else {
            (,, uint64 revision) = allowlist.assetConfig(currency);
            vm.prank(admin);
            allowlist.setIncrementFloor(currency, revision, bound(seed >> 8, 1e12, 0.1 ether));
        }
        ++hits["govern"];
    }

    // ------------------------------------------------------------------------------ reads

    function salesCount() external view returns (uint256) {
        return sales.length;
    }

    function actorsCount() external view returns (uint256) {
        return actors.length;
    }

    function locked(uint256 saleId) external view returns (Locked memory) {
        return _locked[saleId];
    }

    /// @dev Drives everything to an end: unbreaks the token, re-admits the currency, then
    ///      settles each sale (reopened ones again after their end), claims every delivery and
    ///      every credit.
    function drain() external {
        if (broken) {
            broken = false;
            SwitchToken(currency).setBlockedFrom(address(auction), false);
        }
        if (!_active()) {
            (, uint256 since,) = allowlist.statusClock(currency);
            if (block.timestamp < since + Roles.FUNDS) vm.warp(since + Roles.FUNDS);
            toggleCurrency(0);
        }
        for (uint256 round; round < 4; ++round) {
            vm.warp(block.timestamp + 30 days);
            for (uint256 i; i < sales.length; ++i) {
                settle(i);
                claimDelivery(i, false);
            }
        }
        for (uint256 i; i < actors.length; ++i) {
            claim(i);
        }
        for (uint256 i; i < 5; ++i) {
            claimFor(i);
        }
    }

    // ---------------------------------------------------------------------------- helpers

    /// @dev The 30-day freeze exit: the standing bid is credited back to its bidder and the
    ///      work goes to its artist, delivered or pending.
    function _freezeExit(uint256 saleId, IEnglishAuction.Auction memory a) internal {
        address artist = stream.primaryTerms(a.tokenId, "").creator;
        uint256 credit = a.bidder == address(0) ? 0 : auction.claimable(a.bidder, currency);
        auction.settle(saleId);
        if (a.bidder != address(0)) {
            assertEq(auction.claimable(a.bidder, currency), credit + a.bid, "the bid is credited");
        }
        address pending = auction.pendingDelivery(saleId);
        if (pending == address(0)) {
            assertEq(stream.ownerOf(a.tokenId), artist, "the work goes to its artist");
        } else {
            assertEq(pending, artist, "pending for its artist");
        }
        ghostRecipient[saleId] = address(0);
        ++ghostSettlements[saleId];
        ++hits["freezeExit"];
    }

    function _sale(uint256 seed) internal view returns (uint256) {
        return sales[seed % sales.length];
    }

    function _recipient(uint256 options) internal view returns (address) {
        uint256 pick = options % 3;
        if (pick == 0) return address(0);
        if (pick == 1) return address(hostile);
        return actors[(options >> 8) % 3];
    }

    function _lockStart(uint256 saleId) internal {
        IEnglishAuction.AuctionConfig memory c = auction.config();
        _locked[saleId] =
            Locked(auction.openingBid(currency), c.incrementShare, c.extensionWindow, 0);
    }

    function _recordBid(uint256 saleId, address recipient) internal {
        Locked storage l = _locked[saleId];
        if (l.incrementFloor == 0) l.incrementFloor = allowlist.incrementFloor(currency);
        ghostRecipient[saleId] = recipient;
    }

    function _token() internal view returns (BlockablePermitToken) {
        return BlockablePermitToken(currency);
    }

    function _pauseSale(uint256 saleSeed) internal returns (uint256 saleId) {
        if (sales.length == 0) return 0;
        saleId = _sale(saleSeed);
        if (auction.auction(saleId).state != IEnglishAuction.AuctionState.ACTIVE) return 0;
        if (_paused[saleId]) {
            bytes memory exhausted =
                abi.encodeWithSelector(IEnglishAuction.PauseExhausted.selector, saleId);
            vm.prank(guardian);
            vm.expectRevert(exhausted);
            auction.pause(saleId, keccak256(abi.encode(saleId)));
            return 0;
        }
        _paused[saleId] = true;
        vm.prank(guardian);
        auction.pause(saleId, keccak256(abi.encode(saleId)));
        ++hits["pause"];
    }

    /// @dev The high bidder withdraws while paused, or (MARKET-2) while the currency is frozen
    ///      and the sale is neither settled nor cancelled.
    function _withdraw(uint256 saleId) internal {
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        if (a.bidder == address(0)) return;
        bool frozen = !_active()
            && (a.state == IEnglishAuction.AuctionState.ACTIVE
                || a.state == IEnglishAuction.AuctionState.ENDED
                || a.state == IEnglishAuction.AuctionState.PAUSED);
        if (a.state != IEnglishAuction.AuctionState.PAUSED && !frozen) return;
        if (a.bidder == address(hostile)) {
            hostile.execute(address(auction), 0, abi.encodeCall(auction.withdrawBid, (saleId)));
        } else {
            vm.prank(a.bidder);
            auction.withdrawBid(saleId);
        }
        ghostRecipient[saleId] = address(0);
        IEnglishAuction.Auction memory b = auction.auction(saleId);
        assertEq(b.bidder, address(0), "no bidder after a withdrawal");
        assertEq(b.bid, a.bid, "the withdrawn bid is the reserve");
        assertGe(auction.minimumBid(saleId), a.bid, "the next bid must reach it");
        ++hits[
            frozen && a.state != IEnglishAuction.AuctionState.PAUSED
                ? bytes32("frozenWithdraw")
                : bytes32("withdraw")
        ];
    }

    function _fund(address payer, uint256 amount) internal returns (Payment memory) {
        if (currency == address(0)) {
            vm.deal(payer, amount);
        } else {
            _token().mint(payer, amount);
            if (payer == address(hostile)) {
                hostile.execute(
                    currency, 0, abi.encodeCall(_token().approve, (address(auction), amount))
                );
            } else {
                vm.prank(payer);
                _token().approve(address(auction), amount);
            }
        }
        return Payment(PaymentMethod.DIRECT, payer, amount, 0, 0, "");
    }

    function _permit(uint256 key, uint256 amount) internal view returns (Payment memory) {
        address owner = vm.addr(key);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                owner,
                address(auction),
                amount,
                _token().nonces(owner),
                deadline
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", _token().DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return Payment(PaymentMethod.PERMIT, owner, amount, deadline, 0, abi.encodePacked(r, s, v));
    }

    function _permit2Payment(uint256 key, uint256 saleId, address recipient, uint256 amount)
        internal
        returns (Payment memory)
    {
        uint256 nonce = ++_permit2Nonce;
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom(
            ISignatureTransfer.TokenPermissions(currency, amount), nonce, block.timestamp + 1 hours
        );
        bytes32 witness = keccak256(
            abi.encode(Typehashes.BID_WITNESS, saleId, recipient, amount, permit.deadline)
        );
        bytes32 digest =
            permit2.witnessDigest(address(auction), permit, witness, Typehashes.BID_WITNESS_TYPE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return Payment(
            PaymentMethod.PERMIT2,
            vm.addr(key),
            amount,
            permit.deadline,
            nonce,
            abi.encodePacked(r, s, v)
        );
    }
}
