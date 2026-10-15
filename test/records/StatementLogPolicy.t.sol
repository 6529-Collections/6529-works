// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { IStatementLog, Role, Statement } from "src/interfaces/IStatementLog.sol";
import { StatementLogFixture } from "./StatementLogFixture.sol";
import { StatementModel } from "./StatementModel.sol";
import {
    ArtistResolverMock,
    ERC1155BalanceMock,
    OZERC1155Mock,
    OZERC721Mock
} from "../mocks/records/RecordsMocks.sol";
import { EvilResolverMock, ForwardingResolverMock } from "../mocks/records/RecordsResolvers.sol";

/// @notice The policy the review asked for: the ARTIST trust boundary and resolver binding, no
///         attribution to the AccessManager, reserved kinds, the dispute pointer, the relayed-nonce
///         event, the nonce bitmap boundaries and the governance manifest exception.
contract StatementLogPolicyTest is StatementLogFixture {
    // ------------------------------------------------ ARTIST trust boundary

    /// @dev Governance can replace the resolver, and only that way can it speak for artists. The
    ///      swap is public, and every ARTIST entry records which resolver vouched for it.
    function test_ResolverSwap_IsTheOnlyGovernedPathToArtistEntriesAndIsRecorded() public {
        vm.recordLogs();
        _append(Role.ARTIST, artist, _statement());

        vm.prank(admin);
        EvilResolverMock evil = new EvilResolverMock();
        vm.prank(admin);
        stmtLog.setArtistResolver(address(resolver), address(evil), address(evil).codehash);
        Statement memory forged = _statement(address(nft), 424_242); // a work the admin has no claim to
        _append(Role.ARTIST, admin, forged);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        StatementModel.Appended[] memory entries = new StatementModel.Appended[](2);
        uint256 n;
        uint256 swaps;
        for (uint256 i; i < logs.length; ++i) {
            if (StatementModel.isAppended(logs[i], address(stmtLog))) {
                entries[n++] = StatementModel.decode(logs[i]);
            } else if (logs[i].topics[0] == IStatementLog.ArtistResolverSet.selector) {
                ++swaps;
            }
        }
        assertEq(n, 2);
        assertEq(swaps, 1, "the swap is an event");
        assertEq(entries[0].resolver, address(resolver));
        assertEq(
            entries[1].resolver, address(evil), "the forged entry names the resolver behind it"
        );
        assertEq(entries[1].signer, admin);
    }

    /// @dev The code-hash pin binds bytecode, not behaviour: a forwarding resolver can change its
    ///      answers without a log event. The entry still names the forwarder, so readers can tell
    ///      which resolver (and so whose governance) they are trusting.
    function test_ForwardingResolver_PinDoesNotPinBehaviourButTheEntryNamesIt() public {
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        ForwardingResolverMock forwarder = new ForwardingResolverMock(address(resolver));
        vm.prank(admin);
        stmtLog.setArtistResolver(
            address(resolver), address(forwarder), address(forwarder).codehash
        );

        vm.prank(keeper);
        EvilResolverMock evil = new EvilResolverMock();
        vm.prank(keeper);
        forwarder.setBackend(address(evil)); // no log call, no log event
        vm.recordLogs();
        vm.prank(keeper);
        stmtLog.append(Role.ARTIST, _statement());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(StatementModel.decode(logs[0]).resolver, address(forwarder));
    }

    function test_OwnerAndPlatformEntriesCarryNoResolver() public {
        vm.recordLogs();
        _append(Role.OWNER, tokenOwner, _statement());
        vm.prank(platform);
        stmtLog.appendPlatform(_statement());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(StatementModel.decode(logs[0]).resolver, address(0));
        assertEq(StatementModel.decode(logs[1]).resolver, address(0));
    }

    function test_ResolverIsPartOfTheEntryHash() public {
        // The same statement under two resolvers hashes differently.
        ArtistResolverMock other = new ArtistResolverMock();
        other.grantEverywhere(artist);
        Statement memory s = _statement();
        bytes32 withFirst = StatementModel.entryHash(
            address(stmtLog), block.chainid, 0, Role.ARTIST, artist, address(resolver), 1, s
        );
        bytes32 withOther = StatementModel.entryHash(
            address(stmtLog), block.chainid, 0, Role.ARTIST, artist, address(other), 1, s
        );
        assertTrue(withFirst != withOther);
    }

    // ------------------------------------------- no attribution to the manager

    function test_Manager_CannotBeTheRecordedSignerOnAnyPath() public {
        // The manager holds an edition and is wired in as an artist: it would pass the role checks.
        editions.setBalance(7, address(manager), 1);
        resolver.grantEverywhere(address(manager));

        Statement memory owned = _statement(address(editions), 7);
        vm.expectRevert(IStatementLog.AuthorityCannotSign.selector);
        _append(Role.OWNER, address(manager), owned);

        vm.expectRevert(IStatementLog.AuthorityCannotSign.selector);
        _append(Role.ARTIST, address(manager), _statement());

        // The same through AccessManager.execute, as the reviewer's proof of concept did.
        bytes memory data = abi.encodeCall(StatementLog.append, (Role.OWNER, owned));
        vm.expectRevert(IStatementLog.AuthorityCannotSign.selector);
        vm.prank(admin);
        manager.execute(address(stmtLog), data);

        // And the restricted paths: the manager is the caller only when it executes them.
        bytes memory curatorCall = abi.encodeCall(StatementLog.appendCurator, (_statement()));
        vm.expectRevert(IStatementLog.AuthorityCannotSign.selector);
        vm.prank(curator);
        manager.execute(address(stmtLog), curatorCall);
        bytes memory platformCall = abi.encodeCall(StatementLog.appendPlatform, (_statement()));
        vm.expectRevert(IStatementLog.AuthorityCannotSign.selector);
        vm.prank(platform);
        manager.execute(address(stmtLog), platformCall);
    }

    // ------------------------------------------------------- reserved kinds

    function test_ReservedKinds_DisputeOutcomeIsPlatformOnly() public {
        Statement memory s = _statement();
        s.kind = StatementKinds.DISPUTE_OUTCOME;
        address[3] memory others = [artist, tokenOwner, curator];
        Role[3] memory roles = [Role.ARTIST, Role.OWNER, Role.CURATOR];
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStatementLog.ReservedKind.selector, StatementKinds.DISPUTE_OUTCOME, roles[i]
                )
            );
            vm.prank(others[i]);
            if (roles[i] == Role.CURATOR) stmtLog.appendCurator(s);
            else stmtLog.append(roles[i], s);
        }
        vm.prank(platform);
        stmtLog.appendPlatform(s);
    }

    function test_ReservedKinds_CurationEvidenceIsCuratorOnly() public {
        Statement memory s = _statement();
        s.kind = StatementKinds.CURATION_EVIDENCE;
        address[3] memory others = [artist, tokenOwner, platform];
        Role[3] memory roles = [Role.ARTIST, Role.OWNER, Role.PLATFORM];
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStatementLog.ReservedKind.selector, StatementKinds.CURATION_EVIDENCE, roles[i]
                )
            );
            vm.prank(others[i]);
            if (roles[i] == Role.PLATFORM) stmtLog.appendPlatform(s);
            else stmtLog.append(roles[i], s);
        }
        vm.prank(curator);
        stmtLog.appendCurator(s);
    }

    function test_ReservedKinds_AlsoHoldForRelayedStatements() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        Statement memory dispute = _statement();
        dispute.kind = StatementKinds.DISPUTE_OUTCOME;
        bytes memory sig = _sign(artistKey, Role.ARTIST, dispute, 0, deadline);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStatementLog.ReservedKind.selector, StatementKinds.DISPUTE_OUTCOME, Role.ARTIST
            )
        );
        _relay(Role.ARTIST, dispute, artist, 0, deadline, sig);

        Statement memory evidence = _statement();
        evidence.kind = StatementKinds.CURATION_EVIDENCE;
        _relay(
            Role.CURATOR,
            evidence,
            curatorSigner,
            0,
            deadline,
            _sign(curatorKey, Role.CURATOR, evidence, 0, deadline)
        );
    }

    // ------------------------------------------------- latest dispute outcome

    function test_LatestDisputeOutcome_TracksOnlyDisputeEntries() public {
        assertEq(stmtLog.latestDisputeOutcome(address(nft), 1), bytes32(0));

        Statement memory dispute = _statement();
        dispute.kind = StatementKinds.DISPUTE_OUTCOME;
        vm.prank(platform);
        bytes32 first = stmtLog.appendPlatform(dispute);
        assertEq(stmtLog.latestDisputeOutcome(address(nft), 1), first);

        // Other kinds, from any role, leave the pointer alone.
        _append(Role.ARTIST, artist, _statement());
        _append(Role.OWNER, tokenOwner, _statement());
        vm.prank(platform);
        stmtLog.appendPlatform(_statement());
        assertEq(stmtLog.latestDisputeOutcome(address(nft), 1), first);

        // A later outcome (here superseding the first) replaces it; the old entry stays in the log.
        dispute.supersedes = first;
        vm.prank(platform);
        bytes32 second = stmtLog.appendPlatform(dispute);
        assertEq(stmtLog.latestDisputeOutcome(address(nft), 1), second);
        assertTrue(first != second);

        // Per subject.
        assertEq(stmtLog.latestDisputeOutcome(address(nft), 2), bytes32(0));
        assertEq(stmtLog.latestDisputeOutcome(address(0), 1), bytes32(0));
    }

    /// @dev LIFECYCLE-4: an outcome about an ERC-721 token needs the token to exist now; an
    ///      ERC-1155 subject is refused (an edition's outcome goes on its master); subjects that
    ///      are not tokens, such as an item or an artist ID, are not checked.
    function test_DisputeOutcome_SubjectRules() public {
        OZERC721Mock works = new OZERC721Mock();
        OZERC1155Mock copies = new OZERC1155Mock();
        works.mint(tokenOwner, 1);
        copies.mint(tokenOwner, 1, 1);
        Statement memory dispute = _statement();
        dispute.kind = StatementKinds.DISPUTE_OUTCOME;

        (dispute.token, dispute.id) = (address(works), 1);
        vm.prank(platform);
        stmtLog.appendPlatform(dispute);
        dispute.id = 2;
        vm.prank(platform);
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.UnknownDisputeSubject.selector, address(works), 2)
        );
        stmtLog.appendPlatform(dispute);

        (dispute.token, dispute.id) = (address(copies), 1);
        vm.prank(platform);
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.UnknownDisputeSubject.selector, address(copies), 1)
        );
        stmtLog.appendPlatform(dispute);

        // Other kinds about the same subjects, and outcomes about non-token subjects, pass.
        dispute.kind = keccak256("SOME_PLATFORM_NOTE");
        vm.prank(platform);
        stmtLog.appendPlatform(dispute);
        dispute.kind = StatementKinds.DISPUTE_OUTCOME;
        (dispute.token, dispute.id) = (address(0), uint256(keccak256("an item")));
        vm.prank(platform);
        stmtLog.appendPlatform(dispute);
        (dispute.token, dispute.id) = (address(stmtLog), 7); // a contract that is no token
        vm.prank(platform);
        stmtLog.appendPlatform(dispute);
    }

    /// @dev A subject's own latest outcome and its position in the chain: a caller that read the
    ///      chain's count earlier tells whether the outcome was recorded since.
    function test_DisputeOutcomeOf_IsTheOwnLatestOutcomeAndItsPosition() public {
        (bytes32 none, uint64 noIndex) = stmtLog.disputeOutcomeOf(address(nft), 1);
        assertEq(none, bytes32(0));
        assertEq(noIndex, 0);
        _append(Role.ARTIST, artist, _statement()); // index 0
        Statement memory dispute = _statement();
        dispute.kind = StatementKinds.DISPUTE_OUTCOME;
        vm.prank(platform);
        bytes32 first = stmtLog.appendPlatform(dispute); // index 1
        (bytes32 entry, uint64 index) = stmtLog.disputeOutcomeOf(address(nft), 1);
        assertEq(entry, first);
        assertEq(index, 1);
        (uint64 countBefore,) = stmtLog.chainOf(address(nft), 1);
        _append(Role.OWNER, tokenOwner, _statement()); // index 2: not an outcome
        (, index) = stmtLog.disputeOutcomeOf(address(nft), 1);
        assertLt(index, countBefore, "recorded before the count was read");
        vm.prank(platform);
        bytes32 second = stmtLog.appendPlatform(dispute); // index 3
        (entry, index) = stmtLog.disputeOutcomeOf(address(nft), 1);
        assertEq(entry, second);
        assertEq(index, 3);
        assertGe(index, countBefore, "recorded since");
    }

    function test_LatestDisputeOutcome_IsTheEntryHashInTheEvent() public {
        Statement memory dispute = _statement();
        dispute.kind = StatementKinds.DISPUTE_OUTCOME;
        vm.recordLogs();
        vm.prank(platform);
        stmtLog.appendPlatform(dispute);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(
            stmtLog.latestDisputeOutcome(address(nft), 1), StatementModel.decode(logs[0]).entryHash
        );
    }

    // ----------------------------------------------------- relayed nonce event

    function test_Relay_EmitsTheNonceAndDirectEntriesDoNot() public {
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(artistKey, Role.ARTIST, s, 77, deadline);

        vm.recordLogs();
        bytes32 entry = _relay(Role.ARTIST, s, artist, 77, deadline, sig);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "the entry, then its nonce");
        assertTrue(StatementModel.isAppended(logs[0], address(stmtLog)));
        assertTrue(StatementModel.isRelayed(logs[1], address(stmtLog)));
        assertEq(logs[1].topics[1], entry);
        assertEq(address(uint160(uint256(logs[1].topics[2]))), artist);
        assertEq(abi.decode(logs[1].data, (uint256)), 77);

        vm.recordLogs();
        _append(Role.ARTIST, artist, s);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertTrue(StatementModel.isAppended(logs[0], address(stmtLog)));
    }

    // --------------------------------------------------- nonce bitmap boundaries

    /// @dev Spends each boundary nonce in turn and checks that no other one flips. A mask of 0x7f
    ///      instead of 0xff makes 128 alias 0 (and 255 alias 127), so this fails on it.
    function test_Nonce_BitmapBoundaries() public {
        uint256[6] memory nonces = [uint256(0), 127, 128, 255, 256, 2 ** 200];
        for (uint256 i; i < nonces.length; ++i) {
            for (uint256 j; j < nonces.length; ++j) {
                assertEq(
                    stmtLog.nonceUsed(stranger, nonces[j]), j < i, "only spent nonces are used"
                );
            }
            vm.prank(stranger);
            stmtLog.revokeNonce(nonces[i]);
        }
        for (uint256 j; j < nonces.length; ++j) {
            assertTrue(stmtLog.nonceUsed(stranger, nonces[j]));
        }
        // Neighbours of every boundary stay unspent.
        uint256[8] memory neighbours =
            [uint256(1), 126, 129, 254, 257, 2 ** 200 + 1, 2 ** 200 - 1, 2 ** 200 + 256];
        for (uint256 j; j < neighbours.length; ++j) {
            assertFalse(stmtLog.nonceUsed(stranger, neighbours[j]));
        }
    }

    /// @dev The same boundaries through the relay, so the check applies where the nonce is spent.
    function test_Nonce_RelayRespectsBoundariesAndRevokedNeighboursDoNotBlock() public {
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        uint256[5] memory nonces = [uint256(127), 128, 255, 256, 2 ** 200];
        for (uint256 i; i < nonces.length; ++i) {
            _relay(
                Role.ARTIST,
                s,
                artist,
                nonces[i],
                deadline,
                _sign(artistKey, Role.ARTIST, s, nonces[i], deadline)
            );
            vm.expectRevert(
                abi.encodeWithSelector(IStatementLog.NonceAlreadyUsed.selector, artist, nonces[i])
            );
            _relay(
                Role.ARTIST,
                s,
                artist,
                nonces[i],
                deadline,
                _sign(artistKey, Role.ARTIST, s, nonces[i], deadline)
            );
        }
        assertFalse(stmtLog.nonceUsed(artist, 0));
        assertFalse(stmtLog.nonceUsed(artist, 129));
    }

    // ------------------------------------------------- governance manifest

    function test_GovernanceManifest_ScheduledExecutionRecordsTheManagerAsPlatform() public {
        Statement memory s = _governanceStatement();
        bytes memory data = abi.encodeCall(StatementLog.appendGovernanceManifest, (s));
        vm.prank(governor);
        manager.schedule(address(stmtLog), data, 0);
        vm.warp(block.timestamp + GOVERNANCE_DELAY);

        vm.recordLogs();
        (bytes32 entry, bytes32 head) = _expectAppend(Role.PLATFORM, address(manager), s);
        vm.prank(governor);
        manager.execute(address(stmtLog), data);

        (uint64 count, bytes32 stored) = stmtLog.chainOf(address(manager), 0);
        assertEq(count, 1, "the governance chain lives under the manager's address");
        assertEq(stored, head);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (!StatementModel.isAppended(logs[i], address(stmtLog))) continue;
            StatementModel.Appended memory e = StatementModel.decode(logs[i]);
            assertEq(e.signer, address(manager));
            assertEq(uint8(e.role), uint8(Role.PLATFORM));
            assertEq(e.resolver, address(0));
            assertEq(e.kind, StatementKinds.GOVERNANCE_MANIFEST);
            assertEq(e.entryHash, entry);
            seen = true;
        }
        assertTrue(seen);
        assertEq(stmtLog.latestDisputeOutcome(address(manager), 0), bytes32(0));

        // The next epoch supersedes it: a new entry, the first one stays.
        Statement memory next = _governanceStatement();
        next.uri = "ar://manifest-2";
        next.supersedes = entry;
        _scheduleAndExecuteManifest(next);
        (count,) = stmtLog.chainOf(address(manager), 0);
        assertEq(count, 2);
    }

    function test_GovernanceManifest_CannotBeWrittenWithoutTheRoleOrTheSchedule() public {
        Statement memory s = _governanceStatement();
        bytes memory data = abi.encodeCall(StatementLog.appendGovernanceManifest, (s));

        // No role: strangers, the other operational roles and the admin.
        address[4] memory outsiders = [stranger, curator, platform, admin];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManaged.AccessManagedUnauthorized.selector, outsiders[i]
                )
            );
            vm.prank(outsiders[i]);
            stmtLog.appendGovernanceManifest(s);
        }

        // The role holder has a 30-day delay: unscheduled, early and late calls all fail.
        vm.expectPartialRevert(IAccessManager.AccessManagerNotScheduled.selector);
        vm.prank(governor);
        stmtLog.appendGovernanceManifest(s);

        vm.prank(governor);
        manager.schedule(address(stmtLog), data, 0);
        vm.expectPartialRevert(IAccessManager.AccessManagerNotReady.selector);
        vm.prank(governor);
        manager.execute(address(stmtLog), data);

        vm.warp(block.timestamp + GOVERNANCE_DELAY + manager.expiration() + 1);
        vm.expectPartialRevert(IAccessManager.AccessManagerExpired.selector);
        vm.prank(governor);
        manager.execute(address(stmtLog), data);

        (uint64 count,) = stmtLog.chainOf(address(manager), 0);
        assertEq(count, 0);
    }

    /// @dev The log checks what it records, not how it was reached. These calls go through a log
    ///      whose selector is mapped to a zero-delay role, so the log's own checks are what fail.
    function test_GovernanceManifest_MustBeAboutTheManagerWithTheGovernanceKind() public {
        StatementLog direct =
            new StatementLog(address(manager), address(resolver), address(resolver).codehash);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = direct.appendGovernanceManifest.selector;
        vm.prank(admin);
        manager.setTargetFunctionRole(address(direct), selectors, CURATOR_ROLE);

        Statement memory s = _governanceStatement();
        s.token = address(nft);
        vm.expectRevert(IStatementLog.InvalidGovernanceManifest.selector);
        vm.prank(curator);
        direct.appendGovernanceManifest(s);

        s = _governanceStatement();
        s.id = 1;
        vm.expectRevert(IStatementLog.InvalidGovernanceManifest.selector);
        vm.prank(curator);
        direct.appendGovernanceManifest(s);

        s = _governanceStatement();
        s.kind = StatementKinds.ARTIST_STATEMENT; // an ordinary kind may not use this path
        vm.expectRevert(IStatementLog.InvalidGovernanceManifest.selector);
        vm.prank(curator);
        direct.appendGovernanceManifest(s);

        // The statement itself is still validated like any other.
        s = _governanceStatement();
        s.uri = "";
        vm.expectRevert(IStatementLog.MissingLocator.selector);
        vm.prank(curator);
        direct.appendGovernanceManifest(s);

        // And the delay class belongs to the mapping: a zero-delay role holder writes at once, as
        // the manager, so the deploy configuration must map this selector to the 30-day class.
        s = _governanceStatement();
        vm.recordLogs();
        vm.prank(curator);
        direct.appendGovernanceManifest(s);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        StatementModel.Appended memory e = StatementModel.decode(logs[0]);
        assertEq(e.signer, address(manager), "recorded as the manager, not as the caller");
        assertEq(uint8(e.role), uint8(Role.PLATFORM));
    }

    /// @dev Every other path rejects the kind, whoever signs and whatever the subject.
    function test_GovernanceManifest_EveryOtherPathRejectsTheKind() public {
        resolver.grantEverywhere(artist);
        Statement memory onManager = _governanceStatement();
        Statement memory onToken = _governanceStatement();
        onToken.token = address(nft);
        onToken.id = 1;
        bytes32 kind = StatementKinds.GOVERNANCE_MANIFEST;

        Statement[2] memory subjects = [onManager, onToken];
        for (uint256 i; i < subjects.length; ++i) {
            Statement memory s = subjects[i];
            vm.expectRevert(
                abi.encodeWithSelector(IStatementLog.ReservedKind.selector, kind, Role.ARTIST)
            );
            _append(Role.ARTIST, artist, s);

            vm.expectRevert(
                abi.encodeWithSelector(IStatementLog.ReservedKind.selector, kind, Role.CURATOR)
            );
            vm.prank(curator);
            stmtLog.appendCurator(s);

            // PLATFORM is the role the governance path records, and still may not write it.
            vm.expectRevert(
                abi.encodeWithSelector(IStatementLog.ReservedKind.selector, kind, Role.PLATFORM)
            );
            vm.prank(platform);
            stmtLog.appendPlatform(s);
        }
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.ReservedKind.selector, kind, Role.OWNER)
        );
        _append(Role.OWNER, tokenOwner, onToken);

        // Relayed, under every role that can be relayed.
        uint64 deadline = uint64(block.timestamp + 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.ReservedKind.selector, kind, Role.ARTIST)
        );
        _relay(
            Role.ARTIST,
            onManager,
            artist,
            0,
            deadline,
            _sign(artistKey, Role.ARTIST, onManager, 0, deadline)
        );
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.ReservedKind.selector, kind, Role.OWNER)
        );
        _relay(
            Role.OWNER,
            onToken,
            tokenOwner,
            0,
            deadline,
            _sign(ownerKey, Role.OWNER, onToken, 0, deadline)
        );
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.ReservedKind.selector, kind, Role.CURATOR)
        );
        _relay(
            Role.CURATOR,
            onManager,
            curatorSigner,
            0,
            deadline,
            _sign(curatorKey, Role.CURATOR, onManager, 0, deadline)
        );

        (uint64 count,) = stmtLog.chainOf(address(manager), 0);
        assertEq(count, 0, "nothing reached the governance chain");
    }

    /// @dev The manager still may not sign anywhere else, the governance kind included.
    function test_GovernanceManifest_ManagerStillCannotSignOnOtherPaths() public {
        editions.setBalance(7, address(manager), 1);
        resolver.grantEverywhere(address(manager));
        Statement memory s = _governanceStatement();
        s.token = address(editions);
        s.id = 7;

        vm.expectRevert(IStatementLog.AuthorityCannotSign.selector);
        _append(Role.OWNER, address(manager), s);
        vm.expectRevert(IStatementLog.AuthorityCannotSign.selector);
        _append(Role.ARTIST, address(manager), s);

        // Through AccessManager.execute as well: the manager is the caller of the ordinary paths.
        bytes memory data = abi.encodeCall(StatementLog.append, (Role.OWNER, s));
        vm.expectRevert(IStatementLog.AuthorityCannotSign.selector);
        vm.prank(admin);
        manager.execute(address(stmtLog), data);

        // An ordinary kind through the governance path is not a way around it either.
        Statement memory ordinary = _statement(address(manager), 0);
        bytes memory viaGovernance =
            abi.encodeCall(StatementLog.appendGovernanceManifest, (ordinary));
        vm.prank(governor);
        manager.schedule(address(stmtLog), viaGovernance, 0);
        vm.warp(block.timestamp + GOVERNANCE_DELAY);
        vm.expectRevert(IStatementLog.InvalidGovernanceManifest.selector);
        vm.prank(governor);
        manager.execute(address(stmtLog), viaGovernance);
    }
}
