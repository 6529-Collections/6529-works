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

/// @notice Drives renunciations, consented royalty changes (lower, equal and higher) and
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

    function addWork(uint256 tokenId, PackageItem memory item) external {
        tokenIds.push(tokenId);
        _items.push(abi.encode(item));
        ghostRate[tokenId] = stream.work(tokenId).royaltyRate;
    }

    function workCount() external view returns (uint256) {
        return tokenIds.length;
    }

    // -------------------------------------------------------------------------------- actions

    /// @dev The lead artist (or, one time in four, the collaborator) signs a renunciation of a
    ///      random mask, unknown bits included.
    function renounce(uint256 seed, uint16 powers) external {
        (uint256 index, uint256 tokenId) = _pick(seed);
        powers = uint16(bound(powers, 0, 7));
        bool byCollaborator = (seed >> 8) % 4 == 0;
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _sign(
            byCollaborator ? collaboratorKey : artistKey,
            keccak256(abi.encode(Typehashes.RENOUNCE_POWERS, tokenId, powers, state, deadline))
        );
        uint16 before = ghostMask[tokenId];
        bool unknown = powers & ~WorkPowers.ALL != 0;
        bool adds = powers & ~before != 0;
        // Allowed: known bits, and either nothing new (a no-op) or the lead artist's signature.
        bool allowed = !unknown && (!adds || !byCollaborator);
        try records.renounce(tokenId, powers, state, deadline, sig) {
            if (!allowed) ++violations;
            ghostMask[tokenId] = before | powers;
            if (adds) ++renounced;
        } catch {
            if (allowed) ++violations;
        }
        index;
    }

    /// @dev Every party consents to a random rate, higher, equal or lower; FUNDS_SETTER applies.
    function changeRoyalty(uint256 seed, uint32 rate) external {
        (uint256 index, uint256 tokenId) = _pick(seed);
        rate = uint32(bound(rate, 0, 100_000));
        uint32 current = ghostRate[tokenId];
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 15 days);
        bytes[] memory sigs = _both(
            keccak256(abi.encode(Typehashes.ROYALTY_RATE_CHANGE, tokenId, rate, state, deadline))
        );
        bool allowed = ghostMask[tokenId] & WorkPowers.ROYALTY_RATE == 0 && rate <= current;
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
        return abi.encodePacked(r, s, v);
    }

    function _both(bytes32 structHash) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        sigs[0] = _sign(artistKey, structHash);
        sigs[1] = _sign(collaboratorKey, structHash);
    }
}
