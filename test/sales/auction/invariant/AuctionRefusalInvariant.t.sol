// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEnglishAuctionRefusal } from "src/interfaces/IEnglishAuctionRefusal.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { Payment, PaymentMethod, PrimarySettlement } from "src/interfaces/types/SaleTypes.sol";
import { IEnglishAuctionFull } from "test/helpers/IEnglishAuctionFull.sol";
import { HostileMintTarget } from "../../../mocks/sales/HostileMintTarget.sol";
import { MockFederationRegistry } from "../../../mocks/sales/SaleMocks.sol";
import { AuctionBase } from "../AuctionBase.sol";

/// @dev Drives sales of hostile tokens, listed and federated, whose settlement calls fail, burn
///      gas, answer malformed or hostile values, re-enter, and change behaviour, while bidders bid,
///      time passes and anyone calls `settle`, `settleOrRefund`, `claim` and `claimDelivery`.
///      Every call into a token is made with bounded gas, so a gas burner ends.
contract AuctionRefusalHandler is Test {
    uint256 internal constant MAX_SALES = 8;
    uint256 internal constant KEEPER_GAS = 10_000_000;

    IEnglishAuctionFull public immutable auction;
    address public immutable artist;
    address public immutable artistVault = makeAddr("artistVault");
    HostileMintTarget[] public tokens;
    bool[] public federated;
    address[] public actors;
    uint256[] public sales;
    mapping(uint256 saleId => uint256) public tokenOf;
    uint256 public ghostDeposited;
    uint256 public ghostClaimed;

    constructor(
        IEnglishAuctionFull auction_,
        HostileMintTarget[] memory tokens_,
        bool[] memory fed,
        address artist_
    ) {
        auction = auction_;
        artist = artist_;
        for (uint256 i; i < tokens_.length; ++i) {
            tokens.push(tokens_[i]);
            federated.push(fed[i]);
        }
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
    }

    function salesCount() external view returns (uint256) {
        return sales.length;
    }

    function actorsCount() external view returns (uint256) {
        return actors.length;
    }

    function start(uint256 seed) external {
        if (sales.length >= MAX_SALES) return;
        uint256 t = seed % tokens.length;
        try auction.start{ gas: KEEPER_GAS }(address(tokens[t]), "") returns (uint256 saleId) {
            sales.push(saleId);
            tokenOf[saleId] = t;
        } catch { }
    }

    function bid(uint256 seed, uint256 amountSeed) external {
        if (sales.length == 0) return;
        uint256 saleId = sales[seed % sales.length];
        if (auction.auction(saleId).state != IEnglishAuction.AuctionState.ACTIVE) return;
        address bidder = actors[(seed >> 8) % actors.length];
        uint256 amount = auction.minimumBid(saleId) + amountSeed % 1 ether;
        vm.deal(bidder, amount);
        vm.prank(bidder);
        try auction.bid{ value: amount }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, bidder, amount, 0, 0, "")
        ) {
            ghostDeposited += amount;
        } catch { }
    }

    function warp(uint256 seed) external {
        vm.warp(block.timestamp + 1 hours + seed % 10 days);
    }

    /// @dev Any fault on any call of any token, within a gas band and a time window, for one
    ///      buyer, or after some calls went through; a re-entry targets another sale.
    function setFault(uint256 seed) external {
        HostileMintTarget h = tokens[seed % tokens.length];
        HostileMintTarget.Fault fault = HostileMintTarget.Fault((seed >> 16) % 6);
        h.setRule(HostileMintTarget.Call((seed >> 8) % 5), _rule(seed, fault));
        if (fault == HostileMintTarget.Fault.REENTER && sales.length != 0) {
            uint256 other = sales[(seed >> 200) % sales.length];
            bytes memory data = (seed >> 208) % 2 == 0
                ? abi.encodeCall(IEnglishAuctionRefusal.settleOrRefund, (other))
                : abi.encodeCall(IEnglishAuction.settle, (other));
            h.setReentry(address(auction), data, (seed >> 216) % 2 == 0);
        }
    }

    function _rule(uint256 seed, HostileMintTarget.Fault fault)
        internal
        view
        returns (HostileMintTarget.Rule memory r)
    {
        r.fault = fault;
        if ((seed >> 24) % 3 == 0) r.minGas = uint64(2_000_000 + (seed >> 32) % 6_000_000);
        if ((seed >> 64) % 3 == 0) r.maxGas = uint64(2_000_000 + (seed >> 72) % 6_000_000);
        if ((seed >> 104) % 2 == 1) r.until = uint64(block.timestamp + (seed >> 112) % 20 days);
        if ((seed >> 144) % 4 == 0) r.onlyBuyer = actors[(seed >> 152) % actors.length];
        r.skip = uint32((seed >> 160) % 3);
    }

    function clearFaults(uint256 seed) external {
        HostileMintTarget h = tokens[seed % tokens.length];
        for (uint256 c; c < 5; ++c) {
            h.clear(HostileMintTarget.Call(c));
        }
    }

    function settle(uint256 seed) external {
        if (sales.length == 0) return;
        try auction.settle{ gas: KEEPER_GAS }(sales[seed % sales.length]) { } catch { }
    }

    function settleOrRefund(uint256 seed) external {
        if (sales.length == 0) return;
        try auction.settleOrRefund{ gas: KEEPER_GAS }(sales[seed % sales.length]) { } catch { }
    }

    function claim(uint256 seed) external {
        address actor = actors[seed % actors.length];
        uint256 owed = auction.claimable(actor, address(0));
        if (owed == 0) return;
        vm.prank(actor);
        auction.claim(address(0), actor);
        ghostClaimed += owed;
    }

    function claimDelivery(uint256 seed) external {
        if (sales.length == 0) return;
        vm.prank(artist);
        try auction.claimDelivery{ gas: KEEPER_GAS }(sales[seed % sales.length], artistVault) { }
            catch { }
    }
}

