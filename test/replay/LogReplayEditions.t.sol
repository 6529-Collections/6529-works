// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { UniformEditionAuctionLens } from "src/sales/UniformEditionAuctionLens.sol";
import { MockSale } from "../mocks/core/CoreMocks.sol";
import { ReplayBase } from "./ReplayBase.sol";
import { ReplayEvents } from "./ReplayEvents.sol";

/// @notice Log replay of 6529 Stream Editions on the deployed stack, from its deployment on: a
///         history that emits every event it can emit (editions opened by the uniform edition
///         auction during their masters' sales, bids settled, sealed and claimed, single and
///         batch transfers, an operator approval, a burn, a royalty change through the rules
///         module, single and batch metadata refreshes, the network's settings and modules, a
///         minter removed and an unminted edition rebound to a new one) rebuilds every getter
///         from Editions' logs alone, and the rebuilt values match after each step.
/// @dev `URI` is declared by ERC-1155 and never emitted (the renderer answers `uri`).
contract LogReplayEditionsTest is ReplayBase {
    address internal artist;
    address internal collector = makeAddr("editionCollector");
    address internal second = makeAddr("editionSecond");
    address internal operator = makeAddr("editionOperator");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("editionArtist");
        Work[] memory works = new Work[](3);
        for (uint256 i; i < 3; ++i) {
            works[i] = _asMaster(_work(artist, collectionId), 10);
        }
        root = _publish(works);
        _keep(root, works);
        _sync();
    }

    /// @dev Starts master `index`'s 1/1 sale and opens its edition sale; returns both sale IDs
    ///      and the master's token ID (the edition ID).
    function _openEdition(uint256 index)
        internal
        returns (uint256 oneOfOne, uint256 editionSale, uint256 id)
    {
        Work[] memory works = _package(root);
        (oneOfOne, id) = _start(root, works, index);
        editionSale = editionAuction.open(
            address(editions), id, abi.encode(works[index].item, root, _proofOf(works, index))
        );
    }

    function _bid(uint256 saleId, address bidder, uint256 quantity) internal {
        // The lens reads the auction's storage: its views are served through the auction.
        uint256 amount =
            quantity * UniformEditionAuctionLens(address(editionAuction)).stepPrice(saleId, 0);
        vm.deal(bidder, bidder.balance + amount);
        vm.prank(bidder);
        editionAuction.bid{ value: amount }(saleId, 0, quantity);
    }

    function _settleEdition(uint256 saleId) internal {
        for (uint256 i; i < 20; ++i) {
            if (editionAuction.settle(saleId, new uint256[](0))) return;
        }
        revert("edition sale did not settle");
    }

    function test_Editions_EveryEventReplaysToTheSameState() public {
        Work[] memory works = _package(root);
        // Two editions opened beside their masters' sales, bid on, settled and claimed; the
        // third opened and never bid on.
        (uint256 oneA, uint256 saleA, uint256 a) = _openEdition(0);
        (uint256 oneB, uint256 saleB, uint256 b) = _openEdition(1);
        (uint256 oneC,, uint256 c) = _openEdition(2);
        _sync();
        _bid(saleA, collector, 3);
        _bid(saleB, collector, 2);
        _settleAtEnd(oneA);
        auction.settle(oneB);
        auction.settle(oneC);
        skip(1 hours);
        _settleEdition(saleA);
        _settleEdition(saleB);
        _sync();
        vm.startPrank(collector);
        editionAuction.claimBid(saleA, 1, collector);
        editionAuction.claimBid(saleB, 1, collector);
        vm.stopPrank();
        _sync();
        assertTrue(editions.editionOf(a).supplySealed, "sealed at settlement");
        assertEq(editions.balanceOf(collector, a), 3);

        // Transfers, an operator approval and a burn.
        vm.startPrank(collector);
        editions.safeTransferFrom(collector, second, a, 1, "");
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        (ids[0], ids[1], amounts[0], amounts[1]) = (a, b, 1, 1);
        editions.safeBatchTransferFrom(collector, second, ids, amounts, "");
        editions.setApprovalForAll(operator, true);
        vm.stopPrank();
        vm.prank(second);
        editions.burn(b, 1);
        _sync();

        // The master's royalty change reaches its edition; finalize refreshes both tokens.
        _open(a, works[0]);
        _setRoyaltyRate(a, works[0], 8_000);
        _sync();
        assertEq(editions.editionOf(a).royaltyRate, 8_000);
        bytes32 state = rules.workStateHash(address(stream), a);
        vm.prank(artist);
        rules.finalize(address(stream), a, state);
        _govern(
            storageOperator,
            address(delivery),
            abi.encodeCall(delivery.setPreferredKind, (address(stream), LocatorKind.ARWEAVE))
        );
        _sync();

        // The network's settings, the owner and the TERMS slot announced and installed again.
        _asNetwork(address(editions), abi.encodeCall(editions.setContractURI, ("ar://editions")));
        _asNetwork(address(editions), abi.encodeCall(editions.setOwner, (makeAddr("edOwner"))));
        _asNetwork(address(editions), abi.encodeCall(editions.setRebindDelay, (2 days)));
        _asNetwork(address(editions), abi.encodeCall(editions.setModuleDelay, (1 days)));
        _asNetwork(
            address(editions), abi.encodeCall(editions.proposeModule, (Slots.TERMS, address(terms)))
        );
        _sync();
        skip(1 days);
        editions.activateModule(Slots.TERMS);
        _sync();

        // The edition auction removed as a minter; after the rebind delay the unminted edition
        // moves to a newly added minter, and the auction is added again.
        MockSale next = new MockSale();
        _asNetwork(
            address(editions), abi.encodeCall(editions.removeMinter, (address(editionAuction)))
        );
        _asNetwork(address(editions), abi.encodeCall(editions.addMinter, (address(next))));
        _sync();
        skip(2 days);
        _asNetwork(address(editions), abi.encodeCall(editions.rebind, (c, address(next))));
        _asNetwork(address(editions), abi.encodeCall(editions.addMinter, (address(editionAuction))));
        _sync();
        next.mintEdition(address(editions), collector, c, 2, 0);
        _sync();
        assertEq(editions.editionOf(c).minter, address(next));

        _assertEveryEventReplayed(
            "Editions", editionsIdx, ReplayEvents.editions(), _list("URI(string,uint256)")
        );
    }

    // ------------------------------------------------------------------ negative controls

    /// @dev Slot 4 holds the contract URI: a value no `ContractURISet` logged.
    function test_Editions_ReplayFailsOnStateNoLogExplains() public {
        editionsIdx.assertMatches();
        vm.store(address(editions), bytes32(uint256(4)), bytes32(uint256(0x41 << 248 | 2)));
        vm.expectRevert();
        editionsIdx.assertMatches();
    }

    /// @dev A claim whose `TransferSingle` log is dropped: the rebuilt balance is stale.
    function test_Editions_ReplayFailsOnADroppedLog() public {
        (uint256 one, uint256 sale, uint256 a) = _openEdition(0);
        _bid(sale, collector, 2);
        _settleAtEnd(one);
        skip(1 hours);
        _settleEdition(sale);
        _sync();
        vm.prank(collector);
        editionAuction.claimBid(sale, 1, collector);
        _apply(_dropOne(address(editions), IERC1155.TransferSingle.selector));
        vm.expectRevert(bytes("balanceOf: 2 != 0"));
        editionsIdx.assertMatches();
        assertEq(editions.balanceOf(collector, a), 2);
        assertGt(editionsIdx.seen(IEditions.EditionMinted.selector), 0);
    }
}
