// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { IndependentStreamRegistryStub } from "../mocks/identity/IdentityWorksMocks.sol";
import { PreApprovedWallet } from "../mocks/identity/PermanenceMocks.sol";
import { SignatureReverts } from "test/helpers/SignatureReverts.sol";
import { AccountsFixture } from "./AccountsFixture.sol";

/// @notice Signature-scheme agility: a wallet of an account can be any contract account. The
///         pre-approved-message route (the account approves a digest on chain, then answers
///         ERC-1271 from storage, whatever the signature bytes) lets an account adopt any future
///         signature scheme it verifies itself, with no change to the registry. Shown for a
///         deployed wallet and for an EIP-7702 delegated account.
contract SignatureAgilityTest is AccountsFixture {
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

    /// @dev A contract root stages a change by pre-approving its digest: the proof is its
    ///      address and no signature bytes. Without the approval the same call is refused.
    function test_ContractRoot_StagesByPreApproval() public {
        ArtistIdentity memory next = _identity(address(smart), payout);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = registry.changeDigest(smartId, next, 0, deadline);
        bytes memory proof = abi.encodePacked(address(smart));
        vm.expectRevert(SignatureReverts.invalid(address(smart)));
        registry.stageChange(smartId, next, deadline, proof);
        vm.prank(stranger);
        smart.approve(digest);
        registry.stageChange(smartId, next, deadline, proof);
        assertEq(registry.pendingChange(smartId).next.payout, payout);
        // Its direct calls act for the account too.
        vm.prank(stranger);
        smart.execute(address(registry), abi.encodeCall(IArtistRegistry.cancelChange, (smartId)));
        vm.prank(stranger);
        smart.execute(address(registry), abi.encodeCall(IArtistRegistry.revokeNonce, (smartId)));
        assertEq(registry.changeNonce(smartId), 2);
    }

    /// @dev A replacement to a contract root: the new root accepts by pre-approval.
    function test_ContractRoot_AcceptsAReplacementByPreApproval() public {
        PreApprovedWallet next_ = new PreApprovedWallet(stranger);
        ArtistIdentity memory next = _identity(address(next_), address(next_));
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = registry.replacementDigest(artistId, next, EVIDENCE, deadline);
        vm.prank(stranger);
        next_.approve(digest);
        vm.prank(network);
        registry.stageReplacement(artistId, next, EVIDENCE, deadline, "");
        vm.warp(block.timestamp + 14 days);
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
        bytes memory bare = abi.encodePacked(eoa);
        vm.expectRevert(SignatureReverts.invalid(eoa));
        registry.stageChange(id, next, deadline, bare);
        vm.prank(eoa);
        PreApprovedWallet(eoa).approve(digest);
        assertTrue(PreApprovedWallet(eoa).approved(digest), "stored in the account");
        registry.stageChange(id, next, deadline, bare);
        vm.prank(eoa);
        registry.cancelChange(id);

        bytes32 second = registry.changeDigest(id, next, 1, deadline);
        registry.stageChange(id, next, deadline, _proof(EOA_KEY, second));
        assertEq(registry.changeNonce(id), 2);
    }

    /// @dev Consent to an identity created by the Independent Stream registry works the same way.
    function test_7702Account_ConsentsToAIndependentIdentityByPreApproval() public {
        address independentStream = address(new IndependentStreamRegistryStub());
        directory.setModule(Slots.INDEPENDENT_STREAM, independentStream);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = registry.registrationDigest(eoa, PROFILE, PROFILE_DOC, deadline);
        vm.prank(eoa);
        PreApprovedWallet(eoa).approve(digest);
        vm.prank(independentStream);
        registry.registerIndependent(eoa, PROFILE, PROFILE_DOC, deadline, "");
        assertEq(registry.authorityOf(uint160(eoa)), eoa);
    }
}
