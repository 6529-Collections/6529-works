// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DeployCore } from "script/DeployCore.sol";
import { VerifyCore } from "script/VerifyCore.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { DependencyRegistry } from "src/content/DependencyRegistry.sol";
import { Renderer } from "src/content/Renderer.sol";
import { Directory } from "src/core/Directory.sol";
import { Editions } from "src/core/Editions.sol";
import { Stream } from "src/core/Stream.sol";
import { WorkFacts } from "src/core/WorkFacts.sol";
import { Eip712CurationVerifier } from "src/curation/Eip712CurationVerifier.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { ClaimRouter } from "src/economics/ClaimRouter.sol";
import { EconomicsResolver } from "src/economics/EconomicsResolver.sol";
import { GovernedVault } from "src/economics/GovernedVault.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { ConsolidationAdapter } from "src/identity/ConsolidationAdapter.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { WorkRules } from "src/records/WorkRules.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { SaleStarter } from "src/sales/SaleStarter.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { UniformEditionAuctionLens } from "src/sales/UniformEditionAuctionLens.sol";
import { WorkDelivery } from "src/stream/WorkDelivery.sol";
import { StreamTerms } from "src/terms/StreamTerms.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { MockVrfCoordinator } from "../mocks/entropy/EntropyMocks.sol";

