// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { PRODUCT_STREAM, WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { SaleStarter } from "src/sales/SaleStarter.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice The keeper's start helper on the real stack: one transaction starts the 1/1's
///         auction, deploys the work's seller and royalty vaults and opens its record; if the
///         record cannot open, nothing happens at all (no token, no sale, no vault).
contract SaleStarterTest is IntegrationBase {
    SaleStarter internal starter;

    function setUp() public override {
        super.setUp();
        starter = new SaleStarter();
    }

    function test_StartsDeploysTheVaultsAndOpensTheRecord() public {
        Work[] memory works = _one(_work(_actor("starterArtist"), collectionId));
        bytes32 root = _publish(works);
        WorkTerms memory w = economics.newWorkTerms(PRODUCT_STREAM, works[0].item.payees);
        assertFalse(splitFactory.isWallet(w.seller), "no seller vault before");
        uint256 saleId = starter.start(
            IEnglishAuction(address(auction)),
            address(stream),
            _mintData(root, works, 0),
            works[0].media
        );
        uint256 tokenId = IStream(address(stream)).totalMinted();
        assertEq(saleId, auction.saleIdOf(address(stream), tokenId));
        assertTrue(splitFactory.isWallet(w.seller), "the seller vault");
        if (w.feeShare != 0) assertTrue(splitFactory.isWallet(w.royaltyReceiver), "the royalty");
        assertTrue(records.isOpen(tokenId), "the record is open");
        assertEq(address(starter).balance, 0, "the helper holds nothing");
    }

    /// @dev Fails without the helper's all-or-nothing call: a start made on its own leaves the
    ///      record unopened. Here the record's media do not match the item, so the whole call,
    ///      the start and the vaults included, reverts.
    function test_RevertsAsAWholeWhenTheRecordCannotOpen() public {
        Work[] memory works = _one(_work(_actor("brokenRecordArtist"), collectionId));
        bytes32 root = _publish(works);
        WorkTerms memory w = economics.newWorkTerms(PRODUCT_STREAM, works[0].item.payees);
        uint256 before = IStream(address(stream)).totalMinted();
        MediaFile[] memory none = new MediaFile[](0);
        bytes memory mintData = _mintData(root, works, 0);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidRecordData.selector, before + 1));
        starter.start(IEnglishAuction(address(auction)), address(stream), mintData, none);
        assertEq(IStream(address(stream)).totalMinted(), before, "no token was minted");
        assertFalse(splitFactory.isWallet(w.seller), "no vault was deployed");
    }
}
