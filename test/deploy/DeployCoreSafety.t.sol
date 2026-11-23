// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { CoreFactory } from "script/CoreFactory.sol";
import { DeployCore } from "script/DeployCore.sol";
import { DeployGuards } from "script/DeployGuards.sol";
import { ScriptIO } from "script/ScriptIO.sol";
import { VerifyCore } from "script/VerifyCore.sol";
import { VerifyCoreScript } from "script/VerifyCore.s.sol";
import { StreamEditions6529 } from "src/core/StreamEditions6529.sol";
import { Stream6529 } from "src/core/Stream6529.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { MockVrfCoordinator } from "../mocks/entropy/EntropyMocks.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";

/// @notice The scripts' parameter reader (`ScriptIO.params`) with the environment set by the
///         test.
contract ParamsHarness is ScriptIO {
    mapping(string name => string) internal _envs;

    function setEnv(string memory name, string memory value) external {
        _envs[name] = value;
    }

    function _env(string memory name) internal view override returns (string memory) {
        return _envs[name];
    }
}

/// @notice The verification script with the environment set by the test.
contract VerifyHarness is VerifyCoreScript {
    mapping(string name => string) internal _envs;

    function setEnv(string memory name, string memory value) external {
        _envs[name] = value;
    }

    function _env(string memory name) internal view override returns (string memory) {
        return _envs[name];
    }
}

