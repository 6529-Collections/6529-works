// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { EconomicsResolver } from "src/economics/EconomicsResolver.sol";
import { Splits } from "src/economics/Splits.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { PRODUCT_STREAM, WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { Stream } from "src/stream/Stream.sol";
import { StreamFixture } from "./StreamFixture.sol";

/// @notice Stream wired to the real `EconomicsResolver` and `SplitFactory` (review L3): the
///         receiver Stream derives is exactly the one the resolver quotes and the factory
///         deploys, and the start reports the resolver's fee terms.
contract StreamEconomicsTest is StreamFixture {
    EconomicsResolver internal resolver;
    Stream internal wired;
    uint256 internal wiredCollection;

    function setUp() public override {
        super.setUp();
        AssetAllowlist allowlist = new AssetAllowlist(address(manager), 1);
        resolver = new EconomicsResolver(
            address(manager),
            allowlist,
            ISplitFactory(address(splitFactory)),
            feeRecipient,
            makeAddr("museum"),
            keccak256("cc0 text")
        );
        wired = new Stream(
            address(manager),
            address(registry),
            address(artists),
            address(resolver),
            address(entropy),
            address(renderer),
            address(renderer).codehash,
            marketOwner
        );
        // The test is the AccessManager admin.
        wired.setAdmittedMinter(address(auction), true);
        wiredCollection = wired.createCollection("Wired", keccak256("wired"));
    }

    function test_receiverIsTheResolversAndTheFactorys() public {
        PackageItem memory item = _item(1);
        item.collectionId = wiredCollection;
        (uint256 tokenId, PrimaryTerms memory terms) = auction.start(wired, _request(item));
        WorkTerms memory w = resolver.newWorkTerms(PRODUCT_STREAM, item.payees);
        assertTrue(w.feeShare != 0);

        assertEq(wired.work(tokenId).royaltyReceiver, w.royaltyReceiver);
        (address receiver, uint256 amount) = wired.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, w.royaltyReceiver);
        assertEq(amount, uint256(w.royaltyRate) * 1 ether / Splits.DENOMINATOR);
        assertEq(terms.seller, w.seller);
        assertEq(terms.feeRecipient, w.feeRecipient);
        assertEq(terms.feeShare, w.feeShare);

        address deployed = splitFactory.createWallet(
            Splits.royaltyPayees(w.seller, w.feeRecipient, w.feeShare), bytes32(0)
        );
        assertEq(deployed, receiver);
    }

    /// @dev With the resolver's fee set to zero (and a zero recipient) the receiver is the
    ///      seller wallet; after a governed fee change, new works get the new receiver and
    ///      existing ones keep theirs.
    function test_receiverAtZeroFeeAndAfterAFeeChange() public {
        resolver.setFeeTerms(PRODUCT_STREAM, 1, address(0), 0);
        PackageItem memory item = _item(1);
        item.collectionId = wiredCollection;
        (uint256 tokenId, PrimaryTerms memory terms) = auction.start(wired, _request(item));
        WorkTerms memory w = resolver.newWorkTerms(PRODUCT_STREAM, item.payees);
        assertEq(w.feeShare, 0);
        assertEq(terms.feeRecipient, address(0));
        (address receiver,) = wired.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, w.royaltyReceiver);
        assertEq(receiver, w.seller);
        assertEq(wired.work(tokenId).royaltyReceiver, w.royaltyReceiver);

        address other = makeAddr("otherFee");
        resolver.setFeeTerms(PRODUCT_STREAM, 2, other, 12_345);
        PackageItem memory second = _item(2);
        second.collectionId = wiredCollection;
        (uint256 secondId,) = auction.start(wired, _request(second));
        WorkTerms memory w2 = resolver.newWorkTerms(PRODUCT_STREAM, second.payees);
        (address r2,) = wired.royaltyInfo(secondId, 1 ether);
        assertEq(r2, w2.royaltyReceiver);
        assertEq(
            r2,
            splitFactory.createWallet(Splits.royaltyPayees(w2.seller, other, 12_345), bytes32(0))
        );
        (receiver,) = wired.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, w.seller);
    }
}
