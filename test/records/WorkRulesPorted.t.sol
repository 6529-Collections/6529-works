// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IWorkPowers, WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { IWorkRules } from "src/interfaces/core/IWorkRules.sol";
import { FileRole, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { WorkRules } from "src/records/WorkRules.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";
import { CodeRenderer, RulesChunkStore, SigningAccounts } from "../mocks/records/RulesMocks.sol";
import { RulesFixture } from "./RulesFixture.sol";

/// @notice A chunk store that serves a chunk wrongly: with its first byte flipped, one byte
///         too long, or by reverting.
contract WrongChunkStore {
    enum Mode {
        FLIP,
        LONGER,
        REVERT
    }

    Mode public mode;
    mapping(bytes32 => bytes) internal _data;

    function put(bytes calldata data) external {
        _data[keccak256(data)] = data;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function chunkData(bytes32 chunkHash) external view returns (bytes memory d) {
        d = _data[chunkHash];
        if (mode == Mode.REVERT) revert("refused");
        if (mode == Mode.FLIP) d[0] = bytes1(uint8(d[0]) ^ 0xff);
        if (mode == Mode.LONGER) d = bytes.concat(d, "x");
    }
}

/// @notice `WorkRules` behaviour carried over from the `WorkRecords` and `WorkPowers` suites
///         that the first port left out: approved records the rules refuse, refusals on either
///         side of each compared value, renunciations by every wallet and their locks binding a
///         no-op, the signed payloads' goldens, and the added stores' checks.
contract WorkRulesPortedTest is RulesFixture {
    address internal s;
    uint64 internal deadline;

    function setUp() public override {
        super.setUp();
        s = address(stream);
        deadline = uint64(block.timestamp + 1 days);
    }

    // ------------------------------------------------------------------ helpers

    function _open(uint256 salt) internal returns (uint256 id, PackageItem memory item) {
        (id, item,) = _work(stream, salt);
    }

    function _withLicense(uint256 salt, License memory license)
        internal
        returns (uint256 id, PackageItem memory item)
    {
        MediaFile[] memory media = _single(salt);
        item = _item(salt, media);
        item.license = license;
        id = _mintItem(stream, item);
        facts.open(s, id, item, media);
    }

    function _relicenseHash(uint256 id, License memory next, bytes32 state, uint64 dl)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                rules.RELICENSE_TYPEHASH(),
                s,
                id,
                WorksHashing.licenseKey(next.spdxId),
                next.textFileId,
                state,
                dl
            )
        );
    }

    function _rateHash(uint256 id, uint24 rate, bytes32 state, uint64 dl)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(rules.ROYALTY_RATE_TYPEHASH(), s, id, rate, state, dl));
    }

    function _renounceHash(uint256 id, uint16 powers, bytes32 state, uint64 dl)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(rules.RENOUNCE_POWERS_TYPEHASH(), s, id, powers, state, dl));
    }

    function _relicense(uint256 id, PackageItem memory item, License memory next) internal {
        bytes32 state = _state(id);
        rules.relicense(
            s, id, next, item, state, deadline, _both(_relicenseHash(id, next, state, deadline))
        );
    }

    /// @dev An external hop so `vm.expectRevert` sees exactly the relicense call.
    function relicenseAs(uint256 id, PackageItem memory item, License memory next) external {
        _relicense(id, item, next);
    }

    function _setRate(uint256 id, PackageItem memory item, uint24 rate) internal {
        bytes32 state = _state(id);
        rules.setRoyaltyRate(
            s, id, rate, item, state, deadline, _both(_rateHash(id, rate, state, deadline))
        );
    }

    function _renounceBy(uint256 key, uint256 id, uint16 powers) internal {
        bytes32 state = _state(id);
        rules.renounce(
            s, id, powers, state, deadline, _sign(key, _renounceHash(id, powers, state, deadline))
        );
    }

    function _artistFinalize(uint256 id) internal {
        bytes32 state = _state(id);
        vm.prank(artist);
        rules.finalize(s, id, state);
    }

    /// @dev Registers a record manifest over `chunks` with `encoding`, uploading them if asked.
    function _recordFile(bytes[] memory chunks, IContentStore.Encoding encoding, bool upload)
        internal
        returns (bytes32)
    {
        bytes32[] memory hashes = new bytes32[](chunks.length);
        uint256 length;
        for (uint256 i; i < chunks.length; ++i) {
            hashes[i] = keccak256(chunks[i]);
            length += chunks[i].length;
            if (upload) store.writeChunk(chunks[i]);
        }
        return store.registerManifest(
            hashes, length, uint8(encoding), "application/json", sha256(abi.encode(hashes))
        );
    }

    function _one(bytes memory data) internal pure returns (bytes[] memory chunks) {
        chunks = new bytes[](1);
        chunks[0] = data;
    }

    // ------------------------------------------------------- approved bad records

    /// @dev `bad` is refused by `setRecord` with `setError`; as an approved record it still
    ///      opens, the artist's finalize refuses it with `finalizeError`, and the artist replaces
    ///      it and finalizes.
    function _expectBadRecord(
        uint256 salt,
        bytes32 bad,
        bytes memory setError,
        bytes memory finalizeError
    ) internal {
        (uint256 id,) = _open(salt);
        bytes32 state = _state(id);
        vm.prank(artist);
        vm.expectRevert(setError);
        rules.setRecord(s, id, bad, state);

        MediaFile[] memory media = _single(salt + 1000);
        PackageItem memory item = _item(salt + 1000, media);
        item.recordFileId = bad;
        uint256 approved = _mintItem(stream, item);
        facts.open(s, approved, item, media);
        assertEq(facts.factsOf(s, approved).recordFileId, bad);
        state = _state(approved);
        vm.prank(artist);
        vm.expectRevert(finalizeError);
        rules.finalize(s, approved, state);
        bytes32 good = _record(salt + 2000);
        vm.prank(artist);
        rules.setRecord(s, approved, good, state);
        _artistFinalize(approved);
        assertEq(facts.factsOf(s, approved).recordFileId, good);
    }

    /// @dev The structural record bound, at every set and at finalize: one complete chunk
    ///      stored as it is. An approved record that breaks it (unregistered, not stored yet,
    ///      gzip, base64, two chunks) opens, and the artist fixes it before finalize.
    function test_SetRecord_ApprovedRecordsTheRulesRefuseOpenAndAreFixable() public {
        bytes32 unknown = keccak256("no such record");
        bytes memory unknownError =
            abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, unknown);
        _expectBadRecord(1, unknown, unknownError, unknownError);
        bytes memory json = '{"name":"r"}';
        bytes32[4] memory bad = [
            _recordFile(_one('{"name":"pending"}'), IContentStore.Encoding.Identity, false),
            _recordFile(_one(json), IContentStore.Encoding.Gzip, true),
            _recordFile(_one(bytes("eyJuIjoxfQ==")), IContentStore.Encoding.Base64, true),
            bytes32(0)
        ];
        bytes[] memory two = new bytes[](2);
        two[0] = new bytes(store.CHUNK_SIZE());
        two[1] = "}";
        bad[3] = _recordFile(two, IContentStore.Encoding.Identity, true);
        for (uint256 i; i < bad.length; ++i) {
            uint256 salt = 10 + i;
            uint256 nextId = stream.totalMinted() + 2;
            _expectBadRecord(
                salt,
                bad[i],
                abi.encodeWithSelector(WorkRules.InvalidRecordFile.selector, bad[i]),
                abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, s, nextId)
            );
        }
    }

    /// @dev A full chunk is a record, and its bytes are not parsed here (the renderer falls back
    ///      for an invalid record): a record of exactly one chunk and one that is not JSON set
    ///      and finalize.
    function test_SetRecord_AFullChunkOfAnyBytesSetsAndFinalizes() public {
        (uint256 id,) = _open(1);
        bytes memory full = new bytes(store.CHUNK_SIZE());
        full[0] = "{";
        bytes32 fullId = _recordFile(_one(full), IContentStore.Encoding.Identity, true);
        bytes32 state = _state(id);
        vm.prank(artist);
        rules.setRecord(s, id, fullId, state);
        assertEq(facts.factsOf(s, id).recordFileId, fullId);
        bytes32 notJson = _recordFile(_one("not json"), IContentStore.Encoding.Identity, true);
        state = _state(id);
        vm.prank(artist);
        rules.setRecord(s, id, notJson, state);
        _artistFinalize(id);
        assertEq(facts.factsOf(s, id).recordFileId, notJson);
    }

    // ----------------------------------------------------------------- relicense

    /// @dev A license whose approved text is not registered opens; finalize refuses it until the
    ///      parties and the network relicense to a stored text.
    function test_Relicense_RepairsAnUnregisteredApprovedText() public {
        bytes32 typo = keccak256("typo in the text file id");
        (uint256 id, PackageItem memory item) = _withLicense(1, License("CC-BY-4.0", typo));
        bytes32 state = _state(id);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, typo));
        rules.finalize(s, id, state);
        _relicense(id, item, License("CC-BY-4.0", mitText));
        _artistFinalize(id);
        assertEq(facts.factsOf(s, id).licenseTextFileId, mitText);
    }

    /// @dev Consents are checked against the work's own item: another item is refused whichever
    ///      way its hash sorts against the minted one's, even with every party's consent.
    function test_Relicense_RefusesAnotherItemEitherWay() public {
        (uint256 id, PackageItem memory item) = _withLicense(1, License("MIT", mitText));
        bytes32 minted = WorksHashing.itemHash(item);
        License memory next = License("CC-BY-4.0", mitText);
        bytes32 state = _state(id);
        bytes[] memory sigs = _both(_relicenseHash(id, next, state, deadline));
        bool below;
        bool above;
        for (uint256 i = 1; !(below && above); ++i) {
            item.recordFileId = keccak256(abi.encode("another record", i));
            bool lower = WorksHashing.itemHash(item) < minted;
            if (lower ? below : above) continue;
            if (lower) below = true;
            else above = true;
            vm.expectRevert(abi.encodeWithSelector(IWorkRules.InvalidConsent.selector, s, id));
            rules.relicense(s, id, next, item, state, deadline, sigs);
        }
    }

    /// @dev Leaving CC0 is refused whichever way the next key sorts against CC0's ("mit" below,
    ///      "unlicense" above), with every consent; a license keyed above CC0 is not CC0 and may
    ///      be left; another identifier with the same text is a change, either way.
    function test_Relicense_KeysOnEitherSideOfCc0() public {
        (uint256 cc0Work, PackageItem memory cc0Item) = _open(1);
        string[2] memory nexts = ["mit", "unlicense"];
        for (uint256 i; i < nexts.length; ++i) {
            vm.expectRevert(IWorkFacts.InvalidLicense.selector);
            this.relicenseAs(cc0Work, cc0Item, License(nexts[i], mitText));
        }
        (uint256 above, PackageItem memory aboveItem) =
            _withLicense(2, License("unlicense", mitText));
        _relicense(above, aboveItem, License("mit", mitText));
        assertEq(facts.factsOf(s, above).licenseId, "mit");

        (uint256 id, PackageItem memory item) = _withLicense(3, License("cc-by-4.0", mitText));
        string[2] memory same = ["gpl-3.0-only", "mit"];
        for (uint256 i; i < same.length; ++i) {
            _relicense(id, item, License(same[i], mitText));
            assertEq(facts.factsOf(s, id).licenseId, same[i]);
            assertEq(rules.versionOf(s, id), i + 1);
        }
    }

    // ------------------------------------------------------------ royalty rate

    function test_SetRoyaltyRate_AConsentForAnotherRateIsRefused() public {
        (uint256 id, PackageItem memory item) = _open(1);
        bytes32 state = _state(id);
        bytes[] memory sigs = _both(_rateHash(id, 1, state, deadline));
        vm.expectRevert(abi.encodeWithSelector(SigningAccounts.BadSignature.selector, artist));
        rules.setRoyaltyRate(s, id, 2, item, state, deadline, sigs);
        assertEq(stream.workOf(id).royaltyRate, 6529);
    }

    /// @dev A rate change moves only its own work.
    function test_SetRoyaltyRate_OneWorksRateNeverMovesAnother() public {
        (uint256 first, PackageItem memory firstItem) = _open(1);
        (uint256 second, PackageItem memory secondItem) = _open(2);
        _setRate(first, firstItem, 5_000);
        assertEq(stream.workOf(second).royaltyRate, 6529);
        _setRate(second, secondItem, 9_000);
        assertEq(stream.workOf(first).royaltyRate, 5_000);
        assertEq(rules.versionOf(s, second), 1);
    }

    // ------------------------------------------------------------------ repin

    function test_RepinRenderer_RefusesAStaleState() public {
        (uint256 id,) = _open(1);
        _artistFinalize(id);
        bytes32 state = _state(id);
        address next = address(new CodeRenderer(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                IWorkRules.StateHashMismatch.selector, bytes32(uint256(1)), state
            )
        );
        rules.repinRenderer(s, id, next, bytes32(uint256(1)));
        assertEq(stream.rendererOf(id), address(renderer));
    }

    // ---------------------------------------------------------------- renounce

    /// @dev Any wallet of the lead artist's account signs a renunciation; a wallet that left it
    ///      cannot.
    function test_Renounce_ASecondWalletSignsAndAWalletThatLeftCannot() public {
        uint256 secondKey = 0x5EC0;
        address second = vm.addr(secondKey);
        signers.setWallet(uint160(artist), second, true);
        (uint256 id,) = _open(1);
        _renounceBy(secondKey, id, WorkPowers.RELICENSE);
        assertEq(rules.renouncedPowers(s, id), WorkPowers.RELICENSE);
        signers.setWallet(uint160(artist), second, false);
        bytes32 state = _state(id);
        bytes memory sig =
            _sign(secondKey, _renounceHash(id, WorkPowers.ROYALTY_RATE, state, deadline));
        vm.expectRevert(
            abi.encodeWithSelector(SigningAccounts.NotAWallet.selector, uint160(artist), second)
        );
        rules.renounce(s, id, WorkPowers.ROYALTY_RATE, state, deadline, sig);
    }

    function test_Renounce_NeedsAnOpenRecord() public {
        uint256 id = _mintItem(stream, _item(1, _single(1)));
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RecordNotOpen.selector, s, id));
        rules.renounce(s, id, WorkPowers.ROYALTY_RATE, 0, deadline, "");
    }

    /// @dev A renunciation moves the version, so consents collected before it lapse.
    function test_Renounce_PendingConsentsLapse() public {
        (uint256 id, PackageItem memory item) = _open(1);
        bytes32 s0 = _state(id);
        bytes[] memory sigs = _both(_rateHash(id, 5_000, s0, deadline));
        _renounceBy(artistKey, id, WorkPowers.RELICENSE);
        bytes32 s1 = _state(id);
        vm.expectRevert(abi.encodeWithSelector(IWorkRules.StateHashMismatch.selector, s0, s1));
        rules.setRoyaltyRate(s, id, 5_000, item, s0, deadline, sigs);
    }

    /// @dev Once a power is renounced, every call of it reverts, the one that would change
    ///      nothing included: the current rate, the current license, the current renderer.
    function test_Renounce_EveryCallOfARenouncedPowerRevertsANoOpIncluded() public {
        (uint256 id, PackageItem memory item) = _withLicense(1, License("MIT", mitText));
        _artistFinalize(id);
        _renounceBy(artistKey, id, WorkPowers.ALL);
        uint24[2] memory rates = [uint24(6529), 0];
        for (uint256 i; i < rates.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IWorkPowers.PowerRenounced.selector, s, id, WorkPowers.ROYALTY_RATE
                )
            );
            rules.setRoyaltyRate(s, id, rates[i], item, 0, 0, new bytes[](0));
        }
        vm.expectRevert(
            abi.encodeWithSelector(IWorkPowers.PowerRenounced.selector, s, id, WorkPowers.RELICENSE)
        );
        rules.relicense(s, id, License("MIT", mitText), item, 0, 0, new bytes[](0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IWorkPowers.PowerRenounced.selector, s, id, WorkPowers.RENDERER_REPIN
            )
        );
        rules.repinRenderer(s, id, address(renderer), 0);
    }

    /// @dev The deadline is inclusive: refused one second after it, applied at it.
    function test_Renounce_TheDeadlineIsInclusive() public {
        (uint256 id,) = _open(1);
        bytes32 state = _state(id);
        uint64 dl = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(artistKey, _renounceHash(id, WorkPowers.ROYALTY_RATE, state, dl));
        vm.warp(dl + 1);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.SignatureExpired.selector, dl));
        rules.renounce(s, id, WorkPowers.ROYALTY_RATE, state, dl, sig);
        vm.warp(dl);
        rules.renounce(s, id, WorkPowers.ROYALTY_RATE, state, dl, sig);
        assertEq(rules.renouncedPowers(s, id), WorkPowers.ROYALTY_RATE);
    }

    /// @dev No license can be fixed for good that finalize could never accept: the RELICENSE
    ///      power cannot be renounced while the identifier is not a valid SPDX identifier, the
    ///      text has more than 16 chunks or is not registered (only a relicense could repair
    ///      it); other powers still renounce. A valid custom identifier with a registered text
    ///      whose chunks are still missing renounces, and finalizes once they are stored.
    function test_Renounce_TheLicensePowerOnlyForALicenseFinalizeCouldAccept() public {
        string[3] memory badIds = [string(new bytes(65)), "MIT License", string(hex"4d4954c3a9")];
        for (uint256 i; i < badIds.length; ++i) {
            (uint256 id,) = _withLicense(100 + i, License(badIds[i], mitText));
            assertEq(facts.factsOf(s, id).licenseId, badIds[i], "stored as approved");
            bytes32 state = _state(id);
            bytes memory sig =
                _sign(artistKey, _renounceHash(id, WorkPowers.RELICENSE, state, deadline));
            vm.expectRevert(IWorkFacts.InvalidLicense.selector);
            rules.renounce(s, id, WorkPowers.RELICENSE, state, deadline, sig);
            _renounceBy(artistKey, id, WorkPowers.ROYALTY_RATE);
            assertEq(rules.renouncedPowers(s, id), WorkPowers.ROYALTY_RATE);
        }
        // A registered text of 17 chunks, none stored.
        bytes32[] memory hashes = new bytes32[](17);
        for (uint256 i; i < 17; ++i) {
            hashes[i] = keccak256(abi.encode("chunk", i));
        }
        bytes32 long = store.registerManifest(
            hashes, 16 * store.CHUNK_SIZE() + 1, 0, "text/plain", keccak256("long")
        );
        (uint256 tooLong,) = _withLicense(200, License("LicenseRef-Long", long));
        bytes32 st = _state(tooLong);
        bytes memory longSig =
            _sign(artistKey, _renounceHash(tooLong, WorkPowers.RELICENSE, st, deadline));
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        rules.renounce(s, tooLong, WorkPowers.RELICENSE, st, deadline, longSig);
        bytes32 unknown = keccak256("unregistered text");
        (uint256 unregistered,) = _withLicense(201, License("LicenseRef-Unknown", unknown));
        st = _state(unregistered);
        bytes memory unknownSig =
            _sign(artistKey, _renounceHash(unregistered, WorkPowers.RELICENSE, st, deadline));
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, unknown));
        rules.renounce(s, unregistered, WorkPowers.RELICENSE, st, deadline, unknownSig);

        bytes memory terms = "the terms";
        bytes32 later = _file(terms, "text/plain", false);
        (uint256 good,) = _withLicense(202, License("LicenseRef-Terms", later));
        _renounceBy(artistKey, good, WorkPowers.RELICENSE);
        assertTrue(facts.factsOf(s, good).licenseLocked);
        bytes32 state2 = _state(good);
        vm.prank(artist);
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        rules.finalize(s, good, state2);
        store.writeChunk(terms);
        vm.prank(artist);
        rules.finalize(s, good, state2);
        assertTrue(facts.factsOf(s, good).finalized);
    }

    // ----------------------------------------------------------------- goldens

    /// @dev Golden values, computed independently with `cast keccak` over each type string, and
    ///      the power bits. A failure means a signed payload changed shape.
    function test_Typehashes_Golden() public view {
        assertEq(
            rules.RELICENSE_TYPEHASH(),
            0x931a811e6b684375c33ff9dd19f465f9b0029f067114a85c36e70a2515a9214a
        );
        assertEq(
            rules.ROYALTY_RATE_TYPEHASH(),
            0xce5d0f43a86dedd7a3ef97fdc2aa082a7da4503c38bcc5d69a37918796836df2
        );
        assertEq(
            rules.RENOUNCE_POWERS_TYPEHASH(),
            0x51c2848ada45e48191946c63376efc2c3cbcc5c0465555da04b4041af793cb8c
        );
        assertEq(WorkPowers.ROYALTY_RATE, 1);
        assertEq(WorkPowers.RELICENSE, 2);
        assertEq(WorkPowers.RENDERER_REPIN, 4);
        assertEq(WorkPowers.ALL, 7);
        assertEq(rules.NAME(), "6529 Works Rules");
        assertEq(
            rules.domainSeparator(),
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH,
                    keccak256("6529 Works Rules"),
                    keccak256("1"),
                    block.chainid,
                    address(rules)
                )
            )
        );
    }

    /// @dev The state hash every consent binds, rebuilt from its documented fields (the domain
    ///      is `cast keccak "6529WORKS_WORK_STATE_V2"`).
    function test_StateHash_Golden() public {
        (uint256 id, PackageItem memory item) = _open(1);
        bytes32 expected = keccak256(
            abi.encode(
                bytes32(0x7b6fed9dbcdcee8599bd9a0623d29046d480130c7b1612e60ae146a670a5183b),
                address(rules),
                s,
                id,
                uint32(0),
                item.recordFileId,
                WorksHashing.CC0_LICENSE_KEY,
                cc0Text,
                uint24(6529),
                address(renderer)
            )
        );
        assertEq(_state(id), expected);
    }

    /// @dev Locators, preferences, dead marks and the choice of store change nothing a consent
    ///      binds.
    function test_StateHash_IgnoresDeliveryAndStoreChoices() public {
        (uint256 id,, MediaFile[] memory media) = _work(stream, 1);
        bytes32 file = media[0].fileId;
        bytes32 state = _state(id);
        delivery.addLocator(s, id, file, CA.ar("a0"));
        delivery.setPreferredKind(s, LocatorKind.IPFS);
        delivery.setFilePreference(s, id, file, 0);
        delivery.markLocatorDead(s, id, file, 0);
        rules.setFileStore(s, id, file, 0);
        assertEq(_state(id), state);
    }

    // ------------------------------------------------------------------ stores

    function _twoFileWork(uint256 salt)
        internal
        returns (uint256 id, bytes32 file, RulesChunkStore cs)
    {
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(salt, FileRole.PRIMARY, true);
        media[1] = _mediaFile(salt + 1, FileRole.PREVIEW, false);
        PackageItem memory item = _item(salt, media);
        id = _mintItem(stream, item);
        facts.open(s, id, item, media);
        file = media[1].fileId;
        cs = new RulesChunkStore();
        cs.put(_mediaBytes(salt + 1));
        rules.addStore(address(cs), address(cs).codehash);
    }

    /// @dev Any wallet of the artist's account chooses a file's store; a wallet that left it is
    ///      a stranger (the storage operator's role is asked, and refuses).
    function test_FileStore_ASecondWalletChoosesAndAWalletThatLeftCannot() public {
        (uint256 id, bytes32 file,) = _twoFileWork(1);
        address second = makeAddr("second wallet");
        signers.setWallet(uint160(artist), second, true);
        vm.prank(second);
        rules.setFileStore(s, id, file, 1);
        assertEq(rules.fileStore(s, id, file), 1);
        signers.setWallet(uint160(artist), second, false);
        vm.prank(second);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, second)
        );
        rules.setFileStore(s, id, file, 0);
    }

    /// @dev Retiring a store keeps the choice files already made; no file can choose it again.
    function test_FileStore_ARetiredStoreKeepsWhatFilesChose() public {
        (uint256 id, bytes32 file,) = _twoFileWork(1);
        vm.prank(artist);
        rules.setFileStore(s, id, file, 1);
        rules.retireStore(1);
        assertEq(rules.fileStore(s, id, file), 1);
        assertTrue(rules.store(1).retired);
        rules.setFileStore(s, id, file, 0);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(WorkRules.UnknownStore.selector, 1));
        rules.setFileStore(s, id, file, 1);
    }

    /// @dev Bytes that do not hash to the manifest's chunk, bytes of another length, and a
    ///      store's refusal all count as a chunk the store does not serve.
    function test_FileStore_TheStoresBytesAreVerified() public {
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(1, FileRole.PRIMARY, true);
        media[1] = _mediaFile(2, FileRole.PREVIEW, false);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(stream, item);
        facts.open(s, id, item, media);
        WrongChunkStore wrong = new WrongChunkStore();
        wrong.put(_mediaBytes(2));
        WrongChunkStore.Mode[3] memory modes =
            [WrongChunkStore.Mode.FLIP, WrongChunkStore.Mode.LONGER, WrongChunkStore.Mode.REVERT];
        for (uint256 i; i < 3; ++i) {
            wrong.setMode(modes[i]);
            rules.addStore(address(wrong), address(wrong).codehash);
            vm.prank(artist);
            vm.expectRevert(
                abi.encodeWithSelector(WorkRules.FileNotServed.selector, media[1].fileId, i + 1)
            );
            rules.setFileStore(s, id, media[1].fileId, i + 1);
        }
    }

    /// @dev A store whose code changed since it was added cannot be chosen, whichever way its
    ///      code hash moved against the pin.
    function test_FileStore_AStoreWhoseCodeChangedIsRefusedEitherWay() public {
        (uint256 id, bytes32 file, RulesChunkStore cs) = _twoFileWork(1);
        bytes memory code = address(cs).code;
        bytes32 pin = address(cs).codehash;
        bool below;
        bool above;
        for (uint256 i = 1; !(below && above); ++i) {
            bytes memory moved = abi.encodePacked(code, i);
            bool lower = keccak256(moved) < pin;
            if (lower ? below : above) continue;
            if (lower) below = true;
            else above = true;
            vm.etch(address(cs), moved);
            vm.prank(artist);
            vm.expectRevert(abi.encodeWithSelector(WorkRules.UnknownStore.selector, 1));
            rules.setFileStore(s, id, file, 1);
        }
        vm.etch(address(cs), code);
        vm.prank(artist);
        rules.setFileStore(s, id, file, 1);
    }

    /// @dev On-chain completeness is the content store's alone: a store a file chose, gone bad
    ///      later, is never asked, and the work completes once the content store holds every
    ///      chunk.
    function test_FileStore_OnChainCompleteNeverAsksAnAddedStore() public {
        (uint256 id, bytes32 file, RulesChunkStore cs) = _twoFileWork(1);
        vm.prank(artist);
        rules.setFileStore(s, id, file, 1);
        vm.etch(address(cs), hex"fe");
        store.writeChunk(_mediaBytes(2));
        vm.expectCall(address(cs), "", 0);
        facts.markOnChainComplete(s, id);
        assertTrue(facts.factsOf(s, id).onChainComplete);
    }
}