/// @notice The deployment cannot be taken over and its readback catches a half-built or foreign
///         deployment: every contract is created in one call only the deployer may make, so
///         nobody can put code at a predicted address between two steps; `VerifyCore` compares
///         every contract's runtime code with a reference deployment of the same build and
///         fails on foreign code at any address, on a deployment that was never installed, on a
///         wrong module slot and on each missing genesis wiring call. It also reads back what
///         the constructors stored (each auction value, the ETH increment floor, each VRF
///         setting) against what it is told the deployment was given, and the tokens'
///         `MinterAdded` logs show a genesis minter that is not a contract of the deployment.
contract DeployCoreSafetyTest is Test {
    string internal constant GENESIS = "config/genesis.core.example.json";
    string internal constant CC0_FIXTURE = "test/fixtures/cc0-legalcode.txt";

    address internal network = makeAddr("network");
    address internal deployer = makeAddr("deployer");
    address internal outsider = makeAddr("outsider");
    address internal delegation;

    function setUp() public {
        vm.warp(1_800_000_000);
        delegation = address(new DelegationManagementMock());
    }

    // ------------------------------------------------------------------ creation

    function test_OnlyTheDeployerCanCreateThroughItsFactory() public {
        DeployCore.Params memory p = _params("only the deployer");
        DeployCore.Deployment memory d = DeployCore.deployPermanent(p, address(this));
        assertEq(CoreFactory(d.coreFactory).owner(), address(this));
        bytes32 s = DeployCore.salt(p, "Accounts");
        bytes memory code = type(DelegationManagementMock).creationCode;
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(CoreFactory.NotOwner.selector, outsider));
        CoreFactory(d.coreFactory).create(s, code);
    }

    /// @dev Between the permanent part and the modules, an outsider tries every way to put code
    ///      at Stream's genesis minter and at Directory's ACCOUNTS module: the factory refuses
    ///      them, the one-use proxies do not exist yet, and a factory of their own (same
    ///      namespace) lands elsewhere. The deployment then completes with the build's code.
    function test_AnOutsiderCannotOccupyAnAddressBetweenSteps() public {
        uint256 before = vm.snapshotState();
        DeployCore.Params memory p = _params("between steps");
        DeployCore.Deployment memory d = DeployCore.deployPermanent(p, address(this));
        bytes memory foreign = type(DelegationManagementMock).creationCode;
        string[2] memory targets = ["EnglishAuction", "Accounts"];
        vm.prank(outsider);
        CoreFactory theirs = new CoreFactory{ salt: DeployCore.salt(p, "CoreFactory") }(outsider);
        for (uint256 i; i < targets.length; ++i) {
            address predicted = DeployCore.addressOf(d, targets[i]);
            bytes32 s = DeployCore.salt(p, targets[i]);
            assertEq(predicted.code.length, 0);
            // 1. The deployer's factory refuses anyone else.
            vm.prank(outsider);
            vm.expectRevert(abi.encodeWithSelector(CoreFactory.NotOwner.selector, outsider));
            CoreFactory(d.coreFactory).create(s, foreign);
            // 2. The proxy that will create the contract does not exist outside the deployer's
            //    call: calling its address creates nothing.
            address proxy =
                vm.computeCreate2Address(s, keccak256(DeployCore.PROXY_INITCODE), d.coreFactory);
            assertEq(proxy.code.length, 0);
            vm.prank(outsider);
            (bool ok,) = proxy.call(foreign);
            assertTrue(ok);
            assertEq(predicted.code.length, 0, "nothing at the predicted address");
            // 3. An outsider's own factory with the same namespace and salt creates elsewhere.
            vm.prank(outsider);
            address created = theirs.create(s, foreign);
            assertTrue(created != predicted);
            assertEq(predicted.code.length, 0, "still nothing at the predicted address");
        }
        DeployCore.deployModules(p, d);
        GovernanceConfig.Config memory cfg = _install(d, _calls(d));
        this.verifyExternal(p, d, cfg);
        bytes32[] memory actual = VerifyCore.codeHashes(p, d);
        vm.revertToState(before);
        DeployCore.Deployment memory ref = DeployCore.deploy(p, address(this));
        this.checkCodeExternal(p, d, actual, ref, VerifyCore.codeHashes(p, ref));
    }

    /// @dev After the deployment, the one-use proxies are still on chain and anyone may call
    ///      them. Such a call creates at the proxy's next nonce, a different address: the code at
    ///      the predicted address does not change.
    function test_ALaterCallToAUsedProxyCreatesElsewhere() public {
        DeployCore.Params memory p = _params("used proxy");
        DeployCore.Deployment memory d = DeployCore.deploy(p, address(this));
        bytes memory foreign = type(DelegationManagementMock).creationCode;
        string[2] memory targets = ["EnglishAuction", "Accounts"];
        for (uint256 i; i < targets.length; ++i) {
            address predicted = DeployCore.addressOf(d, targets[i]);
            bytes32 codeBefore = predicted.codehash;
            assertGt(predicted.code.length, 0);
            address proxy = vm.computeCreate2Address(
                DeployCore.salt(p, targets[i]), keccak256(DeployCore.PROXY_INITCODE), d.coreFactory
            );
            assertGt(proxy.code.length, 0, "the proxy stays on chain");
            uint64 nonce = vm.getNonce(proxy);
            assertEq(nonce, 2, "its first nonce is spent");
            address later = vm.computeCreateAddress(proxy, nonce);
            assertTrue(later != predicted);
            vm.prank(outsider);
            (bool ok,) = proxy.call(foreign);
            assertTrue(ok);
            assertGt(later.code.length, 0, "created at the later nonce");
            assertEq(predicted.codehash, codeBefore, "the predicted address is untouched");
        }
    }

    /// @dev The script path: the factory is created through the public CREATE2 deployer, and
    ///      an outsider who creates it first creates the same factory, owned by the deployer.
    function test_AFrontRunFactoryIsTheDeployersOwn() public {
        DeployCore.Params memory p = _params("front run");
        address factory = DeployCore.CREATE2_FACTORY;
        address expected = DeployCore.factoryAddress(p, factory);
        vm.prank(outsider);
        (bool ok,) = factory.call(
            bytes.concat(DeployCore.salt(p, "CoreFactory"), DeployCore.factoryInitcode(p, factory))
        );
        assertTrue(ok);
        assertEq(CoreFactory(expected).owner(), deployer);
        vm.startPrank(deployer);
        DeployCore.Deployment memory d = DeployCore.deploy(p, factory);
        vm.stopPrank();
        assertEq(d.coreFactory, expected);
        assertGt(address(d.stream).code.length, 0);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(CoreFactory.NotOwner.selector, outsider));
        CoreFactory(expected).create(bytes32(0), hex"00");
    }

    // ------------------------------------------------------------------ runtime code

    /// @dev The script's check: the same build deployed again from the state before the
    ///      deployment has the same address and runtime code for every contract.
    function test_TheRuntimeCodeMatchesAFreshDeploymentOfTheBuild() public {
        uint256 before = vm.snapshotState();
        DeployCore.Params memory p = _params("runtime code");
        DeployCore.Deployment memory d = DeployCore.deploy(p, address(this));
        _install(d, _calls(d));
        bytes32[] memory actual = VerifyCore.codeHashes(p, d);
        vm.revertToState(before);
        DeployCore.Deployment memory ref = DeployCore.deploy(p, address(this));
        this.checkCodeExternal(p, d, actual, ref, VerifyCore.codeHashes(p, ref));
        assertEq(actual.length, DeployCore.order(p).length + 2);
    }

    /// @dev Foreign code at any one address of the deployment (factory, manager, every
    ///      contract) fails the runtime-code check.
    function test_ForeignCodeAtAnyAddressFailsTheCheck() public {
        DeployCore.Params memory p = _params("foreign code");
        DeployCore.Deployment memory d = DeployCore.deploy(p, address(this));
        bytes32[] memory honest = VerifyCore.codeHashes(p, d);
        this.checkCodeExternal(p, d, honest, d, honest);
        string[] memory names = VerifyCore.codeNames(p);
        bytes memory foreign = address(new DelegationManagementMock()).code;
        for (uint256 i; i < names.length; ++i) {
            address a = DeployCore.addressOf(d, names[i]);
            uint256 snap = vm.snapshotState();
            vm.etch(a, foreign);
            bytes32[] memory actual = VerifyCore.codeHashes(p, d);
            vm.expectRevert(abi.encodeWithSelector(VerifyCore.CodeMismatch.selector, names[i], a));
            this.checkCodeExternal(p, d, actual, d, honest);
            vm.revertToState(snap);
        }
    }

    /// @dev The same, through the full flow: foreign code at Stream, compared with a fresh
    ///      deployment from the state before.
    function test_ForeignCodeFailsAgainstAFreshDeployment() public {
        uint256 before = vm.snapshotState();
        DeployCore.Params memory p = _params("foreign stream");
        DeployCore.Deployment memory d = DeployCore.deploy(p, address(this));
        vm.etch(address(d.stream), address(new DelegationManagementMock()).code);
        bytes32[] memory actual = VerifyCore.codeHashes(p, d);
        vm.revertToState(before);
        DeployCore.Deployment memory ref = DeployCore.deploy(p, address(this));
        bytes32[] memory expected = VerifyCore.codeHashes(p, ref);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyCore.CodeMismatch.selector, "Stream6529", address(d.stream)
            )
        );
        this.checkCodeExternal(p, d, actual, ref, expected);
    }

    // ------------------------------------------------------------------ readback

    function test_ADeploymentThatWasNeverInstalledFailsTheReadback() public {
        DeployCore.Params memory p = _params("no install");
        DeployCore.Deployment memory d = DeployCore.deploy(p, address(this));
        GovernanceConfig.Config memory cfg = DeployCore.config(d, vm.readFile(GENESIS));
        cfg.network = network;
        _expectFailure(p, d, cfg, false);
        _expectFailure(p, d, cfg, true);
        vm.expectRevert(VerifyCore.NotInstalled.selector);
        this.verifyInstalledExternal(d, cfg, false);
    }

    function test_AnInstalledDeploymentReadsBackBeforeAndAfterTheNetworkAccepts() public {
        DeployCore.Params memory p = _params("pending network");
        DeployCore.Deployment memory d = DeployCore.deploy(p, address(this));
        GovernanceConfig.Config memory cfg = _config(d);
        vm.prank(deployer);
        DeployCore.install(d, cfg, _manifest(), _calls(d));
        this.verifyAcceptedExternal(p, d, cfg, false);
        _expectFailure(p, d, cfg, true);
        vm.prank(network);
        d.manager.acceptNetwork();
        this.verifyExternal(p, d, cfg);
    }

    function test_AWrongModuleSlotFailsTheReadback() public {
        DeployCore.Params memory p = _params("wrong slot");
        DeployCore.Deployment memory d = DeployCore.deploy(p, address(this));
        GovernanceConfig.Config memory cfg = _install(d, _calls(d));
        this.verifyExternal(p, d, cfg);
        vm.prank(network);
        d.stream.proposeModule(Slots.RENDERER, address(d.contentStore));
        vm.warp(block.timestamp + d.stream.moduleDelay());
        d.stream.activateModule(Slots.RENDERER);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyCore.Mismatch.selector, "Stream6529.RENDERER", address(d.stream)
            )
        );
        this.verifyExternal(p, d, cfg);
    }

    function test_AnotherMinterFailsTheReadback() public {
        DeployCore.Params memory p = _params("another minter");
        DeployCore.Deployment memory d = DeployCore.deploy(p, address(this));
        GovernanceConfig.Config memory cfg = _install(d, _calls(d));
        vm.prank(network);
        d.stream.addMinter(d.editionAuction);
        vm.expectRevert(
            abi.encodeWithSelector(VerifyCore.Mismatch.selector, "Stream minter", d.editionAuction)
        );
        this.verifyExternal(p, d, cfg);
    }

    /// @dev Each genesis wiring call left out of the install, one at a time, fails the readback.
    function test_EachMissingWiringCallFailsTheReadback() public {
        DeployCore.Params memory p = _params("missing wiring");
        DeployCore.Deployment memory d = DeployCore.deploy(p, address(this));
        GovernanceConfig.Call[] memory all = _calls(d);
        assertEq(all.length, 8);
        for (uint256 k; k < all.length; ++k) {
            uint256 snap = vm.snapshotState();
            GovernanceConfig.Call[] memory some = new GovernanceConfig.Call[](all.length - 1);
            uint256 j;
            for (uint256 i; i < all.length; ++i) {
                if (i != k) some[j++] = all[i];
            }
            GovernanceConfig.Config memory cfg = _install(d, some);
            _expectFailure(p, d, cfg, true);
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------ stored configuration

    /// @dev Each value of the English auction's configuration, one at a time: a deployment
    ///      given another value reads back when the check is told that value, and fails, naming
    ///      the field with both values, when it is told the launch value.
    function test_EachEnglishAuctionValueOtherThanToldFailsTheReadback() public {
        string[4] memory fields = ["duration", "extensionWindow", "incrementShare", "refusalGas"];
        uint32[4] memory launch = [uint32(24 hours), 15 minutes, 5_000, 4_000_000];
        uint32[4] memory planted = [uint32(1 hours), 10 minutes, 10_000, 5_000_000];
        for (uint256 i; i < fields.length; ++i) {
            string memory namespace = string.concat("english ", fields[i]);
            DeployCore.Params memory told = _params(namespace);
            DeployCore.Params memory given = _params(namespace);
            given.auctionConfig = _englishConfig(i, planted[i]);
            (DeployCore.Deployment memory d, GovernanceConfig.Config memory cfg) = _deploy(given);
            this.verifyExternal(given, d, cfg);
            _expectValue(
                string.concat("EnglishAuction.config.", fields[i]),
                d.englishAuction,
                launch[i],
                planted[i]
            );
            this.verifyExternal(told, d, cfg);
        }
    }

    /// @dev The scripts' own path: with `AUCTION_DURATION` set, `ScriptIO.params` shortens the
    ///      1/1 auction. That deployment reads back only for a run with the same variable; a run
    ///      without it, or with another duration, fails on the duration.
    function test_AnAuctionShortenedByTheEnvironmentReadsBackOnlyWithTheSameEnvironment() public {
        ParamsHarness io = new ParamsHarness();
        io.setEnv("DELEGATION_CONTRACT", vm.toString(delegation));
        io.setEnv("AUCTION_DURATION", "7200");
        DeployCore.Params memory given = io.params(true);
        given.deployer = deployer;
        (DeployCore.Deployment memory d, GovernanceConfig.Config memory cfg) = _deploy(given);
        this.verifyExternal(given, d, cfg);

        io.setEnv("AUCTION_DURATION", "");
        DeployCore.Params memory told = io.params(true);
        told.deployer = deployer;
        _expectValue("EnglishAuction.config.duration", d.englishAuction, 24 hours, 2 hours);
        this.verifyExternal(told, d, cfg);

        io.setEnv("AUCTION_DURATION", "3600");
        told = io.params(true);
        told.deployer = deployer;
        _expectValue("EnglishAuction.config.duration", d.englishAuction, 1 hours, 2 hours);
        this.verifyExternal(told, d, cfg);
    }

    /// @dev Each value of the edition auctions' configuration and the payout gas, one at a
    ///      time. Both auctions are built from the same parameters, so the 6529 Stream one fails
    ///      first; with its answer replaced by the launch value, the Independent Stream one
    ///      fails on what it stored.
    function test_EachEditionAuctionValueOtherThanToldFailsTheReadback() public {
        string[7] memory fields = [
            "config.basePrice",
            "config.stepsPerDecade",
            "config.stepCount",
            "config.marginShare",
            "config.softWindow",
            "config.maxExtension",
            "limits.payoutGas"
        ];
        uint256[7] memory launch =
            [uint256(0.0001 ether), 48, 336, 10_000, 5 minutes, 24 hours, 100_000];
        uint256[7] memory planted =
            [uint256(0.001 ether), 24, 384, 20_000, 10 minutes, 12 hours, 200_000];
        for (uint256 i; i < fields.length; ++i) {
            _editionCase(fields[i], i, launch[i], planted[i]);
        }
    }

    function _editionCase(string memory field, uint256 i, uint256 launch, uint256 planted)
        internal
    {
        string memory namespace = string.concat("edition ", field);
        DeployCore.Params memory told = _params(namespace);
        DeployCore.Params memory given = _params(namespace);
        given.editionAuctionConfig = _editionConfig(i, planted);
        (DeployCore.Deployment memory d, GovernanceConfig.Config memory cfg) = _deploy(given);
        this.verifyExternal(given, d, cfg);
        _expectValue(
            string.concat("UniformEditionAuction.", field), d.editionAuction, launch, planted
        );
        this.verifyExternal(told, d, cfg);
        // The 6529 Stream edition auction answers the launch values; the other still fails.
        _answerLaunchValues(d.editionAuction);
        _expectValue(
            string.concat("IndependentEditionAuction.", field),
            d.independentEditionAuction,
            launch,
            planted
        );
        this.verifyExternal(told, d, cfg);
        vm.clearMockedCalls();
    }

    function test_AnotherEthIncrementFloorThanToldFailsTheReadback() public {
        DeployCore.Params memory told = _params("increment floor");
        DeployCore.Params memory given = _params("increment floor");
        given.ethIncrementFloor = 0.002 ether;
        (DeployCore.Deployment memory d, GovernanceConfig.Config memory cfg) = _deploy(given);
        this.verifyExternal(given, d, cfg);
        _expectValue(
            "AssetAllowlist.incrementFloor(ETH)", d.assetAllowlist, 0.001 ether, 0.002 ether
        );
        this.verifyExternal(told, d, cfg);
    }

    /// @dev Each VRF setting the entropy module stores, one at a time.
    function test_EachVrfSettingOtherThanToldFailsTheReadback() public {
        string[6] memory fields = [
            "config.subscriptionId",
            "config.keyHash",
            "config.callbackGasLimit",
            "config.confirmations",
            "config.nativePayment",
            "retryDelay"
        ];
        uint256[6] memory launch =
            [uint256(1), uint256(keccak256("vrf key hash")), 500_000, 3, 0, 3 days];
        uint256[6] memory planted =
            [uint256(2), uint256(keccak256("another key hash")), 400_000, 5, 1, 4 days];
        address coordinator = address(new MockVrfCoordinator());
        for (uint256 i; i < fields.length; ++i) {
            _vrfCase(coordinator, fields[i], i, launch[i], planted[i]);
        }
    }

    function _vrfCase(
        address coordinator,
        string memory field,
        uint256 i,
        uint256 launch,
        uint256 planted
    ) internal {
        string memory namespace = string.concat("vrf ", field);
        DeployCore.Params memory told = _vrfParams(namespace, coordinator);
        DeployCore.Params memory given = _vrfParams(namespace, coordinator);
        _plantVrf(given, i, planted);
        (DeployCore.Deployment memory d, GovernanceConfig.Config memory cfg) = _deploy(given);
        assertGt(d.entropyModule.code.length, 0);
        this.verifyExternal(given, d, cfg);
        _expectValue(string.concat("EntropyModule.", field), d.entropyModule, launch, planted);
        this.verifyExternal(told, d, cfg);
    }

    /// @dev A deployment built on one coordinator does not read back for a run told another.
    function test_AnotherVrfCoordinatorThanToldFailsTheReadback() public {
        MockVrfCoordinator first = new MockVrfCoordinator();
        MockVrfCoordinator second = new MockVrfCoordinator();
        DeployCore.Params memory given = _vrfParams("vrf coordinator", address(first));
        DeployCore.Params memory told = _vrfParams("vrf coordinator", address(second));
        (DeployCore.Deployment memory d, GovernanceConfig.Config memory cfg) = _deploy(given);
        this.verifyExternal(given, d, cfg);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyCore.Mismatch.selector, "EntropyModule.coordinator", address(first)
            )
        );
        this.verifyExternal(told, d, cfg);
    }

    /// @dev The module is built with no wrapper; one in its storage at genesis fails the readback.
    function test_AVrfWrapperSetAtGenesisFailsTheReadback() public {
        DeployCore.Params memory p = _vrfParams("vrf wrapper", address(new MockVrfCoordinator()));
        (DeployCore.Deployment memory d, GovernanceConfig.Config memory cfg) = _deploy(p);
        this.verifyExternal(p, d, cfg);
        vm.record();
        assertEq(VrfEntropyModule(d.entropyModule).wrapper(), address(0));
        (bytes32[] memory reads,) = vm.accesses(d.entropyModule);
        assertEq(reads.length, 1, "the wrapper's storage slot");
        vm.store(d.entropyModule, reads[0], bytes32(uint256(uint160(outsider))));
        vm.expectRevert(
            abi.encodeWithSelector(VerifyCore.Mismatch.selector, "EntropyModule.wrapper", outsider)
        );
        this.verifyExternal(p, d, cfg);
    }

    // ------------------------------------------------------------------ minter logs

    /// @dev The honest deployment: each token logged exactly its genesis minter.
    function test_TheMinterLogsOfTheBuildAreTheTwoGenesisMinters() public {
        DeployCore.Params memory p = _params("minter logs");
        vm.recordLogs();
        (DeployCore.Deployment memory d, GovernanceConfig.Config memory cfg) = _deploy(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address[] memory streamAdded = VerifyCore.mintersAdded(logs, address(d.stream));
        address[] memory editionsAdded = VerifyCore.mintersAdded(logs, address(d.editions));
        assertEq(streamAdded.length, 1);
        assertEq(streamAdded[0], d.englishAuction);
        assertEq(editionsAdded.length, 1);
        assertEq(editionsAdded[0], d.editionAuction);
        this.verifyExternal(p, d, cfg);
        this.verifyMinterLogsExternal(d, streamAdded, editionsAdded);
    }

    /// @dev `Stream6529` built with a second genesis minter that is not a contract of the
    ///      deployment: every readback of state passes (no view lists the minters), and the
    ///      logs show it.
    function test_AGenesisStreamMinterOutsideTheDeploymentShowsInTheLogs() public {
        DeployCore.Params memory p = _params("outside stream minter");
        vm.recordLogs();
        DeployCore.Deployment memory d = _deployWithExtraMinters(p, outsider, address(0));
        GovernanceConfig.Config memory cfg = _install(d, _calls(d));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(d.stream.isMinter(outsider), "the outside minter mints");
        this.verifyExternal(p, d, cfg);
        address[] memory streamAdded = VerifyCore.mintersAdded(logs, address(d.stream));
        address[] memory editionsAdded = VerifyCore.mintersAdded(logs, address(d.editions));
        assertEq(streamAdded.length, 2);
        vm.expectRevert(
            abi.encodeWithSelector(VerifyCore.UnexpectedMinter.selector, "Stream6529", outsider)
        );
        this.verifyMinterLogsExternal(d, streamAdded, editionsAdded);
    }

    /// @dev The same for `StreamEditions6529`.
    function test_AGenesisEditionsMinterOutsideTheDeploymentShowsInTheLogs() public {
        DeployCore.Params memory p = _params("outside editions minter");
        vm.recordLogs();
        DeployCore.Deployment memory d = _deployWithExtraMinters(p, address(0), outsider);
        GovernanceConfig.Config memory cfg = _install(d, _calls(d));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(d.editions.isMinter(outsider), "the outside minter mints");
        this.verifyExternal(p, d, cfg);
        address[] memory streamAdded = VerifyCore.mintersAdded(logs, address(d.stream));
        address[] memory editionsAdded = VerifyCore.mintersAdded(logs, address(d.editions));
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyCore.UnexpectedMinter.selector, "StreamEditions6529", outsider
            )
        );
        this.verifyMinterLogsExternal(d, streamAdded, editionsAdded);
    }

    /// @dev Logs that do not reach back to the deployment (no `MinterAdded` at all for a token)
    ///      fail too: the check needs exactly one per token.
    function test_MinterLogsThatMissATokensGenesisMinterFail() public {
        DeployCore.Params memory p = _params("missing minter logs");
        vm.recordLogs();
        (DeployCore.Deployment memory d,) = _deploy(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address[] memory streamAdded = VerifyCore.mintersAdded(logs, address(d.stream));
        address[] memory editionsAdded = VerifyCore.mintersAdded(logs, address(d.editions));
        address[] memory none = new address[](0);
        _expectValue("Stream6529 MinterAdded logs", address(d.stream), 1, 0);
        this.verifyMinterLogsExternal(d, none, editionsAdded);
        _expectValue("StreamEditions6529 MinterAdded logs", address(d.editions), 1, 0);
        this.verifyMinterLogsExternal(d, streamAdded, none);
    }

    // ------------------------------------------------------------------ governance manifest

    /// @dev The honest deployment: the governance chain holds exactly the manifest it was given.
    function test_TheManifestOfTheBuildIsTheOneGiven() public {
        DeployCore.Params memory p = _params("manifest");
        vm.recordLogs();
        (DeployCore.Deployment memory d,) = _deploy(p);
        VerifyCore.ManifestEntry[] memory entries =
            VerifyCore.manifestsAppended(vm.getRecordedLogs(), d);
        assertEq(entries.length, 1);
        assertEq(entries[0].statement.content.digest, _manifest().digest);
        this.verifyManifestExternal(d, _manifest(), entries);
    }

    /// @dev A deployment given another manifest (another digest, or another URI) has an entry in
    ///      its governance chain, which is all the wiring readback asks; the manifest check
    ///      fails it.
    function test_AnotherManifestThanExpectedFails() public {
        DeployCore.Params memory p = _params("another manifest");
        vm.recordLogs();
        (DeployCore.Deployment memory d, GovernanceConfig.Config memory cfg) = _deploy(p);
        VerifyCore.ManifestEntry[] memory entries =
            VerifyCore.manifestsAppended(vm.getRecordedLogs(), d);
        this.verifyExternal(p, d, cfg);
        DeployCore.Manifest memory expected = _manifest();
        expected.digest = keccak256("the manifest that was reviewed");
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyCore.Mismatch.selector, "governance manifest", d.statementLog
            )
        );
        this.verifyManifestExternal(d, expected, entries);
        expected = _manifest();
        expected.uri = "ar://elsewhere";
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyCore.Mismatch.selector, "governance manifest", d.statementLog
            )
        );
        this.verifyManifestExternal(d, expected, entries);
    }

    /// @dev Logs that are not the chain's (none, two, or one whose head is not the stored head)
    ///      fail: the check needs the one entry the chain's head commits to.
    function test_ManifestLogsThatAreNotTheChainsFail() public {
        DeployCore.Params memory p = _params("manifest logs");
        vm.recordLogs();
        (DeployCore.Deployment memory d,) = _deploy(p);
        VerifyCore.ManifestEntry[] memory entries =
            VerifyCore.manifestsAppended(vm.getRecordedLogs(), d);
        _expectValue("governance manifest logs", d.statementLog, 1, 0);
        this.verifyManifestExternal(d, _manifest(), new VerifyCore.ManifestEntry[](0));
        VerifyCore.ManifestEntry[] memory two = new VerifyCore.ManifestEntry[](2);
        (two[0], two[1]) = (entries[0], entries[0]);
        _expectValue("governance manifest logs", d.statementLog, 1, 2);
        this.verifyManifestExternal(d, _manifest(), two);
        // A log that states the expected manifest but is not the entry the chain holds.
        entries[0].head = keccak256("another head");
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyCore.Mismatch.selector, "governance manifest head", d.statementLog
            )
        );
        this.verifyManifestExternal(d, _manifest(), entries);
    }

    // ------------------------------------------------------------------ script guards

    /// @dev `ScriptIO.params` refuses a `VRF_NATIVE_PAYMENT` that is neither 0 nor 1, and reads
    ///      both.
    function test_AVrfNativePaymentOtherThanZeroOrOneIsRefused() public {
        ParamsHarness io = new ParamsHarness();
        io.setEnv("DELEGATION_CONTRACT", vm.toString(delegation));
        io.setEnv("VRF_COORDINATOR", vm.toString(address(new MockVrfCoordinator())));
        io.setEnv("VRF_SUBSCRIPTION_ID", "1");
        io.setEnv("VRF_KEY_HASH", vm.toString(keccak256("vrf key hash")));
        io.setEnv("VRF_NATIVE_PAYMENT", "2");
        vm.expectRevert(
            abi.encodeWithSelector(ScriptIO.MissingParameter.selector, "VRF_NATIVE_PAYMENT")
        );
        io.params(true);
        io.setEnv("VRF_NATIVE_PAYMENT", "1");
        assertTrue(io.params(true).vrf.nativePayment);
        io.setEnv("VRF_NATIVE_PAYMENT", "0");
        assertFalse(io.params(true).vrf.nativePayment);
        io.setEnv("VRF_NATIVE_PAYMENT", "");
        assertFalse(io.params(true).vrf.nativePayment);
    }

    /// @dev `VerifyCoreScript.load` refuses a record with an entropy module when the run has no
    ///      VRF coordinator: the module would otherwise be left out of the readback.
    function test_ARecordWithAnEntropyModuleNeedsTheVrfCoordinator() public {
        VerifyHarness script = new VerifyHarness();
        DeployCore.Params memory p = _params("entropy record");
        string memory record = string.concat(
            "{\"CoreFactory\":\"",
            vm.toString(outsider),
            "\",\"EntropyModule\":\"",
            vm.toString(outsider),
            "\"}"
        );
        vm.expectRevert(
            abi.encodeWithSelector(ScriptIO.MissingParameter.selector, "VRF_COORDINATOR")
        );
        script.load(p, record);
    }

    /// @dev A zero `LOG_BLOCK_RANGE` is refused before any log is asked for (the loop over the
    ///      blocks would never advance).
    function test_AZeroLogBlockRangeIsRefused() public {
        VerifyHarness script = new VerifyHarness();
        script.setEnv("LOG_BLOCK_RANGE", "0");
        vm.expectRevert(
            abi.encodeWithSelector(ScriptIO.MissingParameter.selector, "LOG_BLOCK_RANGE")
        );
        script.mintersAdded(outsider, block.number);
    }

    /// @dev The environment's manifest: the digest is required off anvil, and a file is hashed.
    function test_TheManifestIsReadFromTheEnvironment() public {
        ParamsHarness io = new ParamsHarness();
        vm.expectRevert(
            abi.encodeWithSelector(ScriptIO.MissingParameter.selector, "MANIFEST_DIGEST")
        );
        io.manifestFromEnv(false);
        assertEq(io.manifestFromEnv(true).digest, keccak256("local manifest"));
        io.setEnv("MANIFEST_PATH", CC0_FIXTURE);
        io.setEnv("MANIFEST_URI", "ar://manifest");
        DeployCore.Manifest memory m = io.manifestFromEnv(false);
        assertEq(m.digest, sha256(vm.readFileBinary(CC0_FIXTURE)));
        assertEq(m.uri, "ar://manifest");
    }

    /// @dev `DeployGuards.checkHoldersAgainst` refuses the factory as the network or as a role
    ///      holder, like every contract of the deployment.
    function test_TheFactoryIsRefusedAsARoleHolder() public {
        DeployCore.Params memory p = _params("factory holder");
        DeployCore.Deployment memory d = DeployCore.predict(p, address(this));
        GovernanceConfig.Config memory cfg = _config(d);
        this.checkHoldersAgainstExternal(d, p, cfg);
        cfg.network = d.coreFactory;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.HolderIsADeploymentContract.selector, Roles.NETWORK, d.coreFactory
            )
        );
        this.checkHoldersAgainstExternal(d, p, cfg);
        cfg = _config(d);
        uint64 role = cfg.grants[0].role;
        cfg.grants[0].account = d.coreFactory;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.HolderIsADeploymentContract.selector, role, d.coreFactory
            )
        );
        this.checkHoldersAgainstExternal(d, p, cfg);
    }

    /// @dev A token given the zero address as a genesis minter does not deploy.
    function test_AZeroGenesisMinterIsRefused() public {
        address[] memory minters = new address[](2);
        minters[0] = outsider;
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.InvalidModule.selector, address(0)));
        new Stream6529(
            address(1), address(2), address(3), address(4), address(5), address(6), minters
        );
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.InvalidModule.selector, address(0)));
        new StreamEditions6529(address(1), address(2), address(3), address(4), minters);
    }

    // ------------------------------------------------------------------ external wrappers

    function verifyManifestExternal(
        DeployCore.Deployment memory d,
        DeployCore.Manifest memory expected,
        VerifyCore.ManifestEntry[] memory entries
    ) external view {
        VerifyCore.verifyManifest(d, expected, entries);
    }

    function checkHoldersAgainstExternal(
        DeployCore.Deployment memory d,
        DeployCore.Params memory p,
        GovernanceConfig.Config memory cfg
    ) external pure {
        DeployGuards.checkHoldersAgainst(d, p, cfg);
    }

    function verifyMinterLogsExternal(
        DeployCore.Deployment memory d,
        address[] memory streamAdded,
        address[] memory editionsAdded
    ) external pure {
        VerifyCore.verifyMinterLogs(d, streamAdded, editionsAdded);
    }

    function verifyExternal(
        DeployCore.Params memory p,
        DeployCore.Deployment memory d,
        GovernanceConfig.Config memory cfg
    ) external view {
        VerifyCore.verify(p, d, cfg, vm.readFile(GENESIS), true);
    }

    function verifyAcceptedExternal(
        DeployCore.Params memory p,
        DeployCore.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        bool accepted
    ) external view {
        VerifyCore.verify(p, d, cfg, vm.readFile(GENESIS), accepted);
    }

    function verifyInstalledExternal(
        DeployCore.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        bool accepted
    ) external view {
        VerifyCore.verifyInstalled(d, cfg, accepted);
    }

    function checkCodeExternal(
        DeployCore.Params memory p,
        DeployCore.Deployment memory d,
        bytes32[] memory actual,
        DeployCore.Deployment memory ref,
        bytes32[] memory expected
    ) external pure {
        VerifyCore.checkCode(p, d, actual, ref, expected);
    }

    // ------------------------------------------------------------------ helpers

    function _params(string memory namespace) internal returns (DeployCore.Params memory p) {
        p.deployer = deployer;
        p.namespace = keccak256(bytes(namespace));
        p.feeRecipient = makeAddr("feeRecipient");
        p.museum = makeAddr("museum");
        p.marketOwner = makeAddr("marketOwner");
        p.delegation = delegation;
        p.cc0Text = vm.readFileBinary(CC0_FIXTURE);
        p.ethIncrementFloor = 0.001 ether;
        p.auctionConfig = DeployCore.auctionConfig();
        p.editionAuctionConfig = DeployCore.editionAuctionConfig();
    }

    /// @dev The parameters with a VRF coordinator, so the entropy module is deployed.
    function _vrfParams(string memory namespace, address coordinator)
        internal
        returns (DeployCore.Params memory p)
    {
        p = _params(namespace);
        p.vrfCoordinator = coordinator;
        p.vrfCoordinatorCodeHash = coordinator.codehash;
        p.vrf = VrfEntropyModule.VrfConfig(1, keccak256("vrf key hash"), 500_000, 3, false);
        p.vrfRetryDelay = 3 days;
    }

    /// @dev Sets VRF setting `i` (in the order of the test's table) to `value`.
    function _plantVrf(DeployCore.Params memory p, uint256 i, uint256 value) internal pure {
        if (i == 0) p.vrf.subscriptionId = value;
        else if (i == 1) p.vrf.keyHash = bytes32(value);
        else if (i == 2) p.vrf.callbackGasLimit = uint32(value);
        else if (i == 3) p.vrf.confirmations = uint16(value);
        else if (i == 4) p.vrf.nativePayment = value == 1;
        else p.vrfRetryDelay = uint64(value);
    }

    /// @dev The English auction's launch configuration with value `i` replaced.
    function _englishConfig(uint256 i, uint32 value) internal pure returns (bytes memory) {
        IEnglishAuction.AuctionConfig memory c =
            abi.decode(DeployCore.auctionConfig(), (IEnglishAuction.AuctionConfig));
        if (i == 0) c.duration = value;
        else if (i == 1) c.extensionWindow = value;
        else if (i == 2) c.incrementShare = value;
        else c.refusalGas = value;
        return abi.encode(c);
    }

    /// @dev The edition auctions' launch configuration and limits with value `i` replaced.
    function _editionConfig(uint256 i, uint256 value) internal pure returns (bytes memory) {
        (IUniformEditionAuction.AuctionConfig memory c, IUniformEditionAuction.Limits memory l) = abi.decode(
            DeployCore.editionAuctionConfig(),
            (IUniformEditionAuction.AuctionConfig, IUniformEditionAuction.Limits)
        );
        if (i == 0) c.basePrice = uint96(value);
        else if (i == 1) c.stepsPerDecade = uint16(value);
        else if (i == 2) c.stepCount = uint16(value);
        else if (i == 3) c.marginShare = uint32(value);
        else if (i == 4) c.softWindow = uint32(value);
        else if (i == 5) c.maxExtension = uint32(value);
        else l.payoutGas = uint32(value);
        return abi.encode(c, l);
    }

    /// @dev Makes `auction` answer the launch configuration and limits, whatever it stored.
    function _answerLaunchValues(address auction) internal {
        (IUniformEditionAuction.AuctionConfig memory c, IUniformEditionAuction.Limits memory l) = abi.decode(
            DeployCore.editionAuctionConfig(),
            (IUniformEditionAuction.AuctionConfig, IUniformEditionAuction.Limits)
        );
        vm.mockCall(auction, abi.encodeCall(IUniformEditionAuction.config, ()), abi.encode(c));
        vm.mockCall(auction, abi.encodeCall(IUniformEditionAuction.limits, ()), abi.encode(l));
    }

    /// @dev Deploys the whole stack with `p`, installs the committed policy and accepts.
    function _deploy(DeployCore.Params memory p)
        internal
        returns (DeployCore.Deployment memory d, GovernanceConfig.Config memory cfg)
    {
        d = DeployCore.deploy(p, address(this));
        cfg = _install(d, _calls(d));
    }

    /// @dev `DeployCore.deploy` step by step, with one more genesis minter given to the
    ///      constructor of `Stream6529` (`streamExtra`) or `StreamEditions6529` (`editionsExtra`)
    ///      when nonzero. Everything else is the library's creation code at the same addresses.
    function _deployWithExtraMinters(
        DeployCore.Params memory p,
        address streamExtra,
        address editionsExtra
    ) internal returns (DeployCore.Deployment memory d) {
        d = DeployCore.predict(p, address(this));
        address factory =
            address(new CoreFactory{ salt: DeployCore.salt(p, "CoreFactory") }(address(this)));
        assertEq(factory, d.coreFactory);
        string[] memory list = DeployCore.order(p);
        for (uint256 i; i < list.length; ++i) {
            bytes32 n = keccak256(bytes(list[i]));
            bytes memory code = DeployCore.initcode(p, d, list[i]);
            if (n == keccak256("Stream6529") && streamExtra != address(0)) {
                code = _streamCode(p, d, streamExtra);
            }
            if (n == keccak256("StreamEditions6529") && editionsExtra != address(0)) {
                code = _editionsCode(p, d, editionsExtra);
            }
            CoreFactory(factory).create(DeployCore.salt(p, list[i]), code);
            if (n == keccak256("ContentStore")) {
                d.cc0TextFileId = DeployCore.uploadText(d.contentStore, p.cc0Text, "text/plain");
            }
        }
    }

    /// @dev `Stream6529`'s creation code as `DeployCore.initcode` builds it, with `extra` as a
    ///      second genesis minter.
    function _streamCode(DeployCore.Params memory p, DeployCore.Deployment memory d, address extra)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            type(Stream6529).creationCode,
            abi.encode(
                d.manager,
                d.workFacts,
                p.marketOwner,
                d.renderer,
                d.streamTerms,
                d.workRules,
                _pair(d.englishAuction, extra)
            )
        );
    }

    /// @dev The same for `StreamEditions6529`.
    function _editionsCode(
        DeployCore.Params memory p,
        DeployCore.Deployment memory d,
        address extra
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            type(StreamEditions6529).creationCode,
            abi.encode(
                d.manager, d.stream, p.marketOwner, d.streamTerms, _pair(d.editionAuction, extra)
            )
        );
    }

    function _pair(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    function _expectValue(string memory what, address account, uint256 expected, uint256 found)
        internal
    {
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyCore.ValueMismatch.selector, what, account, expected, found
            )
        );
    }

    function _manifest() internal pure returns (DeployCore.Manifest memory) {
        return DeployCore.Manifest(keccak256("safety manifest"), "ar://safety");
    }

    function _config(DeployCore.Deployment memory d)
        internal
        view
        returns (GovernanceConfig.Config memory cfg)
    {
        cfg = DeployCore.config(d, vm.readFile(GENESIS));
        cfg.network = network;
    }

    function _calls(DeployCore.Deployment memory d)
        internal
        view
        returns (GovernanceConfig.Call[] memory)
    {
        return DeployCore.wiring(d, vm.readFile(GENESIS), _manifest());
    }

    /// @dev Installs `calls` with the committed policy and accepts the network.
    function _install(DeployCore.Deployment memory d, GovernanceConfig.Call[] memory calls)
        internal
        returns (GovernanceConfig.Config memory cfg)
    {
        cfg = _config(d);
        vm.prank(deployer);
        DeployCore.install(d, cfg, _manifest(), calls);
        vm.prank(network);
        d.manager.acceptNetwork();
    }

    /// @dev Expects the readback to fail with one of `VerifyCore`'s or the configurator's
    ///      errors.
    function _expectFailure(
        DeployCore.Params memory p,
        DeployCore.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        bool accepted
    ) internal view {
        try this.verifyAcceptedExternal(p, d, cfg, accepted) {
            revert("the readback passed");
        } catch (bytes memory reason) {
            assertGe(reason.length, 4, "a named error");
        }
    }
}
