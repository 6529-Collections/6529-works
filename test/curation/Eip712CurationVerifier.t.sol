// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Eip712CurationVerifier } from "src/curation/Eip712CurationVerifier.sol";
import { Roles } from "src/governance/Roles.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { ICurationSignerVerifier, ICurationVerifier } from "src/interfaces/ICurationVerifier.sol";
import { ERC1271WalletMock } from "test/mocks/AdversarialTargets.sol";
import { CurationBase } from "./CurationBase.sol";

contract Eip712CurationVerifierTest is CurationBase {
    // Golden vectors computed independently with `cast keccak` and `cast abi-encode`.
    bytes32 internal constant GOLDEN_APPROVAL_TYPEHASH =
        0xbf131d47e2ddcf4bd120061a8a3c2841ef379caa26b7eec0881120e1d8a43cdd;
    address internal constant FIXED_VERIFIER = 0x1000000000000000000000000000000000000001;
    bytes32 internal constant GOLDEN_DOMAIN =
        0x81c511d2826231982036519eb645b3739e82fe2e2095098b6796cc25de79bffe;
    /// @dev `approvalDigest(keccak256("root"), keccak256("evidence"), 1)` at FIXED_VERIFIER on
    ///      chain 31337.
    bytes32 internal constant GOLDEN_APPROVAL_DIGEST =
        0x8832dc6f5fe11be44c58102634abf24ef3ae736343fc16aeb7a54252f00009d3;

    bytes32 internal constant ROOT = keccak256("a package root");

    function _epoch1() internal view returns (uint256) {
        return verifier.signerEpoch(signer1);
    }

    // ------------------------------------------------------------------- golden vectors

    function test_golden_typehash() public pure {
        assertEq(Typehashes.PACKAGE_APPROVAL, GOLDEN_APPROVAL_TYPEHASH);
    }

    function test_golden_digest() public {
        vm.chainId(31337);
        vm.etch(FIXED_VERIFIER, address(verifier).code);
        Eip712CurationVerifier fixedVerifier = Eip712CurationVerifier(FIXED_VERIFIER);
        assertEq(
            fixedVerifier.approvalDigest(keccak256("root"), keccak256("evidence"), 1),
            GOLDEN_APPROVAL_DIGEST
        );
        bytes32 structHash = keccak256(
            abi.encode(GOLDEN_APPROVAL_TYPEHASH, keccak256("root"), keccak256("evidence"), 1)
        );
        assertEq(
            GOLDEN_APPROVAL_DIGEST,
            keccak256(abi.encodePacked(hex"1901", GOLDEN_DOMAIN, structHash))
        );
    }

    function test_eip712Domain() public view {
        (, string memory name, string memory version, uint256 chainId, address self,,) =
            verifier.eip712Domain();
        assertEq(name, "6529 Works Curation Verifier");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(self, address(verifier));
    }

    function test_supportsInterface() public view {
        assertTrue(verifier.supportsInterface(type(IERC165).interfaceId));
        assertTrue(verifier.supportsInterface(type(ICurationVerifier).interfaceId));
        assertTrue(verifier.supportsInterface(type(ICurationSignerVerifier).interfaceId));
        assertFalse(verifier.supportsInterface(0xffffffff));
    }

    // ------------------------------------------------------------------------ isApproved

    function test_isApproved_eitherSigner() public view {
        assertTrue(_approved(verifier, ROOT, EVIDENCE, _attestation(signerKey1, ROOT, EVIDENCE)));
        assertTrue(_approved(verifier, ROOT, EVIDENCE, _attestation(signerKey2, ROOT, EVIDENCE)));
    }

    function test_isApproved_compactSignature() public view {
        bytes memory sig = _compact(signerKey1, verifier.approvalDigest(ROOT, EVIDENCE, _epoch1()));
        assertTrue(_approved(verifier, ROOT, EVIDENCE, abi.encode(signer1, sig)));
    }

    function test_isApproved_rejectsMalleableHighS() public view {
        bytes memory sig = _highS(signerKey1, verifier.approvalDigest(ROOT, EVIDENCE, _epoch1()));
        assertFalse(_approved(verifier, ROOT, EVIDENCE, abi.encode(signer1, sig)));
    }

    function test_isApproved_bindsRootAndEvidence() public view {
        bytes memory att = _attestation(signerKey1, ROOT, EVIDENCE);
        assertFalse(_approved(verifier, keccak256("other root"), EVIDENCE, att));
        assertFalse(_approved(verifier, ROOT, keccak256("other evidence"), att));
    }

    function test_isApproved_rejectsNonSigner() public view {
        uint256 outsider = 0xBAD;
        assertFalse(_approved(verifier, ROOT, EVIDENCE, _attestation(outsider, ROOT, EVIDENCE)));
    }

    function test_isApproved_rejectsSignerClaimMismatch() public view {
        // signer2 is named, but signer1 signed.
        bytes memory sig = _sig(signerKey1, verifier.approvalDigest(ROOT, EVIDENCE, _epoch1()));
        assertFalse(_approved(verifier, ROOT, EVIDENCE, abi.encode(signer2, sig)));
    }

    function test_isApproved_rejectsWrongChain() public {
        bytes memory att = _attestation(signerKey1, ROOT, EVIDENCE);
        vm.chainId(block.chainid + 1);
        assertFalse(_approved(verifier, ROOT, EVIDENCE, att));
    }

    function test_isApproved_rejectsOtherDeployment() public {
        Eip712CurationVerifier other = new Eip712CurationVerifier(address(manager));
        bytes memory att = _attestation(signerKey1, ROOT, EVIDENCE);
        assertFalse(_approved(other, ROOT, EVIDENCE, att));
    }

    function test_isApproved_signerWithExecutionDelayDoesNotCount() public {
        vm.prank(admin);
        manager.grantRole(Roles.CURATION_SIGNER, signer1, 1 days);
        assertFalse(verifier.isSignerActive(signer1));
        assertFalse(_approved(verifier, ROOT, EVIDENCE, _attestation(signerKey1, ROOT, EVIDENCE)));
    }

    function test_isApproved_pendingGrantDoesNotCount() public {
        uint256 key = 0xC3;
        vm.startPrank(admin);
        manager.setGrantDelay(Roles.CURATION_SIGNER, 30 days);
        vm.warp(block.timestamp + 5 days); // the AccessManager's minimum setback
        manager.grantRole(Roles.CURATION_SIGNER, vm.addr(key), 0);
        vm.stopPrank();
        assertFalse(_approved(verifier, ROOT, EVIDENCE, _attestation(key, ROOT, EVIDENCE)));
        vm.warp(block.timestamp + 30 days);
        assertTrue(_approved(verifier, ROOT, EVIDENCE, _attestation(key, ROOT, EVIDENCE)));
    }

    function test_isApproved_revokedRoleDoesNotCount() public {
        vm.prank(admin);
        manager.revokeRole(Roles.CURATION_SIGNER, signer1);
        assertFalse(_approved(verifier, ROOT, EVIDENCE, _attestation(signerKey1, ROOT, EVIDENCE)));
    }

    // ------------------------------------------------------------------------ epochs (SIGS-2)

    function test_signerEpoch_isTheGrantTimeAndTheDisableCount() public {
        (uint48 since,,,) = manager.getAccess(Roles.CURATION_SIGNER, signer1);
        assertEq(verifier.signerEpoch(signer1), uint256(since) << 64);
        vm.prank(guardian);
        verifier.disableSigner(signer1);
        assertEq(verifier.signerEpoch(signer1), uint256(since) << 64 | 1);
        vm.prank(successor);
        verifier.enableSigner(signer1);
        assertEq(verifier.signerEpoch(signer1), uint256(since) << 64 | 2, "enabling changes it");
        vm.startPrank(admin);
        manager.revokeRole(Roles.CURATION_SIGNER, signer1);
        assertEq(verifier.signerEpoch(signer1), 2, "no grant");
        vm.warp(block.timestamp + 1 days);
        manager.grantRole(Roles.CURATION_SIGNER, signer1, 0);
        vm.stopPrank();
        assertEq(verifier.signerEpoch(signer1), uint256(block.timestamp) << 64 | 2);
        assertEq(verifier.signerEpoch(makeAddr("never a signer")), 0);
    }

    function test_isApproved_onlyAtTheCurrentEpoch() public view {
        uint256 epoch = verifier.signerEpoch(signer1);
        uint256[3] memory others = [epoch + 1, epoch - 1, 0];
        for (uint256 i; i < others.length; ++i) {
            bytes memory sig = _sig(signerKey1, verifier.approvalDigest(ROOT, EVIDENCE, others[i]));
            assertFalse(_approved(verifier, ROOT, EVIDENCE, abi.encode(signer1, sig)));
        }
    }

    /// @dev Review SIGS-2, inverted: approvals signed before a disable, including those signed
    ///      while disabled, never count after `enableSigner`; a fresh signature does.
    function test_isApproved_reEnablingDoesNotReviveOlderApprovals() public {
        bytes memory before = _attestation(signerKey1, ROOT, EVIDENCE);
        vm.prank(guardian);
        verifier.disableSigner(signer1);
        bytes memory whileDisabled = _attestation(signerKey1, ROOT, EVIDENCE);
        vm.prank(successor);
        verifier.enableSigner(signer1);
        assertTrue(verifier.isSignerActive(signer1));
        assertFalse(_approved(verifier, ROOT, EVIDENCE, before));
        assertFalse(_approved(verifier, ROOT, EVIDENCE, whileDisabled));
        assertTrue(_approved(verifier, ROOT, EVIDENCE, _attestation(signerKey1, ROOT, EVIDENCE)));
    }

    /// @dev Review SIGS-2, inverted: a revoked and re-granted role is a new grant.
    function test_isApproved_regrantingDoesNotReviveOlderApprovals() public {
        bytes memory oldGrant = _attestation(signerKey1, ROOT, EVIDENCE);
        vm.startPrank(admin);
        manager.revokeRole(Roles.CURATION_SIGNER, signer1);
        vm.warp(block.timestamp + 1);
        manager.grantRole(Roles.CURATION_SIGNER, signer1, 0);
        vm.stopPrank();
        assertTrue(verifier.isSignerActive(signer1));
        assertFalse(_approved(verifier, ROOT, EVIDENCE, oldGrant));
        assertTrue(_approved(verifier, ROOT, EVIDENCE, _attestation(signerKey1, ROOT, EVIDENCE)));
    }

    function test_isApproved_erc1271Signer() public {
        ERC1271WalletMock safe = new ERC1271WalletMock(signer1);
        vm.prank(admin);
        manager.grantRole(Roles.CURATION_SIGNER, address(safe), 0);
        uint256 epoch = verifier.signerEpoch(address(safe));
        bytes memory sig = _sig(signerKey1, verifier.approvalDigest(ROOT, EVIDENCE, epoch));
        assertTrue(_approved(verifier, ROOT, EVIDENCE, abi.encode(address(safe), sig)));
        bytes memory wrong = _sig(signerKey2, verifier.approvalDigest(ROOT, EVIDENCE, epoch));
        assertFalse(_approved(verifier, ROOT, EVIDENCE, abi.encode(address(safe), wrong)));
    }

    function test_isApproved_malformedAttestationsReturnFalse() public view {
        bytes memory sig = _sig(signerKey1, verifier.approvalDigest(ROOT, EVIDENCE, _epoch1()));
        bytes memory good = abi.encode(signer1, sig);
        assertTrue(_approved(verifier, ROOT, EVIDENCE, good));
        // Too short, a raw signature, dirty address bits, a non-canonical offset, and a length
        // running past the end: all false, none reverting.
        assertFalse(_approved(verifier, ROOT, EVIDENCE, ""));
        assertFalse(_approved(verifier, ROOT, EVIDENCE, sig));
        bytes memory dirty = bytes.concat(good);
        dirty[0] = 0x01;
        assertFalse(_approved(verifier, ROOT, EVIDENCE, dirty));
        bytes memory offset = bytes.concat(good);
        offset[63] = 0x60;
        assertFalse(_approved(verifier, ROOT, EVIDENCE, offset));
        bytes memory long = bytes.concat(good);
        long[95] = 0xff;
        assertFalse(_approved(verifier, ROOT, EVIDENCE, long));
    }

    /// @dev Review PoC 5, inverted: only the exact canonical encoding counts (no dirty padding,
    ///      no trailing bytes, no short or overlong body).
    function test_isApproved_rejectsNonCanonicalEncodings() public view {
        bytes memory sig = _sig(signerKey1, verifier.approvalDigest(ROOT, EVIDENCE, _epoch1()));
        bytes memory canonical = abi.encode(signer1, sig); // 65 bytes, 31 bytes of padding
        assertEq(canonical.length, 96 + 96);
        assertTrue(_approved(verifier, ROOT, EVIDENCE, canonical));
        bytes memory dirty = bytes.concat(canonical);
        dirty[96 + 65] = 0xff;
        assertFalse(_approved(verifier, ROOT, EVIDENCE, dirty));
        bytes memory lastPad = bytes.concat(canonical);
        lastPad[lastPad.length - 1] = 0x01;
        assertFalse(_approved(verifier, ROOT, EVIDENCE, lastPad));
        assertFalse(_approved(verifier, ROOT, EVIDENCE, bytes.concat(canonical, hex"deadbeef")));
        assertFalse(_approved(verifier, ROOT, EVIDENCE, bytes.concat(canonical, bytes32(0))));
        bytes memory unpadded = new bytes(96 + 65);
        for (uint256 i; i < unpadded.length; ++i) {
            unpadded[i] = canonical[i];
        }
        assertFalse(_approved(verifier, ROOT, EVIDENCE, unpadded));
        // A 64-byte signature has no padding at all.
        bytes memory compact =
            _compact(signerKey1, verifier.approvalDigest(ROOT, EVIDENCE, _epoch1()));
        assertTrue(_approved(verifier, ROOT, EVIDENCE, abi.encode(signer1, compact)));
    }

    function testFuzz_isApproved_neverRevertsOnGarbage(bytes calldata garbage) public view {
        assertFalse(_approved(verifier, ROOT, EVIDENCE, garbage));
    }

    function testFuzz_isApproved_onlyActiveSignersCount(uint256 key, bytes32 root, bytes32 ev)
        public
        view
    {
        key = bound(key, 1, SECP256K1_N - 1);
        bool active = key == signerKey1 || key == signerKey2;
        assertEq(_approved(verifier, root, ev, _attestation(key, root, ev)), active);
    }

    // -------------------------------------------------------------- disable and enable

    function test_disableSigner_immediateAndOneWay() public {
        bytes memory att = _attestation(signerKey1, ROOT, EVIDENCE);
        vm.expectEmit(address(verifier));
        emit ICurationSignerVerifier.SignerDisabled(signer1);
        vm.prank(guardian);
        verifier.disableSigner(signer1);
        assertTrue(verifier.isDisabled(signer1));
        assertFalse(verifier.isSignerActive(signer1));
        assertFalse(_approved(verifier, ROOT, EVIDENCE, att));
        // The second signer keeps curation running.
        assertTrue(_approved(verifier, ROOT, EVIDENCE, _attestation(signerKey2, ROOT, EVIDENCE)));
        // The guardian cannot undo its own disable.
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian)
        );
        verifier.enableSigner(signer1);
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(ICurationSignerVerifier.SignerAlreadyDisabled.selector, signer1)
        );
        verifier.disableSigner(signer1);
    }

    function test_disableSigner_survivesRoleRegrant() public {
        vm.prank(guardian);
        verifier.disableSigner(signer1);
        vm.startPrank(admin);
        manager.revokeRole(Roles.CURATION_SIGNER, signer1);
        manager.grantRole(Roles.CURATION_SIGNER, signer1, 0);
        vm.stopPrank();
        assertFalse(verifier.isSignerActive(signer1));
    }

    function test_disableSigner_inAdvance() public {
        address future = makeAddr("future signer");
        vm.prank(guardian);
        verifier.disableSigner(future);
        vm.prank(admin);
        manager.grantRole(Roles.CURATION_SIGNER, future, 0);
        assertFalse(verifier.isSignerActive(future));
    }

    function test_disableSigner_onlyGuardian() public {
        address[3] memory callers = [admin, successor, signer1];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManaged.AccessManagedUnauthorized.selector, callers[i]
                )
            );
            verifier.disableSigner(signer2);
        }
    }

    function test_enableSigner_restores() public {
        vm.prank(guardian);
        verifier.disableSigner(signer1);
        vm.expectEmit(address(verifier));
        emit ICurationSignerVerifier.SignerEnabled(signer1);
        vm.prank(successor);
        verifier.enableSigner(signer1);
        assertFalse(verifier.isDisabled(signer1));
        assertTrue(_approved(verifier, ROOT, EVIDENCE, _attestation(signerKey1, ROOT, EVIDENCE)));
    }

    function test_enableSigner_revertsWhenNotDisabled() public {
        vm.prank(successor);
        vm.expectRevert(
            abi.encodeWithSelector(ICurationSignerVerifier.SignerNotDisabled.selector, signer1)
        );
        verifier.enableSigner(signer1);
    }

    /// @dev With the 30-day class configured, re-enabling must be scheduled and wait 30 days,
    ///      and the guardian can cancel it meanwhile.
    function test_enableSigner_thirtyDayClass() public {
        vm.prank(admin);
        manager.grantRole(Roles.SUCCESSOR_SETTER, successor, 30 days);
        vm.prank(admin);
        manager.setRoleGuardian(Roles.SUCCESSOR_SETTER, Roles.GUARDIAN);
        vm.prank(guardian);
        verifier.disableSigner(signer1);

        bytes memory data = abi.encodeCall(Eip712CurationVerifier.enableSigner, (signer1));
        bytes32 opId = manager.hashOperation(successor, address(verifier), data);
        vm.prank(successor);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, opId)
        );
        verifier.enableSigner(signer1);

        vm.prank(successor);
        manager.schedule(address(verifier), data, 0);
        vm.warp(block.timestamp + 30 days - 1);
        vm.prank(successor);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, opId));
        manager.execute(address(verifier), data);

        vm.prank(guardian);
        manager.cancel(successor, address(verifier), data);
        assertTrue(verifier.isDisabled(signer1));

        vm.prank(successor);
        manager.schedule(address(verifier), data, 0);
        vm.warp(block.timestamp + 30 days);
        vm.prank(successor);
        manager.execute(address(verifier), data);
        assertFalse(verifier.isDisabled(signer1));
    }

    function test_governedFunctionsAreNonPayable() public {
        (bool ok,) = address(verifier).call{ value: 1 }(
            abi.encodeCall(Eip712CurationVerifier.disableSigner, (signer1))
        );
        assertFalse(ok);
    }

    /// @dev `isApproved`'s verdict, asserting that the signer is reported exactly when approved.
    function _approved(
        Eip712CurationVerifier target,
        bytes32 root,
        bytes32 evidence,
        bytes memory attestation
    ) internal view returns (bool) {
        (bool approved, address signer) = target.isApproved(root, evidence, attestation);
        if (approved) {
            (address named,) = abi.decode(attestation, (address, bytes));
            assertEq(signer, named, "approved: the named signer");
        } else {
            assertEq(signer, address(0), "rejected: no signer");
        }
        return approved;
    }
}
