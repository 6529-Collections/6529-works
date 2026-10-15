// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Renderer } from "src/content/Renderer.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice DEPS-6 on the renderer pins: a renderer is pinned by its code hash when it is
///         installed (Stream's default renderer) or pinned to a work (finalize, the errata
///         repin), and the hash is checked again every time `rendererOf` names it, so
///         `Stream.tokenURI` and `Editions.uri` never run code other than the code that was
///         pinned. A renderer whose code changed fails closed: the metadata view reverts (it
///         does not fall back to another renderer, which would show a finalized work in an
///         output format nobody pinned for it) until governance installs a renderer again
///         (`setDefaultRenderer`, or the errata repin for a finalized work).
/// @dev `vm.etch` stands for any way the code at the pinned address could change after the pin
///      (a contract created, pinned and self-destructed in one transaction, then recreated at
///      the same CREATE2 address). The replacement code here is the renderer's own runtime code
///      with one byte appended: it behaves the same, and is still refused.
contract RendererCodePinTest is IntegrationBase {
    address internal artist;
    address internal collector = makeAddr("pinCollector");
    uint256 internal open;
    uint256 internal finalized;

    function setUp() public override {
        super.setUp();
        artist = _actor("pinArtist");
        Work[] memory works = new Work[](2);
        works[0] = _work(artist, collectionId);
        works[1] = _work(artist, collectionId);
        bytes32 root = _publish(works);
        _keep(root, works);
        open = _sell(root, works, 0, collector, 1 ether);
        finalized = _sell(root, works, 1, collector, 1 ether);
        records.openRecord(open, works[0].item, works[0].media);
        records.openRecord(finalized, works[1].item, works[1].media);
        bytes32 state = records.workStateHash(finalized);
        vm.prank(artist);
        records.finalize(finalized, state);
    }

    function _changeCode(address target) internal {
        vm.etch(target, bytes.concat(target.code, hex"00"));
    }

    function _newRenderer() internal returns (Renderer) {
        return
            new Renderer(IContentStore(address(store)), IStatementLog(address(statements)), 262_144);
    }

    function _setDefault(address next) internal {
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(
                stream.setDefaultRenderer, (stream.defaultRenderer(), next, next.codehash)
            )
        );
    }

    /// @dev The default renderer's code changes: every work it serves (not finalized, or with no
    ///      open record) reverts, editions included; the finalized work keeps its own pin. A new
    ///      default renderer restores them.
    function test_DefaultRendererWithChangedCodeIsRefused() public {
        assertTrue(_contains(stream.tokenURI(open), '"name":"Work'));
        address pinned = address(renderer);
        _changeCode(pinned);
        vm.expectRevert(abi.encodeWithSelector(IStream.InvalidBinding.selector, pinned));
        stream.tokenURI(open);
        vm.expectRevert(abi.encodeWithSelector(IStream.InvalidBinding.selector, pinned));
        stream.rendererOf(open);

        Renderer next = _newRenderer();
        _setDefault(address(next));
        assertEq(stream.rendererOf(open), address(next));
        assertTrue(_contains(stream.tokenURI(open), '"name":"Work'));
    }

    /// @dev A finalized work's pinned renderer changes code: its `tokenURI` reverts, while the
    ///      works the (new, unchanged) default serves keep rendering. The errata repin to an
    ///      unchanged renderer restores it.
    function test_PinnedRendererWithChangedCodeIsRefused() public {
        Renderer next = _newRenderer();
        _setDefault(address(next));
        assertEq(stream.rendererOf(finalized), address(renderer), "the finalized pin");
        address pinned = address(renderer);
        _changeCode(pinned);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidRenderer.selector, pinned));
        stream.tokenURI(finalized);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidRenderer.selector, pinned));
        records.pinnedRenderer(finalized);
        assertTrue(_contains(stream.tokenURI(open), '"name":"Work'), "the default still serves");

        _repin(finalized, address(next));
        assertEq(stream.rendererOf(finalized), address(next));
        assertTrue(_contains(stream.tokenURI(finalized), '"name":"Work'));
    }

    /// @dev The errata repin pins the code hash the artist signed for; once a renderer address is
    ///      pinned with a code hash, a repin cannot pin it again with another (its works would
    ///      run code their artists never signed for).
    function test_RepinRefusesARendererWhoseCodeChangedSincePinned() public {
        // The other work is finalized under a new default, so it is pinned to that one.
        Renderer next = _newRenderer();
        _setDefault(address(next));
        bytes32 state = records.workStateHash(open);
        vm.prank(artist);
        records.finalize(open, state);
        assertEq(records.pinnedRenderer(open), address(next));
        // The first renderer's code changes. The artist signs the changed code's hash, but the
        // address was pinned (by the first work's finalize) with the original code.
        _changeCode(address(renderer));
        bytes memory call = _repinCall(open, address(renderer));
        _schedule(hotAdmin, address(records), call);
        vm.warp(block.timestamp + 30 days);
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.InvalidRenderer.selector, address(renderer))
        );
        manager.execute(address(records), call);
    }

    /// @dev Finalize pins the default renderer only while its code is the code Stream pinned.
    function test_FinalizeRefusesADefaultRendererWhoseCodeChanged() public {
        _changeCode(address(renderer));
        bytes32 state = records.workStateHash(open);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IStream.InvalidBinding.selector, address(renderer)));
        records.finalize(open, state);
    }

    function _repinCall(uint256 tokenId, address next) internal view returns (bytes memory) {
        uint64 deadline = uint64(block.timestamp + 40 days);
        bytes32 current = records.workStateHash(tokenId);
        bytes32 digest = _typedDigest(
            address(records),
            keccak256(
                abi.encode(
                    Typehashes.RENDERER_REPIN, tokenId, next, next.codehash, current, deadline
                )
            )
        );
        return abi.encodeCall(
            records.repinRenderer,
            (tokenId, next, next.codehash, current, deadline, _sign(artist, digest))
        );
    }

    function _repin(uint256 tokenId, address next) internal {
        _govern(hotAdmin, address(records), _repinCall(tokenId, next));
    }
}
