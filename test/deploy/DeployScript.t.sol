// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { Deploy } from "script/Deploy.s.sol";
import { DeployGuards } from "script/DeployGuards.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { ScriptIO } from "script/ScriptIO.sol";
import { Verify } from "script/Verify.s.sol";
import { VerifyV1 } from "script/VerifyV1.sol";
import { MockVrfCoordinator } from "../mocks/EntropyMocks.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { DeployHarness, MockSafe, MockZeroThresholdSafe, VerifyHarness } from "./ScriptHarness.sol";

/// @notice `Deploy.s.sol` and `Verify.s.sol` run end to end, with their outside inputs
///         (environment, files, the RPC's chain ID, the pinned CC0 digest) set by the test. The
///         off-anvil guards are driven one input at a time from a set where every input is
///         valid; the review PoCs of PR #31 are ported inverted (`test_ReviewPoC_*`).
contract DeployScriptTest is Test {
    string internal constant EXAMPLE = "config/genesis.example.json";
    /// A deployment's copy of the genesis, served by the harness (not a file on disk).
    string internal constant GENESIS = "config/genesis.sepolia.json";
    string internal constant PLACEHOLDER_PREFIX = "0x000000000000000000000000000000000000b0";
    /// Filled holders keep their suffix behind a high digit: above the placeholder range.
    string internal constant FILLED_PREFIX = "0x100000000000000000000000000000000000b0";
    uint256 internal constant SEPOLIA = 11_155_111;
    bytes internal constant CC0 = "CC0 1.0 Universal (test copy of the legal code)";
    bytes internal constant MANIFEST = '{"schema":"6529-works/governance-manifest/1","epoch":0}';

    DeployHarness internal deployer;
    VerifyHarness internal verifier;
    string internal example;

    function setUp() public {
        deployer = new DeployHarness();
        verifier = new VerifyHarness();
        example = vm.readFile(EXAMPLE);
    }

    // ------------------------------------------------------------------ helpers

    function _account(string memory suffix) internal pure returns (address) {
        return vm.parseAddress(string.concat(FILLED_PREFIX, suffix));
    }

    /// @dev The example with every holder moved off the placeholder range.
    function _filled() internal view returns (string memory) {
        return vm.replace(example, PLACEHOLDER_PREFIX, FILLED_PREFIX);
    }

    function _genesisFile(string memory json) internal {
        deployer.setFile(GENESIS, bytes(json));
        deployer.setEnv("GENESIS_CONFIG", GENESIS);
    }

    /// @dev Every input an off-anvil run needs, all valid: Safes behind the admins and
    ///      guardians, a delegation contract, Permit2 code, the pinned CC0 text, an explicit
    ///      NO_VRF, the manifest file and URI.
    function _sepolia() internal returns (DelegationManagementMock delegation) {
        vm.chainId(SEPOLIA);
        bytes memory safe = address(new MockSafe()).code;
        string[5] memory safes = ["01", "02", "11", "12", "13"];
        for (uint256 i; i < safes.length; ++i) {
            vm.etch(_account(safes[i]), safe);
        }
        _genesisFile(_filled());
        deployer.setEnv("NETWORK_FEE_RECIPIENT", vm.toString(makeAddr("fee")));
        deployer.setEnv("MARKETPLACE_OWNER", vm.toString(makeAddr("owner")));
        delegation = new DelegationManagementMock();
        deployer.setEnv("DELEGATION_CONTRACT", vm.toString(address(delegation)));
        deployer.setFile("config/cc0.txt", CC0);
        deployer.setEnv("CC0_TEXT_PATH", "config/cc0.txt");
        deployer.setCc0Digest(sha256(CC0));
        vm.etch(DeployV1.CANONICAL_PERMIT2, address(delegation).code); // code at Permit2
        deployer.setEnv("NO_VRF", "1");
        deployer.setFile("config/manifest.json", MANIFEST);
        deployer.setEnv("MANIFEST_PATH", "config/manifest.json");
        deployer.setEnv("MANIFEST_URI", "ar://epoch-0");
    }

    /// @dev A deployment on anvil with recorded logs, verified-ready (5 days later).
    function _anvilRecord() internal returns (string memory record, DeployV1.Deployment memory d) {
        vm.recordLogs();
        d = deployer.run();
        verifier.addLogs(vm.getRecordedLogs());
        record = deployer.lastRecord();
        vm.warp(block.timestamp + 5 days);
    }

    function _tamper(string memory record, string memory from, string memory to)
        internal
        pure
        returns (string memory out)
    {
        out = vm.replace(record, from, to);
        require(keccak256(bytes(out)) != keccak256(bytes(record)), "nothing replaced");
    }

    function checkPolicyExternal(DeployV1.Deployment memory d, string memory json) external view {
        DeployGuards.checkPolicy(
            d, json, example, DeployV1.Manifest(keccak256("manifest"), "ar://m")
        );
    }

    function checkNothingDroppedExternal(DeployV1.Deployment memory d, bool noVrf) external view {
        DeployGuards.checkNothingDropped(d, _filled(), noVrf);
    }

    function checkHoldersAgainstExternal(
        DeployV1.Deployment memory d,
        DeployV1.Params memory p,
        GovernanceConfig.Config memory cfg
    ) external pure {
        DeployGuards.checkHoldersAgainst(d, p, cfg);
    }

    function _localParams() internal returns (DeployV1.Params memory p) {
        p.deployer = address(this);
        p.namespace = keccak256("6529-works/script-test");
        p.feeRecipient = makeAddr("fee");
        p.marketOwner = makeAddr("owner");
        p.delegation = address(new DelegationManagementMock());
        p.cc0Text = CC0;
        p.ethIncrementFloor = 0.001 ether;
        p.permit2 = DeployV1.CANONICAL_PERMIT2;
        p.auction = IEnglishAuction.AuctionConfig(24 hours, 15 minutes, 5_000);
    }

    // ------------------------------------------------------------------ anvil end to end

    function test_AnvilRunRecordsEveryParameterAndVerifies() public {
        (string memory record, DeployV1.Deployment memory d) = _anvilRecord();
        assertFalse(vm.parseJsonBool(record, ".confirmed"), "unconfirmed until Verify");
        assertTrue(vm.parseJsonBool(record, ".placeholders"));
        assertTrue(vm.parseJsonBool(record, ".delegationMock"));
        assertEq(vm.parseJsonString(record, ".entropy"), "none");
        assertEq(vm.parseJsonStringArray(record, ".standIns").length, 1);
        assertEq(vm.parseJsonAddress(record, ".params.factory"), DeployGuards.CREATE2_FACTORY);
        assertEq(vm.parseJsonAddress(record, ".params.deployer"), address(this));
        assertEq(vm.parseJsonBytes32(record, ".cc0TextFileId"), d.cc0TextFileId);
        (uint256 targets, uint256 calls, uint256 holders) = verifier.verify(record);
        assertEq(targets, 13);
        assertEq(calls, 11);
        assertEq(holders, 17);
    }

    function test_VerifyRunReadsTheRecordFile() public {
        (string memory record,) = _anvilRecord();
        verifier.setFile("deployments/31337/test.json", bytes(record));
        verifier.setEnv("DEPLOYMENT", "deployments/31337/test.json");
        verifier.run();
    }

    function test_VerifyNeedsADeployment() public {
        vm.expectRevert(abi.encodeWithSelector(Verify.MissingParameter.selector, "DEPLOYMENT"));
        verifier.run();
    }

    function test_RunsRefuseAnRpcOnAnotherChain() public {
        deployer.setRpcChainId(1);
        vm.expectRevert(abi.encodeWithSelector(ScriptIO.ChainIdMismatch.selector, 31_337, 1));
        deployer.run();
        verifier.setRpcChainId(SEPOLIA);
        vm.expectRevert(abi.encodeWithSelector(ScriptIO.ChainIdMismatch.selector, 31_337, SEPOLIA));
        verifier.run();
    }

    function test_TheSenderMustBeGiven() public {
        vm.prank(DEFAULT_SENDER);
        vm.expectRevert(Deploy.SenderNotSet.selector);
        deployer.run();
    }

    function test_AnvilManifestFileIsHashedAndVerified() public {
        deployer.setFile("config/manifest.json", MANIFEST);
        deployer.setEnv("MANIFEST_PATH", "config/manifest.json");
        (string memory record,) = _anvilRecord();
        assertEq(vm.parseJsonBytes32(record, ".manifestDigest"), sha256(MANIFEST));
        verifier.setFile("config/manifest.json", MANIFEST);
        verifier.verify(record);
        // A different file at the recorded path fails.
        verifier.setFile("config/manifest.json", bytes("another manifest"));
        bytes32 actual = sha256("another manifest");
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.HashMismatch.selector, "manifest file", sha256(MANIFEST), actual
            )
        );
        verifier.verify(record);
    }

    // ------------------------------------------------------------------ off anvil: inputs

    function test_OffAnvilEveryInputPassesAndTheRunStopsAtThePendingRenderer() public {
        _sepolia();
        Deploy.Run memory r = deployer.prepare();
        assertFalse(r.local);
        assertEq(r.p.deployer, address(this));
        assertEq(r.p.vrfCoordinator, address(0), "declined with NO_VRF=1");
        assertEq(keccak256(r.p.cc0Text), keccak256(CC0));
        assertEq(r.manifest.digest, sha256(MANIFEST));
        assertEq(r.manifest.uri, "ar://epoch-0");
        vm.expectRevert(DeployV1.RendererPending.selector);
        deployer.run();
    }

    function test_OffAnvilEveryRequiredInputIsRequired() public {
        _sepolia();
        string[6] memory names = [
            "GENESIS_CONFIG",
            "NETWORK_FEE_RECIPIENT",
            "MARKETPLACE_OWNER",
            "CC0_TEXT_PATH",
            "MANIFEST_PATH",
            "MANIFEST_URI"
        ];
        string[6] memory values = [
            GENESIS,
            vm.toString(makeAddr("fee")),
            vm.toString(makeAddr("owner")),
            "config/cc0.txt",
            "config/manifest.json",
            "ar://epoch-0"
        ];
        for (uint256 i; i < names.length; ++i) {
            deployer.setEnv(names[i], "");
            vm.expectRevert(abi.encodeWithSelector(Deploy.MissingParameter.selector, names[i]));
            deployer.prepare();
            deployer.setEnv(names[i], values[i]);
        }
        deployer.prepare();
    }

    function test_OffAnvilTheExampleIsRefusedUnderAnyPath() public {
        _sepolia();
        deployer.setEnv("GENESIS_CONFIG", EXAMPLE);
        vm.expectRevert(DeployGuards.ExampleGenesisOffAnvil.selector);
        deployer.prepare();
        deployer.setEnv("GENESIS_CONFIG", "./config/../config/genesis.example.json");
        vm.expectRevert(DeployGuards.ExampleGenesisOffAnvil.selector);
        deployer.prepare();
        _genesisFile(example); // a copy under another name
        vm.expectRevert(DeployGuards.ExampleGenesisOffAnvil.selector);
        deployer.prepare();
    }

    function test_OffAnvilACopyWithPlaceholderHoldersIsRefused() public {
        _sepolia();
        _genesisFile(vm.replace(example, "Example genesis configuration", "Sepolia genesis"));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.PlaceholderHolder.selector, "ADMIN", address(0xB001)
            )
        );
        deployer.prepare();
    }

    function test_OffAnvilThePlaceholderRangeEndsAt0xFFFF() public {
        _sepolia();
        string memory curator = string.concat(FILLED_PREFIX, "61");
        _genesisFile(vm.replace(_filled(), curator, "0x000000000000000000000000000000000000ffff"));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.PlaceholderHolder.selector, "CURATOR", address(0xFFFF)
            )
        );
        deployer.prepare();
        _genesisFile(vm.replace(_filled(), curator, "0x0000000000000000000000000000000000010000"));
        deployer.prepare();
    }

    /// Review PoC (M-1), inverted: holders with no code (an undeployed Safe, a typo) used to
    /// pass, and genesis renounced the configurator's ADMIN to them.
    function test_ReviewPoC_CodelessAdminsAndGuardiansAreRefused() public {
        _sepolia();
        vm.etch(_account("01"), "");
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.HolderNotASafe.selector, "ADMIN", _account("01"))
        );
        deployer.prepare();
        vm.etch(_account("01"), address(new MockSafe()).code);
        vm.etch(_account("12"), "");
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.HolderNotASafe.selector, "GUARDIAN", _account("12"))
        );
        deployer.prepare();
    }

    function test_OffAnvilAdminsAndGuardiansMustBeSafesWithAThreshold() public {
        _sepolia();
        vm.etch(_account("02"), address(new MockZeroThresholdSafe()).code);
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.HolderNotASafe.selector, "ADMIN", _account("02"))
        );
        deployer.prepare();
        vm.etch(_account("02"), address(new MockSafe()).code);
        // An EIP-7702 delegated EOA has code, and even answers through its delegate.
        vm.etch(_account("11"), abi.encodePacked(hex"ef0100", address(new MockSafe())));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.HolderNotASafe.selector, "GUARDIAN", _account("11"))
        );
        deployer.prepare();
        // A contract without getThreshold().
        vm.etch(_account("11"), address(new DelegationManagementMock()).code);
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.HolderNotASafe.selector, "GUARDIAN", _account("11"))
        );
        deployer.prepare();
    }

    function test_OffAnvilSystemAddressesCannotHoldRoles() public {
        _sepolia();
        address[4] memory system = [
            DeployGuards.CREATE2_FACTORY,
            0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02,
            DeployV1.CANONICAL_PERMIT2,
            DeployGuards.CANONICAL_DELEGATION
        ];
        for (uint256 i; i < system.length; ++i) {
            _genesisFile(
                vm.replace(_filled(), string.concat(FILLED_PREFIX, "61"), vm.toString(system[i]))
            );
            vm.expectRevert(
                abi.encodeWithSelector(DeployGuards.ForbiddenHolder.selector, "CURATOR", system[i])
            );
            deployer.prepare();
        }
    }

    function test_OffAnvilNeedsThreeGuardiansAndTwoCurationSigners() public {
        _sepolia();
        string memory guardian3 = string.concat(FILLED_PREFIX, "13");
        _genesisFile(
            vm.replace(
                _filled(),
                string.concat('"role": "GUARDIAN",\n      "account": "', guardian3),
                string.concat('"role": "KEEPER",\n      "account": "', guardian3)
            )
        );
        vm.expectRevert(abi.encodeWithSelector(DeployGuards.TooFewGuardians.selector, 2));
        deployer.prepare();
        string memory signer2 = string.concat(FILLED_PREFIX, "22");
        _genesisFile(
            vm.replace(
                _filled(),
                string.concat('"role": "CURATION_SIGNER",\n      "account": "', signer2),
                string.concat('"role": "KEEPER",\n      "account": "', signer2)
            )
        );
        vm.expectRevert(abi.encodeWithSelector(DeployGuards.TooFewCurationSigners.selector, 1));
        deployer.prepare();
    }

    function test_OffAnvilDependenciesMustHaveCode() public {
        _sepolia();
        address eoa = makeAddr("eoa");
        deployer.setEnv("DELEGATION_CONTRACT", vm.toString(eoa));
        vm.expectRevert(abi.encodeWithSelector(Deploy.NoCode.selector, "DELEGATION_CONTRACT", eoa));
        deployer.prepare();
        _sepolia();
        vm.etch(DeployV1.CANONICAL_PERMIT2, "");
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.NoCode.selector, "PERMIT2", DeployV1.CANONICAL_PERMIT2)
        );
        deployer.prepare();
    }

    /// Review PoC (M-3, M-4, L-3), inverted: on mainnet any file was accepted as the CC0 text,
    /// an unset VRF_COORDINATOR silently dropped the entropy module, and any contract was
    /// accepted as Permit2.
    function test_ReviewPoC_MainnetPinsCanonicalDependencies() public {
        DelegationManagementMock delegation = _sepolia();
        vm.chainId(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.NonCanonicalOnMainnet.selector, "DELEGATION_CONTRACT", address(delegation)
            )
        );
        deployer.prepare();
        vm.etch(DeployGuards.CANONICAL_DELEGATION, address(delegation).code);
        deployer.setEnv("DELEGATION_CONTRACT", "");
        address fake = address(new DelegationManagementMock());
        deployer.setEnv("PERMIT2", vm.toString(fake));
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.NonCanonicalOnMainnet.selector, "PERMIT2", fake)
        );
        deployer.prepare();
        deployer.setEnv("PERMIT2", "");
        deployer.prepare();
    }

    function test_ReviewPoC_TheCc0TextMustBeTheCanonicalOne() public {
        _sepolia();
        deployer.setEnv("CC0_TEXT_PATH", "config/README.md");
        bytes32 actual = sha256(vm.readFileBinary("config/README.md"));
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.Cc0TextMismatch.selector, actual, sha256(CC0))
        );
        deployer.prepare();
        // Until the canonical digest is pinned, nothing off anvil can deploy.
        deployer.setCc0Digest(bytes32(0));
        vm.expectRevert(Deploy.Cc0DigestNotPinned.selector);
        deployer.prepare();
    }

    /// The canonical CC0 1.0 legal code (legalcode.txt, 7,048 bytes), pinned from two sources.
    function test_TheCanonicalCc0DigestIsPinned() public {
        bytes32 canonical = 0xa2010f343487d3f7618affe54f789f5487602331c0a8d03f49e9a7c547cf0499;
        assertEq(DeployV1.CC0_LEGALCODE_SHA256, canonical);
        assertEq(DeployV1.CC0_LEGALCODE_LENGTH, 7048);
        assertEq(
            DeployV1.CC0_LEGALCODE_URL,
            "https://creativecommons.org/publicdomain/zero/1.0/legalcode.txt"
        );
        // Both scripts require it unless a test overrides it.
        assertEq(new Deploy().cc0Digest(), canonical);
        assertEq(new Verify().cc0Digest(), canonical);
    }

    function test_AnvilChecksAGivenCc0FileOnceTheDigestIsPinned() public {
        deployer.setCc0Digest(sha256(CC0));
        deployer.setEnv("CC0_TEXT_PATH", "config/README.md");
        bytes32 actual = sha256(vm.readFileBinary("config/README.md"));
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.Cc0TextMismatch.selector, actual, sha256(CC0))
        );
        deployer.cc0Text(true);
        deployer.setFile("config/cc0.txt", CC0);
        deployer.setEnv("CC0_TEXT_PATH", "config/cc0.txt");
        assertEq(keccak256(deployer.cc0Text(true)), keccak256(CC0));
    }

    function test_ReviewPoC_TheEntropyModuleIsAnExplicitChoice() public {
        _sepolia();
        deployer.setEnv("NO_VRF", "");
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.MissingParameter.selector,
                "VRF_COORDINATOR (or NO_VRF=1 to deploy without VRF)"
            )
        );
        deployer.prepare();
        deployer.setEnv("NO_VRF", "2");
        vm.expectRevert(abi.encodeWithSelector(Deploy.MissingParameter.selector, "NO_VRF (0 or 1)"));
        deployer.prepare();

        MockVrfCoordinator coordinator = new MockVrfCoordinator();
        deployer.setEnv("VRF_COORDINATOR", vm.toString(address(coordinator)));
        deployer.setEnv("NO_VRF", "1");
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.ConflictingParameters.selector, "VRF_COORDINATOR", "NO_VRF"
            )
        );
        deployer.prepare();
        deployer.setEnv("NO_VRF", "0");
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.MissingParameter.selector, "VRF_SUBSCRIPTION_ID")
        );
        deployer.prepare();
        deployer.setEnv("VRF_SUBSCRIPTION_ID", "7");
        vm.expectRevert(abi.encodeWithSelector(Deploy.MissingParameter.selector, "VRF_KEY_HASH"));
        deployer.prepare();
        deployer.setEnv("VRF_KEY_HASH", vm.toString(keccak256("lane")));
        Deploy.Run memory r = deployer.prepare();
        assertEq(r.p.vrfCoordinator, address(coordinator));
        assertEq(r.p.vrfCoordinatorCodeHash, address(coordinator).codehash);
        assertEq(r.p.vrf.subscriptionId, 7);
        assertEq(r.p.vrf.keyHash, keccak256("lane"));
        assertEq(r.p.vrf.callbackGasLimit, 200_000);
        assertEq(r.p.vrf.confirmations, 3);
        assertFalse(r.p.vrf.nativePayment);
        assertEq(r.p.vrfRetryDelay, 3 days);

        address eoa = makeAddr("not a coordinator");
        deployer.setEnv("VRF_COORDINATOR", vm.toString(eoa));
        vm.expectRevert(abi.encodeWithSelector(Deploy.NoCode.selector, "VRF_COORDINATOR", eoa));
        deployer.prepare();
    }

    function test_EnvironmentNumbersAreCheckedCasts() public {
        _sepolia();
        deployer.setEnv("AUCTION_DURATION", vm.toString(uint256(type(uint32).max) + 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedUintDowncast.selector, 32, uint256(type(uint32).max) + 1
            )
        );
        deployer.prepare();
        deployer.setEnv("AUCTION_DURATION", "");
        MockVrfCoordinator coordinator = new MockVrfCoordinator();
        deployer.setEnv("NO_VRF", "0");
        deployer.setEnv("VRF_COORDINATOR", vm.toString(address(coordinator)));
        deployer.setEnv("VRF_SUBSCRIPTION_ID", "7");
        deployer.setEnv("VRF_KEY_HASH", vm.toString(keccak256("lane")));
        deployer.setEnv("VRF_CONFIRMATIONS", "70000");
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 16, 70_000)
        );
        deployer.prepare();
    }

    /// Review PoC (front-run), ported: squatting the operator's own configurator initcode only
    /// builds the operator's configurator (no takeover). The run now detects the taken slot
    /// before broadcasting and asks for a new namespace.
    function test_ReviewPoC_AConfiguratorFrontRunIsGriefOnlyAndDetected() public {
        _sepolia();
        DeployV1.Params memory p = deployer.params(false);
        p.deployer = address(this);
        DeployV1.Deployment memory none;
        bytes memory honest = DeployV1.initcode(p, none, "GovernanceConfigurator");
        bytes32 s = DeployV1.salt(p, "GovernanceConfigurator");
        address predicted =
            vm.computeCreate2Address(s, keccak256(honest), DeployGuards.CREATE2_FACTORY);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        (bool ok,) = DeployGuards.CREATE2_FACTORY.call(abi.encodePacked(s, honest));
        assertTrue(ok);
        assertEq(GovernanceConfigurator(predicted).deployer(), address(this), "still ours");
        GovernanceConfig.Config memory empty;
        GovernanceConfig.Call[] memory noCalls;
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceConfigurator.NotDeployer.selector, attacker)
        );
        GovernanceConfigurator(predicted).configure(empty, bytes32(0), noCalls);

        vm.expectRevert(abi.encodeWithSelector(Deploy.ConfiguratorAddressTaken.selector, predicted));
        deployer.prepare();
        deployer.setEnv("DEPLOY_NAMESPACE", vm.toString(keccak256("6529-works/v1-retry")));
        deployer.prepare();
    }

    // ------------------------------------------------------------------ off anvil: deployment

    /// Review PoC (M-2), inverted: remapping Stream.setAdmittedMinter (30-day class) to
    /// PLATFORM (zero delay) used to pass and install.
    function test_ReviewPoC_ARemappedSelectorIsRefused() public {
        DeployV1.Deployment memory d = DeployV1.deploy(_localParams());
        this.checkPolicyExternal(d, _filled());
        string memory hostile = vm.replace(
            _filled(),
            string.concat(
                '"selector": "0xa82ed63a",\n          "role": "SUCCESSOR_SETTER",\n',
                '          "class": "successor",\n          "delay": 2592000'
            ),
            string.concat(
                '"selector": "0xa82ed63a",\n          "role": "PLATFORM",\n',
                '          "class": "immediate",\n          "delay": 0'
            )
        );
        vm.expectRevert(abi.encodeWithSelector(DeployGuards.PolicyMismatch.selector, "targets"));
        this.checkPolicyExternal(d, hostile);
    }

    function test_ChangedWiringIsRefused() public {
        DeployV1.Deployment memory d = DeployV1.deploy(_localParams());
        string memory hostile = vm.replace(
            _filled(), '"EnglishAuction",\n        true', '"DutchSale",\n        true'
        );
        vm.expectRevert(abi.encodeWithSelector(DeployGuards.PolicyMismatch.selector, "wiring"));
        this.checkPolicyExternal(d, hostile);
    }

    function test_NothingTheGenesisNamesMayBeDropped() public {
        DeployV1.Deployment memory d = DeployV1.deploy(_localParams());
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.DroppedFromGenesis.selector, "Editions")
        );
        this.checkNothingDroppedExternal(d, true);
        // With Editions present, only the entropy module is missing: allowed only when declined.
        d.editions = makeAddr("editions");
        this.checkNothingDroppedExternal(d, true);
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.DroppedFromGenesis.selector, "EntropyModule")
        );
        this.checkNothingDroppedExternal(d, false);
    }

    function test_HoldersCannotBeDeploymentContracts() public {
        DeployV1.Params memory p = _localParams();
        DeployV1.Deployment memory d = DeployV1.deploy(p);
        GovernanceConfig.Config memory cfg = DeployV1.config(d, _filled());
        this.checkHoldersAgainstExternal(d, p, cfg);
        for (uint256 i; i < cfg.grants.length; ++i) {
            if (cfg.grants[i].role == Roles.PLATFORM) cfg.grants[i].account = address(d.stream);
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.HolderIsADeploymentContract.selector, Roles.PLATFORM, address(d.stream)
            )
        );
        this.checkHoldersAgainstExternal(d, p, cfg);
        for (uint256 i; i < cfg.grants.length; ++i) {
            if (cfg.grants[i].role == Roles.PLATFORM) cfg.grants[i].account = p.delegation;
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.HolderIsADeploymentContract.selector, Roles.PLATFORM, p.delegation
            )
        );
        this.checkHoldersAgainstExternal(d, p, cfg);
    }

    function test_CheckDeploymentRunsTheGuardsOnlyOffAnvil() public {
        DeployV1.Params memory p = _localParams();
        DeployV1.Deployment memory d = DeployV1.deploy(p);
        Deploy.Run memory r;
        r.json = _filled();
        r.p = p;
        r.manifest = DeployV1.Manifest(keccak256("manifest"), "ar://m");
        GovernanceConfig.Config memory cfg = DeployV1.config(d, r.json);
        r.local = true;
        deployer.checkDeployment(d, r, cfg);
        r.local = false;
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.DroppedFromGenesis.selector, "Editions")
        );
        deployer.checkDeployment(d, r, cfg);
    }

    // ------------------------------------------------------------------ Verify

    function test_VerifyRefusesARecordFromAnotherChain() public {
        (string memory record,) = _anvilRecord();
        record = _tamper(record, '"chainId":31337', '"chainId":1');
        vm.expectRevert(abi.encodeWithSelector(Verify.WrongChain.selector, 1, 31_337));
        verifier.verify(record);
    }

    function test_VerifyRefusesPlaceholdersAndStandInsOffAnvil() public {
        (string memory record,) = _anvilRecord();
        vm.chainId(SEPOLIA);
        record = _tamper(record, '"chainId":31337', '"chainId":11155111');
        vm.expectRevert(Verify.PlaceholdersOffAnvil.selector);
        verifier.verify(record);
        record = _tamper(record, '"placeholders":true', '"placeholders":false');
        vm.expectRevert(abi.encodeWithSelector(Verify.StandInsOffAnvil.selector, "Renderer"));
        verifier.verify(record);
    }

    function test_VerifyRecomputesEveryAddressFromTheRecordedParameters() public {
        (string memory record, DeployV1.Deployment memory d) = _anvilRecord();
        // A different marketplace owner would have put Stream elsewhere.
        string memory owner = vm.toString(address(0xC002));
        string memory tampered = _tamper(
            record,
            string.concat('"marketOwner":"', vm.toLowercase(owner), '"'),
            '"marketOwner":"0x000000000000000000000000000000000000c003"'
        );
        vm.expectPartialRevert(VerifyV1.AddressMismatch.selector);
        verifier.verify(tampered);
        // A recorded address that is not where CREATE2 put it.
        string memory router = vm.toString(address(d.claimRouter));
        tampered = _tamper(record, router, vm.toString(makeAddr("elsewhere")));
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyV1.AddressMismatch.selector,
                "ClaimRouter",
                address(d.claimRouter),
                makeAddr("elsewhere")
            )
        );
        verifier.verify(tampered);
        // Another CREATE2 deployer moves everything.
        tampered = _tamper(
            record,
            vm.toString(DeployGuards.CREATE2_FACTORY),
            vm.toString(makeAddr("another factory"))
        );
        vm.expectPartialRevert(VerifyV1.AddressMismatch.selector);
        verifier.verify(tampered);
    }

    function test_VerifyChecksEveryCodeHash() public {
        (string memory record, DeployV1.Deployment memory d) = _anvilRecord();
        string memory hash = vm.toString(address(d.claimRouter).codehash);
        record = _tamper(record, hash, vm.toString(keccak256("other code")));
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.CodeHashMismatch.selector, "ClaimRouter", address(d.claimRouter)
            )
        );
        verifier.verify(record);
    }

    function test_VerifyChecksTheDefaultLicenseText() public {
        (string memory record, DeployV1.Deployment memory d) = _anvilRecord();
        bytes32 recorded = vm.parseJsonBytes32(record, ".cc0TextSha256");
        string memory tampered =
            _tamper(record, vm.toString(recorded), vm.toString(keccak256("other text")));
        vm.expectRevert(abi.encodeWithSelector(VerifyV1.Cc0Mismatch.selector, "SHA-256"));
        verifier.verify(tampered);
        // Off anvil the recorded digest must be the pinned canonical one: the anvil
        // placeholder text is not.
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.Cc0NotCanonical.selector, recorded, DeployV1.CC0_LEGALCODE_SHA256
            )
        );
        verifier.checkCc0External(d, record, false);
        // No pin at all is refused too.
        verifier.setCc0Digest(bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(Verify.Cc0NotCanonical.selector, recorded, 0));
        verifier.checkCc0External(d, record, false);
        // A deployment whose stored text is the pinned one passes.
        verifier.setCc0Digest(recorded);
        verifier.checkCc0External(d, record, false);
    }

    function test_VerifyNeedsTheManifestFileOffAnvil() public {
        (string memory record,) = _anvilRecord();
        verifier.checkManifestExternal(record, true); // no path recorded on anvil: skipped
        vm.expectRevert(abi.encodeWithSelector(Verify.MissingParameter.selector, "MANIFEST_PATH"));
        verifier.checkManifestExternal(record, false);
    }

    function test_VerifyNeedsTheGovernanceConfiguredEvent() public {
        (string memory record,) = _anvilRecord();
        verifier.clearLogs();
        vm.expectRevert(Verify.MissingGovernanceConfigured.selector);
        verifier.verify(record);
    }

    function test_VerifyRecomputesTheEventHashes() public {
        (string memory record,) = _anvilRecord();
        bytes32 real = vm.parseJsonBytes32(record, ".manifestDigest");
        bytes32 other = keccak256("another manifest");
        record = _tamper(record, vm.toString(real), vm.toString(other));
        vm.expectRevert(
            abi.encodeWithSelector(Verify.HashMismatch.selector, "manifestHash", other, real)
        );
        verifier.verify(record);
    }

    function test_VerifyCatchesPendingDelayChanges() public {
        (string memory record, DeployV1.Deployment memory d) = _anvilRecord();
        uint48 effect = uint48(block.timestamp + 1 days);
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = keccak256("RoleGrantDelayChanged(uint64,uint32,uint48)");
        topics[1] = bytes32(uint256(Roles.PLATFORM));
        verifier.addLog(address(d.manager), topics, abi.encode(uint32(1), effect));
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.PendingGrantDelayChange.selector, Roles.PLATFORM, uint32(1), effect
            )
        );
        verifier.verify(record);

        (record, d) = _reset();
        effect = uint48(block.timestamp + 1 days);
        topics[0] = keccak256("TargetAdminDelayUpdated(address,uint32,uint48)");
        topics[1] = bytes32(uint256(uint160(address(d.stream))));
        verifier.addLog(address(d.manager), topics, abi.encode(uint32(1), effect));
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.PendingTargetAdminDelayChange.selector, address(d.stream), uint32(1), effect
            )
        );
        verifier.verify(record);
    }

    function test_VerifyCatchesAnUnexpectedGrant() public {
        (string memory record, DeployV1.Deployment memory d) = _anvilRecord();
        address stranger = makeAddr("stranger");
        bytes32[] memory topics = new bytes32[](3);
        topics[0] = keccak256("RoleGranted(uint64,address,uint32,uint48,bool)");
        topics[1] = bytes32(uint256(Roles.PLATFORM));
        topics[2] = bytes32(uint256(uint160(stranger)));
        verifier.addLog(address(d.manager), topics, abi.encode(uint32(0), uint48(1), true));
        vm.expectRevert(
            abi.encodeWithSelector(Verify.UnexpectedGrant.selector, Roles.PLATFORM, stranger)
        );
        verifier.verify(record);
    }

    /// @dev A fresh verifier and deployment (the harness keeps logs across calls).
    function _reset() internal returns (string memory record, DeployV1.Deployment memory d) {
        deployer = new DeployHarness();
        verifier = new VerifyHarness();
        deployer.setEnv("DEPLOY_NAMESPACE", vm.toString(keccak256("6529-works/second")));
        (record, d) = _anvilRecord();
    }
}
