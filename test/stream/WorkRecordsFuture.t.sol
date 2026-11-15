// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IMintPolicy } from "src/interfaces/IMintPolicy.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { Burner, GasRuleAssertions } from "test/helpers/GasRule.sol";
import { toWorkItem, toWorkMedia } from "test/helpers/WorkItems.sol";
import { MockRenderer } from "../mocks/stream/StreamMocks.sol";
import { RecordsFixture } from "./RecordsFixture.sol";

/// @notice A mint policy of the future: it accepts items with kinds, seed policies and roles
///         today's enums do not name, encoded exactly as `PackageItem` (enums are `uint8`).
contract FuturePolicy {
    address public artistRegistry;
    address internal immutable _seller;
    address internal immutable _fee;

    constructor(address registry, address seller_, address fee_) {
        artistRegistry = registry;
        _seller = seller_;
        _fee = fee_;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IMintPolicy).interfaceId || id == 0x01ffc9a7;
    }

    function authorize(IMintPolicy.MintContext calldata, bytes calldata request)
        external
        pure
        returns (IMintPolicy.MintRecord memory r)
    {
        IWorkRecords.WorkItem memory item = abi.decode(request, (IWorkRecords.WorkItem));
        r.itemHash = keccak256(abi.encode(WorksHashing.PACKAGE_ITEM_DOMAIN, item));
        r.artistId = uint160(item.parties[0].account);
        r.collectionId = item.collectionId;
        r.kind = item.kind;
        r.seedPolicy = item.seedPolicy;
        r.royaltyRate = 6_529;
        r.contentHash = item.contentHash;
        r.mediaHash = item.mediaHash;
        r.recordFileId = item.recordFileId;
        r.saleKind = item.sale.saleKind;
        r.creator = item.parties[0].account;
        r.seller = address(0x5E11E7);
        r.feeRecipient = address(0xFEE);
        r.feeShare = 25_000;
    }

    function preview(IMintPolicy.MintContext calldata, bytes calldata)
        external
        pure
        returns (PrimaryTerms memory)
    {
        revert("not used");
    }
}

/// @notice A renderer that states its record and preview bounds (`IRecordLimits`).
contract LimitsRenderer is MockRenderer {
    uint256 internal immutable _record;
    uint256 internal immutable _preview;

    constructor(uint256 record_, uint256 preview_) MockRenderer("limits") {
        _record = record_;
        _preview = preview_;
    }

    function recordLimits() external view returns (uint256, uint256) {
        return (_record, _preview);
    }
}

/// @notice A renderer whose bounds answer is not two words.
contract MalformedLimitsRenderer is MockRenderer {
    constructor() MockRenderer("malformed") { }

    function recordLimits() external pure returns (uint256, uint256, uint256) {
        return (1, 1, 1);
    }
}

