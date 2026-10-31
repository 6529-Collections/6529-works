// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionTerms, ItemKind, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @dev A replacement dependency that only reports its interface: any other call reverts, so a
///      read of it on a measured path fails loudly instead of returning plausible data.
contract DependencyStandIn is IERC165 {
    bytes4 internal immutable _id;

    constructor(bytes4 id) {
        _id = id;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return interfaceId == _id || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Owner decision 16 on the real genesis deployment: Stream's package registry, artist
///         registry, economics resolver and entropy module are replaceable by governance in the
///         30-day class, and 6529 Stream Editions and the work-records satellite follow at once.
///         Existing tokens are unaffected: their owner, the metadata of a finalized work (a VRF
///         work's seed is fixed when its record opens) and their royalty info are byte for byte
///         the same after every replacement, which reads none of the replaced contracts.
contract StreamDependenciesTest is IntegrationBase {
    bytes32[4] internal KINDS =
        [bytes32("PACKAGE_REGISTRY"), "ARTIST_REGISTRY", "ECONOMICS", "ENTROPY_MODULE"];

    address internal artist;
    address internal collector = makeAddr("dependencyCollector");
    uint256[] internal tokens;
    uint256 internal editionId;

    function setUp() public override {
        super.setUp();
        artist = _actor("dependencyArtist");
        Work[] memory works = new Work[](3);
        works[0] = _work(artist, collectionId);
        works[1] = _work(artist, collectionId);
        works[1].item.seedPolicy = SeedPolicy.VRF;
        works[2] = _work(artist, collectionId);
        works[2].item.kind = ItemKind.EDITION_MASTER;
        works[2].item.edition = EditionTerms(0, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        bytes32 root = _publish(works);
        _keep(root, works);
        // The VRF work's seed is requested and delivered before its start.
        uint256 requestId = entropy.requestSeed(works[1].item, root, _proofOf(works, 1));
        coordinator.fulfill(requestId, uint256(keccak256("seed")));
        for (uint256 i; i < works.length; ++i) {
            uint256 tokenId = _sell(root, works, i, collector, 1 ether);
            tokens.push(tokenId);
            records.openRecord(tokenId, works[i].item, works[i].media);
            bytes32 state = records.workStateHash(tokenId);
            vm.prank(artist);
            records.finalize(tokenId, state);
        }
        editionId = editions.createEdition(tokens[2], works[2].item, root, _proofOf(works, 2));
    }

    function _interfaceOf(bytes32 kind) internal pure returns (bytes4) {
        if (kind == "PACKAGE_REGISTRY") return type(IPackageRegistry).interfaceId;
        if (kind == "ARTIST_REGISTRY") return type(IArtistRegistry).interfaceId;
        if (kind == "ECONOMICS") return type(IEconomicsResolver).interfaceId;
        return type(IEntropyModule).interfaceId;
    }

    function _current(bytes32 kind) internal view returns (address) {
        if (kind == "PACKAGE_REGISTRY") return stream.packageRegistry();
        if (kind == "ARTIST_REGISTRY") return stream.artistRegistry();
        if (kind == "ECONOMICS") return stream.economics();
        return stream.entropyModule();
    }

    /// @dev Everything an existing token shows the world.
    function _snapshot() internal view returns (bytes32) {
        bytes memory all;
        for (uint256 i; i < tokens.length; ++i) {
            (address receiver, uint256 amount) = stream.royaltyInfo(tokens[i], 1 ether);
            all = abi.encode(
                all, stream.ownerOf(tokens[i]), stream.tokenURI(tokens[i]), receiver, amount
            );
        }
        (address eReceiver, uint256 eAmount) = editions.royaltyInfo(editionId, 1 ether);
        return keccak256(abi.encode(all, editions.uri(editionId), eReceiver, eAmount));
    }

    /// @dev Each replacement is a 30-day SUCCESSOR_SETTER action; afterwards every existing
    ///      token reads the same, and Editions and the work-records satellite name the new
    ///      contract.
    function test_ReplacingEachDependencyLeavesExistingTokensUnchanged() public {
        bytes32 before = _snapshot();
        for (uint256 i; i < KINDS.length; ++i) {
            bytes32 kind = KINDS[i];
            address previous = _current(kind);
            address next = address(new DependencyStandIn(_interfaceOf(kind)));
            bytes memory call = abi.encodeCall(stream.setDependency, (kind, previous, next));
            (bool immediate, uint32 delay) =
                manager.canCall(hotAdmin, address(stream), bytes4(call));
            assertFalse(immediate);
            assertEq(delay, 30 days, "the successor class");
            _schedule(hotAdmin, address(stream), call);
            vm.warp(block.timestamp + delay);
            vm.expectEmit(address(stream));
            emit IStream.DependencySet(kind, previous, next);
            vm.prank(hotAdmin);
            manager.execute(address(stream), call);
            assertEq(_current(kind), next);
            assertEq(_snapshot(), before, "existing tokens are unaffected");
        }
        // One source of truth: the satellites read Stream's pointers.
        assertEq(address(editions.packageRegistry()), stream.packageRegistry());
        assertEq(address(editions.economics()), stream.economics());
        assertEq(address(editions.artistRegistry()), stream.artistRegistry());
        assertEq(records.artistRegistry(), stream.artistRegistry());
        assertEq(records.entropyModule(), stream.entropyModule());
        // A finalized VRF work keeps the seed fixed at open.
        (, bytes32 seed) = records.seedOf(tokens[1]);
        assertTrue(seed != 0);
    }

    /// @dev The replacement is what new works use: a new start consumes through the new
    ///      package registry (here a stand-in, so it reverts), and putting the original back
    ///      restores it.
    function test_NewWorksUseTheReplacement() public {
        address original = stream.packageRegistry();
        address next = address(new DependencyStandIn(type(IPackageRegistry).interfaceId));
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.setDependency, ("PACKAGE_REGISTRY", original, next))
        );
        Work memory w = _work(artist, collectionId);
        Work[] memory one = _one(w);
        bytes32 root = _publish(one);
        bytes memory data = _mintData(root, one, 0);
        vm.expectRevert();
        auction.start(address(stream), data);
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.setDependency, ("PACKAGE_REGISTRY", next, original))
        );
        auction.start(address(stream), _mintData(root, one, 0));
        assertEq(stream.ownerOf(stream.totalMinted()), address(auction));
    }
}
