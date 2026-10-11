// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { RendererBase } from "./RendererBase.sol";
import { IBase64Attested, Renderer } from "src/content/Renderer.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { SeedPolicy } from "src/interfaces/types/PackageTypes.sol";

/// @dev Which media the renderer inlines, which it hands out by locator, and the HTML page it
///      builds around a script.
contract RendererMediaTest is RendererBase {
    /// @dev A renderer with the largest threshold, which inlines an `Identity` file of up to
    ///      128 KiB, for the tests of long identity files.
    Renderer internal wide;

    function setUp() public override {
        super.setUp();
        wide = new Renderer(store, IStatementLog(address(disputeLog)), 1_048_576);
    }

    function _wideOut() internal view returns (string memory) {
        return _decode(wide.tokenURI(address(stream), ID));
    }

    string internal constant PNG = "image/png";
    string internal constant IPFS = "ipfs://bafyprimary";
    string internal constant AR = "ar://primary";

    function _dataUri(string memory mime, bytes memory media)
        internal
        pure
        returns (string memory)
    {
        return string.concat("data:", mime, ";base64,", Base64.encode(media));
    }

    /// @dev A work whose primary file is `primary`, with `preview` as its PREVIEW file.
    function _workWith(bytes32 primary, bytes32 preview) internal {
        _install(primary, preview, _rec());
    }

    function _noMedia(string memory json) internal view {
        assertFalse(_has(json, ".image"));
        assertFalse(_has(json, ".animation_url"));
        assertFalse(_has(json, ".media_url"));
    }

    // ---------------------------------------------------------------- inline: the rules

    function test_Inline_Base64StoredTextIsConcatenatedAsItIs() public {
        bytes memory media = _data(1_000, 1);
        bytes32 file = _file(bytes(Base64.encode(media)), BASE64, PNG);
        _install(file);

        string memory j = _out();

        assertEq(_str(j, ".image"), _dataUri(PNG, media));
        assertFalse(_has(j, ".animation_url"));
        assertFalse(_has(j, ".media_url"));
        assertEq(_str(j, ".content_type"), PNG);
    }

    function test_Inline_IdentityStoredBytesAreEncodedOnChain() public {
        bytes memory media = _data(1_000, 2);
        bytes32 file = _file(media, IDENTITY, PNG);
        _install(file);

        assertEq(_str(_out(), ".image"), _dataUri(PNG, media));
    }

    function testFuzz_Inline_IdentityAnyLengthAcrossChunks(uint256 length, uint256 seed) public {
        length = bound(length, 1, 3 * CHUNK + 50);
        bytes memory media = _data(length, seed);
        bytes32 file = _file(media, IDENTITY, PNG);
        _install(file);

        assertEq(_str(_wideOut(), ".image"), _dataUri(PNG, media));
    }

    function testFuzz_Inline_Base64AnyLengthAcrossChunks(uint256 length, uint256 seed) public {
        length = bound(length, 1, 2 * CHUNK);
        bytes memory media = _data(length, seed);
        bytes32 file = _file(bytes(Base64.encode(media)), BASE64, PNG);
        _install(file);

        assertEq(_str(_out(), ".image"), _dataUri(PNG, media));
    }

    function test_Inline_ChunkBoundaries() public {
        uint256[6] memory lengths =
            [CHUNK - 1, CHUNK, CHUNK + 1, 2 * CHUNK - 1, 2 * CHUNK, 2 * CHUNK + 1];
        for (uint256 i; i < lengths.length; ++i) {
            bytes memory media = _data(lengths[i], i);
            _install(_file(media, IDENTITY, PNG));
            assertEq(_str(_wideOut(), ".image"), _dataUri(PNG, media));
        }
    }

    function test_Inline_EveryTypeOfMimeKeepsItsLabel() public {
        bytes memory media = _data(300, 3);
        string[4] memory mimes = ["image/svg+xml", "image/webp", "image/gif", "image/avif"];
        for (uint256 i; i < mimes.length; ++i) {
            _install(_file(media, IDENTITY, mimes[i]));
            assertEq(_str(_out(), ".image"), _dataUri(mimes[i], media));
        }
    }

    function test_Inline_TheThresholdIsInclusive() public {
        Renderer small = new Renderer(store, IStatementLog(address(disputeLog)), 1_000);
        bytes memory fits = _data(750, 4); // 1,000 base64 characters
        _install(_file(bytes(Base64.encode(fits)), BASE64, PNG));
        assertEq(_str(_decode(small.tokenURI(address(stream), ID)), ".image"), _dataUri(PNG, fits));

        bytes memory over = _data(751, 5); // 1,004
        bytes32 file = _file(bytes(Base64.encode(over)), BASE64, PNG);
        _install(file);
        records.addLocator(ID, file, Locator(LocatorKind.IPFS, IPFS));
        assertEq(_str(_decode(small.tokenURI(address(stream), ID)), ".image"), IPFS);
    }

    /// @dev An `Identity` file costs several times a base64 file of the same size to render (it
    ///      is encoded on-chain), so it counts eight times against the threshold.
    function test_Inline_AnIdentityFileCountsEightTimes() public {
        Renderer small = new Renderer(store, IStatementLog(address(disputeLog)), 1_000);
        bytes memory fits = _data(125, 6);
        _install(_file(fits, IDENTITY, PNG));
        assertEq(_str(_decode(small.tokenURI(address(stream), ID)), ".image"), _dataUri(PNG, fits));

        bytes32 file = _file(_data(126, 7), IDENTITY, PNG);
        _install(file);
        records.addLocator(ID, file, Locator(LocatorKind.IPFS, IPFS));
        assertEq(_str(_decode(small.tokenURI(address(stream), ID)), ".image"), IPFS);
    }

    function test_Inline_TheThresholdCountsStoredBytesNotDecodedBytes() public {
        Renderer small = new Renderer(store, IStatementLog(address(disputeLog)), 1_000);
        // 750 decoded bytes are 1,000 stored base64 characters; 751 are 1,004.
        bytes memory fits = _data(750, 6);
        _install(_file(bytes(Base64.encode(fits)), BASE64, PNG));
        assertEq(_str(_decode(small.tokenURI(address(stream), ID)), ".image"), _dataUri(PNG, fits));

        bytes memory over = _data(751, 7);
        bytes32 file = _file(bytes(Base64.encode(over)), BASE64, PNG);
        _install(file);
        assertFalse(_has(_decode(small.tokenURI(address(stream), ID)), ".image"));
    }

    // ---------------------------------------------------------------- not inlined: locators

    function test_Locator_OverTheThresholdUsesThePreferredLocator() public {
        bytes32 file = _file(_data(THRESHOLD + 1, 8), IDENTITY, PNG);
        _install(file);
        records.addLocator(ID, file, Locator(LocatorKind.IPFS, IPFS));
        records.addLocator(ID, file, Locator(LocatorKind.ARWEAVE, AR));

        string memory j = _out();

        assertEq(_str(j, ".image"), IPFS);
        assertEq(_str(j, ".media_url"), IPFS);
        assertFalse(_has(j, ".animation_url"));
        assertLt(bytes(_uri()).length, 3_000, "compact");
    }

    function test_Locator_NoneRegisteredMeansNoMediaButStillMetadata() public {
        bytes32 file = _file(_data(THRESHOLD + 1, 9), IDENTITY, PNG);
        _install(file);

        string memory j = _out();

        _noMedia(j);
        assertEq(_str(j, ".name"), "Title");
        assertEq(_str(j, ".content_type"), PNG);
        assertEq(_str(j, ".content_hash"), vm.toString(sha256(_data(THRESHOLD + 1, 9))));
    }

    /// @dev Decision M1: the satellite's answer is the preference, and an on-chain preference has
    ///      no URL. The renderer does not look through the list for another copy.
    function test_Locator_AnOnChainPreferenceGivesNoUrl() public {
        bytes32 file = _file(_data(THRESHOLD + 1, 10), IDENTITY, PNG);
        _install(file);
        records.addLocator(ID, file, Locator(LocatorKind.ARWEAVE, AR));
        records.preferOnchain(ID, file, true);

        _noMedia(_out());

        bytes32 bare = _file(_data(THRESHOLD + 1, 11), IDENTITY, PNG);
        _install(bare);
        records.preferOnchain(ID, bare, true);
        _noMedia(_out());
    }

    /// @dev A locator of kind NONE is no locator, whatever its text (the satellite answers it for a
    ///      file without a copy).
    function test_Locator_KindNoneGivesNoMediaField() public {
        bytes32 file = _file(_data(THRESHOLD + 1, 44), IDENTITY, PNG);
        _install(file);
        records.addLocator(ID, file, Locator(LocatorKind.NONE, ""));
        _noMedia(_out());
        bytes32 other = _file(_data(THRESHOLD + 1, 45), IDENTITY, PNG);
        _install(other);
        records.addLocator(ID, other, Locator(LocatorKind.NONE, IPFS));
        _noMedia(_out());
        // An empty URL of a real kind is no media either.
        bytes32 third = _file(_data(THRESHOLD + 1, 46), IDENTITY, PNG);
        _install(third);
        records.addLocator(ID, third, Locator(LocatorKind.IPFS, ""));
        _noMedia(_out());
    }

    /// @dev Decision M1: a satellite that cannot answer `preferredLocator` within its gas cap fails
    ///      the call. Media silently dropped would be a plausible but wrong token.
    function test_Locator_AFailedReadFailsClosed() public {
        bytes32 file = _file(_data(THRESHOLD + 1, 47), IDENTITY, PNG);
        _install(file);
        records.fail(IWorkRecords.preferredLocator.selector, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                Renderer.RendererReadFailed.selector,
                address(records),
                IWorkRecords.preferredLocator.selector
            )
        );
        renderer.tokenURI(address(stream), ID);
    }

    function test_Locator_GzipFilesAreNeverInlined() public {
        IContentStore.Encoding[2] memory encodings = [GZIP, GZIP_BASE64];
        for (uint256 i; i < 2; ++i) {
            bytes32 file = _file(_data(500, 12 + i), encodings[i], PNG);
            _install(file);
            records.addLocator(ID, file, Locator(LocatorKind.ARWEAVE, AR));
            string memory j = _out();
            assertEq(_str(j, ".image"), AR);
            assertEq(_str(j, ".media_url"), AR);
        }
    }

    function test_Locator_NotOnChainCompleteIsNotInlined() public {
        bytes32 file = _file(_data(500, 14), IDENTITY, PNG);
        _install(file);
        IWorkRecords.RecordInfo memory info = _info();
        info.onChainComplete = false;
        _setRecordInfo(info);
        records.addLocator(ID, file, Locator(LocatorKind.IPFS, IPFS));

        assertEq(_str(_out(), ".image"), IPFS);
    }

    function test_Locator_AMissingChunkFallsBackToTheLocator() public {
        bytes memory media = _data(2 * CHUNK + 10, 15);
        bytes32 file = _incompleteFile(media, IDENTITY, PNG);
        _install(file); // the Stream says complete; the store says otherwise
        records.addLocator(ID, file, Locator(LocatorKind.IPFS, IPFS));
        assertFalse(store.isComplete(file));

        assertEq(_str(_wideOut(), ".image"), IPFS);

        // Completing the upload switches the same token to the inline media.
        (bytes[] memory chunks,) = _split(media);
        store.writeChunk(chunks[2]);
        assertEq(_str(_wideOut(), ".image"), _dataUri(PNG, media));
    }

    // ---------------------------------------------------------------- previews

    function test_Preview_OnChainPreviewIsTheImageAndTheLocatorIsMediaUrl() public {
        bytes32 primary = _file(_data(THRESHOLD + 1, 16), IDENTITY, PNG);
        bytes memory small = _data(2_000, 17);
        bytes32 preview = _file(small, IDENTITY, "image/jpeg");
        _workWith(primary, preview);
        records.addLocator(ID, primary, Locator(LocatorKind.IPFS, IPFS));

        string memory j = _out();

        assertEq(_str(j, ".image"), _dataUri("image/jpeg", small));
        assertEq(_str(j, ".media_url"), IPFS);
        assertFalse(_has(j, ".animation_url"));
    }

    function test_Preview_IsNotShownWhenAnImagePrimaryIsInlined() public {
        bytes memory media = _data(500, 18);
        bytes32 primary = _file(media, IDENTITY, PNG);
        bytes32 preview = _file(_data(200, 19), IDENTITY, PNG);
        _workWith(primary, preview);

        string memory j = _out();

        assertEq(_str(j, ".image"), _dataUri(PNG, media));
        assertFalse(_has(j, ".media_url"));
    }

    function test_Preview_Base64StoredPreviewIsInlinedAsText() public {
        bytes32 primary = _file(_data(THRESHOLD + 1, 20), IDENTITY, PNG);
        bytes memory small = _data(900, 21);
        bytes32 preview = _file(bytes(Base64.encode(small)), BASE64, PNG);
        _workWith(primary, preview);

        assertEq(_str(_out(), ".image"), _dataUri(PNG, small));
    }

    function test_Preview_FallsBackToItsLocatorWhenNotOnChain() public {
        bytes32 primary = _file(_data(THRESHOLD + 1, 22), IDENTITY, PNG);
        bytes32 incomplete = _incompleteFile(_data(2 * CHUNK, 23), IDENTITY, PNG);
        bytes32 gzipped = _file(_data(300, 24), GZIP, PNG);
        bytes32 tooBig = _file(_data(renderer.PREVIEW_LIMIT() + 1, 25), IDENTITY, PNG);
        bytes32[3] memory previews = [incomplete, gzipped, tooBig];
        for (uint256 i; i < previews.length; ++i) {
            _workWith(primary, previews[i]);
            records.addLocator(ID, previews[i], Locator(LocatorKind.ARWEAVE, "ar://preview"));
            assertEq(_str(_out(), ".image"), "ar://preview");
        }
    }

    /// @dev A small preview whose chunks are not all in the store is not inlined (reading it
    ///      would revert), and its locator is used instead; with no locator there is no image.
    function test_Preview_ASmallIncompletePreviewIsNotInlined() public {
        bytes32 primary = _file(_data(THRESHOLD + 1, 48), IDENTITY, PNG);
        // One chunk, well under the preview limit, never uploaded.
        bytes32 preview = _incompleteFile(_data(2_000, 49), IDENTITY, PNG);
        assertFalse(store.isComplete(preview));
        _workWith(primary, preview);
        records.addLocator(ID, preview, Locator(LocatorKind.ARWEAVE, "ar://preview"));

        assertEq(_str(_out(), ".image"), "ar://preview");

        _workWith(primary, _incompleteFile(_data(2_001, 50), IDENTITY, PNG));
        assertFalse(_has(_out(), ".image"));

        // The same for base64 text over two chunks, the second one missing.
        bytes32 text = _incompleteFile(bytes(Base64.encode(_data(30_000, 51))), BASE64, PNG);
        assertFalse(store.isComplete(text));
        _workWith(primary, text);
        records.addLocator(ID, text, Locator(LocatorKind.ARWEAVE, "ar://text"));
        assertEq(_str(_out(), ".image"), "ar://text");
    }

    function test_Preview_ThePreviewLimitIsInclusiveAndCountsIdentityEightTimes() public {
        bytes32 primary = _file(_data(THRESHOLD + 1, 26), IDENTITY, PNG);
        uint256 limit = renderer.PREVIEW_LIMIT();
        bytes memory text = _data(limit / 8 * 3, 27); // exactly `limit` base64 characters
        _workWith(primary, _file(bytes(Base64.encode(text)), BASE64, PNG));
        assertEq(_str(_out(), ".image"), _dataUri(PNG, text));

        bytes memory raw = _data(limit / 8, 28);
        _workWith(primary, _file(raw, IDENTITY, PNG));
        assertEq(_str(_out(), ".image"), _dataUri(PNG, raw));

        bytes32 over = _file(_data(limit / 8 + 1, 29), IDENTITY, PNG);
        _workWith(primary, over);
        records.addLocator(ID, over, Locator(LocatorKind.IPFS, "ipfs://over"));
        assertEq(_str(_out(), ".image"), "ipfs://over");
    }

    function test_Preview_OnlyAnImageCanBeAPreview() public {
        bytes32 primary = _file(_data(THRESHOLD + 1, 28), IDENTITY, PNG);
        bytes32 preview = _file(_data(300, 29), IDENTITY, "video/mp4");
        _workWith(primary, preview);
        records.addLocator(ID, primary, Locator(LocatorKind.IPFS, IPFS));
        records.addLocator(ID, preview, Locator(LocatorKind.IPFS, "ipfs://video"));

        // The primary's locator stands in for the image; the video is ignored.
        string memory j = _out();
        assertEq(_str(j, ".image"), IPFS);
        assertFalse(_has(j, ".animation_url"));
    }

    function test_Preview_TheFirstPreviewWins() public {
        bytes32 primary = _file(_data(THRESHOLD + 1, 30), IDENTITY, PNG);
        bytes memory first = _data(100, 31);
        bytes32 a = _file(first, IDENTITY, PNG);
        bytes32 b = _file(_data(100, 32), IDENTITY, PNG);
        _install(primary);
        MediaFile[] memory media = new MediaFile[](3);
        media[0] = MediaFile(primary, _sha(primary), FileRole.PRIMARY);
        media[1] = MediaFile(a, _sha(a), FileRole.PREVIEW);
        media[2] = MediaFile(b, _sha(b), FileRole.PREVIEW);
        records.setMedia(ID, media);

        assertEq(_str(_out(), ".image"), _dataUri(PNG, first));
    }

    function test_Preview_AuxiliaryFilesAreNotRendered() public {
        bytes32 primary = _file(_data(THRESHOLD + 1, 33), IDENTITY, PNG);
        bytes32 aux = _file(_data(100, 34), IDENTITY, PNG);
        _install(primary);
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = MediaFile(primary, _sha(primary), FileRole.PRIMARY);
        media[1] = MediaFile(aux, _sha(aux), FileRole.AUXILIARY);
        records.setMedia(ID, media);

        _noMedia(_out());
    }

    // ---------------------------------------------------------------- not an image

    function test_NonImage_HtmlIsTheAnimationAndThePreviewIsTheImage() public {
        bytes memory html = "<html><body>art</body></html>";
        bytes32 primary = _file(html, IDENTITY, "text/html");
        bytes memory thumb = _data(300, 35);
        bytes32 preview = _file(thumb, IDENTITY, PNG);
        _workWith(primary, preview);

        string memory j = _out();

        assertEq(_str(j, ".animation_url"), _dataUri("text/html", html));
        assertEq(_str(j, ".image"), _dataUri(PNG, thumb));
        assertFalse(_has(j, ".media_url"));
        assertEq(_str(j, ".content_type"), "text/html");
    }

    function test_NonImage_HtmlIsInlinedUntouched() public {
        // A document is served as it is: its own `</script>` and comments must survive.
        bytes memory html = "<script>var a='<!--';</script><!-- note -->";
        _install(_file(html, IDENTITY, "text/html"));

        assertEq(_str(_out(), ".animation_url"), _dataUri("text/html", html));
    }

    function test_NonImage_OverTheThresholdUsesTheLocatorAsAnimation() public {
        bytes32 primary = _file(_data(THRESHOLD + 1, 36), IDENTITY, "video/mp4");
        bytes memory thumb = _data(300, 37);
        bytes32 preview = _file(thumb, IDENTITY, PNG);
        _workWith(primary, preview);
        records.addLocator(ID, primary, Locator(LocatorKind.ARWEAVE, "ar://video"));

        string memory j = _out();

        assertEq(_str(j, ".animation_url"), "ar://video");
        assertEq(_str(j, ".image"), _dataUri(PNG, thumb));
        assertEq(_str(j, ".media_url"), "ar://video");
    }

    function test_NonImage_WithoutAPreviewThereIsNoImage() public {
        bytes32 primary = _file("<html></html>", IDENTITY, "text/html");
        _install(primary);

        string memory j = _out();

        assertTrue(_has(j, ".animation_url"));
        assertFalse(_has(j, ".image"));
    }

    // ---------------------------------------------------------------- fullTokenURI

    function test_Full_InlinesWhatTheCompactFormMustNot() public {
        bytes memory media = _data((THRESHOLD + 5_000) / 4 * 3, 38);
        bytes32 file = _file(bytes(Base64.encode(media)), BASE64, PNG);
        _install(file);
        records.addLocator(ID, file, Locator(LocatorKind.IPFS, IPFS));

        assertEq(_str(_out(), ".image"), IPFS);
        string memory full = _decode(renderer.fullTokenURI(address(stream), ID));
        assertEq(_str(full, ".image"), _dataUri(PNG, media));
        assertFalse(_has(full, ".media_url"));
    }

    function test_Full_RevertsWhenThePrimaryCannotBeInlined() public {
        bytes memory expected =
            abi.encodeWithSelector(Renderer.RendererNotInlineable.selector, address(stream), ID);

        // Over 1 MiB (a manifest alone is enough: the size is checked first).
        bytes32 huge = _declareOnly(renderer.MAX_INLINE_BYTES() + 1, PNG);
        _install(huge);
        vm.expectRevert(expected);
        renderer.fullTokenURI(address(stream), ID);

        // Incomplete in the store.
        _install(_incompleteFile(_data(2 * CHUNK, 39), IDENTITY, PNG));
        vm.expectRevert(expected);
        renderer.fullTokenURI(address(stream), ID);

        // Not served as the media itself.
        _install(_file(_data(300, 40), GZIP, PNG));
        vm.expectRevert(expected);
        renderer.fullTokenURI(address(stream), ID);

        // The work is not on-chain complete.
        bytes32 file = _file(_data(300, 41), IDENTITY, PNG);
        _install(file);
        IWorkRecords.RecordInfo memory info = _info();
        info.onChainComplete = false;
        _setRecordInfo(info);
        vm.expectRevert(expected);
        renderer.fullTokenURI(address(stream), ID);
    }

    function test_Full_TheOneMebibyteLimitIsInclusive() public {
        // A base64 file of exactly 1 MiB stored bytes (768 KiB of media) is the largest.
        bytes memory media = _data(786_432, 42);
        bytes32 file = _file(bytes(Base64.encode(media)), BASE64, PNG);
        _install(file);

        string memory full = _strip(renderer.fullTokenURI(address(stream), ID));
        assertEq(_str(full, ".image"), _dataUri(PNG, media));
    }

    function _declareOnly(uint256 length, string memory mime) internal returns (bytes32 fileId) {
        uint256 count = (length + CHUNK - 1) / CHUNK;
        bytes32[] memory hashes = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            hashes[i] = keccak256(abi.encode("missing", i));
        }
        fileId = store.registerManifest(hashes, length, IDENTITY, mime, DIGEST);
    }

    // ---------------------------------------------------------------- the HTML page of a script

    /// @dev `window.works` is set in a script of its own, ahead of the artist's (decision L3).
    bytes internal constant HEAD_MARK =
        "<script>window.works={v:1,tokenId:7,seed:null};</script><script>";
    bytes internal constant TAIL = "</script></body></html>";

    function _page() internal view returns (bytes memory) {
        string memory uri = _str(_out(), ".animation_url");
        bytes memory prefix = "data:text/html;base64,";
        bytes memory b = bytes(uri);
        for (uint256 i; i < prefix.length; ++i) {
            assertEq(b[i], prefix[i]);
        }
        bytes memory encoded = new bytes(b.length - prefix.length);
        for (uint256 i; i < encoded.length; ++i) {
            encoded[i] = b[prefix.length + i];
        }
        return Base64.decode(string(encoded));
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool same = true;
            for (uint256 k; k < needle.length && same; ++k) {
                same = hay[i + k] == needle[k];
            }
            if (same) return true;
        }
        return false;
    }

    function _ends(bytes memory hay, bytes memory suffix) internal pure returns (bool) {
        if (suffix.length > hay.length) return false;
        for (uint256 i; i < suffix.length; ++i) {
            if (hay[hay.length - suffix.length + i] != suffix[i]) return false;
        }
        return true;
    }

    function test_Script_IsWrappedInAPageThatSetsWindowWorks() public {
        bytes memory js = "document.body.append('hi');";
        _install(_file(js, IDENTITY, "text/javascript"));

        bytes memory page = _page();

        assertTrue(_contains(page, bytes.concat(HEAD_MARK, js, TAIL)));
        assertTrue(_contains(page, "<!doctype html><html lang=\"en\">"));
        assertTrue(_contains(page, 'charset="utf-8"'));
        assertTrue(_ends(page, TAIL));
        assertEq(_str(_out(), ".content_type"), "text/javascript");
        assertFalse(_has(_out(), ".image"));
    }

    function test_Script_ApplicationJavascriptIsAlsoAScript() public {
        bytes memory js = "var x = 1;";
        _install(_file(js, IDENTITY, "application/javascript"));

        assertTrue(_contains(_page(), bytes.concat(HEAD_MARK, js, TAIL)));
    }

    function test_Script_NeutralizesScriptEndAndCommentOpen() public {
        bytes memory js =
            "var a='</script><img>';var b='</SCRIPT';var c='<!--<script>';/*</Script >*/<!--";
        _install(_file(js, IDENTITY, "text/javascript"));

        bytes memory page = _page();

        // The renderer's own closing tag is the only `</script` left, and no `<!--` remains.
        assertFalse(_contains(page, "<!--"), "comment open");
        assertTrue(_contains(page, "var a='<\\/script><img>';"), "end tag");
        assertTrue(_contains(page, "var b='<\\/SCRIPT';"), "upper case");
        assertTrue(_contains(page, "var c='<\\!--<script>';"), "comment");
        assertTrue(_contains(page, "/*<\\/Script >*/<\\!--"), "comment and end tag");
        assertTrue(_ends(page, TAIL));
        // Two: the page's own closing tags, one for `window.works` and one for the artist's script.
        assertEq(_countOf(page, "</script"), 2, "only the page's own closing tags");
    }

    function _countOf(bytes memory hay, bytes memory needle) internal pure returns (uint256 n) {
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool same = true;
            for (uint256 k; k < needle.length && same; ++k) {
                same = _lower(hay[i + k]) == _lower(needle[k]);
            }
            if (same) ++n;
        }
    }

    function _lower(bytes1 c) internal pure returns (bytes1) {
        return c >= "A" && c <= "Z" ? bytes1(uint8(c) + 32) : c;
    }

    function test_Script_TheSeedIsInjectedWhenDelivered() public {
        bytes memory js = "go();";
        bytes32 file = _file(js, IDENTITY, "text/javascript");
        _install(file);
        IStream.WorkCore memory core = _core();
        core.seedPolicy = SeedPolicy.ARTIST;
        stream.setWork(ID, core);
        records.setSeed(ID, SeedPolicy.ARTIST, bytes32(uint256(0xfeed)));

        string memory seed = vm.toString(bytes32(uint256(0xfeed)));
        assertTrue(
            _contains(
                _page(),
                bytes(
                    string.concat(
                        '<script>window.works={v:1,tokenId:7,seed:"',
                        seed,
                        '"};</script><script>go();'
                    )
                )
            )
        );

        // No seed at all is null.
        core.seedPolicy = SeedPolicy.NONE;
        stream.setWork(ID, core);
        assertTrue(
            _contains(_page(), "window.works={v:1,tokenId:7,seed:null};</script><script>go();")
        );
    }

    function test_Script_NotInlinedUnlessIdentityStoredUtf8AndSmall() public {
        bytes memory js = "run();";
        // Base64-stored and gzipped scripts cannot be placed in the page.
        bytes32[3] memory files = [
            _file(bytes(Base64.encode(js)), BASE64, "text/javascript"),
            _file(js, GZIP, "text/javascript"),
            _file(bytes(Base64.encode(js)), GZIP_BASE64, "text/javascript")
        ];
        // Not UTF-8, and over the script limit.
        bytes32 notUtf8 = _file(hex"7661722061203d202722c0af27", IDENTITY, "text/javascript");
        bytes32 big = _file(_scriptOf(renderer.SCRIPT_LIMIT() + 1), IDENTITY, "text/javascript");
        for (uint256 i; i < 5; ++i) {
            bytes32 f = i < 3 ? files[i] : (i == 3 ? notUtf8 : big);
            _install(f);
            records.addLocator(ID, f, Locator(LocatorKind.IPFS, IPFS));
            string memory j = _out();
            assertEq(_str(j, ".animation_url"), IPFS, "falls back to the locator");
        }

        // The limit itself is inlined.
        _install(_file(_scriptOf(renderer.SCRIPT_LIMIT()), IDENTITY, "text/javascript"));
        assertTrue(_ends(_page(), TAIL));
    }

    function _scriptOf(uint256 length) internal pure returns (bytes memory js) {
        js = new bytes(length);
        for (uint256 i; i < length; ++i) {
            js[i] = i % 64 == 63 ? bytes1("\n") : bytes1("x");
        }
    }

    function test_Script_FullFormRevertsForAScriptItCannotWrap() public {
        _install(_file(_data(300, 43), GZIP, "text/javascript"));
        vm.expectRevert(
            abi.encodeWithSelector(Renderer.RendererNotInlineable.selector, address(stream), ID)
        );
        renderer.fullTokenURI(address(stream), ID);
    }

    // ---------------------------------------------------------------- Base64 attestation (H1)

    /// @dev Base64 text with a JSON break-out after it. The upload and the SHA-256 of what a lenient
    ///      decoder reads (it drops the rest) are fine; only a strict reader sees the problem.
    function _tampered(bytes memory media) internal returns (bytes32) {
        return
            _file(
                bytes.concat(bytes(Base64.encode(media)), '","name":"Forged","xy":"'), BASE64, PNG
            );
    }

    function test_Base64_AFileThatIsNotStrictBase64IsNeverCopied() public {
        bytes32 file = _tampered(_data(100, 52));
        assertFalse(_attested(file));
        _install(file);
        records.addLocator(ID, file, Locator(LocatorKind.IPFS, IPFS));

        string memory j = _out();

        assertEq(_str(j, ".name"), "Title", "no second name");
        assertEq(_str(j, ".image"), IPFS);
        assertFalse(_has(j, ".xy"));
    }

    function test_Base64_AHashOrPercentInTheTextIsNeverCopied() public {
        string[3] memory tails = ["#AAA", "%41", "\\n"];
        for (uint256 i; i < tails.length; ++i) {
            bytes32 file = _file(
                bytes.concat(bytes(Base64.encode(_data(60, 53))), bytes(tails[i])), BASE64, PNG
            );
            assertFalse(_attested(file));
            _install(file);
            records.addLocator(ID, file, Locator(LocatorKind.IPFS, IPFS));
            // `_decode` fails on a raw `#` or a stray `%`.
            assertEq(_str(_out(), ".image"), IPFS);
        }
    }

    function test_Base64_AValidFileIsCopiedOnlyOnceAttested() public {
        bytes memory media = _data(300, 54);
        bytes32 file = _unattested(bytes(Base64.encode(media)), BASE64, PNG);
        _install(file);
        records.addLocator(ID, file, Locator(LocatorKind.IPFS, IPFS));
        assertEq(_str(_out(), ".image"), IPFS, "not attested yet");

        _attest(file); // permissionless, once
        assertTrue(_attested(file));
        assertEq(_str(_out(), ".image"), _dataUri(PNG, media));
    }

    function test_Base64_AnUnattestedPreviewIsNotInlined() public {
        bytes32 primary = _file(_data(THRESHOLD + 1, 55), IDENTITY, PNG);
        bytes32 preview = _tampered(_data(100, 56));
        _workWith(primary, preview);
        records.addLocator(ID, primary, Locator(LocatorKind.IPFS, IPFS));
        records.addLocator(ID, preview, Locator(LocatorKind.ARWEAVE, "ar://preview"));

        string memory j = _out();

        assertEq(_str(j, ".name"), "Title");
        assertEq(_str(j, ".image"), "ar://preview");
        assertEq(_str(j, ".media_url"), IPFS);
    }

    function test_Base64_FullFormRevertsForAnUnattestedPrimary() public {
        _install(_tampered(_data(100, 57)));
        vm.expectRevert(
            abi.encodeWithSelector(Renderer.RendererNotInlineable.selector, address(stream), ID)
        );
        renderer.fullTokenURI(address(stream), ID);
    }

    function test_Base64_AnAttestationReadThatFailsFailsClosed() public {
        // A store that is not the attesting one cannot answer.
        Renderer noAttest = new Renderer(
            IContentStore(address(new PlainStore(store))),
            IStatementLog(address(disputeLog)),
            THRESHOLD
        );
        _install(_file(bytes(Base64.encode(_data(100, 58))), BASE64, PNG));
        vm.expectRevert(
            abi.encodeWithSelector(
                Renderer.RendererReadFailed.selector,
                address(noAttest.contentStore()),
                IBase64Attested.isBase64Attested.selector
            )
        );
        noAttest.tokenURI(address(stream), ID);
    }

    // ---------------------------------------------------------------- a script with dependencies (L5)

    function test_Script_ADeclaredDependencyIsServedByLocatorNotWrapped() public {
        bytes32 file = _file("p5.setup();", IDENTITY, "text/javascript");
        _installRaw(
            '{"dependencies":[{"name":"p5","version":"1.9.0"}],"name":"N"}', _media(file, 0)
        );
        records.addLocator(ID, file, Locator(LocatorKind.IPFS, IPFS));

        assertEq(_str(_out(), ".animation_url"), IPFS);

        vm.expectRevert(
            abi.encodeWithSelector(Renderer.RendererNotInlineable.selector, address(stream), ID)
        );
        renderer.fullTokenURI(address(stream), ID);
    }

    function test_Script_AnEmptyDependencyListIsWrapped() public {
        bytes32 file = _file("go();", IDENTITY, "text/javascript");
        _installRaw('{"dependencies":[],"name":"N"}', _media(file, 0));
        assertTrue(_ends(_page(), TAIL));
        _installRaw('{"name":"N"}', _media(file, 0));
        assertTrue(_ends(_page(), TAIL));
    }
}

/// @dev A content store that answers everything but the attestation.
contract PlainStore {
    IContentStore internal immutable inner;

    constructor(IContentStore inner_) {
        inner = inner_;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = address(inner).staticcall(data);
        if (!ok || bytes4(data) == IBase64Attested.isBase64Attested.selector) {
            assembly {
                revert(0, 0)
            }
        }
        return ret;
    }
}
