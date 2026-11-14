// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IWorkPowers, WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "src/interfaces/types/IdentityTypes.sol";
import { EditionTerms, ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice The renounceable powers and lower-only royalty changes on the deployed stack: the
///         real artist registry's restraint (nobody acts as the artist while an
///         authority-moving override is pending), the governed path through the AccessManager,
///         and 6529 Stream Editions following its master. `renounce` is not restricted, so the
///         genesis configuration maps no role for it.
contract WorkPowersStackTest is IntegrationBase {
    address internal constant ALL = 0x8888888888888888888888888888888888888888;
    uint256 internal constant CONSOLIDATION = 999;

    address internal artist;
    address internal newKey;
    address internal collector = makeAddr("powersCollector");
    uint256 internal artistId;
    bytes32 internal root;
    uint256 internal masterId;
    uint256 internal workId;

    function setUp() public override {
        super.setUp();
        artist = _actor("powersArtist");
        newKey = _actor("powersRecoveredKey");
        address wallet = _actor("powersArtistWallet");
        artistId = uint160(artist);
        _consolidate(artist, wallet);

        Work[] memory works = new Work[](2);
        works[0] = _work(artist, collectionId);
        works[0].item.kind = ItemKind.EDITION_MASTER;
        works[0].item.edition = EditionTerms(50, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        works[1] = _work(artist, collectionId);
        root = _publish(works);
        _keep(root, works);
        masterId = _sell(root, works, 0, collector, 1 ether);
        editions.createEdition(masterId, works[0].item, root, _proofOf(works, 0));
        records.openRecord(masterId, works[0].item, works[0].media);
        workId = _sell(root, works, 1, collector, 1 ether);
        records.openRecord(workId, works[1].item, works[1].media);
    }

    function _consolidate(address a, address b) internal {
        vm.prank(a);
        delegation.registerDelegationAddress(ALL, b, type(uint64).max, CONSOLIDATION, true, 0);
        vm.prank(b);
        delegation.registerDelegationAddress(ALL, a, type(uint64).max, CONSOLIDATION, true, 0);
    }

    /// @dev Governance stages a CONTESTED override to `newKey`, which restrains the artist.
    function _stageRecovery() internal returns (PendingChange memory p) {
        ArtistIdentity memory next =
            ArtistIdentity(newKey, newKey, _profileId(artist), _profileDoc(artist));
        bytes32 evidence = keccak256("recovery evidence, public notice");
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes memory acceptance = _sign(
            newKey, artists.overrideDigest(artistId, ChangeKind.CONTESTED, next, evidence, deadline)
        );
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(
                artists.stageOverride,
                (artistId, ChangeKind.CONTESTED, next, evidence, deadline, acceptance)
            )
        );
        p = artists.pendingChange(artistId);
        assertEq(artists.activeAuthorityOf(artistId), address(0), "restrained");
    }

    function _renounceDigest(uint256 tokenId, uint16 powers, bytes32 state, uint64 deadline)
        internal
        view
        returns (bytes32)
    {
        return _typedDigest(
            address(records),
            keccak256(abi.encode(Typehashes.RENOUNCE_POWERS, tokenId, powers, state, deadline))
        );
    }

    /// @dev The sole party signs a rate change; FUNDS_SETTER schedules and executes it.
    function _rerateCall(uint256 tokenId, uint32 rate) internal view returns (bytes memory) {
        Work memory w = _package(root)[tokenId == masterId ? 0 : 1];
        uint64 deadline = uint64(block.timestamp + 30 days);
        bytes32 state = records.workStateHash(tokenId);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(
            artist,
            _typedDigest(
                address(records),
                keccak256(
                    abi.encode(Typehashes.ROYALTY_RATE_CHANGE, tokenId, rate, state, deadline)
                )
            )
        );
        return
            abi.encodeCall(records.setRoyaltyRate, (tokenId, rate, w.item, state, deadline, sigs));
    }

    /// Regression: ADD-PWR-2
    /// @dev While a contested override is pending, neither the restrained key (whatever it
    ///      signed before) nor the reserved new key renounces. After execution the former key
    ///      is refused and the new authority renounces.
    function test_NobodyRenouncesWhileTheArtistIsRestrained() public {
        bytes32 state = records.workStateHash(workId);
        // Past the override's notice, so only the authority decides.
        uint64 deadline = uint64(block.timestamp + 365 days);
        bytes32 digest = _renounceDigest(workId, WorkPowers.ROYALTY_RATE, state, deadline);
        bytes memory oldSig = _sign(artist, digest);
        PendingChange memory p = _stageRecovery();
        bytes memory refused =
            abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, workId, 0);
        vm.expectRevert(refused);
        records.renounce(workId, WorkPowers.ROYALTY_RATE, state, deadline, oldSig);
        vm.expectRevert(refused);
        records.renounce(workId, WorkPowers.ROYALTY_RATE, state, deadline, _sign(newKey, digest));

        vm.warp(p.executableAt);
        artists.executeChange(artistId);
        assertEq(artists.activeAuthorityOf(artistId), newKey);
        vm.expectRevert(refused);
        records.renounce(workId, WorkPowers.ROYALTY_RATE, state, deadline, oldSig);
        records.renounce(workId, WorkPowers.ROYALTY_RATE, state, deadline, _sign(newKey, digest));
        assertEq(records.renouncedPowers(workId), WorkPowers.ROYALTY_RATE);
    }

    /// Regression: ADD-PWR-1
    /// @dev Through the AccessManager, the master's lower rate reaches its edition in 6529
    ///      Stream Editions; a higher rate is refused at execution.
    function test_EditionFollowsTheMastersLowerRate() public {
        _govern(hotAdmin, address(records), _rerateCall(masterId, 5_000));
        (, uint256 amount) = stream.royaltyInfo(masterId, 1 ether);
        assertEq(amount, 0.05 ether, "the master");
        (, uint256 editionAmount) = editions.royaltyInfo(masterId, 1 ether);
        assertEq(editionAmount, 0.05 ether, "the edition follows");

        bytes memory higher = _rerateCall(masterId, 6_000);
        _schedule(hotAdmin, address(records), higher);
        (, uint32 delay) = manager.canCall(hotAdmin, address(records), bytes4(higher));
        vm.warp(block.timestamp + delay);
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWorkPowers.RoyaltyRateNotLowered.selector, masterId, 5_000, 6_000
            )
        );
        manager.execute(address(records), higher);
    }

    /// Regression: ADD-PWR-2
    /// @dev Renouncing on the master fixes its edition: a scheduled rate change then fails at
    ///      execution, and the edition keeps the master's rate and license.
    function test_RenouncingOnTheMasterFixesItsEdition() public {
        bytes memory scheduled = _rerateCall(masterId, 4_000);
        _schedule(hotAdmin, address(records), scheduled);
        bytes32 state = records.workStateHash(masterId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        records.renounce(
            masterId,
            WorkPowers.ALL,
            state,
            deadline,
            _sign(artist, _renounceDigest(masterId, WorkPowers.ALL, state, deadline))
        );
        (, uint32 delay) = manager.canCall(hotAdmin, address(records), bytes4(scheduled));
        vm.warp(block.timestamp + delay);
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWorkPowers.PowerRenounced.selector, masterId, WorkPowers.ROYALTY_RATE
            )
        );
        manager.execute(address(records), scheduled);
        (, uint256 editionAmount) = editions.royaltyInfo(masterId, 1 ether);
        assertEq(editionAmount, 0.06529 ether);
        assertEq(abi.encode(editions.licenseOf(masterId)), abi.encode(records.licenseOf(masterId)));
    }
}
