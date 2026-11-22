// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { StreamDirectory6529 } from "src/core/StreamDirectory6529.sol";
import { StreamEditions6529 } from "src/core/StreamEditions6529.sol";
import { Stream6529 } from "src/core/Stream6529.sol";
import { StreamWorkFacts6529 } from "src/core/StreamWorkFacts6529.sol";
import { MintFacts } from "src/interfaces/core/CoreTypes.sol";
import {
    MockAccounts,
    MockIndependentStreamGate,
    MockRecords,
    MockRenderer,
    MockSale,
    MockTerms
} from "./CoreMocks.sol";

/// @notice The permanent core, deployed with pass-through mock modules: the "mock core" for
///         module lanes and the starting fixture for core lanes. The test contract is the
///         network (the AccessManager's admin, no delay).
abstract contract CoreFixture is Test {
    AccessManager internal manager;
    ContentStore internal store;
    StreamWorkFacts6529 internal facts;
    Stream6529 internal stream;
    StreamEditions6529 internal editions;
    StreamDirectory6529 internal directory;
    MockRenderer internal renderer;
    MockTerms internal terms;
    MockRecords internal records;
    MockSale internal sale;
    MockAccounts internal accounts;
    MockIndependentStreamGate internal gate;

    address internal marketOwner = makeAddr("marketOwner");
    address internal collector = makeAddr("collector");
    uint256 internal constant ARTIST = uint160(0xA11CE);
    bytes32 internal constant CC0_TEXT = keccak256("cc0 text file");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        manager = new AccessManager(address(this));
        store = new ContentStore();
        facts = new StreamWorkFacts6529(address(store), CC0_TEXT);
        renderer = new MockRenderer();
        terms = new MockTerms();
        records = new MockRecords(facts);
        sale = new MockSale();
        accounts = new MockAccounts();
        gate = new MockIndependentStreamGate();
        address[] memory minters = new address[](1);
        minters[0] = address(sale);
        stream = new Stream6529(
            address(manager),
            address(facts),
            marketOwner,
            address(renderer),
            address(terms),
            address(records),
            minters
        );
        editions = new StreamEditions6529(
            address(manager), address(stream), marketOwner, address(terms), minters
        );
        directory = new StreamDirectory6529(
            address(manager), address(accounts), address(gate), address(terms), address(records)
        );
        stream.createCollection("Genesis", bytes32(uint256(1)));
    }

    /// @dev Mint facts for work number `n` in collection 1.
    function _facts(uint256 n) internal pure returns (MintFacts memory f) {
        f.itemHash = keccak256(abi.encode("item", n));
        f.contentHash = keccak256(abi.encode("content", n));
        f.artistId = ARTIST;
        f.collectionId = 1;
        f.royaltyReceiver = address(0xFEE);
        f.royaltyRate = 6529;
        f.packageRoot = bytes32(n);
        f.mediaHash = bytes32(n);
        f.recordFileId = bytes32(n);
        f.seller = address(0x5E11);
    }

    /// @dev Mints work `n` into the sale contract's custody.
    function _mint(uint256 n) internal returns (uint256 tokenId) {
        return sale.mint(address(stream), _facts(n));
    }

    /// @dev Mints work `n`, records it sold and delivers it to `to`.
    function _sell(uint256 n, address to) internal returns (uint256 tokenId) {
        tokenId = _mint(n);
        sale.record(address(stream), tokenId, true, to, 1 ether);
        sale.send(address(stream), tokenId, to);
    }
}
