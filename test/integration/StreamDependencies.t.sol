// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IMintPolicy } from "src/interfaces/IMintPolicy.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IStreamExtension } from "src/interfaces/IStreamExtension.sol";
import { IStreamViews } from "src/interfaces/IStreamViews.sol";
import { StreamLayout } from "src/stream/StreamLayout.sol";
import { CURRENCY_ETH, PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionTerms,
    ItemKind,
    PackageItem,
    SeedPolicy
} from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { ICurationVerifier } from "src/interfaces/ICurationVerifier.sol";
import { PrimaryOutcome } from "src/interfaces/types/SaleTypes.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @dev A replacement dependency that only reports its interface (and, as a mint policy must,
///      names the artist registry of the Stream asking): any other call reverts, so a read of it
///      on a measured path fails loudly instead of returning plausible data.
contract DependencyStandIn is IERC165 {
    bytes4 internal immutable _id;

    constructor(bytes4 id) {
        _id = id;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return interfaceId == _id || interfaceId == type(IERC165).interfaceId;
    }

    function artistRegistry() external view returns (address) {
        return IStream(msg.sender).artistRegistry();
    }

    /// @dev As an economics resolver must, names the split factory of the Stream asking.
    function splitFactory() external view virtual returns (address) {
        return IStream(msg.sender).splitFactory();
    }
}

/// @dev A replacement economics resolver that names another split factory.
contract ForeignFactoryStandIn is DependencyStandIn {
    address internal immutable _factory;

    constructor(bytes4 id, address factory) DependencyStandIn(id) {
        _factory = factory;
    }

    function splitFactory() external view override returns (address) {
        return _factory;
    }
}

/// @dev A replacement dependency governed by `authority`: it also answers `authority()`, as
///      every genesis dependency does (they are all AccessManaged).
contract ManagedStandIn is DependencyStandIn {
    address public immutable authority;

    constructor(bytes4 id, address authority_) DependencyStandIn(id) {
        authority = authority_;
    }
}

/// @dev A replacement with a silent fallback: `authority()` succeeds with no answer.
contract SilentStandIn is DependencyStandIn {
    constructor(bytes4 id) DependencyStandIn(id) { }

    fallback() external { }
}

/// @dev A replacement whose `authority()` reverts with a one-word reason.
contract RevertingAuthorityStandIn is DependencyStandIn {
    constructor(bytes4 id) DependencyStandIn(id) { }

    function authority() external pure returns (address) {
        assembly ("memory-safe") {
            mstore(0, 0xdead)
            revert(0, 0x20)
        }
    }
}

/// @dev A replacement that answers `authority()` with a foreign manager, but only after spending
///      more gas than Stream used to forward to the read (100,000).
contract SlowAuthorityStandIn is DependencyStandIn {
    address internal immutable _authority;

    constructor(bytes4 id, address authority_) DependencyStandIn(id) {
        _authority = authority_;
    }

    function authority() external view returns (address) {
        uint256 start = gasleft();
        while (start - gasleft() < 120_000) { }
        return _authority;
    }
}

/// @dev A replacement whose `authority()` answers one word that is not an address.
contract DirtyAuthorityStandIn is DependencyStandIn {
    constructor(bytes4 id) DependencyStandIn(id) { }

    function authority() external pure returns (bytes32) {
        return bytes32(type(uint256).max);
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

    function isDeliveredContent(bytes32) external pure returns (bool) {
        return true;
    }

    function seedOfContent(bytes32 contentHash) external pure returns (bytes32) {
        return keccak256(abi.encode("another module's seed for content", contentHash));
    }
}

/// @dev A replacement entropy module that delivers the seeds the test gives it.
contract DeliveringEntropy is IERC165 {
    mapping(bytes32 itemHash => bytes32 seed) internal _seeds;
    mapping(bytes32 contentHash => bytes32 seed) internal _contentSeeds;

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IEntropyModule).interfaceId
                || interfaceId == type(IERC165).interfaceId;
    }

    function deliver(PackageItem memory item, bytes32 seed) external {
        _seeds[WorksHashing.itemHash(item)] = seed;
        _contentSeeds[item.contentHash] = seed;
    }

    function isDelivered(bytes32 itemHash) external view returns (bool) {
        return _seeds[itemHash] != 0;
    }

    function seedOf(bytes32 itemHash) external view returns (bytes32) {
        return _seeds[itemHash];
    }

    function isDeliveredContent(bytes32 contentHash) external view returns (bool) {
        return _contentSeeds[contentHash] != 0;
    }

    function seedOfContent(bytes32 contentHash) external view returns (bytes32) {
        return _contentSeeds[contentHash];
    }
}

