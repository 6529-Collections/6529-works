// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/Test.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { EconomicsResolver } from "src/economics/EconomicsResolver.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
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

/// @notice 6529 Stream's own share of the auction start (ADR 0003 and ADR 0004 budget: 350K
///         Prague execution gas for the whole steady-state start). The registry, economics and
///         artist registry are constant mocks and every account is cold, so Stream's storage,
///         events, AccessManager check, call overhead and its seller-wallet derivation on the
///         real split factory are measured; the real registry and auction costs come on top.
///         `test_gas_mintShare_realEconomics` also puts the real `EconomicsResolver` in the path
///         (review G-2).
contract StreamGasTest is StreamFixture {
    /// @dev Regression guards for Stream's share of the start, per case. Since G-2 the share
    ///      includes the seller-wallet `walletFor` that the resolver's `newWorkTerms` used to do.
    uint256 internal constant MINT_SHARE_BUDGET = 150_000;
    uint256 internal constant IDLE_ADAPTER_BUDGET = 165_000;
    uint256 internal constant FIRST_MINT_BUDGET = 240_000;
    /// @dev The two-payee start share with the real resolver and factory: 156,827 before G-2.
    uint256 internal constant REAL_ECONOMICS_BUDGET = 150_000;

    Stream internal lean;
    /// @dev The lean stack with the real `EconomicsResolver` and `SplitFactory` (review G-2).
    Stream internal leanReal;
    EconomicsResolver internal resolver;
    ConstantAuction internal adapter;

    function setUp() public override {
        super.setUp();
        lean = new Stream(
            address(manager),
            address(new ConstantPackageRegistry(uint256(uint160(artist)))),
            address(new ConstantArtists()),
            address(new ConstantEconomics(address(splitFactory))),
            address(entropy),
            address(renderer),
            address(renderer).codehash,
            marketOwner
        );
        adapter = new ConstantAuction();
        _map(address(lean), lean.setAdmittedMinter.selector, Roles.SUCCESSOR_SETTER);
        _map(address(lean), lean.createCollection.selector, Roles.PLATFORM);
        vm.prank(governor);
        lean.setAdmittedMinter(address(adapter), true);
        vm.prank(platform);
        lean.createCollection("Genesis", bytes32(0));

        resolver = new EconomicsResolver(
            address(manager),
            new AssetAllowlist(address(manager), 1),
            ISplitFactory(address(splitFactory)),
            feeRecipient,
            keccak256("cc0 text")
        );
        leanReal = new Stream(
            address(manager),
            lean.packageRegistry(),
            lean.artistRegistry(),
            address(resolver),
            address(entropy),
            address(renderer),
            address(renderer).codehash,
            marketOwner
        );
        _map(address(leanReal), leanReal.setAdmittedMinter.selector, Roles.SUCCESSOR_SETTER);
        _map(address(leanReal), leanReal.createCollection.selector, Roles.PLATFORM);
        vm.prank(governor);
        leanReal.setAdmittedMinter(address(adapter), true);
        vm.prank(platform);
        leanReal.createCollection("Genesis", bytes32(0));
    }

    /// @dev Stream's share with the real economics resolver and split factory in the path, so
    ///      it includes the per-work economics read and the seller-wallet derivation (G-2).
    function _measureReal(PackageItem memory item) internal returns (uint256 used) {
        bytes memory data = _request(item);
        vm.cool(address(leanReal));
        vm.cool(address(manager));
        vm.cool(leanReal.packageRegistry());
        vm.cool(address(resolver));
        vm.cool(address(splitFactory));
        vm.cool(leanReal.artistRegistry());
        vm.cool(address(adapter));
        used = adapter.startMeasured(leanReal, data);
    }

    function test_gas_mintShare_realEconomics() public {
        _measureReal(_item(1));
        PackageItem memory item = _item(2);
        // Two parties, as in the e2e lane's two-party start.
        item.payees = new ISplitWallet.Payee[](2);
        (address lo, address hi) = artist < seller ? (artist, seller) : (seller, artist);
        item.payees[0] = ISplitWallet.Payee(0, lo, 50_000);
        item.payees[1] = ISplitWallet.Payee(0, hi, 50_000);
        uint256 used = _measureReal(item);
        console2.log("Stream.mint share, real resolver and factory, two payees:", used);
        assertLe(used, REAL_ECONOMICS_BUDGET);
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

    /// @dev The license-ID check at its longest: a 64-character ID, against the typical
    ///      7-character `cc0-1.0`.
    function test_gas_mintShare_longestLicenseId() public {
        _measure(_item(1));
        PackageItem memory item = _item(2);
        item.license.spdxId = "LicenseRef-6529-Works-Long-Identifier-For-Gas-Measurement-12345.";
        assertEq(bytes(item.license.spdxId).length, 64);
        uint256 used = _measure(item);
        console2.log("Stream.mint share, 64-byte license ID:", used);
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
        assertLe(used, IDLE_ADAPTER_BUDGET);
    }

    /// @dev The derived receiver costs one `SplitFactory.walletFor` (a creation-code hash);
    ///      measured cold, as a marketplace's call would be.
    function test_gas_royaltyInfoAndWorkReads() public {
        _mint(_item(1));
        vm.cool(address(stream));
        vm.cool(address(splitFactory));
        uint256 before = gasleft();
        stream.royaltyInfo(1, 1 ether);
        uint256 royalty = before - gasleft();
        vm.cool(address(stream));
        vm.cool(address(splitFactory));
        before = gasleft();
        stream.work(1);
        uint256 core = before - gasleft();
        console2.log("royaltyInfo, cold, real SplitFactory:", royalty);
        console2.log("work(), cold, real SplitFactory:", core);
        assertLt(royalty, 60_000);
    }

    /// @dev What the economics resolver's `newWorkTerms` would add to the start for the two
    ///      `walletFor` derivations (seller wallet, royalty wallet). Stream's mint share above uses
    ///      a constant mock, so this is reported beside it (review of PR #22).
    function test_gas_walletForCosts() public {
        ISplitWallet.Payee[] memory one = new ISplitWallet.Payee[](1);
        one[0] = ISplitWallet.Payee(uint256(uint160(artist)), address(0), 100_000);
        ISplitWallet.Payee[] memory two = new ISplitWallet.Payee[](2);
        (address lo, address hi) =
            feeRecipient < seller ? (feeRecipient, seller) : (seller, feeRecipient);
        two[0] = ISplitWallet.Payee(0, lo, 25_000);
        two[1] = ISplitWallet.Payee(0, hi, 75_000);
        vm.cool(address(splitFactory));
        uint256 before = gasleft();
        splitFactory.walletFor(one, bytes32(0));
        uint256 sellerWallet = before - gasleft();
        before = gasleft();
        splitFactory.walletFor(two, bytes32(0));
        uint256 royalty = before - gasleft();
        console2.log("walletFor seller (1 payee, cold factory):", sellerWallet);
        console2.log("walletFor royalty (2 payees, warm factory):", royalty);
    }

    function test_gas_mintShare_first() public {
        uint256 used = _measure(_item(1));
        console2.log("Stream.mint share, first mint ever:", used);
        assertLe(used, FIRST_MINT_BUDGET);
    }

    function test_gas_mintShare_artistSeed() public {
        _measure(_item(1));
        PackageItem memory item = _item(2);
        item.seedPolicy = SeedPolicy.ARTIST;
        item.seed = keccak256("seed");
        uint256 used = _measure(item);
        console2.log("Stream.mint share, ARTIST seed:", used);
        assertLe(used, MINT_SHARE_BUDGET);
    }
}
