// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Vm } from "forge-std/Vm.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { Directory } from "src/core/Directory.sol";
import { Editions } from "src/core/Editions.sol";
import { Stream } from "src/core/Stream.sol";
import { WorkFacts } from "src/core/WorkFacts.sol";
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

/// @title DeployCore
/// @notice Deploys the plain-core stack (ADR 0010) and installs its genesis configuration.
/// @dev Every contract is created through a small CREATE3 step: a one-use proxy at a CREATE2
///      address that depends only on the namespace and the contract's name, which then creates
///      the contract. So every address is known before anything is deployed, and the token
///      contracts and `Directory` take their genesis modules and minters as constructor
///      arguments even though those modules are deployed after them. An address therefore does
///      not commit to code: `VerifyCore` reads every contract back (code present, wiring,
///      module slots, minters, settings) instead.
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
    /// @notice The CREATE3 proxy's creation code: its runtime copies the calldata and creates
    ///         a contract from it with CREATE, so the contract's address is the proxy's first
    ///         CREATE address.
    bytes internal constant PROXY_INITCODE = hex"67363d3d37363d34f03d5260086018f3";

    /// @notice The launch value of every module's and minter's waiting period (`moduleDelay`).
    uint48 internal constant LAUNCH_MODULE_DELAY = 7 days;
    /// @notice The launch value of `Stream.rescueDelay`.
    uint48 internal constant LAUNCH_RESCUE_DELAY = 14 days;
    /// @notice The launch value of `Editions.rebindDelay`.
    uint48 internal constant LAUNCH_REBIND_DELAY = 14 days;
    /// @notice The launch value of `Directory.unclaimedPeriod`.
    uint48 internal constant LAUNCH_UNCLAIMED_PERIOD = 180 days;
    /// @notice How many entries of `order` are the permanent part (through `Editions`).
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
        GovernanceConfigurator configurator;
        WorksAccessManager manager;
        ContentStore contentStore;
        WorkFacts workFacts;
        Directory directory;
        GovernedVault feeRecipientVault;
        GovernedVault museumVault;
        SplitLedger splitLedger;
        ClaimRouter claimRouter;
        address revenueEscrow;
        Stream stream;
        Editions editions;
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
        address federationRegistry;
        address federatedStreamDeployer;
        address federatedEditionsDeployer;
        address federatedEditionAuctionLens;
        address federatedEditionAuction;
        address saleStarter;
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
    ///         the CREATE2 deployer of that context.
    function deploy(Params memory p, address factory) internal returns (Deployment memory d) {
        d = deployPermanent(p, factory);
        string[] memory list = order(p);
        for (uint256 i = PERMANENT_COUNT; i < list.length; ++i) {
            _create3(list[i], salt(p, list[i]), initcode(p, d, list[i]));
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
        string[] memory list = order(p);
        for (uint256 i; i < PERMANENT_COUNT; ++i) {
            string memory name = list[i];
            _create3(name, salt(p, name), initcode(p, d, name));
            if (_eq(name, "ContentStore")) {
                d.cc0TextFileId = uploadText(d.contentStore, p.cc0Text, "text/plain");
            }
        }
    }

    /// @notice Every address `deploy(p, factory)` creates, from the salts alone (the CC0 file
    ///         ID is filled in by `deploy`).
    function predict(Params memory p, address factory) internal pure returns (Deployment memory d) {
        string[] memory list = order(p);
        for (uint256 i; i < list.length; ++i) {
            assign(d, list[i], addressFor(p, list[i], factory));
        }
        d.manager = WorksAccessManager(vm.computeCreateAddress(address(d.configurator), 1));
    }

    /// @notice The address of contract `name` under `p.namespace`, created through CREATE2
    ///         deployer `factory`.
    function addressFor(Params memory p, string memory name, address factory)
        internal
        pure
        returns (address)
    {
        address proxy = vm.computeCreate2Address(salt(p, name), keccak256(PROXY_INITCODE), factory);
        return vm.computeCreateAddress(proxy, 1);
    }

    /// @notice The contracts `deploy` creates, in order. The entropy module only with a VRF
    ///         coordinator; the manager is created by the configurator.
    function order(Params memory p) internal pure returns (string[] memory list) {
        string[31] memory all = [
            "GovernanceConfigurator",
            "ContentStore",
            "WorkFacts",
            "Directory",
            "FeeRecipientVault",
            "MuseumVault",
            "SplitFactory",
            "ClaimRouter",
            "RevenueEscrow",
            "Stream",
            "Editions",
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
            "FederationRegistry",
            "FederatedStreamDeployer",
            "FederatedEditionsDeployer",
            "FederatedEditionAuctionLens",
            "FederatedEditionAuction"
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
        if (n == keccak256("WorkFacts")) {
            return bytes.concat(
                type(WorkFacts).creationCode, abi.encode(d.contentStore, d.cc0TextFileId)
            );
        }
        if (n == keccak256("Directory")) {
            // The genesis shared modules: one WorkRules and one StreamTerms serve both 6529
            // Stream and every federated token (both are keyed by token).
            return bytes.concat(
                type(Directory).creationCode,
                abi.encode(m, d.accounts, d.federationRegistry, d.streamTerms, d.workRules)
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
        if (n == keccak256("Stream")) {
            address[] memory minters = new address[](1);
            minters[0] = d.englishAuction;
            return bytes.concat(
                type(Stream).creationCode,
                abi.encode(
                    m, d.workFacts, p.marketOwner, d.renderer, d.streamTerms, d.workRules, minters
                )
            );
        }
        if (n == keccak256("Editions")) {
            address[] memory minters = new address[](1);
            minters[0] = d.editionAuction;
            return bytes.concat(
                type(Editions).creationCode,
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
            // registry), several of them deployed after this module.
            address adapter = d.consolidationAdapter;
            return _artifact(
                "Accounts.sol:Accounts",
                abi.encode(
                    m,
                    adapter,
                    adapter.codehash,
                    d.directory,
                    d.stream,
                    d.editions,
                    d.splitLedger,
                    d.statementLog,
                    d.packageRegistry
                )
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
            // Stream (`bindStream`).
            address verifier = d.curationVerifier;
            return _artifact(
                "PackageRegistry.sol:PackageRegistry",
                abi.encode(
                    m,
                    verifier,
                    verifier.codehash,
                    d.accounts,
                    d.accounts.codehash,
                    d.economicsResolver,
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
            // One token-keyed instance serves Stream and every federated token; its delivery
            // contract is deployed next, at its predicted address.
            return _artifact(
                "WorkRules.sol:WorkRules", abi.encode(m, d.workFacts, d.directory, d.workDelivery)
            );
        }
        if (n == keccak256("WorkDelivery")) {
            return _artifact(
                "WorkDelivery.sol:WorkDelivery",
                abi.encode(m, d.workRules, d.workFacts, d.directory, address(0))
            );
        }
        if (n == keccak256("StreamTerms")) {
            // Manager, split ledger (vault derivation), 6529 Stream and its Editions
            // (`editionsOf`), Directory (federated fee shares).
            return _artifact(
                "StreamTerms.sol:StreamTerms",
                abi.encode(m, d.splitLedger, d.stream, d.editions, d.directory)
            );
        }
        if (n == keccak256("EnglishAuction")) {
            // ETH only. The mint policy for 6529 Stream is the package registry; for federated
            // tokens it is the directory's FEDERATION module.
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
        if (n == keccak256("FederationRegistry")) {
            // Manager, Directory, WorkFacts, economics resolver, content store, and no earlier
            // registry to inherit from.
            return _artifact(
                "FederationRegistry.sol:FederationRegistry",
                abi.encode(
                    m, d.directory, d.workFacts, d.economicsResolver, d.contentStore, address(0)
                )
            );
        }
        if (n == keccak256("FederatedStreamDeployer")) {
            // The deployer holds the template's creation code.
            return _artifact(
                "FederatedDeployer.sol:FederatedDeployer",
                abi.encode(vm.getCode("FederatedStream.sol:FederatedStream"))
            );
        }
        if (n == keccak256("FederatedEditionsDeployer")) {
            return _artifact(
                "FederatedDeployer.sol:FederatedDeployer",
                abi.encode(vm.getCode("FederatedEditions.sol:FederatedEditions"))
            );
        }
        if (n == keccak256("FederatedEditionAuctionLens")) {
            // The federation module is found through Directory.
            return _artifact(
                "FederatedEditionAuctionLens.sol:FederatedEditionAuctionLens",
                abi.encode(d.englishAuction, d.revenueEscrow, d.directory, d.economicsResolver)
            );
        }
        if (n == keccak256("FederatedEditionAuction")) {
            address lens = d.federatedEditionAuctionLens;
            return _artifact(
                "FederatedEditionAuction.sol:FederatedEditionAuction",
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

    /// @dev CREATE3: a proxy at a salt-only CREATE2 address creates `code` with CREATE. A
    ///      constructor that reverts leaves no code at the predicted address; that reverts here.
    function _create3(string memory name, bytes32 salt_, bytes memory code)
        private
        returns (address a)
    {
        bytes memory proxyCode = PROXY_INITCODE;
        address proxy;
        assembly ("memory-safe") {
            proxy := create2(0, add(proxyCode, 0x20), mload(proxyCode), salt_)
        }
        if (proxy == address(0)) revert CreateFailed(name);
        (bool ok,) = proxy.call(code);
        a = vm.computeCreateAddress(proxy, 1);
        if (!ok || a.code.length == 0) revert CreateFailed(name);
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
        if (n == keccak256("GovernanceConfigurator")) return address(d.configurator);
        if (n == keccak256("ContentStore")) return address(d.contentStore);
        if (n == keccak256("WorkFacts")) return address(d.workFacts);
        if (n == keccak256("Directory")) return address(d.directory);
        if (n == keccak256("FeeRecipientVault")) return address(d.feeRecipientVault);
        if (n == keccak256("MuseumVault")) return address(d.museumVault);
        if (n == keccak256("SplitFactory")) return address(d.splitLedger);
        if (n == keccak256("ClaimRouter")) return address(d.claimRouter);
        if (n == keccak256("RevenueEscrow")) return d.revenueEscrow;
        if (n == keccak256("Stream")) return address(d.stream);
        if (n == keccak256("Editions")) return address(d.editions);
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
        if (n == keccak256("FederationRegistry")) return d.federationRegistry;
        if (n == keccak256("FederatedStreamDeployer")) return d.federatedStreamDeployer;
        if (n == keccak256("FederatedEditionsDeployer")) return d.federatedEditionsDeployer;
        if (n == keccak256("FederatedEditionAuctionLens")) return d.federatedEditionAuctionLens;
        if (n == keccak256("FederatedEditionAuction")) return d.federatedEditionAuction;
        if (n == keccak256("SaleStarter")) return d.saleStarter;
        revert UnknownContract(name);
    }

    /// @notice Sets the address of contract `name`.
    function assign(Deployment memory d, string memory name, address a) internal pure {
        bytes32 n = keccak256(bytes(name));
        if (n == keccak256("WorksAccessManager")) {
            d.manager = WorksAccessManager(a);
        } else if (n == keccak256("GovernanceConfigurator")) {
            d.configurator = GovernanceConfigurator(a);
        } else if (n == keccak256("ContentStore")) {
            d.contentStore = ContentStore(a);
        } else if (n == keccak256("WorkFacts")) {
            d.workFacts = WorkFacts(a);
        } else if (n == keccak256("Directory")) {
            d.directory = Directory(a);
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
        } else if (n == keccak256("Stream")) {
            d.stream = Stream(a);
        } else if (n == keccak256("Editions")) {
            d.editions = Editions(a);
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
        } else if (n == keccak256("FederationRegistry")) {
            d.federationRegistry = a;
        } else if (n == keccak256("FederatedStreamDeployer")) {
            d.federatedStreamDeployer = a;
        } else if (n == keccak256("FederatedEditionsDeployer")) {
            d.federatedEditionsDeployer = a;
        } else if (n == keccak256("FederatedEditionAuctionLens")) {
            d.federatedEditionAuctionLens = a;
        } else if (n == keccak256("FederatedEditionAuction")) {
            d.federatedEditionAuction = a;
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
    ///      a bool, a bytes32 as a 0x literal or as a federated template's name (the keccak256
    ///      of its runtime code), or an unsigned integer. False if a named contract is not
    ///      deployed.
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
