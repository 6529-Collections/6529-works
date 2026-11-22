// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { ITerms } from "src/interfaces/core/ITerms.sol";
import { PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Royalty receivers on the deployed stack, re-ported from the retired lowered-share
///         suites (`LoweredShareRoyalties`, PR 118's `FederatedRoyaltyAfterLowering`):
///         - A work started without `SaleStarter` names a royalty vault nobody has deployed
///           yet (a predicted CREATE2 address). Royalties a marketplace sends there are held at
///           the address; anyone deploys the vault and releases them, the network's part to the
///           fee vault.
///         - The network lowers a work's share through the TERMS module (PARAMETER_SETTER, 24
///           hours): the vault at the lower share is deployed in the same call before it is set,
///           so `royaltyInfo` never names an undeployed vault after a lowering; the rate stays.
contract LoweredShareRoyaltiesTest is IntegrationBase {
    address internal collector = makeAddr("loweredCollector");
    address internal anyone = makeAddr("anyone");

    struct Sold {
        uint256 tokenId;
        address seller;
        uint32 share;
    }

    function _sold() internal returns (Sold memory s) {
        Work[] memory works = _one(_work(_actor("loweredArtist"), collectionId));
        bytes32 root = _publish(works);
        s.tokenId = _sell(root, works, 0, collector, 1 ether);
        s.seller = ledger.walletFor(works[0].item.payees, bytes32(0));
        s.share = economics.economics(PRODUCT_STREAM).feeShare;
        assertGt(s.share, 0, "the genesis share is nonzero");
    }

    function _lower(Sold memory s, uint32 current, uint32 next) internal {
        _govern(
            network,
            address(terms),
            abi.encodeCall(
                ITerms.lowerFeeShare,
                (address(stream), s.tokenId, s.seller, networkFee, current, next)
            )
        );
    }

    /// @dev Pays `royalty` to `receiver` as a marketplace would, then anyone releases the
    ///      seller's part, which pushes the network's part to the fee vault in the same call;
    ///      returns the seller's part.
    function _payAndRelease(
        address receiver,
        ISplitWallet.Payee[] memory payees,
        address seller,
        uint256 royalty
    ) internal returns (uint256 sellerPart) {
        vm.deal(address(this), royalty);
        (bool sent,) = receiver.call{ value: royalty }("");
        assertTrue(sent, "a marketplace pays the receiver");
        uint256 sellerIndex = payees[0].account == seller ? 0 : 1;
        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = networkFee.balance;
        vm.prank(anyone);
        sellerPart = ledger.release(payees, bytes32(0), address(0), sellerIndex);
        assertEq(seller.balance - sellerBefore, sellerPart, "the seller's part");
        assertEq(networkFee.balance - feeBefore, royalty - sellerPart, "the network's part");
        assertEq(receiver.balance, 0, "released in full");
    }

    /// @dev PR 118's case on the current stack: the receiver at mint has no code; royalties sent
    ///      there are held, and anyone deploys the vault and releases them.
    function test_RoyaltyInfo_NamesAnUndeployedVaultThatAnyoneDeploysAndReleases() public {
        Sold memory s = _sold();
        ISplitWallet.Payee[] memory payees = Splits.royaltyPayees(s.seller, networkFee, s.share);
        address vault = ledger.walletFor(payees, bytes32(0));
        (address receiver, uint256 royalty) = stream.royaltyInfo(s.tokenId, 10 ether);
        assertEq(receiver, vault, "the work's royalty vault");
        assertEq(vault.code.length, 0, "not deployed by the sale");
        assertGt(royalty, 0);

        vm.deal(address(this), royalty);
        (bool sent,) = vault.call{ value: royalty }("");
        assertTrue(sent);
        assertEq(vault.balance, royalty, "held at the address");

        vm.prank(anyone);
        assertEq(ledger.createWallet(payees, bytes32(0)), vault);
        uint256 sellerIndex = payees[0].account == s.seller ? 0 : 1;
        uint256 sellerBefore = s.seller.balance;
        uint256 feeBefore = networkFee.balance;
        vm.prank(anyone);
        uint256 released = ledger.release(payees, bytes32(0), address(0), sellerIndex);
        assertEq(released, Splits.entitlement(royalty, Splits.DENOMINATOR - s.share));
        assertEq(s.seller.balance - sellerBefore, released);
        assertEq(networkFee.balance - feeBefore, royalty - released, "the network's part, pushed");
        assertEq(vault.balance, 0);
    }

    /// @dev The network lowers the share after the 24-hour delay; the execution deploys the new
    ///      vault before setting it, keeps the rate, and royalties paid there are released.
    function test_LowerFeeShare_DeploysTheVaultFirstAndRoyaltiesAreReleased() public {
        Sold memory s = _sold();
        uint32 next = s.share / 2;
        uint24 rate = stream.workOf(s.tokenId).royaltyRate;
        ISplitWallet.Payee[] memory payees = Splits.royaltyPayees(s.seller, networkFee, next);
        address vault = ledger.walletFor(payees, bytes32(0));
        assertEq(vault.code.length, 0);

        bytes memory data = abi.encodeCall(
            ITerms.lowerFeeShare, (address(stream), s.tokenId, s.seller, networkFee, s.share, next)
        );
        (bool immediate, uint32 delay) = manager.canCall(network, address(terms), bytes4(data));
        assertFalse(immediate, "the network waits");
        assertEq(delay, 24 hours, "PARAMETER_SETTER");
        vm.prank(network);
        manager.schedule(address(terms), data, 0);
        vm.warp(block.timestamp + delay);
        vm.expectEmit(address(terms));
        emit ITerms.FeeShareLowered(address(stream), s.tokenId, s.share, next, vault);
        vm.prank(network);
        manager.execute(address(terms), data);

        (address receiver, uint256 royalty) = stream.royaltyInfo(s.tokenId, 10 ether);
        assertEq(receiver, vault, "royaltyInfo follows the lowered share");
        assertGt(vault.code.length, 0, "and names a deployed vault");
        assertEq(stream.workOf(s.tokenId).royaltyRate, rate, "the rate stays");
        uint256 sellerPart = _payAndRelease(receiver, payees, s.seller, royalty);
        assertEq(sellerPart, Splits.entitlement(royalty, Splits.DENOMINATOR - next));

        // To zero: the seller's vault itself is the receiver.
        _lower(s, next, 0);
        (receiver,) = stream.royaltyInfo(s.tokenId, 10 ether);
        assertEq(receiver, s.seller);
    }

    /// @dev Lower only, and the caller's statement must derive the stored receiver: a raise, an
    ///      equal share, and a stale current share are each refused, the receiver unchanged.
    function test_LowerFeeShare_RefusesARaiseAndAStaleStatement() public {
        Sold memory s = _sold();
        (address before,) = stream.royaltyInfo(s.tokenId, 1 ether);
        bytes[3] memory calls = [
            abi.encodeCall(
                ITerms.lowerFeeShare,
                (address(stream), s.tokenId, s.seller, networkFee, s.share, s.share + 1)
            ),
            abi.encodeCall(
                ITerms.lowerFeeShare,
                (address(stream), s.tokenId, s.seller, networkFee, s.share, s.share)
            ),
            abi.encodeCall(
                ITerms.lowerFeeShare,
                (address(stream), s.tokenId, s.seller, networkFee, s.share + 1, s.share / 2)
            )
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(network);
            manager.schedule(address(terms), calls[i], 0);
        }
        vm.warp(block.timestamp + 24 hours);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(network);
            vm.expectRevert(ITerms.InvalidFeeShare.selector);
            manager.execute(address(terms), calls[i]);
        }
        (address receiver,) = stream.royaltyInfo(s.tokenId, 1 ether);
        assertEq(receiver, before);
    }
}
