# script

Deployment and verification scripts for the v1 contracts in `src/`. They will hold the deploy assembly with a
non-broadcastable rehearsal, AccessManager configuration readback against the
committed configuration JSON, and the deployed-bytecode verifier described in
the [§17 reuse plan](../docs/adr/0001-v1-scope.md#17-reuse-plan-from-rc1-and-pr-744)
and [§13 "Evidence trail"](../docs/adr/0001-v1-scope.md#13-governance) of
[ADR 0001](../docs/adr/0001-v1-scope.md).
