// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { CoreFactory } from "script/CoreFactory.sol";
import { DeployCore } from "script/DeployCore.sol";
import { VerifyCore } from "script/VerifyCore.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";

/// @notice The deployment cannot be taken over and its readback catches a half-built or foreign
///         deployment: every contract is created in one call only the deployer may make, so
///         nobody can put code at a predicted address between two steps; `VerifyCore` compares
///         every contract's runtime code with a reference deployment of the same build and
///         fails on foreign code at any address, on a deployment that was never installed, on a
///         wrong module slot and on each missing genesis wiring call.
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
            abi.encodeWithSelector(VerifyCore.CodeMismatch.selector, "Stream", address(d.stream))
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
                VerifyCore.Mismatch.selector, "Stream.RENDERER", address(d.stream)
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

    // ------------------------------------------------------------------ external wrappers

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
