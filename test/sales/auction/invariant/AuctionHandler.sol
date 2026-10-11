// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
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
    MockMintTarget,
    MockPermit2
} from "../../../mocks/auction/AuctionMocks.sol";

/// @dev Drives one currency's auctions through every lifecycle path: starts and start-with-bids,
///      bids from honest and hostile bidders for themselves, for each other or for the hostile
///      actor (direct, EIP-2612 permits and relayed Permit2 intents for ERC-20), time, dispute
///      pauses with and without withdrawals, upheld cancellations, resumptions, settlements
///      (with the ERC-20 escrow route: the token blocks the seller wallet), credit claims,
///      delivery claims by the recipient or the winner, the emergency start pause, and
///      governance changes to the config, the opening bid and the increment floor. Every action
///      is guarded so it never reverts (`fail_on_revert`), and ghost totals record what entered
///      and left the auction. Ghost terms record what each sale locked and whom its live high
///      bid names. A bid checks the anti-snipe extension against the locked window; a
///      settlement checks that the token reaches (or is pending for) that recipient, or the
///      artist when there was no bid; a second dispute pause must revert; and a withdrawal must
///      leave the sale paused.
contract AuctionHandler is Test {
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
    /// @dev How often each path really ran, for coverage checks.
    mapping(bytes32 path => uint256) public hits;

    /// @dev What a sale locked: the opening bid, increment share and anti-snipe window at its
    ///      start, and the currency's increment floor at its first bid (zero before).
    struct Locked {
        uint256 openingBid;
        uint256 incrementShare;
        uint256 extensionWindow;
        uint256 incrementFloor;
    }

    mapping(uint256 saleId => Locked) internal _locked;
    /// @dev The token's recipient named by the live high bid (its bidder when it named none).
    mapping(uint256 saleId => address) public ghostRecipient;

    constructor(Setup memory c) {
        (auction, stream, statements, escrow, allowlist, permit2) =
        (c.auction, c.stream, c.statements, c.escrow, c.allowlist, c.permit2);
        (currency, admin, guardian, unpauser, setter, platform, pauser) =
        (c.currency, c.admin, c.guardian, c.unpauser, c.setter, c.platform, c.pauser);
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

    // ---------------------------------------------------------------------------- actions

    function start() external {
        if (sales.length >= MAX_SALES || auction.paused()) return;
        uint256 saleId = auction.start(address(stream), "");
        sales.push(saleId);
        _lockStart(saleId);
        ++hits["start"];
    }

    function startWithBid(uint256 actorSeed, uint256 amountSeed) external {
        if (sales.length >= MAX_SALES || auction.paused()) return;
        if (currency != address(0) && !allowlist.isActive(currency)) return;
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
        if (sales.length == 0) return;
        uint256 saleId = _sale(saleSeed);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        if (a.state != IEnglishAuction.AuctionState.ACTIVE) return;
        if (currency != address(0) && !allowlist.isActive(currency)) return;
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
            ++hits["bid"];
        } else if (method == 1) {
            uint256 key = _keys[actorSeed % actors.length];
            _token().mint(bidder, amount);
            Payment memory p = _permit(key, amount);
            vm.prank(bidder);
            auction.bid(saleId, recipient, p);
            ++hits["permit"];
        } else {
            uint256 key = _keys[actorSeed % actors.length];
            _token().mint(bidder, amount);
            Payment memory p =
                _permit2Payment(key, saleId, recipient == address(0) ? bidder : recipient, amount);
            vm.prank(relayer);
            auction.bid(saleId, recipient, p);
            ++hits["permit2"];
        }
        ghostDeposited += amount;
        _recordBid(saleId, recipient == address(0) ? bidder : recipient);
        if (recipient != address(0) && recipient != bidder) ++hits["forAnother"];
        uint256 end = block.timestamp + _locked[saleId].extensionWindow;
        if (a.endTime > end) end = a.endTime;
        assertEq(auction.auction(saleId).endTime, end, "anti-snipe uses the locked window");
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 1 days));
    }

    function settle(uint256 saleSeed) external {
        if (sales.length == 0) return;
        uint256 saleId = _sale(saleSeed);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        if (a.state != IEnglishAuction.AuctionState.ENDED) return;
        address expected = ghostRecipient[saleId];
        if (expected == address(0)) expected = stream.primaryTerms(a.tokenId, "").creator;
        auction.settle(saleId);
        address pending = auction.pendingDelivery(saleId);
        if (pending == address(0)) {
            assertEq(stream.ownerOf(a.tokenId), expected, "delivered to the named recipient");
        } else {
            assertEq(pending, expected, "pending for the named recipient");
        }
        ++ghostSettlements[saleId];
        ++hits["settle"];
    }

    function pause(uint256 saleSeed) external {
        _pauseSale(saleSeed);
    }

    /// @dev A dispute pause followed at once by the high bidder's withdrawal.
    function pauseAndWithdraw(uint256 saleSeed) external {
        uint256 saleId = _pauseSale(saleSeed);
        if (saleId != 0) _withdraw(saleId);
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
        _withdraw(_sale(saleSeed));
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
        ghostRecipient[saleId] = address(0);
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

    /// @dev Governance moves mid-campaign: the config, the opening bid (both ways) and the
    ///      currency's increment floor. Running sales keep what they locked.
    function govern(uint256 seed) external {
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

    // ---------------------------------------------------------------------------- helpers

    function _sale(uint256 seed) internal view returns (uint256) {
        return sales[seed % sales.length];
    }

    /// @dev No recipient (the bidder), the hostile actor, or an honest actor: the bidder itself
    ///      or a third party.
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

    /// @dev A bid landed: the first one locks the floor, and the recipient is the one it named.
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

    function _withdraw(uint256 saleId) internal {
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        if (a.state != IEnglishAuction.AuctionState.PAUSED || a.bidder == address(0)) return;
        if (a.bidder == address(hostile)) {
            hostile.execute(address(auction), 0, abi.encodeCall(auction.withdrawBid, (saleId)));
        } else {
            vm.prank(a.bidder);
            auction.withdrawBid(saleId);
        }
        ghostRecipient[saleId] = address(0);
        assertEq(
            uint8(auction.auction(saleId).state),
            uint8(IEnglishAuction.AuctionState.PAUSED),
            "a withdrawal keeps the pause"
        );
        ++hits["withdraw"];
    }

    /// @dev Funds `payer` for a DIRECT payment of `amount` and returns it.
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
            permit2.digest(permit, address(auction), witness, Typehashes.BID_WITNESS_TYPE);
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
