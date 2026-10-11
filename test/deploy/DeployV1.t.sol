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
import { ConsolidationAdapter } from "src/identity/ConsolidationAdapter.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IStream } from "src/interfaces/IStream.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_EDITIONS,
    PRODUCT_FEDERATED,
    PRODUCT_STREAM
} from "src/interfaces/types/EconomicsTypes.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { DeployGuards } from "script/DeployGuards.sol";
import { EconomicsResolver } from "src/economics/EconomicsResolver.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { Editions } from "src/editions/Editions.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { VerifyV1 } from "script/VerifyV1.sol";
import { MockVrfCoordinator } from "../mocks/EntropyMocks.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";

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
    /// The 6529 delegation contract's faithful reduction (the identity lane's).
    DelegationManagementMock internal delegation;

    function setUp() public {
        json = vm.readFile(GENESIS);
        manifest = DeployV1.Manifest(keccak256("epoch-0 manifest"), "ar://epoch-0");
        delegation = new DelegationManagementMock();
    }

    function _params() internal returns (DeployV1.Params memory p) {
        p.deployer = address(this);
        p.namespace = keccak256("6529-works/test");
        p.feeRecipient = makeAddr("feeRecipient");
        p.marketOwner = makeAddr("marketOwner");
        p.delegation = address(delegation);
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

    function checkPlatformPathExternal(
        DeployV1.Deployment memory d,
        GovernanceConfig.Config memory cfg
    ) external view {
        VerifyV1.checkPlatformPath(d, cfg);
    }

    function checkExternal(
        DeployV1.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        GovernanceConfig.Call[] memory calls
    ) external view {
        VerifyV1.check(d, cfg, calls);
    }

    function checkCc0External(DeployV1.Deployment memory d, bytes32 digest) external view {
        VerifyV1.checkCc0(d, digest);
    }

    function checkAddressesExternal(
        DeployV1.Deployment memory predicted,
        DeployV1.Deployment memory recorded
    ) external pure {
        VerifyV1.checkAddresses(predicted, recorded);
    }

    function configExternal(DeployV1.Deployment memory d, string memory genesis)
        external
        view
        returns (GovernanceConfig.Config memory)
    {
        return DeployV1.config(d, genesis);
    }

    function wiringExternal(DeployV1.Deployment memory d, string memory genesis)
        external
        view
        returns (GovernanceConfig.Call[] memory)
    {
        return DeployV1.wiring(d, genesis, manifest);
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
        // Every v1 contract with a governance map; the optional entropy module is not
        // deployed here.
        assertEq(cfg.targets.length, 14, "governed targets");
        assertEq(cfg.grants.length, 17, "holders");
        // Every wiring call in the genesis JSON: the binds, the admitted minters, the sale
        // targets, three default currencies and the manifest.
        assertEq(calls.length, 18, "wiring calls");
        _settle(d);
        VerifyV1.check(d, cfg, calls);

        // The real identity contracts, reading the delegation contract given.
        assertEq(address(d.consolidationAdapter.delegation()), address(delegation));
        assertEq(address(d.artistRegistry.consolidationSource()), address(d.consolidationAdapter));
        // 6529 Stream and its records satellite, wired both ways.
        assertEq(d.stream.workRecords(), address(d.workRecords));
        assertEq(d.workRecords.stream(), address(d.stream));
        assertEq(d.workRecords.cc0TextFileId(), d.cc0TextFileId, "CC0 default license text");
        assertEq(IPackageRegistry(address(d.packageRegistry)).stream(), address(d.stream));
        assertEq(d.artistRegistry.stream(), address(d.stream));
        assertTrue(d.stream.isAdmittedMinter(address(d.englishAuction)));
        assertTrue(d.englishAuction.isTarget(address(d.stream)));
        assertEq(d.stream.owner(), makeAddr("marketOwner"));
        // The real renderer, pinned by Stream.
        assertEq(d.stream.defaultRenderer(), address(d.renderer));
        assertEq(address(d.renderer.contentStore()), address(d.contentStore));
        assertEq(address(d.renderer.statementLog()), address(d.statementLog));
        assertEq(d.renderer.inlineThreshold(), d.renderer.DEFAULT_INLINE_THRESHOLD());
        // 6529 Editions, linked to Stream and its records, with the fixed-price and Dutch sales
        // as its minters and targets.
        assertEq(d.editions.stream(), address(d.stream));
        assertEq(d.stream.editions(), address(d.editions));
        assertEq(IPackageRegistry(address(d.packageRegistry)).editions(), address(d.editions));
        assertEq(d.editions.workRecords(), address(d.workRecords));
        assertTrue(d.editions.isAdmittedMinter(address(d.fixedPriceSale)));
        assertTrue(d.editions.isAdmittedMinter(address(d.dutchSale)));
        assertTrue(d.fixedPriceSale.isTarget(address(d.editions)));
        assertTrue(d.dutchSale.isTarget(address(d.editions)));
        assertEq(d.editions.owner(), makeAddr("marketOwner"));
        (uint64 count,) = IStatementLog(address(d.statementLog)).chainOf(address(d.manager), 0);
        assertEq(count, 1, "epoch-0 manifest recorded at genesis");
        // Auctions can start at once: every product has its default currency from genesis.
        bytes32[3] memory products = [PRODUCT_STREAM, PRODUCT_EDITIONS, PRODUCT_FEDERATED];
        for (uint256 i; i < products.length; ++i) {
            assertEq(d.assetAllowlist.defaultCurrency(products[i]), address(0), "ETH");
        }
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
        assertEq(cfg.targets.length, 15);
        assertEq(d.stream.entropyModule(), address(d.entropyModule));
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
        // Every contract, recomputed from its initcode (M-5); this test deploys from itself.
        DeployV1.Deployment memory predicted = DeployV1.predict(p, d.cc0TextFileId, address(this));
        assertEq(keccak256(abi.encode(predicted)), keccak256(abi.encode(d)), "predict == deploy");
        this.checkAddressesExternal(predicted, d);
    }

    function test_PredictionFollowsEveryConstructorParameter() public {
        DeployV1.Params memory p = _params();
        MockVrfCoordinator coordinator = new MockVrfCoordinator();
        p.vrfCoordinator = address(coordinator);
        p.vrfCoordinatorCodeHash = address(coordinator).codehash;
        p.vrf = VrfEntropyModule.VrfConfig(1, keccak256("key hash"), 200_000, 3, false);
        p.vrfRetryDelay = 3 days;
        DeployV1.Deployment memory d = DeployV1.deploy(p);
        this.checkAddressesExternal(DeployV1.predict(p, d.cc0TextFileId, address(this)), d);
        // A recorded parameter that differs moves the contracts that take it, and every one
        // that pins them after it.
        p.marketOwner = makeAddr("someone else");
        vm.expectPartialRevert(VerifyV1.AddressMismatch.selector);
        this.checkAddressesExternal(DeployV1.predict(p, d.cc0TextFileId, address(this)), d);
        p = _params();
        p.vrfCoordinator = address(coordinator);
        p.vrfCoordinatorCodeHash = address(coordinator).codehash;
        p.vrf = VrfEntropyModule.VrfConfig(1, keccak256("key hash"), 200_000, 3, false);
        p.vrfRetryDelay = 4 days;
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyV1.AddressMismatch.selector,
                "EntropyModule",
                DeployV1.predict(p, d.cc0TextFileId, address(this)).entropyModule,
                address(d.entropyModule)
            )
        );
        this.checkAddressesExternal(DeployV1.predict(p, d.cc0TextFileId, address(this)), d);
    }

    function test_RecordedAddressesReload() public {
        (DeployV1.Deployment memory d,,) = _genesis(_params());
        DeployV1.Deployment memory reloaded;
        reloaded.cc0TextFileId = d.cc0TextFileId;
        string[] memory names = DeployV1.names();
        for (uint256 i; i < names.length; ++i) {
            DeployV1.assign(reloaded, names[i], DeployV1.addressOf(d, names[i]));
        }
        assertEq(keccak256(abi.encode(reloaded)), keccak256(abi.encode(d)));
    }

    // ------------------------------------------------------------------ fail closed

    function test_TheLibraryDeploysTheSameSystemOffAnvil() public {
        // No stand-in remains: the library deploys the whole system on any chain (the guards
        // that differ off anvil are the scripts').
        DeployV1.Params memory p = _params();
        vm.chainId(11_155_111); // Sepolia
        DeployV1.Deployment memory d = this.deployExternal(p);
        assertTrue(address(d.renderer).code.length != 0);
        assertTrue(address(d.editions).code.length != 0);
    }

    function test_TheRolesTableMustBeRolesSol() public {
        DeployV1.Deployment memory d = DeployV1.deploy(_params());
        // FUNDS_SETTER's 14 days shortened to 48 hours in the published table.
        string memory edited = vm.replace(
            json,
            '"name": "FUNDS_SETTER",\n      "id": 10,\n      "executionClass": "funds",\n      "executionDelay": 1209600',
            '"name": "FUNDS_SETTER",\n      "id": 10,\n      "executionClass": "funds",\n      "executionDelay": 172800'
        );
        assertTrue(keccak256(bytes(edited)) != keccak256(bytes(json)), "edited");
        vm.expectRevert(abi.encodeWithSelector(DeployV1.RoleTableMismatch.selector, "FUNDS_SETTER"));
        this.configExternal(d, edited);
    }

    function test_TheRolesTableMustListEveryRoleOnce() public {
        DeployV1.Deployment memory d = DeployV1.deploy(_params());
        // The last role (CURATOR) removed from the published table.
        string memory curator = string.concat(
            "    },\n    {\n      \"name\": \"CURATOR\",\n      \"id\": 12,\n",
            "      \"executionClass\": \"immediate\",\n      \"executionDelay\": 0,\n",
            "      \"grantClass\": \"successor\",\n      \"grantDelay\": 2592000\n    }\n  ],"
        );
        string memory missing = vm.replace(json, curator, "    }\n  ],");
        assertTrue(keccak256(bytes(missing)) != keccak256(bytes(json)), "edited");
        vm.expectRevert(abi.encodeWithSelector(DeployV1.RoleTableMismatch.selector, "count"));
        this.configExternal(d, missing);
    }

    function test_DroppedListsWhatTheDeploymentLacks() public {
        DeployV1.Deployment memory d = DeployV1.deploy(_params());
        string[] memory gone = DeployV1.dropped(d, json);
        // Only the entropy module (no coordinator) is left out; no wiring names it.
        assertEq(gone.length, 1);
        assertEq(gone[0], "EntropyModule");
        // Without Editions, its target and every wiring call on or naming it would be.
        d.editions = Editions(address(0));
        gone = DeployV1.dropped(d, json);
        assertEq(gone.length, 9);
        assertEq(gone[0], "Editions");
        assertEq(gone[1], "EntropyModule");
        assertEq(gone[2], "Stream.bindEditions(address)");
    }

    function test_ADelegationAddressWithoutCodeIsRefused() public {
        DeployV1.Params memory p = _params();
        p.delegation = 0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d; // no code here, as on Sepolia
        vm.expectRevert(
            abi.encodeWithSelector(ConsolidationAdapter.NoDelegationCode.selector, p.delegation)
        );
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

    function test_ReadbackChecksTheDefaultCurrencyRevision() public {
        (DeployV1.Deployment memory d,,) = _genesis(_params());
        // Genesis wired revision 0, so the allowlist is at revision 1; a call claiming to have
        // wired revision 1 would have left it at 2.
        GovernanceConfig.Call memory claimed = GovernanceConfig.Call(
            address(d.assetAllowlist),
            abi.encodeCall(IAssetAllowlist.setDefaultCurrency, (PRODUCT_STREAM, 1, CURRENCY_ETH))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyV1.WiringNotApplied.selector,
                address(d.assetAllowlist),
                IAssetAllowlist.setDefaultCurrency.selector
            )
        );
        this.checkWiredExternal(d, claimed);
    }

    function test_ReadbackRejectsTruncatedWiringCalldata() public {
        (DeployV1.Deployment memory d,,) = _genesis(_params());
        // setTarget(address,bool) without its bool.
        GovernanceConfig.Call memory truncated = GovernanceConfig.Call(
            address(d.englishAuction),
            abi.encodePacked(ISaleAdapter.setTarget.selector, abi.encode(address(d.stream)))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyV1.MalformedWiringCall.selector, ISaleAdapter.setTarget.selector
            )
        );
        this.checkWiredExternal(d, truncated);
    }

    function test_ReadbackFailsClosedWhenAGetterIsMissing() public {
        (DeployV1.Deployment memory d,,) = _genesis(_params());
        // A zero bind argument must not match a getter that does not exist.
        GovernanceConfig.Call memory wrongTarget = GovernanceConfig.Call(
            address(d.assetAllowlist), abi.encodeCall(IStream.bindWorkRecords, (address(0)))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyV1.GetterFailed.selector, address(d.assetAllowlist), "workRecords()"
            )
        );
        this.checkWiredExternal(d, wrongTarget);
    }

    function test_AMalformedWiringSignatureIsReported() public {
        DeployV1.Deployment memory d = DeployV1.deploy(_params());
        string memory broken = vm.replace(json, '"bindWorkRecords(address)"', '"bindWorkRecords"');
        vm.expectRevert(
            abi.encodeWithSelector(DeployV1.UnsupportedWiringSignature.selector, "bindWorkRecords")
        );
        this.wiringExternal(d, broken);
    }

    // ------------------------------------------------------------------ readback guards

    function test_ReadbackNeedsAPlatformHolder() public {
        (DeployV1.Deployment memory d, GovernanceConfig.Config memory cfg,) = _genesis(_params());
        _settle(d);
        GovernanceConfig.Config memory without = _withoutRole(cfg, Roles.PLATFORM);
        vm.expectRevert(VerifyV1.PlatformHolderMissing.selector);
        this.checkPlatformPathExternal(d, without);
    }

    function test_ReadbackNeedsPlatformsImmediatePath() public {
        (DeployV1.Deployment memory d, GovernanceConfig.Config memory cfg,) = _genesis(_params());
        _settle(d);
        for (uint256 i; i < cfg.grants.length; ++i) {
            if (cfg.grants[i].role == Roles.PLATFORM) cfg.grants[i].account = makeAddr("no role");
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyV1.PlatformPathClosed.selector,
                address(d.fixedPriceSale),
                IFixedPriceSale.openSale.selector
            )
        );
        this.checkPlatformPathExternal(d, cfg);
    }

    function test_ReadbackCatchesARoleGrantedToTheConfigurator() public {
        (
            DeployV1.Deployment memory d,
            GovernanceConfig.Config memory cfg,
            GovernanceConfig.Call[] memory calls
        ) = _genesis(_params());
        // The hot admin grants the configurator a role (30-day ADMIN delay, not vetoed).
        _adminExecutes(
            d,
            address(d.manager),
            abi.encodeCall(IAccessManager.grantRole, (Roles.KEEPER, address(d.configurator), 0))
        );
        vm.expectRevert(
            abi.encodeWithSelector(VerifyV1.ConfiguratorHoldsRole.selector, Roles.KEEPER)
        );
        this.checkExternal(d, cfg, calls);
    }

    function test_ReadbackCatchesATargetMovedToAnotherAuthority() public {
        (
            DeployV1.Deployment memory d,
            GovernanceConfig.Config memory cfg,
            GovernanceConfig.Call[] memory calls
        ) = _genesis(_params());
        address elsewhere = address(new AccessManager(address(this)));
        _adminExecutes(
            d,
            address(d.manager),
            abi.encodeCall(IAccessManager.updateAuthority, (address(d.stream), elsewhere))
        );
        assertEq(IAccessManaged(address(d.stream)).authority(), elsewhere);
        vm.expectRevert(
            abi.encodeWithSelector(VerifyV1.WrongAuthority.selector, address(d.stream), elsewhere)
        );
        this.checkExternal(d, cfg, calls);
    }

    function test_ReadbackChecksTheDefaultLicenseText() public {
        (DeployV1.Deployment memory d,,) = _genesis(_params());
        bytes32 digest = sha256(_params().cc0Text);
        this.checkCc0External(d, digest);

        bytes32 wrong = sha256("another text");
        vm.expectRevert(abi.encodeWithSelector(VerifyV1.Cc0Mismatch.selector, "SHA-256"));
        this.checkCc0External(d, wrong);

        DeployV1.Deployment memory other = d;
        other.cc0TextFileId = bytes32(0);
        vm.expectRevert(
            abi.encodeWithSelector(VerifyV1.Cc0Mismatch.selector, "no CC0 file recorded")
        );
        this.checkCc0External(other, digest);

        // A file that WorkRecords does not name.
        other.cc0TextFileId = keccak256("another file");
        vm.expectRevert(
            abi.encodeWithSelector(VerifyV1.Cc0Mismatch.selector, "WorkRecords.cc0TextFileId")
        );
        this.checkCc0External(other, digest);

        // WorkRecords names it but the resolver does not; then both name an incomplete file.
        bytes32[] memory chunks = new bytes32[](1);
        chunks[0] = keccak256("never uploaded");
        bytes32 neverSha = sha256("never uploaded");
        bytes32 incomplete = d.contentStore
            .registerManifest(chunks, 14, IContentStore.Encoding.Identity, "text/plain", neverSha);
        Cc0Views views = new Cc0Views(incomplete, d.cc0TextFileId);
        other.cc0TextFileId = incomplete;
        other.workRecords = WorkRecords(address(views));
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyV1.Cc0Mismatch.selector, "EconomicsResolver.defaultLicense"
            )
        );
        this.checkCc0External(other, digest);
        other.economicsResolver = EconomicsResolver(address(new Cc0Views(incomplete, incomplete)));
        vm.expectRevert(
            abi.encodeWithSelector(VerifyV1.Cc0Mismatch.selector, "incomplete in the content store")
        );
        this.checkCc0External(other, digest);
    }

    function _withoutRole(GovernanceConfig.Config memory cfg, uint64 role)
        internal
        pure
        returns (GovernanceConfig.Config memory out)
    {
        out.targets = cfg.targets;
        uint256 n;
        for (uint256 i; i < cfg.grants.length; ++i) {
            if (cfg.grants[i].role != role) ++n;
        }
        out.grants = new GovernanceConfig.Grant[](n);
        uint256 k;
        for (uint256 i; i < cfg.grants.length; ++i) {
            if (cfg.grants[i].role != role) out.grants[k++] = cfg.grants[i];
        }
    }

    /// @dev The hot admin schedules `data` on `target`, waits the 30-day ADMIN delay unvetoed
    ///      and executes it.
    function _adminExecutes(DeployV1.Deployment memory d, address target, bytes memory data)
        internal
    {
        vm.prank(HOT_ADMIN);
        d.manager.schedule(target, data, 0);
        vm.warp(block.timestamp + 30 days);
        vm.prank(HOT_ADMIN);
        d.manager.execute(target, data);
    }

    function test_ReadbackFailsBeforeTheDelaysSettle() public {
        (DeployV1.Deployment memory d, GovernanceConfig.Config memory cfg,) = _genesis(_params());
        vm.expectRevert(abi.encodeWithSelector(GovernanceConfig.RoleMismatch.selector, Roles.ADMIN));
        d.configurator.verify(cfg);
    }
}

/// @dev Answers the two CC0 views `VerifyV1.checkCc0` reads: WorkRecords' file ID and every
///      product's default license.
contract Cc0Views {
    bytes32 internal immutable _records;
    bytes32 internal immutable _license;

    constructor(bytes32 records, bytes32 license) {
        _records = records;
        _license = license;
    }

    function cc0TextFileId() external view returns (bytes32) {
        return _records;
    }

    function defaultLicense(bytes32) external view returns (License memory) {
        return License("CC0-1.0", _license);
    }
}
