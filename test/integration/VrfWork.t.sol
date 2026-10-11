// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Flow 6 (integration brief, lane B): a VRF-seeded 1/1 on the real contracts, with the
///         entropy lane's VRF v2.5 coordinator mock. Anyone requests the seed for the approved,
///         unconsumed item; the coordinator delivers; only then can the auction start; and the
///         seed appears in the work's metadata, before and after its record opens.
contract VrfWorkFlowTest is IntegrationBase {
    address internal artist;
    address internal anyone = makeAddr("anyone");
    bytes32 internal root;
    bytes32 internal itemHash;

    function setUp() public override {
        super.setUp();
        artist = _actor("vrfArtist");
        Work[] memory works = new Work[](2);
        works[0] = _work(artist, collectionId);
        works[0].item.seedPolicy = SeedPolicy.VRF;
        works[1] = _work(artist, collectionId);
        works[1].item.seedPolicy = SeedPolicy.ARTIST;
        works[1].item.seed = keccak256("the artist's committed seed");
        root = _publish(works);
        _keep(root, works);
        itemHash = WorksHashing.itemHash(works[0].item);
    }

    function _request() internal returns (uint256 requestId) {
        Work[] memory works = _package(root);
        vm.prank(anyone);
        requestId = entropy.requestSeed(works[0].item, root, _proofOf(works, 0));
    }

    function test_SeedRequestedDeliveredThenStartedAndRendered() public {
        Work[] memory works = _package(root);
        bytes memory early = _mintData(root, works, 0);
        vm.expectRevert(abi.encodeWithSelector(IStream.SeedNotDelivered.selector, itemHash));
        auction.start(address(stream), early);

        uint256 requestId = _request();
        uint256 word = uint256(keccak256("chainlink randomness"));
        coordinator.fulfill(requestId, word);
        assertTrue(entropy.isDelivered(itemHash));
        assertEq(entropy.seedOf(itemHash), bytes32(word));

        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);
        assertEq(uint8(stream.work(tokenId).seedPolicy), uint8(SeedPolicy.VRF));
        string memory seedTrait =
            string.concat('{"trait_type":"Seed","value":"', Strings.toHexString(word, 32), '"}');
        assertTrue(
            _contains(stream.tokenURI(tokenId), seedTrait), "seed shown before the record opens"
        );
        records.openRecord(tokenId, works[0].item, works[0].media);
        (SeedPolicy policy, bytes32 seed) = records.seedOf(tokenId);
        assertEq(uint8(policy), uint8(SeedPolicy.VRF));
        assertEq(seed, bytes32(word));
        assertTrue(_contains(stream.tokenURI(tokenId), seedTrait), "and from the record");

        // A consumed item cannot draw again.
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.NotRequestable.selector, itemHash));
        _request();
        _ethBid(saleId, anyone, 1 ether);
        _settleAtEnd(saleId);
    }

    /// @dev VRF v2.5 never expires a request: a retry after 3 days adds a request, and the first
    ///      delivery wins; a late delivery of the first request is a no-op.
    function test_RetryAfterThreeDaysAndFirstDeliveryWins() public {
        uint256 first = _request();
        uint64 retryAt = uint64(block.timestamp + 3 days);
        Work[] memory works = _package(root);
        bytes32[] memory proof = _proofOf(works, 0);
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.RequestPending.selector, itemHash, retryAt)
        );
        entropy.requestSeed(works[0].item, root, proof);
        vm.warp(retryAt);
        uint256 second = _request();
        assertTrue(second != first);
        coordinator.fulfill(second, 2);
        coordinator.fulfill(first, 1);
        assertEq(entropy.seedOf(itemHash), bytes32(uint256(2)), "the first delivery wins");
        _start(root, works, 0);
    }

    function test_ArtistSeedAppearsOnceTheRecordOpens() public {
        Work[] memory works = _package(root);
        (, uint256 tokenId) = _start(root, works, 1);
        string memory seedTrait = string.concat(
            '{"trait_type":"Seed","value":"',
            Strings.toHexString(uint256(works[1].item.seed), 32),
            '"}'
        );
        assertFalse(_contains(stream.tokenURI(tokenId), seedTrait), "stored when the record opens");
        records.openRecord(tokenId, works[1].item, works[1].media);
        assertTrue(_contains(stream.tokenURI(tokenId), seedTrait));
    }
}
