// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
///         - Escrow credits: the Safe names its replacement on the escrow (its consent), and
///           governance moves the credit there with `recover` (FUNDS_SETTER, 14 days).
///         - Royalty shares: the Safe, a fixed payee, releases its share to any recipient with
///           `releaseTo`. Split wallets have no governance, so nobody else can.
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

    /// @dev MONEY-2 regression: with the Safe's consent, the governed `recover` moves the
    ///      network's escrowed fee to the new Safe, and anyone flushes it there.
    function test_BlockedFeeRecipientCreditMovesWithItsConsent() public {
        _soldWhileBlocked();
        vm.expectRevert();
        escrow.flush(networkFee, address(usdc));

        vm.expectEmit(address(escrow));
        emit IRevenueEscrow.RecoveryConsentSet(networkFee, newFeeSafe);
        vm.prank(networkFee);
        escrow.consentToRecovery(newFeeSafe);
        assertEq(escrow.recoveryConsent(networkFee), newFeeSafe);

        _schedule(hotAdmin, address(escrow), _recoverCall());
        vm.warp(block.timestamp + Roles.FUNDS);
        vm.expectEmit(address(escrow));
        emit IRevenueEscrow.Recovered(networkFee, newFeeSafe, address(usdc), 250e6, 250e6);
        vm.prank(hotAdmin);
        manager.execute(address(escrow), _recoverCall());

        assertEq(escrow.owed(networkFee, address(usdc)), 0);
        assertEq(escrow.owed(newFeeSafe, address(usdc)), 250e6);
        assertEq(escrow.recoveryConsent(networkFee), address(0), "the consent is used up");
        assertEq(escrow.totalOwed(address(usdc)), 250e6);
        escrow.flush(newFeeSafe, address(usdc));
        assertEq(usdc.balanceOf(newFeeSafe), 250e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /// @dev MONEY-2, negative: without the Safe's consent, or to another account than the one
    ///      it named, governance cannot move the credit, even after the full delay.
    function test_GovernanceCannotMoveTheCreditWithoutConsent() public {
        _soldWhileBlocked();
        _schedule(hotAdmin, address(escrow), _recoverCall());
        vm.warp(block.timestamp + Roles.FUNDS);
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRevenueEscrow.RecoveryNotConsented.selector, networkFee, newFeeSafe
            )
        );
        manager.execute(address(escrow), _recoverCall());

        vm.prank(networkFee);
        escrow.consentToRecovery(makeAddr("elsewhere"));
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRevenueEscrow.RecoveryNotConsented.selector, networkFee, newFeeSafe
            )
        );
        manager.execute(address(escrow), _recoverCall());
        assertEq(escrow.owed(networkFee, address(usdc)), 250e6);
    }

    /// @dev MONEY-2, the royalty side: the old work's royalty wallet still names the old Safe as
    ///      a fixed payee. Paying it directly fails while the token blocks it, but the Safe itself
    ///      may release its share to the new Safe.
    function test_BlockedFeeRecipientRedirectsItsRoyaltyShare() public {
        (WorkTerms memory terms, uint256 tokenId) = _soldWhileBlocked();
        (address receiver,) = stream.royaltyInfo(tokenId, 1);
        ISplitWallet.Payee[] memory rp = Splits.royaltyPayees(terms.seller, networkFee, 25_000);
        assertEq(splitFactory.createWallet(rp, bytes32(0)), receiver);
        usdc.mint(receiver, 100e6); // a marketplace pays a USDC royalty
        uint256 feeIndex = rp[0].account == networkFee ? 0 : 1;

        vm.expectRevert();
        ISplitWallet(receiver).release(address(usdc), feeIndex);
        vm.prank(networkFee);
        assertEq(ISplitWallet(receiver).releaseTo(address(usdc), feeIndex, newFeeSafe), 25e6);
        assertEq(usdc.balanceOf(newFeeSafe), 25e6);
        assertEq(ISplitWallet(receiver).releasable(address(usdc), feeIndex), 0);
    }
}
