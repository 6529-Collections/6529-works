// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IItemApprovals } from "src/interfaces/IItemApprovals.sol";
import { MintFacts, MintTerms } from "src/interfaces/core/CoreTypes.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import {
    MoveAuthorization,
    PackageItem,
    PartyAcceptance
} from "src/interfaces/types/PackageTypes.sol";
import { StreamHashing } from "src/interfaces/types/StreamHashing.sol";
import { SignatureReverts } from "test/helpers/SignatureReverts.sol";
import { CurationBase } from "./CurationBase.sol";

/// @notice The package registry with consolidated accounts (any wallet of the lead's account
///         accepts, signs the move and revokes a move nonce), the edition-sale approval check
///         and the network's kill of a curation signer's approvals.
contract ConsolidatedAccountsTest is CurationBase {
    uint256 internal constant WALLET_KEY = 0xB2;
    address internal wallet;

    function setUp() public override {
        super.setUp();
        wallet = vm.addr(WALLET_KEY);
    }

    /// @dev A second wallet of the lead's account signs the move; it is the work's creator
    ///      (fails on the single-authority registry: the signature had to be the authority's).
    function test_Move_AnyWalletOfTheLeadAccount() public {
        PackageItem memory item = _item(lead, keccak256("media"));
        bytes32 root = StreamHashing.leaf(_hash(item));
        _register(root);
        _accept(root, leadKey);
        MoveAuthorization memory move = _move(WALLET_KEY, root, _hash(item), 0);
        vm.expectRevert(SignatureReverts.invalid(wallet));
        _authorize(root, item, new bytes32[](0), move);
        artists.addWallet(_id(lead), wallet, true);
        (MintFacts memory f, MintTerms memory t) = _authorize(root, item, new bytes32[](0), move);
        assertEq(t.creator, wallet);
        assertEq(f.artistId, _id(lead));
    }

    function test_Move_RefusedWhileTheAccountIsFrozen() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) =
            _ready(keccak256("media"));
        artists.setFrozen(_id(lead), true);
        vm.expectRevert(SignatureReverts.invalid(lead));
        _authorize(root, item, new bytes32[](0), move);
    }

    function test_Accept_AnyWalletOfTheAccount() public {
        bytes32 first = keccak256("first");
        bytes32 second = keccak256("second");
        _register(first);
        _register(second);
        _accept(first, leadKey);
        PartyAcceptance memory a = _acceptance(lead);
        bytes memory proof = _pf(WALLET_KEY, _sig(WALLET_KEY, registry.acceptanceDigest(second, a)));
        vm.expectRevert(SignatureReverts.invalid(wallet));
        registry.acceptPackage(second, a, proof);
        artists.addWallet(_id(lead), wallet, true);
        assertEq(registry.acceptPackage(second, a, proof), _id(lead));
    }

    function test_RevokeMove_AnyWalletOfTheAccount() public {
        _ready(keccak256("media"));
        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.NotAuthority.selector, _id(lead), wallet)
        );
        registry.revokeMove(_id(lead), 3);
        artists.addWallet(_id(lead), wallet, true);
        vm.prank(wallet);
        registry.revokeMove(_id(lead), 3);
        assertTrue(registry.isMoveNonceUsed(_id(lead), 3));
    }

    /// @dev C23's check: approved now, signer not killed, and the item in the package.
    function test_IsApprovedItem() public {
        PackageItem memory item = _item(lead, keccak256("media"));
        bytes32 itemHash = _hash(item);
        bytes32 root = StreamHashing.leaf(itemHash);
        bytes32[] memory none = new bytes32[](0);
        assertFalse(registry.isApprovedItem(root, itemHash, none), "unknown root");
        _register(root);
        assertTrue(registry.isApprovedItem(root, itemHash, none));
        assertFalse(registry.isApprovedItem(root, keccak256("other"), none), "not in it");
        assertFalse(
            registry.isApprovedItem(root, itemHash, new bytes32[](33)), "proof over the bound"
        );
        vm.prank(guardian);
        registry.revokePackage(root, 0);
        assertFalse(registry.isApprovedItem(root, itemHash, none), "revoked");
        assertTrue(registry.supportsInterface(type(IItemApprovals).interfaceId));
    }

    /// @dev C32: killing a signer's approvals stops its unminted packages registered before
    ///      the kill, not those of another signer and not those it registers later (fails on the
    ///      old registry, where nothing reached a registered package but a per-root revoke).
    function test_KillSignerApprovals_StopsPackagesRegisteredBefore() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) =
            _ready(keccak256("media"));
        bytes32 other = keccak256("other signer's package");
        registry.registerPackage(other, EVIDENCE, _attestation(signerKey2, other, EVIDENCE));
        vm.prank(stranger());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger())
        );
        registry.killSignerApprovals(signer1);
        vm.expectEmit(address(registry));
        emit IPackageRegistry.SignerApprovalsKilled(signer1, 1);
        vm.prank(guardian);
        registry.killSignerApprovals(signer1);
        assertEq(registry.signerKilledAt(signer1), 1);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        _authorize(root, item, new bytes32[](0), move);
        (IPackageRegistry.PackageStatus status,,) = registry.packageOf(root);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.REVOKED));
        (status,,) = registry.packageOf(other);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.APPROVED), "other signer");
        // A package the same signer registers after the kill is live.
        PackageItem memory later = _item(lead, keccak256("later media"));
        bytes32 laterRoot = StreamHashing.leaf(_hash(later));
        _register(laterRoot);
        _accept(laterRoot, leadKey);
        _authorize(laterRoot, later, new bytes32[](0), _move(leadKey, laterRoot, _hash(later), 1));
        // A second kill stops that one too.
        vm.prank(guardian);
        registry.killSignerApprovals(signer1);
        (status,,) = registry.packageOf(laterRoot);
        assertEq(uint8(status), uint8(IPackageRegistry.PackageStatus.REVOKED));
    }

    /// @dev A minted item is untouched by a kill: the consume already happened.
    function test_KillSignerApprovals_LeavesMintedItems() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) =
            _ready(keccak256("media"));
        (bytes32 itemHash,) = _consume(root, item, new bytes32[](0), move);
        vm.prank(guardian);
        registry.killSignerApprovals(signer1);
        assertEq(registry.consumedItemOf(item.contentHash), itemHash);
    }

    function stranger() internal returns (address) {
        return makeAddr("stranger");
    }
}
