// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { IDutchSale } from "src/interfaces/IDutchSale.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import {
    CURRENCY_DEFAULT,
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
        assertTrue(editions.isAdmittedMinter(address(fixedSale)), "fixed price mints editions");
        assertTrue(editions.isAdmittedMinter(address(dutchSale)), "Dutch mints editions");
        assertFalse(stream.isAdmittedMinter(address(fixedSale)), "Stream is auction-only");
        assertTrue(auction.isTarget(address(stream)), "auction sells Stream");
        assertFalse(auction.isTarget(address(editions)), "the auction does not sell editions");
        assertTrue(fixedSale.isTarget(address(editions)), "fixed price sells editions");
        assertTrue(dutchSale.isTarget(address(editions)), "Dutch sells editions");
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

    function test_PlatformHoldsItsZeroDelayPaths() public view {
        (bool immediate, uint32 delay) =
            manager.canCall(platform, address(fixedSale), IFixedPriceSale.openSale.selector);
        assertTrue(immediate && delay == 0, "PLATFORM opens fixed-price sales");
        (immediate, delay) =
            manager.canCall(platform, address(dutchSale), IDutchSale.closeSale.selector);
        assertTrue(immediate && delay == 0, "PLATFORM closes Dutch sales");
        (immediate, delay) =
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
            abi.encodeCall(stream.setAdmittedMinter, (address(fixedSale), true));
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
        assertFalse(stream.isAdmittedMinter(address(fixedSale)));
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

    /// @dev FINDING G-1: genesis configures no default currency. ADR 0001 §5 says Stream launches
    ///      with ETH, and every package sale term may say `CURRENCY_DEFAULT`, but
    ///      `AssetAllowlist.setDefaultCurrency` is neither a constructor argument nor a genesis
    ///      selector, so an item naming the default cannot start for the first 14 days.
    function test_Finding_G1_NoDefaultCurrencyAtGenesis() public {
        _expectFailure(
            abi.encodeCall(this.check_DefaultCurrencyWorksAtGenesis, ()),
            IAssetAllowlist.CurrencyNotConfigured.selector,
            "G-1"
        );
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.CurrencyNotConfigured.selector, PRODUCT_STREAM)
        );
        allowlist.defaultCurrency(PRODUCT_STREAM);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.CurrencyNotConfigured.selector, PRODUCT_EDITIONS)
        );
        allowlist.defaultCurrency(PRODUCT_EDITIONS);
    }

    function check_DefaultCurrencyWorksAtGenesis() external {
        address artist = _actor("defaultCurrencyArtist");
        Work memory w = _work(artist, collectionId);
        w.item.sale.currency = CURRENCY_DEFAULT;
        Work[] memory works = _one(w);
        bytes32 root = _publish(works);
        _start(root, works, 0);
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
