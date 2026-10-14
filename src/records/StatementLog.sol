// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { AuthorityUtils } from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";
import { Utf8 } from "../libraries/Utf8.sol";
import { isKnownHashAlgorithm } from "../interfaces/types/HashRef.sol";
import { IArtistRoleResolver } from "../interfaces/IArtistRoleResolver.sol";
import { IStatementLog, Role, Statement } from "../interfaces/IStatementLog.sol";
import { IStream } from "../interfaces/IStream.sol";
import { StatementKinds } from "../interfaces/types/StatementKinds.sol";

/// @title StatementLog
/// @notice The one append-only, signed statement log for works (ADR 0001 section 12).
/// @dev Per subject the contract stores a count and a rolling hash-chain head,
///      `head' = keccak256(abi.encode(HEAD_DOMAIN, head, entryHash))`, and emits each entry in
///      full. Nothing is ever edited or deleted: a correction is a new entry whose `supersedes`
///      cites the earlier entry's hash. That citation is not checked on-chain, because checking
///      would cost one more storage write per entry; readers verify it against the chain rebuilt
///      from events. The log does not link a work-ID subject to the token-ID subject it later
///      becomes: the Stream or the package registry holds that link.
///
///      Dispute outcomes. A DISPUTE_OUTCOME about a token must name one that exists when it is
///      recorded; an edition's outcome is recorded on its master, which the edition's metadata
///      shows. Other subjects
///      (an item before its mint, a work ID, an artist in the artist registry) are not checked.
///      {latestDisputeOutcome} answers for a work: the latest outcome about the token, or, while
///      it has none, the latest about the package item it was minted from (read from the token's
///      `IStream.coreOf`).
///
///      Authorization per role:
///      - ARTIST: the pluggable {IArtistRoleResolver} says the signer is an artist of the subject.
///      - OWNER: the signer owns the subject's ERC-721 token or holds a balance of its ERC-1155 ID.
///      - CURATOR and PLATFORM: the signer may call {appendCurator} or {appendPlatform} under the
///        AccessManager, so governance maps those two selectors to roles.
///
///      Trust boundary. No governance role has a direct path to an ARTIST or OWNER statement: those
///      roles never consult the AccessManager. But ARTIST authority is exactly as strong as the
///      resolver's code, whatever governs the resolver's answers, {setArtistResolver}, and the
///      AccessManager that can call it or replace this contract's authority. The code-hash pin
///      binds bytecode, not behaviour. So {setArtistResolver} must map to the 30-day class, and
///      every ARTIST entry records the resolver that vouched for it, in its hash and its event, so
///      a swap can never pass unnoticed. OWNER authority is only as strong as the token contract.
///      No statement is ever attributed to the AccessManager, with one exception: a governance
///      manifest (ADR 0002 section 6) written by {appendGovernanceManifest}, which records the
///      AccessManager as the signer of a statement about itself.
contract StatementLog is IStatementLog, AccessManaged, EIP712 {
    /// @notice The longest accepted URI, in bytes.
    uint256 public constant MAX_URI_BYTES = 2_048;

    /// @notice Gas forwarded to each token ownership read.
    uint256 public constant OWNER_READ_GAS = 50_000;

    bytes32 private constant HASHREF_TYPEHASH =
        keccak256("HashRef(uint16 algorithm,bytes32 digest)");
    bytes32 private constant STATEMENT_TYPEHASH = keccak256(
        "Statement(address token,uint256 id,bytes32 kind,bytes32 schema,HashRef content,string uri,bytes32 fileId,bytes32 supersedes)HashRef(uint16 algorithm,bytes32 digest)"
    );
    bytes32 private constant AUTHORIZATION_TYPEHASH = keccak256(
        "Authorization(uint8 role,address signer,uint256 nonce,uint64 deadline,Statement statement)HashRef(uint16 algorithm,bytes32 digest)Statement(address token,uint256 id,bytes32 kind,bytes32 schema,HashRef content,string uri,bytes32 fileId,bytes32 supersedes)"
    );
    bytes32 private constant ENTRY_DOMAIN = keccak256("6529.works.StatementLog.entry.v1");
    bytes32 private constant HEAD_DOMAIN = keccak256("6529.works.StatementLog.head.v1");

    struct Chain {
        uint64 count;
        bytes32 head;
    }

    /// @dev The values of one entry while it is built; keeps {_append} within the stack.
    struct Entry {
        bytes32 key;
        uint64 index;
        uint64 recordedAt;
        address resolver;
        bytes32 entryHash;
        bytes32 head;
    }

    /// @notice The contract answering "is this account an artist of this subject?".
    address public artistResolver;

    mapping(bytes32 subjectKey => Chain) private _chains;
    mapping(bytes32 subjectKey => bytes32 entryHash) private _latestDispute;
    mapping(address signer => mapping(uint256 word => uint256 bits)) private _nonceBitmap;

    /// @param authority_ The AccessManager that governs this log.
    /// @param resolver The initial artist resolver, or zero to leave ARTIST statements disabled.
    /// @param resolverCodeHash The reviewed code hash of `resolver` (ignored when it is zero).
    constructor(address authority_, address resolver, bytes32 resolverCodeHash)
        AccessManaged(authority_)
        EIP712("6529 Works Statement Log", "1")
    {
        _installResolver(resolver, resolverCodeHash);
    }

    /// @inheritdoc IStatementLog
    function append(Role role, Statement calldata statement) external returns (bytes32) {
        if (role != Role.ARTIST && role != Role.OWNER) revert InvalidRole(role);
        if (!_isAuthorized(role, statement, msg.sender)) revert NotAuthorized(role, msg.sender);
        return _append(role, msg.sender, statement);
    }

    /// @inheritdoc IStatementLog
    /// @dev TODO(governance lane): map this selector to the curator role from
    ///      `src/governance/Roles.sol`. Until mapped, the AccessManager default is ADMIN_ROLE.
    function appendCurator(Statement calldata statement) external restricted returns (bytes32) {
        return _append(Role.CURATOR, msg.sender, statement);
    }

    /// @inheritdoc IStatementLog
    /// @dev TODO(governance lane): map this selector to the platform role from
    ///      `src/governance/Roles.sol`. Until mapped, the AccessManager default is ADMIN_ROLE.
    function appendPlatform(Statement calldata statement) external restricted returns (bytes32) {
        return _append(Role.PLATFORM, msg.sender, statement);
    }

    /// @inheritdoc IStatementLog
    /// @dev The one path that records `signer = authority()` (with role PLATFORM) and the only one
    ///      that may write GOVERNANCE_MANIFEST. The subject is `(authority, 0)`, so a governance
    ///      chain lives under the manager's address. The deploy configuration must map this
    ///      selector to the 30-day class and schedule each call through the AccessManager with
    ///      the epoch's operations; the log cannot enforce the delay, which belongs to the
    ///      mapping, and a zero-delay mapping would let its role holder write at once.
    function appendGovernanceManifest(Statement calldata statement)
        external
        restricted
        returns (bytes32)
    {
        address manager = authority();
        if (
            statement.token != manager || statement.id != 0
                || statement.kind != StatementKinds.GOVERNANCE_MANIFEST
        ) revert InvalidGovernanceManifest();
        return _write(Role.PLATFORM, manager, statement);
    }

    /// @inheritdoc IStatementLog
    /// @dev The digest binds the role, signer, nonce, deadline and the full statement, under this
    ///      contract's address and the chain ID. A relayed CURATOR or PLATFORM statement needs the
    ///      signer to hold that role with no execution delay. ERC-1271 and EIP-7702 signers work
    ///      through {SignatureVerifier}.
    function appendSigned(
        Role role,
        Statement calldata statement,
        address signer,
        uint256 nonce,
        uint64 deadline,
        bytes calldata signature
    ) external returns (bytes32 entryHash) {
        // A deadline is a wall-clock bound by design; validator timestamp drift is immaterial.
        // forge-lint: disable-next-line(block-timestamp)
        if (deadline < block.timestamp) revert DeadlineExpired(deadline);
        _spendNonce(signer, nonce);
        bytes32 digest =
            _hashTypedDataV4(_authorizationHash(role, statement, signer, nonce, deadline));
        if (!SignatureVerifier.isValid(signer, digest, signature)) revert InvalidSignature(signer);
        if (!_isAuthorized(role, statement, signer)) revert NotAuthorized(role, signer);
        entryHash = _append(role, signer, statement);
        emit StatementRelayed(entryHash, signer, nonce);
    }

    /// @inheritdoc IStatementLog
    function revokeNonce(uint256 nonce) external {
        _spendNonce(msg.sender, nonce);
        emit NonceRevoked(msg.sender, nonce);
    }

    /// @notice Replaces the artist resolver (compare-and-set, code-hash pinned).
    /// @dev Governed. It decides who may speak as an artist, so the deploy configuration must
    ///      map it to the 30-day verifier class (ADR 0001 section 13) and no faster. Zero disables
    ///      ARTIST statements. Non-payable, as every governed function is.
    /// @param expected The resolver the proposer saw; a stale proposal reverts.
    /// @param next The new resolver, or zero.
    /// @param nextCodeHash The reviewed code hash `next` must have.
    function setArtistResolver(address expected, address next, bytes32 nextCodeHash)
        external
        restricted
    {
        if (artistResolver != expected) revert ResolverMismatch(artistResolver);
        _installResolver(next, nextCodeHash);
    }

    /// @inheritdoc IStatementLog
    function chainOf(address token, uint256 id) external view returns (uint64, bytes32) {
        Chain storage chain = _chains[subjectKey(token, id)];
        return (chain.count, chain.head);
    }

    /// @inheritdoc IStatementLog
    /// @dev The item fallback is one bounded read of `coreOf(id)` on `token`; any other answer
    ///      (not a Stream, a burned or unminted token) leaves the token's own result, zero.
    function latestDisputeOutcome(address token, uint256 id)
        external
        view
        returns (bytes32 entryHash)
    {
        entryHash = _latestDispute[subjectKey(token, id)];
        if (entryHash != 0 || token == address(0)) return entryHash;
        (bool ok, bytes memory core) = BoundedCall.tryRead(
            token, abi.encodeCall(IStream.coreOf, (id)), OWNER_READ_GAS, 192, 0
        );
        if (ok && core.length == 192) {
            bytes32 itemHash = abi.decode(core, (bytes32));
            entryHash = _latestDispute[subjectKey(address(0), uint256(itemHash))];
        }
    }

    /// @notice Returns the EIP-712 digest `signer` must sign for {appendSigned}.
    function authorizationDigest(
        Role role,
        Statement calldata statement,
        address signer,
        uint256 nonce,
        uint64 deadline
    ) external view returns (bytes32) {
        return _hashTypedDataV4(_authorizationHash(role, statement, signer, nonce, deadline));
    }

    /// @notice Returns whether `signer` has used or revoked `nonce`.
    function nonceUsed(address signer, uint256 nonce) external view returns (bool) {
        return _nonceBitmap[signer][nonce >> 8] & _bit(nonce) != 0;
    }

    /// @notice Returns the key that identifies a subject in events and storage.
    function subjectKey(address token, uint256 id) public pure returns (bytes32) {
        return keccak256(abi.encode(token, id));
    }

    /// @dev Every path except {appendGovernanceManifest}: the AccessManager may not sign, and the
    ///      governance kind is not writable.
    function _append(Role role, address signer, Statement calldata statement)
        private
        returns (bytes32)
    {
        if (signer == authority()) revert AuthorityCannotSign();
        if (statement.kind == StatementKinds.GOVERNANCE_MANIFEST) {
            revert ReservedKind(statement.kind, role);
        }
        return _write(role, signer, statement);
    }

    function _write(Role role, address signer, Statement calldata statement)
        private
        returns (bytes32)
    {
        _validate(statement, role);
        Entry memory e = Entry({
            key: subjectKey(statement.token, statement.id),
            index: 0,
            // forge-lint: disable-next-line(unsafe-typecast)
            recordedAt: uint64(block.timestamp),
            resolver: role == Role.ARTIST ? artistResolver : address(0),
            entryHash: 0,
            head: 0
        });
        if (statement.kind == StatementKinds.DISPUTE_OUTCOME) {
            _checkDisputeSubject(statement.token, statement.id);
        }
        Chain storage chain = _chains[e.key];
        e.index = chain.count;
        // Every word is static, so two encodings joined equal one `abi.encode` of all ten.
        e.entryHash = keccak256(
            bytes.concat(
                abi.encode(ENTRY_DOMAIN, block.chainid, address(this), e.key, e.index),
                abi.encode(role, signer, e.resolver, e.recordedAt, _statementHash(statement))
            )
        );
        e.head = keccak256(abi.encode(HEAD_DOMAIN, chain.head, e.entryHash));
        chain.count = e.index + 1;
        chain.head = e.head;
        if (statement.kind == StatementKinds.DISPUTE_OUTCOME) _latestDispute[e.key] = e.entryHash;
        emit StatementAppended(
            e.key,
            statement.kind,
            signer,
            role,
            e.resolver,
            e.index,
            e.recordedAt,
            e.entryHash,
            e.head,
            statement
        );
        return e.entryHash;
    }

    function _validate(Statement calldata s, Role role) private pure {
        if (s.token == address(0) && s.id == 0) revert InvalidSubject();
        if (s.kind == 0) revert InvalidKind();
        if (
            s.kind == StatementKinds.DISPUTE_OUTCOME && role != Role.PLATFORM
                || s.kind == StatementKinds.CURATION_EVIDENCE && role != Role.CURATOR
        ) revert ReservedKind(s.kind, role);
        if (s.schema == 0) revert InvalidSchema();
        if (s.content.digest == 0 || !isKnownHashAlgorithm(s.content.algorithm)) {
            revert InvalidHashRef(s.content.algorithm);
        }
        // Exactly one locator: a URI or a ContentStore file.
        bool hasUri = bytes(s.uri).length != 0;
        if (hasUri && s.fileId != 0) revert ConflictingLocators();
        if (!hasUri && s.fileId == 0) revert MissingLocator();
        if (hasUri && (bytes(s.uri).length > MAX_URI_BYTES || !Utf8.isValid(bytes(s.uri)))) {
            revert InvalidUri();
        }
    }

    /// @dev A DISPUTE_OUTCOME's token subject (see the contract notes): an ERC-721 (by ERC-165)
    ///      must own the ID now, and an ERC-1155 is refused. Each read is bounded.
    function _checkDisputeSubject(address token, uint256 id) private view {
        if (token == address(0)) return;
        bytes4[] memory kinds = new bytes4[](2);
        kinds[0] = type(IERC721).interfaceId;
        kinds[1] = type(IERC1155).interfaceId;
        bool[] memory supported = ERC165Checker.getSupportedInterfaces(token, kinds);
        if (!supported[0] && !supported[1]) return;
        if (!supported[1]) {
            (bool ok, bytes memory owner) = BoundedCall.tryRead(
                token, abi.encodeCall(IERC721.ownerOf, (id)), OWNER_READ_GAS, 32, 0
            );
            if (ok && owner.length == 32 && abi.decode(owner, (uint256)) != 0) return;
        }
        revert UnknownDisputeSubject(token, id);
    }

    function _isAuthorized(Role role, Statement calldata s, address who)
        private
        view
        returns (bool)
    {
        if (role == Role.ARTIST) {
            address resolver = artistResolver;
            return
                resolver != address(0) && IArtistRoleResolver(resolver).isArtist(s.token, s.id, who);
        }
        if (role == Role.OWNER) return _owns(s.token, s.id, who);
        if (role != Role.CURATOR && role != Role.PLATFORM) return false;
        bytes4 selector =
            role == Role.CURATOR ? this.appendCurator.selector : this.appendPlatform.selector;
        (bool immediate, uint32 delay) =
            AuthorityUtils.canCallWithDelay(authority(), who, address(this), selector);
        return immediate && delay == 0;
    }

    /// @dev Tries ERC-721 `ownerOf`, then ERC-1155 `balanceOf`, each gas-capped and size-capped so
    ///      a hostile token can neither burn the caller's gas nor return a bomb. Any failure is
    ///      "not the owner". Any holder of an edition counts as an owner of that token ID.
    function _owns(address token, uint256 id, address who) private view returns (bool) {
        if (token == address(0) || who == address(0)) return false;
        (bool ok, bytes memory result) = BoundedCall.tryRead(
            token, abi.encodeCall(IERC721.ownerOf, (id)), OWNER_READ_GAS, 32, 0
        );
        // Only a full 32-byte answer is an ERC-721 answer; anything else (a revert, an empty
        // fallback return) falls through to the ERC-1155 read.
        if (ok && result.length == 32) {
            return abi.decode(result, (uint256)) == uint256(uint160(who));
        }
        (ok, result) = BoundedCall.tryRead(
            token, abi.encodeCall(IERC1155.balanceOf, (who, id)), OWNER_READ_GAS, 32, 0
        );
        return ok && result.length == 32 && abi.decode(result, (uint256)) != 0;
    }

    function _spendNonce(address signer, uint256 nonce) private {
        uint256 bit = _bit(nonce);
        uint256 bits = _nonceBitmap[signer][nonce >> 8];
        if (bits & bit != 0) revert NonceAlreadyUsed(signer, nonce);
        _nonceBitmap[signer][nonce >> 8] = bits | bit;
    }

    function _bit(uint256 nonce) private pure returns (uint256) {
        return uint256(1) << (nonce & 0xff);
    }

    function _installResolver(address next, bytes32 codeHash) private {
        if (next != address(0)) {
            if (
                next.code.length == 0 || DelegatedEOA.isDelegated(next)
                    || !ERC165Checker.supportsInterface(next, type(IArtistRoleResolver).interfaceId)
            ) revert InvalidResolver(next);
            if (next.codehash != codeHash) {
                revert ResolverCodeHashMismatch(codeHash, next.codehash);
            }
        } else {
            codeHash = 0;
        }
        emit ArtistResolverSet(artistResolver, next, codeHash);
        artistResolver = next;
    }

    /// @dev EIP-712 `hashStruct(Statement)`; also the statement's identity inside the entry hash.
    function _statementHash(Statement calldata s) private pure returns (bytes32) {
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

    function _authorizationHash(
        Role role,
        Statement calldata s,
        address signer,
        uint256 nonce,
        uint64 deadline
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(AUTHORIZATION_TYPEHASH, role, signer, nonce, deadline, _statementHash(s))
        );
    }
}
