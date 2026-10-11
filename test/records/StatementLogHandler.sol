// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { StatementKinds } from "src/records/StatementKinds.sol";
import { HashRef, HASH_SHA256 } from "src/records/HashRef.sol";
import { Role, Statement } from "src/records/IStatementLog.sol";
import { StatementModel } from "./StatementModel.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { ArtistResolverMock } from "../mocks/RecordsMocks.sol";
import { ERC1271WalletMock } from "../mocks/AdversarialTargets.sol";

/// @notice The accounts and subjects the handler works with. `resolver` is the log's initial
///         artist resolver and already accepts `artist` for every subject; `tokenOwner` owns `nft`
///         1 and 2 and holds `editions` 7.
struct Actors {
    address nft;
    address editions;
    address resolver;
    address artist;
    address tokenOwner;
    address curator;
    address platform;
    address admin;
    address manager;
    address governor;
    address stranger;
    uint256 artistKey;
    uint256 ownerKey;
    uint256 curatorKey;
}

/// @notice Drives the statement log with random valid appends (direct, relayed by EOA and by an
///         ERC-1271 wallet, curator, platform), resolver swaps, nonce revocations, replays, and
///         unauthorised, tampered, expired and reserved-kind attempts. After every call it rebuilds
///         the chain from the emitted events with {StatementModel} and keeps ghost copies of every
///         subject's count, head and latest dispute outcome for the invariants to compare with
///         contract storage.
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
    address internal immutable wallet;
    address internal immutable resolverB;
    address public currentResolver;

    bytes32[] public keys;
    mapping(bytes32 => bool) internal known;
    mapping(bytes32 => address) public subjectToken;
    mapping(bytes32 => uint256) public subjectId;
    mapping(bytes32 => uint64) public ghostCount;
    mapping(bytes32 => bytes32) public ghostHead;
    mapping(bytes32 => bytes32) public ghostDispute;
    mapping(bytes32 => bytes32) internal lastEntry;

    Authorization[] internal authorizations;
    uint256 internal nonceCounter;
    address[] public revokedBy;
    uint256[] public revokedNonce;

    /// @dev Scratch from the latest `_record`, to check relayed-nonce events.
    uint256 internal relayedSeen;
    bytes32 internal lastAppended;
    bytes32 internal relayedEntry;
    address internal relayedSigner;
    uint256 internal relayedNonce;

    uint256 public totalEvents;
    /// @notice Malformed events, gaps, hash mismatches, replays or unauthorised, tampered, expired
    ///         or reserved-kind appends that worked.
    uint256 public violations;
    /// @notice Events whose signer does not fit the role it claims, or whose kind is reserved to
    ///         another role.
    uint256 public roleViolations;
    /// @notice ARTIST events that do not carry the resolver that was active, or other roles that
    ///         carry one.
    uint256 public resolverViolations;
    /// @notice Relayed entries without exactly one matching nonce event, or direct ones with one.
    uint256 public relayViolations;
    uint256 public relayedAppends;
    uint256 public refusedAttempts;
    uint256 public resolverSwaps;

    constructor(StatementLog book_, Actors memory actors) {
        book = book_;
        a = actors;
        curatorSigner = vm.addr(actors.curatorKey);
        address wallet_ = address(new ERC1271WalletMock(vm.addr(actors.artistKey)));
        ArtistResolverMock other = new ArtistResolverMock();
        // Both resolvers vouch for the artist and the artist's contract wallet, everywhere.
        other.grantEverywhere(actors.artist);
        other.grantEverywhere(wallet_);
        ArtistResolverMock(actors.resolver).grantEverywhere(wallet_);
        wallet = wallet_;
        resolverB = address(other);
        currentResolver = actors.resolver;
    }

    // ------------------------------------------------------------------ actions

    function appendArtist(uint256 seed) external {
        _begin(seed);
        Statement memory s = _statement(seed, 4);
        vm.prank(a.artist);
        book.append(Role.ARTIST, s);
        _expectDirect();
    }

    function appendOwner(uint256 seed) external {
        _begin(seed);
        Statement memory s = _statement(seed, 3); // tokens only: a work ID has no owner
        vm.prank(a.tokenOwner);
        book.append(Role.OWNER, s);
        _expectDirect();
    }

    function appendCurator(uint256 seed) external {
        _begin(seed);
        Statement memory s = _statement(seed, 4);
        if ((seed >> 60) % 4 == 0) s.kind = StatementKinds.CURATION_EVIDENCE;
        vm.prank(a.curator);
        book.appendCurator(s);
        _expectDirect();
    }

    function appendPlatform(uint256 seed) external {
        _begin(seed);
        Statement memory s = _statement(seed, 4);
        if ((seed >> 60) % 4 == 0) s.kind = StatementKinds.DISPUTE_OUTCOME;
        vm.prank(a.platform);
        book.appendPlatform(s);
        _expectDirect();
    }

    /// @dev A valid relayed entry, signed by the artist, the owner or the curator key.
    function appendRelayed(uint256 seed) external {
        _begin(seed);
        Authorization memory auth = _validAuthorization(seed);
        _submit(auth);
    }

    /// @dev A valid relayed ARTIST entry whose signer is an ERC-1271 contract wallet.
    function appendRelayedByWallet(uint256 seed) external {
        _begin(seed);
        Statement memory s = _statement(seed, 4);
        Authorization memory auth =
            _sign(Role.ARTIST, s, a.artistKey, wallet, type(uint64).max, _freshNonce());
        _submit(auth);
    }

    /// @dev Governance swaps the artist resolver; ARTIST entries from now on must carry the new one.
    function swapResolver(uint256 seed) external {
        _begin(seed);
        address next = currentResolver == a.resolver ? resolverB : a.resolver;
        vm.prank(a.admin);
        book.setArtistResolver(currentResolver, next, next.codehash);
        currentResolver = next;
        ++resolverSwaps;
        _record();
    }

    /// @dev Spends a fresh nonce by revocation; a later relay of it must fail.
    function revokeNonce(uint256 seed) external {
        _begin(seed);
        address signer = seed % 2 == 0 ? a.artist : a.tokenOwner;
        uint256 nonce = _freshNonce();
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
        _mustFail(auth.role, auth.statement, auth.signer, auth.nonce, auth.deadline, auth.signature);
        _record();
    }

    /// @dev Changes one signed field (or the role or the nonce) of a valid authorization; the
    ///      relay must fail and must not spend the real nonce.
    function tamperedRelay(uint256 seed) external {
        _begin(seed);
        Authorization memory auth = _validAuthorization(seed);
        Role role = auth.role;
        Statement memory s = auth.statement;
        uint256 nonce = auth.nonce;
        uint64 deadline = auth.deadline;
        uint256 how = (seed >> 70) % 5;
        if (how == 0) s.uri = string.concat(s.uri, "x");
        if (how == 1) nonce += 1;
        if (how == 2) deadline -= 1;
        if (how == 3) role = role == Role.ARTIST ? Role.OWNER : Role.ARTIST;
        if (how == 4) s.supersedes = bytes32(uint256(s.supersedes) + 1);
        _mustFail(role, s, auth.signer, nonce, deadline, auth.signature);
        if (book.nonceUsed(auth.signer, auth.nonce)) ++violations; // a failed relay spends nothing
        _record();
    }

    /// @dev A correctly signed authorization whose deadline has already passed.
    function expiredRelay(uint256 seed) external {
        _begin(seed);
        Statement memory s = _statement(seed, 4);
        Authorization memory auth = _sign(
            Role.ARTIST, s, a.artistKey, a.artist, uint64(block.timestamp - 1), _freshNonce()
        );
        _mustFail(auth.role, s, auth.signer, auth.nonce, auth.deadline, auth.signature);
        if (book.nonceUsed(auth.signer, auth.nonce)) ++violations;
        _record();
    }

    /// @dev Everyone who is not the subject's artist or owner tries to speak as one.
    function unauthorized(uint256 seed) external {
        _begin(seed);
        // The manager passes the ARTIST and OWNER role checks (see the invariant setUp), so only
        // the rule against attributing statements to it can stop it.
        address[7] memory actors =
            [a.stranger, a.admin, a.curator, a.platform, curatorSigner, address(book), a.manager];
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

    /// @dev The reserved kinds under a role that does not own them.
    function reservedKindMisuse(uint256 seed) external {
        _begin(seed);
        Statement memory dispute = _statement(seed, 3);
        dispute.kind = StatementKinds.DISPUTE_OUTCOME;
        Statement memory evidence = _statement(seed, 3);
        evidence.kind = StatementKinds.CURATION_EVIDENCE;

        vm.prank(a.artist);
        try book.append(Role.ARTIST, dispute) {
            ++violations;
        } catch {
            ++refusedAttempts;
        }
        vm.prank(a.tokenOwner);
        try book.append(Role.OWNER, evidence) {
            ++violations;
        } catch {
            ++refusedAttempts;
        }
        vm.prank(a.curator);
        try book.appendCurator(dispute) {
            ++violations;
        } catch {
            ++refusedAttempts;
        }
        vm.prank(a.platform);
        try book.appendPlatform(evidence) {
            ++violations;
        } catch {
            ++refusedAttempts;
        }
        _record();
    }

    /// @dev A governance manifest through the real flow: the governor (30-day delay) schedules it
    ///      on the AccessManager and, once the delay has passed, either the manager executes it or
    ///      the governor calls the log, which consumes the scheduled operation. Either way it is
    ///      recorded with the manager as signer and role PLATFORM, under the subject
    ///      `(manager, 0)`.
    function appendGovernanceManifest(uint256 seed) external {
        _begin(seed);
        Statement memory s = _manifest(seed);
        bytes memory data = abi.encodeCall(StatementLog.appendGovernanceManifest, (s));
        vm.prank(a.governor);
        AccessManager(a.manager).schedule(address(book), data, 0);
        vm.warp(block.timestamp + 30 days);
        vm.prank(a.governor);
        if ((seed >> 20) % 2 == 0) {
            AccessManager(a.manager).execute(address(book), data); // the manager is the caller
        } else {
            book.appendGovernanceManifest(s); // the governor calls, consuming the scheduled operation
        }
        _expectDirect();
    }

    /// @dev The governance kind and the manager's signature, from everywhere they must not work.
    function governanceMisuse(uint256 seed) external {
        _begin(seed);
        Statement memory manifest = _manifest(seed);
        Statement memory onToken = _statement(seed, 3);
        onToken.kind = StatementKinds.GOVERNANCE_MANIFEST;

        // Direct calls to the governance path without a scheduled operation, by anyone.
        address[4] memory callers = [a.stranger, a.curator, a.platform, a.governor];
        vm.prank(callers[(seed >> 5) % callers.length]);
        try book.appendGovernanceManifest(manifest) {
            ++violations;
        } catch {
            ++refusedAttempts;
        }
        // Every other path refuses the kind.
        vm.prank(a.artist);
        try book.append(Role.ARTIST, manifest) {
            ++violations;
        } catch {
            ++refusedAttempts;
        }
        vm.prank(a.tokenOwner);
        try book.append(Role.OWNER, onToken) {
            ++violations;
        } catch {
            ++refusedAttempts;
        }
        vm.prank(a.curator);
        try book.appendCurator(manifest) {
            ++violations;
        } catch {
            ++refusedAttempts;
        }
        vm.prank(a.platform);
        try book.appendPlatform(manifest) {
            ++violations;
        } catch {
            ++refusedAttempts;
        }
        Authorization memory auth =
            _sign(Role.ARTIST, manifest, a.artistKey, a.artist, type(uint64).max, _freshNonce());
        _mustFail(auth.role, manifest, auth.signer, auth.nonce, auth.deadline, auth.signature);
        // The manager, which passes the OWNER check on edition 7, may not sign anywhere else.
        Statement memory edition = _statement(seed, 3);
        edition.token = a.editions;
        edition.id = 7;
        vm.prank(a.manager);
        try book.append(Role.OWNER, edition) {
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

    /// @dev Spread across bitmap words: half are hashes, half are multiples of 37 (so they walk
    ///      through the low words and cross word boundaries). Every nonce is distinct.
    function _freshNonce() internal returns (uint256) {
        uint256 c = nonceCounter++;
        return c % 2 == 0 ? uint256(keccak256(abi.encode("nonce", c))) : c * 37;
    }

    function _validAuthorization(uint256 seed) internal returns (Authorization memory) {
        uint256 pick = (seed >> 3) % 3;
        Role role = pick == 0 ? Role.ARTIST : pick == 1 ? Role.OWNER : Role.CURATOR;
        uint256 key = pick == 0 ? a.artistKey : pick == 1 ? a.ownerKey : a.curatorKey;
        Statement memory s = _statement(seed, role == Role.OWNER ? 3 : 4);
        if (role == Role.CURATOR && (seed >> 60) % 4 == 0) {
            s.kind = StatementKinds.CURATION_EVIDENCE;
        }
        return _sign(role, s, key, vm.addr(key), type(uint64).max, _freshNonce());
    }

    function _sign(
        Role role,
        Statement memory s,
        uint256 key,
        address signer,
        uint64 deadline,
        uint256 nonce
    ) internal view returns (Authorization memory auth) {
        auth = Authorization(role, s, signer, nonce, deadline, "");
        bytes32 digest =
            StatementModel.digest(block.chainid, address(book), role, s, signer, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 sv) = vm.sign(key, digest);
        auth.signature = abi.encodePacked(r, sv, v);
    }

    /// @dev Relays `auth` from a stranger and checks the relayed-nonce event.
    function _submit(Authorization memory auth) internal {
        authorizations.push(auth);
        vm.prank(a.stranger);
        book.appendSigned(
            auth.role, auth.statement, auth.signer, auth.nonce, auth.deadline, auth.signature
        );
        ++relayedAppends;
        _expectRelayed(auth);
    }

    function _mustFail(
        Role role,
        Statement memory s,
        address signer,
        uint256 nonce,
        uint64 deadline,
        bytes memory signature
    ) internal {
        vm.prank(a.stranger);
        try book.appendSigned(role, s, signer, nonce, deadline, signature) {
            ++violations;
        } catch {
            ++refusedAttempts;
        }
    }

    /// @dev The subjects: (nft,1), (nft,2), (editions,7), (no token, work 5). `count` limits how
    ///      many are eligible. Exactly one locator is set: a URI or a file ID.
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
        if ((seed >> 32) % 3 == 0) {
            s.fileId = keccak256(abi.encode(seed, "file"));
        } else {
            uint256 uriLength = 1 + (seed >> 24) % 47;
            bytes memory uri = new bytes(uriLength);
            for (uint256 i; i < uriLength; ++i) {
                uri[i] = "u";
            }
            s.uri = string(uri);
        }
        if ((seed >> 40) % 2 == 0) s.supersedes = lastEntry[StatementModel.subjectKey(token, id)];
    }

    /// @dev A valid governance manifest: subject `(manager, 0)`, exactly one locator.
    function _manifest(uint256 seed) internal view returns (Statement memory s) {
        s = _statement(seed, 3);
        s.token = a.manager;
        s.id = 0;
        s.kind = StatementKinds.GOVERNANCE_MANIFEST;
        s.supersedes =
            (seed >> 40) % 2 == 0 ? lastEntry[StatementModel.subjectKey(a.manager, 0)] : bytes32(0);
    }

    function _expectDirect() internal {
        if (_record() != 1) ++violations;
        if (relayedSeen != 0) ++relayViolations; // a direct entry spends no nonce
    }

    function _expectRelayed(Authorization memory auth) internal {
        if (_record() != 1) ++violations;
        bool ok = relayedSeen == 1 && relayedEntry == lastAppended && relayedNonce == auth.nonce
            && relayedSigner == auth.signer;
        if (!ok) ++relayViolations;
    }

    /// @dev Rebuilds each emitted entry's hash and chain head from the event alone, and checks them
    ///      against the previous ghost state.
    function _record() internal returns (uint256 appended) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        relayedSeen = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (StatementModel.isRelayed(logs[i], address(book))) {
                ++relayedSeen;
                relayedEntry = logs[i].topics[1];
                relayedSigner = address(uint160(uint256(logs[i].topics[2])));
                relayedNonce = abi.decode(logs[i].data, (uint256));
                continue;
            }
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
                address(book),
                block.chainid,
                e.index,
                e.role,
                e.signer,
                e.resolver,
                e.recordedAt,
                e.statement
            );
            bool ok = e.index == ghostCount[key] && entry == e.entryHash
                && key == StatementModel.subjectKey(e.statement.token, e.statement.id)
                && e.kind == e.statement.kind && e.recordedAt == block.timestamp;
            ghostHead[key] = StatementModel.fold(ghostHead[key], entry);
            ok = ok && ghostHead[key] == e.head;
            if (!ok) ++violations;
            ++ghostCount[key];
            lastEntry[key] = entry;
            lastAppended = entry;
            if (e.statement.kind == StatementKinds.DISPUTE_OUTCOME) ghostDispute[key] = entry;
            if (e.statement.kind == StatementKinds.GOVERNANCE_MANIFEST) {
                // Only the governance path writes this kind: the manager, as PLATFORM, about itself.
                bool fits = e.signer == a.manager && e.role == Role.PLATFORM
                    && e.statement.token == a.manager && e.statement.id == 0;
                if (!fits) ++roleViolations;
            } else if (!_signerFitsRole(e.role, e.signer) || _reservedElsewhere(e)) {
                ++roleViolations; // the manager fits no role here, so it may sign nothing else
            }
            address expected = e.role == Role.ARTIST ? currentResolver : address(0);
            if (e.resolver != expected) ++resolverViolations;
        }
    }

    function _signerFitsRole(Role role, address signer) internal view returns (bool) {
        if (role == Role.ARTIST) return signer == a.artist || signer == wallet;
        if (role == Role.OWNER) return signer == a.tokenOwner;
        if (role == Role.CURATOR) return signer == a.curator || signer == curatorSigner;
        if (role == Role.PLATFORM) return signer == a.platform;
        return false;
    }

    function _reservedElsewhere(StatementModel.Appended memory e) internal pure returns (bool) {
        bytes32 kind = e.statement.kind;
        return (kind == StatementKinds.DISPUTE_OUTCOME && e.role != Role.PLATFORM)
            || (kind == StatementKinds.CURATION_EVIDENCE && e.role != Role.CURATOR);
    }
}
