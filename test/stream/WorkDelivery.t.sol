// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IWorkDelivery } from "src/interfaces/IWorkDelivery.sol";
import { Facts } from "src/interfaces/core/CoreTypes.sol";
import { ILocators } from "src/interfaces/core/ILocators.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { RulesFixture } from "../records/RulesFixture.sol";

/// @notice `WorkDelivery`, keyed by token: locators, quotas, preferences and dead marks, with
///         every fact read from `WorkFacts`.
contract WorkDeliveryTest is RulesFixture {
    uint256 internal constant NONE = type(uint256).max;
    address internal s;

    function setUp() public override {
        super.setUp();
        s = address(stream);
    }

    function _open(uint256 salt) internal returns (uint256 id, bytes32 file) {
        MediaFile[] memory media;
        (id,, media) = _work(stream, salt);
        file = media[0].fileId;
    }

    function _ar(uint256 i) internal pure returns (Locator memory) {
        return Locator(LocatorKind.ARWEAVE, CA.arweave(vm.toString(i)));
    }

    function _ipfs(uint256 i) internal pure returns (Locator memory) {
        return Locator(LocatorKind.IPFS, CA.ipfs(vm.toString(i)));
    }

    function _preferred(uint256 id, bytes32 file)
        internal
        view
        returns (ILocators.Location memory l, uint256 index)
    {
        return ILocators(address(delivery)).preferredLocator(s, id, file);
    }

    function _finalize(uint256 id) internal {
        bytes32 state = _state(id);
        vm.prank(artist);
        rules.finalize(s, id, state);
    }

    // ---------------------------------------------------------------------- adding

    function test_AddLocator_TheArtistBeforeFinalizeThePlatformAlways() public {
        (uint256 id, bytes32 file) = _open(1);
        Locator memory l = _ar(1);
        vm.expectEmit(address(delivery));
        emit IWorkDelivery.LocatorAdded(s, id, file, 0, l, artist, true);
        vm.expectEmit(s);
        emit IERC4906.MetadataUpdate(id);
        vm.prank(artist);
        delivery.addLocator(s, id, file, l);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        delivery.addLocator(s, id, file, _ar(2));
        // The platform (the network's role here).
        delivery.addLocator(s, id, file, _ipfs(2));
        (uint256 a, uint256 p, uint256 byArtist) = delivery.locatorCounts(s, id, file);
        assertEq(a, 1);
        assertEq(p, 1);
        assertEq(byArtist, 1);
        _finalize(id);
        Locator memory late = _ar(3);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, artist)
        );
        delivery.addLocator(s, id, file, late);
        delivery.addLocator(s, id, file, late);
        assertEq(delivery.locators(s, id, file).length, 3);
    }

    function test_AddLocator_SeparateQuotasThenThePlatformTakesTheRestAfterFinalize() public {
        (uint256 id, bytes32 file) = _open(1);
        for (uint256 i; i < 8; ++i) {
            vm.prank(artist);
            delivery.addLocator(s, id, file, _ar(i));
        }
        Locator memory ninth = _ar(8);
        vm.prank(artist);
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.addLocator(s, id, file, ninth);
        for (uint256 i = 10; i < 14; ++i) {
            delivery.addLocator(s, id, file, _ipfs(i));
        }
        _finalize(id);
        for (uint256 i = 20; i < 24; ++i) {
            delivery.addLocator(s, id, file, _ipfs(i));
        }
        Locator memory over = _ipfs(30);
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.addLocator(s, id, file, over);
        assertEq(delivery.locators(s, id, file).length, 16);
    }

    function test_AddLocator_Refusals() public {
        (uint256 id, bytes32 file) = _open(1);
        delivery.addLocator(s, id, file, _ar(1));
        Locator memory dup = _ar(1);
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.addLocator(s, id, file, dup);
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.addLocator(s, id, file, Locator(LocatorKind.ONCHAIN, ""));
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.addLocator(s, id, file, Locator(LocatorKind.NONE, CA.arweave("x")));
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.addLocator(s, id, file, Locator(LocatorKind.ARWEAVE, "https://example.com/x"));
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.addLocator(s, id, file, Locator(LocatorKind.IPFS, CA.arweave("y")));
        Locator memory ok = _ar(2);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkDelivery.FileNotInWork.selector, s, id, bytes32(0))
        );
        delivery.addLocator(s, id, bytes32(0), ok);
        uint256 unopened = _mintItem(stream, _item(9, _single(9)));
        vm.expectRevert(abi.encodeWithSelector(IWorkDelivery.RecordNotOpen.selector, s, unopened));
        delivery.addLocator(s, unopened, file, ok);
    }

    /// @dev The same token ID in two token contracts keeps two sets of locators; a token whose
    ///      RECORDS module is not this delivery's cannot be served (its refresh is refused).
    function test_KeyedByToken() public {
        (uint256 id, bytes32 file) = _open(1);
        delivery.addLocator(s, id, file, _ar(1));
        MediaFile[] memory media;
        (,, media) = _work(bare, 1);
        assertEq(delivery.locators(address(bare), id, file).length, 0);
        Locator memory l = _ar(2);
        vm.expectRevert();
        delivery.addLocator(address(bare), id, media[0].fileId, l);
    }

    // ---------------------------------------------------------------- preferences

    function test_PreferredLocator_TheMostSpecificLiveChoiceWins() public {
        (uint256 id, bytes32 file) = _open(1);
        (ILocators.Location memory l, uint256 index) = _preferred(id, file);
        assertEq(l.kind, 0);
        assertEq(index, NONE);
        delivery.addLocator(s, id, file, _ar(1));
        delivery.addLocator(s, id, file, _ipfs(2));
        delivery.addLocator(s, id, file, _ar(3));
        (, index) = _preferred(id, file);
        assertEq(index, 0, "first live");
        delivery.setPreferredKind(s, LocatorKind.IPFS);
        (, index) = _preferred(id, file);
        assertEq(index, 1, "token kind");
        delivery.setCollectionPreferredKind(s, 1, LocatorKind.ARWEAVE);
        (, index) = _preferred(id, file);
        assertEq(index, 0, "collection kind");
        delivery.setFilePreference(s, id, file, 2);
        (l, index) = _preferred(id, file);
        assertEq(index, 2, "file preference");
        assertEq(l.uri, CA.arweave("3"));
        delivery.markLocatorDead(s, id, file, 2);
        (, index) = _preferred(id, file);
        assertEq(index, 0, "a dead preference is passed over");
        delivery.markLocatorDead(s, id, file, 0);
        (, index) = _preferred(id, file);
        assertEq(index, 1, "collection kind has no live match; token kind");
    }

    function test_PreferredLocator_OnChainOnlyOnceRecordedComplete() public {
        (uint256 id, bytes32 file) = _open(1);
        delivery.setPreferredKind(s, LocatorKind.ONCHAIN);
        (ILocators.Location memory l, uint256 index) = _preferred(id, file);
        assertEq(l.kind, 0);
        facts.markOnChainComplete(s, id);
        (l, index) = _preferred(id, file);
        assertEq(l.kind, uint8(LocatorKind.ONCHAIN));
        assertEq(index, NONE);
        assertEq(bytes(l.uri).length, 0);
    }

    function test_Setters_TheStorageOperatorOnlyAndTheyRefresh() public {
        (uint256 id, bytes32 file) = _open(1);
        delivery.addLocator(s, id, file, _ar(1));
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(IWorkDelivery.setPreferredKind, (s, LocatorKind.IPFS));
        calls[1] =
            abi.encodeCall(IWorkDelivery.setCollectionPreferredKind, (s, 1, LocatorKind.IPFS));
        calls[2] = abi.encodeCall(IWorkDelivery.setFilePreference, (s, id, file, 0));
        calls[3] = abi.encodeCall(IWorkDelivery.markLocatorDead, (s, id, file, 0));
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(stranger);
            (bool ok,) = address(delivery).call(calls[i]);
            assertFalse(ok);
        }
        vm.expectEmit(address(delivery));
        emit IWorkDelivery.PreferredKindSet(s, LocatorKind.NONE, LocatorKind.IPFS);
        vm.expectEmit(s);
        emit IERC4906.MetadataUpdate(1);
        delivery.setPreferredKind(s, LocatorKind.IPFS);
        vm.expectEmit(address(delivery));
        emit IWorkDelivery.FilePreferenceSet(s, id, file, NONE, 0);
        delivery.setFilePreference(s, id, file, 0);
        assertEq(delivery.filePreference(s, id, file), 0);
        delivery.setFilePreference(s, id, file, NONE);
        assertEq(delivery.filePreference(s, id, file), NONE);
        vm.expectEmit(address(delivery));
        emit IWorkDelivery.LocatorDead(s, id, file, 0);
        delivery.markLocatorDead(s, id, file, 0);
        assertEq(delivery.deadLocators(s, id, file), 1);
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.markLocatorDead(s, id, file, 0);
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.setFilePreference(s, id, file, 0);
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.setFilePreference(s, id, file, 5);
        vm.expectRevert(abi.encodeWithSelector(IWorkDelivery.UnknownCollection.selector, s, 7));
        delivery.setCollectionPreferredKind(s, 7, LocatorKind.IPFS);
        assertEq(uint8(delivery.preferredKind(s)), uint8(LocatorKind.IPFS));
        assertEq(uint8(delivery.collectionPreferredKind(s, 1)), 0);
    }

    function test_SupportsInterface_TheExactIds() public view {
        assertTrue(delivery.supportsInterface(type(IWorkDelivery).interfaceId));
        assertTrue(delivery.supportsInterface(type(ILocators).interfaceId));
        assertTrue(delivery.supportsInterface(type(IERC165).interfaceId));
        assertFalse(delivery.supportsInterface(0xffffffff));
        assertEq(delivery.records(), address(rules));
        assertEq(delivery.facts(), address(facts));
        assertEq(delivery.directory(), address(directory));
        assertEq(delivery.predecessor(), address(0));
    }

    /// @dev Nothing the delivery contract does changes a fact of the work.
    function test_NoFactChanges() public {
        (uint256 id, bytes32 file) = _open(1);
        bytes32 before = keccak256(abi.encode(facts.factsOf(s, id)));
        delivery.addLocator(s, id, file, _ar(1));
        delivery.setPreferredKind(s, LocatorKind.ONCHAIN);
        delivery.markLocatorDead(s, id, file, 0);
        Facts memory f = facts.factsOf(s, id);
        assertEq(keccak256(abi.encode(f)), before);
    }

    function test_AMultiFileWorkServesEachFile() public {
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(1, FileRole.PRIMARY, true);
        media[1] = _mediaFile(2, FileRole.PREVIEW, false);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(stream, item);
        facts.open(s, id, item, media);
        delivery.addLocator(s, id, media[1].fileId, _ipfs(1));
        (ILocators.Location memory l,) = _preferred(id, media[1].fileId);
        assertEq(l.kind, uint8(LocatorKind.IPFS));
        (l,) = _preferred(id, media[0].fileId);
        assertEq(l.kind, 0);
    }
}
