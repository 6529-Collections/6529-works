// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Roles } from "src/governance/Roles.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Stopping a curation signer on the deployed stack under the genesis policy
///         (re-ported from the retired `CurationSigner` flow suite): the network disables a
///         signer and kills its approvals, both at once; the two do different things, so a
///         signer is stopped by both; a re-grant of the role ends the signer's epoch.
contract CurationSignerPortedTest is IntegrationBase {
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

    /// @dev Both calls are the network's with no delay; after them a registered package of the
    ///      signer no longer starts.
    function test_TheNetworkKillsAndDisablesASignerAtOnce() public {
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        _keep(root, works);
        (bool immediate,) =
            manager.canCall(network, address(registry), registry.killSignerApprovals.selector);
        assertTrue(immediate, "kill: no delay");
        (immediate,) = manager.canCall(network, address(verifier), verifier.disableSigner.selector);
        assertTrue(immediate, "disable: no delay");
        vm.prank(network);
        registry.killSignerApprovals(signer1);
        vm.prank(network);
        verifier.disableSigner(signer1);
        bytes memory data = _mintData(root, _package(root), 0);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        auction.start(address(stream), data);
    }

    /// @dev A kill alone leaves an attestation signed before it registrable, and live; the
    ///      disable ends the signer's epoch, so no attestation it signed before registers.
    function test_AKillWithoutADisableLeavesUnregisteredAttestationsGood() public {
        bytes32 first = _freshRoot();
        bytes32 second = _freshRoot();
        uint256 epoch = verifier.signerEpoch(signer1);
        bytes memory a1 = _attest(first, epoch);
        bytes memory a2 = _attest(second, epoch);
        vm.prank(network);
        registry.killSignerApprovals(signer1);
        registry.registerPackage(first, _evidence(first), a1);
        (IPackageRegistry.PackageStatus status,,) = registry.packageOf(first);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.APPROVED), "kill only");
        vm.prank(network);
        verifier.disableSigner(signer1);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, second));
        registry.registerPackage(second, _evidence(second), a2);
    }

    /// @dev With the deployed manager, the signer renouncing its role and the network granting
    ///      it again (NETWORK administers the role, at once) changes the signer's epoch, so an
    ///      attestation signed under the earlier grant never registers; one signed under the new
    ///      grant does.
    function test_ARegrantChangesTheSignerEpoch() public {
        bytes32 root = _freshRoot();
        uint256 before = verifier.signerEpoch(signer1);
        bytes memory old = _attest(root, before);
        vm.prank(signer1);
        manager.renounceRole(Roles.CURATION_SIGNER, signer1);
        vm.prank(network); // NETWORK is the signer role's admin, no delay
        manager.grantRole(Roles.CURATION_SIGNER, signer1, 0);
        vm.warp(block.timestamp + manager.getRoleGrantDelay(Roles.CURATION_SIGNER));
        uint256 next = verifier.signerEpoch(signer1);
        assertTrue(next != before, "epoch changed");
        assertGt(next >> 176, before >> 176, "one more grant");
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.NotApproved.selector, root));
        registry.registerPackage(root, _evidence(root), old);
        registry.registerPackage(root, _evidence(root), _attest(root, next));
    }
}
