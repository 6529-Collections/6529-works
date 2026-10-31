// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { Roles } from "src/governance/Roles.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import {
    PRODUCT_EDITIONS,
    PRODUCT_FEDERATED,
    PRODUCT_STREAM,
    WorkTerms
} from "src/interfaces/types/EconomicsTypes.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { Mock1271Account } from "../mocks/economics/EconomicsMocks.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Who may receive money, on the real deployment. An artist's payout address must be
///         able to pull (artist-resolved payees are pull-only), so the registry refuses the
///         protocol contracts that cannot (MONEY-4). The network fee recipient must accept
///         payments, so the economics resolver refuses the system contracts that cannot
///         (CALLS-1).
contract RecipientValidationTest is IntegrationBase {
    address internal artist;
    address internal bidder = makeAddr("recipientBidder");
    address internal stranger = makeAddr("recipientStranger");
    uint256 internal artistId;

    function setUp() public override {
        super.setUp();
        artist = _actor("recipientArtist");
        _govern(
            hotAdmin,
            address(allowlist),
            abi.encodeCall(allowlist.admitAsset, (address(usd), 0, 1e16))
        );
    }

    /// @dev The artist's next identity with `payout`, staged by the artist's own signature.
    function _stagePayout(address payout) internal {
        (ArtistIdentity memory id,) = artists.artist(artistId);
        id.payout = payout;
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = artists.changeDigest(artistId, id, artists.changeNonce(artistId), deadline);
        artists.stageChange(artistId, id, artist, deadline, _sign(artist, digest), "");
    }

    /// @dev A work by the artist sold for 1,000 USD, its seller wallet deployed.
    function _soldInUsd() internal returns (address seller) {
        Work memory w = _work(artist, collectionId);
        w.item.sale.currency = address(usd);
        Work[] memory works = _one(w);
        bytes32 root = _publish(works);
        artistId = artists.artistIdOf(artist);
        (uint256 saleId,) = _start(root, works, 0);
        usd.mint(bidder, 1000e18);
        vm.startPrank(bidder);
        usd.approve(address(auction), 1000e18);
        auction.bid(saleId, address(0), Payment(PaymentMethod.DIRECT, bidder, 1000e18, 0, 0, ""));
        vm.stopPrank();
        _settleAtEnd(saleId);
        WorkTerms memory t = economics.newWorkTerms(PRODUCT_STREAM, w.item.payees);
        seller = splitFactory.createWallet(w.item.payees, bytes32(0));
        assertEq(seller, t.seller);
    }

    // ------------------------------------------------------------------ MONEY-4

    /// Regression: MONEY-4 (docs/security/internal-review-2026-10.md)
    /// @dev MONEY-4 regression: the claim router, the revenue escrow and every sale adapter
    ///      cannot call `release`, so none may become an artist's payout address.
    function test_PayoutRefusesProtocolContractsThatCannotPull() public {
        _soldInUsd();
        address[3] memory refused = [address(claimRouter), address(escrow), address(auction)];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
            this.stagePayout(refused[i]);
        }
        // Also refused: the work records (ERC-165), and as before Stream, Editions, the package
        // registry and a deployed split wallet.
        address[5] memory before = [
            address(records),
            address(stream),
            address(editions),
            address(registry),
            _otherWallet(true)
        ];
        for (uint256 i; i < before.length; ++i) {
            vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
            this.stagePayout(before[i]);
        }
        assertEq(artists.payoutAddress(artistId), artist);
    }

    /// Regression: MONEY-4 (docs/security/internal-review-2026-10.md)
    /// @dev MONEY-4 regression, the PoC's path: with the router refused as the payout, a stranger
    ///      batching the artist's index gets `NotPayoutAddress`, and the artist's share stays in
    ///      the wallet for the artist alone.
    function test_StrangerCannotMoveTheArtistShareThroughTheRouter() public {
        address seller = _soldInUsd();
        vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
        this.stagePayout(address(claimRouter));

        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](1);
        claims[0] = IClaimRouter.Claim(seller, address(usd), 0);
        bytes memory reason = abi.encodeWithSelector(
            ISplitWallet.NotPayoutAddress.selector, address(claimRouter), artist
        );
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimRouter.ClaimCallFailed.selector, 0, seller, reason.length, reason
            )
        );
        claimRouter.claim(claims, false);
        assertEq(usd.balanceOf(address(claimRouter)), 0);
        assertEq(ISplitWallet(seller).releasable(address(usd), 0), 750e18);
        vm.prank(artist);
        assertEq(ISplitWallet(seller).release(address(usd), 0), 750e18);
        assertEq(usd.balanceOf(artist), 750e18);
    }

    /// @dev Accounts that can pull stay allowed: an EOA and a smart account (here an ERC-1271
    ///      wallet, which declares none of the protocol interfaces). The change is staged and
    ///      announced, and applies after the delay.
    function test_PayoutAcceptsAccountsThatCanPull() public {
        _soldInUsd();
        Mock1271Account smart = new Mock1271Account();
        address[2] memory allowed = [makeAddr("artistVault"), address(smart)];
        for (uint256 i; i < allowed.length; ++i) {
            vm.recordLogs();
            _stagePayout(allowed[i]);
            assertTrue(_logged(IArtistRegistry.ChangeStaged.selector), "ChangeStaged");
            vm.warp(block.timestamp + artists.CHANGE_DELAY());
            artists.executeChange(artistId);
            assertEq(artists.payoutAddress(artistId), allowed[i]);
        }
    }

    /// @dev The documented limit: a split wallet's predicted address has no code until someone
    ///      deploys it, so it cannot be told apart from an empty account at staging. Deployed
    ///      while the change waits, it is caught at execution and the change is cleared.
    function test_PredictedWalletIsCaughtOnlyOnceDeployed() public {
        _soldInUsd();
        address predicted = _otherWallet(false);
        _stagePayout(predicted);
        _otherWallet(true);
        vm.warp(block.timestamp + artists.CHANGE_DELAY());
        vm.expectEmit(address(artists));
        emit IArtistRegistry.ChangeCancelled(artistId, address(artists), false);
        artists.executeChange(artistId);
        assertEq(artists.payoutAddress(artistId), artist);
    }

    // ------------------------------------------------------------------ CALLS-1 (resolver)

    /// Regression: CALLS-1 (docs/security/internal-review-2026-10.md)
    /// @dev CALLS-1 regression, the resolver's side: governance cannot point a product's network
    ///      fee at the revenue escrow, or at another system contract that cannot accept a
    ///      payment. The governed execution reverts after its delay, and the product keeps its
    ///      recipient.
    function test_FeeRecipientRefusesSystemContracts() public {
        address[12] memory refused = [
            address(escrow),
            address(claimRouter),
            address(auction),
            address(stream),
            address(editions),
            address(economics),
            address(allowlist),
            address(splitFactory),
            address(artists),
            address(registry),
            address(records),
            address(releaseVerifier)
        ];
        bytes32[3] memory products = [PRODUCT_STREAM, PRODUCT_EDITIONS, PRODUCT_FEDERATED];
        for (uint256 i; i < refused.length; ++i) {
            bytes32 product = products[i % 3];
            (uint64 revision,,) = economics.revisions(product);
            bytes memory call =
                abi.encodeCall(economics.setFeeTerms, (product, revision, refused[i], 25_000));
            _schedule(hotAdmin, address(economics), call);
            vm.warp(block.timestamp + Roles.FUNDS);
            vm.prank(hotAdmin);
            vm.expectRevert(
                abi.encodeWithSelector(IEconomicsResolver.InvalidFeeRecipient.selector, refused[i])
            );
            manager.execute(address(economics), call);
            assertEq(economics.networkFeeRecipient(product), networkFee);
        }
    }

    /// Regression: CALLS-1 (docs/security/internal-review-2026-10.md)
    /// @dev CALLS-1, the PoC's flow with the fix: the refused change leaves the fee recipient
    ///      valid, so a work started afterwards settles and pays the network.
    function test_WorksStartedAfterARefusedChangeSettle() public {
        (uint64 revision,,) = economics.revisions(PRODUCT_STREAM);
        bytes memory call = abi.encodeCall(
            economics.setFeeTerms, (PRODUCT_STREAM, revision, address(escrow), 25_000)
        );
        _schedule(hotAdmin, address(economics), call);
        vm.warp(block.timestamp + Roles.FUNDS);
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IEconomicsResolver.InvalidFeeRecipient.selector, address(escrow))
        );
        manager.execute(address(economics), call);

        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        uint256 feeBefore = networkFee.balance;
        uint256 tokenId = _sell(root, works, 0, bidder, 1 ether);
        assertEq(stream.ownerOf(tokenId), bidder);
        assertEq(networkFee.balance - feeBefore, 0.25 ether, "the network fee is paid");
        assertEq(escrow.totalOwed(address(0)), 0);
    }

    /// @dev External, so `vm.expectRevert` sees the registry's revert at this call depth.
    function stagePayout(address payout) external {
        _stagePayout(payout);
    }

    function _logged(bytes32 topic) internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(artists) && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    /// @dev Someone else's single-payee wallet, deployed when `deploy`.
    function _otherWallet(bool deploy) internal returns (address) {
        ISplitWallet.Payee[] memory other = new ISplitWallet.Payee[](1);
        other[0] = ISplitWallet.Payee(0, makeAddr("someoneElse"), Splits.DENOMINATOR);
        return deploy
            ? splitFactory.createWallet(other, bytes32(uint256(1)))
            : splitFactory.walletFor(other, bytes32(uint256(1)));
    }
}
