// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ConsolidationAdapter, IDelegationManagement } from "src/identity/ConsolidationAdapter.sol";
import { ArtistIdentity, Standing } from "src/interfaces/types/IdentityTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { DeployGuards } from "script/DeployGuards.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { WorksForkBase } from "./WorksForkBase.sol";

/// @notice The real 6529 delegation contract, read through the real `ConsolidationAdapter` that
///         `DeployV1` deploys: consolidation age and expiry, one-way and specific-collection
///         registrations, revocation, a full bounded scan, the artist registry's standing and a
///         recovery signer, and the identity lane's mock checked against the real contract.
abstract contract DelegationForkTests is WorksForkBase {
    address internal constant ALL = 0x8888888888888888888888888888888888888888;
    uint256 internal constant CONSOLIDATION = 999;

    function _register(DelegationManagementMock d, address from, address to, uint256 expiry)
        internal
    {
        vm.prank(from);
        d.registerDelegationAddress(ALL, to, expiry, CONSOLIDATION, true, 0);
    }

    function _consolidate(DelegationManagementMock d, address a, address b, uint256 expiry)
        internal
    {
        _register(d, a, b, expiry);
        _register(d, b, a, expiry);
    }

    function test_TheDelegationContractIsTheCanonicalCode() public onFork {
        assertEq(_delegationAddress().codehash, DeployGuards.CANONICAL_DELEGATION_CODEHASH);
        assertEq(address(consolidation.delegation()), _delegationAddress());
        assertEq(address(artists.consolidationSource()), address(consolidation));
    }

    /// @dev A two-way, all-collections consolidation counts from the later registration, and is
    ///      established 30 days after it. The contract's own `checkConsolidationStatus`, which
    ///      ignores age, agrees on presence.
    function test_AdapterReadsALiveTwoWayConsolidation() public onFork {
        address a = makeAddr("forkConsolidatorA");
        address b = makeAddr("forkConsolidatorB");
        _register(delegation, a, b, type(uint64).max);
        vm.warp(block.timestamp + 1 hours);
        _register(delegation, b, a, type(uint64).max);
        uint256 effective = block.timestamp + 30 days;
        assertEq(consolidation.effectiveAt(a, b), effective, "from the later registration");
        assertEq(consolidation.effectiveAt(b, a), effective, "symmetric");
        assertFalse(consolidation.isEstablished(a, b), "not before 30 days");
        (address[] memory wallets, uint64[] memory times) = consolidation.consolidations(a);
        assertEq(wallets.length, 1);
        assertEq(wallets[0], b);
        assertEq(times[0], effective);
        assertEq(consolidation.establishedWallets(a).length, 0);
        assertTrue(delegation.checkConsolidationStatus(a, b, ALL), "the contract agrees");

        vm.warp(effective);
        assertTrue(consolidation.isEstablished(a, b));
        assertTrue(consolidation.isEstablished(b, a));
        assertEq(consolidation.establishedWallets(a)[0], b);
    }

    /// @dev A one-way registration, a specific-collection consolidation and an expired one do
    ///      not count, although the contract's own check reports the specific one.
    function test_OneWaySpecificOrExpiredDoesNotCount() public onFork {
        address a = makeAddr("forkOneWayA");
        address b = makeAddr("forkOneWayB");
        _register(delegation, a, b, type(uint64).max);
        assertEq(consolidation.effectiveAt(a, b), 0, "one way");
        assertFalse(delegation.checkConsolidationStatus(a, b, ALL));

        address collection = makeAddr("forkSpecificCollection");
        address c = makeAddr("forkSpecificC");
        address d = makeAddr("forkSpecificD");
        vm.prank(c);
        delegation.registerDelegationAddress(
            collection, d, type(uint64).max, CONSOLIDATION, true, 0
        );
        vm.prank(d);
        delegation.registerDelegationAddress(
            collection, c, type(uint64).max, CONSOLIDATION, true, 0
        );
        assertTrue(delegation.checkConsolidationStatus(c, d, collection), "the contract counts it");
        assertEq(consolidation.effectiveAt(c, d), 0, "the adapter does not");

        address e = makeAddr("forkExpiringE");
        address f = makeAddr("forkExpiringF");
        _consolidate(delegation, e, f, block.timestamp + 40 days);
        uint256 effective = block.timestamp + 30 days;
        assertEq(consolidation.effectiveAt(e, f), effective);
        vm.warp(effective);
        assertTrue(consolidation.isEstablished(e, f));
        vm.warp(effective + 10 days);
        assertEq(consolidation.effectiveAt(e, f), 0, "expired");
        assertFalse(consolidation.isEstablished(e, f));
    }

    /// @dev A revocation deletes the pair's registrations: the consolidation ends at once, and
    ///      a re-registration starts its 30 days again.
    function test_RevocationEndsTheConsolidation() public onFork {
        address a = makeAddr("forkRevokeA");
        address b = makeAddr("forkRevokeB");
        _consolidate(delegation, a, b, type(uint64).max);
        vm.warp(block.timestamp + 31 days);
        assertTrue(consolidation.isEstablished(a, b));
        vm.prank(b);
        delegation.revokeDelegationAddress(ALL, a, CONSOLIDATION);
        assertEq(consolidation.effectiveAt(a, b), 0);
        (address[] memory wallets,) = consolidation.consolidations(a);
        assertEq(wallets.length, 0);
        _register(delegation, b, a, type(uint64).max);
        assertEq(consolidation.effectiveAt(a, b), block.timestamp + 30 days, "the clock restarts");
    }

    /// @dev The adapter's bounded scan over the real contract's getters fits its read stipend:
    ///      an account with more delegates than it scans, some of them two-way.
    function test_AFullScanFitsTheReadStipend() public onFork {
        address a = makeAddr("forkScanner");
        uint256 scanned = consolidation.MAX_DELEGATES_SCANNED();
        for (uint256 i; i < scanned + 2; ++i) {
            address wallet = makeAddr(string.concat("forkScanned", vm.toString(i)));
            _register(delegation, a, wallet, type(uint64).max);
            if (i % 2 == 0) _register(delegation, wallet, a, type(uint64).max);
        }
        uint256 before = gasleft();
        (address[] memory wallets,) = consolidation.consolidations(a);
        uint256 used = before - gasleft();
        assertEq(wallets.length, scanned / 2, "every two-way delegate among those scanned");
        assertLt(used, 16_777_216, "a scan fits the transaction gas cap");
        vm.warp(block.timestamp + 30 days);
        assertEq(consolidation.establishedWallets(a).length, Limits.MAX_CANCELLERS);
    }

    /// @dev The identity lane's reduction (the integration mock) answers as the real contract
    ///      does for the same history: registrations, revocations (swap-and-pop order),
    ///      re-registrations and expiries.
    function test_TheReductionMatchesTheRealContract() public onFork {
        DelegationManagementMock local = new DelegationManagementMock();
        ConsolidationAdapter mirror =
            new ConsolidationAdapter(IDelegationManagement(address(local)));
        address a = makeAddr("forkDiffA");
        address[5] memory w;
        for (uint256 i; i < 5; ++i) {
            w[i] = makeAddr(string.concat("forkDiffWallet", vm.toString(i)));
        }
        DelegationManagementMock[2] memory both = [delegation, local];
        for (uint256 k; k < 2; ++k) {
            _consolidate(both[k], a, w[0], type(uint64).max);
            _consolidate(both[k], a, w[1], block.timestamp + 20 days);
            _register(both[k], a, w[2], type(uint64).max);
            _consolidate(both[k], a, w[3], type(uint64).max);
            _consolidate(both[k], a, w[4], type(uint64).max);
            vm.prank(a);
            both[k].revokeDelegationAddress(ALL, w[0], CONSOLIDATION);
            _register(both[k], a, w[0], type(uint64).max);
        }
        _assertSame(local, mirror, a, w);
        vm.warp(block.timestamp + 25 days);
        _assertSame(local, mirror, a, w);
        vm.warp(block.timestamp + 10 days);
        _assertSame(local, mirror, a, w);
    }

    function _assertSame(
        DelegationManagementMock local,
        ConsolidationAdapter mirror,
        address a,
        address[5] memory w
    ) internal view {
        assertEq(
            delegation.retrieveDelegationAddresses(a, ALL, CONSOLIDATION),
            local.retrieveDelegationAddresses(a, ALL, CONSOLIDATION),
            "the delegate list, in order"
        );
        (address[] memory realWallets, uint64[] memory realTimes) = consolidation.consolidations(a);
        (address[] memory mockWallets, uint64[] memory mockTimes) = mirror.consolidations(a);
        assertEq(realWallets, mockWallets, "consolidated wallets");
        assertEq(realTimes.length, mockTimes.length);
        for (uint256 i; i < realTimes.length; ++i) {
            assertEq(realTimes[i], mockTimes[i], "effective times");
        }
        for (uint256 i; i < 5; ++i) {
            assertEq(consolidation.effectiveAt(a, w[i]), mirror.effectiveAt(a, w[i]), "a pair");
            assertEq(
                delegation.checkConsolidationStatus(a, w[i], ALL),
                local.checkConsolidationStatus(a, w[i], ALL),
                "the vendored status"
            );
        }
    }

    /// @dev Recovery through 6529 consolidation on the real contract: the artist registry
    ///      records the artist's consolidated wallet as standing, and that wallet, established
    ///      for 30 days, signs a STANDARD change to a new key that executes after its 7 days.
    function test_AnEstablishedWalletSignsARecoveryOnTheRealContract() public onFork {
        address artist = _actor("forkArtist");
        address wallet = _actor("forkArtistWallet");
        address next = _actor("forkArtistNewKey");
        _publish(_one(_work(artist, collectionId)));
        uint256 id = artists.artistIdOf(artist);
        assertEq(id, uint160(artist));
        _consolidate(delegation, artist, wallet, type(uint64).max);
        vm.warp(block.timestamp + 31 days);
        artists.refreshStanding(id);
        Standing[] memory standing = artists.standingOf(id);
        assertEq(standing.length, 1);
        assertEq(standing[0].wallet, wallet);

        ArtistIdentity memory identity =
            ArtistIdentity(next, next, _profileId(artist), _profileDoc(artist));
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = artists.changeDigest(id, identity, artists.changeNonce(id), deadline);
        artists.stageChange(
            id, identity, wallet, deadline, _sign(wallet, digest), _sign(next, digest)
        );
        vm.warp(block.timestamp + artists.CHANGE_DELAY());
        artists.executeChange(id);
        assertEq(artists.authorityOf(id), next, "recovered through the consolidated wallet");
    }
}

contract DelegationMainnetForkTest is DelegationForkTests {
    function _rpcVar() internal pure override returns (string memory) {
        return "FORK_MAINNET_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return MAINNET;
    }
}

contract DelegationSepoliaForkTest is DelegationForkTests {
    function _rpcVar() internal pure override returns (string memory) {
        return "FORK_SEPOLIA_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return SEPOLIA;
    }
}
