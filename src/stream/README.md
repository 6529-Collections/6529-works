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
| `Stream.sol` | The permanent core ([`IStream`](../interfaces/IStream.sol), one flat ERC-165 id; [`IMintTarget`](../interfaces/IMintTarget.sol)): mints what its mint policy ([`IMintPolicy`](../interfaces/IMintPolicy.sol), the package registry) admits into an admitted adapter's custody, collections and serials, the terms locked at mint, `royaltyInfo`, settle, burn, rescue and museum routing, the edition link, `rendererOf` and `tokenURI`, contract URI and marketplace owner. |
| `StreamViews.sol` | The genesis read-only extension ([`IStreamExtension`](../interfaces/IStreamExtension.sol), [`IStreamViews`](../interfaces/IStreamViews.sol)), deployed by Stream's constructor and reached only by STATICCALL from its fallback, which forwards only its three views: `work`, `collection`, `totalSupply`, and the collection-name rule. Informational: nothing permanent or pinned reads it (AUC-49). |
| `StreamLayout.sol` | The permanent storage slots of Stream that `extsload` readers (a pinned renderer, the extension) use: the token words, a collection's words and name, the counters, the owner and the contract URI (AUC-49). |
| `WorkRecords.sol` | The permanent records satellite ([`IWorkRecords`](../interfaces/IWorkRecords.sol), [`IWorkPowers`](../interfaces/IWorkPowers.sol)): opening a work's record, the record file, media list, license and seed, the state hash, finalize and renderer pins, amendments (the royalty rate only down), the lead artist's renounced powers, on-chain completeness and each file's store, and the governed pointers to the delivery contract and the store set. |
| `WorkDelivery.sol` | The first, replaceable delivery contract ([`IWorkDelivery`, `IWorkLocators`](../interfaces/IWorkDelivery.sol)), deployed by `WorkRecords`' constructor: locators, kinds, preferences and the URI grammar. |
| `SpdxId.sol` | Internal library: the license-ID rule Stream applies at mint and `WorkRecords` at deployment and relicense. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| An admitted adapter whose sale kind is the item's (the English auction at genesis; a later 1/1 method once governance admits it, owner decision 15) | `mint` at `start`, which asks the mint policy in the same call (AUC-38); `settlePrimary` at settle, which records the outcome and moves an unsold work to the museum; `burn` on an upheld dispute; `primaryTerms` (view) | AUC-1 to AUC-9, ENT-12 |
| PLATFORM | `createCollection` | AUC-12 |
| Editions | `linkEdition` once per settled master | AUC-11, ED-2 |
| The bound `WorkRecords` | `setRoyaltyRate`, `emitMetadataUpdate` | AUC-6, WS-23 |
| Anyone | `openRecord`, `syncOnChain(tokenId, 0, maxChunks)` (the content store; an added store is the work's artist's choice); the views (`work`, `coreOf`, `artistOf`, `royaltyInfo`, `rendererOf`, `tokenURI`, `record`, `mediaOf`, `licenseOf`, `seedOf`, `preferredLocator`, ...) | WS-1 to WS-3, WS-17, WS-40 to WS-43, AUC-7, RND-1 |
| The lead artist's active authority | `setRecord`, `finalize`; `WorkDelivery.addLocator` before finalize; EIP-712 consents to amendments; the `RenouncePowers` signature anyone may relay to `renounce` | WS-7 to WS-9, WS-19, WS-37, WS-38 |
| PLATFORM; STORAGE_OPERATOR | `WorkDelivery.addLocator` (after finalize only PLATFORM); its three preference setters | WS-19, WS-22 |
| The current delivery contract | `WorkRecords.refreshMetadata`, `refreshAllMetadata` | WS-39 |
| Governance | `setAdmittedMinter`, `setDependency`, `setRescueDelay`, `setDefaultRenderer`, `releaseContent`, `setContractURI`, `setOwner`; `relicense`, `setRoyaltyRate`, `repinRenderer` with every consent they need; `setDelivery`, `addStore`; the genesis binds | [Role matrix: Stream](../../docs/audit/roles.md#stream) and [WorkRecords](../../docs/audit/roles.md#workrecords) |

Who calls what on `WorkRecords`, and what it calls out to, is tabulated under
[Works and storage](../../docs/spec/works-and-storage.md#who-calls-workrecords-and-what-it-calls).

## Developer notes

- **Storage order is permanent.** `StreamViews` and a pinned renderer read Stream through
  `extsload` at `StreamLayout`'s slots (counters 11, owner 12, contract URI 13, collections 17,
  tokens 18), pinned by `StreamLayout.t.sol`. Add new slots after the others, as `_minterKinds`
  and `_sales` are (AUC-49, RND-22).
- **Start path (QUALITY-6).** `GasReport.t.sol` asserts every start row's exact slot count, so
  any new word on this path fails CI until the
  [ADR 0004 table](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table) moves;
  a replaced dependency is a bit of `Counts.replaced`, a word every mint reads (AUC-38, ENT-18).
- **Nothing in `WorkRecords` is written at mint.** Keep it that way. Its first record word is
  full, so a new per-work field needs a new slot; media is one word per file plus one `files`
  word (role in the low four bits of each byte, store in the high four).
- **Frozen interface ids** `0x2654eed1` (`IWorkRecords`) and `0xbd18229c` (`IWorkPowers`), in
  Stream's and Editions' bind checks, pinned by `StreamInterfaceIds.t.sol`.
- **`royaltyInfo` makes one view call.** Do not add reads to it.
- **Amendments and `renounce` bump the version before external calls.**
- **Behavior is owned by the spec:** fail-closed renderer reads (AUC-42, DEPS-6), content
  uniqueness (AUC-44), the rescue delay (AUC-41), renunciation (WS-37, WS-38), delivery
  forwarding (WS-40) and the sync walks (WS-42, WS-43).
- **Bytecode.** `WorkRecords` is the tighter of the two; margins in the
  [audit scope](../../docs/audit/scope.md#products-and-sales).
- **Tests:** `forge test --match-path 'test/stream/**'`; a Halmos proof of `SpdxId` is in
  `test/symbolic/` ([Testing](../../docs/testing/README.md)). End to end: `CuratedSale.t.sol`,
  `SyncOnChainResume.t.sol` and `GasReport.t.sol` in [`test/integration/`](../../test/integration/).

## See also

[ADR 0001](../../docs/adr/0001-v1-scope.md) §4 (token model), §5, §7 (royalties), §8 (works,
content, storage), §9, §10 (permanence) and §12; [ADR 0006](../../docs/adr/0006-work-powers-and-conventions.md)
(lower-only royalty, renounceable powers); [ADR 0003](../../docs/adr/0003-build-time-decisions.md#token-model-and-storage-amends-adr-0001-4-and-8);
the [differences from the ADRs](../../docs/spec/README.md#differences-from-the-adrs);
[known limitations](../../docs/audit/known-limitations.md) LIM-GAS-10, LIM-CNT-2 and
LIM-CNT-10; [events: Stream and WorkRecords](../../docs/integrators/events-and-indexing.md#stream).
