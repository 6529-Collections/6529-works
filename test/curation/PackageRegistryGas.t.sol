// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StreamContentMock } from "test/mocks/curation/StreamContentMock.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IMintPolicy } from "src/interfaces/IMintPolicy.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    MoveAuthorization,
    PackageItem,
    Party,
    PartyAcceptance,
    PartyRole,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { ERC1271WalletMock } from "test/mocks/libraries/AdversarialTargets.sol";
import { CurationBase } from "./CurationBase.sol";

/// @dev Gas on the auction-start path (`IMintPolicy.authorize`: the item rules, the consume with
///      its move-signature check, and the terms quote against stub economics) and
///      on edition creation (`claimContent`), measured cold around the external call as 6529
///      Stream and 6529 Stream Editions make it; and worst cases against the EIP-7825 transaction
///      cap. Neither path reads the content store: uniqueness keys on the item's declared hash.
contract PackageRegistryGasTest is CurationBase {
    /// @dev Regression gates, measured with every account and slot cold, which overstates a
    ///      real start where some of them are already warm. `authorize` runs the item rules, the
    ///      consume and the terms quote (stub economics and factory); since AUC-44 it writes no
    ///      content record (Stream does). Measured: 43,787 (first work), 60,907 (a nonce past
    ///      the artist's first bitmap word), 48,111 (two parties), 29,647 (edition claim) and
    ///      77,758 for a two-party master plus its edition claim; each gate is about 3% above.
    uint256 internal constant CONSUME_BUDGET = 46_000;
    uint256 internal constant CONSUME_NEW_WORD_BUDGET = 63_000;
    uint256 internal constant CONSUME_TWO_PARTIES_BUDGET = 50_000;
    uint256 internal constant CLAIM_BUDGET = 31_000;
    /// @dev `authorize` on the auction start plus `claimContent` on the edition's creation.
    uint256 internal constant PAIR_BUDGET = 81_000;
    uint256 internal constant TX_GAS_CAP = 16_777_216;

    /// @dev A one-party ORIGINAL in a 16-item package (proof depth 4): an artist's first start.
    ///      The acceptance that created the identity already wrote the nonce word's sentinel.
    function test_gas_consume_typical() public {
        (bytes32 root, PackageItem memory item, bytes32[] memory proof) = _packaged(16, 3);
        MoveAuthorization memory move = _move(leadKey, root, _hash(item), 0);
        uint256 used = _measure(stream, _authorizeCall(root, item, proof, move));
        emit log_named_uint("consume, 1 party, depth 4", used);
        assertLe(used, CONSUME_BUDGET);
    }

    /// @dev A nonce past the first 255 lands in a new bitmap word: one fresh slot more.
    function test_gas_consume_newNonceWord() public {
        (bytes32 root, PackageItem memory item, bytes32[] memory proof) = _packaged(16, 3);
        MoveAuthorization memory move = _move(leadKey, root, _hash(item), 300);
        uint256 used = _measure(stream, _authorizeCall(root, item, proof, move));
        emit log_named_uint("consume, 1 party, depth 4, new nonce word", used);
        assertLe(used, CONSUME_NEW_WORD_BUDGET);
    }

    /// @dev An edition master credited to a collaborator (two parties, two payees).
    function test_gas_consume_withCollaborator() public {
        PackageItem memory item = _masterItem(keccak256("master"));
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        _accept(root, leadKey);
        _accept(root, collabKey);
        MoveAuthorization memory move = _move(leadKey, root, _hash(item), 0);
        uint256 used = _measure(stream, _authorizeCall(root, item, new bytes32[](0), move));
        emit log_named_uint("consume, 2 parties, depth 0", used);
        assertLe(used, CONSUME_TWO_PARTIES_BUDGET);
    }

    /// @dev The linked pair end to end: the master's `consume`, then its edition's
    ///      `claimContent`, each measured cold.
    function test_gas_consumeAndClaimContent() public {
        PackageItem memory item = _masterItem(keccak256("master"));
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        _accept(root, leadKey);
        _accept(root, collabKey);
        MoveAuthorization memory move = _move(leadKey, root, _hash(item), 0);
        uint256 consumed = _measure(stream, _authorizeCall(root, item, new bytes32[](0), move));
        StreamContentMock(stream).setConsumed(item.contentHash, _hash(item)); // Stream's record
        uint256 claimed = _measure(
            editions, abi.encodeCall(PackageRegistry.claimContent, (item.contentHash, _hash(item)))
        );
        emit log_named_uint("claimContent (edition of a master)", claimed);
        emit log_named_uint("consume + claimContent", consumed + claimed);
        assertLe(claimed, CLAIM_BUDGET);
        assertLe(consumed + claimed, PAIR_BUDGET);
    }

    /// @dev Worst case: 16 parties, 16 artist-resolved payees, a 32-deep proof and a lead whose
    ///      authority is an ERC-1271 wallet. Execution plus intrinsic and calldata gas stays far
    ///      below the 16,777,216 cap.
    function test_txCap_consumeWorstCase() public {
        ERC1271WalletMock safe = new ERC1271WalletMock(lead);
        address[] memory accounts = new address[](16);
        accounts[0] = address(safe);
        for (uint256 i = 1; i < 16; ++i) {
            accounts[i] = vm.addr(0x100 + i);
        }
        PackageItem memory item = _item(address(safe), keccak256("worst"));
        item.parties = new Party[](16);
        item.payees = new ISplitWallet.Payee[](16);
        uint256[] memory ids = new uint256[](16);
        for (uint256 i; i < 16; ++i) {
            item.parties[i] = Party(
                accounts[i], i == 0 ? uint8(PartyRole.ARTIST) : uint8(PartyRole.COLLABORATOR)
            );
            ids[i] = _id(accounts[i]);
        }
        _sortAscending(ids);
        for (uint256 i; i < 16; ++i) {
            item.payees[i] = ISplitWallet.Payee(ids[i], address(0), 6_250);
        }
        bytes32[] memory proof = new bytes32[](Limits.MAX_PROOF_DEPTH);
        bytes32 node = WorksHashing.leaf(_hash(item));
        for (uint256 i; i < proof.length; ++i) {
            proof[i] = keccak256(abi.encode("sibling", i));
            (bytes32 a, bytes32 b) = node < proof[i] ? (node, proof[i]) : (proof[i], node);
            node = keccak256(abi.encode(a, b));
        }
        bytes32 root = node;
        _register(root);
        PartyAcceptance memory acc = _acceptance(address(safe));
        registry.acceptPackage(root, acc, _sig(leadKey, registry.acceptanceDigest(root, acc)));
        for (uint256 i = 1; i < 16; ++i) {
            _accept(root, 0x100 + i);
        }
        MoveAuthorization memory move = _move(leadKey, root, _hash(item), 0);
        bytes memory data = _authorizeCall(root, item, proof, move);
        uint256 used = _measure(stream, data);
        uint256 total = _txGas(data, used);
        emit log_named_uint("consume worst case, execution", used);
        emit log_named_uint("consume worst case, whole transaction", total);
        assertEq(registry.consumedItemOf(item.contentHash), bytes32(0), "Stream records it");
        assertLt(total, TX_GAS_CAP / 16);
    }

    function test_txCap_registerPackageMaxSignature() public {
        bytes32 root = keccak256("root");
        bytes memory sig = new bytes(4096);
        bytes memory data = abi.encodeCall(
            PackageRegistry.registerPackage, (root, EVIDENCE, abi.encode(signer1, sig))
        );
        vm.cool(address(registry));
        uint256 before = gasleft();
        (bool ok,) = address(registry).call(data);
        uint256 used = before - gasleft();
        assertFalse(ok); // not a valid signature; the cost is what matters
        assertLt(_txGas(data, used), TX_GAS_CAP / 16);
    }

    // -------------------------------------------------------------------------- helpers

    /// @dev `IMintPolicy.authorize` as the bound Stream calls it (stub economics and factory).
    function _authorizeCall(
        bytes32 root,
        PackageItem memory item,
        bytes32[] memory proof,
        MoveAuthorization memory move
    ) internal view returns (bytes memory) {
        IMintPolicy.MintContext memory c = IMintPolicy.MintContext(
            stream, address(_policyStub), address(0), address(_policyStub)
        );
        return abi.encodeCall(
            IMintPolicy.authorize, (c, abi.encode(StreamMintRequest(root, item, proof, move)))
        );
    }

    /// @dev A registered `size`-item package whose item `index` is the lead's ORIGINAL.
    function _packaged(uint256 size, uint256 index)
        internal
        returns (bytes32 root, PackageItem memory item, bytes32[] memory proof)
    {
        item = _item(lead, keccak256("typical"));
        bytes32[] memory leaves = new bytes32[](size);
        for (uint256 i; i < size; ++i) {
            leaves[i] = keccak256(abi.encode("other item", i));
        }
        leaves[index] = WorksHashing.leaf(_hash(item));
        root = _root(leaves);
        proof = _proof(leaves, index);
        _register(root);
        _accept(root, leadKey);
    }

    /// @dev Gas of one call from `caller`, with every contract it touches cold.
    function _measure(address caller, bytes memory data) internal returns (uint256 used) {
        vm.cool(address(registry));
        vm.cool(address(artists));
        vm.cool(address(manager));
        vm.prank(caller);
        uint256 before = gasleft();
        (bool ok,) = address(registry).call(data);
        used = before - gasleft();
        assertTrue(ok, "measured call reverted");
    }

    /// @dev Intrinsic plus calldata plus execution, with the EIP-7623 calldata floor.
    function _txGas(bytes memory data, uint256 execution) internal pure returns (uint256) {
        uint256 tokens;
        for (uint256 i; i < data.length; ++i) {
            tokens += data[i] == 0 ? 1 : 4;
        }
        uint256 standard = 21_000 + 4 * tokens + execution;
        uint256 floor = 21_000 + 10 * tokens;
        return standard > floor ? standard : floor;
    }

    function _sortAscending(uint256[] memory a) internal pure {
        for (uint256 i = 1; i < a.length; ++i) {
            for (uint256 j = i; j > 0 && a[j - 1] > a[j]; --j) {
                (a[j - 1], a[j]) = (a[j], a[j - 1]);
            }
        }
    }
}

