// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IWorkDelivery, IWorkLocators } from "src/interfaces/IWorkDelivery.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { Burner, GasRuleAssertions } from "test/helpers/GasRule.sol";
import { ContentAddresses as CA } from "test/helpers/ContentAddresses.sol";
import { RecordsFixture } from "./RecordsFixture.sol";

/// @notice A delivery contract whose `preferredLocator` answer is set by the test: raw bytes
///         (mode 0), a revert (1) or a call that burns every gas unit it is given (2).
contract DeliveryStub {
    address public records;
    address public predecessor;
    uint8 public mode;
    bytes internal _raw;

    constructor(address records_, address predecessor_) {
        records = records_;
        predecessor = predecessor_;
    }

    function set(uint8 mode_, bytes memory raw) external {
        mode = mode_;
        _raw = raw;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IWorkDelivery).interfaceId || id == 0x01ffc9a7;
    }

    function preferredLocator(uint256, bytes32) external view returns (bytes memory) {
        uint8 m = mode;
        if (m == 1) revert("delivery down");
        if (m == 2) {
            uint256 i;
            while (true) {
                ++i;
            }
        }
        bytes memory raw = _raw;
        assembly ("memory-safe") {
            return(add(raw, 0x20), mload(raw))
        }
    }
}

/// @notice A successor that keeps its predecessor's locators by reading them through, as
///         `IWorkDelivery` obliges every successor to.
contract ReadThroughDelivery {
    address public immutable records;
    address public immutable predecessor;

    constructor(address records_, address predecessor_) {
        records = records_;
        predecessor = predecessor_;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IWorkDelivery).interfaceId || id == 0x01ffc9a7;
    }

    function preferredLocator(uint256 tokenId, bytes32 fileId)
        external
        view
        returns (IWorkDelivery.Location memory, uint256)
    {
        return IWorkDelivery(predecessor).preferredLocator(tokenId, fileId);
    }
}

