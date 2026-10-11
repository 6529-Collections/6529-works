# editions

The single shared 6529 Editions ERC-1155 (`Editions.sol`, implementing `IEditions`
and `IMintTarget`). Every edition is anchored by a Stream work of kind
`EDITION_MASTER`; the edition token records `(stream, workId, contentId)` and
the master's claimed content hash (`contentHashOf`), renders the master's `ContentStore` bytes, carries the master's license, and is
created only from the approved package. Edition sales use the shared fixed-price
(allowlist phases with the recipient-bound leaf fix, ERC-20 permits) and Dutch
adapters from `sales/`. Governed by
[ADR 0001 §6](../../docs/adr/0001-v1-scope.md#6-6529-editions), with
the exclusivity rule in §3 and the license rule in §8.

**Link.** `createEdition(workId, item)` is permissionless. It accepts only the
exact item the master was minted from (Stream's recorded item hash and content
ID), only while the package is approved and the item consumed, and only after
the master's auction has settled, so a disputed or burned master never gets an
edition. It claims the content hash under `PRODUCT_EDITIONS` in the package
registry, locks the `PRODUCT_EDITIONS` economics (seller, fee, royalty), calls `IStream.linkEdition`, and verifies Stream's side before returning. The
edition ID is the master's token ID, and nothing changes or removes a link.

**Minting.** Only MINTER adapters whose `saleKind()` matches the package's may
mint. FIXED editions stop at `size` copies; OPEN editions sell for `window`
seconds from the first mint, capped at `size` when it is nonzero. Burned copies
still count toward the size. The package's currency is resolved when the terms
are read (`CURRENCY_DEFAULT` to the product default, every currency checked
active), so an adapter locks it when it opens a sale, from `primaryTerms`.

**Reads.** `royaltyInfo` uses the receiver and rate (out of 100,000) locked at
creation, from local storage. `licenseOf` and `uri` read through the master:
`uri` is served by `IStream.rendererOf(id)`. ERC-4906 `MetadataUpdate` is emitted
at creation and whenever the bound work-records satellite calls
`notifyMasterUpdated` for a master with an edition.

**Wiring.** Stream is checked at deployment (code, no EIP-7702 delegation,
ERC-165 for ERC-721, the reviewed code hash), and the package registry, economics
resolver and artist registry are read from it. The package registry must bind
Editions as its Editions caller (for `claimContent`), Stream must name it as
`editions()`, and genesis wiring binds the work-records satellite once
(`bindWorkRecords`, with its reviewed code hash).
