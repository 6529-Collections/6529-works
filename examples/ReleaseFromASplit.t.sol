// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Example: release funds from split wallets.
//
// Every work has two split wallets, both small vaults that the split ledger deploys and
// commands: the seller wallet (sale proceeds; its payees are the work's payees) and the
// royalty wallet (ERC-2981 royalties; its payees are the seller wallet and the network fee
// recipient). Every release call names the wallet by its payee list and salt (zero). A release
// from a wallet that names the network fee recipient also pays the network its share in the
// same call.

import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { IntegrationBase } from "test/integration/IntegrationBase.sol";

contract ExampleReleaseFromASplit is IntegrationBase {
    address internal artist;
    address internal anyone = makeAddr("anyone");
    uint256 internal tokenId;
    bytes32 internal root;
    PrimaryTerms internal t;

    function setUp() public override {
        super.setUp();
        artist = _actor("artist");
        Work[] memory works = _one(_work(artist, collectionId));
        root = _publish(works);
        _keep(root, works);
        tokenId = _sell(root, works, 0, makeAddr("collector"), 1 ether);
        t = stream.primaryTerms(tokenId, "");
    }

    function test_TheArtistReleasesSaleProceeds() public {
        Work memory w = _package(root)[0];
        // The sale paid the seller wallet's predicted address. Deploy it (anyone may; the
        // address is fixed by the payees and salt), then release.
        assertEq(splitFactory.createWallet(w.item.payees, bytes32(0)), t.seller);
        uint256 due = splitFactory.releasable(w.item.payees, bytes32(0), address(0), 0);
        assertEq(due, t.seller.balance, "the artist is the only payee here");

        // The artist's payee is resolved through the artist registry: only the account's
        // current payout address may release it (pull-only).
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, anyone, artist)
        );
        splitFactory.release(w.item.payees, bytes32(0), address(0), 0);

        uint256 before = artist.balance;
        vm.prank(artist);
        splitFactory.release(w.item.payees, bytes32(0), address(0), 0);
        assertEq(artist.balance - before, due);
    }

    function test_RoyaltiesPayTheNetworkInTheSameCall() public {
        // A marketplace pays the royalty to the receiver royaltyInfo names.
        (address receiver, uint256 royalty) = stream.royaltyInfo(tokenId, 10 ether);
        vm.deal(anyone, royalty);
        vm.prank(anyone);
        (bool ok,) = receiver.call{ value: royalty }("");
        assertTrue(ok);

        // The royalty wallet's payees: the seller wallet and the fee recipient, sorted by
        // address. Both are fixed payees, so anyone may push either share.
        ISplitWallet.Payee[] memory payees =
            Splits.royaltyPayees(t.seller, t.feeRecipient, t.feeShare);
        assertEq(splitFactory.createWallet(payees, bytes32(0)), receiver);
        uint256 sellerIndex = payees[0].account == t.seller ? 0 : 1;

        // What each payee can release now (rounded down; at most one wei per payee stays).
        uint256 sellerDue = splitFactory.releasable(payees, bytes32(0), address(0), sellerIndex);
        uint256 networkDue =
            splitFactory.releasable(payees, bytes32(0), address(0), 1 - sellerIndex);
        assertEq(networkDue, royalty * t.feeShare / 100_000);

        // Releasing the seller wallet's share also pays the network its share.
        uint256 feeBefore = t.feeRecipient.balance;
        uint256 sellerBefore = t.seller.balance;
        vm.prank(anyone);
        splitFactory.release(payees, bytes32(0), address(0), sellerIndex);
        assertEq(t.seller.balance - sellerBefore, sellerDue, "seller wallet");
        assertEq(t.feeRecipient.balance - feeBefore, networkDue, "network, same call");
    }

    function test_BatchThroughTheClaimRouter() public {
        // A keeper batches pushes through the stateless ClaimRouter. Rule: for a wallet and
        // asset whose other payee is also released in the batch, leave out the network's own
        // index. The other release already paid the network, so that item would release zero
        // and fail (and atomic mode would revert the whole batch).
        (address receiver, uint256 royalty) = stream.royaltyInfo(tokenId, 10 ether);
        vm.deal(receiver, royalty);
        ISplitWallet.Payee[] memory payees =
            Splits.royaltyPayees(t.seller, t.feeRecipient, t.feeShare);
        splitFactory.createWallet(payees, bytes32(0));
        uint256 sellerIndex = payees[0].account == t.seller ? 0 : 1;
        uint256 sellerDue = splitFactory.releasable(payees, bytes32(0), address(0), sellerIndex);

        IClaimRouter.Claim[] memory batch = new IClaimRouter.Claim[](1);
        batch[0] = IClaimRouter.Claim(payees, bytes32(0), address(0), sellerIndex);
        vm.prank(anyone);
        uint256[] memory amounts = claimRouter.claim(batch, false); // atomic
        assertEq(amounts[0], sellerDue);
        assertEq(splitFactory.releasable(payees, bytes32(0), address(0), 1 - sellerIndex), 0);
    }
}
