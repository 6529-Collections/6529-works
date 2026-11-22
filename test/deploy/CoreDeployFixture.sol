// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DeployCore } from "script/DeployCore.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { MintFacts } from "src/interfaces/core/CoreTypes.sol";
import {
    MockAccounts,
    MockFederationGate,
    MockRecords,
    MockRenderer,
    MockSale,
    MockTerms
} from "../mocks/core/CoreMocks.sol";

/// @notice The permanent part of the plain-core stack, deployed by the deploy library
///         (`DeployCore.deployPermanent`) at its predicted addresses, with pass-through stand-ins
///         etched at the predicted addresses of the genesis modules and minters, and the
///         governance policy of `config/genesis.core.example.json` installed for the contracts
///         that exist. The network is whatever `_networkAccount` returns (a key here, a Safe on
///         a fork); every network call goes through `_asNetwork`.
/// @dev The replaceable modules are being written by other lanes: `DeployCore.deploy` (the
///      whole stack) runs at integration. Until then the stand-ins are `test/mocks/core`.
abstract contract CoreDeployFixture is Test {
    string internal constant GENESIS = "config/genesis.core.example.json";
    string internal constant CC0_FIXTURE = "test/fixtures/cc0-legalcode.txt";

    DeployCore.Params internal p;
    DeployCore.Deployment internal d;
    address internal network;
    address internal deployer = makeAddr("deployer");
    address internal marketOwner = makeAddr("marketOwner");
    address internal museum = makeAddr("museum");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal stranger = makeAddr("stranger");
    /// @dev The genesis file's platform key (it may create collections).
    address internal platform;

    /// @dev The stand-in minters at the predicted addresses of the two genesis sale contracts.
    MockSale internal sale;
    MockSale internal editionSale;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        p = _params();
        d = DeployCore.deployPermanent(p, address(this));
        _etchModules();
        network = _networkAccount();
        _install();
        string memory json = vm.readFile(GENESIS);
        platform = _holder(json, "PLATFORM");
    }

    /// @dev The account that holds the network roles.
    function _networkAccount() internal virtual returns (address);

    /// @dev Makes the network call `target` with `data`; bubbles a revert.
    function _asNetwork(address target, bytes memory data) internal virtual {
        vm.prank(network);
        (bool ok, bytes memory reason) = target.call(data);
        if (!ok) _bubble(reason);
    }

    /// @dev Expects the next network call to revert with `reason`.
    function _expectNetworkRevert(bytes memory reason) internal virtual {
        vm.expectRevert(reason);
    }

    function _params() internal view returns (DeployCore.Params memory q) {
        q.deployer = deployer;
        q.namespace = keccak256("6529-works/core-test");
        q.feeRecipient = feeRecipient;
        q.museum = museum;
        q.marketOwner = marketOwner;
        q.cc0Text = vm.readFileBinary(CC0_FIXTURE);
        q.ethIncrementFloor = 0.001 ether;
    }

    /// @dev Pass-through stand-ins at the predicted module and minter addresses.
    function _etchModules() internal {
        vm.etch(d.renderer, address(new MockRenderer()).code);
        vm.etch(d.streamTerms, address(new MockTerms()).code);
        vm.etch(d.workRules, address(new MockRecords(IWorkFacts(address(d.workFacts)))).code);
        vm.etch(d.accounts, address(new MockAccounts()).code);
        vm.etch(d.federationRegistry, address(new MockFederationGate()).code);
        vm.etch(d.englishAuction, address(new MockSale()).code);
        vm.etch(d.editionAuction, address(new MockSale()).code);
        sale = MockSale(d.englishAuction);
        editionSale = MockSale(d.editionAuction);
    }

    /// @dev The deployment as the governance policy sees it now: only contracts that exist and
    ///      are governed (the stand-ins are not).
    function _governed() internal view returns (DeployCore.Deployment memory g) {
        g.manager = d.manager;
        g.configurator = d.configurator;
        g.contentStore = d.contentStore;
        g.workFacts = d.workFacts;
        g.directory = d.directory;
        g.feeRecipientVault = d.feeRecipientVault;
        g.museumVault = d.museumVault;
        g.splitLedger = d.splitLedger;
        g.claimRouter = d.claimRouter;
        g.revenueEscrow = d.revenueEscrow;
        g.stream = d.stream;
        g.editions = d.editions;
    }

    function _config() internal view returns (GovernanceConfig.Config memory cfg) {
        cfg = DeployCore.config(_governed(), vm.readFile(GENESIS));
        cfg.network = network;
    }

    function _install() internal {
        DeployCore.Manifest memory manifest =
            DeployCore.Manifest(keccak256("core test manifest"), "ar://core-test");
        GovernanceConfig.Call[] memory calls =
            DeployCore.wiring(_governed(), vm.readFile(GENESIS), manifest);
        GovernanceConfig.Config memory cfg = _config();
        vm.prank(deployer);
        DeployCore.install(d, cfg, manifest, calls);
        _asNetwork(address(d.manager), abi.encodeCall(WorksAccessManager.acceptNetwork, ()));
    }

    function _holder(string memory json, string memory role) internal pure returns (address) {
        for (uint256 i;; ++i) {
            string memory h = string.concat(".holders[", vm.toString(i), "]");
            if (
                keccak256(bytes(vm.parseJsonString(json, string.concat(h, ".role"))))
                    == keccak256(bytes(role))
            ) {
                return vm.parseJsonAddress(json, string.concat(h, ".account"));
            }
        }
    }

    /// @dev Mint facts for work number `n` in collection 1.
    function _facts(uint256 n) internal pure returns (MintFacts memory f) {
        f.itemHash = keccak256(abi.encode("item", n));
        f.contentHash = keccak256(abi.encode("content", n));
        f.artistId = uint160(0xA11CE);
        f.collectionId = 1;
        f.royaltyReceiver = address(0xFEE);
        f.royaltyRate = 6529;
    }

    /// @dev Creates collection 1 (platform key) and mints work `n` into the sale's custody.
    function _mintInCustody(uint256 n) internal returns (uint256 tokenId) {
        if (d.stream.collectionCount() == 0) {
            vm.prank(platform);
            d.stream.createCollection("Genesis", bytes32(uint256(1)));
        }
        tokenId = sale.mint(address(d.stream), _facts(n));
    }

    function _bubble(bytes memory reason) internal pure {
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}
