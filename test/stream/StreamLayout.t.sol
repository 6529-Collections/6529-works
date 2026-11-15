// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IStreamViews } from "src/interfaces/IStreamViews.sol";
import { SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { StreamLayout } from "src/stream/StreamLayout.sol";
import { StreamFixture } from "./StreamFixture.sol";

/// @notice H-1 (review A): Stream's storage slots that `StreamLayout` names are part of its
///         permanent interface, read by a pinned renderer through `extsload` instead of the
///         replaceable view extension. Each slot and its packing is pinned here against what the
///         compiler laid out, read back through the native views: a change to `Stream`'s state
///         variables that moved one fails this test (and Stream, never redeployed, can then never
///         ship).
contract StreamLayoutTest is StreamFixture {
    function _word(bytes32 slot) internal view returns (uint256) {
        return uint256(stream.extsload(slot, 1)[0]);
    }

    /// @dev A storage string at `slot`, decoded as Solidity lays it out.
    function _string(uint256 slot) internal view returns (string memory) {
        uint256 head = _word(bytes32(slot));
        if (head & 1 == 0) {
            bytes memory short = new bytes((head & 0xff) >> 1);
            for (uint256 i; i < short.length; ++i) {
                short[i] = bytes1(uint8(head >> (248 - 8 * i)));
            }
            return string(short);
        }
        uint256 size = (head - 1) >> 1;
        bytes32[] memory words = stream.extsload(keccak256(abi.encode(slot)), (size + 31) >> 5);
        bytes memory long = abi.encodePacked(words);
        assembly ("memory-safe") {
            mstore(long, size)
        }
        return string(long);
    }

    function test_TokenWordsAreAtTheirPermanentSlots() public {
        PackageItem memory item = _item(41);
        item.kind = 1;
        item.seedPolicy = uint8(SeedPolicy.ARTIST);
        item.seed = keccak256("an artist seed");
        _mint(_item(40));
        uint256 id = _mint(item);
        auction.settle(stream, id);
        bytes32[] memory w = stream.extsload(StreamLayout.tokenSlot(id), 2);
        uint256 word = uint256(w[0]);
        (bytes32 itemHash,, uint256 collection, uint8 kind, uint8 seedPolicy,) = stream.coreOf(id);
        IStreamViews.WorkCore memory core = IStreamViews(address(stream)).work(id);
        assertEq(address(uint160(word)), core.seller, "seller, bits 0-159");
        assertEq(uint32(word >> 160), core.serial, "serial, bits 160-191");
        assertEq(core.serial, 2);
        assertEq(uint32(word >> 192), collection, "collection, bits 192-223");
        uint8 flags = uint8(word >> 224);
        assertEq(flags & 3, kind, "kind, flag bits 0-1");
        assertEq((flags >> 2) & 3, seedPolicy, "seed policy, flag bits 2-3");
        assertEq(seedPolicy, uint8(SeedPolicy.ARTIST));
        assertTrue(flags & 16 != 0, "settled, flag 16");
        assertEq(w[1], itemHash, "the item hash in the next slot");
    }

    function test_CollectionWordsAreAtTheirPermanentSlots() public {
        string memory long = "A collection name longer than one storage word, so it is stored apart";
        vm.prank(platform);
        uint256 id = stream.createCollection(long, keccak256("long"));
        PackageItem memory item = _item(42);
        item.collectionId = id;
        _mint(item);
        uint256 base = uint256(StreamLayout.collectionSlot(id));
        uint256 head = _word(bytes32(base));
        assertTrue(head & 0xff != 0, "exists, bits 0-7");
        assertEq(uint32(head >> 8), 1, "minted, bits 8-39");
        assertEq(bytes32(_word(bytes32(base + 1))), keccak256("long"), "metadata hash at + 1");
        assertEq(_string(base + 2), long, "a long name at + 2");
        assertEq(IStreamViews(address(stream)).collection(id).name, long);
        uint256 genesis = uint256(StreamLayout.collectionSlot(collectionId));
        assertEq(_string(genesis + 2), "Genesis", "a short name at + 2");
        assertEq(_word(StreamLayout.collectionSlot(99)), 0, "an unknown collection is empty");
    }

    function test_CountsOwnerAndContractUriAreAtTheirPermanentSlots() public {
        _mint(43);
        uint256 burned = _mint(44);
        auction.burn(stream, burned, 1);
        string memory uri = "ipfs://a-contract-uri-long-enough-to-need-its-own-storage-words";
        vm.startPrank(governor);
        stream.setContractURI(uri);
        stream.setOwner(marketOwner, address(0xB0B));
        vm.stopPrank();
        uint256 counts = _word(bytes32(StreamLayout.COUNTS_SLOT));
        assertEq(uint64(counts), stream.totalMinted(), "minted, bits 0-63");
        assertEq(uint64(counts >> 64), 1, "burned, bits 64-127");
        assertEq(uint32(counts >> 128), stream.collectionCount(), "collections, bits 128-159");
        assertEq(address(uint160(_word(bytes32(StreamLayout.OWNER_SLOT)))), stream.owner());
        assertEq(stream.owner(), address(0xB0B));
        assertEq(_string(StreamLayout.CONTRACT_URI_SLOT), stream.contractURI());
        assertEq(stream.contractURI(), uri);
    }
}
