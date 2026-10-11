// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import {
    CURRENCY_DEFAULT,
    PRODUCT_FEDERATED,
    PRODUCT_STREAM
} from "src/interfaces/types/EconomicsTypes.sol";
import { LockedTerms } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { MockFederationRegistry, MockMintTarget } from "../../mocks/auction/AuctionMocks.sol";
import { AuctionBase } from "./AuctionBase.sol";

/// @dev Dispute pauses, withdrawals, upheld cancellation, resumption, and governed setters.
contract EnglishAuctionDisputesTest is AuctionBase {
    function _state(uint256 saleId) internal view returns (IEnglishAuction.AuctionState) {
        return auction.auction(saleId).state;
    }

    function _expectState(uint256 saleId, IEnglishAuction.AuctionState state) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.InvalidAuctionState.selector, saleId, state)
        );
    }

    // ------------------------------------------------------------------------------ pause

    function test_Pause_FreezesTheAuction() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionPaused(saleId, keccak256("dispute"));
        _pause(saleId);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.PAUSED));
        assertEq(a.pausedAt, block.timestamp);
        vm.deal(bob, 2 ether);
        vm.prank(bob);
        _expectState(saleId, IEnglishAuction.AuctionState.PAUSED);
        auction.bid{ value: 2 ether }(saleId, address(0), _direct(bob, 2 ether));
        vm.warp(a.endTime + 1);
        _expectState(saleId, IEnglishAuction.AuctionState.PAUSED);
        auction.settle(saleId);
    }

    function test_Pause_OnlyTheGuardian() public {
        uint256 saleId = _start();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.pause(saleId, bytes32(0));
    }

    function test_Pause_OnlyALiveAuctionOnce() public {
        uint256 saleId = _start();
        _pause(saleId);
        vm.prank(guardian);
        _expectState(saleId, IEnglishAuction.AuctionState.PAUSED);
        auction.pause(saleId, bytes32(0));
        vm.prank(unpauser);
        auction.resume(saleId);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.PauseExhausted.selector, saleId));
        auction.pause(saleId, bytes32(0));

        uint256 ended = _start();
        _end(ended);
        vm.prank(guardian);
        _expectState(ended, IEnglishAuction.AuctionState.ENDED);
        auction.pause(ended, bytes32(0));
        vm.prank(guardian);
        _expectState(_saleIdOf(99), IEnglishAuction.AuctionState.NONE);
        auction.pause(_saleIdOf(99), bytes32(0));
    }

    // ------------------------------------------------------------------------ withdrawals

    function test_WithdrawBid_WhilePaused() public {
        vm.prank(setter);
        auction.setOpeningBid(ETH, 0, 0.1 ether);
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _bidEth(saleId, bob, 2 ether);
        vm.prank(bob);
        _expectState(saleId, IEnglishAuction.AuctionState.ACTIVE);
        auction.withdrawBid(saleId);
        _pause(saleId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.NotHighBidder.selector, alice));
        auction.withdrawBid(saleId);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(bob, ETH, saleId, 2 ether);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.BidWithdrawn(saleId, bob, 2 ether);
        vm.prank(bob);
        auction.withdrawBid(saleId);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.bidder, address(0));
        assertEq(a.bid, 0);
        assertEq(auction.claimable(bob, ETH), 2 ether);
        assertEq(auction.minimumBid(saleId), 0.1 ether, "back to the locked opening bid");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.NotHighBidder.selector, bob));
        auction.withdrawBid(saleId);
    }

    // ----------------------------------------------------------------------------- resume

    function test_Resume_KeepsTheRemainingTime() public {
        uint256 saleId = _start();
        uint256 end = auction.auction(saleId).endTime;
        vm.warp(end - 1 hours);
        _pause(saleId);
        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionResumed(saleId, uint64(end + 2 days));
        vm.prank(unpauser);
        auction.resume(saleId);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.endTime, end + 2 days);
        assertEq(a.pausedAt, 0);
        assertEq(a.pausedTotal, 2 days);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(a.endTime - block.timestamp, 1 hours);
    }

    function test_Resume_OnlyTheUnpauserAndOnlyWhilePaused() public {
        uint256 saleId = _start();
        vm.prank(unpauser);
        _expectState(saleId, IEnglishAuction.AuctionState.ACTIVE);
        auction.resume(saleId);
        _pause(saleId);
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian)
        );
        auction.resume(saleId);
    }

    function test_Pause_EndsByItselfAfterSevenDays() public {
        uint256 saleId = _start();
        uint256 end = auction.auction(saleId).endTime;
        vm.warp(end - 10 minutes);
        _pause(saleId);
        uint256 pausedAt = block.timestamp;
        vm.warp(pausedAt + 7 days);
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.PAUSED), "inclusive");
        vm.warp(pausedAt + 7 days + 1);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.ACTIVE), "resumed, no call");
        assertEq(a.endTime, end + 7 days);
        assertEq(a.pausedAt, 0);
        assertEq(a.pausedTotal, 7 days);
        vm.prank(unpauser);
        _expectState(saleId, IEnglishAuction.AuctionState.ACTIVE);
        auction.resume(saleId);

        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionResumed(saleId, uint64(end + 7 days));
        _bidEth(saleId, alice, 1 ether);
        assertEq(auction.auction(saleId).endTime, block.timestamp + WINDOW, "anti-snipe applies");
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.PauseExhausted.selector, saleId));
        auction.pause(saleId, bytes32(0));
        vm.warp(block.timestamp + WINDOW);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), alice);
    }

    function test_Pause_ExpiredPauseSettlesWithoutAResumeCall() public {
        uint256 saleId = _start();
        uint256 end = auction.auction(saleId).endTime;
        _bidEth(saleId, alice, 1 ether);
        vm.warp(end - 1);
        _pause(saleId);
        vm.warp(end + 7 days);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), alice);
    }

    // ----------------------------------------------------------------------------- cancel

    function test_Cancel_UpheldDisputeRefundsAndBurns() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _bidEth(saleId, bob, 2 ether);
        _pause(saleId);
        bytes32 outcome = _recordOutcome(1);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(bob, ETH, saleId, 2 ether);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionCancelled(saleId, outcome);
        vm.prank(setter);
        auction.cancel(saleId, outcome);
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.CANCELLED));
        assertEq(stream.burned(), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        stream.ownerOf(1);
        assertEq(auction.claimable(alice, ETH), 1 ether);
        assertEq(auction.claimable(bob, ETH), 2 ether);
        vm.prank(alice);
        auction.claim(ETH, alice);
        vm.prank(bob);
        auction.claim(ETH, bob);
        assertEq(address(auction).balance, 0, "every bid refunded");
        _expectState(saleId, IEnglishAuction.AuctionState.CANCELLED);
        auction.settle(saleId);
    }

    function test_Cancel_WithNoBids() public {
        uint256 saleId = _start();
        _pause(saleId);
        bytes32 outcome = _recordOutcome(1);
        vm.prank(setter);
        auction.cancel(saleId, outcome);
        assertEq(stream.burned(), 1);
    }

    function test_Cancel_NeedsTheRecordedOutcome() public {
        uint256 saleId = _start();
        _pause(saleId);
        vm.startPrank(setter);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.OutcomeNotRecorded.selector, saleId, bytes32(0))
        );
        auction.cancel(saleId, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.OutcomeNotRecorded.selector, saleId, keccak256("x")
            )
        );
        auction.cancel(saleId, keccak256("x"));
        vm.stopPrank();
        bytes32 first = _recordOutcome(1);
        bytes32 latest = _recordOutcome(1);
        vm.prank(setter);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.OutcomeNotRecorded.selector, saleId, first)
        );
        auction.cancel(saleId, first);
        vm.prank(setter);
        auction.cancel(saleId, latest);
    }

    function test_Cancel_OnlyWhileThePauseIsLive() public {
        uint256 saleId = _start();
        bytes32 outcome = _recordOutcome(1);
        vm.prank(setter);
        _expectState(saleId, IEnglishAuction.AuctionState.ACTIVE);
        auction.cancel(saleId, outcome);
        _pause(saleId);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(setter);
        _expectState(saleId, IEnglishAuction.AuctionState.ACTIVE);
        auction.cancel(saleId, outcome);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.cancel(saleId, outcome);
    }

    /// @dev The pause window is inclusive: `cancel` lands at exactly `pausedAt + 7 days` and is
    ///      refused one second later.
    function test_Cancel_PauseWindowBoundary() public {
        uint256 inside = _start();
        uint256 outside = _start();
        _pause(inside);
        _pause(outside);
        uint256 pausedAt = block.timestamp;
        bytes32 insideOutcome = _recordOutcome(_tokenIdOf(inside));
        bytes32 outsideOutcome = _recordOutcome(_tokenIdOf(outside));
        vm.warp(pausedAt + 7 days);
        vm.prank(setter);
        auction.cancel(inside, insideOutcome);
        assertEq(uint8(_state(inside)), uint8(IEnglishAuction.AuctionState.CANCELLED));
        vm.warp(pausedAt + 7 days + 1);
        vm.prank(setter);
        _expectState(outside, IEnglishAuction.AuctionState.ACTIVE);
        auction.cancel(outside, outsideOutcome);
    }

    /// @dev The upheld outcome is a 48-hour action. Scheduled exactly at day 5 of the pause it
    ///      becomes executable at `pausedAt + 7 days`, which the inclusive window still accepts;
    ///      scheduled one second later it lands after the pause and is refused.
    function test_Cancel_ThroughTheStandardDelay() public {
        address council = makeAddr("council");
        manager.grantRole(PARAMETER_SETTER, council, 48 hours);
        uint256 saleId = _start();
        uint256 other = _start();
        _pause(saleId);
        _pause(other);
        bytes32 outcome = _recordOutcome(_tokenIdOf(saleId));
        bytes32 otherOutcome = _recordOutcome(_tokenIdOf(other));
        bytes memory onTime = abi.encodeCall(auction.cancel, (saleId, outcome));
        bytes memory late = abi.encodeCall(auction.cancel, (other, otherOutcome));

        uint256 pausedAt = block.timestamp;
        vm.warp(pausedAt + 5 days);
        vm.prank(council);
        manager.schedule(address(auction), onTime, 0);
        vm.warp(pausedAt + 5 days + 1);
        vm.prank(council);
        manager.schedule(address(auction), late, 0);

        vm.warp(pausedAt + 7 days);
        vm.prank(council);
        manager.execute(address(auction), onTime);
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.CANCELLED));

        vm.warp(pausedAt + 7 days + 1);
        vm.prank(council);
        _expectState(other, IEnglishAuction.AuctionState.ACTIVE);
        manager.execute(address(auction), late);
    }

    // ------------------------------------------------------------------------- governance

    function test_SetConfig_CompareAndSet() public {
        IEnglishAuction.AuctionConfig memory next =
            IEnglishAuction.AuctionConfig(12 hours, 10 minutes, 10_000);
        vm.prank(setter);
        vm.expectRevert(ISaleAdapter.ExpectedValueMismatch.selector);
        auction.setConfig(next, next);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.ConfigSet(_config(), next);
        vm.prank(setter);
        auction.setConfig(_config(), next);
        assertEq(auction.config().duration, 12 hours);
        IEnglishAuction.AuctionConfig memory current = auction.config();
        next.incrementShare = 100_001;
        vm.prank(setter);
        vm.expectRevert(EnglishAuction.InvalidConfig.selector);
        auction.setConfig(current, next);
        uint256 saleId = _start();
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.endTime - block.timestamp, 12 hours, "new sales use the new config");
    }

    /// @dev The opening bid is a two-way compare-and-set price within an absolute ceiling.
    function test_SetOpeningBid_MovesBothWaysWithinTheCeiling() public {
        uint256 ceiling = ETH_FLOOR * auction.OPENING_BID_FLOORS();
        vm.startPrank(setter);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnglishAuction.OpeningBidAboveCeiling.selector, ceiling + 1, ceiling
            )
        );
        auction.setOpeningBid(ETH, 0, ceiling + 1);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.OpeningBidSet(ETH, 0, 0.5 ether);
        auction.setOpeningBid(ETH, 0, 0.5 ether);
        vm.expectRevert(ISaleAdapter.ExpectedValueMismatch.selector);
        auction.setOpeningBid(ETH, 0, 0.2 ether);
        auction.setOpeningBid(ETH, 0.5 ether, 0.2 ether);
        auction.setOpeningBid(ETH, 0.2 ether, ceiling);
        auction.setOpeningBid(ETH, ceiling, 0);
        auction.setOpeningBid(ETH, 0, 0.2 ether);
        vm.expectRevert(abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, alice));
        auction.setOpeningBid(alice, 0, 1);
        vm.stopPrank();
        assertEq(auction.openingBid(ETH), 0.2 ether);
        uint256 saleId = _start();
        assertEq(auction.minimumBid(saleId), 0.2 ether);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, 0.2 ether, 0.1 ether)
        );
        auction.bid{ value: 0.1 ether }(saleId, address(0), _direct(alice, 0.1 ether));
        vm.prank(setter);
        auction.setOpeningBid(ETH, 0.2 ether, 0);
        assertEq(auction.minimumBid(saleId), 0.2 ether, "locked for the running sale");
    }

    function testFuzz_SetOpeningBid_AnyValueUpToTheCeiling(uint256 first, uint256 next) public {
        uint256 ceiling = ETH_FLOOR * auction.OPENING_BID_FLOORS();
        first = bound(first, 0, ceiling);
        vm.prank(setter);
        auction.setOpeningBid(ETH, 0, first);
        vm.prank(setter);
        if (next > ceiling) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    EnglishAuction.OpeningBidAboveCeiling.selector, next, ceiling
                )
            );
            auction.setOpeningBid(ETH, first, next);
            assertEq(auction.openingBid(ETH), first);
        } else {
            auction.setOpeningBid(ETH, first, next);
            assertEq(auction.openingBid(ETH), next);
        }
    }

    function test_SetTarget_AdmitsAndRemoves() public {
        MockMintTarget other = new MockMintTarget();
        other.setAdmittedMinter(address(auction), true);
        other.setTerms(_terms(ETH));
        vm.expectEmit(address(auction));
        emit ISaleAdapter.TargetSet(address(other), true);
        vm.prank(successor);
        auction.setTarget(address(other), true);
        assertTrue(auction.isTarget(address(other)));
        uint256 saleId = auction.start(address(other), "");
        assertEq(auction.saleIdOf(address(other), 1), saleId);
        assertTrue(saleId != auction.saleIdOf(address(stream), 1));

        vm.prank(successor);
        auction.setTarget(address(other), false);
        assertFalse(auction.isTarget(address(other)));
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(other))
        );
        auction.start(address(other), "");
        _bidEth(saleId, alice, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(other.ownerOf(1), alice, "running sales finish");
    }

    function test_SetTarget_RejectsNonTokens() public {
        vm.startPrank(successor);
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.InvalidTarget.selector, alice));
        auction.setTarget(alice, true);
        vm.expectRevert(
            abi.encodeWithSelector(EnglishAuction.InvalidTarget.selector, address(escrow))
        );
        auction.setTarget(address(escrow), true);
        vm.stopPrank();
    }

    function test_GovernedSettersAreRestricted() public {
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.setConfig(_config(), _config());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.setOpeningBid(ETH, 0, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.setTarget(alice, true);
        vm.stopPrank();
        assertEq(address(manager), auction.authority());
    }
}

