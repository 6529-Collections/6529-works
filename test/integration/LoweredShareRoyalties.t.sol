// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice R9 on the real contracts: after the network lowers a work's fee share, `royaltyInfo`
///         names the royalty vault at the lower share, which nobody has deployed yet. Royalties
///         sent there first are not lost: anyone deploys the vault later and they are released
///         in full, the network's part pushed to the fee vault (R11).
contract LoweredShareRoyaltiesTest is IntegrationBase {
    function test_RoyaltiesSentBeforeTheVaultIsDeployedAreReleased() public {
        Work[] memory works = _one(_work(_actor("loweredArtist"), collectionId));
        bytes32 root = _publish(works);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);
        _ethBid(saleId, makeAddr("loweredCollector"), 1 ether);
        _settleAtEnd(saleId);
        _govern(hotAdmin, address(stream), abi.encodeCall(stream.lowerFeeShare, (tokenId, 10_000)));

        (address receiver, uint256 royalty) = stream.royaltyInfo(tokenId, 10 ether);
        assertGt(royalty, 0);
        assertEq(receiver.code.length, 0, "not deployed yet");
        vm.deal(receiver, royalty); // a marketplace pays the royalty

        address seller = splitFactory.walletFor(works[0].item.payees, bytes32(0));
        ISplitWallet.Payee[] memory payees = Splits.royaltyPayees(seller, networkFee, 10_000);
        assertEq(splitFactory.createWallet(payees, bytes32(0)), receiver, "the named vault");
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
