# Reading a work

This page is for marketplaces, wallets, indexers and front ends that show 6529 Stream works
and 6529 Editions editions. It shows how to fetch a token's metadata, how to decode it, what
every field means, where the media is, how to read dispute status, royalties and licenses, and
when to refresh a cache. The rules behind each answer are in the spec page
[Rendering and tokenURI](../spec/rendering-and-tokenuri.md), cited here by rule ID; this page is
the practical view. Contract addresses are in [Addresses](addresses.md); ABIs and ERC-165
interface IDs are in [ABIs and interface IDs](abis-and-interface-ids.md).

> Pre-audit. See the [project status](../../README.md#status).

## Quick reference

| You want | Call | Contract |
| --- | --- | --- |
| A work's metadata | `tokenURI(tokenId)` | 6529 Stream (ERC-721) |
| An edition's metadata | `uri(id)` | 6529 Editions (ERC-1155) |
| The metadata with all media inlined (up to 1 MiB) | `fullTokenURI(tokenContract, id)` | the renderer that `Stream.rendererOf(id)` names |
| Which renderer serves a token | `rendererOf(tokenId)` | 6529 Stream |
| Royalties | `royaltyInfo(id, salePrice)` | 6529 Stream or 6529 Editions (ERC-2981) |
| The license | `licenseOf(id)` | WorkRecords (works) or 6529 Editions (editions) |
| The dispute status | `latestDisputeOutcome(stream, tokenId)` | StatementLog (`Renderer.statementLog()` gives its address) |
| The edition of a master, and back | `editionOf(tokenId)`; `masterOf(editionId)` | 6529 Stream; 6529 Editions |
| When to refresh | `MetadataUpdate`, `BatchMetadataUpdate` (ERC-4906) | both tokens |

## Fetching the metadata

### 6529 Stream: `tokenURI`

```sh
cast call "$STREAM" "tokenURI(uint256)(string)" 12 --rpc-url "$RPC_URL"
```

```ts
// viem
const uri = await client.readContract({
  address: STREAM,
  abi: streamAbi,
  functionName: "tokenURI",
  args: [12n],
});
```

A burned or unminted token reverts with `UnknownWork(tokenId)`. Token IDs are one global
sequence from 1; a burn leaves a gap.

### 6529 Editions: `uri`

```sh
cast call "$EDITIONS" "uri(uint256)(string)" 42 --rpc-url "$RPC_URL"
```

- The edition ID is the master's Stream token ID, so edition 42 is the edition of Stream
  work 42.
- `uri(id)` returns that ID's metadata already resolved. It is not an ERC-1155 `{id}`
  template, and Editions emits no ERC-1155 `URI` event; it uses ERC-4906 instead.
- An ID with no edition reverts with `UnknownEdition(id)`.

### The full inline version: `fullTokenURI`

`tokenURI` inlines media only up to the inline threshold (256 KiB of attested base64 text,
32 KiB of raw bytes: `Renderer.DEFAULT_INLINE_THRESHOLD`). For more, call `fullTokenURI` on
the token's renderer. It is not a function of Stream or Editions:

```sh
RENDERER=$(cast call "$STREAM" "rendererOf(uint256)(address)" 12 --rpc-url "$RPC_URL")
cast call "$RENDERER" "fullTokenURI(address,uint256)(string)" "$STREAM" 12 --rpc-url "$RPC_URL"
# an edition: same renderer (rendererOf the edition ID), token = the Editions address
cast call "$RENDERER" "fullTokenURI(address,uint256)(string)" "$EDITIONS" 42 --rpc-url "$RPC_URL"
```

- It inlines a primary file of up to 1 MiB of attested base64 text, or 128 KiB of raw bytes.
- It reverts with `RendererNotInlineable(token, id)` instead of falling back to a locator
  ([RND-21][rnd]): for a work without a usable record, and for media that is not on-chain
  complete, too large, compressed, unattested base64, or a script it cannot wrap. Catch the
  revert and use `tokenURI`.
- It has no 8M gas promise. 1 MiB costs about 30M gas
  ([fullTokenURI](../spec/rendering-and-tokenuri.md#fulltokenuri)). Use `eth_call` against a node
  whose call gas cap allows it (geth's and reth's default is 50M, per the
  [uploader](../../tools/content/README.md#glamsterdam)).

### Supply enough gas

Every call the renderer makes is bounded: before each read it checks that the gas left covers
that read's cap plus a margin, and reverts with `BoundedCallInsufficientGas(gasLimit)` if not
([RND-6][rnd], [RND-7][rnd]).
A work with an open record needs about 1.07M gas left when the renderer reads its media list
(the 1,000,000 cap plus EIP-150's retention and a 51,000 margin), even though a typical
`tokenURI` uses about 0.3M ([flows.md](../../deployments/11155111/flows.md), section 4). The
worst case the protocol allows uses about 7.8M (the budget proof in
[`TokenUriBudget.t.sol`](../../test/integration/TokenUriBudget.t.sol)).

- Leave `gas` unset in `eth_call` (nodes then use their call gas cap), or set at least
  10,000,000 for `tokenURI` and `uri`, and 40,000,000 for `fullTokenURI`.
- A `BoundedCallInsufficientGas` revert means "retry with more gas". It never comes back as
  partial or empty metadata.
- `eth_estimateGas` returns more than the gas used, by design. It measured about 1.0M for an
  inlined `tokenURI` on Sepolia ([flows.md](../../deployments/11155111/flows.md)), before the
  media-list read got its own 1,000,000 cap; expect somewhat more now.

## Decoding the URI

The result is a `data:` URI, not a link:

```text
data:application/json;utf8,{"name":"Study %234","description":"Ink on paper, scanned at 600 dpi.","image":"data:image/png;base64,iVBORw0KGgo...
```

- The prefix is always `data:application/json;utf8,`.
- The body is compact JSON in UTF-8, **not base64**.
- Exactly two characters are percent-escaped: `%` as `%25` and `#` as `%23` (a `#` would end a
  `data:` URI, a stray `%` would break it). Nothing else is escaped, so quotes, braces, spaces
  and non-ASCII text appear as they are.

Decode in one pass, so `%2523` (a literal `%23` in the text) comes back as `%23`:

```ts
const PREFIX = "data:application/json;utf8,";

export function parseWorkUri(uri: string): Record<string, unknown> {
  if (!uri.startsWith(PREFIX)) throw new Error("not 6529 Works metadata");
  const body = uri.slice(PREFIX.length).replace(/%2[35]/g, (m) => (m === "%23" ? "#" : "%"));
  return JSON.parse(body);
}
```

```python
import json
import re

PREFIX = "data:application/json;utf8,"

def parse_work_uri(uri: str) -> dict:
    if not uri.startswith(PREFIX):
        raise ValueError("not 6529 Works metadata")
    body = re.sub(r"%2[35]", lambda m: "#" if m.group() == "%23" else "%", uri[len(PREFIX):])
    return json.loads(body)
```

Do not replace `%25` and `%23` in two passes in that order: `%2523` would decode to `#`.
A standard full percent-decoder (`decodeURIComponent`, `urllib.parse.unquote`) also works,
because no other `%` occurs.

## What the JSON looks like

The examples below are pretty-printed; the real output is one line, members in the order shown.
Long values are cut with `…`.

### A work with its record and inline media

Work 12 is serial 3 of the collection "Spring". Its primary file is a PNG stored as base64
text, attested and on-chain complete, under the inline threshold. Its record file (written in
RFC 8785 canonical form, as the tooling does) is:

```json
{"artists":["Ada Lovelace"],"attributes":[{"trait_type":"Palette","value":"Warm"},{"display_type":"number","max_value":9,"trait_type":"Layers","value":4}],"description":"Ink on paper, scanned at 600 dpi.","dimensions":"30 x 40 cm","medium":"Ink","name":"Study #4","year":2026}
```

`tokenURI(12)`, decoded:

```json
{
  "name": "Study #4",
  "description": "Ink on paper, scanned at 600 dpi.",
  "image": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA…",
  "content_type": "image/png",
  "content_hash": "0xc42cf928fa9d745ca5b19d93138c84a071d89a6b5a300cfbe61cdbc0195e8782",
  "license": "CC0-1.0",
  "license_url": "https://spdx.org/licenses/CC0-1.0.html",
  "license_text_file": "0x16f36978ff2763eee543b9e8af4dc7c1ab5ed2966aff3485474569012cfdd22b",
  "attributes": [
    {"trait_type": "Artist", "value": "Ada Lovelace"},
    {"trait_type": "Year", "value": 2026},
    {"trait_type": "Medium", "value": "Ink"},
    {"trait_type": "Dimensions", "value": "30 x 40 cm"},
    {"trait_type": "Collection", "value": "Spring"},
    {"trait_type": "Serial", "value": 3},
    {"trait_type": "Palette", "value": "Warm"},
    {"display_type": "number", "max_value": 9, "trait_type": "Layers", "value": 4}
  ]
}
```

- `name` and `description` come from the record; `name` keeps its `#` (it was `%23` in the URI).
- The first six attributes are the renderer's own; the last two are the record's, copied as the
  record wrote them, member order included ([RND-14][rnd]).
- `license_text_file` is the content-store file of the CC0 legal code the deployment pinned. The
  file ID depends only on the bytes, so it is the same on every deployment that uploads the committed
  text (`cc0TextFileId` in each deployment record).

### A work whose record is not available yet

Work 40 is serial 12 of "Spring", a VRF-seeded work whose record nobody has opened yet:

```json
{
  "name": "Spring #12",
  "description": "The work record is not available.",
  "record_status": "not_open",
  "attributes": [
    {"trait_type": "Artist ID", "value": "0x5b38da6a701c568545dcfcb03fcb875f56beddc4"},
    {"trait_type": "Collection", "value": "Spring"},
    {"trait_type": "Serial", "value": 12},
    {"trait_type": "Seed", "value": "0x1a17a88be4fc267d71fcd3d6004cbe8e15256602f4f76fe1a744ba68bbedf795"}
  ]
}
```

- `record_status` is the signal ([RND-9][rnd]): `not_open` (nobody has called
  `WorkRecords.openRecord`), `incomplete` (the record file is not fully uploaded) or `invalid`
  (the record breaks a rule). There is no media, no license and no `content_hash` in this form.
- The name is the collection and the serial, not the token ID.
- `Artist ID` is the lead artist ID as lowercase hex, with leading zero bytes dropped. For most
  artists it is their first authority address, but it is an ID, not a wallet to pay.
- `Seed` appears here only for a VRF work. An artist-chosen seed appears once the record opens.
- Anyone can open a record (`openRecord` is permissionless), so this state is usually short.

### An edition

Edition 42 is the edition of Stream work 42 (serial 7 of "Spring"). The master's primary file is
a video over the threshold with an Arweave copy, and the master lists a small PNG preview:

```json
{
  "name": "Tide",
  "description": "A looping study of the tide line.",
  "image": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA…",
  "animation_url": "ar://5mCceXH9Ohrp0JeAVmMWJklL1b8IZJc-iXJ52fH8Z_k",
  "media_url": "ar://5mCceXH9Ohrp0JeAVmMWJklL1b8IZJc-iXJ52fH8Z_k",
  "content_type": "video/mp4",
  "content_hash": "0x9f2c…",
  "license": "CC0-1.0",
  "license_url": "https://spdx.org/licenses/CC0-1.0.html",
  "license_text_file": "0x16f36978ff2763eee543b9e8af4dc7c1ab5ed2966aff3485474569012cfdd22b",
  "attributes": [
    {"trait_type": "Artist", "value": "Bo"},
    {"trait_type": "Year", "value": 2026},
    {"trait_type": "Medium", "value": "Video"},
    {"trait_type": "Collection", "value": "Spring"},
    {"trait_type": "Serial", "value": 7},
    {"trait_type": "Edition of", "value": 42}
  ]
}
```

- An edition shows its master's record, media and license. The only addition is `Edition of`,
  the master's token ID.
- Every copy of an edition has the same metadata. There are no numbered copies.
- Before the master's record opens, the edition is core-only too, with `Edition of`.

### A generative script

A JavaScript primary (`text/javascript`, at most 8 KiB) is served in `animation_url` as an HTML
page, `data:text/html;base64,…`, while `content_type` stays `text/javascript` and
`content_hash` is the hash of the script itself. The page runs this in a script of its own,
before the artist's script:

```js
window.works={v:1,tokenId:42,seed:"0x…"};
```

`seed` is `0x` and 64 hex digits, or `null` for an unseeded work. This object is a stable
interface: version 1 never changes meaning, and a change would need a new `v`. Show the page in a
sandboxed iframe, as you would any HTML artwork.

## Field reference

"Full" is the form with the record; "core-only" is the form with `record_status`.

| Field | Full | Core-only | Meaning |
| --- | --- | --- | --- |
| `name` | always | always | The record's title; core-only: `<collection> #<serial>` |
| `description` | always | always | The record's description (`""` if it has none); core-only: `The work record is not available.` |
| `image` | optional | never | A still image: the primary if it is an image, else the preview |
| `animation_url` | optional | never | The primary when it is not an image (HTML, video, audio, a script page) |
| `media_url` | optional | never | The primary's preferred off-chain copy, whenever the primary is not inlined |
| `content_type` | always | never | The primary file's MIME type |
| `content_hash` | always | never | SHA-256 of the decoded primary media, `0x` and 64 hex digits |
| `license` | always | never | SPDX identifier in its original case (`CC0-1.0`), or a `LicenseRef-…` |
| `license_url` | optional | never | `https://spdx.org/licenses/<id>.html` for an SPDX identifier; for a `LicenseRef-` license, an `ar://` or `ipfs://` copy of its text, when there is one |
| `license_text_file` | optional | never | Content-store file ID of the full license text |
| `record_status` | never | always | `not_open`, `incomplete` or `invalid` |
| `attributes` | always | always | The renderer's traits, then the record's own |

### Traits the renderer writes

These come first in `attributes`, in this order. The renderer vouches for them: a record may not
use these names, in any case or spacing ([RND-13][rnd]).

| Trait | When | Value |
| --- | --- | --- |
| `Artist ID` | core-only | string, the lead artist ID in hex |
| `Artist` | full, once per artist in the record | string |
| `Year` | full, when the record has a year | number |
| `Medium` | full, when non-empty | string |
| `Dimensions` | full, when non-empty | string |
| `Collection` | always for a Stream work or edition | string |
| `Serial` | always for a Stream work or edition | number, the serial within the collection |
| `Edition of` | editions | number, the master's token ID |
| `Seed` | seeded works, once the seed is readable | string, `0x` and 64 hex digits |
| `Dispute statement` | when a dispute outcome is recorded | string, the statement's entry hash |

### The record's own attributes

After the renderer's traits come the record's `attributes`, copied as the artist wrote them:
at most 32, each with a string `trait_type` and a string or number `value`, and optionally
`display_type` and `max_value` ([RND-12][rnd]). They are the artist's, not the protocol's: show
them as the work's traits, and do not treat one as a fact the chain checked.

Record text (names, descriptions, artists, attribute values) can hold any UTF-8, including `<`
and markup. Escape it before you put it in HTML.

## Media: inline or by locator

### Inline media

An inline value is a `data:<mime>;base64,…` URI you can use directly. The primary is inlined
only when the work is on-chain complete (every media file stored in the content store and
`syncOnChain` called), the file is under the threshold, and it is stored as attested base64
text or as raw bytes small enough to encode ([RND-17][rnd], [RND-18][rnd]). A preview image
is inlined as soon as the preview file itself is stored (and, if it is base64 text, attested),
before the work is on-chain complete. The base64 payload of an inlined primary decodes to bytes whose SHA-256 is
`content_hash` (except a script page, which wraps the script).

### Locators

When the primary is not inlined, `media_url` is its preferred copy, and `image` or
`animation_url` points at the same copy (or at the preview, for an image work). A locator is a
bare content address ([WS-18][ws]):

- `ar://` and a 43-character Arweave transaction ID;
- `ipfs://` and a base32 CIDv1 (`bafkrei…` or `bafybei…`, 66 characters in all).

Resolve them through a gateway you trust. For the primary, check that the SHA-256 of the decoded
media equals `content_hash`; a copy of a compressed or base64-encoded file holds the encoded
stream, which you decode first. Encodings, on-chain chunked reads and gateway advice are in
[Storage](storage.md).

The STORAGE_OPERATOR role chooses which registered copy is preferred ([WS-21][ws],
[WS-22][ws]) and can switch it at any time; each switch emits ERC-4906. Re-read the metadata on those events rather than storing a
locator for good.

### No media member

A work can have no `image`, `animation_url` or `media_url` for its primary. That happens when
the primary is over the threshold and has no Arweave or IPFS copy, or when its preferred copy
is the on-chain one (which has no URL). Then:

- call `fullTokenURI` (up to 1 MiB), or
- read the file from the content store by its file ID, from `WorkRecords.mediaOf(tokenId)`
  ([Storage](storage.md) shows the chunked reads).

## Dispute statements

When a dispute outcome is recorded about a work, the metadata carries a `Dispute statement`
trait:

```json
{"trait_type": "Dispute statement", "value": "0x1a17a88be4fc267d71fcd3d6004cbe8e15256602f4f76fe1a744ba68bbedf795"}
```

The value is an entry hash in the statement log, not the outcome itself. To read the outcome:

1. Get the log's address from the renderer: `Renderer.statementLog()`.
2. `latestDisputeOutcome(stream, tokenId)` returns the same entry hash: the latest
   `DISPUTE_OUTCOME` about the token, or, if the token has none, the latest about the package
   item it was minted from (subject `(address(0), uint256(itemHash))`, with `itemHash` from
   `Stream.coreOf(tokenId)`).
3. `disputeOutcomeOf(stream, tokenId)` returns the token's own latest outcome only (no item
   fallback) and its position in the token's chain.
4. Find the `StatementAppended` event whose `entryHash` matches. Filter by `subjectKey`
   (`keccak256(abi.encode(token, id))`, also the log's public `subjectKey(token, id)`) and by
   `kind` = `keccak256("DISPUTE_OUTCOME")`. The event's `statement` holds the content hash and
   a `uri` or a content-store `fileId` for the outcome document.

The latest outcome replaces earlier ones in this answer ([DSP-12][dsp], [RND-23][rnd]), so each
outcome document restates the earlier disputes it keeps in force. For an edition, query the
master: `(stream, editionId)`. The log refuses an outcome about an ERC-1155 subject, so none is
ever recorded against the edition itself ([DSP-11][dsp]).

## Other reads

| Read | Contract | Returns | Notes |
| --- | --- | --- | --- |
| `royaltyInfo(tokenId, salePrice)` | Stream | receiver, amount | ERC-2981. Rate out of 100,000 (`Splits.DENOMINATOR`). The receiver is fixed at mint; the rate changes only with every party's consent plus a governed action (FUNDS_SETTER, 14 days, [WS-14][ws]). It makes one view call to the split factory: it can run out of gas and revert, but never returns a zero royalty for lack of gas ([AUC-7][auc]). About 41K gas ([ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#the-table)). |
| `royaltyInfo(id, salePrice)` | Editions | receiver, amount | Read from storage, no external call. Receiver locked at creation; the rate follows the master's. |
| `licenseOf(tokenId)` | WorkRecords | `(spdxId, textFileId)` | Reverts with `RecordNotOpen` until the record opens. Defaults to the deployment's CC0. |
| `licenseOf(editionId)` | Editions | the master's license | Reverts with `UnknownEdition`, or `RecordNotOpen` until the master's record opens. |
| `work(tokenId)` | Stream | item hash, artist ID, collection, serial, kind, seed policy, seller, royalty receiver, royalty rate | Reverts with `UnknownWork`. |
| `coreOf(tokenId)` | Stream | item hash, artist ID, collection, kind, seed policy, royalty rate | The cheap read. |
| `primarySaleSettled(tokenId)` | Stream | bool | True once the auction settled; false before, and for burned IDs. |
| `editionOf(tokenId)` | Stream | Editions address and edition ID, or zeros | Only for a master with an edition. |
| `masterOf(editionId)` | Editions | Stream address, master token ID, content hash | Reverts with `UnknownEdition`. |
| `edition(editionId)`, `exists(editionId)`, `formatOf(editionId)` | Editions | edition state, terms, minted count; FIXED or OPEN | |
| `isOpen(tokenId)` | WorkRecords | bool | Never reverts. Every other per-token WorkRecords view reverts with `RecordNotOpen` until the record opens. |
| `record(tokenId)` | WorkRecords | record file ID, media hash, license key, version, `finalized`, `onChainComplete`, pinned renderer | |
| `mediaOf(tokenId)`, `locators(tokenId, fileId)`, `preferredLocator(tokenId, fileId)` | WorkRecords | the media list (primary first), every registered copy, the served copy | See [Storage](storage.md). |
| `seedOf(tokenId)` | WorkRecords | seed policy and seed | |
| `rendererOf(tokenId)` | Stream | renderer address | Reverts if the renderer's code changed (below). |
| `collection(collectionId)` | Stream | name, metadata hash, works minted | |
| `contractURI()` | Stream, Editions | ERC-7572 contract-level metadata URI | Changes emit `ContractURIUpdated`. |
| `owner()` | Stream, Editions | the marketplace owner | Held by 6529 for marketplace settings such as creator earnings; it has no on-chain powers. |

Both tokens report ERC-4906 (`0x49064906`) and ERC-2981 through ERC-165.

## When to refresh

### Events

| Event | Contract | Refresh |
| --- | --- | --- |
| `MetadataUpdate(tokenId)` | Stream | that work |
| `BatchMetadataUpdate(1, totalMinted)` | Stream | every work (a new default renderer, or a global or collection storage preference) |
| `MetadataUpdate(editionId)` | Editions | that edition |
| `BatchMetadataUpdate(0, type(uint256).max)` | Editions | every edition |

Stream emits `MetadataUpdate` when a record opens, changes or is finalized, when a work becomes
on-chain complete, when a locator is added or a file preference set, after a relicense, a
royalty change or an errata repin, and when an edition is linked to a master. Editions emits the
same for a master's edition ([RND-27][rnd]). Every source is listed under
[ERC-4906 refresh triggers](events-and-indexing.md#erc-4906-refresh-triggers).

Three changes reach `tokenURI` without an ERC-4906 event, because the contract that changes does
not know which works use the file:

| Change | Signal to watch | Refresh |
| --- | --- | --- |
| A record file or a preview image becomes complete in the store | `ContentStore.ManifestRegistered` or `ChunkWritten`, or poll `ContentStore.isComplete(fileId)` | works whose `record_status` is `incomplete` (the file ID is `WorkRecords.record(tokenId).recordFileId`), or whose preview was a locator |
| A base64 file is attested | `ContentStore.Base64Attested(fileId)` | works listing that file (`WorkRecords.mediaOf`) |
| A dispute outcome is recorded | `StatementLog.StatementAppended` with kind `DISPUTE_OUTCOME` | the work in the subject, or every work minted from the item in the subject; and its edition |

A simple policy: refresh on every ERC-4906 event, and re-fetch at intervals any work that is
core-only or not yet on-chain complete. [Events and indexing](events-and-indexing.md) covers
indexing these in full.

### What never changes

- **The media.** The media list, `content_type` and `content_hash` are fixed by the approved
  package from the moment the record opens ([WS-6][ws]). Bytes in the content store are
  permanent.
- **The record, after finalize.** Once `WorkFinalized` is emitted, `name`, `description`, the
  artist, year, medium and dimensions traits and the record's attributes never change, and the
  renderer is pinned, so the output format does not change either. Only an errata repin
  (`RendererRepinned`, the artist's signature plus a 30-day governed delay, [WS-15][ws])
  installs another renderer for that work.
- **The collection and serial.** Collections cannot be renamed; serials never change.
- **A CC0 license.** It is irrevocable ([WS-12][ws]).

What can still change after finalize: the media members (new copies, a new preference,
on-chain completion, attestation), a non-CC0 license (a relicense needs every party plus a
48-hour governed action, [WS-13][ws]), the dispute statement, and the royalty rate (not part
of the JSON).

### When a call reverts

Do not cache a revert as empty metadata.

| Revert | Meaning | What to do |
| --- | --- | --- |
| `UnknownWork(tokenId)` | Burned or never minted | Drop the token. A burn is also a `Transfer` to the zero address. |
| `UnknownEdition(id)` | No edition with this ID | Check the ID against `editionOf`. |
| `BoundedCallInsufficientGas(gasLimit)` | Your call supplied too little gas | Retry with more gas, or with `gas` unset. |
| `InvalidBinding(renderer)` (Stream) or `InvalidRenderer(renderer)` (WorkRecords) | The renderer's code is no longer the code it was installed or pinned with; the metadata is withheld on purpose | Keep the last good metadata and retry later. A new default renderer or an errata repin restores it, with ERC-4906 events. |
| `RendererReadFailed(target, selector)`, `BoundedCallFailed(target)`, `BoundedCallMalformedReturn(target)` | A contract the renderer reads failed or returned malformed data | Keep the last good metadata and retry later. |
| `RendererNotInlineable(token, id)` | Only from `fullTokenURI`: the work cannot be served fully inline | Use `tokenURI`. |

[rnd]: ../spec/rendering-and-tokenuri.md#rules-and-invariants
[ws]: ../spec/works-and-storage.md#rules-and-invariants
[dsp]: ../spec/disputes-and-statements.md#rules-and-invariants
[auc]: ../spec/stream-and-auctions.md#rules-and-invariants