/// @dev The real call shape (review harness): a Stream-like caller passes the adapter's request,
///      unread, to `IMintPolicy.authorize`; it also answers ERC-165 as Stream and Editions so the
///      registry can bind it.
contract StreamLikeHarness is IERC165 {
    function start(IMintPolicy r, address stub, bytes calldata data)
        external
        returns (uint256 decodeGas, uint256 consumeGas)
    {
        uint256 g0 = gasleft();
        IMintPolicy.MintContext memory c =
            IMintPolicy.MintContext(msg.sender, stub, address(0), stub);
        uint256 g1 = gasleft();
        IMintPolicy.MintRecord memory rec = r.authorize(c, data);
        consumeGas = g1 - gasleft();
        consumedItemOf[rec.contentHash] = rec.itemHash; // as Stream records it (AUC-44)
        return (g0 - g1, consumeGas);
    }

    /// @notice What Stream would answer: the item that minted each content.
    mapping(bytes32 contentHash => bytes32 itemHash) public consumedItemOf;

    function claim(IPackageRegistry r, bytes32 contentHash, bytes32 itemHash)
        external
        returns (uint256 used)
    {
        used = gasleft();
        r.claimContent(contentHash, itemHash);
        used -= gasleft();
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IStream).interfaceId
            || interfaceId == type(IEditions).interfaceId;
    }
}

