// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { Renderer } from "src/content/Renderer.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { DependencyRegistry } from "src/content/DependencyRegistry.sol";
import { Eip712CurationVerifier } from "src/curation/Eip712CurationVerifier.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { ClaimRouter } from "src/economics/ClaimRouter.sol";
import { EconomicsResolver } from "src/economics/EconomicsResolver.sol";
import { ReleaseVerifier } from "src/economics/ReleaseVerifier.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitFactory } from "src/economics/SplitFactory.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { Editions } from "src/editions/Editions.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { ConsolidationAdapter } from "src/identity/ConsolidationAdapter.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IStatementLog, Statement } from "src/interfaces/IStatementLog.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { HashRef, HASH_SHA256 } from "src/interfaces/types/HashRef.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { EnglishAuctionLens } from "src/sales/EnglishAuctionLens.sol";
import { Stream } from "src/stream/Stream.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";

/// @title DeployV1
/// @notice Deploys every v1 contract in dependency order and installs the genesis
///         configuration. `script/Deploy.s.sol` broadcasts it; the integration tests call it
///         directly, so both exercise the same deployment.
/// @dev Immutable dependencies are constructor arguments; one-shot binds, admitted minters,
///      sale targets, first default currencies and the epoch-0 manifest are genesis wiring
///      (config/README.md). Every contract is created with CREATE2 under `Params.namespace`, so
///      its address depends only on the namespace, its initcode (`initcode`) and the CREATE2
///      deployer, and `predict` recomputes it. The governance map and the wiring come from the
///      genesis JSON, with the deployed addresses substituted by contract name. A contract not
///      deployed (the optional entropy module) is left out of both, with any wiring that names
///      it; `dropped` lists what is left out, and `Deploy.s.sol` refuses anything there off
///      anvil except an explicitly declined entropy module.
library DeployV1 {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Anvil's chain ID: the only chain where stand-ins and placeholders are allowed.
    uint256 internal constant LOCAL_CHAIN_ID = 31337;
    /// @notice Uniswap's canonical Permit2, deployed at the same address on every major chain.
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @notice Schema of the governance manifest statements in the statement log.
    bytes32 internal constant MANIFEST_SCHEMA = keccak256("6529-works/governance-manifest/1");
    /// @notice Where the CC0 1.0 Universal legal code is published in plain text.
    string internal constant CC0_LEGALCODE_URL =
        "https://creativecommons.org/publicdomain/zero/1.0/legalcode.txt";
    /// @notice The same file in Creative Commons' own data repository.
    string internal constant CC0_LEGALCODE_MIRROR =
        "https://raw.githubusercontent.com/creativecommons/cc-legal-tools-data/main/docs/publicdomain/zero/1.0/legalcode.txt";
    /// @notice The size of that file: 7,048 bytes of `text/plain`.
    uint256 internal constant CC0_LEGALCODE_LENGTH = 7048;
    /// @notice The SHA-256 of that file, the default license text of every work. Pinned on
    ///         11 October 2026 after both sources served the same 7,048 bytes with this digest
    ///         (the first fetched twice). Off anvil, `Deploy.s.sol` and `Verify.s.sol` refuse
    ///         any other text.
    /// @notice The default renderer's inline threshold (`Renderer.DEFAULT_INLINE_THRESHOLD`).
    uint256 internal constant RENDERER_INLINE_THRESHOLD = 262_144;
    bytes32 internal constant CC0_LEGALCODE_SHA256 =
        0xa2010f343487d3f7618affe54f789f5487602331c0a8d03f49e9a7c547cf0499;

    struct Params {
        /// The operator account that broadcasts the genesis and alone may call `configure`.
        address deployer;
        /// CREATE2 salt namespace; one namespace deploys one system.
        bytes32 namespace;
        /// Network share recipient of every product (EconomicsResolver defaults).
        address feeRecipient;
        /// The 6529 Network Museum (D140): where an unbid canonical 6529 Stream work goes. An
        /// existing Safe or EOA; FUNDS_SETTER can change it.
        address museum;
        /// The marketplace `owner()` of 6529 Stream (and 6529 Stream Editions): collection admin
        /// on marketplaces, no protocol power. FUNDS_SETTER can change it.
        address marketOwner;
        /// The 6529 delegation contract the consolidation adapter reads (a faithful mock where
        /// the canonical contract is absent, as on Sepolia). It must have code.
        address delegation;
        /// The CC0 1.0 Universal legal code, plain text. Genesis stores it in the content store
        /// (the default license text: WorkRecords requires it, and finalize needs it complete).
        bytes cc0Text;
        /// Minimum ETH bid increment, 0.001 ether at launch (ADR 0001 §5).
        uint256 ethIncrementFloor;
        /// Permit2 for the English auction (`auctionPermit2`).
        address permit2;
        IEnglishAuction.AuctionConfig auction;
        /// The edition auction's governed parameters at genesis (`editionAuctionDefaults`).
        IUniformEditionAuction.AuctionConfig editionAuction;
        /// Chainlink VRF v2.5 coordinator, or zero to deploy without the entropy module.
        address vrfCoordinator;
        bytes32 vrfCoordinatorCodeHash;
        VrfEntropyModule.VrfConfig vrf;
        uint64 vrfRetryDelay;
    }

    struct Deployment {
        /// Content store file ID of the CC0 legal code, uploaded at genesis.
        bytes32 cc0TextFileId;
        GovernanceConfigurator configurator;
        WorksAccessManager manager;
        ContentStore contentStore;
        DependencyRegistry dependencyRegistry;
        ConsolidationAdapter consolidationAdapter;
        ArtistRegistry artistRegistry;
        ReleaseVerifier releaseVerifier;
        SplitFactory splitFactory;
        ClaimRouter claimRouter;
        AssetAllowlist assetAllowlist;
        EconomicsResolver economicsResolver;
        RevenueEscrow revenueEscrow;
        Eip712CurationVerifier curationVerifier;
        PackageRegistry packageRegistry;
        StatementLog statementLog;
        VrfEntropyModule entropyModule;
        EnglishAuction englishAuction;
        /// The uniform-price edition auction: 6529 Stream Editions' genesis sale method.
        UniformEditionAuction editionAuction;
        /// Its stateless views, created by its constructor (`lens()`, its first CREATE).
        address editionAuctionLens;
        /// The English auction's lens: its first CREATE, made by its constructor.
        EnglishAuctionLens englishAuctionLens;
        /// The default renderer 6529 Stream pins (ADR 0001 §8).
        Renderer renderer;
        Stream stream;
        WorkRecords workRecords;
        Editions editions;
    }

    /// @notice The epoch-0 governance manifest: the SHA-256 of the signed manifest JSON and
    ///         where it is published.
    struct Manifest {
        bytes32 digest;
        string uri;
    }

    error UnknownContract(string name);
    error UnknownRoleName(string name);
    error UnsupportedWiringSignature(string signature);
    error EmptyText();
    /// @notice CREATE2 produced no contract and no revert reason (the address is taken).
    error Create2Failed(string name);
    /// @notice The genesis JSON's `roles` disagree with `Roles.sol` (count, ID or a delay).
    error RoleTableMismatch(string name);

    // ------------------------------------------------------------------ deploy

    /// @notice Deploys the system, contract by contract in `order(p)`, each with CREATE2 under
    ///         `p.namespace` from the calling context: a broadcasting script goes through the
    ///         CREATE2 deployer, a test deploys from itself. Every contract's authority is the
    ///         configurator's manager. `predict` recomputes the same addresses from the same
    ///         initcode.
    function deploy(Params memory p) internal returns (Deployment memory d) {
        string[] memory list = order(p);
        for (uint256 i; i < list.length; ++i) {
            string memory name = list[i];
            assign(d, name, _create2(name, salt(p, name), initcode(p, d, name)));
            if (_eq(name, "GovernanceConfigurator")) {
                d.manager = d.configurator.worksManager();
            } else if (_eq(name, "UniformEditionAuction")) {
                d.editionAuctionLens = d.editionAuction.lens();
            } else if (_eq(name, "EnglishAuction")) {
                d.englishAuctionLens = EnglishAuctionLens(d.englishAuction.lens());
            } else if (_eq(name, "ContentStore")) {
                d.cc0TextFileId = uploadText(d.contentStore, p.cc0Text, "text/plain");
            }
        }
    }

    /// @notice The addresses `deploy(p)` creates through CREATE2 deployer `factory`, recomputed
    ///         from each contract's creation code and constructor arguments. The code hashes a
    ///         constructor pins are read from the chain at the addresses predicted before it, so
    ///         a substituted dependency changes every later address. `cc0TextFileId` is the
    ///         recorded CC0 file ID (the content store derives it from the manifest).
    function predict(Params memory p, bytes32 cc0TextFileId, address factory)
        internal
        view
        returns (Deployment memory d)
    {
        d.cc0TextFileId = cc0TextFileId;
        string[] memory list = order(p);
        for (uint256 i; i < list.length; ++i) {
            string memory name = list[i];
            address a =
                vm.computeCreate2Address(salt(p, name), keccak256(initcode(p, d, name)), factory);
            assign(d, name, a);
            if (_eq(name, "GovernanceConfigurator")) {
                d.manager = WorksAccessManager(vm.computeCreateAddress(a, 1));
            } else if (_eq(name, "UniformEditionAuction")) {
                d.editionAuctionLens = vm.computeCreateAddress(a, 1);
            } else if (_eq(name, "EnglishAuction")) {
                d.englishAuctionLens = EnglishAuctionLens(vm.computeCreateAddress(a, 1));
            }
        }
    }

    /// @notice The contracts `deploy` creates with CREATE2, in order. The entropy module is
    ///         included only with a VRF coordinator; the manager is created by the configurator.
    function order(Params memory p) internal pure returns (string[] memory list) {
        string[20] memory all = [
            "GovernanceConfigurator",
            "ContentStore",
            "DependencyRegistry",
            "ConsolidationAdapter",
            "ArtistRegistry",
            "ReleaseVerifier",
            "SplitFactory",
            "ClaimRouter",
            "AssetAllowlist",
            "EconomicsResolver",
            "RevenueEscrow",
            "CurationVerifier",
            "PackageRegistry",
            "StatementLog",
            "Renderer",
            "Stream",
            "WorkRecords",
            "Editions",
            "EnglishAuction",
            "UniformEditionAuction"
        ];
        bool vrf = p.vrfCoordinator != address(0);
        list = new string[](all.length + (vrf ? 1 : 0));
        uint256 k;
        for (uint256 i; i < all.length; ++i) {
            if (vrf && _eq(all[i], "Renderer")) list[k++] = "EntropyModule";
            list[k++] = all[i];
        }
    }

    /// @notice The creation code and ABI-encoded constructor arguments of contract `name`, given
    ///         the contracts deployed before it in `d`. `deploy` and `predict` both use it.
    function initcode(Params memory p, Deployment memory d, string memory name)
        internal
        view
        returns (bytes memory)
    {
        bytes32 n = keccak256(bytes(name));
        address m = address(d.manager);
        if (n == keccak256("GovernanceConfigurator")) {
            return _code(type(GovernanceConfigurator).creationCode, abi.encode(p.deployer));
        }
        if (n == keccak256("ContentStore")) return type(ContentStore).creationCode;
        if (n == keccak256("DependencyRegistry")) {
            return _code(type(DependencyRegistry).creationCode, abi.encode(m, d.contentStore));
        }
        if (n == keccak256("ConsolidationAdapter")) {
            return _code(type(ConsolidationAdapter).creationCode, abi.encode(p.delegation));
        }
        if (n == keccak256("ArtistRegistry")) {
            address adapter = address(d.consolidationAdapter);
            return
                _code(type(ArtistRegistry).creationCode, abi.encode(m, adapter, adapter.codehash));
        }
        if (n == keccak256("ReleaseVerifier")) return type(ReleaseVerifier).creationCode;
        if (n == keccak256("SplitFactory")) {
            return _code(
                type(SplitFactory).creationCode, abi.encode(d.artistRegistry, d.releaseVerifier)
            );
        }
        if (n == keccak256("ClaimRouter")) return type(ClaimRouter).creationCode;
        if (n == keccak256("AssetAllowlist")) {
            return _code(type(AssetAllowlist).creationCode, abi.encode(m, p.ethIncrementFloor));
        }
        if (n == keccak256("EconomicsResolver")) {
            return _code(
                type(EconomicsResolver).creationCode,
                abi.encode(
                    m, d.assetAllowlist, d.splitFactory, p.feeRecipient, p.museum, d.cc0TextFileId
                )
            );
        }
        if (n == keccak256("RevenueEscrow")) {
            return _code(type(RevenueEscrow).creationCode, abi.encode(m, d.splitFactory));
        }
        return _initcodeLater(p, d, n, name);
    }

    function _initcodeLater(Params memory p, Deployment memory d, bytes32 n, string memory name)
        private
        view
        returns (bytes memory)
    {
        address m = address(d.manager);
        address artists = address(d.artistRegistry);
        if (n == keccak256("CurationVerifier")) {
            return _code(type(Eip712CurationVerifier).creationCode, abi.encode(m));
        }
        if (n == keccak256("PackageRegistry")) {
            address verifier = address(d.curationVerifier);
            return _code(
                type(PackageRegistry).creationCode,
                abi.encode(m, verifier, verifier.codehash, artists, artists.codehash)
            );
        }
        if (n == keccak256("StatementLog")) {
            return _code(type(StatementLog).creationCode, abi.encode(m, artists, artists.codehash));
        }
        if (n == keccak256("EntropyModule")) {
            address registry = address(d.packageRegistry);
            return _code(
                type(VrfEntropyModule).creationCode,
                abi.encode(
                    m,
                    p.vrfCoordinator,
                    p.vrfCoordinatorCodeHash,
                    p.vrf,
                    p.vrfRetryDelay,
                    registry,
                    registry.codehash
                )
            );
        }
        if (n == keccak256("Renderer")) {
            // The ADR 0001 inline threshold (256 KiB), the gas matrix's measured bound.
            return _code(
                type(Renderer).creationCode,
                abi.encode(d.contentStore, d.statementLog, RENDERER_INLINE_THRESHOLD)
            );
        }
        return _initcodeCore(p, d, n, name);
    }

    function _initcodeCore(Params memory p, Deployment memory d, bytes32 n, string memory name)
        private
        view
        returns (bytes memory)
    {
        address m = address(d.manager);
        if (n == keccak256("Stream")) {
            // 6529 Stream pins the default renderer's code hash.
            return _code(
                type(Stream).creationCode,
                abi.encode(
                    m,
                    d.packageRegistry,
                    d.artistRegistry,
                    d.economicsResolver,
                    d.entropyModule,
                    d.renderer,
                    address(d.renderer).codehash,
                    p.marketOwner
                )
            );
        }
        if (n == keccak256("WorkRecords")) {
            // The CC0 text `deploy` uploads right after the content store is the default license.
            return _code(
                type(WorkRecords).creationCode,
                abi.encode(m, d.stream, d.contentStore, License("CC0-1.0", d.cc0TextFileId))
            );
        }
        if (n == keccak256("Editions")) {
            // 6529 Stream Editions pins 6529 Stream's code hash.
            return _code(
                type(Editions).creationCode,
                abi.encode(m, d.stream, address(d.stream).codehash, p.marketOwner)
            );
        }
        if (n == keccak256("EnglishAuction")) {
            // Targets are genesis wiring, not constructor arguments (config/README.md); 6529
            // Stream is also named here as the only token whose unbid works go to the museum.
            return _code(
                type(EnglishAuction).creationCode,
                abi.encode(
                    m,
                    d.revenueEscrow,
                    d.economicsResolver,
                    d.statementLog,
                    auctionPermit2(p),
                    p.auction,
                    new address[](0),
                    d.stream
                )
            );
        }
        if (n == keccak256("UniformEditionAuction")) {
            // It reads 6529 Stream and the economics resolver from Editions; its target is
            // genesis wiring, like the English auction's.
            return _code(
                type(UniformEditionAuction).creationCode,
                abi.encode(m, d.revenueEscrow, d.editions, d.englishAuction, p.editionAuction)
            );
        }
        revert UnknownContract(name);
    }

    /// @notice The edition auction's genesis parameters (ADR 0005 §4; D138, D140, D141, owner
    ///         decisions 3 to 5): 0.0001 ETH at step 0, 48 steps per decade over 336 steps (to
    ///         about 953 ETH), a 10% breadth margin (10,000 of 100,000), a close 15 minutes after
    ///         the 1/1's, a 5-minute soft close and a 24-hour extension backstop. Each is
    ///         governed (`setConfig`, PARAMETER_SETTER) and locked into a sale when it opens.
    function editionAuctionDefaults()
        internal
        pure
        returns (IUniformEditionAuction.AuctionConfig memory)
    {
        return IUniformEditionAuction.AuctionConfig({
            basePrice: 0.0001 ether,
            stepsPerDecade: 48,
            stepCount: 336,
            marginShare: 10_000,
            closeOffset: 15 minutes,
            softWindow: 5 minutes,
            maxExtension: 24 hours
        });
    }

    /// @notice Permit2 for the English auction, which takes zero where Permit2 has no code (a
    ///         local chain); off anvil `Deploy.s.sol` requires code at `p.permit2`.
    function auctionPermit2(Params memory p) internal view returns (address) {
        return p.permit2.code.length != 0 ? p.permit2 : address(0);
    }

    /// @notice The CREATE2 salt of contract `name` under `p.namespace`.
    function salt(Params memory p, string memory name) internal pure returns (bytes32) {
        return keccak256(abi.encode(p.namespace, name));
    }

    /// @notice Stores `text` in `store` (identity encoding, `CHUNK_SIZE` chunks) and registers its
    ///         manifest; returns the file ID. Writing bytes already stored is a no-op.
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
            hashes, text.length, IContentStore.Encoding.Identity, mime, sha256(text)
        );
    }

    /// @dev CREATE2 from the calling context; a constructor's revert is bubbled up.
    function _create2(string memory name, bytes32 salt_, bytes memory code)
        private
        returns (address a)
    {
        assembly ("memory-safe") {
            a := create2(0, add(code, 0x20), mload(code), salt_)
        }
        if (a == address(0)) {
            assembly ("memory-safe") {
                if returndatasize() {
                    let ptr := mload(0x40)
                    returndatacopy(ptr, 0, returndatasize())
                    revert(ptr, returndatasize())
                }
            }
            revert Create2Failed(name);
        }
    }

    function _code(bytes memory creation, bytes memory args) private pure returns (bytes memory) {
        return bytes.concat(creation, args);
    }

    // ------------------------------------------------------------------ names

    /// @notice The deployed address of a contract or peer named in the genesis JSON, or zero
    ///         if it is not deployed (the optional entropy module).
    function addressOf(Deployment memory d, string memory name) internal pure returns (address) {
        bytes32 n = keccak256(bytes(name));
        if (n == keccak256("WorksAccessManager")) return address(d.manager);
        if (n == keccak256("GovernanceConfigurator")) return address(d.configurator);
        if (n == keccak256("ContentStore")) return address(d.contentStore);
        if (n == keccak256("DependencyRegistry")) return address(d.dependencyRegistry);
        if (n == keccak256("ConsolidationAdapter")) return address(d.consolidationAdapter);
        if (n == keccak256("ArtistRegistry")) return address(d.artistRegistry);
        if (n == keccak256("ReleaseVerifier")) return address(d.releaseVerifier);
        if (n == keccak256("SplitFactory")) return address(d.splitFactory);
        if (n == keccak256("ClaimRouter")) return address(d.claimRouter);
        if (n == keccak256("AssetAllowlist")) return address(d.assetAllowlist);
        if (n == keccak256("EconomicsResolver")) return address(d.economicsResolver);
        if (n == keccak256("RevenueEscrow")) return address(d.revenueEscrow);
        if (n == keccak256("CurationVerifier")) return address(d.curationVerifier);
        if (n == keccak256("PackageRegistry")) return address(d.packageRegistry);
        if (n == keccak256("StatementLog")) return address(d.statementLog);
        if (n == keccak256("EntropyModule")) return address(d.entropyModule);
        if (n == keccak256("EnglishAuction")) return address(d.englishAuction);
        if (n == keccak256("UniformEditionAuction")) return address(d.editionAuction);
        if (n == keccak256("UniformEditionAuctionLens")) return d.editionAuctionLens;
        if (n == keccak256("EnglishAuctionLens")) return address(d.englishAuctionLens);
        if (n == keccak256("Renderer")) return address(d.renderer);
        if (n == keccak256("Stream")) return address(d.stream);
        if (n == keccak256("WorkRecords")) return address(d.workRecords);
        if (n == keccak256("Editions")) return address(d.editions);
        revert UnknownContract(name);
    }

    /// @notice Sets the address of contract `name`, for reloading a recorded deployment.
    function assign(Deployment memory d, string memory name, address a) internal pure {
        bytes32 n = keccak256(bytes(name));
        if (n == keccak256("WorksAccessManager")) {
            d.manager = WorksAccessManager(a);
        } else if (n == keccak256("GovernanceConfigurator")) {
            d.configurator = GovernanceConfigurator(a);
        } else if (n == keccak256("ContentStore")) {
            d.contentStore = ContentStore(a);
        } else if (n == keccak256("DependencyRegistry")) {
            d.dependencyRegistry = DependencyRegistry(a);
        } else if (n == keccak256("ConsolidationAdapter")) {
            d.consolidationAdapter = ConsolidationAdapter(a);
        } else if (n == keccak256("ArtistRegistry")) {
            d.artistRegistry = ArtistRegistry(a);
        } else if (n == keccak256("ReleaseVerifier")) {
            d.releaseVerifier = ReleaseVerifier(a);
        } else if (n == keccak256("SplitFactory")) {
            d.splitFactory = SplitFactory(a);
        } else if (n == keccak256("ClaimRouter")) {
            d.claimRouter = ClaimRouter(a);
        } else if (n == keccak256("AssetAllowlist")) {
            d.assetAllowlist = AssetAllowlist(a);
        } else if (n == keccak256("EconomicsResolver")) {
            d.economicsResolver = EconomicsResolver(a);
        } else if (n == keccak256("RevenueEscrow")) {
            d.revenueEscrow = RevenueEscrow(a);
        } else if (n == keccak256("CurationVerifier")) {
            d.curationVerifier = Eip712CurationVerifier(a);
        } else if (n == keccak256("PackageRegistry")) {
            d.packageRegistry = PackageRegistry(a);
        } else if (n == keccak256("StatementLog")) {
            d.statementLog = StatementLog(a);
        } else if (n == keccak256("EntropyModule")) {
            d.entropyModule = VrfEntropyModule(a);
        } else if (n == keccak256("EnglishAuction")) {
            d.englishAuction = EnglishAuction(a);
        } else if (n == keccak256("UniformEditionAuction")) {
            d.editionAuction = UniformEditionAuction(a);
        } else if (n == keccak256("UniformEditionAuctionLens")) {
            d.editionAuctionLens = a;
        } else if (n == keccak256("EnglishAuctionLens")) {
            d.englishAuctionLens = EnglishAuctionLens(a);
        } else if (n == keccak256("Renderer")) {
            d.renderer = Renderer(a);
        } else if (n == keccak256("Stream")) {
            d.stream = Stream(a);
        } else if (n == keccak256("WorkRecords")) {
            d.workRecords = WorkRecords(a);
        } else if (n == keccak256("Editions")) {
            d.editions = Editions(a);
        } else {
            revert UnknownContract(name);
        }
    }

    /// @notice Every contract name `addressOf` knows, for records and readback.
    function names() internal pure returns (string[] memory list) {
        string[23] memory all = [
        string[22] memory all = [
            "GovernanceConfigurator",
            "WorksAccessManager",
            "ContentStore",
            "DependencyRegistry",
            "ConsolidationAdapter",
            "ArtistRegistry",
            "ReleaseVerifier",
            "SplitFactory",
            "ClaimRouter",
            "AssetAllowlist",
            "EconomicsResolver",
            "RevenueEscrow",
            "CurationVerifier",
            "PackageRegistry",
            "StatementLog",
            "EntropyModule",
            "Renderer",
            "Stream",
            "WorkRecords",
            "EnglishAuction",
        string[24] memory all = [
            "Editions"
        ];
        list = new string[](all.length);
        for (uint256 i; i < all.length; ++i) {
            list[i] = all[i];
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

    /// @notice Reverts unless the JSON's `roles` table is exactly `Roles.sol`: every role once,
    ///         with its ID, execution delay and grant delay. `configure` takes the delays from
    ///         `Roles.sol`; this keeps the published table honest.
    function checkRoles(string memory json) internal view {
        uint256 n = _count(json, ".roles");
        if (n != Roles.COUNT) revert RoleTableMismatch("count");
        for (uint256 i; i < n; ++i) {
            string memory r = _at(".roles", i);
            string memory name = vm.parseJsonString(json, string.concat(r, ".name"));
            uint64 id = _roleId(name);
            if (
                vm.parseJsonUint(json, string.concat(r, ".id")) != id
                    || vm.parseJsonUint(json, string.concat(r, ".executionDelay"))
                        != Roles.executionDelay(id)
                    || vm.parseJsonUint(json, string.concat(r, ".grantDelay"))
                        != Roles.grantDelay(id)
            ) revert RoleTableMismatch(name);
        }
    }

    /// @notice What the genesis JSON names that `d` did not deploy: governed contracts left out
    ///         of `config`, then wiring calls left out of `wiring` (as `Contract.signature`).
    function dropped(Deployment memory d, string memory json)
        internal
        view
        returns (string[] memory out)
    {
        uint256 contracts = _count(json, ".contracts");
        uint256 calls = _count(json, ".wiring");
        out = new string[](contracts + calls);
        uint256 k;
        for (uint256 i; i < contracts; ++i) {
            if (_deployedAt(d, json, i) == address(0)) {
                out[k++] = vm.parseJsonString(json, string.concat(_at(".contracts", i), ".name"));
            }
        }
        Manifest memory none;
        for (uint256 i; i < calls; ++i) {
            (bool kept,) = _wiringCall(d, json, i, none);
            if (!kept) {
                string memory w = _at(".wiring", i);
                out[k++] = string.concat(
                    vm.parseJsonString(json, string.concat(w, ".contract")),
                    ".",
                    vm.parseJsonString(json, string.concat(w, ".signature"))
                );
            }
        }
        assembly ("memory-safe") {
            mstore(out, k)
        }
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

    /// @notice The genesis wiring from the JSON, re-encoded with the deployed addresses. A call
    ///         on, or naming, a contract that is not deployed is left out. The epoch-0 manifest
    ///         statement is built from `manifest`.
    function wiring(Deployment memory d, string memory json, Manifest memory manifest)
        internal
        view
        returns (GovernanceConfig.Call[] memory calls)
    {
        uint256 n = _count(json, ".wiring");
        calls = new GovernanceConfig.Call[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            (bool ok, GovernanceConfig.Call memory c) = _wiringCall(d, json, i, manifest);
            if (ok) calls[k++] = c;
        }
        // Shrink the array to the calls kept. The dropped tail stays allocated but unreachable:
        // the array's length word is all that callers and `abi.encode` read.
        assembly ("memory-safe") {
            mstore(calls, k)
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

    /// @notice Installs `cfg` and `wiring` and renounces the configurator. The caller must be
    ///         `Params.deployer`.
    function install(
        Deployment memory d,
        GovernanceConfig.Config memory cfg,
        Manifest memory manifest,
        GovernanceConfig.Call[] memory calls
    ) internal {
        d.configurator.configure(cfg, manifest.digest, calls);
    }

    function _wiringCall(
        Deployment memory d,
        string memory json,
        uint256 i,
        Manifest memory manifest
    ) private pure returns (bool, GovernanceConfig.Call memory c) {
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
    ///      a bool, a bytes32 literal or an unsigned integer. False if a named contract is not
    ///      deployed.
    function _encodeArgs(
        Deployment memory d,
        string memory json,
        string memory w,
        string memory sig
    ) private pure returns (bool, bytes memory out) {
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
                out = bytes.concat(out, vm.parseJsonBytes32(json, arg));
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