/// @notice AUC-38 to AUC-41 under adversarial sequences: the auction's ETH always equals its
///         credits plus its live bids; the network is paid its fee on every sold sale and on no
///         other; and from any reachable state every sale reaches a terminal state through a
///         permissionless `settleOrRefund`, with the bid paid out or credited back in full.
contract AuctionRefusalInvariantTest is AuctionBase {
    AuctionRefusalHandler internal handler;
    MockFederationRegistry internal registry;
    HostileMintTarget[] internal hostiles;

    function setUp() public override {
        super.setUp();
        registry = new MockFederationRegistry();
        vm.prank(successor);
        auction.setFederationRegistry(address(0), address(registry));
        bool[] memory fed = new bool[](3);
        fed[2] = true;
        HostileMintTarget[] memory list = new HostileMintTarget[](3);
        for (uint256 i; i < 3; ++i) {
            HostileMintTarget h = new HostileMintTarget();
            h.setAdmittedMinter(address(auction), true);
            h.setTerms(_terms(ETH));
            h.setLiar(makeAddr("liar"));
            // A hostile REPORT names a seller the payout refuses, on the listed fee terms.
            h.setReported(PrimarySettlement(address(0), network, FEE, address(0)));
            if (fed[i]) {
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
            } else {
                vm.prank(successor);
                auction.setTarget(address(h), true);
            }
            list[i] = h;
            hostiles.push(h);
        }
        handler = new AuctionRefusalHandler(auction, list, fed, artist);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = AuctionRefusalHandler.start.selector;
        selectors[1] = AuctionRefusalHandler.bid.selector;
        selectors[2] = AuctionRefusalHandler.warp.selector;
        selectors[3] = AuctionRefusalHandler.setFault.selector;
        selectors[4] = AuctionRefusalHandler.clearFaults.selector;
        selectors[5] = AuctionRefusalHandler.settle.selector;
        selectors[6] = AuctionRefusalHandler.settleOrRefund.selector;
        selectors[7] = AuctionRefusalHandler.claim.selector;
        selectors[8] = AuctionRefusalHandler.claimDelivery.selector;
        selectors[9] = AuctionRefusalHandler.bid.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// @dev The auction holds exactly its credits plus the live high bids.
    function invariant_HeldEqualsCreditsPlusLiveBids() public view {
        assertEq(address(auction).balance, _credits() + _liveBids(), "held");
    }

    /// @dev Every bid deposited is held, claimed, or paid out to a seller or the network.
    function invariant_ValueIsConserved() public view {
        assertEq(
            handler.ghostDeposited(),
            address(auction).balance + handler.ghostClaimed() + _paidOut(),
            "conserved"
        );
    }

    /// @dev The network receives its fee on every sold sale, from the terms the auction or the
    ///      registry locked, and nothing on a sale that did not complete.
    function invariant_TheNetworkIsPaidOnEverySoldSale() public view {
        (uint256 listedFees, uint256 federatedFees) = _expectedFees();
        assertEq(network.balance + escrow.owed(network, ETH), listedFees, "listed fees");
        assertEq(
            federatedNetwork.balance + escrow.owed(federatedNetwork, ETH),
            federatedFees,
            "federated fees"
        );
    }

    /// @dev From the state the run reached, every unsettled sale reaches a terminal state by a
    ///      permissionless call once its refusal delay has passed, whatever its token does, and
    ///      the value stays conserved and the network's fees exact afterwards.
    function afterInvariant() public {
        uint256 latest = block.timestamp;
        for (uint256 i; i < handler.salesCount(); ++i) {
            uint256 at = auction.refusableAt(handler.sales(i));
            if (at > latest) latest = at;
        }
        vm.warp(latest);
        for (uint256 i; i < handler.salesCount(); ++i) {
            uint256 saleId = handler.sales(i);
            IEnglishAuction.AuctionState state = auction.auction(saleId).state;
            if (state == IEnglishAuction.AuctionState.SETTLED) continue;
            auction.settleOrRefund{ gas: 15_000_000 }(saleId);
            assertEq(
                uint8(auction.auction(saleId).state),
                uint8(IEnglishAuction.AuctionState.SETTLED),
                "terminal"
            );
        }
        _tally();
        invariant_HeldEqualsCreditsPlusLiveBids();
        invariant_ValueIsConserved();
        invariant_TheNetworkIsPaidOnEverySoldSale();
        assertEq(_liveBids(), 0, "no bid is left standing");
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Logs how the run's sales ended (`-vv`), to show the campaign reaches refusals, sales
    ///      and unsold ends.
    function _tally() internal view {
        uint256[3] memory n;
        for (uint256 i; i < handler.salesCount(); ++i) {
            uint256 saleId = handler.sales(i);
            HostileMintTarget h = hostiles[handler.tokenOf(saleId)];
            if (!h.primarySettled(auction.auction(saleId).tokenId)) ++n[0];
            else if (auction.auction(saleId).bidder != address(0)) ++n[1];
            else ++n[2];
        }
        console2.log("refused, sold, unsold:", n[0], n[1], n[2]);
    }

    function _credits() internal view returns (uint256 owed) {
        for (uint256 i; i < handler.actorsCount(); ++i) {
            owed += auction.claimable(handler.actors(i), ETH);
        }
    }

    function _liveBids() internal view returns (uint256 live) {
        for (uint256 i; i < handler.salesCount(); ++i) {
            IEnglishAuction.Auction memory a = auction.auction(handler.sales(i));
            if (a.state != IEnglishAuction.AuctionState.SETTLED && a.bidder != address(0)) {
                live += a.bid;
            }
        }
    }

    function _paidOut() internal view returns (uint256) {
        return seller.balance + network.balance + federatedNetwork.balance
            + escrow.owed(seller, ETH) + escrow.owed(network, ETH)
            + escrow.owed(federatedNetwork, ETH);
    }

    /// @dev A SETTLED sale that kept its bidder was sold at its bid (a refused or rescued close,
    ///      or an unsold end, clears the bidder).
    function _expectedFees() internal view returns (uint256 listed, uint256 fed) {
        for (uint256 i; i < handler.salesCount(); ++i) {
            uint256 saleId = handler.sales(i);
            IEnglishAuction.Auction memory a = auction.auction(saleId);
            if (a.state != IEnglishAuction.AuctionState.SETTLED || a.bidder == address(0)) {
                continue;
            }
            if (handler.federated(handler.tokenOf(saleId))) {
                fed += uint256(a.bid) * 10_000 / 100_000;
            } else {
                listed += uint256(a.bid) * FEE / 100_000;
            }
        }
    }
}
