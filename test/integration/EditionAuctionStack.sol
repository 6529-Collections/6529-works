// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { CURRENCY_ETH, PRODUCT_EDITIONS } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionTerms, ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice The edition auction on the real, wired v1 stack: `UniformEditionAuction` deployed
///         against the deployment's 6529 Stream Editions, English auction and revenue escrow,
///         admitted as an edition minter and listed through governance, as genesis does. Shared
///         by the end-to-end flows and the gas report.
/// @dev Until the deploy wiring (L3) lists the adapter in `DeployV1`, this fixture deploys it and
///      runs the two governed wiring calls itself (`Editions.setAdmittedMinter` and `setTarget`),
///      warping their delays in `setUp`, before any sale starts.
abstract contract EditionAuctionStack is IntegrationBase {
    UniformEditionAuction internal editionAuction;
    IUniformEditionAuction internal ea;

    function setUp() public virtual override {
        super.setUp();
        editionAuction = new UniformEditionAuction(
            address(manager), address(escrow), address(editions), address(auction), _editionConfig()
        );
        ea = IUniformEditionAuction(address(editionAuction));
        _govern(
            hotAdmin,
            address(editions),
            abi.encodeCall(editions.setAdmittedMinter, (address(editionAuction), true))
        );
        _govern(
            hotAdmin,
            address(editionAuction),
            abi.encodeCall(editionAuction.setTarget, (address(editions), true))
        );
    }

    /// @dev The launch parameters (ADR 0005 section 4).
    function _editionConfig() internal pure returns (IUniformEditionAuction.AuctionConfig memory) {
        return IUniformEditionAuction.AuctionConfig(
            1e14, 48, 336, 10_000, 15 minutes, 5 minutes, 1 days
        );
    }

    /// @dev The adapter is measured like every deployed contract (the lens has no storage).
    function _cooled() internal view virtual override returns (address[] memory all) {
        address[] memory base = super._cooled();
        all = new address[](base.length + 2);
        for (uint256 i; i < base.length; ++i) {
            all[i] = base[i];
        }
        all[base.length] = address(editionAuction);
        all[base.length + 1] = editionAuction.lens();
    }

    /// @dev An EDITION_MASTER work by `lead` whose edition is sold by the uniform auction, in ETH,
    ///      capped at `maxCount` (zero for none).
    function _masterWork(address lead, uint32 maxCount) internal returns (Work memory w) {
        w = _work(lead, collectionId);
        w.item.kind = ItemKind.EDITION_MASTER;
        w.item.edition = EditionTerms(maxCount, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
    }

    /// @dev Publishes a one-item package of a master, starts its 1/1 and opens its edition sale.
    function _startMaster(address lead, uint32 maxCount)
        internal
        returns (bytes32 root, Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId)
    {
        w = _masterWork(lead, maxCount);
        Work[] memory works = _one(w);
        root = _publish(works);
        (oneSaleId, tokenId) = _start(root, works, 0);
        saleId = editionAuction.open(address(editions), tokenId, abi.encode(w.item));
    }

    function _editionBid(uint256 saleId, address bidder, uint256 step, uint256 quantity)
        internal
        returns (uint256 bidId)
    {
        uint256 amount = quantity * ea.stepPrice(saleId, step);
        vm.deal(bidder, bidder.balance + amount);
        vm.prank(bidder);
        bidId = editionAuction.bid{ value: amount }(saleId, step, quantity);
        // A bidder has sent a transaction, so its account is never empty: a refund to it never
        // pays for a new account (a prank leaves the nonce at zero).
        if (vm.getNonce(bidder) == 0) vm.setNonce(bidder, 1);
    }

    /// @dev Settles the 1/1 at its end and creates the edition (both permissionless, as the
    ///      keeper batches them).
    function _settleOneOfOneAndCreate(uint256 oneSaleId, bytes32 root, Work memory w) internal {
        _settleAtEnd(oneSaleId);
        uint256 tokenId = auction.auction(oneSaleId).tokenId;
        editions.createEdition(tokenId, w.item, root, _proofOf(_one(w), 0));
    }

    /// @dev Warps to the edition close and settles with the lens's order.
    function _settleEditions(uint256 saleId) internal {
        IUniformEditionAuction.EndTimes memory e = ea.endTimes(saleId);
        if (block.timestamp < e.endTime) vm.warp(e.endTime);
        assertTrue(editionAuction.settle(saleId, ea.settlementOrder(saleId)), "settled");
    }

    /// @dev The seller split wallet a master's edition pays (predicted, maybe undeployed).
    function _editionSeller(Work memory w) internal view returns (address) {
        return economics.newWorkTerms(PRODUCT_EDITIONS, w.item.payees).seller;
    }
}
