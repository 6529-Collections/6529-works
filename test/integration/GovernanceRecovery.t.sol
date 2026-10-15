// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { IDutchSale } from "src/interfaces/IDutchSale.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { Statement } from "src/interfaces/IStatementLog.sol";
import { Locator, LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { HASH_SHA256, HashRef } from "src/interfaces/types/HashRef.sol";
import { EditionFormat, EditionTerms, ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { DutchParams, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Governance recovery on the real genesis deployment (ADR 0002 decision 5, owner
///         decision 2): the cold recovery admin completes a recovery even when the hot admin and
///         one guardian (of three) act against it together.
contract GovernanceRecoveryTest is IntegrationBase {
    uint32 internal constant META_DELAY = 30 days;

    function _revoke(uint64 role, address account) internal pure returns (bytes memory) {
        return abi.encodeCall(IAccessManager.revokeRole, (role, account));
    }

    function _has(uint64 role, address account) internal view returns (bool member) {
        (member,) = manager.hasRole(role, account);
    }

    function _hotAdminRoles() internal pure returns (uint64[5] memory) {
        return [
            Roles.ADMIN,
            Roles.UNPAUSER,
            Roles.PARAMETER_SETTER,
            Roles.FUNDS_SETTER,
            Roles.SUCCESSOR_SETTER
        ];
    }

    function _expectUnauthorizedCancel(address canceller, address caller, bytes memory data)
        internal
    {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCancel.selector,
                canceller,
                caller,
                address(manager),
                bytes4(data)
            )
        );
        vm.prank(canceller);
        manager.cancel(caller, address(manager), data);
    }

    // ------------------------------------------------- GOV-1: recovery completes

    /// @dev Round one removes the guardian (only another guardian may cancel its revocation,
    ///      and the honest ones do not); round two removes the hot admin (nobody left may cancel
    ///      it). Then the cold admin appoints the replacement: revocations first, grants after.
    function test_GOV1_ColdAdminRemovesAHotAdminAndAGuardianActingTogether() public {
        vm.warp(block.timestamp + manager.minSetback());
        uint64[5] memory hotRoles = _hotAdminRoles();
        bytes[5] memory removeHot;
        for (uint256 i; i < 5; ++i) {
            removeHot[i] = _revoke(hotRoles[i], hotAdmin);
        }
        bytes memory removeGuardian = _revoke(Roles.GUARDIAN, guardian1);
        bytes memory removePauser = _revoke(Roles.PAUSER, guardian1);

        // Round one.
        for (uint256 i; i < 5; ++i) {
            _schedule(coldAdmin, address(manager), removeHot[i]);
        }
        _schedule(coldAdmin, address(manager), removeGuardian);
        _schedule(coldAdmin, address(manager), removePauser);
        // A guardian may still cancel any operation, the hot admin's revocations included.
        for (uint256 i; i < 5; ++i) {
            vm.prank(guardian1);
            manager.cancel(coldAdmin, address(manager), removeHot[i]);
        }
        // Neither may cancel the revocation of the guardian: guardian 1 by Rule 2, the hot
        // admin by Rule 3 (only guardians cancel another account's revocation).
        _expectUnauthorizedCancel(guardian1, coldAdmin, removeGuardian);
        _expectUnauthorizedCancel(guardian1, coldAdmin, removePauser);
        _expectUnauthorizedCancel(hotAdmin, coldAdmin, removeGuardian);
        _expectUnauthorizedCancel(hotAdmin, coldAdmin, removePauser);
        vm.warp(block.timestamp + META_DELAY);
        vm.startPrank(coldAdmin);
        manager.execute(address(manager), removeGuardian);
        manager.execute(address(manager), removePauser);
        vm.stopPrank();
        assertFalse(_has(Roles.GUARDIAN, guardian1), "guardian 1 removed");
        assertFalse(_has(Roles.PAUSER, guardian1), "guardian 1 pauser removed");

        // Round two: the hot admin's revocations.
        for (uint256 i; i < 5; ++i) {
            _schedule(coldAdmin, address(manager), removeHot[i]);
            _expectUnauthorizedCancel(hotAdmin, coldAdmin, removeHot[i]);
            _expectUnauthorizedCancel(guardian1, coldAdmin, removeHot[i]);
        }
        vm.warp(block.timestamp + META_DELAY);
        vm.startPrank(coldAdmin);
        for (uint256 i; i < 5; ++i) {
            manager.execute(address(manager), removeHot[i]);
        }
        vm.stopPrank();
        for (uint256 i; i < 5; ++i) {
            (uint48 since,,,) = manager.getAccess(hotRoles[i], hotAdmin);
            assertEq(since, 0, "the hot admin keeps a role");
        }

        // Only then the replacement: nobody left can cancel the cold admin's grants.
        address newHot = makeAddr("newHotAdminSafe");
        bytes memory grantUnpauser =
            abi.encodeCall(IAccessManager.grantRole, (Roles.UNPAUSER, newHot, Roles.STANDARD));
        _schedule(coldAdmin, address(manager), grantUnpauser);
        _expectUnauthorizedCancel(hotAdmin, coldAdmin, grantUnpauser);
        vm.warp(block.timestamp + META_DELAY);
        vm.prank(coldAdmin);
        manager.execute(address(manager), grantUnpauser);
        vm.warp(block.timestamp + Roles.grantDelay(Roles.UNPAUSER));
        assertTrue(_has(Roles.UNPAUSER, newHot), "the new hot admin unpauses");
        assertTrue(_has(Roles.ADMIN, coldAdmin), "the cold admin stays");
    }

    /// @dev The guardian veto is unchanged: any other guardian cancels a hostile admin's
    ///      revocation of a guardian, and admins keep the stock power to cancel each other's
    ///      operations other than revocations.
    function test_GOV1_TheGuardianVetoIsUnchanged() public {
        vm.warp(block.timestamp + manager.minSetback());
        bytes memory removeGuardian2 = _revoke(Roles.GUARDIAN, guardian2);
        bytes32 id = _schedule(hotAdmin, address(manager), removeGuardian2);
        _expectUnauthorizedCancel(guardian2, hotAdmin, removeGuardian2);
        vm.prank(guardian3);
        manager.cancel(hotAdmin, address(manager), removeGuardian2);
        assertEq(manager.getSchedule(id), 0, "vetoed");

        // A scheduler still withdraws its own revocation.
        bytes memory removeCold = _revoke(Roles.ADMIN, coldAdmin);
        id = _schedule(hotAdmin, address(manager), removeCold);
        vm.prank(hotAdmin);
        manager.cancel(hotAdmin, address(manager), removeCold);
        assertEq(manager.getSchedule(id), 0, "withdrawn");

        // With every guardian offline, the cold admin still cancels the hot admin's grants.
        bytes memory grab =
            abi.encodeCall(IAccessManager.grantRole, (Roles.ADMIN, makeAddr("intruder"), 0));
        id = _schedule(hotAdmin, address(manager), grab);
        vm.prank(coldAdmin);
        manager.cancel(hotAdmin, address(manager), grab);
        assertEq(manager.getSchedule(id), 0, "admin cancels a grant");
    }

    // ------------------------------------------------- GOV-2: guardian suspension

    function _statement(address token, uint256 id) internal pure returns (Statement memory) {
        string memory uri = "ar://platform-statement";
        return Statement(
            token,
            id,
            StatementKinds.DISPUTE_OUTCOME,
            keccak256("6529-works/dispute-outcome/1"),
            HashRef(HASH_SHA256, keccak256(bytes(uri))),
            uri,
            bytes32(0),
            bytes32(0)
        );
    }

    function _suspend(address guardian, uint64 role, address account) internal {
        vm.expectEmit(address(manager));
        emit WorksAccessManager.RoleSuspended(role, account, guardian);
        vm.prank(guardian);
        manager.suspend(role, account);
        assertTrue(manager.isSuspended(role, account), "suspended");
        assertFalse(_has(role, account), "no longer acts for the role");
        (uint48 since,,,) = manager.getAccess(role, account);
        assertTrue(since != 0, "still on record until revoked");
    }

    function _closed(address caller, address target, bytes4 selector) internal view {
        (bool immediate, uint32 delay) = manager.canCall(caller, target, selector);
        assertFalse(immediate, "immediate path open");
        assertEq(delay, 0, "no delayed path either");
    }

    /// @dev A sold, open Stream work (for locators and statements) and a sold Dutch edition
    ///      master with its edition created (for the adapters' PLATFORM path).
    function _soldWorkAndEdition(address artist)
        internal
        returns (uint256 tokenId, bytes32 fileId, uint256 editionId)
    {
        Work[] memory works = new Work[](2);
        works[0] = _work(artist, collectionId);
        works[1] = _work(artist, collectionId);
        works[1].item.kind = ItemKind.EDITION_MASTER;
        works[1].item.edition = EditionTerms(
            EditionFormat.FIXED,
            20,
            0,
            0.1 ether,
            CURRENCY_ETH,
            SaleKind.DUTCH,
            abi.encode(DutchParams(0.01 ether, 1 hours, 0))
        );
        bytes32 root = _publish(works);
        tokenId = _sell(root, works, 0, makeAddr("collectorA"), 1 ether);
        records.openRecord(tokenId, works[0].item, works[0].media);
        fileId = works[0].media[0].fileId;
        editionId = _sell(root, works, 1, makeAddr("collectorB"), 1 ether);
        editions.createEdition(editionId, works[1].item, root, _proofOf(works, 1));
    }

    /// @dev A guardian suspends the PLATFORM key and every platform path closes in the same
    ///      block: `canCall` and the manual checks that consult it. The creator path, which
    ///      needs no role, stays open.
    function test_GOV2_AGuardianSuspendsThePlatformKeyAtOnce() public {
        address artist = _actor("suspensionArtist");
        (uint256 tokenId, bytes32 fileId, uint256 editionId) = _soldWorkAndEdition(artist);

        _suspend(guardian2, Roles.PLATFORM, platform);
        _closed(platform, address(fixedSale), IFixedPriceSale.openSale.selector);
        _closed(platform, address(fixedSale), IFixedPriceSale.closeSale.selector);
        _closed(platform, address(dutchSale), IDutchSale.openSale.selector);
        _closed(platform, address(dutchSale), IDutchSale.closeSale.selector);
        _closed(platform, address(records), records.addLocator.selector);
        _closed(platform, address(statements), statements.appendPlatform.selector);
        _closed(platform, address(stream), stream.createCollection.selector);

        vm.startPrank(platform);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, platform)
        );
        statements.appendPlatform(_statement(address(stream), tokenId));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, platform)
        );
        records.addLocator(
            tokenId,
            fileId,
            Locator(LocatorKind.ARWEAVE, "ar://M1rror0000000000000000000000000000000000000")
        );
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, platform)
        );
        stream.createCollection("Another", keccak256("another"));
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, platform));
        dutchSale.openSale(address(editions), editionId, uint64(block.timestamp));
        vm.stopPrank();

        // The artist still opens its own sale; the suspended key cannot close it.
        vm.prank(artist);
        uint256 saleId = dutchSale.openSale(address(editions), editionId, uint64(block.timestamp));
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, platform));
        dutchSale.closeSale(saleId);
        vm.prank(artist);
        dutchSale.closeSale(saleId);

        // Lifting it is an ADMIN action in the 30-day class, which a guardian may veto.
        bytes memory lift = abi.encodeCall(IAccessManager.grantRole, (Roles.PLATFORM, platform, 0));
        _schedule(hotAdmin, address(manager), lift);
        vm.warp(block.timestamp + META_DELAY);
        vm.expectEmit(address(manager));
        emit WorksAccessManager.RoleSuspensionLifted(Roles.PLATFORM, platform);
        vm.prank(hotAdmin);
        manager.execute(address(manager), lift);
        assertFalse(manager.isSuspended(Roles.PLATFORM, platform));
        vm.prank(platform);
        records.addLocator(
            tokenId,
            fileId,
            Locator(LocatorKind.ARWEAVE, "ar://M1rror0000000000000000000000000000000000000")
        );
    }

    /// @dev The other suspendable roles close the same way; nobody but a guardian suspends,
    ///      and only these roles can be suspended.
    function test_GOV2_EveryOperationalRoleCanBeSuspended() public {
        _suspend(guardian1, Roles.STORAGE_OPERATOR, storageOperator);
        vm.prank(storageOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManaged.AccessManagedUnauthorized.selector, storageOperator
            )
        );
        records.setPreferredKind(LocatorKind.IPFS);

        _suspend(guardian3, Roles.CURATOR, curator);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, curator)
        );
        statements.appendCurator(_statement(address(stream), 1));

        // A curation signer is cut off by the verifier's `disableSigner` instead, which also
        // ends its approval epoch.
        vm.prank(guardian1);
        vm.expectRevert(
            abi.encodeWithSelector(
                WorksAccessManager.RoleNotSuspendable.selector, Roles.CURATION_SIGNER
            )
        );
        manager.suspend(Roles.CURATION_SIGNER, signer1);
        vm.prank(guardian1);
        verifier.disableSigner(signer1);
        assertFalse(verifier.isSignerActive(signer1), "signer 1 no longer approves");
        assertTrue(verifier.isSignerActive(signer2), "signer 2 still does");

        // Admins and keys cannot suspend; guardians cannot suspend a governance role.
        address[3] memory others = [hotAdmin, coldAdmin, platform];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManager.AccessManagerUnauthorizedAccount.selector,
                    others[i],
                    Roles.GUARDIAN
                )
            );
            manager.suspend(Roles.PLATFORM, platform);
        }
        vm.prank(guardian1);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.RoleNotSuspendable.selector, Roles.ADMIN)
        );
        manager.suspend(Roles.ADMIN, hotAdmin);
    }

    /// @dev Revocation and a new grant also clear it: the replacement key is never suspended.
    function test_GOV2_ReplacingASuspendedKey() public {
        _suspend(guardian1, Roles.PLATFORM, platform);
        address newPlatform = makeAddr("newPlatformKey");
        bytes memory revoke = _revoke(Roles.PLATFORM, platform);
        bytes memory grant =
            abi.encodeCall(IAccessManager.grantRole, (Roles.PLATFORM, newPlatform, 0));
        _schedule(hotAdmin, address(manager), revoke);
        _schedule(hotAdmin, address(manager), grant);
        vm.warp(block.timestamp + META_DELAY);
        vm.startPrank(hotAdmin);
        manager.execute(address(manager), revoke);
        manager.execute(address(manager), grant);
        vm.stopPrank();
        assertFalse(manager.isSuspended(Roles.PLATFORM, platform), "cleared by the revocation");
        vm.warp(block.timestamp + Roles.grantDelay(Roles.PLATFORM));
        vm.prank(newPlatform);
        stream.createCollection("Replacement", keccak256("replacement"));
    }
}
