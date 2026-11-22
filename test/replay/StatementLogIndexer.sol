// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { IStatementLog, Role, Statement } from "src/interfaces/IStatementLog.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { ReplayIndexer } from "./ReplayIndexer.sol";

/// @notice Rebuilds the statement log from its own logs alone: every subject's chain (count and
///         head), its latest dispute outcome and that entry's index, every spent or revoked
///         signed-append nonce, the artist resolver and the AccessManager. Each entry hash is
///         recomputed from the logged statement and the entry's fields (the published formula:
///         `keccak256(abi.encode(ENTRY_DOMAIN, chainid, log, subjectKey, index, role, signer,
///         resolver, recordedAt, statementHash))`), and each head from the one before, so a log
///         that was altered or dropped breaks the chain here.
contract StatementLogIndexer is ReplayIndexer {
    bytes32 internal constant ENTRY_DOMAIN = keccak256("6529.works.StatementLog.entry.v1");
    bytes32 internal constant HEAD_DOMAIN = keccak256("6529.works.StatementLog.head.v1");
    bytes32 internal constant HASHREF_TYPEHASH =
        keccak256("HashRef(uint16 algorithm,bytes32 digest)");
    bytes32 internal constant STATEMENT_TYPEHASH = keccak256(
        "Statement(address token,uint256 id,bytes32 kind,bytes32 schema,HashRef content,string uri,bytes32 fileId,bytes32 supersedes)HashRef(uint16 algorithm,bytes32 digest)"
    );
    uint256 private constant PROBED_NONCES = 32;

    struct SubjectChain {
        uint64 count;
        bytes32 head;
        uint64 disputeIndex;
        bytes32 latestDispute;
    }

    struct Subject {
        address token;
        uint256 id;
    }

    address public artistResolver;
    address public authority;
    mapping(bytes32 key => SubjectChain) internal _chains;
    Subject[] internal _subjects;
    mapping(address signer => mapping(uint256 nonce => bool)) internal _used;
    address[] internal _nonceSigners;
    uint256[] internal _nonces;
    address[] internal _probes;

    constructor(address log_) ReplayIndexer(log_) { }

    /// @notice Also compare `signer`'s first nonces, logged or not.
    function probe(address signer) external {
        _probes.push(signer);
    }

    function _apply(Vm.Log memory l) internal override {
        bytes32 sig = l.topics[0];
        if (sig == IStatementLog.StatementAppended.selector) {
            _appended(l);
        } else if (sig == IStatementLog.StatementRelayed.selector) {
            (uint256 nonce) = abi.decode(l.data, (uint256));
            _spend(_addr(l.topics[2]), nonce);
        } else if (sig == IStatementLog.NonceRevoked.selector) {
            _spend(_addr(l.topics[1]), uint256(l.topics[2]));
        } else if (sig == IStatementLog.ArtistResolverSet.selector) {
            assertEq(_addr(l.topics[1]), artistResolver, "indexer: resolver history");
            artistResolver = _addr(l.topics[2]);
        } else if (sig == IAccessManaged.AuthorityUpdated.selector) {
            authority = abi.decode(l.data, (address));
        } else {
            _unknown(sig);
        }
    }

    /// @dev The static head of a `StatementAppended` log's data (it encodes as these six words).
    struct Entry {
        Role role;
        address resolver;
        uint64 index;
        uint64 recordedAt;
        bytes32 entryHash;
        bytes32 head;
    }

    function _appended(Vm.Log memory l) private {
        (Entry memory e, Statement memory s) = abi.decode(l.data, (Entry, Statement));
        bytes32 key = keccak256(abi.encode(s.token, s.id));
        assertEq(l.topics[1], key, "indexer: subject key");
        assertEq(l.topics[2], s.kind, "indexer: kind topic");
        SubjectChain storage c = _chains[key];
        if (c.count == 0) _subjects.push(Subject(s.token, s.id));
        assertEq(e.index, c.count, "indexer: entry index");
        assertEq(e.entryHash, _entryHash(key, e, _addr(l.topics[3]), s), "indexer: entry hash");
        assertEq(e.head, keccak256(abi.encode(HEAD_DOMAIN, c.head, e.entryHash)), "indexer: head");
        c.count = e.index + 1;
        c.head = e.head;
        if (s.kind == StatementKinds.DISPUTE_OUTCOME) {
            c.disputeIndex = e.index;
            c.latestDispute = e.entryHash;
        }
    }

    function _entryHash(bytes32 key, Entry memory e, address signer, Statement memory s)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            bytes.concat(
                abi.encode(ENTRY_DOMAIN, block.chainid, target, key, e.index),
                abi.encode(e.role, signer, e.resolver, e.recordedAt, _statementHash(s))
            )
        );
    }

    function _statementHash(Statement memory s) private pure returns (bytes32) {
        bytes32 content =
            keccak256(abi.encode(HASHREF_TYPEHASH, s.content.algorithm, s.content.digest));
        return keccak256(
            abi.encode(
                STATEMENT_TYPEHASH,
                s.token,
                s.id,
                s.kind,
                s.schema,
                content,
                keccak256(bytes(s.uri)),
                s.fileId,
                s.supersedes
            )
        );
    }

    function _spend(address signer, uint256 nonce) private {
        assertFalse(_used[signer][nonce], "indexer: nonce spent twice");
        _used[signer][nonce] = true;
        _nonceSigners.push(signer);
        _nonces.push(nonce);
    }

    function subjectCount() external view returns (uint256) {
        return _subjects.length;
    }

    function assertMatches() external view override {
        StatementLog s = StatementLog(target);
        assertEq(s.artistResolver(), artistResolver, "artistResolver");
        assertEq(s.authority(), authority, "authority");
        for (uint256 i; i < _subjects.length; ++i) {
            Subject memory sub = _subjects[i];
            SubjectChain storage c = _chains[keccak256(abi.encode(sub.token, sub.id))];
            (uint64 count, bytes32 head) = s.chainOf(sub.token, sub.id);
            assertEq(count, c.count, "chainOf count");
            assertEq(head, c.head, "chainOf head");
            (bytes32 dispute, uint64 disputeIndex) = s.disputeOutcomeOf(sub.token, sub.id);
            assertEq(dispute, c.latestDispute, "disputeOutcomeOf entry");
            assertEq(disputeIndex, c.disputeIndex, "disputeOutcomeOf index");
            if (sub.token == address(0)) {
                assertEq(s.latestDisputeOutcome(sub.token, sub.id), c.latestDispute, "latest");
            }
        }
        for (uint256 i; i < _nonces.length; ++i) {
            address signer = _nonceSigners[i];
            assertTrue(s.nonceUsed(signer, _nonces[i]), "nonceUsed");
            uint256 next = _nonces[i] ^ 1;
            assertEq(s.nonceUsed(signer, next), _used[signer][next], "nonceUsed (neighbour)");
        }
        for (uint256 i; i < _probes.length; ++i) {
            for (uint256 n; n < PROBED_NONCES; ++n) {
                assertEq(s.nonceUsed(_probes[i], n), _used[_probes[i]][n], "nonceUsed (probed)");
            }
        }
    }
}
