// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { Payment, PaymentMethod, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { FeeOnTransferToken } from "../../mocks/EconomicsMocks.sol";
import {
    HostileActor,
    MockFederationRegistry,
    PermitToken
} from "../../mocks/auction/AuctionMocks.sol";
import { AuctionBase } from "./AuctionBase.sol";

/// @dev A minimal federated template: every `IMintTarget` function, with the settlement hook as a
///      no-op (as 6529 Editions implements it).
contract PlainMintTarget is ERC721, IMintTarget {
    PrimaryTerms internal _terms;
    mapping(address => bool) public isAdmittedMinter;
    uint256 public nextId;

    constructor() ERC721("Federated", "FED") { }

    function setAdmittedMinter(address adapter, bool admitted) external {
        isAdmittedMinter[adapter] = admitted;
        emit AdmittedMinterSet(adapter, admitted);
    }

    function setTerms(PrimaryTerms calldata terms) external {
        _terms = terms;
    }

    function mint(address to, uint256, uint256, bytes calldata)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        require(isAdmittedMinter[msg.sender], "minter");
        tokenId = ++nextId;
        terms = _terms;
        _mint(to, tokenId);
    }

    function primaryTerms(uint256, bytes calldata) external view returns (PrimaryTerms memory t) {
        t = _terms;
        t.currency = address(0);
    }

    function burn(uint256 id, uint256) external {
        require(isAdmittedMinter[msg.sender], "minter");
        _burn(id);
    }

    function markPrimarySettled(uint256) external { }
}

/// @dev Mints a chosen token ID.
contract HugeIdTarget is ERC721, IMintTarget {
    mapping(address => bool) public isAdmittedMinter;
    uint256 public id;

    constructor() ERC721("Huge", "HUGE") { }

    function setAdmittedMinter(address adapter, bool admitted) external {
        isAdmittedMinter[adapter] = admitted;
    }

    function setId(uint256 id_) external {
        id = id_;
    }

    function mint(address to, uint256, uint256, bytes calldata)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        tokenId = id;
        terms = PrimaryTerms(
            SaleKind.ENGLISH_AUCTION,
            address(0),
            0,
            "",
            address(0xB),
            address(0xC),
            25_000,
            address(0xA)
        );
        _mint(to, tokenId);
    }

    function primaryTerms(uint256, bytes calldata) external pure returns (PrimaryTerms memory t) {
        t.saleKind = SaleKind.ENGLISH_AUCTION;
    }

    function burn(uint256, uint256) external { }

    function markPrimarySettled(uint256) external { }
}

