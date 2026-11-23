// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DeployCore } from "script/DeployCore.sol";
import { Roles } from "src/governance/Roles.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { PRODUCT_EDITIONS } from "src/interfaces/types/EconomicsTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { UniformEditionAuctionLens } from "src/sales/UniformEditionAuctionLens.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice The edition auction on the deployed plain-core stack: the `UniformEditionAuction`
///         that `DeployCore` deploys against 6529 Stream Editions, the English auction and the
///         revenue escrow, a genesis minter of Editions and listed by the genesis wiring. Shared
///         by the edition suites of this directory.
/// @dev `open` creates the edition (`StreamEditions6529.create`), so a master's edition exists from
///      the open of its sale; the clearing seals it at the count sold.
abstract contract EditionAuctionStack is IntegrationBase {
    /// @dev The adapter's views, answered by its lens through its fallback.
    IUniformEditionAuction internal ea;
    /// @dev The same address, for the lens-only views (`settlementOrderFor`, `claimable`).
    IUniformEditionAuctionLens internal eaLens;

    function setUp() public virtual override {
        super.setUp();
        ea = IUniformEditionAuction(address(editionAuction));
        eaLens = IUniformEditionAuctionLens(address(editionAuction));
        assertEq(
            keccak256(abi.encode(ea.config())),
            keccak256(abi.encode(_editionConfig())),
            "the genesis parameters"
        );
    }

    // ------------------------------------------------------------------ the genesis parameters

    function _editionConfig()
        internal
        pure
        returns (IUniformEditionAuction.AuctionConfig memory c)
    {
        (c,) = abi.decode(
            DeployCore.editionAuctionConfig(),
            (IUniformEditionAuction.AuctionConfig, IUniformEditionAuction.Limits)
        );
    }

    function _editionLimits() internal pure returns (IUniformEditionAuction.Limits memory l) {
        (, l) = abi.decode(
            DeployCore.editionAuctionConfig(),
            (IUniformEditionAuction.AuctionConfig, IUniformEditionAuction.Limits)
        );
    }

    // ------------------------------------------------------------------ masters

    /// @dev An EDITION_MASTER work by `lead`, its edition sold by the uniform auction in ETH,
    ///      capped at `maxCount` (zero for none).
    function _masterWork(address lead, uint32 maxCount) internal returns (Work memory) {
        return _asMaster(_work(lead, collectionId), maxCount);
    }

    /// @dev 6529 Stream Editions' open data: item `index` of `works` under `root`, the root and
    ///      the item's proof.
    function _openData(bytes32 root, Work[] memory works, uint256 index)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(works[index].item, root, _proofOf(works, index));
    }

    /// @dev The open data of a master published as a one-item package.
    function _openData(Work memory w) internal pure returns (bytes memory) {
        Work[] memory works = _one(w);
        return _openData(_rootOf(works), works, 0);
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
        saleId = editionAuction.open(address(editions), tokenId, _openData(root, works, 0));
        assertEq(saleId, ea.saleIdOf(address(editions), tokenId), "sale ID");
    }

    /// @dev Publishes a master and starts its 1/1 without opening its edition sale.
    function _startUnopened(address lead, uint32 maxCount)
        internal
        returns (Work memory w, uint256 oneSaleId, uint256 tokenId)
    {
        w = _masterWork(lead, maxCount);
        bytes32 root = _publish(_one(w));
        (oneSaleId, tokenId) = _start(root, _one(w), 0);
    }

    // ------------------------------------------------------------------ bidding and settlement

    function _editionBid(uint256 saleId, address bidder, uint256 step, uint256 quantity)
        internal
        returns (uint256 bidId)
    {
        uint256 amount = quantity * ea.stepPrice(saleId, step);
        vm.deal(bidder, bidder.balance + amount);
        vm.prank(bidder);
        bidId = editionAuction.bid{ value: amount }(saleId, step, quantity);
        // A bidder has sent a transaction, so its account is never empty.
        if (vm.getNonce(bidder) == 0) vm.setNonce(bidder, 1);
    }

    function _editionRaise(uint256 saleId, uint256 bidId, uint256 newStep) internal {
        IUniformEditionAuction.Bid memory b = ea.bidOf(saleId, bidId);
        uint256 cost =
            uint256(b.quantity) * (ea.stepPrice(saleId, newStep) - ea.stepPrice(saleId, b.step));
        vm.deal(b.bidder, b.bidder.balance + cost);
        vm.prank(b.bidder);
        editionAuction.raise{ value: cost }(saleId, bidId, newStep);
    }

    /// @dev Warps to the edition close if needed and settles with the lens's order, call after
    ///      call until done.
    function _settleEditions(uint256 saleId) internal {
        _settleEditionsOn(editionAuction, saleId);
    }

    function _settleEditionsOn(UniformEditionAuction adapter, uint256 saleId) internal {
        IUniformEditionAuction view_ = IUniformEditionAuction(address(adapter));
        IUniformEditionAuction.EndTimes memory e = view_.endTimes(saleId);
        if (block.timestamp < e.endTime) vm.warp(e.endTime);
        IUniformEditionAuctionLens l = IUniformEditionAuctionLens(address(adapter));
        for (uint256 i; !adapter.settle(saleId, l.settlementOrderFor(saleId, address(this))); ++i) {
            require(i < 64, "settlement does not advance");
        }
    }

    /// @dev What `settler` passes to its next settle call: the rest of its own sweep.
    function _orderFor(uint256 saleId, address settler) internal view returns (uint256[] memory) {
        return eaLens.settlementOrderFor(saleId, settler);
    }

    /// @dev The seller split wallet a master's edition pays.
    function _editionSeller(Work memory w) internal view returns (address) {
        return economics.newWorkTerms(PRODUCT_EDITIONS, w.item.payees).seller;
    }

    /// @dev The royalty receiver split wallet a master's new edition records.
    function _editionRoyalty(Work memory w) internal view returns (address) {
        return economics.newWorkTerms(PRODUCT_EDITIONS, w.item.payees).royaltyReceiver;
    }

    // ------------------------------------------------------------------ disputes

    /// @dev A pauser pauses the 1/1 for a dispute, the platform records the upheld outcome and
    ///      the network cancels the 1/1 (the token is burned).
    function _cancelOneOfOne(uint256 oneSaleId, uint256 tokenId) internal {
        _pauseOneOfOne(oneSaleId);
        bytes32 outcome = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://upheld"
        );
        _asNetwork(address(auction), abi.encodeCall(auction.cancel, (oneSaleId, outcome)));
    }

    /// @dev A pauser (PAUSER, no delay) pauses the 1/1 for a dispute.
    function _pauseOneOfOne(uint256 oneSaleId) internal {
        _govern(
            pauser1,
            address(auction),
            abi.encodeWithSignature("pause(uint256,bytes32)", oneSaleId, bytes32("dispute"))
        );
    }

    // ------------------------------------------------------------------ another adapter

    /// @dev Another uniform auction against this stack, as a replacement would be deployed: its
    ///      lens in its own deployment, then the adapter pinning it. Not a minter, not listed.
    function _newEditionAuction() internal returns (UniformEditionAuction) {
        address l = address(
            new UniformEditionAuctionLens(
                address(editions),
                address(stream),
                address(auction),
                address(escrow),
                address(directory),
                address(economics),
                address(registry)
            )
        );
        return new UniformEditionAuction(
            address(manager),
            address(escrow),
            address(directory),
            address(editions),
            address(auction),
            l,
            l.codehash,
            _editionConfig(),
            _editionLimits()
        );
    }

    /// @dev Deploys another adapter and wires it as the network would: `adopt` and `setTarget`
    ///      mapped to the NETWORK role, listed, and added as an Editions minter, active after the
    ///      network's `moduleDelay` (waited out here).
    function _wiredEditionAuction() internal returns (UniformEditionAuction a) {
        a = _newEditionAuction();
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = a.adopt.selector;
        selectors[1] = a.setTarget.selector;
        _asNetwork(
            address(manager),
            abi.encodeCall(manager.setTargetFunctionRole, (address(a), selectors, Roles.NETWORK))
        );
        _asNetwork(address(a), abi.encodeCall(a.setTarget, (address(editions), true)));
        _asNetwork(address(editions), abi.encodeCall(editions.addMinter, (address(a))));
        vm.warp(block.timestamp + editions.moduleDelay());
        assertTrue(editions.isMinter(address(a)), "the new adapter mints");
    }
}
