// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { Role, Statement } from "src/interfaces/IStatementLog.sol";

/// @notice An independent restatement of the log's wire formats, written from the spec in
///         `src/records/README.md` and sharing no code or constants with `StatementLog`. Tests
///         use it to rebuild entry hashes, chain heads and EIP-712 digests from event data.
library StatementModel {
    bytes32 internal constant ENTRY_DOMAIN = keccak256("6529.works.StatementLog.entry.v1");
    bytes32 internal constant HEAD_DOMAIN = keccak256("6529.works.StatementLog.head.v1");

    /// @dev A decoded `StatementAppended` event.
    struct Appended {
        bytes32 subjectKey;
        bytes32 kind;
        address signer;
        Role role;
        address resolver;
        uint64 index;
        uint64 recordedAt;
        bytes32 entryHash;
        bytes32 head;
        Statement statement;
    }

    function subjectKey(address token, uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(token, id));
    }

    function statementHash(Statement memory s) internal pure returns (bytes32) {
        bytes32 content = keccak256(
            abi.encode(
                keccak256("HashRef(uint16 algorithm,bytes32 digest)"),
                s.content.algorithm,
                s.content.digest
            )
        );
        return keccak256(
            abi.encode(
                keccak256(
                    "Statement(address token,uint256 id,bytes32 kind,bytes32 schema,HashRef content,string uri,bytes32 fileId,bytes32 supersedes)HashRef(uint16 algorithm,bytes32 digest)"
                ),
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

    function entryHash(
        address log,
        uint256 chainId,
        uint64 index,
        Role role,
        address signer,
        address resolver,
        uint64 recordedAt,
        Statement memory s
    ) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(ENTRY_DOMAIN, chainId, log, subjectKey(s.token, s.id), index),
                abi.encode(role, signer, resolver, recordedAt, statementHash(s))
            )
        );
    }

    function fold(bytes32 head, bytes32 entry) internal pure returns (bytes32) {
        return keccak256(abi.encode(HEAD_DOMAIN, head, entry));
    }

    /// @dev The EIP-712 digest for `appendSigned`, under an explicit domain.
    function digest(
        uint256 chainId,
        address log,
        Role role,
        Statement memory s,
        address signer,
        uint256 nonce,
        uint64 deadline
    ) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("6529 Works Statement Log"),
                keccak256("1"),
                chainId,
                log
            )
        );
        bytes32 authorization = keccak256(
            abi.encode(
                keccak256(
                    "Authorization(uint8 role,address signer,uint256 nonce,uint64 deadline,Statement statement)HashRef(uint16 algorithm,bytes32 digest)Statement(address token,uint256 id,bytes32 kind,bytes32 schema,HashRef content,string uri,bytes32 fileId,bytes32 supersedes)"
                ),
                role,
                signer,
                nonce,
                deadline,
                statementHash(s)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, authorization));
    }

    /// @dev Decodes a recorded log as a `StatementAppended` event.
    function decode(Vm.Log memory entry) internal pure returns (Appended memory a) {
        a.subjectKey = entry.topics[1];
        a.kind = entry.topics[2];
        a.signer = address(uint160(uint256(entry.topics[3])));
        (a.role, a.resolver, a.index, a.recordedAt, a.entryHash, a.head, a.statement) =
            abi.decode(entry.data, (Role, address, uint64, uint64, bytes32, bytes32, Statement));
    }

    /// @dev Whether `entry` is a `StatementAppended` event emitted by `log`.
    function isAppended(Vm.Log memory entry, address log) internal pure returns (bool) {
        return entry.emitter == log
            && entry.topics[0]
                == keccak256(
                "StatementAppended(bytes32,bytes32,address,uint8,address,uint64,uint64,bytes32,bytes32,(address,uint256,bytes32,bytes32,(uint16,bytes32),string,bytes32,bytes32))"
            );
    }

    /// @dev Whether `entry` is a `StatementRelayed` event emitted by `log`.
    function isRelayed(Vm.Log memory entry, address log) internal pure returns (bool) {
        return entry.emitter == log
            && entry.topics[0] == keccak256("StatementRelayed(bytes32,address,uint256)");
    }
}
