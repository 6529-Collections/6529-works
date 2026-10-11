# script

Deployment and verification scripts for the v1 contracts in `src/`. They will hold the deploy assembly with a
non-broadcastable rehearsal, AccessManager configuration readback against the
committed configuration JSON, and the deployed-bytecode verifier described in
the §17 reuse plan and §13 "Evidence trail" of
[ADR 0001](../../docs/adr/0055-v1-network-curated-stream-rescope.md).
