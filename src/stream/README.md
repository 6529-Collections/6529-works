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
| `StreamViews.sol` | The genesis read-only extension ([`IStreamExtension`](../interfaces/IStreamExtension.sol), [`IStreamViews`](../interfaces/IStreamViews.sol)), deployed by Stream's constructor and reached only by STATICCALL from its fallback: `work`, `collection`, `totalSupply`, `contractURI`, `owner`, and the collection-name rule. |
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

- **Permanent core, replaceable policy (AUC-38).** `mint` checks the adapter (one SLOAD), then
  `_authorize` encodes `authorize(context, data)` by hand and reads the policy's flat
  `MintRecord` where the call returned it, after checking each word is a clean value of its type;
  `_checked` applies the core's invariants. The policy has no write path into Stream. The artist
  registry and split factory are immutables with no setter; the policy, economics resolver,
  entropy module and view extension are genesis immutables until `setDependency` writes
  `_replaced[i]` and sets bit `i` of `Counts.replaced`, in the counter word every mint already
  reads, so genesis mints read no extra slot. Replacing the entropy module appends the module it
  replaces, with the last token ID minted, to `_entropyEras`; `entropyModuleOf(tokenId)` walks
  it (ENT-18).
- **Extension and layout.** `StreamViews` reads Stream through `extsload` with compiled slot
  numbers (`COUNTS_SLOT` 11, `OWNER_SLOT` 12, `CONTRACT_URI_SLOT` 13, `COLLECTIONS_SLOT` 17,
  `TOKENS_SLOT` 18): any change to Stream's storage order needs a new extension. The renderer
  reads slots 17 and 18 the same way, and never Stream's fallback, so no extension replacement
  touches a work's metadata (RND-22).
  `collectionCount` and `totalMinted` stay native because `WorkRecords` reads them.
- **Pluggable 1/1 sale (owner decision 15).** `_minterKinds` records each adapter's sale kind
  at its first admission, after every earlier mapping, so the storage layout of the other
  slots is unchanged; `primaryTerms` reads it for a minted work. `mint` compares the record's kind
  with `Minter.kindKey`, the same kind as 152 bits of its keccak256 kept in the minter word it
  reads anyway, so an adapter's later `saleKind()` answer changes nothing and the check costs no
  extra slot.
- **Primary-sale outcome (owner decision 17).** `settlePrimary` keeps the outcome in two
  `TokenData.flags` bits beside `SETTLED` (`SALE_SOLD`, `SALE_FROZEN_OUT`; neither is UNBID,
  and both, which no adapter can report, is `rescueToMuseum`'s RESCUED, owner decision 28), in
  the word it rewrites anyway, and a SOLD work's currency and price in `_sales` (declared last),
  the only new slot. An unsold work moves to the museum through `_update`, checked for the
  adapter's custody and a nonzero museum, with no receiver callback; the only external call is
  the resolver's `museum()`.
- **Fail-closed metadata (AUC-42).** `rendererOf` reads the records satellite's
  `pinnedRenderer` with all the gas it has (`BoundedCall.tryReadAll`): only "no pin" and
  `RecordNotOpen` serve the default renderer; other reverts pass on, a malformed answer reverts
  `RendererPinUnreadable`, and a shortfall reverts `BoundedCallShortfall`.
- **Content uniqueness (AUC-44).** `_contents[contentHash]` packs the minting token ID, a
  release's beneficiary and a released flag; `_claimContent` checks and sets it in `_store` (the
  cold read and the one new slot the registry paid before). `releaseContent` and the tombstones
  (`_tombstoned`) are Stream's; a burn leaves the record.
- **Rescue delay (AUC-41).** `Counts.rescueDelay` (zero means the 90-day floor) is read at an
  adapter's removal and locked in its `Minter.rescueDelay`.
