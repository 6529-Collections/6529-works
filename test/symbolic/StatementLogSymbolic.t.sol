// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { IStatementLog, Role, Statement } from "src/interfaces/IStatementLog.sol";
import { HashRef } from "src/interfaces/types/HashRef.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { ArtistResolverMock, ERC721OwnerMock } from "../mocks/records/RecordsMocks.sol";
import { SymHelpers } from "./LedgerSymbolic.t.sol";

/// @dev An ERC-1271 account that accepts exactly the one digest it was told to.
contract SymDigestSigner {
    bytes32 public accepted;

    function accept(bytes32 digest) external {
        accepted = digest;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return digest == accepted ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @notice Halmos proofs of the statement log's write rules on the real `StatementLog` behind a
///         real OpenZeppelin `AccessManager` (docs/testing/README.md, "Symbolic").
/// @dev Subjects are token 1 of an ERC-721 owner mock; the artist resolver is the records mock.
///      The URI is a fixed short string: its UTF-8 and length checks are proved for every input
///      in `TextSymbolicTest` and are not what these proofs are about.
contract StatementLogSymbolicTest is SymHelpers {
    uint64 internal constant CURATOR_ROLE = 1;
    uint64 internal constant PLATFORM_ROLE = 2;
    uint64 internal constant GOVERNANCE_ROLE = 3;
    bytes32 internal constant ENTRY_DOMAIN = keccak256("6529.stream.StatementLog.entry.v1");
    bytes32 internal constant HEAD_DOMAIN = keccak256("6529.stream.StatementLog.head.v1");

    address internal constant ADMIN = address(0xAD);
    address internal constant ARTIST = address(0xA471);
    address internal constant OWNER = address(0x0412);
    address internal constant CURATOR = address(0xC0C0);
    address internal constant PLATFORM = address(0x9147);
    address internal constant GOVERNOR = address(0x6060);

    AccessManager internal manager;
    StatementLog internal slog;
    ArtistResolverMock internal resolver;
    ERC721OwnerMock internal nft;

    function setUp() public {
        manager = new AccessManager(ADMIN);
        resolver = new ArtistResolverMock();
        slog = new StatementLog(address(manager), address(resolver), address(resolver).codehash);
        nft = new ERC721OwnerMock();
        vm.startPrank(ADMIN);
        _map(slog.appendCurator.selector, CURATOR_ROLE);
        _map(slog.appendPlatform.selector, PLATFORM_ROLE);
        _map(slog.appendGovernanceManifest.selector, GOVERNANCE_ROLE);
        manager.grantRole(CURATOR_ROLE, CURATOR, 0);
        manager.grantRole(PLATFORM_ROLE, PLATFORM, 0);
        // Zero delay so the manifest path is reachable in one call; the integrator's delay
        // lives in the manager, not in the slog.
        manager.grantRole(GOVERNANCE_ROLE, GOVERNOR, 0);
        vm.stopPrank();
        nft.setOwner(1, OWNER);
        resolver.grant(address(nft), 1, ARTIST);
    }

    // ---------------------------------------------------------------------------------------
    // Who writes: DSP-3, DSP-4, DSP-5
    // ---------------------------------------------------------------------------------------

    /// @notice DSP-3: `append` serves only ARTIST and OWNER, and each only for its holder; every
    ///         other role value is refused; CURATOR and PLATFORM write only through their
    ///         restricted functions, by their role holders. A refused call adds no entry.
    /// @dev Bounds: any caller; any role byte (0 to 255) for `append`; the four write paths.
    function check_append_servesOnlyArtistAndOwner(address caller, uint8 role, uint8 path) public {
        Statement memory s = _statement(StatementKinds.ARTIST_STATEMENT);
        bytes memory data;
        if (path == 0) data = abi.encodeWithSelector(slog.append.selector, uint256(role), s);
        else if (path == 1) data = abi.encodeCall(slog.appendCurator, (s));
        else data = abi.encodeCall(slog.appendPlatform, (s));

        (bool ok,) = _call(caller, address(slog), data);
        (uint64 count,) = slog.chainOf(address(nft), 1);
        assert(count == _toUint(ok));
        if (path == 0) {
            bool artist = _and(role == uint8(Role.ARTIST), caller == ARTIST);
            bool owner = _and(role == uint8(Role.OWNER), caller == OWNER);
            assert(ok == _or(artist, owner));
        } else if (path == 1) {
            assert(ok == (caller == CURATOR));
        } else {
            assert(ok == (caller == PLATFORM));
        }
    }

    /// @notice DSP-4: `DISPUTE_OUTCOME` is written only as PLATFORM, `CURATION_EVIDENCE` only as
    ///         CURATOR, and `GOVERNANCE_MANIFEST` only through `appendGovernanceManifest`, on
    ///         every write path, each by the holder entitled to that path.
    /// @dev Bounds: the five write paths, each by its own holder; the three reserved kinds and
    ///      one ordinary kind; the manifest path with its required subject.
    function check_outcomeKinds_onlyFromTheirRole(uint8 path, uint8 kindIndex) public {
        vm.assume(path <= 4 && kindIndex <= 3);
        bytes32 kind = kindIndex == 0
            ? StatementKinds.DISPUTE_OUTCOME
            : kindIndex == 1
                ? StatementKinds.CURATION_EVIDENCE
                : kindIndex == 2 ? StatementKinds.GOVERNANCE_MANIFEST : StatementKinds.EXHIBITION;
        Statement memory s = _statement(kind);
        address caller;
        bytes memory data;
        if (path == 0) {
            (caller, data) = (ARTIST, abi.encodeCall(slog.append, (Role.ARTIST, s)));
        } else if (path == 1) {
            (caller, data) = (OWNER, abi.encodeCall(slog.append, (Role.OWNER, s)));
        } else if (path == 2) {
            (caller, data) = (CURATOR, abi.encodeCall(slog.appendCurator, (s)));
        } else if (path == 3) {
            (caller, data) = (PLATFORM, abi.encodeCall(slog.appendPlatform, (s)));
        } else {
            s.token = address(manager);
            s.id = 0;
            (caller, data) = (GOVERNOR, abi.encodeCall(slog.appendGovernanceManifest, (s)));
        }
        (bool ok,) = _call(caller, address(slog), data);
        bool dispute = kind == StatementKinds.DISPUTE_OUTCOME;
        bool curation = kind == StatementKinds.CURATION_EVIDENCE;
        bool manifest = kind == StatementKinds.GOVERNANCE_MANIFEST;
        if (ok) {
            assert(_or(!dispute, path == 3));
            assert(_or(!curation, path == 2));
            assert(manifest == (path == 4));
        } else {
            // Every holder's own path takes an ordinary kind.
            assert(_or(_or(dispute, curation), _or(manifest, path == 4)));
        }
    }

    /// @notice DSP-5: no path records the AccessManager as the signer: `append` and the relay
    ///         refuse it, and an `appendPlatform` or `appendCurator` the manager executes for a
    ///         role holder reverts, so the only entry the manager signs is a governance manifest.
    /// @dev Bounds: every role byte for `append` and the relay; the manager's `execute` of the
    ///      two restricted appends for their zero-delay holders.
    function check_noEntryNamesTheManager(uint8 path, uint8 role) public {
        Statement memory s = _statement(StatementKinds.EXHIBITION);
        // Even a resolver and an owner that name the manager do not let it sign.
        resolver.grant(address(nft), 1, address(manager));
        nft.setOwner(1, address(manager));
        bool ok;
        if (path == 0) {
            (ok,) = _call(
                address(manager),
                address(slog),
                abi.encodeWithSelector(slog.append.selector, uint256(role), s)
            );
        } else if (path == 1) {
            (ok,) = _call(
                CURATOR,
                address(manager),
                abi.encodeCall(
                    manager.execute, (address(slog), abi.encodeCall(slog.appendCurator, (s)))
                )
            );
        } else if (path == 2) {
            (ok,) = _call(
                PLATFORM,
                address(manager),
                abi.encodeCall(
                    manager.execute, (address(slog), abi.encodeCall(slog.appendPlatform, (s)))
                )
            );
        } else {
            (ok,) = _call(
                PLATFORM,
                address(slog),
                abi.encodeWithSelector(
                    slog.appendSigned.selector,
                    uint256(role),
                    s,
                    address(manager),
                    uint256(0),
                    type(uint64).max,
                    hex"00"
                )
            );
        }
        assert(!ok);
        (uint64 count,) = slog.chainOf(address(nft), 1);
        assert(count == 0);
    }

    // ---------------------------------------------------------------------------------------
    // Relay: DSP-9
    // ---------------------------------------------------------------------------------------

    /// @notice DSP-9: a relayed entry succeeds exactly when the deadline has not passed
    ///         (inclusive), the nonce is unused, the signature covers every field the relayer
    ///         submits, and the signer holds the role; it spends the nonce once, and a failed
    ///         relay spends none.
    /// @dev Bounds: the signer is an ERC-1271 artist account that accepts one authorization's
    ///      digest; the relayer may change the role, nonce, deadline, kind, schema and content
    ///      digest to any value; any block time; the nonce revoked first or not.
    function check_relay_deadlineNonceAndSigner(
        Auth memory signed,
        Auth memory relayed,
        uint32 time,
        bool revoked
    ) public {
        vm.assume(signed.role <= uint8(Role.PLATFORM) && relayed.role <= uint8(Role.PLATFORM));
        SymDigestSigner signer = new SymDigestSigner();
        resolver.grant(address(nft), 1, address(signer));
        signer.accept(
            slog.authorizationDigest(
                Role(signed.role),
                _authStatement(signed),
                address(signer),
                signed.nonce,
                signed.deadline
            )
        );
        if (revoked) {
            vm.prank(address(signer));
            slog.revokeNonce(relayed.nonce);
        }
        vm.warp(time);

        bytes memory data = abi.encodeCall(
            slog.appendSigned,
            (
                Role(relayed.role),
                _authStatement(relayed),
                address(signer),
                relayed.nonce,
                relayed.deadline,
                hex"00"
            )
        );
        (bool ok,) = _call(PLATFORM, address(slog), data);

        bool same = _and(
            _and(relayed.role == signed.role, relayed.nonce == signed.nonce),
            _and(
                relayed.deadline == signed.deadline,
                _and(relayed.schema == signed.schema, relayed.digest == signed.digest)
            )
        );
        bool valid = _and(relayed.schema != 0, relayed.digest != 0);
        bool expected = _and(
            _and(same, valid),
            _and(_and(time <= relayed.deadline, !revoked), relayed.role == uint8(Role.ARTIST))
        );
        assert(ok == expected);
        assert(slog.nonceUsed(address(signer), relayed.nonce) == _or(ok, revoked));
        if (ok) {
            (bool again, bytes4 err) = _call(PLATFORM, address(slog), data);
            assert(!again && err == IStatementLog.NonceAlreadyUsed.selector);
        }
    }

    /// @dev The fields of a relayed authorization the relay proof varies.
    struct Auth {
        uint8 role;
        uint256 nonce;
        uint64 deadline;
        bytes32 schema;
        bytes32 digest;
    }

    function _authStatement(Auth memory a) internal view returns (Statement memory s) {
        s = _statement(StatementKinds.EXHIBITION);
        s.schema = a.schema;
        s.content.digest = a.digest;
    }

    // ---------------------------------------------------------------------------------------
    // The chain: DSP-1, DSP-10
    // ---------------------------------------------------------------------------------------

    /// @notice DSP-1, DSP-10: two appends to a subject leave count 2 and the head the formula
    ///         of the specification gives, folded from zero over the two entry hashes, each
    ///         computed here from the formula alone; another subject's chain is untouched.
    /// @dev Bounds: any kind (not reserved), schema, content and file ID for each entry; the
    ///      artist then the owner; any timestamps.
    function check_head_followsTheFormula(
        bytes32 kind1,
        bytes32 schema1,
        HashRef memory content1,
        bytes32 fileId1,
        bytes32 kind2,
        bytes32 schema2,
        HashRef memory content2,
        uint32 t1,
        uint32 t2
    ) public {
        Statement memory a = _statement(kind1);
        a.schema = schema1;
        a.content = content1;
        a.fileId = fileId1;
        a.uri = "";
        Statement memory b = _statement(kind2);
        b.schema = schema2;
        b.content = content2;
        vm.warp(t1);
        vm.prank(ARTIST);
        bytes32 e1 = slog.append(Role.ARTIST, a);
        vm.warp(t2);
        vm.prank(OWNER);
        bytes32 e2 = slog.append(Role.OWNER, b);

        bytes32 key = keccak256(abi.encode(address(nft), uint256(1)));
        assert(e1 == _entryHash(key, 0, Role.ARTIST, ARTIST, address(resolver), t1, a));
        assert(e2 == _entryHash(key, 1, Role.OWNER, OWNER, address(0), t2, b));
        bytes32 head =
            keccak256(abi.encode(HEAD_DOMAIN, keccak256(abi.encode(HEAD_DOMAIN, 0, e1)), e2));
        (uint64 count, bytes32 stored) = slog.chainOf(address(nft), 1);
        assert(count == 2 && stored == head);
        (uint64 otherCount, bytes32 otherHead) = slog.chainOf(address(nft), 2);
        assert(otherCount == 0 && otherHead == 0);
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    function _map(bytes4 selector, uint64 roleId) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(address(slog), selectors, roleId);
    }

    function _statement(bytes32 kind) internal view returns (Statement memory) {
        return Statement({
            token: address(nft),
            id: 1,
            kind: kind,
            schema: keccak256("schema/v1"),
            content: HashRef(2, keccak256("the document")),
            uri: "ar://document",
            fileId: bytes32(0),
            supersedes: bytes32(0)
        });
    }

    /// @dev The specification's entry hash (docs/spec/disputes-and-statements.md).
    function _entryHash(
        bytes32 key,
        uint64 index,
        Role role,
        address signer,
        address resolverAtWrite,
        uint64 recordedAt,
        Statement memory s
    ) internal view returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(ENTRY_DOMAIN, block.chainid, address(slog), key, index),
                abi.encode(role, signer, resolverAtWrite, recordedAt, _statementHash(s))
            )
        );
    }

    function _statementHash(Statement memory s) internal pure returns (bytes32) {
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
}