/// @notice The whole plain-core stack for the end-to-end suites, deployed and configured by the
///         deploy library (`script/DeployCore.sol`), the same code the deploy script broadcasts,
///         with the governance policy of `config/genesis.core.example.json` (its placeholder
///         holders replaced by this test's actors, so the curation signers are keys the test
///         holds). The network is one key that accepts in `setUp`; `VerifyCore` reads the whole
///         deployment back before any test runs.
/// @dev Only external systems are mocked: the 6529 delegation contract (the identity lane's
///      reduction) and the Chainlink VRF v2.5 coordinator (the entropy lane's mock). Every
///      module is the real contract, built by `DeployCore.deploy` with its real constructor.
abstract contract CoreIntegrationBase is Test {
    /// @dev Every start row, as a whole transaction in Prague gas, is at most this (ADR 0010).
    uint256 internal constant START_BUDGET = 370_000;
    /// @dev New storage slots a start may write, with or without a bid (ADR 0010).
    uint256 internal constant START_MAX_SLOTS = 8;
    /// @dev EIP-7825: no transaction may carry more than 2^24 gas.
    uint256 internal constant TX_GAS_CAP = 1 << 24;

    string internal constant GENESIS = "config/genesis.core.example.json";
    string internal constant CC0_FIXTURE = "test/fixtures/cc0-legalcode.txt";

    DeployCore.Deployment internal deployment;
    DeployCore.Params internal params;
    DeployCore.Manifest internal manifest;
    /// @dev The genesis configuration is rebuilt on demand (`_genesisConfig`): a struct with
    ///      dynamic arrays of structs cannot be copied to storage by the legacy pipeline.
    string internal genesisJson;

    // ------------------------------------------------------------------ genesis holders
    /// @dev The network: one address holding every network role (a 2-of-n Safe today).
    address internal network = makeAddr("network");
    address internal deployer = makeAddr("deployer");
    address internal marketOwner = makeAddr("marketOwner");
    /// @dev The first destinations of the two governed vaults.
    address internal museumSafe = makeAddr("museumSafe");
    address internal feeSafe = makeAddr("feeSafe");
    address internal pauser1 = makeAddr("pauserKey1");
    address internal pauser2 = makeAddr("pauserKey2");
    address internal pauser3 = makeAddr("pauserKey3");
    uint256 internal signer1Pk = uint256(keccak256("curation signer 1"));
    uint256 internal signer2Pk = uint256(keccak256("curation signer 2"));
    address internal signer1 = vm.addr(signer1Pk);
    address internal signer2 = vm.addr(signer2Pk);
    address internal storageOperator = makeAddr("storageOperator");
    address internal platform = makeAddr("platform");
    address internal curator = makeAddr("curator");

    // ------------------------------------------------------------------ external systems
    DelegationManagementMock internal delegation;
    MockVrfCoordinator internal coordinator;

    // ------------------------------------------------------------------ typed handles
    WorksAccessManager internal manager;
    GovernanceConfigurator internal configurator;
    ContentStore internal store;
    WorkFacts internal facts;
    Directory internal directory;
    SplitLedger internal ledger;
    ClaimRouter internal claimRouter;
    RevenueEscrow internal escrow;
    Stream internal stream;
    Editions internal editions;
    GovernedVault internal feeVault;
    GovernedVault internal museumVault;
    /// @dev The network fee recipient the resolver names (the fee vault) and the museum (the
    ///      museum vault), where an unsold 6529 Stream work goes.
    address internal networkFee;
    address internal museum;
    ConsolidationAdapter internal consolidation;
    Accounts internal accounts;
    AssetAllowlist internal allowlist;
    EconomicsResolver internal economics;
    Eip712CurationVerifier internal verifier;
    PackageRegistry internal registry;
    StatementLog internal statements;
    VrfEntropyModule internal entropy;
    DependencyRegistry internal dependencies;
    Renderer internal renderer;
    WorkRules internal rules;
    WorkDelivery internal delivery;
    StreamTerms internal terms;
    EnglishAuction internal auction;
    UniformEditionAuction internal editionAuction;
    UniformEditionAuctionLens internal editionLens;
    FederationRegistry internal federation;
    SaleStarter internal starter;
    bytes32 internal cc0TextFileId;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        delegation = new DelegationManagementMock();
        coordinator = new MockVrfCoordinator();
        params = _params();
        deployment = DeployCore.deploy(params, address(this));
        _adopt(deployment);
        manifest = DeployCore.Manifest(keccak256("integration manifest"), "ar://integration");
        genesisJson = _withHolders(vm.readFile(GENESIS));
        GovernanceConfig.Config memory cfg = DeployCore.config(deployment, genesisJson);
        cfg.network = network;

        GovernanceConfig.Call[] memory calls = DeployCore.wiring(deployment, genesisJson, manifest);
        vm.prank(deployer);
        DeployCore.install(deployment, cfg, manifest, calls);
        vm.prank(network);
        manager.acceptNetwork();
        VerifyCore.verify(params, deployment, cfg, true);
    }

    /// @dev The deployment's parameters. Suites override pieces (the VRF coordinator).
    function _params() internal view virtual returns (DeployCore.Params memory p) {
        p.deployer = deployer;
        p.namespace = keccak256("6529-works/core-integration");
        p.feeRecipient = feeSafe;
        p.museum = museumSafe;
        p.marketOwner = marketOwner;
        p.delegation = address(delegation);
        p.cc0Text = vm.readFileBinary(CC0_FIXTURE);
        p.ethIncrementFloor = 0.001 ether;
        p.auctionConfig = DeployCore.auctionConfig();
        p.editionAuctionConfig = DeployCore.editionAuctionConfig();
        if (_withVrf()) {
            p.vrfCoordinator = address(coordinator);
            p.vrfCoordinatorCodeHash = address(coordinator).codehash;
            p.vrf = VrfEntropyModule.VrfConfig(1, keccak256("vrf key hash"), 500_000, 3, false);
            p.vrfRetryDelay = 3 days;
        }
    }

    /// @dev Whether the deployment includes the entropy module (a suite with VRF works).
    function _withVrf() internal view virtual returns (bool) {
        return false;
    }

    function _adopt(DeployCore.Deployment memory d) private {
        cc0TextFileId = d.cc0TextFileId;
        manager = d.manager;
        configurator = d.configurator;
        store = d.contentStore;
        facts = d.workFacts;
        directory = d.directory;
        ledger = d.splitLedger;
        claimRouter = d.claimRouter;
        escrow = RevenueEscrow(payable(d.revenueEscrow));
        stream = d.stream;
        editions = d.editions;
        feeVault = d.feeRecipientVault;
        museumVault = d.museumVault;
        networkFee = address(d.feeRecipientVault);
        museum = address(d.museumVault);
        consolidation = ConsolidationAdapter(d.consolidationAdapter);
        accounts = Accounts(d.accounts);
        allowlist = AssetAllowlist(d.assetAllowlist);
        economics = EconomicsResolver(d.economicsResolver);
        verifier = Eip712CurationVerifier(d.curationVerifier);
        registry = PackageRegistry(d.packageRegistry);
        statements = StatementLog(d.statementLog);
        entropy = VrfEntropyModule(d.entropyModule);
        dependencies = DependencyRegistry(d.dependencyRegistry);
        renderer = Renderer(d.renderer);
        rules = WorkRules(d.workRules);
        delivery = WorkDelivery(d.workDelivery);
        terms = StreamTerms(d.streamTerms);
        auction = EnglishAuction(payable(d.englishAuction));
        editionAuction = UniformEditionAuction(payable(d.editionAuction));
        editionLens = UniformEditionAuctionLens(d.editionAuctionLens);
        federation = FederationRegistry(d.federationRegistry);
        starter = SaleStarter(d.saleStarter);
        vm.label(address(stream), "Stream");
        vm.label(address(editions), "Editions");
        vm.label(address(facts), "WorkFacts");
        vm.label(address(directory), "Directory");
        vm.label(address(ledger), "SplitLedger");
        vm.label(address(escrow), "RevenueEscrow");
        vm.label(address(store), "ContentStore");
        vm.label(address(manager), "WorksAccessManager");
        vm.label(address(accounts), "Accounts");
        vm.label(address(registry), "PackageRegistry");
        vm.label(address(statements), "StatementLog");
        vm.label(address(renderer), "Renderer");
        vm.label(address(rules), "WorkRules");
        vm.label(address(delivery), "WorkDelivery");
        vm.label(address(terms), "StreamTerms");
        vm.label(address(auction), "EnglishAuction");
        vm.label(address(editionAuction), "UniformEditionAuction");
        vm.label(address(federation), "FederationRegistry");
        vm.label(address(economics), "EconomicsResolver");
        vm.label(networkFee, "feeVault");
        vm.label(museum, "museumVault");
    }

    /// @dev The committed genesis JSON with each placeholder holder (`0x...b0xx`) replaced by
    ///      this test's actor for it.
    function _withHolders(string memory json) internal view returns (string memory) {
        address[8] memory actors =
            [pauser1, pauser2, pauser3, signer1, signer2, storageOperator, platform, curator];
        uint16[8] memory placeholders =
            [0xb011, 0xb012, 0xb013, 0xb021, 0xb022, 0xb031, 0xb051, 0xb061];
        for (uint256 i; i < 8; ++i) {
            string memory from = vm.toLowercase(vm.toString(address(uint160(placeholders[i]))));
            json = vm.replace(json, from, vm.toString(actors[i]));
        }
        return json;
    }

    /// @dev The genesis configuration `install` applied, with the network set.
    function _genesisConfig() internal view returns (GovernanceConfig.Config memory cfg) {
        cfg = DeployCore.config(deployment, genesisJson);
        cfg.network = network;
    }

    /// @dev The manager, typed.
    function _manager() internal view returns (WorksAccessManager) {
        return deployment.manager;
    }

    // ------------------------------------------------------------------ governed actions

    /// @dev Runs a governed call as `caller` the way the AccessManager allows it: directly for a
    ///      zero-delay role, otherwise scheduled, waited out and executed.
    function _govern(address caller, address target, bytes memory data) internal {
        (bool immediate, uint32 delay) = manager.canCall(caller, target, bytes4(data));
        if (immediate) {
            vm.prank(caller);
            (bool ok, bytes memory reason) = target.call(data);
            _bubble(ok, reason);
            return;
        }
        require(delay != 0, "caller has no role for this selector");
        vm.prank(caller);
        manager.schedule(target, data, 0);
        vm.warp(block.timestamp + delay);
        vm.prank(caller);
        manager.execute(target, data);
    }

    /// @dev A network call (every core module, minter and setting function is NETWORK with no
    ///      role delay).
    function _asNetwork(address target, bytes memory data) internal {
        _govern(network, target, data);
    }

    function _bubble(bool ok, bytes memory reason) internal pure {
        if (ok) return;
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}
