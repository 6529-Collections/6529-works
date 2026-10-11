// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import {
    MoveAuthorization,
    PackageItem,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { Stream } from "src/stream/Stream.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { MockRenderer, MockSaleAdapter } from "../mocks/stream/StreamMocks.sol";

/// @notice Drives 6529 Stream and its records satellite through random sequences of mints,
///         burns, transfers, record edits, finalizes, attacks on finalized works, consented and
///         unconsented royalty changes and renderer swaps, keeping ghost state for the
///         invariants.
/// @dev Every action either succeeds or is skipped, so `fail_on_revert` holds; an action that
///      must revert is checked with try/catch and counted as a violation if it does not.
contract StreamHandler is CommonBase, StdCheats, StdUtils {
    struct Snapshot {
        bytes32 recordFileId;
        address renderer;
    }

    Stream internal immutable stream;
    WorkRecords internal immutable records;
    MockSaleAdapter internal immutable auction;
    address internal immutable artist;
    uint256 internal immutable artistKey;
    uint256 internal immutable collaboratorKey;
    address internal immutable governor;
    address internal immutable platform;
    MockRenderer internal immutable rendererA;
    MockRenderer internal immutable rendererB;

    bytes[] internal _items;
    bytes32[] internal _spareRecords;
    address[] public actors;

    uint256 public nextItem;
    uint256 public ghostMinted;
    uint256 public ghostBurned;
    uint256 public violations;
    mapping(uint256 => bool) public burned;
    mapping(uint256 => bool) public opened;
    mapping(uint256 => address) public ghostReceiver;
    mapping(uint256 => uint32) public ghostRate;
    mapping(uint256 => bool) public finalized;
    mapping(uint256 => Snapshot) internal _final;

    constructor(
        Stream stream_,
        WorkRecords records_,
        MockSaleAdapter auction_,
        uint256 artistKey_,
        uint256 collaboratorKey_,
        address governor_,
        address platform_,
        MockRenderer rendererA_,
        MockRenderer rendererB_
    ) {
        stream = stream_;
        records = records_;
        auction = auction_;
        artistKey = artistKey_;
        artist = vm.addr(artistKey_);
        collaboratorKey = collaboratorKey_;
        governor = governor_;
        platform = platform_;
        rendererA = rendererA_;
        rendererB = rendererB_;
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string.concat("collector", vm.toString(i))));
        }
    }

    function addItem(PackageItem memory item, MediaFile[] memory media) external {
        _items.push(abi.encode(item, media));
    }

    function addSpareRecord(bytes32 fileId) external {
        _spareRecords.push(fileId);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function finalSnapshot(uint256 tokenId) external view returns (bytes32, address) {
        return (_final[tokenId].recordFileId, _final[tokenId].renderer);
    }

    // -------------------------------------------------------------------------------- actions

    function mint(uint256) external {
        if (nextItem >= _items.length) return;
        (PackageItem memory item,) = _item(nextItem++);
        uint256 expected = stream.totalMinted() + 1;
        (uint256 tokenId,) = auction.start(stream, _request(item));
        if (tokenId != expected) ++violations;
        ++ghostMinted;
        ghostReceiver[tokenId] = stream.work(tokenId).royaltyReceiver;
        ghostRate[tokenId] = stream.work(tokenId).royaltyRate;
    }

    function burn(uint256 seed) external {
        (bool ok, uint256 tokenId) = _held(seed, address(auction));
        if (!ok) return;
        auction.burn(stream, tokenId, 1);
        burned[tokenId] = true;
        ++ghostBurned;
    }

    function deliver(uint256 seed, uint256 actorSeed) external {
        (bool ok, uint256 tokenId) = _held(seed, address(auction));
        if (!ok) return;
        auction.deliver(address(stream), tokenId, actors[actorSeed % actors.length]);
    }

    function transfer(uint256 seed, uint256 actorSeed) external {
        (bool ok, uint256 tokenId) = _live(seed);
        if (!ok) return;
        address holder = stream.ownerOf(tokenId);
        if (holder == address(auction)) return;
        vm.prank(holder);
        stream.transferFrom(holder, actors[actorSeed % actors.length], tokenId);
    }

    function openRecord(uint256 seed) external {
        (bool ok, uint256 tokenId) = _live(seed);
        if (!ok || opened[tokenId]) return;
        (PackageItem memory item, MediaFile[] memory media) = _item(tokenId - 1);
        records.openRecord(tokenId, item, media);
        opened[tokenId] = true;
    }

    function setRecord(uint256 seed, uint256 recordSeed) external {
        (bool ok, uint256 tokenId) = _live(seed);
        if (!ok || !opened[tokenId] || finalized[tokenId]) return;
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.setRecord(tokenId, _spareRecords[recordSeed % _spareRecords.length], state);
    }

    function finalize(uint256 seed) external {
        (bool ok, uint256 tokenId) = _live(seed);
        if (!ok || !opened[tokenId] || finalized[tokenId]) return;
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        finalized[tokenId] = true;
        IWorkRecords.RecordInfo memory info = records.record(tokenId);
        _final[tokenId] = Snapshot(info.recordFileId, info.renderer);
    }

    /// @dev The artist tries to edit or re-finalize a finalized work; both must revert.
    function attackFinalized(uint256 seed, uint256 recordSeed) external {
        (bool ok, uint256 tokenId) = _live(seed);
        if (!ok || !finalized[tokenId]) return;
        bytes32 state = records.workStateHash(tokenId);
        bytes32 next = _spareRecords[recordSeed % _spareRecords.length];
        vm.prank(artist);
        try records.setRecord(tokenId, next, state) {
            ++violations;
        } catch { }
        vm.prank(artist);
        try records.finalize(tokenId, state) {
            ++violations;
        } catch { }
    }

    /// @dev A consented, governed royalty-rate change: the only way a rate may move.
    function changeRoyalty(uint256 seed, uint32 rate) external {
        (bool ok, uint256 tokenId) = _live(seed);
        if (!ok || !opened[tokenId]) return;
        rate = uint32(bound(rate, 0, 100_000));
        if (rate == ghostRate[tokenId]) return;
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 structHash =
            keccak256(abi.encode(Typehashes.ROYALTY_RATE_CHANGE, tokenId, rate, state, deadline));
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(artistKey, structHash);
        sigs[1] = _sign(collaboratorKey, structHash);
        (PackageItem memory item,) = _item(tokenId - 1);
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, rate, item, state, deadline, sigs);
        ghostRate[tokenId] = rate;
    }

    /// @dev A royalty change by governance alone, without the parties' consent, must revert.
    function forceRoyalty(uint256 seed, uint32 rate) external {
        (bool ok, uint256 tokenId) = _live(seed);
        if (!ok || !opened[tokenId]) return;
        rate = uint32(bound(rate, 0, 100_000));
        if (rate == ghostRate[tokenId]) return;
        bytes32 state = records.workStateHash(tokenId);
        (PackageItem memory item,) = _item(tokenId - 1);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = new bytes(65);
        sigs[1] = new bytes(65);
        vm.prank(governor);
        try records.setRoyaltyRate(tokenId, rate, item, state, uint64(block.timestamp), sigs) {
            ++violations;
        } catch { }
    }

    function swapRenderer() external {
        address current = stream.defaultRenderer();
        address next = current == address(rendererA) ? address(rendererB) : address(rendererA);
        vm.prank(governor);
        stream.setDefaultRenderer(current, next);
    }

    function addLocator(uint256 seed) external {
        (bool ok, uint256 tokenId) = _live(seed);
        if (!ok || !opened[tokenId]) return;
        (, MediaFile[] memory media) = _item(tokenId - 1);
        bytes32 file = media[0].fileId;
        uint256 n = records.locators(tokenId, file).length;
        if (n >= 16) return;
        vm.prank(platform);
        records.addLocator(
            tokenId, file, Locator(LocatorKind.IPFS, string.concat("ipfs://", vm.toString(n)))
        );
    }

    function warp(uint256 secondsAhead) external {
        vm.warp(block.timestamp + bound(secondsAhead, 0, 30 days));
    }

    // -------------------------------------------------------------------------------- helpers

    function _item(uint256 index)
        internal
        view
        returns (PackageItem memory item, MediaFile[] memory media)
    {
        return abi.decode(_items[index], (PackageItem, MediaFile[]));
    }

    function _live(uint256 seed) internal view returns (bool, uint256) {
        uint256 minted = stream.totalMinted();
        if (minted == 0) return (false, 0);
        uint256 tokenId = seed % minted + 1;
        return (!burned[tokenId], tokenId);
    }

    function _held(uint256 seed, address holder) internal view returns (bool, uint256) {
        (bool ok, uint256 tokenId) = _live(seed);
        if (!ok || stream.ownerOf(tokenId) != holder) return (false, 0);
        return (true, tokenId);
    }

    function _request(PackageItem memory item) internal pure returns (bytes memory) {
        return abi.encode(
            StreamMintRequest(
                keccak256("root"), item, new bytes32[](0), MoveAuthorization(1, 0, new bytes(0))
            )
        );
    }

    function _sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(Typehashes.WORK_RECORDS_NAME)),
                keccak256(bytes(Typehashes.DOMAIN_VERSION)),
                block.chainid,
                address(records)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }
}
