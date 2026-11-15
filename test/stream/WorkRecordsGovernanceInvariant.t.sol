// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CommonBase } from "forge-std/Base.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { Renderer } from "src/content/Renderer.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IWorkDelivery, IWorkLocators } from "src/interfaces/IWorkDelivery.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { Stream } from "src/stream/Stream.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { MockRenderer } from "../mocks/stream/StreamMocks.sol";
import { RecordsFixture } from "./RecordsFixture.sol";

/// @notice A delivery contract that answers garbage and names whichever predecessor it is given.
contract HostileDelivery {
    address public immutable records;
    address public immutable predecessor;

    constructor(address records_, address predecessor_) {
        records = records_;
        predecessor = predecessor_;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IWorkDelivery).interfaceId || id == 0x01ffc9a7;
    }

    function preferredLocator(uint256, bytes32) external pure returns (bytes memory) {
        assembly ("memory-safe") {
            mstore(0, 0xbad)
            return(0, 0x20)
        }
    }
}

/// @notice A store adapter that serves wrong bytes for every chunk.
contract HostileSource {
    function readChunk(bytes32 hash) external pure returns (bytes memory) {
        return abi.encode(hash, "not the chunk");
    }
}

/// @notice Every governance action that touches `WorkRecords` or what it reads, plus the
///         permissionless sync, in random order.
contract GovernanceHandler is CommonBase, StdUtils {
    Stream internal immutable stream;
    WorkRecords internal immutable records;
    address internal immutable governor;
    address internal immutable operator;
    uint256 internal immutable tokenId;
    MockRenderer internal immutable other;
    uint256 public actions;

    constructor(
        Stream stream_,
        WorkRecords records_,
        address governor_,
        address operator_,
        uint256 tokenId_
    ) {
        stream = stream_;
        records = records_;
        governor = governor_;
        operator = operator_;
        tokenId = tokenId_;
        other = new MockRenderer("other default");
    }

    function swapDelivery() external {
        address current = records.delivery();
        HostileDelivery next = new HostileDelivery(address(records), current);
        vm.prank(governor);
        records.setDelivery(current, address(next));
        ++actions;
    }

    function addStore() external {
        if (records.storeCount() == 16) return;
        HostileSource s = new HostileSource();
        vm.prank(governor);
        records.addStore(address(s), address(s).codehash);
        ++actions;
    }

    function sync(uint256 storeId, uint256 budget) external {
        storeId = bound(storeId, 0, records.storeCount() - 1);
        records.syncOnChain(tokenId, storeId, bound(budget, 0, 64));
        ++actions;
    }

    function preference(uint8 kind) external {
        address d = records.delivery();
        vm.prank(operator);
        try IWorkLocators(d).setPreferredKind(LocatorKind(bound(kind, 0, 3))) {
            ++actions;
        } catch { }
    }

    function swapDefaultRenderer() external {
        address current = stream.defaultRenderer();
        if (current != address(other)) {
            vm.prank(governor);
            stream.setDefaultRenderer(current, address(other), address(other).codehash);
            ++actions;
        }
    }
}

/// @notice Study G's guarantee as an invariant: no governance action (a new delivery contract,
///         new stores, preferences, a new default renderer) and no permissionless sync alters
///         what `tokenURI` inlines for a finalized, on-chain complete work, nor its facts: media,
///         each file's store, completeness, record, license and pin.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
contract WorkRecordsGovernanceInvariantTest is RecordsFixture {
    GovernanceHandler internal handler;
    uint256 internal tokenId;
    string internal uri;
    bytes internal facts;

    function setUp() public override {
        super.setUp();
        Renderer real =
            new Renderer(IContentStore(address(store)), IStatementLog(address(0)), 256 * 1024);
        vm.prank(governor);
        stream.setDefaultRenderer(address(renderer), address(real), address(real).codehash);
        (tokenId,) = _work(1);
        records.syncOnChain(tokenId, 0, type(uint256).max);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        uri = stream.tokenURI(tokenId);
        facts = _facts();
        assertTrue(_contains(uri, "data:image/png;base64,"), "the primary is inlined");

        handler = new GovernanceHandler(stream, records, governor, storageOperator, tokenId);
        targetContract(address(handler));
    }

    function _facts() internal view returns (bytes memory) {
        (uint256 storeId, bool complete) = records.mediaStore(tokenId, 0);
        return abi.encode(
            records.record(tokenId),
            records.mediaOf(tokenId),
            records.licenseOf(tokenId),
            records.pinnedRenderer(tokenId),
            storeId,
            complete
        );
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool same = true;
            for (uint256 j; j < n.length && same; ++j) {
                same = h[i + j] == n[j];
            }
            if (same) return true;
        }
        return false;
    }

    function invariant_tokenUriOfACompleteWorkNeverChanges() public view {
        assertEq(stream.tokenURI(tokenId), uri);
    }

    function invariant_aCompleteWorksFactsNeverChange() public view {
        assertEq(_facts(), facts);
        assertTrue(records.record(tokenId).onChainComplete);
    }
}
