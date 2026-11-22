// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Directory } from "src/core/Directory.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IModules } from "src/interfaces/core/IModules.sol";
import { MintFacts, MintTerms } from "src/interfaces/core/CoreTypes.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Eip712CurationVerifier } from "src/curation/Eip712CurationVerifier.sol";
import { Roles } from "src/governance/Roles.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { ICurationVerifier } from "src/interfaces/ICurationVerifier.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { CURRENCY_DEFAULT, CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    ItemKind,
    MoveAuthorization,
    PackageItem,
    Party,
    PartyAcceptance,
    PartyRole,
    SeedPolicy,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { ProductEconomics } from "src/interfaces/types/EconomicsTypes.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { MockBoundCaller } from "test/mocks/curation/MockBoundCaller.sol";
import {
    MisnumberingArtistRegistry,
    UndernumberingArtistRegistry
} from "test/mocks/curation/CurationArtistRegistryMock.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { EditionRules } from "src/editions/EditionRules.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { ERC1271WalletMock } from "test/mocks/libraries/AdversarialTargets.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { SignatureReverts } from "test/helpers/SignatureReverts.sol";
import { CurationBase, CurationPolicyStub, EntropyStub, PolicyMinter } from "./CurationBase.sol";

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
        assertFalse(registry.supportsInterface(0x00000001));
    }

    function test_constructor_rejectsBadDependencies() public {
        address eoa = makeAddr("eoa");
        ICurationVerifier v = ICurationVerifier(address(verifier));
        bytes32 vh = address(verifier).codehash;
        address dir = address(
            new Directory(address(manager), address(artists), address(0), address(0), address(0))
        );
        // The directory: code that declares `IDirectory` (the accounts module is read from it
        // at every use, so nothing about the module is pinned here).
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new PackageRegistry(
            address(manager), v, vh, eoa, IEconomicsResolver(address(_policyStub)), address(0),
            keccak256("cc0 text file")
        );
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(verifier))
        );
        new PackageRegistry(
            address(manager),
            v,
            vh,
            address(verifier),
            IEconomicsResolver(address(_policyStub)),
            address(0),
            keccak256("cc0 text file")
        );
        // The verifier's code hash is pinned.
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(verifier))
        );
        new PackageRegistry(
            address(manager),
            v,
            keccak256("other"),
            dir,
            IEconomicsResolver(address(_policyStub)),
            address(0),
            keccak256("cc0 text file")
        );
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new PackageRegistry(
            address(manager),
            ICurationVerifier(eoa),
            vh,
            dir,
            IEconomicsResolver(address(_policyStub)),
            address(0),
            keccak256("cc0 text file")
        );
    }

    function test_constructor_rejectsDelegatedVerifier() public {
        address delegated = makeAddr("7702 account");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(verifier)));
        bytes32 h = delegated.codehash;
        address dir = address(
            new Directory(address(manager), address(artists), address(0), address(0), address(0))
        );
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, delegated));
        new PackageRegistry(
            address(manager),
            ICurationVerifier(delegated),
            h,
            dir,
            IEconomicsResolver(address(_policyStub)),
            address(0),
            keccak256("cc0 text file")
        );
    }

    // -------------------------------------------------------------------- caller binding

    bytes32 internal constant STREAM_NAME = "STREAM";

    function test_bindStream_once() public {
        assertEq(registry.stream(), stream);
        PackageRegistry fresh = _newRegistry();
        address s2 = address(new MockBoundCaller(type(IStream).interfaceId));
        // A Stream whose facts do not answer is refused, and so is one whose facts name
        // another CC0 text than the registry was built with.
        vm.prank(admin);
        vm.expectRevert();
        fresh.bindStream(s2);
        vm.mockCall(
            IStream(stream).facts(),
            abi.encodeWithSignature("cc0TextFileId()"),
            abi.encode(keccak256("another text"))
        );
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stream));
        fresh.bindStream(stream);
        vm.clearMockedCalls();
        vm.expectEmit(address(fresh));
        emit IPackageRegistry.Bound(STREAM_NAME, stream);
        vm.prank(admin);
        fresh.bindStream(stream);
        assertEq(fresh.stream(), stream);
        assertEq(fresh.cc0TextFileId(), keccak256("cc0 text file"));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.AlreadyBound.selector, STREAM_NAME));
        fresh.bindStream(stream);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.AlreadyBound.selector, STREAM_NAME));
        registry.bindStream(s2);
    }

    /// @dev A binding must answer ERC-165 for the core `IStream`, so a wrong address cannot be
    ///      bound forever by mistake.
    function test_bind_rejectsContractsWithoutTheInterface() public {
        PackageRegistry fresh = _newRegistry();
        address[3] memory notStreams = [address(verifier), address(_policyStub), address(artists)];
        for (uint256 i; i < notStreams.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(
                abi.encodeWithSelector(Dependency.InvalidDependency.selector, notStreams[i])
            );
            fresh.bindStream(notStreams[i]);
        }
        assertEq(fresh.stream(), address(0));
    }

    function test_bind_governedAndContractsOnly() public {
        PackageRegistry fresh = _newRegistry();
        bytes memory unauthorized =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian);
        vm.prank(guardian);
        vm.expectRevert(unauthorized);
        fresh.bindStream(stream);
        address eoa = makeAddr("eoa");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        fresh.bindStream(eoa);
        address delegated = makeAddr("7702 account");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", stream));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, delegated));
        fresh.bindStream(delegated);
    }

    /// @dev An unbound registry admits nothing, even for an active minter of a real Stream.
    function test_unboundRegistryRefusesEveryone() public {
        PackageRegistry fresh = _newRegistry();
        PackageItem memory item;
        MoveAuthorization memory move;
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.NotSaleContract.selector, stream, address(minter))
        );
        _policyCall(fresh, bytes32(0), item, new bytes32[](0), move);
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
        vm.prank(address(minter));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        _policyCall(registry, root, item, new bytes32[](0), move);
        PartyAcceptance memory a = _acceptance(collab);
        bytes memory sig = _pf(collabKey, _sig(collabKey, registry.acceptanceDigest(root, a)));
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
        bytes memory sig = _pf(leadKey, _sig(leadKey, registry.acceptanceDigest(root, a)));
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

    /// @dev Only a first acceptance creates the identity; a later one reuses it.
    function test_acceptPackage_laterAcceptancesReuseTheIdentity() public {
        bytes32 root1 = keccak256("root1");
        bytes32 root2 = keccak256("root2");
        _register(root1);
        _register(root2);
        _accept(root1, leadKey);
        vm.warp(block.timestamp + 100 days);
        deadline = uint64(block.timestamp + 1 days);
        // An existing artist's acceptance is announced like the first one.
        vm.expectEmit(address(registry));
        emit IPackageRegistry.PackageAccepted(root2, _id(lead), lead);
        _accept(root2, leadKey);
        assertEq(registry.acceptedAs(root2, lead), _id(lead));
        assertEq(artists.registrations(), 1);
    }

    function test_acceptPackage_replayIsNoop() public {
        bytes32 root = keccak256("root");
        _register(root);
        PartyAcceptance memory a = _acceptance(lead);
        bytes memory sig = _pf(leadKey, _sig(leadKey, registry.acceptanceDigest(root, a)));
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
        vm.expectRevert(SignatureReverts.invalid(lead));
        registry.acceptPackage(root, a, _pf(leadKey, _sig(leadKey, digest)));
        assertEq(registry.acceptPackage(root, a, _pf(newKey, _sig(newKey, digest))), _id(lead));
    }

    function test_acceptPackage_erc1271Authority() public {
        bytes32 root = keccak256("root");
        _register(root);
        ERC1271WalletMock safe = new ERC1271WalletMock(lead);
        PartyAcceptance memory a = _acceptance(address(safe));
        bytes memory sig = _as(address(safe), _sig(leadKey, registry.acceptanceDigest(root, a)));
        assertEq(registry.acceptPackage(root, a, sig), _id(address(safe)));
    }

    function test_acceptPackage_revertsProfileMismatch() public {
        bytes32 root = keccak256("root");
        _register(root);
        _accept(keccak256("unrelated"), leadKey, true);
        artists.setProfile(_id(lead), keccak256("new profile"), keccak256("new doc"));
        PartyAcceptance memory a = _acceptance(lead);
        bytes memory sig = _pf(leadKey, _sig(leadKey, registry.acceptanceDigest(root, a)));
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
        bytes memory s1 = _pf(leadKey, _sig(leadKey, registry.acceptanceDigest(r1, a1)));
        bytes memory s2 = _pf(leadKey, _sig(leadKey, registry.acceptanceDigest(r2, a2)));
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
        bytes memory wrongKey = _as(lead, _sig(collabKey, digest));
        bytes memory malleable = _pf(leadKey, _highS(leadKey, digest));
        vm.expectRevert(SignatureReverts.invalid(lead));
        registry.acceptPackage(root, a, wrongKey);
        vm.expectRevert(SignatureReverts.invalid(lead));
        registry.acceptPackage(root, a, malleable);
        // Bound to the root: a signature for another root does not transfer.
        bytes32 other = keccak256("other root");
        _register(other);
        vm.expectRevert(SignatureReverts.invalid(lead));
        registry.acceptPackage(other, a, _pf(leadKey, _sig(leadKey, digest)));
        // The zero account never signs.
        a.account = address(0);
        bytes memory zeroSig = _as(address(0), _sig(leadKey, registry.acceptanceDigest(root, a)));
        vm.expectRevert(SignatureReverts.invalid(address(0)));
        registry.acceptPackage(root, a, zeroSig);
    }

    /// @dev The deadline second itself is still in time.
    function test_acceptPackage_atTheDeadline() public {
        bytes32 root = keccak256("root");
        _register(root);
        PartyAcceptance memory a = _acceptance(lead);
        bytes memory sig = _pf(leadKey, _sig(leadKey, registry.acceptanceDigest(root, a)));
        vm.warp(a.deadline);
        assertEq(registry.acceptPackage(root, a, sig), _id(lead));
    }

    /// @dev A profile that differs in either direction, in either field, is a mismatch.
    function test_acceptPackage_profileMismatchEitherWay() public {
        bytes32 root = keccak256("root");
        _register(root);
        _accept(keccak256("unrelated"), leadKey, true);
        artists.setProfile(_id(lead), bytes32(uint256(5)), bytes32(uint256(5)));
        PartyAcceptance memory base = _acceptance(lead);
        for (uint256 v; v < 4; ++v) {
            PartyAcceptance memory a = PartyAcceptance(
                base.account, bytes32(uint256(5)), bytes32(uint256(5)), base.deadline
            );
            if (v == 0) a.profileId = bytes32(uint256(6));
            else if (v == 1) a.profileId = bytes32(uint256(4));
            else if (v == 2) a.profileDocHash = bytes32(uint256(6));
            else a.profileDocHash = bytes32(uint256(4));
            bytes memory sig = _pf(leadKey, _sig(leadKey, registry.acceptanceDigest(root, a)));
            vm.expectRevert(
                abi.encodeWithSelector(IPackageRegistry.ProfileMismatch.selector, _id(lead))
            );
            registry.acceptPackage(root, a, sig);
        }
    }

    function test_acceptPackage_revertsExpired() public {
        bytes32 root = keccak256("root");
        _register(root);
        PartyAcceptance memory a = _acceptance(lead);
        bytes memory sig = _pf(leadKey, _sig(leadKey, registry.acceptanceDigest(root, a)));
        vm.warp(uint256(a.deadline) + 1);
        vm.expectRevert(SignatureReverts.expired(a.deadline));
        registry.acceptPackage(root, a, sig);
    }

    function test_acceptPackage_revertsUnknownPackage() public {
        bytes32 root = keccak256("root");
        PartyAcceptance memory a = _acceptance(lead);
        bytes memory sig = _pf(leadKey, _sig(leadKey, registry.acceptanceDigest(root, a)));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        registry.acceptPackage(root, a, sig);
    }

    function test_acceptPackage_revertsWrongChain() public {
        bytes32 root = keccak256("root");
        _register(root);
        PartyAcceptance memory a = _acceptance(lead);
        bytes memory sig = _pf(leadKey, _sig(leadKey, registry.acceptanceDigest(root, a)));
        vm.chainId(block.chainid + 1);
        vm.expectRevert(SignatureReverts.invalid(lead));
        registry.acceptPackage(root, a, sig);
    }

    // -------------------------------------------------------------------------- consume

    function test_consume() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        bytes32 itemHash = _hash(item);
        (MintFacts memory rec, MintTerms memory terms) =
            _authorize(root, item, new bytes32[](0), move);
        (bytes32 h, uint256 artistId, address authority) =
            (rec.itemHash, rec.artistId, terms.creator);
        assertEq(h, itemHash);
        assertEq(artistId, _id(lead));
        assertEq(authority, lead, "the active authority that signed the move");
        assertEq(registry.consumedItemOf(SHA_A), itemHash);
        assertTrue(registry.isMoveNonceUsed(_id(lead), 0));
        assertFalse(registry.isMoveNonceUsed(_id(lead), 1));
    }

    /// @dev The quote and the mint facts carry the item's own sale terms, root, media hash and
    ///      record file, whatever they hold (the auction checks the sale kind and the params).
    function test_previewAndAuthorize_carryTheItemsOwnFields() public {
        PackageItem memory item = _item(lead, SHA_A);
        item.sale.params = hex"0102";
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        _accept(root, leadKey);
        MoveAuthorization memory move = _move(leadKey, root, _hash(item), 0);
        (MintFacts memory pf, MintTerms memory t) =
            registry.preview(stream, _request(root, item, new bytes32[](0), move));
        assertEq(t.params, item.sale.params);
        assertEq(t.saleKind, item.sale.saleKind);
        assertEq(pf.itemHash, _hash(item));
        (MintFacts memory rec, MintTerms memory rt) = _authorize(root, item, new bytes32[](0), move);
        assertEq(rec.packageRoot, root);
        assertEq(rec.mediaHash, item.mediaHash);
        assertEq(rec.recordFileId, item.recordFileId);
        assertEq(rt.params, item.sale.params);
        assertEq(rec.contentHash, SHA_A);
        assertEq(rec.collectionId, item.collectionId);
        assertEq(rec.kind, item.kind);
        assertEq(abi.encode(pf), abi.encode(rec), "the preview answers the same facts");
    }

    /// @dev The registry hashes the item from calldata (`WorksHashing.itemHashCalldata`);
    ///      whatever the dynamic fields hold, the result is `WorksHashing.itemHash`.
    /// The license ID is fixed: the policy refuses one outside the `SpdxId` grammar before hashing.
    function testFuzz_consume_itemHashMatchesWorksHashing(
        uint256 collectionId,
        bytes32 mediaHash,
        bytes calldata saleParams,
        bytes32 seed
    ) public {
        vm.assume(seed != 0);
        PackageItem memory item = _item(lead, SHA_A);
        item.collectionId = collectionId;
        item.mediaHash = mediaHash;
        item.sale.params = saleParams;
        item.seedPolicy = uint8(SeedPolicy.ARTIST);
        item.seed = seed;
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        _accept(root, leadKey);
        (MintFacts memory f,) = minter.authorizeOnly(
            address(registry),
            stream,
            _request(root, item, new bytes32[](0), _move(leadKey, root, _hash(item), 0))
        );
        assertEq(f.itemHash, WorksHashing.itemHash(item));
        assertEq(f.seed, seed);
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
        vm.prank(address(minter));
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.PartyNotAccepted.selector, root, collab)
        );
        _policyCall(registry, root, item, new bytes32[](0), move);
        // The collaborator accepted a different package: still not this one.
        _accept(keccak256("unrelated"), collabKey, true);
        vm.prank(address(minter));
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.PartyNotAccepted.selector, root, collab)
        );
        _policyCall(registry, root, item, new bytes32[](0), move);
    }

    /// @dev Only an active minter of the bound Stream is served: the network, artists, a
    ///      minter not yet active or removed, and a minter naming another token are refused.
    function test_consume_onlyAnActiveMinterOfTheBoundStream() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        bytes memory request = _request(root, item, new bytes32[](0), move);
        address[3] memory callers = [admin, guardian, lead];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IMintPolicy.NotSaleContract.selector, stream, callers[i])
            );
            registry.authorize(stream, request);
        }
        // An active minter naming another token.
        address other = address(new MockBoundCaller(type(IStream).interfaceId));
        vm.prank(address(minter));
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.NotSaleContract.selector, other, address(minter))
        );
        registry.authorize(other, request);
        // A minter added but still waiting, then active, then removed.
        PolicyMinter pending = new PolicyMinter();
        vm.prank(admin);
        IModules(stream).addMinter(address(pending));
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.NotSaleContract.selector, stream, address(pending))
        );
        pending.mint(address(registry), stream, request);
        vm.warp(block.timestamp + IModules(stream).moduleDelay());
        deadline = uint64(block.timestamp + 1 days);
        move = _move(leadKey, root, _hash(item), 0);
        request = _request(root, item, new bytes32[](0), move);
        vm.prank(admin);
        IModules(stream).removeMinter(address(pending));
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.NotSaleContract.selector, stream, address(pending))
        );
        pending.mint(address(registry), stream, request);
        assertFalse(registry.isMoveNonceUsed(_id(lead), 0), "nothing spent");
        // The genesis minter is served.
        _authorize(root, item, new bytes32[](0), move);
    }

    function test_consume_revertsDoubleConsume() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        _consume(root, item, new bytes32[](0), move);
        MoveAuthorization memory fresh = _move(leadKey, root, _hash(item), 1);
        vm.expectRevert(abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, SHA_A, uint256(1)));
        _authorize(root, item, new bytes32[](0), fresh);
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
        vm.expectRevert(abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, SHA_A, uint256(1)));
        _authorize(rootB, item, proof, move);
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
        vm.expectRevert(abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, SHA_A, uint256(1)));
        _authorize(root, items[1], proofs[1], move);
        assertEq(registry.consumedItemOf(SHA_A), _hash(items[0]));
    }

    function test_consume_revertsItemNotInPackage() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        item.collectionId = 2; // any field change is another item
        vm.prank(address(minter));
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.ItemNotInPackage.selector, root, _hash(item))
        );
        _policyCall(registry, root, item, new bytes32[](0), move);
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
        vm.prank(address(minter));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ItemNotInPackage.selector, deepRoot, _hash(item)
            )
        );
        _policyCall(registry, deepRoot, item, deep, move);
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
        vm.prank(address(minter));
        vm.expectRevert(SignatureReverts.expired(move.deadline));
        _policyCall(registry, root, item, new bytes32[](0), move);
    }

    function test_move_validAtDeadline() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        vm.warp(move.deadline);
        _consume(root, item, new bytes32[](0), move);
    }

    function test_move_revertsWrongSigner() public {
        (bytes32 root, PackageItem memory item,) = _ready(SHA_A);
        MoveAuthorization memory move = _move(collabKey, root, _hash(item), 0);
        vm.prank(address(minter));
        vm.expectRevert(SignatureReverts.invalid(collab));
        _policyCall(registry, root, item, new bytes32[](0), move);
    }

    function test_move_revertsMalleableHighS() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        move.signature =
            _pf(leadKey, _highS(leadKey, registry.moveDigest(root, _hash(item), 0, deadline)));
        vm.prank(address(minter));
        vm.expectRevert(SignatureReverts.invalid(lead));
        _policyCall(registry, root, item, new bytes32[](0), move);
    }

    function test_move_revertsWrongChain() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        vm.chainId(block.chainid + 1);
        vm.prank(address(minter));
        vm.expectRevert(SignatureReverts.invalid(lead));
        _policyCall(registry, root, item, new bytes32[](0), move);
    }

    function test_move_revertsOtherRegistryDeployment() public {
        (bytes32 root, PackageItem memory item,) = _ready(SHA_A);
        PackageRegistry other = _newRegistry();
        bytes memory foreign =
            _pf(leadKey, _sig(leadKey, other.moveDigest(root, _hash(item), 0, deadline)));
        vm.prank(address(minter));
        vm.expectRevert(SignatureReverts.invalid(lead));
        _policyCall(registry, root, item, new bytes32[](0), MoveAuthorization(0, deadline, foreign));
    }

    function test_move_bindsItem() public {
        PackageItem[] memory items = new PackageItem[](2);
        items[0] = _item(lead, SHA_A);
        items[1] = _item(lead, SHA_B);
        (bytes32 root, bytes32[][] memory proofs) = _tree(items);
        _register(root);
        _accept(root, leadKey);
        MoveAuthorization memory moveFor0 = _move(leadKey, root, _hash(items[0]), 0);
        vm.prank(address(minter));
        vm.expectRevert(SignatureReverts.invalid(lead));
        _policyCall(registry, root, items[1], proofs[1], moveFor0);
    }

    function test_move_signedByCurrentAuthorityAfterRecovery() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory oldMove) = _ready(SHA_A);
        uint256 newKey = 0xA9;
        artists.recover(_id(lead), vm.addr(newKey));
        vm.prank(address(minter));
        vm.expectRevert(SignatureReverts.invalid(lead));
        _policyCall(registry, root, item, new bytes32[](0), oldMove);
        _consume(root, item, new bytes32[](0), _move(newKey, root, _hash(item), 0));
    }

    function test_move_erc1271Authority() public {
        ERC1271WalletMock safe = new ERC1271WalletMock(lead);
        PackageItem memory item = _item(address(safe), SHA_A);
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        PartyAcceptance memory a = _acceptance(address(safe));
        registry.acceptPackage(
            root, a, _as(address(safe), _sig(leadKey, registry.acceptanceDigest(root, a)))
        );
        bytes32 moveDigest = registry.moveDigest(root, _hash(item), 0, deadline);
        _consume(
            root,
            item,
            new bytes32[](0),
            MoveAuthorization(0, deadline, _as(address(safe), _sig(leadKey, moveDigest)))
        );
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
        _consume(
            root,
            items[0],
            proofs[0],
            MoveAuthorization(5, deadline, _pf(leadKey, _compact(leadKey, d0)))
        );
        MoveAuthorization memory second =
            MoveAuthorization(5, deadline, _pf(leadKey, _sig(leadKey, d1)));
        vm.prank(address(minter));
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.MoveNonceUsed.selector, _id(lead), 5)
        );
        _policyCall(registry, root, items[1], proofs[1], second);
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
        MoveAuthorization memory compact =
            MoveAuthorization(0, deadline, _pf(leadKey, _compact(leadKey, digest)));
        vm.prank(address(minter));
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.MoveNonceUsed.selector, _id(lead), 0)
        );
        _policyCall(registry, root, item, new bytes32[](0), move);
        vm.prank(address(minter));
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.MoveNonceUsed.selector, _id(lead), 0)
        );
        _policyCall(registry, root, item, new bytes32[](0), compact);
        // A fresh nonce still works.
        _consume(root, item, new bytes32[](0), _move(leadKey, root, _hash(item), 1));
    }

    /// @dev A bitmap word holds 255 nonces; its top bit is the sentinel acceptance sets. The
    ///      nonces on either side of a word boundary are distinct from each other and from it.
    function test_revokeMove_nonceWordBoundary() public {
        _ready(SHA_A);
        uint256 id = _id(lead);
        for (uint256 n = 253; n <= 256; ++n) {
            assertFalse(registry.isMoveNonceUsed(id, n));
        }
        vm.prank(lead);
        registry.revokeMove(id, 255);
        assertTrue(registry.isMoveNonceUsed(id, 255));
        assertFalse(registry.isMoveNonceUsed(id, 254));
        assertFalse(registry.isMoveNonceUsed(id, 256));
        assertFalse(registry.isMoveNonceUsed(id, 0));
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

    /// @dev The policy's item rules (`InvalidSeedPolicy`) run before the consume.
    function test_invalidItem_seedPolicy() public {
        bytes memory reason = abi.encodeWithSelector(IPackageRegistry.InvalidSeedPolicy.selector);
        PackageItem memory item = _item(lead, SHA_A);
        item.seed = keccak256("seed"); // seed without SeedPolicy.ARTIST
        _expectInvalidWith(item, _keys(leadKey), reason);
        item.seedPolicy = uint8(SeedPolicy.ARTIST);
        item.seed = 0; // ARTIST policy without a seed
        _expectInvalidWith(item, _keys(leadKey), reason);
        item.seedPolicy = uint8(SeedPolicy.VRF);
        item.seed = keccak256("seed");
        _expectInvalidWith(item, _keys(leadKey), reason);
    }

    /// @dev A VRF item carries no seed of its own (the seed comes from the entropy module): with
    ///      an entropy module in the context it is quoted.
    function test_preview_aVrfItemWithoutASeed() public {
        PackageItem memory item = _item(lead, SHA_A);
        item.seedPolicy = uint8(SeedPolicy.VRF);
        item.seed = 0;
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        _accept(root, leadKey);
        (MintFacts memory f, MintTerms memory t) = registry.preview(
            stream, _request(root, item, new bytes32[](0), _move(leadKey, root, _hash(item), 0))
        );
        assertEq(t.creator, lead);
        assertEq(f.seed, bytes32(0), "not delivered yet");
        entropy.deliver(SHA_A, keccak256("vrf"));
        (f,) = registry.preview(
            stream, _request(root, item, new bytes32[](0), _move(leadKey, root, _hash(item), 0))
        );
        assertEq(f.seed, keccak256("vrf"));
    }

    /// @dev Kinds, seed policies and party roles are open `uint8`s in the package types; the
    ///      genesis policy refuses every value it does not know for a new item (a value above
    ///      today's enum used to fail the ABI decode instead).
    function test_invalidItem_valuesTodaysEnumsDoNotName() public {
        PackageItem memory item = _item(lead, SHA_A);
        item.seedPolicy = uint8(SeedPolicy.VRF) + 1;
        _expectInvalidWith(
            item,
            _keys(leadKey),
            abi.encodeWithSelector(IPackageRegistry.InvalidSeedPolicy.selector)
        );
        item = _item(lead, SHA_A);
        item.kind = uint8(ItemKind.EDITION_MASTER) + 1;
        _expectInvalid(item, _keys(leadKey));
        item = _masterItem(SHA_A);
        item.parties[1].role = uint8(PartyRole.COLLABORATOR) + 1; // a second party's role
        _expectInvalid(item, _keys(leadKey, collabKey));
    }

    function test_invalidItem_zeroContentHash() public {
        _expectInvalid(_item(lead, bytes32(0)), _keys(leadKey));
    }

    function test_invalidItem_originalWithEditionTerms() public {
        PackageItem memory item = _item(lead, SHA_A);
        item.edition.maxCount = 1;
        _expectInvalid(item, _keys(leadKey));
        // Each of the other terms on its own.
        item.edition.maxCount = 0;
        item.edition.params = hex"01";
        _expectInvalid(item, _keys(leadKey));
        item.edition.params = "";
        item.edition.currency = address(1);
        _expectInvalid(item, _keys(leadKey));
        item.edition.currency = address(0);
        item.edition.saleKind = SaleKind.UNIFORM_AUCTION;
        _expectInvalid(item, _keys(leadKey));
    }

    function test_invalidItem_masterEditionTerms() public {
        PackageItem memory item = _masterItem(SHA_A);
        item.edition.saleKind = 0;
        _expectInvalid(item, _keys(leadKey, collabKey));
        item = _masterItem(item.contentHash);
        item.edition.maxCount = 0; // no creator cap
        _expectValid(item, _keys(leadKey, collabKey));
    }

    /// @dev The registry applies the same edition-terms rule as 6529 Stream Editions
    ///      (`EditionRules.isValid`), so a master whose edition could never be created is refused
    ///      at `consume`, before it can mint. The rule is generic (ADR 0005, owner decision 14):
    ///      any nonzero kind, any currency and params within the bound pass, and the kind's
    ///      adapter checks them when it opens.
    function test_invalidItem_masterEditionTermsSharedRule() public {
        uint256[] memory keys = _keys(leadKey, collabKey);
        PackageItem memory item = _masterItem(SHA_A);
        item.edition.saleKind = keccak256("RAFFLE");
        item.edition.params = new bytes(EditionRules.MAX_PARAMS_BYTES + 1);
        _expectInvalid(item, keys);
        item.edition.params = abi.encode(uint256(1 ether));
        item.edition.currency = CURRENCY_DEFAULT;
        _expectValid(item, keys);
    }

    function test_invalidItem_parties() public {
        PackageItem memory item = _item(lead, SHA_A);
        item.parties = new Party[](0);
        _expectInvalidWith(
            item,
            _keys(leadKey),
            abi.encodeWithSelector(IPackageRegistry.InvalidLeadArtist.selector)
        );
        item = _masterItem(item.contentHash);
        item.parties[0].role = uint8(PartyRole.COLLABORATOR); // the lead must be an ARTIST
        _expectInvalid(item, _keys(leadKey, collabKey));
        item = _masterItem(item.contentHash);
        item.parties[1] = Party(lead, uint8(PartyRole.COLLABORATOR)); // listed twice
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
        item.parties[0] = Party(lead, uint8(PartyRole.ARTIST));
        item.parties[1] = Party(next, uint8(PartyRole.ARTIST));
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
            item.parties[i] = Party(vm.addr(0x100 + i), uint8(PartyRole.ARTIST));
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
        // Nor to more than 100,000.
        item = _masterItem(c);
        item.payees[0].share += 1;
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
        // One whose ID is above every party's: a match is equality, not an order.
        item = _masterItem(c);
        item.payees[1].artistId = type(uint256).max;
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

    function test_validItem_fewerPayeesThanParties() public {
        // The collaborator is credited but not paid: one payee for two parties.
        PackageItem memory item = _masterItem(SHA_A);
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(_id(lead), address(0), 100_000);
        _expectValid(item, _keys(leadKey, collabKey));
    }

    /// @dev C15: the lead is paid only through its account (artist-resolved), so a freeze of
    ///      the lead's account holds its payout; a fixed payee naming the lead is refused, alone
    ///      or beside its artist-resolved payee. Collaborators keep fixed payees. Fails without
    ///      the change: both items were valid.
    function test_invalidItem_leadPaidAsAFixedPayee() public {
        PackageItem memory item = _masterItem(SHA_A);
        item.payees = new ISplitWallet.Payee[](2);
        item.payees[0] = ISplitWallet.Payee(0, collab, 20_000);
        item.payees[1] = ISplitWallet.Payee(0, lead, 80_000);
        if (lead < collab) (item.payees[0], item.payees[1]) = (item.payees[1], item.payees[0]);
        _expectInvalid(item, _keys(leadKey, collabKey));
        item = _masterItem(SHA_A);
        item.payees = new ISplitWallet.Payee[](2);
        item.payees[0] = ISplitWallet.Payee(0, lead, 20_000);
        item.payees[1] = ISplitWallet.Payee(_id(lead), address(0), 80_000);
        _expectInvalid(item, _keys(leadKey, collabKey));
    }

    function test_validItem_partyPaidBothWays() public {
        // A party may be both a fixed and an artist-resolved payee: distinct canonical keys.
        PackageItem memory item = _masterItem(SHA_A);
        item.payees[1].artistId = _id(collab);
        _expectValid(item, _keys(leadKey, collabKey));
    }

    /// @dev An item with no sale kind is refused by the policy's item rules, before the consume.
    function test_invalidItem_noSaleKind() public {
        PackageItem memory item = _item(lead, SHA_A);
        item.sale.saleKind = 0;
        _expectInvalidWith(
            item, _keys(leadKey), abi.encodeWithSelector(IPackageRegistry.InvalidItemSale.selector)
        );
    }

    /// @dev A license ID outside the `SpdxId` rule (empty, a character it does not allow, longer
    ///      than the limit) is refused, as `WorkRecords` refuses it at relicense.
    function test_invalidItem_licenseId() public {
        bytes memory reason = abi.encodeWithSelector(IPackageRegistry.InvalidLicenseId.selector);
        PackageItem memory item = _item(lead, SHA_A);
        item.license.spdxId = "";
        _expectInvalidWith(item, _keys(leadKey), reason);
        item.license.spdxId = "CC0 1.0";
        _expectInvalidWith(item, _keys(leadKey), reason);
        // One byte over the limit, every byte allowed: only the length check refuses it.
        bytes memory long = new bytes(Limits.MAX_LICENSE_ID_BYTES + 1);
        for (uint256 i; i < long.length; ++i) {
            long[i] = "A";
        }
        item.license.spdxId = string(long);
        _expectInvalidWith(item, _keys(leadKey), reason);
    }

    /// @dev A request that is not `abi.encode(StreamMintRequest)` (too short, or a head that
    ///      does not point at offset 32) is refused before anything is read from it.
    function test_authorize_revertsMalformedRequest() public {
        bytes memory reason = abi.encodeWithSelector(IPackageRegistry.InvalidMintRequest.selector);
        vm.prank(address(minter));
        vm.expectRevert(reason);
        registry.authorize(stream, new bytes(159));
        (bytes32 root, PackageItem memory item,) = _ready(SHA_A);
        bytes memory request = abi.encode(
            StreamMintRequest(root, item, new bytes32[](0), _move(leadKey, root, _hash(item), 0))
        );
        request[31] = bytes1(uint8(64)); // the head no longer points at offset 32
        vm.prank(address(minter));
        vm.expectRevert(reason);
        registry.authorize(stream, request);
        request[31] = bytes1(uint8(0)); // nor below it
        vm.prank(address(minter));
        vm.expectRevert(reason);
        registry.authorize(stream, request);
    }

    /// @dev The quote refuses product terms that cannot yield a valid royalty payee list: a
    ///      royalty rate above the denominator, a fee share at it, or a fee share whose recipient
    ///      is zero or the seller wallet itself. Valid fee terms pass and are quoted as they are.
    function test_authorize_revertsInvalidWorkTerms() public {
        CurationPolicyStub stub = _policyStub;
        address seller = address(0x5E11E7);
        address fee = makeAddr("feeRecipient");
        ProductEconomics[5] memory bad = [
            ProductEconomics(address(0), 0, 100_001),
            ProductEconomics(fee, 100_000, 5000),
            ProductEconomics(fee, 100_001, 5000),
            ProductEconomics(address(0), 1, 5000),
            ProductEconomics(seller, 1, 5000)
        ];
        (bytes32 root, PackageItem memory item,) = _ready(SHA_A);
        bytes memory request = abi.encode(
            StreamMintRequest(root, item, new bytes32[](0), _move(leadKey, root, _hash(item), 0))
        );
        for (uint256 i; i < bad.length; ++i) {
            stub.set(bad[i]);
            vm.prank(address(minter));
            vm.expectRevert(IPackageRegistry.InvalidWorkTerms.selector);
            registry.authorize(stream, request);
        }
        stub.set(ProductEconomics(fee, 99_999, 100_000));
        vm.prank(address(minter));
        (MintFacts memory f, MintTerms memory r) = registry.authorize(stream, request);
        assertEq(r.seller, seller);
        assertEq(f.seller, seller);
        assertEq(r.feeRecipient, fee);
        assertEq(r.feeShare, 99_999);
        assertEq(f.royaltyRate, 100_000);
        assertEq(f.royaltyReceiver, stub.royaltyWallet(), "the royalty wallet, not the seller");
    }

    // -------------------------------------------------------------------------- preview

    /// @dev `preview` quotes the terms `authorize` would lock without consuming anything: the
    ///      seller wallet, the product's fee terms, the item's sale terms, and the lead's active
    ///      authority as creator (zero while the account is frozen). Anyone may call it.
    function test_preview_quotesWithoutConsuming() public {
        CurationPolicyStub stub = _policyStub;
        address fee = makeAddr("feeRecipient");
        stub.set(ProductEconomics(fee, 10_000, 7500));
        (bytes32 root, PackageItem memory item,) = _ready(SHA_A);
        bytes memory request = abi.encode(
            StreamMintRequest(root, item, new bytes32[](0), _move(leadKey, root, _hash(item), 0))
        );
        vm.prank(makeAddr("anyone"));
        (MintFacts memory f, MintTerms memory t) = registry.preview(stream, request);
        assertEq(t.seller, address(0x5E11E7));
        assertEq(f.royaltyRate, 7500);
        assertEq(f.royaltyReceiver, stub.royaltyWallet());
        assertEq(t.feeRecipient, fee);
        assertEq(t.feeShare, 10_000);
        assertEq(t.saleKind, item.sale.saleKind);
        assertEq(t.params, item.sale.params);
        assertEq(t.creator, lead);
        assertFalse(registry.isMoveNonceUsed(_id(lead), 0), "nonce unspent");
        assertEq(registry.consumedItemOf(SHA_A), bytes32(0), "nothing consumed");
        artists.setFrozen(_id(lead), true);
        (, t) = registry.preview(stream, request);
        assertEq(t.creator, address(0));
        // The quote is still consumable afterwards.
        artists.setFrozen(_id(lead), false);
        _consume(root, item, new bytes32[](0), _move(leadKey, root, _hash(item), 0));
        assertEq(registry.consumedItemOf(SHA_A), _hash(item));
    }

    /// @dev `preview` refuses what `authorize` would: a malformed request, the item rules, a
    ///      lead artist with no identity, and invalid product terms.
    function test_preview_reverts() public {
        address c = stream;
        vm.expectRevert(IPackageRegistry.InvalidMintRequest.selector);
        registry.preview(c, new bytes(159));
        PackageItem memory item = _item(lead, SHA_A);
        bytes32 root = WorksHashing.leaf(_hash(item));
        MoveAuthorization memory none;
        // The lead has no identity yet: nobody has accepted a package for this account.
        vm.expectRevert(IPackageRegistry.InvalidLeadArtist.selector);
        registry.preview(c, abi.encode(StreamMintRequest(root, item, new bytes32[](0), none)));
        item.sale.saleKind = 0;
        vm.expectRevert(IPackageRegistry.InvalidItemSale.selector);
        registry.preview(c, abi.encode(StreamMintRequest(root, item, new bytes32[](0), none)));
        item = _item(lead, SHA_A);
        _register(root);
        _accept(root, leadKey);
        CurationPolicyStub stub = _policyStub;
        stub.set(ProductEconomics(address(0), 1, 5000));
        vm.expectRevert(IPackageRegistry.InvalidWorkTerms.selector);
        registry.preview(stream, abi.encode(StreamMintRequest(root, item, new bytes32[](0), none)));
    }

    // ------------------------------------------------------- acceptPackage: registry answer

    /// @dev The package registry assigns the artist ID `uint160(account)` before it registers
    ///      the identity; an artist registry that answers with another ID is refused
    ///      (`InvalidDependency`), so no acceptance is recorded under an ID the registry does not
    ///      hold. Defensive: the pinned artist registry always returns the ID asked for.
    function test_acceptPackage_revertsWhenTheArtistRegistryMisnumbers() public {
        MisnumberingArtistRegistry odd = new MisnumberingArtistRegistry();
        PackageRegistry reg = new PackageRegistry(
            address(manager),
            ICurationVerifier(address(verifier)),
            address(verifier).codehash,
            address(
                new Directory(address(manager), address(odd), address(0), address(0), address(0))
            ),
            IEconomicsResolver(address(_policyStub)),
            address(0),
            keccak256("cc0 text file")
        );
        bytes32 root = keccak256("misnumbered");
        reg.registerPackage(root, EVIDENCE, _attestation(signerKey1, root, EVIDENCE));
        PartyAcceptance memory a = _acceptance(lead);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(odd)));
        reg.acceptPackage(root, a, "");
        assertEq(reg.acceptedAs(root, lead), 0);
    }

    /// @dev The same refusal for an ID below the one asked for.
    function test_acceptPackage_revertsWhenTheArtistRegistryAnswersALowerId() public {
        UndernumberingArtistRegistry odd = new UndernumberingArtistRegistry();
        PackageRegistry reg = new PackageRegistry(
            address(manager),
            ICurationVerifier(address(verifier)),
            address(verifier).codehash,
            address(
                new Directory(address(manager), address(odd), address(0), address(0), address(0))
            ),
            IEconomicsResolver(address(_policyStub)),
            address(0),
            keccak256("cc0 text file")
        );
        bytes32 root = keccak256("undernumbered");
        reg.registerPackage(root, EVIDENCE, _attestation(signerKey1, root, EVIDENCE));
        PartyAcceptance memory a = _acceptance(lead);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(odd)));
        reg.acceptPackage(root, a, "");
    }

    /// @dev A proof of exactly `Limits.MAX_PROOF_DEPTH` nodes places an item; one more does not.
    function test_isApprovedItem_aProofAtTheMaximumDepth() public {
        bytes32 itemHash = keccak256("deep item");
        bytes32[] memory proof = new bytes32[](Limits.MAX_PROOF_DEPTH);
        bytes32 node = WorksHashing.leaf(itemHash);
        for (uint256 i; i < proof.length; ++i) {
            proof[i] = keccak256(abi.encode("sibling", i));
            node = _pairHash(node, proof[i]);
        }
        _register(node);
        assertTrue(registry.isApprovedItem(node, itemHash, proof));
    }

    function _pairHash(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    // ------------------------------------------------------------------- releaseContent

    /// @dev Burns `lead`'s item for `SHA_A` in the minter's custody; returns its root, item and
    ///      the burned token.
    function _burned() internal returns (bytes32 root, PackageItem memory item, uint256 tokenId) {
        MoveAuthorization memory move;
        (root, item, move) = _ready(SHA_A);
        tokenId = _mintAndBurn(root, item, new bytes32[](0), move);
    }

    /// @dev A second item for the same content by `artistKey`, ready to move at nonce 0.
    function _rival(uint256 artistKey)
        internal
        returns (bytes32 root, PackageItem memory item, MoveAuthorization memory move)
    {
        item = _item(vm.addr(artistKey), SHA_A);
        item.mediaHash = keccak256("the rival's media list");
        root = WorksHashing.leaf(_hash(item));
        _register(root);
        _accept(root, artistKey);
        move = _move(artistKey, root, _hash(item), 0);
    }

    function test_burnedContent_refusedWithoutARelease() public {
        (bytes32 root, PackageItem memory item, uint256 tokenId) = _burned();
        assertEq(core.tokenOfContent(SHA_A), tokenId);
        assertEq(registry.consumedItemOf(SHA_A), _hash(item), "still the burned item's");
        // Neither the burned item again (a fresh nonce) nor another item of the same content.
        MoveAuthorization memory again = _move(leadKey, root, _hash(item), 1);
        vm.expectRevert(abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, SHA_A, tokenId));
        _authorize(root, item, new bytes32[](0), again);
        (bytes32 r2, PackageItem memory i2, MoveAuthorization memory m2) = _rival(collabKey);
        vm.expectRevert(abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, SHA_A, tokenId));
        _authorize(r2, i2, new bytes32[](0), m2);
    }

    function test_releaseContent_recordsTheReleaseAndBarsTheItem() public {
        (, PackageItem memory item, uint256 tokenId) = _burned();
        _accept(keccak256("collab registers"), collabKey, true);
        vm.expectEmit(address(registry));
        emit IMintPolicy.ContentReleased(stream, tokenId, SHA_A, _id(collab));
        vm.prank(guardian);
        registry.releaseContent(stream, tokenId, SHA_A, _id(collab));
        assertEq(registry.releasedTo(stream, SHA_A), _id(collab));
        assertTrue(registry.isBarred(_hash(item)));
        assertEq(registry.consumedItemOf(SHA_A), bytes32(0), "released");
    }

    function test_releaseContent_onlyTheNetwork() public {
        (,, uint256 tokenId) = _burned();
        address[3] memory callers = [admin, successor, lead];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManaged.AccessManagedUnauthorized.selector, callers[i]
                )
            );
            registry.releaseContent(stream, tokenId, SHA_A, _id(lead));
        }
    }

    /// @dev Only a burned token of the bound Stream, with the content `tokenOfContent` names
    ///      for it, and only for a registered artist.
    function test_releaseContent_refusesAnythingButABurnedTokensOwnContent() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        (,, uint256 live) =
            minter.mint(address(registry), stream, _request(root, item, new bytes32[](0), move));
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, SHA_A, live));
        registry.releaseContent(stream, live, SHA_A, _id(lead));
        vm.stopPrank();
        minter.burn(stream, live);
        vm.startPrank(guardian);
        // Another content hash than the token's.
        vm.expectRevert(abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, SHA_B, live));
        registry.releaseContent(stream, live, SHA_B, _id(lead));
        // A token ID that never existed, or zero.
        vm.expectRevert(abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, SHA_A, uint256(9)));
        registry.releaseContent(stream, 9, SHA_A, _id(lead));
        vm.expectRevert(abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, SHA_A, uint256(0)));
        registry.releaseContent(stream, 0, SHA_A, _id(lead));
        // Another token contract.
        address other = address(new MockBoundCaller(type(IStream).interfaceId));
        vm.expectRevert(abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, SHA_A, live));
        registry.releaseContent(other, live, SHA_A, _id(lead));
        // An unknown beneficiary.
        uint256 unknown = _id(makeAddr("nobody"));
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, unknown));
        registry.releaseContent(stream, live, SHA_A, unknown);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.UnknownArtist.selector, uint256(1) << 160)
        );
        registry.releaseContent(stream, live, SHA_A, uint256(1) << 160);
        vm.stopPrank();
        assertEq(registry.releasedTo(stream, SHA_A), 0);
    }

    function test_releasedContent_mintsOnlyForTheBeneficiary() public {
        (,, uint256 tokenId) = _burned();
        (bytes32 r2, PackageItem memory i2, MoveAuthorization memory m2) = _rival(collabKey);
        vm.prank(guardian);
        registry.releaseContent(stream, tokenId, SHA_A, _id(lead));
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.ContentReserved.selector, SHA_A, _id(lead))
        );
        _authorize(r2, i2, new bytes32[](0), m2);
        assertFalse(registry.isMoveNonceUsed(_id(collab), 0));
        // The beneficiary's own other item of that content mints.
        PackageItem memory mine = _item(lead, SHA_A);
        mine.recordFileId = keccak256("the rightful record");
        bytes32 root = WorksHashing.leaf(_hash(mine));
        _register(root);
        _accept(root, leadKey);
        (bytes32 h,) = _consume(root, mine, new bytes32[](0), _move(leadKey, root, _hash(mine), 5));
        assertEq(registry.consumedItemOf(SHA_A), h);
    }

    function test_releasedContent_neverByTheBarredItem() public {
        (bytes32 root, PackageItem memory item, uint256 tokenId) = _burned();
        vm.prank(guardian);
        registry.releaseContent(stream, tokenId, SHA_A, _id(lead));
        MoveAuthorization memory again = _move(leadKey, root, _hash(item), 1);
        vm.expectRevert(abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, SHA_A, tokenId));
        _authorize(root, item, new bytes32[](0), again);
    }

    /// @dev A release names the burned token: once its content minted again it is used up, and
    ///      a second burn needs a new release.
    function test_release_isUsedUpByTheNextMint() public {
        (,, uint256 first) = _burned();
        (bytes32 r2, PackageItem memory i2, MoveAuthorization memory m2) = _rival(collabKey);
        vm.prank(guardian);
        registry.releaseContent(stream, first, SHA_A, _id(collab));
        (,, uint256 second) =
            minter.mint(address(registry), stream, _request(r2, i2, new bytes32[](0), m2));
        assertEq(registry.releasedTo(stream, SHA_A), 0, "used up");
        assertEq(registry.consumedItemOf(SHA_A), _hash(i2));
        minter.burn(stream, second);
        PackageItem memory third = _item(collab, SHA_A);
        third.recordFileId = keccak256("third");
        bytes32 r3 = WorksHashing.leaf(_hash(third));
        _register(r3);
        _accept(r3, collabKey);
        MoveAuthorization memory m3 = _move(collabKey, r3, _hash(third), 1);
        vm.expectRevert(abi.encodeWithSelector(IMintPolicy.ContentUsed.selector, SHA_A, second));
        _authorize(r3, third, new bytes32[](0), m3);
        vm.prank(guardian);
        registry.releaseContent(stream, second, SHA_A, _id(collab));
        _authorize(r3, third, new bytes32[](0), m3);
    }

    /// @dev A release can be replaced while the token's content is still unminted.
    function test_release_canBeReplacedBeforeUse() public {
        (,, uint256 tokenId) = _burned();
        _accept(keccak256("collab registers"), collabKey, true);
        vm.startPrank(guardian);
        registry.releaseContent(stream, tokenId, SHA_A, _id(lead));
        registry.releaseContent(stream, tokenId, SHA_A, _id(collab));
        vm.stopPrank();
        assertEq(registry.releasedTo(stream, SHA_A), _id(collab));
    }

    // -------------------------------------------------------------------- facts and terms

    /// @dev With no network share the royalty receiver is the seller; the rate is the
    ///      economics' rate.
    function test_facts_royaltyReceiverIsTheSellerAtZeroShare() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        (MintFacts memory f, MintTerms memory t) = _authorize(root, item, new bytes32[](0), move);
        assertEq(f.royaltyReceiver, _policyStub.seller());
        assertEq(f.seller, _policyStub.seller());
        assertEq(t.feeShare, 0);
        assertEq(f.royaltyRate, 5000);
        assertEq(core.workOf(1).royaltyReceiver, _policyStub.seller());
        assertEq(core.workOf(1).royaltyRate, 5000);
    }

    function test_facts_artistSeed() public {
        PackageItem memory item = _item(lead, SHA_A);
        item.seedPolicy = uint8(SeedPolicy.ARTIST);
        item.seed = keccak256("artist seed");
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        _accept(root, leadKey);
        (MintFacts memory f,) =
            _authorize(root, item, new bytes32[](0), _move(leadKey, root, _hash(item), 0));
        assertEq(f.seed, keccak256("artist seed"));
        assertEq(core.workOf(1).seed, keccak256("artist seed"));
    }

    function test_facts_vrfSeedOnlyOnceDelivered() public {
        PackageItem memory item = _item(lead, SHA_A);
        item.seedPolicy = uint8(SeedPolicy.VRF);
        bytes32 root = WorksHashing.leaf(_hash(item));
        _register(root);
        _accept(root, leadKey);
        MoveAuthorization memory move = _move(leadKey, root, _hash(item), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.SeedNotDelivered.selector, _hash(item))
        );
        _authorize(root, item, new bytes32[](0), move);
        entropy.deliver(SHA_A, keccak256("vrf seed"));
        (MintFacts memory f,) = _authorize(root, item, new bytes32[](0), move);
        assertEq(f.seed, keccak256("vrf seed"));
        assertEq(core.workOf(1).seed, keccak256("vrf seed"));
    }

    /// @dev With no entropy module a VRF item is refused by the item rules.
    function test_facts_vrfRefusedWithoutAnEntropyModule() public {
        vm.prank(guardian);
        registry.setEntropyModule(address(entropy), address(0));
        PackageItem memory item = _item(lead, SHA_A);
        item.seedPolicy = uint8(SeedPolicy.VRF);
        _expectInvalidWith(
            item,
            _keys(leadKey),
            abi.encodeWithSelector(IPackageRegistry.InvalidSeedPolicy.selector)
        );
    }

    function test_setEntropyModule() public {
        EntropyStub next = new EntropyStub();
        assertEq(registry.entropyModule(), address(entropy));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, admin)
        );
        registry.setEntropyModule(address(entropy), address(next));
        vm.prank(guardian);
        vm.expectRevert(IPackageRegistry.ExpectedValueMismatch.selector);
        registry.setEntropyModule(address(next), address(next));
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(verifier))
        );
        registry.setEntropyModule(address(entropy), address(verifier));
        vm.expectEmit(address(registry));
        emit IPackageRegistry.EntropyModuleSet(address(entropy), address(next));
        vm.prank(guardian);
        registry.setEntropyModule(address(entropy), address(next));
        assertEq(registry.entropyModule(), address(next));
    }

    /// @dev The sale is in ETH: `CURRENCY_ETH` or `CURRENCY_DEFAULT` pass, any other refused.
    function test_item_saleCurrencyIsEth() public {
        PackageItem memory item = _item(lead, SHA_A);
        item.sale.currency = makeAddr("someToken");
        _expectInvalidWith(
            item, _keys(leadKey), abi.encodeWithSelector(IPackageRegistry.InvalidItemSale.selector)
        );
        item.sale.currency = CURRENCY_DEFAULT;
        _expectValid(item, _keys(leadKey));
        item = _item(collab, SHA_B);
        item.sale.currency = CURRENCY_ETH;
        _expectValid(item, _keys(collabKey));
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

    /// Regression: DEPS-6 (docs/security/internal-review-2026-10.md)
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

    /// @dev Code whose hash sorts below the pinned one is refused as well as code above it.
    function test_registerPackage_refusesAVerifierCodeHashBelowThePin() public {
        bytes32 pinned = address(verifier).codehash;
        bytes memory lower;
        for (uint256 i; lower.length == 0; ++i) {
            bytes memory code = abi.encodePacked(bytes1(0x60), bytes1(uint8(i)), bytes1(0x00));
            if (keccak256(code) < pinned) lower = code;
        }
        vm.etch(address(verifier), lower);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.DependencyCodeChanged.selector, address(verifier))
        );
        registry.registerPackage(keccak256("root"), EVIDENCE, "");
    }

    function test_setVerifier_keepsRegisteredApprovals() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) = _ready(SHA_A);
        _swapVerifier(new Eip712CurationVerifier(address(manager)));
        _consume(root, item, new bytes32[](0), move);
    }

    /// Regression: SIGS-2 (docs/security/internal-review-2026-10.md)
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
            vm.prank(address(minter));
            vm.expectRevert(
                abi.encodeWithSelector(
                    IPackageRegistry.ItemNotInPackage.selector, root, _hash(item)
                )
            );
            _policyCall(registry, root, item, bad, move);
            // Dropping the last element also fails.
            bytes32[] memory shorter = new bytes32[](proof.length - 1);
            for (uint256 i; i < shorter.length; ++i) {
                shorter[i] = proof[i];
            }
            vm.prank(address(minter));
            vm.expectRevert(
                abi.encodeWithSelector(
                    IPackageRegistry.ItemNotInPackage.selector, root, _hash(item)
                )
            );
            _policyCall(registry, root, item, shorter, move);
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
        vm.prank(address(minter));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPackageRegistry.ItemNotInPackage.selector, root, _hash(outsider)
            )
        );
        _policyCall(registry, root, outsider, proof, move);
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
        registry.acceptPackage(root, a, _pf(key, _sig(key, registry.acceptanceDigest(root, a))));
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
        vm.prank(address(minter));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.InvalidItem.selector, _hash(item)));
        _policyCall(registry, root, item, new bytes32[](0), move);
    }

    function _expectInvalidWith(PackageItem memory item, uint256[] memory keys, bytes memory reason)
        internal
    {
        bytes32 root = _prepare(item, keys);
        MoveAuthorization memory move = _move(keys[0], root, _hash(item), 0);
        vm.prank(address(minter));
        vm.expectRevert(reason);
        _policyCall(registry, root, item, new bytes32[](0), move);
    }

    function _expectValid(PackageItem memory item, uint256[] memory keys) internal {
        bytes32 root = _prepare(item, keys);
        _consume(root, item, new bytes32[](0), _move(keys[0], root, _hash(item), 0));
        assertEq(registry.consumedItemOf(item.contentHash), _hash(item));
    }
}
