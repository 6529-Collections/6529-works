// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { CURRENCY_DEFAULT } from "src/interfaces/types/EconomicsTypes.sol";
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

    /// @dev A revision of the VRF item, approved in its own root: the same content, media,
    ///      record and parties, a different item hash (the sale currency spelled as the default).
    function _revision() internal returns (bytes32 revisionRoot, bytes32 revisionItem) {
        Work memory w = _package(root)[0];
        w.item.sale.currency = CURRENCY_DEFAULT;
        revisionRoot = _publish(_one(w));
        _keep(revisionRoot, _one(w));
        revisionItem = WorksHashing.itemHash(w.item);
        assertTrue(revisionItem != itemHash, "a different item of the same content");
    }

    function _requestRevision(bytes32 revisionRoot) internal returns (uint256 requestId) {
        Work[] memory revision = _package(revisionRoot);
        vm.prank(anyone);
        requestId = entropy.requestSeed(revision[0].item, revisionRoot, _proofOf(revision, 0));
    }

    /// @dev One seed per work, whatever package lists it: a revision approved after the seed was
    ///      delivered joins the content's draw, and the coordinator is not asked again.
    function test_ARevisionOfTheWorkReadsTheSameSeed() public {
        uint256 word = uint256(keccak256("the work's one draw"));
        coordinator.fulfill(_request(), word);
        (bytes32 revisionRoot, bytes32 revisionItem) = _revision();
        uint256 nextId = coordinator.nextId();

        assertEq(_requestRevision(revisionRoot), 0, "joined, not requested");
        assertEq(coordinator.nextId(), nextId, "the coordinator was not asked");
        assertTrue(entropy.isDelivered(revisionItem));
        assertEq(entropy.seedOf(revisionItem), bytes32(word));
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.SeedAlreadyDelivered.selector, revisionItem)
        );
        _requestRevision(revisionRoot);

        Work[] memory revision = _package(revisionRoot);
        (, uint256 tokenId) = _start(revisionRoot, revision, 0);
        records.openRecord(tokenId, revision[0].item, revision[0].media);
        (SeedPolicy policy, bytes32 seed) = records.seedOf(tokenId);
        assertEq(uint8(policy), uint8(SeedPolicy.VRF));
        assertEq(seed, bytes32(word), "the token carries the work's one draw");
    }

    /// @dev A revision approved while the draw is pending joins it too: one delivery seeds both
    ///      items, and the revision may repeat only when the content's request is overdue.
    function test_ARevisionJoinsAPendingDraw() public {
        uint256 first = _request();
        (bytes32 revisionRoot, bytes32 revisionItem) = _revision();
        assertEq(_requestRevision(revisionRoot), 0, "joined the pending draw");
        assertFalse(entropy.isDelivered(revisionItem));
        (uint256 pendingId,) = entropy.requestOf(revisionItem);
        assertEq(pendingId, first, "the content's pending request");
        uint64 retryAt = uint64(block.timestamp + 3 days);
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.RequestPending.selector, revisionItem, retryAt)
        );
        _requestRevision(revisionRoot);

        coordinator.fulfill(first, 7);
        assertEq(entropy.seedOf(revisionItem), bytes32(uint256(7)));
        assertEq(entropy.seedOf(itemHash), bytes32(uint256(7)));
    }
}
