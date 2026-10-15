// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { StreamFixture } from "./StreamFixture.sol";

/// @notice The accepted limitation of Stream's hashed terms positions (QUALITY-6, ADR 0004): an
///         artist ID ground offline (89,317 tries over addresses, a brute-force search of
///         `keccak256(abi.encode(artistId, 6529, 25000, 1, 1)) & 0x7fffff`) shares the victim's
///         23-bit position under the current economics. Whoever starts first takes the position;
///         the other's first start then writes the overflow word and its index, one new slot more
///         than ADR 0004's "an artist's first work" row, and each later start under those terms
///         reads the overflow index cold. The views stay correct. (From the review of PR #63.)
contract StreamTermsGrindTest is StreamFixture {
    address internal constant VICTIM = address(0x000000000000000000000000000000000000B0B5);
    address internal constant GROUND = address(0x00a77AC4E5000000000000000000000000015ce5);
    uint256 internal salt = 100;

    function _mintBy(address who) internal returns (uint256 tokenId) {
        PackageItem memory item = _item(++salt);
        item.parties[0].account = who;
        return _mint(item);
    }

    /// @dev New (zero to nonzero) Stream slots written by a mint of `who`, and its gas.
    function _measure(address who) internal returns (uint256 fresh, uint256 gas) {
        vm.startStateDiffRecording();
        uint256 g = gasleft();
        _mintBy(who);
        gas = g - gasleft();
        Vm.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();
        bytes32[] memory seen = new bytes32[](64);
        uint256 n;
        for (uint256 i; i < diff.length; ++i) {
            for (uint256 j; j < diff[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = diff[i].storageAccesses[j];
                if (s.account != address(stream) || !s.isWrite || s.reverted) continue;
                if (s.previousValue != 0 || s.newValue == 0) continue;
                bool dup;
                for (uint256 k; k < n; ++k) {
                    if (seen[k] == s.slot) dup = true;
                }
                if (!dup) seen[n++] = s.slot;
            }
        }
        fresh = n;
    }

    function setUp() public override {
        super.setUp();
        artists.register(VICTIM);
        artists.register(GROUND);
        _mint(1); // registers the fee recipient (index 1), as at steady state
    }

    function test_FirstStartWithoutACollision() public {
        (uint256 first,) = _measure(VICTIM);
        (uint256 later, uint256 gasLater) = _measure(VICTIM);
        emit log_named_uint("victim first start, new Stream slots", first);
        emit log_named_uint("victim later start, new Stream slots", later);
        emit log_named_uint("victim later start, gas", gasLater);
        assertEq(first, later + 1);
    }

    function test_GroundCollisionAddsOneSlotToTheFirstStart() public {
        _mintBy(GROUND); // the ground artist starts first and takes the hashed position
        (uint256 first,) = _measure(VICTIM);
        (uint256 later, uint256 gasLater) = _measure(VICTIM);
        emit log_named_uint("victim first start after the ground start, new Stream slots", first);
        emit log_named_uint("victim later start, new Stream slots", later);
        emit log_named_uint("victim later start, gas", gasLater);
        assertEq(first, later + 2, "one slot more than the ADR row");
        assertEq(stream.artistOf(stream.totalSupply()), uint160(VICTIM), "views still correct");
    }
}
