// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Renderer } from "src/content/Renderer.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStatementLog, Role, Statement } from "src/interfaces/IStatementLog.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { HASH_SHA256, HashRef } from "src/interfaces/types/HashRef.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Flow 3, continued: the governed amendments of a work's record on the real contracts
///         (relicense with every party's consent, a new default renderer, the errata repin) and
///         the artist and owner statements the statement log resolves through the artist
///         registry.
contract RecordAmendmentsFlowTest is IntegrationBase {
    address internal artist;
    address internal owner = makeAddr("recordOwner");
    bytes32 internal root;
    bytes32 internal byTextFileId;

    function setUp() public override {
        super.setUp();
        artist = _actor("amendingArtist");
        byTextFileId = _storeText("Creative Commons Attribution 4.0 (fixture)", "text/plain");
        Work[] memory works = new Work[](3);
        works[0] = _work(artist, collectionId);
        works[0].item.license = License("CC-BY-4.0", byTextFileId);
        works[1] = _work(artist, collectionId); // CC0, the default
        works[2] = _work(artist, collectionId); // CC0, finalized below
        root = _publish(works);
        _keep(root, works);
        for (uint256 i; i < 3; ++i) {
            uint256 tokenId = _sell(root, works, i, owner, 1 ether);
            records.openRecord(tokenId, works[i].item, works[i].media);
        }
    }

    function _relicenseCall(uint256 tokenId, uint256 index, License memory next)
        internal
        view
        returns (bytes memory)
    {
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes32 digest = _typedDigest(
            address(records),
            keccak256(
                abi.encode(
                    Typehashes.RELICENSE,
                    tokenId,
                    WorksHashing.licenseKey(next.spdxId),
                    next.textFileId,
                    state,
                    deadline
                )
            )
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(artist, digest);
        return abi.encodeCall(
            records.relicense, (tokenId, next, _package(root)[index].item, state, deadline, sigs)
        );
    }

    function test_RelicenseToCc0WithConsentAndGovernance() public {
        assertEq(records.licenseOf(1).spdxId, "CC-BY-4.0");
        assertTrue(_contains(stream.tokenURI(1), '"license":"CC-BY-4.0"'));
        _govern(hotAdmin, address(records), _relicenseCall(1, 0, License("CC0-1.0", cc0TextFileId)));
        assertEq(records.licenseOf(1).spdxId, "CC0-1.0");
        assertEq(records.record(1).licenseKey, WorksHashing.CC0_LICENSE_KEY);
        assertTrue(_contains(stream.tokenURI(1), '"license":"CC0-1.0"'));
        // CC0 is irrevocable.
        bytes memory back = _relicenseCall(1, 0, License("CC-BY-4.0", byTextFileId));
        _schedule(hotAdmin, address(records), back);
        vm.warp(block.timestamp + 2 days);
        vm.prank(hotAdmin);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.LicenseIrrevocable.selector, 1));
        manager.execute(address(records), back);
    }

    /// @dev A CC0 work names the deployment's CC0 text and keeps it: another text is refused
    ///      even with every consent and the governed action.
    function test_Cc0WorkKeepsThePinnedText() public {
        bytes32 corrected = _storeText("CC0 1.0 Universal (corrected text)", "text/plain");
        bytes memory call = _relicenseCall(2, 1, License("CC0-1.0", corrected));
        _schedule(hotAdmin, address(records), call);
        vm.warp(block.timestamp + 2 days);
        vm.prank(hotAdmin);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        manager.execute(address(records), call);
        assertEq(records.licenseOf(2).textFileId, cc0TextFileId);
    }

    /// @dev A finalized work's new license text must be stored on-chain, not only registered.
    function test_FinalizedWorkNeedsAnOnChainLicenseText() public {
        bytes32 state = records.workStateHash(1);
        vm.prank(artist);
        records.finalize(1, state);
        bytes memory text = "MIT License (fixture), off-chain only";
        bytes32 offChain =
            _registerOnly(text, IContentStore.Encoding.Identity, "text/plain", sha256(text));
        bytes memory call = _relicenseCall(1, 0, License("MIT", offChain));
        _schedule(hotAdmin, address(records), call);
        vm.warp(block.timestamp + 2 days);
        vm.prank(hotAdmin);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        manager.execute(address(records), call);
        _writeChunks(text);
        vm.prank(hotAdmin);
        manager.execute(address(records), call);
        assertEq(records.licenseOf(1).spdxId, "MIT");
    }

    /// @dev A new default renderer (30-day class) reaches works that are not finalized; a
    ///      finalized work keeps its pin until the artist agrees to the errata repin (also 30
    ///      days). Editions hear about the change.
    function test_NewDefaultRendererAndTheErrataRepin() public {
        bytes32 state = records.workStateHash(3);
        vm.prank(artist);
        records.finalize(3, state);
        Renderer next = new Renderer(
            IContentStore(address(store)), IStatementLog(address(statements)), 131_072
        );
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(
                stream.setDefaultRenderer,
                (address(renderer), address(next), address(next).codehash)
            )
        );
        assertEq(stream.defaultRenderer(), address(next));
        assertEq(stream.rendererOf(2), address(next), "not finalized: the new default");
        assertEq(stream.rendererOf(3), address(renderer), "finalized: still pinned");

        uint64 deadline = uint64(block.timestamp + 40 days);
        bytes32 current = records.workStateHash(3);
        bytes32 digest = _typedDigest(
            address(records),
            keccak256(
                abi.encode(
                    Typehashes.RENDERER_REPIN,
                    3,
                    address(next),
                    address(next).codehash,
                    current,
                    deadline
                )
            )
        );
        _govern(
            hotAdmin,
            address(records),
            abi.encodeCall(
                records.repinRenderer,
                (3, address(next), address(next).codehash, current, deadline, _sign(artist, digest))
            )
        );
        assertEq(stream.rendererOf(3), address(next), "the errata repin");
    }

    function test_ArtistAndOwnerStatementsResolveThroughTheRegistry() public {
        Statement memory s = Statement(
            address(stream),
            1,
            StatementKinds.ARTIST_STATEMENT,
            keccak256("6529-works/artist-statement/1"),
            HashRef(HASH_SHA256, keccak256("my statement")),
            "ar://artist-statement",
            bytes32(0),
            bytes32(0)
        );
        vm.prank(artist);
        statements.append(Role.ARTIST, s);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.ARTIST, owner)
        );
        statements.append(Role.ARTIST, s);
        s.kind = StatementKinds.EXHIBITION;
        vm.prank(owner);
        statements.append(Role.OWNER, s);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.OWNER, artist)
        );
        statements.append(Role.OWNER, s);
        (uint64 count,) = statements.chainOf(address(stream), 1);
        assertEq(count, 2);
    }
}
