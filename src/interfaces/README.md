# interfaces

The contract surfaces every implementation lane builds against, and the shared
types they exchange. `IMintTarget` is the only thing a shared sale adapter knows
about a token; `IStream` and `IEditions` extend it. `types/` holds the package
item, work record, sale, economics and identity structs, the `Limits` that keep
every transaction under the EIP-7825 gas cap, and `WorksHashing`, the one
definition of item hashes, package Merkle leaves, work-record hashes and split
IDs (golden vectors in `test/interfaces/`). Governed functions name the
`Roles` role their selector is meant to map to. How the contracts fit together,
the main call flows and the trust boundaries are in
[docs/architecture.md](../../docs/architecture.md). Governed by
[ADR 0001](../../docs/adr/0001-v1-scope.md) as a whole.
