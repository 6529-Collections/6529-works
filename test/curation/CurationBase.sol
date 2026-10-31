// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Eip712CurationVerifier } from "src/curation/Eip712CurationVerifier.sol";
import { Roles } from "src/governance/Roles.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { ICurationVerifier } from "src/interfaces/ICurationVerifier.sol";
import { CURRENCY_DEFAULT, CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    EditionTerms,
    ItemKind,
    License,
    MoveAuthorization,
    PackageItem,
    Party,
    PartyAcceptance,
    PartyRole,
    SaleTerms,
    SeedPolicy
} from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { CurationArtistRegistryMock } from "test/mocks/curation/CurationArtistRegistryMock.sol";
import { MockBoundCaller } from "test/mocks/curation/MockBoundCaller.sol";

/// @dev Pure fixtures shared by the curation tests and the invariant handler: items, Merkle
///      trees with sorted-pair hashing, and the three signature forms.
abstract contract CurationHelpers is Test {
    uint256 internal constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    // --------------------------------------------------------------------------- items

    function _id(address account) internal pure returns (uint256) {
        return uint256(uint160(account));
    }

    /// @dev An ORIGINAL by `artist` alone, paid in full through the artist-resolved payee, whose
    ///      primary media has the declared SHA-256 `contentHash`.
    function _item(address artist, bytes32 contentHash)
        internal
        pure
        returns (PackageItem memory i)
    {
        i.kind = ItemKind.ORIGINAL;
        i.collectionId = 1;
        i.contentHash = contentHash;
        i.mediaHash = keccak256(abi.encode("media list", contentHash));
        i.recordFileId = keccak256(abi.encode("record file", contentHash));
        i.parties = new Party[](1);
        i.parties[0] = Party(artist, PartyRole.ARTIST);
        i.payees = new ISplitWallet.Payee[](1);
        i.payees[0] = ISplitWallet.Payee(_id(artist), address(0), 100_000);
        i.license = License("CC0-1.0", keccak256("cc0"));
        i.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
    }

    function _hash(PackageItem memory item) internal pure returns (bytes32) {
        return WorksHashing.itemHash(item);
    }

    // ---------------------------------------------------------------------- merkle trees

    /// @dev The root over `leaves` with sorted-pair hashing; an odd node is carried up unchanged.
    function _root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            level = _up(level);
        }
        return level[0];
    }

    function _proof(bytes32[] memory leaves, uint256 index)
        internal
        pure
        returns (bytes32[] memory proof)
    {
        bytes32[] memory path = new bytes32[](64);
        uint256 depth;
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < level.length) path[depth++] = level[sibling];
            level = _up(level);
            index >>= 1;
        }
        proof = new bytes32[](depth);
        for (uint256 i; i < depth; ++i) {
            proof[i] = path[i];
        }
    }

    function _up(bytes32[] memory level) private pure returns (bytes32[] memory next) {
        next = new bytes32[]((level.length + 1) / 2);
        for (uint256 i; i < next.length; ++i) {
            uint256 l = 2 * i;
            if (l + 1 == level.length) {
                next[i] = level[l];
            } else {
                (bytes32 a, bytes32 b) =
                    level[l] < level[l + 1] ? (level[l], level[l + 1]) : (level[l + 1], level[l]);
                next[i] = keccak256(abi.encode(a, b));
            }
        }
    }

    /// @dev Root and proofs of a package of `items`.
    function _tree(PackageItem[] memory items)
        internal
        pure
        returns (bytes32 root, bytes32[][] memory proofs)
    {
        bytes32[] memory leaves = new bytes32[](items.length);
        for (uint256 i; i < items.length; ++i) {
            leaves[i] = WorksHashing.leaf(_hash(items[i]));
        }
        root = _root(leaves);
        proofs = new bytes32[][](items.length);
        for (uint256 i; i < items.length; ++i) {
            proofs[i] = _proof(leaves, i);
        }
    }

    // ------------------------------------------------------------------------ signatures

    function _sig(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The ERC-2098 64-byte form of the same signature.
    function _compact(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, bytes32(uint256(s) | (uint256(v - 27) << 255)));
    }

    /// @dev The malleable high-s twin of the same signature. It really recovers the signer at
    ///      the precompile level (asserted), so only the low-s rule rejects it.
    function _highS(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        uint8 flipped = v == 27 ? 28 : 27;
        assertEq(ecrecover(digest, flipped, r, highS), vm.addr(key), "malleable twin");
        return abi.encodePacked(r, highS, flipped);
    }
}

