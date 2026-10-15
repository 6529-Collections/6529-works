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
import { Editions } from "src/editions/Editions.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { ConsolidationAdapter } from "src/identity/ConsolidationAdapter.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { DutchSale } from "src/sales/DutchSale.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { FixedPriceSale } from "src/sales/FixedPriceSale.sol";
import { Stream } from "src/stream/Stream.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { MockVrfCoordinator } from "../mocks/EntropyMocks.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { MockPermit2, PermitToken } from "../mocks/sales/SaleMocks.sol";

/// @notice The whole v1 system for the end-to-end flows (integration lane B), deployed and
///         configured by Lane A's deploy library, `script/DeployV1.sol`: the same code the
///         deploy script broadcasts.
/// @dev `DeployV1.deploy` creates every contract in dependency order with CREATE2, immutable
///      dependencies as constructor arguments; `DeployV1.install` then runs
///      `GovernanceConfigurator.configure` with `config/genesis.example.json`'s role and selector
///      map and its wiring (binds, admitted minters, sale targets, default currencies and the
///      epoch-0 manifest). The JSON's placeholder holders are replaced by this test's actors,
///      so the curation signers are keys the test holds.
///
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

    // ------------------------------------------------------------------ the deployment
    DeployV1.Deployment internal deployment;
    DeployV1.Manifest internal manifest;
    GovernanceConfigurator internal configurator;
    WorksAccessManager internal manager;
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
        _deployExternals();

        DeployV1.Deployment memory d = DeployV1.deploy(_params());
        deployment = d;
        _adopt(d);
        genesisJson = _withHolders(vm.readFile(GENESIS_PATH));
        manifest = DeployV1.Manifest(MANIFEST_HASH, "ar://integration-epoch-0-manifest");
        if (!deferGenesis) DeployV1.install(d, _genesisConfig(), manifest, _genesisWiring());
    }

    /// @dev The external systems: the identity lane's delegation reduction, the entropy lane's
    ///      VRF coordinator mock, the sales lane's Permit2 reproduction at the canonical address,
    ///      and an EIP-2612 ERC-20. A fork test overrides this to keep the real deployments.
    function _deployExternals() internal virtual {
        delegation = new DelegationManagementMock();
        coordinator = new MockVrfCoordinator();
        deployCodeTo("SaleMocks.sol:MockPermit2", PERMIT2);
        permit2 = MockPermit2(PERMIT2);
        usd = new PermitToken();
    }

    function _params() internal view virtual returns (DeployV1.Params memory p) {
        p.deployer = address(this);
        p.namespace = keccak256("6529-works/integration-lane-b");
        p.feeRecipient = networkFee;
        p.marketOwner = marketOwner;
        p.delegation = address(delegation);
        p.cc0Text = CC0_TEXT;
        p.ethIncrementFloor = ETH_INCREMENT_FLOOR;
        p.permit2 = PERMIT2;
        p.auction =
            IEnglishAuction.AuctionConfig(AUCTION_DURATION, EXTENSION_WINDOW, INCREMENT_SHARE);
        p.vrfCoordinator = address(coordinator);
        p.vrfCoordinatorCodeHash = address(coordinator).codehash;
        p.vrf = VrfEntropyModule.VrfConfig(1, keccak256("vrf key hash"), 500_000, 3, false);
        p.vrfRetryDelay = 3 days;
    }

    function _adopt(DeployV1.Deployment memory d) private {
        cc0TextFileId = d.cc0TextFileId;
        configurator = d.configurator;
        manager = d.manager;
        store = d.contentStore;
        dependencies = d.dependencyRegistry;
        consolidation = d.consolidationAdapter;
        artists = d.artistRegistry;
        releaseVerifier = d.releaseVerifier;
        splitFactory = d.splitFactory;
        claimRouter = d.claimRouter;
        allowlist = d.assetAllowlist;
        economics = d.economicsResolver;
        escrow = d.revenueEscrow;
        verifier = d.curationVerifier;
        registry = d.packageRegistry;
        statements = d.statementLog;
        renderer = Renderer(address(d.renderer));
        entropy = d.entropyModule;
        stream = d.stream;
        records = d.workRecords;
        editions = Editions(address(d.editions));
        auction = d.englishAuction;
        fixedSale = d.fixedPriceSale;
        dutchSale = d.dutchSale;
    }

    /// @dev The committed genesis JSON with each placeholder holder (`0x...b0xx`) replaced by
    ///      this test's actor for it.
    function _withHolders(string memory json) internal view returns (string memory) {
        address[10] memory actors = [
            hotAdmin,
            coldAdmin,
            guardian1,
            guardian2,
            guardian3,
            signer1,
            signer2,
            storageOperator,
            platform,
            curator
        ];
        uint16[10] memory placeholders =
            [0xb001, 0xb002, 0xb011, 0xb012, 0xb013, 0xb021, 0xb022, 0xb031, 0xb051, 0xb061];
        for (uint256 i; i < 10; ++i) {
            string memory from = vm.toLowercase(vm.toString(address(uint160(placeholders[i]))));
            json = vm.replace(json, from, vm.toString(actors[i]));
        }
        return json;
    }

    /// @dev The genesis configuration `install` applies: holders and governed selectors.
    function _genesisConfig() internal view returns (GovernanceConfig.Config memory) {
        return DeployV1.config(deployment, genesisJson);
    }

    /// @dev The genesis wiring `install` runs, re-encoded with the deployed addresses.
    function _genesisWiring() internal view returns (GovernanceConfig.Call[] memory) {
        return DeployV1.wiring(deployment, genesisJson, manifest);
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
