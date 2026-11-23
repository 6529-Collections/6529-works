# content

On-chain content and metadata: the permissionless content store that keeps any file as
content-addressed SSTORE2 chunks, the governed registry of pinned script libraries, and the
renderer that builds `tokenURI` for 6529 Stream works and their editions in 6529 Stream
Editions. The storage rules are in [Works and storage](../../docs/spec/works-and-storage.md)
(`WS-24` to `WS-35`, `WS-50` to `WS-54`); the metadata format, media selection, record validation and the 8M gas budget in
[Rendering and tokenURI](../../docs/spec/rendering-and-tokenuri.md) (`RND-*`). Off-chain
tooling to plan, upload, attest and verify files, with gas quotes under Prague and Glamsterdam,
is the [uploader](../../tools/content/README.md).

## Files

| File | What it is |
| --- | --- |
| `ContentStore.sol` | [`IContentStore`](../interfaces/IContentStore.sol): chunks (whole or linked from parts), manifests (in one call or from list chunks), completeness by range, verified chunk and range reads, the base64 attestation in pieces, and [`IChunkStore`](../interfaces/IChunkStore.sol) for store adapters. No owner, no governance, nothing payable. |
| `Base64Validator.sol` | Internal library: the strict RFC 4648 alphabet check behind `attestBase64`, 32 bytes per step. |
| `DependencyRegistry.sol` | [`IDependencyRegistry`](../interfaces/IDependencyRegistry.sol): `(name, version)` to a complete store file, forever; deprecation is a one-way flag. |
| `Renderer.sol` | [`IRenderer`](../interfaces/IRenderer.sol): `tokenURI` and `fullTokenURI`. Immutable and stateless. |
| `JsonScan.sol` | Internal library: a strict RFC 8259 scanner that validates the record and reports where each value sits. Never decodes, never reverts. |
| `DataUri.sol`, `HtmlScript.sol` | Internal libraries: percent-escaping of `%` and `#`; neutralizing `</script` and `<!--` in a wrapped script. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Anyone (artist, platform, collector, uploader) | `writeChunk`, `linkChunk`, `registerManifest`, `registerManifestList`, `attestBase64`, `attestComplete`, in any order | WS-24 to WS-27, WS-29, WS-31, WS-50, WS-51, WS-55 |
| Anyone; `StreamWorkFacts6529`; the renderer | `fileInfo`, `sha256Of`, `isComplete`, `completeThrough`, `firstMissing`, `missingChunks`, `readChunk`, `chunkData`, `read`, `isBase64Attested` | WS-28, WS-30, WS-52, WS-53, WS-55 |
| Governance | `DependencyRegistry.register`, `deprecate` | WS-34, WS-35; [role matrix](../../docs/audit/roles.md#dependencyregistry) |
| `Stream6529.tokenURI`, `StreamEditions6529.uri` (through `rendererOf`); anyone by `eth_call` | `Renderer.tokenURI(token, id)`, `fullTokenURI(token, id)` | RND-1 to RND-27 |

The upload flow is under [Upload and register a file](../../docs/spec/works-and-storage.md#upload-and-register-a-file),
and what the renderer reads, in order, under
[Inside the renderer](../../docs/spec/rendering-and-tokenuri.md#inside-the-renderer).
Integrators start at [Reading a work](../../docs/integrators/reading-a-work.md) and
[Storage](../../docs/spec/works-and-storage.md).

## Developer notes

- **The file ID is permanent and chain-independent.** Changing its formula, `CHUNK_SIZE` or the
  layout rule breaks every package and the uploader's golden vectors (WS-33).
- **Storage layout.** A file's `entries` are its chunk hashes (`hashesPerList` 0) or its list
  chunks' pointers; a link is one `(length, count)` word and one pointer per part.
  `chunkPointer` is zero for a linked chunk: read it with `chunkData` or `readChunk` (WS-50).
  `completeThrough` (the last slot) is each file's attested prefix of present chunks; only
  `attestComplete` writes it, and `isComplete` walks only past it (WS-55).
- **Writes trust CREATE2's result (WS-24).** No read or write recomputes an address, and the
  store deduplicates by `chunkPointer` before writing (a repeat CREATE2 would collide).
- **Large reads are superlinear.** Every touched chunk is read in full and checked against its
  keccak256; on-chain callers read chunk by chunk or in ranges of a few hundred KiB.
- **Renderer reads.** Every external read uses `BoundedCall.tryReadAll` with no compiled gas
  figure, since a finalized work pins its renderer, possibly for good. A work is read only
  through plain views: `IStream.workOf` and `collectionOf`, `IEditions.stream()` for an edition
  (its ID is the master's token ID), and `IWorkFacts.factsOf` once (record file, media, license,
  on-chain flag; the seed is `Work.seed`). A failed read of these fails the call, except the
  collection name, which is then no name.
- **The renderer owns the locator check.** It asks the token's RECORDS module for its delivery
  contract and that for `ILocators.preferredLocator`, and prints a URI only if the answer is a
  canonical encoding of a kind other than NONE and ONCHAIN with 1 to `Limits.MAX_URI_BYTES`
  bytes of printable ASCII other than space, `"` and `\`. Anything else, a revert included, is
  "no locator"; running short of gas still reverts (`RendererHostile.t.sol`,
  `RendererCore.t.sol`).
- **The 8M budget is a joint bound** (RND-26). Raising any record cap or the preview bound
  (`PREVIEW_LIMIT`, `Limits.MAX_PREVIEW_BYTES`), or changing `JsonScan`, `JsonEscape`, `Utf8`,
  `HtmlScript` or the read path, means rerunning
  [`RendererGas.t.sol`](../../test/content/renderer/RendererGas.t.sol) and
  `TokenUriBudget.t.sol`; the margin is small.
- **`window.works` is a public API.** Finalized works pin their renderer, so version 1's fields
  never change meaning; a change needs a new `v` and a new renderer.
- **Behavior is owned by the spec:** piecewise writes and links (WS-50, WS-51), bounded source
  answers (WS-52), open encoding ids (WS-54), degraded versus reverting metadata (RND-9,
  RND-16), and the part-count limit (RND-26, LIM-CNT-22).
- **Bytecode: `Renderer` is the second-tightest contract**, barely under EIP-170 (current
  margin in the [audit scope](../../docs/audit/scope.md#modules)). New features
  belong in a later renderer, which works pin per work.
- **Tests:** `forge test --match-path 'test/content/**'`: the store, the dependency registry,
  the renderer and the uploader's golden and CID vectors. Halmos proofs of `Base64Validator`,
  `DataUri` and `HtmlScript` are in `test/symbolic/` ([Testing](../../docs/testing/README.md)).
  End to end: `ContentToTokenURI.t.sol`, `TokenUriBudget.t.sol` and `SyncOnChainResume.t.sol`
  in [`test/integration/`](../../test/integration/).

## Known gaps in v1

No gzip page (compressed media is served by locator), no dependency bundling, and small inline
limits for scripts and `Identity` media: LIM-CNT-5 to LIM-CNT-9 in
[known limitations](../../docs/audit/known-limitations.md#content-records-and-rendering).

## See also

[ADR 0001 §8](../../docs/adr/0001-v1-scope.md#8-works-content-and-storage) and
[§10](../../docs/adr/0001-v1-scope.md#10-permanence),
[ADR 0003, token model and storage](../../docs/adr/0003-build-time-decisions.md#token-model-and-storage-amends-adr-0001-4-and-8),
[ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md) (Glamsterdam storage costs);
[Sepolia content receipts](../../deployments/11155111/flows.md#1-content).
