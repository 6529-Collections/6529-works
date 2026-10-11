// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/Test.sol";
import { Roles } from "src/governance/Roles.sol";
import { PackageItem, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { Stream } from "src/stream/Stream.sol";
import {
    ConstantArtists,
    ConstantAuction,
    ConstantEconomics,
    ConstantPackageRegistry
} from "../mocks/stream/StreamMocks.sol";
import { StreamFixture } from "./StreamFixture.sol";

/// @notice 6529 Stream's own share of the auction start (ADR 0001 budget: 300K for the whole
///         start). The registry, economics and artist registry are constant mocks and every
///         account is cold, so only Stream's storage, events, AccessManager check and call
///         overhead are measured; the real registry and auction costs come on top.
contract StreamGasTest is StreamFixture {
    /// @dev Regression guard for Stream's share of a typical start.
    uint256 internal constant MINT_SHARE_BUDGET = 170_000;

    Stream internal lean;
    ConstantAuction internal adapter;

    function setUp() public override {
        super.setUp();
        lean = new Stream(
            address(manager),
            address(new ConstantPackageRegistry(uint256(uint160(artist)))),
            address(new ConstantArtists()),
            address(new ConstantEconomics()),
            address(entropy),
            address(renderer),
            marketOwner
        );
        adapter = new ConstantAuction();
        _map(address(lean), lean.mint.selector, Roles.MINTER);
        _map(address(lean), lean.createCollection.selector, Roles.MINTER);
        manager.grantRole(Roles.MINTER, address(this), 0);
        manager.grantRole(Roles.MINTER, address(adapter), 0);
        lean.createCollection("Genesis", bytes32(0));
    }

    function _measure(PackageItem memory item) internal returns (uint256 used) {
        bytes memory data = _request(item);
        vm.cool(address(lean));
        vm.cool(address(manager));
        vm.cool(lean.packageRegistry());
        vm.cool(lean.economics());
        vm.cool(lean.artistRegistry());
        vm.cool(address(adapter));
        used = adapter.startMeasured(lean, data);
    }

    function test_gas_mintShare_typical() public {
        _measure(_item(1)); // first mint: counters, fee terms and adapter balance from zero
        uint256 used = _measure(_item(2));
        console2.log("Stream.mint share, typical (warm counters, cold accounts):", used);
        console2.log("StreamMintRequest bytes:", _request(_item(2)).length);
        assertLe(used, MINT_SHARE_BUDGET);
    }

    /// @dev The adapter holds no other token (no concurrent auction), so its balance word is
    ///      written from zero.
    function test_gas_mintShare_idleAdapter() public {
        _measure(_item(1));
        vm.prank(address(adapter));
        lean.transferFrom(address(adapter), outsider, 1);
        uint256 used = _measure(_item(2));
        console2.log("Stream.mint share, idle adapter (balance from zero):", used);
    }

    function test_gas_mintShare_first() public {
        uint256 used = _measure(_item(1));
        console2.log("Stream.mint share, first mint ever:", used);
    }

    function test_gas_mintShare_artistSeed() public {
        _measure(_item(1));
        PackageItem memory item = _item(2);
        item.seedPolicy = SeedPolicy.ARTIST;
        item.seed = keccak256("seed");
        uint256 used = _measure(item);
        console2.log("Stream.mint share, ARTIST seed:", used);
    }
}
