// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StatementKinds
/// @notice Well-known statement kinds. A kind is only a `bytes32` label: the log accepts any
///         non-zero value, so new kinds need no deployment. Two kinds are reserved:
///         DISPUTE_OUTCOME only under the PLATFORM role and CURATION_EVIDENCE only under the
///         CURATOR role. Every other kind may be written under any role, so consumers must read
///         a kind together with the entry's signer role.
/// @dev Constants only; nothing here is linked bytecode.
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
}
