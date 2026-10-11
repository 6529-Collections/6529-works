// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_EDITIONS,
    PRODUCT_FEDERATED,
    PRODUCT_STREAM
} from "src/interfaces/types/EconomicsTypes.sol";
import { LockedTerms, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { VerifyV1 } from "script/VerifyV1.sol";
import { MockMintTarget } from "../mocks/auction/AuctionMocks.sol";
import { MockVrfCoordinator } from "../mocks/EntropyMocks.sol";
import { MockEditionTarget } from "../mocks/sales/SaleMocks.sol";

/// @notice The deploy library the script broadcasts and the integration tests reuse: every
///         merged v1 contract, the genesis configuration from config/genesis.example.json, the
///         genesis wiring, and the readback.
contract DeployV1Test is Test {
    string internal constant GENESIS = "config/genesis.example.json";
    /// Holders from the example JSON.
    address internal constant HOT_ADMIN = address(0xB001);
    address internal constant GUARDIAN = address(0xB011);

    string internal json;
    DeployV1.Manifest internal manifest;

    function setUp() public {
        json = vm.readFile(GENESIS);
        manifest = DeployV1.Manifest(keccak256("epoch-0 manifest"), "ar://epoch-0");
    }

    function _params() internal returns (DeployV1.Params memory p) {
        p.deployer = address(this);
        p.namespace = keccak256("6529-works/test");
        p.feeRecipient = makeAddr("feeRecipient");
        p.cc0Text = bytes("CC0 1.0 Universal (test copy)");
        p.ethIncrementFloor = 0.001 ether;
        p.permit2 = DeployV1.CANONICAL_PERMIT2;
        p.auction = IEnglishAuction.AuctionConfig(24 hours, 15 minutes, 5_000);
    }

    function _genesis(DeployV1.Params memory p)
        internal
        returns (
            DeployV1.Deployment memory d,
            GovernanceConfig.Config memory cfg,
            GovernanceConfig.Call[] memory calls
        )
    {
        d = DeployV1.deploy(p);
        cfg = DeployV1.config(d, json);
        calls = DeployV1.wiring(d, json, manifest);
        DeployV1.install(d, cfg, manifest, calls);
    }

    /// @dev External entry points, so tests can expect the libraries' reverts.
    function deployExternal(DeployV1.Params memory p)
        external
        returns (DeployV1.Deployment memory)
    {
        return DeployV1.deploy(p);
    }

    function checkWiredExternal(DeployV1.Deployment memory d, GovernanceConfig.Call memory call)
        external
        view
    {
        VerifyV1.checkWired(d, call);
    }

    function _settle(DeployV1.Deployment memory d) internal {
        vm.warp(block.timestamp + d.manager.minSetback());
    }

    // ------------------------------------------------------------------ genesis

    function test_GenesisDeploysConfiguresWiresAndReadsBack() public {
        (
            DeployV1.Deployment memory d,
            GovernanceConfig.Config memory cfg,
            GovernanceConfig.Call[] memory calls
        ) = _genesis(_params());
        // The merged contracts with a governance map; Stream, WorkRecords and Editions and the
        // optional entropy module are not deployed here.
        assertEq(cfg.targets.length, 11, "governed targets");
        assertEq(cfg.grants.length, 17, "holders");
        // The artist registry's package-registry and split-factory binds, three default
        // currencies and the manifest; the rest name pending contracts.
        assertEq(calls.length, 6, "wiring calls");
        _settle(d);
        VerifyV1.check(d, cfg, calls);

        assertEq(IPackageRegistry(address(d.packageRegistry)).stream(), address(0), "pending");
        (uint64 count,) = IStatementLog(address(d.statementLog)).chainOf(address(d.manager), 0);
        assertEq(count, 1, "epoch-0 manifest recorded at genesis");
        // Auctions can start at once: every product has its default currency from genesis.
        bytes32[3] memory products = [PRODUCT_STREAM, PRODUCT_EDITIONS, PRODUCT_FEDERATED];
        for (uint256 i; i < products.length; ++i) {
            assertEq(d.assetAllowlist.defaultCurrency(products[i]), address(0), "ETH");
        }
    }

    // ------------------------------------------------- default currency (finding G-1)

    /// @dev Genesis with a mock Stream on the auction and a mock Editions on the fixed-price
    ///      sale, both listed by genesis wiring (`setTarget`, as the JSON does for the real
    ///      tokens once they land). Both mocks price in `CURRENCY_DEFAULT`. Without
    ///      `withDefaults`, the JSON's `setDefaultCurrency` calls are dropped.
    function _genesisWithDefaultCurrencyItems(bool withDefaults)
        internal
        returns (DeployV1.Deployment memory d, MockMintTarget stream, MockEditionTarget editions)
    {
        DeployV1.Params memory p = _params();
        d = DeployV1.deploy(p);
        stream = new MockMintTarget();
        editions = new MockEditionTarget();
        stream.setAdmittedMinter(address(d.englishAuction), true);
        stream.setTerms(
            PrimaryTerms(
                SaleKind.ENGLISH_AUCTION,
                CURRENCY_DEFAULT,
                0,
                "",
                makeAddr("seller"),
                p.feeRecipient,
                5_000,
                makeAddr("artist")
            )
        );
        editions.setTerms(
            1,
            PrimaryTerms(
                SaleKind.FIXED_PRICE,
                CURRENCY_DEFAULT,
                0, // a gift: CURRENCY_DEFAULT is for zero-price sales only
                "",
                makeAddr("seller"),
                p.feeRecipient,
                5_000,
                makeAddr("artist")
            ),
            100
        );

        GovernanceConfig.Call[] memory json_ = DeployV1.wiring(d, json, manifest);
        GovernanceConfig.Call[] memory calls = new GovernanceConfig.Call[](json_.length + 2);
        uint256 n;
        for (uint256 i; i < json_.length; ++i) {
            if (
                !withDefaults
                    && bytes4(json_[i].data) == IAssetAllowlist.setDefaultCurrency.selector
            ) {
                continue;
            }
            calls[n++] = json_[i];
        }
        calls[n++] = GovernanceConfig.Call(
            address(d.englishAuction),
            abi.encodeCall(ISaleAdapter.setTarget, (address(stream), true))
        );
        calls[n++] = GovernanceConfig.Call(
            address(d.fixedPriceSale),
            abi.encodeCall(ISaleAdapter.setTarget, (address(editions), true))
        );
        assembly ("memory-safe") {
            mstore(calls, n)
        }
        DeployV1.install(d, DeployV1.config(d, json), manifest, calls);
    }

    function _giftPhase() internal view returns (IFixedPriceSale.Phase[] memory phases) {
        phases = new IFixedPriceSale.Phase[](1);
        phases[0] = IFixedPriceSale.Phase(
            uint64(block.timestamp), uint64(block.timestamp + 1 days), bytes32(0), 0, false, false
        );
    }

    /// G-1: a `CURRENCY_DEFAULT` item starts in the genesis block, with no governance delay.
    function test_CurrencyDefaultItemsStartRightAfterGenesis() public {
        (DeployV1.Deployment memory d, MockMintTarget stream, MockEditionTarget editions) =
            _genesisWithDefaultCurrencyItems(true);
        uint256 genesisTime = block.timestamp;

        // A 6529 Stream auction: EnglishAuction reads AssetAllowlist.defaultCurrency directly.
        uint256 saleId = d.englishAuction.start(address(stream), "");
        assertEq(d.englishAuction.lockedTerms(saleId).currency, CURRENCY_ETH, "auction in ETH");

        // A 6529 Editions gift: MintSaleBase resolves through EconomicsResolver.resolveCurrency.
        vm.prank(makeAddr("artist"));
        uint256 giftId = d.fixedPriceSale
            .openSale(address(editions), 1, _giftPhase(), IFixedPriceSale.ArtistConsent(0, 0, ""));
        (LockedTerms memory terms,,) = d.fixedPriceSale.sale(giftId);
        assertEq(terms.currency, CURRENCY_ETH, "gift in ETH");

        assertEq(block.timestamp, genesisTime, "no time passed");
    }

    /// The control: without the genesis defaults, both items wait out FUNDS_SETTER's delay.
    function test_WithoutGenesisDefaultsCurrencyDefaultItemsCannotStart() public {
        (DeployV1.Deployment memory d, MockMintTarget stream, MockEditionTarget editions) =
            _genesisWithDefaultCurrencyItems(false);

        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.CurrencyNotConfigured.selector, PRODUCT_STREAM)
        );
        d.englishAuction.start(address(stream), "");

        IFixedPriceSale.Phase[] memory phases = _giftPhase();
        vm.prank(makeAddr("artist"));
        vm.expectRevert(
            abi.encodeWithSelector(IEconomicsResolver.CurrencyNotAllowed.selector, CURRENCY_DEFAULT)
        );
        d.fixedPriceSale
            .openSale(address(editions), 1, phases, IFixedPriceSale.ArtistConsent(0, 0, ""));
    }

    function test_GenesisStoresTheCc0TextCompleteOnChain() public {
        DeployV1.Params memory p = _params();
        (DeployV1.Deployment memory d,,) = _genesis(p);
        assertTrue(d.contentStore.isComplete(d.cc0TextFileId));
        assertEq(d.contentStore.sha256Of(d.cc0TextFileId), sha256(p.cc0Text));
        assertEq(d.economicsResolver.defaultLicense(PRODUCT_STREAM).textFileId, d.cc0TextFileId);
    }

    function test_MultiChunkTextUploads() public {
        DeployV1.Params memory p = _params();
        p.cc0Text = new bytes(30_000); // two chunks
        for (uint256 i; i < p.cc0Text.length; ++i) {
            p.cc0Text[i] = bytes1(uint8(65 + i % 26));
        }
        DeployV1.Deployment memory d = DeployV1.deploy(p);
        assertTrue(d.contentStore.isComplete(d.cc0TextFileId));
        assertEq(d.contentStore.sha256Of(d.cc0TextFileId), sha256(p.cc0Text));
    }

    function test_EntropyModuleJoinsWhenACoordinatorIsGiven() public {
        DeployV1.Params memory p = _params();
        MockVrfCoordinator coordinator = new MockVrfCoordinator();
        p.vrfCoordinator = address(coordinator);
        p.vrfCoordinatorCodeHash = address(coordinator).codehash;
        p.vrf = VrfEntropyModule.VrfConfig(1, keccak256("key hash"), 200_000, 3, false);
        p.vrfRetryDelay = 3 days;
        (
            DeployV1.Deployment memory d,
            GovernanceConfig.Config memory cfg,
            GovernanceConfig.Call[] memory calls
        ) = _genesis(p);
        assertTrue(address(d.entropyModule) != address(0));
        assertEq(cfg.targets.length, 12);
        _settle(d);
        VerifyV1.check(d, cfg, calls);
    }

    function test_GovernanceConfiguredCarriesTheRecomputableHashes() public {
        DeployV1.Deployment memory d = DeployV1.deploy(_params());
        GovernanceConfig.Config memory cfg = DeployV1.config(d, json);
        GovernanceConfig.Call[] memory calls = DeployV1.wiring(d, json, manifest);
        vm.recordLogs();
        DeployV1.install(d, cfg, manifest, calls);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != GovernanceConfigurator.GovernanceConfigured.selector) {
                continue;
            }
            found = true;
            assertEq(logs[i].topics[2], keccak256(abi.encode(cfg)));
            assertEq(logs[i].topics[3], manifest.digest);
            assertEq(abi.decode(logs[i].data, (bytes32)), keccak256(abi.encode(calls)));
        }
        assertTrue(found);
    }

    function test_AGuardianCancelsAHostileAdminOperationOnTheLiveSystem() public {
        (DeployV1.Deployment memory d,,) = _genesis(_params());
        _settle(d);
        IAccessManager manager = IAccessManager(address(d.manager));
        bytes memory hostile =
            abi.encodeCall(IAccessManager.grantRole, (Roles.ADMIN, makeAddr("attacker"), 0));
        vm.prank(HOT_ADMIN);
        (bytes32 id,) = manager.schedule(address(manager), hostile, 0);
        assertEq(manager.getSchedule(id), block.timestamp + 30 days);
        vm.prank(GUARDIAN);
        manager.cancel(HOT_ADMIN, address(manager), hostile);
        assertEq(manager.getSchedule(id), 0);
    }

    function test_AddressesArePredictable() public {
        DeployV1.Params memory p = _params();
        DeployV1.Deployment memory d = DeployV1.deploy(p);
        bytes memory initcode =
            abi.encodePacked(type(GovernanceConfigurator).creationCode, abi.encode(p.deployer));
        address configurator = vm.computeCreate2Address(
            DeployV1.salt(p, "GovernanceConfigurator"), keccak256(initcode), address(this)
        );
        assertEq(address(d.configurator), configurator);
        assertEq(address(d.manager), vm.computeCreateAddress(configurator, 1));
    }

    function test_RecordedAddressesReload() public {
        (DeployV1.Deployment memory d,,) = _genesis(_params());
        DeployV1.Deployment memory reloaded;
        reloaded.cc0TextFileId = d.cc0TextFileId;
        string[22] memory names = DeployV1.names();
        for (uint256 i; i < names.length; ++i) {
            DeployV1.assign(reloaded, names[i], DeployV1.addressOf(d, names[i]));
        }
        assertEq(keccak256(abi.encode(reloaded)), keccak256(abi.encode(d)));
    }

    // ------------------------------------------------------------------ fail closed

    function test_TheStandInIsRefusedOffAnvil() public {
        DeployV1.Params memory p = _params();
        vm.chainId(11_155_111); // Sepolia
        vm.expectRevert(DeployV1.ArtistRegistryPending.selector);
        this.deployExternal(p);
    }

    function test_ReadbackCatchesAnUnappliedWire() public {
        (DeployV1.Deployment memory d,,) = _genesis(_params());
        GovernanceConfig.Call memory fake = GovernanceConfig.Call(
            address(d.fixedPriceSale),
            abi.encodeCall(ISaleAdapter.setTarget, (makeAddr("never listed"), true))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyV1.WiringNotApplied.selector,
                address(d.fixedPriceSale),
                ISaleAdapter.setTarget.selector
            )
        );
        this.checkWiredExternal(d, fake);
    }

    function test_ReadbackFailsBeforeTheDelaysSettle() public {
        (DeployV1.Deployment memory d, GovernanceConfig.Config memory cfg,) = _genesis(_params());
        vm.expectRevert(abi.encodeWithSelector(GovernanceConfig.RoleMismatch.selector, Roles.ADMIN));
        d.configurator.verify(cfg);
    }
}
