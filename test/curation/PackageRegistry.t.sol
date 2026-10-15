// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Eip712CurationVerifier } from "src/curation/Eip712CurationVerifier.sol";
import { Roles } from "src/governance/Roles.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { ICurationVerifier } from "src/interfaces/ICurationVerifier.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { PRODUCT_EDITIONS, PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import { CURRENCY_DEFAULT } from "src/interfaces/types/EconomicsTypes.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    EditionFormat,
    ItemKind,
    MoveAuthorization,
    PackageItem,
    Party,
    PartyAcceptance,
    PartyRole,
    SeedPolicy
} from "src/interfaces/types/PackageTypes.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { MockBoundCaller } from "test/mocks/curation/MockBoundCaller.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { DutchParams, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { ERC1271WalletMock } from "test/mocks/AdversarialTargets.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { SignatureReverts } from "test/helpers/SignatureReverts.sol";
import { CurationBase } from "./CurationBase.sol";

/// @dev A verifier that approves every root: code that could take the place of the pinned one.
contract ApproveEverythingVerifier {
    function isApproved(bytes32, bytes32, bytes calldata) external pure returns (bool, address) {
        return (true, address(0xBAD));
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

contract PackageRegistryTest is CurationBase {
    // Golden vectors computed independently with `cast keccak` and `cast abi-encode`.
    bytes32 internal constant GOLDEN_MOVE_TYPEHASH =
        0xe193fedc71b458003faf3a90795989683ea6a572f7cae0f6729d1219894814f8;
    bytes32 internal constant GOLDEN_ACCEPTANCE_TYPEHASH =
        0x557d83fa1b5c5123a734c14182eab668ea8678f09c42986018a05d2be5aa362f;
    address internal constant FIXED_REGISTRY = 0x2000000000000000000000000000000000000002;
    /// @dev `moveDigest(keccak256("root"), keccak256("item"), 7, 1_900_000_000)` at
    ///      FIXED_REGISTRY on chain 31337.
    bytes32 internal constant GOLDEN_MOVE_DIGEST =
        0x327fbd1136cdfe4edd681975e83c7944766d06b9231f85adeeb356f02735bc64;
    /// @dev `acceptanceDigest(keccak256("root"), (0x3333…, keccak256("profile"),
    ///      keccak256("doc"), 1_900_000_000))` at FIXED_REGISTRY on chain 31337.
    bytes32 internal constant GOLDEN_ACCEPTANCE_DIGEST =
        0x9b13406fdd672b692130dd492f58c58aa8626911fb1523fb27750e9e9f2c6760;

    // Declared media SHA-256 values (plain constants: the precompile would consume `vm.prank`).
    bytes32 internal constant SHA_A = keccak256("media A");
    bytes32 internal constant SHA_B = keccak256("media B");

    // ------------------------------------------------------------------- golden vectors

    function test_golden_typehashes() public pure {
        assertEq(Typehashes.MOVE_TO_STREAM, GOLDEN_MOVE_TYPEHASH);
        assertEq(Typehashes.PACKAGE_ACCEPTANCE, GOLDEN_ACCEPTANCE_TYPEHASH);
    }

    function test_golden_digests() public {
        vm.chainId(31337);
        vm.etch(FIXED_REGISTRY, address(registry).code);
        PackageRegistry r = PackageRegistry(FIXED_REGISTRY);
        assertEq(
            r.moveDigest(keccak256("root"), keccak256("item"), 7, 1_900_000_000), GOLDEN_MOVE_DIGEST
        );
        PartyAcceptance memory a = PartyAcceptance(
            0x3333333333333333333333333333333333333333,
            keccak256("profile"),
            keccak256("doc"),
            1_900_000_000
        );
        assertEq(r.acceptanceDigest(keccak256("root"), a), GOLDEN_ACCEPTANCE_DIGEST);
    }

    function test_eip712Domain() public view {
        (, string memory name, string memory version, uint256 chainId, address self,,) =
            registry.eip712Domain();
        assertEq(name, "6529 Works Package Registry");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(self, address(registry));
    }

    // ---------------------------------------------------------------------- constructor

    function test_constructor_wiring() public view {
        assertEq(address(registry.verifier()), address(verifier));
        assertEq(registry.artistRegistry(), address(artists));
        assertEq(registry.authority(), address(manager));
    }

    function test_supportsInterface() public view {
        assertTrue(registry.supportsInterface(type(IERC165).interfaceId));
        assertTrue(registry.supportsInterface(type(IPackageRegistry).interfaceId));
        assertFalse(registry.supportsInterface(0xffffffff));
    }

    function test_constructor_rejectsBadDependencies() public {
        address eoa = makeAddr("eoa");
        ICurationVerifier v = ICurationVerifier(address(verifier));
        bytes32 vh = address(verifier).codehash;
        bytes32 ah = address(artists).codehash;
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new PackageRegistry(address(manager), v, vh, eoa, eoa.codehash);
        // A contract without the artist registry's ERC-165 interface.
        bytes32 wrongHash = address(verifier).codehash;
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(verifier))
        );
        new PackageRegistry(address(manager), v, vh, address(verifier), wrongHash);
        // Code hashes are pinned: the artist registry's and the verifier's.
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(artists))
        );
        new PackageRegistry(address(manager), v, vh, address(artists), keccak256("other"));
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(verifier))
        );
        new PackageRegistry(address(manager), v, keccak256("other"), address(artists), ah);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new PackageRegistry(address(manager), ICurationVerifier(eoa), vh, address(artists), ah);
    }

    function test_constructor_rejectsDelegatedVerifier() public {
        address delegated = makeAddr("7702 account");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(verifier)));
        bytes32 h = delegated.codehash;
        bytes32 ah = address(artists).codehash;
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, delegated));
        new PackageRegistry(address(manager), ICurationVerifier(delegated), h, address(artists), ah);
    }

    // -------------------------------------------------------------------- caller binding

    bytes32 internal constant STREAM_NAME = "STREAM";
    bytes32 internal constant EDITIONS_NAME = "EDITIONS";

    function test_bindStream_once() public {
        assertEq(registry.stream(), stream);
        PackageRegistry fresh = _newRegistry();
        address s2 = address(new MockBoundCaller(type(IStream).interfaceId));
        vm.expectEmit(address(fresh));
        emit IPackageRegistry.Bound(STREAM_NAME, s2);
        vm.prank(admin);
        fresh.bindStream(s2);
        assertEq(fresh.stream(), s2);
        assertEq(fresh.editions(), address(0)); // bound independently
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.AlreadyBound.selector, STREAM_NAME));
        fresh.bindStream(stream);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.AlreadyBound.selector, STREAM_NAME));
        registry.bindStream(s2);
    }

    function test_bindEditions_onceAndLater() public {
        assertEq(registry.editions(), editions);
        PackageRegistry fresh = _newRegistry();
        vm.prank(admin);
        fresh.bindStream(stream);
        // Editions deploys later and is bound on its own.
        address e2 = address(new MockBoundCaller(type(IEditions).interfaceId));
        vm.expectEmit(address(fresh));
        emit IPackageRegistry.Bound(EDITIONS_NAME, e2);
        vm.prank(admin);
        fresh.bindEditions(e2);
        assertEq(fresh.editions(), e2);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.AlreadyBound.selector, EDITIONS_NAME)
        );
        fresh.bindEditions(editions);
    }

    /// @dev Review PoC 4, inverted: a binding must answer ERC-165 for the bound role, so a wrong
    ///      address cannot be bound forever by mistake.
    function test_bind_rejectsContractsWithoutTheInterface() public {
        PackageRegistry fresh = _newRegistry();
        address[3] memory notStreams = [address(verifier), editions, address(artists)];
        for (uint256 i; i < notStreams.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(
                abi.encodeWithSelector(Dependency.InvalidDependency.selector, notStreams[i])
            );
            fresh.bindStream(notStreams[i]);
        }
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stream));
        fresh.bindEditions(stream);
        assertEq(fresh.stream(), address(0));
        assertEq(fresh.editions(), address(0));
    }

    function test_bind_governedAndContractsOnly() public {
        PackageRegistry fresh = _newRegistry();
        bytes memory unauthorized =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian);
        vm.prank(guardian);
        vm.expectRevert(unauthorized);
        fresh.bindStream(stream);
        vm.prank(guardian);
        vm.expectRevert(unauthorized);
        fresh.bindEditions(editions);
        address eoa = makeAddr("eoa");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        fresh.bindStream(eoa);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        fresh.bindEditions(eoa);
        address delegated = makeAddr("7702 account");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", stream));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, delegated));
        fresh.bindStream(delegated);
    }

    function test_unboundRegistryRefusesEveryone() public {
        PackageRegistry fresh = _newRegistry();
        vm.prank(editions);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.UnboundCaller.selector, editions));
        fresh.claimContent(bytes32(0), bytes32(0));
        PackageItem memory item;
        MoveAuthorization memory move;
        vm.prank(stream);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.UnboundCaller.selector, stream));
        fresh.consume(bytes32(0), item, new bytes32[](0), move);
    }

    // ------------------------------------------------------------------ registerPackage

    function test_registerPackage() public {
        bytes32 root = keccak256("root");
        vm.expectEmit(address(registry));
        emit IPackageRegistry.PackageRegistered(root, EVIDENCE, address(verifier), signer1);
        _register(root);
        (IPackageRegistry.PackageStatus status, bytes32 evidence, address signer) =
            registry.packageOf(root);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.APPROVED));
        assertEq(evidence, EVIDENCE);
        assertEq(signer, signer1);
    }

    function test_registerPackage_permissionless() public {
        bytes32 root = keccak256("root");
        bytes memory att = _attestation(signerKey2, root, EVIDENCE);
        vm.prank(makeAddr("anyone"));
        registry.registerPackage(root, EVIDENCE, att);
        (IPackageRegistry.PackageStatus status,, address signer) = registry.packageOf(root);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.APPROVED));
        assertEq(signer, signer2);
    }

    function test_registerPackage_revertsNotApproved() public {
        bytes32 root = keccak256("root");
        bytes memory wrongEvidence = _attestation(signerKey1, root, keccak256("other"));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, root));
        registry.registerPackage(root, EVIDENCE, wrongEvidence);
        bytes memory outsider = _attestation(0xBAD, root, EVIDENCE);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, root));
        registry.registerPackage(root, EVIDENCE, outsider);
    }

    function test_registerPackage_revertsZeroEvidence() public {
        bytes32 root = keccak256("root");
        bytes memory att = _attestation(signerKey1, root, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, root));
        registry.registerPackage(root, bytes32(0), att);
    }

    function test_registerPackage_revertsAfterSignerDisabled() public {
        bytes32 root = keccak256("root");
        bytes memory att = _attestation(signerKey1, root, EVIDENCE);
        vm.prank(guardian);
        verifier.disableSigner(signer1);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, root));
        registry.registerPackage(root, EVIDENCE, att);
    }

    function test_registerPackage_onceOnly() public {
        bytes32 root = keccak256("root");
        _register(root);
        bytes memory att = _attestation(signerKey2, root, keccak256("new evidence"));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageExists.selector, root));
        registry.registerPackage(root, keccak256("new evidence"), att);
        // A revoked root cannot come back either.
        vm.prank(guardian);
        registry.revokePackage(root, 0);
        bytes memory again = _attestation(signerKey1, root, EVIDENCE);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageExists.selector, root));
        registry.registerPackage(root, EVIDENCE, again);
    }

    // -------------------------------------------------------------------- revokePackage

    function test_revokePackage_blocksUnconsumedItems() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        vm.expectEmit(address(registry));
        emit IPackageRegistry.PackageRevoked(root, keccak256("reason"));
        vm.prank(guardian);
        registry.revokePackage(root, keccak256("reason"));
        (IPackageRegistry.PackageStatus status,,) = registry.packageOf(root);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.REVOKED));
        vm.prank(stream);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        registry.consume(root, item, new bytes32[](0), move);
        PartyAcceptance memory a = _acceptance(collab);
        bytes memory sig = _sig(collabKey, registry.acceptanceDigest(root, a));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        registry.acceptPackage(root, a, sig);
    }

    function test_revokePackage_onlyGuardian() public {
        bytes32 root = keccak256("root");
        _register(root);
        address[3] memory callers = [admin, successor, stream];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManaged.AccessManagedUnauthorized.selector, callers[i]
                )
            );
            registry.revokePackage(root, 0);
        }
    }

    /// @dev Review PoC 2, inverted: the guardian can revoke a root before anyone registers it
    ///      (a leaked attestation), and the root can then never be registered or used.
    function test_revokePackage_inAdvance() public {
        PackageItem memory item = _item(lead, SHA_A);
        bytes32 root = WorksHashing.leaf(_hash(item));
        vm.expectEmit(address(registry));
        emit IPackageRegistry.PackageRevoked(root, keccak256("leaked attestation"));
        vm.prank(guardian);
        registry.revokePackage(root, keccak256("leaked attestation"));
        (IPackageRegistry.PackageStatus status,,) = registry.packageOf(root);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.REVOKED));
        bytes memory att = _attestation(signerKey1, root, EVIDENCE);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageExists.selector, root));
        registry.registerPackage(root, EVIDENCE, att);
        PartyAcceptance memory a = _acceptance(lead);
        bytes memory sig = _sig(leadKey, registry.acceptanceDigest(root, a));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        registry.acceptPackage(root, a, sig);
    }

    function test_revokePackage_revertsOnlyWhenRevoked() public {
        bytes32 root = keccak256("root");
        _register(root);
        vm.prank(guardian);
        registry.revokePackage(root, 0);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        registry.revokePackage(root, 0);
    }

    /// @dev Review PoC 7, kept as documented behaviour: revocation is per root, not per item, so
    ///      the guardian revokes every root that lists a bad item.
    function test_revokePackage_isPerRoot() public {
        PackageItem memory item = _item(lead, SHA_A);
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = WorksHashing.leaf(_hash(item));
        leaves[1] = keccak256("other leaf");
        bytes32 single = leaves[0];
        bytes32 pair = _root(leaves);
        _register(single);
        _register(pair);
        _accept(single, leadKey);
        _accept(pair, leadKey);
        vm.prank(guardian);
        registry.revokePackage(single, keccak256("bad item"));
        bytes32[] memory proof = _proof(leaves, 0);
        _consume(pair, item, proof, _move(leadKey, pair, _hash(item), 0));
        assertEq(registry.consumedItemOf(SHA_A), _hash(item));
    }

    /// @dev Review PoC 3, kept as documented behaviour: disabling a signer stops future
    ///      registrations only; its registered roots are withdrawn with `revokePackage`.
    function test_disabledSigner_registeredRootsStayUsable() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        vm.prank(guardian);
        verifier.disableSigner(signer1);
        (,, address signer) = registry.packageOf(root);
        assertEq(signer, signer1);
        _consume(root, item, new bytes32[](0), move);
        assertEq(registry.consumedItemOf(SHA_A), _hash(item));
    }

    // -------------------------------------------------------------------- acceptPackage

    function test_acceptPackage_createsIdentity() public {
        bytes32 root = keccak256("root");
        _register(root);
        vm.expectEmit(address(registry));
        emit IPackageRegistry.PackageAccepted(root, _id(lead), lead);
        uint256 id = _accept(root, leadKey);
        assertEq(id, _id(lead));
        assertEq(artists.artistIdOf(lead), _id(lead));
        assertEq(registry.acceptedAs(root, lead), id);
        assertEq(artists.registrations(), 1);
    }

    /// @dev Only a first acceptance (which creates the identity) counts as activity.
    function test_acceptPackage_laterAcceptancesAreNotActivity() public {
        bytes32 root1 = keccak256("root1");
        bytes32 root2 = keccak256("root2");
        _register(root1);
        _register(root2);
        _accept(root1, leadKey);
        uint64 first = artists.lastActivity(_id(lead));
        vm.warp(block.timestamp + 100 days);
        deadline = uint64(block.timestamp + 1 days);
        _accept(root2, leadKey);
        assertEq(registry.acceptedAs(root2, lead), _id(lead));
        assertEq(artists.registrations(), 1);
        assertEq(artists.lastActivity(_id(lead)), first);
    }

    function test_acceptPackage_replayIsNoop() public {
        bytes32 root = keccak256("root");
        _register(root);
        PartyAcceptance memory a = _acceptance(lead);
        bytes memory sig = _sig(leadKey, registry.acceptanceDigest(root, a));
        registry.acceptPackage(root, a, sig);
        vm.recordLogs();
        assertEq(registry.acceptPackage(root, a, sig), _id(lead));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(artists.registrations(), 1);
    }

    function test_acceptPackage_afterRecoverySignedByNewAuthority() public {
        bytes32 root = keccak256("root");
        _register(root);
        _accept(keccak256("unrelated"), leadKey, true);
        uint256 newKey = 0xA9;
        artists.recover(_id(lead), vm.addr(newKey));
        // The old address still names the identity, but only the new authority can sign.
        PartyAcceptance memory a = _acceptance(lead);
        bytes32 digest = registry.acceptanceDigest(root, a);
        vm.expectRevert(SignatureReverts.invalid(vm.addr(newKey)));
        registry.acceptPackage(root, a, _sig(leadKey, digest));
        assertEq(registry.acceptPackage(root, a, _sig(newKey, digest)), _id(lead));
    }

    function test_acceptPackage_erc1271Authority() public {
        bytes32 root = keccak256("root");
        _register(root);
        ERC1271WalletMock safe = new ERC1271WalletMock(lead);
        PartyAcceptance memory a = _acceptance(address(safe));
        bytes memory sig = _sig(leadKey, registry.acceptanceDigest(root, a));
        assertEq(registry.acceptPackage(root, a, sig), _id(address(safe)));
    }

    function test_acceptPackage_revertsProfileMismatch() public {
        bytes32 root = keccak256("root");
        _register(root);
        _accept(keccak256("unrelated"), leadKey, true);
        artists.setProfile(_id(lead), keccak256("new profile"), keccak256("new doc"));
        PartyAcceptance memory a = _acceptance(lead);
        bytes memory sig = _sig(leadKey, registry.acceptanceDigest(root, a));
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.ProfileMismatch.selector, _id(lead))
        );
        registry.acceptPackage(root, a, sig);
    }

    /// @dev Review PoC 6, kept as documented behaviour: the first acceptance relayed sets the
    ///      identity's profile, so a second pre-signed acceptance with other profile fields fails.
    function test_acceptPackage_relayOrderPicksProfile() public {
        bytes32 r1 = keccak256("r1");
        bytes32 r2 = keccak256("r2");
        _register(r1);
        _register(r2);
        PartyAcceptance memory a1 =
            PartyAcceptance(lead, keccak256("p"), keccak256("doc v1"), deadline);
        PartyAcceptance memory a2 =
            PartyAcceptance(lead, keccak256("p"), keccak256("doc v2"), deadline);
        bytes memory s1 = _sig(leadKey, registry.acceptanceDigest(r1, a1));
        bytes memory s2 = _sig(leadKey, registry.acceptanceDigest(r2, a2));
        registry.acceptPackage(r1, a1, s1);
        (ArtistIdentity memory identity,) = artists.artist(_id(lead));
        assertEq(identity.profileDocHash, keccak256("doc v1"));
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.ProfileMismatch.selector, _id(lead))
        );
        registry.acceptPackage(r2, a2, s2);
    }

    function test_acceptPackage_revertsBadSignature() public {
        bytes32 root = keccak256("root");
        _register(root);
        PartyAcceptance memory a = _acceptance(lead);
        bytes32 digest = registry.acceptanceDigest(root, a);
        bytes memory wrongKey = _sig(collabKey, digest);
        bytes memory malleable = _highS(leadKey, digest);
        vm.expectRevert(SignatureReverts.invalid(lead));
        registry.acceptPackage(root, a, wrongKey);
        vm.expectRevert(SignatureReverts.invalid(lead));
        registry.acceptPackage(root, a, malleable);
        // Bound to the root: a signature for another root does not transfer.
        bytes32 other = keccak256("other root");
        _register(other);
        vm.expectRevert(SignatureReverts.invalid(lead));
        registry.acceptPackage(other, a, _sig(leadKey, digest));
        // The zero account never signs.
        a.account = address(0);
        bytes memory zeroSig = _sig(leadKey, registry.acceptanceDigest(root, a));
        vm.expectRevert(SignatureReverts.invalid(address(0)));
        registry.acceptPackage(root, a, zeroSig);
    }

    function test_acceptPackage_revertsExpired() public {
        bytes32 root = keccak256("root");
        _register(root);
        PartyAcceptance memory a = _acceptance(lead);
        bytes memory sig = _sig(leadKey, registry.acceptanceDigest(root, a));
        vm.warp(uint256(a.deadline) + 1);
        vm.expectRevert(SignatureReverts.expired(a.deadline));
        registry.acceptPackage(root, a, sig);
    }

    function test_acceptPackage_revertsUnknownPackage() public {
        bytes32 root = keccak256("root");
        PartyAcceptance memory a = _acceptance(lead);
        bytes memory sig = _sig(leadKey, registry.acceptanceDigest(root, a));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        registry.acceptPackage(root, a, sig);
    }

    function test_acceptPackage_revertsWrongChain() public {
        bytes32 root = keccak256("root");
        _register(root);
        PartyAcceptance memory a = _acceptance(lead);
        bytes memory sig = _sig(leadKey, registry.acceptanceDigest(root, a));
        vm.chainId(block.chainid + 1);
        vm.expectRevert(SignatureReverts.invalid(lead));
        registry.acceptPackage(root, a, sig);
    }

    // -------------------------------------------------------------------------- consume

    function test_consume() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        bytes32 itemHash = _hash(item);
        vm.expectEmit(address(registry));
        emit IPackageRegistry.ItemConsumed(root, itemHash, _id(lead), SHA_A);
        (bytes32 h, uint256 artistId) = _consume(root, item, new bytes32[](0), move);
        assertEq(h, itemHash);
        assertEq(artistId, _id(lead));
        assertEq(registry.consumedItemOf(SHA_A), itemHash);
        assertEq(registry.editionClaimOf(SHA_A), bytes32(0));
        assertTrue(registry.isMoveNonceUsed(_id(lead), 0));
        assertFalse(registry.isMoveNonceUsed(_id(lead), 1));
    }

    /// @dev The registry hashes the item from calldata (`WorksHashing.itemHashCalldata`);
    ///      whatever the dynamic fields hold, the result is `WorksHashing.itemHash`.
    function testFuzz_consume_itemHashMatchesWorksHashing(
        uint256 collectionId,
        bytes32 mediaHash,
        string calldata spdxId,
        bytes calldata saleParams,
        bytes32 seed
    ) public {
        vm.assume(seed != 0);
        PackageItem memory item = _item(lead, SHA_A);
        item.collectionId = collectionId;
        item.mediaHash = mediaHash;
        item.license.spdxId = spdxId;
        item.sale.params = saleParams;
        item.seedPolicy = SeedPolicy.ARTIST;
        item.seed = seed;
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        _accept(root, leadKey);
        (bytes32 h,) = _consume(root, item, new bytes32[](0), _move(leadKey, root, _hash(item), 0));
        assertEq(h, WorksHashing.itemHash(item));
    }

    function test_consume_masterWithCollaborator() public {
        PackageItem memory item = _masterItem(SHA_A);
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        _accept(root, leadKey);
        _accept(root, collabKey);
        (, uint256 artistId) =
            _consume(root, item, new bytes32[](0), _move(leadKey, root, _hash(item), 9));
        assertEq(artistId, _id(lead));
    }

    function test_consume_revertsMissingCollaboratorAcceptance() public {
        PackageItem memory item = _masterItem(SHA_A);
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        _accept(root, leadKey);
        MoveAuthorization memory move = _move(leadKey, root, _hash(item), 0);
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.PartyNotAccepted.selector, root, collab)
        );
        registry.consume(root, item, new bytes32[](0), move);
        // The collaborator accepted a different package: still not this one.
        _accept(keccak256("unrelated"), collabKey, true);
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.PartyNotAccepted.selector, root, collab)
        );
        registry.consume(root, item, new bytes32[](0), move);
    }

    function test_consume_onlyBoundStream() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        address[4] memory callers = [admin, guardian, lead, editions];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IPackageRegistry.UnboundCaller.selector, callers[i])
            );
            registry.consume(root, item, new bytes32[](0), move);
        }
    }

    function test_consume_revertsDoubleConsume() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        _consume(root, item, new bytes32[](0), move);
        MoveAuthorization memory fresh = _move(leadKey, root, _hash(item), 1);
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ContentUsed.selector, PRODUCT_STREAM, SHA_A, _hash(item)
            )
        );
        registry.consume(root, item, new bytes32[](0), fresh);
    }

    function test_consume_itemIsSingleUseAcrossPackages() public {
        // The same item listed in two approved packages still mints once.
        PackageItem memory item = _item(lead, SHA_A);
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = WorksHashing.leaf(_hash(item));
        leaves[1] = keccak256("another leaf");
        bytes32 rootA = leaves[0];
        bytes32 rootB = _root(leaves);
        _register(rootA);
        _register(rootB);
        _accept(rootA, leadKey);
        _accept(rootB, leadKey);
        _consume(rootA, item, new bytes32[](0), _move(leadKey, rootA, _hash(item), 0));
        MoveAuthorization memory move = _move(leadKey, rootB, _hash(item), 1);
        bytes32[] memory proof = _proof(leaves, 0);
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ContentUsed.selector, PRODUCT_STREAM, SHA_A, _hash(item)
            )
        );
        registry.consume(rootB, item, proof, move);
    }

    /// @dev Two different items declaring the same content hash (other media lists and record
    ///      files): 6529 Stream rejects the second.
    function test_consume_contentUniquenessKeysOnContentHash() public {
        PackageItem[] memory items = new PackageItem[](2);
        items[0] = _item(lead, SHA_A);
        items[1] = _item(collab, SHA_A);
        items[1].mediaHash = keccak256("the same primary media, other files");
        assertTrue(_hash(items[0]) != _hash(items[1]));
        (bytes32 root, bytes32[][] memory proofs) = _tree(items);
        _register(root);
        _accept(root, leadKey);
        _accept(root, collabKey);
        _consume(root, items[0], proofs[0], _move(leadKey, root, _hash(items[0]), 0));
        MoveAuthorization memory move = _move(collabKey, root, _hash(items[1]), 0);
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ContentUsed.selector, PRODUCT_STREAM, SHA_A, _hash(items[0])
            )
        );
        registry.consume(root, items[1], proofs[1], move);
        assertEq(registry.consumedItemOf(SHA_A), _hash(items[0]));
    }

    function test_consume_revertsItemNotInPackage() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        item.collectionId = 2; // any field change is another item
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.ItemNotInPackage.selector, root, _hash(item))
        );
        registry.consume(root, item, new bytes32[](0), move);
    }

    /// @dev A *valid* proof one level deeper than the cap is refused; at the cap it consumes.
    function test_consume_proofLengthCap() public {
        uint256 cap = Limits.MAX_PROOF_DEPTH;
        PackageItem memory item = _item(lead, SHA_A);
        (bytes32 deepRoot, bytes32[] memory deep) = _deepProof(item, cap + 1);
        _register(deepRoot);
        _accept(deepRoot, leadKey);
        MoveAuthorization memory move = _move(leadKey, deepRoot, _hash(item), 0);
        assertTrue(MerkleProof.verify(deep, deepRoot, WorksHashing.leaf(_hash(item))));
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ItemNotInPackage.selector, deepRoot, _hash(item)
            )
        );
        registry.consume(deepRoot, item, deep, move);
        (bytes32 root, bytes32[] memory atCap) = _deepProof(item, cap);
        _register(root);
        _accept(root, leadKey);
        _consume(root, item, atCap, _move(leadKey, root, _hash(item), 1));
        assertEq(registry.consumedItemOf(SHA_A), _hash(item));
    }

    /// @dev A valid proof of `depth` siblings for `item`, and the root it folds to.
    function _deepProof(PackageItem memory item, uint256 depth)
        internal
        pure
        returns (bytes32 root, bytes32[] memory proof)
    {
        proof = new bytes32[](depth);
        root = WorksHashing.leaf(_hash(item));
        for (uint256 i; i < depth; ++i) {
            proof[i] = keccak256(abi.encode("sibling", depth, i));
            (bytes32 a, bytes32 b) = root < proof[i] ? (root, proof[i]) : (proof[i], root);
            root = keccak256(abi.encode(a, b));
        }
    }

    // ------------------------------------------------------------- consume: move signature

    function test_move_revertsExpired() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        vm.warp(uint256(move.deadline) + 1);
        vm.prank(stream);
        vm.expectRevert(SignatureReverts.expired(move.deadline));
        registry.consume(root, item, new bytes32[](0), move);
    }

    function test_move_validAtDeadline() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        vm.warp(move.deadline);
        _consume(root, item, new bytes32[](0), move);
    }

    function test_move_revertsWrongSigner() public {
        (bytes32 root, PackageItem memory item,) = _ready(SHA_A);
        MoveAuthorization memory move = _move(collabKey, root, _hash(item), 0);
        vm.prank(stream);
        vm.expectRevert(SignatureReverts.invalid(lead));
        registry.consume(root, item, new bytes32[](0), move);
    }

    function test_move_revertsMalleableHighS() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        move.signature = _highS(leadKey, registry.moveDigest(root, _hash(item), 0, deadline));
        vm.prank(stream);
        vm.expectRevert(SignatureReverts.invalid(lead));
        registry.consume(root, item, new bytes32[](0), move);
    }

    function test_move_revertsWrongChain() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        vm.chainId(block.chainid + 1);
        vm.prank(stream);
        vm.expectRevert(SignatureReverts.invalid(lead));
        registry.consume(root, item, new bytes32[](0), move);
    }

    function test_move_revertsOtherRegistryDeployment() public {
        (bytes32 root, PackageItem memory item,) = _ready(SHA_A);
        PackageRegistry other = _newRegistry();
        bytes memory foreign = _sig(leadKey, other.moveDigest(root, _hash(item), 0, deadline));
        vm.prank(stream);
        vm.expectRevert(SignatureReverts.invalid(lead));
        registry.consume(root, item, new bytes32[](0), MoveAuthorization(0, deadline, foreign));
    }

    function test_move_bindsItem() public {
        PackageItem[] memory items = new PackageItem[](2);
        items[0] = _item(lead, SHA_A);
        items[1] = _item(lead, SHA_B);
        (bytes32 root, bytes32[][] memory proofs) = _tree(items);
        _register(root);
        _accept(root, leadKey);
        MoveAuthorization memory moveFor0 = _move(leadKey, root, _hash(items[0]), 0);
        vm.prank(stream);
        vm.expectRevert(SignatureReverts.invalid(lead));
        registry.consume(root, items[1], proofs[1], moveFor0);
    }

    function test_move_signedByCurrentAuthorityAfterRecovery() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory oldMove) = _ready(SHA_A);
        uint256 newKey = 0xA9;
        artists.recover(_id(lead), vm.addr(newKey));
        vm.prank(stream);
        vm.expectRevert(SignatureReverts.invalid(vm.addr(newKey)));
        registry.consume(root, item, new bytes32[](0), oldMove);
        _consume(root, item, new bytes32[](0), _move(newKey, root, _hash(item), 0));
    }

    function test_move_erc1271Authority() public {
        ERC1271WalletMock safe = new ERC1271WalletMock(lead);
        PackageItem memory item = _item(address(safe), SHA_A);
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        PartyAcceptance memory a = _acceptance(address(safe));
        registry.acceptPackage(root, a, _sig(leadKey, registry.acceptanceDigest(root, a)));
        _consume(root, item, new bytes32[](0), _move(leadKey, root, _hash(item), 0));
        assertEq(registry.consumedItemOf(item.contentHash), _hash(item));
    }

    /// @dev Replay protection keys on the nonce, not the signature bytes: once nonce 0 is spent
    ///      by the 64-byte form, the 65-byte form of the same signature is dead too.
    function test_move_nonceSpentWhateverTheSignatureForm() public {
        PackageItem[] memory items = new PackageItem[](2);
        items[0] = _item(lead, SHA_A);
        items[1] = _item(lead, SHA_B);
        (bytes32 root, bytes32[][] memory proofs) = _tree(items);
        _register(root);
        _accept(root, leadKey);
        // One nonce authorizes two items (the artist signed both with nonce 5).
        bytes32 d0 = registry.moveDigest(root, _hash(items[0]), 5, deadline);
        bytes32 d1 = registry.moveDigest(root, _hash(items[1]), 5, deadline);
        _consume(root, items[0], proofs[0], MoveAuthorization(5, deadline, _compact(leadKey, d0)));
        MoveAuthorization memory second = MoveAuthorization(5, deadline, _sig(leadKey, d1));
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.MoveNonceUsed.selector, _id(lead), 5)
        );
        registry.consume(root, items[1], proofs[1], second);
    }

    // ----------------------------------------------------------------------- revokeMove

    function test_revokeMove_beforeUse() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        vm.expectEmit(address(registry));
        emit IPackageRegistry.MoveRevoked(_id(lead), 0);
        vm.prank(lead);
        registry.revokeMove(_id(lead), 0);
        assertTrue(registry.isMoveNonceUsed(_id(lead), 0));
        // Neither form of the signature works any more.
        bytes32 digest = registry.moveDigest(root, _hash(item), 0, deadline);
        MoveAuthorization memory compact = MoveAuthorization(0, deadline, _compact(leadKey, digest));
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.MoveNonceUsed.selector, _id(lead), 0)
        );
        registry.consume(root, item, new bytes32[](0), move);
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.MoveNonceUsed.selector, _id(lead), 0)
        );
        registry.consume(root, item, new bytes32[](0), compact);
        // A fresh nonce still works.
        _consume(root, item, new bytes32[](0), _move(leadKey, root, _hash(item), 1));
    }

    function test_revokeMove_onlyCurrentAuthority() public {
        _ready(SHA_A);
        vm.prank(collab);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.NotAuthority.selector, _id(lead), collab)
        );
        registry.revokeMove(_id(lead), 0);
        address next = makeAddr("next authority");
        artists.recover(_id(lead), next);
        vm.prank(lead);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.NotAuthority.selector, _id(lead), lead)
        );
        registry.revokeMove(_id(lead), 0);
        vm.prank(next);
        registry.revokeMove(_id(lead), 0);
    }

    function test_revokeMove_revertsWhenUsedOrRevoked() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        _consume(root, item, new bytes32[](0), move);
        vm.prank(lead);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.MoveNonceUsed.selector, _id(lead), 0)
        );
        registry.revokeMove(_id(lead), 0);
        vm.prank(lead);
        registry.revokeMove(_id(lead), 300);
        vm.prank(lead);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.MoveNonceUsed.selector, _id(lead), 300)
        );
        registry.revokeMove(_id(lead), 300);
    }

    function testFuzz_revokeMove_bitmapIsolation(uint256 a, uint256 b) public {
        vm.assume(a != b);
        _ready(SHA_A);
        vm.prank(lead);
        registry.revokeMove(_id(lead), a);
        assertTrue(registry.isMoveNonceUsed(_id(lead), a));
        assertFalse(registry.isMoveNonceUsed(_id(lead), b));
        assertFalse(registry.isMoveNonceUsed(_id(collab), a));
    }

    // ------------------------------------------------------------------ item validation

    function test_invalidItem_seedPolicy() public {
        PackageItem memory item = _item(lead, SHA_A);
        item.seed = keccak256("seed"); // seed without SeedPolicy.ARTIST
        _expectInvalid(item, _keys(leadKey));
        item.seedPolicy = SeedPolicy.ARTIST;
        item.seed = 0; // ARTIST policy without a seed
        _expectInvalid(item, _keys(leadKey));
        item.seedPolicy = SeedPolicy.VRF;
        item.seed = keccak256("seed");
        _expectInvalid(item, _keys(leadKey));
    }

    function test_invalidItem_zeroContentHash() public {
        _expectInvalid(_item(lead, bytes32(0)), _keys(leadKey));
    }

    function test_invalidItem_originalWithEditionTerms() public {
        PackageItem memory item = _item(lead, SHA_A);
        item.edition.size = 1;
        _expectInvalid(item, _keys(leadKey));
        item.edition.size = 0;
        item.edition.params = hex"01";
        _expectInvalid(item, _keys(leadKey));
        item.edition.params = "";
        item.edition.format = EditionFormat.OPEN;
        _expectInvalid(item, _keys(leadKey));
    }

    function test_invalidItem_masterEditionTerms() public {
        PackageItem memory item = _masterItem(SHA_A);
        item.edition.saleKind = 0;
        _expectInvalid(item, _keys(leadKey, collabKey));
        item = _masterItem(item.contentHash);
        item.edition.size = 0; // a fixed edition of nothing
        _expectInvalid(item, _keys(leadKey, collabKey));
        item = _masterItem(item.contentHash);
        item.edition.window = 1 days; // a fixed edition has no window
        _expectInvalid(item, _keys(leadKey, collabKey));
        item = _masterItem(item.contentHash);
        item.edition.format = EditionFormat.OPEN; // an open edition needs a window
        _expectInvalid(item, _keys(leadKey, collabKey));
        item.edition.window = 1 days;
        _expectValid(item, _keys(leadKey, collabKey));
    }

    /// @dev A priced edition must name its currency: `CURRENCY_DEFAULT` only with a zero price.
    function test_invalidItem_pricedEditionInDefaultCurrency() public {
        PackageItem memory item = _masterItem(SHA_A);
        item.edition.currency = CURRENCY_DEFAULT;
        _expectInvalid(item, _keys(leadKey, collabKey));
        item.edition.price = 0;
        _expectValid(item, _keys(leadKey, collabKey));
    }

    /// @dev The registry applies the same edition-terms rule as 6529 Editions
    ///      (`EditionRules.isValid`), so a master whose edition could never be created, or never
    ///      be sold by its Dutch adapter, is refused at `consume`, before it can mint.
    function test_invalidItem_masterEditionTermsSharedRule() public {
        uint256[] memory keys = _keys(leadKey, collabKey);
        PackageItem memory item = _masterItem(SHA_A);
        item.edition.saleKind = SaleKind.ENGLISH_AUCTION; // no edition adapter sells it
        _expectInvalid(item, keys);
        item = _masterItem(SHA_A);
        item.edition.saleKind = keccak256("RAFFLE");
        _expectInvalid(item, keys);
        item = _masterItem(SHA_A);
        item.edition.params = hex"01"; // fixed price takes no params
        _expectInvalid(item, keys);

        item = _masterItem(SHA_A);
        item.edition.saleKind = SaleKind.DUTCH;
        item.edition.params = abi.encode(DutchParams(0.02 ether, 1 hours, 0)); // rests above start
        _expectInvalid(item, keys);
        item.edition.params = abi.encode(DutchParams(0.001 ether, 0, 0)); // falls with no duration
        _expectInvalid(item, keys);
        item.edition.params = abi.encode(DutchParams(0.001 ether, 100, 7)); // steps do not divide
        _expectInvalid(item, keys);
        item.edition.params = abi.encode(uint256(0), uint256(1) << 64, uint256(0)); // not a uint64
        _expectInvalid(item, keys);
        item.edition.params = abi.encode(DutchParams(0.001 ether, 100, 10));
        _expectValid(item, keys);
    }

    function test_invalidItem_parties() public {
        PackageItem memory item = _item(lead, SHA_A);
        item.parties = new Party[](0);
        _expectInvalid(item, _keys(leadKey));
        item = _masterItem(item.contentHash);
        item.parties[0].role = PartyRole.COLLABORATOR; // the lead must be an ARTIST
        _expectInvalid(item, _keys(leadKey, collabKey));
        item = _masterItem(item.contentHash);
        item.parties[1] = Party(lead, PartyRole.COLLABORATOR); // listed twice
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(_id(lead), address(0), 100_000);
        _expectInvalid(item, _keys(leadKey));
    }

    function test_invalidItem_sameArtistUnderTwoAccounts() public {
        PackageItem memory item = _item(lead, SHA_A);
        bytes32 root0 = keccak256("first");
        _register(root0);
        _accept(root0, leadKey);
        address next = vm.addr(0xA9);
        artists.recover(_id(lead), next);
        item.parties = new Party[](2);
        item.parties[0] = Party(lead, PartyRole.ARTIST);
        item.parties[1] = Party(next, PartyRole.ARTIST);
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        // Each account accepts (signed by the current authority); both resolve to one artist.
        _acceptAs(root, lead, 0xA9);
        _acceptAs(root, next, 0xA9);
        assertEq(registry.acceptedAs(root, next), _id(lead));
        _consumeExpectInvalid(root, item, 0xA9);
    }

    function test_invalidItem_tooManyParties() public {
        PackageItem memory item = _item(lead, SHA_A);
        item.parties = new Party[](17);
        for (uint256 i; i < 17; ++i) {
            item.parties[i] = Party(vm.addr(0x100 + i), PartyRole.ARTIST);
        }
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        _consumeExpectInvalid(root, item, 0x100);
    }

    function test_invalidItem_payees() public {
        bytes32 c = SHA_A;
        uint256[] memory keys = _keys(leadKey, collabKey);
        // Shares do not sum to 100,000.
        PackageItem memory item = _masterItem(c);
        item.payees[0].share = 19_999;
        _expectInvalid(item, keys);
        // A zero share.
        item = _masterItem(c);
        item.payees[0].share = 0;
        item.payees[1].share = 100_000;
        _expectInvalid(item, keys);
        // Both an artist ID and an account.
        item = _masterItem(c);
        item.payees[0].artistId = _id(collab);
        _expectInvalid(item, keys);
        // Neither.
        item = _masterItem(c);
        item.payees[0].account = address(0);
        _expectInvalid(item, keys);
        // Not canonical: artist-resolved before fixed.
        item = _masterItem(c);
        (item.payees[0], item.payees[1]) = (item.payees[1], item.payees[0]);
        _expectInvalid(item, keys);
        // A fixed payee who is not a party.
        item = _masterItem(c);
        item.payees[0].account = makeAddr("stranger");
        _expectInvalid(item, keys);
        // An artist-resolved payee who is not a party.
        item = _masterItem(c);
        item.payees[1].artistId = _id(makeAddr("stranger"));
        _expectInvalid(item, keys);
        // More payees than parties.
        item = _masterItem(c);
        ISplitWallet.Payee[] memory three = new ISplitWallet.Payee[](3);
        three[0] = ISplitWallet.Payee(0, collab, 10_000);
        three[1] = ISplitWallet.Payee(_id(lead), address(0), 80_000);
        three[2] = ISplitWallet.Payee(_id(collab), address(0), 10_000);
        item.payees = three;
        _expectInvalid(item, keys);
        // No payees.
        item = _masterItem(c);
        item.payees = new ISplitWallet.Payee[](0);
        _expectInvalid(item, keys);
    }

    function test_invalidItem_duplicatePayee() public {
        PackageItem memory item = _masterItem(SHA_A);
        item.payees[0] = ISplitWallet.Payee(_id(lead), address(0), 20_000);
        _expectInvalid(item, _keys(leadKey, collabKey));
    }

    function test_validItem_partyPaidBothWays() public {
        // A party may be both a fixed and an artist-resolved payee: distinct canonical keys.
        PackageItem memory item = _masterItem(SHA_A);
        item.payees[1].artistId = _id(collab);
        _expectValid(item, _keys(leadKey, collabKey));
    }

    // --------------------------------------------------------------------- claimContent

    function test_claimContent_linkedPairException() public {
        PackageItem memory item = _masterItem(SHA_A);
        _expectValid(item, _keys(leadKey, collabKey));
        // The edition carries exactly its master's hash and names the master item.
        vm.expectEmit(address(registry));
        emit IPackageRegistry.ContentClaimed(SHA_A, _hash(item));
        _claim(SHA_A, _hash(item));
        assertEq(registry.editionClaimOf(SHA_A), _hash(item));
        // A second edition of the same media collides.
        vm.prank(editions);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ContentUsed.selector, PRODUCT_EDITIONS, SHA_A, _hash(item)
            )
        );
        registry.claimContent(SHA_A, _hash(item));
    }

    function test_claimContent_mustNameTheMasterItem() public {
        PackageItem memory item = _masterItem(SHA_A);
        _expectValid(item, _keys(leadKey, collabKey));
        bytes32[3] memory wrong = [keccak256("another item"), bytes32(0), _hash(_item(lead, SHA_A))];
        for (uint256 i; i < wrong.length; ++i) {
            vm.prank(editions);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IPackageRegistry.ClaimNotAllowed.selector, PRODUCT_EDITIONS, SHA_A
                )
            );
            registry.claimContent(SHA_A, wrong[i]);
        }
    }

    function test_claimContent_editionNeedsStreamMaster() public {
        vm.prank(editions);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ClaimNotAllowed.selector, PRODUCT_EDITIONS, SHA_B
            )
        );
        registry.claimContent(SHA_B, keccak256("an item"));
        // Not even a zero item hash against an unused content hash.
        vm.prank(editions);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ClaimNotAllowed.selector, PRODUCT_EDITIONS, SHA_B
            )
        );
        registry.claimContent(SHA_B, bytes32(0));
    }

    function test_claimContent_onlyBoundEditions() public {
        PackageItem memory item = _masterItem(SHA_A);
        _expectValid(item, _keys(leadKey, collabKey));
        address[4] memory callers = [admin, guardian, lead, stream];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IPackageRegistry.UnboundCaller.selector, callers[i])
            );
            registry.claimContent(SHA_A, _hash(item));
        }
    }

    // ------------------------------------------------------------------- releaseContent

    /// @dev Review PoC 1, inverted: a copier's item consumes the rightful artist's media; an
    ///      upheld dispute burns the token and Stream releases the hash to the rightful artist,
    ///      whose identity exists (its acceptance of its own package created it); the artist
    ///      then mints.
    function test_releaseContent_rightfulArtistConsumesAfterBurn() public {
        uint256 copierKey = 0xBAD;
        PackageItem memory copy = _item(vm.addr(copierKey), SHA_A);
        bytes32 copyRoot = WorksHashing.leaf(_hash(copy));
        _register(copyRoot);
        _accept(copyRoot, copierKey);
        _consume(copyRoot, copy, new bytes32[](0), _move(copierKey, copyRoot, _hash(copy), 0));
        PackageItem memory real = _item(lead, SHA_A);
        real.recordFileId = keccak256("the real record");
        bytes32 realRoot = WorksHashing.leaf(_hash(real));
        _register(realRoot);
        _accept(realRoot, leadKey);

        vm.expectEmit(address(registry));
        emit IPackageRegistry.ContentReleased(SHA_A, _hash(copy), uint160(lead));
        _release(SHA_A, _hash(copy), uint160(lead));
        assertEq(registry.consumedItemOf(SHA_A), bytes32(0));
        assertEq(registry.releasedTo(SHA_A), uint160(lead));
        assertTrue(registry.isReleased(_hash(copy)));

        vm.expectEmit(address(registry));
        emit IPackageRegistry.ItemConsumed(realRoot, _hash(real), _id(lead), SHA_A);
        _consume(realRoot, real, new bytes32[](0), _move(leadKey, realRoot, _hash(real), 0));
        assertEq(registry.consumedItemOf(SHA_A), _hash(real));
        // The rightful master's edition can then claim the hash.
        _claim(SHA_A, _hash(real));
        assertEq(registry.editionClaimOf(SHA_A), _hash(real));
    }

    /// @dev The burned item is tombstoned: no root, nonce or later release brings it back.
    function test_releaseContent_tombstonesTheItemEverywhere() public {
        uint256 copierKey = 0xBAD;
        PackageItem memory copy = _item(vm.addr(copierKey), SHA_A);
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = WorksHashing.leaf(_hash(copy));
        leaves[1] = keccak256("another item");
        bytes32 single = leaves[0];
        bytes32 pair = _root(leaves);
        _register(single);
        _register(pair);
        _accept(single, copierKey);
        _accept(pair, copierKey);
        PackageItem memory other = _item(lead, SHA_A);
        other.collectionId = 9;
        bytes32 otherRoot = WorksHashing.leaf(_hash(other));
        _register(otherRoot);
        _accept(otherRoot, leadKey);
        _consume(single, copy, new bytes32[](0), _move(copierKey, single, _hash(copy), 0));
        _release(SHA_A, _hash(copy), uint160(lead));

        bytes32[] memory proof = _proof(leaves, 0);
        bytes32[2] memory roots = [single, pair];
        for (uint256 r; r < 2; ++r) {
            MoveAuthorization memory move = _move(copierKey, roots[r], _hash(copy), 10 + r);
            vm.prank(stream);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IPackageRegistry.ContentUsed.selector, PRODUCT_STREAM, SHA_A, _hash(copy)
                )
            );
            registry.consume(roots[r], copy, r == 0 ? new bytes32[](0) : proof, move);
        }
        // Even after the hash is consumed and released again by another item, to the copier.
        _consume(otherRoot, other, new bytes32[](0), _move(leadKey, otherRoot, _hash(other), 0));
        _release(SHA_A, _hash(other), uint160(vm.addr(copierKey)));
        MoveAuthorization memory again = _move(copierKey, single, _hash(copy), 20);
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ContentUsed.selector, PRODUCT_STREAM, SHA_A, _hash(copy)
            )
        );
        registry.consume(single, copy, new bytes32[](0), again);
    }

    function test_releaseContent_revertsOnMismatch() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        _consume(root, item, new bytes32[](0), move);
        bytes32[3] memory wrongItems = [keccak256("another item"), bytes32(0), bytes32(uint256(1))];
        for (uint256 i; i < wrongItems.length; ++i) {
            vm.prank(stream);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IPackageRegistry.ClaimNotAllowed.selector, PRODUCT_STREAM, SHA_A
                )
            );
            registry.releaseContent(SHA_A, wrongItems[i], _id(lead));
        }
        // An unconsumed hash, and a second release of the same item.
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.ClaimNotAllowed.selector, PRODUCT_STREAM, SHA_B)
        );
        registry.releaseContent(SHA_B, _hash(item), _id(lead));
        // A release names a registered artist: zero and unknown IDs are refused.
        uint256[2] memory unknown = [uint256(0), uint160(makeAddr("never an artist"))];
        for (uint256 i; i < unknown.length; ++i) {
            vm.prank(stream);
            vm.expectRevert(
                abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, unknown[i])
            );
            registry.releaseContent(SHA_A, _hash(item), unknown[i]);
        }
        _release(SHA_A, _hash(item), _id(lead));
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.ClaimNotAllowed.selector, PRODUCT_STREAM, SHA_A)
        );
        registry.releaseContent(SHA_A, _hash(item), _id(lead));
        assertEq(registry.releasedTo(SHA_A), _id(lead), "a release happens once");
        // The release marker is not an item: it can neither be released nor claimed.
        bytes32 marker = bytes32(uint256(1));
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.ClaimNotAllowed.selector, PRODUCT_STREAM, SHA_A)
        );
        registry.releaseContent(SHA_A, marker, _id(lead));
        vm.prank(editions);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ClaimNotAllowed.selector, PRODUCT_EDITIONS, SHA_A
            )
        );
        registry.claimContent(SHA_A, marker);
    }

    function test_releaseContent_onlyBoundStream() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        _consume(root, item, new bytes32[](0), move);
        address[4] memory callers = [admin, guardian, lead, editions];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IPackageRegistry.UnboundCaller.selector, callers[i])
            );
            registry.releaseContent(SHA_A, _hash(item), _id(lead));
        }
        assertEq(registry.consumedItemOf(SHA_A), _hash(item));
    }

    /// @dev SIGS-1: a released content hash is reserved for the named artist. Another artist's
    ///      approved item with the same content (here the copier's second copy) is refused, in
    ///      the same block as the release, while the named artist's item consumes. Fresh content
    ///      is unaffected by any reservation.
    function test_releaseContent_reservesTheContentForTheNamedArtist() public {
        uint256 copierKey = 0xBAD;
        PackageItem memory copy = _item(vm.addr(copierKey), SHA_A);
        PackageItem memory sibling = _item(vm.addr(copierKey), SHA_A);
        sibling.recordFileId = keccak256("another record");
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = WorksHashing.leaf(_hash(copy));
        leaves[1] = WorksHashing.leaf(_hash(sibling));
        bytes32 copyRoot = _root(leaves);
        _register(copyRoot);
        _accept(copyRoot, copierKey);
        PackageItem memory real = _item(lead, SHA_A);
        real.recordFileId = keccak256("the real record");
        bytes32 realRoot = WorksHashing.leaf(_hash(real));
        _register(realRoot);
        _accept(realRoot, leadKey);
        _consume(copyRoot, copy, _proof(leaves, 0), _move(copierKey, copyRoot, _hash(copy), 0));
        _release(SHA_A, _hash(copy), uint160(lead));

        MoveAuthorization memory move = _move(copierKey, copyRoot, _hash(sibling), 1);
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ContentReserved.selector, SHA_A, uint256(uint160(lead))
            )
        );
        registry.consume(copyRoot, sibling, _proof(leaves, 1), move);

        _consume(realRoot, real, new bytes32[](0), _move(leadKey, realRoot, _hash(real), 0));
        assertEq(registry.consumedItemOf(SHA_A), _hash(real));
        // Consumed again, the content is used: the reservation no longer matters.
        move = _move(copierKey, copyRoot, _hash(sibling), 2);
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ContentUsed.selector, PRODUCT_STREAM, SHA_A, _hash(real)
            )
        );
        registry.consume(copyRoot, sibling, _proof(leaves, 1), move);
    }

    // ---------------------------------------------------------------------- setVerifier

    function test_setVerifier() public {
        Eip712CurationVerifier next = new Eip712CurationVerifier(address(manager));
        vm.expectEmit(address(registry));
        emit IPackageRegistry.VerifierSet(address(verifier), address(next), address(next).codehash);
        _swapVerifier(next);
        assertEq(address(registry.verifier()), address(next));
        // Attestations for the old verifier's domain no longer register packages.
        bytes32 root = keccak256("root");
        bytes memory oldAtt = _attestation(signerKey1, root, EVIDENCE);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, root));
        registry.registerPackage(root, EVIDENCE, oldAtt);
        bytes memory sig =
            _sig(signerKey1, next.approvalDigest(root, EVIDENCE, next.signerEpoch(signer1)));
        registry.registerPackage(root, EVIDENCE, abi.encode(signer1, sig));
    }

    /// @dev DEPS-6: the verifier's code hash is checked at every registration, so code that
    ///      replaced the pinned code at the verifier's address (here one that approves anything)
    ///      registers nothing.
    function test_registerPackage_refusesAVerifierWhoseCodeChanged() public {
        vm.etch(address(verifier), address(new ApproveEverythingVerifier()).code);
        bytes32 root = keccak256("an unapproved root");
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.DependencyCodeChanged.selector, address(verifier))
        );
        registry.registerPackage(root, EVIDENCE, "");
        (IPackageRegistry.PackageStatus status,,) = registry.packageOf(root);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.NONE));
    }

    function test_setVerifier_keepsRegisteredApprovals() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        _swapVerifier(new Eip712CurationVerifier(address(manager)));
        _consume(root, item, new bytes32[](0), move);
    }

    /// @dev Review of SIGS-2: a verifier once replaced is retired and can never be installed
    ///      again (A to B to A is refused), so a swap back cannot bring back the approvals and
    ///      the signer states of the retired verifier.
    function test_setVerifier_refusesARetiredVerifier() public {
        Eip712CurationVerifier a = verifier;
        Eip712CurationVerifier b = new Eip712CurationVerifier(address(manager));
        _swapVerifier(b);
        bytes32 aHash = address(a).codehash;
        vm.prank(successor);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, a));
        registry.setVerifier(ICurationVerifier(address(b)), ICurationVerifier(address(a)), aHash);
        assertEq(address(registry.verifier()), address(b));
        // A verifier never installed is accepted.
        Eip712CurationVerifier c = new Eip712CurationVerifier(address(manager));
        bytes32 cHash = address(c).codehash;
        vm.prank(successor);
        registry.setVerifier(ICurationVerifier(address(b)), ICurationVerifier(address(c)), cHash);
        assertEq(address(registry.verifier()), address(c));
        vm.prank(successor);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, b));
        registry.setVerifier(ICurationVerifier(address(c)), ICurationVerifier(address(b)), aHash);
    }

    function test_setVerifier_compareAndSet() public {
        Eip712CurationVerifier next = new Eip712CurationVerifier(address(manager));
        bytes32 h = address(next).codehash;
        vm.prank(successor);
        vm.expectRevert(IPackageRegistry.ExpectedValueMismatch.selector);
        registry.setVerifier(ICurationVerifier(address(next)), ICurationVerifier(address(next)), h);
    }

    function test_setVerifier_revertsOnNoOp() public {
        bytes32 h = address(verifier).codehash;
        ICurationVerifier current = ICurationVerifier(address(verifier));
        vm.prank(successor);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(verifier))
        );
        registry.setVerifier(current, current, h);
    }

    function test_setVerifier_rejectsBadVerifier() public {
        ICurationVerifier current = ICurationVerifier(address(verifier));
        address eoa = makeAddr("eoa");
        vm.prank(successor);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        registry.setVerifier(current, ICurationVerifier(eoa), eoa.codehash);
        // A contract without ERC-165 support for ICurationVerifier.
        bytes32 artistsHash = address(artists).codehash;
        vm.prank(successor);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(artists))
        );
        registry.setVerifier(current, ICurationVerifier(address(artists)), artistsHash);
        // A verifier whose code is not the reviewed code.
        Eip712CurationVerifier next = new Eip712CurationVerifier(address(manager));
        vm.prank(successor);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(next))
        );
        registry.setVerifier(current, ICurationVerifier(address(next)), keccak256("reviewed"));
    }

    function test_setVerifier_onlySuccessorSetter() public {
        Eip712CurationVerifier next = new Eip712CurationVerifier(address(manager));
        bytes32 h = address(next).codehash;
        address[3] memory callers = [admin, guardian, stream];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManaged.AccessManagedUnauthorized.selector, callers[i]
                )
            );
            registry.setVerifier(
                ICurationVerifier(address(verifier)), ICurationVerifier(address(next)), h
            );
        }
    }

    function _swapVerifier(Eip712CurationVerifier next) internal {
        bytes32 h = address(next).codehash;
        vm.prank(successor);
        registry.setVerifier(
            ICurationVerifier(address(verifier)), ICurationVerifier(address(next)), h
        );
    }

    function test_governedFunctionsAreNonPayable() public {
        (bool ok,) = address(registry).call{ value: 1 }(
            abi.encodeCall(PackageRegistry.revokePackage, (bytes32(0), bytes32(0)))
        );
        assertFalse(ok);
    }

    // ------------------------------------------------------------------- merkle fuzzing

    /// @dev Any position in a package of any size: the honest proof consumes, and a proof with
    ///      one flipped bit, or the honest proof against a sibling position, does not.
    function testFuzz_merkle_proofs(uint8 size, uint256 index, bytes32 salt, uint256 flip) public {
        uint256 n = bound(size, 1, 64);
        index = bound(index, 0, n - 1);
        PackageItem memory item = _item(lead, SHA_A);
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            leaves[i] = keccak256(abi.encode(salt, i));
        }
        leaves[index] = WorksHashing.leaf(_hash(item));
        bytes32 root = _root(leaves);
        bytes32[] memory proof = _proof(leaves, index);
        _register(root);
        _accept(root, leadKey);
        MoveAuthorization memory move = _move(leadKey, root, _hash(item), 0);

        if (proof.length != 0) {
            bytes32[] memory bad = new bytes32[](proof.length);
            for (uint256 i; i < proof.length; ++i) {
                bad[i] = proof[i];
            }
            uint256 bitIndex = bound(flip, 0, proof.length * 256 - 1);
            bad[bitIndex / 256] = bad[bitIndex / 256] ^ bytes32(uint256(1) << (bitIndex % 256));
            vm.prank(stream);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IPackageRegistry.ItemNotInPackage.selector, root, _hash(item)
                )
            );
            registry.consume(root, item, bad, move);
            // Dropping the last element also fails.
            bytes32[] memory shorter = new bytes32[](proof.length - 1);
            for (uint256 i; i < shorter.length; ++i) {
                shorter[i] = proof[i];
            }
            vm.prank(stream);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IPackageRegistry.ItemNotInPackage.selector, root, _hash(item)
                )
            );
            registry.consume(root, item, shorter, move);
        }
        _consume(root, item, proof, move);
        assertEq(registry.consumedItemOf(item.contentHash), _hash(item));
    }

    /// @dev An arbitrary proof for an item that is not in the package never consumes it.
    function testFuzz_merkle_foreignItemRejected(bytes32[] calldata proof, bytes32 salt) public {
        vm.assume(proof.length <= 32);
        PackageItem memory member = _item(lead, keccak256(abi.encode(salt)));
        PackageItem memory outsider = _item(lead, SHA_A);
        bytes32 root = WorksHashing.leaf(_hash(member));
        _register(root);
        _accept(root, leadKey);
        MoveAuthorization memory move = _move(leadKey, root, _hash(outsider), 0);
        vm.prank(stream);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ItemNotInPackage.selector, root, _hash(outsider)
            )
        );
        registry.consume(root, outsider, proof, move);
    }

    // -------------------------------------------------------------------------- helpers

    function _keys(uint256 a) internal pure returns (uint256[] memory k) {
        k = new uint256[](1);
        k[0] = a;
    }

    function _keys(uint256 a, uint256 b) internal pure returns (uint256[] memory k) {
        k = new uint256[](2);
        (k[0], k[1]) = (a, b);
    }

    function _accept(bytes32 root, uint256 key, bool registerFirst) internal returns (uint256) {
        if (registerFirst) {
            (IPackageRegistry.PackageStatus status,,) = registry.packageOf(root);
            if (status == IPackageRegistry.PackageStatus.NONE) _register(root);
        }
        return _accept(root, key);
    }

    /// @dev Accepts for `account`, signed by `key` (its artist's current authority).
    function _acceptAs(bytes32 root, address account, uint256 key) internal {
        (ArtistIdentity memory identity,) = artists.artist(artists.artistIdOf(account));
        PartyAcceptance memory a =
            PartyAcceptance(account, identity.profileId, identity.profileDocHash, deadline);
        registry.acceptPackage(root, a, _sig(key, registry.acceptanceDigest(root, a)));
    }

    function _prepare(PackageItem memory item, uint256[] memory keys)
        internal
        returns (bytes32 root)
    {
        root = WorksHashing.leaf(_hash(item));
        (IPackageRegistry.PackageStatus status,,) = registry.packageOf(root);
        if (status == IPackageRegistry.PackageStatus.NONE) _register(root);
        for (uint256 i; i < keys.length; ++i) {
            if (registry.acceptedAs(root, vm.addr(keys[i])) == 0) _accept(root, keys[i]);
        }
    }

    function _expectInvalid(PackageItem memory item, uint256[] memory keys) internal {
        bytes32 root = _prepare(item, keys);
        _consumeExpectInvalid(root, item, keys[0]);
    }

    function _consumeExpectInvalid(bytes32 root, PackageItem memory item, uint256 leadKey_)
        internal
    {
        MoveAuthorization memory move = _move(leadKey_, root, _hash(item), 0);
        vm.prank(stream);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.InvalidItem.selector, _hash(item)));
        registry.consume(root, item, new bytes32[](0), move);
    }

    function _expectValid(PackageItem memory item, uint256[] memory keys) internal {
        bytes32 root = _prepare(item, keys);
        _consume(root, item, new bytes32[](0), _move(keys[0], root, _hash(item), 0));
        assertEq(registry.consumedItemOf(item.contentHash), _hash(item));
    }
}
