// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PaymentMethod, PrimaryOutcome } from "src/interfaces/types/SaleTypes.sol";
import { IEnglishAuctionFull } from "../helpers/IEnglishAuctionFull.sol";
import { FederationBase } from "./FederationBase.sol";
import { FaultyFederatedStream } from "./FederatedRefusal.t.sol";

/// @notice Drives federated sales on the real stack: starts on a genuine and a faulty template,
///         bids, settles, refused closes and reclaims, fault switching, delisting and relisting.
///         Ghosts what the network must have been paid.
contract FederationHandler is Test {
    IEnglishAuctionFull internal immutable _auction;
    FederationRegistry internal immutable _registry;
    WorksAccessManager internal immutable _manager;
    address internal immutable _admin;
    address internal immutable _artist;
    FederatedStream internal immutable _good;
    FaultyFederatedStream internal immutable _bad;
    uint256 internal immutable _refusalDelay;

    struct Start {
        bytes32 itemHash;
        bytes data;
    }

    Start[] internal _ready;
    uint256[] public sales;
    address[] public bidders;
    mapping(address => bool) internal _seen;
    /// @dev What the network must have received: price × share on each sold federated sale.
    uint256 public expectedFees;
    uint256 public soldCount;
    bool public delisted;

    constructor(
        IEnglishAuctionFull auction_,
        FederationRegistry registry_,
        WorksAccessManager manager_,
        address admin_,
        address artist_,
        FederatedStream good_,
        FaultyFederatedStream bad_,
        uint256 refusalDelay_
    ) {
        (
            _auction, _registry, _manager, _admin, _artist, _good, _bad, _refusalDelay
        ) = (auction_, registry_, manager_, admin_, artist_, good_, bad_, refusalDelay_);
    }

    /// @dev Pre-built mint requests (`FederationBase` builds them with content in the store).
    function addReady(bytes32 itemHash, bytes calldata data) external {
        _ready.push(Start(itemHash, data));
    }

    function readyCount() external view returns (uint256) {
        return _ready.length;
    }

    function salesCount() external view returns (uint256) {
        return sales.length;
    }

    function biddersCount() external view returns (uint256) {
        return bidders.length;
    }

    function start(uint256 seed) external {
        if (_ready.length == 0 || delisted) return;
        Start memory s = _ready[_ready.length - 1];
        _ready.pop();
        FederatedStream token = seed % 2 == 0 ? _good : FederatedStream(address(_bad));
        vm.prank(_artist);
        token.approveItem(s.itemHash, uint32(seed % 20_000));
        sales.push(_auction.start(address(token), s.data));
    }

    function bid(uint256 i, uint256 seed, uint96 amount) external {
        if (sales.length == 0) return;
        uint256 saleId = sales[i % sales.length];
        IEnglishAuction.Auction memory a = _auction.auction(saleId);
        if (a.state != IEnglishAuction.AuctionState.ACTIVE || block.timestamp >= a.endTime) return;
        if (delisted) return;
        uint256 minimum = _auction.minimumBid(saleId);
        uint256 value = bound(amount, minimum, minimum + 10 ether);
        address bidder = address(uint160(0xb1d000 + seed % 4));
        if (!_seen[bidder]) {
            _seen[bidder] = true;
            bidders.push(bidder);
        }
        vm.deal(bidder, value);
        vm.prank(bidder);
        _auction.bid{ value: value }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, bidder, value, 0, 0, "")
        );
    }

    function settle(uint256 i) external {
        if (sales.length == 0) return;
        uint256 saleId = sales[i % sales.length];
        IEnglishAuction.Auction memory a = _auction.auction(saleId);
        if (!_open(a)) return;
        if (block.timestamp < a.endTime) vm.warp(a.endTime);
        _settle(saleId, a, false);
    }

    function refuse(uint256 i) external {
        if (sales.length == 0) return;
        uint256 saleId = sales[i % sales.length];
        IEnglishAuction.Auction memory a = _auction.auction(saleId);
        if (!_open(a)) return;
        if (block.timestamp < a.endTime + _refusalDelay) vm.warp(a.endTime + _refusalDelay);
        _settle(saleId, a, true);
    }

    function toggleFault() external {
        _bad.setRefuse(!_bad.refuse());
    }

    function toggleListing() external {
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(_good), address(_bad));
        IFederationRegistry.Status next =
            delisted ? IFederationRegistry.Status.ACTIVE : IFederationRegistry.Status.DELISTED;
        bytes memory call = abi.encodeCall(_registry.setStatus, (tokens, next, bytes32(0)));
        vm.prank(_admin);
        _manager.schedule(address(_registry), call, 0);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(_admin);
        _manager.execute(address(_registry), call);
        delisted = !delisted;
    }

    function _open(IEnglishAuction.Auction memory a) private pure returns (bool) {
        return a.state == IEnglishAuction.AuctionState.ACTIVE
            || a.state == IEnglishAuction.AuctionState.ENDED;
    }

    /// @dev Settles (or, with `orRefund`, settles or refuses) and records the fee owed: a sale
    ///      sells only if it had a bidder, its token was served and its settlement succeeded.
    function _settle(uint256 saleId, IEnglishAuction.Auction memory a, bool orRefund) private {
        bool served = _registry.isActive(a.token);
        bool faulty = a.token == address(_bad) && _bad.refuse();
        if (orRefund) {
            _auction.settleOrRefund{ gas: 8_000_000 }(saleId);
            if (faulty) FederatedStream(a.token).reclaim(a.tokenId);
        } else {
            if (faulty) return;
            _auction.settle(saleId);
        }
        if (a.bidder != address(0) && served && !faulty) {
            expectedFees += a.bid - a.bid * (100_000 - 10_000) / 100_000;
            ++soldCount;
        }
    }
}

