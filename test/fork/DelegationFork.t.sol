// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ConsolidationAdapter, IDelegationManagement } from "src/identity/ConsolidationAdapter.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { DeployGuards } from "script/DeployGuards.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { WorksForkBase } from "./WorksForkBase.sol";

/// @notice The real 6529 delegation contract, read through the real `ConsolidationAdapter` that
///         `DeployV1` deploys: two-way, one-way, specific-collection and expired registrations,
///         revocation, a consolidated wallet acting for an account, and the identity lane's mock
///         checked against the real contract.
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

    /// @dev A two-way, all-collections consolidation counts at once (no minimum age), and the
    ///      contract's own `checkConsolidationStatus` agrees.
    function test_AdapterReadsALiveTwoWayConsolidation() public onFork {
        address a = makeAddr("forkConsolidatorA");
        address b = makeAddr("forkConsolidatorB");
        _register(delegation, a, b, type(uint64).max);
        assertFalse(consolidation.isConsolidated(a, b), "one way");
        _register(delegation, b, a, type(uint64).max);
        assertTrue(consolidation.isConsolidated(a, b));
        assertTrue(consolidation.isConsolidated(b, a), "symmetric");
        assertTrue(delegation.checkConsolidationStatus(a, b, ALL), "the contract agrees");
    }

    /// @dev A specific-collection consolidation and an expired one do not count, although the
    ///      contract's own check reports the specific one.
    function test_SpecificOrExpiredDoesNotCount() public onFork {
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
        assertFalse(consolidation.isConsolidated(c, d), "the adapter does not");

        address e = makeAddr("forkExpiringE");
        address f = makeAddr("forkExpiringF");
        _consolidate(delegation, e, f, block.timestamp + 10 days);
        assertTrue(consolidation.isConsolidated(e, f));
        vm.warp(block.timestamp + 10 days);
        assertFalse(consolidation.isConsolidated(e, f), "expired");
    }

    /// @dev A revocation deletes the pair's registrations: the consolidation ends at once.
    function test_RevocationEndsTheConsolidation() public onFork {
        address a = makeAddr("forkRevokeA");
        address b = makeAddr("forkRevokeB");
        _consolidate(delegation, a, b, type(uint64).max);
        assertTrue(consolidation.isConsolidated(a, b));
        vm.prank(b);
        delegation.revokeDelegationAddress(ALL, a, CONSOLIDATION);
        assertFalse(consolidation.isConsolidated(a, b));
    }

    /// @dev The identity lane's reduction (the integration mock) answers as the real contract
    ///      does for the same history: registrations, revocations, re-registrations, expiries.
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
        for (uint256 i; i < 5; ++i) {
            assertEq(
                consolidation.isConsolidated(a, w[i]), mirror.isConsolidated(a, w[i]), "a pair"
            );
            assertEq(
                delegation.checkConsolidationStatus(a, w[i], ALL),
                local.checkConsolidationStatus(a, w[i], ALL),
                "the vendored status"
            );
        }
    }

    /// @dev On the real contract, a wallet consolidated with the artist's root acts for the
    ///      account at once: it moves the root to itself, executed after the 2-day wait.
    function test_AConsolidatedWalletActsForTheAccountOnTheRealContract() public onFork {
        address artist = _actor("forkArtist");
        address wallet = _actor("forkArtistWallet");
        _publish(_one(_work(artist, collectionId)));
        uint256 id = artists.artistIdOf(artist);
        assertEq(id, uint160(artist));
        assertFalse(artists.isWallet(id, wallet));
        _consolidate(delegation, artist, wallet, type(uint64).max);
        assertTrue(artists.isWallet(id, wallet));

        ArtistIdentity memory identity =
            ArtistIdentity(wallet, wallet, _profileId(artist), _profileDoc(artist));
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = artists.changeDigest(id, identity, artists.changeNonce(id), deadline);
        artists.stageChange(id, identity, deadline, abi.encodePacked(wallet, _sign(wallet, digest)));
        vm.warp(block.timestamp + 2 days);
        artists.executeChange(id);
        assertEq(artists.authorityOf(id), wallet, "the root moved to the consolidated wallet");
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
