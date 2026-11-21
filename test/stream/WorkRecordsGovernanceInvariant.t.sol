// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CommonBase } from "forge-std/Base.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Renderer } from "src/content/Renderer.sol";
import { Roles } from "src/governance/Roles.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IWorkDelivery, IWorkLocators } from "src/interfaces/IWorkDelivery.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { Stream } from "src/stream/Stream.sol";
import { WorkDelivery } from "src/stream/WorkDelivery.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { MockRenderer } from "../mocks/stream/StreamMocks.sol";
import { RecordsFixture } from "./RecordsFixture.sol";
import { HandlerReach } from "../helpers/HandlerReach.sol";

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
    /// @dev The access manager's admin (the test), which maps a new real delivery's roles.
    address internal immutable admin;
    /// @dev Delivery contracts that are real `WorkDelivery` instances.
    mapping(address => bool) internal _real;
    uint256 public actions;
    uint256 public realDeliveries;
    uint256 public preferences;
    uint256 public preferencesOnAReplacement;
    address internal immutable firstDelivery;
    /// @dev Store IDs in use, the content store included (from `StoreAdded`).
    uint256 public stores = 1;

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
        admin = msg.sender;
        firstDelivery = records_.delivery();
        _real[firstDelivery] = true;
    }

    /// @dev Replaces the delivery contract, alternating a hostile one and a new real one that
    ///      names it as predecessor, so preferences keep reaching a real delivery after a swap.
    function swapDelivery() external {
        address current = records.delivery();
        address next;
        if (_real[current]) {
            next = address(new HostileDelivery(address(records), current));
        } else {
            AccessManager manager = AccessManager(records.authority());
            next = address(
                new WorkDelivery(address(manager), address(records), address(stream), current)
            );
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = IWorkLocators.setPreferredKind.selector;
            vm.prank(admin);
            manager.setTargetFunctionRole(next, selectors, Roles.STORAGE_OPERATOR);
            _real[next] = true;
            ++realDeliveries;
        }
        vm.prank(governor);
        records.setDelivery(current, next);
        ++actions;
    }

    function addStore() external {
        if (stores == 16) return;
        HostileSource s = new HostileSource();
        vm.prank(governor);
        records.addStore(address(s), address(s).codehash);
        ++stores;
        ++actions;
    }

    function sync(uint256 storeId, uint256 budget) external {
        storeId = bound(storeId, 0, stores - 1);
        records.syncOnChain(tokenId, storeId, bound(budget, 0, 64));
        ++actions;
    }

    function preference(uint8 kind) external {
        address d = records.delivery();
        vm.prank(operator);
        try IWorkLocators(d).setPreferredKind(LocatorKind(bound(kind, 0, 3))) {
            ++actions;
            ++preferences;
            if (d != firstDelivery) ++preferencesOnAReplacement;
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

    /// @notice Handler self-test: every governance action changes the records satellite or
    ///         Stream (a new delivery, a new store, a new default renderer), preferences are set
    ///         on a real replacement delivery as well as the first, and the permissionless sync
    ///         reaches the records satellite and returns; then both invariants hold on the state
    ///         the drive left.
    function test_HandlerPathsReachState() public {
        HandlerReach.Expect[] memory e = new HandlerReach.Expect[](5);
        e[0] = HandlerReach.Expect(handler.swapDelivery.selector, HandlerReach.WRITES);
        e[1] = HandlerReach.Expect(handler.addStore.selector, HandlerReach.WRITES);
        e[2] = HandlerReach.Expect(handler.sync.selector, HandlerReach.CALLED);
        // Preferences reach replacement deliveries, which the fixed list below does not name:
        // the handler's counters show it.
        e[3] = HandlerReach.Expect(handler.preference.selector, 0);
        e[4] = HandlerReach.Expect(handler.swapDefaultRenderer.selector, HandlerReach.WRITES);
        address[] memory sut = new address[](3);
        sut[0] = address(stream);
        sut[1] = address(records);
        sut[2] = address(delivery);
        HandlerReach.check(e, HandlerReach.drive(address(handler), e, sut, 24, 1));
        assertGt(handler.stores(), 1);
        assertGt(handler.realDeliveries(), 0);
        assertGt(handler.preferencesOnAReplacement(), 0);
        invariant_tokenUriOfACompleteWorkNeverChanges();
        invariant_aCompleteWorksFactsNeverChange();
    }
}
