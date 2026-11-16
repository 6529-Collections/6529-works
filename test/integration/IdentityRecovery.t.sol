// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { PartyAcceptance } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Consolidated accounts on the real, wired contracts, with the 6529 delegation contract
///         as the identity lane's faithful mock: any wallet of an artist's account accepts a
///         package and signs the move that starts a sale; a wallet that left cannot; a frozen
///         or replaced account cannot start; killing a curation signer's approvals stops its
///         unminted items and leaves minted works alone.
contract IdentityRecoveryFlowTest is IntegrationBase {
    address internal constant ALL = 0x8888888888888888888888888888888888888888;
    uint256 internal constant CONSOLIDATION = 999;

    address internal artist;
    address internal wallet;
    uint256 internal artistId;
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("artist");
        wallet = _actor("artistWallet");
        Work[] memory works = new Work[](3);
        for (uint256 i; i < 3; ++i) {
            works[i] = _work(artist, collectionId);
        }
        root = _publish(works);
        _keep(root, works);
        artistId = artists.artistIdOf(artist);
        _consolidate(artist, wallet);
    }

    /// @dev A second wallet of the account signs the move and the sale starts; such a start is
    ///      a non-default path (one live read of the delegation contract), measured here.
    function test_ASecondWalletSignsTheMove() public {
        Work[] memory works = _package(root);
        bytes memory data = _mintDataSignedBy(root, works, 0, wallet, 0);
        uint256 before = gasleft();
        uint256 saleId = auction.start(address(stream), data);
        console2.log("start signed by a consolidated wallet, execution gas", before - gasleft());
        uint256 tokenId = IStream(address(stream)).totalMinted();
        assertEq(saleId, auction.saleIdOf(address(stream), tokenId));
        assertEq(IStream(address(stream)).artistOf(tokenId), artistId);
    }

    /// @dev A wallet of the account accepts a new package for the account.
    function test_ASecondWalletAcceptsAPackage() public {
        Work[] memory fresh = _one(_work(artist, collectionId));
        bytes32 freshRoot = _rootOf(fresh);
        _approve(freshRoot);
        PartyAcceptance memory a = PartyAcceptance(
            artist, _profileId(artist), _profileDoc(artist), uint64(block.timestamp + 1 days)
        );
        bytes32 digest = registry.acceptanceDigest(freshRoot, a);
        assertEq(
            registry.acceptPackage(freshRoot, a, abi.encodePacked(wallet, _sign(wallet, digest))),
            artistId
        );
        assertEq(registry.acceptedAs(freshRoot, artist), artistId);
    }

    function test_AWalletThatLeftTheConsolidationCannotStart() public {
        vm.prank(wallet);
        delegation.revokeDelegationAddress(ALL, artist, CONSOLIDATION);
        bytes memory data = _mintDataSignedBy(root, _package(root), 0, wallet, 0);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, wallet));
        auction.start(address(stream), data);
        // The root still starts.
        auction.start(address(stream), _mintDataSignedBy(root, _package(root), 0, artist, 1));
    }

    function test_AFrozenAccountCannotStart() public {
        _govern(hotAdmin, address(artists), abi.encodeCall(IArtistRegistry.freeze, (artistId)));
        bytes memory data = _mintDataSignedBy(root, _package(root), 0, artist, 0);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, artist));
        auction.start(address(stream), data);
        assertEq(artists.payoutAddress(artistId), address(0), "the payout is held");
        vm.warp(block.timestamp + 14 days);
        auction.start(address(stream), _mintDataSignedBy(root, _package(root), 0, artist, 0));
    }

    function test_AReplacedAccountCannotStartUntilItEnds() public {
        address next = _actor("replacementRoot");
        ArtistIdentity memory id =
            ArtistIdentity(next, next, _profileId(artist), _profileDoc(artist));
        uint64 deadline = uint64(block.timestamp + 60 days);
        bytes32 evidence = keccak256("replacement evidence");
        bytes memory acceptance =
            _sign(next, artists.replacementDigest(artistId, id, evidence, deadline));
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(
                IArtistRegistry.stageReplacement, (artistId, id, evidence, deadline, acceptance)
            )
        );
        bytes memory data = _mintDataSignedBy(root, _package(root), 0, artist, 0);
        vm.expectRevert(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, artist));
        auction.start(address(stream), data);
        vm.warp(block.timestamp + 14 days);
        artists.executeChange(artistId);
        auction.start(address(stream), _mintDataSignedBy(root, _package(root), 0, next, 0));
    }

    /// @dev C32: killing a signer's approvals stops every unminted item of the packages it
    ///      approved; a work already minted is untouched (fails on the old registry, where
    ///      disabling a signer stopped only future registrations).
    function test_KillingASignersApprovalsStopsUnmintedItems() public {
        Work[] memory works = _package(root);
        (, uint256 tokenId) = _start(root, works, 0);
        _govern(
            hotAdmin,
            address(registry),
            abi.encodeCall(IPackageRegistry.killSignerApprovals, (signer1))
        );
        bytes memory data = _mintData(root, works, 1);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        auction.start(address(stream), data);
        (IPackageRegistry.PackageStatus status,,) = registry.packageOf(root);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.REVOKED));
        assertFalse(
            registry.isApprovedItem(root, WorksHashing.itemHash(works[1].item), _proofOf(works, 1))
        );
        assertEq(IStream(address(stream)).artistOf(tokenId), artistId, "the minted work stays");
        // A package the same signer approves afterwards is live.
        Work[] memory fresh = _one(_work(artist, collectionId));
        bytes32 freshRoot = _publish(fresh);
        assertTrue(
            registry.isApprovedItem(
                freshRoot, WorksHashing.itemHash(fresh[0].item), _proofOf(fresh, 0)
            )
        );
    }

    function _consolidate(address a, address b) internal {
        vm.prank(a);
        delegation.registerDelegationAddress(ALL, b, type(uint64).max, CONSOLIDATION, true, 0);
        vm.prank(b);
        delegation.registerDelegationAddress(ALL, a, type(uint64).max, CONSOLIDATION, true, 0);
    }
}
