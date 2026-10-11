// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { StatementKinds } from "src/records/StatementKinds.sol";
import { HashRef, HASH_SHA256, HASH_KECCAK256, HASH_BLAKE3 } from "src/records/HashRef.sol";
import { IStatementLog, Role, Statement } from "src/records/IStatementLog.sol";
import { StatementLogFixture } from "./StatementLogFixture.sol";
import { StatementModel } from "./StatementModel.sol";
import {
    ArtistResolverMock,
    WrongInterfaceMock,
    ERC1155BalanceMock
} from "../mocks/RecordsMocks.sol";
import {
    ERC1271WalletMock,
    GasBurnerMock,
    ReturnBombMock,
    ReturnDataMock
} from "../mocks/AdversarialTargets.sol";

contract StatementLogTest is StatementLogFixture {
    // ------------------------------------------------------------------ ARTIST

    function test_Artist_AppendRecordsCountHeadAndEvent() public {
        Statement memory s = _statement();
        (bytes32 entry, bytes32 head) = _expectAppend(Role.ARTIST, artist, s);
        bytes32 returned = _append(Role.ARTIST, artist, s);

        assertEq(returned, entry);
        (uint64 count, bytes32 stored) = stmtLog.chainOf(address(nft), 1);
        assertEq(count, 1);
        assertEq(stored, head);
        assertEq(
            head,
            keccak256(abi.encode(keccak256("6529.works.StatementLog.head.v1"), bytes32(0), entry))
        );
    }

    function test_Artist_RejectsNonArtist() public {
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.ARTIST, stranger)
        );
        _append(Role.ARTIST, stranger, _statement());
    }

    function test_Artist_ResolverAnswersPerSubject() public {
        // `artist` is an artist of token 1 only.
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.ARTIST, artist)
        );
        _append(Role.ARTIST, artist, _statement(address(nft), 2));
    }

    function test_Artist_WorkIdSubjectWithoutToken() public {
        resolver.grant(address(0), 77, artist);
        Statement memory s = _statement(address(0), 77);
        _expectAppend(Role.ARTIST, artist, s);
        _append(Role.ARTIST, artist, s);
        (uint64 count,) = stmtLog.chainOf(address(0), 77);
        assertEq(count, 1);
    }

    function test_Artist_DisabledWhenResolverUnset() public {
        StatementLog bare = new StatementLog(address(manager), address(0), bytes32(0));
        assertEq(bare.artistResolver(), address(0));
        Statement memory s = _statement();
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.ARTIST, artist)
        );
        vm.prank(artist);
        bare.append(Role.ARTIST, s);
    }

    // ------------------------------------------------------------------- OWNER

    function test_Owner_ERC721OwnerMayWrite() public {
        Statement memory s = _statement();
        s.kind = StatementKinds.CONSERVATION_NOTE;
        _expectAppend(Role.OWNER, tokenOwner, s);
        _append(Role.OWNER, tokenOwner, s);
        (uint64 count,) = stmtLog.chainOf(address(nft), 1);
        assertEq(count, 1);
    }

    function test_Owner_RejectsNonOwnerAndFormerOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.OWNER, stranger)
        );
        _append(Role.OWNER, stranger, _statement());

        nft.setOwner(1, stranger); // the token is sold
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.OWNER, tokenOwner)
        );
        _append(Role.OWNER, tokenOwner, _statement());
        _append(Role.OWNER, stranger, _statement());
    }

    function test_Owner_RejectsNonexistentToken() public {
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.OWNER, tokenOwner)
        );
        _append(Role.OWNER, tokenOwner, _statement(address(nft), 99));
    }

    function test_Owner_ERC1155HolderMayWrite() public {
        editions.setBalance(7, tokenOwner, 1);
        Statement memory s = _statement(address(editions), 7);
        _expectAppend(Role.OWNER, tokenOwner, s);
        _append(Role.OWNER, tokenOwner, s);

        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.OWNER, stranger)
        );
        _append(Role.OWNER, stranger, s); // zero balance
    }

    function test_Owner_RejectsWorkIdAndCodelessToken() public {
        Statement memory workId = _statement(address(0), 5);
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.OWNER, tokenOwner)
        );
        _append(Role.OWNER, tokenOwner, workId);

        Statement memory codeless = _statement(makeAddr("not a contract"), 1);
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.OWNER, tokenOwner)
        );
        _append(Role.OWNER, tokenOwner, codeless);
    }

    function test_Owner_ExactWordIsAcceptedButDirtyOrOversizedIsNot() public {
        ReturnDataMock token = new ReturnDataMock();
        Statement memory s = _statement(address(token), 1);

        token.configure(abi.encode(tokenOwner), false);
        _append(Role.OWNER, tokenOwner, s); // positive control

        // Dirty upper bits must not be read as the owner (nor revert the abi decoder).
        token.configure(abi.encode(uint256(uint160(tokenOwner)) | (uint256(1) << 200)), false);
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.OWNER, tokenOwner)
        );
        _append(Role.OWNER, tokenOwner, s);

        token.configure(abi.encode(tokenOwner, tokenOwner), false); // 64 bytes
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.OWNER, tokenOwner)
        );
        _append(Role.OWNER, tokenOwner, s);
    }

    function test_Owner_HostileTokensFailClosedWithBoundedGas() public {
        Statement memory s = _statement(address(new GasBurnerMock()), 1);
        uint256 gasBefore = gasleft();
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.OWNER, tokenOwner)
        );
        _append(Role.OWNER, tokenOwner, s);
        // Two reads of at most 50k gas each; the rest is a fixed overhead.
        assertLt(gasBefore - gasleft(), 200_000, "hostile token burned the caller's gas");
    }

    // ------------------------------------------------------- CURATOR / PLATFORM

    function test_Curator_RoleHolderMayWrite() public {
        Statement memory s = _statement();
        s.kind = StatementKinds.CURATION_EVIDENCE;
        _expectAppend(Role.CURATOR, curator, s);
        vm.prank(curator);
        stmtLog.appendCurator(s);
    }

    function test_Platform_RoleHolderMayWrite() public {
        Statement memory s = _statement();
        s.kind = StatementKinds.DISPUTE_OUTCOME;
        _expectAppend(Role.PLATFORM, platform, s);
        vm.prank(platform);
        stmtLog.appendPlatform(s);
    }

    function test_CuratorAndPlatform_RejectStrangersAndTheOtherRole() public {
        Statement memory s = _statement();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        vm.prank(stranger);
        stmtLog.appendCurator(s);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, curator)
        );
        vm.prank(curator);
        stmtLog.appendPlatform(s);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, platform)
        );
        vm.prank(platform);
        stmtLog.appendCurator(s);
    }

    function test_Append_RefusesCuratorPlatformAndNoneRoles() public {
        Role[3] memory refused = [Role.CURATOR, Role.PLATFORM, Role.NONE];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidRole.selector, refused[i]));
            _append(refused[i], curator, _statement());
        }
    }

    function test_Curator_DelayedRoleCannotWriteDirectlyOrByRelay() public {
        uint256 delayedKey = 0xDE1A;
        address delayed = vm.addr(delayedKey);
        vm.prank(admin);
        manager.grantRole(CURATOR_ROLE, delayed, 1 days);
        Statement memory s = _statement();

        // A delayed role must schedule the call on the manager; a direct call is refused.
        vm.expectPartialRevert(IAccessManager.AccessManagerNotScheduled.selector);
        vm.prank(delayed);
        stmtLog.appendCurator(s);

        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(delayedKey, Role.CURATOR, s, 0, deadline);
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.CURATOR, delayed)
        );
        _relay(Role.CURATOR, s, delayed, 0, deadline, sig);
    }

    function test_Curator_ScheduledExecutionCannotBeAttributedToTheManager() public {
        address delayed = makeAddr("delayed curator");
        vm.prank(admin);
        manager.grantRole(CURATOR_ROLE, delayed, 1 days);
        Statement memory s = _statement();
        bytes memory data = abi.encodeCall(StatementLog.appendCurator, (s));

        vm.prank(delayed);
        manager.schedule(address(stmtLog), data, 0);
        vm.warp(block.timestamp + 1 days);
        // The manager would be the caller, and no statement may be attributed to it.
        vm.expectRevert(IStatementLog.AuthorityCannotSign.selector);
        vm.prank(delayed);
        manager.execute(address(stmtLog), data);
        (uint64 count,) = stmtLog.chainOf(address(nft), 1);
        assertEq(count, 0);
    }

    function test_UnmappedSelectorsDefaultToAdminOnly() public {
        // Function roles are per target, so a new log under the same manager has none mapped.
        StatementLog fresh =
            new StatementLog(address(manager), address(resolver), address(resolver).codehash);
        Statement memory s = _statement();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, curator)
        );
        vm.prank(curator);
        fresh.appendCurator(s);
        vm.prank(admin); // the manager's default role for unmapped selectors
        fresh.appendCurator(s);
    }

    // ------------------------------------------------------------------- ADMIN

    function test_Admin_CannotWriteArtistOrOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.ARTIST, admin)
        );
        _append(Role.ARTIST, admin, _statement());
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.OWNER, admin)
        );
        _append(Role.OWNER, admin, _statement());
    }

    function test_Admin_HoldingEveryGovernedRoleStillCannotWriteArtistOrOwner() public {
        vm.startPrank(admin);
        manager.grantRole(CURATOR_ROLE, admin, 0);
        manager.grantRole(PLATFORM_ROLE, admin, 0);
        vm.stopPrank();

        // Even mapping `append` to the admin role changes nothing: it is not `restricted`.
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = stmtLog.append.selector;
        uint64 adminRole = manager.ADMIN_ROLE();
        vm.prank(admin);
        manager.setTargetFunctionRole(address(stmtLog), selectors, adminRole);

        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.ARTIST, admin)
        );
        _append(Role.ARTIST, admin, _statement());
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.OWNER, admin)
        );
        _append(Role.OWNER, admin, _statement());
        // The roles do work for what they are: curator and platform statements.
        vm.prank(admin);
        stmtLog.appendCurator(_statement());
        vm.prank(admin);
        stmtLog.appendPlatform(_statement());
    }

    function test_Admin_RelayedArtistOrOwnerSignatureIsRejected() public {
        uint256 adminKey = 0xAD31;
        address adminSigner = vm.addr(adminKey);
        vm.startPrank(admin);
        manager.grantRole(manager.ADMIN_ROLE(), adminSigner, 0);
        manager.grantRole(CURATOR_ROLE, adminSigner, 0);
        manager.grantRole(PLATFORM_ROLE, adminSigner, 0);
        vm.stopPrank();

        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory artistSig = _sign(adminKey, Role.ARTIST, s, 0, deadline);
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.ARTIST, adminSigner)
        );
        _relay(Role.ARTIST, s, adminSigner, 0, deadline, artistSig);

        bytes memory ownerSig = _sign(adminKey, Role.OWNER, s, 1, deadline);
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.OWNER, adminSigner)
        );
        _relay(Role.OWNER, s, adminSigner, 1, deadline, ownerSig);
    }

    function test_Curator_CannotWriteArtistOrOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.ARTIST, curator)
        );
        _append(Role.ARTIST, curator, _statement());
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.OWNER, platform)
        );
        _append(Role.OWNER, platform, _statement());
    }

    // ------------------------------------------------------------------- RELAY

    function test_Relay_ArtistSignatureSubmittedByAnyone() public {
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(artistKey, Role.ARTIST, s, 5, deadline);

        (bytes32 entry,) = _expectAppend(Role.ARTIST, artist, s);
        bytes32 returned = _relay(Role.ARTIST, s, artist, 5, deadline, sig);
        assertEq(returned, entry);
        assertTrue(stmtLog.nonceUsed(artist, 5));
        assertFalse(stmtLog.nonceUsed(artist, 6));
    }

    function test_Relay_ERC2098CompactSignature() public {
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 digest = StatementModel.digest(
            block.chainid, address(stmtLog), Role.ARTIST, s, artist, 0, deadline
        );
        (uint8 v, bytes32 r, bytes32 sv) = vm.sign(artistKey, digest);
        bytes memory compact = abi.encodePacked(r, bytes32(uint256(sv) | (uint256(v - 27) << 255)));
        assertEq(compact.length, 64);
        _relay(Role.ARTIST, s, artist, 0, deadline, compact);
    }

    function test_Relay_OwnerAndCuratorSignatures() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        Statement memory s = _statement();
        _relay(Role.OWNER, s, tokenOwner, 0, deadline, _sign(ownerKey, Role.OWNER, s, 0, deadline));
        _relay(
            Role.CURATOR,
            s,
            curatorSigner,
            0,
            deadline,
            _sign(curatorKey, Role.CURATOR, s, 0, deadline)
        );
        (uint64 count,) = stmtLog.chainOf(address(nft), 1);
        assertEq(count, 2);
    }

    function test_Relay_PlatformSigner() public {
        uint256 platformKey = 0x91A7;
        address platformSigner = vm.addr(platformKey);
        vm.prank(admin);
        manager.grantRole(PLATFORM_ROLE, platformSigner, 0);
        Statement memory s = _statement();
        s.kind = StatementKinds.DISPUTE_OUTCOME;
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(platformKey, Role.PLATFORM, s, 0, deadline);

        _expectAppend(Role.PLATFORM, platformSigner, s);
        _relay(Role.PLATFORM, s, platformSigner, 0, deadline, sig);
    }

    function test_Relay_CuratorSignerWithoutTheRoleIsRejected() public {
        uint256 key = 0xBAD;
        address nobody = vm.addr(key);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        Statement memory s = _statement();
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.CURATOR, nobody)
        );
        _relay(Role.CURATOR, s, nobody, 0, deadline, _sign(key, Role.CURATOR, s, 0, deadline));
        // The curator role is not the platform role.
        vm.expectRevert(
            abi.encodeWithSelector(
                IStatementLog.NotAuthorized.selector, Role.PLATFORM, curatorSigner
            )
        );
        _relay(
            Role.PLATFORM,
            s,
            curatorSigner,
            0,
            deadline,
            _sign(curatorKey, Role.PLATFORM, s, 0, deadline)
        );
    }

    function test_Relay_ERC1271ContractWalletArtist() public {
        ERC1271WalletMock wallet = new ERC1271WalletMock(artist);
        resolver.grant(address(nft), 1, address(wallet));
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 digest = StatementModel.digest(
            block.chainid, address(stmtLog), Role.ARTIST, s, address(wallet), 0, deadline
        );
        (uint8 v, bytes32 r, bytes32 sv) = vm.sign(artistKey, digest);
        _relay(Role.ARTIST, s, address(wallet), 0, deadline, abi.encodePacked(r, sv, v));
        (uint64 count,) = stmtLog.chainOf(address(nft), 1);
        assertEq(count, 1);
    }

    function test_Relay_ReplayIsRejected() public {
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(artistKey, Role.ARTIST, s, 3, deadline);
        _relay(Role.ARTIST, s, artist, 3, deadline, sig);
        vm.expectRevert(abi.encodeWithSelector(IStatementLog.NonceAlreadyUsed.selector, artist, 3));
        _relay(Role.ARTIST, s, artist, 3, deadline, sig);
        (uint64 count,) = stmtLog.chainOf(address(nft), 1);
        assertEq(count, 1);
    }

    function test_Relay_NonceIsPerSigner() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        Statement memory s = _statement();
        _relay(Role.ARTIST, s, artist, 0, deadline, _sign(artistKey, Role.ARTIST, s, 0, deadline));
        _relay(Role.OWNER, s, tokenOwner, 0, deadline, _sign(ownerKey, Role.OWNER, s, 0, deadline));
    }

    function test_Relay_DeadlineIsInclusive() public {
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 100);
        bytes memory sig = _sign(artistKey, Role.ARTIST, s, 0, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IStatementLog.DeadlineExpired.selector, deadline));
        _relay(Role.ARTIST, s, artist, 0, deadline, sig);

        vm.warp(deadline);
        _relay(Role.ARTIST, s, artist, 0, deadline, sig);
    }

    function test_Relay_RevokeBeforeUse() public {
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(artistKey, Role.ARTIST, s, 9, deadline);

        vm.expectEmit(true, true, false, false, address(stmtLog));
        emit IStatementLog.NonceRevoked(artist, 9);
        vm.prank(artist);
        stmtLog.revokeNonce(9);
        assertTrue(stmtLog.nonceUsed(artist, 9));

        vm.expectRevert(abi.encodeWithSelector(IStatementLog.NonceAlreadyUsed.selector, artist, 9));
        _relay(Role.ARTIST, s, artist, 9, deadline, sig);

        vm.expectRevert(abi.encodeWithSelector(IStatementLog.NonceAlreadyUsed.selector, artist, 9));
        vm.prank(artist);
        stmtLog.revokeNonce(9); // already spent
    }

    function test_Relay_RevokeLeavesNeighbouringNoncesUsable() public {
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        uint256[4] memory nonces = [uint256(0), 255, 256, type(uint256).max];
        for (uint256 i; i < nonces.length; ++i) {
            vm.prank(stranger);
            stmtLog.revokeNonce(nonces[i]);
            assertTrue(stmtLog.nonceUsed(stranger, nonces[i]));
            assertFalse(stmtLog.nonceUsed(artist, nonces[i]), "nonces are per signer");
        }
        assertFalse(stmtLog.nonceUsed(stranger, 1));
        assertFalse(stmtLog.nonceUsed(stranger, 254));
        assertFalse(stmtLog.nonceUsed(stranger, 257));
        _relay(
            Role.ARTIST, s, artist, 255, deadline, _sign(artistKey, Role.ARTIST, s, 255, deadline)
        );
    }

    function test_Relay_WrongChainIsRejected() public {
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig =
            _signAs(artistKey, block.chainid + 1, address(stmtLog), Role.ARTIST, s, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidSignature.selector, artist));
        _relay(Role.ARTIST, s, artist, 0, deadline, sig);

        // A signature made for this chain stops working if the chain ID changes (a fork).
        sig = _sign(artistKey, Role.ARTIST, s, 0, deadline);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidSignature.selector, artist));
        _relay(Role.ARTIST, s, artist, 0, deadline, sig);
    }

    function test_Relay_WrongContractIsRejected() public {
        StatementLog other =
            new StatementLog(address(manager), address(resolver), address(resolver).codehash);
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(artistKey, Role.ARTIST, s, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidSignature.selector, artist));
        vm.prank(stranger);
        other.appendSigned(Role.ARTIST, s, artist, 0, deadline, sig);
    }

    function test_Relay_AnyTamperedFieldIsRejected() public {
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(artistKey, Role.ARTIST, s, 0, deadline);
        bytes memory invalid =
            abi.encodeWithSelector(IStatementLog.InvalidSignature.selector, artist);

        Statement memory t = _statement();
        t.uri = "ar://other";
        vm.expectRevert(invalid);
        _relay(Role.ARTIST, t, artist, 0, deadline, sig);

        t = _statement();
        t.supersedes = bytes32(uint256(1));
        vm.expectRevert(invalid);
        _relay(Role.ARTIST, t, artist, 0, deadline, sig);

        t = _statement();
        t.content.digest = keccak256("another document");
        vm.expectRevert(invalid);
        _relay(Role.ARTIST, t, artist, 0, deadline, sig);

        vm.expectRevert(invalid);
        _relay(Role.ARTIST, s, artist, 1, deadline, sig); // nonce

        vm.expectRevert(invalid);
        _relay(Role.ARTIST, s, artist, 0, deadline + 1, sig); // deadline

        // A signature made for one role cannot be replayed under another.
        resolver.grant(address(nft), 1, tokenOwner);
        bytes memory ownerSig = _sign(ownerKey, Role.OWNER, s, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidSignature.selector, tokenOwner));
        _relay(Role.ARTIST, s, tokenOwner, 0, deadline, ownerSig);
    }

    function test_Relay_SignatureByAnotherKeyIsRejected() public {
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(ownerKey, Role.ARTIST, s, 0, deadline); // signed by the owner
        vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidSignature.selector, artist));
        _relay(Role.ARTIST, s, artist, 0, deadline, sig);

        vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidSignature.selector, artist));
        _relay(Role.ARTIST, s, artist, 0, deadline, hex"1234");
        vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidSignature.selector, address(0)));
        _relay(Role.ARTIST, s, address(0), 0, deadline, sig);
    }

    function test_Relay_FailedAppendDoesNotSpendTheNonce() public {
        Statement memory s = _statement();
        s.kind = bytes32(0); // invalid, but signed
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(artistKey, Role.ARTIST, s, 4, deadline);
        vm.expectRevert(IStatementLog.InvalidKind.selector);
        _relay(Role.ARTIST, s, artist, 4, deadline, sig);
        assertFalse(stmtLog.nonceUsed(artist, 4));
    }

    function test_AuthorizationDigestMatchesIndependentModel() public view {
        Statement memory s = _statement();
        bytes32 expected = StatementModel.digest(
            block.chainid, address(stmtLog), Role.OWNER, s, tokenOwner, 12, 3456
        );
        assertEq(stmtLog.authorizationDigest(Role.OWNER, s, tokenOwner, 12, 3456), expected);
    }

    // -------------------------------------------------------------- VALIDATION

    function test_Validation_RejectsMalformedStatements() public {
        Statement memory s = _statement(address(0), 0);
        resolver.grantEverywhere(artist);
        vm.expectRevert(IStatementLog.InvalidSubject.selector);
        _append(Role.ARTIST, artist, s);

        s = _statement();
        s.kind = bytes32(0);
        vm.expectRevert(IStatementLog.InvalidKind.selector);
        _append(Role.ARTIST, artist, s);

        s = _statement();
        s.schema = bytes32(0);
        vm.expectRevert(IStatementLog.InvalidSchema.selector);
        _append(Role.ARTIST, artist, s);

        s = _statement();
        s.content.digest = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidHashRef.selector, HASH_SHA256));
        _append(Role.ARTIST, artist, s);

        s = _statement();
        s.content.algorithm = 4; // variable-length multihash: reserved, not accepted
        vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidHashRef.selector, 4));
        _append(Role.ARTIST, artist, s);

        s = _statement();
        s.content.algorithm = 0;
        vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidHashRef.selector, 0));
        _append(Role.ARTIST, artist, s);
    }

    function test_Validation_Locators() public {
        Statement memory s = _statement();
        s.fileId = keccak256("file");
        vm.expectRevert(IStatementLog.ConflictingLocators.selector);
        _append(Role.ARTIST, artist, s); // uri and fileId

        s.uri = ""; // a ContentStore file alone
        _append(Role.ARTIST, artist, s);

        s.fileId = bytes32(0); // neither locator: not accepted
        vm.expectRevert(IStatementLog.MissingLocator.selector);
        _append(Role.ARTIST, artist, s);

        s.uri = _ascii(2048);
        _append(Role.ARTIST, artist, s);

        s.uri = _ascii(2049);
        vm.expectRevert(IStatementLog.InvalidUri.selector);
        _append(Role.ARTIST, artist, s);
    }

    function test_Validation_UriMustBeUtf8() public {
        Statement memory s = _statement();
        bytes[3] memory bad = [
            bytes(hex"ff"),
            hex"c080", /* overlong */
            hex"e282" /* truncated */
        ];
        for (uint256 i; i < bad.length; ++i) {
            s.uri = string(bad[i]);
            vm.expectRevert(IStatementLog.InvalidUri.selector);
            _append(Role.ARTIST, artist, s);
        }
        s.uri = unicode"ipfs://café";
        _append(Role.ARTIST, artist, s);
    }

    function test_Validation_AcceptsEveryRecognisedAlgorithm() public {
        uint16[3] memory ok = [HASH_KECCAK256, HASH_SHA256, HASH_BLAKE3];
        for (uint256 i; i < ok.length; ++i) {
            Statement memory s = _statement();
            s.content.algorithm = ok[i];
            _append(Role.ARTIST, artist, s);
        }
        // 4 and 5 (variable-length multihash, CID) and 6 (an Arweave transaction ID, which is a
        // locator, not a digest) are not digests the log accepts.
        for (uint16 a = 4; a <= 7; ++a) {
            Statement memory s = _statement();
            s.content.algorithm = a;
            vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidHashRef.selector, a));
            _append(Role.ARTIST, artist, s);
        }
    }

    function test_Kinds_AreStableLabels() public pure {
        assertEq(StatementKinds.ARTIST_STATEMENT, keccak256("ARTIST_STATEMENT"));
        assertEq(StatementKinds.INTERVIEW, keccak256("INTERVIEW"));
        assertEq(StatementKinds.EXHIBITION, keccak256("EXHIBITION"));
        assertEq(StatementKinds.CONSERVATION_NOTE, keccak256("CONSERVATION_NOTE"));
        assertEq(StatementKinds.STORAGE_COPY, keccak256("STORAGE_COPY"));
        assertEq(StatementKinds.FIXITY_CHECK, keccak256("FIXITY_CHECK"));
        assertEq(StatementKinds.ACCESSION, keccak256("ACCESSION"));
        assertEq(StatementKinds.DISPUTE_OUTCOME, keccak256("DISPUTE_OUTCOME"));
        assertEq(StatementKinds.CURATION_EVIDENCE, keccak256("CURATION_EVIDENCE"));
        assertEq(StatementKinds.GOVERNANCE_MANIFEST, keccak256("GOVERNANCE_MANIFEST"));
    }

    function test_ExtensibleKindIsAccepted() public {
        Statement memory s = _statement();
        s.kind = keccak256("SOME_FUTURE_KIND");
        _expectAppend(Role.ARTIST, artist, s);
        _append(Role.ARTIST, artist, s);
    }

    // ------------------------------------------------------------- SUPERSESSION

    function test_Supersession_IsANewEntryAndNothingIsOverwritten() public {
        Statement memory original = _statement();
        vm.recordLogs();
        bytes32 first = _append(Role.ARTIST, artist, original);

        Statement memory correction = _statement();
        correction.uri = "ar://corrected";
        correction.supersedes = first;
        bytes32 second = _append(Role.ARTIST, artist, correction);

        assertTrue(first != second);
        (uint64 count,) = stmtLog.chainOf(address(nft), 1);
        assertEq(count, 2);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "both entries stay in the log");
        StatementModel.Appended memory a = StatementModel.decode(logs[0]);
        StatementModel.Appended memory b = StatementModel.decode(logs[1]);
        assertEq(a.statement.uri, "ar://document");
        assertEq(a.statement.supersedes, bytes32(0));
        assertEq(b.statement.supersedes, a.entryHash);
        assertEq(b.index, 1);
    }

    function test_Supersession_OfAnotherRolesEntryIsAllowedAndRecorded() public {
        bytes32 ownersEntry = _append(Role.OWNER, tokenOwner, _statement());
        Statement memory s = _statement();
        s.kind = StatementKinds.DISPUTE_OUTCOME;
        s.supersedes = ownersEntry;
        vm.prank(platform);
        stmtLog.appendPlatform(s);
        (uint64 count,) = stmtLog.chainOf(address(nft), 1);
        assertEq(count, 2);
    }

    function test_IdenticalStatementsGetDistinctEntries() public {
        Statement memory s = _statement();
        bytes32 first = _append(Role.ARTIST, artist, s);
        bytes32 second = _append(Role.ARTIST, artist, s);
        assertTrue(first != second);
        (uint64 count,) = stmtLog.chainOf(address(nft), 1);
        assertEq(count, 2);
    }

    function test_SubjectsHaveIndependentChains() public {
        resolver.grantEverywhere(artist);
        _append(Role.ARTIST, artist, _statement(address(nft), 1));
        _append(Role.ARTIST, artist, _statement(address(nft), 2));
        _append(Role.ARTIST, artist, _statement(address(nft), 2));
        _append(Role.ARTIST, artist, _statement(address(0), 2));

        (uint64 c1,) = stmtLog.chainOf(address(nft), 1);
        (uint64 c2,) = stmtLog.chainOf(address(nft), 2);
        (uint64 cw,) = stmtLog.chainOf(address(0), 2);
        (uint64 c3, bytes32 h3) = stmtLog.chainOf(address(nft), 3);
        assertEq(c1, 1);
        assertEq(c2, 2);
        assertEq(cw, 1);
        assertEq(c3, 0);
        assertEq(h3, bytes32(0));
        assertEq(stmtLog.subjectKey(address(nft), 1), StatementModel.subjectKey(address(nft), 1));
    }

    // -------------------------------------------------------------- RESOLVER

    function test_SetArtistResolver_IsRestricted() public {
        ArtistResolverMock next = new ArtistResolverMock();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        vm.prank(stranger);
        stmtLog.setArtistResolver(address(resolver), address(next), address(next).codehash);
    }

    function test_SetArtistResolver_SwapsAndEmits() public {
        ArtistResolverMock next = new ArtistResolverMock();
        vm.expectEmit(true, true, false, true, address(stmtLog));
        emit IStatementLog.ArtistResolverSet(
            address(resolver), address(next), address(next).codehash
        );
        vm.prank(admin);
        stmtLog.setArtistResolver(address(resolver), address(next), address(next).codehash);
        assertEq(stmtLog.artistResolver(), address(next));

        // The old resolver's artists lose the role immediately; the new resolver decides.
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.ARTIST, artist)
        );
        _append(Role.ARTIST, artist, _statement());
    }

    function test_SetArtistResolver_StaleExpectedValueReverts() public {
        ArtistResolverMock next = new ArtistResolverMock();
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.ResolverMismatch.selector, address(resolver))
        );
        vm.prank(admin);
        stmtLog.setArtistResolver(address(0xBEEF), address(next), address(next).codehash);
    }

    function test_SetArtistResolver_RejectsUnsuitableResolvers() public {
        ArtistResolverMock next = new ArtistResolverMock();
        address r = address(resolver);

        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.InvalidResolver.selector, makeAddr("eoa"))
        );
        vm.prank(admin);
        stmtLog.setArtistResolver(r, makeAddr("eoa"), bytes32(0));

        address wrong = address(new WrongInterfaceMock());
        vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidResolver.selector, wrong));
        vm.prank(admin);
        stmtLog.setArtistResolver(r, wrong, wrong.codehash);

        address plain = address(nft); // no ERC-165 at all
        vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidResolver.selector, plain));
        vm.prank(admin);
        stmtLog.setArtistResolver(r, plain, plain.codehash);

        address delegated = makeAddr("7702 account");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(next)));
        vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidResolver.selector, delegated));
        vm.prank(admin);
        stmtLog.setArtistResolver(r, delegated, delegated.codehash);

        vm.expectRevert(
            abi.encodeWithSelector(
                IStatementLog.ResolverCodeHashMismatch.selector,
                bytes32(uint256(1)),
                address(next).codehash
            )
        );
        vm.prank(admin);
        stmtLog.setArtistResolver(r, address(next), bytes32(uint256(1)));
    }

    function test_SetArtistResolver_ZeroDisablesArtistStatements() public {
        vm.prank(admin);
        stmtLog.setArtistResolver(address(resolver), address(0), bytes32(0));
        assertEq(stmtLog.artistResolver(), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.ARTIST, artist)
        );
        _append(Role.ARTIST, artist, _statement());
    }

    function test_Constructor_RejectsUnsuitableResolver() public {
        address wrong = address(new WrongInterfaceMock());
        vm.expectRevert(abi.encodeWithSelector(IStatementLog.InvalidResolver.selector, wrong));
        new StatementLog(address(manager), wrong, wrong.codehash);
    }

    function test_NothingIsPayable() public {
        Statement memory s = _statement();
        (bool ok,) =
            address(stmtLog).call{ value: 1 }(abi.encodeCall(StatementLog.append, (Role.ARTIST, s)));
        assertFalse(ok);
        (ok,) = address(stmtLog).call{ value: 1 }(abi.encodeCall(StatementLog.appendCurator, (s)));
        assertFalse(ok);
        (ok,) = address(stmtLog).call{ value: 1 }(abi.encodeCall(StatementLog.revokeNonce, (1)));
        assertFalse(ok);
        (ok,) = address(stmtLog).call{ value: 1 }("");
        assertFalse(ok);
        assertEq(address(stmtLog).balance, 0);
    }

    // ------------------------------------------------ HASH CHAIN FROM EVENTS

    function test_HashChainRebuiltFromEventsEqualsStoredHeads() public {
        resolver.grantEverywhere(artist);
        nft.setOwner(2, tokenOwner);
        vm.recordLogs();

        uint64 deadline = uint64(block.timestamp + 1 days);
        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + 1 + i);
            Statement memory s = _statement(address(nft), 1 + (i % 2));
            s.uri = string.concat("ar://doc-", vm.toString(i));
            if (i % 3 == 0) _append(Role.ARTIST, artist, s);
            if (i % 3 == 1) _append(Role.OWNER, tokenOwner, s);
            if (i % 3 == 2) {
                _relay(
                    Role.CURATOR,
                    s,
                    curatorSigner,
                    i,
                    deadline,
                    _sign(curatorKey, Role.CURATOR, s, i, deadline)
                );
            }
        }
        vm.prank(platform);
        stmtLog.appendPlatform(_statement(address(0), 9));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32[3] memory heads; // subjects: (nft,1), (nft,2), (0,9)
        uint64[3] memory counts;
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (!StatementModel.isAppended(logs[i], address(stmtLog))) continue;
            StatementModel.Appended memory e = StatementModel.decode(logs[i]);
            uint256 slot = e.statement.token == address(0) ? 2 : e.statement.id - 1;
            assertEq(e.index, counts[slot], "indices are gapless");
            bytes32 entry = StatementModel.entryHash(
                address(stmtLog),
                block.chainid,
                e.index,
                e.role,
                e.signer,
                e.resolver,
                e.recordedAt,
                e.statement
            );
            assertEq(entry, e.entryHash, "entry hash is recomputable from the event");
            assertEq(e.resolver, e.role == Role.ARTIST ? address(resolver) : address(0));
            heads[slot] = StatementModel.fold(heads[slot], entry);
            assertEq(heads[slot], e.head, "event head matches the rebuilt chain");
            ++counts[slot];
            ++seen;
        }
        assertEq(seen, 7);

        (uint64 c, bytes32 h) = stmtLog.chainOf(address(nft), 1);
        assertEq(c, counts[0]);
        assertEq(h, heads[0]);
        (c, h) = stmtLog.chainOf(address(nft), 2);
        assertEq(c, counts[1]);
        assertEq(h, heads[1]);
        (c, h) = stmtLog.chainOf(address(0), 9);
        assertEq(c, counts[2]);
        assertEq(h, heads[2]);
    }

    // -------------------------------------------------------------------- FUZZ

    function testFuzz_SequenceMatchesModel(uint256 seed, uint8 rawCount) public {
        uint256 n = bound(rawCount, 1, 24);
        resolver.grantEverywhere(artist);
        bytes32[3] memory heads;
        bytes32[3] memory lastEntries;
        uint64[3] memory counts;
        for (uint256 i; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 slot = seed % 3;
            Statement memory s = _statement(address(nft), slot + 1);
            s.kind = bytes32(seed >> 8) | bytes32(uint256(1));
            s.schema = bytes32(seed >> 16) | bytes32(uint256(1));
            s.content.digest = bytes32(seed >> 24) | bytes32(uint256(1));
            s.uri = _ascii(1 + (seed >> 32) % 63);
            if ((seed >> 100) % 2 == 0) s.supersedes = lastEntries[slot]; // an earlier entry hash
            vm.warp(block.timestamp + ((seed >> 40) % 1000));

            bytes32 entry = StatementModel.entryHash(
                address(stmtLog),
                block.chainid,
                counts[slot],
                Role.ARTIST,
                artist,
                address(resolver),
                uint64(block.timestamp),
                s
            );
            heads[slot] = StatementModel.fold(heads[slot], entry);
            lastEntries[slot] = entry;
            ++counts[slot];
            assertEq(_append(Role.ARTIST, artist, s), entry);
        }
        for (uint256 slot; slot < 3; ++slot) {
            (uint64 count, bytes32 head) = stmtLog.chainOf(address(nft), slot + 1);
            assertEq(count, counts[slot]);
            assertEq(head, heads[slot]);
        }
    }

    function testFuzz_AnySubjectAndContentRoundTrips(
        address token,
        uint256 id,
        bytes32 kind,
        bytes32 schema,
        bytes32 digest,
        bytes32 fileId,
        bytes32 supersedes
    ) public {
        vm.assume(kind != 0 && schema != 0 && digest != 0 && fileId != 0);
        // The fuzzer picks keccak constants out of the bytecode, so exclude every reserved kind.
        vm.assume(
            kind != StatementKinds.DISPUTE_OUTCOME && kind != StatementKinds.CURATION_EVIDENCE
                && kind != StatementKinds.GOVERNANCE_MANIFEST
        );
        vm.assume(token != address(0) || id != 0);
        resolver.grantEverywhere(artist);
        Statement memory s = Statement(
            token, id, kind, schema, HashRef(HASH_SHA256, digest), "", fileId, supersedes
        );
        (bytes32 entry, bytes32 head) = _expectAppend(Role.ARTIST, artist, s);
        assertEq(_append(Role.ARTIST, artist, s), entry);
        (uint64 count, bytes32 stored) = stmtLog.chainOf(token, id);
        assertEq(count, 1);
        assertEq(stored, head);
    }

    function testFuzz_RelayRoundTripAndReplay(uint256 nonce, uint32 lead, uint64 extra) public {
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp) + lead;
        bytes memory sig = _sign(artistKey, Role.ARTIST, s, nonce, deadline);
        vm.warp(block.timestamp + (extra % (uint64(lead) + 1)));
        _relay(Role.ARTIST, s, artist, nonce, deadline, sig);
        assertTrue(stmtLog.nonceUsed(artist, nonce));
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NonceAlreadyUsed.selector, artist, nonce)
        );
        _relay(Role.ARTIST, s, artist, nonce, deadline, sig);
    }

    function testFuzz_NonceBitmapTracksExactlyTheSpentNonces(uint256 a, uint256 b) public {
        vm.assume(a != b);
        vm.prank(stranger);
        stmtLog.revokeNonce(a);
        assertTrue(stmtLog.nonceUsed(stranger, a));
        assertFalse(stmtLog.nonceUsed(stranger, b));
        vm.prank(stranger);
        stmtLog.revokeNonce(b);
        assertTrue(stmtLog.nonceUsed(stranger, b));
    }

    // --------------------------------------------------------------------- GAS

    /// @dev Marks every contract a call touches cold again, so a measurement matches a call in
    ///      its own transaction rather than one riding on warm slots from earlier in the test.
    function _cool() internal {
        vm.cool(address(stmtLog));
        vm.cool(address(resolver));
        vm.cool(address(nft));
        vm.cool(address(manager));
    }

    /// @dev Execution gas of one append (excluding the 21,000 intrinsic and calldata gas), with
    ///      cold storage and accounts as in a real transaction.
    function test_Gas_PerAppend() public {
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig0 = _sign(artistKey, Role.ARTIST, s, 0, deadline);
        bytes memory sig1 = _sign(artistKey, Role.ARTIST, s, 1, deadline);
        bytes memory sig256 = _sign(artistKey, Role.ARTIST, s, 256, deadline);
        uint256[7] memory used;
        uint256 g;

        _cool();
        vm.prank(artist);
        g = gasleft();
        stmtLog.append(Role.ARTIST, s);
        used[0] = g - gasleft(); // first entry for a subject: count and head slots go 0 -> non-zero

        _cool();
        vm.prank(artist);
        g = gasleft();
        stmtLog.append(Role.ARTIST, s);
        used[1] = g - gasleft(); // a later entry: both slots are rewritten

        _cool();
        vm.prank(tokenOwner);
        g = gasleft();
        stmtLog.append(Role.OWNER, s);
        used[2] = g - gasleft();

        _cool();
        vm.prank(curator);
        g = gasleft();
        stmtLog.appendCurator(s);
        used[3] = g - gasleft();

        _cool();
        vm.prank(stranger);
        g = gasleft();
        stmtLog.appendSigned(Role.ARTIST, s, artist, 0, deadline, sig0);
        used[4] = g - gasleft(); // relay; the nonce word goes 0 -> non-zero

        _cool();
        vm.prank(stranger);
        g = gasleft();
        stmtLog.appendSigned(Role.ARTIST, s, artist, 1, deadline, sig1);
        used[5] = g - gasleft(); // relay; the nonce word is already non-zero

        _cool();
        vm.prank(stranger);
        g = gasleft();
        stmtLog.appendSigned(Role.ARTIST, s, artist, 256, deadline, sig256);
        used[6] = g - gasleft(); // relay; a new nonce word

        emit log_named_uint("gas append ARTIST, first entry of a subject", used[0]);
        emit log_named_uint("gas append ARTIST, later entry", used[1]);
        emit log_named_uint("gas append OWNER (ERC-721 ownerOf), later entry", used[2]);
        emit log_named_uint("gas appendCurator (AccessManager canCall), later entry", used[3]);
        emit log_named_uint("gas appendSigned ARTIST, first nonce word", used[4]);
        emit log_named_uint("gas appendSigned ARTIST, same nonce word", used[5]);
        emit log_named_uint("gas appendSigned ARTIST, new nonce word", used[6]);

        assertLt(used[0], 85_000);
        assertLt(used[1], 42_000);
        assertLt(used[2], 42_000);
        assertLt(used[3], 48_000);
        assertLt(used[4], 78_000);
        assertLt(used[5], 58_000);
        assertLt(used[6], 78_000);
    }
}
