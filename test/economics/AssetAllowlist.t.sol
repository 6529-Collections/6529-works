// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { Roles } from "src/governance/Roles.sol";
import { MockERC20 } from "../mocks/economics/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

/// @notice The ETH-only allowlist: ETH is admitted at deployment and stays active, no other
///         asset can be admitted, and the English auction's opening bid and the increment floor
///         are compare-and-set on a revision.
contract AssetAllowlistTest is EconomicsBase {
    MockERC20 internal usdc;
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        usdc = new MockERC20("USD Coin", "USDC");
    }

    function _revision(address asset) internal view returns (uint64 revision) {
        (,, revision) = allowlist.assetConfig(asset);
    }

    function _mismatch(uint64 expected, uint64 actual) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAssetAllowlist.RevisionMismatch.selector, expected, actual);
    }

    function test_ConstructorAdmitsETHWithItsFloor() public {
        vm.expectEmit(true, false, false, true);
        emit IAssetAllowlist.AssetStatusChanged(
            ETH, IAssetAllowlist.Status.None, IAssetAllowlist.Status.Active, 1
        );
        vm.expectEmit(true, false, false, true);
        emit IAssetAllowlist.IncrementFloorChanged(ETH, 0, ETH_FLOOR, 1);
        AssetAllowlist fresh = new AssetAllowlist(address(manager), ETH_FLOOR);
        assertTrue(fresh.isActive(ETH));
        assertEq(fresh.incrementFloor(ETH), ETH_FLOOR);
        assertEq(fresh.authority(), address(manager));
        (IAssetAllowlist.Status status, uint256 floor, uint64 revision) = fresh.assetConfig(ETH);
        assertEq(uint8(status), uint8(IAssetAllowlist.Status.Active));
        assertEq(floor, ETH_FLOOR);
        assertEq(revision, 1);
        vm.expectRevert(IAssetAllowlist.InvalidIncrementFloor.selector);
        new AssetAllowlist(address(manager), 0);
    }

    /// @dev No other asset can be admitted and ETH cannot be deprecated: neither function
    ///      exists, and any other asset stays `None` (inactive) whatever the network calls.
    function test_NoOtherAssetCanBeAdmitted() public {
        (bool ok,) = address(allowlist)
            .call(abi.encodeWithSignature("admitAsset(address,uint64,uint256)", usdc, 0, 1e6));
        assertFalse(ok, "no admission function");
        assertFalse(allowlist.isActive(address(usdc)));
        assertEq(uint8(allowlist.status(address(usdc))), uint8(IAssetAllowlist.Status.None));
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, address(usdc))
        );
        allowlist.incrementFloor(address(usdc));
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, address(usdc))
        );
        allowlist.setOpeningBid(address(usdc), 0, 1);
        (ok,) = address(allowlist).call(abi.encodeWithSignature("deprecateAsset(address)", ETH));
        assertFalse(ok, "no deprecation function");
        (ok,) = address(allowlist)
            .call(
                abi.encodeWithSignature(
                    "setDefaultCurrency(bytes32,uint64,address)", bytes32(uint256(1)), 0, ETH
                )
            );
        assertFalse(ok, "no default-currency function");
        assertTrue(allowlist.isActive(ETH));
    }

    function test_EveryChangeBumpsTheRevision() public {
        assertEq(_revision(ETH), 1);
        allowlist.setIncrementFloor(ETH, 1, 2e15);
        assertEq(_revision(ETH), 2);
        allowlist.setOpeningBid(ETH, 2, 0.01 ether);
        assertEq(_revision(ETH), 3);
        allowlist.setIncrementFloor(ETH, 3, ETH_FLOOR);
        // Same floor as at revision 1, but a later revision: a stale write fails.
        vm.expectRevert(_mismatch(1, 4));
        allowlist.setIncrementFloor(ETH, 1, 5e15);
    }

    /// @dev The English auction's opening bid lives in ETH's status word: set compare-and-set
    ///      on the revision up to the 96-bit storage bound (no price cap), and read with the
    ///      status (`activeOpeningBid`).
    function test_OpeningBid_LivesInTheStatusWord() public {
        uint256 cap = type(uint96).max;
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.OpeningBidAboveCeiling.selector, cap + 1, cap)
        );
        allowlist.setOpeningBid(ETH, 1, cap + 1);
        vm.expectEmit(true, false, false, true, address(allowlist));
        emit IAssetAllowlist.OpeningBidSet(ETH, 0, 0.05 ether, 2);
        allowlist.setOpeningBid(ETH, 1, 0.05 ether);
        vm.expectRevert(_mismatch(1, 2));
        allowlist.setOpeningBid(ETH, 1, 0.06 ether);
        assertEq(allowlist.openingBid(ETH), 0.05 ether);
        assertEq(allowlist.activeOpeningBid(ETH), 0.05 ether);
        assertEq(allowlist.incrementFloor(ETH), ETH_FLOOR, "the floor is untouched");

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        allowlist.setOpeningBid(ETH, 2, 0);
    }

    function test_IncrementFloorIsCompareAndSet() public {
        vm.expectEmit(true, false, false, true, address(allowlist));
        emit IAssetAllowlist.IncrementFloorChanged(ETH, ETH_FLOOR, 0.002 ether, 2);
        allowlist.setIncrementFloor(ETH, 1, 0.002 ether);
        assertEq(allowlist.incrementFloor(ETH), 0.002 ether);

        vm.expectRevert(_mismatch(1, 2));
        allowlist.setIncrementFloor(ETH, 1, 0.005 ether);
        vm.expectRevert(IAssetAllowlist.InvalidIncrementFloor.selector);
        allowlist.setIncrementFloor(ETH, 2, 0);
    }

    function test_GovernedFunctionsRejectOtherCallers() public {
        vm.startPrank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        allowlist.setIncrementFloor(ETH, 1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        allowlist.setOpeningBid(ETH, 1, 1);
        vm.stopPrank();
    }

    function test_GovernedFunctionsAreNonPayable() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(allowlist).call{ value: 1 }(
            abi.encodeCall(IAssetAllowlist.setOpeningBid, (ETH, 1, 1))
        );
        assertFalse(ok);
        (ok,) = address(allowlist).call{ value: 1 }("");
        assertFalse(ok);
    }

    /// @dev A setter remapped to a delayed role runs only through the AccessManager's schedule.
    function test_TimelockedSettingThroughAccessManager() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IAssetAllowlist.setOpeningBid.selector;
        manager.setTargetFunctionRole(address(allowlist), selectors, Roles.FUNDS_SETTER);
        manager.grantRole(Roles.FUNDS_SETTER, alice, Roles.DELAY_3D);

        bytes memory set = abi.encodeCall(IAssetAllowlist.setOpeningBid, (ETH, 1, 0.05 ether));
        bytes32 operation = manager.hashOperation(alice, address(allowlist), set);
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, operation)
        );
        allowlist.setOpeningBid(ETH, 1, 0.05 ether);
        manager.schedule(address(allowlist), set, 0);
        vm.warp(block.timestamp + Roles.DELAY_3D - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, operation)
        );
        manager.execute(address(allowlist), set);
        vm.warp(block.timestamp + 1);
        manager.execute(address(allowlist), set);
        vm.stopPrank();
        assertEq(allowlist.openingBid(ETH), 0.05 ether);

        // The admin role no longer reaches the remapped selector directly.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this))
        );
        allowlist.setOpeningBid(ETH, 2, 0.06 ether);
    }

    function testFuzz_FloorRoundTrips(uint256 floor) public {
        floor = bound(floor, 1, type(uint256).max);
        allowlist.setIncrementFloor(ETH, 1, floor);
        assertEq(allowlist.incrementFloor(ETH), floor);
    }

    /// @dev No price cap: any opening bid that fits its 96-bit storage is accepted whatever the
    ///      increment floor; only a bid above `type(uint96).max` is refused.
    function testFuzz_OpeningBid_NoPriceCap(uint256 bid) public {
        bid = bound(bid, ETH_FLOOR * 1_000 + 1, type(uint96).max);
        vm.expectEmit(address(allowlist));
        emit IAssetAllowlist.OpeningBidSet(ETH, 0, bid, 2);
        allowlist.setOpeningBid(ETH, 1, bid);
        assertEq(allowlist.activeOpeningBid(ETH), bid);
    }
}
