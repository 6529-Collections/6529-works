# records

The single append-only, signed statement log. Each entry records the work, the
statement kind, the schema hash, a content hash plus URI or a `ContentStore`
file, and the signer's role (artist, owner, curator or platform). It carries
dispute outcomes, curation evidence hashes, fixity statements, artist
statements and museum accession records, and exposes the events and reads the
museum repository needs to rebuild a package from chain data alone. Governed
by [ADR 0001](../../docs/adr/0055-v1-network-curated-stream-rescope.md) §12
("Statement log"), with §3 (evidence hashes) and §15 (museum source data).
