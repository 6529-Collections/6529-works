// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IWorkPowers, WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionTerms, ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice The renounceable powers and royalty changes on the deployed stack: the governed path
///         through the AccessManager and 6529 Stream Editions following its master. Renouncing
///         the royalty or licence power is relayed by the network (C7), so the genesis
///         configuration maps `renounce` to the 24-hour class.
contract WorkPowersStackTest is IntegrationBase {
    address internal constant ALL = 0x8888888888888888888888888888888888888888;
    uint256 internal constant CONSOLIDATION = 999;

    address internal artist;
    address internal collector = makeAddr("powersCollector");
    uint256 internal artistId;
    bytes32 internal root;
    uint256 internal masterId;
    uint256 internal workId;

    function setUp() public override {
        super.setUp();
        artist = _actor("powersArtist");
        address wallet = _actor("powersArtistWallet");
        artistId = uint160(artist);
        _consolidate(artist, wallet);

        Work[] memory works = new Work[](2);
        works[0] = _work(artist, collectionId);
        works[0].item.kind = uint8(ItemKind.EDITION_MASTER);
        works[0].item.edition = EditionTerms(50, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        works[1] = _work(artist, collectionId);
        root = _publish(works);
        _keep(root, works);
        masterId = _sell(root, works, 0, collector, 1 ether);
        editions.createEdition(masterId, works[0].item);
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
        sigs[0] = abi.encodePacked(
            artist,
            _sign(
                artist,
                _typedDigest(
                    address(records),
                    keccak256(
                        abi.encode(Typehashes.ROYALTY_RATE_CHANGE, tokenId, rate, state, deadline)
                    )
                )
            )
        );
        return
            abi.encodeCall(records.setRoyaltyRate, (tokenId, rate, w.item, state, deadline, sigs));
    }

    /// Regression: ADD-PWR-1
    /// @dev Through the AccessManager, the master's new rate reaches its edition in 6529 Stream
    ///      Editions, down and then up (R10).
    function test_EditionFollowsTheMastersRate() public {
        _govern(hotAdmin, address(records), _rerateCall(masterId, 5_000));
        (, uint256 amount) = stream.royaltyInfo(masterId, 1 ether);
        assertEq(amount, 0.05 ether, "the master");
        (, uint256 editionAmount) = editions.royaltyInfo(masterId, 1 ether);
        assertEq(editionAmount, 0.05 ether, "the edition follows");
        _govern(hotAdmin, address(records), _rerateCall(masterId, 6_000));
        (, editionAmount) = editions.royaltyInfo(masterId, 1 ether);
        assertEq(editionAmount, 0.06 ether, "the edition follows a rise");
    }

    /// Regression: ADD-PWR-2
    /// @dev Renouncing on the master fixes its edition: a scheduled rate change then fails at
    ///      execution, and the edition keeps the master's rate and license.
    function test_RenouncingOnTheMasterFixesItsEdition() public {
        bytes memory scheduled = _rerateCall(masterId, 4_000);
        _schedule(hotAdmin, address(records), scheduled);
        bytes32 state = records.workStateHash(masterId);
        uint64 deadline = uint64(block.timestamp + 30 days);
        uint16 powers = WorkPowers.ROYALTY_RATE | WorkPowers.RELICENSE;
        bytes memory proof = abi.encodePacked(
            artist, _sign(artist, _renounceDigest(masterId, powers, state, deadline))
        );
        // C7: the network relays a renunciation of the royalty or licence power.
        _govern(
            hotAdmin,
            address(records),
            abi.encodeCall(records.renounce, (masterId, powers, state, deadline, proof))
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
