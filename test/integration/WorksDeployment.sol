// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { DependencyRegistry } from "src/content/DependencyRegistry.sol";
import { Renderer } from "src/content/Renderer.sol";
import { Eip712CurationVerifier } from "src/curation/Eip712CurationVerifier.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { ClaimRouter } from "src/economics/ClaimRouter.sol";
import { EconomicsResolver } from "src/economics/EconomicsResolver.sol";
import { ReleaseVerifier } from "src/economics/ReleaseVerifier.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitFactory } from "src/economics/SplitFactory.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { Editions } from "src/editions/Editions.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { ConsolidationAdapter, IDelegationManagement } from "src/identity/ConsolidationAdapter.sol";
import { IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { ICurationVerifier } from "src/interfaces/ICurationVerifier.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { DutchSale } from "src/sales/DutchSale.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { FixedPriceSale } from "src/sales/FixedPriceSale.sol";
import { Stream } from "src/stream/Stream.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { MockVrfCoordinator } from "../mocks/EntropyMocks.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { MockPermit2, PermitToken } from "../mocks/sales/SaleMocks.sol";

/// @notice Test-only deployment of the whole v1 system, wired exactly as
///         `config/genesis.example.json` and `config/README.md` describe (integration lane B).
/// @dev Lane A's deploy library (`script/`, branch `claude/deploy`) was not on `origin` when this
///      lane started, so this fixture stands in for it. It follows the same rule as the deploy
///      plan:
///      - constructor arguments supply every immutable or pinned dependency (the curation
///        verifier in the package registry, the resolver and escrow in each sale adapter, the
///        consolidation source in the artist registry, the artist resolver in the statement log,
///        the initial economics and default license in the economics resolver);
///      - `GovernanceConfigurator.configure` then applies the committed configuration: the
///        role, delay and selector map read from the JSON, and the JSON's own wiring calldata
///        (binds, admitted minters, sale targets and the epoch-0 manifest), with each placeholder
///        address replaced by the deployed contract it names.
///      Only external systems are mocked: the 6529 delegation contract (the identity lane's
///      faithful reduction), the Chainlink VRF v2.5 coordinator (the entropy lane's), Permit2
///      (the sales lane's faithful reproduction, placed at the canonical address) and an
///      EIP-2612 ERC-20.
abstract contract WorksDeployment is Test {
    string internal constant GENESIS_PATH = "config/genesis.example.json";
    /// @dev Permit2's canonical address on every chain.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bytes32 internal constant MANIFEST_HASH = keccak256("6529 Works integration genesis manifest");
    bytes internal constant CC0_TEXT = "CC0 1.0 Universal (integration fixture text)";
    uint256 internal constant ETH_INCREMENT_FLOOR = 0.001 ether;
    uint256 internal constant INLINE_THRESHOLD = 262_144;
    uint32 internal constant AUCTION_DURATION = 24 hours;
    uint32 internal constant EXTENSION_WINDOW = 15 minutes;
    uint32 internal constant INCREMENT_SHARE = 5_000;

    // ------------------------------------------------------------------ external systems
    DelegationManagementMock internal delegation;
    MockVrfCoordinator internal coordinator;
    MockPermit2 internal permit2;
    PermitToken internal usd;

    // ------------------------------------------------------------------ governance
    GovernanceConfigurator internal configurator;
    WorksAccessManager internal manager;

    // ------------------------------------------------------------------ v1 contracts
    ContentStore internal store;
    DependencyRegistry internal dependencies;
    ConsolidationAdapter internal consolidation;
    ArtistRegistry internal artists;
    ReleaseVerifier internal releaseVerifier;
    SplitFactory internal splitFactory;
    ClaimRouter internal claimRouter;
    AssetAllowlist internal allowlist;
    EconomicsResolver internal economics;
    RevenueEscrow internal escrow;
    Eip712CurationVerifier internal verifier;
    PackageRegistry internal registry;
    StatementLog internal statements;
    Renderer internal renderer;
    VrfEntropyModule internal entropy;
    Stream internal stream;
    WorkRecords internal records;
    Editions internal editions;
    EnglishAuction internal auction;
    FixedPriceSale internal fixedSale;
    DutchSale internal dutchSale;

    // ------------------------------------------------------------------ genesis holders
    address internal hotAdmin = makeAddr("hotAdminSafe");
    address internal coldAdmin = makeAddr("coldAdminSafe");
    address internal guardian1 = makeAddr("guardianSafe1");
    address internal guardian2 = makeAddr("guardianSafe2");
    address internal guardian3 = makeAddr("guardianSafe3");
    uint256 internal signer1Pk = uint256(keccak256("curation signer 1"));
    uint256 internal signer2Pk = uint256(keccak256("curation signer 2"));
    address internal signer1;
    address internal signer2;
    address internal storageOperator = makeAddr("storageOperator");
    address internal platform = makeAddr("platform");
    address internal curator = makeAddr("curator");
    address internal networkFee = makeAddr("networkFeeSafe");
    address internal marketOwner = makeAddr("marketOwner");

    bytes32 internal cc0TextFileId;
    string internal genesisJson;
    /// @dev Set to deploy everything but leave `configure` to the test (genesis measurements).
    bool internal deferGenesis;

    function _deployWorks() internal {
        signer1 = vm.addr(signer1Pk);
        signer2 = vm.addr(signer2Pk);
        genesisJson = vm.readFile(GENESIS_PATH);
        _deployExternals();
        configurator = new GovernanceConfigurator();
        manager = configurator.worksManager();
        _deployContent();
        _deployIdentityAndEconomics();
        _deployCuration();
        _deployCore();
        _deploySales();
        if (!deferGenesis) {
            configurator.configure(_genesisConfig(), MANIFEST_HASH, _genesisWiring());
        }
    }

    // ------------------------------------------------------------------ deployment, in order

    function _deployExternals() private {
        delegation = new DelegationManagementMock();
        coordinator = new MockVrfCoordinator();
        deployCodeTo("SaleMocks.sol:MockPermit2", PERMIT2);
        permit2 = MockPermit2(PERMIT2);
        usd = new PermitToken();
    }

    function _deployContent() private {
        store = new ContentStore();
        cc0TextFileId = _storeText(CC0_TEXT, "text/plain");
        dependencies = new DependencyRegistry(address(manager), IContentStore(address(store)));
    }

    function _deployIdentityAndEconomics() private {
        consolidation = new ConsolidationAdapter(IDelegationManagement(address(delegation)));
        artists = new ArtistRegistry(
            address(manager),
            IConsolidationSource(address(consolidation)),
            address(consolidation).codehash
        );
        releaseVerifier = new ReleaseVerifier();
        splitFactory = new SplitFactory(
            IArtistPayoutResolver(address(artists)), IReleaseVerifier(address(releaseVerifier))
        );
        claimRouter = new ClaimRouter();
        allowlist = new AssetAllowlist(address(manager), ETH_INCREMENT_FLOOR);
        economics = new EconomicsResolver(
            address(manager),
            IAssetAllowlist(address(allowlist)),
            ISplitFactory(address(splitFactory)),
            networkFee,
            cc0TextFileId
        );
        escrow = new RevenueEscrow(address(manager), ISplitFactory(address(splitFactory)));
    }

    function _deployCuration() private {
        verifier = new Eip712CurationVerifier(address(manager));
        registry = new PackageRegistry(
            address(manager),
            ICurationVerifier(address(verifier)),
            address(verifier).codehash,
            address(artists),
            address(artists).codehash
        );
        statements = new StatementLog(address(manager), address(artists), address(artists).codehash);
        renderer = new Renderer(
            IContentStore(address(store)), IStatementLog(address(statements)), INLINE_THRESHOLD
        );
        entropy = new VrfEntropyModule(
            address(manager),
            address(coordinator),
            address(coordinator).codehash,
            VrfEntropyModule.VrfConfig(1, keccak256("vrf key hash"), 500_000, 3, false),
            3 days,
            IPackageRegistry(address(registry)),
            address(registry).codehash
        );
    }

    function _deployCore() private {
        stream = new Stream(
            address(manager),
            address(registry),
            address(artists),
            address(economics),
            address(entropy),
            address(renderer),
            address(renderer).codehash,
            marketOwner
        );
        records = new WorkRecords(
            address(manager), address(stream), address(store), License("CC0-1.0", cc0TextFileId)
        );
        editions =
            new Editions(address(manager), address(stream), address(stream).codehash, marketOwner);
    }

    function _deploySales() private {
        auction = new EnglishAuction(
            address(manager),
            address(escrow),
            IAssetAllowlist(address(allowlist)),
            address(statements),
            PERMIT2,
            IEnglishAuction.AuctionConfig(AUCTION_DURATION, EXTENSION_WINDOW, INCREMENT_SHARE),
            new address[](0)
        );
        fixedSale = new FixedPriceSale(
            address(manager),
            IRevenueEscrow(address(escrow)),
            ISignatureTransfer(PERMIT2),
            IEconomicsResolver(address(economics))
        );
        dutchSale = new DutchSale(
            address(manager),
            IRevenueEscrow(address(escrow)),
            ISignatureTransfer(PERMIT2),
            IEconomicsResolver(address(economics))
        );
    }

    // ------------------------------------------------------------------ content helpers

    /// @dev Uploads `stored` in `CHUNK_SIZE` chunks and registers its manifest. `sha` is the
    ///      decoded media's SHA-256 (the store does not recompute it).
    function _upload(
        bytes memory stored,
        IContentStore.Encoding encoding,
        string memory mime,
        bytes32 sha
    ) internal returns (bytes32 fileId) {
        bytes32[] memory hashes = _writeChunks(stored);
        fileId = store.registerManifest(hashes, stored.length, encoding, mime, sha);
    }

    /// @dev Registers the manifest of `stored` without uploading any chunk (the off-chain default).
    function _registerOnly(
        bytes memory stored,
        IContentStore.Encoding encoding,
        string memory mime,
        bytes32 sha
    ) internal returns (bytes32 fileId) {
        fileId = store.registerManifest(_chunkHashes(stored), stored.length, encoding, mime, sha);
    }

    function _writeChunks(bytes memory stored) internal returns (bytes32[] memory hashes) {
        uint256 size = store.CHUNK_SIZE();
        hashes = new bytes32[]((stored.length + size - 1) / size);
        for (uint256 i; i < hashes.length; ++i) {
            (hashes[i],) = store.writeChunk(_slice(stored, i * size, size));
        }
    }

    function _chunkHashes(bytes memory stored) internal view returns (bytes32[] memory hashes) {
        uint256 size = store.CHUNK_SIZE();
        hashes = new bytes32[]((stored.length + size - 1) / size);
        for (uint256 i; i < hashes.length; ++i) {
            hashes[i] = keccak256(_slice(stored, i * size, size));
        }
    }

    function _storeText(bytes memory text, string memory mime) internal returns (bytes32) {
        return _upload(text, IContentStore.Encoding.Identity, mime, sha256(text));
    }

    function _slice(bytes memory data, uint256 from, uint256 max)
        internal
        pure
        returns (bytes memory out)
    {
        uint256 n = data.length - from < max ? data.length - from : max;
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = data[from + i];
        }
    }

    // ------------------------------------------------------------------ the committed genesis

    function _at(string memory base, uint256 i) internal pure returns (string memory) {
        return string.concat(base, "[", vm.toString(i), "]");
    }

    function _count(string memory base) internal view returns (uint256 n) {
        while (vm.keyExistsJson(genesisJson, _at(base, n))) ++n;
    }

    function _jsonString(string memory key) internal view returns (string memory) {
        return vm.parseJsonString(genesisJson, key);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _roleId(string memory name) internal pure returns (uint64) {
        if (_eq(name, "ADMIN")) return Roles.ADMIN;
        for (uint64 role = 1; role < Roles.COUNT; ++role) {
            if (_eq(name, Roles.label(role))) return role;
        }
        revert(string.concat("unknown role ", name));
    }

    /// @dev The deployed contract (or peer) a JSON name stands for.
    function _deployed(string memory name) internal view returns (address) {
        if (_eq(name, "Stream")) return address(stream);
        if (_eq(name, "WorkRecords")) return address(records);
        if (_eq(name, "Editions")) return address(editions);
        if (_eq(name, "PackageRegistry")) return address(registry);
        if (_eq(name, "CurationVerifier")) return address(verifier);
        if (_eq(name, "ArtistRegistry")) return address(artists);
        if (_eq(name, "StatementLog")) return address(statements);
        if (_eq(name, "EnglishAuction")) return address(auction);
        if (_eq(name, "FixedPriceSale")) return address(fixedSale);
        if (_eq(name, "DutchSale")) return address(dutchSale);
        if (_eq(name, "EconomicsResolver")) return address(economics);
        if (_eq(name, "AssetAllowlist")) return address(allowlist);
        if (_eq(name, "RevenueEscrow")) return address(escrow);
        if (_eq(name, "DependencyRegistry")) return address(dependencies);
        if (_eq(name, "EntropyModule")) return address(entropy);
        if (_eq(name, "SplitFactory")) return address(splitFactory);
        if (_eq(name, "WorksAccessManager")) return address(manager);
        revert(string.concat("no deployment for ", name));
    }

    /// @dev The genesis holder a placeholder account (`0x...b0xx`) stands for.
    function _holder(address placeholder) internal view returns (address) {
        uint160 p = uint160(placeholder);
        if (p == 0xb001) return hotAdmin;
        if (p == 0xb002) return coldAdmin;
        if (p == 0xb011) return guardian1;
        if (p == 0xb012) return guardian2;
        if (p == 0xb013) return guardian3;
        if (p == 0xb021) return signer1;
        if (p == 0xb022) return signer2;
        if (p == 0xb031) return storageOperator;
        if (p == 0xb051) return platform;
        if (p == 0xb061) return curator;
        revert(string.concat("unknown holder ", vm.toString(placeholder)));
    }

    /// @dev The deployed address behind a contract or peer placeholder, or zero for none.
    function _placeholderTarget(uint256 word) internal view returns (address) {
        if (word >> 16 != 0 || (word & 0xff00) != 0xa000) return address(0);
        string[2] memory lists = [".contracts", ".peers"];
        for (uint256 l; l < 2; ++l) {
            for (uint256 i; i < _count(lists[l]); ++i) {
                string memory c = _at(lists[l], i);
                address location = vm.parseJsonAddress(genesisJson, string.concat(c, ".address"));
                if (uint160(location) == word) {
                    return _deployed(_jsonString(string.concat(c, ".name")));
                }
            }
        }
        return address(0);
    }

    /// @dev `cfg` from the JSON: every holder, and every contract's mapped selectors, with the
    ///      placeholders replaced by this deployment's addresses.
    function _genesisConfig() internal view returns (GovernanceConfig.Config memory cfg) {
        uint256 holders = _count(".holders");
        cfg.grants = new GovernanceConfig.Grant[](holders);
        for (uint256 i; i < holders; ++i) {
            string memory h = _at(".holders", i);
            cfg.grants[i] = GovernanceConfig.Grant(
                _roleId(_jsonString(string.concat(h, ".role"))),
                _holder(vm.parseJsonAddress(genesisJson, string.concat(h, ".account")))
            );
        }
        uint256 contracts = _count(".contracts");
        cfg.targets = new GovernanceConfig.Target[](contracts);
        for (uint256 i; i < contracts; ++i) {
            string memory c = _at(".contracts", i);
            string memory fnBase = string.concat(c, ".functions");
            uint256 n = _count(fnBase);
            GovernanceConfig.FunctionRole[] memory fns = new GovernanceConfig.FunctionRole[](n);
            for (uint256 j; j < n; ++j) {
                string memory f = _at(fnBase, j);
                bytes memory raw = vm.parseJsonBytes(genesisJson, string.concat(f, ".selector"));
                fns[j] = GovernanceConfig.FunctionRole(
                    bytes4(raw), _roleId(_jsonString(string.concat(f, ".role")))
                );
            }
            cfg.targets[i] =
                GovernanceConfig.Target(_deployed(_jsonString(string.concat(c, ".name"))), fns);
        }
    }

    /// @dev The JSON's wiring calls, its committed calldata with every placeholder word replaced.
    function _genesisWiring() internal view returns (GovernanceConfig.Call[] memory wiring) {
        uint256 n = _count(".wiring");
        wiring = new GovernanceConfig.Call[](n);
        for (uint256 i; i < n; ++i) {
            string memory w = _at(".wiring", i);
            bytes memory data = vm.parseJsonBytes(genesisJson, string.concat(w, ".calldata"));
            for (uint256 offset = 4; offset + 32 <= data.length; offset += 32) {
                uint256 word;
                assembly ("memory-safe") {
                    word := mload(add(add(data, 0x20), offset))
                }
                address real = _placeholderTarget(word);
                if (real == address(0)) continue;
                assembly ("memory-safe") {
                    mstore(add(add(data, 0x20), offset), real)
                }
            }
            wiring[i] =
                GovernanceConfig.Call(_deployed(_jsonString(string.concat(w, ".contract"))), data);
        }
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

    /// @dev Schedules a governed call and returns the operation ID, for cancellation tests.
    function _schedule(address caller, address target, bytes memory data)
        internal
        returns (bytes32 operationId)
    {
        vm.prank(caller);
        (operationId,) = manager.schedule(target, data, 0);
    }

    function _bubble(bool ok, bytes memory reason) internal pure {
        if (ok) return;
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}
