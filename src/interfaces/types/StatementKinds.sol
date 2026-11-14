// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StatementKinds
/// @notice Well-known statement kinds. A kind is only a `bytes32` label: the log accepts any
///         non-zero value, so new kinds need no deployment. Three kinds are reserved:
///         DISPUTE_OUTCOME only under the PLATFORM role, CURATION_EVIDENCE only under the CURATOR
///         role, and GOVERNANCE_MANIFEST only through the governance path. Every other kind may
///         be written under any role, so consumers must read a kind together with the entry's
///         signer role. The kinds from CONTENT_CHANGE_PROPOSAL on are conventions: the log
///         enforces none of their rules beyond its role checks, and readers apply the rules in
///         docs/spec/declarations-and-conventions.md (who may write each, and how to validate it).
/// @dev Constants only; nothing here is linked bytecode, and no contract reads the convention
///      kinds, so adding one changes no contract's executable code. It does change the CBOR
///      metadata hash appended to the bytecode of a contract that imports this file.
library StatementKinds {
    /// @notice A statement by the artist about a work.
    bytes32 internal constant ARTIST_STATEMENT = keccak256("ARTIST_STATEMENT");
    /// @notice An interview with or about the artist.
    bytes32 internal constant INTERVIEW = keccak256("INTERVIEW");
    /// @notice An exhibition record.
    bytes32 internal constant EXHIBITION = keccak256("EXHIBITION");
    /// @notice A conservation or condition note.
    bytes32 internal constant CONSERVATION_NOTE = keccak256("CONSERVATION_NOTE");
    /// @notice A record that a copy of the work's content exists at a location.
    bytes32 internal constant STORAGE_COPY = keccak256("STORAGE_COPY");
    /// @notice A fixity check of stored copies against the committed hash.
    bytes32 internal constant FIXITY_CHECK = keccak256("FIXITY_CHECK");
    /// @notice A museum accession record, including package hashes recorded at accession.
    bytes32 internal constant ACCESSION = keccak256("ACCESSION");
    /// @notice The recorded outcome of a dispute (ADR 0001 section 12). Reserved to PLATFORM; the
    ///         log keeps the latest one per subject for renderers.
    bytes32 internal constant DISPUTE_OUTCOME = keccak256("DISPUTE_OUTCOME");
    /// @notice The evidence hash behind a curation approval (ADR 0001 section 3). Reserved to
    ///         CURATOR.
    bytes32 internal constant CURATION_EVIDENCE = keccak256("CURATION_EVIDENCE");
    /// @notice The manifest hash of a governance configuration epoch (ADR 0002 section 6).
    ///         Written only by `StatementLog.appendGovernanceManifest`, which records the
    ///         AccessManager itself as the signer; no other path may write it.
    bytes32 internal constant GOVERNANCE_MANIFEST = keccak256("GOVERNANCE_MANIFEST");
    /// @notice Convention: the artist proposes new display content for a 1/1 work. Readers
    ///         count it only under the ARTIST role, about a 6529 Stream token. Display only: the
    ///         token's media and `tokenURI` never change.
    bytes32 internal constant CONTENT_CHANGE_PROPOSAL = keccak256("CONTENT_CHANGE_PROPOSAL");
    /// @notice Convention: the owner of a 1/1 work accepts a CONTENT_CHANGE_PROPOSAL by citing its
    ///         entry hash, or restores the approved content. Readers count it only under the
    ///         OWNER role, about a 6529 Stream token.
    bytes32 internal constant CONTENT_CHANGE_ACCEPTANCE = keccak256("CONTENT_CHANGE_ACCEPTANCE");
    /// @notice Convention: the artist's catalogue raisonne entry for a work. Readers count it
    ///         only under the ARTIST role.
    bytes32 internal constant CATALOGUE_ENTRY = keccak256("CATALOGUE_ENTRY");
    /// @notice Convention: the artist cites another work, on any chain, from a work. Readers count
    ///         it only under the ARTIST role.
    bytes32 internal constant CITATION = keccak256("CITATION");
    /// @notice Convention: a custodian's signed attestation about a work's physical twin, posted
    ///         by the owner, the artist or the platform. Readers verify the custodian's EIP-712
    ///         signature inside the document; the poster's role says only who published it.
    bytes32 internal constant CUSTODY_ATTESTATION = keccak256("CUSTODY_ATTESTATION");
}
