// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
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

/// @dev Gas of the policy's share of an auction start (`IMintPolicy.authorize`: the item rules,
///      the consume with its move-signature check, the content check against Stream and the
///      terms quote against stub economics), measured cold around the external call as the sale
///      contract makes it, logged only (the start's ceiling is measured end to end at
///      integration); and worst cases against the EIP-7825 transaction cap.
contract PackageRegistryGasTest is CurationBase {
    uint256 internal constant TX_GAS_CAP = 16_777_216;

    /// @dev A one-party ORIGINAL in a 16-item package (proof depth 4): an artist's first start.
    ///      The acceptance that created the identity already wrote the nonce word's sentinel.
    function test_gas_consume_typical() public {
        (bytes32 root, PackageItem memory item, bytes32[] memory proof) = _packaged(16, 3);
        MoveAuthorization memory move = _move(leadKey, root, _hash(item), 0);
        uint256 used = _measure(address(minter), _authorizeCall(root, item, proof, move));
        emit log_named_uint("consume, 1 party, depth 4", used);
    }

    /// @dev A nonce past the first 255 lands in a new bitmap word: one fresh slot more.
    function test_gas_consume_newNonceWord() public {
        (bytes32 root, PackageItem memory item, bytes32[] memory proof) = _packaged(16, 3);
        MoveAuthorization memory move = _move(leadKey, root, _hash(item), 300);
        uint256 used = _measure(address(minter), _authorizeCall(root, item, proof, move));
        emit log_named_uint("consume, 1 party, depth 4, new nonce word", used);
    }

    /// @dev An edition master credited to a collaborator (two parties, two payees).
    function test_gas_consume_withCollaborator() public {
        PackageItem memory item = _masterItem(keccak256("master"));
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        _accept(root, leadKey);
        _accept(root, collabKey);
        MoveAuthorization memory move = _move(leadKey, root, _hash(item), 0);
        uint256 used = _measure(address(minter), _authorizeCall(root, item, new bytes32[](0), move));
        emit log_named_uint("consume, 2 parties, depth 0", used);
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
        registry.acceptPackage(
            root, acc, _as(address(safe), _sig(leadKey, registry.acceptanceDigest(root, acc)))
        );
        for (uint256 i = 1; i < 16; ++i) {
            _accept(root, 0x100 + i);
        }
        MoveAuthorization memory move = _move(leadKey, root, _hash(item), 0);
        move.signature =
            _as(address(safe), _sig(leadKey, registry.moveDigest(root, _hash(item), 0, deadline)));
        bytes memory data = _authorizeCall(root, item, proof, move);
        uint256 used = _measure(address(minter), data);
        uint256 total = _txGas(data, used);
        emit log_named_uint("consume worst case, execution", used);
        emit log_named_uint("consume worst case, whole transaction", total);
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
        return abi.encodeCall(
            IMintPolicy.authorize, (stream, abi.encode(StreamMintRequest(root, item, proof, move)))
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
        vm.cool(address(_policyStub));
        vm.cool(stream);
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
