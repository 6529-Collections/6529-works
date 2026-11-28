// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { ICurationVerifier } from "src/interfaces/ICurationVerifier.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IRevokedRoots } from "src/interfaces/IRevokedRoots.sol";
import { PackageItem, PartyAcceptance } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { Roles } from "src/governance/Roles.sol";
import { Burner, GasRuleAssertions } from "../helpers/GasRule.sol";
import { CurationBase } from "./CurationBase.sol";

/// @dev Stands where a replaced mint policy stands (`PackageRegistry.previous`): declares
///      `IRevokedRoots` and answers `isRevoked` as the test sets it.
contract RevokedRootsMock is IERC165 {
    enum Mode {
        NO,
        YES,
        TWO,
        REVERT,
        EMPTY,
        OVERSIZED
    }

    Mode public mode;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IRevokedRoots).interfaceId || id == type(IERC165).interfaceId;
    }

    function isRevoked(bytes32) external view {
        Mode m = mode;
        if (m == Mode.REVERT) revert("no answer");
        uint256 word = m == Mode.YES ? 1 : m == Mode.TWO ? 2 : 0;
        uint256 size = m == Mode.EMPTY ? 0 : m == Mode.OVERSIZED ? 64 : 32;
        assembly ("memory-safe") {
            mstore(0, word)
            mstore(0x20, 0)
            return(0, size)
        }
    }
}