contract PackageRegistryStreamShapeGasTest is CurationBase {
    StreamLikeHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new StreamLikeHarness();
        registry = _newRegistry(); // the signing helpers use `registry`
        artists.bindPackageRegistry(address(registry));
        vm.startPrank(admin);
        registry.bindStream(address(harness));
        registry.bindEditions(address(harness));
        vm.stopPrank();
    }

    function _start(PackageItem memory item, bytes32 root, bytes32[] memory proof)
        internal
        returns (uint256 decodeGas, uint256 consumeGas)
    {
        bytes memory data = abi.encode(
            StreamMintRequest(root, item, proof, _move(leadKey, root, _hash(item), 0))
        );
        vm.cool(address(registry));
        vm.cool(address(artists));
        vm.cool(address(manager));
        return harness.start(registry, address(_policyStub), data);
    }

    /// @dev One party, a realistic license, a 64-item package (proof depth 6).
    function test_gas_streamShape_typical() public {
        PackageItem memory item = _item(lead, keccak256("typical"));
        item.license.spdxId = "CC-BY-NC-SA-4.0";
        bytes32[] memory leaves = new bytes32[](64);
        for (uint256 i; i < 64; ++i) {
            leaves[i] = keccak256(abi.encode("other item", i));
        }
        leaves[5] = WorksHashing.leaf(_hash(item));
        bytes32 root = _root(leaves);
        _register(root);
        _accept(root, leadKey);
        (uint256 decodeGas, uint256 consumeGas) = _start(item, root, _proof(leaves, 5));
        emit log_named_uint("Stream-side decode of the mint request", decodeGas);
        emit log_named_uint("consume from Stream, 1 party, depth 6", consumeGas);
        assertLe(consumeGas, 48_000); // measured 46,549
    }

    /// @dev A two-party master and its edition claim, each from the bound caller.
    function test_gas_streamShape_masterAndClaim() public {
        PackageItem memory item = _masterItem(keccak256("master"));
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        _accept(root, leadKey);
        _accept(root, collabKey);
        (, uint256 consumeGas) = _start(item, root, new bytes32[](0));
        vm.cool(address(registry));
        uint256 claimGas = harness.claim(registry, item.contentHash, _hash(item));
        emit log_named_uint("consume from Stream, 2 parties", consumeGas);
        emit log_named_uint("claimContent from Editions", claimGas);
        assertLe(consumeGas + claimGas, 82_000); // measured 79,399
    }
}
