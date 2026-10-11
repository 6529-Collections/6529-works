// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { DependencyRegistry } from "src/content/DependencyRegistry.sol";
import { Eip712CurationVerifier } from "src/curation/Eip712CurationVerifier.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { ClaimRouter } from "src/economics/ClaimRouter.sol";
import { EconomicsResolver } from "src/economics/EconomicsResolver.sol";
import { ReleaseVerifier } from "src/economics/ReleaseVerifier.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitFactory } from "src/economics/SplitFactory.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IStatementLog, Statement } from "src/interfaces/IStatementLog.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { HashRef, HASH_SHA256 } from "src/interfaces/types/HashRef.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { DutchSale } from "src/sales/DutchSale.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { FixedPriceSale } from "src/sales/FixedPriceSale.sol";
import { ArtistRegistryStandIn } from "./standins/ArtistRegistryStandIn.sol";

/// @title DeployV1
/// @notice Deploys every v1 contract in dependency order and installs the genesis
///         configuration. `script/Deploy.s.sol` broadcasts it; the integration tests call it
///         directly, so both exercise the same deployment.
/// @dev Immutable dependencies are constructor arguments; one-shot binds, admitted minters,
///      sale targets and the epoch-0 manifest are genesis wiring (config/README.md). Every
///      contract is created with CREATE2 under `Params.namespace`, so its address depends only
///      on the namespace, its constructor arguments and the CREATE2 deployer. The governance
///      map and the wiring come from the committed genesis JSON, with the deployed addresses
///      substituted by contract name; contracts not deployed (pending lanes, the optional
///      entropy module) are left out of both, together with any wiring that names them.
library DeployV1 {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Anvil's chain ID: the only chain where stand-ins and placeholders are allowed.
    uint256 internal constant LOCAL_CHAIN_ID = 31337;
    /// @notice Uniswap's canonical Permit2, deployed at the same address on every major chain.
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @notice Schema of the governance manifest statements in the statement log.
    bytes32 internal constant MANIFEST_SCHEMA = keccak256("6529-works/governance-manifest/1");

    struct Params {
        /// The operator account that broadcasts the genesis and alone may call `configure`.
        address deployer;
        /// CREATE2 salt namespace; one namespace deploys one system.
        bytes32 namespace;
        /// Network share recipient of every product (EconomicsResolver defaults).
        address feeRecipient;
        /// ContentStore file ID of the CC0 1.0 legal code (the default license text).
        bytes32 cc0TextFileId;
        /// Minimum ETH bid increment, 0.001 ether at launch (ADR 0001 §5).
        uint256 ethIncrementFloor;
        /// Permit2; the auction gets it only where it has code.
        address permit2;
        IEnglishAuction.AuctionConfig auction;
        /// Chainlink VRF v2.5 coordinator, or zero to deploy without the entropy module.
        address vrfCoordinator;
        bytes32 vrfCoordinatorCodeHash;
        VrfEntropyModule.VrfConfig vrf;
        uint64 vrfRetryDelay;
    }

    struct Deployment {
        GovernanceConfigurator configurator;
        WorksAccessManager manager;
        ContentStore contentStore;
        DependencyRegistry dependencyRegistry;
        address artistRegistry;
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
        FixedPriceSale fixedPriceSale;
        DutchSale dutchSale;
        // Pending lanes, zero until they merge: renderer, stream (Stream and WorkRecords) and
        // editions. Their slots in `deploy` are marked below.
        address renderer;
        address stream;
        address workRecords;
        address editions;
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
    /// @notice The identity lane has not merged: only a local dry run may deploy, with the
    ///         `ArtistRegistryStandIn`.
    error ArtistRegistryPending();

    // ------------------------------------------------------------------ deploy

    /// @notice Deploys the system. Every contract's authority is the configurator's manager.
    function deploy(Params memory p) internal returns (Deployment memory d) {
        d.configurator =
            new GovernanceConfigurator{ salt: salt(p, "GovernanceConfigurator") }(p.deployer);
        d.manager = d.configurator.worksManager();
        _content(p, d);
        _identity(p, d);
        _economics(p, d);
        _curationAndRecords(p, d);
        _entropy(p, d);
        _sales(p, d);
        // Pending lanes slot in here, in this order, as they merge (constructors from their
        // branches; see script/README.md):
        //   d.renderer   = Renderer(contentStore, statementLog, inlineThreshold)
        //   d.stream     = Stream(manager, packageRegistry, artistRegistry, economicsResolver,
        //                         entropyModule, renderer, renderer.codehash, marketplaceOwner)
        //   d.workRecords = WorkRecords(manager, stream, contentStore, CC0 license)
        //   d.editions   = Editions(manager, stream, stream.codehash, marketplaceOwner)
    }

    /// @notice The CREATE2 salt of contract `name` under `p.namespace`.
    function salt(Params memory p, string memory name) internal pure returns (bytes32) {
        return keccak256(abi.encode(p.namespace, name));
    }

    function _content(Params memory p, Deployment memory d) private {
        d.contentStore = new ContentStore{ salt: salt(p, "ContentStore") }();
        d.dependencyRegistry = new DependencyRegistry{ salt: salt(p, "DependencyRegistry") }(
            address(d.manager), d.contentStore
        );
    }

    function _identity(Params memory p, Deployment memory d) private {
        // The identity lane's ConsolidationAdapter and ArtistRegistry replace this as it merges:
        //   adapter        = ConsolidationAdapter(delegation)
        //   artistRegistry = ArtistRegistry(manager, adapter, adapter.codehash)
        if (block.chainid != LOCAL_CHAIN_ID) revert ArtistRegistryPending();
        d.artistRegistry = address(
            new ArtistRegistryStandIn{ salt: salt(p, "ArtistRegistry") }(address(d.manager))
        );
    }

    function _economics(Params memory p, Deployment memory d) private {
        address m = address(d.manager);
        d.releaseVerifier = new ReleaseVerifier{ salt: salt(p, "ReleaseVerifier") }();
        d.splitFactory = new SplitFactory{ salt: salt(p, "SplitFactory") }(
            IArtistPayoutResolver(d.artistRegistry), d.releaseVerifier
        );
        d.claimRouter = new ClaimRouter{ salt: salt(p, "ClaimRouter") }();
        d.assetAllowlist =
            new AssetAllowlist{ salt: salt(p, "AssetAllowlist") }(m, p.ethIncrementFloor);
        d.economicsResolver = new EconomicsResolver{ salt: salt(p, "EconomicsResolver") }(
            m, d.assetAllowlist, d.splitFactory, p.feeRecipient, p.cc0TextFileId
        );
        d.revenueEscrow = new RevenueEscrow{ salt: salt(p, "RevenueEscrow") }(m, d.splitFactory);
    }

    function _curationAndRecords(Params memory p, Deployment memory d) private {
        address m = address(d.manager);
        d.curationVerifier = new Eip712CurationVerifier{ salt: salt(p, "CurationVerifier") }(m);
        d.packageRegistry = new PackageRegistry{ salt: salt(p, "PackageRegistry") }(
            m,
            d.curationVerifier,
            address(d.curationVerifier).codehash,
            d.artistRegistry,
            d.artistRegistry.codehash
        );
        d.statementLog = new StatementLog{ salt: salt(p, "StatementLog") }(
            m, d.artistRegistry, d.artistRegistry.codehash
        );
    }

    function _entropy(Params memory p, Deployment memory d) private {
        if (p.vrfCoordinator == address(0)) return; // optional module (ADR 0001 §9)
        d.entropyModule = new VrfEntropyModule{ salt: salt(p, "EntropyModule") }(
            address(d.manager),
            p.vrfCoordinator,
            p.vrfCoordinatorCodeHash,
            p.vrf,
            p.vrfRetryDelay,
            d.packageRegistry,
            address(d.packageRegistry).codehash
        );
    }

    function _sales(Params memory p, Deployment memory d) private {
        address m = address(d.manager);
        // Targets are genesis wiring, not constructor arguments (config/README.md).
        d.englishAuction = new EnglishAuction{ salt: salt(p, "EnglishAuction") }(
            m,
            address(d.revenueEscrow),
            d.assetAllowlist,
            address(d.statementLog),
            p.permit2.code.length != 0 ? p.permit2 : address(0),
            p.auction,
            new address[](0)
        );
        d.fixedPriceSale = new FixedPriceSale{ salt: salt(p, "FixedPriceSale") }(
            m, d.revenueEscrow, ISignatureTransfer(p.permit2), d.economicsResolver
        );
        d.dutchSale = new DutchSale{ salt: salt(p, "DutchSale") }(
            m, d.revenueEscrow, ISignatureTransfer(p.permit2), d.economicsResolver
        );
    }

    // ------------------------------------------------------------------ names

    /// @notice The deployed address of a contract or peer named in the genesis JSON, or zero
    ///         if it is not deployed (pending lane or optional module).
    function addressOf(Deployment memory d, string memory name) internal pure returns (address) {
        bytes32 n = keccak256(bytes(name));
        if (n == keccak256("WorksAccessManager")) return address(d.manager);
        if (n == keccak256("GovernanceConfigurator")) return address(d.configurator);
        if (n == keccak256("ContentStore")) return address(d.contentStore);
        if (n == keccak256("DependencyRegistry")) return address(d.dependencyRegistry);
        if (n == keccak256("ArtistRegistry")) return d.artistRegistry;
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
        if (n == keccak256("FixedPriceSale")) return address(d.fixedPriceSale);
        if (n == keccak256("DutchSale")) return address(d.dutchSale);
        if (n == keccak256("Renderer")) return d.renderer;
        if (n == keccak256("Stream")) return d.stream;
        if (n == keccak256("WorkRecords")) return d.workRecords;
        if (n == keccak256("Editions")) return d.editions;
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
        } else if (n == keccak256("ArtistRegistry")) {
            d.artistRegistry = a;
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
        } else if (n == keccak256("FixedPriceSale")) {
            d.fixedPriceSale = FixedPriceSale(a);
        } else if (n == keccak256("DutchSale")) {
            d.dutchSale = DutchSale(a);
        } else if (n == keccak256("Renderer")) {
            d.renderer = a;
        } else if (n == keccak256("Stream")) {
            d.stream = a;
        } else if (n == keccak256("WorkRecords")) {
            d.workRecords = a;
        } else if (n == keccak256("Editions")) {
            d.editions = a;
        } else {
            revert UnknownContract(name);
        }
    }

    /// @notice Every contract name `addressOf` knows, for records and readback.
    function names() internal pure returns (string[22] memory) {
        return [
            "GovernanceConfigurator",
            "WorksAccessManager",
            "ContentStore",
            "DependencyRegistry",
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
            "EnglishAuction",
            "FixedPriceSale",
            "DutchSale",
            "Renderer",
            "Stream",
            "WorkRecords",
            "Editions"
        ];
    }

    // ------------------------------------------------------------------ genesis configuration

    /// @notice `cfg` from the genesis JSON: every holder, and every deployed contract's governed
    ///         selectors at its deployed address.
    function config(Deployment memory d, string memory json)
        internal
        view
        returns (GovernanceConfig.Config memory cfg)
    {
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
        while (s[open] != "(") ++open;
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
