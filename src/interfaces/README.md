# interfaces

The contract surfaces every implementation lane builds against, and the shared
types they exchange. `IMintTarget` is the only thing a shared sale adapter knows
about a token; `IStream` and `IEditions` extend it. The content store and
dependency registry interfaces live here too. `types/` holds:
- the package item, media, sale, economics and identity structs, and the product
  IDs (payees are the economics lane's `ISplitWallet.Payee`);
- the `Limits` that keep every transaction under the EIP-7825 gas cap;
- `WorksHashing`, the one definition of item hashes, package Merkle leaves and
  work-record hashes (golden vectors in `test/interfaces/`).

Governed functions name the `Roles` role their selector is meant to map to. How
the contracts fit together, the main call flows and the trust boundaries are in
[docs/architecture.md](../../docs/architecture.md). Governed by
[ADR 0001](../../docs/adr/0001-v1-scope.md) as a whole.
