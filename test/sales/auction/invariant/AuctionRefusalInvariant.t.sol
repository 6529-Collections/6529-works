// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEnglishAuctionRefusal } from "src/interfaces/IEnglishAuctionRefusal.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { Statement } from "src/interfaces/IStatementLog.sol";
import { HashRef, HASH_SHA256 } from "src/interfaces/types/HashRef.sol";
import { PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { Payment, PaymentMethod, PrimarySettlement } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { IEnglishAuctionFull } from "test/helpers/IEnglishAuctionFull.sol";
import { MockMintTarget } from "../../../mocks/sales/AuctionMocks.sol";
import { HostileMintTarget } from "../../../mocks/sales/HostileMintTarget.sol";
import {
    MockEconomicsResolver,
    MockFederationRegistry,
    MockPermit2,
    PermitToken
} from "../../../mocks/sales/SaleMocks.sol";
import { AuctionBase } from "../AuctionBase.sol";

/// @dev Drives sales of two hostile federated tokens, whose settlement calls fail, burn gas,
///      answer malformed or hostile values, re-enter another sale, or steer by gas, time, buyer
///      or call count, and of 6529 Stream's cooperating stand-in (listed, never refusable),
///      while bidders bid (in ETH, or in an ERC-20 directly or through Permit2), time passes,
///      governance changes the refusal parameters, the federated fee recipient and the registry,
///      the guardian freezes the ERC-20 and pauses or cancels sales, and anyone calls `settle`,
///      `settleOrRefund`, `claim` and `claimDelivery`. Every call into a token gets bounded gas.
contract AuctionRefusalHandler is Test {
    uint256 internal constant MAX_SALES = 8;
    uint256 internal constant KEEPER_GAS = 10_000_000;

    struct Setup {
        IEnglishAuctionFull auction;
        MockMintTarget stream;
        HostileMintTarget[] hostiles;
        MockFederationRegistry registry;
        MockEconomicsResolver resolver;
        AssetAllowlist allowlist;
        StatementLog statements;
        MockPermit2 permit2;
        PermitToken usd;
        address currency;
        address admin;
        address setter;
        address guardian;
        address platform;
        address artist;
        address feeRecipientA;
        address feeRecipientB;
    }

    IEnglishAuctionFull public immutable auction;
    MockMintTarget public immutable stream;
    MockFederationRegistry public immutable registry;
    MockEconomicsResolver public immutable resolver;
    AssetAllowlist public immutable allowlist;
    StatementLog public immutable statements;
    MockPermit2 public immutable permit2;
    PermitToken public immutable usd;
    address public immutable currency;
    address public immutable admin;
    address public immutable setter;
    address public immutable guardian;
    address public immutable platform;
    address public immutable artist;
    address public immutable feeRecipientA;
    address public immutable feeRecipientB;
    address public immutable artistVault = makeAddr("artistVault");
    HostileMintTarget[] public hostiles;
    address[] public actors;
    uint256[] internal _keys;
    uint256[] public sales;
    /// @dev Index into `hostiles`, or `hostiles.length` for the stream stand-in.
    mapping(uint256 saleId => uint256) public tokenOf;
    uint256 public ghostDeposited;
    uint256 public ghostClaimed;
    uint256 internal _nonce;

    constructor(Setup memory s) {
        (auction, stream, registry, resolver) = (s.auction, s.stream, s.registry, s.resolver);
        (allowlist, statements, permit2, usd) = (s.allowlist, s.statements, s.permit2, s.usd);
        (currency, admin, setter, guardian) = (s.currency, s.admin, s.setter, s.guardian);
        (platform, artist, feeRecipientA, feeRecipientB) =
        (s.platform, s.artist, s.feeRecipientA, s.feeRecipientB);
        for (uint256 i; i < s.hostiles.length; ++i) {
            hostiles.push(s.hostiles[i]);
        }
        for (uint256 i = 1; i <= 3; ++i) {
            uint256 pk = 0xA11CE0 + i;
            _keys.push(pk);
            actors.push(vm.addr(pk));
        }
    }

    function salesCount() external view returns (uint256) {
        return sales.length;
    }

    function actorsCount() external view returns (uint256) {
        return actors.length;
    }

    function isStreamSale(uint256 saleId) public view returns (bool) {
        return tokenOf[saleId] == hostiles.length;
    }

    /// @dev Where the token's own ledger has the work (not for a cancelled, burned work).
    function holderOf(uint256 saleId) public view returns (address) {
        uint256 tokenId = auction.auction(saleId).tokenId;
        if (isStreamSale(saleId)) return stream.ownerOf(tokenId);
        return hostiles[tokenOf[saleId]].holderOf(tokenId);
    }

    function start(uint256 seed) external {
        if (sales.length >= MAX_SALES) return;
        uint256 t = seed % (hostiles.length + 1);
        address token = t == hostiles.length ? address(stream) : address(hostiles[t]);
        try auction.start{ gas: KEEPER_GAS }(token, "") returns (uint256 saleId) {
            sales.push(saleId);
            tokenOf[saleId] = t;
        } catch { }
    }

    function bid(uint256 seed, uint256 amountSeed) external {
        if (sales.length == 0) return;
        uint256 saleId = sales[seed % sales.length];
        if (auction.auction(saleId).state != IEnglishAuction.AuctionState.ACTIVE) return;
        uint256 who = (seed >> 8) % actors.length;
        address bidder = actors[who];
        uint256 amount;
        try auction.minimumBid(saleId) returns (uint256 m) {
            amount = m + amountSeed % (currency == address(0) ? 1 ether : 10e18);
        } catch {
            return;
        }
        if (currency == address(0)) {
            vm.deal(bidder, amount);
            vm.prank(bidder);
            try auction.bid{ value: amount }(
                saleId, address(0), Payment(PaymentMethod.DIRECT, bidder, amount, 0, 0, "")
            ) {
                ghostDeposited += amount;
            } catch { }
            return;
        }
        usd.mint(bidder, amount);
        Payment memory p;
        if ((seed >> 16) % 2 == 0) {
            vm.prank(bidder);
            usd.approve(address(auction), amount);
            p = Payment(PaymentMethod.DIRECT, bidder, amount, 0, 0, "");
            vm.prank(bidder);
        } else {
            vm.prank(bidder);
            usd.approve(address(permit2), type(uint256).max);
            p = _permit2(who, saleId, amount);
        }
        try auction.bid(saleId, address(0), p) {
            ghostDeposited += amount;
        } catch { }
    }

    function _permit2(uint256 who, uint256 saleId, uint256 amount)
        internal
        returns (Payment memory)
    {
        ISignatureTransfer.PermitTransferFrom memory permit =
            ISignatureTransfer.PermitTransferFrom(
                ISignatureTransfer.TokenPermissions(address(usd), amount),
                ++_nonce,
                block.timestamp + 1
            );
        bytes32 witness = keccak256(
            abi.encode(Typehashes.BID_WITNESS, saleId, actors[who], amount, permit.deadline)
        );
        bytes32 digest =
            permit2.witnessDigest(address(auction), permit, witness, Typehashes.BID_WITNESS_TYPE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_keys[who], digest);
        return Payment(
            PaymentMethod.PERMIT2,
            actors[who],
            amount,
            permit.deadline,
            _nonce,
            abi.encodePacked(r, s, v)
        );
    }

    function warp(uint256 seed) external {
        vm.warp(block.timestamp + 1 hours + seed % 10 days);
    }

    /// @dev Any fault on any call of any hostile token, within a gas band and a time window, for
    ///      one buyer, or after some calls went through; a re-entry targets another sale.
    function setFault(uint256 seed) external {
        HostileMintTarget h = hostiles[seed % hostiles.length];
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
        HostileMintTarget h = hostiles[seed % hostiles.length];
        for (uint256 c; c < 5; ++c) {
            h.clear(HostileMintTarget.Call(c));
        }
    }

    /// @dev Governance: a refusal-delay change and a refusal-gas raise (running federated sales
    ///      keep their delay), or the federated fee recipient switched (running sales keep theirs).
    function govern(uint256 seed) external {
        if (seed % 2 == 0) {
            IEnglishAuction.AuctionConfig memory c = auction.config();
            IEnglishAuction.AuctionConfig memory n = auction.config();
            n.refusalDelay = uint32(1 days + (seed >> 8) % 29 days);
            uint256 raised = uint256(c.refusalGas) + (seed >> 40) % (uint256(c.refusalGas) + 1);
            if (raised <= 15_000_000) n.refusalGas = uint32(raised);
            vm.prank(setter);
            auction.setConfig(c, n);
        } else {
            resolver.set(
                PRODUCT_FEDERATED, (seed >> 8) % 2 == 0 ? feeRecipientA : feeRecipientB, 10_000
            );
        }
    }

    /// @dev The registry delists or re-lists a hostile token.
    function toggleListing(uint256 seed) external {
        HostileMintTarget h = hostiles[seed % hostiles.length];
        bool active = registry.isActive(address(h));
        registry.setStatus(
            address(h),
            active ? IFederationRegistry.Status.DELISTED : IFederationRegistry.Status.ACTIVE,
            bytes32(0)
        );
    }

    /// @dev The guardian deprecates the ERC-20; governance re-admits it once allowed.
    function toggleCurrency(uint256 seed) external {
        // Rarely, so most runs also see sales that complete.
        if (currency == address(0) || seed % 4 != 0) return;
        vm.startPrank(admin);
        if (allowlist.isActive(currency)) {
            allowlist.deprecateAsset(currency);
        } else {
            (,, uint64 revision) = allowlist.assetConfig(currency);
            try allowlist.admitAsset(currency, revision, 1e18) { } catch { }
        }
        vm.stopPrank();
    }

    /// @dev A dispute pause on any live sale; a 6529 Stream sale's may end in a cancel.
    function dispute(uint256 seed) external {
        if (sales.length == 0) return;
        uint256 saleId = sales[seed % sales.length];
        vm.prank(guardian);
        try auction.pause(saleId, keccak256("dispute")) { }
        catch {
            return;
        }
        if (!isStreamSale(saleId) || (seed >> 8) % 2 == 0) return;
        vm.warp(block.timestamp + 2 days);
        Statement memory st = Statement({
            token: address(stream),
            id: auction.auction(saleId).tokenId,
            kind: StatementKinds.DISPUTE_OUTCOME,
            schema: keccak256("dispute-outcome/v1"),
            content: HashRef(HASH_SHA256, keccak256(abi.encode(seed))),
            uri: "ipfs://outcome",
            fileId: bytes32(0),
            supersedes: bytes32(0)
        });
        vm.prank(platform);
        try statements.appendPlatform(st) returns (bytes32 entry) {
            vm.prank(setter);
            try auction.cancel(saleId, entry) { } catch { }
        } catch { }
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
        uint256 owed = auction.claimable(actor, currency);
        if (owed == 0) return;
        vm.prank(actor);
        auction.claim(currency, actor);
        ghostClaimed += owed;
    }

    function claimDelivery(uint256 seed) external {
        if (sales.length == 0) return;
        vm.prank(artist);
        try auction.claimDelivery{ gas: KEEPER_GAS }(sales[seed % sales.length], artistVault) { }
            catch { }
    }
}

/// @notice AUC-38 to AUC-41 under adversarial sequences, in ETH and in an ERC-20: the auction
///         holds exactly its credits plus its live bids; every deposit is held, claimed or paid
///         out; the network is paid its fee on every sold sale and on no other; a bidder holds a
///         work only after paying for it; and from any reachable state every sale reaches a
///         terminal state by a permissionless call: a federated one through `settleOrRefund`
///         whatever its token does, 6529 Stream's stand-in through `settle`.
abstract contract AuctionRefusalFixture is AuctionBase {
    AuctionRefusalHandler internal handler;
    MockFederationRegistry internal registry;
    address internal federatedNetwork2 = makeAddr("federatedNetwork2");
    address internal cur;

    function _currency() internal view virtual returns (address);

    function setUp() public override {
        super.setUp();
        cur = _currency();
        stream.setTerms(_terms(cur));
        registry = new MockFederationRegistry();
        vm.prank(successor);
        auction.setFederationRegistry(address(0), address(registry));
        HostileMintTarget[] memory list = new HostileMintTarget[](2);
        for (uint256 i; i < 2; ++i) {
            list[i] = _hostile();
        }
        handler = new AuctionRefusalHandler(
            AuctionRefusalHandler.Setup(
                auction,
                stream,
                list,
                registry,
                resolver,
                allowlist,
                statements,
                permit2,
                usd,
                cur,
                address(this),
                setter,
                guardian,
                platform,
                artist,
                federatedNetwork,
                federatedNetwork2
            )
        );
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](16);
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
        selectors[10] = AuctionRefusalHandler.govern.selector;
        selectors[11] = AuctionRefusalHandler.toggleListing.selector;
        selectors[12] = AuctionRefusalHandler.toggleCurrency.selector;
        selectors[13] = AuctionRefusalHandler.dispute.selector;
        selectors[14] = AuctionRefusalHandler.start.selector;
        selectors[15] = AuctionRefusalHandler.bid.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function _hostile() internal returns (HostileMintTarget h) {
        h = new HostileMintTarget();
        h.setAdmittedMinter(address(auction), true);
        h.setTerms(_terms(cur));
        h.setLiar(makeAddr("liar"));
        // A hostile REPORT names a seller the payout refuses.
        h.setReported(PrimarySettlement(address(0), network, FEE, address(0)));
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

    /// @dev The auction holds exactly the credits plus the live high bids.
    function invariant_HeldEqualsCreditsPlusLiveBids() public view {
        assertEq(_bal(address(auction)), _credits() + _liveBids(), "held");
    }

    /// @dev Every bid deposited is held, claimed, or paid out to a seller or the network
    ///      (directly, through the escrow, or as a payout credit the auction still holds).
    function invariant_ValueIsConserved() public view {
        assertEq(
            handler.ghostDeposited() + _payeeCredits(),
            _bal(address(auction)) + handler.ghostClaimed() + _paidOut(),
            "conserved"
        );
    }

    /// @dev The network receives its fee on every sold sale, from the terms the auction locked
    ///      (for a federated sale the registry's share to the recipient locked at its start), and
    ///      nothing on a sale that did not complete.
    function invariant_TheNetworkIsPaidOnEverySoldSale() public view {
        (uint256 listedFees, uint256 fed1, uint256 fed2) = _expectedFees();
        assertEq(_received(network), listedFees, "listed fees");
        assertEq(_received(federatedNetwork), fed1, "federated fees, first recipient");
        assertEq(_received(federatedNetwork2), fed2, "federated fees, second recipient");
    }

    /// @dev A bidder holds a sale's work only if that sale was sold to it: paid, with the
    ///      network's fee counted above.
    function invariant_TheBuyerHoldsTheWorkOnlyIfItPaid() public view {
        for (uint256 i; i < handler.salesCount(); ++i) {
            uint256 saleId = handler.sales(i);
            IEnglishAuction.Auction memory a = auction.auction(saleId);
            if (a.state == IEnglishAuction.AuctionState.CANCELLED) continue;
            address holder = handler.holderOf(saleId);
            for (uint256 j; j < handler.actorsCount(); ++j) {
                if (holder != handler.actors(j)) continue;
                assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.SETTLED), "settled");
                assertEq(a.bidder, holder, "sold to the holder");
            }
        }
    }

    /// @dev From the state the run reached, every sale reaches a terminal state by a
    ///      permissionless call once its delay has passed and its currency is back or frozen out:
    ///      a federated sale through `settleOrRefund`, whatever its token does; 6529 Stream's
    ///      stand-in through `settle`. The invariants still hold afterwards.
    function afterInvariant() public {
        vm.warp(block.timestamp + 61 days);
        for (uint256 i; i < handler.salesCount(); ++i) {
            uint256 saleId = handler.sales(i);
            IEnglishAuction.AuctionState state = auction.auction(saleId).state;
            if (
                state == IEnglishAuction.AuctionState.SETTLED
                    || state == IEnglishAuction.AuctionState.CANCELLED
            ) continue;
            if (handler.isStreamSale(saleId)) {
                // A late re-admission reopens the sale once; it then ends and settles.
                auction.settle{ gas: 16_777_216 }(saleId);
                if (auction.auction(saleId).state != IEnglishAuction.AuctionState.SETTLED) {
                    vm.warp(auction.auction(saleId).endTime);
                    auction.settle{ gas: 16_777_216 }(saleId);
                }
            } else {
                auction.settleOrRefund{ gas: 16_777_216 }(saleId);
                if (auction.auction(saleId).state != IEnglishAuction.AuctionState.SETTLED) {
                    vm.warp(auction.refusableAt(saleId));
                    auction.settleOrRefund{ gas: 16_777_216 }(saleId);
                }
            }
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
        invariant_TheBuyerHoldsTheWorkOnlyIfItPaid();
        assertEq(_liveBids(), 0, "no bid is left standing");
    }

    // ------------------------------------------------------------------ helpers

    function _bal(address account) internal view returns (uint256) {
        return cur == ETH ? account.balance : usd.balanceOf(account);
    }

    function _received(address payee) internal view returns (uint256) {
        return _bal(payee) + escrow.owed(payee, cur) + auction.claimable(payee, cur);
    }

    /// @dev Logs how the run's sales ended (`-vv`), to show the campaign reaches refusals, sales
    ///      and cancels.
    function _tally() internal view {
        uint256[3] memory n;
        for (uint256 i; i < handler.salesCount(); ++i) {
            IEnglishAuction.Auction memory a = auction.auction(handler.sales(i));
            if (a.state != IEnglishAuction.AuctionState.SETTLED) ++n[2];
            else if (a.bidder != address(0)) ++n[1];
            else ++n[0];
        }
        console2.log("closed without a sale, sold, cancelled:", n[0], n[1], n[2]);
    }

    function _credits() internal view returns (uint256 owed) {
        for (uint256 i; i < handler.actorsCount(); ++i) {
            owed += auction.claimable(handler.actors(i), cur);
        }
        owed += _payeeCredits();
    }

    /// @dev ERC-20 payouts that failed in their frame are credited to the payee in the auction.
    function _payeeCredits() internal view returns (uint256) {
        return auction.claimable(seller, cur) + auction.claimable(network, cur)
            + auction.claimable(federatedNetwork, cur) + auction.claimable(federatedNetwork2, cur);
    }

    function _liveBids() internal view returns (uint256 live) {
        for (uint256 i; i < handler.salesCount(); ++i) {
            IEnglishAuction.Auction memory a = auction.auction(handler.sales(i));
            if (
                a.state != IEnglishAuction.AuctionState.SETTLED
                    && a.state != IEnglishAuction.AuctionState.CANCELLED && a.bidder != address(0)
            ) live += a.bid;
        }
    }

    function _paidOut() internal view returns (uint256) {
        return _received(seller) + _received(network) + _received(federatedNetwork)
            + _received(federatedNetwork2);
    }

    /// @dev A SETTLED sale that kept its bidder was sold at its bid (a refused or rescued close,
    ///      or an unsold end, clears the bidder). A federated sale's fee goes to the recipient
    ///      locked in its terms record (`_federatedTerms`, slot 11, low 160 bits).
    function _expectedFees() internal view returns (uint256 listed, uint256 fed1, uint256 fed2) {
        for (uint256 i; i < handler.salesCount(); ++i) {
            uint256 saleId = handler.sales(i);
            IEnglishAuction.Auction memory a = auction.auction(saleId);
            if (a.state != IEnglishAuction.AuctionState.SETTLED || a.bidder == address(0)) {
                continue;
            }
            if (handler.isStreamSale(saleId)) {
                listed += uint256(a.bid) * FEE / 100_000;
                continue;
            }
            uint256 fee = uint256(a.bid) * 10_000 / 100_000;
            if (_lockedRecipient(saleId) == federatedNetwork) fed1 += fee;
            else fed2 += fee;
        }
    }

    function _lockedRecipient(uint256 saleId) internal view returns (address) {
        uint256 w0 = uint256(vm.load(address(auction), keccak256(abi.encode(saleId, uint256(8)))));
        uint256 termsId = uint16(w0 >> 224);
        // `_federatedTerms` is slot 10 since opening bids moved to the asset allowlist (ADR 0007).
        bytes32 slot = keccak256(abi.encode(termsId, uint256(10)));
        return address(uint160(uint256(vm.load(address(auction), slot))));
    }
}

contract AuctionRefusalInvariantEth is AuctionRefusalFixture {
    function _currency() internal pure override returns (address) {
        return ETH;
    }
}

contract AuctionRefusalInvariantErc20 is AuctionRefusalFixture {
    function _currency() internal view override returns (address) {
        return address(usd);
    }
}
