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
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
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

/// @dev A replacement entropy module that has a seed for every item, but not its predecessor's:
///      the worst replacement for the works minted before it.
contract OtherSeedsEntropy is IERC165 {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IEntropyModule).interfaceId
                || interfaceId == type(IERC165).interfaceId;
    }

    function isDelivered(bytes32) external pure returns (bool) {
        return true;
    }

    function seedOf(bytes32 itemHash) external pure returns (bytes32) {
        return keccak256(abi.encode("another module's seed", itemHash));
    }
}

/// @dev A replacement entropy module that delivers the seeds the test gives it.
contract DeliveringEntropy is IERC165 {
    mapping(bytes32 itemHash => bytes32 seed) internal _seeds;

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IEntropyModule).interfaceId
                || interfaceId == type(IERC165).interfaceId;
    }

    function deliver(bytes32 itemHash, bytes32 seed) external {
        _seeds[itemHash] = seed;
    }

    function isDelivered(bytes32 itemHash) external view returns (bool) {
        return _seeds[itemHash] != 0;
    }

    function seedOf(bytes32 itemHash) external view returns (bytes32) {
        return _seeds[itemHash];
    }
}

/// @notice Owner decision 16 on the real genesis deployment: Stream's package registry, artist
///         registry, economics resolver and entropy module are replaceable by governance in the
///         30-day class, and 6529 Stream Editions and the work-records satellite follow at once.
///         Existing tokens are unaffected, finalized or not: their owner, their metadata (a VRF
///         work's seed comes from the module current at its mint, `entropyModuleOf`) and their
///         royalty info are byte for byte the same after every replacement.
contract StreamDependenciesTest is IntegrationBase {
    bytes32[4] internal KINDS =
        [bytes32("PACKAGE_REGISTRY"), "ARTIST_REGISTRY", "ECONOMICS", "ENTROPY_MODULE"];

    address internal artist;
    address internal collector = makeAddr("dependencyCollector");
    /// @dev Every existing token: finalized (an ARTIST work, a VRF work, an edition master),
    ///      then not finalized (a record open, a VRF work and a VRF edition master whose records
    ///      are not open yet, and a work still in its auction).
    uint256[] internal tokens;
    uint256[] internal editionIds;
    /// @dev The works whose records are not open yet, by their index in `tokens`.
    uint256 internal constant PENDING_VRF = 4;
    uint256 internal constant PENDING_VRF_MASTER = 5;
    bytes32 internal pendingRoot;

    function setUp() public override {
        super.setUp();
        artist = _actor("dependencyArtist");
        Work[] memory works = new Work[](3);
        works[0] = _work(artist, collectionId);
        works[1] = _work(artist, collectionId);
        works[1].item.seedPolicy = SeedPolicy.VRF;
        works[2] = _master(artist);
        bytes32 root = _publish(works);
        _keep(root, works);
        // The VRF work's seed is requested and delivered before its start.
        _deliver(works, root, 1);
        for (uint256 i; i < works.length; ++i) {
            uint256 tokenId = _sell(root, works, i, collector, 1 ether);
            tokens.push(tokenId);
            records.openRecord(tokenId, works[i].item, works[i].media);
            bytes32 state = records.workStateHash(tokenId);
            vm.prank(artist);
            records.finalize(tokenId, state);
        }
        editionIds.push(editions.createEdition(tokens[2], works[2].item, root, _proofOf(works, 2)));

        // Works that are not finalized: a record open, two VRF works whose records are not open
        // (one an edition master with an edition), and a work still in its auction.
        Work[] memory pending = new Work[](4);
        pending[0] = _work(artist, collectionId);
        pending[1] = _work(artist, collectionId);
        pending[1].item.seedPolicy = SeedPolicy.VRF;
        pending[2] = _master(artist);
        pending[2].item.seedPolicy = SeedPolicy.VRF;
        pending[3] = _work(artist, collectionId);
        pendingRoot = _publish(pending);
        _keep(pendingRoot, pending);
        _deliver(pending, pendingRoot, 1);
        _deliver(pending, pendingRoot, 2);
        for (uint256 i; i < 3; ++i) {
            tokens.push(_sell(pendingRoot, pending, i, collector, 1 ether));
        }
        records.openRecord(tokens[3], pending[0].item, pending[0].media);
        editionIds.push(
            editions.createEdition(
                tokens[PENDING_VRF_MASTER], pending[2].item, pendingRoot, _proofOf(pending, 2)
            )
        );
        (, uint256 inAuction) = _start(pendingRoot, pending, 3);
        tokens.push(inAuction);
        assertEq(stream.ownerOf(inAuction), address(auction));
    }

    function _master(address lead) internal returns (Work memory w) {
        w = _work(lead, collectionId);
        w.item.kind = ItemKind.EDITION_MASTER;
        w.item.edition = EditionTerms(0, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
    }

    function _deliver(Work[] memory works, bytes32 root, uint256 index) internal {
        uint256 requestId = entropy.requestSeed(works[index].item, root, _proofOf(works, index));
        coordinator.fulfill(requestId, uint256(keccak256(abi.encode("seed", root, index))));
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

    /// @dev A 30-day SUCCESSOR_SETTER replacement through the real governance path.
    function _replace(bytes32 kind, address next) internal {
        address previous = _current(kind);
        bytes memory call = abi.encodeCall(stream.setDependency, (kind, previous, next));
        (bool immediate, uint32 delay) = manager.canCall(hotAdmin, address(stream), bytes4(call));
        assertFalse(immediate);
        assertEq(delay, 30 days, "the successor class");
        _schedule(hotAdmin, address(stream), call);
        vm.warp(block.timestamp + delay);
        vm.expectEmit(address(stream));
        emit IStream.DependencySet(kind, previous, next);
        vm.prank(hotAdmin);
        manager.execute(address(stream), call);
        assertEq(_current(kind), next);
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
        for (uint256 i; i < editionIds.length; ++i) {
            (address receiver, uint256 amount) = editions.royaltyInfo(editionIds[i], 1 ether);
            all = abi.encode(all, editions.uri(editionIds[i]), receiver, amount);
        }
        return keccak256(all);
    }

    /// @dev Each replacement is a 30-day SUCCESSOR_SETTER action; afterwards every existing
    ///      token reads the same, finalized or not, and Editions and the work-records satellite
    ///      name the new contract. The replacements are stand-ins that revert on any call but
    ///      ERC-165, so no existing token's metadata or royalty reads a replaced contract.
    function test_ReplacingEachDependencyLeavesExistingTokensUnchanged() public {
        bytes32 before = _snapshot();
        bytes32 vrfSeed = entropy.seedOf(stream.work(tokens[PENDING_VRF]).itemHash);
        address genesisEntropy = stream.entropyModule();
        for (uint256 i; i < KINDS.length; ++i) {
            _replace(KINDS[i], address(new DependencyStandIn(_interfaceOf(KINDS[i]))));
            assertEq(_snapshot(), before, "existing tokens are unaffected");
        }
        // One source of truth: the satellites read Stream's pointers.
        assertEq(address(editions.packageRegistry()), stream.packageRegistry());
        assertEq(address(editions.economics()), stream.economics());
        assertEq(address(editions.artistRegistry()), stream.artistRegistry());
        assertEq(records.artistRegistry(), stream.artistRegistry());
        // Every existing work keeps the module its seed was delivered by.
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(stream.entropyModuleOf(tokens[i]), genesisEntropy);
        }
        // A finalized VRF work keeps the seed fixed at open, and a VRF work minted before the
        // replacement opens its record with the seed it was minted with.
        (, bytes32 seed) = records.seedOf(tokens[1]);
        assertTrue(seed != 0);
        _open(PENDING_VRF, 1);
        (, seed) = records.seedOf(tokens[PENDING_VRF]);
        assertEq(seed, vrfSeed, "the seed it was minted with");
    }

    /// @dev The worst entropy replacement: a module with a seed for every item, none of them its
    ///      predecessor's. Works minted before it keep their seeds, before and after their
    ///      records open; works minted after it take its seeds.
    function test_ReplacingTheEntropyModuleNeverChangesAnExistingWorksSeed() public {
        bytes32 before = _snapshot();
        bytes32 itemHash = stream.work(tokens[PENDING_VRF]).itemHash;
        bytes32 vrfSeed = entropy.seedOf(itemHash);
        address genesisEntropy = address(entropy);
        OtherSeedsEntropy other = new OtherSeedsEntropy();
        _replace("ENTROPY_MODULE", address(other));
        assertEq(_snapshot(), before, "existing tokens are unaffected");
        assertEq(stream.entropyModuleOf(tokens[PENDING_VRF]), genesisEntropy);
        _open(PENDING_VRF, 1);
        (, bytes32 seed) = records.seedOf(tokens[PENDING_VRF]);
        assertEq(seed, vrfSeed, "the seed it was minted with");
        assertTrue(seed != other.seedOf(itemHash));

        // A VRF work minted after the replacement takes the new module's seed.
        Work memory w = _work(artist, collectionId);
        w.item.seedPolicy = SeedPolicy.VRF;
        Work[] memory one = _one(w);
        bytes32 root = _publish(one);
        (, uint256 later) = _start(root, one, 0);
        assertEq(stream.entropyModuleOf(later), address(other));
        records.openRecord(later, w.item, w.media);
        (, seed) = records.seedOf(later);
        assertEq(seed, other.seedOf(WorksHashing.itemHash(w.item)));
    }

    /// @dev Two replacements make three eras. A VRF work minted in each of the first two keeps
    ///      its module and its metadata byte for byte through every later replacement, before
    ///      and after its record opens with that module's seed.
    function test_TwoEntropyReplacementsLeaveEachErasWorksUnchanged() public {
        address genesisEntropy = address(entropy);
        DeliveringEntropy second = new DeliveringEntropy();
        _replace("ENTROPY_MODULE", address(second));
        Work memory w = _work(artist, collectionId);
        w.item.seedPolicy = SeedPolicy.VRF;
        Work[] memory one = _one(w);
        bytes32 root = _publish(one);
        second.deliver(WorksHashing.itemHash(w.item), keccak256("the second era's seed"));
        (, uint256 secondEra) = _start(root, one, 0);
        tokens.push(secondEra);
        bytes32 before = _snapshot();

        _replace("ENTROPY_MODULE", address(new OtherSeedsEntropy()));
        assertEq(_snapshot(), before, "both eras' tokens are unaffected");
        assertEq(stream.entropyModuleOf(tokens[PENDING_VRF]), genesisEntropy);
        assertEq(stream.entropyModuleOf(secondEra), address(second));

        _open(PENDING_VRF, 1);
        records.openRecord(secondEra, w.item, w.media);
        (, bytes32 seed) = records.seedOf(tokens[PENDING_VRF]);
        assertEq(seed, entropy.seedOf(stream.work(tokens[PENDING_VRF]).itemHash));
        (, seed) = records.seedOf(secondEra);
        assertEq(seed, keccak256("the second era's seed"));
    }

    /// @dev A VRF request in flight across a replacement is fulfilled by the module that took it,
    ///      which keeps the seed. An item not started yet starts only on the current module's
    ///      delivery (`mint` checks the current module), so it is requested again there.
    function test_AVrfRequestInFlightAcrossAReplacement() public {
        Work memory w = _work(artist, collectionId);
        w.item.seedPolicy = SeedPolicy.VRF;
        Work[] memory one = _one(w);
        bytes32 root = _publish(one);
        bytes32 itemHash = WorksHashing.itemHash(w.item);
        uint256 requestId = entropy.requestSeed(w.item, root, _proofOf(one, 0));
        DeliveringEntropy next = new DeliveringEntropy();
        _replace("ENTROPY_MODULE", address(next));

        coordinator.fulfill(requestId, uint256(keccak256("in flight")));
        assertTrue(entropy.isDelivered(itemHash), "fulfilled by the module that took it");
        bytes memory data = _mintData(root, one, 0);
        vm.expectRevert(abi.encodeWithSelector(IStream.SeedNotDelivered.selector, itemHash));
        auction.start(address(stream), data);

        next.deliver(itemHash, keccak256("the current module's seed"));
        (, uint256 tokenId) = _start(root, one, 0);
        assertEq(stream.entropyModuleOf(tokenId), address(next));
        records.openRecord(tokenId, w.item, w.media);
        (, bytes32 seed) = records.seedOf(tokenId);
        assertEq(seed, keccak256("the current module's seed"));
    }

    /// @dev Opens the record of `tokens[index]`, the `item`-th of the pending works.
    function _open(uint256 index, uint256 item) internal {
        Work[] memory pending = _package(pendingRoot);
        records.openRecord(tokens[index], pending[item].item, pending[item].media);
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
