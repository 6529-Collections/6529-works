// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { PackageItem, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { EntropyBase } from "./EntropyBase.sol";

/// @notice Fuzzing of the request IDs the coordinator issues and delivers, the seeds, the retry
///         window, the callback's caller and the package gate.
contract VrfEntropyFuzzTest is EntropyBase {
    function _fulfillAs(address caller, uint256 requestId, uint256 word) internal {
        vm.prank(caller);
        module.rawFulfillRandomWords(requestId, _oneWord(word));
    }

    /// @dev Whatever nonzero IDs the coordinator issues, each ID delivers to its own item, once.
    function testFuzz_RequestIdsRouteToTheirOwnItems(
        uint256 idA,
        uint256 idB,
        uint256 wordA,
        uint256 wordB
    ) public {
        vm.assume(idA != 0 && idB != 0 && idA != idB);
        coordinator.force(idA, false);
        assertEq(_request(0), idA);
        coordinator.force(idB, false);
        assertEq(_request(1), idB);

        coordinator.fulfill(idB, wordB);
        assertTrue(module.isDelivered(items[1]));
        assertFalse(module.isDelivered(items[0]));
        assertEq(module.seedOf(items[1]), bytes32(wordB));

        coordinator.fulfill(idA, wordA);
        assertEq(module.seedOf(items[0]), bytes32(wordA));
        assertEq(module.seedOf(items[1]), bytes32(wordB));

        // Neither ID can deliver again: a repeated delivery is a no-op.
        _fulfillAs(address(coordinator), idA, 1);
        _fulfillAs(address(coordinator), idB, 1);
        assertEq(module.seedOf(items[0]), bytes32(wordA));
        assertEq(module.seedOf(items[1]), bytes32(wordB));
    }

    /// @dev An ID the module never recorded delivers nothing, for any value.
    function testFuzz_UnissuedRequestIdsNeverDeliver(uint256 id, uint256 word) public {
        uint256 issued = _request(0);
        vm.assume(id != issued);
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.UnknownRequest.selector, id));
        _fulfillAs(address(coordinator), id, word);
        assertFalse(module.isDelivered(items[0]));
    }

    /// @dev After any number of repeats, any outstanding request may deliver first and the first
    ///      delivery fixes the seed; every later delivery, from any request, changes nothing.
    function testFuzz_TheFirstDeliveryOfManyRequestsWins(
        uint8 count,
        uint8 first,
        uint256 word,
        uint256 other
    ) public {
        uint256 n = bound(count, 1, 12);
        uint256[] memory ids = new uint256[](n);
        ids[0] = _request(0);
        for (uint256 i = 1; i < n; ++i) {
            vm.warp(block.timestamp + RETRY_DELAY);
            ids[i] = _request(0);
        }
        uint256 winner = bound(first, 0, n - 1);
        _fulfillAs(address(coordinator), ids[winner], word);
        for (uint256 i; i < n; ++i) {
            _fulfillAs(address(coordinator), ids[i], other);
        }
        assertEq(module.seedOf(items[0]), bytes32(word));
    }

    /// @dev The seed is the delivered word, unchanged.
    function testFuzz_SeedIsTheDeliveredWord(uint256 word) public {
        uint256 id = _request(0);
        coordinator.fulfill(id, word);
        assertEq(module.seedOf(items[0]), bytes32(word));
    }

    /// @dev A request is open to repeat exactly from `requestedAt + retryDelay`, for anyone.
    function testFuzz_RetryWindow(uint256 elapsed, address caller) public {
        _request(0);
        uint256 requestedAt = block.timestamp;
        elapsed = bound(elapsed, 0, 90 days);
        vm.warp(requestedAt + elapsed);
        vm.prank(caller);
        if (elapsed < RETRY_DELAY) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IEntropyModule.RequestPending.selector,
                    items[0],
                    uint64(requestedAt + RETRY_DELAY)
                )
            );
            module.requestSeed(_item(0), root, proofs[0]);
        } else {
            uint256 id = module.requestSeed(_item(0), root, proofs[0]);
            (uint256 requestId, uint64 stamp) = module.requestOf(items[0]);
            assertEq(requestId, id);
            assertEq(stamp, requestedAt + elapsed);
        }
    }

    /// @dev Only the coordinator may call the callback, whoever the caller is.
    function testFuzz_OnlyTheCoordinatorMayFulfill(address caller, uint256 word) public {
        vm.assume(caller != address(coordinator));
        uint256 id = _request(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntropyModule.OnlyCoordinatorCanFulfill.selector, caller, address(coordinator)
            )
        );
        _fulfillAs(caller, id, word);
    }

    /// @dev No item outside the approved package can be requested, with any proof.
    function testFuzz_OnlyItemsOfAnApprovedPackageCanBeRequested(
        uint256 salt,
        bytes32[] calldata proof
    ) public {
        vm.assume(proof.length <= module.MAX_PROOF_LENGTH());
        vm.assume(salt > 1000); // not one of the fixtures' items
        PackageItem memory item = _makeItem(salt, SeedPolicy.VRF);
        vm.expectRevert(_notRequestable(_hash(item)));
        module.requestSeed(item, root, proof);
        (uint256 requestId,) = module.requestOf(_hash(item));
        assertEq(requestId, 0);
    }

    /// @dev No root the registry has not approved can be requested against, with any item.
    function testFuzz_OnlyApprovedRootsPass(bytes32 packageRoot, uint256 salt) public {
        vm.assume(packageRoot != root && packageRoot != soloRoot);
        vm.assume(packageRoot != plainRoot(SeedPolicy.NONE));
        vm.assume(packageRoot != plainRoot(SeedPolicy.ARTIST));
        PackageItem memory item = _makeItem(salt, SeedPolicy.VRF);
        vm.expectRevert(_notRequestable(_hash(item)));
        module.requestSeed(item, packageRoot, new bytes32[](0));
    }

    /// @dev An item whose seed policy is not VRF is refused whatever the root and proof, even
    ///      when it is an approved item of an approved package.
    function testFuzz_NonVrfItemsAreAlwaysRefused(
        uint256 salt,
        bool artistPolicy,
        bytes32 packageRoot,
        bytes32[] calldata proof
    ) public {
        SeedPolicy policy = artistPolicy ? SeedPolicy.ARTIST : SeedPolicy.NONE;
        PackageItem memory item = _makeItem(salt, policy);
        vm.expectRevert(_notRequestable(_hash(item)));
        module.requestSeed(item, packageRoot, proof);
        (uint256 requestId,) = module.requestOf(_hash(item));
        assertEq(requestId, 0);
    }
}
