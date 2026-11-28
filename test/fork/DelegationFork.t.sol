// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { DeployGuards } from "script/DeployGuards.sol";
import { ConsolidationAdapter, IDelegationManagement } from "src/identity/ConsolidationAdapter.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { CoreForkBase } from "./StreamForkBase.sol";

/// @notice The real 6529 delegation contract, read through the `ConsolidationAdapter` that
///         `DeployCore` deploys and the `Accounts` module that asks it: a two-way,
///         all-collections consolidation counts at once; one-way, specific-collection and
///         expired registrations do not; revocation ends it; the read is bounded to
///         `MAX_REGISTRATIONS_READ` registrations per direction; the identity lane's mock
///         answers as the real contract for the same history; and a consolidated wallet acts
///         for an artist's account (it signs the artist's move, and moves the root to itself).
abstract contract DelegationForkTests is CoreForkBase {
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

    /// @notice The deployment reads the canonical delegation code through its adapter.
    function test_Delegation_TheContractIsTheCanonicalCode() public view {
        assertEq(_delegationAddress().codehash, DeployGuards.CANONICAL_DELEGATION_CODEHASH);
        assertEq(address(consolidation.delegation()), _delegationAddress());
        assertEq(address(accounts.consolidationSource()), address(consolidation));
    }

    /// @notice A two-way, all-collections consolidation counts at once (no minimum age), and
    ///         the contract's own `checkConsolidationStatus` agrees; one way does not count.
    function test_Delegation_AdapterReadsALiveTwoWayConsolidation() public {
        address a = makeAddr("forkConsolidatorA");
        address b = makeAddr("forkConsolidatorB");
        _register(delegation, a, b, type(uint64).max);
        assertFalse(consolidation.isConsolidated(a, b), "one way");
        _register(delegation, b, a, type(uint64).max);
        assertTrue(consolidation.isConsolidated(a, b));
        assertTrue(consolidation.isConsolidated(b, a), "symmetric");
        assertTrue(delegation.checkConsolidationStatus(a, b, ALL), "the contract agrees");
    }

    /// @notice A specific-collection consolidation and an expired one do not count, although
    ///         the contract's own check reports the specific one.
    function test_Delegation_SpecificOrExpiredDoesNotCount() public {
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

    /// @notice A revocation deletes the pair's registrations: the consolidation ends at once.
    function test_Delegation_RevocationEndsTheConsolidation() public {
        address a = makeAddr("forkRevokeA");
        address b = makeAddr("forkRevokeB");
        _consolidate(delegation, a, b, type(uint64).max);
        assertTrue(consolidation.isConsolidated(a, b));
        vm.prank(b);
        delegation.revokeDelegationAddress(ALL, a, CONSOLIDATION);
        assertFalse(consolidation.isConsolidated(a, b));
    }

    /// @notice The adapter reads at most `MAX_REGISTRATIONS_READ` registrations of a pair per
    ///         direction: a live registration behind that many expired ones is not read.
    function test_Delegation_TheReadIsBounded() public {
        address a = makeAddr("forkBoundA");
        address b = makeAddr("forkBoundB");
        uint256 bound = consolidation.MAX_REGISTRATIONS_READ();
        _register(delegation, b, a, type(uint64).max);
        for (uint256 i; i < bound - 1; ++i) {
            _register(delegation, a, b, block.timestamp + 1 days);
        }
        _register(delegation, a, b, type(uint64).max);
        vm.warp(block.timestamp + 2 days);
        assertTrue(consolidation.isConsolidated(a, b), "the last read registration is live");

        address c = makeAddr("forkBoundC");
        _register(delegation, c, a, type(uint64).max);
        for (uint256 i; i < bound; ++i) {
            _register(delegation, a, c, block.timestamp + 1 days);
        }
        _register(delegation, a, c, type(uint64).max);
        vm.warp(block.timestamp + 2 days);
        assertFalse(consolidation.isConsolidated(a, c), "past the bound");
        assertTrue(delegation.checkConsolidationStatus(a, c, ALL), "the contract still counts it");
    }

    /// @notice The identity lane's reduction (the integration mock) answers as the real
    ///         contract does for the same history: registrations, revocations,
    ///         re-registrations, expiries.
    function test_Delegation_TheMockMatchesTheRealContract() public {
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

    /// @notice A wallet consolidated with the artist's root on the real contract signs the
    ///         artist's move, which starts the work; without the consolidation the same proof
    ///         is refused.
    function test_Delegation_AConsolidatedWalletSignsTheArtistsMove() public {
        address artist = _actor("forkMoveArtist");
        address wallet = _actor("forkMoveWallet");
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        uint256 id = accounts.artistIdOf(artist);
        bytes memory request = _mintDataSignedBy(root, works, 0, wallet, 0);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, wallet));
        auction.start(address(stream), request);

        _consolidate(delegation, artist, wallet, type(uint64).max);
        assertTrue(accounts.isWallet(id, wallet));
        auction.start(address(stream), request);
        assertEq(stream.workOf(stream.totalMinted()).artistId, id);
    }

    /// @notice On the real contract, a wallet consolidated with the artist's root moves the
    ///         root to itself, executed after the own-change delay.
    function test_Delegation_AConsolidatedWalletMovesTheRoot() public {
        address artist = _actor("forkArtist");
        address wallet = _actor("forkArtistWallet");
        _publish(_one(_work(artist, collectionId)));
        uint256 id = accounts.artistIdOf(artist);
        assertEq(id, uint160(artist));
        assertFalse(accounts.isWallet(id, wallet));
        _consolidate(delegation, artist, wallet, type(uint64).max);
        assertTrue(accounts.isWallet(id, wallet));

        ArtistIdentity memory identity =
            ArtistIdentity(wallet, wallet, _profileId(artist), _profileDoc(artist));
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = accounts.changeDigest(id, identity, accounts.changeNonce(id), deadline);
        accounts.stageChange(
            id, identity, deadline, abi.encodePacked(wallet, _sign(wallet, digest))
        );
        vm.warp(block.timestamp + accounts.OWN_CHANGE_DELAY());
        accounts.executeChange(id);
        assertEq(accounts.authorityOf(id), wallet, "the root moved to the consolidated wallet");
    }
}

/// @dev Gated by `FORK_MAINNET_RPC`: the canonical contract at
///      `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`.
contract DelegationMainnetForkTest is DelegationForkTests {
    function _rpcVar() internal pure override returns (string memory) {
        return "FORK_MAINNET_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return MAINNET;
    }
}

/// @dev Gated by `FORK_SEPOLIA_RPC`: the official Sepolia deployment at
///      `0x8f86c644f845A077999939C69Bc787662377d915` (byte-identical runtime code).
contract DelegationSepoliaForkTest is DelegationForkTests {
    function _rpcVar() internal pure override returns (string memory) {
        return "FORK_SEPOLIA_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return SEPOLIA;
    }
}
