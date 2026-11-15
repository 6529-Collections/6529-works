// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { ArtistIdentity, ChangeKind } from "src/interfaces/types/IdentityTypes.sol";
import { FederationRegistryStub } from "../mocks/identity/IdentityWorksMocks.sol";
import { PreApprovedWallet } from "../mocks/identity/PermanenceMocks.sol";
import { SignatureReverts } from "test/helpers/SignatureReverts.sol";
import { IdentityFixture } from "./IdentityFixture.sol";

/// @notice Signature-scheme agility: an artist authority can be any contract account. The
///         pre-approved-message route (the account approves a digest on chain, then answers
///         ERC-1271 from storage, whatever the signature bytes) lets an account adopt any future
///         signature scheme it verifies itself, with no change to the registry. Shown for a
///         deployed wallet and for an EIP-7702 delegated account.
contract SignatureAgilityTest is IdentityFixture {
    PreApprovedWallet internal smart;
    uint256 internal smartId;
    uint256 internal constant EOA_KEY = 0xE7702;
    address internal eoa;

    function setUp() public override {
        super.setUp();
        smart = new PreApprovedWallet(stranger);
        smartId = _register(address(smart));
        eoa = vm.addr(EOA_KEY);
        vm.signAndAttachDelegation(address(new PreApprovedWallet(address(0))), EOA_KEY);
    }

    /// @dev A contract authority stages a change by pre-approving its digest: no signature
    ///      bytes at all. Without the approval the same call is refused.
    function test_ContractAuthority_StagesByPreApproval() public {
        ArtistIdentity memory next = _identity(address(smart), payout);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = registry.changeDigest(smartId, next, 0, deadline);
        vm.expectRevert(SignatureReverts.invalid(address(smart)));
        registry.stageChange(smartId, next, address(smart), deadline, "", "");
        vm.prank(stranger);
        smart.approve(digest);
        registry.stageChange(smartId, next, address(smart), deadline, "", "");
        assertEq(registry.pendingChange(smartId).next.payout, payout);
        // Its direct calls act as the authority too.
        vm.prank(stranger);
        smart.execute(address(registry), abi.encodeCall(IArtistRegistry.cancelChange, (smartId)));
        vm.prank(stranger);
        smart.execute(address(registry), abi.encodeCall(IArtistRegistry.heartbeat, (smartId)));
        vm.prank(stranger);
        smart.execute(address(registry), abi.encodeCall(IArtistRegistry.revokeNonce, (smartId)));
        assertEq(registry.changeNonce(smartId), 2);
    }

    /// @dev A rotation to a contract authority: the new authority countersigns by
    ///      pre-approval, and accepts an override the same way.
    function test_ContractAuthority_AcceptsARotationAndAnOverrideByPreApproval() public {
        PreApprovedWallet next_ = new PreApprovedWallet(stranger);
        ArtistIdentity memory next = _identity(address(next_), address(next_));
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = _digest(next, deadline);
        vm.prank(stranger);
        next_.approve(digest);
        registry.stageChange(artistId, next, artist, deadline, _sign(artistKey, digest), "");
        vm.prank(guardian);
        registry.vetoChange(artistId);

        bytes32 evidence = keccak256("evidence");
        bytes32 accept =
            registry.overrideDigest(artistId, ChangeKind.CONTESTED, next, evidence, deadline);
        vm.prank(stranger);
        next_.approve(accept);
        vm.prank(governor);
        registry.stageOverride(artistId, ChangeKind.CONTESTED, next, evidence, deadline, "");
        vm.warp(block.timestamp + 180 days);
        registry.executeChange(artistId);
        assertEq(registry.authorityOf(artistId), address(next_));
    }

    /// @dev An EIP-7702 delegated account pre-approves in its own storage; its plain ECDSA
    ///      signature keeps working beside it.
    function test_7702Account_PreApprovalAndECDSABothWork() public {
        uint256 id = _register(eoa);
        ArtistIdentity memory next = _identity(eoa, payout);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = registry.changeDigest(id, next, 0, deadline);
        vm.expectRevert(SignatureReverts.invalid(eoa));
        registry.stageChange(id, next, eoa, deadline, "", "");
        vm.prank(eoa);
        PreApprovedWallet(eoa).approve(digest);
        assertTrue(PreApprovedWallet(eoa).approved(digest), "stored in the account");
        registry.stageChange(id, next, eoa, deadline, "", "");
        vm.prank(eoa);
        registry.cancelChange(id);

        bytes32 second = registry.changeDigest(id, next, 1, deadline);
        registry.stageChange(id, next, eoa, deadline, _sign(EOA_KEY, second), "");
        assertEq(registry.changeNonce(id), 2);
    }

    /// @dev Consent to an identity created by the federation registry works the same way.
    function test_7702Account_ConsentsToAFederatedIdentityByPreApproval() public {
        address federation = address(new FederationRegistryStub());
        vm.prank(admin);
        registry.bindFederationRegistry(federation);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = registry.registrationDigest(eoa, PROFILE, PROFILE_DOC, deadline);
        vm.prank(eoa);
        PreApprovedWallet(eoa).approve(digest);
        vm.prank(federation);
        registry.registerFederated(eoa, PROFILE, PROFILE_DOC, deadline, "");
        assertEq(registry.authorityOf(uint160(eoa)), eoa);
    }
}
