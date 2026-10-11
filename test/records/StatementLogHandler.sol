// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { StatementKinds } from "src/records/StatementKinds.sol";
import { HashRef, HASH_SHA256 } from "src/records/HashRef.sol";
import { Role, Statement } from "src/records/IStatementLog.sol";
import { StatementModel } from "./StatementModel.sol";

/// @notice The accounts and subjects the handler works with. The artist resolver already accepts
///         `artist` for every subject; `tokenOwner` owns `nft` 1 and 2 and holds `editions` 7.
struct Actors {
    address nft;
    address editions;
    address artist;
    address tokenOwner;
    address curator;
    address platform;
    address admin;
    address stranger;
    uint256 artistKey;
    uint256 ownerKey;
    uint256 curatorKey;
}

/// @notice Drives the statement log with random valid appends (direct, relayed, curator, platform),
///         nonce revocations, replays and unauthorised attempts. After every call it rebuilds the
///         chain from the emitted events with {StatementModel} and keeps ghost copies of every
///         subject's count and head for the invariants to compare with contract storage.
contract StatementLogHandler is Test {
    struct Authorization {
        Role role;
        Statement statement;
        address signer;
        uint256 nonce;
        uint64 deadline;
        bytes signature;
    }

    StatementLog internal immutable book;
    Actors internal a;
    address internal immutable curatorSigner;

    bytes32[] public keys;
    mapping(bytes32 => bool) internal known;
    mapping(bytes32 => address) public subjectToken;
    mapping(bytes32 => uint256) public subjectId;
    mapping(bytes32 => uint64) public ghostCount;
    mapping(bytes32 => bytes32) public ghostHead;
    mapping(bytes32 => bytes32) internal lastEntry;

    Authorization[] internal authorizations;
    uint256 internal nextNonce;
    /// @notice Nonces spent by revocation, per signer.
    address[] public revokedBy;
    uint256[] public revokedNonce;

    uint256 public totalEvents;
    /// @notice Malformed events, gaps, hash mismatches, replays or unauthorised appends that worked.
    uint256 public violations;
    /// @notice Events whose signer does not fit the role it claims.
    uint256 public roleViolations;
    uint256 public relayedAppends;
    uint256 public refusedAttempts;

    constructor(StatementLog book_, Actors memory actors) {
        book = book_;
        a = actors;
        curatorSigner = vm.addr(actors.curatorKey);
    }

    // ------------------------------------------------------------------ actions

    function appendArtist(uint256 seed) external {
        _begin(seed);
        Statement memory s = _statement(seed, 4);
        vm.prank(a.artist);
        book.append(Role.ARTIST, s);
        _expectOne();
    }

    function appendOwner(uint256 seed) external {
        _begin(seed);
        Statement memory s = _statement(seed, 3); // tokens only: a work ID has no owner
        vm.prank(a.tokenOwner);
        book.append(Role.OWNER, s);
        _expectOne();
    }

    function appendCurator(uint256 seed) external {
        _begin(seed);
        Statement memory s = _statement(seed, 4);
        vm.prank(a.curator);
        book.appendCurator(s);
        _expectOne();
    }

    function appendPlatform(uint256 seed) external {
        _begin(seed);
        Statement memory s = _statement(seed, 4);
        vm.prank(a.platform);
        book.appendPlatform(s);
        _expectOne();
    }

    function appendRelayed(uint256 seed) external {
        _begin(seed);
        uint256 pick = (seed >> 3) % 3;
        Role role = pick == 0 ? Role.ARTIST : pick == 1 ? Role.OWNER : Role.CURATOR;
        uint256 key = pick == 0 ? a.artistKey : pick == 1 ? a.ownerKey : a.curatorKey;
        Statement memory s = _statement(seed, role == Role.OWNER ? 3 : 4);
        Authorization memory auth = Authorization({
            role: role,
            statement: s,
            signer: vm.addr(key),
            nonce: nextNonce++,
            deadline: type(uint64).max, // never expires, so a replay always reaches the nonce check
            signature: ""
        });
        bytes32 digest = StatementModel.digest(
            block.chainid, address(book), role, s, auth.signer, auth.nonce, auth.deadline
        );
        (uint8 v, bytes32 r, bytes32 sv) = vm.sign(key, digest);
        auth.signature = abi.encodePacked(r, sv, v);
        authorizations.push(auth);

        vm.prank(a.stranger);
        book.appendSigned(role, s, auth.signer, auth.nonce, auth.deadline, auth.signature);
        ++relayedAppends;
        _expectOne();
    }

    /// @dev Spends a fresh nonce by revocation; a later relay of it must fail.
    function revokeNonce(uint256 seed) external {
        _begin(seed);
        address signer = seed % 2 == 0 ? a.artist : a.tokenOwner;
        uint256 nonce = nextNonce++;
        vm.prank(signer);
        book.revokeNonce(nonce);
        revokedBy.push(signer);
        revokedNonce.push(nonce);
        _record();
    }

    /// @dev Resubmits an already used signed authorization; it must never succeed again.
    function replay(uint256 seed) external {
        if (authorizations.length == 0) return;
        _begin(seed);
        Authorization memory auth = authorizations[seed % authorizations.length];
        vm.prank(a.stranger);
        try book.appendSigned(
            auth.role, auth.statement, auth.signer, auth.nonce, auth.deadline, auth.signature
        ) {
            ++violations;
        } catch {
            ++refusedAttempts;
        }
        _record();
    }

    /// @dev Everyone who is not the subject's artist or owner tries to speak as one.
    function unauthorized(uint256 seed) external {
        _begin(seed);
        address[6] memory actors =
            [a.stranger, a.admin, a.curator, a.platform, curatorSigner, address(book)];
        address actor = actors[(seed >> 5) % actors.length];
        Role role = (seed >> 9) % 2 == 0 ? Role.ARTIST : Role.OWNER;
        Statement memory s = _statement(seed, role == Role.OWNER ? 3 : 4);
        vm.prank(actor);
        try book.append(role, s) {
            ++violations;
        } catch {
            ++refusedAttempts;
        }
        // The artist is not an owner, and the owner is not an artist.
        vm.prank(role == Role.OWNER ? a.artist : a.tokenOwner);
        try book.append(role, s) {
            ++violations;
        } catch {
            ++refusedAttempts;
        }
        _record();
    }

    // ---------------------------------------------------------------- bookkeeping

    function keysLength() external view returns (uint256) {
        return keys.length;
    }

    function authorizationsLength() external view returns (uint256) {
        return authorizations.length;
    }

    function authorizationAt(uint256 i) external view returns (address signer, uint256 nonce) {
        return (authorizations[i].signer, authorizations[i].nonce);
    }

    function revokedLength() external view returns (uint256) {
        return revokedNonce.length;
    }

    function _begin(uint256 seed) internal {
        vm.recordLogs();
        vm.warp(block.timestamp + ((seed >> 128) % 2 days));
    }

    /// @dev The subjects: (nft,1), (nft,2), (editions,7), (no token, work 5). `count` limits how
    ///      many are eligible.
    function _statement(uint256 seed, uint256 count) internal view returns (Statement memory s) {
        uint256 pick = (seed >> 16) % count;
        address token = a.nft;
        uint256 id = pick + 1;
        if (pick == 2) (token, id) = (a.editions, 7);
        if (pick == 3) (token, id) = (address(0), 5);
        s.token = token;
        s.id = id;
        s.kind = bytes32(uint256(keccak256(abi.encode(seed, "kind"))) | 1);
        s.schema = bytes32(uint256(keccak256(abi.encode(seed, "schema"))) | 1);
        s.content =
            HashRef(HASH_SHA256, bytes32(uint256(keccak256(abi.encode(seed, "digest"))) | 1));
        uint256 uriLength = (seed >> 24) % 48;
        bytes memory uri = new bytes(uriLength);
        for (uint256 i; i < uriLength; ++i) {
            uri[i] = "u";
        }
        s.uri = string(uri);
        if (uriLength == 0 && (seed >> 32) % 2 == 0) {
            s.fileId = keccak256(abi.encode(seed, "file"));
        }
        if ((seed >> 40) % 2 == 0) s.supersedes = lastEntry[StatementModel.subjectKey(token, id)];
    }

    function _expectOne() internal {
        if (_record() != 1) ++violations;
    }

    /// @dev Rebuilds each emitted entry's hash and chain head from the event alone, and checks them
    ///      against the previous ghost state.
    function _record() internal returns (uint256 appended) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (!StatementModel.isAppended(logs[i], address(book))) continue;
            StatementModel.Appended memory e = StatementModel.decode(logs[i]);
            ++appended;
            ++totalEvents;
            bytes32 key = e.subjectKey;
            if (!known[key]) {
                known[key] = true;
                keys.push(key);
                subjectToken[key] = e.statement.token;
                subjectId[key] = e.statement.id;
            }
            bytes32 entry = StatementModel.entryHash(
                address(book), block.chainid, e.index, e.role, e.signer, e.recordedAt, e.statement
            );
            bool ok = e.index == ghostCount[key] && entry == e.entryHash
                && key == StatementModel.subjectKey(e.statement.token, e.statement.id)
                && e.kind == e.statement.kind && e.recordedAt == block.timestamp;
            ghostHead[key] = StatementModel.fold(ghostHead[key], entry);
            ok = ok && ghostHead[key] == e.head;
            if (!ok) ++violations;
            ++ghostCount[key];
            lastEntry[key] = entry;
            if (!_signerFitsRole(e.role, e.signer)) ++roleViolations;
        }
    }

    function _signerFitsRole(Role role, address signer) internal view returns (bool) {
        if (role == Role.ARTIST) return signer == a.artist;
        if (role == Role.OWNER) return signer == a.tokenOwner;
        if (role == Role.CURATOR) return signer == a.curator || signer == curatorSigner;
        if (role == Role.PLATFORM) return signer == a.platform;
        return false;
    }
}
