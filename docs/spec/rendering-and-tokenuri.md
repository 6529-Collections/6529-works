# Rendering and tokenURI

How a work and an edition get their token metadata. `Stream6529.tokenURI` and
`StreamEditions6529.uri` ask a renderer, which reads the work through plain views and builds a
`data:` URI. The renderer is a replaceable module until the work is finalized; finalize pins it in
`StreamWorkFacts6529`. Integrators who only read metadata should start with
[Reading a work](../integrators/reading-a-work.md).

> Pre-audit. See the [project status](../../README.md#status).

## Contracts

| Contract | Kind | What it does |
| --- | --- | --- |
| [`Renderer`](../../src/content/Renderer.sol) ([`IRenderer`](../../src/interfaces/IRenderer.sol)) | module (RENDERER), pinned at finalize | Builds `tokenURI` and `fullTokenURI` for works and editions. Stateless; reads only. |
| [`JsonScan`](../../src/content/JsonScan.sol), [`DataUri`](../../src/content/DataUri.sol), [`HtmlScript`](../../src/content/HtmlScript.sol), [`JsonEscape`](../../src/libraries/JsonEscape.sol), [`Utf8`](../../src/libraries/Utf8.sol), [`BoundedCall`](../../src/libraries/BoundedCall.sol) | libraries | Strict JSON scanning, escaping, script neutralizing, UTF-8 checks, bounded reads. |
| `Stream6529`, `StreamEditions6529` | permanent | Choose the renderer and forward `tokenURI` / `uri`; emit ERC-4906. |
| `StreamWorkFacts6529` | permanent | The record, media, license and the pinned renderer. |

## Renderer selection

- A **finalized** work is drawn by the renderer pinned in `StreamWorkFacts6529`
  (`IWorkFacts.rendererOf`). If its code is no longer the code that was pinned, the call reverts.
- An **unfinalized** work is drawn by the token's RENDERER module. If no module is installed, or
  it reverts or runs out of gas, `tokenURI` reverts.
- There is no fallback to another renderer, so `tokenURI` never shows another renderer's picture.
- An edition is drawn by its master's renderer (`IEditions.stream()` is the master's token
  contract; the work ID is the edition ID).
- The network changes the RENDERER module after `moduleDelay` (7 days at launch). It may repin a
  finalized work through the RECORDS module until the artist locks the pin.

## Inside the renderer

All reads are plain views: `IStream.workOf` and `collectionOf` for the work's facts, its seed and
its collection; `IWorkFacts.factsOf(token, id)` once for the record, media, license and
on-chain flag; the content store for bytes; the statement log for a dispute outcome; and the
preferred locator from the delivery module named by the token's RECORDS module
(`ILocators.preferredLocator(token, id, fileId)`).

**The renderer owns the served-locator check.** A locator is served only if it is printable ASCII
(`0x21` to `0x7e`) without `"` or `\`, at most `Limits.MAX_URI_BYTES`, and `ONCHAIN` only when
the work is on-chain complete. A revert or a bad answer from the delivery module is "no
locator". Every other read that fails or runs short of gas reverts the whole call.

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

The seed is `Work.seed`, stored in the token at mint, and is shown from mint. The fallback name
`6529 Works #<id>` exists for a token without a collection, which Stream never mints.

### Media selection

The primary file is the first entry of the work's media in `StreamWorkFacts6529`, which must have
role `PRIMARY`. The preview is the first `PREVIEW` entry, used only if its MIME type is `image/*`.

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
cost-weighted size is at most `PREVIEW_LIMIT` (`Limits.MAX_PREVIEW_BYTES`, 16,384; an `Identity`
file weighs eight times its length, so at most 2,048 `Identity` bytes or 16,384 attested `Base64`
characters), without the work being on-chain complete. `StreamWorkFacts6529` holds no preview bound
(a preview of any size opens); a larger preview is served by locator, which keeps the 8M budget.

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
primary it cannot inline under those limits. Call it on `Stream6529.rendererOf(id)`, with
`eth_call`. It has no 8M promise: 1 MiB of `Base64` costs about 30M gas, 512 KiB about 8.4M
(`test_FullForm_1MiB` and `test_FullForm_512KiB` in
[`RendererGas.t.sol`](../../test/content/renderer/RendererGas.t.sol)).

