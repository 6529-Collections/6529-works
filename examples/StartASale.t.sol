// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Example: start a 1/1 sale from the artist's signed move.
//
// The artist's wallet signs a MoveToStream digest; the proof is the signing wallet followed by
// its signature, abi.encodePacked(wallet, signature). Anyone may then submit the start. The
// network's keeper submits it through SaleStarter, which in the same transaction deploys the
// work's payout vaults and opens its record. If someone started the sale directly first,
// SaleStarter reverts and the keeper finishes the two steps with permissionless calls.

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { MoveAuthorization, StreamMintRequest } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { Splits } from "src/economics/Splits.sol";
import { PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { IntegrationBase } from "test/integration/IntegrationBase.sol";

contract ExampleStartASale is IntegrationBase {
    address internal artist;
    address internal keeper = makeAddr("keeper");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("artist");
        Work[] memory works = _one(_work(artist, collectionId));
        root = _publish(works); // approved by the curation signer, accepted by the artist
        _keep(root, works);
    }

    /// The artist's side: sign the move and encode the start request.
    function _signedRequest(uint256 nonce) internal view returns (bytes memory mintData) {
        Work memory w = _package(root)[0];
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 itemHash = WorksHashing.itemHash(w.item);
        // The digest in the package registry's EIP-712 domain; any wallet of the artist's
        // consolidated account may sign it (here, the root wallet itself).
        bytes32 digest = registry.moveDigest(root, itemHash, nonce, deadline);
        bytes memory proof = abi.encodePacked(artist, _sign(artist, digest));
        // One tuple, encoded as one parameter: the first word must be 0x20.
        mintData = abi.encode(
            StreamMintRequest(
                root,
                w.item,
                _proofOf(_one(w), 0), // empty: a one-item package's root is the leaf
                MoveAuthorization(nonce, deadline, proof)
            )
        );
    }

    function test_StartThroughSaleStarter() public {
        Work memory w = _package(root)[0];
        bytes memory mintData = _signedRequest(0);
        // Preview first: a nonzero creator means the artist's account may start now.
        assertTrue(stream.primaryTerms(0, mintData).creator != address(0));

        vm.prank(keeper);
        uint256 saleId = deployment.saleStarter
            .start(IEnglishAuction(address(auction)), address(stream), mintData, w.media);

        uint256 tokenId = auction.auction(saleId).tokenId;
        assertEq(stream.ownerOf(tokenId), address(auction), "minted into the auction's custody");
        assertTrue(records.isOpen(tokenId), "the record is open");
        PrimaryTerms memory t = stream.primaryTerms(tokenId, "");
        assertTrue(splitFactory.isWallet(t.seller), "the seller vault is deployed");
        assertTrue(splitFactory.isWallet(_royaltyWallet(t)), "and the royalty vault");
        assertTrue(registry.isMoveNonceUsed(artists.artistIdOf(artist), 0), "the nonce is spent");
    }

    function test_SomeoneStartedFirst() public {
        Work memory w = _package(root)[0];
        bytes memory mintData = _signedRequest(0);
        // Anyone holding the signed move can start the auction directly...
        uint256 saleId = auction.start(address(stream), mintData);
        uint256 tokenId = auction.auction(saleId).tokenId;

        // ...and then SaleStarter's start of the same request reverts: the item is used.
        IEnglishAuction english = IEnglishAuction(address(auction));
        vm.prank(keeper);
        vm.expectRevert();
        deployment.saleStarter.start(english, address(stream), mintData, w.media);

        // The keeper notices the work exists (Stream.consumedItemOf(contentHash) is the item
        // hash; the token ID is in the WorkMinted event) and finishes what SaleStarter would
        // have done. Both calls are permissionless and fully determined by the item.
        assertEq(stream.consumedItemOf(w.item.contentHash), WorksHashing.itemHash(w.item));
        PrimaryTerms memory t = stream.primaryTerms(tokenId, "");
        vm.startPrank(keeper);
        assertEq(splitFactory.createWallet(w.item.payees, bytes32(0)), t.seller);
        if (t.feeShare != 0) {
            splitFactory.createWallet(
                Splits.royaltyPayees(t.seller, t.feeRecipient, t.feeShare), bytes32(0)
            );
        }
        records.openRecord(tokenId, w.item, w.media);
        vm.stopPrank();
        assertTrue(records.isOpen(tokenId));
        assertTrue(splitFactory.isWallet(_royaltyWallet(t)));
    }

    function _royaltyWallet(PrimaryTerms memory t) internal view returns (address) {
        return splitFactory.walletFor(
            Splits.royaltyPayees(t.seller, t.feeRecipient, t.feeShare), bytes32(0)
        );
    }
}
