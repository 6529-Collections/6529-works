// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { ReturnDataMock } from "../mocks/AdversarialTargets.sol";
import { MockERC20 } from "../mocks/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

contract AssetAllowlistTest is EconomicsBase {
    bytes32 internal constant STREAM = keccak256("6529.stream.auction");
    bytes32 internal constant EDITIONS = keccak256("6529.editions.sale");
    uint64 internal constant STANDARD_ROLE = 2;
    uint32 internal constant STANDARD_DELAY = 48 hours;

    MockERC20 internal usdc;
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        usdc = new MockERC20("USD Coin", "USDC");
    }

    function test_ConstructorAdmitsETHWithItsFloor() public {
        vm.expectEmit(true, false, false, true);
        emit IAssetAllowlist.AssetStatusChanged(
            ETH, IAssetAllowlist.Status.None, IAssetAllowlist.Status.Active
        );
        vm.expectEmit(true, false, false, true);
        emit IAssetAllowlist.IncrementFloorChanged(ETH, 0, ETH_FLOOR);
        AssetAllowlist fresh = new AssetAllowlist(address(manager), ETH_FLOOR);
        assertTrue(fresh.isActive(ETH));
        assertEq(fresh.incrementFloor(ETH), ETH_FLOOR);
        assertEq(fresh.authority(), address(manager));
        vm.expectRevert(IAssetAllowlist.InvalidIncrementFloor.selector);
        new AssetAllowlist(address(manager), 0);
    }

    function test_AdmitAssetActivatesWithFloor() public {
        vm.expectEmit(true, false, false, true, address(allowlist));
        emit IAssetAllowlist.AssetStatusChanged(
            address(usdc), IAssetAllowlist.Status.None, IAssetAllowlist.Status.Active
        );
        vm.expectEmit(true, false, false, true, address(allowlist));
        emit IAssetAllowlist.IncrementFloorChanged(address(usdc), 0, 1e6);
        allowlist.admitAsset(address(usdc), 1e6);
        assertEq(uint8(allowlist.status(address(usdc))), uint8(IAssetAllowlist.Status.Active));
        assertTrue(allowlist.isActive(address(usdc)));
        assertEq(allowlist.incrementFloor(address(usdc)), 1e6);
        (IAssetAllowlist.Status status, uint256 floor) = allowlist.assetConfig(address(usdc));
        assertEq(uint8(status), uint8(IAssetAllowlist.Status.Active));
        assertEq(floor, 1e6);
    }

    function test_AdmitRejectsNonTokens() public {
        vm.expectRevert(abi.encodeWithSelector(IAssetAllowlist.AssetNotAdmissible.selector, alice));
        allowlist.admitAsset(alice, 1);

        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(usdc)));
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotAdmissible.selector, delegated)
        );
        allowlist.admitAsset(delegated, 1);

        ReturnDataMock malformed = new ReturnDataMock();
        malformed.configure(hex"01", false);
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.TokenReadFailed.selector, address(malformed))
        );
        allowlist.admitAsset(address(malformed), 1);
        malformed.configure("", true);
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.TokenReadFailed.selector, address(malformed))
        );
        allowlist.admitAsset(address(malformed), 1);
    }

    function test_AdmitRejectsABalanceAboveTotalSupply() public {
        usdc.mint(address(allowlist), 10);
        vm.mockCall(address(usdc), abi.encodeWithSignature("totalSupply()"), abi.encode(9));
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotAdmissible.selector, address(usdc))
        );
        allowlist.admitAsset(address(usdc), 1);
        vm.clearMockedCalls();
        allowlist.admitAsset(address(usdc), 1);
        assertTrue(allowlist.isActive(address(usdc)));
    }

    function test_AdmitRejectsZeroFloorAndActiveAssets() public {
        vm.expectRevert(IAssetAllowlist.InvalidIncrementFloor.selector);
        allowlist.admitAsset(address(usdc), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetAllowlist.InvalidStatusTransition.selector, ETH, IAssetAllowlist.Status.Active
            )
        );
        allowlist.admitAsset(ETH, 1);
    }

    function test_DeprecateThenReadmit() public {
        allowlist.admitAsset(address(usdc), 1e6);
        vm.expectEmit(true, false, false, true, address(allowlist));
        emit IAssetAllowlist.AssetStatusChanged(
            address(usdc), IAssetAllowlist.Status.Active, IAssetAllowlist.Status.Deprecated
        );
        allowlist.deprecateAsset(address(usdc));
        assertFalse(allowlist.isActive(address(usdc)));
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, address(usdc))
        );
        allowlist.incrementFloor(address(usdc));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetAllowlist.InvalidStatusTransition.selector,
                address(usdc),
                IAssetAllowlist.Status.Deprecated
            )
        );
        allowlist.deprecateAsset(address(usdc));

        vm.expectEmit(true, false, false, true, address(allowlist));
        emit IAssetAllowlist.IncrementFloorChanged(address(usdc), 1e6, 2e6);
        allowlist.admitAsset(address(usdc), 2e6);
        assertEq(allowlist.incrementFloor(address(usdc)), 2e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetAllowlist.InvalidStatusTransition.selector, bob, IAssetAllowlist.Status.None
            )
        );
        allowlist.deprecateAsset(bob);
    }

    function test_IncrementFloorIsCompareAndSet() public {
        vm.expectEmit(true, false, false, true, address(allowlist));
        emit IAssetAllowlist.IncrementFloorChanged(ETH, ETH_FLOOR, 0.002 ether);
        allowlist.setIncrementFloor(ETH, ETH_FLOOR, 0.002 ether);
        assertEq(allowlist.incrementFloor(ETH), 0.002 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetAllowlist.IncrementFloorMismatch.selector, ETH_FLOOR, 0.002 ether
            )
        );
        allowlist.setIncrementFloor(ETH, ETH_FLOOR, 0.005 ether);
        vm.expectRevert(IAssetAllowlist.InvalidIncrementFloor.selector);
        allowlist.setIncrementFloor(ETH, 0.002 ether, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, address(usdc))
        );
        allowlist.setIncrementFloor(address(usdc), 0, 1);
    }

    function test_DefaultCurrencyIsCompareAndSet() public {
        vm.expectEmit(true, false, false, true, address(allowlist));
        emit IAssetAllowlist.DefaultCurrencyChanged(STREAM, false, address(0), ETH);
        allowlist.setDefaultCurrency(STREAM, false, address(0), ETH);
        assertEq(allowlist.defaultCurrency(STREAM), ETH);

        // A second "first" setting is stale even though ETH is also the zero address.
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.DefaultCurrencyMismatch.selector, true, ETH)
        );
        allowlist.setDefaultCurrency(STREAM, false, address(0), ETH);

        allowlist.admitAsset(address(usdc), 1e6);
        vm.expectEmit(true, false, false, true, address(allowlist));
        emit IAssetAllowlist.DefaultCurrencyChanged(STREAM, true, ETH, address(usdc));
        allowlist.setDefaultCurrency(STREAM, true, ETH, address(usdc));
        assertEq(allowlist.defaultCurrency(STREAM), address(usdc));
        (bool configured, address asset) = allowlist.defaultCurrencyConfig(STREAM);
        assertTrue(configured);
        assertEq(asset, address(usdc));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetAllowlist.DefaultCurrencyMismatch.selector, true, address(usdc)
            )
        );
        allowlist.setDefaultCurrency(STREAM, true, ETH, ETH);
        vm.expectRevert(IAssetAllowlist.InvalidProduct.selector);
        allowlist.setDefaultCurrency(bytes32(0), false, address(0), ETH);
        vm.expectRevert(abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, bob));
        allowlist.setDefaultCurrency(EDITIONS, false, address(0), bob);
    }

    function test_DefaultCurrencyFailsClosed() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.CurrencyNotConfigured.selector, EDITIONS)
        );
        allowlist.defaultCurrency(EDITIONS);
        (bool configured, address asset) = allowlist.defaultCurrencyConfig(EDITIONS);
        assertFalse(configured);
        assertEq(asset, address(0));

        allowlist.admitAsset(address(usdc), 1e6);
        allowlist.setDefaultCurrency(EDITIONS, false, address(0), address(usdc));
        allowlist.deprecateAsset(address(usdc));
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, address(usdc))
        );
        allowlist.defaultCurrency(EDITIONS);
        allowlist.setDefaultCurrency(EDITIONS, true, address(usdc), ETH);
        assertEq(allowlist.defaultCurrency(EDITIONS), ETH);
    }

    function test_GovernedFunctionsRejectOtherCallers() public {
        vm.startPrank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        allowlist.admitAsset(address(usdc), 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        allowlist.deprecateAsset(ETH);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        allowlist.setIncrementFloor(ETH, ETH_FLOOR, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        allowlist.setDefaultCurrency(STREAM, false, address(0), ETH);
        vm.stopPrank();
    }

    function test_GovernedFunctionsAreNonPayable() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(allowlist).call{ value: 1 }(
            abi.encodeCall(IAssetAllowlist.deprecateAsset, (ETH))
        );
        assertFalse(ok);
        (ok,) = address(allowlist).call{ value: 1 }("");
        assertFalse(ok);
    }

    function test_TimelockedAdmissionThroughAccessManager() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IAssetAllowlist.admitAsset.selector;
        selectors[1] = IAssetAllowlist.setDefaultCurrency.selector;
        manager.setTargetFunctionRole(address(allowlist), selectors, STANDARD_ROLE);
        manager.grantRole(STANDARD_ROLE, alice, STANDARD_DELAY);

        bytes memory admit = abi.encodeCall(IAssetAllowlist.admitAsset, (address(usdc), 1e6));
        bytes32 operation = manager.hashOperation(alice, address(allowlist), admit);
        vm.startPrank(alice);
        // A delayed role cannot call directly; the call must be scheduled first.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, operation)
        );
        allowlist.admitAsset(address(usdc), 1e6);
        manager.schedule(address(allowlist), admit, 0);
        vm.warp(block.timestamp + STANDARD_DELAY - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, operation)
        );
        manager.execute(address(allowlist), admit);
        vm.warp(block.timestamp + 1);
        manager.execute(address(allowlist), admit);
        vm.stopPrank();
        assertTrue(allowlist.isActive(address(usdc)));

        // The admin role no longer reaches the remapped selector directly.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this))
        );
        allowlist.setDefaultCurrency(STREAM, false, address(0), address(usdc));
        assertEq(manager.getTargetFunctionRole(address(allowlist), selectors[1]), STANDARD_ROLE);
    }

    function testFuzz_FloorRoundTrips(uint256 floor) public {
        floor = bound(floor, 1, type(uint256).max);
        allowlist.admitAsset(address(usdc), floor);
        assertEq(allowlist.incrementFloor(address(usdc)), floor);
    }
}
