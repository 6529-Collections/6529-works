// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { Locator, LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import {
    MoveAuthorization,
    PackageItem,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { Stream } from "src/stream/Stream.sol";
import { IWorkRecords } from "src/stream/IWorkRecords.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { MockRenderer, MockSaleAdapter } from "../mocks/stream/StreamMocks.sol";

/// @notice Drives 6529 Stream and its records satellite through random sequences of mints,
///         burns, transfers, record edits, finalizes, attacks on finalized works, consented
///         royalty changes and renderer swaps, keeping ghost state for the invariants.
/// @dev Every action either succeeds or is skipped, so `fail_on_revert` holds; an action that
///      must revert is checked with try/catch and counted as a violation if it does not.
contract StreamHandler is CommonBase, StdCheats, StdUtils {
    struct Snapshot {
        bytes32 record;
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
    mapping(uint256 => bool) public registered;
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

    function addItem(PackageItem memory item) external {
        _items.push(abi.encode(item));
    }

    function addSpareRecord(bytes32 fileId) external {
        _spareRecords.push(fileId);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function finalSnapshot(uint256 tokenId) external view returns (bytes32, address) {
        return (_final[tokenId].record, _final[tokenId].renderer);
    }

    // -------------------------------------------------------------------------------- actions

    function mint(uint256) external {
        if (nextItem >= _items.length) return;
        PackageItem memory item = _item(nextItem++);
        uint256 expected = stream.totalMinted() + 1;
        (uint256 tokenId,) = auction.start(stream, _request(item));
        if (tokenId != expected) ++violations;
        ++ghostMinted;
        (ghostReceiver[tokenId], ghostRate[tokenId]) = stream.royaltyOf(tokenId);
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

    function register(uint256 seed) external {
        (bool ok, uint256 tokenId) = _live(seed);
        if (!ok || registered[tokenId]) return;
        PackageItem memory item = _item(tokenId - 1);
        bytes32[] memory media = new bytes32[](1);
        media[0] = item.contentId;
        records.register(tokenId, item, media);
        registered[tokenId] = true;
    }

    function setRecord(uint256 seed, uint256 recordSeed) external {
        (bool ok, uint256 tokenId) = _live(seed);
        if (!ok || !registered[tokenId] || finalized[tokenId]) return;
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.setRecord(tokenId, _spareRecords[recordSeed % _spareRecords.length], state);
    }

    function finalize(uint256 seed) external {
        (bool ok, uint256 tokenId) = _live(seed);
        if (!ok || !registered[tokenId] || finalized[tokenId]) return;
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        finalized[tokenId] = true;
        IWorkRecords.RecordState memory s = records.recordState(tokenId);
        _final[tokenId] = Snapshot(s.record, s.renderer);
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
        if (!ok || !registered[tokenId]) return;
        rate = uint32(bound(rate, 0, 100_000));
        if (rate == ghostRate[tokenId]) return;
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 structHash =
            keccak256(abi.encode(records.ROYALTY_TYPEHASH(), tokenId, rate, state, deadline));
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(artistKey, structHash);
        sigs[1] = _sign(collaboratorKey, structHash);
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, _item(tokenId - 1).parties, rate, state, deadline, sigs);
        ghostRate[tokenId] = rate;
    }

    /// @dev An unconsented royalty change by governance alone must revert.
    function forceRoyalty(uint256 seed, uint32 rate) external {
        (bool ok, uint256 tokenId) = _live(seed);
        if (!ok || !registered[tokenId]) return;
        rate = uint32(bound(rate, 0, 100_000));
        if (rate == ghostRate[tokenId]) return;
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(governor);
        try records.setRoyaltyRate(
            tokenId,
            _item(tokenId - 1).parties,
            rate,
            state,
            uint64(block.timestamp),
            new bytes[](2)
        ) {
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
        if (!ok || !registered[tokenId]) return;
        bytes32 file = _item(tokenId - 1).contentId;
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

    function _item(uint256 index) internal view returns (PackageItem memory) {
        return abi.decode(_items[index], (PackageItem));
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
                keccak256("6529 Stream Records"),
                keccak256("1"),
                block.chainid,
                address(records)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }
}
