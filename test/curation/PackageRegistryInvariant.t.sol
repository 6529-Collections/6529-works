// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StreamContentMock } from "test/mocks/curation/StreamContentMock.sol";
import { IMintPolicy } from "src/interfaces/IMintPolicy.sol";
import { StreamMintRequest } from "src/interfaces/types/PackageTypes.sol";
import { Eip712CurationVerifier } from "src/curation/Eip712CurationVerifier.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionTerms,
    ItemKind,
    MoveAuthorization,
    PackageItem,
    PartyAcceptance
} from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { CurationArtistRegistryMock } from "test/mocks/curation/CurationArtistRegistryMock.sol";
import { CurationBase, CurationHelpers } from "./CurationBase.sol";
import { HandlerReach } from "../helpers/HandlerReach.sol";

/// @dev An exact model of the registry, driven the way Stream, Editions, artists, relayers, the
///      guardian and outsiders would. Twenty items by three artists: items 0-9 form package A,
///      6-15 package B (6-9 are in both), and 16-19 belong to no package; items `i` and `i + 8`
///      declare the same content hash. A third root C starts unregistered. Each action predicts
///      its outcome from the ghost state (root status, membership, proofs, keys, spent nonces,
///      content slots, releases, callers) before calling; an unexpected success or failure sets
///      a flag the invariants check, and the ghost state advances only on success.
contract CurationHandler is CurationHelpers {
    uint256 internal constant ITEMS = 20;
    uint256 internal constant PACKAGED = 16;
    uint256 internal constant MEDIA = 8;
    uint256 internal constant ARTISTS = 3;
    uint256 internal constant ACCEPTORS = 4;
    uint256 internal constant NONCES = 31;
    uint8 internal constant NONE = 0;
    uint8 internal constant APPROVED = 1;
    uint8 internal constant REVOKED = 2;

    PackageRegistry internal registry;
    Eip712CurationVerifier internal verifier;
    CurationArtistRegistryMock internal artists;
    address internal stream;
    address internal editions;
    address internal guardian;
    address internal admin;
    uint256 internal signerKey;

    uint256[ARTISTS] internal originalKey;
    uint256[ARTISTS] public currentKey;
    address[ARTISTS] public accounts;

    bytes[ITEMS] internal encodedItems;
    bytes32[ITEMS] public itemHashes;
    bytes32[MEDIA] public shas;
    bytes32[3] public roots;
    bytes32[][ITEMS] internal proofA;
    bytes32[][ITEMS] internal proofB;

    mapping(bytes32 root => uint8) public statusOf;
    mapping(uint256 artist => mapping(uint256 nonce => bool)) public spent;
    mapping(bytes32 itemHash => uint256) public consumeCount;
    mapping(bytes32 itemHash => bool) public released;
    mapping(bytes32 sha => bytes32) public streamItemOf;
    /// @dev The artist the latest release of each content hash named (its first account's ID).
    mapping(bytes32 sha => uint256) public releasedTo;
    bool public unexpectedSuccess;
    bool public unexpectedFailure;
    uint256 public consumed;
    uint256 public releases;

    constructor(
        PackageRegistry registry_,
        Eip712CurationVerifier verifier_,
        uint256 signerKey_,
        CurationArtistRegistryMock artists_,
        address[4] memory actors // stream, editions, guardian, admin
    ) {
        registry = registry_;
        verifier = verifier_;
        signerKey = signerKey_;
        artists = artists_;
        (stream, editions, guardian, admin) = (actors[0], actors[1], actors[2], actors[3]);
        for (uint256 a; a < ARTISTS; ++a) {
            originalKey[a] = 0xD00 + a;
            currentKey[a] = originalKey[a];
            accounts[a] = vm.addr(originalKey[a]);
        }
        for (uint256 m; m < MEDIA; ++m) {
            shas[m] = keccak256(abi.encode("media", m));
        }
        for (uint256 i; i < ITEMS; ++i) {
            PackageItem memory item = _item(accounts[i % ARTISTS], shas[i % MEDIA]);
            item.collectionId = i;
            item.mediaHash = keccak256(abi.encode("media list", i));
            if (i % 2 == 1) {
                item.kind = uint8(ItemKind.EDITION_MASTER);
                item.edition = EditionTerms(10, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
            }
            encodedItems[i] = abi.encode(item);
            itemHashes[i] = WorksHashing.itemHash(item);
        }
        roots[0] = _package(0, 10, proofA);
        roots[1] = _package(6, PACKAGED, proofB);
        roots[2] = keccak256("root C: never listed an item");
        _register(roots[0]);
        _register(roots[1]);
        for (uint256 r; r < 2; ++r) {
            for (uint256 a; a < ARTISTS; ++a) {
                _acceptAs(roots[r], accounts[a], originalKey[a]);
            }
        }
    }

    // ------------------------------------------------------------------------ actions

    struct Attempt {
        uint256 i;
        uint256 a;
        uint256 nonce;
        bytes32 root;
        bytes32 sha;
        address caller;
        uint64 deadline;
        bool proofValid;
        bool expected;
    }

    /// @dev A start, honest or not. Each fault fires a quarter of the time: any root instead of
    ///      one listing the item, a wrong proof, a stale key, an expired deadline, or a caller
    ///      that is not the bound Stream; spent nonces and used content arise on their own.
    function consume(
        uint256 itemSeed,
        uint256 nonceSeed,
        uint8 rootSeed,
        uint8 faults,
        uint8 callerSeed
    ) external {
        // Faults key on residue 1, so the fuzzer's favourite edge values (0, 255) stay honest.
        bool stale = faults % 4 == 1;
        bool wrongProof = (faults >> 2) % 4 == 1;
        bool expired = (faults >> 4) % 4 == 1;
        Attempt memory t;
        t.i = bound(itemSeed, 0, ITEMS - 1);
        t.a = t.i % ARTISTS;
        t.nonce = bound(nonceSeed, 0, NONCES - 1);
        // Mostly a root that lists the item (orphans have none, so they try A).
        uint256 r = rootSeed % 4 == 1
            ? rootSeed % 3
            : (t.i >= 10 && t.i < PACKAGED) || (t.i >= 6 && t.i < 10 && rootSeed % 2 == 1) ? 1 : 0;
        t.root = roots[r];
        t.sha = shas[t.i % MEDIA];
        t.caller = callerSeed % 4 != 1 ? stream : (callerSeed % 8 == 1 ? editions : admin);
        t.deadline = expired ? 0 : type(uint64).max;
        uint256 p = wrongProof ? (t.i + 1) % ITEMS : t.i;
        bool member = (r == 0 && t.i < 10) || (r == 1 && t.i >= 6 && t.i < PACKAGED);
        t.proofValid = member && p == t.i;
        bytes32[] memory proof = r == 0 ? proofA[p] : r == 1 ? proofB[p] : new bytes32[](0);
        uint256 key = stale ? originalKey[t.a] : currentKey[t.a];
        t.expected = t.caller == stream && statusOf[t.root] == APPROVED && t.proofValid
            && streamItemOf[t.sha] == 0 && !released[itemHashes[t.i]] && key == currentKey[t.a]
            && !expired && !spent[t.a][t.nonce]
            && (releasedTo[t.sha] == 0 || releasedTo[t.sha] == uint160(accounts[t.a]));
        MoveAuthorization memory move =
            _signedMove(key, t.root, itemHashes[t.i], t.nonce, t.deadline);
        PackageItem memory item = abi.decode(encodedItems[t.i], (PackageItem));
        try this.mintAs(
            t.caller,
            IMintPolicy.MintContext(
                t.caller, address(_policyStub), address(0), address(_policyStub)
            ),
            abi.encode(StreamMintRequest(t.root, item, proof, move))
        ) returns (
            IMintPolicy.MintRecord memory rec
        ) {
            bytes32 itemHash = rec.itemHash;
            if (!t.expected || itemHash != itemHashes[t.i]) {
                unexpectedSuccess = true;
            }
            ++consumeCount[itemHash];
            streamItemOf[t.sha] = itemHash;
            spent[t.a][t.nonce] = true;
            ++consumed;
        } catch {
            if (t.expected) unexpectedFailure = true;
        }
    }

    /// @dev The move authorization `key` signs, as a proof the artist registry checks.
    function _signedMove(
        uint256 key,
        bytes32 root,
        bytes32 itemHash,
        uint256 nonce,
        uint64 deadline
    ) internal view returns (MoveAuthorization memory) {
        bytes32 digest = registry.moveDigest(root, itemHash, nonce, deadline);
        return MoveAuthorization(nonce, deadline, _pf(key, _sig(key, digest)));
    }

    /// @dev Stream mints through its stand-in, which applies Stream's content rule (AUC-44);
    ///      any other caller calls the registry itself.
    function mintAs(address caller, IMintPolicy.MintContext calldata c, bytes calldata request)
        external
        returns (IMintPolicy.MintRecord memory)
    {
        require(msg.sender == address(this), "self only");
        if (caller == stream) {
            return StreamContentMock(stream).mintThrough(registry, c, request);
        }
        vm.prank(caller);
        return registry.authorize(c, request);
    }

    /// @dev Stream's dispute-burn path, honest or not, or a caller that is not Stream. The
    ///      release names one of the artists (by its first account's ID).
    function release(uint256 shaSeed, uint256 itemSeed, bool honest, uint8 callerSeed) external {
        bytes32 sha = shas[bound(shaSeed, 0, MEDIA - 1)];
        bytes32 itemHash = honest ? streamItemOf[sha] : itemHashes[bound(itemSeed, 0, ITEMS - 1)];
        address caller = callerSeed % 4 == 1 ? editions : stream;
        bool expected = itemHash != 0 && streamItemOf[sha] == itemHash;
        uint256 beneficiary = uint160(accounts[(itemSeed >> 8) % ARTISTS]);
        caller; // Stream holds releases since AUC-44: the stand-in plays Stream's part.
        try StreamContentMock(stream).release(sha, itemHash, beneficiary, address(artists)) {
            if (!expected) unexpectedSuccess = true;
            streamItemOf[sha] = 0;
            releasedTo[sha] = beneficiary;
            released[itemHash] = true;
            ++releases;
        } catch {
            if (expected) unexpectedFailure = true;
        }
    }

    /// @dev The current authority, or someone else (the old key after a rotation, an outsider).
    function revokeMove(uint256 artistSeed, uint256 nonceSeed, bool asAuthority) external {
        uint256 a = bound(artistSeed, 0, ARTISTS - 1);
        uint256 nonce = bound(nonceSeed, 0, NONCES - 1);
        address current = vm.addr(currentKey[a]);
        address caller = asAuthority
            ? current
            : (currentKey[a] != originalKey[a] ? accounts[a] : address(0xBEEF));
        bool expected = caller == current && !spent[a][nonce];
        vm.prank(caller);
        try registry.revokeMove(uint256(uint160(accounts[a])), nonce) {
            if (!expected) unexpectedSuccess = true;
            spent[a][nonce] = true;
        } catch {
            if (expected) unexpectedFailure = true;
        }
    }

    /// @dev An executed recovery: the artist's authority moves to a new key.
    function rotate(uint256 artistSeed) external {
        uint256 a = bound(artistSeed, 0, ARTISTS - 1);
        currentKey[a] = uint256(keccak256(abi.encode(currentKey[a]))) % (SECP256K1_N - 1) + 1;
        artists.recover(uint256(uint160(accounts[a])), vm.addr(currentKey[a]));
    }

    /// @dev Rarely, the guardian (or, wrongly, the admin) revokes A, B or the unregistered C.
    function revokePackage(uint8 rootSeed, bool byGuardian, uint8 gate) external {
        if (gate % 16 != 7) return;
        bytes32 root = roots[rootSeed % 3];
        address caller = byGuardian ? guardian : admin;
        bool expected = caller == guardian && statusOf[root] != REVOKED;
        vm.prank(caller);
        try registry.revokePackage(root, bytes32(uint256(gate))) {
            if (!expected) unexpectedSuccess = true;
            statusOf[root] = REVOKED;
        } catch {
            if (expected) unexpectedFailure = true;
        }
    }

    /// @dev A valid attestation for any root: only a root never registered nor revoked registers.
    function registerLate(uint8 rootSeed) external {
        bytes32 root = roots[rootSeed % 3];
        bytes32 evidence = keccak256(abi.encode("late evidence", root));
        bytes memory att =
            abi.encode(vm.addr(signerKey), _sig(signerKey, _approvalDigest(root, evidence)));
        bool expected = statusOf[root] == NONE;
        try registry.registerPackage(root, evidence, att) {
            if (!expected) unexpectedSuccess = true;
            statusOf[root] = APPROVED;
        } catch {
            if (expected) unexpectedFailure = true;
        }
    }

    /// @dev A relayed acceptance by a new party: it lands only on an approved root.
    function acceptLate(uint8 rootSeed, uint256 accountSeed) external {
        bytes32 root = roots[rootSeed % 3];
        uint256 key = 0xE00 + bound(accountSeed, 0, ACCEPTORS - 1);
        address account = vm.addr(key);
        PartyAcceptance memory acc =
            PartyAcceptance(account, keccak256(abi.encode(account)), 0, type(uint64).max);
        bytes memory sig = _pf(key, _sig(key, registry.acceptanceDigest(root, acc)));
        bool expected = statusOf[root] == APPROVED;
        try registry.acceptPackage(root, acc, sig) {
            if (!expected) unexpectedSuccess = true;
        } catch {
            if (expected) unexpectedFailure = true;
        }
    }

    /// @dev Bindings are one-shot: no later call by anyone may rebind.
    function rebind(bool editionsSlot, bool byAdmin) external {
        vm.prank(byAdmin ? admin : guardian);
        if (editionsSlot) {
            try registry.bindEditions(editions) {
                unexpectedSuccess = true;
            } catch { }
        } else {
            try registry.bindStream(stream) {
                unexpectedSuccess = true;
            } catch { }
        }
    }

    // ------------------------------------------------------------------------ helpers

    function _approvalDigest(bytes32 root, bytes32 evidence) internal view returns (bytes32) {
        return verifier.approvalDigest(root, evidence, verifier.signerEpoch(vm.addr(signerKey)));
    }

    function _register(bytes32 root) internal {
        bytes32 evidence = keccak256(abi.encode("evidence", root));
        bytes memory sig = _sig(signerKey, _approvalDigest(root, evidence));
        registry.registerPackage(root, evidence, abi.encode(vm.addr(signerKey), sig));
        statusOf[root] = APPROVED;
    }

    function _acceptAs(bytes32 root, address account, uint256 key) internal {
        PartyAcceptance memory acc =
            PartyAcceptance(account, keccak256(abi.encode(account)), 0, type(uint64).max);
        registry.acceptPackage(root, acc, _pf(key, _sig(key, registry.acceptanceDigest(root, acc))));
    }

    /// @dev Root of items `[from, to)`, writing each member's proof into `proofs`.
    function _package(uint256 from, uint256 to, bytes32[][ITEMS] storage proofs)
        internal
        returns (bytes32 root)
    {
        bytes32[] memory leaves = new bytes32[](to - from);
        for (uint256 i; i < leaves.length; ++i) {
            leaves[i] = WorksHashing.leaf(itemHashes[from + i]);
        }
        root = _root(leaves);
        for (uint256 i; i < leaves.length; ++i) {
            proofs[from + i] = _proof(leaves, i);
        }
    }
}

/// @dev Stateful invariants of the package registry (foundry.toml: 256 runs x depth 128).
contract PackageRegistryInvariantTest is CurationBase {
    CurationHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new CurationHandler(
            registry, verifier, signerKey1, artists, [stream, editions, guardian, admin]
        );
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = CurationHandler.consume.selector;
        selectors[1] = CurationHandler.release.selector;
        selectors[2] = CurationHandler.revokeMove.selector;
        selectors[3] = CurationHandler.rotate.selector;
        selectors[4] = CurationHandler.revokePackage.selector;
        selectors[5] = CurationHandler.registerLate.selector;
        selectors[6] = CurationHandler.acceptLate.selector;
        selectors[7] = CurationHandler.rebind.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// @dev Nothing the model forbids ever succeeds: revoked or unregistered roots, foreign or
    ///      wrong proofs, stale keys, spent or revoked nonces, expired moves, used or released
    ///      content, unbound callers, rebinding.
    function invariant_noUnexpectedSuccess() public view {
        assertFalse(handler.unexpectedSuccess());
    }

    /// @dev Everything the model allows succeeds, so the model is exact.
    function invariant_noUnexpectedFailure() public view {
        assertFalse(handler.unexpectedFailure());
    }

    /// @dev An item is consumed at most once, a released item never again, an orphan never.
    function invariant_itemConsumedAtMostOnce() public view {
        for (uint256 i; i < 20; ++i) {
            bytes32 h = handler.itemHashes(i);
            assertLe(handler.consumeCount(h), 1);
            assertEq(registry.isReleased(h), handler.released(h));
            if (i >= 16) assertEq(handler.consumeCount(h), 0);
        }
    }

    /// @dev Each content hash has at most one live item per product, recorded exactly.
    function invariant_contentRecordsMatch() public view {
        for (uint256 m; m < 8; ++m) {
            bytes32 sha = handler.shas(m);
            assertEq(registry.consumedItemOf(sha), handler.streamItemOf(sha));
        }
    }

    /// @dev Move nonces and root statuses match the model exactly.
    function invariant_noncesAndStatuses() public view {
        for (uint256 a; a < 3; ++a) {
            uint256 id = uint256(uint160(handler.accounts(a)));
            for (uint256 n; n < 31; ++n) {
                assertEq(registry.isMoveNonceUsed(id, n), handler.spent(a, n));
            }
        }
        for (uint256 r; r < 3; ++r) {
            bytes32 root = handler.roots(r);
            (IPackageRegistry.PackageStatus status,,) = registry.packageOf(root);
            assertEq(uint8(status), handler.statusOf(root));
        }
    }

    /// @notice Handler self-test: each action both succeeds (writing the registry, Stream's
    ///         content stand-in or the artist registry) and, where the model has a forbidden
    ///         case, is refused there; rebinding only ever reaches a refusal. Then every
    ///         invariant holds on the state the drive left.
    function test_HandlerPathsReachState() public {
        uint8 wr = HandlerReach.WRITES | HandlerReach.REFUSED;
        HandlerReach.Expect[] memory e = new HandlerReach.Expect[](8);
        e[0] = HandlerReach.Expect(CurationHandler.consume.selector, wr);
        e[1] = HandlerReach.Expect(CurationHandler.release.selector, wr);
        e[2] = HandlerReach.Expect(CurationHandler.revokeMove.selector, wr);
        e[3] = HandlerReach.Expect(CurationHandler.rotate.selector, HandlerReach.WRITES);
        e[4] = HandlerReach.Expect(CurationHandler.revokePackage.selector, wr);
        e[5] = HandlerReach.Expect(CurationHandler.registerLate.selector, wr);
        e[6] = HandlerReach.Expect(CurationHandler.acceptLate.selector, wr);
        e[7] = HandlerReach.Expect(CurationHandler.rebind.selector, HandlerReach.REFUSED);
        HandlerReach.covers(targetSelectors()[0].selectors, e);
        address[] memory sut = new address[](3);
        sut[0] = address(registry);
        sut[1] = stream;
        sut[2] = address(artists);
        HandlerReach.check(e, HandlerReach.drive(address(handler), e, sut, 160, 1));
        assertGt(handler.consumed(), 0);
        assertGt(handler.releases(), 0);
        invariant_noUnexpectedSuccess();
        invariant_noUnexpectedFailure();
        invariant_itemConsumedAtMostOnce();
        invariant_contentRecordsMatch();
        invariant_noncesAndStatuses();
    }
}
