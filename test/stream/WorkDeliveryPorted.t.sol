// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { Vm } from "forge-std/Vm.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IWorkDelivery } from "src/interfaces/IWorkDelivery.sol";
import { ILocators } from "src/interfaces/core/ILocators.sol";
import { Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { RulesFixture } from "../records/RulesFixture.sol";

/// @notice `WorkDelivery` behaviour carried over from the `WorkRecords` suite that the first
///         port left out: near-miss locators, the one duplicate set both quotas share, the
///         implicit on-chain copy, refreshes before any mint and to the editions contract, and
///         the exact bounds of the preference setters.
contract WorkDeliveryPortedTest is RulesFixture {
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

    function _preferred(uint256 id, bytes32 file)
        internal
        view
        returns (ILocators.Location memory l, uint256 index)
    {
        return ILocators(address(delivery)).preferredLocator(s, id, file);
    }

    function _expectBad(uint256 id, bytes32 file, Locator memory l) internal {
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.addLocator(s, id, file, l);
    }

    /// @dev `str` with byte `i` replaced by `b`.
    function _with(string memory str, uint256 i, bytes1 b) internal pure returns (string memory) {
        bytes memory out = bytes(string.concat(str));
        out[i] = b;
        return string(out);
    }

    // ---------------------------------------------------------------- the URI check

    /// @dev A locator is a content address in its one canonical spelling: every near miss is
    ///      refused (a kind that does not match, a changed byte in the scheme, the profile
    ///      prefix or the address, a byte added or removed, a non-ASCII byte, a NUL inside or
    ///      last), and a file the work does not have is refused on either side of its files.
    function test_AddLocator_RefusesNearMisses() public {
        (uint256 id, bytes32 file) = _open(1);
        string memory txid = CA.arweave("tx");
        string memory cid = CA.ipfs("cid");
        bytes memory raw = bytes(txid);
        bytes memory short = new bytes(raw.length - 1);
        for (uint256 i; i < short.length; ++i) {
            short[i] = raw[i < short.length - 1 ? i : i + 1];
        }
        _expectBad(id, file, Locator(LocatorKind.NONE, cid));
        _expectBad(id, file, Locator(LocatorKind.ONCHAIN, txid));
        _expectBad(id, file, Locator(LocatorKind.ARWEAVE, cid));
        _expectBad(id, file, Locator(LocatorKind.IPFS, txid));
        _expectBad(id, file, Locator(LocatorKind.IPFS, "ipfs://"));
        _expectBad(id, file, Locator(LocatorKind.IPFS, "ipfs:/"));
        _expectBad(id, file, Locator(LocatorKind.ARWEAVE, _with(txid, 2, "/")));
        _expectBad(id, file, Locator(LocatorKind.ARWEAVE, _with(txid, 2, ";")));
        _expectBad(id, file, Locator(LocatorKind.ARWEAVE, _with(txid, 5, "=")));
        _expectBad(id, file, Locator(LocatorKind.ARWEAVE, _with(txid, 47, "+")));
        _expectBad(id, file, Locator(LocatorKind.ARWEAVE, string.concat(txid, "A")));
        _expectBad(id, file, Locator(LocatorKind.ARWEAVE, string(short)));
        _expectBad(id, file, Locator(LocatorKind.IPFS, _with(cid, 9, "y")));
        _expectBad(id, file, Locator(LocatorKind.IPFS, _with(cid, 14, "1")));
        _expectBad(id, file, Locator(LocatorKind.IPFS, _with(cid, 65, "A")));
        _expectBad(id, file, Locator(LocatorKind.IPFS, string.concat(cid, "a")));
        _expectBad(id, file, Locator(LocatorKind.IPFS, unicode"ipfs://é"));
        _expectBad(id, file, Locator(LocatorKind.IPFS, _with(cid, 30, hex"ff")));
        Locator[2] memory good = [CA.ar("nul"), CA.ipfsLocator("nul")];
        for (uint256 i; i < 2; ++i) {
            uint256 n = bytes(good[i].uri).length;
            _expectBad(id, file, Locator(good[i].kind, _with(good[i].uri, n - 2, 0x00)));
            _expectBad(id, file, Locator(good[i].kind, _with(good[i].uri, n - 1, 0x00)));
        }
        bytes32 above = bytes32(type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IWorkDelivery.FileNotInWork.selector, s, id, above));
        delivery.addLocator(s, id, above, CA.ar("tx"));
        delivery.addLocator(s, id, file, Locator(LocatorKind.ARWEAVE, txid));
        delivery.addLocator(s, id, file, Locator(LocatorKind.IPFS, cid));
        delivery.addLocator(s, id, file, Locator(LocatorKind.IPFS, CA.ipfsRoot("cid")));
        assertEq(delivery.locators(s, id, file).length, 3);
    }

    /// @dev The quotas are separate but the duplicate set is one: either side may add a URI
    ///      first and the other cannot add it again; the same CID as a dag-pb root is another
    ///      spelling, so another URI.
    function test_AddLocator_BothQuotasShareOneDuplicateSet() public {
        (uint256 id, bytes32 file) = _open(1);
        for (uint256 i; i < 8; ++i) {
            vm.prank(artist);
            delivery.addLocator(s, id, file, CA.ipfsLocator(vm.toString(i)));
        }
        Locator memory ninth = CA.ipfsLocator("artist-9");
        vm.prank(artist);
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.addLocator(s, id, file, ninth);
        delivery.addLocator(s, id, file, CA.ipfsLocator("p0"));
        _expectBad(id, file, CA.ipfsLocator("0"));
        delivery.addLocator(s, id, file, Locator(LocatorKind.IPFS, CA.ipfsRoot("0")));
        assertEq(delivery.locators(s, id, file).length, 10);
        // The platform first, then the artist.
        (uint256 other, bytes32 otherFile) = _open(2);
        delivery.addLocator(s, other, otherFile, CA.ar("first"));
        Locator memory again = CA.ar("first");
        vm.prank(artist);
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.addLocator(s, other, otherFile, again);
    }

    // ---------------------------------------------------------- the on-chain copy

    /// @dev With no locator and no preference, an on-chain complete work is served from its
    ///      on-chain copy; the answer reads the recorded flag and never asks the content store.
    ///      A file the work does not have is refused.
    function test_PreferredLocator_TheImplicitOnChainCopyNeverAsksTheStore() public {
        (uint256 id, bytes32 file) = _open(1);
        (ILocators.Location memory l, uint256 index) = _preferred(id, file);
        assertEq(l.kind, uint8(LocatorKind.NONE));
        assertEq(index, NONE);
        facts.markOnChainComplete(s, id);
        vm.expectCall(address(store), abi.encodeWithSelector(IContentStore.isComplete.selector), 0);
        (l, index) = _preferred(id, file);
        assertEq(l.kind, uint8(LocatorKind.ONCHAIN));
        assertEq(index, NONE);
        assertEq(bytes(l.uri).length, 0);
        bytes32 other = keccak256("x");
        vm.expectRevert(abi.encodeWithSelector(IWorkDelivery.FileNotInWork.selector, s, id, other));
        _preferred(id, other);
    }

    /// @dev When every locator is dead the on-chain copy of a complete work is served, else
    ///      nothing; a dead locator's URI stays taken.
    function test_MarkLocatorDead_AllDeadServesTheOnChainCopyAndTheUriStaysTaken() public {
        (uint256 id, bytes32 file) = _open(1);
        vm.prank(artist);
        delivery.addLocator(s, id, file, CA.ipfsLocator("a0"));
        delivery.addLocator(s, id, file, CA.ipfsLocator("p1"));
        delivery.setFilePreference(s, id, file, 0);
        delivery.markLocatorDead(s, id, file, 0);
        (, uint256 index) = _preferred(id, file);
        assertEq(index, 1, "a dead preference is passed over");
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.markLocatorDead(s, id, file, 2);
        delivery.markLocatorDead(s, id, file, 1);
        ILocators.Location memory l;
        (l, index) = _preferred(id, file);
        assertEq(l.kind, uint8(LocatorKind.NONE));
        assertEq(index, NONE);
        facts.markOnChainComplete(s, id);
        (l, index) = _preferred(id, file);
        assertEq(l.kind, uint8(LocatorKind.ONCHAIN), "the implicit on-chain copy");
        _expectBad(id, file, CA.ipfsLocator("p1"));
    }

    // ------------------------------------------------------------------ refreshes

    /// @dev With nothing minted there is nothing to refresh: no `BatchMetadataUpdate(1, 0)`.
    function test_Setters_RefreshNothingBeforeAMint() public {
        assertEq(stream.totalMinted(), 0);
        vm.recordLogs();
        delivery.setPreferredKind(s, LocatorKind.ARWEAVE);
        delivery.setCollectionPreferredKind(s, 1, LocatorKind.IPFS);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != s, "the token emitted a refresh");
            assertTrue(logs[i].emitter != address(editions), "the editions emitted a refresh");
        }
    }

    /// @dev A token-wide preference refreshes every work of the token and of its editions
    ///      contract, and logs the collection preference it replaced.
    function test_Setters_RefreshTheTokenAndItsEditions() public {
        _open(1);
        _open(2);
        vm.expectEmit(s);
        emit IERC4906.BatchMetadataUpdate(1, 2);
        vm.expectEmit(address(editions));
        emit IERC4906.BatchMetadataUpdate(1, 2);
        delivery.setPreferredKind(s, LocatorKind.IPFS);
        vm.expectEmit(address(delivery));
        emit IWorkDelivery.CollectionPreferredKindSet(s, 1, LocatorKind.NONE, LocatorKind.IPFS);
        vm.expectEmit(address(editions));
        emit IERC4906.BatchMetadataUpdate(1, 2);
        delivery.setCollectionPreferredKind(s, 1, LocatorKind.IPFS);
        vm.expectEmit(address(delivery));
        emit IWorkDelivery.CollectionPreferredKindSet(s, 1, LocatorKind.IPFS, LocatorKind.ARWEAVE);
        delivery.setCollectionPreferredKind(s, 1, LocatorKind.ARWEAVE);
    }

    // ------------------------------------------------------------- setter bounds

    /// @dev A preference must name a listed locator: one past the end is refused, and every
    ///      index further out; clearing it needs a file of the work.
    function test_SetFilePreference_RefusesEveryIndexPastTheList() public {
        (uint256 id, bytes32 file) = _open(1);
        delivery.addLocator(s, id, file, CA.ar("a0"));
        for (uint256 index = 1; index < 4; ++index) {
            vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
            delivery.setFilePreference(s, id, file, index);
        }
        delivery.setFilePreference(s, id, file, 0);
        assertEq(delivery.filePreference(s, id, file), 0);
        bytes32 other = keccak256("x");
        vm.expectRevert(abi.encodeWithSelector(IWorkDelivery.FileNotInWork.selector, s, id, other));
        delivery.setFilePreference(s, id, other, NONE);
    }

    /// @dev Any existing collection takes a preferred kind, not only the newest.
    function test_SetCollectionPreferredKind_AcceptsAnOlderCollection() public {
        uint256 newer = stream.createCollection("Second", keccak256("second"));
        assertGt(newer, 1);
        delivery.setCollectionPreferredKind(s, 1, LocatorKind.IPFS);
        assertEq(uint8(delivery.collectionPreferredKind(s, 1)), uint8(LocatorKind.IPFS));
        vm.expectRevert(
            abi.encodeWithSelector(IWorkDelivery.UnknownCollection.selector, s, newer + 1)
        );
        delivery.setCollectionPreferredKind(s, newer + 1, LocatorKind.IPFS);
    }
}
