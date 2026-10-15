# federated

Reserved for 6529 Stream Federated, which ships in v1.1 and only if needed: artist-run token
contracts built from the network's audited templates and registered without curation through a
factory and a federation registry ([ADR 0001 §16](../../docs/adr/0001-v1-scope.md#16-6529-stream-federated)).
There is no code here in v1.

## What v1 already has

| Piece | Where |
| --- | --- |
| The registry interface the sale adapters read (`isActive`, the registry entry with its code hash and fee share) | [`IFederationRegistry`](../interfaces/IFederationRegistry.sol) |
| Federated targets in the shared adapters: a token sells while the registry reports it active and runs its recorded code, and pays the registry's fee share to the network's federated fee recipient | [`MintSaleBase`](../sales/MintSaleBase.sol), [`EnglishAuction`](../sales/EnglishAuction.sol); rules ED-24 in [Editions and sales](../../docs/spec/editions-and-sales.md#rules-and-invariants) and AUC-28 in [Stream and auctions](../../docs/spec/stream-and-auctions.md#rules-and-invariants) |
| The governed install of a registry in the adapters (`setFederationRegistry`, 30 days) and the artist registry's deferred `bindFederationRegistry` | [Role and permission matrix](../../docs/audit/roles.md) |
| The `PRODUCT_FEDERATED` economics (90/10 primary and royalty split) | [Economics and payouts](../../docs/spec/economics-and-payouts.md#products-and-launch-terms) |

## Before installing a registry

No registry is installed in v1. Before one is, set the economics resolver's
`PRODUCT_FEDERATED` fee recipient to a nonzero wallet and keep it nonzero while the registry is
installed: the auction checks it when a federated auction starts and reads it again at
settlement (LIM-SAL-4 in [known limitations](../../docs/audit/known-limitations.md#sales-and-auctions)).

## See also

[Glossary: 6529 Stream Federated](../../docs/glossary.md#6529-stream-federated),
[trust assumptions](../../docs/audit/trust-assumptions.md),
[sales module](../sales/README.md).
