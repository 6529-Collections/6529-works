// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Vm } from "forge-std/Vm.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { StreamDirectory6529 } from "src/core/StreamDirectory6529.sol";
import { StreamEditions6529 } from "src/core/StreamEditions6529.sol";
import { Stream6529 } from "src/core/Stream6529.sol";
import { StreamWorkFacts6529 } from "src/core/StreamWorkFacts6529.sol";
import { ClaimRouter } from "src/economics/ClaimRouter.sol";
import { GovernedVault } from "src/economics/GovernedVault.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IStatementLog, Statement } from "src/interfaces/IStatementLog.sol";
import { HashRef, HASH_SHA256 } from "src/interfaces/types/HashRef.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { CoreFactory } from "./CoreFactory.sol";

/// @title DeployCore
/// @notice Deploys the plain-core stack (ADR 0010) and installs its genesis configuration.
/// @dev Every contract is created by a `CoreFactory` owned by the deployer, in one call that
///      only the deployer may make: a one-use proxy at a CREATE2 address that depends only on
///      the factory and the contract's name creates the contract in the same call. So every
///      address is known before anything is deployed, nobody else can create code at one, and
///      the token contracts and `StreamDirectory6529` take their genesis modules and minters as
///      constructor arguments even though those modules are deployed after them. The factory's
///      own address commits to the namespace and the deployer. An address does not commit to
///      code: `VerifyCore` compares every contract's runtime code with a reference deployment
///      of the same build and reads back the wiring.
///
///      Order (each contract only needs code at the addresses it calls in its constructor):
///      governance, ContentStore (and the CC0 text), WorkFacts, Directory, the two governed
///      vaults, SplitLedger (with Directory as its payout resolver), ClaimRouter, RevenueEscrow,
///      Stream, Editions, then the replaceable modules. A module's constructor may store the
///      address of a token contract or of Directory but must not call it before it exists;
///      the permanent contracts never call a module in their constructors.
///
///      The replaceable modules are created from their build artifacts (`vm.getCode`), so this
///      library does not import their sources; each constructor is written once, in
///      `_moduleCode` and `_moduleCodeLater`.
library DeployCore {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Anvil's chain ID.
    uint256 internal constant LOCAL_CHAIN_ID = 31337;
    /// @notice Schema of the governance manifest statements in the statement log.
    bytes32 internal constant MANIFEST_SCHEMA = keccak256("6529-works/governance-manifest/1");
    /// @notice The SHA-256 of the CC0 1.0 Universal legal code in plain text (7,048 bytes), the
    ///         default license text of every work.
    bytes32 internal constant CC0_LEGALCODE_SHA256 =
        0xa2010f343487d3f7618affe54f789f5487602331c0a8d03f49e9a7c547cf0499;
    /// @notice The default renderer's inline threshold, 256 KiB.
    uint256 internal constant RENDERER_INLINE_THRESHOLD = 262_144;
    /// @notice The CREATE3 proxy's creation code (as in `CoreFactory`): its runtime creates a
    ///         contract from the calldata with CREATE, so the contract's address is the proxy's
    ///         first CREATE address.
    bytes internal constant PROXY_INITCODE = hex"67363d3d37363d34f03d5260086018f3";
    /// @notice The public CREATE2 deployer a script under broadcast creates through.
    address internal constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice The launch value of every module's and minter's waiting period (`moduleDelay`).
    uint48 internal constant LAUNCH_MODULE_DELAY = 7 days;
    /// @notice The launch value of `Stream6529.rescueDelay`.
    uint48 internal constant LAUNCH_RESCUE_DELAY = 14 days;
    /// @notice The launch value of `StreamEditions6529.rebindDelay`.
    uint48 internal constant LAUNCH_REBIND_DELAY = 14 days;
    /// @notice The launch value of `StreamDirectory6529.unclaimedPeriod`.
    uint48 internal constant LAUNCH_UNCLAIMED_PERIOD = 180 days;
    /// @notice How many entries of `order` are the permanent part (through `StreamEditions6529`).
    uint256 internal constant PERMANENT_COUNT = 11;

    struct Params {
        /// The operator account that broadcasts the genesis and alone may call `configure`.
        address deployer;
        /// Salt namespace; one namespace deploys one system.
        bytes32 namespace;
        /// The first destination of the network fee recipient's governed vault.
        address feeRecipient;
        /// The first destination of the museum's governed vault.
        address museum;
        /// The marketplace `owner()` of Stream and Editions. No protocol power.
        address marketOwner;
        /// The 6529 delegation contract the consolidation adapter reads. It must have code.
        address delegation;
        /// The CC0 1.0 Universal legal code, plain text, stored at genesis.
        bytes cc0Text;
        /// Minimum ETH bid increment.
        uint256 ethIncrementFloor;
        /// The English auction's governed configuration, ABI-encoded as its constructor takes
        /// it (static words only).
        bytes auctionConfig;
        /// Both edition auctions' configuration and limits, ABI-encoded as their constructors
        /// take them (static words only).
        bytes editionAuctionConfig;
        /// Chainlink VRF v2.5 coordinator, or zero to deploy without the entropy module.
        address vrfCoordinator;
        bytes32 vrfCoordinatorCodeHash;
        VrfEntropyModule.VrfConfig vrf;
        uint64 vrfRetryDelay;
    }

    /// @notice Every deployed address. Modules are plain addresses: their types belong to the
    ///         lanes that write them.
    struct Deployment {
        bytes32 cc0TextFileId;
        /// The deployer's `CoreFactory`, which created every contract below.
        address coreFactory;
        GovernanceConfigurator configurator;
        WorksAccessManager manager;
        ContentStore contentStore;
        StreamWorkFacts6529 workFacts;
        StreamDirectory6529 directory;
        GovernedVault feeRecipientVault;
        GovernedVault museumVault;
        SplitLedger splitLedger;
        ClaimRouter claimRouter;
        address revenueEscrow;
        Stream6529 stream;
        StreamEditions6529 editions;
        // modules
        address consolidationAdapter;
        address accounts;
        address assetAllowlist;
        address economicsResolver;
        address curationVerifier;
        address packageRegistry;
        address statementLog;
        address entropyModule;
        address dependencyRegistry;
        address renderer;
        address workRules;
        address workDelivery;
        address streamTerms;
        address englishAuction;
        address editionAuctionLens;
        address editionAuction;
        address independentStreamRegistry;
        address independentStream721Deployer;
        address independentStreamEditionsDeployer;
        address independentEditionAuctionLens;
        address independentEditionAuction;
        address saleStarter;
    }

    /// @notice The constructor wiring of `Accounts` (`Accounts.Wiring`, field for field).
    struct AccountsWiring {
        address directory;
        address stream;
        address editions;
        address splitFactory;
        address statementLog;
        address packageRegistry;
        address previous;
    }

    /// @notice The epoch-0 governance manifest.
    struct Manifest {
        bytes32 digest;
        string uri;
    }

    error UnknownContract(string name);
    error CreateFailed(string name);
    error EmptyText();
    error RoleTableMismatch(string role);
    error UnknownRoleName(string name);
    error UnsupportedWiringSignature(string signature);

    // ------------------------------------------------------------------ genesis parameters

    /// @notice The English auction's genesis configuration, encoded as its constructor takes it:
    ///         a 24-hour auction, a 15-minute extension window, a 5% minimum increment
    ///         (5,000 of 100,000) and 4,000,000 gas for a refusal attempt. Each is governed
    ///         after genesis.
    function auctionConfig() internal pure returns (bytes memory) {
        return abi.encode(IEnglishAuction.AuctionConfig(24 hours, 15 minutes, 5_000, 4_000_000));
    }

    /// @notice Both edition auctions' genesis configuration and limit, encoded as their
    ///         constructors take them: 0.0001 ETH at step 0, 48 steps per decade over 336 steps,
    ///         a 10% breadth margin (10,000 of 100,000), a 5-minute soft close, a 24-hour
    ///         extension backstop, and 100,000 gas per settlement payout. Each is governed after
    ///         genesis.
    function editionAuctionConfig() internal pure returns (bytes memory) {
        return abi.encode(
            IUniformEditionAuction.AuctionConfig({
                basePrice: 0.0001 ether,
                stepsPerDecade: 48,
                stepCount: 336,
                marginShare: 10_000,
                softWindow: 5 minutes,
                maxExtension: 24 hours
            }),
            IUniformEditionAuction.Limits({ payoutGas: 100_000 })
        );
    }

    // ------------------------------------------------------------------ deployment

    /// @notice Deploys every contract in `order(p)` from the calling context (a script under
    ///         broadcast, or a test). Addresses equal `predict(p, factory)`, where `factory` is
    ///         the CREATE2 deployer of that context: `CREATE2_FACTORY` in a script, whose calls
    ///         are sent by `p.deployer`; in a test, the calling contract itself, which then
    ///         also sends the calls (see `sender`).
    function deploy(Params memory p, address factory) internal returns (Deployment memory d) {
        d = deployPermanent(p, factory);
        deployModules(p, d);
    }

    /// @notice Deploys the contracts of `order(p)` after the permanent part, through the
    ///         `CoreFactory` of `d`, which `deployPermanent` created.
    function deployModules(Params memory p, Deployment memory d) internal {
        string[] memory list = order(p);
        for (uint256 i = PERMANENT_COUNT; i < list.length; ++i) {
            _create(d.coreFactory, list[i], salt(p, list[i]), initcode(p, d, list[i]));
        }
    }

    /// @notice Deploys the first `PERMANENT_COUNT` contracts of `order(p)`: governance, the
    ///         content store, WorkFacts, Directory, the vaults, the split ledger, the claim
    ///         router, the escrow, Stream and Editions. The token contracts and Directory are
    ///         created with the predicted addresses of their genesis modules and minters, which
    ///         `deploy` creates next. Tests use it alone with stand-in modules.
    function deployPermanent(Params memory p, address factory)
        internal
        returns (Deployment memory d)
    {
        d = predict(p, factory);
        _createFactory(p, factory, d.coreFactory);
        string[] memory list = order(p);
        for (uint256 i; i < PERMANENT_COUNT; ++i) {
            string memory name = list[i];
            _create(d.coreFactory, name, salt(p, name), initcode(p, d, name));
            if (_eq(name, "ContentStore")) {
                d.cc0TextFileId = uploadText(d.contentStore, p.cc0Text, "text/plain");
            }
        }
    }

    /// @notice Every address `deploy(p, factory)` creates, from the salts alone (the CC0 file
    ///         ID is filled in by `deploy`).
    function predict(Params memory p, address factory) internal pure returns (Deployment memory d) {
        d.coreFactory = factoryAddress(p, factory);
        string[] memory list = order(p);
        for (uint256 i; i < list.length; ++i) {
            assign(d, list[i], addressFor(p, list[i], factory));
        }
        d.manager = WorksAccessManager(vm.computeCreateAddress(address(d.configurator), 1));
    }

    /// @notice The account that sends the creation calls and owns the `CoreFactory`:
    ///         `p.deployer` in a script (CREATE2 deployer `CREATE2_FACTORY`), otherwise `factory`
    ///         itself (a test is its own CREATE2 deployer and sends its own calls).
    function sender(Params memory p, address factory) internal pure returns (address) {
        return factory == CREATE2_FACTORY ? p.deployer : factory;
    }

    /// @notice The `CoreFactory`'s creation code for `p` (its owner is `sender(p, factory)`).
    function factoryInitcode(Params memory p, address factory)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(type(CoreFactory).creationCode, abi.encode(sender(p, factory)));
    }

    /// @notice The `CoreFactory`'s address: CREATE2 by `factory` from the namespace and its
    ///         creation code, which names the owner.
    function factoryAddress(Params memory p, address factory) internal pure returns (address) {
        return vm.computeCreate2Address(
            salt(p, "CoreFactory"), keccak256(factoryInitcode(p, factory)), factory
        );
    }

    /// @notice The address of contract `name` under `p.namespace`, created by the `CoreFactory`
    ///         of `p` and CREATE2 deployer `factory`.
    function addressFor(Params memory p, string memory name, address factory)
        internal
        pure
        returns (address)
    {
        address proxy = vm.computeCreate2Address(
            salt(p, name), keccak256(PROXY_INITCODE), factoryAddress(p, factory)
        );
        return vm.computeCreateAddress(proxy, 1);
    }

    /// @notice The contracts `deploy` creates, in order. The entropy module only with a VRF
    ///         coordinator; the manager is created by the configurator.
    function order(Params memory p) internal pure returns (string[] memory list) {
        string[31] memory all = [
            "GovernanceConfigurator",
            "ContentStore",
            "StreamWorkFacts6529",
            "StreamDirectory6529",
            "FeeRecipientVault",
            "MuseumVault",
            "SplitFactory",
            "ClaimRouter",
            "RevenueEscrow",
            "Stream6529",
            "StreamEditions6529",
            "ConsolidationAdapter",
            "Accounts",
            "AssetAllowlist",
            "EconomicsResolver",
            "CurationVerifier",
            "PackageRegistry",
            "StatementLog",
            "DependencyRegistry",
            "Renderer",
            "WorkRules",
            "WorkDelivery",
            "StreamTerms",
            "EnglishAuction",
            "UniformEditionAuctionLens",
            "UniformEditionAuction",
            "IndependentStreamRegistry",
            "IndependentStream721Deployer",
            "IndependentStreamEditionsDeployer",
            "IndependentEditionAuctionLens",
            "IndependentEditionAuction"
        ];
        bool vrf = p.vrfCoordinator != address(0);
        list = new string[](all.length + 1 + (vrf ? 1 : 0));
        uint256 k;
        for (uint256 i; i < all.length; ++i) {
            list[k++] = all[i];
            if (vrf && _eq(all[i], "PackageRegistry")) list[k++] = "EntropyModule";
        }
        list[k] = "SaleStarter";
    }

    /// @notice The contracts of the deployment the accounts module refuses as a payout by
    ///         address: the ones that neither declare a network interface (ERC-165) nor are
    ///         governed by the AccessManager, so no rule of the module recognises them.
    function notPayouts(Deployment memory d) internal pure returns (address[] memory list) {
        list = new address[](10);
        list[0] = d.coreFactory;
        list[1] = address(d.configurator);
        list[2] = address(d.contentStore);
        list[3] = address(d.workFacts);
        list[4] = d.renderer;
        list[5] = d.editionAuctionLens;
        list[6] = d.independentStream721Deployer;
        list[7] = d.independentStreamEditionsDeployer;
        list[8] = d.independentEditionAuctionLens;
        list[9] = d.saleStarter;
    }

    /// @notice The creation code and constructor arguments of contract `name`, given every
    ///         predicted address in `d`. Code hashes a constructor pins are read from the chain,
    ///         so `deploy` must have created the dependency first (as `order` does).
    function initcode(Params memory p, Deployment memory d, string memory name)
        internal
        view
        returns (bytes memory)
    {
        bytes32 n = keccak256(bytes(name));
        address m = address(d.manager);
        if (n == keccak256("GovernanceConfigurator")) {
            return bytes.concat(type(GovernanceConfigurator).creationCode, abi.encode(p.deployer));
        }
        if (n == keccak256("ContentStore")) return type(ContentStore).creationCode;
        if (n == keccak256("StreamWorkFacts6529")) {
            return bytes.concat(
                type(StreamWorkFacts6529).creationCode, abi.encode(d.contentStore, d.cc0TextFileId)
            );
        }
        if (n == keccak256("StreamDirectory6529")) {
            // The genesis shared modules: one WorkRules and one StreamTerms serve both 6529
            // Stream and every Independent Stream token (both are keyed by token).
            return bytes.concat(
                type(StreamDirectory6529).creationCode,
                abi.encode(m, d.accounts, d.independentStreamRegistry, d.streamTerms, d.workRules)
            );
        }
        if (n == keccak256("FeeRecipientVault")) {
            return bytes.concat(type(GovernedVault).creationCode, abi.encode(m, p.feeRecipient));
        }
        if (n == keccak256("MuseumVault")) {
            return bytes.concat(type(GovernedVault).creationCode, abi.encode(m, p.museum));
        }
        if (n == keccak256("SplitFactory")) {
            // The split ledger asks Directory for payout addresses and for the unclaimed period.
            return bytes.concat(
                type(SplitLedger).creationCode, abi.encode(d.directory, d.feeRecipientVault)
            );
        }
        if (n == keccak256("ClaimRouter")) {
            return bytes.concat(type(ClaimRouter).creationCode, abi.encode(d.splitLedger));
        }
        if (n == keccak256("RevenueEscrow")) {
            return bytes.concat(type(RevenueEscrow).creationCode, abi.encode(m, d.splitLedger));
        }
        if (n == keccak256("Stream6529")) {
            address[] memory minters = new address[](1);
            minters[0] = d.englishAuction;
            return bytes.concat(
                type(Stream6529).creationCode,
                abi.encode(
                    m, d.workFacts, p.marketOwner, d.renderer, d.streamTerms, d.workRules, minters
                )
            );
        }
        if (n == keccak256("StreamEditions6529")) {
            address[] memory minters = new address[](1);
            minters[0] = d.editionAuction;
            return bytes.concat(
                type(StreamEditions6529).creationCode,
                abi.encode(m, d.stream, p.marketOwner, d.streamTerms, minters)
            );
        }
        return _moduleCode(p, d, n, name);
    }

    /// @dev The replaceable modules, created from their build artifacts.
    function _moduleCode(Params memory p, Deployment memory d, bytes32 n, string memory name)
        private
        view
        returns (bytes memory)
    {
        address m = address(d.manager);
        if (n == keccak256("ConsolidationAdapter")) {
            return
                _artifact("ConsolidationAdapter.sol:ConsolidationAdapter", abi.encode(p.delegation));
        }
        if (n == keccak256("Accounts")) {
            // The consolidation source is pinned by code hash; the rest of the wiring is plain
            // addresses (directory, Stream, Editions, split ledger, statement log, package
            // registry), several of them deployed after this module. The first accounts
            // module replaces none (`previous` is zero), and it is given the contracts of the
            // deployment it must refuse as a payout by address.
            address adapter = d.consolidationAdapter;
            AccountsWiring memory w = AccountsWiring(
                address(d.directory),
                address(d.stream),
                address(d.editions),
                address(d.splitLedger),
                d.statementLog,
                d.packageRegistry,
                address(0)
            );
            return _artifact(
                "Accounts.sol:Accounts", abi.encode(m, adapter, adapter.codehash, w, notPayouts(d))
            );
        }
        if (n == keccak256("AssetAllowlist")) {
            return
                _artifact("AssetAllowlist.sol:AssetAllowlist", abi.encode(m, p.ethIncrementFloor));
        }
        if (n == keccak256("EconomicsResolver")) {
            return _artifact(
                "EconomicsResolver.sol:EconomicsResolver",
                abi.encode(
                    m,
                    d.assetAllowlist,
                    d.splitLedger,
                    d.feeRecipientVault,
                    d.museumVault,
                    d.cc0TextFileId
                )
            );
        }
        if (n == keccak256("CurationVerifier")) {
            return _artifact("Eip712CurationVerifier.sol:Eip712CurationVerifier", abi.encode(m));
        }
        if (n == keccak256("PackageRegistry")) {
            // The accounts module and the curation verifier are pinned by code hash. It starts
            // with no entropy module (the module pins this registry's code hash, so it is
            // deployed after it); the genesis wiring sets it (`setEntropyModule`) and binds
            // Stream (`bindStream`). The first mint policy replaces none (`previous` is zero).
            address verifier = d.curationVerifier;
            return _artifact(
                "PackageRegistry.sol:PackageRegistry",
                abi.encode(
                    m,
                    verifier,
                    verifier.codehash,
                    d.directory,
                    d.economicsResolver,
                    address(0),
                    d.cc0TextFileId,
                    address(0)
                )
            );
        }
        if (n == keccak256("StatementLog")) {
            // Its artist resolver is the accounts module (code-pinned, as today).
            return _artifact(
                "StatementLog.sol:StatementLog", abi.encode(m, d.accounts, d.accounts.codehash)
            );
        }
        if (n == keccak256("EntropyModule")) {
            address registry = d.packageRegistry;
            return bytes.concat(
                type(VrfEntropyModule).creationCode,
                abi.encode(
                    m,
                    p.vrfCoordinator,
                    p.vrfCoordinatorCodeHash,
                    p.vrf,
                    p.vrfRetryDelay,
                    registry,
                    registry.codehash,
                    d.directory
                )
            );
        }
        if (n == keccak256("DependencyRegistry")) {
            return
                _artifact(
                    "DependencyRegistry.sol:DependencyRegistry", abi.encode(m, d.contentStore)
                );
        }
        if (n == keccak256("Renderer")) {
            // The renderer finds WorkFacts through each token's `facts()`.
            return _artifact(
                "Renderer.sol:Renderer",
                abi.encode(d.contentStore, d.statementLog, RENDERER_INLINE_THRESHOLD)
            );
        }
        return _moduleCodeLater(p, d, n, name);
    }

    function _moduleCodeLater(Params memory p, Deployment memory d, bytes32 n, string memory name)
        private
        view
        returns (bytes memory)
    {
        address m = address(d.manager);
        if (n == keccak256("WorkRules")) {
            // One token-keyed instance serves Stream and every Independent Stream token; its
            // delivery contract is deployed next, at its predicted address.
            return _artifact(
                "WorkRules.sol:WorkRules", abi.encode(m, d.workFacts, d.directory, d.workDelivery)
            );
        }
        if (n == keccak256("WorkDelivery")) {
            return _artifact(
                "WorkDelivery.sol:WorkDelivery",
                abi.encode(m, d.workRules, d.workFacts, d.directory)
            );
        }
        if (n == keccak256("StreamTerms")) {
            // Manager, split ledger (vault derivation), 6529 Stream and its Editions
            // (`editionsOf`), Directory (Independent Stream fee shares).
            return _artifact(
                "StreamTerms.sol:StreamTerms",
                abi.encode(m, d.splitLedger, d.stream, d.editions, d.directory)
            );
        }
        if (n == keccak256("EnglishAuction")) {
            // ETH only. The mint policy for 6529 Stream is the package registry; for Independent
            // Stream tokens it is the directory's INDEPENDENT_STREAM module.
            return _artifact(
                "EnglishAuction.sol:EnglishAuction",
                bytes.concat(
                    abi.encode(
                        m,
                        d.stream,
                        d.directory,
                        d.economicsResolver,
                        d.revenueEscrow,
                        d.statementLog,
                        d.packageRegistry
                    ),
                    p.auctionConfig
                )
            );
        }
        if (n == keccak256("UniformEditionAuctionLens")) {
            return _artifact(
                "UniformEditionAuctionLens.sol:UniformEditionAuctionLens",
                abi.encode(
                    d.editions,
                    d.stream,
                    d.englishAuction,
                    d.revenueEscrow,
                    d.directory,
                    d.economicsResolver,
                    d.packageRegistry
                )
            );
        }
        if (n == keccak256("UniformEditionAuction")) {
            // It pins the lens deployed just before.
            address lens = d.editionAuctionLens;
            return _artifact(
                "UniformEditionAuction.sol:UniformEditionAuction",
                bytes.concat(
                    abi.encode(
                        m,
                        d.revenueEscrow,
                        d.directory,
                        d.editions,
                        d.englishAuction,
                        lens,
                        lens.codehash
                    ),
                    p.editionAuctionConfig
                )
            );
        }
        if (n == keccak256("IndependentStreamRegistry")) {
            // Manager, Directory, WorkFacts, economics resolver, content store, and no earlier
            // registry to inherit from.
            return _artifact(
                "IndependentStreamRegistry.sol:IndependentStreamRegistry",
                abi.encode(
                    m, d.directory, d.workFacts, d.economicsResolver, d.contentStore, address(0)
                )
            );
        }
        if (n == keccak256("IndependentStream721Deployer")) {
            // The deployer holds the template's creation code.
            return _artifact(
                "IndependentStreamDeployer.sol:IndependentStreamDeployer",
                abi.encode(vm.getCode("IndependentStream6529.sol:IndependentStream6529"))
            );
        }
        if (n == keccak256("IndependentStreamEditionsDeployer")) {
            return _artifact(
                "IndependentStreamDeployer.sol:IndependentStreamDeployer",
                abi.encode(
                    vm.getCode("IndependentStreamEditions6529.sol:IndependentStreamEditions6529")
                )
            );
        }
        if (n == keccak256("IndependentEditionAuctionLens")) {
            // The Independent Stream module is found through Directory.
            return _artifact(
                "IndependentEditionAuctionLens.sol:IndependentEditionAuctionLens",
                abi.encode(d.englishAuction, d.revenueEscrow, d.directory, d.economicsResolver)
            );
        }
        if (n == keccak256("IndependentEditionAuction")) {
            address lens = d.independentEditionAuctionLens;
            return _artifact(
                "IndependentEditionAuction.sol:IndependentEditionAuction",
                bytes.concat(
                    abi.encode(
                        m, d.revenueEscrow, d.directory, d.englishAuction, lens, lens.codehash
                    ),
                    p.editionAuctionConfig
                )
            );
        }
        if (n == keccak256("SaleStarter")) return vm.getCode("SaleStarter.sol:SaleStarter");
        revert UnknownContract(name);
    }

    /// @notice The salt of contract `name` under `p.namespace`.
    function salt(Params memory p, string memory name) internal pure returns (bytes32) {
        return keccak256(abi.encode(p.namespace, name));
    }

    /// @notice Stores `text` in `store` and registers its manifest; returns the file ID.
    function uploadText(IContentStore store, bytes memory text, string memory mime)
        internal
        returns (bytes32 fileId)
    {
        if (text.length == 0) revert EmptyText();
        uint256 size = store.CHUNK_SIZE();
        bytes32[] memory hashes = new bytes32[]((text.length + size - 1) / size);
        for (uint256 i; i < hashes.length; ++i) {
            uint256 start = i * size;
            uint256 end = start + size < text.length ? start + size : text.length;
            bytes memory chunk = new bytes(end - start);
            for (uint256 j; j < chunk.length; ++j) {
                chunk[j] = text[start + j];
            }
            (hashes[i],) = store.writeChunk(chunk);
        }
        fileId = store.registerManifest(
            hashes, text.length, uint8(IContentStore.Encoding.Identity), mime, sha256(text)
        );
    }

    /// @dev Creates the `CoreFactory` at `expected` unless it exists: its address commits to
    ///      its creation code and so to its owner, so code there is this factory whoever sent it.
    function _createFactory(Params memory p, address factory, address expected) private {
        if (expected.code.length == 0) {
            bytes memory code = factoryInitcode(p, factory);
            bytes32 s = salt(p, "CoreFactory");
            if (factory == CREATE2_FACTORY) {
                (bool ok,) = factory.call(bytes.concat(s, code));
                if (!ok) revert CreateFailed("CoreFactory");
            } else {
                assembly ("memory-safe") {
                    pop(create2(0, add(code, 0x20), mload(code), s))
                }
            }
        }
        if (expected.code.length == 0 || CoreFactory(expected).owner() != sender(p, factory)) {
            revert CreateFailed("CoreFactory");
        }
    }

    /// @dev Creates `code` as contract `name` through the deployer's `CoreFactory`, in one call.
    function _create(address coreFactory, string memory name, bytes32 salt_, bytes memory code)
        private
    {
        address a = CoreFactory(coreFactory).create(salt_, code);
        if (a.code.length == 0) revert CreateFailed(name);
    }

    function _artifact(string memory artifact, bytes memory args)
        private
        view
        returns (bytes memory)
    {
        return bytes.concat(vm.getCode(artifact), args);
    }

    // ------------------------------------------------------------------ names

    /// @notice The address of a contract or peer named in the genesis JSON, or zero if it is
    ///         not deployed (the optional entropy module).
    function addressOf(Deployment memory d, string memory name) internal pure returns (address) {
        bytes32 n = keccak256(bytes(name));
        if (n == keccak256("WorksAccessManager")) return address(d.manager);
        if (n == keccak256("CoreFactory")) return d.coreFactory;
        if (n == keccak256("GovernanceConfigurator")) return address(d.configurator);
        if (n == keccak256("ContentStore")) return address(d.contentStore);
        if (n == keccak256("StreamWorkFacts6529")) return address(d.workFacts);
        if (n == keccak256("StreamDirectory6529")) return address(d.directory);
        if (n == keccak256("FeeRecipientVault")) return address(d.feeRecipientVault);
        if (n == keccak256("MuseumVault")) return address(d.museumVault);
        if (n == keccak256("SplitFactory")) return address(d.splitLedger);
        if (n == keccak256("ClaimRouter")) return address(d.claimRouter);
        if (n == keccak256("RevenueEscrow")) return d.revenueEscrow;
        if (n == keccak256("Stream6529")) return address(d.stream);
        if (n == keccak256("StreamEditions6529")) return address(d.editions);
        if (n == keccak256("ConsolidationAdapter")) return d.consolidationAdapter;
        if (n == keccak256("Accounts")) return d.accounts;
        if (n == keccak256("AssetAllowlist")) return d.assetAllowlist;
        if (n == keccak256("EconomicsResolver")) return d.economicsResolver;
        if (n == keccak256("CurationVerifier")) return d.curationVerifier;
        if (n == keccak256("PackageRegistry")) return d.packageRegistry;
        if (n == keccak256("StatementLog")) return d.statementLog;
        if (n == keccak256("EntropyModule")) return d.entropyModule;
        if (n == keccak256("DependencyRegistry")) return d.dependencyRegistry;
        if (n == keccak256("Renderer")) return d.renderer;
        if (n == keccak256("WorkRules")) return d.workRules;
        if (n == keccak256("WorkDelivery")) return d.workDelivery;
        if (n == keccak256("StreamTerms")) return d.streamTerms;
        if (n == keccak256("EnglishAuction")) return d.englishAuction;
        if (n == keccak256("UniformEditionAuctionLens")) return d.editionAuctionLens;
        if (n == keccak256("UniformEditionAuction")) return d.editionAuction;
        if (n == keccak256("IndependentStreamRegistry")) return d.independentStreamRegistry;
        if (n == keccak256("IndependentStream721Deployer")) return d.independentStream721Deployer;
        if (n == keccak256("IndependentStreamEditionsDeployer")) {
            return d.independentStreamEditionsDeployer;
        }
        if (n == keccak256("IndependentEditionAuctionLens")) {
            return d.independentEditionAuctionLens;
        }
        if (n == keccak256("IndependentEditionAuction")) return d.independentEditionAuction;
        if (n == keccak256("SaleStarter")) return d.saleStarter;
        revert UnknownContract(name);
    }

    /// @notice Sets the address of contract `name`.
    function assign(Deployment memory d, string memory name, address a) internal pure {
        bytes32 n = keccak256(bytes(name));
        if (n == keccak256("WorksAccessManager")) {
            d.manager = WorksAccessManager(a);
        } else if (n == keccak256("CoreFactory")) {
            d.coreFactory = a;
        } else if (n == keccak256("GovernanceConfigurator")) {
            d.configurator = GovernanceConfigurator(a);
        } else if (n == keccak256("ContentStore")) {
            d.contentStore = ContentStore(a);
        } else if (n == keccak256("StreamWorkFacts6529")) {
            d.workFacts = StreamWorkFacts6529(a);
        } else if (n == keccak256("StreamDirectory6529")) {
            d.directory = StreamDirectory6529(a);
        } else if (n == keccak256("FeeRecipientVault")) {
            d.feeRecipientVault = GovernedVault(payable(a));
        } else if (n == keccak256("MuseumVault")) {
            d.museumVault = GovernedVault(payable(a));
        } else if (n == keccak256("SplitFactory")) {
            d.splitLedger = SplitLedger(a);
        } else if (n == keccak256("ClaimRouter")) {
            d.claimRouter = ClaimRouter(a);
        } else if (n == keccak256("RevenueEscrow")) {
            d.revenueEscrow = a;
        } else if (n == keccak256("Stream6529")) {
            d.stream = Stream6529(a);
        } else if (n == keccak256("StreamEditions6529")) {
            d.editions = StreamEditions6529(a);
        } else if (n == keccak256("ConsolidationAdapter")) {
            d.consolidationAdapter = a;
        } else if (n == keccak256("Accounts")) {
            d.accounts = a;
        } else if (n == keccak256("AssetAllowlist")) {
            d.assetAllowlist = a;
        } else if (n == keccak256("EconomicsResolver")) {
            d.economicsResolver = a;
        } else if (n == keccak256("CurationVerifier")) {
            d.curationVerifier = a;
        } else if (n == keccak256("PackageRegistry")) {
            d.packageRegistry = a;
        } else if (n == keccak256("StatementLog")) {
            d.statementLog = a;
        } else if (n == keccak256("EntropyModule")) {
            d.entropyModule = a;
        } else if (n == keccak256("DependencyRegistry")) {
            d.dependencyRegistry = a;
        } else if (n == keccak256("Renderer")) {
            d.renderer = a;
        } else if (n == keccak256("WorkRules")) {
            d.workRules = a;
        } else if (n == keccak256("WorkDelivery")) {
            d.workDelivery = a;
        } else if (n == keccak256("StreamTerms")) {
            d.streamTerms = a;
        } else if (n == keccak256("EnglishAuction")) {
            d.englishAuction = a;
        } else if (n == keccak256("UniformEditionAuctionLens")) {
            d.editionAuctionLens = a;
        } else if (n == keccak256("UniformEditionAuction")) {
            d.editionAuction = a;
        } else if (n == keccak256("IndependentStreamRegistry")) {
            d.independentStreamRegistry = a;
        } else if (n == keccak256("IndependentStream721Deployer")) {
            d.independentStream721Deployer = a;
        } else if (n == keccak256("IndependentStreamEditionsDeployer")) {
            d.independentStreamEditionsDeployer = a;
        } else if (n == keccak256("IndependentEditionAuctionLens")) {
            d.independentEditionAuctionLens = a;
        } else if (n == keccak256("IndependentEditionAuction")) {
            d.independentEditionAuction = a;
        } else if (n == keccak256("SaleStarter")) {
            d.saleStarter = a;
        } else {
            revert UnknownContract(name);
        }
    }

    // ------------------------------------------------------------------ genesis configuration

    /// @notice `cfg` from the genesis JSON: every holder, and every deployed contract's governed
    ///         selectors at its deployed address.
    function config(Deployment memory d, string memory json)
        internal
        view
        returns (GovernanceConfig.Config memory cfg)
    {
        checkRoles(json);
        cfg.network = vm.parseJsonAddress(json, ".network");
        if (vm.keyExistsJson(json, ".brake")) cfg.brake = vm.parseJsonAddress(json, ".brake");
        cfg.grants = _grants(json);
        uint256 contracts = _count(json, ".contracts");
        uint256 deployed;
        for (uint256 i; i < contracts; ++i) {
            if (_deployedAt(d, json, i) != address(0)) ++deployed;
        }
        cfg.targets = new GovernanceConfig.Target[](deployed);
        uint256 k;
        for (uint256 i; i < contracts; ++i) {
            address target = _deployedAt(d, json, i);
            if (target != address(0)) {
                cfg.targets[k++] = GovernanceConfig.Target(target, _functions(json, i));
            }
        }
    }

    /// @notice Reverts unless the JSON's `roles` table is exactly `Roles.sol`.
    function checkRoles(string memory json) internal view {
        uint256 n = _count(json, ".roles");
        uint256 known;
        for (uint64 id; id < Roles.COUNT; ++id) {
            if (Roles.isKnown(id)) ++known;
        }
        if (n != known) revert RoleTableMismatch("count");
        uint256 seen;
        for (uint256 i; i < n; ++i) {
            string memory r = _at(".roles", i);
            string memory name = vm.parseJsonString(json, string.concat(r, ".name"));
            uint64 id = _roleId(name);
            if (
                seen & (1 << id) != 0 || vm.parseJsonUint(json, string.concat(r, ".id")) != id
                    || vm.parseJsonUint(json, string.concat(r, ".executionDelay"))
                        != Roles.executionDelay(id)
                    || vm.parseJsonUint(json, string.concat(r, ".grantDelay")) != 0
            ) revert RoleTableMismatch(name);
            seen |= 1 << id;
        }
    }

    /// @notice The genesis wiring from the JSON, re-encoded with the deployed addresses. A call
    ///         on, or naming, a contract that is not deployed is left out.
    function wiring(Deployment memory d, string memory json, Manifest memory manifest)
        internal
        view
        returns (GovernanceConfig.Call[] memory calls)
    {
        uint256 n = _count(json, ".wiring");
        GovernanceConfig.Call[] memory all = new GovernanceConfig.Call[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            (bool ok, GovernanceConfig.Call memory c) = _wiringCall(d, json, i, manifest);
            if (ok) all[k++] = c;
        }
        calls = new GovernanceConfig.Call[](k);
        for (uint256 i; i < k; ++i) {
            calls[i] = all[i];
        }
    }

    /// @notice The epoch-0 manifest statement the wiring appends.
    function manifestStatement(Deployment memory d, Manifest memory manifest)
        internal
        pure
        returns (Statement memory)
    {
        return Statement({
            token: address(d.manager),
            id: 0,
            kind: StatementKinds.GOVERNANCE_MANIFEST,
            schema: MANIFEST_SCHEMA,
            content: HashRef(HASH_SHA256, manifest.digest),
            uri: manifest.uri,
            fileId: bytes32(0),
            supersedes: bytes32(0)
        });
    }

    /// @notice Installs `cfg` and `calls` and renounces the configurator. The caller must be
    ///         `Params.deployer`.
    function install(
        Deployment memory d,
        GovernanceConfig.Config memory cfg,
        Manifest memory manifest,
        GovernanceConfig.Call[] memory calls
    ) internal {
        d.configurator.configure(cfg, manifest.digest, calls);
    }

    function _grants(string memory json)
        private
        view
        returns (GovernanceConfig.Grant[] memory grants)
    {
        grants = new GovernanceConfig.Grant[](_count(json, ".holders"));
        for (uint256 i; i < grants.length; ++i) {
            string memory h = _at(".holders", i);
            grants[i] = GovernanceConfig.Grant(
                _roleId(vm.parseJsonString(json, string.concat(h, ".role"))),
                vm.parseJsonAddress(json, string.concat(h, ".account"))
            );
        }
    }

    function _functions(string memory json, uint256 contractIndex)
        private
        view
        returns (GovernanceConfig.FunctionRole[] memory fns)
    {
        string memory base = string.concat(_at(".contracts", contractIndex), ".functions");
        fns = new GovernanceConfig.FunctionRole[](_count(json, base));
        for (uint256 j; j < fns.length; ++j) {
            string memory f = _at(base, j);
            fns[j] = GovernanceConfig.FunctionRole(
                bytes4(vm.parseJsonBytes(json, string.concat(f, ".selector"))),
                _roleId(vm.parseJsonString(json, string.concat(f, ".role")))
            );
        }
    }

    function _wiringCall(
        Deployment memory d,
        string memory json,
        uint256 i,
        Manifest memory manifest
    ) private view returns (bool, GovernanceConfig.Call memory c) {
        string memory w = _at(".wiring", i);
        c.target = addressOf(d, vm.parseJsonString(json, string.concat(w, ".contract")));
        if (c.target == address(0)) return (false, c);
        string memory sig = vm.parseJsonString(json, string.concat(w, ".signature"));
        bytes4 selector = bytes4(keccak256(bytes(sig)));
        if (selector == IStatementLog.appendGovernanceManifest.selector) {
            c.data = abi.encodeCall(
                IStatementLog.appendGovernanceManifest, (manifestStatement(d, manifest))
            );
            return (true, c);
        }
        (bool ok, bytes memory args) = _encodeArgs(d, json, w, sig);
        c.data = bytes.concat(selector, args);
        return (ok, c);
    }

    /// @dev Encodes a wiring call's arguments: an address by contract name or as a 0x literal,
    ///      a bool, a bytes32 as a 0x literal or as an Independent Stream template's name (the
    ///      keccak256 of its runtime code), or an unsigned integer. False if a named contract is
    ///      not deployed.
    function _encodeArgs(
        Deployment memory d,
        string memory json,
        string memory w,
        string memory sig
    ) private view returns (bool, bytes memory out) {
        string[] memory types = _paramTypes(sig);
        for (uint256 j; j < types.length; ++j) {
            string memory arg = _at(string.concat(w, ".args"), j);
            bytes32 t = keccak256(bytes(types[j]));
            if (t == keccak256("address")) {
                string memory value = vm.parseJsonString(json, arg);
                bytes memory b = bytes(value);
                bool literal = b.length == 42 && b[0] == "0" && b[1] == "x";
                address a = literal ? vm.parseAddress(value) : addressOf(d, value);
                if (!literal && a == address(0)) return (false, out);
                out = bytes.concat(out, abi.encode(a));
            } else if (t == keccak256("bytes32")) {
                string memory value = vm.parseJsonString(json, arg);
                bytes memory b = bytes(value);
                bool literal = b.length == 66 && b[0] == "0" && b[1] == "x";
                out = bytes.concat(
                    out,
                    literal
                        ? vm.parseBytes32(value)
                        : keccak256(vm.getDeployedCode(string.concat(value, ".sol:", value)))
                );
            } else if (_isUint(types[j])) {
                out = bytes.concat(out, abi.encode(vm.parseJsonUint(json, arg)));
            } else if (t == keccak256("bool")) {
                out = bytes.concat(out, abi.encode(vm.parseJsonBool(json, arg)));
            } else {
                revert UnsupportedWiringSignature(sig);
            }
        }
        return (true, out);
    }

    // ------------------------------------------------------------------ helpers

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _isUint(string memory t) private pure returns (bool) {
        bytes memory b = bytes(t);
        return b.length >= 4 && b[0] == "u" && b[1] == "i" && b[2] == "n" && b[3] == "t";
    }

    function _deployedAt(Deployment memory d, string memory json, uint256 i)
        private
        pure
        returns (address)
    {
        return addressOf(d, vm.parseJsonString(json, string.concat(_at(".contracts", i), ".name")));
    }

    function _at(string memory base, uint256 i) private pure returns (string memory) {
        return string.concat(base, "[", vm.toString(i), "]");
    }

    function _count(string memory json, string memory base) private view returns (uint256 n) {
        while (vm.keyExistsJson(json, _at(base, n))) ++n;
    }

    function _roleId(string memory name) private pure returns (uint64) {
        if (keccak256(bytes(name)) == keccak256("ADMIN")) return Roles.ADMIN;
        for (uint64 role = 1; role < Roles.COUNT; ++role) {
            if (!Roles.isKnown(role)) continue;
            if (keccak256(bytes(name)) == keccak256(bytes(Roles.label(role)))) return role;
        }
        revert UnknownRoleName(name);
    }

    /// @dev Parameter types of a signature with elementary, comma-separated parameters.
    function _paramTypes(string memory sig) private pure returns (string[] memory types) {
        bytes memory s = bytes(sig);
        uint256 open;
        while (open < s.length && s[open] != "(") ++open;
        if (open + 1 >= s.length || s[s.length - 1] != ")") revert UnsupportedWiringSignature(sig);
        uint256 count = s[open + 1] == ")" ? 0 : 1;
        for (uint256 i = open + 1; i < s.length; ++i) {
            if (s[i] == "(") revert UnsupportedWiringSignature(sig);
            if (s[i] == ",") ++count;
        }
        types = new string[](count);
        uint256 start = open + 1;
        uint256 k;
        for (uint256 i = open + 1; i < s.length && k < count; ++i) {
            if (s[i] == "," || s[i] == ")") {
                bytes memory t = new bytes(i - start);
                for (uint256 j; j < t.length; ++j) {
                    t[j] = s[start + j];
                }
                types[k++] = string(t);
                start = i + 1;
            }
        }
    }
}