- **Start-path storage (QUALITY-6).** A mint writes the ERC-721 owner, two token words (seller,
  serial, collection, a flags byte (kind and seed policy, two bits each, then the sale and link
  bits) and a 24-bit terms ID; the item hash) and rewrites two
  nonzero counter words (the global counts and the collection's). The
  terms (lead artist ID, and 24 bits each for royalty rate, fee share, fee-recipient index
  and minting-adapter index) are one word shared by every work under the same terms, at the position its hash names or,
  after a 23-bit collision, in an overflow range found by the full hash; nothing loops. A first
  start under new terms writes it. The layout is what keeps `start` within its budget and slot
  maximum ([ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table)); the
  collision cost is LIM-GAS-10. `GasReport.t.sol` asserts every start row's exact slot count,
  so any new word on this path fails CI until the ADR's table moves.
- **Nothing in `WorkRecords` is written at mint.** Keep it that way: the record opens later
  with the permissionless `openRecord`, and every per-token function reverts with
  `RecordNotOpen` until then. Its first record word packs the pin, version, media count,
  `syncedFiles`, a flags byte (opened, finalized, on-chain complete, custom license), the 24-bit
  chunk cursor and the 16-bit `renounced` mask: it is full, so a new per-work field needs a new
  slot. Media is one word per file plus one `files` word, a byte per file: the role in the low
  four bits, the store in the high four.
- **Permanent, so frozen at launch.** `WorkRecords` is bound once by Stream and Editions and can
  never be replaced; `IWorkRecords`' ERC-165 ID (`0x2654eed1`) and `IWorkPowers`' (`0xbd18229c`)
  freeze with it. What may change lives behind its two governed pointers: the delivery contract
  (`setDelivery`) and the store set (`addStore`).
- **Item fields are open `uint8`s** in the shared `PackageItem` and `MediaFile` (kind, seed
  policy, party and media roles; the enums only name today's values), so a kind, seed policy or
  role a future mint policy adds never makes `openRecord` revert (WS-45). The ABI, the item hash
  and every selector are unchanged: an enum encodes as `uint8`.
- **`royaltyInfo` makes one view call** (the split factory's `walletFor`) and nothing else, so a
  gas shortfall reverts instead of returning a zero royalty. Do not add reads to it.
- **Renderer pins fail closed** (DEPS-6): `rendererOf` re-checks the default renderer's and a
  finalized work's pinned code hash at every call and reverts instead of falling back.
- **`syncOnChain`** verifies at most the caller's `maxChunks` (no compiled budget) through the
  content store's `firstMissing(fileId, from, to, source)`, which checks its own chunks or
  re-hashes what an added store serves. Two walks: the content store's, anyone's, cursor in word
  0; an added store's, the artist's only, cursor in `_storeCursors` (one slot per work, written
  only on that walk). An added store is checked one chunk per call, so a refusal is a missing
  chunk. Each file that completes emits `MediaFileComplete` with its store, every call that
  progressed `OnChainSyncProgress`, and the call that finishes `WorkOnChainComplete` (WS-42,
  WS-43).
- **Forwarding.** `preferredLocator` asks the delivery contract with all the gas the EIP-150
  rule allows (`BoundedCall.tryReadAll`) and checks the answer (`_isLocation`); a refusal or a
  malformed answer serves the work's own (WS-40; a URI that is not UTF-8 is malformed), a
  shortfall reverts. No renderer budget is held: a record is one chunk, and the pinned
  renderer decides what it can show.
- **Locator adders** (`WorkDelivery`). `LocatorCounts` keeps, beside the two quota counts, a
  16-bit mask of the indices the artist added; the preferred-location fallbacks read only those
  (WS-21), and `LocatorAdded` names the adder, so a successor can rebuild it.
- **Amendments** bump the version before their external calls (Stream, Editions), and every
  consent binds the state hash, so nothing applies twice. `renounce` bumps it too, which is its
  replay protection; it shares the artist-only signature check with `repinRenderer`
  (`_checkArtistConsent`).
- **`IWorkPowers` is a second interface.** 6529 Stream and 6529 Stream Editions compile
  `type(IWorkRecords).interfaceId` into their bind checks; both IDs freeze at launch.
  `RENDERER_REPIN` (4) is renounceable only after finalize, and then `repinRenderer` reverts for
  good for that work.
- **Bytecode.** `WorkRecords` is the tighter of the two; current margins in the
  [audit scope](../../docs/audit/scope.md#products-and-sales).
- **Tests:** `forge test --match-path 'test/stream/**'`: core and satellite units, preferred
  location, the terms tests (`StreamTerms*.t.sol`, including real and ground collisions), the
  stateful invariants and `StreamTxCap.t.sol`; a Halmos proof of `SpdxId` is in
  `test/symbolic/` ([Testing](../../docs/testing/README.md)). End to end: `CuratedSale.t.sol`,
  `RecordAmendments.t.sol`, `SyncOnChainResume.t.sol`, `RendererCodePin.t.sol`, the powers
  on the deployed stack in `test/stream/WorkPowersStack.t.sol`; delivery, stores, future item
  values and the governance invariant in `test/stream/WorkDelivery.t.sol`, `WorkStores.t.sol`,
  `WorkRecordsFuture.t.sol` and `WorkRecordsGovernanceInvariant.t.sol`; and
  `GasReport.t.sol` in [`test/integration/`](../../test/integration/). The mint policy's safety
  (a hostile policy and its invariant) is `test/stream/StreamPolicySafety.t.sol`; the interface
  ids are pinned in `test/interfaces/StreamInterfaceIds.t.sol`.

## See also

[ADR 0001](../../docs/adr/0001-v1-scope.md) §4 (token model), §5, §7 (royalties), §8 (works,
content, storage), §9, §10 (permanence) and §12; [ADR 0006](../../docs/adr/0006-work-powers-and-conventions.md)
(lower-only royalty, renounceable powers); [ADR 0003](../../docs/adr/0003-build-time-decisions.md#token-model-and-storage-amends-adr-0001-4-and-8);
the [differences from the ADRs](../../docs/spec/README.md#differences-from-the-adrs);
[known limitations](../../docs/audit/known-limitations.md) LIM-GAS-10, LIM-CNT-2 and
LIM-CNT-10; [events: Stream and WorkRecords](../../docs/integrators/events-and-indexing.md#stream).