### License fields

- `license` is `IWorkFacts.factsOf(token, id).licenseId`, always present in full metadata; a work
  with no stored license reads the deployment's CC0 license.
- `license_url` is `https://spdx.org/licenses/<id>.html`, in the identifier's own case, for an
  identifier made only of `A-Z a-z 0-9 . + -` that is not a `LicenseRef-` expression in any
  case. Otherwise it is the preferred locator of the license text file, if the work lists that
  file among its media, else left out.
- `license_text_file` is the license text file ID whenever the license has one.


### Rules

| ID | Rule | Tests |
| --- | --- | --- |
| RND-1 | A finalized work is drawn by its pinned renderer, an unfinalized one by the RENDERER module; never by any other. | `test_RendererOf_PinnedThenModuleThenNone`, `test_RendererOf_UnfinalizedServesTheModule`, `test_Record_PinnedRendererRepinBeforeLockThenFixed` |
| RND-2 | A pinned renderer whose code changed is refused; `tokenURI` and `uri` revert instead of falling back. | `test_RendererOf_RefusesAPinnedRendererWhoseCodeChanged`, `test_RendererOf_RefusesMovedCodeEitherWay`, `test_Uri_AndTokenURIRevertWhenThePinnedRendererCodeChanged` |
| RND-3 | Finalize pins the token's current RENDERER module with its code hash; an address is pinned with one code hash. | `test_Finalize_PinsTheTokensRendererModuleOnce`, `test_Finalize_TheArtistAtAnyTimePinsTheRenderer`, `test_Finalize_RefusesADelegatedRendererModule` |
| RND-4 | A new RENDERER module is installed only after `moduleDelay`, announced by `ModuleProposed`. | `testFuzz_Activate_NeverBeforeTheWait` |
| RND-5 | The network repins a finalized work through the RECORDS module until the pin is locked. | `test_RepinRenderer_TheNetworkAloneAfterFinalize`, `test_Repin_OnlyAfterFinalizeAndNeverOnceLocked`, `test_Renounce_TheRepinPowerByTheArtistsSignatureAloneAfterFinalize`, `test_Record_PinnedRendererRepinBeforeLockThenFixed` |
| RND-6 | Every read forwards all the gas it may with its own return cap; a failed read reverts with `RendererReadFailed`. | `test_Token_ReturnDataBombsAndGasBurnersFailClosed`, `test_FailsClosed_EveryReadOfTheStreamAndRecords` |
| RND-7 | A read that runs short of gas reverts with `BoundedCallShortfall`; an answer is always the full answer. | `test_NotEnoughGasRevertsInsteadOfMisreporting` |
| RND-8 | A store chunk must have the layout length, or the call reverts. | `test_Store_ChunksOfTheWrongLengthRevert` |
| RND-9 | A record that is not open, not complete or not acceptable gives core-only metadata with `record_status`, never a revert. | `test_CoreOnly_UntilTheRecordIsOpen`, `test_CoreOnly_WhenTheRecordFileIsNotCompleteYet` |
| RND-10 | A record is acceptable only if `Identity`, at most 12,288 bytes, valid UTF-8, within the escape cap, and a strict JSON object. | `test_Record_MustBeAnIdentityFileWithinTheSizeLimit`, `testFuzz_AgreesWithSerdeJson` |
| RND-11 | `name` is a non-empty string; `artists` at most 16; `year` at most six digits. | `test_Record_WrongTypesAndMissingNameAreRejected` |
| RND-12 | `attributes` is at most 32 objects with only the four allowed keys. | `test_Record_AtMostTheCapOfAttributes` |
| RND-13 | A record `trait_type` is none of the renderer's trait names. | `test_TraitNames_ARecordCannotUseARendererTraitName` |
| RND-14 | The renderer's traits come first; the record's attributes follow. | `test_Record_AttributesAreCopiedAfterTheRenderersOwnTraits` |
| RND-15 | Record text is copied as validated JSON; every other string is checked as UTF-8 and escaped. | `test_InvalidUtf8_InLicenseCollectionAndLocator` |
| RND-16 | The media list must start with a primary file, or the call reverts. | `test_FailsClosed_ThePrimaryMediaFileIsRequired` |
| RND-17 | A primary is inlined only when the work is on-chain complete, the file complete and its weighted size within the limit. | `test_Locator_NotOnChainCompleteIsNotInlined`, `test_Inline_TheThresholdIsInclusive` |
| RND-18 | `Base64` text is copied only once attested; gzip files are never inlined. | `test_Base64_AValidFileIsCopiedOnlyOnceAttested` |
| RND-19 | A script is wrapped only if small, UTF-8 and without dependencies; `</script` and `<!--` are neutralized. | `test_Script_IsWrappedInAPageThatSetsWindowWorks` |
| RND-20 | The preferred locator is served only if it passes the renderer's locator check; a failing or malformed delivery answer is "no locator". | `test_Locator_AnOnChainPreferenceGivesNoUrl` |
| RND-21 | `fullTokenURI` inlines up to 1 MiB and reverts instead of falling back. | `test_Full_RevertsWhenThePrimaryCannotBeInlined` |
| RND-22 | A work's facts are read through plain views of the token (`workOf`, `collectionOf`) and `StreamWorkFacts6529.factsOf`. | `test_Edition_RendersTheMastersWorkAsAnEdition` |
| RND-23 | The dispute status is the statement log's latest outcome; a broken log reverts. | `test_Dispute_ShownWhenTheLogHasAnOutcome`, `test_Dispute_ABrokenLogFailsClosed` |
| RND-24 | `license_url` is the SPDX page only for an SPDX identifier that is not `LicenseRef-`. | `test_License_UrlIsTheSpdxPageInTheOriginalCase` |
| RND-25 | The inline threshold is between 1 and 1,048,576. | `test_Constructor_RejectsBadThresholds` |
| RND-26 | `tokenURI` and `uri` cost at most 8M Prague gas with every cap at once. | `test_Budget_*` |
| RND-27 | Every visible change to a work's record emits ERC-4906 on its token. | `test_Open_AnyoneOpensWithTheMintedItemAndItsMedia`, `test_SetRecord_TheArtistReplacesItAndTheVersionMoves`, `test_Finalize_EmitsMetadataUpdateOnTheToken`, `test_Relicense_EmitsMetadataUpdateOnTheToken`, `test_RepinRenderer_EmitsMetadataUpdateOnTheToken`, `test_SetFileStore_EmitsMetadataUpdateOnTheToken`, `test_MarkOnChainComplete_EmitsMetadataUpdateOnceOnTheToken`, `test_AddLocator_TheArtistBeforeFinalizeThePlatformAlways`, `test_Delivery_APreferenceAndADeadLocatorEmitMetadataUpdateOnTheToken`, `test_Setters_RefreshTheTokenAndItsEditions`, `test_Refresh_NotifiesTheEditionOfAMaster`, `test_NoOps_EmitNoMetadataUpdate` |
| RND-28 | Retired: there is no default renderer and no fallback path; RND-1 and RND-2 hold. | |

## Events

The renderer emits nothing. Three changes reach `tokenURI` with no ERC-4906 event: a record or
preview file completing in the store, a base64 attestation, and a new dispute statement.

## Failure modes and recovery

| Failure | Effect | Recovery |
| --- | --- | --- |
| No RENDERER module, or it fails | Unfinalized works revert | The network installs one (after `moduleDelay`); the artist may finalize to pin a working one. |
| A pinned renderer's code changed | That work reverts with `RendererCodeChanged` | The network repins, unless the pin is locked. |
| The record is not open, incomplete or refused | Core-only metadata | Anyone opens it or uploads chunks; the artist sets a new record before finalize. |
| The primary is not inlineable | Served by locator, with a preview | Upload, attest, or add a locator. |

## Limits

| Limit | Value |
| --- | --- |
| `tokenURI` gas budget | 8,000,000 Prague gas |
| Inline threshold | 262,144 cost-weighted bytes at launch (1 to 1,048,576) |
| `Identity` weight | 8 times its stored length |
| `fullTokenURI` | 1,048,576 cost-weighted bytes |
| Preview | 16,384 cost-weighted bytes |
| Record | 12,288 bytes, 32 attributes, 16 artists, 512 escapes |
