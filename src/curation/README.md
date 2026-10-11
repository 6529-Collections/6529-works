# curation

The package registry and the `ICurationVerifier` boundary. A package is a
Merkle root over canonical-JSON (RFC 8785) items committing to content and
metadata hashes, artist and collaborators, split, collection, kind and edition
terms; every listed party signs the root, each item mints at most once, and the
artist's revocable "move to Stream" signature makes a work startable. The v1
verifier checks an EIP-712 attestation from the curation signer and is
replaceable by a 6529-chain verifier through a timelocked action. Governed by
[ADR 0001 §3](../../docs/adr/0001-v1-scope.md#3-curation-and-approved-packages), with
the per-product content-hash uniqueness rule in §3 "Exclusivity".
