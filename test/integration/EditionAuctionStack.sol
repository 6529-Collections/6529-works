// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { CURRENCY_ETH, PRODUCT_EDITIONS } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionTerms, ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { UniformEditionAuctionLens } from "src/sales/UniformEditionAuctionLens.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice The edition auction on the real, wired v1 stack: the `UniformEditionAuction` that
///         `DeployV1` deploys against the deployment's 6529 Stream Editions, English auction and
///         revenue escrow, admitted as the edition minter and listed by the genesis wiring.
///         Shared by the end-to-end flows and the gas report.
abstract contract EditionAuctionStack is IntegrationBase {
    IUniformEditionAuction internal ea;

    function setUp() public virtual override {
        super.setUp();
        ea = IUniformEditionAuction(address(editionAuction));
        assertEq(
            keccak256(abi.encode(editionAuction.config())),
            keccak256(abi.encode(_editionConfig())),
            "the genesis parameters"
        );
    }

    /// @dev Another uniform auction against this stack, as an upgrade would deploy one: its lens
    ///      in its own deployment, then the adapter pinning it (F8). Not admitted or listed.
    function _newEditionAuction() internal returns (UniformEditionAuction) {
        address l = address(
            new UniformEditionAuctionLens(
                address(editions), address(stream), address(auction), address(escrow)
            )
        );
        return new UniformEditionAuction(
            address(manager),
            address(escrow),
            address(editions),
            address(auction),
            l,
            l.codehash,
            _editionConfig()
        );
    }

    /// @dev The launch parameters (ADR 0005 section 4).
    function _editionConfig() internal pure returns (IUniformEditionAuction.AuctionConfig memory) {
        return IUniformEditionAuction.AuctionConfig(
            1e14, 48, 336, 10_000, 15 minutes, 5 minutes, 1 days
        );
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
        // Settlement runs in calls of bounded gas: call until it is done.
        for (uint256 i; !editionAuction.settle(saleId, _orderFor(saleId, address(this))); ++i) {
            require(i < 64, "settlement does not advance");
        }
    }

    /// @dev What `settler` passes to its next settle call: the rest of its own sweep.
    function _orderFor(uint256 saleId, address settler) internal view returns (uint256[] memory) {
        return
            IUniformEditionAuctionLens(address(editionAuction)).settlementOrderFor(saleId, settler);
    }

    /// @dev The seller split wallet a master's edition pays (predicted, maybe undeployed).
    function _editionSeller(Work memory w) internal view returns (address) {
        return economics.newWorkTerms(PRODUCT_EDITIONS, w.item.payees).seller;
    }
}