/// @dev The PR #21 review's proofs of concept and mutant killers, ported, and inverted where the
///      fix changes the outcome.
contract EnglishAuctionReviewTest is AuctionBase {
    function _state(uint256 saleId) internal view returns (IEnglishAuction.AuctionState) {
        return auction.auction(saleId).state;
    }

    /// @dev M-1 (PoC F1, inverted): the settlement hook is part of `IMintTarget`, so every served
    ///      token has it; a template that makes it a no-op still settles and pays.
    function test_M1_EveryMintTargetSettles() public {
        PlainMintTarget fed = new PlainMintTarget();
        fed.setAdmittedMinter(address(auction), true);
        fed.setTerms(
            PrimaryTerms(SaleKind.ENGLISH_AUCTION, ETH, 0, "", seller, network, FEE, artist)
        );
        MockFederationRegistry registry = new MockFederationRegistry();
        registry.register(
            address(fed),
            IFederationRegistry.Entry(
                IFederationRegistry.Form.ERC721,
                address(0),
                1,
                1,
                address(fed).codehash,
                25_000,
                IFederationRegistry.Status.ACTIVE
            )
        );
        vm.prank(successor);
        auction.setFederationRegistry(address(0), address(registry));

        uint256 saleId = auction.start(address(fed), "");
        _bidEth(saleId, alice, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        assertEq(fed.ownerOf(1), alice);
        assertEq(seller.balance, 0.75 ether);
        assertEq(network.balance, 0.25 ether);
    }

    /// @dev L-6: a federated token whose code does not match its registry entry, or a registry
    ///      whose code changed after it was pinned, serves no sale.
    function test_L6_FederationCodeHashesArePinned() public {
        PlainMintTarget fed = new PlainMintTarget();
        fed.setAdmittedMinter(address(auction), true);
        fed.setTerms(
            PrimaryTerms(SaleKind.ENGLISH_AUCTION, ETH, 0, "", seller, network, FEE, artist)
        );
        MockFederationRegistry registry = new MockFederationRegistry();
        IFederationRegistry.Entry memory e = IFederationRegistry.Entry(
            IFederationRegistry.Form.ERC721,
            address(0),
            1,
            1,
            keccak256("another template"),
            25_000,
            IFederationRegistry.Status.ACTIVE
        );
        registry.register(address(fed), e);
        vm.prank(successor);
        auction.setFederationRegistry(address(0), address(registry));
        assertEq(auction.federationRegistryCodeHash(), address(registry).codehash);
        vm.expectRevert(
            abi.encodeWithSelector(EnglishAuction.InvalidTerms.selector, address(fed), 1)
        );
        auction.start(address(fed), "");

        e.codeHash = address(fed).codehash;
        registry.register(address(fed), e);
        assertTrue(auction.isTarget(address(fed)));
        vm.etch(address(registry), address(new MockFederationRegistryV2()).code);
        assertFalse(auction.isTarget(address(fed)), "registry code changed");
    }

    /// @dev L-1 (PoC F2, inverted): a zero fee with no fee recipient starts.
    function test_L1_ZeroFeeWorkStarts() public {
        stream.setTerms(
            PrimaryTerms(SaleKind.ENGLISH_AUCTION, ETH, 0, "", seller, address(0), 0, artist)
        );
        uint256 saleId = auction.start(address(stream), "");
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.ACTIVE));
    }

    /// @dev L-3 (PoC F4, inverted): an adapter that lost its mint admission while the auction was
    ///      paused can still enforce an upheld dispute, because the token accepts its minting
    ///      adapter's burn.
    function test_L3_DeadmittedAdapterCanStillCancel() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _pause(saleId);
        bytes32 outcome = _recordOutcome(1);
        stream.setAdmittedMinter(address(auction), false);
        vm.prank(setter);
        auction.cancel(saleId, outcome);
        assertFalse(stream.exists(1), "burned");
        assertEq(auction.claimable(alice, ETH), 1 ether);
    }

    /// @dev Boundaries: a bid at exactly the end reverts; a bid one second before extends to
    ///      exactly now + window; a bid at end - window does not extend.
    function test_EdgeTiming() public {
        uint256 saleId = _start();
        uint256 end = auction.auction(saleId).endTime;
        vm.warp(end - WINDOW);
        _bidEth(saleId, alice, 1 ether);
        assertEq(auction.auction(saleId).endTime, end, "no extension at exactly the window");
        vm.warp(end - 1);
        _bidEth(saleId, bob, 2 ether);
        assertEq(auction.auction(saleId).endTime, end - 1 + WINDOW);
        vm.warp(end - 1 + WINDOW);
        vm.deal(carol, 3 ether);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ENDED
            )
        );
        auction.bid{ value: 3 ether }(saleId, address(0), _direct(carol, 3 ether));
    }

    /// @dev Pause boundaries (inverted for the inclusive window): `cancel` at exactly
    ///      `pausedAt + 7 days` lands; the pause cannot be reused on another sale.
    function test_PauseBoundaries() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        uint256 end = auction.auction(saleId).endTime;
        vm.warp(end - 100);
        _pause(saleId);
        uint256 p = block.timestamp;
        bytes32 outcome = _recordOutcome(1);
        vm.warp(p + 7 days);
        vm.prank(setter);
        auction.cancel(saleId, outcome);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.CANCELLED));
        assertEq(a.pausedTotal, 7 days);

        uint256 other = _start();
        _pause(other);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.prank(unpauser);
        auction.resume(other);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.PauseExhausted.selector, other));
        auction.pause(other, bytes32("again"));
    }

    /// @dev Token IDs at the packing limit: 2^32 - 1 is accepted and round-trips; 2^32 is refused.
    function test_TokenIdPackingLimit() public {
        HugeIdTarget t = new HugeIdTarget();
        t.setAdmittedMinter(address(auction), true);
        vm.prank(successor);
        auction.setTarget(address(t), true);
        t.setId(type(uint32).max);
        uint256 saleId = auction.start(address(t), "");
        assertEq(auction.auction(saleId).tokenId, type(uint32).max);
        assertEq(saleId, auction.saleIdOf(address(t), type(uint32).max));
        t.setId(uint256(type(uint32).max) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnglishAuction.InvalidTerms.selector, address(t), uint256(type(uint32).max) + 1
            )
        );
        auction.start(address(t), "");
    }

    /// @dev N1 (inverted): a cancelled sale reports the pause it actually had.
    function test_N1_CancelledViewReportsTheActualPause() public {
        uint256 saleId = _start();
        uint256 end = auction.auction(saleId).endTime;
        _pause(saleId);
        bytes32 outcome = _recordOutcome(1);
        vm.warp(block.timestamp + 1 days);
        vm.prank(setter);
        auction.cancel(saleId, outcome);
        vm.warp(block.timestamp + 7 days);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.CANCELLED));
        assertEq(a.pausedTotal, 1 days);
        assertEq(a.pausedAt, 0);
        assertEq(a.endTime, end);
    }

    /// @dev L-5 (PoC N2, inverted): after a recovery, the artist's current authority claims a
    ///      no-bid pending delivery; an outsider still cannot.
    function test_L5_NoBidClaimFollowsTheCurrentAuthority() public {
        HostileActor oldWallet = new HostileActor();
        oldWallet.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.REVERT);
        PrimaryTerms memory t = _terms(ETH);
        t.creator = address(oldWallet);
        stream.setTerms(t);
        uint256 saleId = _start();
        _end(saleId);
        auction.settle(saleId);
        assertEq(auction.pendingDelivery(saleId), address(oldWallet));
        address recovered = makeAddr("recoveredAuthority");
        stream.setCreatorNow(recovered);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        auction.claimDelivery(saleId, alice);
        vm.prank(recovered);
        auction.claimDelivery(saleId, recovered);
        assertEq(stream.ownerOf(1), recovered);
    }

    /// @dev Killer I5: a floor raised after the first bid does not apply to later bids.
    function test_Killer_I5_FloorLockedForLaterBids() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _setFloor(ETH, 1 ether);
        _bidEth(saleId, bob, 1.05 ether);
        assertEq(auction.auction(saleId).bidder, bob);
        assertEq(auction.auction(saleId).incrementFloor, ETH_FLOOR);
    }

    /// @dev Killer K1: a fee-on-transfer token through Permit2 is caught only by the adapter's
    ///      own balance-delta check.
    function test_Killer_K1_Permit2FeeOnTransferFailsClosed() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        allowlist.admitAsset(address(fot), 0, 1);
        stream.setTerms(_terms(address(fot)));
        uint256 saleId = auction.start(address(stream), "");
        fot.mint(alice, 100e18);
        vm.prank(alice);
        fot.approve(address(permit2), type(uint256).max);
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom(
            ISignatureTransfer.TokenPermissions(address(fot), 10e18), 0, block.timestamp + 1 hours
        );
        bytes32 witness = keccak256(
            abi.encode(Typehashes.BID_WITNESS, saleId, alice, uint256(10e18), permit.deadline)
        );
        bytes32 digest =
            permit2.digest(permit, address(auction), witness, Typehashes.BID_WITNESS_TYPE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        Payment memory p = Payment(
            PaymentMethod.PERMIT2, alice, 10e18, permit.deadline, 0, abi.encodePacked(r, s, v)
        );
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, address(fot))
        );
        vm.prank(relayer);
        auction.bid(saleId, address(0), p);
    }

    /// @dev L-4: a bid for oneself stores no recipient; a bid for another stores it, and the
    ///      next self-bid clears it.
    function test_L4_RecipientStoredOnlyWhenItDiffers() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        assertEq(auction.auction(saleId).recipient, alice, "resolved to the bidder");
        vm.deal(bob, 2 ether);
        vm.prank(bob);
        auction.bid{ value: 2 ether }(saleId, carol, _direct(bob, 2 ether));
        assertEq(auction.auction(saleId).recipient, carol);
        _bidEth(saleId, alice, 3 ether);
        assertEq(auction.auction(saleId).recipient, alice);
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), alice);
    }

    /// @dev L-4: bids above 96 bits (7.9e28 base units) are refused rather than truncated; the
    ///      largest one is accepted.
    function test_L4_BidAbove96BitsReverts() public {
        uint256 largest = _start();
        _bidEth(largest, bob, type(uint96).max);
        assertEq(auction.auction(largest).bid, type(uint96).max);
        uint256 saleId = _start();
        uint256 amount = uint256(type(uint96).max) + 1;
        vm.deal(alice, amount);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 96, amount)
        );
        auction.bid{ value: amount }(saleId, address(0), _direct(alice, amount));
    }

    // ------------------------------------------------------------------- PR #33 review

    /// @dev PR #33 review (survivor M8): a recipient already stored is replaced when the next
    ///      bid names a different third party, and the token goes to the latest one.
    function test_PR33_RecipientChangesBetweenThirdParties() public {
        uint256 saleId = _start();
        address dave = makeAddr("dave");
        _bidFor(saleId, alice, carol, 1 ether);
        _bidFor(saleId, bob, dave, 2 ether);
        assertEq(auction.auction(saleId).recipient, dave);
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(_tokenIdOf(saleId)), dave, "the winning bid's recipient");
    }

    /// @dev PR #33 review: withdrawing a bid for another clears the recipient but keeps the
    ///      dispute pause, so no bid lands while it lasts.
    function test_PR33_WithdrawForAnotherKeepsThePause() public {
        uint256 saleId = _start();
        _bidFor(saleId, alice, carol, 1 ether);
        _pause(saleId);
        vm.prank(alice);
        auction.withdrawBid(saleId);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.PAUSED), "still paused");
        assertEq(a.recipient, address(0));
        vm.deal(bob, 2 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.PAUSED
            )
        );
        auction.bid{ value: 2 ether }(saleId, address(0), _direct(bob, 2 ether));
    }

    /// @dev PR #33 review: a bid for oneself that clears the stored recipient keeps the record
    ///      that the one dispute pause was used.
    function test_PR33_ClearingTheRecipientKeepsThePauseUsed() public {
        uint256 saleId = _start();
        _pause(saleId);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.prank(unpauser);
        auction.resume(saleId);
        _bidFor(saleId, alice, carol, 1 ether);
        _bidEth(saleId, bob, 2 ether);
        assertEq(auction.auction(saleId).recipient, bob);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.PauseExhausted.selector, saleId));
        auction.pause(saleId, keccak256("second dispute"));
    }

    /// @dev PR #33 review (survivor M16): the floor locked by a withdrawn first bid still applies
    ///      to the bids after the withdrawal, even when governance changes the floor meanwhile.
    function test_PR33_FloorKeptForTheBidsAfterAWithdrawal() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _pause(saleId);
        vm.prank(alice);
        auction.withdrawBid(saleId);
        _setFloor(ETH, 0.5 ether);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.prank(unpauser);
        auction.resume(saleId);
        assertEq(auction.minimumBid(saleId), 1, "no bid: the opening bid, at least 1");
        _bidEth(saleId, bob, 1 ether);
        assertEq(auction.auction(saleId).incrementFloor, ETH_FLOOR, "kept, not relocked");
        uint256 minimum = _minimumAfter(1 ether, ETH_FLOOR);
        assertEq(auction.minimumBid(saleId), minimum);
        _bidEth(saleId, carol, minimum);
        assertEq(auction.auction(saleId).bidder, carol);
    }

    /// @dev PR #33 review (low): the opening bid's ceiling is the 96-bit bid cap, so every
    ///      opening bid can be met.
    function test_PR33_OpeningBidCappedAtTheLargestBid() public {
        PermitToken big = new PermitToken();
        allowlist.admitAsset(address(big), 0, 1e26);
        uint256 cap = type(uint96).max;
        vm.startPrank(setter);
        vm.expectRevert(
            abi.encodeWithSelector(EnglishAuction.OpeningBidAboveCeiling.selector, cap + 1, cap)
        );
        auction.setOpeningBid(address(big), 0, cap + 1);
        auction.setOpeningBid(address(big), 0, cap);
        vm.stopPrank();
        stream.setTerms(_terms(address(big)));
        uint256 saleId = auction.start(address(stream), "");
        assertEq(auction.minimumBid(saleId), cap);
        big.mint(alice, cap);
        vm.startPrank(alice);
        big.approve(address(auction), cap);
        auction.bid(saleId, address(0), _direct(alice, cap));
        vm.stopPrank();
        assertEq(auction.auction(saleId).bid, cap);
    }

    function _bidFor(uint256 saleId, address payer, address recipient, uint256 amount) internal {
        vm.deal(payer, payer.balance + amount);
        vm.prank(payer);
        auction.bid{ value: amount }(saleId, recipient, _direct(payer, amount));
    }
}

/// @dev A registry with different code, for the code-hash pin.
contract MockFederationRegistryV2 is MockFederationRegistry {
    function version() external pure returns (uint256) {
        return 2;
    }
}
