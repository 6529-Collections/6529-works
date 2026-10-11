// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { WorksHashing } from "../../src/interfaces/types/WorksHashing.sol";
import {
    EditionFormat,
    EditionTerms,
    ItemKind,
    License,
    PackageItem,
    Party,
    PartyRole,
    SaleTerms,
    SeedPolicy
} from "../../src/interfaces/types/PackageTypes.sol";
import {
    Attribute,
    ContentFile,
    DependencyRef,
    FileRole,
    Work
} from "../../src/interfaces/types/ContentTypes.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    SHARE_DENOMINATOR,
    SplitRecipient
} from "../../src/interfaces/types/EconomicsTypes.sol";
import { SaleKind } from "../../src/interfaces/types/SaleTypes.sol";

/// @dev Golden vectors were computed independently with Foundry's `cast abi-encode` and
///      `cast keccak`, the way off-chain tooling builds them, so these tests pin the encoding
///      itself and not only the Solidity library.
contract WorksHashingTest is Test {
    address internal constant A1 = 0x1111111111111111111111111111111111111111;
    address internal constant A2 = 0x2222222222222222222222222222222222222222;

    bytes32 internal constant GOLDEN_SPLIT_ID =
        0x4186dfcc05a326c030fa3cd00c82314e836d420bf744af38d224a9456eca5c68;
    bytes32 internal constant GOLDEN_ITEM_HASH =
        0x57a38fca6197a1289624f813e33342b1df992b7a8ee6e65316c643d06fdd1488;
    bytes32 internal constant GOLDEN_LEAF =
        0xccd5d4a9f7361fa00614dd702b9fb300419bc702852b2156fff4158915c9b53e;
    bytes32 internal constant GOLDEN_WORK_HASH =
        0x6b4de16764850366c1b437cbb70a951bd364b5419f7af48a390a5a3e654e7a53;

    function _parties() internal pure returns (Party[] memory parties) {
        parties = new Party[](2);
        parties[0] = Party(A1, 75_000, PartyRole.ARTIST);
        parties[1] = Party(A2, 25_000, PartyRole.COLLABORATOR);
    }

    function _item() internal pure returns (PackageItem memory item) {
        item.kind = ItemKind.EDITION_MASTER;
        item.collectionId = 7;
        item.contentId = keccak256("content");
        item.metadataHash = keccak256("metadata");
        item.parties = _parties();
        item.split = WorksHashing.partySplitId(item.parties);
        item.license = License("CC0-1.0", keccak256("cc0 text"));
        item.seedPolicy = SeedPolicy.ARTIST;
        item.seed = keccak256("seed");
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_DEFAULT, "");
        item.edition = EditionTerms(
            EditionFormat.FIXED, 100, 0, 0.05 ether, CURRENCY_ETH, SaleKind.FIXED_PRICE, ""
        );
    }

    function _work() internal pure returns (Work memory work) {
        work.title = "Title";
        work.description = "Desc";
        work.artists = new string[](2);
        work.artists[0] = "Alice";
        work.artists[1] = "Bob";
        work.year = 2026;
        work.medium = "Digital";
        work.dimensions = "1920 x 1080 px";
        work.attributes = new Attribute[](1);
        work.attributes[0] = Attribute("Palette", "Warm");
        work.media = new ContentFile[](2);
        work.media[0] = ContentFile(keccak256("file1"), FileRole.PRIMARY, "index.png");
        work.media[1] = ContentFile(keccak256("file2"), FileRole.PREVIEW, "preview.png");
        work.dependencies = new DependencyRef[](1);
        work.dependencies[0] = DependencyRef(bytes32("p5"), bytes32("1.9.0"));
    }

    function test_domainLabels() public pure {
        assertEq(WorksHashing.PACKAGE_ITEM_DOMAIN, keccak256("6529WORKS_PACKAGE_ITEM_V1"));
        assertEq(WorksHashing.WORK_RECORD_DOMAIN, keccak256("6529WORKS_WORK_RECORD_V1"));
        assertEq(WorksHashing.SPLIT_DOMAIN, keccak256("6529WORKS_SPLIT_V1"));
    }

    function test_constants() public pure {
        assertEq(SHARE_DENOMINATOR, 100_000);
        assertEq(CURRENCY_ETH, address(0));
        assertEq(CURRENCY_DEFAULT, 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        assertEq(SaleKind.ENGLISH_AUCTION, keccak256("ENGLISH_AUCTION"));
        assertEq(SaleKind.FIXED_PRICE, keccak256("FIXED_PRICE"));
        assertEq(SaleKind.DUTCH, keccak256("DUTCH"));
    }

    function test_itemHash_golden() public pure {
        bytes32 itemHash = WorksHashing.itemHash(_item());
        assertEq(itemHash, GOLDEN_ITEM_HASH);
        assertEq(WorksHashing.leaf(itemHash), GOLDEN_LEAF);
        assertEq(WorksHashing.leaf(itemHash), keccak256(abi.encode(itemHash)));
    }

    function test_workRecordHash_golden() public pure {
        assertEq(WorksHashing.workRecordHash(_work()), GOLDEN_WORK_HASH);
    }

    function test_partySplitId_golden() public pure {
        assertEq(WorksHashing.partySplitId(_parties()), GOLDEN_SPLIT_ID);
        SplitRecipient[] memory recipients = new SplitRecipient[](2);
        recipients[0] = SplitRecipient(A1, 75_000, true);
        recipients[1] = SplitRecipient(A2, 25_000, true);
        assertEq(WorksHashing.splitId(recipients), GOLDEN_SPLIT_ID);
        // A non-resolved recipient is a different split.
        recipients[1].artistResolved = false;
        assertTrue(WorksHashing.splitId(recipients) != GOLDEN_SPLIT_ID);
    }

    /// @dev Package roots are chain-independent: no chain ID enters the item hash.
    function testFuzz_itemHash_independentOfChain(uint64 chainId) public {
        vm.assume(chainId != 0);
        vm.chainId(chainId);
        assertEq(WorksHashing.itemHash(_item()), GOLDEN_ITEM_HASH);
    }

    function testFuzz_itemHash_bindsCollection(uint256 collectionId) public pure {
        vm.assume(collectionId != 7);
        PackageItem memory item = _item();
        item.collectionId = collectionId;
        assertTrue(WorksHashing.itemHash(item) != GOLDEN_ITEM_HASH);
    }

    function testFuzz_itemHash_bindsShares(uint32 share) public pure {
        vm.assume(share != 75_000);
        PackageItem memory item = _item();
        item.parties[0].share = share;
        assertTrue(WorksHashing.itemHash(item) != GOLDEN_ITEM_HASH);
    }

    function test_itemHash_bindsCurrencyAndKind() public pure {
        PackageItem memory item = _item();
        item.sale.currency = CURRENCY_ETH;
        assertTrue(WorksHashing.itemHash(item) != GOLDEN_ITEM_HASH);
        item = _item();
        item.kind = ItemKind.ORIGINAL;
        assertTrue(WorksHashing.itemHash(item) != GOLDEN_ITEM_HASH);
    }

    /// @dev Domain separation: the same struct bytes under another label hash differently.
    function test_itemHash_isDomainSeparated() public pure {
        PackageItem memory item = _item();
        assertTrue(WorksHashing.itemHash(item) != keccak256(abi.encode(item)));
        assertTrue(
            WorksHashing.itemHash(item)
                != keccak256(abi.encode(WorksHashing.WORK_RECORD_DOMAIN, item))
        );
    }

    function test_singleItemPackage_rootIsLeaf() public pure {
        bytes32 itemHash = WorksHashing.itemHash(_item());
        bytes32 root = WorksHashing.leaf(itemHash);
        assertTrue(WorksHashing.isItem(new bytes32[](0), root, itemHash));
        // The item hash itself is not the root: the leaf is double-hashed.
        assertFalse(WorksHashing.isItem(new bytes32[](0), itemHash, itemHash));
    }

    function test_threeItemPackage_proofs() public pure {
        bytes32[3] memory hashes;
        bytes32[3] memory leaves;
        for (uint256 i; i < 3; ++i) {
            PackageItem memory item = _item();
            item.collectionId = i + 1;
            item.contentId = keccak256(abi.encode("content", i));
            hashes[i] = WorksHashing.itemHash(item);
            leaves[i] = WorksHashing.leaf(hashes[i]);
        }
        bytes32 node01 = _pair(leaves[0], leaves[1]);
        bytes32 root = _pair(node01, leaves[2]);

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaves[1];
        proof[1] = leaves[2];
        assertTrue(WorksHashing.isItem(proof, root, hashes[0]));
        proof[0] = leaves[0];
        assertTrue(WorksHashing.isItem(proof, root, hashes[1]));
        bytes32[] memory short = new bytes32[](1);
        short[0] = node01;
        assertTrue(WorksHashing.isItem(short, root, hashes[2]));

        // An unlisted item does not verify.
        PackageItem memory other = _item();
        other.collectionId = 99;
        assertFalse(WorksHashing.isItem(short, root, WorksHashing.itemHash(other)));
        // An inner node cannot pass as an item (second-preimage guard).
        short[0] = leaves[2];
        assertFalse(WorksHashing.isItem(short, root, node01));
    }

    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }
}
