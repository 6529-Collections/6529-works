// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IGovernedVault } from "src/economics/interfaces/IGovernedVault.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { Roles } from "src/governance/Roles.sol";
import { PRODUCT_STREAM, WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { BlocklistToken } from "../mocks/economics/EconomicsMocks.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Recovering the network's own money after a token blocks its fee recipient (MONEY-2),
///         on the real deployment. A USDC-style token blocks the network fee Safe: the fee of
///         every sale in that token is credited to the escrow under the Safe, and every existing
///         work's royalty wallet keeps the Safe as a fixed payee.
///         - Escrow credits: the fee vault answers to the network, so the network moves its
///           credit with `recover` (FUNDS_SETTER) without any consent (C19). Anyone else's
///           credit still needs that account's consent.
///         - Royalty shares: the vault, a fixed payee, releases its share to its destination
///           (`releaseToDestination`); a seller's release still succeeds while the token refuses
///           the network's pushed share, which stays due (R11).
contract EscrowRecoveryTest is IntegrationBase {
    BlocklistToken internal usdc;
    address internal artist;
    address internal bidder = makeAddr("escrowBidder");
    address internal newFeeSafe = makeAddr("newFeeSafe");

    function setUp() public override {
        super.setUp();
        artist = _actor("escrowArtist");
        usdc = new BlocklistToken();
        _govern(
            hotAdmin,
            address(allowlist),
            abi.encodeCall(allowlist.admitAsset, (address(usdc), 0, 1e6))
        );
    }

    /// @dev A work sold for 1,000 USDC while the token blocks the fee Safe: the network's 250 is
    ///      escrowed under the Safe. Returns the work's terms.
    function _soldWhileBlocked() internal returns (WorkTerms memory terms, uint256 tokenId) {
        Work memory w = _work(artist, collectionId);
        w.item.sale.currency = address(usdc);
        Work[] memory works = _one(w);
        bytes32 root = _publish(works);
        uint256 saleId;
        (saleId, tokenId) = _start(root, works, 0);
        usdc.mint(bidder, 1000e6);
        vm.startPrank(bidder);
        usdc.approve(address(auction), 1000e6);
        auction.bid(saleId, address(0), Payment(PaymentMethod.DIRECT, bidder, 1000e6, 0, 0, ""));
        vm.stopPrank();
        usdc.setBlocked(networkFee, true);
        _settleAtEnd(saleId);
        assertEq(escrow.owed(networkFee, address(usdc)), 250e6, "the network share is escrowed");
        terms = economics.newWorkTerms(PRODUCT_STREAM, w.item.payees);
        // Governance rotates the fee recipient for new works (14 days).
        _govern(
            hotAdmin,
            address(economics),
            abi.encodeCall(economics.setFeeTerms, (PRODUCT_STREAM, 1, newFeeSafe, 25_000))
        );
    }

    function _recoverCall() internal view returns (bytes memory) {
        return abi.encodeCall(IRevenueEscrow.recover, (networkFee, newFeeSafe, address(usdc)));
    }

    /// Regression: MONEY-2 (docs/security/internal-review-2026-10.md)
    /// @dev C19: the fee recipient is the governed vault, which answers to the network, so the
    ///      governed `recover` moves the network's escrowed fee to the new Safe with no consent
    ///      recorded anywhere, and anyone flushes it. Fails without the change: `recover` reverts
    ///      with `RecoveryNotConsented`.
    function test_TheNetworkMovesItsBlockedFeeCreditWithoutConsent() public {
        _soldWhileBlocked();
        vm.expectRevert();
        escrow.flush(networkFee, address(usdc));
        assertEq(escrow.recoveryConsent(networkFee), address(0), "no consent recorded");

        _schedule(hotAdmin, address(escrow), _recoverCall());
        vm.warp(block.timestamp + Roles.DELAY_3D);
        vm.expectEmit(address(escrow));
        emit IRevenueEscrow.Recovered(networkFee, newFeeSafe, address(usdc), 250e6, 250e6);
        vm.prank(hotAdmin);
        manager.execute(address(escrow), _recoverCall());

        assertEq(escrow.owed(networkFee, address(usdc)), 0);
        assertEq(escrow.owed(newFeeSafe, address(usdc)), 250e6);
        assertEq(escrow.totalOwed(address(usdc)), 250e6);
        escrow.flush(newFeeSafe, address(usdc));
        assertEq(usdc.balanceOf(newFeeSafe), 250e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /// Regression: MONEY-2 (docs/security/internal-review-2026-10.md)
    /// @dev C19, negative: an account that is not the network's (an ordinary Safe credited by a
    ///      payer) keeps its credit unless it consents, even after the full delay; with its
    ///      consent the credit moves only where it named.
    function test_TheNetworkCannotMoveAnotherAccountsCreditWithoutConsent() public {
        address other = makeAddr("otherSafe");
        usdc.mint(address(this), 40e6);
        usdc.approve(address(escrow), 40e6);
        escrow.depositERC20(other, address(usdc), 40e6);
        bytes memory call =
            abi.encodeCall(IRevenueEscrow.recover, (other, newFeeSafe, address(usdc)));
        _schedule(hotAdmin, address(escrow), call);
        vm.warp(block.timestamp + Roles.DELAY_3D);
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.RecoveryNotConsented.selector, other, newFeeSafe)
        );
        manager.execute(address(escrow), call);

        vm.prank(other);
        escrow.consentToRecovery(makeAddr("elsewhere"));
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.RecoveryNotConsented.selector, other, newFeeSafe)
        );
        manager.execute(address(escrow), call);
        assertEq(escrow.owed(other, address(usdc)), 40e6);
    }

    /// Regression: MONEY-2 (docs/security/internal-review-2026-10.md)
    /// @dev MONEY-2, the royalty side: the old work's royalty wallet still names the fee vault as
    ///      a fixed payee. While the token blocks the vault, the seller's release still pays the
    ///      seller (the network's pushed share is refused and stays due, R11), paying the vault
    ///      directly fails, and anyone releases the vault's share to its destination.
    function test_BlockedFeeRecipientRedirectsItsRoyaltyShare() public {
        (WorkTerms memory terms, uint256 tokenId) = _soldWhileBlocked();
        (address receiver,) = stream.royaltyInfo(tokenId, 1);
        ISplitWallet.Payee[] memory rp = Splits.royaltyPayees(terms.seller, networkFee, 25_000);
        assertEq(splitFactory.createWallet(rp, bytes32(0)), receiver);
        usdc.mint(receiver, 100e6); // a marketplace pays a USDC royalty
        uint256 feeIndex = rp[0].account == networkFee ? 0 : 1;

        uint256 sellerBefore = usdc.balanceOf(terms.seller);
        assertEq(splitFactory.release(rp, bytes32(0), address(usdc), 1 - feeIndex), 75e6);
        assertEq(usdc.balanceOf(terms.seller) - sellerBefore, 75e6, "the seller is paid");
        assertEq(splitFactory.releasable(rp, bytes32(0), address(usdc), feeIndex), 25e6);
        vm.expectRevert();
        splitFactory.release(rp, bytes32(0), address(usdc), feeIndex);
        IGovernedVault vault = IGovernedVault(networkFee);
        _govern(
            hotAdmin,
            networkFee,
            abi.encodeCall(IGovernedVault.setDestination, (vault.destinationRevision(), newFeeSafe))
        );
        assertEq(
            vault.releaseToDestination(splitFactory, rp, bytes32(0), address(usdc), feeIndex), 25e6
        );
        assertEq(usdc.balanceOf(newFeeSafe), 25e6);
        assertEq(splitFactory.releasable(rp, bytes32(0), address(usdc), feeIndex), 0);
    }
}