/// @notice What makes `WorkRecords` last: items a future mint policy defines still open
///         (`uint8` decoding), `RecordOpened` carries every fact the open fixes (logs-only
///         consensus), and record and preview bounds come from the renderer that will show the
///         work, with the compiled bounds as the fallback.
contract WorkRecordsFutureTest is RecordsFixture, GasRuleAssertions {
    function setUp() public override(RecordsFixture) {
        RecordsFixture.setUp();
    }

    function _setDefault(address next) internal {
        address current = stream.defaultRenderer();
        vm.prank(governor);
        stream.setDefaultRenderer(current, next, next.codehash);
    }

    // ------------------------------------------------------------------- future item values

    /// @dev Kind 3, seed policy 3, a party role 7 and a media role 9 (none named by today's
    ///      enums) mint under a future policy and the record opens; the seed of an unknown
    ///      policy is the item's own, recorded, and `mediaOf` reports the role as given.
    function test_openRecord_itemValuesTodaysEnumsDoNotName() public {
        FuturePolicy policy = new FuturePolicy(address(artists), address(0), address(0));
        vm.prank(governor);
        stream.setDependency("PACKAGE_REGISTRY", address(registry), address(policy));

        IWorkRecords.WorkMedia[] memory media = toWorkMedia(_single(1, true));
        media = _withExtra(media, _mediaFile(2, FileRole.AUXILIARY, true));
        media[1].role = 9;
        IWorkRecords.WorkItem memory item = toWorkItem(_item(1));
        item.kind = 3;
        item.seedPolicy = 3;
        item.seed = keccak256("future seed");
        item.parties[0].role = 7;
        item.contentHash = media[0].sha256Hash;
        item.mediaHash = keccak256(abi.encode(WorksHashing.MEDIA_DOMAIN, media));
        item.recordFileId = _record(1);
        (uint256 tokenId,) = auction.start(stream, abi.encode(item));

        vm.expectEmit(address(records));
        emit IWorkRecords.RecordOpened(
            tokenId, item, media, WorksHashing.CC0_LICENSE_KEY, keccak256("future seed")
        );
        records.openRecord(tokenId, item, media);
        (uint8 policyOf, bytes32 seed) = records.seedOf(tokenId);
        assertEq(policyOf, 3);
        assertEq(seed, keccak256("future seed"));
        assertEq(records.mediaOf(tokenId)[1].role, 9);
    }

    function _withExtra(IWorkRecords.WorkMedia[] memory media, MediaFile memory extra)
        internal
        pure
        returns (IWorkRecords.WorkMedia[] memory out)
    {
        out = new IWorkRecords.WorkMedia[](media.length + 1);
        for (uint256 i; i < media.length; ++i) {
            out[i] = media[i];
        }
        out[media.length] =
            IWorkRecords.WorkMedia(extra.fileId, extra.sha256Hash, uint8(extra.role));
    }

    /// @dev `WorkItem` is `PackageItem` byte for byte: the same item hash.
    function testFuzz_workItemHashesAsPackageItem(uint256 salt, bytes32 seed) public view {
        PackageItem memory p = _item(salt);
        p.seed = seed;
        assertEq(
            keccak256(abi.encode(WorksHashing.PACKAGE_ITEM_DOMAIN, toWorkItem(p))),
            WorksHashing.itemHash(p)
        );
    }

    // ---------------------------------------------------------------- consensus from logs

    /// @dev `RecordOpened` carries the item (record file, media commitment, license, seed
    ///      policy, parties, payees with their shares), the media list, the license key and the
    ///      seed: its item hashes to the core's stored item hash.
    function test_recordOpened_carriesEveryFactOfTheOpen() public {
        (uint256 tokenId, PackageItem memory item, MediaFile[] memory media) = _minted(5, true);
        vm.recordLogs();
        records.openRecord(tokenId, toWorkItem(item), toWorkMedia(media));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory data;
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IWorkRecords.RecordOpened.selector) {
                data = logs[i].data;
                ++found;
            }
        }
        assertEq(found, 1);
        (
            IWorkRecords.WorkItem memory logged,
            IWorkRecords.WorkMedia[] memory loggedMedia,
            bytes32 key,
            bytes32 seed
        ) = abi.decode(data, (IWorkRecords.WorkItem, IWorkRecords.WorkMedia[], bytes32, bytes32));
        (bytes32 itemHash,,,,,) = stream.coreOf(tokenId);
        assertEq(keccak256(abi.encode(WorksHashing.PACKAGE_ITEM_DOMAIN, logged)), itemHash);
        assertEq(keccak256(abi.encode(WorksHashing.MEDIA_DOMAIN, loggedMedia)), item.mediaHash);
        assertEq(key, WorksHashing.licenseKey(item.license.spdxId));
        assertEq(seed, 0);
        assertEq(logged.parties.length, 2);
        assertEq(logged.payees[0].share, 20_000);
    }

    // ------------------------------------------------------------- bounds from the renderer

    function _recordOf(uint256 length) internal returns (bytes32) {
        bytes memory data = new bytes(length);
        data[0] = "{";
        data[length - 1] = "}";
        return _file(data, "application/json", true);
    }

    /// @dev A renderer that shows 20,000-byte records lets a 13,000-byte record be set; the
    ///      compiled 12,288 refuses it under a renderer that states nothing or answers badly.
    function test_recordBound_comesFromTheRenderer() public {
        (uint256 tokenId,) = _work(1);
        bytes32 big = _recordOf(13_000);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownRecordFile.selector, big));
        records.setRecord(tokenId, big, state);

        _setDefault(address(new MalformedLimitsRenderer()));
        state = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownRecordFile.selector, big));
        records.setRecord(tokenId, big, state);

        LimitsRenderer wide = new LimitsRenderer(20_000, Limits.MAX_PREVIEW_BYTES);
        _setDefault(address(wide));
        state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.setRecord(tokenId, big, state);
        state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertEq(records.pinnedRenderer(tokenId), address(wide));
    }

    /// @dev Finalize checks the record against the renderer it pins: a default renderer with a
    ///      tighter bound refuses a record set under a wider one.
    function test_recordBound_finalizeUsesThePinnedRenderer() public {
        (uint256 tokenId,) = _work(2);
        _setDefault(address(new LimitsRenderer(20_000, Limits.MAX_PREVIEW_BYTES)));
        bytes32 big = _recordOf(13_000);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.setRecord(tokenId, big, state);
        _setDefault(address(new LimitsRenderer(1_000, Limits.MAX_PREVIEW_BYTES)));
        state = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownRecordFile.selector, big));
        records.finalize(tokenId, state);
    }

    /// @dev The preview bound at open is the default renderer's.
    function test_previewBound_comesFromTheRenderer() public {
        _setDefault(address(new LimitsRenderer(Limits.MAX_RECORD_BYTES, 100)));
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(10, FileRole.PRIMARY, true);
        media[1] = _mediaFile(11, FileRole.PREVIEW, true); // 128 bytes, counted 512
        PackageItem memory item = _recordsItem(10, media);
        uint256 tokenId = _mint(item);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidRecordData.selector, tokenId));
        records.openRecord(tokenId, toWorkItem(item), toWorkMedia(media));
        _setDefault(address(new LimitsRenderer(Limits.MAX_RECORD_BYTES, 512)));
        records.openRecord(tokenId, toWorkItem(item), toWorkMedia(media));
    }

    /// @dev Gas rule on the bounds read: the renderer costing 1x to 100x its base gives the same
    ///      result, and running short reverts with the shortfall error, never falls back to the
    ///      compiled bound.
    function test_GasRule_recordBoundRead() public {
        (uint256 tokenId,) = _work(3);
        LimitsRenderer wide = new LimitsRenderer(20_000, Limits.MAX_PREVIEW_BYTES);
        Burner burner = new Burner(address(wide), 20_000);
        _setDefault(address(burner));
        bytes32 big = _recordOf(13_000);
        bytes32 state = records.workStateHash(tokenId);
        bytes memory data = abi.encodeCall(records.setRecord, (tokenId, big, state));
        Outcome memory o = _assertSameAtEveryMultiple(burner, artist, address(records), data);
        assertTrue(o.ok);
        for (uint256 i; i < 3; ++i) {
            burner.burnerSetMultiple(i == 0 ? 1 : i == 1 ? 4 : 10);
            _assertShortfallNeverAnswers(burner, artist, address(records), data);
        }
    }
}
