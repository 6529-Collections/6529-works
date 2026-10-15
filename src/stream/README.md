# stream

6529 Stream: the one shared, network-curated ERC-721 that holds every curated 1/1, split into a
core token and a records satellite. The core mints a work when an admitted sale adapter starts
its auction, locks its terms, serves royalties and forwards `tokenURI`; the satellite holds
everything that describes the work and can change after the mint. The rules are in
[Stream and auctions](../../docs/spec/stream-and-auctions.md) (`AUC-*`, the core) and
[Works and storage](../../docs/spec/works-and-storage.md) (`WS-*`, the satellite); renderer
selection in [Rendering and tokenURI](../../docs/spec/rendering-and-tokenuri.md#renderer-selection).

## Files

| File | What it is |
| --- | --- |
| `Stream.sol` | The core ([`IStream`](../interfaces/IStream.sol), [`IMintTarget`](../interfaces/IMintTarget.sol)): minting for consumed package items, collections and serials, the terms locked at mint, `royaltyInfo`, burns, the edition link, `rendererOf` and `tokenURI`, contract URI and marketplace owner. |
| `WorkRecords.sol` | The records satellite ([`IWorkRecords`](../interfaces/IWorkRecords.sol)): opening a work's record, the record file, media list, license and ARTIST seed, the state hash, finalize and renderer pins, amendments, on-chain completeness, locators and preferred location. |
| `SpdxId.sol` | Internal library: the license-ID rule Stream applies at mint and `WorkRecords` at deployment and relicense. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| An admitted adapter (the English auction) | `mint` at `start`, which consumes the item through the package registry in the same call; `markPrimarySettled` at settle; `burn` on an upheld dispute; `primaryTerms` (view) | AUC-1 to AUC-9, ENT-12 |
| PLATFORM | `createCollection` | AUC-12 |
| Editions | `linkEdition` once per settled master | AUC-11, ED-2 |
| The bound `WorkRecords` | `setRoyaltyRate`, `emitMetadataUpdate` | AUC-6, WS-23 |
| Anyone | `openRecord`, `syncOnChain`; the views (`work`, `coreOf`, `artistOf`, `royaltyInfo`, `rendererOf`, `tokenURI`, `record`, `mediaOf`, `licenseOf`, `seedOf`, `preferredLocator`, ...) | WS-1 to WS-3, WS-17, AUC-7, RND-1 |
| The lead artist's active authority | `setRecord`, `finalize`; `addLocator` before finalize; EIP-712 consents to amendments | WS-7 to WS-9, WS-19 |
| PLATFORM; STORAGE_OPERATOR | `addLocator` (after finalize only PLATFORM); the three preference setters | WS-19, WS-22 |
| Governance | `setAdmittedMinter`, `setDefaultRenderer`, `releaseContent`, `setContractURI`, `setOwner`; `relicense`, `setRoyaltyRate`, `repinRenderer` with every consent they need; the genesis binds | [Role matrix: Stream](../../docs/audit/roles.md#stream) and [WorkRecords](../../docs/audit/roles.md#workrecords) |

Who calls what on `WorkRecords`, and what it calls out to, is tabulated under
[Works and storage](../../docs/spec/works-and-storage.md#who-calls-workrecords-and-what-it-calls).

## Developer notes

- **Start-path storage (QUALITY-6).** A mint writes the ERC-721 owner, two token words (seller,
  serial, collection, a flags byte and a 24-bit terms ID; the item hash) and rewrites two
  nonzero counter words (the global counts and the collection's). The
  terms (lead artist ID, royalty rate, fee share, fee-recipient index, minting-adapter index)
  are one word shared by every work under the same terms, at the position its hash names or,
  after a 23-bit collision, in an overflow range found by the full hash; nothing loops. A first
  start under new terms writes it. The layout is what keeps `start` within its budget and slot
  maximum ([ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table)); the
  collision cost is LIM-GAS-10. `GasReport.t.sol` asserts every start row's exact slot count,
  so any new word on this path fails CI until the ADR's table moves.
- **Nothing in `WorkRecords` is written at mint.** Keep it that way: the record opens later
  with the permissionless `openRecord`, and every per-token function reverts with
  `RecordNotOpen` until then. Its first record word packs the pin, version, media count, flags
  and `syncedFiles`; media is one word per file plus one word of roles.
- **`royaltyInfo` makes one view call** (the split factory's `walletFor`) and nothing else, so a
  gas shortfall reverts instead of returning a zero royalty. Do not add reads to it.
- **Renderer pins fail closed** (DEPS-6): `rendererOf` re-checks the default renderer's and a
  finalized work's pinned code hash at every call and reverts instead of falling back.
- **`syncOnChain`** checks whole files within a 512-chunk budget per call (about a quarter of the
  EIP-7825 cap from cold storage), stores progress in the record's first word and emits
  `OnChainSyncProgress` only when the budget stops it; the call that finishes emits
  `WorkOnChainComplete`.
- **Amendments** bump the version before their external calls (Stream, Editions), and every
  consent binds the state hash, so nothing applies twice.
- **Bytecode.** `WorkRecords` is the tighter of the two; current margins in the
  [audit scope](../../docs/audit/scope.md#products-and-sales).
- **Tests:** `forge test --match-path 'test/stream/**'`: core and satellite units, preferred
  location, the terms tests (`StreamTerms*.t.sol`, including real and ground collisions), the
  stateful invariants and `StreamTxCap.t.sol`; a Halmos proof of `SpdxId` is in
  `test/symbolic/` ([Testing](../../docs/testing/README.md)). End to end: `CuratedSale.t.sol`,
  `RecordAmendments.t.sol`, `SyncOnChainResume.t.sol`, `RendererCodePin.t.sol` and
  `GasReport.t.sol` in [`test/integration/`](../../test/integration/).

## See also

[ADR 0001](../../docs/adr/0001-v1-scope.md) §4 (token model), §5, §7 (royalties), §8 (works,
content, storage), §9, §10 (permanence) and §12; [ADR 0003](../../docs/adr/0003-build-time-decisions.md#token-model-and-storage-amends-adr-0001-4-and-8);
the [differences from the ADRs](../../docs/spec/README.md#differences-from-the-adrs);
[known limitations](../../docs/audit/known-limitations.md) LIM-GAS-10, LIM-CNT-2 and
LIM-CNT-10; [events: Stream and WorkRecords](../../docs/integrators/events-and-indexing.md#stream).
