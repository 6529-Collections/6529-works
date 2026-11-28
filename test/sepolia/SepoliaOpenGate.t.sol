// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { SepoliaOpenGate } from "script/sepolia/SepoliaOpenGate.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { PartyAcceptance } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { EditionAuctionStack } from "../integration/EditionAuctionStack.sol";

/// @notice `SepoliaOpenGate` (a Sepolia test convenience, `script/sepolia/`) on the deployed
///         stack: with the two roles the network grants it, any wallet creates a collection,
///         registers a package with no curation signer, and runs the curated 1/1 and edition
///         sale to the end; and what the gate cannot be used for.
contract SepoliaOpenGateTest is EditionAuctionStack {
    SepoliaOpenGate internal gate;
    address internal artist;
    address internal stranger = makeAddr("stranger");
    address internal collector1 = makeAddr("collector1");
    address internal collector2 = makeAddr("collector2");

    function setUp() public override {
        super.setUp();
        gate = new SepoliaOpenGate(address(verifier), address(stream));
        artist = _actor("freshArtist");
        _grant(Roles.CURATION_SIGNER);
        _grant(Roles.PLATFORM);
    }

    /// @dev The network grants `role` to the gate directly: no schedule, no wait.
    function _grant(uint64 role) internal {
        vm.prank(network);
        manager.grantRole(role, address(gate), 0);
    }

    function _register(bytes32 root) internal {
        (bytes32 evidence, bytes memory attestation) = gate.attestationOf(root);
        vm.prank(stranger);
        registry.registerPackage(root, evidence, attestation);
    }

    // ------------------------------------------------------------------ the chain

    function test_OpenGate_DeploysOnlyOnSepoliaOrALocalChain() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(SepoliaOpenGate.NotATestChain.selector, 1));
        new SepoliaOpenGate(address(verifier), address(stream));
        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(SepoliaOpenGate.NotATestChain.selector, 8453));
        new SepoliaOpenGate(address(verifier), address(stream));
        vm.chainId(11_155_111);
        new SepoliaOpenGate(address(verifier), address(stream));
        vm.chainId(31_337);
        new SepoliaOpenGate(address(verifier), address(stream));
    }

    function test_OpenGate_ConstructorRefusesAnAddressWithNoCode() public {
        vm.expectRevert(abi.encodeWithSelector(SepoliaOpenGate.NotAContract.selector, stranger));
        new SepoliaOpenGate(stranger, address(stream));
        vm.expectRevert(abi.encodeWithSelector(SepoliaOpenGate.NotAContract.selector, stranger));
        new SepoliaOpenGate(address(verifier), stranger);
    }

    /// @dev A gate that found itself on another chain (the same state under another chain ID)
    ///      approves nothing and creates nothing.
    function test_OpenGate_AnswersNothingOnAnotherChain() public {
        bytes32 root = keccak256("root");
        bytes32 digest = verifier.approvalDigest(
            root, gate.evidenceOf(root), verifier.signerEpoch(address(gate))
        );
        assertEq(gate.isValidSignature(digest, abi.encodePacked(root)), bytes4(0x1626ba7e));
        vm.chainId(1);
        digest = verifier.approvalDigest(
            root, gate.evidenceOf(root), verifier.signerEpoch(address(gate))
        );
        assertEq(gate.isValidSignature(digest, abi.encodePacked(root)), bytes4(0xffffffff));
        vm.expectRevert(abi.encodeWithSelector(SepoliaOpenGate.NotATestChain.selector, 1));
        gate.createCollection("x", bytes32(0));
    }

    // ------------------------------------------------------------------ the open path

    /// @dev The network grants both roles at once: it is their admin with no delay.
    function test_OpenGate_TheNetworkGrantsBothRolesWithNoWait() public view {
        (bool signer, uint32 signerDelay) = manager.hasRole(Roles.CURATION_SIGNER, address(gate));
        (bool platformRole, uint32 platformDelay) = manager.hasRole(Roles.PLATFORM, address(gate));
        assertTrue(signer && platformRole, "both roles");
        assertEq(signerDelay + platformDelay, 0, "no execution delay");
        assertTrue(verifier.isSignerActive(address(gate)), "an active curation signer");
        assertEq(manager.getRoleAdmin(Roles.CURATION_SIGNER), Roles.NETWORK);
        assertEq(manager.getRoleAdmin(Roles.PLATFORM), Roles.NETWORK);
        (, uint32 networkDelay) = manager.hasRole(Roles.NETWORK, network);
        assertEq(networkDelay, 0, "the network acts as their admin at once");
    }

    /// @dev A fresh wallet, with no role and no account: a collection, a package of one edition
    ///      master registered by a stranger with the gate's approval, the artist's acceptance, a
    ///      start with a bid, the edition sale, a second bidder on both, settlement and claims.
    function test_OpenGate_AnyWalletRunsTheCuratedPathToTheEnd() public {
        vm.expectEmit(address(gate));
        emit SepoliaOpenGate.CollectionOpened(2, artist, "Fresh", keccak256("fresh metadata"));
        vm.prank(artist);
        uint256 collection = gate.createCollection("Fresh", keccak256("fresh metadata"));
        assertEq(collection, 2, "the next collection of Stream");
        assertEq(stream.collectionCount(), 2);

        Work[] memory works = _one(_asMaster(_work(artist, collection), 0));
        bytes32 root = _rootOf(works);
        vm.expectEmit(address(registry));
        emit IPackageRegistry.PackageRegistered(
            root, gate.evidenceOf(root), address(verifier), address(gate)
        );
        _register(root);
        (IPackageRegistry.PackageStatus status, bytes32 evidence, address signer) =
            registry.packageOf(root);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.APPROVED));
        assertEq(evidence, gate.evidenceOf(root));
        assertEq(signer, address(gate), "the gate is the approving signer");

        _accept(root, artist);
        assertEq(accounts.artistIdOf(artist), uint160(artist), "the acceptance made the account");

        bytes memory request = _mintData(root, works, 0);
        vm.deal(collector1, OPENING_BID);
        vm.prank(collector1);
        uint256 oneSaleId =
            auction.startWithBid{ value: OPENING_BID }(address(stream), request, address(0));
        uint256 tokenId = stream.totalMinted();
        assertEq(stream.workOf(tokenId).artistId, uint160(artist), "the wallet is the artist");
        assertEq(stream.workOf(tokenId).collectionId, collection);
        _open(tokenId, works[0]);

        uint256 saleId = editionAuction.open(address(editions), tokenId, _openData(root, works, 0));
        uint256 bidId = _editionBid(saleId, collector2, 20, 2);
        _ethBid(oneSaleId, collector2, auction.minimumBid(oneSaleId));
        assertEq(auction.claimable(collector1), OPENING_BID, "the outbid bidder is credited");

        _settleAtEnd(oneSaleId);
        assertEq(stream.ownerOf(tokenId), collector2, "the 1/1 is the high bidder's");
        _settleEditions(saleId);
        vm.prank(collector2);
        (uint256 won,) = editionAuction.claimBid(saleId, bidId, collector2);
        assertEq(won, 2);
        assertEq(editions.balanceOf(collector2, tokenId), 2, "two copies of the edition");
        vm.prank(collector1);
        assertEq(auction.claim(collector1), OPENING_BID);
        assertEq(collector1.balance, OPENING_BID, "the refund is pulled");

        uint256 before = artist.balance;
        vm.prank(artist);
        ledger.release(works[0].item.payees, bytes32(0), CURRENCY_ETH, 0);
        assertGt(artist.balance, before, "the artist is paid from the seller vault");
    }

    /// @dev Whoever registers a root through the gate first leaves the same record; the second
    ///      registration finds the package there.
    function test_OpenGate_RegistrationIsTheSameWhoeverSendsIt() public {
        bytes32 root = _rootOf(_one(_work(artist, collectionId)));
        (bytes32 evidence, bytes memory attestation) = gate.attestationOf(root);
        vm.prank(collector1);
        registry.registerPackage(root, evidence, attestation);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageExists.selector, root));
        registry.registerPackage(root, evidence, attestation);
        (, bytes32 stored,) = registry.packageOf(root);
        assertEq(stored, gate.evidenceOf(root));
    }

    /// @dev The two pure helpers answer what `WorksHashing` computes.
    function test_OpenGate_HashHelpersMatchWorksHashing() public {
        Work memory w = _asMaster(_work(artist, collectionId), 3);
        (bytes32 itemHash, bytes32 root) = gate.oneItemPackage(w.item);
        assertEq(itemHash, WorksHashing.itemHash(w.item));
        assertEq(root, _rootOf(_one(w)));
        assertEq(gate.mediaHashOf(w.media), w.item.mediaHash);
    }

    // ------------------------------------------------------------------ without the roles

    function test_OpenGate_WithoutTheRolesNothingIsOpen() public {
        vm.startPrank(network);
        manager.revokeRole(Roles.CURATION_SIGNER, address(gate));
        manager.revokeRole(Roles.PLATFORM, address(gate));
        vm.stopPrank();
        bytes32 root = _rootOf(_one(_work(artist, collectionId)));
        (bytes32 evidence, bytes memory attestation) = gate.attestationOf(root);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, root));
        registry.registerPackage(root, evidence, attestation);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(gate))
        );
        gate.createCollection("Fresh", bytes32(0));
    }

    /// @dev The network closes the gate with the verifier's `disableSigner`, and stops the
    ///      packages it approved before with `killSignerApprovals`.
    function test_OpenGate_TheNetworkClosesItAndStopsItsPackages() public {
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _rootOf(works);
        _register(root);
        _accept(root, artist);

        _asNetwork(address(verifier), abi.encodeCall(verifier.disableSigner, (address(gate))));
        bytes32 other = keccak256("another root");
        (bytes32 evidence, bytes memory attestation) = gate.attestationOf(other);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, other));
        registry.registerPackage(other, evidence, attestation);

        _asNetwork(address(registry), abi.encodeCall(registry.killSignerApprovals, (address(gate))));
        bytes memory request = _mintData(root, works, 0);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        auction.start(address(stream), request);
    }

    // ------------------------------------------------------------------ what it cannot do

    /// @dev The gate approves one kind of digest only: the verifier's approval digest of the
    ///      root in the signature, with the gate's own evidence hash, at its current epoch.
    function test_OpenGate_SignsNothingButItsOwnPackageApproval() public view {
        bytes32 root = keccak256("root");
        uint256 epoch = verifier.signerEpoch(address(gate));
        bytes32 good = verifier.approvalDigest(root, gate.evidenceOf(root), epoch);
        bytes4 valid = IERC1271.isValidSignature.selector;
        bytes4 invalid = 0xffffffff;
        assertEq(gate.isValidSignature(good, abi.encodePacked(root)), valid);
        // Another root in the signature, another evidence hash, another epoch.
        assertEq(gate.isValidSignature(good, abi.encodePacked(keccak256("other"))), invalid);
        assertEq(
            gate.isValidSignature(
                verifier.approvalDigest(root, keccak256("evidence"), epoch), abi.encodePacked(root)
            ),
            invalid
        );
        assertEq(
            gate.isValidSignature(
                verifier.approvalDigest(root, gate.evidenceOf(root), epoch + 1),
                abi.encodePacked(root)
            ),
            invalid
        );
        // Any other length: empty, an ECDSA signature's, the root with a trailing byte.
        assertEq(gate.isValidSignature(good, ""), invalid);
        assertEq(gate.isValidSignature(good, new bytes(65)), invalid);
        assertEq(gate.isValidSignature(good, abi.encodePacked(root, uint8(0))), invalid);
        // Digests of other kinds: a move, an acceptance, an account consent, a bare hash.
        assertEq(
            gate.isValidSignature(
                registry.moveDigest(root, keccak256("item"), 0, type(uint64).max),
                abi.encodePacked(root)
            ),
            invalid
        );
        assertEq(
            gate.isValidSignature(
                accounts.consentDigest(address(independentStream), root), abi.encodePacked(root)
            ),
            invalid
        );
        assertEq(gate.isValidSignature(root, abi.encodePacked(root)), invalid);
    }

    /// @dev A registration with any evidence hash but the gate's own is refused.
    function test_OpenGate_RefusesAnotherEvidenceHash() public {
        bytes32 root = keccak256("root");
        (, bytes memory attestation) = gate.attestationOf(root);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, root));
        registry.registerPackage(root, keccak256("other evidence"), attestation);
    }

    /// @dev The gate is no party: it cannot accept a package (its ERC-1271 answer refuses the
    ///      acceptance digest), so it cannot become an artist or sign a move.
    function test_OpenGate_CannotAcceptAPackageOrBecomeAnArtist() public {
        bytes32 root = _rootOf(_one(_work(address(gate), collectionId)));
        _register(root);
        PartyAcceptance memory a = PartyAcceptance(
            address(gate),
            _profileId(address(gate)),
            _profileDoc(address(gate)),
            uint64(block.timestamp + 1 days)
        );
        vm.expectRevert(
            abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, address(gate))
        );
        registry.acceptPackage(root, a, abi.encodePacked(address(gate), root));
        assertEq(accounts.artistIdOf(address(gate)), 0);
    }

    /// @dev A package that names another artist is registered like any other, and gives nobody
    ///      anything: the item starts only with that artist's own acceptance and signed move.
    function test_OpenGate_CannotActForAnotherArtist() public {
        address victim = _actor("existingArtist");
        // The existing artist has an account and a work of its own, curated the usual way.
        Work[] memory own = _one(_work(victim, collectionId));
        bytes32 ownRoot = _publish(own);
        (, uint256 ownToken) = _start(ownRoot, own, 0);

        // A stranger registers, through the gate, a package that names the artist.
        Work[] memory forged = _one(_work(victim, collectionId));
        bytes32 root = _rootOf(forged);
        _register(root);
        // Without the artist's acceptance of this root, nothing starts.
        bytes memory request = _mintData(root, forged, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.PartyNotAccepted.selector, root, victim)
        );
        auction.start(address(stream), request);
        // The stranger cannot accept for the artist with its own signature.
        (address forger, uint256 forgerKey) = makeAddrAndKey("forger");
        keyOf[forger] = forgerKey;
        PartyAcceptance memory a = PartyAcceptance(
            victim, _profileId(victim), _profileDoc(victim), uint64(block.timestamp + 1 days)
        );
        bytes memory forgedProof =
            abi.encodePacked(forger, _sign(forger, registry.acceptanceDigest(root, a)));
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, forger));
        registry.acceptPackage(root, a, forgedProof);

        // The artist's own work is untouched: same owner, same package, still in its sale.
        assertEq(stream.ownerOf(ownToken), address(auction));
        assertEq(stream.workOf(ownToken).artistId, uint160(victim));
        (IPackageRegistry.PackageStatus status,, address signer) = registry.packageOf(ownRoot);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.APPROVED));
        assertEq(signer, signer1, "the usual signer's package is not the gate's");
        // A root that exists already cannot be registered again through the gate.
        (bytes32 evidence, bytes memory attestation) = gate.attestationOf(ownRoot);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageExists.selector, ownRoot));
        registry.registerPackage(ownRoot, evidence, attestation);
    }

    /// @dev The gate holds exactly its two roles, and no network role.
    function test_OpenGate_HoldsOnlyItsTwoRoles() public view {
        for (uint64 role; role < Roles.COUNT; ++role) {
            (bool member,) = manager.hasRole(role, address(gate));
            assertEq(
                member, role == Roles.CURATION_SIGNER || role == Roles.PLATFORM, "role membership"
            );
        }
        assertTrue(manager.network() != address(gate));
    }

    /// @dev Of every governed function of the deployment, the manager lets the gate call only
    ///      the PLATFORM ones; nothing that grants a role, moves funds, pauses, or changes a
    ///      module or a setting. The gate's code calls one of them, `createCollection`.
    function test_OpenGate_ManagerAllowsItOnlyPlatformFunctions() public view {
        GovernanceConfig.Config memory cfg = _genesisConfig();
        uint256 allowed;
        for (uint256 i; i < cfg.targets.length; ++i) {
            GovernanceConfig.Target memory t = cfg.targets[i];
            for (uint256 j; j < t.functions.length; ++j) {
                (bool immediate, uint32 delay) =
                    manager.canCall(address(gate), t.target, t.functions[j].selector);
                bool isPlatform = t.functions[j].role == Roles.PLATFORM;
                assertEq(immediate, isPlatform, "only PLATFORM selectors");
                assertEq(delay, 0, "nothing it could schedule");
                if (isPlatform) ++allowed;
            }
        }
        assertGt(allowed, 0);
        // The manager's own administration is closed to it.
        bytes4[7] memory admin = [
            IAccessManager.grantRole.selector,
            IAccessManager.revokeRole.selector,
            IAccessManager.setRoleAdmin.selector,
            IAccessManager.setTargetFunctionRole.selector,
            IAccessManager.setTargetClosed.selector,
            IAccessManager.updateAuthority.selector,
            manager.transferNetwork.selector
        ];
        for (uint256 i; i < admin.length; ++i) {
            (bool immediate, uint32 delay) =
                manager.canCall(address(gate), address(manager), admin[i]);
            assertFalse(immediate || delay != 0, "no manager administration");
        }
    }

    /// @dev The gate has two views, one ERC-1271 answer and one state-changing function. Every
    ///      other call reverts: it has no fallback, takes no ETH and forwards no arbitrary call.
    function test_OpenGate_HasNoOtherEntryPoint() public {
        bytes[8] memory calls = [
            abi.encodeCall(IAccessManager.grantRole, (Roles.PLATFORM, stranger, 0)),
            abi.encodeCall(manager.transferNetwork, (stranger)),
            abi.encodeCall(stream.proposeModule, (bytes32("RENDERER"), stranger)),
            abi.encodeCall(stream.setModuleDelay, (0)),
            abi.encodeCall(stream.addMinter, (stranger)),
            abi.encodeWithSignature("pause(uint256,bytes32)", 1, bytes32(0)),
            abi.encodeCall(IEnglishAuction.claim, (stranger)),
            abi.encodeWithSignature("execute(address,bytes)", address(stream), "")
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(stranger);
            (bool ok,) = address(gate).call(calls[i]);
            assertFalse(ok, "an unknown selector reverts");
        }
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool sent,) = address(gate).call{ value: 1 ether }("");
        assertFalse(sent, "the gate takes no ETH");
        vm.prank(stranger);
        (sent,) = address(gate).call{ value: 1 ether }(
            abi.encodeCall(gate.createCollection, ("x", bytes32(0)))
        );
        assertFalse(sent, "createCollection is not payable");
        assertEq(address(gate).balance, 0);
    }

    /// @dev `createCollection` creates a collection and nothing else: no token, no minter, no
    ///      module and no owner change in Stream, and no role change in the manager.
    function test_OpenGate_CreateCollectionChangesNothingElse() public {
        address owner = stream.owner();
        uint256 minted = stream.totalMinted();
        uint48 moduleDelay = stream.moduleDelay();
        vm.recordLogs();
        vm.prank(stranger);
        uint256 id = gate.createCollection("Second", keccak256("second"));
        assertEq(vm.getRecordedLogs().length, 2, "CollectionCreated and CollectionOpened");
        assertEq(id, stream.collectionCount());
        assertEq(stream.owner(), owner);
        assertEq(stream.totalMinted(), minted);
        assertEq(stream.moduleDelay(), moduleDelay);
        assertTrue(stream.isMinter(address(auction)));
        assertFalse(stream.isMinter(address(gate)));
        (bool member,) = manager.hasRole(Roles.PLATFORM, stranger);
        assertFalse(member, "the caller gained no role");
    }
}
