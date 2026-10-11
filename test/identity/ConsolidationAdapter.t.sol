// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ConsolidationAdapter, IDelegationManagement } from "src/identity/ConsolidationAdapter.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { IdentityFixture } from "./IdentityFixture.sol";

/// @notice The consolidation adapter against the delegation-contract mock: age, expiry, both
///         directions, all collections only, revocation, bounded walks and fail-closed reads.
contract ConsolidationAdapterTest is IdentityFixture {
    address internal a = makeAddr("a");
    address internal b = makeAddr("b");

    function test_Constants() public view {
        assertEq(adapter.ALL_COLLECTIONS(), delegation.ALL_COLLECTIONS());
        assertEq(adapter.USE_CASE_CONSOLIDATION(), 999);
        assertEq(adapter.MIN_AGE(), 30 days);
        assertEq(address(adapter.delegation()), address(delegation));
    }

    function test_Constructor_RevertsWithoutCode() public {
        vm.expectRevert(
            abi.encodeWithSelector(ConsolidationAdapter.NoDelegationCode.selector, stranger)
        );
        new ConsolidationAdapter(IDelegationManagement(stranger));
    }

    function test_IsEstablished_OnlyAfterThirtyDays() public {
        _consolidate(a, b);
        assertFalse(adapter.isEstablished(a, b));
        vm.warp(block.timestamp + 30 days - 1);
        assertFalse(adapter.isEstablished(a, b));
        vm.warp(block.timestamp + 1);
        assertTrue(adapter.isEstablished(a, b));
        assertTrue(adapter.isEstablished(b, a));
    }

    function test_IsEstablished_FalseOnceExpired() public {
        _delegate(a, b, block.timestamp + 40 days);
        _delegate(b, a, FAR);
        vm.warp(block.timestamp + 30 days);
        assertTrue(adapter.isEstablished(a, b));
        vm.warp(block.timestamp + 10 days - 1);
        assertTrue(adapter.isEstablished(a, b));
        // The delegation contract's own rule: active while `expiryDate > date`.
        vm.warp(block.timestamp + 1);
        assertFalse(adapter.isEstablished(a, b));
        assertFalse(adapter.isEstablished(b, a));
    }

    function test_IsEstablished_FalseForOneDirection() public {
        _delegate(a, b, FAR);
        vm.warp(block.timestamp + 90 days);
        assertFalse(adapter.isEstablished(a, b));
        assertFalse(adapter.isEstablished(b, a));
    }

    function test_IsEstablished_FalseForSelf() public {
        _consolidate(a, a);
        vm.warp(block.timestamp + 90 days);
        assertFalse(adapter.isEstablished(a, a));
    }

    function test_IsEstablished_IgnoresSpecificCollections() public {
        address collection = makeAddr("collection");
        vm.prank(a);
        delegation.registerDelegationAddress(collection, b, FAR, CONSOLIDATION, true, 0);
        vm.prank(b);
        delegation.registerDelegationAddress(collection, a, FAR, CONSOLIDATION, true, 0);
        vm.warp(block.timestamp + 90 days);
        assertTrue(delegation.checkConsolidationStatus(a, b, collection));
        assertFalse(adapter.isEstablished(a, b));
    }

    function test_IsEstablished_IgnoresOtherUseCases() public {
        vm.prank(a);
        delegation.registerDelegationAddress(ALL, b, FAR, 997, true, 0);
        vm.prank(b);
        delegation.registerDelegationAddress(ALL, a, FAR, 997, true, 0);
        vm.warp(block.timestamp + 90 days);
        assertFalse(adapter.isEstablished(a, b));
    }

    function test_IsEstablished_FalseAfterEitherSideRevokes() public {
        _consolidate(a, b);
        vm.warp(block.timestamp + 30 days);
        _revoke(a, b);
        assertFalse(adapter.isEstablished(a, b));
        _delegate(a, b, FAR);
        vm.warp(block.timestamp + 30 days);
        assertTrue(adapter.isEstablished(a, b));
        _revoke(b, a);
        assertFalse(adapter.isEstablished(a, b));
    }

    /// @dev The ADR 0001 section 11 reason for the adapter: the vendored check ignores age and
    ///      expiry, so a fresh or expired consolidation passes it.
    function test_VendoredCheckIgnoresAgeAndExpiry() public {
        _delegate(a, b, block.timestamp + 1 days);
        _delegate(b, a, block.timestamp + 1 days);
        assertTrue(delegation.checkConsolidationStatus(a, b, ALL));
        assertFalse(adapter.isEstablished(a, b));
        vm.warp(block.timestamp + 60 days);
        assertTrue(delegation.checkConsolidationStatus(a, b, ALL));
        assertFalse(adapter.isEstablished(a, b));
    }

    function test_IsEstablished_RenewalStartsANewAge() public {
        _delegate(a, b, block.timestamp + 10 days);
        _delegate(b, a, FAR);
        vm.warp(block.timestamp + 20 days);
        _delegate(a, b, FAR);
        vm.warp(block.timestamp + 29 days);
        assertFalse(adapter.isEstablished(a, b));
        vm.warp(block.timestamp + 1 days);
        assertTrue(adapter.isEstablished(a, b));
    }

    /// @dev A key holder appending registrations cannot displace an older live one.
    function test_IsEstablished_OldRegistrationSurvivesNewPushes() public {
        _consolidate(a, b);
        vm.warp(block.timestamp + 30 days);
        for (uint256 i; i < 10; ++i) {
            _delegate(a, b, block.timestamp + 1);
        }
        assertTrue(adapter.isEstablished(a, b));
    }

    /// @dev Documented bound: only the first MAX_REGISTRATIONS_READ registrations of a pair count.
    function test_IsEstablished_ReadsAtMostFourRegistrations() public {
        for (uint256 i; i < adapter.MAX_REGISTRATIONS_READ(); ++i) {
            _delegate(a, b, block.timestamp + 1);
        }
        _delegate(a, b, FAR);
        _delegate(b, a, FAR);
        vm.warp(block.timestamp + 90 days);
        assertFalse(adapter.isEstablished(a, b));
    }

    function testFuzz_IsEstablished_MatchesModel(
        uint32 ageAB,
        uint32 lifeAB,
        uint32 ageBA,
        uint32 lifeBA
    ) public {
        uint256 now_ = block.timestamp + 400 days;
        ageAB = uint32(bound(ageAB, 0, 400 days));
        ageBA = uint32(bound(ageBA, 0, 400 days));
        vm.warp(now_ - ageAB);
        _delegate(a, b, now_ - ageAB + lifeAB);
        vm.warp(now_ - ageBA);
        _delegate(b, a, now_ - ageBA + lifeBA);
        vm.warp(now_);
        bool expected = ageAB >= 30 days && lifeAB > ageAB && ageBA >= 30 days && lifeBA > ageBA;
        assertEq(adapter.isEstablished(a, b), expected);
        assertEq(adapter.isEstablished(b, a), expected);
    }

    function test_EstablishedWallets_FiltersAndDeduplicates() public {
        address fresh = makeAddr("fresh");
        address oneSided = makeAddr("oneSided");
        _consolidate(a, b);
        _delegate(a, oneSided, FAR);
        _delegate(a, b, FAR); // a duplicate entry for b
        _consolidate(a, wallet2);
        vm.warp(block.timestamp + 30 days);
        _consolidate(a, fresh);
        address[] memory wallets = adapter.establishedWallets(a);
        assertEq(wallets.length, 2);
        assertEq(wallets[0], b);
        assertEq(wallets[1], wallet2);
    }

    /// @dev `effectiveAt` is the later side's earliest live registration plus 30 days, and zero
    ///      unless both sides hold a live registration.
    function test_EffectiveAt_FollowsTheLaterSide() public {
        assertEq(adapter.effectiveAt(a, b), 0);
        _delegate(a, b, FAR);
        assertEq(adapter.effectiveAt(a, b), 0, "one-sided");
        vm.warp(block.timestamp + 5 days);
        _delegate(b, a, FAR);
        uint64 expected = uint64(block.timestamp + 30 days);
        assertEq(adapter.effectiveAt(a, b), expected);
        assertEq(adapter.effectiveAt(b, a), expected);
        assertFalse(adapter.isEstablished(a, b));
        vm.warp(expected);
        assertTrue(adapter.isEstablished(a, b));
        _revoke(b, a);
        assertEq(adapter.effectiveAt(a, b), 0, "revoked");
        assertEq(adapter.effectiveAt(a, a), 0, "self");
    }

    /// @dev `consolidations` lists young consolidations too, with their effective times, and
    ///      skips one-sided and expired ones; `establishedWallets` lists only established ones.
    function test_Consolidations_IncludeYoungOnes() public {
        address young = makeAddr("young");
        address expired = makeAddr("expired");
        _consolidate(a, b);
        vm.warp(block.timestamp + 30 days);
        _consolidate(a, young);
        _delegate(a, expired, block.timestamp + 1);
        _delegate(expired, a, FAR);
        _delegate(a, stranger, FAR);
        vm.warp(block.timestamp + 1);
        (address[] memory wallets, uint64[] memory times) = adapter.consolidations(a);
        assertEq(wallets.length, 2);
        assertEq(wallets[0], b);
        assertEq(times[0], block.timestamp - 1);
        assertEq(wallets[1], young);
        assertEq(times[1], block.timestamp - 1 + 30 days);
        address[] memory established = adapter.establishedWallets(a);
        assertEq(established.length, 1);
        assertEq(established[0], b);
    }

    /// @dev `consolidations` returns everything the 32-entry scan sees, beyond 16.
    function test_Consolidations_ReturnTheWholeScan() public {
        for (uint256 i; i < 20; ++i) {
            _consolidate(a, address(uint160(0x1000 + i)));
        }
        (address[] memory wallets,) = adapter.consolidations(a);
        assertEq(wallets.length, 20);
        assertEq(adapter.establishedWallets(a).length, 0);
    }

    function test_EstablishedWallets_EmptyWithoutDelegations() public view {
        assertEq(adapter.establishedWallets(stranger).length, 0);
    }

    function test_EstablishedWallets_CapsAtMaxCancellers() public {
        for (uint256 i; i < 20; ++i) {
            _consolidate(a, address(uint160(0x1000 + i)));
        }
        vm.warp(block.timestamp + 30 days);
        address[] memory wallets = adapter.establishedWallets(a);
        assertEq(wallets.length, Limits.MAX_CANCELLERS);
        assertEq(wallets[15], address(uint160(0x1000 + 15)));
    }

    /// @dev Appended entries stay behind earlier ones until a revocation reorders the list
    ///      (swap-and-pop, PoC-2); the registry's standing snapshot, not this order, protects
    ///      the artist's wallets.
    function test_EstablishedWallets_AppendsStayBehindUntilARevocation() public {
        address tail = makeAddr("tail");
        _consolidate(a, b);
        for (uint256 i; i < 40; ++i) {
            _delegate(a, address(uint160(0x2000 + i)), FAR);
        }
        _consolidate(a, tail);
        vm.warp(block.timestamp + 30 days);
        address[] memory wallets = adapter.establishedWallets(a);
        assertEq(wallets.length, 1);
        assertEq(wallets[0], b);
        _revoke(a, b);
        wallets = adapter.establishedWallets(a);
        assertEq(wallets.length, 1);
        assertEq(wallets[0], tail, "the tail moved into the revoked slot");
    }

    /// @dev L1: a use-case-998 sub-delegate of `a` can write `a`'s consolidation registrations, so
    ///      it can make a wallet established for `a` without `a`'s key.
    function test_IsEstablished_SubDelegateCanEstablishAWallet() public {
        address subDelegate = makeAddr("subDelegate");
        vm.prank(a);
        delegation.registerDelegationAddress(ALL, subDelegate, FAR, 998, true, 0);
        vm.prank(subDelegate);
        delegation.registerDelegationAddressUsingSubDelegation(
            a, ALL, b, FAR, CONSOLIDATION, true, 0
        );
        _delegate(b, a, FAR);
        vm.warp(block.timestamp + 30 days);
        assertTrue(adapter.isEstablished(a, b));
        vm.prank(stranger);
        vm.expectRevert();
        delegation.registerDelegationAddressUsingSubDelegation(
            a, ALL, stranger, FAR, CONSOLIDATION, true, 0
        );
    }

    function test_EstablishedWallets_ScansAtMostMaxDelegates() public {
        for (uint256 i; i < adapter.MAX_DELEGATES_SCANNED(); ++i) {
            _delegate(a, address(uint160(0x2000 + i)), FAR);
        }
        _consolidate(a, b);
        vm.warp(block.timestamp + 30 days);
        assertTrue(adapter.isEstablished(a, b));
        assertEq(adapter.establishedWallets(a).length, 0);
    }

    /// @dev A caller cannot starve the reads to truncate a walk: a shortfall reverts.
    function test_Reads_RevertWhenGasCannotBeForwarded() public {
        _consolidate(a, b);
        vm.warp(block.timestamp + 30 days);
        (bool ok, bytes memory data) = address(adapter).staticcall{ gas: 45_000 }(
            abi.encodeCall(ConsolidationAdapter.isEstablished, (a, b))
        );
        assertFalse(ok);
        assertEq(
            data,
            abi.encodeWithSelector(
                BoundedCall.BoundedCallInsufficientGas.selector, adapter.READ_GAS()
            )
        );
    }

    /// @dev Worst case for `establishedWallets` (PoC-6): 32 distinct cold delegates, each with one
    ///      aged forward registration and four expired reverse ones, so every entry costs six
    ///      cold reads and none is established.
    function test_EstablishedWallets_WorstCaseGas() public {
        for (uint256 i; i < adapter.MAX_DELEGATES_SCANNED(); ++i) {
            address w = address(uint160(0x7000 + i));
            _delegate(a, w, FAR);
            for (uint256 j; j < adapter.MAX_REGISTRATIONS_READ(); ++j) {
                _delegate(w, a, block.timestamp + 1);
            }
        }
        vm.warp(block.timestamp + 30 days);
        vm.cool(address(delegation));
        uint256 before = gasleft();
        assertEq(adapter.establishedWallets(a).length, 0);
        uint256 used = before - gasleft();
        emit log_named_uint("establishedWallets all-cold worst-case gas", used);
        assertLt(used, 3_500_000);
    }
}
