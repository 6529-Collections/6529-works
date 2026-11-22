// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice A federated token reads the network's share live for `royaltyInfo`, so a lowering
///         names a royalty vault nobody has deployed yet. Royalties sent there are held at the
///         address, and anyone can deploy the vault and release them.
contract FederatedRoyaltyAfterLoweringTest is FederationBase {
    function test_RoyaltyInfo_AfterALoweringNamesAnUndeployedVaultThatAnyoneCanDeployAndRelease()
        public
    {
        _joinedFed();
        (, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        address seller = fed.work(tokenId).seller;
        (address before,) = fed.royaltyInfo(tokenId, 1 ether);
        assertGt(before.code.length, 0, "the vault at the deployed share exists");

        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.lowerFederatedFeeShare, (address(fed), 5_000))
        );
        ISplitWallet.Payee[] memory payees = Splits.royaltyPayees(seller, networkFee, 5_000);
        address lowered = splitFactory.walletFor(payees, 0);
        (address receiver, uint256 royalty) = fed.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, lowered, "royaltyInfo follows the lowered share");
        assertEq(lowered.code.length, 0, "and names an address with no code");

        // A marketplace pays the royalty to the address it was given.
        vm.deal(address(this), royalty);
        (bool sent,) = lowered.call{ value: royalty }("");
        assertTrue(sent);

        // Anyone deploys the vault; the balance already there is the payees'.
        vm.prank(makeAddr("anyone"));
        splitFactory.createWallet(payees, 0);
        assertGt(lowered.code.length, 0);
        uint256 sellerIndex = payees[0].account == seller ? 0 : 1;
        uint256 sellerBefore = seller.balance;
        vm.prank(makeAddr("anyone"));
        splitFactory.release(payees, 0, address(0), sellerIndex);
        assertEq(
            seller.balance - sellerBefore,
            royalty * (Splits.DENOMINATOR - 5_000) / Splits.DENOMINATOR,
            "the seller's share is released"
        );
    }
}
