// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { EditionTerms, ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { EditionsAdapterMock } from "../mocks/editions/EditionsMocks.sol";
import { ReplayBase } from "./ReplayBase.sol";

/// @notice Log replay of 6529 Stream Editions (ED-5, ED-7, ED-25 to ED-27, INV-ED-2, INV-ED-5,
///         INV-ED-6): a history that emits every event it can rebuilds, from its logs alone,
///         each edition's terms, bound adapter, locked economics, rate, minted count, sealed
///         supply and holders.
/// @dev The editions are sold by an adapter admitted by governance (a reduced stand-in for a
///      sale adapter, `EditionsAdapterMock`), so the history reaches burns and a bind before
///      creation that the genesis edition auction does not; the edition auction's own flows
///      are in `test/integration/EditionAuction*.t.sol`.
contract LogReplayEditionsTest is ReplayBase {
    address internal artist;
    address internal buyer = makeAddr("editionBuyer");
    address internal friend = makeAddr("editionFriend");
    address internal collector = makeAddr("masterCollector");
    bytes32 internal root;
    EditionsAdapterMock internal adapter;

    function setUp() public override {
        super.setUp();
        artist = _actor("editionArtist");
        Work[] memory works = new Work[](3);
        for (uint256 i; i < 3; ++i) {
            works[i] = _work(artist, collectionId);
            works[i].item.kind = uint8(ItemKind.EDITION_MASTER);
            works[i].item.edition =
                EditionTerms(i == 1 ? 0 : 50, address(0), SaleKind.UNIFORM_AUCTION, "");
        }
        root = _publish(works);
        _keep(root, works);
        adapter = new EditionsAdapterMock(SaleKind.UNIFORM_AUCTION);
        _sync();
    }

    function test_EveryEditionsEventReplaysToTheSameState() public {
        Work[] memory works = _package(root);
        uint256 m0 = _sell(root, works, 0, collector, 1 ether);
        uint256 m1 = _sell(root, works, 1, collector, 1 ether);
        uint256 m2 = _sell(root, works, 2, collector, 1 ether);
        _govern(
            hotAdmin,
            address(editions),
            abi.encodeCall(editions.setAdmittedMinter, (address(adapter), true))
        );
        editions.createEdition(m0, works[0].item);
        editions.createEdition(m1, works[1].item);
        _sync();

        // Mints bind the edition to the adapter (ED-5); copies it holds can be burned.
        adapter.buy(editions, m0, buyer, 3);
        adapter.buy(editions, m1, buyer, 2);
        adapter.buy(editions, m0, address(adapter), 2);
        adapter.burnHeld(editions, m0, 1);
        _sync();
        vm.startPrank(buyer);
        editions.safeTransferFrom(buyer, friend, m0, 1, "");
        editions.setApprovalForAll(friend, true);
        vm.stopPrank();
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        (ids[0], ids[1], amounts[0], amounts[1]) = (m0, m1, 1, 2);
        vm.prank(friend);
        editions.safeBatchTransferFrom(buyer, friend, ids, amounts, "");
        adapter.seal(editions, m0, 10);
        _sync();

        // A bind and a seal at zero before the edition exists (the sale sold nothing).
        adapter.bind(editions, m2, works[2].item);
        adapter.seal(editions, m2, 0);
        _sync();
        editions.createEdition(m2, works[2].item);
        _sync();
        assertEq(editions.edition(m2).maxSupply, 0);

        // The master re-rated with every party's consent: the edition follows (ED-7).
        records.openRecord(m0, works[0].item, works[0].media);
        _govern(hotAdmin, address(records), _rerateCall(m0, 3_000));
        _govern(hotAdmin, address(editions), abi.encodeCall(editions.lowerFeeShare, (m0, 1_000)));
        _govern(
            hotAdmin, address(editions), abi.encodeCall(editions.setContractURI, ("ar://editions"))
        );
        _govern(
            hotAdmin,
            address(editions),
            abi.encodeCall(editions.setOwner, (marketOwner, makeAddr("nextEditionsOwner")))
        );
        _sync();
        // A preferred-kind change refreshes every edition (`BatchMetadataUpdate`).
        vm.prank(storageOperator);
        delivery.setPreferredKind(LocatorKind.IPFS);
        _govern(
            hotAdmin,
            address(editions),
            abi.encodeCall(editions.setAdmittedMinter, (address(adapter), false))
        );
        _sync();
        // A removed adapter still mints an edition it sealed, never one it did not.
        adapter.buy(editions, m0, buyer, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(adapter))
        );
        adapter.buy(editions, m1, buyer, 1);
        _sync();
        _assertEveryEventReplayed("Editions", editionsIdx, _list("URI(string,uint256)"));
    }

    function _rerateCall(uint256 tokenId, uint32 rate) internal view returns (bytes memory) {
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes32 structHash =
            keccak256(abi.encode(Typehashes.ROYALTY_RATE_CHANGE, tokenId, rate, state, deadline));
        bytes[] memory sigs = new bytes[](1);
        sigs[0] =
            abi.encodePacked(artist, _sign(artist, _typedDigest(address(records), structHash)));
        return abi.encodeCall(
            records.setRoyaltyRate, (tokenId, rate, _package(root)[0].item, state, deadline, sigs)
        );
    }

    /// @dev Negative control: slot 6 holds the marketplace owner (and the minter count above
    ///      it); a value no log explains makes the comparison fail.
    function test_IndexerDetectsStateThatLogsDoNotExplain() public {
        editionsIdx.assertMatches();
        vm.store(address(editions), bytes32(uint256(6)), bytes32(uint256(uint160(buyer))));
        vm.expectRevert();
        editionsIdx.assertMatches();
    }
}
