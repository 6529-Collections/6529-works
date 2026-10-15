# federated

6529 Stream Federated, shipped in v1.1 and only if needed: artist-run
contracts built from the network's audited templates and registered
permissionlessly, without curation. Templates are the 6529 Stream ERC-721 and
6529 Editions ERC-1155 token code with curation switched off, published by
governance and identified by code hash; a factory deploys a template (or a
linked 721/1155 pair, linked in the same transaction) as a full non-proxy
contract; and the federation registry, written only by the factory, records
each contract's address, form, artist ID, template version and code hash, fee
terms and `ACTIVE`/`DELISTED` status for the shared sale adapters (90/10
primary and royalty split) and for indexers. v1 keeps only what makes this
possible: the shared sale adapters in `sales/`, template-ready token code and
the registry interface. Governed by
[ADR 0001 §16](../../docs/adr/0001-v1-scope.md#16-6529-stream-federated), with
the license rule in §8 and the network tiers in §2. Before a federation
registry is installed in the sale adapters, meet the prerequisites in the
[sales README](../sales/README.md) (federation install prerequisites).
