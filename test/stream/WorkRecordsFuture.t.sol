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

/// @notice What makes `WorkRecords` last: items a future mint policy defines still open
///         (`uint8` decoding), `RecordOpened` carries every fact the open fixes (logs-only
///         consensus), and the record bound is structural (one chunk), not a renderer's budget.
contract WorkRecordsFutureTest is RecordsFixture {
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

    // ------------------------------------------------------------------ the record bound

    function _recordOf(uint256 length) internal returns (bytes32) {
        bytes memory data = new bytes(length);
        data[0] = "{";
        data[length - 1] = "}";
        bytes32[] memory hashes = new bytes32[]((length + 24_574) / 24_575);
        for (uint256 i; i < hashes.length; ++i) {
            uint256 from = i * 24_575;
            uint256 to = from + 24_575 > length ? length : from + 24_575;
            bytes memory part = new bytes(to - from);
            for (uint256 j; j < part.length; ++j) {
                part[j] = data[from + j];
            }
            hashes[i] = keccak256(part);
            store.writeChunk(part);
        }
        return store.registerManifest(hashes, length, uint8(0), "application/json", sha256(data));
    }

    /// @dev The record bound is structural, not a renderer's budget: a one-chunk record of any
    ///      length (24,575 bytes here) is set and finalized; a two-chunk record never is.
    function test_recordBound_isOneChunk() public {
        (uint256 tokenId,) = _work(1);
        bytes32 two = _recordOf(24_576);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownRecordFile.selector, two));
        records.setRecord(tokenId, two, state);

        bytes32 one = _recordOf(24_575);
        vm.prank(artist);
        records.setRecord(tokenId, one, state);
        state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertEq(records.record(tokenId).recordFileId, one);
    }
}
