// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

/// @title Typehashes
/// @notice The EIP-712 domain names and typehashes of the package registry, the curation
///         verifier and the accounts module (the artist registry). Those three contracts use
///         every constant here; golden tests in `test/interfaces/` pin the values (ADR 0001
///         section 17 "golden typehash tests"). The RECORDS module, the statement log and the
///         split ledger keep their own domain names and typehashes beside their code
///         (`WorkRules.NAME` and its `*_TYPEHASH` constants, `StatementLog`,
///         `SplitLedger.RELEASE_TYPEHASH`), pinned by their own golden tests. An Independent
///         Stream listing is an `ACCOUNT_CONSENT` to
///         `IIndependentStreamRegistry.listingSubject`; it has no typehash of its own.
/// @dev Each signing contract uses the EIP-712 domain `(name, DOMAIN_VERSION, chainid, itself)`.
///      Every artist or party signature here binds a deadline (a move and an account's own
///      identity change also a single-use nonce), except `ACCOUNT_CONSENT`: a consent binds
///      only the contract and what it consents to (for an Independent Stream item, the item
///      hash, used once), and has no deadline. A curation approval (`PACKAGE_APPROVAL`) binds
///      no deadline either: it binds the signer's epoch. Constants only; nothing here is linked
///      bytecode.
library Typehashes {
    /// @notice The EIP-712 domain version of every v1 contract.
    string internal constant DOMAIN_VERSION = "1";
    /// @notice Domain name of the package registry.
    string internal constant PACKAGE_REGISTRY_NAME = "6529 Stream Package Registry";
    /// @notice Domain name of the v1 curation verifier.
    string internal constant CURATION_VERIFIER_NAME = "6529 Stream Curation Verifier";
    /// @notice Domain name of the artist registry.
    string internal constant ARTIST_REGISTRY_NAME = "6529 Stream Artist Registry";

    /// @notice The lead artist moves an approved item to Stream (package registry domain).
    bytes32 internal constant MOVE_TO_STREAM = keccak256(
        "MoveToStream(bytes32 packageRoot,bytes32 itemHash,uint256 nonce,uint64 deadline)"
    );
    /// @notice A party accepts a package root (package registry domain).
    bytes32 internal constant PACKAGE_ACCEPTANCE = keccak256(
        "PackageAcceptance(bytes32 packageRoot,address account,bytes32 profileId,"
        "bytes32 profileDocHash,uint64 deadline)"
    );
    /// @notice A curation signer approves a package root at its epoch (curation verifier
    ///         domain).
    bytes32 internal constant PACKAGE_APPROVAL = keccak256(
        "PackageApproval(bytes32 packageRoot,bytes32 evidenceHash,uint256 signerEpoch)"
    );
    /// @notice An account's own identity change, signed by any wallet of the account (artist
    ///         registry domain).
    bytes32 internal constant IDENTITY_CHANGE = keccak256(
        "IdentityChange(uint256 artistId,address root,address payout,bytes32 profileId,"
        "bytes32 profileDocHash,uint256 nonce,uint64 deadline)"
    );
    /// @notice The new root accepts a network replacement (artist registry domain). It binds no
    ///         change nonce; the registry consumes it once by digest.
    bytes32 internal constant REPLACEMENT_ACCEPTANCE = keccak256(
        "ReplacementAcceptance(uint256 artistId,address root,address payout,bytes32 profileId,"
        "bytes32 profileDocHash,bytes32 evidenceHash,uint64 deadline)"
    );
    /// @notice An account consents to `what`, for the contract `subject` only (artist registry
    ///         domain, `IAccounts.consentDigest`). No deadline and no nonce: the consent holds
    ///         until it is used, or its signing wallet leaves the account.
    bytes32 internal constant ACCOUNT_CONSENT = keccak256("Consent(address subject,bytes32 what)");
    /// @notice An account consents to an identity the Independent Stream registry creates for it
    ///         (artist registry domain, `registerIndependent`).
    bytes32 internal constant ARTIST_REGISTRATION = keccak256(
        "ArtistRegistration(address account,bytes32 profileId,bytes32 profileDocHash,uint64 deadline)"
    );
}
