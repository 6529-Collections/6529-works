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
import { Editions } from "src/editions/Editions.sol";
import { VerifyV1 } from "script/VerifyV1.sol";
import { MockVrfCoordinator } from "../mocks/EntropyMocks.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import {
    DeployHarness,
    MockNestedOwnerSafe,
    MockOneKeySafe,
    MockSafe,
    MockSafeWithoutOwners,
    MockSharedSignerSafe,
    MockTwoKeySafe,
    MockZeroThresholdSafe,
    VerifyHarness
} from "./ScriptHarness.sol";

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
    /// The committed CC0 1.0 legal code: the deploy's default text.
    string internal constant CC0_FIXTURE = "test/fixtures/cc0-legalcode.txt";
    bytes internal constant MANIFEST = '{"schema":"6529-works/governance-manifest/1","epoch":0}';

    DeployHarness internal deployer;
    VerifyHarness internal verifier;
    string internal example;
    bytes internal cc0;

    function setUp() public {
        deployer = new DeployHarness();
        verifier = new VerifyHarness();
        example = vm.readFile(EXAMPLE);
        cc0 = vm.readFileBinary(CC0_FIXTURE);
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
        vm.deal(makeAddr("fee"), 1); // an existing account
        deployer.setEnv("NETWORK_FEE_RECIPIENT", vm.toString(makeAddr("fee")));
        deployer.setEnv("MARKETPLACE_OWNER", vm.toString(makeAddr("owner")));
        delegation = new DelegationManagementMock();
        deployer.setEnv("DELEGATION_CONTRACT", vm.toString(address(delegation)));
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
        p.cc0Text = cc0;
        p.ethIncrementFloor = 0.001 ether;
        p.permit2 = DeployV1.CANONICAL_PERMIT2;
        p.auction = IEnglishAuction.AuctionConfig(24 hours, 15 minutes, 5_000);
    }

    // ------------------------------------------------------------------ anvil end to end

    function test_AnvilRunRecordsEveryParameterAndVerifies() public {
        (string memory record, DeployV1.Deployment memory d) = _anvilRecord();
        assertFalse(vm.parseJsonBool(record, ".confirmed"), "unconfirmed until Verify");
        assertTrue(vm.parseJsonBool(record, ".placeholders"));
        assertTrue(vm.parseJsonBool(record, ".delegationMock"), "anvil's mock");
        assertEq(
            vm.parseJsonBytes32(record, ".delegationCodeHash"),
            vm.parseJsonAddress(record, ".params.delegation").codehash
        );
        assertEq(vm.parseJsonString(record, ".entropy"), "none");
        assertEq(vm.parseJsonStringArray(record, ".standIns").length, 0, "no stand-ins");
        assertEq(vm.parseJsonStringArray(record, ".pendingLanes").length, 0, "no pending lanes");
        assertEq(vm.parseJsonAddress(record, ".params.factory"), DeployGuards.CREATE2_FACTORY);
        assertEq(vm.parseJsonAddress(record, ".params.deployer"), address(this));
        assertEq(vm.parseJsonBytes32(record, ".cc0TextFileId"), d.cc0TextFileId);
        (uint256 targets, uint256 calls, uint256 holders) = verifier.verify(record);
        assertEq(targets, 14);
        assertEq(calls, 19);
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

    /// Off anvil with every input valid: the run deploys, passes the deployment guards,
    /// configures and records; Verify then confirms the record with the off-anvil checks
    /// (no placeholders or stand-ins, the pinned CC0 text, the manifest file, the policy).
    function test_OffAnvilRunDeploysAndVerifies() public {
        _sepolia();
        Deploy.Run memory r = deployer.prepare();
        assertFalse(r.local);
        assertEq(r.p.deployer, address(this));
        assertEq(r.p.vrfCoordinator, address(0), "declined with NO_VRF=1");
        assertEq(sha256(r.p.cc0Text), DeployV1.CC0_LEGALCODE_SHA256, "the canonical text");
        assertEq(r.manifest.digest, sha256(MANIFEST));
        assertEq(r.manifest.uri, "ar://epoch-0");

        vm.recordLogs();
        DeployV1.Deployment memory d = deployer.run();
        verifier.addLogs(vm.getRecordedLogs());
        string memory record = deployer.lastRecord();
        assertFalse(vm.parseJsonBool(record, ".placeholders"));
        assertTrue(vm.parseJsonBool(record, ".delegationMock"), "not the canonical code");
        assertEq(vm.parseJsonString(record, ".entropy"), "none");
        assertEq(d.renderer.inlineThreshold(), DeployV1.RENDERER_INLINE_THRESHOLD);

        // Verify reads the same inputs: the genesis copy and the manifest file.
        verifier.setFile(GENESIS, bytes(_filled()));
        verifier.setFile("config/manifest.json", MANIFEST);
        vm.warp(block.timestamp + 5 days);
        (uint256 targets, uint256 calls, uint256 holders) = verifier.verify(record);
        assertEq(targets, 14);
        assertEq(calls, 19);
        assertEq(holders, 17);
        // Against another pin it does not verify.
        verifier.setCc0Digest(keccak256("another text"));
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.Cc0NotCanonical.selector,
                DeployV1.CC0_LEGALCODE_SHA256,
                keccak256("another text")
            )
        );
        verifier.verify(record);
    }

    function test_OffAnvilEveryRequiredInputIsRequired() public {
        _sepolia();
        string[5] memory names = [
            "GENESIS_CONFIG",
            "NETWORK_FEE_RECIPIENT",
            "MARKETPLACE_OWNER",
            "MANIFEST_PATH",
            "MANIFEST_URI"
        ];
        string[5] memory values = [
            GENESIS,
            vm.toString(makeAddr("fee")),
            vm.toString(makeAddr("owner")),
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

    /// @dev ADR 0004: off anvil the network fee recipient must already exist, so no payout pays
    ///      to create it. Code, a balance or a nonce each count; on anvil the placeholder stays.
    function test_OffAnvilTheFeeRecipientMustExist() public {
        _sepolia();
        address empty = makeAddr("emptyFeeRecipient");
        deployer.setEnv("NETWORK_FEE_RECIPIENT", vm.toString(empty));
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.AccountDoesNotExist.selector, "NETWORK_FEE_RECIPIENT", empty
            )
        );
        deployer.prepare();

        address[3] memory existing =
            [makeAddr("feeWithNonce"), makeAddr("feeWithBalance"), makeAddr("feeSafe")];
        vm.setNonce(existing[0], 1); // an EOA that has sent a transaction
        vm.deal(existing[1], 1); // a funded EOA
        vm.etch(existing[2], address(new MockSafe()).code); // a Safe
        for (uint256 i; i < existing.length; ++i) {
            deployer.setEnv("NETWORK_FEE_RECIPIENT", vm.toString(existing[i]));
            assertEq(deployer.prepare().p.feeRecipient, existing[i]);
        }

        // On anvil the placeholder, which does not exist, is still accepted.
        deployer.setEnv("NETWORK_FEE_RECIPIENT", "");
        address placeholder = deployer.params(true).feeRecipient;
        assertEq(placeholder, address(0xC001));
        assertEq(placeholder.balance + placeholder.code.length + vm.getNonce(placeholder), 0);
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
        address[5] memory system = [
            DeployGuards.CREATE2_FACTORY,
            0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02,
            DeployV1.CANONICAL_PERMIT2,
            DeployGuards.CANONICAL_DELEGATION,
            DeployGuards.SEPOLIA_DELEGATION
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

    /// Owner decision 2: a hot and a cold admin Safe, at least.
    function test_OffAnvilNeedsTwoAdminSafes() public {
        _sepolia();
        string memory cold = string.concat(FILLED_PREFIX, "02");
        _genesisFile(
            vm.replace(
                _filled(),
                string.concat('"role": "ADMIN",\n      "account": "', cold),
                string.concat('"role": "KEEPER",\n      "account": "', cold)
            )
        );
        vm.expectRevert(abi.encodeWithSelector(DeployGuards.TooFewAdmins.selector, 1));
        deployer.prepare();
    }

    /// Owner decision 2: the cold admin's signers differ from the hot admin's and the
    /// guardians'.
    function test_OffAnvilAdminSafesShareNoSigner() public {
        _sepolia();
        bytes memory shared = address(new MockSharedSignerSafe()).code;
        address signer = MockSharedSignerSafe(address(new MockSharedSignerSafe())).SHARED();
        // The hot and the cold admin share a signer.
        vm.etch(_account("01"), shared);
        vm.etch(_account("02"), shared);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.SharedSigner.selector, _account("01"), _account("02"), signer
            )
        );
        deployer.prepare();
        // The cold admin and a guardian share a signer.
        vm.etch(_account("01"), address(new MockSafe()).code);
        vm.etch(_account("12"), shared);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.SharedSigner.selector, _account("02"), _account("12"), signer
            )
        );
        deployer.prepare();
        // GOV-4: guardian Safes share no signer with each other either.
        vm.etch(_account("02"), address(new MockSafe()).code);
        vm.etch(_account("11"), shared);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.SharedSigner.selector, _account("11"), _account("12"), signer
            )
        );
        deployer.prepare();
        vm.etch(_account("12"), address(new MockSafe()).code);
        deployer.prepare();
        // A Safe must list its owners.
        vm.etch(_account("02"), address(new MockSafeWithoutOwners()).code);
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.HolderNotASafe.selector, "ADMIN", _account("02"))
        );
        deployer.prepare();
    }

    /// GOV-4: one key behind every guardian Safe is refused: a 1-of-1 Safe is below the
    ///        threshold floor, and 2-of-2 Safes of the same two keys share signers.
    function test_GOV4_OneKeyBehindEveryGuardianSafeIsRefused() public {
        _sepolia();
        bytes memory oneKey = address(new MockOneKeySafe()).code;
        vm.etch(_account("11"), oneKey);
        vm.etch(_account("12"), oneKey);
        vm.etch(_account("13"), oneKey);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.ThresholdTooLow.selector, "GUARDIAN", _account("11"), 1
            )
        );
        deployer.prepare();
        bytes memory twoKeys = address(new MockTwoKeySafe()).code;
        vm.etch(_account("11"), twoKeys);
        vm.etch(_account("12"), twoKeys);
        vm.etch(_account("13"), twoKeys);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.SharedSigner.selector,
                _account("11"),
                _account("12"),
                MockTwoKeySafe(_account("11")).KEY_A()
            )
        );
        deployer.prepare();
        // The admins need the floor too.
        _sepolia();
        vm.etch(_account("01"), oneKey);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.ThresholdTooLow.selector, "ADMIN", _account("01"), 1
            )
        );
        deployer.prepare();
    }

    /// GOV-4: an owner with code (a nested Safe, any contract or an EIP-7702 delegated EOA) is
    ///        refused, so it cannot hide a signer shared with another Safe.
    function test_GOV4_ANestedOwnerIsRefused() public {
        _sepolia();
        address inner = MockNestedOwnerSafe(address(new MockNestedOwnerSafe())).INNER();
        vm.etch(_account("01"), address(new MockNestedOwnerSafe()).code);
        vm.etch(inner, address(new MockSafe()).code);
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.NestedOwner.selector, _account("01"), inner)
        );
        deployer.prepare();
        vm.etch(inner, abi.encodePacked(hex"ef0100", makeAddr("delegate")));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.NestedOwner.selector, _account("01"), inner)
        );
        deployer.prepare();
        vm.etch(inner, "");
        deployer.prepare();
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

    /// The 6529 delegation contract: the canonical code, and the official Sepolia deployment.
    function test_TheCanonicalDelegationIsPinned() public {
        assertEq(DeployGuards.CANONICAL_DELEGATION, 0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d);
        assertEq(
            DeployGuards.CANONICAL_DELEGATION_CODEHASH,
            0x28e32b740f699e25d2a1afac207a84e31197c0d4b87c1432c9c5c52c4c1e74e0
        );
        assertEq(DeployGuards.SEPOLIA_DELEGATION, 0x8f86c644f845A077999939C69Bc787662377d915);
        // On Sepolia the official deployment is the default.
        _sepolia();
        deployer.setEnv("DELEGATION_CONTRACT", "");
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.NoCode.selector, "DELEGATION_CONTRACT", DeployGuards.SEPOLIA_DELEGATION
            )
        );
        deployer.params(false);
        vm.etch(DeployGuards.SEPOLIA_DELEGATION, address(new DelegationManagementMock()).code);
        assertEq(deployer.params(false).delegation, DeployGuards.SEPOLIA_DELEGATION);
        // Elsewhere off mainnet, the canonical address (which has no code here).
        vm.chainId(17_000);
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.NoCode.selector, "DELEGATION_CONTRACT", DeployGuards.CANONICAL_DELEGATION
            )
        );
        deployer.params(false);
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
            abi.encodeWithSelector(
                Deploy.Cc0TextMismatch.selector, actual, DeployV1.CC0_LEGALCODE_SHA256
            )
        );
        deployer.prepare();
        // Without a pinned digest, nothing off anvil can deploy.
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

    /// The committed fixture is that file, byte for byte: the deploy's default CC0 text.
    function test_TheCc0FixtureIsTheCanonicalLegalCode() public view {
        assertEq(cc0.length, DeployV1.CC0_LEGALCODE_LENGTH, "7,048 bytes");
        assertEq(sha256(cc0), DeployV1.CC0_LEGALCODE_SHA256, "the pinned digest");
        assertEq(keccak256(deployer.cc0Text(false)), keccak256(cc0), "the default text");
    }

    function test_AnvilChecksTheCc0TextToo() public {
        // The default is the committed fixture, on anvil as elsewhere.
        assertEq(keccak256(deployer.cc0Text(true)), keccak256(cc0));
        deployer.setEnv("CC0_TEXT_PATH", "config/README.md");
        bytes32 actual = sha256(vm.readFileBinary("config/README.md"));
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.Cc0TextMismatch.selector, actual, DeployV1.CC0_LEGALCODE_SHA256
            )
        );
        deployer.cc0Text(true);
        // An explicit copy of the same bytes passes.
        deployer.setFile("config/cc0.txt", cc0);
        deployer.setEnv("CC0_TEXT_PATH", "config/cc0.txt");
        assertEq(keccak256(deployer.cc0Text(true)), keccak256(cc0));
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
        // Only the entropy module is missing: allowed only when declined.
        this.checkNothingDroppedExternal(d, true);
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.DroppedFromGenesis.selector, "EntropyModule")
        );
        this.checkNothingDroppedExternal(d, false);
        // A deployment without a contract the genesis governs is refused.
        d.editions = Editions(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.DroppedFromGenesis.selector, "Editions")
        );
        this.checkNothingDroppedExternal(d, true);
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
        r.local = false;
        deployer.checkDeployment(d, r, cfg); // the committed policy, nothing dropped
        d.editions = Editions(address(0));
        r.local = true;
        deployer.checkDeployment(d, r, cfg); // anvil: not checked
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
        record = _tamper(record, '"standIns":[]', '"standIns":["Renderer"]');
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
        // The anvil run stores the canonical text, so it passes the off-anvil check too.
        assertEq(recorded, DeployV1.CC0_LEGALCODE_SHA256);
        verifier.checkCc0External(d, record, false);
        // Another pin is refused...
        verifier.setCc0Digest(keccak256("another text"));
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.Cc0NotCanonical.selector, recorded, keccak256("another text")
            )
        );
        verifier.checkCc0External(d, record, false);
        // ...and so is no pin at all.
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

    // ------------------------------------------------------------------ GOV-3: holders at readback

    /// @dev An off-anvil deployment, recorded, with Verify's inputs set, 5 days later.
    function _offAnvilRecord()
        internal
        returns (string memory record, DeployV1.Deployment memory d)
    {
        _sepolia();
        vm.recordLogs();
        d = deployer.run();
        verifier.addLogs(vm.getRecordedLogs());
        record = deployer.lastRecord();
        verifier.setFile(GENESIS, bytes(_filled()));
        verifier.setFile("config/manifest.json", MANIFEST);
        vm.warp(block.timestamp + 5 days);
        verifier.verify(record);
    }

    /// GOV-3: Verify repeats the deploy's holder guards against the chain. After genesis the
    /// cold admin Safe takes one of the hot admin's signers (an ordinary owner swap), which the
    /// deploy refuses; the readback now refuses it too.
    function test_GOV3_VerifyRepeatsTheHolderGuards() public {
        (string memory record,) = _offAnvilRecord();
        bytes memory shared = address(new MockSharedSignerSafe()).code;
        vm.etch(_account("01"), shared);
        vm.etch(_account("02"), shared);
        address signer = MockSharedSignerSafe(_account("01")).SHARED();
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.SharedSigner.selector, _account("01"), _account("02"), signer
            )
        );
        verifier.verify(record);
        // A guardian Safe that lost its code (or was never a Safe) is refused as well.
        vm.etch(_account("01"), address(new MockSafe()).code);
        vm.etch(_account("02"), address(new MockSafe()).code);
        vm.etch(_account("13"), "");
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.HolderNotASafe.selector, "GUARDIAN", _account("13"))
        );
        verifier.verify(record);
    }

    /// GOV-3: a genesis file naming a contract of the deployment as a holder fails readback.
    function test_GOV3_VerifyRefusesADeploymentContractAsAHolder() public {
        (string memory record, DeployV1.Deployment memory d) = _offAnvilRecord();
        string memory platform = vm.toLowercase(vm.toString(_account("51")));
        string memory edited = vm.replace(_filled(), platform, vm.toString(address(d.stream)));
        assertTrue(keccak256(bytes(edited)) != keccak256(bytes(_filled())), "edited");
        verifier.setFile(GENESIS, bytes(edited));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.HolderIsADeploymentContract.selector, Roles.PLATFORM, address(d.stream)
            )
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
