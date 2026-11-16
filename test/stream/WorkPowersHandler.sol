// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CommonBase } from "forge-std/Base.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { Stream } from "src/stream/Stream.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IStreamViews } from "src/interfaces/IStreamViews.sol";

/// @notice Drives renunciations (relayed by the network or by anyone), consented royalty
///         changes (lower, equal and higher), network repins and
///         consented relicenses on a few open works, keeping a ghost of each work's renounced
///         mask, rate and license for `WorkPowersInvariantTest`.
/// @dev Every call that can revert is made with try/catch, so `fail_on_revert` holds. A call
///      the rules refuse that succeeds, or one they allow that reverts, counts as a violation.
contract WorkPowersHandler is CommonBase, StdUtils {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    Stream internal immutable stream;
    WorkRecords internal immutable records;
    uint256 internal immutable artistKey;
    uint256 internal immutable collaboratorKey;
    address internal immutable governor;

    uint256[] public tokenIds;
    bytes[] internal _items;
    License[] internal _licenses;

    uint256 public violations;
    uint256 public renounced;
    uint256 public reRated;
    uint256 public relicensed;
    mapping(uint256 tokenId => uint16) public ghostMask;
    mapping(uint256 tokenId => uint32) public ghostRate;
    mapping(uint256 tokenId => uint256) public ghostLicense;
    mapping(uint256 tokenId => bool) public ghostFinalized;
    mapping(uint256 tokenId => address) public ghostRenderer;
    address[] internal _renderers;
    uint256 public repinned;

    constructor(
        Stream stream_,
        WorkRecords records_,
        uint256 artistKey_,
        uint256 collaboratorKey_,
        address governor_
    ) {
        stream = stream_;
        records = records_;
        artistKey = artistKey_;
        collaboratorKey = collaboratorKey_;
        governor = governor_;
    }

    /// @dev The licenses relicenses move between; the first is every work's license at open.
    function addLicense(License memory license) external {
        _licenses.push(license);
    }

    /// @dev Renderers the errata repin moves between (each pinned with its own code hash).
    function addRenderer(address renderer) external {
        _renderers.push(renderer);
    }

    function addWork(uint256 tokenId, PackageItem memory item) external {
        tokenIds.push(tokenId);
        _items.push(abi.encode(item));
        ghostRate[tokenId] = IStreamViews(address(stream)).work(tokenId).royaltyRate;
    }

    function workCount() external view returns (uint256) {
        return tokenIds.length;
    }

    // -------------------------------------------------------------------------------- actions

    /// @dev The lead artist (or, one time in four, the collaborator) signs a renunciation of a
    ///      random mask, unknown bits included; the network relays it, or one time in three
    ///      anyone else, which may not add the royalty or licence power (C7).
    function renounce(uint256 seed, uint16 powers) external {
        (, uint256 tokenId) = _pick(seed);
        powers = uint16(bound(powers, 0, 15));
        bool byCollaborator = (seed >> 8) % 4 == 0;
        bool byNetwork = (seed >> 16) % 3 != 0;
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _sign(
            byCollaborator ? collaboratorKey : artistKey,
            keccak256(abi.encode(Typehashes.RENOUNCE_POWERS, tokenId, powers, state, deadline))
        );
        uint16 before = ghostMask[tokenId];
        bool allowed = _renounceAllowed(tokenId, powers, byCollaborator, byNetwork);
        vm.prank(byNetwork ? governor : address(0xCAFE));
        try records.renounce(tokenId, powers, state, deadline, sig) {
            if (!allowed) ++violations;
            ghostMask[tokenId] = before | powers;
            if (powers & ~before != 0) ++renounced;
        } catch {
            if (allowed) ++violations;
        }
    }

    /// @dev Allowed: known bits, and either nothing new (a no-op) or the lead artist's
    ///      signature, with the renderer repin renounceable only once the work is finalized,
    ///      and a new royalty or licence bit only through the network (C7).
    function _renounceAllowed(uint256 tokenId, uint16 powers, bool byCollaborator, bool byNetwork)
        internal
        view
        returns (bool)
    {
        uint16 added = powers & ~ghostMask[tokenId];
        if (powers & ~WorkPowers.ALL != 0) return false;
        if (added == 0) return true;
        bool repinTooEarly = powers & WorkPowers.RENDERER_REPIN != 0 && !ghostFinalized[tokenId];
        bool needsNetwork = added & (WorkPowers.ROYALTY_RATE | WorkPowers.RELICENSE) != 0;
        return !byCollaborator && !repinTooEarly && (byNetwork || !needsNetwork);
    }

    /// @dev Every party consents to a random rate, higher, equal or lower; FUNDS_SETTER applies:
    ///      allowed until the power is renounced (R10).
    function changeRoyalty(uint256 seed, uint32 rate) external {
        (uint256 index, uint256 tokenId) = _pick(seed);
        rate = uint32(bound(rate, 0, 100_000));
        uint32 current = ghostRate[tokenId];
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 15 days);
        bytes[] memory sigs = _both(
            keccak256(abi.encode(Typehashes.ROYALTY_RATE_CHANGE, tokenId, rate, state, deadline))
        );
        bool allowed = ghostMask[tokenId] & WorkPowers.ROYALTY_RATE == 0;
        PackageItem memory item = _item(index);
        vm.prank(governor);
        try records.setRoyaltyRate(tokenId, rate, item, state, deadline, sigs) {
            if (!allowed) ++violations;
            if (rate != current) ++reRated;
            ghostRate[tokenId] = rate;
        } catch {
            if (allowed) ++violations;
        }
    }

    /// @dev Every party consents to another (or the same) license; PARAMETER_SETTER applies.
    function relicense(uint256 seed, uint256 which) external {
        (uint256 index, uint256 tokenId) = _pick(seed);
        which = which % _licenses.length;
        License memory next = _licenses[which];
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes[] memory sigs = _both(
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
        bool allowed = ghostMask[tokenId] & WorkPowers.RELICENSE == 0;
        PackageItem memory item = _item(index);
        vm.prank(governor);
        try records.relicense(tokenId, next, item, state, deadline, sigs) {
            if (!allowed) ++violations;
            if (which != ghostLicense[tokenId]) ++relicensed;
            ghostLicense[tokenId] = which;
        } catch {
            if (allowed) ++violations;
        }
    }

    /// @dev The lead artist finalizes the work (once; later calls revert).
    function finalize(uint256 seed) external {
        (, uint256 tokenId) = _pick(seed);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(vm.addr(artistKey));
        try records.finalize(tokenId, state) {
            if (ghostFinalized[tokenId]) ++violations;
            ghostFinalized[tokenId] = true;
            ghostRenderer[tokenId] = stream.defaultRenderer();
        } catch {
            if (!ghostFinalized[tokenId]) ++violations;
        }
    }

    /// @dev SUCCESSOR_SETTER repins one of the renderers alone (C8): allowed only for a
    ///      finalized work whose repin power is not renounced.
    function repin(uint256 seed, uint256 which) external {
        (, uint256 tokenId) = _pick(seed);
        address next = _renderers[which % _renderers.length];
        bytes32 state = ghostFinalized[tokenId] ? records.workStateHash(tokenId) : bytes32(0);
        bool allowed =
            ghostFinalized[tokenId] && ghostMask[tokenId] & WorkPowers.RENDERER_REPIN == 0;
        vm.prank(governor);
        try records.repinRenderer(tokenId, next, next.codehash, state) {
            if (!allowed) ++violations;
            if (next != ghostRenderer[tokenId]) ++repinned;
            ghostRenderer[tokenId] = next;
        } catch {
            if (allowed) ++violations;
        }
    }

    /// @dev The current license as the ghost tracks it.
    function ghostLicenseOf(uint256 tokenId) external view returns (License memory) {
        return _licenses[ghostLicense[tokenId]];
    }

    // ------------------------------------------------------------------------------- internal

    function _pick(uint256 seed) internal view returns (uint256 index, uint256 tokenId) {
        index = seed % tokenIds.length;
        tokenId = tokenIds[index];
    }

    function _item(uint256 index) internal view returns (PackageItem memory) {
        return abi.decode(_items[index], (PackageItem));
    }

    function _sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(Typehashes.WORK_RECORDS_NAME)),
                keccak256(bytes(Typehashes.DOMAIN_VERSION)),
                block.chainid,
                address(records)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(vm.addr(key), r, s, v);
    }

    function _both(bytes32 structHash) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        sigs[0] = _sign(artistKey, structHash);
        sigs[1] = _sign(collaboratorKey, structHash);
    }
}
