// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Roles } from "src/governance/Roles.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Stopping a curation signer on the real deployment (genesis role map, the 6529 Works
///         manager): the network disables a signer and kills its approvals, both at once (C32);
///         a signer's epoch changes when its role is revoked and granted again in one second.
contract CurationSignerFlowTest is IntegrationBase {
    address internal artist;

    function setUp() public override {
        super.setUp();
        artist = _actor("artist");
    }

    function _attest(bytes32 root, uint256 epoch) internal view returns (bytes memory) {
        return abi.encode(
            signer1, _sign(signer1, verifier.approvalDigest(root, _evidence(root), epoch))
        );
    }

    function _freshRoot() internal returns (bytes32) {
        return _rootOf(_one(_work(artist, collectionId)));
    }

    /// @dev C32 under the genesis map: the network kills a signer's approvals with no delay,
    ///      like `disableSigner`. Fails without the change: `killSignerApprovals` was mapped
    ///      to the 24-hour class, so the direct call reverts.
    function test_TheNetworkKillsASignersApprovalsAtOnce() public {
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        _keep(root, works);
        vm.prank(hotAdmin);
        registry.killSignerApprovals(signer1);
        vm.prank(hotAdmin);
        verifier.disableSigner(signer1);
        bytes memory data = _mintData(root, _package(root), 0);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        auction.start(address(stream), data);
    }

    /// @dev The two calls do different things, so a signer is stopped by both: a kill alone
    ///      leaves an attestation signed before it registrable, and live; the disable ends the
    ///      signer's epoch, so no attestation it signed before registers.
    function test_AKillWithoutADisableLeavesUnregisteredAttestationsGood() public {
        bytes32 first = _freshRoot();
        bytes32 second = _freshRoot();
        uint256 epoch = verifier.signerEpoch(signer1);
        bytes memory a1 = _attest(first, epoch);
        bytes memory a2 = _attest(second, epoch);
        vm.prank(hotAdmin);
        registry.killSignerApprovals(signer1);
        registry.registerPackage(first, _evidence(first), a1);
        (IPackageRegistry.PackageStatus status,,) = registry.packageOf(first);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.APPROVED), "kill only");
        vm.prank(hotAdmin);
        verifier.disableSigner(signer1);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, second));
        registry.registerPackage(second, _evidence(second), a2);
    }

    /// @dev With the real manager, revoking and granting the signer role again in the same
    ///      second changes the signer's epoch (the grant count), so an attestation signed under
    ///      the earlier grant never registers; one signed under the new grant does.
    function test_ARegrantInTheSameSecondChangesTheSignerEpoch() public {
        bytes32 root = _freshRoot();
        vm.startPrank(hotAdmin);
        manager.revokeRole(Roles.CURATION_SIGNER, signer1);
        manager.grantRole(Roles.CURATION_SIGNER, signer1, 0);
        vm.stopPrank();
        uint256 before = verifier.signerEpoch(signer1);
        bytes memory old = _attest(root, before);
        vm.startPrank(hotAdmin);
        manager.revokeRole(Roles.CURATION_SIGNER, signer1);
        manager.grantRole(Roles.CURATION_SIGNER, signer1, 0);
        vm.stopPrank();
        uint256 next = verifier.signerEpoch(signer1);
        assertTrue(next != before, "epoch changed");
        assertEq(next >> 128 & type(uint48).max, before >> 128 & type(uint48).max, "same since");
        vm.warp(block.timestamp + manager.getRoleGrantDelay(Roles.CURATION_SIGNER));
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, root));
        registry.registerPackage(root, _evidence(root), old);
        registry.registerPackage(root, _evidence(root), _attest(root, next));
    }
}
