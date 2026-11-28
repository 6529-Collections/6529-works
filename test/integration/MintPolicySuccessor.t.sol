// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Eip712CurationVerifier } from "src/curation/Eip712CurationVerifier.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { ICurationVerifier } from "src/interfaces/ICurationVerifier.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { UniformEditionAuctionLens } from "src/sales/UniformEditionAuctionLens.sol";
import { EditionAuctionStack } from "./EditionAuctionStack.sol";

/// @notice Replacing 6529 Stream's mint policy without bringing a revoked approval back, on the
///         real deployed stack. A curator's attestation is signed in the verifier's domain and
///         names no registry, so a second `PackageRegistry` that keeps the verifier would take
///         it again. The second registry is deployed naming the first as `previous` and refuses
///         every root the first reports as revoked: revoked after registration, revoked in
///         advance, registered by a signer whose approvals were killed, and revoked in the first
///         registry after the second took over. A root that was never revoked registers in the
///         second with the attestation it already has. A third registry refuses what either
///         registry before it revoked. The other way to replace the policy, a new verifier and
///         no predecessor, accepts no old attestation at all.
contract MintPolicySuccessorTest is EditionAuctionStack {
    address internal artist;
    address internal collector = makeAddr("policyCollector");

    function setUp() public override {
        super.setUp();
        artist = _actor("policyArtist");
    }

    // ------------------------------------------------------------------ revoked roots

    /// @dev A registered and accepted root is revoked, then the policy is replaced: the same
    ///      attestation does not register it again, and its item does not start.
    function test_MintPolicySuccessor_ARevokedRootStaysRevoked() public {
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _rootOf(works);
        bytes memory attestation = _attestation(root);
        registry.registerPackage(root, _evidence(root), attestation);
        _accept(root, artist);
        _revoke(registry, root);
        bytes memory request = _mintData(root, works, 0);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        auction.start(address(stream), request);

        PackageRegistry old = registry;
        PackageRegistry next = _install(_deploy(address(old)));
        assertEq(next.previous(), address(old));
        assertTrue(old.isRevoked(root));
        assertTrue(next.isRevoked(root));
        _assertStatus(next, root, IPackageRegistry.PackageStatus.REVOKED);

        vm.prank(makeAddr("anyone"));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        next.registerPackage(root, _evidence(root), attestation);
        _assertStatus(next, root, IPackageRegistry.PackageStatus.REVOKED);
        _expectNotAccepted(next, root);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        auction.start(address(stream), request);
    }

    /// @dev A root revoked before anyone registered it (a leaked attestation) does not register
    ///      in the replacement either.
    function test_MintPolicySuccessor_AnAdvanceRevocationIsCarried() public {
        bytes32 root = _rootOf(_one(_work(artist, collectionId)));
        bytes memory leaked = _attestation(root);
        _revoke(registry, root);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageExists.selector, root));
        registry.registerPackage(root, _evidence(root), leaked);

        PackageRegistry next = _install(_deploy(address(registry)));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        next.registerPackage(root, _evidence(root), leaked);
        _assertStatus(next, root, IPackageRegistry.PackageStatus.REVOKED);
    }

    /// @dev The roots a signer registered before its approvals were killed stay stopped under
    ///      the replacement. A root the same signer registers after the kill is not stopped,
    ///      there or here.
    function test_MintPolicySuccessor_KilledSignerApprovalsAreCarried() public {
        bytes32 root = _rootOf(_one(_work(artist, collectionId)));
        bytes memory attestation = _attestation(root);
        registry.registerPackage(root, _evidence(root), attestation);
        _asNetwork(
            address(registry), abi.encodeCall(PackageRegistry.killSignerApprovals, (signer1))
        );
        _assertStatus(registry, root, IPackageRegistry.PackageStatus.REVOKED);
        bytes32 later = _rootOf(_one(_work(artist, collectionId)));
        bytes memory laterAttestation = _attestation(later);
        registry.registerPackage(later, _evidence(later), laterAttestation);
        _assertStatus(registry, later, IPackageRegistry.PackageStatus.APPROVED);

        PackageRegistry next = _install(_deploy(address(registry)));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        next.registerPackage(root, _evidence(root), attestation);
        assertTrue(next.isRevoked(root));
        assertFalse(next.isRevoked(later));
        next.registerPackage(later, _evidence(later), laterAttestation);
        _assertStatus(next, later, IPackageRegistry.PackageStatus.APPROVED);
    }

    /// @dev A master whose root was revoked while its 1/1 ran: neither the genesis edition
    ///      auction nor one wired to the replacement policy opens its edition sale.
    function test_MintPolicySuccessor_ARevokedMastersEditionSaleStaysClosed() public {
        // The network prepares the replacement: the new policy and its edition auction, added
        // as an Editions minter and waited out.
        PackageRegistry old = registry;
        PackageRegistry next = _deploy(address(old));
        registry = next; // `_wiredEditionAuction` wires the lens to `registry`
        UniformEditionAuction nextAuction = _wiredEditionAuction();
        registry = old;
        assertEq(UniformEditionAuctionLens(address(nextAuction)).packageRegistry(), address(next));

        Work memory w = _masterWork(artist, 0);
        Work[] memory works = _one(w);
        bytes32 root = _rootOf(works);
        bytes memory attestation = _attestation(root);
        old.registerPackage(root, _evidence(root), attestation);
        _accept(root, artist);
        (, uint256 tokenId) = _start(root, works, 0);
        _revoke(old, root);
        bytes memory openData = _openData(root, works, 0);
        bytes memory refused = abi.encodeWithSelector(
            ISaleAdapter.InvalidSaleTerms.selector, address(editions), tokenId
        );
        vm.expectRevert(refused);
        editionAuction.open(address(editions), tokenId, openData);

        vm.prank(makeAddr("anyone"));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        next.registerPackage(root, _evidence(root), attestation);
        assertFalse(next.isApprovedItem(root, WorksHashing.itemHash(w.item), _proofOf(works, 0)));
        vm.expectRevert(refused);
        nextAuction.open(address(editions), tokenId, openData);
        assertEq(editions.editionOf(tokenId).minter, address(0), "no edition was opened");
    }

    /// @dev A root registered in both registries and then revoked in the first, after the
    ///      second took over, is stopped in the second too: the second asks the first at each
    ///      use.
    function test_MintPolicySuccessor_ARevocationInTheOldRegistryAfterTheSwapStopsTheRoot() public {
        Work memory w = _masterWork(artist, 0);
        Work[] memory works = _one(w);
        bytes32 root = _rootOf(works);
        bytes memory attestation = _attestation(root);
        PackageRegistry old = registry;
        old.registerPackage(root, _evidence(root), attestation);

        PackageRegistry next = _install(_deploy(address(old)));
        next.registerPackage(root, _evidence(root), attestation);
        _assertStatus(next, root, IPackageRegistry.PackageStatus.APPROVED);
        bytes32 itemHash = WorksHashing.itemHash(w.item);
        assertTrue(next.isApprovedItem(root, itemHash, _proofOf(works, 0)));
        registry = next;
        _accept(root, artist);
        bytes memory request = _mintData(root, works, 0);

        _revoke(old, root);
        _assertStatus(next, root, IPackageRegistry.PackageStatus.REVOKED);
        assertTrue(next.isRevoked(root));
        assertFalse(next.isApprovedItem(root, itemHash, _proofOf(works, 0)));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        auction.start(address(stream), request);
        _expectNotAccepted(next, root);
    }

    // ------------------------------------------------------------------ roots never revoked

    /// @dev A root that was approved and never revoked registers in the replacement with the
    ///      attestation it already has; the artist accepts and signs the move in the new
    ///      registry's domain and the work sells.
    function test_MintPolicySuccessor_APendingRootRegistersWithItsOldAttestation() public {
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _rootOf(works);
        bytes memory attestation = _attestation(root);
        registry.registerPackage(root, _evidence(root), attestation);
        _accept(root, artist);

        PackageRegistry next = _install(_deploy(address(registry)));
        assertFalse(next.isRevoked(root));
        _assertStatus(next, root, IPackageRegistry.PackageStatus.NONE);
        vm.prank(makeAddr("anyone"));
        next.registerPackage(root, _evidence(root), attestation);
        _assertStatus(next, root, IPackageRegistry.PackageStatus.APPROVED);

        registry = next;
        _accept(root, artist);
        nextMoveNonce[accounts.artistIdOf(artist)] = 0;
        uint256 tokenId = _sell(root, works, 0, collector, 1 ether);
        assertEq(stream.ownerOf(tokenId), collector);
    }

    // ------------------------------------------------------------------ a third registry

    /// @dev Two replacements in a row: the third registry refuses a root the first revoked and
    ///      a root the second revoked, and registers a root neither revoked.
    function test_MintPolicySuccessor_AThirdRegistryRefusesWhatEitherBeforeItRevoked() public {
        bytes32 first = _rootOf(_one(_work(artist, collectionId)));
        bytes32 second = _rootOf(_one(_work(artist, collectionId)));
        bytes32 clean = _rootOf(_one(_work(artist, collectionId)));
        PackageRegistry one = registry;
        one.registerPackage(first, _evidence(first), _attestation(first));
        _revoke(one, first);

        PackageRegistry two = _install(_deploy(address(one)));
        registry = two;
        two.registerPackage(second, _evidence(second), _attestation(second));
        _mapRevoke(two);
        _revoke(two, second);

        PackageRegistry three = _install(_deploy(address(two)));
        assertTrue(three.isRevoked(first));
        assertTrue(three.isRevoked(second));
        assertFalse(three.isRevoked(clean));
        bytes memory firstAttestation = _attestation(first);
        bytes memory secondAttestation = _attestation(second);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, first));
        three.registerPackage(first, _evidence(first), firstAttestation);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, second)
        );
        three.registerPackage(second, _evidence(second), secondAttestation);
        three.registerPackage(clean, _evidence(clean), _attestation(clean));
        _assertStatus(three, clean, IPackageRegistry.PackageStatus.APPROVED);

        // A revocation made in the first registry now still reaches the third.
        _revoke(one, clean);
        _assertStatus(three, clean, IPackageRegistry.PackageStatus.REVOKED);
    }

    // ------------------------------------------------------------------ the other way

    /// @dev A replacement with no predecessor and a new verifier: an attestation made for the
    ///      old verifier verifies for no root, revoked or not, so the signers attest again
    ///      what is to carry over.
    function test_MintPolicySuccessor_AFreshVerifierTakesNoOldAttestation() public {
        bytes32 revoked = _rootOf(_one(_work(artist, collectionId)));
        bytes32 pending = _rootOf(_one(_work(artist, collectionId)));
        bytes memory revokedAttestation = _attestation(revoked);
        bytes memory pendingAttestation = _attestation(pending);
        registry.registerPackage(revoked, _evidence(revoked), revokedAttestation);
        registry.registerPackage(pending, _evidence(pending), pendingAttestation);
        _revoke(registry, revoked);

        Eip712CurationVerifier fresh = new Eip712CurationVerifier(address(manager));
        PackageRegistry next = new PackageRegistry(
            address(manager),
            ICurationVerifier(address(fresh)),
            address(fresh).codehash,
            address(directory),
            IEconomicsResolver(address(economics)),
            address(0),
            cc0TextFileId,
            address(0)
        );
        assertEq(next.previous(), address(0));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, revoked));
        next.registerPackage(revoked, _evidence(revoked), revokedAttestation);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, pending));
        next.registerPackage(pending, _evidence(pending), pendingAttestation);

        // The signer attests the pending root again, in the new verifier's domain.
        bytes memory again = abi.encode(
            signer1,
            _sign(
                signer1,
                fresh.approvalDigest(pending, _evidence(pending), fresh.signerEpoch(signer1))
            )
        );
        next.registerPackage(pending, _evidence(pending), again);
        _assertStatus(next, pending, IPackageRegistry.PackageStatus.APPROVED);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev A second `PackageRegistry` with the genesis constructor arguments (so the same
    ///      verifier), naming `replaced` as the policy it replaces, bound to Stream.
    function _deploy(address replaced) internal returns (PackageRegistry next) {
        next = new PackageRegistry(
            address(manager),
            ICurationVerifier(address(verifier)),
            address(verifier).codehash,
            address(directory),
            IEconomicsResolver(address(economics)),
            address(0),
            cc0TextFileId,
            replaced
        );
        _asNetwork(address(next), abi.encodeCall(PackageRegistry.bindStream, (address(stream))));
    }

    /// @dev Makes `next` the accounts module's `register` caller and the English auction's
    ///      6529 Stream policy, each at its role's delay.
    function _install(PackageRegistry next) internal returns (PackageRegistry) {
        _asNetwork(
            address(accounts),
            abi.encodeCall(Accounts.setPackageRegistry, (accounts.packageRegistry(), address(next)))
        );
        _asNetwork(
            address(auction),
            abi.encodeCall(EnglishAuction.setStreamPolicy, (auction.streamPolicy(), address(next)))
        );
        return next;
    }

    /// @dev Maps `revokePackage` of a new registry to the role the genesis registry has it at.
    function _mapRevoke(PackageRegistry next) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PackageRegistry.revokePackage.selector;
        uint64 role = manager.getTargetFunctionRole(
            deployment.packageRegistry, PackageRegistry.revokePackage.selector
        );
        _asNetwork(
            address(manager),
            abi.encodeCall(manager.setTargetFunctionRole, (address(next), selectors, role))
        );
    }

    function _revoke(PackageRegistry where, bytes32 root) internal {
        _asNetwork(
            address(where),
            abi.encodeCall(PackageRegistry.revokePackage, (root, keccak256("revoked")))
        );
    }

    function _attestation(bytes32 root) internal view returns (bytes memory) {
        return abi.encode(
            signer1,
            _sign(
                signer1,
                verifier.approvalDigest(root, _evidence(root), verifier.signerEpoch(signer1))
            )
        );
    }

    function _assertStatus(
        PackageRegistry where,
        bytes32 root,
        IPackageRegistry.PackageStatus expected
    ) internal view {
        (IPackageRegistry.PackageStatus status,,) = where.packageOf(root);
        assertEq(uint8(status), uint8(expected));
    }

    /// @dev The artist's acceptance of `root`, signed in the domain of `where`, is refused: the
    ///      root is not approved there.
    function _expectNotAccepted(PackageRegistry where, bytes32 root) internal {
        PackageRegistry current = registry;
        registry = where;
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        this.accept(root, artist);
        registry = current;
    }

    function accept(bytes32 root, address account) external {
        _accept(root, account);
    }
}
