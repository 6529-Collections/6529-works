// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { ReplayBase } from "./ReplayBase.sol";

/// @notice Log replay of the federation directory (ID-12, ID-13, FED-43 to FED-49, FED-64,
///         FED-65): a history that emits every event of the federation registry and every
///         directory event of the artist registry rebuilds, from those logs alone, each template
///         version, admitted adapter, listing, status, account delisting and recorded network
///         share, and the registry's derived answers (`entry`, `isActive`, `canMint`).
contract LogReplayFederationTest is ReplayBase {
    /// @dev The artist registry events this lane does not replay (identity changes, contests,
    ///      freezes and nonces): `DirectoryIndexer` fails on any of them, and none is emitted
    ///      here. `EIP712DomainChanged` is declared and never emitted. `PackageRegistrySet` is
    ///      replayed by the indexer but not exercised (it needs a successor package registry).
    function _identityEvents() internal pure returns (string[] memory l) {
        l = new string[](12);
        l[0] = "AccountFrozen(uint256,uint48)";
        l[1] = "AccountUnfrozen(uint256)";
        l[2] = "ChangeCancelled(uint256,address,bool)";
        l[3] = "ChangeContested(uint256,address,bytes32)";
        l[4] =
            "ChangeExecuted(uint256,(address,address,bytes32,bytes32),(address,address,bytes32,bytes32))";
        l[5] =
            "ChangeStaged(uint256,(uint8,uint48,uint48,(address,address,bytes32,bytes32),bytes32,bytes32))";
        l[6] = "ContestExpired(uint256)";
        l[7] = "ContestResolved(uint256,bool,bool,bytes32)";
        l[8] = "NonceRevoked(uint256,uint256)";
        l[9] = "ReplacementAcceptanceConsumed(uint256,bytes32)";
        l[10] = "EIP712DomainChanged()";
        l[11] = "PackageRegistrySet(address,address)";
    }

    function test_EveryFederationEventReplaysToTheSameState() public {
        _joinedFed();
        address second = _actor("secondFederatedArtist");
        (FederatedStream pairStream, FederatedEditions pairEditions) = _pair(second);
        _sync();

        // The network delists one token, then the whole account, and relists both (ID-13, C5).
        _setListing(address(fed), IFederationRegistry.Status.DELISTED);
        uint256 secondId = artists.artistIdOf(second);
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.setFederationDelisted, (secondId, true, "account decision"))
        );
        _sync();
        assertFalse(fedRegistry.isActive(address(pairStream)));
        _setListing(address(fed), IFederationRegistry.Status.ACTIVE);
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.setFederationDelisted, (secondId, false, "relisted"))
        );
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.lowerFederatedFeeShare, (address(pairEditions), FED_SHARE / 2))
        );
        _sync();

        // Every template transition (FED-44 to FED-46, C26) and an adapter removed and restored.
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.suspendTemplate, (streamHash))
        );
        _sync();
        _govern(
            hotAdmin, address(fedRegistry), abi.encodeCall(fedRegistry.resumeTemplate, (streamHash))
        );
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.revokeTemplate, (editionsHash))
        );
        _sync();
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.reinstateTemplate, (editionsHash))
        );
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setAdapter, (address(auction), false))
        );
        _sync();
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setAdapter, (address(auction), true))
        );

        // A replacement registry, then the original again: the directory stays (ID-12).
        FederationRegistry next = new FederationRegistry(
            address(manager), address(artists), address(economics), address(store)
        );
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.setFederationRegistry, (address(fedRegistry), address(next)))
        );
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.setFederationRegistry, (address(next), address(fedRegistry)))
        );
        _sync();
        _assertEveryEventReplayed("FederationRegistry", fedIdx, new string[](0));
        _assertEveryEventReplayed("ArtistRegistry", directoryIdx, _identityEvents());
    }

    /// @dev Negative control: slot 2 holds the admitted adapters; one admitted with no
    ///      `AdapterSet` makes the comparison fail.
    function test_RegistryIndexerDetectsStateThatLogsDoNotExplain() public {
        _joinedFed();
        _sync();
        vm.store(address(fedRegistry), keccak256(abi.encode(address(auction), uint256(2))), 0);
        vm.expectRevert();
        fedIdx.assertMatches();
    }

    /// @dev Negative control: slot 6 holds the listings; a recorded share no log lowered.
    function test_DirectoryIndexerDetectsStateThatLogsDoNotExplain() public {
        _joinedFed();
        _sync();
        bytes32 slot = keccak256(abi.encode(address(fed), uint256(6)));
        bytes32 word = vm.load(address(artists), slot);
        vm.store(address(artists), slot, word ^ bytes32(uint256(1) << 168));
        vm.expectRevert();
        directoryIdx.assertMatches();
    }
}
