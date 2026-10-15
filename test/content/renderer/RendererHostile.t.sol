// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { RendererBase } from "./RendererBase.sol";
import { BurningRecords, HostileStore } from "../../mocks/content/RendererHostile.sol";
import { StreamMock } from "../../mocks/stream/StreamMock.sol";
import {
    GasBurnerMock,
    ReturnBombMock,
    ReturnDataMock
} from "../../mocks/libraries/AdversarialTargets.sol";
import { Renderer } from "src/content/Renderer.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { IRenderer } from "src/interfaces/IRenderer.sol";

/// @dev A renderer is a view over whatever `token` and its store say: a hostile or broken answer
///      must end in a revert (fail closed), never in metadata, and must never cost more than the
///      per-read gas caps.
contract RendererHostileTest is RendererBase {
    uint256 internal constant LENGTH = 30_000; // two chunks

    Renderer internal onHostile;

    /// @dev Work `ID` whose record and media live in a hostile store, read by its own renderer.
    function _withStore(HostileStore.Mode mode) internal returns (HostileStore hostile) {
        hostile = new HostileStore(LENGTH, mode, bytes('{"name":"N"}'));
        onHostile =
            new Renderer(IContentStore(address(hostile)), IStatementLog(address(0)), THRESHOLD);
        IWorkRecords.RecordInfo memory info;
        info.recordFileId = hostile.RECORD();
        info.onChainComplete = true;
        stream.setWork(ID, _core());
        records.setRecord(ID, info);
        records.setOpen(ID, true);
        MediaFile[] memory media = new MediaFile[](1);
        media[0] = MediaFile(bytes32(uint256(0xf11e)), bytes32(uint256(1)), FileRole.PRIMARY);
        records.setMedia(ID, media);
        records.setLicense(ID, _license());
    }

    function _uriOnHostile() internal view returns (string memory) {
        return onHostile.tokenURI(address(stream), ID);
    }

    // ---------------------------------------------------------------- the store

    function test_Store_HonestBaseline() public {
        _withStore(HostileStore.Mode.Honest);
        bytes memory a = new bytes(LENGTH);
        for (uint256 i; i < LENGTH; ++i) {
            a[i] = "A";
        }
        assertEq(
            _str(_decode(_uriOnHostile()), ".image"),
            string.concat("data:image/png;base64,", string(a))
        );
    }

    function test_Store_ChunksOfTheWrongLengthRevert() public {
        HostileStore.Mode[2] memory modes =
            [HostileStore.Mode.EmptyChunk, HostileStore.Mode.ShortChunk];
        for (uint256 i; i < modes.length; ++i) {
            HostileStore hostile = _withStore(modes[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IRenderer.RendererReadFailed.selector,
                    address(hostile),
                    IContentStore.readChunk.selector
                )
            );
            _uriOnHostile();
        }
        // One byte over the chunk size is refused by the bounded decoder before the length check.
        HostileStore tooLong = _withStore(HostileStore.Mode.LongChunk);
        vm.expectRevert(
            abi.encodeWithSelector(
                BoundedCall.BoundedCallMalformedReturn.selector, address(tooLong)
            )
        );
        _uriOnHostile();
    }

    function test_Store_ARevertingOrOversizedChunkReadFailsClosed() public {
        HostileStore.Mode[2] memory modes =
            [HostileStore.Mode.RevertChunk, HostileStore.Mode.BombChunk];
        for (uint256 i; i < modes.length; ++i) {
            HostileStore hostile = _withStore(modes[i]);
            vm.expectRevert(
                abi.encodeWithSelector(BoundedCall.BoundedCallFailed.selector, address(hostile))
            );
            _uriOnHostile();
        }
    }

    function test_Store_AChunkThatBurnsGasCostsOnlyItsCap() public {
        HostileStore hostile = _withStore(HostileStore.Mode.BurnChunk);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallFailed.selector, address(hostile))
        );
        _uriOnHostile();

        // The cost: the chunk's cap (300,000 gas) plus the other reads.
        uint256 before = gasleft();
        try onHostile.tokenURI(address(stream), ID) returns (string memory) { } catch { }
        assertLt(before - gasleft(), 900_000);
    }

    function test_Store_BadCompletenessAnswersFailClosed() public {
        _withStore(HostileStore.Mode.NonBoolComplete);
        vm.expectRevert();
        _uriOnHostile();

        HostileStore hostile = _withStore(HostileStore.Mode.BurnComplete);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector,
                address(hostile),
                IContentStore.isComplete.selector
            )
        );
        _uriOnHostile();
    }

    function test_Store_BadAttestationAnswersFailClosed() public {
        _withStore(HostileStore.Mode.NonBoolAttest);
        vm.expectRevert();
        _uriOnHostile();

        HostileStore hostile = _withStore(HostileStore.Mode.BurnAttest);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector,
                address(hostile),
                IContentStore.isBase64Attested.selector
            )
        );
        _uriOnHostile();
    }

    function test_Store_AnOversizedFileInfoFailsClosed() public {
        HostileStore hostile = _withStore(HostileStore.Mode.BombInfo);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector,
                address(hostile),
                IContentStore.fileInfo.selector
            )
        );
        _uriOnHostile();
    }

    // ---------------------------------------------------------------- the token

    function test_Token_ReturnDataBombsAndGasBurnersFailClosed() public {
        address bomb = address(new ReturnBombMock(1_000_000, bytes32(uint256(1))));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector, bomb, IStream.work.selector
            )
        );
        renderer.tokenURI(bomb, ID);

        address burner = address(new GasBurnerMock());
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector, burner, IStream.work.selector
            )
        );
        renderer.tokenURI(burner, ID);
        // Two reads, each capped at 300,000 gas.
        uint256 before = gasleft();
        try renderer.tokenURI(burner, ID) returns (string memory) { } catch { }
        assertLt(before - gasleft(), 800_000);
    }

    function test_Token_GarbageAnswersFailClosed() public {
        ReturnDataMock garbage = new ReturnDataMock();
        bytes memory junk = new bytes(480);
        for (uint256 i; i < junk.length; ++i) {
            junk[i] = 0xff;
        }
        garbage.configure(junk, false);
        vm.expectRevert(); // an enum outside its range cannot be decoded
        renderer.tokenURI(address(garbage), ID);

        garbage.configure("", false); // an empty answer
        vm.expectRevert();
        renderer.tokenURI(address(garbage), ID);
    }

    function test_Token_OversizedAnswersFailClosed() public {
        bytes32 file = _file(hex"89504e47", IDENTITY, "image/png");

        // A license identifier above 64 bytes (plus the encoding) cannot be a real license.
        _install(file);
        records.setLicense(ID, License(_text(5_000), bytes32(0)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector,
                address(records),
                IWorkRecords.licenseOf.selector
            )
        );
        renderer.tokenURI(address(stream), ID);

        // A collection name above 4 KiB.
        records.setLicense(ID, _license());
        IStream.WorkCore memory core = _core();
        core.collectionId = 1;
        stream.setWork(ID, core);
        stream.setCollection(1, IStream.Collection(_text(5_000), bytes32(0), 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector, address(stream), IStream.collection.selector
            )
        );
        renderer.tokenURI(address(stream), ID);

        // More media files than a work may have.
        stream.setWork(ID, _core());
        MediaFile[] memory media = new MediaFile[](33);
        for (uint256 i; i < media.length; ++i) {
            media[i] = MediaFile(
                bytes32(i + 1), bytes32(i + 1), i == 0 ? FileRole.PRIMARY : FileRole.AUXILIARY
            );
        }
        records.setMedia(ID, media);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector,
                address(records),
                IWorkRecords.mediaOf.selector
            )
        );
        renderer.tokenURI(address(stream), ID);
    }

    /// @dev Decision M1: a locator read that fails, here by returning more than a URL may have,
    ///      fails the call. Media silently dropped would be a plausible but wrong token.
    function test_Token_AnOversizedLocatorFailsClosed() public {
        bytes32 file = _file(_data(THRESHOLD + 1, 1), IDENTITY, "image/png");
        _install(file);
        records.addLocator(ID, file, Locator(LocatorKind.IPFS, _text(2_500)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector,
                address(records),
                IWorkRecords.preferredLocator.selector
            )
        );
        renderer.tokenURI(address(stream), ID);
    }

    /// @dev The media list has a read cap of its own, 1,000,000 gas: the real satellite's
    ///      `mediaOf` makes one content-store read per file, under 200,000 gas fully cold at 32
    ///      files (`TokenUriBudget.t.sol`), so a repricing of cold reads does not stop
    ///      `tokenURI` for the largest works. A read past the cap still fails closed.
    function test_Records_TheMediaReadHasRoomAboveItsCost() public {
        bytes32 file = _file(hex"89504e47", IDENTITY, "image/png");
        _install(file);
        records.burn(IWorkRecords.mediaOf.selector, 800_000);
        assertFalse(_has(_out(), ".record_status"), "the full metadata");

        records.burn(IWorkRecords.mediaOf.selector, 1_000_000);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector,
                address(records),
                IWorkRecords.mediaOf.selector
            )
        );
        renderer.tokenURI(address(stream), ID);
    }

    /// Regression: M1 in the review of #20
    /// @dev A satellite that spends its gas cap on `preferredLocator` (a stream lane walking a
    ///      large file to answer an on-chain preference) fails the call: it is not "no media".
    function test_Records_APreferredLocatorThatRunsOutOfGasFailsClosed() public {
        bytes32 file = _file(_data(THRESHOLD + 1, 5), IDENTITY, "text/html");
        _install(file);
        records.addLocator(ID, file, Locator(LocatorKind.ARWEAVE, "ar://tx"));
        assertTrue(_has(_out(), ".animation_url"));

        BurningRecords burning = new BurningRecords(address(records), 310_000);
        stream.setWorkRecords(address(burning));

        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector,
                address(burning),
                IWorkRecords.preferredLocator.selector
            )
        );
        renderer.tokenURI(address(stream), ID);
    }

    function test_NotEnoughGasRevertsInsteadOfMisreporting() public {
        bytes32 file = _file(hex"89504e47", IDENTITY, "image/png");
        _install(file);
        // The first read is capped at 300,000 gas and needs that much, plus a share, to be sent.
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallInsufficientGas.selector, 300_000)
        );
        renderer.tokenURI{ gas: 250_000 }(address(stream), ID);
    }

    function _text(uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = "x";
        }
        return string(b);
    }
}
