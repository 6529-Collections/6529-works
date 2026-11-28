// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StreamHashing } from "../../src/interfaces/types/StreamHashing.sol";
import {
    EditionTerms,
    ItemKind,
    License,
    PackageItem,
    Party,
    PartyRole,
    SaleTerms,
    SeedPolicy
} from "../../src/interfaces/types/PackageTypes.sol";
import { FileRole, MediaFile } from "../../src/interfaces/types/ContentTypes.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_EDITIONS,
    PRODUCT_INDEPENDENT,
    PRODUCT_STREAM
} from "../../src/interfaces/types/EconomicsTypes.sol";
import { ISplitWallet } from "../../src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "../../src/economics/Splits.sol";
import { SaleKind } from "../../src/interfaces/types/SaleTypes.sol";

/// @dev Golden vectors were computed independently with Foundry's `cast abi-encode` and
///      `cast keccak`, the way off-chain tooling builds them, so these tests pin the encoding
///      itself and not only the Solidity library.
contract StreamHashingTest is Test {
    address internal constant A1 = 0x1111111111111111111111111111111111111111;
    address internal constant A2 = 0x2222222222222222222222222222222222222222;
    address internal constant A3 = 0x3333333333333333333333333333333333333333;

    bytes32 internal constant GOLDEN_MEDIA_HASH =
        0x37db9f4e1f154da4956bdeac192e36f3d3a3aad9789431fccbcf4b03db809167;
    bytes32 internal constant GOLDEN_ITEM_HASH =
        0x1ccc77b2e21031b9ba42652ace4d486deb9f6ae9f36483a72bc10033ec5dfb3d;
    bytes32 internal constant GOLDEN_LEAF =
        0xde93f09beaea0edbe91b3c103a4326ffdfcaacee6aae651f6cb274bf8d65a8d4;
    bytes32 internal constant GOLDEN_CC0_KEY =
        0xc524702ec980d5da7df189fec7f0c9b69529a70700cfd88d07f8cc34d042ad71;

    function _media() internal pure returns (MediaFile[] memory media) {
        media = new MediaFile[](2);
        media[0] = MediaFile(keccak256("file1"), keccak256("sha1"), uint8(FileRole.PRIMARY));
        media[1] = MediaFile(keccak256("file2"), keccak256("sha2"), uint8(FileRole.PREVIEW));
    }

    /// @dev A lead artist, a credited and paid collaborator (artist-resolved), and a fixed payee
    ///      who is also a party, in canonical payee order: fixed first, then by artist ID.
    function _item() internal pure returns (PackageItem memory item) {
        item.kind = uint8(ItemKind.EDITION_MASTER);
        item.collectionId = 7;
        item.contentHash = keccak256("sha1");
        item.mediaHash = StreamHashing.mediaHash(_media());
        item.recordFileId = keccak256("record");
        item.parties = new Party[](3);
        item.parties[0] = Party(A1, uint8(PartyRole.ARTIST));
        item.parties[1] = Party(A2, uint8(PartyRole.COLLABORATOR));
        item.parties[2] = Party(A3, uint8(PartyRole.COLLABORATOR));
        item.payees = new ISplitWallet.Payee[](3);
        item.payees[0] = ISplitWallet.Payee(0, A3, 10_000);
        item.payees[1] = ISplitWallet.Payee(uint256(uint160(A1)), address(0), 65_000);
        item.payees[2] = ISplitWallet.Payee(uint256(uint160(A2)), address(0), 25_000);
        item.license = License("CC0-1.0", keccak256("cc0 text"));
        item.seedPolicy = uint8(SeedPolicy.ARTIST);
        item.seed = keccak256("seed");
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_DEFAULT, "");
        item.edition = EditionTerms(100, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
    }

    function test_domainLabels() public pure {
        assertEq(StreamHashing.PACKAGE_ITEM_DOMAIN, keccak256("6529STREAM_PACKAGE_ITEM_V1"));
        assertEq(StreamHashing.MEDIA_DOMAIN, keccak256("6529STREAM_MEDIA_V1"));
    }

    function test_constants() public pure {
        assertEq(Splits.DENOMINATOR, 100_000);
        assertEq(CURRENCY_ETH, address(0));
        assertEq(CURRENCY_DEFAULT, 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        assertEq(SaleKind.ENGLISH_AUCTION, keccak256("ENGLISH_AUCTION"));
        assertEq(SaleKind.UNIFORM_AUCTION, keccak256("UNIFORM_AUCTION"));
        assertEq(PRODUCT_STREAM, 0x8d6f9a2373152dc58ba78e223790bc7f77f86abeb152249f9dfa37dfb9f47de2);
        assertEq(
            PRODUCT_EDITIONS, 0xdda24e9b6aae8e08617e9965b04fb0c49afa288965fbdf1734798e07309ffb7b
        );
        assertEq(
            PRODUCT_INDEPENDENT, 0xceae10eeadd6514ab815b7d46a9e2a6acffb06f8b066a317051724d4676d4051
        );
    }

    function test_mediaHash_golden() public pure {
        assertEq(StreamHashing.mediaHash(_media()), GOLDEN_MEDIA_HASH);
        MediaFile[] memory media = _media();
        media[1].role = uint8(FileRole.AUXILIARY);
        assertTrue(StreamHashing.mediaHash(media) != GOLDEN_MEDIA_HASH);
    }

    function test_itemHash_golden() public pure {
        bytes32 itemHash = StreamHashing.itemHash(_item());
        assertEq(itemHash, GOLDEN_ITEM_HASH);
        assertEq(StreamHashing.leaf(itemHash), GOLDEN_LEAF);
        assertEq(StreamHashing.leaf(itemHash), keccak256(abi.encode(itemHash)));
    }

    /// @dev External entry so the item arrives in calldata.
    function hashCalldata(PackageItem calldata item) external pure returns (bytes32) {
        return StreamHashing.itemHashCalldata(item);
    }

    function test_itemHashCalldata_matchesMemory() public view {
        assertEq(this.hashCalldata(_item()), GOLDEN_ITEM_HASH);
    }

    function test_licenseKey_isCaseInsensitive() public pure {
        assertEq(StreamHashing.CC0_LICENSE_KEY, GOLDEN_CC0_KEY);
        assertEq(StreamHashing.licenseKey("CC0-1.0"), GOLDEN_CC0_KEY);
        assertEq(StreamHashing.licenseKey("cc0-1.0"), GOLDEN_CC0_KEY);
        assertEq(StreamHashing.licenseKey("Cc0-1.0"), GOLDEN_CC0_KEY);
        assertTrue(StreamHashing.licenseKey("CC-BY-4.0") != GOLDEN_CC0_KEY);
    }

    function testFuzz_licenseKey_matchesLowercase(bytes32 raw) public pure {
        bytes memory id = new bytes(32);
        bytes memory lower = new bytes(32);
        for (uint256 i; i < 32; ++i) {
            bytes1 c = raw[i];
            id[i] = c;
            lower[i] = (c >= "A" && c <= "Z") ? bytes1(uint8(c) + 32) : c;
        }
        assertEq(StreamHashing.licenseKey(string(id)), keccak256(lower));
    }

    /// @dev Package roots are chain-independent: no chain ID enters the item hash.
    function testFuzz_itemHash_independentOfChain(uint64 chainId) public {
        vm.assume(chainId != 0);
        vm.chainId(chainId);
        assertEq(StreamHashing.itemHash(_item()), GOLDEN_ITEM_HASH);
    }

    function testFuzz_itemHash_bindsCollection(uint256 collectionId) public pure {
        vm.assume(collectionId != 7);
        PackageItem memory item = _item();
        item.collectionId = collectionId;
        assertTrue(StreamHashing.itemHash(item) != GOLDEN_ITEM_HASH);
    }

    function testFuzz_itemHash_bindsShares(uint32 share) public pure {
        vm.assume(share != 65_000);
        PackageItem memory item = _item();
        item.payees[1].share = share;
        assertTrue(StreamHashing.itemHash(item) != GOLDEN_ITEM_HASH);
    }

    function test_itemHash_bindsMediaPayeeKindAndCurrency() public pure {
        PackageItem memory item = _item();
        MediaFile[] memory media = _media();
        media[1].fileId = keccak256("swapped");
        item.mediaHash = StreamHashing.mediaHash(media);
        assertTrue(StreamHashing.itemHash(item) != GOLDEN_ITEM_HASH);
        item = _item();
        item.payees[1] = ISplitWallet.Payee(0, A1, 65_000);
        assertTrue(StreamHashing.itemHash(item) != GOLDEN_ITEM_HASH);
        item = _item();
        item.sale.currency = CURRENCY_ETH;
        assertTrue(StreamHashing.itemHash(item) != GOLDEN_ITEM_HASH);
        item = _item();
        item.kind = uint8(ItemKind.ORIGINAL);
        assertTrue(StreamHashing.itemHash(item) != GOLDEN_ITEM_HASH);
    }

    /// @dev Domain separation: the same struct bytes under another label hash differently.
    function test_itemHash_isDomainSeparated() public pure {
        PackageItem memory item = _item();
        assertTrue(StreamHashing.itemHash(item) != keccak256(abi.encode(item)));
        assertTrue(
            StreamHashing.itemHash(item) != keccak256(abi.encode(StreamHashing.MEDIA_DOMAIN, item))
        );
    }

    function test_singleItemPackage_rootIsLeaf() public pure {
        bytes32 itemHash = StreamHashing.itemHash(_item());
        bytes32 root = StreamHashing.leaf(itemHash);
        assertTrue(StreamHashing.isItem(new bytes32[](0), root, itemHash));
        // The item hash itself is not the root: the leaf is double-hashed.
        assertFalse(StreamHashing.isItem(new bytes32[](0), itemHash, itemHash));
    }

    function test_threeItemPackage_proofs() public pure {
        bytes32[3] memory hashes;
        bytes32[3] memory leaves;
        for (uint256 i; i < 3; ++i) {
            PackageItem memory item = _item();
            item.collectionId = i + 1;
            item.contentHash = keccak256(abi.encode("content", i));
            hashes[i] = StreamHashing.itemHash(item);
            leaves[i] = StreamHashing.leaf(hashes[i]);
        }
        bytes32 node01 = _pair(leaves[0], leaves[1]);
        bytes32 root = _pair(node01, leaves[2]);

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaves[1];
        proof[1] = leaves[2];
        assertTrue(StreamHashing.isItem(proof, root, hashes[0]));
        proof[0] = leaves[0];
        assertTrue(StreamHashing.isItem(proof, root, hashes[1]));
        bytes32[] memory short = new bytes32[](1);
        short[0] = node01;
        assertTrue(StreamHashing.isItem(short, root, hashes[2]));

        // An unlisted item does not verify.
        PackageItem memory other = _item();
        other.collectionId = 99;
        assertFalse(StreamHashing.isItem(short, root, StreamHashing.itemHash(other)));
        // An inner node cannot pass as an item (second-preimage guard).
        short[0] = leaves[2];
        assertFalse(StreamHashing.isItem(short, root, node01));
    }

    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }
}