/// @dev Federated targets (D21) and the golden Permit2 witness (D16).
contract EnglishAuctionFederationTest is AuctionBase {
    function test_Federation_ActiveContractsSellWithTheRegistryFee() public {
        MockFederationRegistry registry = new MockFederationRegistry();
        MockMintTarget federated = new MockMintTarget();
        federated.setAdmittedMinter(address(auction), true);
        federated.setTerms(_terms(ETH));
        assertFalse(auction.isTarget(address(federated)));

        vm.prank(successor);
        vm.expectRevert(ISaleAdapter.ExpectedValueMismatch.selector);
        auction.setFederationRegistry(alice, address(registry));
        vm.expectEmit(address(auction));
        emit ISaleAdapter.FederationRegistrySet(address(0), address(registry));
        vm.prank(successor);
        auction.setFederationRegistry(address(0), address(registry));
        assertEq(auction.federationRegistry(), address(registry));

        IFederationRegistry.Entry memory e = IFederationRegistry.Entry(
            IFederationRegistry.Form.ERC721,
            address(0),
            uint160(artist),
            1,
            address(federated).codehash,
            10_000,
            IFederationRegistry.Status.ACTIVE
        );
        registry.register(address(federated), e);
        assertTrue(auction.isTarget(address(federated)));
        uint256 saleId = auction.start(address(federated), "");
        (LockedTerms memory lt,) = auction.lockedTerms(saleId);
        assertEq(lt.feeShare, 10_000, "the registry's fee, not the token's");
        _bidEth(saleId, alice, 1 ether);
        vm.warp(block.timestamp + DURATION);
        auction.settle(saleId);
        assertEq(network.balance, 0.1 ether);
        assertEq(seller.balance, 0.9 ether);

        registry.setStatus(address(federated), IFederationRegistry.Status.DELISTED, bytes32(0));
        assertFalse(auction.isTarget(address(federated)));
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(federated))
        );
        auction.start(address(federated), "");
    }

    function test_Federation_SetterIsRestrictedAndChecksCode() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.setFederationRegistry(address(0), alice);
        vm.prank(successor);
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.InvalidDependency.selector, alice));
        auction.setFederationRegistry(address(0), alice);
        vm.prank(successor);
        vm.expectRevert(
            abi.encodeWithSelector(EnglishAuction.InvalidDependency.selector, address(escrow))
        );
        auction.setFederationRegistry(address(0), address(escrow));
    }

    /// @dev A federated token naming `CURRENCY_DEFAULT` locks the Federated product's default.
    function test_Federation_DefaultCurrencyIsTheFederatedProducts() public {
        MockFederationRegistry registry = new MockFederationRegistry();
        MockMintTarget federated = new MockMintTarget();
        federated.setAdmittedMinter(address(auction), true);
        federated.setTerms(_terms(CURRENCY_DEFAULT));
        vm.prank(successor);
        auction.setFederationRegistry(address(0), address(registry));
        IFederationRegistry.Entry memory e;
        e.status = IFederationRegistry.Status.ACTIVE;
        e.feeShare = 10_000;
        registry.register(address(federated), e);
        _setDefault(PRODUCT_STREAM, ETH);
        _setDefault(PRODUCT_FEDERATED, address(usd));
        uint256 saleId = auction.start(address(federated), "");
        assertEq(auction.auction(saleId).currency, address(usd));
    }

    /// @dev Golden values computed off-chain with `cast keccak`: the full Permit2 type hashes the
    ///      auction's PERMIT2 bids are signed under (D16), built from `Typehashes`.
    function test_Permit2Witness_Golden() public pure {
        string memory stub =
            "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
        assertEq(keccak256(abi.encodePacked(stub, Typehashes.BID_WITNESS_TYPE)), BID_PERMIT_GOLDEN);
        assertEq(
            keccak256(abi.encodePacked(stub, Typehashes.START_BID_WITNESS_TYPE)),
            START_BID_PERMIT_GOLDEN
        );
        assertEq(
            Typehashes.BID_WITNESS,
            keccak256("Bid(uint256 saleId,address recipient,uint256 amount,uint256 deadline)")
        );
    }

    bytes32 internal constant BID_PERMIT_GOLDEN =
        0x0bfd3d1d308e98f9f0a38b17a9eaaad1118b7813eead91902f6714537c0eb034;
    bytes32 internal constant START_BID_PERMIT_GOLDEN =
        0xb44f39960bfdaf0c5fedccb2b3159844117a56c2d506bcf2c35776fe2c346acf;
}
