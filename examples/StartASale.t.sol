// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

// Example: start a 1/1 sale from the artist's signed move.
//
// The artist's wallet signs a move digest in the package registry's EIP-712 domain; the proof is
// the signing wallet followed by its signature, abi.encodePacked(wallet, signature). Anyone may
// then submit the start. The network's keeper submits it through SaleStarter, which in the same
// transaction starts the auction (the work is minted into the auction's custody), deploys the
// work's payout vaults and opens its record in WorkFacts. If someone started the sale directly
// first, the keeper finishes those steps with permissionless calls.

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { MintTerms, Work } from "src/interfaces/core/CoreTypes.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { MoveAuthorization, StreamMintRequest } from "src/interfaces/types/PackageTypes.sol";
import { StreamHashing } from "src/interfaces/types/StreamHashing.sol";
import { ExampleBase } from "./ExampleBase.sol";

contract ExampleStartASale is ExampleBase {
    address internal keeper = makeAddr("keeper");

    function test_StartThroughSaleStarter() public {
        Package memory pkg = _original(); // approved by the curation signer, accepted by the artist
        bytes memory request = _request(pkg);
        // Preview first: the policy (the package registry) answers the terms the start would
        // lock, or reverts with the reason the start would refuse the item for.
        (, MintTerms memory t) =
            IMintPolicy(auction.policyOf(address(stream))).preview(address(stream), request);
        assertTrue(t.feeRecipient != address(0));

        vm.prank(keeper);
        uint256 saleId = starter.start(auction, address(stream), request, pkg.media);

        uint256 tokenId = auction.auction(saleId).tokenId;
        assertEq(saleId, auction.saleIdOf(address(stream), tokenId), "sale IDs are derived");
        assertEq(stream.ownerOf(tokenId), address(auction), "minted into the auction's custody");
        assertTrue(facts.factsOf(address(stream), tokenId).opened, "the record is open");
        assertTrue(ledger.isWallet(t.seller), "the seller vault is deployed");
        Work memory w = stream.workOf(tokenId);
        assertTrue(ledger.isWallet(w.royaltyReceiver), "and the royalty vault");
        assertTrue(registry.isMoveNonceUsed(uint256(uint160(artist)), 0), "the nonce is spent");
    }

    function test_SomeoneStartedFirst() public {
        Package memory pkg = _original();
        bytes memory request = _request(pkg);
        (, MintTerms memory t) =
            IMintPolicy(auction.policyOf(address(stream))).preview(address(stream), request);
        // Anyone holding the signed move can start the auction directly...
        uint256 saleId = auction.start(address(stream), request);
        uint256 tokenId = auction.auction(saleId).tokenId;

        // ...and then SaleStarter's start of the same request reverts: the item is used.
        vm.prank(keeper);
        vm.expectRevert();
        starter.start(auction, address(stream), request, pkg.media);

        // The keeper sees the work exists (the token of the content hash; the token ID is also
        // in Stream's WorkMinted event) and finishes what SaleStarter would have done. Each
        // call is permissionless and fully determined by the item and the locked terms.
        assertEq(stream.tokenOfContent(pkg.item.contentHash), tokenId);
        assertEq(stream.itemHashOf(tokenId), StreamHashing.itemHash(pkg.item));
        vm.startPrank(keeper);
        assertEq(ledger.createWallet(pkg.item.payees, bytes32(0)), t.seller);
        address royalty = ledger.createWallet(
            Splits.royaltyPayees(t.seller, t.feeRecipient, t.feeShare), bytes32(0)
        );
        facts.open(address(stream), tokenId, pkg.item, pkg.media);
        vm.stopPrank();
        assertEq(royalty, stream.workOf(tokenId).royaltyReceiver, "the royalty vault");
        assertTrue(facts.factsOf(address(stream), tokenId).opened);
    }

    /// Preview every item before anyone signs: an item that breaks a rule can be approved and
    /// accepted, and is refused only when its sale starts. Preview refuses it first, with the
    /// error the start would give.
    function test_PreviewBeforeAnyoneSigns() public {
        Package memory pkg = _original();
        IMintPolicy policy = IMintPolicy(auction.policyOf(address(stream)));

        // The lead artist as a fixed payee: the lead is paid only through its account.
        pkg.item.payees = new ISplitWallet.Payee[](1);
        pkg.item.payees[0] = ISplitWallet.Payee(0, artist, 100_000);
        pkg.root = StreamHashing.leaf(StreamHashing.itemHash(pkg.item));
        bytes memory refused = abi.encodeWithSelector(
            IPackageRegistry.InvalidItem.selector, StreamHashing.itemHash(pkg.item)
        );
        vm.expectRevert(refused);
        policy.preview(address(stream), _unsigned(pkg));

        // Without the preview the package can still be approved, accepted and its move signed;
        // the start then refuses the item, and every signature was for nothing.
        _publish(pkg.root);
        bytes memory request = _request(pkg);
        vm.expectRevert(refused);
        auction.start(address(stream), request);
    }

    /// The request preview reads before anything is signed: the item and its root, with an
    /// empty proof and an empty move.
    function _unsigned(Package memory pkg) internal pure returns (bytes memory) {
        MoveAuthorization memory none;
        return abi.encode(StreamMintRequest(pkg.root, pkg.item, new bytes32[](0), none));
    }
}
