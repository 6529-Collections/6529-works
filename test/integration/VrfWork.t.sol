// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { Work as StoredWork } from "src/interfaces/core/CoreTypes.sol";
import { SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { SaleFlowBase } from "./SaleFlowBase.sol";

/// @notice A seeded 1/1 on the deployed stack with the VRF entropy module (the Chainlink VRF v2.5
///         coordinator is the entropy lane's mock). Anyone requests the seed of an approved,
///         unconsumed VRF item; the coordinator delivers; only then can the sale start; the seed
///         is fixed in the work at mint and shown in its metadata. A request may be repeated only
///         after the retry delay, and the first delivery wins. An artist-seeded item carries its
///         committed seed. After an upheld dispute the rightful artist's VRF item reads the
///         content's one seed.
contract VrfWorkTest is SaleFlowBase {
    address internal artist;
    address internal anyone = makeAddr("anyone");
    bytes32 internal root;
    bytes32 internal itemHash;
    bytes32 internal constant ARTIST_SEED = keccak256("the artist's committed seed");

    function _withVrf() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        artist = _actor("vrfArtist");
        Work[] memory works = new Work[](2);
        works[0] = _work(artist, collectionId);
        works[0].item.seedPolicy = uint8(SeedPolicy.VRF);
        works[1] = _work(artist, collectionId);
        works[1].item.seedPolicy = uint8(SeedPolicy.ARTIST);
        works[1].item.seed = ARTIST_SEED;
        root = _publish(works);
        _keep(root, works);
        itemHash = WorksHashing.itemHash(works[0].item);
    }

    function _request() internal returns (uint256 requestId) {
        Work[] memory works = _package(root);
        vm.prank(anyone);
        requestId = entropy.requestSeed(works[0].item, root, _proofOf(works, 0));
    }

    function _seedTrait(bytes32 seed) internal pure returns (string memory) {
        return string.concat(
            '{"trait_type":"Seed","value":"', Strings.toHexString(uint256(seed), 32), '"}'
        );
    }

    function test_VrfWork_DeploymentWiresTheEntropyModule() public view {
        assertTrue(address(entropy) != address(0));
        assertEq(registry.entropyModule(), address(entropy));
        assertEq(entropy.coordinator(), address(coordinator));
        assertEq(entropy.retryDelay(), 3 days);
    }

    function test_VrfWork_SeedRequestedDeliveredThenStartedStoredAndRendered() public {
        Work[] memory works = _package(root);
        bytes memory early = _mintData(root, works, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.SeedNotDelivered.selector, itemHash)
        );
        auction.start(address(stream), early);

        uint256 requestId = _request();
        assertGt(requestId, 0);
        (uint256 pending,) = entropy.requestOf(itemHash);
        assertEq(pending, requestId);
        assertFalse(entropy.isDelivered(itemHash));
        bytes32 word = keccak256("chainlink randomness");
        coordinator.fulfill(requestId, uint256(word));
        assertTrue(entropy.isDelivered(itemHash));
        assertEq(entropy.seedOf(itemHash), word);

        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);
        StoredWork memory w = stream.workOf(tokenId);
        assertEq(w.seed, word, "the seed is fixed in the work at mint");
        assertEq(w.seedPolicy, uint8(SeedPolicy.VRF));
        assertTrue(_contains(stream.tokenURI(tokenId), _seedTrait(word)), "shown in metadata");
        _open(tokenId, works[0]);
        assertTrue(
            _contains(stream.tokenURI(tokenId), _seedTrait(word)), "and after the record opens"
        );

        // A consumed item cannot draw again.
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.NotRequestable.selector, itemHash));
        _request();
        _ethBid(saleId, anyone, 1 ether);
        _settleAtEnd(saleId);
        assertEq(stream.workOf(tokenId).seed, word, "the sale changes nothing");
    }

    /// @dev VRF v2.5 never expires a request: a repeat is refused until the retry delay has
    ///      passed, then adds a request; the first delivery wins and a late one is a no-op.
    function test_VrfWork_RetryAfterTheDelayAndTheFirstDeliveryWins() public {
        uint256 first = _request();
        uint64 retryAt = uint64(block.timestamp + 3 days);
        Work[] memory works = _package(root);
        bytes32[] memory proof = _proofOf(works, 0);
        vm.warp(retryAt - 1);
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.RequestPending.selector, itemHash, retryAt)
        );
        entropy.requestSeed(works[0].item, root, proof);
        vm.warp(retryAt);
        uint256 second = _request();
        assertTrue(second != first);
        (uint256 pending,) = entropy.requestOf(itemHash);
        assertEq(pending, second, "the newest request is the current one");
        coordinator.fulfill(second, 2);
        coordinator.fulfill(first, 1);
        assertEq(entropy.seedOf(itemHash), bytes32(uint256(2)), "the first delivery wins");
        (, uint256 tokenId) = _start(root, works, 0);
        assertEq(stream.workOf(tokenId).seed, bytes32(uint256(2)));
    }

    /// @dev An artist-seeded item mints with its committed seed, shown at once.
    function test_VrfWork_ArtistSeedIsStoredAndShown() public {
        Work[] memory works = _package(root);
        (, uint256 tokenId) = _start(root, works, 1);
        StoredWork memory w = stream.workOf(tokenId);
        assertEq(w.seed, ARTIST_SEED);
        assertEq(w.seedPolicy, uint8(SeedPolicy.ARTIST));
        assertTrue(_contains(stream.tokenURI(tokenId), _seedTrait(ARTIST_SEED)));
    }

    /// @dev The artist seed policy and the seed agree: an ARTIST item without a seed, or a
    ///      NONE item with one, is refused at the start.
    function test_VrfWork_ArtistSeedPolicyMustMatchTheSeed() public {
        Work[] memory works = new Work[](2);
        works[0] = _work(artist, collectionId);
        works[0].item.seedPolicy = uint8(SeedPolicy.ARTIST);
        works[1] = _work(artist, collectionId);
        works[1].item.seed = ARTIST_SEED;
        bytes32 badRoot = _publish(works);
        for (uint256 i; i < 2; ++i) {
            bytes memory data = _mintData(badRoot, works, i);
            vm.expectRevert(IPackageRegistry.InvalidSeedPolicy.selector);
            auction.start(address(stream), data);
        }
    }

    /// @dev After an upheld dispute burns a VRF copy, the rightful artist's VRF item cannot
    ///      request while the content is consumed; after the release it joins the content's
    ///      delivered draw, with no new request, and mints with that seed.
    function test_VrfWork_TheRightfulItemReadsTheContentsSeedAfterADispute() public {
        address rightful = _actor("rightfulVrfArtist");
        Work memory original = _work(rightful, collectionId);
        original.item.seedPolicy = uint8(SeedPolicy.VRF);
        Work memory copy = _work(_actor("vrfCopier"), collectionId);
        copy.media = original.media;
        copy.item.contentHash = original.item.contentHash;
        copy.item.mediaHash = original.item.mediaHash;
        copy.item.seedPolicy = uint8(SeedPolicy.VRF);
        bytes32 copyRoot = _publish(_one(copy));
        bytes32 originalRoot = _publish(_one(original));
        bytes32[] memory none = new bytes32[](0);
        coordinator.fulfill(entropy.requestSeed(copy.item, copyRoot, none), 77);

        (uint256 saleId, uint256 tokenId) = _start(copyRoot, _one(copy), 0);
        bytes32 originalItem = WorksHashing.itemHash(original.item);
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.NotRequestable.selector, originalItem)
        );
        entropy.requestSeed(original.item, originalRoot, none);

        _upholdAndRelease(saleId, tokenId, original.item.contentHash, rightful);

        uint256 nextId = coordinator.nextId();
        assertEq(entropy.requestSeed(original.item, originalRoot, none), 0, "joined");
        assertEq(coordinator.nextId(), nextId, "no second draw");
        assertEq(entropy.seedOf(originalItem), bytes32(uint256(77)));
        (, uint256 rightfulToken) = _start(originalRoot, _one(original), 0);
        assertEq(stream.workOf(rightfulToken).seed, bytes32(uint256(77)), "the content's one seed");
    }

    /// @dev Pauses the sale, records an upheld outcome, cancels it and releases the content to
    ///      `rightful`.
    function _upholdAndRelease(
        uint256 saleId,
        uint256 tokenId,
        bytes32 contentHash,
        address rightful
    ) internal {
        _govern(
            pauser1,
            address(auction),
            abi.encodeWithSignature("pause(uint256,bytes32)", saleId, keccak256("copied media"))
        );
        bytes32 outcome = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://vrf-dispute-upheld"
        );
        _asNetwork(address(auction), abi.encodeCall(auction.cancel, (saleId, outcome)));
        _asNetwork(
            address(registry),
            abi.encodeCall(
                registry.releaseContent,
                (address(stream), tokenId, contentHash, accounts.artistIdOf(rightful))
            )
        );
    }
}

/// @notice Without the entropy module, a VRF item is refused at the start.
contract VrfAbsentTest is SaleFlowBase {
    function test_VrfWork_AVrfItemIsRefusedWithoutTheEntropyModule() public {
        assertEq(registry.entropyModule(), address(0));
        Work memory w = _work(_actor("artist"), collectionId);
        w.item.seedPolicy = uint8(SeedPolicy.VRF);
        Work[] memory works = _one(w);
        bytes32 root = _publish(works);
        bytes memory data = _mintData(root, works, 0);
        vm.expectRevert(IPackageRegistry.InvalidSeedPolicy.selector);
        auction.start(address(stream), data);
    }
}