/// @notice Invariants of federated sales: the auction holds exactly the credits and live bids;
///         the network is paid exactly its locked share on every sold federated sale and nothing
///         otherwise; a buyer holds a federated work only if it paid; federation never touches
///         6529 Stream, a curated artist's identity or the network's canonical state.
contract FederationInvariantTest is FederationBase {
    FederationHandler internal handler;
    FaultyFederatedStream internal bad;
    uint256 internal feeStart;
    uint256 internal streamMinted;
    bytes32 internal curatedIdentity;
    address internal curated;
    address internal curatedCollector;

    function setUp() public override {
        super.setUp();
        _joinedFed();
        bad = FaultyFederatedStream(
            _copy(type(FaultyFederatedStream).creationCode, abi.encode(_streamConfig(fedArtist)))
        );
        _approveTemplate(
            fedRegistry,
            type(FaultyFederatedStream).creationCode,
            address(bad).codehash,
            99,
            IFederationRegistry.Form.ERC721
        );
        _join(address(bad), fedArtist);
        handler = new FederationHandler(
            auction, fedRegistry, manager, hotAdmin, fedArtist, fed, bad, REFUSAL_DELAY
        );
        for (uint256 i; i < 24; ++i) {
            Work memory w = _fedWork(fedArtist);
            handler.addReady(_itemHash(w), _mintData(w));
        }
        // A curated 6529 Stream sale, sold before the campaign: federation must never touch it.
        curated = _actor("curatedArtist");
        Work[] memory works = _one(_work(curated, collectionId));
        bytes32 root = _publish(works);
        curatedCollector = makeAddr("curatedCollector");
        _sell(root, works, 0, curatedCollector, 1 ether);
        streamMinted = stream.totalMinted();
        curatedIdentity = keccak256(abi.encode(artists.authorityOf(uint160(curated))));
        feeStart = networkFee.balance;
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.start.selector;
        selectors[1] = handler.bid.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.refuse.selector;
        selectors[4] = handler.toggleFault.selector;
        selectors[5] = handler.toggleListing.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_TheAuctionHoldsExactlyCreditsAndLiveBids() public view {
        uint256 owed;
        for (uint256 i; i < handler.biddersCount(); ++i) {
            owed += auction.claimable(handler.bidders(i), CURRENCY_ETH);
        }
        for (uint256 i; i < handler.salesCount(); ++i) {
            IEnglishAuction.Auction memory a = auction.auction(handler.sales(i));
            if (a.state != IEnglishAuction.AuctionState.SETTLED && a.bidder != address(0)) {
                owed += a.bid;
            }
        }
        assertEq(address(auction).balance, owed);
    }

    function invariant_TheNetworkIsPaidItsShareExactlyOnSoldSales() public view {
        assertEq(networkFee.balance - feeStart, handler.expectedFees());
    }

    function invariant_ABuyerHoldsAFederatedWorkOnlyIfItPaid() public view {
        for (uint256 i; i < handler.salesCount(); ++i) {
            IEnglishAuction.Auction memory a = auction.auction(handler.sales(i));
            FederatedStream token = FederatedStream(a.token);
            (,, uint8 state) = token.tokenInfo(a.tokenId);
            if (state == 0) continue;
            try token.ownerOf(a.tokenId) returns (address holder) {
                bool custody = holder == address(auction) || holder == address(token);
                (PrimaryOutcome outcome,,) = token.primarySale(a.tokenId);
                assertEq(!custody, outcome == PrimaryOutcome.SOLD, "held by a person iff sold");
                // No action of this campaign moves a sold work on, so its holder is the bidder
                // who paid for it.
                if (!custody) assertEq(holder, a.bidder, "held by the paying bidder");
            } catch { }
        }
    }

    function invariant_FederationNeverTouchesCanonicalState() public view {
        assertEq(stream.totalMinted(), streamMinted);
        assertEq(stream.ownerOf(1), curatedCollector);
        assertEq(keccak256(abi.encode(artists.authorityOf(uint160(curated)))), curatedIdentity);
    }

    /// @dev Every sale ends: refused or settled, the auction then owes only credits.
    function afterInvariant() public {
        for (uint256 i; i < handler.salesCount(); ++i) {
            handler.refuse(i);
        }
        invariant_TheAuctionHoldsExactlyCreditsAndLiveBids();
        invariant_TheNetworkIsPaidItsShareExactlyOnSoldSales();
    }
}
