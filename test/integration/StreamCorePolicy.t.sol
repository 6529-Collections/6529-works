// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IStreamViews } from "src/interfaces/IStreamViews.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { ItemKind, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice The permanent core and its replaceable pieces on the wired stack: the mint record and
///         the terms the core emits, the read-only extension's views, the core's lower-only
///         royalty floor, `rendererOf`'s fail-closed pin read and the permanent artist registry.
contract StreamCorePolicyTest is IntegrationBase {
    bytes32 internal root;
    address internal lead;

    function setUp() public override {
        super.setUp();
        lead = _actor("coreArtist");
        Work[] memory w = new Work[](4);
        for (uint256 i; i < 4; ++i) {
            w[i] = _work(lead, collectionId);
        }
        root = _publish(w);
        _keep(root, w);
    }

    function _first() internal returns (uint256 tokenId) {
        (, tokenId) = _start(root, _package(root), 0);
    }

    // ------------------------------------------------------------------ mint record and terms

    function test_Mint_EmitsTermsOnceAndWorkMintedWithTermsId() public {
        vm.recordLogs();
        uint256 tokenId = _first();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint24 termsId, bool interned, bool minted) = _scan(logs, tokenId);
        assertTrue(interned, "first work under these terms announces them");
        assertTrue(minted, "WorkMinted");
        assertGt(termsId, 0);

        vm.recordLogs();
        (, uint256 second) = _start(root, _package(root), 1);
        (uint24 termsId2, bool interned2,) = _scan(vm.getRecordedLogs(), second);
        assertFalse(interned2, "later works reuse the announced terms");
        assertEq(termsId2, termsId);
    }

    function _scan(Vm.Log[] memory logs, uint256 tokenId)
        internal
        view
        returns (uint24 termsId, bool interned, bool minted)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(stream)) continue;
            if (logs[i].topics[0] == IStream.TermsInterned.selector) interned = true;
            if (
                logs[i].topics[0] == IStream.WorkMinted.selector
                    && uint256(logs[i].topics[1]) == tokenId
            ) {
                minted = true;
                assertEq(uint256(logs[i].topics[3]), stream.artistOf(tokenId), "artistId topic");
                (,,,,,,, address seller, uint24 id) = abi.decode(
                    logs[i].data,
                    (bytes32, uint64, uint8, bytes32, bytes32, bytes32, bytes32, address, uint24)
                );
                assertEq(seller, IStreamViews(address(stream)).work(tokenId).seller, "seller");
                termsId = id;
            }
        }
    }

    /// @dev Stream answers the native surface's id and the extension views' id.
    function test_SupportsBothInterfaceIds() public view {
        assertTrue(stream.supportsInterface(type(IStream).interfaceId), "IStream");
        assertTrue(stream.supportsInterface(type(IStreamViews).interfaceId), "IStreamViews");
        assertTrue(stream.supportsInterface(type(IMintTarget).interfaceId), "IMintTarget");
        assertFalse(stream.supportsInterface(0xffffffff));
    }

    function test_CoreOf_KindAndSeedAsUint8() public {
        uint256 tokenId = _first();
        (,,, uint8 kind, uint8 seed,) = stream.coreOf(tokenId);
        assertEq(kind, uint8(ItemKind.ORIGINAL));
        assertEq(seed, uint8(_package(root)[0].item.seedPolicy));
    }

    // ------------------------------------------------------------------ the read-only extension

    function test_Extension_ServesInformationalViews() public {
        uint256 tokenId = _first();
        IStream views = IStream(address(stream));
        IStreamViews.WorkCore memory w = IStreamViews(address(views)).work(tokenId);
        (bytes32 itemHash, uint256 artistId, uint256 cid,,, uint32 rate) = stream.coreOf(tokenId);
        assertEq(w.itemHash, itemHash);
        assertEq(w.artistId, artistId);
        assertEq(w.collectionId, cid);
        assertEq(w.royaltyRate, rate);
        assertEq(w.serial, 1);
        (address receiver,) = stream.royaltyInfo(tokenId, 1 ether);
        assertEq(w.royaltyReceiver, receiver);
        assertEq(views.totalMinted(), tokenId);
        assertEq(IStreamViews(address(views)).totalSupply(), tokenId);
        assertEq(views.collectionCount(), collectionId);
        IStreamViews.Collection memory c = IStreamViews(address(views)).collection(collectionId);
        assertEq(c.minted, 1);
        assertGt(bytes(c.name).length, 0);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownCollection.selector, 999));
        IStreamViews(address(views)).collection(999);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, 999));
        IStreamViews(address(views)).work(999);
    }

    function test_Extension_LongCollectionNameRoundTrips() public {
        string memory name = "A collection whose name is longer than thirty-one bytes, stored long";
        vm.prank(platform);
        uint256 id = stream.createCollection(name, keccak256("m"));
        assertEq(IStreamViews(address(stream)).collection(id).name, name);
        vm.prank(platform);
        vm.expectRevert(IStream.InvalidCollectionName.selector);
        stream.createCollection("bad<name", 0);
    }

    function test_Extension_UnknownSelectorReverts() public {
        (bool ok,) = address(stream).call(abi.encodeWithSignature("nothingHere()"));
        assertFalse(ok);
        (ok,) = address(stream).call{ value: 1 }(abi.encodeWithSignature("totalMinted()"));
        assertFalse(ok, "the fallback is not payable");
    }

    // ------------------------------------------------------------------ royalty floor

    function test_SetRoyaltyRate_LowerOnlyInCore() public {
        uint256 tokenId = _first();
        (,,,,, uint32 rate) = stream.coreOf(tokenId);
        vm.prank(address(records));
        vm.expectRevert(abi.encodeWithSelector(IStream.InvalidRoyaltyRate.selector, rate + 1));
        stream.setRoyaltyRate(tokenId, rate + 1);
        vm.prank(address(records));
        stream.setRoyaltyRate(tokenId, rate - 1);
        (,,,,, uint32 lowered) = stream.coreOf(tokenId);
        assertEq(lowered, rate - 1);
    }

    // ------------------------------------------------------------------ renderer fail-closed

    function test_RendererOf_NotOpenServesDefault() public {
        uint256 tokenId = _first();
        assertEq(stream.rendererOf(tokenId), stream.defaultRenderer());
    }

    function test_RendererOf_FaultFailsClosed() public {
        uint256 tokenId = _first();
        vm.mockCallRevert(
            address(records),
            abi.encodeCall(IWorkRecords.pinnedRenderer, (tokenId)),
            abi.encodeWithSignature("Boom()")
        );
        vm.expectRevert(abi.encodeWithSignature("Boom()"));
        stream.rendererOf(tokenId);
    }

    function test_RendererOf_MalformedAnswerFailsClosed() public {
        uint256 tokenId = _first();
        vm.mockCall(
            address(records),
            abi.encodeCall(IWorkRecords.pinnedRenderer, (tokenId)),
            abi.encode(type(uint256).max)
        );
        vm.expectRevert(abi.encodeWithSelector(IStream.RendererPinUnreadable.selector, tokenId));
        stream.rendererOf(tokenId);
    }

    function test_RendererOf_ShortGasFailsClosed() public {
        uint256 tokenId = _first();
        // Enough to enter rendererOf, not enough for the satellite's cold reads.
        (bool ok,) =
            address(stream).call{ gas: 12_000 }(abi.encodeCall(stream.rendererOf, (tokenId)));
        assertFalse(ok, "a short read never serves a renderer");
    }

    // ------------------------------------------------------------------ dependencies

    function test_ArtistRegistry_IsPermanent() public {
        address current = stream.artistRegistry();
        bytes memory call =
            abi.encodeCall(stream.setDependency, (bytes32("ARTIST_REGISTRY"), current, current));
        _schedule(hotAdmin, address(stream), call);
        (, uint32 delay) = manager.canCall(hotAdmin, address(stream), bytes4(call));
        vm.warp(block.timestamp + delay);
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IStream.UnknownDependency.selector, bytes32("ARTIST_REGISTRY"))
        );
        manager.execute(address(stream), call);
    }

    function test_Burn_StillOnlyMintingAdapter() public {
        uint256 tokenId = _first();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC721Errors.ERC721IncorrectOwner.selector, address(this), tokenId, auction
            )
        );
        stream.burn(tokenId, 1);
    }
}
