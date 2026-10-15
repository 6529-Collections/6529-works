# Rendering and tokenURI

How a 6529 Stream work and a 6529 Editions edition get their token metadata: which renderer
serves a token, how it bounds every read, how it turns a work's record and media into a `data:`
URI, when media is inlined, and when marketplaces are told to refresh. For auditors and renderer
authors. `Stream.tokenURI` and `Editions.uri` forward to an immutable, stateless `Renderer`,
which reads `WorkRecords`, the content store and the statement log. Integrators who only read
metadata should start with [Reading a work](../integrators/reading-a-work.md).

> Pre-audit. See the [project status](../../README.md#status).

## Contracts

| Contract | Source | Interface | Responsibility |
| --- | --- | --- | --- |
| `Renderer` | [`src/content/Renderer.sol`](../../src/content/Renderer.sol) | [`IRenderer`](../../src/interfaces/IRenderer.sol) | Builds `tokenURI` and `fullTokenURI` for Stream works and Editions editions. Immutable and stateless; reads only. |
| `JsonScan` | [`src/content/JsonScan.sol`](../../src/content/JsonScan.sol) | library | Strict RFC 8259 scanner: validates the record and reports where each value sits. Never decodes, never reverts. |
| `DataUri` | [`src/content/DataUri.sol`](../../src/content/DataUri.sol) | library | Percent-escapes `%` and `#`, with a cap on how many. |
| `HtmlScript` | [`src/content/HtmlScript.sol`](../../src/content/HtmlScript.sol) | library | Neutralizes `</script` and `<!--` in a script placed in the renderer's HTML page, with a cap on `<`. |
| `JsonEscape` | [`src/libraries/JsonEscape.sol`](../../src/libraries/JsonEscape.sol) | library | Escapes strings from Stream, a locator or the store for a JSON string. |
| `Utf8` | [`src/libraries/Utf8.sol`](../../src/libraries/Utf8.sol) | library | RFC 3629 UTF-8 validation. |
| `BoundedCall` | [`src/libraries/BoundedCall.sol`](../../src/libraries/BoundedCall.sol) | library | A `staticcall` with a gas cap and a return-size cap; reverts if the caller cannot forward the full cap. |
| `Stream` | [`src/stream/Stream.sol`](../../src/stream/Stream.sol) | [`IStream`](../../src/interfaces/IStream.sol) | `tokenURI` forwarding, `rendererOf`, the default renderer and its code-hash pin, ERC-4906 events for works. |
| `Editions` | [`src/editions/Editions.sol`](../../src/editions/Editions.sol) | [`IEditions`](../../src/interfaces/IEditions.sol) | `uri` forwarding to the master's renderer, `masterOf`, ERC-4906 events for editions. |

## Concepts

The [record](../glossary.md#record), [record status](../glossary.md#record-status),
[core-only metadata](../glossary.md#core-only-metadata), [renderer](../glossary.md#renderer),
[pin](../glossary.md#pin), [errata repin](../glossary.md#errata-repin),
[on-chain complete](../glossary.md#on-chain-complete),
[base64 attestation](../glossary.md#base64-attestation),
[inline threshold](../glossary.md#inline-threshold),
[preferred locator](../glossary.md#preferred-locator) and
[`fullTokenURI`](../glossary.md#fulltokenuri) are defined in the glossary. What this page adds:

- **Default renderer.** `Stream.defaultRenderer`, installed with a code hash, serves every
  unfinalized work and its editions; a finalized work only its pin (RND-1).
- **Fail closed.** A renderer never returns plausible metadata for a token it cannot read. Every
  external read is bounded; a read that fails reverts the whole call.
- **Cost-weighted size.** The stored length of a file, with an `Identity` file counted eight
  times, because the renderer must base64-encode it (about 80 gas a byte against about 10 for
  copying text that is already base64, per `Renderer._weight`).

## State machine

A token's metadata has two independent states: what its metadata shows, and which renderer
builds it.

### Metadata mode

```mermaid
stateDiagram-v2
    state "Core-only, not_open" as NotOpen
    state "Core-only, incomplete" as Incomplete
    state "Core-only, invalid" as Invalid
    state "Full record, primary by locator" as ByLocator
    state "Full record, primary inline" as Inline
    [*] --> NotOpen : mint at auction start
    NotOpen --> Incomplete : openRecord, record file missing or partial
    NotOpen --> Invalid : openRecord, record refused
    NotOpen --> ByLocator : openRecord, record accepted
    Incomplete --> ByLocator : last record chunk stored, record accepted
    Incomplete --> Invalid : last record chunk stored, record refused
    Invalid --> ByLocator : setRecord before finalize
    ByLocator --> Invalid : setRecord before finalize
    ByLocator --> Inline : syncOnChain or attestBase64
    Inline --> Invalid : setRecord before finalize
```

- "Refused" and "accepted" are decided on every call, not stored, so a new renderer can move a
  work between `Invalid` and the full states without any record change.
- A burn ends every state: `tokenURI` then reverts with `UnknownWork`.

| Transition | Caller (role) | Delay | Function |
| --- | --- | --- | --- |
| Mint, core-only `not_open` | the English auction adapter at start | immediate | `Stream.mint` (through `IMintTarget`) |
| Open the record | anyone | immediate | `WorkRecords.openRecord` |
| Complete the record file | anyone | immediate | `ContentStore.registerManifest`, `writeChunk` (no ERC-4906 event) |
| Replace the record, before finalize | the artist (active authority of the lead artist ID) | immediate | `WorkRecords.setRecord` |
| Inline the primary | anyone | immediate | `WorkRecords.syncOnChain`; `ContentStore.attestBase64` for a `Base64` file (no ERC-4906 event) |
| Finalize: the record is fixed | the artist | immediate | `WorkRecords.finalize` |

### Renderer selection

```mermaid
stateDiagram-v2
    state "Default renderer" as UsesDefault
    state "Pinned renderer" as UsesPin
    state "Reverts, default code changed" as BrokenDefault
    state "Reverts, pinned code changed" as BrokenPin
    [*] --> UsesDefault : mint
    UsesDefault --> UsesDefault : setDefaultRenderer
    UsesDefault --> UsesPin : finalize pins the default
    UsesPin --> UsesPin : repinRenderer, errata path
    UsesDefault --> BrokenDefault : code at the default address changes
    BrokenDefault --> UsesDefault : setDefaultRenderer
    UsesPin --> BrokenPin : code at the pinned address changes
    BrokenPin --> UsesPin : repinRenderer, errata path
```

| Transition | Caller (role) | Delay | Function |
| --- | --- | --- | --- |
| New default renderer | hot admin Safe (SUCCESSOR_SETTER) | successor, 30 days | `Stream.setDefaultRenderer` |
| Finalize pins the default | the artist | immediate | `WorkRecords.finalize` |
| Errata repin | hot admin Safe (SUCCESSOR_SETTER) with the artist's `RENDERER_REPIN` signature | successor, 30 days | `WorkRecords.repinRenderer` |
| Code changes at a renderer address | nobody intended (say, a CREATE2 redeploy) | n/a | detected by `Stream.rendererOf` and `WorkRecords.pinnedRenderer` (DEPS-6) |

Role holders and delays are in [Governance](governance.md) and [roles.md](../audit/roles.md).

## Flows

### `Stream.tokenURI`: choosing the renderer

```mermaid
sequenceDiagram
    participant C as Caller
    participant S as Stream
    participant W as WorkRecords
    participant R as Renderer
    C->>S: tokenURI(tokenId)
    S->>S: rendererOf, the token must be live
    S->>W: isOpen(tokenId)
    opt record open
        S->>W: pinnedRenderer(tokenId)
        Note over W: reverts InvalidRenderer if the pinned code changed
    end
    opt no pin
        S->>S: defaultRenderer, its codehash must match the installed hash
    end
    S->>R: tokenURI(stream, tokenId)
    R-->>S: data URI
    S-->>C: data URI
```

- `rendererOf` never falls back from a broken pin to the default, or from a broken default to
  anything else: the call reverts (`IStream.InvalidBinding` or `IWorkRecords.InvalidRenderer`).

### Inside the renderer

```mermaid
sequenceDiagram
    participant R as Renderer
    participant T as Token
    participant S as Stream
    participant W as WorkRecords
    participant CS as ContentStore
    participant L as StatementLog
    R->>T: supportsInterface(IERC1155)
    opt the token is an edition
        R->>T: masterOf(id)
    end
    R->>S: work, workRecords, collection
    R->>W: isOpen(workId)
    opt record open
        R->>W: record, mediaOf
        R->>CS: fileInfo of the primary
        R->>CS: fileInfo, isComplete, readChunk of the record
    end
    R->>W: seedOf, open record only
    R->>L: latestDisputeOutcome(stream, workId)
    opt record accepted
        R->>CS: fileInfo, isComplete, isBase64Attested, readChunk of the media
        R->>W: preferredLocator for files not inlined
        R->>W: licenseOf(workId)
    end
```

- For a Stream token, `Token` and `Stream` are the same contract. Before the record is open, a
  VRF seed is read from `Stream.entropyModule()` by item hash instead of `seedOf`.
- **Gas left.** Every arrow is one `BoundedCall` with its own gas and return cap. Before each
  read the renderer requires `gasleft()` to cover the cap, EIP-150's 1/63 retention,
  `AFTER_GAS` (50,000) and `BoundedCall.CALL_RESERVE` (1,000), or reverts with
  `BoundedCallInsufficientGas`. The media-list read alone needs about 1.07M gas left
  (`MEDIA_GAS` 1,000,000 plus 15,874 plus 51,000), so a caller must supply well over the gas the
  call uses.
- Media bytes are read one store chunk at a time (`readChunk`, at most 24,575 bytes and 300,000
  gas each) straight into the single output buffer.
- **Gas.** At most 8M Prague gas for every work the protocol allows (RND-26;
  [ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#the-table), decision 1). With every
  cap filled at once the highest figure found is 7,796,194. The budget proof is
  [`TokenUriBudget.t.sol`](../../test/integration/TokenUriBudget.t.sol) on the real stack; the
  record matrix and each limit on its own are in
  [`RendererGas.t.sol`](../../test/content/renderer/RendererGas.t.sol), which print their
  figures with `-vv`.

### `Editions.uri`

```mermaid
sequenceDiagram
    participant C as Caller
    participant E as Editions
    participant S as Stream
    participant R as Renderer
    C->>E: uri(id)
    E->>E: the edition must exist
    E->>S: rendererOf(id)
    S-->>E: the renderer of the master
    E->>R: tokenURI(editions, id)
    R->>E: supportsInterface(IERC1155) is true
    R->>E: masterOf(id)
    E-->>R: stream, workId, contentHash
    R->>S: reads the master as above
    Note over R: the primary SHA-256 must equal contentHash
    R-->>E: metadata of the master plus the Edition of trait
    E-->>C: data URI
```

The edition ID equals the master's token ID. The renderer recognises an edition only by ERC-165
support for `IERC1155` (RND-22).

### `setDefaultRenderer`

```mermaid
sequenceDiagram
    participant A as Hot admin Safe
    participant M as AccessManager
    participant S as Stream
    participant E as Editions
    A->>M: schedule setDefaultRenderer (SUCCESSOR_SETTER, 30 days)
    Note over M: guardians can cancel during the delay
    A->>M: execute after 30 days
    M->>S: setDefaultRenderer(expected, next, nextCodeHash)
    S->>S: expected must equal the current default
    S->>S: next has code, is not delegated, supports IRenderer, codehash matches
    S->>S: emit DefaultRendererSet and BatchMetadataUpdate(1, totalMinted)
    S->>E: notifyAllUpdated()
    E->>E: emit BatchMetadataUpdate(0, max)
```

- A stale `expected` reverts with `ExpectedValueMismatch`; any failed check is
  `InvalidBinding(next)` (`_requireRenderer`).
- The state hash of every unfinalized work changes, because it commits to the effective
  renderer, so a signature over the old one (a pending `finalize`, relicense or rate change) no
  longer applies.
- The batch events are skipped when nothing is minted yet and Editions is not bound
  (`test_setDefaultRenderer_quietBeforeFirstMintAndBinding`).

### Finalize and the errata repin

[Works and storage](works-and-storage.md#set-the-record-and-finalize) specifies `finalize` and
[the errata repin](works-and-storage.md#relicense-royalty-rate-and-errata-repin). For rendering:
`finalize` reverts with `InvalidBinding` if the default renderer's code changed (RND-3), and a
finalized record the pinned renderer refuses stays core-only `invalid`.

## Rules and invariants

### Output format

The output is `data:application/json;utf8,` followed by one compact JSON object. It is not
base64: inline media is already base64 text, and encoding it again would cost gas and a third
more size. Members appear in this order; an optional member is left out when it has no value.

| Member | Full record | Core-only | Value |
| --- | --- | --- | --- |
| `name` | always | always | The record's `name`; core-only: `<collection name> #<serial>` |
| `description` | always | always | The record's `description`, or `""` when absent; core-only: `The work record is not available.` |
| `image` | optional | never | See [Media selection](#media-selection) |
| `animation_url` | optional | never | See [Media selection](#media-selection) |
| `media_url` | optional | never | The primary file's preferred locator, when the primary is not inlined |
| `record_status` | never | always | `not_open`, `incomplete` or `invalid` |
| `content_type` | always | never | The primary file's MIME type from the store |
| `content_hash` | always | never | The primary's SHA-256 of the decoded media, `0x` and 64 hex digits |
| `license` | always | never | The license's SPDX identifier as stored, in its original case |
| `license_url` | optional | never | See [License fields](#license-fields) |
| `license_text_file` | optional | never | The license text's content-store file ID, `0x` and 64 hex digits |
| `attributes` | always | always | The renderer's traits, then (full record only) the record's own `attributes` elements |

The renderer writes these traits, in this order, each as `{"trait_type":...,"value":...}`:

| Trait | Written when | Value |
| --- | --- | --- |
| `Artist ID` | core-only only | The lead artist ID as a lowercase hex string, whole bytes (`Strings.toHexString(uint256)`) |
| `Artist` | full record, once per element of `artists` | The element, as the record wrote it |
| `Year` | full record with `year` | The number, as the record wrote it |
| `Medium` | full record with a non-empty `medium` | The string |
| `Dimensions` | full record with a non-empty `dimensions` | The string |
| `Collection` | the work has a collection (every Stream work does) | The collection name |
| `Serial` | the same | The serial, a number |
| `Edition of` | the token is an edition | The master's token ID, a number |
| `Seed` | the work is seeded and its seed is readable | `0x` and 64 hex digits |
| `Dispute statement` | the renderer has a statement log and `latestDisputeOutcome` is nonzero | The entry hash, `0x` and 64 hex digits |

Before the record opens, only a VRF seed can be shown; an ARTIST seed appears once the record is
open, in core-only and full metadata alike. The fallback name `6529 Works #<id>` exists for a
token without a collection, which Stream never mints.

### Media selection

The primary file is the first entry of `mediaOf`, which must have role `PRIMARY`. The preview
is the first `PREVIEW` entry, used only if its MIME type is `image/*`.

The primary is **inlined** when the work is on-chain complete, the file is complete, its
cost-weighted size is at most the limit (`inlineThreshold()` for `tokenURI`, 1 MiB for
`fullTokenURI`), and its encoding can be served as the media itself:

| Stored encoding | Inlined as |
| --- | --- |
| `Base64`, attested | `data:<mime>;base64,` followed by the stored text, copied as it is |
| `Base64`, not attested | never; served by locator |
| `Identity` (not a script) | `data:<mime>;base64,` followed by the bytes, base64-encoded on-chain (counts eight times) |
| `Identity` script (`text/javascript` or `application/javascript`) | an HTML page around the script (below), as `data:text/html;base64,...`, if the script is at most 8,192 bytes (`SCRIPT_LIMIT`; `fullTokenURI` lifts this to its size limit), valid UTF-8, holds at most 1,024 `<` (`MAX_SCRIPT_LT`) and the record declares no `dependencies` |
| `Base64` or `Gzip` script, `Gzip`, `GzipBase64` | never; served by locator |

A preview is inlined by the same encoding rules when it is complete in the store and its
cost-weighted size is at most `PREVIEW_LIMIT` (65,536), without the work being on-chain complete.
`WorkRecords.openRecord` caps an `Identity` or `Base64` preview lower, at
`Limits.MAX_PREVIEW_BYTES` (16,384 stored bytes, an `Identity` file counting four times), which
keeps the 8M budget.

The three media members are then:

- `media_url`: the primary's preferred locator, whenever the primary is not inlined.
- An image primary (`image/*`) is the `image`: inline if inlined; otherwise the preview if there
  is one (inline or its locator); otherwise the primary's locator.
- Any other primary is the `animation_url` (inline or its locator), and the preview, if any, is
  the `image` (inline or its locator).

A locator is the `preferredLocator` answer, used as it is (RND-20): kind NONE (no copy) or
ONCHAIN (the implicit on-chain copy) leaves the member out, and no other copy is sought.

### The page around a script

A JavaScript primary is wrapped in a fixed page:

```html
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body{margin:0;height:100%;overflow:hidden}</style></head><body><script>window.works={v:1,tokenId:7,seed:"0x...64 hex digits"};</script><script>/* the artist's script */</script></body></html>
```

- [`window.works`](../glossary.md#windowworks) is a public, stable interface: `v` (1), `tokenId`
  (the rendered ID; for an edition, the edition ID, which equals the master's) and `seed` (`0x`
  hex, or `null` without a seed). A change to its fields needs a new `v`, which means a new
  renderer.
- `HtmlScript.neutralize` inserts a backslash after the `<` of every `</script` (any case) and
  every `<!--` in the artist's script. `<!--` matters because it can start the HTML parser's
  "double escaped" state, after which the next `</script>` no longer closes the element. The
  rewrite is exact inside JavaScript strings, template literals and comments, and changes code
  elsewhere: the page uses a classic script, in which `<!--` starts a single-line comment, so
  `a<!--b` is a comment to the browser and a syntax error after the rewrite, and
  `x</script/i.test(s)` (a comparison with a regular expression) becomes a different
  expression. Code that needs either sequence splits it (`"<" + "/script"`), which passes
  through unchanged.
- A record declares `dependencies` when that member's JSON value is longer than two bytes, so
  `[]` declares none but `[ ]` does; a script whose record declares any is served by locator.
- A `text/html` primary is inlined as it is, never rewritten.

### fullTokenURI

`Renderer.fullTokenURI(token, id)` is the same render with the limit raised to
`MAX_INLINE_BYTES` (1,048,576 cost-weighted: a `Base64` file up to 1 MiB, an `Identity` file
up to 128 KiB) and no fallback: it reverts with `RendererNotInlineable` for a core-only work or a
primary it cannot inline under those limits. Call it on `Stream.rendererOf(id)`, with `eth_call`. It has no 8M promise: 1 MiB of `Base64`
costs about 30M gas, 512 KiB about 8.4M (`test_FullForm_1MiB` and `test_FullForm_512KiB` in
[`RendererGas.t.sol`](../../test/content/renderer/RendererGas.t.sol)).

### License fields

- `license` is `IWorkRecords.licenseOf(workId).spdxId`, always present in full metadata; a work
  with no stored license reads the deployment's CC0 license.
- `license_url` is `https://spdx.org/licenses/<id>.html`, in the identifier's own case, for an
  identifier made only of `A-Z a-z 0-9 . + -` that is not a `LicenseRef-` expression in any
  case. Otherwise it is the preferred locator of the license text file, if the work lists that
  file among its media, else left out.
- `license_text_file` is the license text file ID whenever the license has one.

### Rules

| ID | Rule | Enforced in | Tested by |
| --- | --- | --- | --- |
| RND-1 | A token is served by its pinned renderer once finalized, else by the default renderer; never by any other. | `Stream.rendererOf` | [`Stream.t.sol`](../../test/stream/Stream.t.sol) `test_setDefaultRenderer`; [`WorkRecords.t.sol`](../../test/stream/WorkRecords.t.sol) `test_finalize_pinsDefaultRenderer` |
| RND-2 | A renderer whose code is no longer the code hash it was installed or pinned with is refused at every use; `tokenURI` and `uri` revert instead of falling back (DEPS-6). | `Stream.rendererOf`, `WorkRecords.pinnedRenderer` | [`RendererCodePin.t.sol`](../../test/integration/RendererCodePin.t.sol) `test_DefaultRendererWithChangedCodeIsRefused`, `test_PinnedRendererWithChangedCodeIsRefused` |
| RND-3 | Finalize pins the default only while its code is unchanged; an address is pinned with one code hash for good. | `WorkRecords.finalize`, `_pinCode` | `RendererCodePin.t.sol` `test_FinalizeRefusesADefaultRendererWhoseCodeChanged`, `test_RepinRefusesARendererWhoseCodeChangedSincePinned` |
| RND-4 | A new default renderer must have code, not be an EIP-7702 delegated account, support `IRenderer` by ERC-165 and match the given code hash; the setter is compare-and-set and SUCCESSOR_SETTER (30 days). | `Stream.setDefaultRenderer`, `_requireRenderer` | `Stream.t.sol` `test_setDefaultRenderer_reverts` |
| RND-5 | The errata repin needs a finalized work, the same renderer checks, the current state hash, an unexpired deadline and the artist's signature by the active authority, plus SUCCESSOR_SETTER (30 days). | `WorkRecords.repinRenderer` | `WorkRecords.t.sol` `test_repinRenderer_errataPath`, `test_repinRenderer_reverts` |
| RND-6 | Every external read is a bounded `staticcall` with its own gas and return cap; a failed read reverts (`RendererReadFailed`, or `BoundedCallFailed` and `BoundedCallMalformedReturn` for a chunk). | `Renderer._read`, `_copyFile`, `BoundedCall` | [`RendererHostile.t.sol`](../../test/content/renderer/RendererHostile.t.sol) `test_Token_ReturnDataBombsAndGasBurnersFailClosed`, `test_Store_ARevertingOrOversizedChunkReadFailsClosed`; [`Renderer.t.sol`](../../test/content/renderer/Renderer.t.sol) `test_FailsClosed_EveryReadOfTheStreamAndRecords` |
| RND-7 | Too little gas to forward a read's full cap reverts with `BoundedCallInsufficientGas`; it is never reported as a failed or empty read. | `BoundedCall.tryRead` | `RendererHostile.t.sol` `test_NotEnoughGasRevertsInsteadOfMisreporting` |
| RND-8 | A store chunk must have the length the layout rule gives, or the call reverts. | `Renderer._copyFile` | `RendererHostile.t.sol` `test_Store_ChunksOfTheWrongLengthRevert` |
| RND-9 | A record that is not open, not registered or not complete, or not acceptable gives core-only metadata with `record_status`, never a revert; `fullTokenURI` reverts for it. | `Renderer._render`, `_record`, `_coreOnly` | `Renderer.t.sol` `test_CoreOnly_UntilTheRecordIsOpen`, `test_CoreOnly_WhenTheRecordFileIsNotCompleteYet`, `test_Record_MalformedRecordsFallBackToCoreOnly` |
| RND-10 | A record is acceptable only if it is `Identity`, at most 12,288 bytes, valid UTF-8, holds at most 512 `%` and `#`, and passes `JsonScan.object` (RFC 8259 object; no backslash in a key; no `\u0000`, lone surrogate or bad hex digit; numbers of at most 24 bytes and two exponent digits; at most 1,024 units and 8 levels; no duplicate of a member the renderer reads). | `Renderer._record`, `JsonScan` | `Renderer.t.sol` `test_Record_MustBeAnIdentityFileWithinTheSizeLimit`, `test_Record_DuplicatedMembersFallBack`; [`RendererReview.t.sol`](../../test/content/renderer/RendererReview.t.sol) `test_M3_AKeyWithAnEscapeMakesTheRecordInvalid`, `test_M4_NulAndLoneSurrogatesMakeTheRecordInvalid`, `test_H2_AtMostTheCapOfPercentAndHashEscapes`; [`JsonScan.t.sol`](../../test/content/renderer/JsonScan.t.sol) `testFuzz_AgreesWithSerdeJson` |
| RND-11 | `name` is a non-empty string; `description`, `medium` and `dimensions` are strings if present; `artists` is an array of at most 16 non-empty strings; `year` is an integer of at most six digits with an optional minus. | `Renderer._describe`, `_year` | `Renderer.t.sol` `test_Record_WrongTypesAndMissingNameAreRejected`, `test_Record_TooManyArtistsFallBack`; `RendererReview.t.sol` `test_H2_TheYearIsAnIntegerOfAtMostSixDigits` |
| RND-12 | `attributes` is an array of at most 32 objects with only the keys `trait_type`, `value`, `display_type` and `max_value`, each at most once; `trait_type` is a string and `value` a string or number. | `Renderer._attributes`, `JsonScan.records` | `RendererReview.t.sol` `test_H2_AtMostTheCapOfAttributes`, `test_N3_ADuplicatedAttributeMemberIsInvalid`; `Renderer.t.sol` `test_Record_NumbersAndStringsAsAttributeValues` |
| RND-13 | A record `trait_type` is printable ASCII, has no backslash and no two spaces in a row, and is none of the renderer's ten trait names in any case or spacing. | `Renderer._reserved` | `RendererReview.t.sol` `test_L2_ARecordCannotUseARendererTraitName`, `test_L2_TheReservedNamesAreExactlyTheOnesTheRendererWrites`; [`RendererOracles.t.sol`](../../test/content/renderer/RendererOracles.t.sol) `test_TraitNamesFollowTheRule` |
| RND-14 | The renderer's traits come first; the record's attributes follow, copied as they are. | `Renderer._tail` | `Renderer.t.sol` `test_Record_AttributesAreCopiedAfterTheRenderersOwnTraits` |
| RND-15 | Record text is copied as validated JSON, never decoded; every string from Stream, a locator or the store is checked as UTF-8 and escaped by `JsonEscape`; the whole output is percent-escaped for `%` and `#`. | `Renderer._record`, `_str`, `DataUri.escape` | `Renderer.t.sol` `test_Record_PercentAndHashInRecordStringsSurviveTheUri`, `test_InvalidUtf8_InLicenseCollectionAndLocator`; `RendererReview.t.sol` `test_E6_PercentAndHashInStreamAndSatelliteStringsAreEscaped` |
| RND-16 | The media list must start with a `PRIMARY` file, and an edition's content hash must be its master's primary SHA-256, or the call reverts with `RendererRecordInvalid`. | `Renderer._loadRecord` | `Renderer.t.sol` `test_FailsClosed_ThePrimaryMediaFileIsRequired`, `test_Edition_ContentHashMustMatchTheMaster` |
| RND-17 | A primary is inlined only when the work is on-chain complete, the file is complete, and its cost-weighted size is at most the limit (inclusive). | `Renderer._primary`, `_weight` | [`RendererMedia.t.sol`](../../test/content/renderer/RendererMedia.t.sol) `test_Locator_NotOnChainCompleteIsNotInlined`, `test_Inline_TheThresholdIsInclusive`, `test_Inline_AnIdentityFileCountsEightTimes` |
| RND-18 | `Base64` text is copied only once attested; `Gzip` and `GzipBase64` are never inlined. | `Renderer._inline` | `RendererMedia.t.sol` `test_Base64_AFileThatIsNotStrictBase64IsNeverCopied`, `test_Base64_AValidFileIsCopiedOnlyOnceAttested`, `test_Locator_GzipFilesAreNeverInlined`; [`ContentToTokenURI.t.sol`](../../test/integration/ContentToTokenURI.t.sol) `test_UnattestedBase64IsNotInlined` |
| RND-19 | A script is wrapped only if `Identity`, UTF-8, within its size limit, at most 1,024 `<`, and without declared `dependencies`; `</script` and `<!--` are neutralized. | `Renderer._inline`, `_shell`, `HtmlScript.neutralize` | `RendererMedia.t.sol` `test_Script_IsWrappedInAPageThatSetsWindowWorks`, `test_Script_ADeclaredDependencyIsServedByLocatorNotWrapped`, `test_Script_NotInlinedUnlessIdentityStoredUtf8AndSmall`; `RendererOracles.t.sol` `test_NeutralizeMatchesTheTokenizerCheckedMirror` |
| RND-20 | The preferred locator is used as the satellite answers it; NONE and ONCHAIN give no URL; a failed read reverts. | `Renderer._locator` | `RendererMedia.t.sol` `test_Locator_AnOnChainPreferenceGivesNoUrl`, `test_Locator_AFailedReadFailsClosed`; `RendererReview.t.sol` `test_M1_APreferredLocatorThatRunsOutOfGasFailsClosed` |
| RND-21 | `fullTokenURI` inlines up to 1 MiB cost-weighted and reverts instead of falling back. | `Renderer.fullTokenURI`, `_primary` | `RendererMedia.t.sol` `test_Full_InlinesWhatTheCompactFormMustNot`, `test_Full_RevertsWhenThePrimaryCannotBeInlined` |
| RND-22 | An edition renders its master's record, media and license, plus `Edition of`; its dispute status is its master's. | `Renderer._load`, `_chainTraits` | `Renderer.t.sol` `test_Edition_RendersTheMastersWorkAsAnEdition`, `test_Dispute_ReadsTheMastersSubjectForAnEdition`; [`MasterEdition.t.sol`](../../test/integration/MasterEdition.t.sol) `test_EditionRendersItsMastersMetadata` |
| RND-23 | The dispute status is `latestDisputeOutcome(stream, workId)`, shown as `Dispute statement` when nonzero; a renderer with no log shows none; a broken log reverts. | `Renderer._chainTraits` | `Renderer.t.sol` `test_Dispute_ShownWhenTheLogHasAnOutcome`, `test_Dispute_NoLogConfiguredMeansNone`, `test_Dispute_ABrokenLogFailsClosed` |
| RND-24 | `license_url` is the SPDX page only for an SPDX identifier that is not `LicenseRef-`; otherwise the text file's locator, if listed among the media. | `Renderer._licenseUrl` | `Renderer.t.sol` `test_License_UrlIsTheSpdxPageInTheOriginalCase`, `test_License_NoUrlForALicenseRefInAnyCaseOrAnEmptyId`; `RendererReview.t.sol` `test_L1_TheLicenseUrlComesOnlyFromAnSpdxIdentifier` |
| RND-25 | The threshold is between 1 and 1,048,576. | `Renderer` constructor | `Renderer.t.sol` `test_Constructor_RejectsBadThresholds` |
| RND-26 | `tokenURI` and `Editions.uri` cost at most 8M Prague gas with every cap at once, and create no state. | the caps above, `Stream.createCollection` (no control characters, `<`, `"` or `\`), `WorkRecords.openRecord` (preview cap) | [`TokenUriBudget.t.sol`](../../test/integration/TokenUriBudget.t.sol) `test_Budget_*`, `test_CollectionName_RefusesBytesThatEscapeLong`, `test_PreviewCap_OpenRecordRefusesALargerPreview`; `RendererGas.t.sol` (`RendererGasBudgetTest`, `RendererGasAdversarialTest`) |
| RND-27 | Every visible change to a work's metadata made through `WorkRecords` or Stream emits ERC-4906 on Stream and, for a master with an edition, on Editions (exceptions under [Events](#events)). | `WorkRecords._refresh`, `_refreshAll`, `Stream.setDefaultRenderer` | `WorkRecords.t.sol` `test_preferenceSetters_eventsAndRefresh`, `test_preferenceSetters_notifyAllEditions`; [`Editions.t.sol`](../../test/editions/Editions.t.sol) `test_NotifyMasterUpdated_EmitsForEditionsOnly`; `Stream.t.sol` `test_emitMetadataUpdate_fromRecords` |

## Events

The renderer emits nothing; the metadata events and their triggers are under
[Stream](../integrators/events-and-indexing.md#stream),
[WorkRecords](../integrators/events-and-indexing.md#workrecords) and
[Editions](../integrators/events-and-indexing.md#editions). Three changes reach `tokenURI` with
no ERC-4906 event, because the contract that changes does not know the works affected: a record
or preview file completing in the store, `attestBase64` on a primary or preview, and a new
`DISPUTE_OUTCOME` statement about the token or the item it was minted from; a renderer whose code
changed makes `tokenURI` revert, also without an event.

## Failure modes and recovery

| Failure | Effect | Recovery |
| --- | --- | --- |
| The default renderer's code changed | Every unfinalized work and its edition reverts with `InvalidBinding(renderer)`; so does `finalize` | SUCCESSOR_SETTER installs a new default (`setDefaultRenderer`, 30 days) |
| A finalized work's pinned renderer's code changed | That work's `tokenURI` and its edition's `uri` revert with `InvalidRenderer(renderer)` | Errata repin (artist signature plus SUCCESSOR_SETTER, 30 days); a lost artist key is recovered first through the artist registry |
| A dependency read fails (no code, revert, out of its gas cap, too much return data) | `RendererReadFailed(target, selector)`, or for a chunk `BoundedCallFailed` or `BoundedCallMalformedReturn` | The renderer's content store and statement log are fixed at construction: a broken one needs a new renderer (a new default, or an errata repin) |
| The caller supplied too little gas | `BoundedCallInsufficientGas(gasLimit)` | Supply more gas (see [Inside the renderer](#inside-the-renderer)) |
| The record is not open | Core-only, `not_open` | Anyone calls `openRecord` |
| The record file is not registered or not completely uploaded | Core-only, `incomplete` | Anyone registers the manifest and uploads the chunk |
| The record is refused | Core-only, `invalid` | Before finalize, the artist calls `setRecord`. After finalize only an errata repin to a renderer that accepts it changes the output |
| A broken media list or edition hash (RND-16), or a string that is not UTF-8 | `RendererRecordInvalid`, `RendererInvalidUtf8` | Not reachable through the deployed contracts, which enforce both |
| The primary is not inlineable | `tokenURI` serves the preferred locator, and a preview | Anyone uploads the missing chunks and calls `syncOnChain` or attests a `Base64` file; the artist (before finalize) or PLATFORM adds a locator |
| The primary is over the threshold and has no ARWEAVE or IPFS locator | No `image`, `animation_url` or `media_url` for the primary | `fullTokenURI` up to 1 MiB, or the content store's chunked reads; PLATFORM registers a locator |
| `fullTokenURI` cannot inline the work | `RendererNotInlineable(token, id)` | Use `tokenURI` and the locator, or read the content store |

## Parameters and limits

| Parameter | Value | Source |
| --- | --- | --- |
| `tokenURI` gas budget | 8,000,000 Prague gas | [ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#the-table) decision 1; `TOKEN_URI_BUDGET` in `test/integration/IntegrationBase.sol` |
| Inline threshold | `DEFAULT_INLINE_THRESHOLD`, 262,144 cost-weighted bytes; the deployment passes it | `Renderer.DEFAULT_INLINE_THRESHOLD`; `RENDERER_INLINE_THRESHOLD` in [`script/DeployV1.sol`](../../script/DeployV1.sol) |
| Allowed thresholds | 1 to 1,048,576 | `Renderer` constructor |
| `Identity` weight | 8 times its stored length | `Renderer._weight` |
| `fullTokenURI` limit | 1,048,576 cost-weighted bytes | `MAX_INLINE_BYTES` (internal) |
| Preview limit, renderer | 65,536 cost-weighted bytes | `PREVIEW_LIMIT` (internal) |
| Script page size, `tokenURI` | 8,192 stored bytes | `SCRIPT_LIMIT` (internal) |
| `<` in a wrapped script | at most 1,024 | `MAX_SCRIPT_LT` (internal) |
| `window.works` version | 1 | `SHELL_HEAD` |
| Artists per record | 16 | `Limits.MAX_ARTISTS` |
| Attributes per record | 32 | `MAX_ATTRIBUTES` (internal) |
| `%` and `#` per record | 512 | `MAX_ESCAPES` (internal) |
| JSON units (values, keys, escapes) | 1,024 | `JsonScan.MAX_VALUES` |
| JSON nesting | 8 levels | `JsonScan.MAX_DEPTH` |
| JSON number | at most 24 bytes, exponent at most 2 digits | `JsonScan` |
| Collection name | 1 to 256 bytes of UTF-8, no control characters, `<`, `"` or `\` | `Stream.MAX_NAME_BYTES`, `createCollection` |
| Read gas caps | 300,000 (`SMALL_GAS`, most reads); 1,000,000 (`MEDIA_GAS`, `mediaOf`); 300,000 (`CHUNK_GAS`, `readChunk`); 700,000 (`COMPLETE_GAS`, `isComplete`) | `Renderer` (private) |
| Gas kept after each read | 50,000 (`AFTER_GAS`) plus 1,000 (`BoundedCall.CALL_RESERVE`) | `Renderer`, `BoundedCall` |
| Return caps | 4,096 bytes (`collection`); 2,304 (`preferredLocator`, `Limits.MAX_URI_BYTES` plus 256); 3,136 (`mediaOf`, 64 plus 96 per file); 512 (`fileInfo`); 288 (`work`); 256 (`record`, `licenseOf`); 96 (`masterOf`); 64 (`seedOf`); 32 (every one-word read); 24,575 (`readChunk`, `SSTORE2.MAX_CHUNK_LENGTH`) | `Renderer` |

Record size, media files and locators per file are limits of [Works and storage](works-and-storage.md#parameters-and-limits).

## Differences from the ADRs

See the [register](README.md#differences-from-the-adrs).

## References

- Code: the sources under [Contracts](#contracts),
  [`WorkRecords.sol`](../../src/stream/WorkRecords.sol),
  [content README](../../src/content/README.md).
- ADRs: [ADR 0001 §8](../adr/0001-v1-scope.md#8-works-content-and-storage) and
  [§10](../adr/0001-v1-scope.md#10-permanence);
  [ADR 0003](../adr/0003-build-time-decisions.md#token-model-and-storage-amends-adr-0001-4-and-8);
  [ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#the-table).
- Tests: [`test/content/renderer/`](../../test/content/renderer), the files in the rules table,
  and [`RecordAmendments.t.sol`](../../test/integration/RecordAmendments.t.sol).
- Measurements: [`deployments/11155111/flows.md`](../../deployments/11155111/flows.md)
  (`tokenURI` on Sepolia).
- Related pages: [Works and storage](works-and-storage.md),
  [Editions and sales](editions-and-sales.md), [Disputes and statements](disputes-and-statements.md),
  [Governance](governance.md), [Identity and recovery](identity-and-recovery.md),
  [Reading a work](../integrators/reading-a-work.md),
  [Events and indexing](../integrators/events-and-indexing.md).