/// @dev Shared fixture: a real AccessManager with the curation selectors mapped to their
///      `Roles`, a mock artist registry, two curation signers, and helpers that build items,
///      Merkle trees and every signature the registry checks.
abstract contract CurationBase is CurationHelpers {
    AccessManager internal manager;
    CurationArtistRegistryMock internal artists;
    Eip712CurationVerifier internal verifier;
    PackageRegistry internal registry;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal successor = makeAddr("successor");
    address internal stream;
    address internal editions;

    uint256 internal signerKey1 = 0xC1;
    uint256 internal signerKey2 = 0xC2;
    address internal signer1;
    address internal signer2;

    uint256 internal leadKey = 0xA1;
    uint256 internal collabKey = 0xA2;
    address internal lead;
    address internal collab;

    bytes32 internal constant EVIDENCE = keccak256("evidence: vote + TDH snapshot + rule");
    uint64 internal deadline;

    function setUp() public virtual {
        signer1 = vm.addr(signerKey1);
        signer2 = vm.addr(signerKey2);
        lead = vm.addr(leadKey);
        collab = vm.addr(collabKey);
        deadline = uint64(block.timestamp + 1 days);

        manager = new AccessManager(admin);
        artists = new CurationArtistRegistryMock();
        verifier = new Eip712CurationVerifier(address(manager));
        registry = _newRegistry();
        artists.bindPackageRegistry(address(registry));
        // Stand-ins for the bound 6529 Stream and 6529 Editions, with their ERC-165 answers.
        stream = address(new MockBoundCaller(type(IStream).interfaceId));
        editions = address(new MockBoundCaller(type(IEditions).interfaceId));

        vm.startPrank(admin);
        _map(address(registry), PackageRegistry.revokePackage.selector, Roles.GUARDIAN);
        _map(address(registry), PackageRegistry.setVerifier.selector, Roles.SUCCESSOR_SETTER);
        _map(address(verifier), Eip712CurationVerifier.disableSigner.selector, Roles.GUARDIAN);
        _map(
            address(verifier), Eip712CurationVerifier.enableSigner.selector, Roles.SUCCESSOR_SETTER
        );
        manager.grantRole(Roles.GUARDIAN, guardian, 0);
        manager.grantRole(Roles.SUCCESSOR_SETTER, successor, 0);
        manager.grantRole(Roles.CURATION_SIGNER, signer1, 0);
        manager.grantRole(Roles.CURATION_SIGNER, signer2, 0);
        registry.bindStream(stream);
        registry.bindEditions(editions);
        vm.stopPrank();
    }

    function _newRegistry() internal returns (PackageRegistry) {
        return new PackageRegistry(
            address(manager),
            ICurationVerifier(address(verifier)),
            address(verifier).codehash,
            address(artists),
            address(artists).codehash
        );
    }

    function _map(address target, bytes4 selector, uint64 role) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(target, selectors, role);
    }

    /// @dev An EDITION_MASTER by `lead` with `collab` credited and paid (fixed payee first).
    function _masterItem(bytes32 contentHash) internal view returns (PackageItem memory i) {
        i = _item(lead, contentHash);
        i.kind = ItemKind.EDITION_MASTER;
        i.parties = new Party[](2);
        i.parties[0] = Party(lead, PartyRole.ARTIST);
        i.parties[1] = Party(collab, PartyRole.COLLABORATOR);
        i.payees = new ISplitWallet.Payee[](2);
        i.payees[0] = ISplitWallet.Payee(0, collab, 20_000);
        i.payees[1] = ISplitWallet.Payee(_id(lead), address(0), 80_000);
        i.edition = EditionTerms(100, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
    }

    function _attestation(uint256 key, bytes32 root, bytes32 evidence)
        internal
        view
        returns (bytes memory)
    {
        address signer = vm.addr(key);
        bytes32 digest = verifier.approvalDigest(root, evidence, verifier.signerEpoch(signer));
        return abi.encode(signer, _sig(key, digest));
    }

    function _register(bytes32 root) internal {
        registry.registerPackage(root, EVIDENCE, _attestation(signerKey1, root, EVIDENCE));
    }

    function _acceptance(address account) internal view returns (PartyAcceptance memory) {
        return PartyAcceptance(account, keccak256(abi.encode("profile", account)), 0, deadline);
    }

    function _accept(bytes32 root, uint256 key) internal returns (uint256) {
        PartyAcceptance memory a = _acceptance(vm.addr(key));
        return registry.acceptPackage(root, a, _sig(key, registry.acceptanceDigest(root, a)));
    }

    function _move(uint256 key, bytes32 root, bytes32 itemHash, uint256 nonce)
        internal
        view
        returns (MoveAuthorization memory)
    {
        return MoveAuthorization(
            nonce, deadline, _sig(key, registry.moveDigest(root, itemHash, nonce, deadline))
        );
    }

    function _consume(
        bytes32 root,
        PackageItem memory item,
        bytes32[] memory proof,
        MoveAuthorization memory move
    ) internal returns (bytes32 itemHash, uint256 artistId) {
        vm.prank(stream);
        return registry.consume(root, item, proof, move);
    }

    function _claim(bytes32 contentHash, bytes32 itemHash) internal {
        vm.prank(editions);
        registry.claimContent(contentHash, itemHash);
    }

    /// @dev Stream's dispute-burn path, releasing to `beneficiary`.
    function _release(bytes32 contentHash, bytes32 itemHash, uint256 beneficiary) internal {
        vm.prank(stream);
        registry.releaseContent(contentHash, itemHash, beneficiary);
    }

    /// @dev A registered one-item package by `lead`, accepted, with its move signed at nonce 0.
    function _ready(bytes32 sha)
        internal
        returns (bytes32 root, PackageItem memory item, MoveAuthorization memory move)
    {
        item = _item(lead, sha);
        root = WorksHashing.leaf(_hash(item));
        _register(root);
        _accept(root, leadKey);
        move = _move(leadKey, root, _hash(item), 0);
    }
}