/// @notice The same rules on the deployed stack: the real accounts module, the genesis roles and
///         their delays.
contract WorkRulesStackPortedTest is IntegrationBase {
    address internal lead;

    function _sold() internal returns (uint256 id, Work memory w) {
        lead = _actor("lead");
        w = _work(lead, collectionId);
        Work[] memory works = _one(w);
        bytes32 root = _publish(works);
        id = _sell(root, works, 0, _actor("buyer"), 1 ether);
        _open(id, w);
    }

    function _rulesDigest(bytes32 structHash) internal view returns (bytes32) {
        return _typedDigest(address(rules), structHash);
    }

    /// @dev ERC-2098 compact signatures consent to a royalty-rate change made through the
    ///      network's scheduled role.
    function test_Stack_CompactSignaturesConsentToARateChange() public {
        (uint256 id, Work memory w) = _sold();
        bytes32 state = rules.workStateHash(address(stream), id);
        uint64 dl = uint64(block.timestamp + 30 days);
        bytes32 digest = _rulesDigest(
            keccak256(
                abi.encode(
                    rules.ROYALTY_RATE_TYPEHASH(), address(stream), id, uint24(5_000), state, dl
                )
            )
        );
        (bytes32 r, bytes32 vs) = vm.signCompact(keyOf[lead], digest);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(lead, r, vs);
        _asNetwork(
            address(rules),
            abi.encodeCall(
                rules.setRoyaltyRate, (address(stream), id, 5_000, w.item, state, dl, sigs)
            )
        );
        assertEq(stream.workOf(id).royaltyRate, 5_000);
    }

    /// @dev While the network freezes the artist's account, no wallet of it renounces; once
    ///      the freeze is lifted the same signature applies.
    function test_Stack_NobodyRenouncesWhileTheAccountIsFrozen() public {
        (uint256 id,) = _sold();
        address s = address(stream);
        bytes32 state = rules.workStateHash(s, id);
        vm.prank(lead);
        rules.finalize(s, id, state);
        state = rules.workStateHash(s, id);
        uint64 dl = uint64(block.timestamp + 1 days);
        bytes32 digest = _rulesDigest(
            keccak256(
                abi.encode(
                    rules.RENOUNCE_POWERS_TYPEHASH(), s, id, WorkPowers.RENDERER_REPIN, state, dl
                )
            )
        );
        bytes memory sig = abi.encodePacked(lead, _sign(lead, digest));
        uint256 artistId = accounts.artistIdOf(lead);
        _asNetwork(address(accounts), abi.encodeCall(accounts.freeze, (artistId)));
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, lead));
        rules.renounce(s, id, WorkPowers.RENDERER_REPIN, state, dl, sig);
        _asNetwork(address(accounts), abi.encodeCall(accounts.unfreeze, (artistId)));
        rules.renounce(s, id, WorkPowers.RENDERER_REPIN, state, dl, sig);
        assertEq(rules.renouncedPowers(s, id), WorkPowers.RENDERER_REPIN);
    }

    /// @dev Only the storage operator marks a locator dead: neither the artist nor the platform.
    function test_Stack_OnlyTheStorageOperatorMarksALocatorDead() public {
        (uint256 id, Work memory w) = _sold();
        address s = address(stream);
        bytes32 file = w.media[0].fileId;
        vm.prank(platform);
        delivery.addLocator(s, id, file, CA.ar("p0"));
        address[2] memory callers = [lead, platform];
        for (uint256 i; i < 2; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManaged.AccessManagedUnauthorized.selector, callers[i]
                )
            );
            delivery.markLocatorDead(s, id, file, 0);
        }
        vm.prank(storageOperator);
        delivery.markLocatorDead(s, id, file, 0);
        assertEq(delivery.deadLocators(s, id, file), 1);
    }
}
