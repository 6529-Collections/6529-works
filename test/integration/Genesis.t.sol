// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_EDITIONS,
    PRODUCT_STREAM
} from "src/interfaces/types/EconomicsTypes.sol";
import { IntegrationBase } from "./IntegrationBase.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";

/// @notice Flow 7 (integration brief, lane B): genesis on the real contracts. The whole system is
///         deployed, configured and wired from `config/genesis.example.json`; the network
///         accepts; the configurator's readback passes; the configurator keeps nothing; the
///         network cancels its own scheduled operations, a brake delays one once, and a handover
///         leaves the old address with nothing.
contract GenesisFlowTest is IntegrationBase {
    address internal attacker = makeAddr("attacker");

    function test_WiringIsInPlaceAndTheReadbackPasses() public {
        // One-shot binds.
        assertEq(stream.workRecords(), address(records), "Stream -> WorkRecords");
        assertEq(stream.editions(), address(editions), "Stream -> Editions");
        assertEq(editions.workRecords(), address(records), "Editions -> WorkRecords");
        assertEq(registry.stream(), address(stream), "PackageRegistry -> Stream");
        assertEq(registry.editions(), address(editions), "PackageRegistry -> Editions");
        assertEq(artists.packageRegistry(), address(registry), "ArtistRegistry -> registry");
        assertEq(artists.stream(), address(stream), "ArtistRegistry -> Stream");
        assertEq(artists.splitFactory(), address(splitFactory), "ArtistRegistry -> factory");
        assertEq(
            artists.federationRegistry(),
            address(deployment.federationRegistry),
            "ArtistRegistry -> federation registry (ADR 0008)"
        );
        assertEq(
            auction.federationRegistry(),
            address(deployment.federationRegistry),
            "EnglishAuction -> federation registry"
        );
        // Admitted minters and sale targets.
        assertTrue(stream.isAdmittedMinter(address(auction)), "auction mints on Stream");
        assertTrue(
            editions.isAdmittedMinter(address(editionAuction)), "the edition auction mints editions"
        );
        assertFalse(editions.isAdmittedMinter(address(auction)), "the 1/1 auction does not");
        assertFalse(stream.isAdmittedMinter(address(editionAuction)), "Stream is auction-only");
        assertTrue(auction.isTarget(address(stream)), "auction sells Stream");
        assertFalse(auction.isTarget(address(editions)), "the auction does not sell editions");
        assertTrue(
            IUniformEditionAuctionLens(address(editionAuction)).isTarget(address(editions)),
            "the edition auction sells editions"
        );
        assertFalse(
            IUniformEditionAuctionLens(address(editionAuction)).isTarget(address(stream)),
            "and nothing else"
        );
        // The epoch-0 governance manifest, subject (manager, 0).
        (uint64 count,) = statements.chainOf(address(manager), 0);
        assertEq(count, 1, "the epoch-0 manifest is the manager's first statement");

        // The configurator renounced its installer record, and the readback holds.
        for (uint64 role; role < Roles.COUNT; ++role) {
            assertFalse(GovernanceConfig.hasRecord(manager, role, address(configurator)));
        }
        vm.warp(block.timestamp + manager.minSetback());
        configurator.verify(_genesisConfig());
    }

    /// @dev PLATFORM keeps its locator path and holds no sale selector: the edition auction
    ///      opens permissionlessly (ADR 0005).
    function test_PlatformHoldsItsZeroDelayPaths() public view {
        (bool immediate, uint32 delay) =
            manager.canCall(platform, address(delivery), delivery.addLocator.selector);
        assertTrue(immediate && delay == 0, "PLATFORM adds locators");
        (immediate,) = manager.canCall(attacker, address(delivery), delivery.addLocator.selector);
        assertFalse(immediate, "nobody else");
    }

    /// @dev The network cancels operations it scheduled; none can be executed afterwards.
    function test_TheNetworkCancelsItsScheduledOperations() public {
        bytes memory takeStream =
            abi.encodeCall(IAccessManager.updateAuthority, (address(stream), attacker));
        bytes memory mapCollections = abi.encodeCall(
            IAccessManager.setTargetFunctionRole,
            (address(stream), _one(stream.createCollection.selector), Roles.PUBLIC)
        );
        bytes memory admitMinter =
            abi.encodeCall(stream.setAdmittedMinter, (address(editionAuction), true));
        _schedule(hotAdmin, address(manager), takeStream);
        _schedule(hotAdmin, address(manager), mapCollections);
        _schedule(hotAdmin, address(stream), admitMinter);
        vm.startPrank(hotAdmin);
        manager.cancel(hotAdmin, address(manager), takeStream);
        manager.cancel(hotAdmin, address(manager), mapCollections);
        manager.cancel(hotAdmin, address(stream), admitMinter);
        vm.stopPrank();

        vm.warp(block.timestamp + 8 days);
        bytes[3] memory ops = [takeStream, mapCollections, admitMinter];
        address[3] memory targets = [address(manager), address(manager), address(stream)];
        for (uint256 i; i < 3; ++i) {
            bytes32 id = manager.hashOperation(hotAdmin, targets[i], ops[i]);
            vm.prank(hotAdmin);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id)
            );
            manager.execute(targets[i], ops[i]);
        }
        assertEq(stream.authority(), address(manager), "Stream stays governed");
        assertFalse(stream.isAdmittedMinter(address(editionAuction)));
    }

    /// @dev A brake the network installs (none at launch) delays a scheduled operation once by
    ///      7 days; it cannot brake it twice, and the operation then runs.
    function test_ABrakeDelaysAScheduledOperationOnce() public {
        address brake = makeAddr("brake");
        _govern(hotAdmin, address(manager), abi.encodeCall(manager.setBrake, (brake)));
        assertEq(manager.brake(), brake);
        bytes memory admitMinter =
            abi.encodeCall(stream.setAdmittedMinter, (address(editionAuction), true));
        bytes32 id = _schedule(hotAdmin, address(stream), admitMinter);
        uint48 ready = manager.getSchedule(id);
        vm.prank(brake);
        manager.brakeOnce(id);
        vm.prank(brake);
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.AlreadyBraked.selector, id));
        manager.brakeOnce(id);
        vm.warp(ready);
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                WorksAccessManager.BrakeNotElapsed.selector, id, ready + uint48(7 days)
            )
        );
        manager.execute(address(stream), admitMinter);
        vm.warp(ready + 7 days);
        vm.prank(hotAdmin);
        manager.execute(address(stream), admitMinter);
        assertTrue(stream.isAdmittedMinter(address(editionAuction)));
    }

    /// @dev The network hands over to a new address: 7 days, then the new address accepts; the
    ///      old address then holds nothing and cannot act.
    function test_TheNetworkHandsOverAndTheOldAddressHoldsNothing() public {
        address next = makeAddr("nextNetwork");
        _govern(hotAdmin, address(manager), abi.encodeCall(manager.transferNetwork, (next)));
        assertEq(manager.network(), hotAdmin, "nothing changes before acceptance");
        vm.prank(next);
        manager.acceptNetwork();
        assertEq(manager.network(), next);
        (bool isAdmin,) = manager.hasRole(Roles.ADMIN, hotAdmin);
        assertFalse(isAdmin, "the old network holds nothing");
        (bool held,) = manager.hasRole(Roles.NETWORK, next);
        assertTrue(held);
        vm.prank(hotAdmin);
        vm.expectRevert();
        manager.schedule(address(manager), abi.encodeCall(manager.setBrake, (attacker)), 0);
    }

    /// @dev Genesis wires each product's first default currency, ETH (formerly finding G-1,
    ///      fixed by #31): an item naming `CURRENCY_DEFAULT` starts in the genesis block and its
    ///      auction locks ETH.
    function test_DefaultCurrencyIsEthFromGenesis() public {
        assertEq(allowlist.defaultCurrency(PRODUCT_STREAM), CURRENCY_ETH);
        assertEq(allowlist.defaultCurrency(PRODUCT_EDITIONS), CURRENCY_ETH);
        address artist = _actor("defaultCurrencyArtist");
        Work memory w = _work(artist, collectionId);
        w.item.sale.currency = CURRENCY_DEFAULT;
        Work[] memory works = _one(w);
        bytes32 root = _publish(works);
        (uint256 saleId,) = _start(root, works, 0);
        assertEq(auction.auction(saleId).currency, CURRENCY_ETH, "locked at start");
    }

    function _one(bytes4 selector) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = selector;
    }
}

/// @notice The genesis transaction itself on the real contracts: `configure` with the committed
///         configuration and wiring, measured against the EIP-7825 transaction cap.
contract GenesisTransactionTest is IntegrationBase {
    function setUp() public override {
        deferGenesis = true;
        _deployWorks();
    }

    function test_GenesisConfigureFitsTheTransactionCap() public {
        bytes memory data = abi.encodeCall(
            configurator.configure, (_genesisConfig(), MANIFEST_HASH, _genesisWiring())
        );
        (uint256 total, uint256 execution) = _measure(address(this), address(configurator), data, 0);
        console2.log("genesis configure, execution", execution);
        console2.log("genesis configure, whole transaction", total);
        assertLt(total, TX_GAS_CAP * 60 / 100, "keep 40% headroom under the EIP-7825 cap");
        vm.prank(hotAdmin);
        manager.acceptNetwork();
        configurator.verify(_genesisConfig());
    }
}
