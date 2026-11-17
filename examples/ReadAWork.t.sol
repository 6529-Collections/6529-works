// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Example: read everything a marketplace or wallet shows for one 6529 Stream work.
//
// The reads are plain view calls. A front end makes the same calls with `cast call` or a
// library such as viem; the cast versions are in examples/README.md.
//
// The work is set up the way it is on chain: a curated package, a sale started through
// SaleStarter (which also opens the work's record), one bid, and settlement.

import { IWorkDelivery } from "src/interfaces/IWorkDelivery.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { IStreamViews } from "src/interfaces/IStreamViews.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryOutcome } from "src/interfaces/types/SaleTypes.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ContentAddresses as CA } from "test/helpers/ContentAddresses.sol";
import { IntegrationBase } from "test/integration/IntegrationBase.sol";

contract ExampleReadAWork is IntegrationBase {
    address internal artist;
    address internal collector = makeAddr("collector");
    uint256 internal tokenId;
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("artist");
        Work[] memory works = _one(_work(artist, collectionId));
        root = _publish(works);
        _keep(root, works);
        // Start through SaleStarter: auction, payout vaults and record in one transaction.
        uint256 saleId = deployment.saleStarter
            .start(
                IEnglishAuction(address(auction)),
                address(stream),
                _mintData(root, works, 0),
                works[0].media
            );
        tokenId = auction.auction(saleId).tokenId;
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
    }

    function test_ReadAWork() public {
        // 1. Who owns it. 6529 Stream is a plain ERC-721.
        assertEq(stream.ownerOf(tokenId), collector);

        // 2. What 6529 Stream stores for it. `work` is served by Stream's views extension
        //    through Stream's own address: call it on Stream with the IStreamViews ABI
        //    (abi/full/Stream.json has both surfaces).
        IStreamViews.WorkCore memory core = IStreamViews(address(stream)).work(tokenId);
        assertEq(core.collectionId, collectionId);
        assertEq(core.artistId, artists.artistIdOf(artist), "the lead artist's account ID");
        assertEq(core.serial, 1, "first work in the collection");

        // 3. The record: the descriptive JSON file, the media commitment, the license and
        //    whether the record is finalized. Every per-token view of WorkRecords reverts with
        //    RecordNotOpen until the record opens, so check `isOpen` first.
        assertTrue(records.isOpen(tokenId));
        IWorkRecords.RecordInfo memory r = records.record(tokenId);
        assertEq(r.recordFileId, _package(root)[0].item.recordFileId);
        assertFalse(r.finalized, "the artist has not finalized yet");

        // 4. The license: an SPDX ID and the content-store file that holds its text.
        License memory license = records.licenseOf(tokenId);
        assertEq(license.spdxId, "CC0-1.0");
        assertEq(license.textFileId, cc0TextFileId);

        // 5. The media list (primary file first) and, for each file, the copy to serve.
        //    Here the artist registers an Arweave copy; `preferredLocator` then names it.
        MediaFile[] memory media = records.mediaOf(tokenId);
        assertEq(media.length, 1);
        vm.prank(artist);
        delivery.addLocator(tokenId, media[0].fileId, CA.ar("example arweave copy"));
        (IWorkDelivery.Location memory where,) = records.preferredLocator(tokenId, media[0].fileId);
        assertEq(where.uri, CA.arweave("example arweave copy"), "an ar:// URI");

        // 6. The metadata: a data: URI with the ERC-721 JSON (name, description, image or
        //    animation, attributes, license). Give the call plenty of gas (up to 8M, the
        //    tokenURI budget): it reads the record and media from the content store.
        string memory uri = stream.tokenURI(tokenId);
        assertTrue(_startsWith(uri, "data:application/json"));

        // 7. Royalties (ERC-2981): the receiver is the work's royalty split wallet, the rate
        //    is 6.529% at launch (6,529 out of 100,000).
        (address receiver, uint256 amount) = stream.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, core.royaltyReceiver);
        assertEq(amount, uint256(1 ether) * core.royaltyRate / 100_000);

        // 8. How the primary sale ended: outcome, currency and price.
        (PrimaryOutcome outcome, address currency, uint256 price) = stream.primarySale(tokenId);
        assertEq(uint8(outcome), uint8(PrimaryOutcome.SOLD));
        assertEq(currency, address(0), "ETH");
        assertEq(price, 1 ether);
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(prefix);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }
}
