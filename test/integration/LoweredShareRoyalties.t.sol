// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice R9 on the real contracts: the network lowers a work's fee share only once the
///         royalty vault at the lower share is deployed (anyone deploys it, permissionless; the
///         network sends both in one batch), so `royaltyInfo` never names an undeployed vault.
///         Royalties sent there are released in full, the network's part pushed to the fee
///         vault (R11).
contract LoweredShareRoyaltiesTest is IntegrationBase {
    function test_TheLoweringWaitsForItsVaultAndRoyaltiesAreReleased() public {
        Work[] memory works = _one(_work(_actor("loweredArtist"), collectionId));
        bytes32 root = _publish(works);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);
        _ethBid(saleId, makeAddr("loweredCollector"), 1 ether);
        _settleAtEnd(saleId);

        address seller = splitFactory.walletFor(works[0].item.payees, bytes32(0));
        ISplitWallet.Payee[] memory payees = Splits.royaltyPayees(seller, networkFee, 10_000);
        address vault = splitFactory.walletFor(payees, bytes32(0));
        bytes memory lower = abi.encodeCall(stream.lowerFeeShare, (tokenId, 10_000));
        (, uint32 delay) = manager.canCall(hotAdmin, address(stream), bytes4(lower));
        vm.prank(hotAdmin);
        manager.schedule(address(stream), lower, 0);
        vm.warp(block.timestamp + delay);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.WalletNotDeployed.selector, vault));
        vm.prank(hotAdmin);
        manager.execute(address(stream), lower);
        assertEq(splitFactory.createWallet(payees, bytes32(0)), vault);
        vm.prank(hotAdmin);
        manager.execute(address(stream), lower);

        (address receiver, uint256 royalty) = stream.royaltyInfo(tokenId, 10 ether);
        assertGt(royalty, 0);
        assertEq(receiver, vault, "the deployed vault");
        vm.deal(receiver, royalty); // a marketplace pays the royalty

        uint256 sellerIndex = payees[0].account == seller ? 0 : 1;
        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = networkFee.balance;
        uint256 released = splitFactory.release(payees, bytes32(0), address(0), sellerIndex);
        assertEq(released, royalty * 90_000 / 100_000, "the seller's part");
        assertEq(seller.balance - sellerBefore, released);
        assertEq(networkFee.balance - feeBefore, royalty - released, "the network's part");
        assertEq(receiver.balance, 0, "released in full");
    }
}