/// @notice The delivery contract behind `WorkRecords` (study B design iv-b): the governed
///         compare-and-set swap, the refresh hooks, the fail-soft forwarding of
///         `preferredLocator` and its gas rule, locator provenance, and a successor that keeps
///         the predecessor's locators.
contract WorkDeliveryTest is RecordsFixture, GasRuleAssertions {
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    uint256 internal constant NONE = type(uint256).max;

    function setUp() public override(RecordsFixture) {
        RecordsFixture.setUp();
    }

    function _primary(uint256 tokenId) internal view returns (bytes32) {
        return records.mediaOf(tokenId)[0].fileId;
    }

    function _stub() internal returns (DeliveryStub stub) {
        stub = new DeliveryStub(address(records), address(delivery));
        vm.prank(governor);
        records.setDelivery(address(delivery), address(stub));
    }

    function _encode(uint8 kind, string memory uri, uint256 index)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(IWorkDelivery.Location(kind, uri), index);
    }

    function _location(uint256 tokenId, bytes32 file)
        internal
        view
        returns (uint8 kind, string memory uri, uint256 index)
    {
        IWorkDelivery.Location memory l;
        (l, index) = records.preferredLocator(tokenId, file);
        return (l.kind, l.uri, index);
    }

    // ------------------------------------------------------------------------- the swap

    function test_constructor_deploysTheFirstDelivery() public view {
        assertEq(records.delivery(), address(delivery));
        assertEq(delivery.records(), address(records));
        assertEq(delivery.predecessor(), address(0));
        assertTrue(delivery.supportsInterface(type(IWorkDelivery).interfaceId));
        assertTrue(delivery.supportsInterface(type(IWorkLocators).interfaceId));
        assertEq(address(delivery.authority()), address(manager));
    }

    function test_setDelivery_swapsAndRefreshesEveryToken() public {
        _work(1);
        _work(2);
        DeliveryStub stub = new DeliveryStub(address(records), address(delivery));
        vm.expectEmit(address(records));
        emit IWorkRecords.DeliverySet(address(delivery), address(stub));
        vm.expectEmit(address(stream));
        emit BatchMetadataUpdate(1, 2);
        vm.prank(governor);
        records.setDelivery(address(delivery), address(stub));
        assertEq(records.delivery(), address(stub));
    }

    function test_setDelivery_refusals() public {
        DeliveryStub good = new DeliveryStub(address(records), address(delivery));
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        records.setDelivery(address(delivery), address(good));

        vm.startPrank(governor);
        vm.expectRevert(IWorkRecords.DeliveryMismatch.selector);
        records.setDelivery(address(good), address(good));

        DeliveryStub otherRecords = new DeliveryStub(address(0xBEEF), address(delivery));
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(otherRecords))
        );
        records.setDelivery(address(delivery), address(otherRecords));

        // A successor must name the delivery it replaces, so no swap forgets the chain.
        DeliveryStub orphan = new DeliveryStub(address(records), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(orphan))
        );
        records.setDelivery(address(delivery), address(orphan));

        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, outsider));
        records.setDelivery(address(delivery), outsider);
        vm.stopPrank();
        assertEq(records.delivery(), address(delivery));
    }

    function test_refreshHooks_onlyTheDelivery() public {
        (uint256 tokenId,) = _work(1);
        _work(2);
        vm.expectRevert(IWorkRecords.NotDelivery.selector);
        vm.prank(outsider);
        records.refreshMetadata(tokenId);
        vm.expectRevert(IWorkRecords.NotDelivery.selector);
        vm.prank(outsider);
        records.refreshAllMetadata();
        vm.expectEmit(address(stream));
        emit BatchMetadataUpdate(1, 2);
        vm.prank(address(delivery));
        records.refreshAllMetadata();
    }

    // ------------------------------------------------------------------ fail-soft forwarding

    /// @dev Every answer that is not a canonical, allowed location yields the work's own answer:
    ///      the empty locator for an unsynced work, the implicit ONCHAIN copy once synced. A
    ///      revert does the same. Removing any check of `_isLocation` makes one row serve the
    ///      delivery contract's bytes.
    function test_preferredLocator_failSoftOnEveryMalformedAnswer() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        DeliveryStub stub = _stub();
        bytes memory longUri = new bytes(2049);
        for (uint256 i; i < longUri.length; ++i) {
            longUri[i] = "a";
        }
        bytes[] memory bad = new bytes[](12);
        bad[0] = "";
        bad[1] = abi.encode(uint256(1));
        bad[2] = bytes.concat(_encode(1, "ar://x", 0), bytes1(0)); // trailing byte
        bad[3] = _encode(0, "ar://x", NONE); // NONE with a URI
        bad[4] = _encode(1, "", 0); // a kind with no URI
        bad[5] = _encode(3, "", NONE); // ONCHAIN for an unsynced work
        bad[6] = _encode(3, "ar://x", NONE); // ONCHAIN with a URI
        bad[7] = _encode(1, string(longUri), 0); // URI over Limits.MAX_URI_BYTES
        bad[8] = _encode(0, "", 0); // NONE with an index
        bad[9] = abi.encode(uint256(0x40), uint256(0), uint256(256), uint256(0x40), uint256(0));
        bad[10] = abi.encode(uint256(0x60), uint256(0), uint256(1), uint256(0x40), uint256(0));
        bad[11] = abi.encode(uint256(0x40), uint256(0), uint256(1), uint256(0x20), uint256(0));
        for (uint256 i; i < bad.length; ++i) {
            stub.set(0, bad[i]);
            (uint8 kind, string memory uri, uint256 index) = _location(tokenId, file);
            assertEq(kind, uint8(LocatorKind.NONE), vm.toString(i));
            assertEq(bytes(uri).length, 0, vm.toString(i));
            assertEq(index, NONE, vm.toString(i));
        }
        stub.set(1, "");
        (uint8 k,, uint256 idx) = _location(tokenId, file);
        assertEq(k, uint8(LocatorKind.NONE));
        assertEq(idx, NONE);

        records.syncOnChain(tokenId, 0, type(uint256).max);
        for (uint256 i; i < bad.length; ++i) {
            if (i == 5) continue; // ONCHAIN is now allowed
            stub.set(0, bad[i]);
            (uint8 kind, string memory uri, uint256 index) = _location(tokenId, file);
            assertEq(kind, uint8(LocatorKind.ONCHAIN), vm.toString(i));
            assertEq(bytes(uri).length, 0, vm.toString(i));
            assertEq(index, NONE, vm.toString(i));
        }
        stub.set(1, "");
        (k,, idx) = _location(tokenId, file);
        assertEq(k, uint8(LocatorKind.ONCHAIN));
    }

    /// @dev Well-formed answers pass through unchanged, a kind `LocatorKind` does not name
    ///      included (a future storage network), and ONCHAIN once the work is synced.
    function test_preferredLocator_passesWellFormedAnswersThrough() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        DeliveryStub stub = _stub();
        stub.set(0, _encode(1, "ar://copy", 4));
        (uint8 kind, string memory uri, uint256 index) = _location(tokenId, file);
        assertEq(kind, 1);
        assertEq(uri, "ar://copy");
        assertEq(index, 4);
        stub.set(0, _encode(9, "bzz://future", 0));
        (kind, uri,) = _location(tokenId, file);
        assertEq(kind, 9);
        assertEq(uri, "bzz://future");
        stub.set(0, _encode(0, "", NONE));
        (kind,, index) = _location(tokenId, file);
        assertEq(kind, 0);
        records.syncOnChain(tokenId, 0, type(uint256).max);
        stub.set(0, _encode(3, "", NONE));
        (kind,, index) = _location(tokenId, file);
        assertEq(kind, 3);
        assertEq(index, NONE);
        // The facts are checked before the delivery contract is asked.
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.FileNotInWork.selector, tokenId, bytes32(0))
        );
        records.preferredLocator(tokenId, bytes32(0));
    }

    /// @dev Gas rule: with the delivery contract costing 1x to 100x its base, the answer is the
    ///      same; with too little gas the call reverts with the shortfall error, never falls back
    ///      to the work's own answer.
    function test_GasRule_preferredLocatorForwarding() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        vm.prank(artist);
        delivery.addLocator(tokenId, file, CA.ar("artist copy"));
        // The successor reads the artist's copy from the predecessor it names.
        ReadThroughDelivery through = new ReadThroughDelivery(address(records), address(delivery));
        Burner burner = new Burner(address(through), 20_000);
        vm.prank(governor);
        records.setDelivery(address(delivery), address(burner));
        bytes memory data = abi.encodeCall(records.preferredLocator, (tokenId, file));
        Outcome memory o = _assertSameAtEveryMultiple(burner, outsider, address(records), data);
        assertTrue(o.ok);
        (IWorkDelivery.Location memory l,) = abi.decode(o.data, (IWorkDelivery.Location, uint256));
        assertEq(l.uri, CA.arweave("artist copy"));
        for (uint256 i; i < 3; ++i) {
            burner.burnerSetMultiple(i == 0 ? 1 : i == 1 ? 4 : 10);
            _assertShortfallNeverAnswers(burner, outsider, address(records), data);
        }
    }

    /// @dev A delivery contract that burns all it is given makes the call revert (shortfall),
    ///      never serve the fallback as if it had answered.
    function test_GasRule_aBurningDeliveryRevertsNeverFallsBack() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        _stub().set(2, "");
        vm.expectRevert();
        this.locate{ gas: 5_000_000 }(tokenId, file);
    }

    function locate(uint256 tokenId, bytes32 file) external view returns (uint8 kind) {
        (kind,,) = _location(tokenId, file);
    }

    // -------------------------------------------------------------- provenance and successors

    function test_locatorCounts_recordWhoAddedEach() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        vm.prank(platform);
        delivery.addLocator(tokenId, file, CA.ipfsLocator("p0"));
        vm.prank(artist);
        delivery.addLocator(tokenId, file, CA.ar("a1"));
        (uint256 a, uint256 p, uint256 mask) = delivery.locatorCounts(tokenId, file);
        assertEq(a, 1);
        assertEq(p, 1);
        assertEq(mask, 2);
    }

    /// @dev A successor that reads its predecessor keeps every artist's locator: the served
    ///      locator and the metadata are the same after the swap.
    function test_successor_keepsThePredecessorsLocators() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        vm.prank(artist);
        delivery.addLocator(tokenId, file, CA.ar("kept"));
        (uint8 k0, string memory u0, uint256 i0) = _location(tokenId, file);
        ReadThroughDelivery next = new ReadThroughDelivery(address(records), address(delivery));
        vm.prank(governor);
        records.setDelivery(address(delivery), address(next));
        (uint8 k1, string memory u1, uint256 i1) = _location(tokenId, file);
        assertEq(k1, k0);
        assertEq(u1, u0);
        assertEq(i1, i0);
        assertEq(u1, CA.arweave("kept"));
    }

    /// @dev The delivery contract has no write path into a fact: a hostile one that answers
    ///      garbage leaves the record, media, license, rate, pin and state hash unchanged.
    function test_aHostileDeliveryChangesNoFact() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        bytes32 state = records.workStateHash(tokenId);
        bytes memory before = abi.encode(
            records.record(tokenId), records.mediaOf(tokenId), records.licenseOf(tokenId)
        );
        DeliveryStub stub = _stub();
        stub.set(0, hex"deadbeef");
        records.preferredLocator(tokenId, file);
        vm.prank(address(stub));
        records.refreshMetadata(tokenId);
        assertEq(records.workStateHash(tokenId), state);
        assertEq(
            abi.encode(
                records.record(tokenId), records.mediaOf(tokenId), records.licenseOf(tokenId)
            ),
            before
        );
    }
}