/// @dev Declares the package registry's interface but not `IRevokedRoots`.
contract PackageRegistryOnlyStub is IERC165 {
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IPackageRegistry).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @notice A mint policy that replaces another (`previous`): it refuses every root the replaced
///         policy reports as revoked, at registration and at every later use, through a chain of
///         replacements; a replaced policy that does not answer leaves every root refused, and
///         one that runs short of gas makes the call revert.
contract PackageRegistrySuccessorTest is CurationBase, GasRuleAssertions {
    bytes32 internal constant SHA_A = keccak256("media a");
    PackageRegistry internal next;
    address internal directoryAddr;

    function setUp() public override {
        super.setUp();
        directoryAddr = registry.directory();
        next = _successorOf(address(registry));
    }

    function _successorOf(address previous) internal returns (PackageRegistry policy) {
        policy = new PackageRegistry(
            address(manager),
            ICurationVerifier(address(verifier)),
            address(verifier).codehash,
            directoryAddr,
            IEconomicsResolver(address(_policyStub)),
            address(entropy),
            keccak256("cc0 text file"),
            previous
        );
        vm.startPrank(admin);
        _map(address(policy), PackageRegistry.revokePackage.selector, Roles.NETWORK);
        _map(address(policy), PackageRegistry.killSignerApprovals.selector, Roles.NETWORK);
        vm.stopPrank();
    }

    function _status(PackageRegistry policy, bytes32 root)
        internal
        view
        returns (IPackageRegistry.PackageStatus status)
    {
        (status,,) = policy.packageOf(root);
    }

    function _assertRefused(PackageRegistry policy, bytes32 root) internal {
        assertTrue(policy.isRevoked(root), "isRevoked");
        assertEq(uint8(_status(policy, root)), uint8(IPackageRegistry.PackageStatus.REVOKED));
        bytes memory attestation = _attestation(signerKey1, root, EVIDENCE);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        policy.registerPackage(root, EVIDENCE, attestation);
        PartyAcceptance memory a = _acceptance(lead);
        bytes memory proof = _pf(leadKey, _sig(leadKey, policy.acceptanceDigest(root, a)));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        policy.acceptPackage(root, a, proof);
    }

    // ------------------------------------------------------------------ wiring

    function test_successor_theFirstPolicyReplacesNone() public {
        assertEq(registry.previous(), address(0));
        assertEq(next.previous(), address(registry));
        assertTrue(registry.supportsInterface(type(IRevokedRoots).interfaceId));
        bytes32 root = keccak256("root");
        assertFalse(registry.isRevoked(root), "unknown");
        _register(root);
        assertFalse(registry.isRevoked(root), "approved");
        vm.prank(guardian);
        registry.revokePackage(root, 0);
        assertTrue(registry.isRevoked(root), "revoked");
        bytes32 advance = keccak256("advance");
        vm.prank(guardian);
        registry.revokePackage(advance, 0);
        assertTrue(registry.isRevoked(advance), "revoked in advance");
        // A root nobody registered has no signer: a kill, even of the zero address, does not
        // revoke it.
        vm.prank(guardian);
        registry.killSignerApprovals(address(0));
        assertFalse(registry.isRevoked(keccak256("never seen")), "unknown after a kill");
    }

    function test_successor_thePredecessorMustDeclareRevokedRoots() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        _successorOf(eoa);
        address other = address(new PackageRegistryOnlyStub());
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, other));
        _successorOf(other);
    }

    // ------------------------------------------------------------------ what is refused

    function test_successor_refusesARootRevokedInThePredecessor() public {
        bytes32 root = keccak256("root");
        _register(root);
        vm.prank(guardian);
        registry.revokePackage(root, keccak256("reason"));
        _assertRefused(next, root);
        (, bytes32 evidence, address signer) = next.packageOf(root);
        assertEq(evidence, bytes32(0), "never registered here");
        assertEq(signer, address(0));
    }

    function test_successor_refusesARootRevokedInAdvanceInThePredecessor() public {
        bytes32 root = keccak256("leaked");
        vm.prank(guardian);
        registry.revokePackage(root, keccak256("leaked attestation"));
        _assertRefused(next, root);
    }

    /// @dev The roots a signer registered before its approvals were killed are refused; a root
    ///      it registers after the kill, and another signer's root, are not.
    function test_successor_refusesTheRootsOfAKilledSigner() public {
        bytes32 before = keccak256("before the kill");
        bytes32 other = keccak256("another signer");
        _register(before);
        registry.registerPackage(other, EVIDENCE, _attestation(signerKey2, other, EVIDENCE));
        vm.prank(guardian);
        registry.killSignerApprovals(signer1);
        bytes32 later = keccak256("after the kill");
        _register(later);

        _assertRefused(next, before);
        assertFalse(next.isRevoked(other));
        assertFalse(next.isRevoked(later));
        next.registerPackage(other, EVIDENCE, _attestation(signerKey2, other, EVIDENCE));
        next.registerPackage(later, EVIDENCE, _attestation(signerKey1, later, EVIDENCE));
        assertEq(uint8(_status(next, later)), uint8(IPackageRegistry.PackageStatus.APPROVED));
        assertEq(uint8(_status(next, other)), uint8(IPackageRegistry.PackageStatus.APPROVED));
    }

    /// @dev Registered in both policies, then revoked (or its signer killed) in the replaced
    ///      one: the root stops being live here at once.
    function test_successor_aLaterRevocationInThePredecessorStopsARootRegisteredHere() public {
        PackageItem memory item = _item(lead, SHA_A);
        bytes32 itemHash = _hash(item);
        bytes32 root = WorksHashing.leaf(itemHash);
        bytes32 killed = keccak256("killed later");
        bytes32[] memory none = new bytes32[](0);
        _register(root);
        _register(killed);
        next.registerPackage(root, EVIDENCE, _attestation(signerKey1, root, EVIDENCE));
        next.registerPackage(killed, EVIDENCE, _attestation(signerKey2, killed, EVIDENCE));
        assertTrue(next.isApprovedItem(root, itemHash, none));
        assertFalse(next.isRevoked(root));

        vm.prank(guardian);
        registry.revokePackage(root, 0);
        assertFalse(next.isApprovedItem(root, itemHash, none));
        assertTrue(next.isRevoked(root));
        assertEq(uint8(_status(next, root)), uint8(IPackageRegistry.PackageStatus.REVOKED));
        (, bytes32 evidence, address signer) = next.packageOf(root);
        assertEq(evidence, EVIDENCE);
        assertEq(signer, signer1);
        PartyAcceptance memory a = _acceptance(lead);
        bytes memory proof = _pf(leadKey, _sig(leadKey, next.acceptanceDigest(root, a)));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        next.acceptPackage(root, a, proof);

        // The kill reaches a root the killed signer registered in the replaced policy, even
        // though another signer registered it here.
        vm.prank(guardian);
        registry.killSignerApprovals(signer1);
        assertTrue(next.isRevoked(killed));
        assertEq(uint8(_status(next, killed)), uint8(IPackageRegistry.PackageStatus.REVOKED));
    }

    function test_successor_registersARootThePredecessorNeverRevoked() public {
        bytes32 root = keccak256("pending");
        _register(root);
        assertFalse(next.isRevoked(root));
        assertEq(uint8(_status(next, root)), uint8(IPackageRegistry.PackageStatus.NONE));
        vm.expectEmit(address(next));
        emit IPackageRegistry.PackageRegistered(root, EVIDENCE, address(verifier), signer1);
        next.registerPackage(root, EVIDENCE, _attestation(signerKey1, root, EVIDENCE));
        assertEq(uint8(_status(next, root)), uint8(IPackageRegistry.PackageStatus.APPROVED));
        // A root nobody registered anywhere registers too.
        bytes32 fresh = keccak256("fresh");
        next.registerPackage(fresh, EVIDENCE, _attestation(signerKey1, fresh, EVIDENCE));
        assertEq(uint8(_status(next, fresh)), uint8(IPackageRegistry.PackageStatus.APPROVED));
    }

    /// @dev Revocations and kills made here stay here: the replaced policy is not written and
    ///      does not ask this one.
    function test_successor_itsOwnRevocationsDoNotReachThePredecessor() public {
        bytes32 root = keccak256("root");
        bytes32 killed = keccak256("killed here");
        _register(root);
        _register(killed);
        next.registerPackage(root, EVIDENCE, _attestation(signerKey1, root, EVIDENCE));
        next.registerPackage(killed, EVIDENCE, _attestation(signerKey1, killed, EVIDENCE));
        vm.prank(guardian);
        next.revokePackage(root, 0);
        assertTrue(next.isRevoked(root));
        assertFalse(registry.isRevoked(root));
        vm.prank(guardian);
        next.killSignerApprovals(signer1);
        assertTrue(next.isRevoked(killed));
        assertFalse(registry.isRevoked(killed));
        assertEq(uint8(_status(registry, killed)), uint8(IPackageRegistry.PackageStatus.APPROVED));
        // A root revoked in the replaced policy can be revoked here as well, once.
        bytes32 both = keccak256("both");
        vm.prank(guardian);
        registry.revokePackage(both, 0);
        vm.prank(guardian);
        next.revokePackage(both, 0);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, both));
        next.revokePackage(both, 0);
    }

    function test_successor_aThirdPolicyRefusesWhatEitherBeforeItRevoked() public {
        PackageRegistry third = _successorOf(address(next));
        bytes32 inFirst = keccak256("revoked in the first");
        bytes32 inSecond = keccak256("revoked in the second");
        bytes32 clean = keccak256("never revoked");
        vm.prank(guardian);
        registry.revokePackage(inFirst, 0);
        vm.prank(guardian);
        next.revokePackage(inSecond, 0);
        _assertRefused(third, inFirst);
        _assertRefused(third, inSecond);
        assertFalse(third.isRevoked(clean));
        third.registerPackage(clean, EVIDENCE, _attestation(signerKey1, clean, EVIDENCE));
        vm.prank(guardian);
        registry.revokePackage(clean, 0);
        assertTrue(third.isRevoked(clean), "a revocation in the first reaches the third");
        assertEq(uint8(_status(third, clean)), uint8(IPackageRegistry.PackageStatus.REVOKED));
    }

    // ------------------------------------------------------------------ a predecessor that fails

    /// @dev Only an answer of exactly one zero word lets a root through. A replaced policy
    ///      that reverts, answers nothing, answers the wrong size or answers any nonzero word
    ///      leaves every root refused, including one registered here while it still answered.
    function test_successor_aPredecessorThatDoesNotAnswerNoRefusesEveryRoot() public {
        RevokedRootsMock mock = new RevokedRootsMock();
        PackageRegistry policy = _successorOf(address(mock));
        PackageItem memory item = _item(lead, SHA_A);
        bytes32 itemHash = _hash(item);
        bytes32 root = WorksHashing.leaf(itemHash);
        bytes32[] memory none = new bytes32[](0);
        policy.registerPackage(root, EVIDENCE, _attestation(signerKey1, root, EVIDENCE));
        assertTrue(policy.isApprovedItem(root, itemHash, none));

        for (uint8 m = 1; m <= uint8(RevokedRootsMock.Mode.OVERSIZED); ++m) {
            mock.setMode(RevokedRootsMock.Mode(m));
            assertFalse(policy.isApprovedItem(root, itemHash, none));
            assertEq(uint8(_status(policy, root)), uint8(IPackageRegistry.PackageStatus.REVOKED));
            _assertRefused(policy, keccak256(abi.encode("another root", m)));
        }
        mock.setMode(RevokedRootsMock.Mode.NO);
        assertTrue(policy.isApprovedItem(root, itemHash, none));
        assertFalse(policy.isRevoked(root));
    }

    // ------------------------------------------------------------------ the gas rule

    /// @dev The read of the replaced policy forwards all gas: with it costing 1x to 100x its
    ///      base the answers are the same, and a read that runs short reverts with
    ///      `BoundedCallShortfall`, never "not revoked" (nor "revoked").
    function test_GasRule_AReadOfTheReplacedPolicyNeverAnswersForGas() public {
        Burner slow = new Burner(address(registry), 20_000);
        PackageRegistry policy = _successorOf(address(slow));
        PackageItem memory item = _item(lead, SHA_A);
        bytes32 itemHash = _hash(item);
        bytes32 root = WorksHashing.leaf(itemHash);
        bytes32[] memory none = new bytes32[](0);
        bytes memory attestation = _attestation(signerKey1, root, EVIDENCE);

        bytes memory data =
            abi.encodeCall(PackageRegistry.registerPackage, (root, EVIDENCE, attestation));
        Outcome memory o = _assertSameAtEveryMultiple(slow, stranger(), address(policy), data);
        assertTrue(o.ok, "registers with ample gas");
        slow.burnerSetMultiple(4);
        _assertShortfallNeverAnswers(slow, stranger(), address(policy), data);

        slow.burnerSetMultiple(1);
        policy.registerPackage(root, EVIDENCE, attestation);
        data = abi.encodeCall(PackageRegistry.isApprovedItem, (root, itemHash, none));
        o = _assertSameAtEveryMultiple(slow, stranger(), address(policy), data);
        assertTrue(abi.decode(o.data, (bool)));
        slow.burnerSetMultiple(4);
        _assertShortfallNeverAnswers(slow, stranger(), address(policy), data);
    }

    function stranger() internal returns (address) {
        return makeAddr("stranger");
    }
}