/// @dev A replacement view extension that answers every view with other facts (another serial,
///      no seed, another artist and collection, another name) and also implements selectors a
///      forwarding fallback would let it answer on Stream's behalf: receiver hooks, ERC-1271,
///      `owner()`, `contractURI()` and an ERC-20 `transfer`.
contract HostileExtension is IStreamExtension {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IStreamExtension).interfaceId
            || interfaceId == type(IStreamViews).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function isValidCollectionName(string calldata) external pure returns (bool) {
        return true;
    }

    function work(uint256 tokenId) external pure returns (WorkCore memory w) {
        w.itemHash = keccak256(abi.encode("another item", tokenId));
        w.artistId = 6529;
        w.collectionId = 1;
        w.serial = uint64(tokenId) + 1000;
        w.kind = 0;
        w.seedPolicy = 0;
        w.royaltyRate = 100_000;
    }

    function collection(uint256) external pure returns (Collection memory c) {
        c.name = "Another name";
        c.minted = 1;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    function owner() external pure returns (address) {
        return address(0xBAD);
    }

    function contractURI() external pure returns (string memory) {
        return "data:,another";
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @notice Owner decision 16 on the real genesis deployment: Stream's package registry, artist
///         registry, economics resolver and entropy module are replaceable by governance in the
///         30-day class, and 6529 Stream Editions and the work-records satellite follow at once.
///         Existing tokens are unaffected, finalized or not: their owner, their metadata (a VRF
///         work's seed comes from the module current at its mint, `entropyModuleOf`) and their
///         royalty info are byte for byte the same after every replacement.
contract StreamDependenciesTest is IntegrationBase {
    /// @dev The replaceable dependencies: the three on the mint path and the view extension; the
    ///      artist registry is permanent.
    bytes32[4] internal KINDS =
        [bytes32("PACKAGE_REGISTRY"), "ECONOMICS", "ENTROPY_MODULE", "EXTENSION"];

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
        works[1].item.seedPolicy = uint8(SeedPolicy.VRF);
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
        editionIds.push(editions.createEdition(tokens[2], works[2].item));

        // Works that are not finalized: a record open, two VRF works whose records are not open
        // (one an edition master with an edition), and a work still in its auction.
        Work[] memory pending = new Work[](4);
        pending[0] = _work(artist, collectionId);
        pending[1] = _work(artist, collectionId);
        pending[1].item.seedPolicy = uint8(SeedPolicy.VRF);
        pending[2] = _master(artist);
        pending[2].item.seedPolicy = uint8(SeedPolicy.VRF);
        pending[3] = _work(artist, collectionId);
        pendingRoot = _publish(pending);
        _keep(pendingRoot, pending);
        _deliver(pending, pendingRoot, 1);
        _deliver(pending, pendingRoot, 2);
        for (uint256 i; i < 3; ++i) {
            tokens.push(_sell(pendingRoot, pending, i, collector, 1 ether));
        }
        records.openRecord(tokens[3], pending[0].item, pending[0].media);
        editionIds.push(editions.createEdition(tokens[PENDING_VRF_MASTER], pending[2].item));
        (, uint256 inAuction) = _start(pendingRoot, pending, 3);
        tokens.push(inAuction);
        assertEq(stream.ownerOf(inAuction), address(auction));
    }

    function _master(address lead) internal returns (Work memory w) {
        w = _work(lead, collectionId);
        w.item.kind = uint8(ItemKind.EDITION_MASTER);
        w.item.edition = EditionTerms(0, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
    }

    function _deliver(Work[] memory works, bytes32 root, uint256 index) internal {
        uint256 requestId = entropy.requestSeed(works[index].item, root, _proofOf(works, index));
        coordinator.fulfill(requestId, uint256(keccak256(abi.encode("seed", root, index))));
    }

    function _interfaceOf(bytes32 kind) internal pure returns (bytes4) {
        if (kind == "PACKAGE_REGISTRY") return type(IMintPolicy).interfaceId;
        if (kind == "ECONOMICS") return type(IEconomicsResolver).interfaceId;
        if (kind == "EXTENSION") return type(IStreamExtension).interfaceId;
        return type(IEntropyModule).interfaceId;
    }

    function _current(bytes32 kind) internal view returns (address) {
        if (kind == "PACKAGE_REGISTRY") return stream.packageRegistry();
        if (kind == "ECONOMICS") return stream.economics();
        if (kind == "EXTENSION") return stream.extension();
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

    /// @dev A 30-day replacement that governance schedules and waits out, but Stream refuses.
    function _refuse(bytes32 kind, address next, bytes memory reason) internal {
        address previous = _current(kind);
        bytes memory call = abi.encodeCall(stream.setDependency, (kind, previous, next));
        _schedule(hotAdmin, address(stream), call);
        vm.warp(block.timestamp + 30 days);
        vm.prank(hotAdmin);
        vm.expectRevert(reason);
        manager.execute(address(stream), call);
        assertEq(_current(kind), previous, "unchanged");
    }

    /// @dev An existing token's permanent facts, everything but its metadata: the native views
    ///      (`coreOf`, ownership, royalty, sale, edition link, renderer) and the storage words a
    ///      pinned renderer reads at `StreamLayout`'s slots (the token's two words, its
    ///      collection's counter word and name).
    function _coreSnapshot() internal view returns (bytes32) {
        bytes memory all;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 id = tokens[i];
            (address receiver, uint256 amount) = stream.royaltyInfo(id, 1 ether);
            (,, uint256 collection,,,) = stream.coreOf(id);
            (PrimaryOutcome outcome, address currency, uint256 price) = stream.primarySale(id);
            (address linked, uint256 editionId) = stream.editionOf(id);
            all = abi.encode(
                all,
                abi.encode(stream.ownerOf(id), receiver, amount, _core(id), stream.rendererOf(id)),
                abi.encode(outcome, currency, price, linked, editionId),
                stream.extsload(StreamLayout.tokenSlot(id), 2),
                stream.extsload(StreamLayout.collectionSlot(collection), 3)
            );
        }
        for (uint256 i; i < editionIds.length; ++i) {
            (address receiver, uint256 amount) = editions.royaltyInfo(editionIds[i], 1 ether);
            (address master, uint256 workId, bytes32 contentHash) = editions.masterOf(editionIds[i]);
            all = abi.encode(all, master, workId, contentHash, receiver, amount);
        }
        return keccak256(all);
    }

    function _core(uint256 id) internal view returns (bytes memory) {
        (
            bytes32 itemHash,
            uint256 artistId,
            uint256 collection,
            uint8 kind,
            uint8 seed,
            uint32 rate
        ) = stream.coreOf(id);
        return abi.encode(itemHash, artistId, collection, kind, seed, rate);
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
        bytes32 vrfSeed =
            entropy.seedOf(IStreamViews(address(stream)).work(tokens[PENDING_VRF]).itemHash);
        address genesisEntropy = stream.entropyModule();
        for (uint256 i; i < KINDS.length; ++i) {
            _replace(KINDS[i], address(new DependencyStandIn(_interfaceOf(KINDS[i]))));
            assertEq(_snapshot(), before, "existing tokens are unaffected");
        }
        // One source of truth: the satellites read Stream's pointers.
        assertEq(address(editions.economics()), stream.economics());
        assertEq(address(editions.artistRegistry()), stream.artistRegistry());
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
        bytes32 itemHash = IStreamViews(address(stream)).work(tokens[PENDING_VRF]).itemHash;
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
        w.item.seedPolicy = uint8(SeedPolicy.VRF);
        Work[] memory one = _one(w);
        bytes32 root = _publish(one);
        (, uint256 later) = _start(root, one, 0);
        assertEq(stream.entropyModuleOf(later), address(other));
        records.openRecord(later, w.item, w.media);
        (, seed) = records.seedOf(later);
        assertEq(seed, other.seedOfContent(w.item.contentHash));
    }

    /// @dev Two replacements make three eras. A VRF work minted in each of the first two keeps
    ///      its module and its metadata byte for byte through every later replacement, before
    ///      and after its record opens with that module's seed.
    function test_TwoEntropyReplacementsLeaveEachErasWorksUnchanged() public {
        address genesisEntropy = address(entropy);
        DeliveringEntropy second = new DeliveringEntropy();
        _replace("ENTROPY_MODULE", address(second));
        Work memory w = _work(artist, collectionId);
        w.item.seedPolicy = uint8(SeedPolicy.VRF);
        Work[] memory one = _one(w);
        bytes32 root = _publish(one);
        second.deliver(w.item, keccak256("the second era's seed"));
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
        assertEq(
            seed, entropy.seedOf(IStreamViews(address(stream)).work(tokens[PENDING_VRF]).itemHash)
        );
        (, seed) = records.seedOf(secondEra);
        assertEq(seed, keccak256("the second era's seed"));
    }

    /// @dev A VRF request in flight across a replacement is fulfilled by the module that took it,
    ///      which keeps the seed. An item not started yet starts only on the current module's
    ///      delivery (`mint` checks the current module), so it is requested again there.
    function test_AVrfRequestInFlightAcrossAReplacement() public {
        Work memory w = _work(artist, collectionId);
        w.item.seedPolicy = uint8(SeedPolicy.VRF);
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

        next.deliver(w.item, keccak256("the current module's seed"));
        (, uint256 tokenId) = _start(root, one, 0);
        assertEq(stream.entropyModuleOf(tokenId), address(next));
        records.openRecord(tokenId, w.item, w.media);
        (, bytes32 seed) = records.seedOf(tokenId);
        assertEq(seed, keccak256("the current module's seed"));
    }

    /// @dev H-1 (review A): the view extension is replaceable, so nothing permanent or pinned
    ///      reads it. Governance replaces it through the real 30-day path with one that answers
    ///      every view with other facts; every existing work's permanent facts (ownership,
    ///      royalty, `coreOf`, sale, edition link, renderer and the `StreamLayout` words) and its
    ///      metadata (`tokenURI`, and each edition's `uri`) stay byte for byte the same.
    ///      Cross-branch: the metadata half needs the renderer that reads `coreOf` and
    ///      `extsload` instead of `IStreamViews` (the content pass's half of H-1); run
    ///      `forge test --match-contract StreamDependenciesTest` once both are merged.
    function test_ReplacingTheExtensionWithAHostileOneLeavesEveryExistingWorkUnchanged() public {
        bytes32 core = _coreSnapshot();
        bytes32 before = _snapshot();
        HostileExtension hostile = new HostileExtension();
        _replace("EXTENSION", address(hostile));
        // The views are informational: they now serve the hostile answer...
        assertEq(IStreamViews(address(stream)).work(tokens[0]).serial, uint64(tokens[0]) + 1000);
        // ...and nothing else changed.
        assertEq(_coreSnapshot(), core, "permanent facts are unaffected");
        assertEq(_snapshot(), before, "metadata is unaffected");
    }

    /// @dev L-2 (review A): the fallback forwards only the three `IStreamViews` selectors. With
    ///      an extension that implements receiver hooks, ERC-1271, an ERC-20 `transfer`,
    ///      `owner()` and `contractURI()`, Stream still answers none of the first three (a
    ///      revert with no data), and the last two natively with what governance set.
    function test_TheFallbackForwardsOnlyTheViews() public {
        _replace("EXTENSION", address(new HostileExtension()));
        bytes[5] memory refused = [
            abi.encodeWithSelector(
                HostileExtension.onERC721Received.selector, address(this), address(this), 1, ""
            ),
            abi.encodeWithSelector(
                HostileExtension.onERC1155Received.selector, address(this), address(this), 1, 1, ""
            ),
            abi.encodeWithSelector(HostileExtension.isValidSignature.selector, bytes32(0), ""),
            abi.encodeWithSelector(HostileExtension.transfer.selector, address(this), 1),
            hex"00"
        ];
        for (uint256 i; i < refused.length; ++i) {
            (bool ok, bytes memory answer) = address(stream).staticcall(refused[i]);
            assertFalse(ok, "not forwarded");
            assertEq(answer.length, 0, "a revert with no data");
        }
        assertEq(stream.owner(), marketOwner, "native owner");
        assertEq(stream.contractURI(), "", "native contract URI");
        assertEq(IStreamViews(address(stream)).totalSupply(), 0, "a view is forwarded");
    }

    /// @dev `supportsInterface(IStreamViews)` is true of every extension Stream accepts: the
    ///      replacement must answer `IStreamExtension`'s flat id, which covers the three views.
    ///      One that answers only the name rule's selector is refused.
    function test_AnExtensionMustCoverTheViews() public {
        assertEq(
            type(IStreamExtension).interfaceId,
            bytes4(keccak256("isValidCollectionName(string)")) ^ type(IStreamViews).interfaceId
        );
        address nameOnly =
            address(new DependencyStandIn(bytes4(keccak256("isValidCollectionName(string)"))));
        _refuse(
            "EXTENSION",
            nameOnly,
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, nameOnly)
        );
        assertTrue(IERC165(address(stream)).supportsInterface(type(IStreamViews).interfaceId));
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
        address next = address(new DependencyStandIn(type(IMintPolicy).interfaceId));
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
        assertEq(stream.ownerOf(IStream(address(stream)).totalMinted()), address(auction));
    }

    /// @dev Uniqueness lives in the mint policy (the package registry's content records), not
    ///      in Stream. Putting a predecessor back never rolls it back: the original registry
    ///      still holds every item it consumed, so the same item cannot start twice across a
    ///      replacement and a return. A successor that is a different contract must read its
    ///      predecessor's records (`consumedItemOf`) to keep this; Stream cannot enforce it.
    function test_APolicyRoundTripNeverReconsumesAnItem() public {
        address original = stream.packageRegistry();
        Work memory w = _work(artist, collectionId);
        Work[] memory one = _one(w);
        bytes32 root = _publish(one);
        auction.start(address(stream), _mintData(root, one, 0));
        address next = address(new DependencyStandIn(type(IMintPolicy).interfaceId));
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.setDependency, ("PACKAGE_REGISTRY", original, next))
        );
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.setDependency, ("PACKAGE_REGISTRY", next, original))
        );
        bytes memory again = _mintData(root, one, 0);
        bytes32 itemHash = WorksHashing.itemHash(w.item);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ContentUsed.selector, PRODUCT_STREAM, w.item.contentHash, itemHash
            )
        );
        auction.start(address(stream), again);
    }

    /// @dev The rc.2 review's G I-1 (fix F7): a replacement that answers `authority()` must name
    ///      Stream's own AccessManager, so a dependency governed elsewhere can never be
    ///      installed. Refused for every kind, the real package registry included; under Stream's
    ///      manager the same stand-in installs, and one with no `authority()` installs too
    ///      (`test_ReplacingEachDependencyLeavesExistingTokensUnchanged`).
    function test_AReplacementUnderAForeignAuthorityIsRefused() public {
        address foreign = address(new AccessManager(address(this)));
        for (uint256 i; i < KINDS.length; ++i) {
            address next = address(new ManagedStandIn(_interfaceOf(KINDS[i]), foreign));
            _refuse(KINDS[i], next, abi.encodeWithSelector(IStream.InvalidBinding.selector, next));
        }
        PackageRegistry real = new PackageRegistry(
            foreign,
            ICurationVerifier(address(verifier)),
            address(verifier).codehash,
            address(artists),
            address(artists).codehash
        );
        _refuse(
            "PACKAGE_REGISTRY",
            address(real),
            abi.encodeWithSelector(IStream.InvalidBinding.selector, address(real))
        );
        // One word that is not an address is refused too.
        address dirty = address(new DirtyAuthorityStandIn(_interfaceOf("ECONOMICS")));
        _refuse("ECONOMICS", dirty, abi.encodeWithSelector(IStream.InvalidBinding.selector, dirty));

        for (uint256 i; i < KINDS.length; ++i) {
            _replace(
                KINDS[i], address(new ManagedStandIn(_interfaceOf(KINDS[i]), address(manager)))
            );
        }
    }

    /// @dev A replacement economics resolver must name Stream's own split factory (fixed at its
    ///      construction): one naming another would derive other wallets for existing works,
    ///      so their edition sales could not deploy the wallets their terms name (automated
    ///      review, 16 November 2026). Fails without the check: the foreign resolver installs.
    function test_AReplacementResolverMustNameStreamsSplitFactory() public {
        address foreign =
            address(new ForeignFactoryStandIn(_interfaceOf("ECONOMICS"), address(0xFAC)));
        _refuse(
            "ECONOMICS", foreign, abi.encodeWithSelector(IStream.InvalidBinding.selector, foreign)
        );
        _replace(
            "ECONOMICS", address(new ManagedStandIn(_interfaceOf("ECONOMICS"), address(manager)))
        );
    }

    /// @dev F7's other side: only a successful one-word `authority()` answer is compared. A
    ///      replacement whose `authority()` succeeds with no answer (a silent fallback) or
    ///      reverts, even with a one-word reason, installs for every kind.
    function test_AReplacementWithNoAuthorityAnswerInstalls() public {
        for (uint256 i; i < KINDS.length; ++i) {
            _replace(KINDS[i], address(new SilentStandIn(_interfaceOf(KINDS[i]))));
            _replace(KINDS[i], address(new RevertingAuthorityStandIn(_interfaceOf(KINDS[i]))));
        }
    }

    /// @dev The read forwards all the gas the call has (the gas rule): an `authority()` that
    ///      needs more than the 100,000 Stream used to forward is still read, so a foreign
    ///      manager it names is refused. Before, this replacement installed.
    function test_ASlowAuthorityAnswerIsStillRead() public {
        address foreign = address(new AccessManager(address(this)));
        address slow = address(new SlowAuthorityStandIn(_interfaceOf("ECONOMICS"), foreign));
        _refuse("ECONOMICS", slow, abi.encodeWithSelector(IStream.InvalidBinding.selector, slow));
    }

    /// @dev The permanence gap the review of #81 found, closed: the artist registry's only
    ///      `register` caller is governed too (`setPackageRegistry`, SUCCESSOR_SETTER, 30
    ///      days), so a successor package registry installed in Stream registers new artists,
    ///      and their works mint. The genesis registry then registers nobody.
    function test_AReplacementPackageRegistryRegistersNewArtists() public {
        PackageRegistry old = registry;
        PackageRegistry next = new PackageRegistry(
            address(manager),
            ICurationVerifier(address(verifier)),
            address(verifier).codehash,
            address(artists),
            address(artists).codehash
        );
        // The successor's one-shot binds (a new target: ADMIN, on the hot admin's delay).
        _govern(hotAdmin, address(next), abi.encodeCall(next.bindStream, (address(stream))));
        _govern(hotAdmin, address(next), abi.encodeCall(next.bindEditions, (address(editions))));

        // Stream and the artist registry switch together, both in the 30-day class.
        _replace("PACKAGE_REGISTRY", address(next));
        bytes memory rebind =
            abi.encodeCall(artists.setPackageRegistry, (address(old), address(next)));
        (bool immediate, uint32 delay) = manager.canCall(hotAdmin, address(artists), bytes4(rebind));
        assertFalse(immediate);
        assertEq(delay, 30 days, "the successor class");
        _schedule(hotAdmin, address(artists), rebind);
        vm.warp(block.timestamp + delay);
        vm.expectEmit(address(artists));
        emit IArtistRegistry.PackageRegistrySet(address(old), address(next));
        vm.prank(hotAdmin);
        manager.execute(address(artists), rebind);
        assertEq(artists.packageRegistry(), address(next));

        // A new artist registers through the successor, and their work mints.
        registry = next;
        address newcomer = _actor("newcomerArtist");
        assertEq(artists.artistIdOf(newcomer), 0);
        Work[] memory one = _one(_work(newcomer, collectionId));
        bytes32 root = _publish(one);
        uint256 artistId = artists.artistIdOf(newcomer);
        assertTrue(artistId != 0, "registered through the successor");
        (, uint256 tokenId) = _start(root, one, 0);
        assertEq(stream.ownerOf(tokenId), address(auction));
        assertEq(stream.artistOf(tokenId), artistId);

        // The genesis registry registers nobody now.
        vm.prank(address(old));
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, address(old))
        );
        artists.register(makeAddr("late"), bytes32(0), bytes32(0));
    }

    /// @dev `setPackageRegistry` is compare-and-set, refuses a contract that is not a package
    ///      registry, and only governance calls it.
    function test_SetPackageRegistryChecks() public {
        address current = artists.packageRegistry();
        PackageRegistry next = new PackageRegistry(
            address(manager),
            ICurationVerifier(address(verifier)),
            address(verifier).codehash,
            address(artists),
            address(artists).codehash
        );
        vm.prank(makeAddr("outsider"));
        vm.expectRevert();
        artists.setPackageRegistry(current, address(next));
        assertFalse(
            _governTry(
                hotAdmin,
                address(artists),
                abi.encodeCall(artists.setPackageRegistry, (address(next), address(next)))
            ),
            "a stale expected value"
        );
        assertFalse(
            _governTry(
                hotAdmin,
                address(artists),
                abi.encodeCall(artists.setPackageRegistry, (current, address(stream)))
            ),
            "not a package registry"
        );
        assertEq(artists.packageRegistry(), current);
    }

    /// @dev The review of #81, option A: Stream's VRF check reads one word, the delivery of the
    ///      item's content. A seed belongs to its content, whichever package lists it, and a
    ///      content hash is consumed by one item only (`PackageRegistry.consume`, which refuses a
    ///      used content hash with `ContentUsed`; CUR-12). So two approved items with the same
    ///      content share one seed, and only one of them can ever exist as a work: here the
    ///      second package's item, never requested itself, starts on its content's seed and
    ///      opens its record with it, and the first package's item can then never start. An item
    ///      whose own content has no seed cannot start, whatever other content is seeded.
    function test_AVrfStartChecksTheItemsContentAndContentIsMintedOnce() public {
        Work memory w = _work(artist, collectionId);
        w.item.seedPolicy = uint8(SeedPolicy.VRF);
        Work[] memory first = _one(w);
        bytes32 firstRoot = _publish(first);
        uint256 requestId = entropy.requestSeed(w.item, firstRoot, _proofOf(first, 0));
        coordinator.fulfill(requestId, uint256(keccak256("the content's seed")));

        // The same content in another package, as a different item never requested itself.
        Work memory again = abi.decode(abi.encode(w), (Work));
        again.item.recordFileId = _record("The same content, listed again");
        Work[] memory second = _one(again);
        assertTrue(
            WorksHashing.itemHash(again.item) != WorksHashing.itemHash(w.item), "another item"
        );
        assertEq(again.item.contentHash, w.item.contentHash, "the same content");
        bytes32 secondRoot = _publish(second);
        assertFalse(entropy.isDelivered(WorksHashing.itemHash(again.item)), "never linked");
        assertTrue(entropy.isDeliveredContent(again.item.contentHash));

        (, uint256 tokenId) = _start(secondRoot, second, 0);
        records.openRecord(tokenId, again.item, again.media);
        (, bytes32 seed) = records.seedOf(tokenId);
        assertEq(seed, entropy.seedOfContent(w.item.contentHash), "the content's one seed");

        bytes memory data = _mintData(firstRoot, first, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ContentUsed.selector,
                PRODUCT_STREAM,
                w.item.contentHash,
                WorksHashing.itemHash(again.item)
            )
        );
        auction.start(address(stream), data);

        // Another item, whose own content has no seed, cannot start.
        Work memory unseeded = _work(artist, collectionId);
        unseeded.item.seedPolicy = uint8(SeedPolicy.VRF);
        Work[] memory third = _one(unseeded);
        bytes32 thirdRoot = _publish(third);
        bytes memory thirdData = _mintData(thirdRoot, third, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStream.SeedNotDelivered.selector, WorksHashing.itemHash(unseeded.item)
            )
        );
        auction.start(address(stream), thirdData);
    }
}

