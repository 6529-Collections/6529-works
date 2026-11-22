// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { ICurationVerifier } from "src/interfaces/ICurationVerifier.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { PackageItem, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @dev A replacement that only reports one interface over ERC-165 and reverts on any other
///      call, so nothing that reads it can succeed.
contract DependencyStandInPorted is IERC165 {
    bytes4 internal immutable id;

    constructor(bytes4 id_) {
        id = id_;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return interfaceId == id || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev A replacement entropy module with a seed for every content, none its predecessor's.
contract OtherSeedsEntropyPorted is IERC165 {
    function isDeliveredContent(bytes32) external pure returns (bool) {
        return true;
    }

    function seedOfContent(bytes32 contentHash) public pure returns (bytes32) {
        return keccak256(abi.encode("another module's seed", contentHash));
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IEntropyModule).interfaceId
                || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev A replacement entropy module that delivers the seeds the test gives it.
contract DeliveringEntropyPorted is IERC165 {
    mapping(bytes32 contentHash => bytes32) public seedOfContent;

    function deliver(bytes32 contentHash, bytes32 seed) external {
        seedOfContent[contentHash] = seed;
    }

    function isDeliveredContent(bytes32 contentHash) external view returns (bool) {
        return seedOfContent[contentHash] != 0;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IEntropyModule).interfaceId
                || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Re-ported from the retired `StreamDependencies` suite onto the deployed plain core.
///         Stream itself has no replaceable dependency any more: what new works go through is
///         replaced around it, each in the SUCCESSOR_SETTER class (7 days): the English auction's
///         mint policy for 6529 Stream (`setStreamPolicy`), the package registry's entropy module
///         (`setEntropyModule`) and the accounts module's registering package registry
///         (`setPackageRegistry`). Existing works are unaffected, finalized or not, in an
///         auction or not: their owner, item, seed (stored at mint), royalty and metadata stay
///         byte for byte the same, and a live sale still settles.
contract StreamDependenciesPortedTest is IntegrationBase {
    address internal artist;
    address internal collector = makeAddr("dependencyCollector");
    /// @dev 0: ARTIST seed, finalized; 1: VRF, finalized; 2: VRF, record open; 3: VRF, record
    ///      not open; 4: in its auction.
    uint256[] internal tokens;
    uint256 internal liveSale;
    bytes32 internal setupRoot;
    /// @dev The content of `tokens[0]`.
    bytes32 internal firstContent;

    function _withVrf() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        artist = _actor("dependencyArtist");
        Work[] memory works = new Work[](5);
        for (uint256 i; i < works.length; ++i) {
            works[i] = _work(artist, collectionId);
        }
        works[0].item.seedPolicy = uint8(SeedPolicy.ARTIST);
        works[0].item.seed = keccak256("the artist's seed");
        for (uint256 i = 1; i < 4; ++i) {
            works[i].item.seedPolicy = uint8(SeedPolicy.VRF);
        }
        bytes32 root = _publish(works);
        for (uint256 i = 1; i < 4; ++i) {
            _deliver(works, root, i);
        }
        for (uint256 i; i < 4; ++i) {
            tokens.push(_sell(root, works, i, collector, 1 ether));
        }
        for (uint256 i; i < 3; ++i) {
            _open(tokens[i], works[i]);
        }
        for (uint256 i; i < 2; ++i) {
            bytes32 state = rules.workStateHash(address(stream), tokens[i]);
            vm.prank(artist);
            rules.finalize(address(stream), tokens[i], state);
        }
        setupRoot = root;
        _keep(root, works);
        firstContent = works[0].item.contentHash;
        uint256 inAuction;
        (liveSale, inAuction) = _start(root, works, 4);
        _ethBid(liveSale, collector, 1 ether);
        tokens.push(inAuction);
        assertEq(stream.ownerOf(inAuction), address(auction));
    }

    /// @dev The VRF work whose record is not open (`tokens[3]`).
    function _pendingVrf() internal view returns (Work memory) {
        return _package(setupRoot)[3];
    }

    function _deliver(Work[] memory works, bytes32 root, uint256 index) internal {
        uint256 requestId = entropy.requestSeed(works[index].item, root, _proofOf(works, index));
        coordinator.fulfill(requestId, uint256(keccak256(abi.encode("seed", root, index))));
    }

    /// @dev A SUCCESSOR_SETTER replacement through the real governance path: 7 days.
    function _successor(address target, bytes memory call) internal {
        (bool immediate, uint32 delay) = manager.canCall(network, target, bytes4(call));
        assertFalse(immediate);
        assertEq(delay, 7 days, "the successor class");
        _govern(network, target, call);
    }

    function _setPolicy(address next) internal {
        _successor(
            address(auction),
            abi.encodeCall(IEnglishAuction.setStreamPolicy, (auction.streamPolicy(), next))
        );
        assertEq(auction.streamPolicy(), next);
    }

    function _setEntropy(address next) internal {
        _successor(
            address(registry),
            abi.encodeCall(IPackageRegistry.setEntropyModule, (registry.entropyModule(), next))
        );
        assertEq(registry.entropyModule(), next);
    }

    /// @dev Everything an existing token shows the world: owner, item, the stored work (its
    ///      seed included), royalty and metadata (`tokenURI`, or its failure, as it stands).
    function _snapshot() internal view returns (bytes32) {
        bytes memory all;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 id = tokens[i];
            (address receiver, uint256 amount) = stream.royaltyInfo(id, 1 ether);
            (bool ok, bytes memory uri) =
                address(stream).staticcall(abi.encodeCall(stream.tokenURI, (id)));
            all = abi.encode(
                all,
                stream.ownerOf(id),
                stream.itemHashOf(id),
                abi.encode(stream.workOf(id)),
                receiver,
                amount,
                ok,
                uri
            );
        }
        return keccak256(all);
    }

    /// @dev Each replacement is a 7-day action; afterwards every existing token reads the same,
    ///      a VRF work opens its record with the seed it was minted with, and the live sale
    ///      settles. The stand-ins revert on every call but ERC-165, so nothing existing reads
    ///      a replaced contract.
    function test_ReplacingEachDependencyLeavesExistingTokensUnchanged() public {
        bytes32 before = _snapshot();
        bytes32 vrfSeed = entropy.seedOfContent(_pendingVrf().item.contentHash);
        assertEq(stream.workOf(tokens[3]).seed, vrfSeed, "the seed is stored at mint");
        _setPolicy(address(new DependencyStandInPorted(type(IMintPolicy).interfaceId)));
        assertEq(_snapshot(), before, "a policy replacement");
        _setEntropy(address(new DependencyStandInPorted(type(IEntropyModule).interfaceId)));
        assertEq(_snapshot(), before, "an entropy replacement");
        _successor(
            address(accounts),
            abi.encodeCall(
                Accounts.setPackageRegistry,
                (accounts.packageRegistry(), address(new DependencyStandInPorted(0xffffffff)))
            )
        );
        assertEq(_snapshot(), before, "a registering-registry replacement");

        _open(tokens[3], _pendingVrf());
        assertEq(stream.workOf(tokens[3]).seed, vrfSeed, "the seed it was minted with");
        assertTrue(facts.factsOf(address(stream), tokens[3]).opened);
        _settleAtEnd(liveSale);
        assertEq(stream.ownerOf(tokens[4]), collector, "the live sale settles");
    }

    /// @dev The worst entropy replacement: a module with a seed for every content, none its
    ///      predecessor's. Works minted before keep their seeds; works minted after take its seed.
    function test_ReplacingTheEntropyModuleNeverChangesAnExistingWorksSeed() public {
        bytes32 before = _snapshot();
        bytes32 vrfSeed = entropy.seedOfContent(_pendingVrf().item.contentHash);
        OtherSeedsEntropyPorted other = new OtherSeedsEntropyPorted();
        _setEntropy(address(other));
        assertEq(_snapshot(), before, "existing tokens are unaffected");
        _open(tokens[3], _pendingVrf());
        assertEq(stream.workOf(tokens[3]).seed, vrfSeed);
        assertTrue(vrfSeed != other.seedOfContent(_pendingVrf().item.contentHash));

        Work memory w = _work(artist, collectionId);
        w.item.seedPolicy = uint8(SeedPolicy.VRF);
        Work[] memory one = _one(w);
        bytes32 root = _publish(one);
        (, uint256 later) = _start(root, one, 0);
        assertEq(stream.workOf(later).seed, other.seedOfContent(w.item.contentHash));
    }

    /// @dev Two replacements make three eras: a VRF work minted in the second era keeps its
    ///      module's seed through the third.
    function test_TwoEntropyReplacementsLeaveEachErasWorksUnchanged() public {
        DeliveringEntropyPorted second = new DeliveringEntropyPorted();
        _setEntropy(address(second));
        Work memory w = _work(artist, collectionId);
        w.item.seedPolicy = uint8(SeedPolicy.VRF);
        Work[] memory one = _one(w);
        bytes32 root = _publish(one);
        second.deliver(w.item.contentHash, keccak256("the second era's seed"));
        (, uint256 secondEra) = _start(root, one, 0);
        tokens.push(secondEra);
        bytes32 before = _snapshot();

        _setEntropy(address(new OtherSeedsEntropyPorted()));
        assertEq(_snapshot(), before, "both eras' tokens are unaffected");
        _open(secondEra, w);
        assertEq(stream.workOf(secondEra).seed, keccak256("the second era's seed"));
        assertEq(
            stream.workOf(tokens[3]).seed, entropy.seedOfContent(_pendingVrf().item.contentHash)
        );
    }

    /// @dev A VRF request in flight across a replacement is fulfilled by the module that took
    ///      it, which keeps the seed. The item starts only on the current module's delivery.
    function test_AVrfRequestInFlightAcrossAReplacement() public {
        Work memory w = _work(artist, collectionId);
        w.item.seedPolicy = uint8(SeedPolicy.VRF);
        Work[] memory one = _one(w);
        bytes32 root = _publish(one);
        bytes32 itemHash = WorksHashing.itemHash(w.item);
        uint256 requestId = entropy.requestSeed(w.item, root, _proofOf(one, 0));
        DeliveringEntropyPorted next = new DeliveringEntropyPorted();
        _setEntropy(address(next));

        coordinator.fulfill(requestId, uint256(keccak256("in flight")));
        assertTrue(entropy.isDelivered(itemHash), "fulfilled by the module that took it");
        bytes memory data = _mintData(root, one, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.SeedNotDelivered.selector, itemHash)
        );
        auction.start(address(stream), data);

        next.deliver(w.item.contentHash, keccak256("the current module's seed"));
        (, uint256 tokenId) = _start(root, one, 0);
        assertEq(stream.workOf(tokenId).seed, keccak256("the current module's seed"));
    }

    /// @dev A new start goes through the replacement policy (a stand-in, so it reverts); putting
    ///      the original back restores it.
    function test_NewWorksUseTheReplacementPolicy() public {
        address original = auction.streamPolicy();
        address next = address(new DependencyStandInPorted(type(IMintPolicy).interfaceId));
        _setPolicy(next);
        Work[] memory one = _one(_work(artist, collectionId));
        bytes32 root = _publish(one);
        bytes memory data = _mintData(root, one, 0);
        vm.expectRevert();
        auction.start(address(stream), data);
        _setPolicy(original);
        (, uint256 tokenId) = _start(root, one, 0);
        assertEq(stream.ownerOf(tokenId), address(auction));
    }

    /// @dev Putting a predecessor policy back never rolls it back: the same item cannot start
    ///      twice across a replacement and a return (its content is minted).
    function test_APolicyRoundTripNeverReconsumesAnItem() public {
        address original = auction.streamPolicy();
        Work memory w = _work(artist, collectionId);
        Work[] memory one = _one(w);
        bytes32 root = _publish(one);
        (, uint256 tokenId) = _start(root, one, 0);
        address next = address(new DependencyStandInPorted(type(IMintPolicy).interfaceId));
        _setPolicy(next);
        _setPolicy(original);
        bytes memory again = _mintData(root, one, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, w.item.contentHash, tokenId)
        );
        auction.start(address(stream), again);
    }

    /// @dev A successor package registry, bound and installed in the auction and the accounts
    ///      module (each 7 days), registers new artists and their works mint; the genesis
    ///      registry registers nobody after. Content minted under the predecessor stays minted:
    ///      the successor reads Stream's one live token per content and refuses it.
    function test_AReplacementPackageRegistryRegistersNewArtists() public {
        PackageRegistry old = registry;
        registry = _installSuccessor(old);
        _newcomerMints();
        _existingContentIsRefused();
        vm.prank(address(old));
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, address(old))
        );
        accounts.register(makeAddr("late"), bytes32(0), bytes32(0));
    }

    /// @dev Deploys a successor registry, binds it (a new target: ADMIN, 7 days) and installs it
    ///      as the auction's policy and the accounts module's registering registry (each 7 days).
    function _installSuccessor(PackageRegistry old) internal returns (PackageRegistry next) {
        next = new PackageRegistry(
            address(manager),
            ICurationVerifier(address(verifier)),
            address(verifier).codehash,
            address(directory),
            IEconomicsResolver(address(economics)),
            address(0),
            cc0TextFileId
        );
        _govern(network, address(next), abi.encodeCall(next.bindStream, (address(stream))));
        _setPolicy(address(next));
        bytes memory rebind =
            abi.encodeCall(Accounts.setPackageRegistry, (address(old), address(next)));
        (bool immediate, uint32 delay) = manager.canCall(network, address(accounts), bytes4(rebind));
        assertFalse(immediate);
        assertEq(delay, 7 days, "the successor class");
        vm.prank(network);
        manager.schedule(address(accounts), rebind, 0);
        vm.warp(block.timestamp + delay);
        vm.expectEmit(address(accounts));
        emit IArtistRegistry.PackageRegistrySet(address(old), address(next));
        vm.prank(network);
        manager.execute(address(accounts), rebind);
        assertEq(accounts.packageRegistry(), address(next));
    }

    function _newcomerMints() internal {
        address newcomer = _actor("newcomerArtist");
        assertEq(accounts.artistIdOf(newcomer), 0);
        Work[] memory one = _one(_work(newcomer, collectionId));
        bytes32 root = _publish(one);
        uint256 artistId = accounts.artistIdOf(newcomer);
        assertTrue(artistId != 0, "registered through the successor");
        (, uint256 tokenId) = _start(root, one, 0);
        assertEq(stream.ownerOf(tokenId), address(auction));
        assertEq(stream.workOf(tokenId).artistId, artistId);
    }

    /// @dev The content of an existing work, approved again in the successor, cannot mint.
    function _existingContentIsRefused() internal {
        Work memory copy = _work(artist, collectionId);
        copy.item.contentHash = firstContent;
        Work[] memory dup = _one(copy);
        bytes32 dupRoot = _publish(dup);
        bytes memory data = _mintData(dupRoot, dup, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, firstContent, tokens[0])
        );
        auction.start(address(stream), data);
    }

    /// @dev Stream's VRF check reads the delivery of the item's content: two approved items with
    ///      the same content share one seed, only one of them can ever exist as a work, and an
    ///      item whose own content has no seed cannot start.
    function test_AVrfStartChecksTheItemsContentAndContentIsMintedOnce() public {
        Work memory w = _work(artist, collectionId);
        w.item.seedPolicy = uint8(SeedPolicy.VRF);
        Work[] memory first = _one(w);
        bytes32 firstRoot = _publish(first);
        uint256 requestId = entropy.requestSeed(w.item, firstRoot, _proofOf(first, 0));
        coordinator.fulfill(requestId, uint256(keccak256("the content's seed")));

        Work memory again = abi.decode(abi.encode(w), (Work));
        again.item.recordFileId = _record("The same content, listed again");
        Work[] memory second = _one(again);
        assertTrue(WorksHashing.itemHash(again.item) != WorksHashing.itemHash(w.item));
        bytes32 secondRoot = _publish(second);
        assertFalse(entropy.isDelivered(WorksHashing.itemHash(again.item)), "never linked");
        assertTrue(entropy.isDeliveredContent(again.item.contentHash));

        (, uint256 tokenId) = _start(secondRoot, second, 0);
        assertEq(stream.workOf(tokenId).seed, entropy.seedOfContent(w.item.contentHash));

        bytes memory data = _mintData(firstRoot, first, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, w.item.contentHash, tokenId)
        );
        auction.start(address(stream), data);

        Work memory unseeded = _work(artist, collectionId);
        unseeded.item.seedPolicy = uint8(SeedPolicy.VRF);
        Work[] memory third = _one(unseeded);
        bytes32 thirdRoot = _publish(third);
        bytes memory thirdData = _mintData(thirdRoot, third, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.SeedNotDelivered.selector, WorksHashing.itemHash(unseeded.item)
            )
        );
        auction.start(address(stream), thirdData);
    }
}
