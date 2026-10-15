// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
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
import { ContentStore } from "src/content/ContentStore.sol";
import { VerifyV1 } from "script/VerifyV1.sol";
import { MockVrfCoordinator } from "../mocks/EntropyMocks.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import {
    DeployHarness,
    MockNestedOwnerSafe,
    MockOneKeySafe,
    MockSafe,
    MockSafeWithoutOwners,
    MockModuleSafe,
    MockSafeSingleton,
    MockSharedSignerSafe,
    MockTwoKeySafe,
    MockVrfSubscriptions,
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
        _allowTestSingleton();
        bytes memory safe = address(new MockSafe()).code;
        string[5] memory safes = ["01", "02", "11", "12", "13"];
        for (uint256 i; i < safes.length; ++i) {
            _etchSafe(_account(safes[i]), safe);
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
        deployer.setEnv("DEPLOY_NAMESPACE", vm.toString(keccak256("6529-works/script-test")));
    }

    /// @dev The test singleton: its address and code hash replace the canonical Safe
    ///      singletons in both scripts (a test cannot reproduce their code).
    address internal testSingleton;

    function _allowTestSingleton() internal {
        testSingleton = address(new MockSafeSingleton());
        address[] memory singletons = new address[](1);
        bytes32[] memory hashes = new bytes32[](1);
        singletons[0] = testSingleton;
        hashes[0] = testSingleton.codehash;
        deployer.setSafeSingletons(singletons, hashes);
        verifier.setSafeSingletons(singletons, hashes);
    }

    /// @dev Etches a mock Safe proxy at `safe`, pointing at the test singleton (slot 0).
    function _etchSafe(address safe, bytes memory code) internal {
        vm.etch(safe, code);
        vm.store(safe, bytes32(0), bytes32(uint256(uint160(testSingleton))));
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
        // An EIP-7702 delegation on an owner key has its own error, and clears with it.
        vm.etch(inner, abi.encodePacked(hex"ef0100", makeAddr("delegate")));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.DelegatedOwner.selector, _account("01"), inner)
        );
        deployer.prepare();
        vm.etch(inner, "");
        deployer.prepare();
    }

    /// L1 (review of #52): a Safe with an enabled module is refused; a module acts without the
    ///     owners' signatures. (The reviewer's PoC, inverted.)
    function test_ASafeWithAModuleIsRefused() public {
        _sepolia();
        bytes memory moduled = address(new MockModuleSafe()).code;
        _etchSafe(_account("01"), moduled); // hot admin
        _etchSafe(_account("11"), moduled); // a guardian
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.SafeHasModules.selector,
                "ADMIN",
                _account("01"),
                MockModuleSafe(_account("01")).MODULE()
            )
        );
        deployer.prepare();
    }

    /// L1: a Safe with a transaction guard is refused.
    function test_ASafeWithAGuardIsRefused() public {
        _sepolia();
        address guard = makeAddr("safeGuard");
        vm.store(_account("12"), DeployGuards.SAFE_GUARD_SLOT, bytes32(uint256(uint160(guard))));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.SafeHasGuard.selector, "GUARDIAN", _account("12"), guard
            )
        );
        deployer.prepare();
    }

    /// L1: a Safe proxy must run a canonical singleton, at its address and with its code.
    function test_ASafeOnAnotherSingletonIsRefused() public {
        _sepolia();
        address other = address(new MockSafeSingleton()); // same code, another address
        vm.store(_account("02"), bytes32(0), bytes32(uint256(uint160(other))));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.NotACanonicalSafe.selector, "ADMIN", _account("02"), other
            )
        );
        deployer.prepare();
        // The allowed address with other code.
        vm.store(_account("02"), bytes32(0), bytes32(uint256(uint160(testSingleton))));
        vm.etch(testSingleton, address(new MockSafe()).code);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.NotACanonicalSafe.selector, "ADMIN", _account("01"), testSingleton
            )
        );
        deployer.prepare();
    }

    /// L1: the canonical singletons both scripts allow by default.
    function test_TheCanonicalSafeSingletonsArePinned() public {
        (address[] memory s, bytes32[] memory h) = new Deploy().safeSingletons();
        assertEq(s.length, 6);
        assertEq(s[0], 0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552, "1.3.0 L1");
        assertEq(s[1], 0x69f4D1788e39c87893C980c06EdF4b7f686e2938, "1.3.0 L1, EIP-155");
        assertEq(s[2], 0x3E5c63644E683549055b9Be8653de26E0B4CD36E, "1.3.0 L2");
        assertEq(s[3], 0xfb1bffC9d739B8D520DaF37dF666da4C687191EA, "1.3.0 L2, EIP-155");
        assertEq(s[4], 0x41675C099F32341bf84BFc5382aF534df5C7461a, "1.4.1 L1");
        assertEq(s[5], 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762, "1.4.1 L2");
        assertEq(h[0], 0xbba688fbdb21ad2bb58bc320638b43d94e7d100f6f3ebaab0a4e4de6304b1c2e);
        assertEq(h[1], h[0]);
        assertEq(h[2], 0x21842597390c4c6e3c1239e434a682b054bd9548eee5e9b1d6a4482731023c0f);
        assertEq(h[3], h[2]);
        assertEq(h[4], 0x1fe2df852ba3299d6534ef416eefa406e56ced995bca886ab7a553e6d0c5e1c4);
        assertEq(h[5], 0xb1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff);
        (address[] memory v,) = new Verify().safeSingletons();
        assertEq(keccak256(abi.encode(v)), keccak256(abi.encode(s)), "Verify uses the same list");
        // Without the test singleton, a mock Safe is refused.
        _sepolia();
        Deploy plain = new DeployHarness();
        DeployHarness(address(plain)).setEnv("GENESIS_CONFIG", GENESIS);
        DeployHarness(address(plain)).setFile(GENESIS, bytes(_filled()));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.NotACanonicalSafe.selector, "ADMIN", _account("01"), testSingleton
            )
        );
        plain.prepare();
    }

    /// L1: Verify repeats it. A module enabled after genesis fails the readback.
    function test_VerifyRefusesAModuleEnabledAfterGenesis() public {
        (string memory record,) = _offAnvilRecord();
        _etchSafe(_account("13"), address(new MockModuleSafe()).code);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.SafeHasModules.selector,
                "GUARDIAN",
                _account("13"),
                MockModuleSafe(_account("13")).MODULE()
            )
        );
        verifier.verify(record);
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

    // ------------------------------------------------------------------ DEPS-3: the coordinator

    /// @dev The off-anvil inputs with a VRF coordinator instead of NO_VRF.
    function _withVrf(address coordinator) internal {
        deployer.setEnv("NO_VRF", "");
        deployer.setEnv("VRF_COORDINATOR", vm.toString(coordinator));
        deployer.setEnv("VRF_SUBSCRIPTION_ID", "7");
        deployer.setEnv("VRF_KEY_HASH", vm.toString(keccak256("lane")));
    }

    /// The Chainlink VRF v2.5 coordinator on Ethereum mainnet (docs.chain.link), and its runtime
    /// code hash read from mainnet on 14 October 2026.
    function test_DEPS3_TheMainnetCoordinatorIsPinned() public pure {
        assertEq(DeployGuards.CANONICAL_VRF_COORDINATOR, 0xD7f86b4b8Cae7D942340FF628F82735b7a20893a);
        assertEq(
            DeployGuards.CANONICAL_VRF_COORDINATOR_CODEHASH,
            0xbe4ae0321fb1c74c80eea0c14c9c7b28c69ce17df15222e27b1e934cc98f5f61
        );
    }

    /// DEPS-3: on mainnet the coordinator must be the canonical one, with its pinned code.
    function test_DEPS3_MainnetRefusesANonCanonicalCoordinator() public {
        DelegationManagementMock delegation = _sepolia();
        vm.chainId(1);
        vm.etch(DeployGuards.CANONICAL_DELEGATION, address(delegation).code);
        deployer.setEnv("DELEGATION_CONTRACT", "");
        MockVrfCoordinator fake = new MockVrfCoordinator();
        _withVrf(address(fake));
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.NonCanonicalOnMainnet.selector, "VRF_COORDINATOR", address(fake)
            )
        );
        deployer.prepare();
        // The canonical address with other code is refused too.
        address canonical = DeployGuards.CANONICAL_VRF_COORDINATOR;
        vm.etch(canonical, address(fake).code);
        _withVrf(canonical);
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.NonCanonicalCode.selector, "VRF_COORDINATOR", canonical, canonical.codehash
            )
        );
        deployer.prepare();
    }

    /// DEPS-3: off mainnet the operator may pin the coordinator's code hash.
    function test_DEPS3_TheCoordinatorCodeHashCanBePinnedOffMainnet() public {
        _sepolia();
        MockVrfCoordinator coordinator = new MockVrfCoordinator();
        _withVrf(address(coordinator));
        deployer.setEnv("VRF_COORDINATOR_CODEHASH", vm.toString(keccak256("other code")));
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.UnexpectedCodeHash.selector,
                "VRF_COORDINATOR",
                keccak256("other code"),
                address(coordinator).codehash
            )
        );
        deployer.prepare();
        deployer.setEnv("VRF_COORDINATOR_CODEHASH", vm.toString(address(coordinator).codehash));
        assertEq(deployer.prepare().p.vrfCoordinator, address(coordinator));
    }

    /// DEPS-3: Verify refuses a mainnet record whose dependencies are not the canonical
    /// contracts with their pinned code. (A Sepolia deployment's record, relabelled chain 1.)
    function test_DEPS3_VerifyRefusesNonCanonicalDependenciesOnMainnet() public {
        DelegationManagementMock delegation = _sepolia();
        MockVrfCoordinator fake = new MockVrfCoordinator();
        _withVrf(address(fake));
        vm.recordLogs();
        deployer.run();
        verifier.addLogs(vm.getRecordedLogs());
        string memory record = _tamper(deployer.lastRecord(), '"chainId":11155111', '"chainId":1');
        verifier.setFile(GENESIS, bytes(_filled()));
        verifier.setFile("config/manifest.json", MANIFEST);
        vm.warp(block.timestamp + 5 days);
        verifier.verify(deployer.lastRecord());
        vm.chainId(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.NonCanonicalOnMainnet.selector, "VRF_COORDINATOR", address(fake)
            )
        );
        verifier.verify(record);
        // The canonical address, but the recorded code hash is not the pinned one.
        address canonical = DeployGuards.CANONICAL_VRF_COORDINATOR;
        string memory moved = _tamper(record, vm.toString(address(fake)), vm.toString(canonical));
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.NonCanonicalCode.selector,
                "params.vrfCoordinatorCodeHash",
                canonical,
                address(fake).codehash
            )
        );
        verifier.verify(moved);
        // Permit2 and the delegation contract, on a record without the module.
        string memory noVrf = _tamper(
            _tamper(record, '"entropy":"vrf"', '"entropy":"none"'),
            vm.toString(address(fake)),
            vm.toString(address(0))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.NonCanonicalOnMainnet.selector, "DELEGATION_CONTRACT", address(delegation)
            )
        );
        verifier.verify(noVrf);
        string memory otherPermit2 =
            _tamper(noVrf, vm.toString(DeployV1.CANONICAL_PERMIT2), vm.toString(address(fake)));
        vm.expectRevert(
            abi.encodeWithSelector(Verify.NonCanonicalOnMainnet.selector, "PERMIT2", address(fake))
        );
        verifier.verify(otherPermit2);
        // The canonical delegation address with other code.
        address canonicalDelegation = DeployGuards.CANONICAL_DELEGATION;
        vm.etch(canonicalDelegation, address(delegation).code);
        string memory mockAtCanonical =
            _tamper(noVrf, vm.toString(address(delegation)), vm.toString(canonicalDelegation));
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.NonCanonicalCode.selector,
                "DELEGATION_CONTRACT",
                canonicalDelegation,
                address(delegation).codehash
            )
        );
        verifier.verify(mockAtCanonical);
        // Permit2 without code.
        vm.etch(DeployV1.CANONICAL_PERMIT2, "");
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.NonCanonicalCode.selector, "PERMIT2", DeployV1.CANONICAL_PERMIT2, bytes32(0)
            )
        );
        verifier.verify(noVrf);
    }

    // ------------------------------------------------------------------ DEPS-4: the subscription

    function _vrfRecord(MockVrfSubscriptions coordinator)
        internal
        returns (string memory record, DeployV1.Deployment memory d)
    {
        _sepolia();
        _withVrf(address(coordinator));
        vm.recordLogs();
        d = deployer.run();
        verifier.addLogs(vm.getRecordedLogs());
        record = deployer.lastRecord();
        verifier.setFile(GENESIS, bytes(_filled()));
        verifier.setFile("config/manifest.json", MANIFEST);
        vm.warp(block.timestamp + 5 days);
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    /// DEPS-4: off anvil, Verify requires the module to be the subscription's only consumer.
    function test_DEPS4_VerifyChecksTheSubscriptionConsumers() public {
        MockVrfSubscriptions coordinator = new MockVrfSubscriptions();
        (string memory record, DeployV1.Deployment memory d) = _vrfRecord(coordinator);
        address module = address(d.entropyModule);
        vm.expectRevert(abi.encodeWithSelector(Verify.SubscriptionConsumers.selector, 7, 0));
        verifier.verify(record);
        address[] memory two = new address[](2);
        two[0] = module;
        two[1] = makeAddr("anotherConsumer");
        coordinator.setSubscription(address(this), two);
        vm.expectRevert(abi.encodeWithSelector(Verify.SubscriptionConsumers.selector, 7, 2));
        verifier.verify(record);
        coordinator.setSubscription(address(this), _one(makeAddr("notTheModule")));
        vm.expectRevert(abi.encodeWithSelector(Verify.SubscriptionConsumers.selector, 7, 1));
        verifier.verify(record);
        // Off mainnet any owner is accepted (Sepolia r2's is the operator).
        coordinator.setSubscription(address(this), _one(module));
        verifier.verify(record);
        // A coordinator that does not know the subscription fails the run (L5).
        coordinator.setUnknown(true);
        vm.expectRevert(
            abi.encodeWithSelector(Verify.SubscriptionUnreadable.selector, address(coordinator), 7)
        );
        verifier.verify(record);
    }

    /// DEPS-4: on mainnet the subscription owner must be the hot admin Safe (ADMIN and
    /// PARAMETER_SETTER), and a coordinator that cannot report it fails closed.
    function test_DEPS4_OnMainnetTheSubscriptionOwnerIsTheHotAdminSafe() public {
        MockVrfSubscriptions coordinator = new MockVrfSubscriptions();
        (, DeployV1.Deployment memory d) = _vrfRecord(coordinator);
        GovernanceConfig.Config memory cfg = DeployV1.config(d, _filled());
        address[] memory consumers = _one(address(d.entropyModule));
        address[2] memory wrong = [address(this), _account("02")]; // the operator, the cold admin
        for (uint256 i; i < 2; ++i) {
            coordinator.setSubscription(wrong[i], consumers);
            verifier.checkSubscriptionExternal(d, cfg, false);
            vm.expectRevert(abi.encodeWithSelector(Verify.SubscriptionOwner.selector, wrong[i]));
            verifier.checkSubscriptionExternal(d, cfg, true);
        }
        coordinator.setSubscription(_account("01"), consumers);
        verifier.checkSubscriptionExternal(d, cfg, true);
        // A coordinator without `getSubscription`: skipped off mainnet, refused on mainnet.
        MockVrfCoordinator plain = new MockVrfCoordinator();
        vm.etch(address(coordinator), address(plain).code);
        verifier.checkSubscriptionExternal(d, cfg, false);
        vm.expectRevert(
            abi.encodeWithSelector(Verify.SubscriptionUnreadable.selector, address(coordinator), 7)
        );
        verifier.checkSubscriptionExternal(d, cfg, true);
    }

    /// DEPS-3 (L4): on mainnet the live coordinator (the module's `coordinator()`) and the
    /// canonical address's code are checked as well as the recorded parameters.
    function test_DEPS3_VerifyChecksTheLiveCoordinatorAndItsCode() public {
        // A deployment whose module points at a fake coordinator, its record moved to the
        // canonical address and pinned hash: the live coordinator is still the fake.
        _sepolia();
        MockVrfCoordinator fake = new MockVrfCoordinator();
        _withVrf(address(fake));
        vm.recordLogs();
        deployer.run();
        verifier.addLogs(vm.getRecordedLogs());
        verifier.setFile(GENESIS, bytes(_filled()));
        verifier.setFile("config/manifest.json", MANIFEST);
        address canonical = DeployGuards.CANONICAL_VRF_COORDINATOR;
        bytes32 pin = DeployGuards.CANONICAL_VRF_COORDINATOR_CODEHASH;
        string memory record = _tamper(
            _tamper(
                _tamper(deployer.lastRecord(), '"chainId":11155111', '"chainId":1'),
                vm.toString(address(fake)),
                vm.toString(canonical)
            ),
            vm.toString(address(fake).codehash),
            vm.toString(pin)
        );
        vm.chainId(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.NonCanonicalOnMainnet.selector, "EntropyModule.coordinator", address(fake)
            )
        );
        verifier.verify(record);
    }

    /// DEPS-3 (L4): a module on the canonical address whose code is not the pinned code.
    function test_DEPS3_VerifyChecksTheCanonicalCoordinatorsCode() public {
        _sepolia();
        address canonical = DeployGuards.CANONICAL_VRF_COORDINATOR;
        vm.etch(canonical, address(new MockVrfCoordinator()).code);
        _withVrf(canonical);
        vm.recordLogs();
        deployer.run();
        verifier.addLogs(vm.getRecordedLogs());
        verifier.setFile(GENESIS, bytes(_filled()));
        verifier.setFile("config/manifest.json", MANIFEST);
        string memory record = _tamper(deployer.lastRecord(), '"chainId":11155111', '"chainId":1');
        vm.chainId(1);
        // The recorded hash is the mock's.
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.NonCanonicalCode.selector,
                "params.vrfCoordinatorCodeHash",
                canonical,
                canonical.codehash
            )
        );
        verifier.verify(record);
        // With the pinned hash recorded, the code on chain still differs.
        string memory pinned = _tamper(
            record,
            vm.toString(canonical.codehash),
            vm.toString(DeployGuards.CANONICAL_VRF_COORDINATOR_CODEHASH)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.NonCanonicalCode.selector, "VRF_COORDINATOR", canonical, canonical.codehash
            )
        );
        verifier.verify(pinned);
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

    // ------------------------------------------------------------------ deployer and namespace

    /// Improvement (DEPS): an EIP-7702 delegated deployer is refused. It alone may call
    /// `configure` until genesis completes, so wallet code driving it must not be in play.
    function test_ADelegatedDeployerIsRefused() public {
        _sepolia();
        address operator = makeAddr("delegatedOperator");
        vm.etch(operator, abi.encodePacked(hex"ef0100", makeAddr("walletCode")));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Deploy.DelegatedDeployer.selector, operator));
        deployer.prepare();
        // On anvil too.
        vm.chainId(DeployV1.LOCAL_CHAIN_ID);
        deployer.setRpcChainId(DeployV1.LOCAL_CHAIN_ID);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Deploy.DelegatedDeployer.selector, operator));
        deployer.prepare();
    }

    /// Improvement (DEPS): off anvil the namespace must be explicit, so no address can be taken
    /// in advance under the default one.
    function test_OffAnvilTheNamespaceIsExplicit() public {
        _sepolia();
        deployer.setEnv("DEPLOY_NAMESPACE", "");
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.MissingParameter.selector, "DEPLOY_NAMESPACE")
        );
        deployer.prepare();
    }

    /// Improvement (DEPS): a contract whose address depends only on the namespace (no
    /// constructor arguments) can be created by anyone who knows the namespace. A taken address
    /// stops the run before anything is broadcast, with its name.
    function test_ATakenAddressIsRefusedBeforeTheBroadcast() public {
        _sepolia();
        DeployV1.Params memory p = deployer.params(false);
        bytes32 s = DeployV1.salt(p, "ContentStore");
        vm.prank(makeAddr("squatter"));
        (bool ok,) =
            DeployGuards.CREATE2_FACTORY.call(abi.encodePacked(s, type(ContentStore).creationCode));
        assertTrue(ok);
        address taken = vm.computeCreate2Address(
            s, keccak256(type(ContentStore).creationCode), DeployGuards.CREATE2_FACTORY
        );
        vm.expectRevert(abi.encodeWithSelector(Deploy.AddressTaken.selector, "ContentStore", taken));
        deployer.prepare();
        deployer.setEnv("DEPLOY_NAMESPACE", vm.toString(keccak256("6529-works/fresh")));
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

    // ------------------------------------------------------------------ re-verify after a change

    /// @dev The cold admin (…b002) replaces the hot admin (…b001) with …b003, by the runbook:
    ///      the revocations first, the grants once they have executed. Records the logs.
    function _recoverHotAdmin(DeployV1.Deployment memory d) internal returns (address newHot) {
        address hot = _account("01");
        address cold = _account("02");
        newHot = _account("03");
        _etchSafe(newHot, address(new MockSharedSignerSafe()).code);
        uint64[5] memory roles = [
            Roles.ADMIN,
            Roles.UNPAUSER,
            Roles.PARAMETER_SETTER,
            Roles.FUNDS_SETTER,
            Roles.SUCCESSOR_SETTER
        ];
        vm.recordLogs();
        vm.startPrank(cold);
        for (uint256 i; i < 5; ++i) {
            d.manager
                .schedule(
                    address(d.manager),
                    abi.encodeCall(IAccessManager.revokeRole, (roles[i], hot)),
                    0
                );
        }
        vm.warp(block.timestamp + 30 days);
        for (uint256 i; i < 5; ++i) {
            d.manager
                .execute(
                    address(d.manager), abi.encodeCall(IAccessManager.revokeRole, (roles[i], hot))
                );
            d.manager
                .schedule(
                    address(d.manager),
                    abi.encodeCall(
                        IAccessManager.grantRole, (roles[i], newHot, Roles.executionDelay(roles[i]))
                    ),
                    0
                );
        }
        vm.warp(block.timestamp + 30 days);
        for (uint256 i; i < 5; ++i) {
            d.manager
                .execute(
                    address(d.manager),
                    abi.encodeCall(
                        IAccessManager.grantRole, (roles[i], newHot, Roles.executionDelay(roles[i]))
                    )
                );
        }
        vm.stopPrank();
        verifier.addLogs(vm.getRecordedLogs());
        vm.warp(block.timestamp + 30 days); // every grant delay has passed
    }

    /// @dev The genesis copy with the hot admin's entries moved to …b003.
    function _epochFile() internal view returns (string memory updated) {
        updated = vm.replace(
            _filled(),
            string.concat(
                '"account": "', FILLED_PREFIX, "01", '",\n      "label": "Hot admin Safe"'
            ),
            string.concat(
                    '"account": "', FILLED_PREFIX, "03", '",\n      "label": "Hot admin Safe"'
                )
        );
        assertTrue(keccak256(bytes(updated)) != keccak256(bytes(_filled())), "edited");
    }

    /// Improvement (runbook): after an admin recovery, Verify passes in epoch mode against a
    /// copy of the genesis file with the new holders, while the genesis event checks keep the
    /// recorded genesis file.
    function test_ReverifyAfterAdminRecoveryPassesInEpochMode() public {
        (string memory record, DeployV1.Deployment memory d) = _offAnvilRecord();
        address newHot = _recoverHotAdmin(d);
        // Against the genesis file alone the readback fails: the old holder is gone.
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceConfig.HolderMismatch.selector, Roles.ADMIN, _account("01")
            )
        );
        verifier.verify(record);
        // Epoch mode.
        verifier.setFile("config/epoch-1.json", bytes(_epochFile()));
        verifier.setEnv("GOVERNANCE_CONFIG", "config/epoch-1.json");
        (,, uint256 holders) = verifier.verify(record);
        assertEq(holders, 17);
        (bool admin,) = d.manager.hasRole(Roles.ADMIN, newHot);
        assertTrue(admin);
    }

    /// Epoch mode with the epoch's manifest: it must be recorded on the manager's statement
    /// chain and name the epoch file by its SHA-256.
    function test_EpochModeBindsTheEpochManifest() public {
        (string memory record, DeployV1.Deployment memory d) = _offAnvilRecord();
        address newHot = _recoverHotAdmin(d);
        bytes memory epoch = bytes(_epochFile());
        bytes memory manifestFile = abi.encodePacked(
            '{"schema":"6529-works/governance-manifest/1","epoch":1,"governanceConfig":{"sha256":"',
            vm.toString(sha256(epoch)),
            '"}}'
        );
        verifier.setFile("config/epoch-1.json", epoch);
        verifier.setEnv("GOVERNANCE_CONFIG", "config/epoch-1.json");
        verifier.setFile("config/manifest-epoch1.json", manifestFile);
        verifier.setEnv("GOVERNANCE_MANIFEST_PATH", "config/manifest-epoch1.json");
        // Not recorded yet.
        vm.expectRevert(
            abi.encodeWithSelector(Verify.ManifestNotRecorded.selector, sha256(manifestFile))
        );
        verifier.verify(record);
        // The new hot admin publishes it (SUCCESSOR_SETTER, 30 days).
        bytes memory publish = abi.encodeCall(
            d.statementLog.appendGovernanceManifest,
            (DeployV1.manifestStatement(d, DeployV1.Manifest(sha256(manifestFile), "ar://epoch-1")))
        );
        vm.recordLogs();
        vm.prank(newHot);
        d.manager.schedule(address(d.statementLog), publish, 0);
        vm.warp(block.timestamp + 30 days);
        vm.prank(newHot);
        d.manager.execute(address(d.statementLog), publish);
        verifier.addLogs(vm.getRecordedLogs());
        verifier.verify(record);
        // A configuration file other than the one the manifest names is refused, even one
        // with the same holders.
        bytes memory other = abi.encodePacked(epoch, " ");
        verifier.setFile("config/epoch-1.json", other);
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.ManifestConfigMismatch.selector, sha256(epoch), sha256(other)
            )
        );
        verifier.verify(record);
    }

    /// Epoch mode: a holder the current file drops must be gone from the chain.
    function test_EpochModeRequiresDroppedHoldersToBeRevoked() public {
        (string memory record, DeployV1.Deployment memory d) = _offAnvilRecord();
        address hot = _account("01");
        address oldCurator = _account("61");
        address newCurator = makeAddr("newCurator");
        bytes memory grant =
            abi.encodeCall(IAccessManager.grantRole, (Roles.CURATOR, newCurator, 0));
        vm.recordLogs();
        vm.prank(hot);
        d.manager.schedule(address(d.manager), grant, 0);
        vm.warp(block.timestamp + 30 days);
        vm.prank(hot);
        d.manager.execute(address(d.manager), grant);
        verifier.addLogs(vm.getRecordedLogs());
        vm.warp(block.timestamp + Roles.grantDelay(Roles.CURATOR));
        string memory epoch =
            _tamper(_filled(), vm.toLowercase(vm.toString(oldCurator)), vm.toString(newCurator));
        verifier.setFile("config/epoch-1.json", bytes(epoch));
        verifier.setEnv("GOVERNANCE_CONFIG", "config/epoch-1.json");
        vm.expectRevert(
            abi.encodeWithSelector(Verify.HolderNotRemoved.selector, Roles.CURATOR, oldCurator)
        );
        verifier.verify(record);
        // Once the old key is revoked, the epoch verifies.
        bytes memory revoke = abi.encodeCall(IAccessManager.revokeRole, (Roles.CURATOR, oldCurator));
        vm.prank(hot);
        d.manager.schedule(address(d.manager), revoke, 0);
        vm.warp(block.timestamp + 30 days);
        vm.prank(hot);
        d.manager.execute(address(d.manager), revoke);
        verifier.verify(record);
    }

    /// Improvement (runbook): Verify reports operations still pending on the manager.
    function test_VerifyReportsPendingOperations() public {
        (string memory record, DeployV1.Deployment memory d) = _anvilRecord();
        address hot = address(0xB001);
        bytes memory data =
            abi.encodeCall(IAccessManager.revokeRole, (Roles.GUARDIAN, address(0xB011)));
        vm.recordLogs();
        vm.prank(hot);
        (bytes32 id,) = d.manager.schedule(address(d.manager), data, 0);
        verifier.addLogs(vm.getRecordedLogs());
        uint48 readyAt = d.manager.getSchedule(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                Verify.PendingOperation.selector,
                id,
                hot,
                address(d.manager),
                IAccessManager.revokeRole.selector,
                readyAt
            )
        );
        verifier.verify(record);
        // Reviewed and allowed: it is logged instead.
        verifier.setEnv("ALLOW_PENDING_OPERATIONS", "1");
        verifier.verify(record);
        verifier.setEnv("ALLOW_PENDING_OPERATIONS", "");
        // A cancelled operation is no longer pending.
        vm.prank(address(0xB012));
        d.manager.cancel(hot, address(d.manager), data);
        verifier.verify(record);
    }

    /// An operation that expired without executing is not pending either.
    function test_AnExpiredOperationIsNotPending() public {
        (string memory record, DeployV1.Deployment memory d) = _anvilRecord();
        bytes memory data = abi.encodeCall(IAccessManager.setGrantDelay, (Roles.KEEPER, 2 days));
        vm.recordLogs();
        vm.prank(address(0xB001));
        (bytes32 id,) = d.manager.schedule(address(d.manager), data, 0);
        verifier.addLogs(vm.getRecordedLogs());
        vm.warp(d.manager.getSchedule(id) + d.manager.expiration());
        assertEq(d.manager.getSchedule(id), 0, "expired");
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
