// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { RendererBase } from "./RendererBase.sol";
import { HostileStore, ShortAnswerToken } from "../../mocks/content/RendererHostile.sol";
import { CollectionInfo, HostileDelivery, RecordInfo, WorkCore } from "./RendererCoreMocks.sol";
import {
    GasBurnerMock,
    ReturnBombMock,
    ReturnDataMock
} from "../../mocks/libraries/AdversarialTargets.sol";
import { Renderer } from "src/content/Renderer.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
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
        RecordInfo memory info;
        info.recordFileId = hostile.RECORD();
        info.onChainComplete = true;
        stream.setWork(ID, _core());
        records.setRecord(ID, info);
        records.setOpen(ID, true);
        MediaFile[] memory media = new MediaFile[](1);
        media[0] = MediaFile(bytes32(uint256(0xf11e)), bytes32(uint256(1)), uint8(FileRole.PRIMARY));
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
        // One byte over the chunk size is refused by the return-size cap before the length check.
        HostileStore tooLong = _withStore(HostileStore.Mode.LongChunk);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector,
                address(tooLong),
                IContentStore.readChunk.selector
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
                abi.encodeWithSelector(
                    IRenderer.RendererReadFailed.selector,
                    address(hostile),
                    IContentStore.readChunk.selector
                )
            );
            _uriOnHostile();
        }
    }

    /// @dev The gas rule (ADR 0007): every read forwards all the gas it may, so a chunk read
    ///      that burns everything is a shortfall, which reverts as one; it never reads as a
    ///      refusal or yields a token without media.
    function test_Store_AChunkThatBurnsGasIsAShortfall() public {
        HostileStore hostile = _withStore(HostileStore.Mode.BurnChunk);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, address(hostile))
        );
        _uriOnHostile();
    }

    function test_Store_BadCompletenessAnswersFailClosed() public {
        _withStore(HostileStore.Mode.NonBoolComplete);
        vm.expectRevert();
        _uriOnHostile();

        HostileStore hostile = _withStore(HostileStore.Mode.BurnComplete);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, address(hostile))
        );
        _uriOnHostile();
    }

    function test_Store_BadAttestationAnswersFailClosed() public {
        _withStore(HostileStore.Mode.NonBoolAttest);
        vm.expectRevert();
        _uriOnHostile();

        HostileStore hostile = _withStore(HostileStore.Mode.BurnAttest);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, address(hostile))
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
                IRenderer.RendererReadFailed.selector, bomb, IStream.workOf.selector
            )
        );
        renderer.tokenURI(bomb, ID);

        // A token that burns everything it is given is a shortfall (the gas rule): the call
        // reverts as one and never answers.
        address burner = address(new GasBurnerMock());
        vm.expectRevert(abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, burner));
        renderer.tokenURI(burner, ID);
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

    /// @dev A token whose `workOf` answer is shorter than the eleven words of a `Work` fails
    ///      closed: the answer cannot be decoded.
    function test_Token_AShortWorkAnswerFailsClosed() public {
        ShortAnswerToken token = new ShortAnswerToken(0, 0);
        vm.expectRevert();
        renderer.tokenURI(address(token), ID);
    }

    function test_Token_OversizedAnswersFailClosed() public {
        bytes32 file = _file(hex"89504e47", IDENTITY, "image/png");

        // A license identifier above 64 bytes makes the record larger than a real one can be.
        _install(file);
        records.setLicense(ID, License(_text(5_000), bytes32(0)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector, address(records), IWorkFacts.factsOf.selector
            )
        );
        renderer.tokenURI(address(stream), ID);

        // A collection name above 128 bytes (`Renderer.MAX_NAME_BYTES`), or not UTF-8, is no
        // name: the work still renders, with an empty collection name.
        records.setLicense(ID, _license());
        WorkCore memory core = _core();
        core.collectionId = 1;
        stream.setWork(ID, core);
        stream.setCollection(1, CollectionInfo(_text(5_000), bytes32(0), 1));
        assertEq(_attr(_out(), "Collection"), "");
        stream.setCollectionName(1, hex"ff");
        assertEq(_attr(_out(), "Collection"), "");
        stream.setCollectionName(1, bytes(_text(129)));
        assertEq(_attr(_out(), "Collection"), "");
        stream.setCollectionName(1, bytes(_text(128)));
        assertEq(_attr(_out(), "Collection"), _text(128));

        // More media files than a work may have.
        stream.setWork(ID, _core());
        MediaFile[] memory media = new MediaFile[](33);
        for (uint256 i; i < media.length; ++i) {
            media[i] = MediaFile(
                bytes32(i + 1),
                bytes32(i + 1),
                i == 0 ? uint8(FileRole.PRIMARY) : uint8(FileRole.AUXILIARY)
            );
        }
        records.setMedia(ID, media);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector, address(records), IWorkFacts.factsOf.selector
            )
        );
        renderer.tokenURI(address(stream), ID);
    }

    /// @dev The renderer owns the locator check: a locator longer than a URL may be, whether it
    ///      fits the return cap or not, is no locator, and the work renders without it.
    function test_Token_AnOversizedLocatorIsNoLocator() public {
        bytes32 file = _file(_data(THRESHOLD + 1, 1), IDENTITY, "image/png");
        _install(file);
        records.addLocator(ID, file, Locator(LocatorKind.IPFS, _text(2_500)));
        string memory j = _out();
        assertFalse(_has(j, ".image"));
        assertFalse(_has(j, ".media_url"));
        assertEq(_str(j, ".name"), "Title");
    }

    /// @dev No read has a gas cap (the gas rule, ADR 0007): a repricing that makes the media
    ///      read cost 2x, 4x or 10x its cost today (under 200,000 gas fully cold at 32 files,
    ///      `TokenUriBudget.t.sol`) makes `tokenURI` dearer, never different or failed, so a work
    ///      whose renderer is pinned for good keeps its metadata.
    function test_Records_TheMediaReadHasNoGasCap() public {
        bytes32 file = _file(hex"89504e47", IDENTITY, "image/png");
        _install(file);
        string memory full = _out();
        uint256[3] memory burns = [uint256(400_000), 800_000, 2_000_000];
        for (uint256 i; i < burns.length; ++i) {
            records.burn(IWorkFacts.factsOf.selector, burns[i]);
            assertEq(_out(), full, "the same metadata at any cost");
        }
    }

    /// Regression: M1 in the review of #20
    /// @dev A delivery contract whose `preferredLocator` costs more than the old 300,000-gas cap
    ///      still answers (no cap); one that burns everything it is given is a shortfall and
    ///      fails the call (the gas rule): it is not "no media".
    function test_Delivery_APreferredLocatorThatRunsOutOfGasIsAShortfall() public {
        bytes32 file = _file(_data(THRESHOLD + 1, 5), IDENTITY, "text/html");
        _install(file);
        HostileDelivery d = new HostileDelivery();
        records.setDelivery(address(d));
        string memory full = _out();
        assertEq(_str(full, ".animation_url"), "ar://honest");

        d.setMode(HostileDelivery.Mode.BURN_SOME, 310_000);
        assertEq(_out(), full, "a dearer locator read gives the same metadata");

        d.setMode(HostileDelivery.Mode.BURN_ALL, 0);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, address(d))
        );
        renderer.tokenURI(address(stream), ID);
    }

    /// @dev A delivery contract that lies (a URI with a quote, a backslash, a space, a control
    ///      or non-ASCII byte, an ONCHAIN answer with a URI, a kind over 255), answers more than
    ///      a URI may hold or a non-canonical encoding, or reverts, is no locator: the work
    ///      renders, with no media URL and nothing else changed.
    function test_Delivery_EveryBadAnswerIsNoLocator() public {
        bytes32 file = _file(_data(THRESHOLD + 1, 5), IDENTITY, "text/html");
        _install(file);
        HostileDelivery d = new HostileDelivery();
        records.setDelivery(address(d));
        string memory honest = _out();
        assertEq(_str(honest, ".media_url"), "ar://honest");
        records.setDelivery(address(0));
        string memory none = _out();
        assertFalse(_has(none, ".media_url"));
        records.setDelivery(address(d));
        for (
            uint256 m = uint256(HostileDelivery.Mode.QUOTE);
            m <= uint256(HostileDelivery.Mode.REVERT);
            ++m
        ) {
            d.setMode(HostileDelivery.Mode(m), 0);
            assertEq(_out(), none, vm.toString(m));
        }
    }

    /// @dev A RECORDS module that is missing, has no `delivery`, or answers something that is not
    ///      an address, is no locator; so is a delivery contract without code.
    function test_Delivery_AMissingOrBrokenRecordsModuleIsNoLocator() public {
        bytes32 file = _file(_data(THRESHOLD + 1, 5), IDENTITY, "text/html");
        _install(file);
        records.addLocator(ID, file, Locator(LocatorKind.ARWEAVE, "ar://tx"));
        assertEq(_str(_out(), ".media_url"), "ar://tx");
        records.fail(bytes4(keccak256("delivery()")), true);
        assertFalse(_has(_out(), ".media_url"), "delivery() refuses");
        records.fail(bytes4(keccak256("delivery()")), false);
        records.setDelivery(makeAddr("no code"));
        assertFalse(_has(_out(), ".media_url"), "no code");
        records.setDelivery(address(records));
        stream.setModule("RECORDS", address(0));
        assertFalse(_has(_out(), ".media_url"), "no RECORDS module");
        ReturnDataMock wide = new ReturnDataMock();
        wide.configure(abi.encode(type(uint256).max), false);
        stream.setModule("RECORDS", address(wide));
        assertFalse(_has(_out(), ".media_url"), "not an address");
    }

    /// @dev Too little gas for the whole call reverts; it never returns metadata that a
    ///      starved read made plausible but wrong.
    function test_NotEnoughGasRevertsInsteadOfMisreporting() public {
        bytes32 file = _file(hex"89504e47", IDENTITY, "image/png");
        _install(file);
        string memory full = renderer.tokenURI(address(stream), ID);
        for (uint256 g = 50_000; g <= 400_000; g += 50_000) {
            try renderer.tokenURI{ gas: g }(address(stream), ID) returns (string memory out) {
                assertEq(out, full, "an answer is the full answer");
            } catch { }
        }
    }

    function _text(uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = "x";
        }
        return string(b);
    }
}
