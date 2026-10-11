// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { HashRef } from "./HashRef.sol";

/// @notice Who a statement speaks as. `NONE` is the zero value so an unset role can never pass.
enum Role {
    NONE,
    ARTIST,
    OWNER,
    CURATOR,
    PLATFORM
}

/// @notice The content of one statement about a subject.
/// @dev The subject is `(token, id)`: a token contract and token ID, or, when `token` is
///      `address(0)`, a work ID that has no token yet. The content is `content` (a hash of the
///      document) located by at most one of `uri` or `fileId` (a `ContentStore` file ID);
///      both empty is a bare hash commitment. `supersedes` is the entry hash of an earlier
///      entry this one corrects or replaces, or zero.
struct Statement {
    address token;
    uint256 id;
    bytes32 kind;
    bytes32 schema;
    HashRef content;
    string uri;
    bytes32 fileId;
    bytes32 supersedes;
}

/// @title IStatementLog
/// @notice The append-only, signed statement log (ADR 0001 section 12). Storage holds only a
///         count and a rolling hash-chain head per subject; every entry is emitted in full.
interface IStatementLog {
    /// @notice A statement was appended to a subject's chain. The event carries everything
    ///         needed to recompute `entryHash` and the new `head`, so an indexer can rebuild a
    ///         subject's history and prove it complete against {chainOf}.
    /// @param subjectKey `keccak256(abi.encode(token, id))` of the subject.
    /// @param kind The statement kind (also inside `statement`, indexed for filtering).
    /// @param signer The account that spoke, whether it called directly or by relay.
    /// @param role The role `signer` spoke as.
    /// @param index The zero-based position of this entry in the subject's chain.
    /// @param recordedAt The block timestamp of the append.
    /// @param entryHash The hash identifying this entry; later entries cite it in `supersedes`.
    /// @param head The subject's chain head after this entry.
    /// @param statement The full statement as signed.
    event StatementAppended(
        bytes32 indexed subjectKey,
        bytes32 indexed kind,
        address indexed signer,
        Role role,
        uint64 index,
        uint64 recordedAt,
        bytes32 entryHash,
        bytes32 head,
        Statement statement
    );

    /// @notice `signer` revoked an unused relay nonce.
    event NonceRevoked(address indexed signer, uint256 indexed nonce);

    /// @notice The artist-role resolver changed (zero disables ARTIST statements).
    /// @param previous The resolver before the change.
    /// @param next The resolver after the change.
    /// @param codeHash The reviewed code hash the new resolver was pinned to.
    event ArtistResolverSet(address indexed previous, address indexed next, bytes32 codeHash);

    /// @notice The role is not valid for this entry point.
    error InvalidRole(Role role);
    /// @notice The subject is `(address(0), 0)`.
    error InvalidSubject();
    /// @notice The kind is zero.
    error InvalidKind();
    /// @notice The schema hash is zero.
    error InvalidSchema();
    /// @notice The content hash is zero or uses an unrecognised algorithm.
    error InvalidHashRef(uint16 algorithm);
    /// @notice Both a URI and a `ContentStore` file ID were given.
    error ConflictingLocators();
    /// @notice The URI is longer than the limit or is not well-formed UTF-8.
    error InvalidUri();
    /// @notice `signer` does not hold `role` for this subject.
    error NotAuthorized(Role role, address signer);
    /// @notice The relay deadline has passed.
    error DeadlineExpired(uint64 deadline);
    /// @notice The relay nonce was already used or revoked.
    error NonceAlreadyUsed(address signer, uint256 nonce);
    /// @notice The signature does not verify for `signer` over this authorization.
    error InvalidSignature(address signer);
    /// @notice The expected current resolver did not match.
    error ResolverMismatch(address current);
    /// @notice The proposed resolver has no code, is a delegated account, or lacks ERC-165 support
    ///         for {IArtistRoleResolver}.
    error InvalidResolver(address resolver);
    /// @notice The proposed resolver's code hash is not the reviewed one.
    error ResolverCodeHashMismatch(bytes32 expected, bytes32 actual);

    /// @notice Appends a statement as the caller, speaking as ARTIST or OWNER.
    /// @dev CURATOR and PLATFORM statements use {appendCurator} and {appendPlatform}.
    /// @return entryHash The new entry's hash.
    function append(Role role, Statement calldata statement) external returns (bytes32 entryHash);

    /// @notice Appends a statement as the caller, who must hold the curator role.
    /// @return entryHash The new entry's hash.
    function appendCurator(Statement calldata statement) external returns (bytes32 entryHash);

    /// @notice Appends a statement as the caller, who must hold the platform role.
    /// @return entryHash The new entry's hash.
    function appendPlatform(Statement calldata statement) external returns (bytes32 entryHash);

    /// @notice Appends a statement that `signer` authorised by an EIP-712 signature; anyone may
    ///         submit it.
    /// @return entryHash The new entry's hash.
    function appendSigned(
        Role role,
        Statement calldata statement,
        address signer,
        uint256 nonce,
        uint64 deadline,
        bytes calldata signature
    ) external returns (bytes32 entryHash);

    /// @notice Revokes one of the caller's relay nonces before it is used.
    function revokeNonce(uint256 nonce) external;

    /// @notice Returns how many entries a subject has and its current chain head.
    function chainOf(address token, uint256 id) external view returns (uint64 count, bytes32 head);
}
