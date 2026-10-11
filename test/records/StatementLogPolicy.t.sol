// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { StatementKinds } from "src/records/StatementKinds.sol";
import { IStatementLog, Role, Statement } from "src/records/IStatementLog.sol";
import { StatementLogFixture } from "./StatementLogFixture.sol";
import { StatementModel } from "./StatementModel.sol";
import { ArtistResolverMock, ERC1155BalanceMock } from "../mocks/RecordsMocks.sol";
import { EvilResolverMock, ForwardingResolverMock } from "../mocks/RecordsResolvers.sol";

/// @notice The policy the review asked for: the ARTIST trust boundary and resolver binding, no
///         attribution to the AccessManager, reserved kinds, the dispute pointer, the relayed-nonce
///         event and the nonce bitmap boundaries.
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
}
