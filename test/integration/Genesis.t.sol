// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_EDITIONS,
    PRODUCT_STREAM
} from "src/interfaces/types/EconomicsTypes.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Flow 7 (integration brief, lane B): genesis on the real contracts. The whole system is
///         deployed, configured and wired from `config/genesis.example.json`; the configurator's
///         readback passes; the configurator keeps no ADMIN; and guardians can cancel a hostile
///         admin operation on the live system.
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
        assertEq(artists.federationRegistry(), address(0), "federation is deferred (v1.1)");
        // Admitted minters and sale targets.
        assertTrue(stream.isAdmittedMinter(address(auction)), "auction mints on Stream");
        assertTrue(
            editions.isAdmittedMinter(address(editionAuction)), "the edition auction mints editions"
        );
        assertFalse(editions.isAdmittedMinter(address(auction)), "the 1/1 auction does not");
        assertFalse(stream.isAdmittedMinter(address(editionAuction)), "Stream is auction-only");
        assertTrue(auction.isTarget(address(stream)), "auction sells Stream");
        assertFalse(auction.isTarget(address(editions)), "the auction does not sell editions");
        assertTrue(editionAuction.isTarget(address(editions)), "the edition auction sells editions");
        assertFalse(editionAuction.isTarget(address(stream)), "and nothing else");
        // The epoch-0 governance manifest, subject (manager, 0).
        (uint64 count,) = statements.chainOf(address(manager), 0);
        assertEq(count, 1, "the epoch-0 manifest is the manager's first statement");

        // The configurator renounced ADMIN, and the readback holds once the delays settle.
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
            manager.canCall(platform, address(records), records.addLocator.selector);
        assertTrue(immediate && delay == 0, "PLATFORM adds locators");
        (immediate,) = manager.canCall(attacker, address(records), records.addLocator.selector);
        assertFalse(immediate, "nobody else");
    }

    /// @dev A compromised hot admin schedules four hostile operations; the guardians cancel each,
    ///      and none can be executed after its delay.
    function test_GuardiansCancelHostileAdminOperations() public {
        bytes memory takeStream =
            abi.encodeCall(IAccessManager.updateAuthority, (address(stream), attacker));
        bytes memory mapCollections = abi.encodeCall(
            IAccessManager.setTargetFunctionRole,
            (address(stream), _one(stream.createCollection.selector), Roles.PUBLIC)
        );
        bytes memory admitMinter =
            abi.encodeCall(stream.setAdmittedMinter, (address(editionAuction), true));
        bytes memory dropGuardian =
            abi.encodeCall(IAccessManager.revokeRole, (Roles.GUARDIAN, guardian1));

        _schedule(hotAdmin, address(manager), takeStream);
        _schedule(hotAdmin, address(manager), mapCollections);
        _schedule(hotAdmin, address(stream), admitMinter);
        _schedule(hotAdmin, address(manager), dropGuardian);

        vm.prank(guardian1);
        manager.cancel(hotAdmin, address(manager), takeStream);
        vm.prank(guardian2);
        manager.cancel(hotAdmin, address(manager), mapCollections);
        vm.prank(guardian3);
        manager.cancel(hotAdmin, address(stream), admitMinter);
        // ADR 0002 rule 2: guardian 1 cannot cancel its own removal; another guardian can.
        vm.prank(guardian1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCancel.selector,
                guardian1,
                hotAdmin,
                address(manager),
                IAccessManager.revokeRole.selector
            )
        );
        manager.cancel(hotAdmin, address(manager), dropGuardian);
        vm.prank(guardian2);
        manager.cancel(hotAdmin, address(manager), dropGuardian);

        vm.warp(block.timestamp + 31 days);
        bytes[4] memory ops = [takeStream, mapCollections, admitMinter, dropGuardian];
        address[4] memory targets =
            [address(manager), address(manager), address(stream), address(manager)];
        for (uint256 i; i < 4; ++i) {
            bytes32 id = manager.hashOperation(hotAdmin, targets[i], ops[i]);
            vm.prank(hotAdmin);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id)
            );
            manager.execute(targets[i], ops[i]);
        }
        assertEq(stream.authority(), address(manager), "Stream stays governed");
        assertFalse(stream.isAdmittedMinter(address(editionAuction)));
        (bool guardian,) = manager.hasRole(Roles.GUARDIAN, guardian1);
        assertTrue(guardian, "guardian 1 stays");
    }

    /// @dev ADR 0002 decision 5: the cold admin removes a compromised hot admin, which cannot
    ///      cancel its own removal.
    function test_ColdAdminRemovesTheHotAdmin() public {
        bytes memory removeHot = abi.encodeCall(IAccessManager.revokeRole, (Roles.ADMIN, hotAdmin));
        _schedule(coldAdmin, address(manager), removeHot);
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCancel.selector,
                hotAdmin,
                coldAdmin,
                address(manager),
                IAccessManager.revokeRole.selector
            )
        );
        manager.cancel(coldAdmin, address(manager), removeHot);
        vm.warp(block.timestamp + 30 days);
        vm.prank(coldAdmin);
        manager.execute(address(manager), removeHot);
        (bool isAdmin,) = manager.hasRole(Roles.ADMIN, hotAdmin);
        assertFalse(isAdmin);
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
        vm.warp(block.timestamp + manager.minSetback());
        configurator.verify(_genesisConfig());
    }
}
