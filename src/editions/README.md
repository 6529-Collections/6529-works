# editions

The single shared 6529 Editions ERC-1155 (`Editions.sol`, implementing `IEditions`
and `IMintTarget`). Every edition is anchored by a Stream work of kind
`EDITION_MASTER`; the edition token records `(stream, workId, contentHash)`,
renders the master's `ContentStore` bytes, carries the master's license, and is
created only from the approved package. Edition sales use the shared fixed-price
(allowlist phases with the recipient-bound leaf fix, ERC-20 permits) and Dutch
adapters from `sales/`. Governed by
[ADR 0001 §6](../../docs/adr/0001-v1-scope.md#6-6529-editions), with
the exclusivity rule in §3 and the license rule in §8.

**Link.** `createEdition(workId, item)` is permissionless. It accepts only the
exact item the master was minted from (Stream's recorded item hash and content
ID), only while the package is approved and the item consumed, and only once a
VRF master's seed is delivered. It claims the content hash under
`PRODUCT_EDITIONS` in the package registry, locks the `PRODUCT_EDITIONS`
economics and the resolved currency, calls `IStream.linkEdition`, and verifies
Stream's side before returning. The edition ID is the master's token ID, and
nothing changes or removes a link.

**Minting.** Only MINTER adapters whose `saleKind()` matches the package's may
mint. FIXED editions stop at `size` copies; OPEN editions sell for `window`
seconds from the first mint, capped at `size` when it is nonzero. Burned copies
still count toward the size, and minting stops if the master is burned.

**Reads.** `royaltyInfo` uses the receiver and rate (out of 100,000) locked at
creation, from local storage. `licenseOf` and `uri` read through the master:
`uri` is served by `IStream.rendererOf(id)`.

**Wiring.** The package registry, economics resolver and artist registry are
read from Stream at deployment. Editions needs the SYSTEM role on the package
registry (for `claimContent`) and must be set as Stream's `editions()`.
