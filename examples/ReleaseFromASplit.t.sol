// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Example: release funds from split wallets.
//
// Every work has two split wallets, both small vaults that the split ledger deploys and
// commands: the seller wallet (sale proceeds; its payees are the work's payees) and the royalty
// wallet (ERC-2981 royalties; its payees are the seller wallet and the network's fee recipient).
// SaleStarter deployed both when the sale started. Every release names the wallet by its payee
// list and salt (zero). A release from a wallet that names the network's fee vault also pays
// the network its share in the same call.

import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ExampleBase } from "./ExampleBase.sol";

contract ExampleReleaseFromASplit is ExampleBase {
    address internal anyone = makeAddr("anyone");
    uint256 internal tokenId;
    address internal seller; // the seller wallet
    uint32 internal feeShare; // the network's share, locked at start
    ISplitWallet.Payee[] internal sellerPayees;

    function setUp() public override {
        super.setUp();
        Package memory pkg = _original();
        uint256 saleId;
        (saleId, tokenId) = _start(pkg);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        (seller, feeShare) = (a.seller, uint32(a.feeShare));
        sellerPayees.push(pkg.item.payees[0]);
        _bid(saleId, makeAddr("collector"), 1 ether);
        _settleAtEnd(saleId);
    }

    function test_TheArtistReleasesSaleProceeds() public {
        // The sale paid the seller wallet; the artist is its only payee here.
        uint256 due = ledger.releasable(sellerPayees, bytes32(0), address(0), 0);
        assertEq(due, seller.balance);

        // The artist's payee is resolved through the accounts module (Directory.payoutAddress):
        // only the account's current payout address may release it (pull-only).
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, anyone, artist)
        );
        ledger.release(sellerPayees, bytes32(0), address(0), 0);

        uint256 before = artist.balance;
        vm.prank(artist);
        ledger.release(sellerPayees, bytes32(0), address(0), 0);
        assertEq(artist.balance - before, due);
    }

    function test_RoyaltiesPayTheNetworkInTheSameCall() public {
        // A marketplace pays the royalty to the receiver royaltyInfo names.
        (address receiver, uint256 royalty) = stream.royaltyInfo(tokenId, 10 ether);
        vm.deal(anyone, royalty);
        vm.prank(anyone);
        (bool ok,) = receiver.call{ value: royalty }("");
        assertTrue(ok);

        // The royalty wallet's payees: the seller wallet and the fee vault, sorted by address.
        // Both are fixed payees, so anyone may push either share.
        address feeVault = address(d.feeRecipientVault);
        ISplitWallet.Payee[] memory payees = Splits.royaltyPayees(seller, feeVault, feeShare);
        assertEq(ledger.walletFor(payees, bytes32(0)), receiver);
        uint256 sellerIndex = payees[0].account == seller ? 0 : 1;

        // What each payee can release now (rounded down; at most one wei per payee stays).
        uint256 sellerDue = ledger.releasable(payees, bytes32(0), address(0), sellerIndex);
        uint256 networkDue = ledger.releasable(payees, bytes32(0), address(0), 1 - sellerIndex);
        assertEq(networkDue, royalty * feeShare / 100_000);

        // Releasing the seller wallet's share also pays the network its share.
        uint256 feeBefore = feeVault.balance;
        uint256 sellerBefore = seller.balance;
        vm.prank(anyone);
        ledger.release(payees, bytes32(0), address(0), sellerIndex);
        assertEq(seller.balance - sellerBefore, sellerDue, "seller wallet");
        assertEq(feeVault.balance - feeBefore, networkDue, "network, same call");
    }

    function test_BatchThroughTheClaimRouter() public {
        // A keeper batches pushes through the stateless ClaimRouter. Rule: for a wallet and
        // asset whose other payee is also released in the batch, leave out the network's own
        // index. The other release already paid the network, so that item would release zero
        // and fail (and atomic mode would revert the whole batch).
        (address receiver, uint256 royalty) = stream.royaltyInfo(tokenId, 10 ether);
        vm.deal(receiver, royalty);
        ISplitWallet.Payee[] memory payees =
            Splits.royaltyPayees(seller, address(d.feeRecipientVault), feeShare);
        uint256 sellerIndex = payees[0].account == seller ? 0 : 1;
        uint256 sellerDue = ledger.releasable(payees, bytes32(0), address(0), sellerIndex);

        IClaimRouter.Claim[] memory batch = new IClaimRouter.Claim[](1);
        batch[0] = IClaimRouter.Claim(payees, bytes32(0), address(0), sellerIndex);
        vm.prank(anyone);
        uint256[] memory amounts = d.claimRouter.claim(batch, false); // atomic
        assertEq(amounts[0], sellerDue);
        assertEq(ledger.releasable(payees, bytes32(0), address(0), 1 - sellerIndex), 0);
    }
}
